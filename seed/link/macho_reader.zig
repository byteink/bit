//! Real Mach-O64 arm64 relocatable object reader (task #345): parses the
//! `MH_OBJECT` that `zig build libbitrt` emits for `aarch64-macos` (plus the
//! compiler's own Mach-O object for the Bit program) and normalizes it into
//! `link/object.zig`'s generic `Module`/`Atom` IR via `atomizeModule` — the
//! macOS sibling of `elf_reader.zig`.
//!
//! Scope is empirical, exactly like `elf_reader.zig`: every section type and
//! relocation type this file switches on was confirmed present in a real
//! `aarch64-macos libbitrt_zcu.o` (via `otool -l`/`otool -r`) before being
//! handled; anything else fails loudly rather than mis-linking.
//!
//! Mach-O differs from ELF in three ways this reader must bridge:
//!  - No per-symbol size (`nlist_64` carries none) — `atomizeModule` infers an
//!    atom's extent from the next symbol's offset, which is why `RawSymbol.size`
//!    is left 0 here.
//!  - Relocations are REL-style: `UNSIGNED` carries its addend in the field
//!    bytes, and the AArch64 page/branch kinds carry it in a *preceding*
//!    `ARM64_RELOC_ADDEND` prefix relocation (folded here into the next reloc's
//!    addend, so the generic model sees one explicit addend per reloc).
//!  - `PAGEOFF12` is one Mach-O type for both `ADD` and every `LDR/STR` width;
//!    ELF splits them. This reader decodes the instruction word to pick the
//!    right generic `aarch64_{add,ldstN}_abs_lo12` kind (scale matters).

const std = @import("std");
const Allocator = std.mem.Allocator;
const object = @import("object.zig");

pub const Error = error{
    OutOfMemory,
    NotMachO,
    UnsupportedMachO,
    Truncated,
    Malformed,
    UnsupportedSymbol,
    UnsupportedRelocation,
    NoCoveringSymbol,
};

const MH_MAGIC_64: u32 = 0xfeedfacf;
const CPU_TYPE_ARM64: i32 = 0x0100000C;
const MH_OBJECT: u32 = 0x1;
const LC_SEGMENT_64: u32 = 0x19;
const LC_SYMTAB: u32 = 0x2;

const S_ZEROFILL: u32 = 0x1;
const S_THREAD_LOCAL_REGULAR: u32 = 0x11;
const S_THREAD_LOCAL_ZEROFILL: u32 = 0x12;
const S_THREAD_LOCAL_VARIABLES: u32 = 0x13;
const SECTION_TYPE: u32 = 0xff;

const N_STAB: u8 = 0xe0;
const N_TYPE: u8 = 0x0e;
const N_EXT: u8 = 0x01;
const N_UNDF: u8 = 0x0;
const N_SECT: u8 = 0xe;

// ARM64 relocation type ordinals (`<mach-o/arm64/reloc.h>`).
const ARM64_RELOC_UNSIGNED: u4 = 0;
const ARM64_RELOC_BRANCH26: u4 = 2;
const ARM64_RELOC_PAGE21: u4 = 3;
const ARM64_RELOC_PAGEOFF12: u4 = 4;
const ARM64_RELOC_GOT_LOAD_PAGE21: u4 = 5;
const ARM64_RELOC_GOT_LOAD_PAGEOFF12: u4 = 6;
const ARM64_RELOC_TLVP_LOAD_PAGE21: u4 = 8;
const ARM64_RELOC_TLVP_LOAD_PAGEOFF12: u4 = 9;
const ARM64_RELOC_ADDEND: u4 = 10;

const MachHeader64 = extern struct {
    magic: u32,
    cputype: i32,
    cpusubtype: i32,
    filetype: u32,
    ncmds: u32,
    sizeofcmds: u32,
    flags: u32,
    reserved: u32,
};

const SegmentCommand64 = extern struct {
    cmd: u32,
    cmdsize: u32,
    segname: [16]u8,
    vmaddr: u64,
    vmsize: u64,
    fileoff: u64,
    filesize: u64,
    maxprot: i32,
    initprot: i32,
    nsects: u32,
    flags: u32,
};

const Section64 = extern struct {
    sectname: [16]u8,
    segname: [16]u8,
    addr: u64,
    size: u64,
    offset: u32,
    @"align": u32,
    reloff: u32,
    nreloc: u32,
    flags: u32,
    reserved1: u32,
    reserved2: u32,
    reserved3: u32,
};

const SymtabCommand = extern struct {
    cmd: u32,
    cmdsize: u32,
    symoff: u32,
    nsyms: u32,
    stroff: u32,
    strsize: u32,
};

const Nlist64 = extern struct {
    n_strx: u32,
    n_type: u8,
    n_sect: u8,
    n_desc: u16,
    n_value: u64,
};

const RelocationInfo = extern struct {
    r_address: i32,
    r_info: u32,
};

/// A parsed section header plus the bookkeeping the reader needs to map file
/// section ordinals and addresses back to `RawSection` indices.
const SectionMeta = struct {
    hdr: Section64,
    raw_index: ?u32, // index into raw_sections, or null if dropped
    kind: ?object.SectionKind,
};

pub fn read(gpa: Allocator, name: []const u8, bytes: []const u8) Error!object.Module {
    const header = try readStruct(MachHeader64, bytes, 0);
    if (header.magic != MH_MAGIC_64) return error.NotMachO;
    if (header.cputype != CPU_TYPE_ARM64) return error.UnsupportedMachO;
    if (header.filetype != MH_OBJECT) return error.UnsupportedMachO;

    // ---- pass 1: sections (one 1-based ordinal each) + LC_SYMTAB -----------
    var raw_sections: std.ArrayList(object.RawSection) = .empty;
    defer raw_sections.deinit(gpa);
    // Indexed by 1-based file section ordinal; entry 0 is unused (NO_SECT).
    var sect_meta: std.ArrayList(SectionMeta) = .empty;
    defer sect_meta.deinit(gpa);
    try sect_meta.append(gpa, .{ .hdr = std.mem.zeroes(Section64), .raw_index = null, .kind = null });

    var symtab: ?SymtabCommand = null;

    var lc_off: usize = @sizeOf(MachHeader64);
    var lci: u32 = 0;
    while (lci < header.ncmds) : (lci += 1) {
        if (lc_off + 8 > bytes.len) return error.Truncated;
        const cmd = readInt(u32, bytes, lc_off);
        const cmdsize = readInt(u32, bytes, lc_off + 4);
        if (cmdsize < 8 or lc_off + cmdsize > bytes.len) return error.Malformed;

        switch (cmd) {
            LC_SEGMENT_64 => {
                const seg = try readStruct(SegmentCommand64, bytes, lc_off);
                var so = lc_off + @sizeOf(SegmentCommand64);
                var si: u32 = 0;
                while (si < seg.nsects) : (si += 1) {
                    const sh = try readStruct(Section64, bytes, so);
                    so += @sizeOf(Section64);
                    const kind = classify(&sh);
                    if (kind) |k| {
                        const data: []const u8 = if (k.isBss())
                            &.{}
                        else blk: {
                            if (sh.offset + sh.size > bytes.len) return error.Truncated;
                            break :blk bytes[sh.offset..][0..@intCast(sh.size)];
                        };
                        try sect_meta.append(gpa, .{ .hdr = sh, .raw_index = @intCast(raw_sections.items.len), .kind = k });
                        try raw_sections.append(gpa, .{
                            .name = try sliceName(&sh.sectname),
                            .kind = k,
                            .data = data,
                            .size = sh.size,
                            // Mach-O stores log2 of the required alignment.
                            .alignment = @as(u32, 1) << @intCast(sh.@"align"),
                        });
                    } else {
                        try sect_meta.append(gpa, .{ .hdr = sh, .raw_index = null, .kind = null });
                    }
                }
            },
            LC_SYMTAB => symtab = try readStruct(SymtabCommand, bytes, lc_off),
            else => {},
        }
        lc_off += cmdsize;
    }

    const st = symtab orelse return error.Malformed;
    if (st.stroff + st.strsize > bytes.len) return error.Truncated;
    const strtab = bytes[st.stroff..][0..st.strsize];

    // ---- pass 2: symbols ---------------------------------------------------
    // sym_target[i] tells a relocation what symbol i resolves to.
    const SymTarget = union(enum) {
        undefined_: []const u8, // an import / cross-module global
        raw: u32, // index into raw_symbols (a defined symbol)
        ignored, // stab/absolute/defined-in-dropped-section
    };
    const sym_targets = try gpa.alloc(SymTarget, st.nsyms);
    defer gpa.free(sym_targets);

    var raw_symbols: std.ArrayList(object.RawSymbol) = .empty;
    defer raw_symbols.deinit(gpa);

    var s: u32 = 0;
    while (s < st.nsyms) : (s += 1) {
        const nl = try readStruct(Nlist64, bytes, st.symoff + s * @sizeOf(Nlist64));
        if (nl.n_type & N_STAB != 0) { // debug symbol
            sym_targets[s] = .ignored;
            continue;
        }
        const sym_name = try cstr(strtab, nl.n_strx);
        const ntype = nl.n_type & N_TYPE;
        if (ntype == N_UNDF or nl.n_sect == 0) {
            sym_targets[s] = .{ .undefined_ = sym_name };
            continue;
        }
        if (ntype != N_SECT) return error.UnsupportedSymbol; // N_ABS/N_PBUD unsupported
        if (nl.n_sect >= sect_meta.items.len) return error.Malformed;
        const meta = sect_meta.items[nl.n_sect];
        const raw_index = meta.raw_index orelse {
            sym_targets[s] = .ignored; // defined in a dropped section (e.g. unwind)
            continue;
        };
        const align_log2: u5 = @intCast(@min(meta.hdr.@"align", 31));
        sym_targets[s] = .{ .raw = @intCast(raw_symbols.items.len) };
        try raw_symbols.append(gpa, .{
            .name = sym_name,
            .section = raw_index,
            .offset = @intCast(nl.n_value - meta.hdr.addr), // n_value is the absolute addr; section.addr is its base
            .size = 0, // Mach-O carries none; atomize infers from the next symbol
            .binding = if (nl.n_type & N_EXT != 0) .global else .local,
            .weak = false,
            .alignment = @as(u32, 1) << align_log2,
        });
    }

    // ---- pass 3: relocations (per owning section) --------------------------
    var raw_relocs: std.ArrayList(object.RawReloc) = .empty;
    defer raw_relocs.deinit(gpa);

    for (sect_meta.items) |meta| {
        const owner = meta.raw_index orelse continue;
        const sh = meta.hdr;
        if (sh.nreloc == 0) continue;
        if (sh.reloff + sh.nreloc * @sizeOf(RelocationInfo) > bytes.len) return error.Truncated;

        var pending_addend: ?i64 = null;
        var ri: u32 = 0;
        while (ri < sh.nreloc) : (ri += 1) {
            const rel = try readStruct(RelocationInfo, bytes, sh.reloff + ri * @sizeOf(RelocationInfo));
            const symbolnum: u32 = rel.r_info & 0x00FFFFFF;
            const length: u2 = @intCast((rel.r_info >> 25) & 0x3);
            const is_extern = (rel.r_info >> 27) & 1 != 0;
            const rtype: u4 = @intCast((rel.r_info >> 28) & 0xF);

            if (rtype == ARM64_RELOC_ADDEND) {
                // Prefix reloc: r_symbolnum is a signed 24-bit addend for the
                // immediately following page/branch relocation.
                pending_addend = @as(i64, @as(i32, @bitCast(symbolnum << 8)) >> 8);
                continue;
            }
            if (!is_extern) return error.UnsupportedRelocation; // only ADDEND is section-based here

            const section_data = raw_sections.items[owner].data;
            const kind = try relocKind(rtype, length, section_data, @intCast(rel.r_address));

            // Addend: UNSIGNED reads it from the field; page/branch kinds take
            // it from a preceding ARM64_RELOC_ADDEND (else 0).
            var addend: i64 = pending_addend orelse 0;
            pending_addend = null;
            if (rtype == ARM64_RELOC_UNSIGNED) {
                addend = readImplicitAddend(section_data, @intCast(rel.r_address), length);
            }

            const target: object.RawTarget = switch (sym_targets[symbolnum]) {
                .ignored => return error.Malformed,
                .undefined_ => |nm| .{ .global = nm },
                .raw => |idx| if (raw_symbols.items[idx].binding == .global)
                    .{ .global = raw_symbols.items[idx].name }
                else
                    .{ .symbol = idx },
            };

            try raw_relocs.append(gpa, .{
                .section = owner,
                .offset = @intCast(rel.r_address),
                .kind = kind,
                .target = target,
                .addend = addend,
            });
        }
    }

    return object.atomizeModule(gpa, name, raw_sections.items, raw_symbols.items, raw_relocs.items);
}

/// Classifies a section by segment + `SECTION_TYPE`. Drops unwind/debug/LD
/// helper sections (`null`) — nothing running needs them in v1 (no exceptions).
fn classify(sh: *const Section64) ?object.SectionKind {
    const seg = std.mem.sliceTo(&sh.segname, 0);
    const sect = std.mem.sliceTo(&sh.sectname, 0);
    switch (sh.flags & SECTION_TYPE) {
        S_THREAD_LOCAL_ZEROFILL => return .tls_bss,
        S_THREAD_LOCAL_VARIABLES => return .tls_vars, // tlv_descriptors
        S_THREAD_LOCAL_REGULAR => return .tls_data, // thread-local init image
        S_ZEROFILL => return .bss,
        else => {},
    }
    if (std.mem.eql(u8, seg, "__TEXT")) {
        if (std.mem.eql(u8, sect, "__unwind_info") or std.mem.eql(u8, sect, "__eh_frame") or
            std.mem.eql(u8, sect, "__gcc_except_tab") or std.mem.eql(u8, sect, "__compact_unwind")) return null;
        if (std.mem.eql(u8, sect, "__text")) return .text;
        return .rodata; // __const, __cstring, __literal4/8/16
    }
    if (std.mem.eql(u8, seg, "__DATA") or std.mem.eql(u8, seg, "__DATA_CONST")) {
        if (std.mem.eql(u8, sect, "__compact_unwind")) return null;
        // ABI.md §4: must be tested BEFORE the blanket `.data` below, which
        // would otherwise scatter the GC stack-map entries among unrelated
        // `__DATA` atoms and break the merged table's contiguity silently.
        if (std.mem.eql(u8, sect, "__bit_gc")) return .gc_meta;
        return .data;
    }
    return null; // __LD and anything else: not needed
}

/// Maps a Mach-O arm64 relocation type to the generic kind, decoding the
/// instruction word for `PAGEOFF12` (one Mach-O type spanning `ADD` and every
/// `LDR/STR` width — the scale is in the instruction, not the reloc).
fn relocKind(rtype: u4, length: u2, section_data: []const u8, r_address: usize) Error!object.RelocKind {
    return switch (rtype) {
        ARM64_RELOC_UNSIGNED => switch (length) {
            3 => .abs64,
            2 => .abs32,
            else => error.UnsupportedRelocation,
        },
        ARM64_RELOC_BRANCH26 => .aarch64_call26,
        ARM64_RELOC_PAGE21 => .aarch64_adr_prel_pg_hi21,
        ARM64_RELOC_GOT_LOAD_PAGE21 => .aarch64_adr_got_page,
        ARM64_RELOC_GOT_LOAD_PAGEOFF12 => .aarch64_ld64_got_lo12_nc,
        ARM64_RELOC_TLVP_LOAD_PAGE21 => .aarch64_tlvp_adr_page21,
        ARM64_RELOC_TLVP_LOAD_PAGEOFF12 => .aarch64_tlvp_ld64_lo12,
        ARM64_RELOC_PAGEOFF12 => blk: {
            if (r_address + 4 > section_data.len) return error.Malformed;
            const insn = std.mem.readInt(u32, section_data[r_address..][0..4], .little);
            // LDR/STR unsigned-immediate form: bits[29:27]=111, bits[25:24]=01.
            if (insn & 0x3b000000 == 0x39000000) {
                // 128-bit SIMD LDR/STR has size=00 but bit[23] set (opc high).
                const scale: u2 = if (insn & 0x04800000 == 0x04800000) 0 else @intCast(insn >> 30);
                const is_128 = insn & 0x04800000 == 0x04800000;
                break :blk if (is_128) .aarch64_ldst128_abs_lo12_nc else switch (scale) {
                    0 => .aarch64_ldst8_abs_lo12_nc,
                    1 => .aarch64_ldst16_abs_lo12_nc,
                    2 => .aarch64_ldst32_abs_lo12_nc,
                    3 => .aarch64_ldst64_abs_lo12_nc,
                };
            }
            break :blk .aarch64_add_abs_lo12_nc; // ADD immediate (address materialization)
        },
        else => error.UnsupportedRelocation,
    };
}

fn readImplicitAddend(section_data: []const u8, r_address: usize, length: u2) i64 {
    return switch (length) {
        3 => std.mem.readInt(i64, section_data[r_address..][0..8], .little),
        2 => std.mem.readInt(i32, section_data[r_address..][0..4], .little),
        else => 0,
    };
}

fn sliceName(field: *const [16]u8) Error![]const u8 {
    return std.mem.sliceTo(field, 0);
}

fn cstr(strtab: []const u8, offset: u32) Error![]const u8 {
    if (offset >= strtab.len) return error.Malformed;
    const end = std.mem.indexOfScalarPos(u8, strtab, offset, 0) orelse return error.Malformed;
    return strtab[offset..end];
}

/// Reads a fixed-layout struct at `offset` without assuming slice alignment
/// (ar members are only 2-byte aligned — see `archive.zig`).
fn readStruct(comptime T: type, bytes: []const u8, offset: usize) Error!T {
    if (offset + @sizeOf(T) > bytes.len) return error.Truncated;
    var r: std.Io.Reader = .fixed(bytes[offset..][0..@sizeOf(T)]);
    return r.takeStruct(T, .little) catch error.Truncated;
}

fn readInt(comptime T: type, bytes: []const u8, offset: usize) T {
    return std.mem.readInt(T, bytes[offset..][0..@sizeOf(T)], .little);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------
const testing = std.testing;

test "rejects a non-Mach-O buffer" {
    const not_macho = "this is definitely not a mach-o object file, padded long enough";
    try testing.expect(not_macho.len >= @sizeOf(MachHeader64));
    try testing.expectError(error.NotMachO, read(testing.allocator, "t", not_macho));
}

test "reads the real aarch64-macos libbitrt.a member and atomizes it" {
    const archive = @import("archive.zig");
    const gpa = testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const path = "zig-out/lib/aarch64-macos/libbitrt.a";
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest, // `zig build libbitrt` not run here
        else => return err,
    };
    defer gpa.free(bytes);

    const members = try archive.parse(gpa, bytes);
    defer gpa.free(members);
    try testing.expect(members.len >= 1);

    var total_atoms: usize = 0;
    var found_start = false;
    var found_bit_main_ref = false;
    for (members) |member| {
        const mod = read(gpa, member.name, member.data) catch |err| {
            std.debug.print("macho read failed on {s}: {}\n", .{ member.name, err });
            return err;
        };
        defer {
            for (mod.atoms) |atom| gpa.free(atom.relocs);
            gpa.free(mod.atoms);
        }
        total_atoms += mod.atoms.len;
        for (mod.atoms) |atom| {
            if (std.mem.eql(u8, atom.name, "__start")) found_start = true;
            for (atom.relocs) |r| {
                if (r.target == .global and std.mem.eql(u8, r.target.global, "_bit_main")) found_bit_main_ref = true;
            }
        }
    }
    try testing.expect(total_atoms > 50);
    try testing.expect(found_start);
    try testing.expect(found_bit_main_ref);
}
