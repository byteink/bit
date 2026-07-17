//! ELF64 relocatable object writer (task #342) — the compiler's first
//! concrete object-file backend. Consumed by the coming static linker
//! (task #345, `compiler/link.zig`), which turns `.o`s plus `libbitrt.a`
//! into a standalone executable.
//!
//! Deliberately decoupled from `codegen/x64.zig` and `codegen/arm64.zig`:
//! this file knows nothing of `ir.zig`, physical registers, or instruction
//! encoding — only the generic shape every object file needs (named
//! sections, a symbol table, relocations against those symbols). Building
//! the small adapter from a backend's `FuncCode` list to `Object` is
//! `link.zig`'s job; putting that seam here would make every future
//! object writer (`macho.zig` #343, `pe.zig` #344) depend on codegen
//! internals for no reason.
//!
//! Reuses `std.elf`'s `Elf64` structs and constants verbatim instead of
//! hand-rolling byte layouts. This project's only two targets (x86-64,
//! ARM64) are little-endian, matching `std.elf.Header`'s own "all integers
//! are native endian" assumption — writing the extern structs directly
//! with the host's native encoding is both correct and the least code that
//! works.
//!
//! One `Object` == one compiled Bit module: at most one section per kind
//! (`.text`/`.data`/`.rodata`/`.bss`, plus `.bit_gc` holding the
//! `runtime/ABI.md` §2 `TypeInfo` tables the runtime's GC reads at
//! startup). Multiple Bit modules become multiple `.o` files; the linker
//! merges them.

const std = @import("std");
const elf = std.elf;
const Allocator = std.mem.Allocator;

pub const Target = enum {
    x86_64,
    aarch64,

    fn machine(self: Target) elf.EM {
        return switch (self) {
            .x86_64 => .X86_64,
            .aarch64 => .AARCH64,
        };
    }
};

pub const SectionKind = enum {
    text,
    data,
    rodata,
    bss,
    gc_meta,

    fn sectionName(self: SectionKind) []const u8 {
        return switch (self) {
            .text => ".text",
            .data => ".data",
            .rodata => ".rodata",
            .bss => ".bss",
            .gc_meta => ".bit_gc",
        };
    }

    fn shType(self: SectionKind) elf.SHT {
        return if (self == .bss) .NOBITS else .PROGBITS;
    }

    fn shFlags(self: SectionKind) elf.SHF {
        return switch (self) {
            .text => .{ .ALLOC = true, .EXECINSTR = true },
            .data, .bss => .{ .ALLOC = true, .WRITE = true },
            .rodata, .gc_meta => .{ .ALLOC = true },
        };
    }
};

const num_kinds = @typeInfo(SectionKind).@"enum".fields.len;

/// Fixed emission order for real sections and their string-table entries —
/// spelled out explicitly rather than derived from enum declaration order,
/// so reordering `SectionKind`'s declaration can never silently reorder the
/// file layout.
const canonical_order = [_]SectionKind{ .text, .data, .rodata, .bss, .gc_meta };

/// One section's content. `.bss` is the only kind with no file bytes: give
/// it `size` and leave `data` empty (its contents are implicitly zero).
/// Every other kind derives its size from `data.len`.
pub const Section = struct {
    kind: SectionKind,
    data: []const u8 = &.{},
    size: u64 = 0,
    /// 0 or a power of two, per the ELF `sh_addralign` contract; 0 means
    /// "no constraint" and is normalized to 1.
    alignment: u32 = 1,

    fn byteSize(self: Section) u64 {
        return if (self.kind == .bss) self.size else self.data.len;
    }
};

pub const Binding = enum { local, global };
pub const SymKind = enum { notype, object, func };

/// `section == null` names an external symbol (a runtime `bit_rt_*` export,
/// or another Bit module's function) that the linker must resolve — it
/// carries no offset/size and must be `.global`: nothing else can ever
/// define an undefined local.
pub const Symbol = struct {
    name: []const u8,
    section: ?SectionKind,
    offset: u64 = 0,
    size: u64 = 0,
    binding: Binding,
    kind: SymKind = .notype,
};

/// Mirrors `codegen/common.zig`'s `Reloc` (offset + symbol) plus the
/// architecture-specific "how the field's bytes are interpreted" that only
/// the object writer needs to know.
pub const RelocKind = enum {
    /// x86-64 `R_X86_64_PC32`: a 4-byte field holding `S + A - P` (a `call
    /// rel32`'s immediate; codegen supplies `addend = -4` so `P` can name
    /// the immediate's own start, not the end of the instruction).
    pc32,
    /// `R_X86_64_64` / `R_AARCH64_ABS64`: an 8-byte absolute pointer (e.g.
    /// a `TypeInfo.name_ptr` in `.bit_gc` pointing into `.rodata`).
    abs64,
    /// ARM64 `R_AARCH64_CALL26`: a `bl`'s 26-bit PC-relative immediate.
    aarch64_call26,
    /// ARM64 `R_AARCH64_ADR_PREL_PG_HI21`: an `ADRP`'s ±4 GiB page immediate
    /// (page(S+A) - page(P)) — the high half of a two-instruction address load.
    aarch64_adr_prel_pg_hi21,
    /// ARM64 `R_AARCH64_ADD_ABS_LO12_NC`: an `ADD` immediate's low 12 bits
    /// ((S+A) & 0xfff) — the low half paired with the `ADRP` above.
    aarch64_add_abs_lo12_nc,

    fn width(self: RelocKind) u64 {
        return switch (self) {
            .pc32, .aarch64_call26, .aarch64_adr_prel_pg_hi21, .aarch64_add_abs_lo12_nc => 4,
            .abs64 => 8,
        };
    }

    fn elfType(self: RelocKind, target: Target) ?u32 {
        return switch (self) {
            .pc32 => if (target == .x86_64) @intFromEnum(elf.R_X86_64.PC32) else null,
            .abs64 => switch (target) {
                .x86_64 => @intFromEnum(elf.R_X86_64.@"64"),
                .aarch64 => @intFromEnum(elf.R_AARCH64.ABS64),
            },
            .aarch64_call26 => if (target == .aarch64) @intFromEnum(elf.R_AARCH64.CALL26) else null,
            .aarch64_adr_prel_pg_hi21 => if (target == .aarch64) @intFromEnum(elf.R_AARCH64.ADR_PREL_PG_HI21) else null,
            .aarch64_add_abs_lo12_nc => if (target == .aarch64) @intFromEnum(elf.R_AARCH64.ADD_ABS_LO12_NC) else null,
        };
    }
};

pub const Relocation = struct {
    section: SectionKind,
    offset: u64,
    symbol: []const u8,
    kind: RelocKind,
    addend: i64 = 0,
};

pub const Object = struct {
    sections: []const Section,
    symbols: []const Symbol = &.{},
    relocations: []const Relocation = &.{},
};

pub const Error = error{
    /// Two `Section`s in `Object.sections` name the same `SectionKind`.
    DuplicateSection,
    /// A `Section.alignment` is neither 0 nor a power of two.
    InvalidSectionAlignment,
    /// A `Symbol`/`Relocation` names a `SectionKind` absent from `Object.sections`.
    SectionNotPresent,
    /// A defined `Symbol`'s `offset + size` overruns its section.
    SymbolOutOfBounds,
    /// Two `Symbol`s in `Object.symbols` share a name.
    DuplicateSymbol,
    /// An external (`section == null`) `Symbol` is `.local` — nothing can
    /// ever define it, so a local binding is meaningless.
    UndefinedLocalSymbol,
    /// A `Relocation.symbol` names no `Symbol` in `Object.symbols`.
    UnknownSymbol,
    /// A `Relocation.kind` has no encoding on the requested `Target`.
    RelocKindUnsupportedForTarget,
    /// A `Relocation.offset + kind.width()` overruns its section.
    RelocOutOfBounds,
} || Allocator.Error;

/// Appends a NUL-terminated string to a string table buffer, returning its
/// byte offset. `buf` must already carry the ELF-mandated leading NUL (so
/// offset 0 is the empty string).
fn internString(buf: *std.ArrayList(u8), gpa: Allocator, s: []const u8) Allocator.Error!u32 {
    const off: u32 = @intCast(buf.items.len);
    try buf.appendSlice(gpa, s);
    try buf.append(gpa, 0);
    return off;
}

fn alignUp(buf: *std.ArrayList(u8), gpa: Allocator, alignment: u64) Allocator.Error!void {
    const rem = buf.items.len % alignment;
    if (rem == 0) return;
    const pad = try buf.addManyAsSlice(gpa, alignment - rem);
    @memset(pad, 0);
}

fn appendStruct(buf: *std.ArrayList(u8), gpa: Allocator, value: anytype) Allocator.Error!void {
    try buf.appendSlice(gpa, std.mem.asBytes(&value));
}

/// Emits a complete ELF64 `ET_REL` object for `object`, targeting the given
/// architecture. Returned slice is owned by the caller (`gpa.free`).
pub fn write(gpa: Allocator, target: Target, object: Object) Error![]u8 {
    var by_kind: [num_kinds]?Section = .{null} ** num_kinds;
    for (object.sections) |s| {
        const idx = @intFromEnum(s.kind);
        if (by_kind[idx] != null) return error.DuplicateSection;
        if (s.alignment != 0 and !std.math.isPowerOfTwo(s.alignment)) return error.InvalidSectionAlignment;
        by_kind[idx] = s;
    }

    // Symbol table order: all STB_LOCAL entries before any STB_GLOBAL, each
    // group preserving `object.symbols`'s own order (ELF's symtab contract:
    // `sh_info` names the boundary as one index). `order[i]` is the
    // original `object.symbols` index landing at final symtab slot `i+1`
    // (slot 0 is the mandatory null symbol).
    const order = try gpa.alloc(usize, object.symbols.len);
    defer gpa.free(order);
    var n_local: usize = 0;
    for (object.symbols, 0..) |sym, i| {
        if (sym.section == null and sym.binding == .local) return error.UndefinedLocalSymbol;
        if (sym.section) |k| {
            const sec = by_kind[@intFromEnum(k)] orelse return error.SectionNotPresent;
            if (sym.offset + sym.size > sec.byteSize()) return error.SymbolOutOfBounds;
        }
        if (sym.binding == .local) {
            order[n_local] = i;
            n_local += 1;
        }
    }
    var next_global = n_local;
    for (object.symbols, 0..) |sym, i| {
        if (sym.binding != .local) {
            order[next_global] = i;
            next_global += 1;
        }
    }

    var name_to_symidx = std.StringHashMap(u32).init(gpa);
    defer name_to_symidx.deinit();
    try name_to_symidx.ensureTotalCapacity(@intCast(object.symbols.len));
    for (order, 0..) |orig, i| {
        const gop = name_to_symidx.getOrPutAssumeCapacity(object.symbols[orig].name);
        if (gop.found_existing) return error.DuplicateSymbol;
        gop.value_ptr.* = @intCast(i + 1); // +1: slot 0 is the null symbol
    }

    // Relocations are validated up front and bucketed by target section so
    // each `.rela.<name>` can be emitted as one contiguous run, in the
    // caller's original relative order.
    var relocs_by_kind: [num_kinds]std.ArrayList(Relocation) = undefined;
    for (&relocs_by_kind) |*l| l.* = .empty;
    defer for (&relocs_by_kind) |*l| l.deinit(gpa);
    for (object.relocations) |r| {
        const sec = by_kind[@intFromEnum(r.section)] orelse return error.SectionNotPresent;
        if (r.offset + r.kind.width() > sec.byteSize()) return error.RelocOutOfBounds;
        if (r.kind.elfType(target) == null) return error.RelocKindUnsupportedForTarget;
        if (!name_to_symidx.contains(r.symbol)) return error.UnknownSymbol;
        try relocs_by_kind[@intFromEnum(r.section)].append(gpa, r);
    }

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    var shdrs: std.ArrayList(elf.Elf64.Shdr) = .empty;
    defer shdrs.deinit(gpa);
    var shstrtab: std.ArrayList(u8) = .empty;
    defer shstrtab.deinit(gpa);
    try shstrtab.append(gpa, 0); // offset 0 == empty string

    {
        const hdr_space = try out.addManyAsSlice(gpa, @sizeOf(elf.Elf64.Ehdr));
        @memset(hdr_space, 0);
    }
    try shdrs.append(gpa, std.mem.zeroes(elf.Elf64.Shdr)); // index 0: mandatory null section

    var sh_index_of: [num_kinds]?u16 = .{null} ** num_kinds;
    for (canonical_order) |kind| {
        const sec = by_kind[@intFromEnum(kind)] orelse continue;
        const name_off = try internString(&shstrtab, gpa, kind.sectionName());
        const alignment: u64 = if (sec.alignment == 0) 1 else sec.alignment;
        try alignUp(&out, gpa, alignment);
        const file_off = out.items.len;
        if (kind != .bss) try out.appendSlice(gpa, sec.data);
        sh_index_of[@intFromEnum(kind)] = @intCast(shdrs.items.len);
        try shdrs.append(gpa, .{
            .name = name_off,
            .type = kind.shType(),
            .flags = .{ .shf = kind.shFlags() },
            .addr = 0,
            .offset = file_off,
            .size = sec.byteSize(),
            .link = 0,
            .info = 0,
            .addralign = alignment,
            .entsize = 0,
        });
    }

    // `.rela.<name>` sections: `link` (symtab's section index) isn't known
    // until the symtab is emitted below, so it's patched in afterwards —
    // `rela_positions` remembers where in `shdrs` to patch.
    var rela_positions: std.ArrayList(usize) = .empty;
    defer rela_positions.deinit(gpa);
    for (canonical_order) |kind| {
        const relocs = relocs_by_kind[@intFromEnum(kind)].items;
        if (relocs.len == 0) continue;
        var rela_name_buf: [".rela".len + ".bit_gc".len]u8 = undefined;
        const rela_name = std.fmt.bufPrint(&rela_name_buf, ".rela{s}", .{kind.sectionName()}) catch unreachable;
        const name_off = try internString(&shstrtab, gpa, rela_name);
        try alignUp(&out, gpa, 8);
        const file_off = out.items.len;
        for (relocs) |r| {
            try appendStruct(&out, gpa, elf.Elf64.Rela{
                .offset = r.offset,
                .info = .{ .type = r.kind.elfType(target).?, .sym = name_to_symidx.get(r.symbol).? },
                .addend = r.addend,
            });
        }
        try rela_positions.append(gpa, shdrs.items.len);
        try shdrs.append(gpa, .{
            .name = name_off,
            .type = .RELA,
            .flags = .{ .shf = .{ .INFO_LINK = true } },
            .addr = 0,
            .offset = file_off,
            .size = relocs.len * @sizeOf(elf.Elf64.Rela),
            .link = 0, // patched below once the symtab section index is known
            .info = sh_index_of[@intFromEnum(kind)].?,
            .addralign = 8,
            .entsize = @sizeOf(elf.Elf64.Rela),
        });
    }

    // `.strtab` (symbol names) before `.symtab`: `.symtab.link` needs
    // `.strtab`'s section index, which only exists once `.strtab` itself
    // has been emitted.
    var strtab: std.ArrayList(u8) = .empty;
    defer strtab.deinit(gpa);
    try strtab.append(gpa, 0);
    const sym_name_offs = try gpa.alloc(u32, object.symbols.len);
    defer gpa.free(sym_name_offs);
    for (order, 0..) |orig, i| sym_name_offs[i] = try internString(&strtab, gpa, object.symbols[orig].name);

    const strtab_name_off = try internString(&shstrtab, gpa, ".strtab");
    try alignUp(&out, gpa, 1);
    const strtab_file_off = out.items.len;
    try out.appendSlice(gpa, strtab.items);
    const strtab_index: u32 = @intCast(shdrs.items.len);
    try shdrs.append(gpa, .{
        .name = strtab_name_off,
        .type = .STRTAB,
        .flags = .{ .shf = .{} },
        .addr = 0,
        .offset = strtab_file_off,
        .size = strtab.items.len,
        .link = 0,
        .info = 0,
        .addralign = 1,
        .entsize = 0,
    });

    const symtab_name_off = try internString(&shstrtab, gpa, ".symtab");
    try alignUp(&out, gpa, 8);
    const symtab_file_off = out.items.len;
    try appendStruct(&out, gpa, std.mem.zeroes(elf.Elf64.Sym)); // index 0: mandatory null symbol
    for (order, 0..) |orig, i| {
        const sym = object.symbols[orig];
        const shndx: u16 = if (sym.section) |k| sh_index_of[@intFromEnum(k)].? else 0; // SHN_UNDEF
        try appendStruct(&out, gpa, elf.Elf64.Sym{
            .name = sym_name_offs[i],
            .info = .{
                .type = switch (sym.kind) {
                    .notype => .NOTYPE,
                    .object => .OBJECT,
                    .func => .FUNC,
                },
                .bind = if (sym.binding == .local) .LOCAL else .GLOBAL,
            },
            .other = .{ .visibility = .DEFAULT },
            .shndx = shndx,
            .value = sym.offset,
            .size = sym.size,
        });
    }
    try shdrs.append(gpa, .{
        .name = symtab_name_off,
        .type = .SYMTAB,
        .flags = .{ .shf = .{} },
        .addr = 0,
        .offset = symtab_file_off,
        .size = (object.symbols.len + 1) * @sizeOf(elf.Elf64.Sym),
        .link = strtab_index,
        .info = @intCast(n_local + 1), // one greater than the last local symbol's index
        .addralign = 8,
        .entsize = @sizeOf(elf.Elf64.Sym),
    });
    const symtab_index: u32 = strtab_index + 1;
    for (rela_positions.items) |pos| shdrs.items[pos].link = symtab_index;

    const shstrtab_name_off = try internString(&shstrtab, gpa, ".shstrtab");
    try alignUp(&out, gpa, 1);
    const shstrtab_file_off = out.items.len;
    try out.appendSlice(gpa, shstrtab.items);
    const shstrtab_index: u16 = @intCast(shdrs.items.len);
    try shdrs.append(gpa, .{
        .name = shstrtab_name_off,
        .type = .STRTAB,
        .flags = .{ .shf = .{} },
        .addr = 0,
        .offset = shstrtab_file_off,
        .size = shstrtab.items.len,
        .link = 0,
        .info = 0,
        .addralign = 1,
        .entsize = 0,
    });

    try alignUp(&out, gpa, 8);
    const shoff = out.items.len;
    for (shdrs.items) |shdr| try appendStruct(&out, gpa, shdr);

    var ident = std.mem.zeroes([elf.EI.NIDENT]u8);
    @memcpy(ident[0..4], elf.MAGIC);
    ident[elf.EI.CLASS] = elf.ELFCLASS64;
    ident[elf.EI.DATA] = elf.ELFDATA2LSB;
    ident[elf.EI.VERSION] = 1;
    ident[elf.EI.OSABI] = @intFromEnum(elf.OSABI.NONE);
    const ehdr = elf.Elf64.Ehdr{
        .ident = ident,
        .type = .REL,
        .machine = target.machine(),
        .version = 1,
        .entry = 0,
        .phoff = 0,
        .shoff = shoff,
        .flags = 0,
        .ehsize = @sizeOf(elf.Elf64.Ehdr),
        .phentsize = 0,
        .phnum = 0,
        .shentsize = @sizeOf(elf.Elf64.Shdr),
        .shnum = @intCast(shdrs.items.len),
        .shstrndx = shstrtab_index,
    };
    @memcpy(out.items[0..@sizeOf(elf.Elf64.Ehdr)], std.mem.asBytes(&ehdr));

    return out.toOwnedSlice(gpa);
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

/// Round-trips `bytes` through `std.elf`'s own reader rather than a
/// hand-rolled decoder in the test, so a test failure means the *stdlib's*
/// ELF parser rejects our output — the same class of check `readelf`
/// performs at the `Verify` step.
const Parsed = struct {
    header: elf.Header,
    bytes: []const u8,

    fn sectionName(self: Parsed, shdr: elf.Elf64_Shdr) []const u8 {
        var it = self.header.iterateSectionHeadersBuffer(self.bytes);
        const shstrtab_shdr = blk: {
            var i: usize = 0;
            while (it.next() catch unreachable) |s| : (i += 1) {
                if (i == self.header.shstrndx) break :blk s;
            }
            unreachable;
        };
        const strtab = self.bytes[shstrtab_shdr.sh_offset..][0..shstrtab_shdr.sh_size];
        return std.mem.sliceTo(strtab[shdr.sh_name..], 0);
    }

    fn findSection(self: Parsed, name: []const u8) ?elf.Elf64_Shdr {
        var it = self.header.iterateSectionHeadersBuffer(self.bytes);
        while (it.next() catch unreachable) |s| {
            if (std.mem.eql(u8, self.sectionName(s), name)) return s;
        }
        return null;
    }
};

fn parse(bytes: []const u8) !Parsed {
    var reader = std.Io.Reader.fixed(bytes);
    return .{ .header = try elf.Header.read(&reader), .bytes = bytes };
}

test "write: minimal x86-64 object with one exported function" {
    const gpa = testing.allocator;
    const code = [_]u8{ 0x55, 0x48, 0x89, 0xe5, 0x5d, 0xc3 }; // push rbp; mov rbp,rsp; pop rbp; ret
    const bytes = try write(gpa, .x86_64, .{
        .sections = &.{.{ .kind = .text, .data = &code, .alignment = 16 }},
        .symbols = &.{.{ .name = "main", .section = .text, .offset = 0, .size = code.len, .binding = .global, .kind = .func }},
    });
    defer gpa.free(bytes);

    const p = try parse(bytes);
    try testing.expectEqual(elf.ET.REL, p.header.type);
    try testing.expectEqual(elf.EM.X86_64, p.header.machine);
    try testing.expect(p.header.is_64);
    try testing.expectEqual(std.builtin.Endian.little, p.header.endian);

    const text = p.findSection(".text") orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(u64, code.len), text.sh_size);
    try testing.expectEqualSlices(u8, &code, bytes[text.sh_offset..][0..text.sh_size]);
    try testing.expect(p.findSection(".symtab") != null);
    try testing.expect(p.findSection(".strtab") != null);
    try testing.expect(p.findSection(".shstrtab") != null);
}

test "write: aarch64 object with data, bss, gc metadata, and both reloc kinds" {
    const gpa = testing.allocator;
    const code = [_]u8{ 0xc0, 0x03, 0x5f, 0xd6 }; // ret
    const rodata = "hello\x00";
    const gc_meta = [_]u8{0} ** 16; // placeholder TypeInfo bytes, patched by relocs at link time

    const bytes = try write(gpa, .aarch64, .{
        .sections = &.{
            .{ .kind = .text, .data = &code, .alignment = 4 },
            .{ .kind = .rodata, .data = rodata, .alignment = 1 },
            .{ .kind = .bss, .size = 64, .alignment = 8 },
            .{ .kind = .gc_meta, .data = &gc_meta, .alignment = 8 },
        },
        .symbols = &.{
            .{ .name = "add", .section = .text, .offset = 0, .size = code.len, .binding = .global, .kind = .func },
            .{ .name = "msg", .section = .rodata, .offset = 0, .size = rodata.len, .binding = .local, .kind = .object },
            .{ .name = "bit_rt_gc_alloc", .section = null, .binding = .global, .kind = .func },
        },
        .relocations = &.{
            .{ .section = .text, .offset = 0, .symbol = "bit_rt_gc_alloc", .kind = .aarch64_call26 },
            .{ .section = .gc_meta, .offset = 8, .symbol = "msg", .kind = .abs64 },
        },
    });
    defer gpa.free(bytes);

    const p = try parse(bytes);
    try testing.expectEqual(elf.ET.REL, p.header.type);
    try testing.expectEqual(elf.EM.AARCH64, p.header.machine);

    const bss = p.findSection(".bss") orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(u64, 64), bss.sh_size);
    try testing.expectEqual(@as(u64, @intFromEnum(elf.SHT.NOBITS)), @as(u64, bss.sh_type));

    const gc = p.findSection(".bit_gc") orelse return error.TestUnexpectedResult;
    try testing.expectEqualSlices(u8, &gc_meta, bytes[gc.sh_offset..][0..gc.sh_size]);

    try testing.expect(p.findSection(".rela.text") != null);
    try testing.expect(p.findSection(".rela.bit_gc") != null);
    try testing.expect(p.findSection(".rela.rodata") == null); // no reloc targets .rodata
}

test "write: rejects a relocation kind unsupported on the target" {
    const gpa = testing.allocator;
    const code = [_]u8{0} ** 4;
    try testing.expectError(error.RelocKindUnsupportedForTarget, write(gpa, .aarch64, .{
        .sections = &.{.{ .kind = .text, .data = &code, .alignment = 4 }},
        .symbols = &.{.{ .name = "fn", .section = null, .binding = .global }},
        .relocations = &.{.{ .section = .text, .offset = 0, .symbol = "fn", .kind = .pc32 }}, // x86-64-only kind
    }));
}

test "write: rejects an undefined local symbol" {
    const gpa = testing.allocator;
    try testing.expectError(error.UndefinedLocalSymbol, write(gpa, .x86_64, .{
        .sections = &.{},
        .symbols = &.{.{ .name = "hidden", .section = null, .binding = .local }},
    }));
}

test "write: rejects a duplicate section kind" {
    const gpa = testing.allocator;
    const a = [_]u8{0};
    const b = [_]u8{0};
    try testing.expectError(error.DuplicateSection, write(gpa, .x86_64, .{
        .sections = &.{ .{ .kind = .text, .data = &a }, .{ .kind = .text, .data = &b } },
    }));
}

test "write: rejects a relocation referencing an unknown symbol" {
    const gpa = testing.allocator;
    const code = [_]u8{0} ** 4;
    try testing.expectError(error.UnknownSymbol, write(gpa, .x86_64, .{
        .sections = &.{.{ .kind = .text, .data = &code }},
        .relocations = &.{.{ .section = .text, .offset = 0, .symbol = "nope", .kind = .pc32 }},
    }));
}

test "write: symtab orders locals before globals regardless of input order" {
    const gpa = testing.allocator;
    const code = [_]u8{0} ** 8;
    const bytes = try write(gpa, .x86_64, .{
        .sections = &.{.{ .kind = .text, .data = &code }},
        .symbols = &.{
            .{ .name = "pub_fn", .section = .text, .offset = 0, .size = 4, .binding = .global, .kind = .func },
            .{ .name = "priv_fn", .section = .text, .offset = 4, .size = 4, .binding = .local, .kind = .func },
        },
    });
    defer gpa.free(bytes);

    const p = try parse(bytes);
    const symtab = p.findSection(".symtab").?;
    const syms = std.mem.bytesAsSlice(elf.Elf64_Sym, bytes[symtab.sh_offset..][0..symtab.sh_size]);
    try testing.expectEqual(@as(usize, 3), syms.len); // null + 2
    try testing.expectEqual(@as(u4, @intFromEnum(elf.STB.LOCAL)), syms[1].st_info >> 4);
    try testing.expectEqual(@as(u4, @intFromEnum(elf.STB.GLOBAL)), syms[2].st_info >> 4);
    try testing.expectEqual(@as(u32, 2), symtab.sh_info); // one past the last local (index 1)
}
