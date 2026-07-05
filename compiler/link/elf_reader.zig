//! Real ELF64 relocatable object reader (task #345): parses whatever
//! `libbitrt.a`'s member (built by `zig build libbitrt` — a normal Zig
//! compilation, not this project's own `obj/elf.zig` writer) actually
//! contains, and normalizes it into `link/object.zig`'s generic
//! `Module`/`Atom` IR via `atomizeModule`.
//!
//! Scope is deliberately "whatever a real ReleaseSmall, stripped, no-PIC
//! (`build.zig`'s `libbitrt` step) x86-64/ARM64 Linux object contains" —
//! verified empirically against a real build rather than guessed: every
//! `SHT_PROGBITS`/`SHT_NOBITS` `SHF_ALLOC` section kind, and every
//! relocation type, this file switches on was confirmed present in a real
//! `libbitrt.a` before being added. Anything else fails loudly
//! (`error.UnsupportedRelocation`/`.UnsupportedSymbol`) rather than
//! silently mis-linking — this is a real, if narrower-than-`lld`, linker,
//! not a best-effort approximation.
//!
//! Built on `std.elf.Header`'s own section-header iterator (the same one
//! `obj/elf.zig`'s own tests use to read back its output) rather than a
//! hand-rolled byte decoder — it already normalizes 32-vs-64-bit and
//! endianness and is exercised elsewhere in this codebase.

const std = @import("std");
const elf = std.elf;
const Allocator = std.mem.Allocator;
const object = @import("object.zig");

pub const Target = enum {
    x86_64,
    aarch64,

    fn machine(self: Target) elf.EM {
        return switch (self) {
            .x86_64 => .X86_64,
            .aarch64 => .AARCH64,
        };
    }

    /// AArch64 instruction fetch faults on a misaligned PC; x86-64 has no
    /// such requirement. Floor every `.text` atom's alignment at this so a
    /// dead-stripped, repacked `.text` never places a function on a
    /// non-4-byte boundary even if the source section's own `sh_addralign`
    /// happened to be 1.
    fn minTextAlign(self: Target) u32 {
        return switch (self) {
            .x86_64 => 1,
            .aarch64 => 4,
        };
    }
};

pub const Error = error{
    OutOfMemory,
    ReadFailed,
    Truncated,
    NotElf,
    UnsupportedElf,
    Malformed,
    UnsupportedSymbol,
    UnsupportedRelocation,
    OverlappingSymbols,
    NoCoveringSymbol,
};

pub fn read(gpa: Allocator, target: Target, name: []const u8, bytes: []const u8) Error!object.Module {
    var head_reader: std.Io.Reader = .fixed(bytes);
    const header = elf.Header.read(&head_reader) catch |err| return switch (err) {
        error.InvalidElfMagic => error.NotElf,
        error.InvalidElfVersion, error.InvalidElfClass, error.InvalidElfEndian => error.UnsupportedElf,
        error.EndOfStream, error.ReadFailed => error.Truncated,
    };
    if (!header.is_64) return error.UnsupportedElf;
    if (header.type != .REL) return error.UnsupportedElf;
    if (header.machine != target.machine()) return error.UnsupportedElf;
    if (header.shnum == 0 or header.shstrndx >= header.shnum) return error.Malformed;
    if (header.shentsize != @sizeOf(elf.Elf64_Shdr)) return error.Malformed;

    const shnum = header.shnum;
    const shdrs = try gpa.alloc(elf.Elf64_Shdr, shnum);
    defer gpa.free(shdrs);
    {
        var it = header.iterateSectionHeadersBuffer(bytes);
        var i: usize = 0;
        while (try nextOrTruncated(&it)) |sh| : (i += 1) {
            if (i >= shnum) return error.Malformed;
            shdrs[i] = sh;
        }
        if (i != shnum) return error.Malformed;
    }

    const shstrtab = try sectionBytes(bytes, shdrs[header.shstrndx]);

    var symtab_index: ?usize = null;
    for (shdrs, 0..) |sh, i| {
        if (sh.sh_type == @intFromEnum(elf.SHT.SYMTAB)) {
            if (symtab_index != null) return error.UnsupportedElf; // one symtab assumed throughout
            symtab_index = i;
        }
    }
    const symtab_sh = shdrs[symtab_index orelse return error.Malformed];
    if (symtab_sh.sh_entsize != @sizeOf(elf.Elf64_Sym)) return error.Malformed;
    if (symtab_sh.sh_link >= shnum) return error.Malformed;
    const strtab = try sectionBytes(bytes, shdrs[symtab_sh.sh_link]);

    // Classify + keep every `SHF_ALLOC` section; `section_map[i]` is this
    // section's index into `raw_sections`, or `null` if dropped (debug
    // info, `.comment`, `.note.*`, the symbol/string tables themselves).
    var raw_sections: std.ArrayList(object.RawSection) = .empty;
    defer raw_sections.deinit(gpa);
    const section_map = try gpa.alloc(?u32, shnum);
    defer gpa.free(section_map);
    @memset(section_map, null);

    for (shdrs, 0..) |sh, i| {
        const kind = classify(sh) orelse continue;
        section_map[i] = @intCast(raw_sections.items.len);
        try raw_sections.append(gpa, .{
            .name = try cstr(shstrtab, sh.sh_name),
            .kind = kind,
            .data = if (kind.isBss()) &.{} else try sectionBytes(bytes, sh),
            .size = sh.sh_size,
        });
    }

    // One pass over the symbol table: builds `raw_symbols` (only real,
    // atomizable defined symbols) plus a lookup from original symtab index
    // to either a `raw_symbols` slot or the info needed to resolve a
    // relocation directly (external name, or a `STT_SECTION` symbol's own
    // mapped section).
    if (symtab_sh.sh_size % @sizeOf(elf.Elf64_Sym) != 0) return error.Malformed;
    const sym_count = symtab_sh.sh_size / @sizeOf(elf.Elf64_Sym);
    if (sym_count == 0) return error.Malformed;

    const SymInfo = union(enum) {
        undefined_: []const u8,
        section: u32, // our RawSection index
        raw: u32, // index into raw_symbols
        ignored, // STT_FILE, or defined in a dropped section — never a valid relocation target
    };
    const sym_infos = try gpa.alloc(SymInfo, sym_count);
    defer gpa.free(sym_infos);

    var raw_symbols: std.ArrayList(object.RawSymbol) = .empty;
    defer raw_symbols.deinit(gpa);

    const raw_symtab = try sectionBytes(bytes, symtab_sh);
    var i: usize = 1; // index 0 is the mandatory null symbol
    while (i < sym_count) : (i += 1) {
        const sym = readAt(elf.Elf64_Sym, raw_symtab, i * @sizeOf(elf.Elf64_Sym), header.endian);
        const sym_name = try cstr(strtab, sym.st_name);
        const stt = sym.st_type();
        const stb = sym.st_bind();

        if (sym.st_shndx == elf.SHN_UNDEF) {
            sym_infos[i] = .{ .undefined_ = sym_name };
            continue;
        }
        if (stt == @intFromEnum(elf.STT.FILE)) {
            // Compiler-emitted source-file-name symbol — always
            // `st_shndx == SHN_ABS` (no section), never a relocation
            // target; must be checked before the `SHN_ABS` rejection below.
            sym_infos[i] = .ignored;
            continue;
        }
        if (sym.st_shndx == elf.SHN_ABS or sym.st_shndx == elf.SHN_COMMON) return error.UnsupportedSymbol;
        if (stt == @intFromEnum(elf.STT.GNU_IFUNC)) return error.UnsupportedSymbol;
        if (sym.st_shndx >= shnum) return error.Malformed;

        const mapped = section_map[sym.st_shndx] orelse {
            sym_infos[i] = .ignored;
            continue;
        };

        if (stt == @intFromEnum(elf.STT.SECTION)) {
            sym_infos[i] = .{ .section = mapped };
            continue;
        }

        const text_align = target.minTextAlign();
        const section_align: u32 = @intCast(@max(shdrs[sym.st_shndx].sh_addralign, 1));
        const alignment = if (raw_sections.items[mapped].kind == .text) @max(section_align, text_align) else section_align;

        sym_infos[i] = .{ .raw = @intCast(raw_symbols.items.len) };
        try raw_symbols.append(gpa, .{
            .name = sym_name,
            .section = mapped,
            .offset = @intCast(sym.st_value),
            .size = @intCast(sym.st_size),
            .binding = if (stb == @intFromEnum(elf.STB.LOCAL)) .local else .global,
            .weak = stb == @intFromEnum(elf.STB.WEAK),
            .alignment = alignment,
        });
    }

    // Relocations: one `SHT_RELA` section per section it applies to
    // (`sh_info` names the target).
    var raw_relocs: std.ArrayList(object.RawReloc) = .empty;
    defer raw_relocs.deinit(gpa);

    for (shdrs) |sh| {
        if (sh.sh_type != @intFromEnum(elf.SHT.RELA)) continue;
        if (sh.sh_entsize != @sizeOf(elf.Elf64_Rela)) return error.Malformed;
        if (sh.sh_info >= shnum) return error.Malformed;
        const owner = section_map[sh.sh_info] orelse continue; // target section dropped: its relocs are moot
        if (sh.sh_link >= shnum or shdrs[sh.sh_link].sh_type != @intFromEnum(elf.SHT.SYMTAB)) return error.Malformed;
        if (sh.sh_size % @sizeOf(elf.Elf64_Rela) != 0) return error.Malformed;

        const raw_rela = try sectionBytes(bytes, sh);
        const count = sh.sh_size / @sizeOf(elf.Elf64_Rela);
        var r: usize = 0;
        while (r < count) : (r += 1) {
            const rela = readAt(elf.Elf64_Rela, raw_rela, r * @sizeOf(elf.Elf64_Rela), header.endian);
            const sym_index = rela.r_sym();
            const r_type = rela.r_type();
            if (sym_index == 0 or sym_index >= sym_count) return error.Malformed;

            const kind = try relocKind(target, r_type);
            const info = sym_infos[sym_index];
            switch (info) {
                .ignored => return error.Malformed,
                .undefined_ => |sym_name| try raw_relocs.append(gpa, .{
                    .section = owner,
                    .offset = @intCast(rela.r_offset),
                    .kind = kind,
                    .target = .{ .global = sym_name },
                    .addend = rela.r_addend,
                }),
                .section => |sec| try raw_relocs.append(gpa, .{
                    .section = owner,
                    .offset = @intCast(rela.r_offset),
                    .kind = kind,
                    // `r_addend` is the signed section offset `S + A` points to
                    // (can be negative near a section's start — see
                    // `object.RawTarget.section_offset`); atomize folds it in.
                    .target = .{ .section_offset = .{ .section = sec, .offset = rela.r_addend } },
                    .addend = 0,
                }),
                .raw => |raw_idx| {
                    const target_binding = raw_symbols.items[raw_idx].binding;
                    try raw_relocs.append(gpa, .{
                        .section = owner,
                        .offset = @intCast(rela.r_offset),
                        .kind = kind,
                        .target = if (target_binding == .global)
                            .{ .global = raw_symbols.items[raw_idx].name }
                        else
                            .{ .symbol = raw_idx },
                        .addend = rela.r_addend,
                    });
                },
            }
        }
    }

    return object.atomizeModule(gpa, name, raw_sections.items, raw_symbols.items, raw_relocs.items);
}

fn nextOrTruncated(it: *elf.SectionHeaderBufferIterator) error{Malformed}!?elf.Elf64_Shdr {
    return it.next() catch error.Malformed;
}

fn classify(sh: elf.Elf64_Shdr) ?object.SectionKind {
    const flags = sh.sh_flags;
    if (flags & elf.SHF_ALLOC == 0) return null;
    const is_progbits = sh.sh_type == @intFromEnum(elf.SHT.PROGBITS);
    const is_nobits = sh.sh_type == @intFromEnum(elf.SHT.NOBITS);
    if (!is_progbits and !is_nobits) return null;

    const is_tls = flags & elf.SHF_TLS != 0;
    if (is_tls) return if (is_nobits) .tls_bss else .tls_data;
    if (is_nobits) return .bss;
    if (flags & elf.SHF_EXECINSTR != 0) return .text;
    if (flags & elf.SHF_WRITE != 0) return .data;
    return .rodata;
}

fn relocKind(target: Target, r_type: u32) Error!object.RelocKind {
    return switch (target) {
        .x86_64 => switch (@as(elf.R_X86_64, @enumFromInt(r_type))) {
            .@"64" => .abs64,
            .PC32 => .pc32,
            .PLT32 => .pc32, // fully static, no interposition: no real PLT needed
            .@"32" => .abs32,
            .@"32S" => .abs32_signed,
            .TPOFF32 => .tpoff32,
            .GOTPCRELX, .REX_GOTPCRELX => .got32,
            else => error.UnsupportedRelocation,
        },
        .aarch64 => switch (@as(elf.R_AARCH64, @enumFromInt(r_type))) {
            .ABS64 => .abs64,
            .ABS32 => .abs32,
            .CALL26 => .aarch64_call26,
            .JUMP26 => .aarch64_jump26,
            .ADR_PREL_PG_HI21, .ADR_PREL_PG_HI21_NC => .aarch64_adr_prel_pg_hi21,
            .ADD_ABS_LO12_NC => .aarch64_add_abs_lo12_nc,
            .LDST8_ABS_LO12_NC => .aarch64_ldst8_abs_lo12_nc,
            .LDST16_ABS_LO12_NC => .aarch64_ldst16_abs_lo12_nc,
            .LDST32_ABS_LO12_NC => .aarch64_ldst32_abs_lo12_nc,
            .LDST64_ABS_LO12_NC => .aarch64_ldst64_abs_lo12_nc,
            .LDST128_ABS_LO12_NC => .aarch64_ldst128_abs_lo12_nc,
            .ADR_GOT_PAGE => .aarch64_adr_got_page,
            .LD64_GOT_LO12_NC => .aarch64_ld64_got_lo12_nc,
            .TLSLE_ADD_TPREL_HI12 => .tlsle_add_tprel_hi12,
            .TLSLE_ADD_TPREL_LO12_NC => .tlsle_add_tprel_lo12_nc,
            else => error.UnsupportedRelocation,
        },
    };
}

fn sectionBytes(file: []const u8, sh: elf.Elf64_Shdr) error{Truncated}![]const u8 {
    if (sh.sh_type == @intFromEnum(elf.SHT.NOBITS)) return &.{};
    if (sh.sh_offset + sh.sh_size > file.len) return error.Truncated;
    return file[sh.sh_offset..][0..sh.sh_size];
}

fn cstr(strtab: []const u8, offset: u32) error{Malformed}![]const u8 {
    if (offset >= strtab.len) return error.Malformed;
    const end = std.mem.indexOfScalarPos(u8, strtab, offset, 0) orelse return error.Malformed;
    return strtab[offset..end];
}

/// `sub` (a section's own bytes) is a slice into the file buffer and only
/// guaranteed 1-byte aligned (ar member data is 2-byte aligned at best —
/// see `archive.zig`) — reads through `std.Io.Reader.fixed` rather than a
/// pointer cast so this never depends on the slice's actual alignment.
fn readAt(comptime T: type, sub: []const u8, offset: usize, endian: std.builtin.Endian) T {
    var r: std.Io.Reader = .fixed(sub[offset..][0..@sizeOf(T)]);
    return r.takeStruct(T, endian) catch unreachable; // exactly sizeOf(T) bytes were sliced above
}

const testing = std.testing;

test "rejects a non-ELF file" {
    // At least `@sizeOf(Elf64_Ehdr)` (64) bytes: `elf.Header.read` peeks
    // that many bytes before it even looks at the magic, so a shorter
    // buffer reports `Truncated`, not `NotElf` — exercise the real "wrong
    // magic" path, not the "too short to tell" one.
    const not_elf = "not an elf file at all, but padded out long enough to fill a full Ehdr-sized peek buffer";
    try testing.expect(not_elf.len >= 64);
    try testing.expectError(error.NotElf, read(testing.allocator, .x86_64, "t", not_elf));
}

test "rejects a truncated buffer too short to contain an ELF header" {
    try testing.expectError(error.Truncated, read(testing.allocator, .x86_64, "t", "short"));
}

test "reads the real libbitrt.a x86-64 Linux member and atomizes it" {
    const archive = @import("archive.zig");
    const gpa = testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const path = "zig-out/lib/x86_64-linux/libbitrt.a";
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest, // `zig build libbitrt` not run in this environment
        else => return err,
    };
    defer gpa.free(bytes);

    const members = try archive.parse(gpa, bytes);
    defer gpa.free(members);
    // Two members since `bundle_compiler_rt`: the runtime's own translation
    // unit plus compiler-rt (memcpy/memset/memmove/__divti3). Read every one
    // and check the whole archive atomizes and carries the entry contract.
    try testing.expect(members.len >= 1);

    var total_atoms: usize = 0;
    var found_start = false;
    var found_bit_main_ref = false;
    for (members) |member| {
        const mod = try read(gpa, .x86_64, member.name, member.data);
        defer {
            for (mod.atoms) |atom| gpa.free(atom.relocs);
            gpa.free(mod.atoms);
        }
        total_atoms += mod.atoms.len;
        for (mod.atoms) |atom| {
            if (std.mem.eql(u8, atom.name, "_start")) found_start = true;
            for (atom.relocs) |r| {
                if (r.target == .global and std.mem.eql(u8, r.target.global, "bit_main")) found_bit_main_ref = true;
            }
        }
    }
    try testing.expect(total_atoms > 50);
    try testing.expect(found_start);
    try testing.expect(found_bit_main_ref);
}
