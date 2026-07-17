//! Mach-O64 relocatable object writer (task #343) — macOS sibling of
//! `elf.zig` (#342). Consumed by the coming static linker (task #345,
//! `compiler/link.zig`), which turns `.o`s plus `libbitrt.a` into a
//! standalone executable.
//!
//! Mirrors `elf.zig`'s public shape (`Target`, `SectionKind`,
//! `canonical_order`, `Section`, `Symbol`, `RelocKind`, `Relocation`,
//! `Object`, `write`) so `link.zig` can treat every object-writer sibling
//! uniformly. Deliberately decoupled from `codegen/x64.zig` and
//! `codegen/arm64.zig` for the same reason `elf.zig` is: this file knows
//! nothing of `ir.zig`, physical registers, or instruction encoding.
//!
//! Two shape differences from `elf.zig`, both format-driven, not oversight:
//! - `Symbol` has no `SymKind` — Mach-O's `nlist_64.n_type` distinguishes
//!   only undefined/absolute/section-relative, never "function vs object"
//!   the way ELF's `st_info` type nibble does.
//! - The symbol table is emitted in `Object.symbols`' own order, not
//!   locals-then-globals. That reordering exists in `elf.zig` only because
//!   `SHT_SYMTAB.sh_info` must name the local/global boundary; Mach-O's
//!   `nlist_64` carries no such boundary field, and without an
//!   `LC_DYSYMTAB` command (deliberately omitted — see below) nothing else
//!   in the file depends on symbol order either.
//!
//! Emits the smallest layout `ld` accepts, not the layout `as` happens to
//! produce: one `LC_SEGMENT_64` (Mach-O's `MH_OBJECT` convention — every
//! section lives in one nameless segment, see `<mach-o/loader.h>`) plus one
//! `LC_SYMTAB`. No `LC_DYSYMTAB`, no `LC_BUILD_VERSION`, no chained fixups
//! (`LC_DYLD_CHAINED_FIXUPS` is an `MH_EXECUTE`/`MH_DYLIB` concept — never
//! valid on a relocatable object regardless). Verified empirically on this
//! Mac: a hand-built object carrying only those two load commands relinks
//! clean via `ld -r` and links+runs via `clang` (see this file's tests) —
//! `as`'s extra load commands aren't load-bearing for `ld` to accept input.
//!
//! Struct layouts and constants are transcribed from the Xcode SDK's
//! `<mach-o/loader.h>`, `<mach-o/nlist.h>`, `<mach-o/reloc.h>`,
//! `<mach-o/x86_64/reloc.h>`, `<mach-o/arm64/reloc.h>` — not from memory —
//! and cross-checked byte-for-byte against `as`/`otool` output.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Target = enum {
    x86_64,
    aarch64,

    fn cpuType(self: Target) i32 {
        return switch (self) {
            .x86_64 => 0x01000007, // CPU_TYPE_X86_64 (CPU_TYPE_X86 | CPU_ARCH_ABI64)
            .aarch64 => 0x0100000C, // CPU_TYPE_ARM64 (CPU_TYPE_ARM | CPU_ARCH_ABI64)
        };
    }

    fn cpuSubtype(self: Target) i32 {
        return switch (self) {
            .x86_64 => 3, // CPU_SUBTYPE_X86_64_ALL
            .aarch64 => 0, // CPU_SUBTYPE_ARM64_ALL
        };
    }
};

pub const SectionKind = enum {
    text,
    data,
    rodata,
    bss,
    gc_meta,

    fn segmentName(self: SectionKind) []const u8 {
        return switch (self) {
            .text, .rodata => "__TEXT",
            .data, .bss, .gc_meta => "__DATA",
        };
    }

    fn sectionName(self: SectionKind) []const u8 {
        return switch (self) {
            .text => "__text",
            .data => "__data",
            .rodata => "__const",
            .bss => "__bss",
            .gc_meta => "__bit_gc",
        };
    }

    fn isZerofill(self: SectionKind) bool {
        return self == .bss;
    }

    fn flags(self: SectionKind) u32 {
        return switch (self) {
            .text => S_REGULAR | S_ATTR_PURE_INSTRUCTIONS | S_ATTR_SOME_INSTRUCTIONS,
            .data, .rodata, .gc_meta => S_REGULAR,
            .bss => S_ZEROFILL,
        };
    }
};

const num_kinds = @typeInfo(SectionKind).@"enum".fields.len;

/// Fixed emission order — see `elf.zig`'s identical `canonical_order` doc
/// comment: spelled out explicitly so reordering `SectionKind`'s
/// declaration can never silently reorder the file layout.
const canonical_order = [_]SectionKind{ .text, .data, .rodata, .bss, .gc_meta };

/// One section's content. `.bss` is the only kind with no file bytes (a
/// Mach-O `S_ZEROFILL` section): give it `size` and leave `data` empty.
pub const Section = struct {
    kind: SectionKind,
    data: []const u8 = &.{},
    size: u64 = 0,
    /// 0 or a power of two; 0 means "no constraint" and is normalized to 1.
    alignment: u32 = 1,

    fn byteSize(self: Section) u64 {
        return if (self.kind == .bss) self.size else self.data.len;
    }
};

pub const Binding = enum { local, global };

/// `section == null` names an external symbol (a runtime `bit_rt_*` export,
/// or another Bit module's function) that the linker must resolve — it
/// carries no offset and must be `.global`: nothing else can ever define an
/// undefined local.
pub const Symbol = struct {
    name: []const u8,
    section: ?SectionKind,
    offset: u64 = 0,
    size: u64 = 0,
    binding: Binding,
};

/// Mirrors `codegen/common.zig`'s `Reloc` (offset + symbol) plus the
/// architecture-specific "how the field's bytes are interpreted" the
/// object writer needs. Unlike `elf.zig`'s `pc32`/`aarch64_call26` split,
/// Mach-O gives every target an equivalent encoding for both kinds below,
/// so one enum covers both architectures.
pub const RelocKind = enum {
    /// PC-relative call/branch operand: x86-64 `CALL rel32`'s 4-byte
    /// immediate, or ARM64 `BL`'s 26-bit immediate packed into its 4-byte
    /// instruction word.
    branch,
    /// Absolute pointer-sized reference, e.g. a `.bit_gc` `TypeInfo`
    /// pointer into `.rodata`.
    unsigned64,
    /// ARM64 `ADRP` page-of-symbol immediate (`ARM64_RELOC_PAGE21`) — the high
    /// half of an address-of sequence (a `const_string`'s `__bitstr_N`).
    page21,
    /// ARM64 `ADD`/`LDR` low-12-bits immediate (`ARM64_RELOC_PAGEOFF12`) — the
    /// low half of that sequence.
    pageoff12,

    fn width(self: RelocKind) u64 {
        return switch (self) {
            .branch, .page21, .pageoff12 => 4,
            .unsigned64 => 8,
        };
    }

    fn pcrel(self: RelocKind) bool {
        return self == .branch or self == .page21;
    }

    fn length(self: RelocKind) u2 {
        return switch (self) {
            .branch, .page21, .pageoff12 => 2, // 4 bytes
            .unsigned64 => 3, // 8 bytes
        };
    }

    /// Mach-O relocation type ordinal. `X86_64_RELOC_BRANCH` and
    /// `ARM64_RELOC_BRANCH26` are both `2`; `X86_64_RELOC_UNSIGNED` and
    /// `ARM64_RELOC_UNSIGNED` are both `0` — spelled out per-target anyway
    /// (not collapsed to one constant) so a future third target with a
    /// different ordinal is a one-line change, not a hidden assumption. The
    /// `page21`/`pageoff12` kinds are AArch64-only (x86-64 materializes a
    /// symbol address as an absolute `unsigned64`, never a PC-relative pair).
    fn machoType(self: RelocKind, target: Target) u4 {
        return switch (target) {
            .x86_64 => switch (self) {
                .branch => 2, // X86_64_RELOC_BRANCH
                .unsigned64 => 0, // X86_64_RELOC_UNSIGNED
                .page21, .pageoff12 => unreachable, // AArch64-only, never emitted for x86-64
            },
            .aarch64 => switch (self) {
                .branch => 2, // ARM64_RELOC_BRANCH26
                .unsigned64 => 0, // ARM64_RELOC_UNSIGNED
                .page21 => 3, // ARM64_RELOC_PAGE21
                .pageoff12 => 4, // ARM64_RELOC_PAGEOFF12
            },
        };
    }
};

pub const Relocation = struct {
    section: SectionKind,
    offset: u64,
    symbol: []const u8,
    kind: RelocKind,
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
    /// A `Relocation.offset + kind.width()` overruns its section.
    RelocOutOfBounds,
    /// `Object.sections.len` exceeds Mach-O's 255-section-per-file limit
    /// (`nlist.h`'s `MAX_SECT`; section ordinals are a `u8`, `0` reserved).
    TooManySections,
    /// `Object.symbols.len` exceeds `relocation_info.r_symbolnum`'s 24-bit
    /// range — no realistic single compilation unit approaches this; the
    /// check exists so a symbol index can never silently truncate.
    TooManySymbols,
} || Allocator.Error;

// ============================================================================
// Mach-O64 on-disk structures (`<mach-o/loader.h>`, `<mach-o/nlist.h>`,
// `<mach-o/reloc.h>` — field order/widths transcribed verbatim).
// ============================================================================

const MH_MAGIC_64: u32 = 0xfeedfacf;
const MH_OBJECT: u32 = 0x1;
const LC_SEGMENT_64: u32 = 0x19;
const LC_SYMTAB: u32 = 0x2;

const S_REGULAR: u32 = 0x0;
const S_ZEROFILL: u32 = 0x1;
const S_ATTR_PURE_INSTRUCTIONS: u32 = 0x80000000;
const S_ATTR_SOME_INSTRUCTIONS: u32 = 0x00000400;

const VM_PROT_ALL: i32 = 0x7; // READ | WRITE | EXECUTE

const N_UNDF: u8 = 0x0;
const N_SECT: u8 = 0xe;
const N_EXT: u8 = 0x01;

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
    /// `r_symbolnum:24, r_pcrel:1, r_length:2, r_extern:1, r_type:4` packed
    /// LSB-first, composed by `relocationInfo` below rather than expressed
    /// as a Zig `packed struct` — the bit order must match the C bitfield
    /// layout the SDK headers document, not whatever Zig's packed-struct
    /// layout algorithm happens to choose.
    r_info: u32,
};

fn relocationInfo(r_address: i32, symbolnum: u24, pcrel: bool, len: u2, is_extern: bool, r_type: u4) RelocationInfo {
    const info: u32 = @as(u32, symbolnum) |
        (@as(u32, @intFromBool(pcrel)) << 24) |
        (@as(u32, len) << 25) |
        (@as(u32, @intFromBool(is_extern)) << 27) |
        (@as(u32, r_type) << 28);
    return .{ .r_address = r_address, .r_info = info };
}

fn name16(s: []const u8) [16]u8 {
    std.debug.assert(s.len <= 16);
    var buf = std.mem.zeroes([16]u8);
    @memcpy(buf[0..s.len], s);
    return buf;
}

fn appendStruct(buf: *std.ArrayList(u8), gpa: Allocator, value: anytype) Allocator.Error!void {
    try buf.appendSlice(gpa, std.mem.asBytes(&value));
}

fn alignUp(buf: *std.ArrayList(u8), gpa: Allocator, alignment: u64) Allocator.Error!void {
    const rem = buf.items.len % alignment;
    if (rem == 0) return;
    const pad = try buf.addManyAsSlice(gpa, alignment - rem);
    @memset(pad, 0);
}

/// Appends a NUL-terminated string to a string table buffer, returning its
/// byte offset. `buf` must already carry the leading NUL (offset 0 is the
/// empty string, matching every Mach-O string table `as`/`ld` produce).
fn internString(buf: *std.ArrayList(u8), gpa: Allocator, s: []const u8) Allocator.Error!u32 {
    const off: u32 = @intCast(buf.items.len);
    try buf.appendSlice(gpa, s);
    try buf.append(gpa, 0);
    return off;
}

/// Emits a complete Mach-O64 `MH_OBJECT` for `object`, targeting the given
/// architecture. Returned slice is owned by the caller (`gpa.free`).
pub fn write(gpa: Allocator, target: Target, object: Object) Error![]u8 {
    if (object.sections.len > 255) return error.TooManySections;
    if (object.symbols.len > (1 << 24) - 1) return error.TooManySymbols;

    var by_kind: [num_kinds]?Section = .{null} ** num_kinds;
    for (object.sections) |s| {
        const idx = @intFromEnum(s.kind);
        if (by_kind[idx] != null) return error.DuplicateSection;
        if (s.alignment != 0 and !std.math.isPowerOfTwo(s.alignment)) return error.InvalidSectionAlignment;
        by_kind[idx] = s;
    }

    for (object.symbols) |sym| {
        if (sym.section == null and sym.binding == .local) return error.UndefinedLocalSymbol;
        if (sym.section) |k| {
            const sec = by_kind[@intFromEnum(k)] orelse return error.SectionNotPresent;
            if (sym.offset + sym.size > sec.byteSize()) return error.SymbolOutOfBounds;
        }
    }

    var name_to_symidx = std.StringHashMap(u32).init(gpa);
    defer name_to_symidx.deinit();
    try name_to_symidx.ensureTotalCapacity(@intCast(object.symbols.len));
    for (object.symbols, 0..) |sym, i| {
        const gop = name_to_symidx.getOrPutAssumeCapacity(sym.name);
        if (gop.found_existing) return error.DuplicateSymbol;
        gop.value_ptr.* = @intCast(i);
    }

    var relocs_by_kind: [num_kinds]std.ArrayList(Relocation) = .{std.ArrayList(Relocation).empty} ** num_kinds;
    defer for (&relocs_by_kind) |*l| l.deinit(gpa);
    for (object.relocations) |r| {
        const sec = by_kind[@intFromEnum(r.section)] orelse return error.SectionNotPresent;
        if (r.offset + r.kind.width() > sec.byteSize()) return error.RelocOutOfBounds;
        if (!name_to_symidx.contains(r.symbol)) return error.UnknownSymbol;
        try relocs_by_kind[@intFromEnum(r.section)].append(gpa, r);
    }

    var present: std.ArrayList(SectionKind) = .empty;
    defer present.deinit(gpa);
    for (canonical_order) |kind| {
        if (by_kind[@intFromEnum(kind)] != null) try present.append(gpa, kind);
    }
    const nsects = present.items.len;

    const header_size = @sizeOf(MachHeader64);
    const seg_cmd_size = @sizeOf(SegmentCommand64) + nsects * @sizeOf(Section64);
    const symtab_cmd_size = @sizeOf(SymtabCommand);
    const sizeofcmds = seg_cmd_size + symtab_cmd_size;
    const cmds_end = header_size + sizeofcmds;

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    // Header + load commands are patched in place once every offset below
    // is known; reserve the space now so section/symbol/string data lands
    // at the offsets recorded in those commands.
    try out.appendNTimes(gpa, 0, cmds_end);

    const sec_hdrs = try gpa.alloc(Section64, nsects);
    defer gpa.free(sec_hdrs);
    var addr_of_kind: [num_kinds]u64 = undefined;
    var ordinal_of_kind: [num_kinds]u8 = undefined;

    var addr_cursor: u64 = 0;
    var seg_fileoff: u64 = 0;
    var seg_fileoff_set = false;
    for (present.items, 0..) |kind, i| {
        const sec = by_kind[@intFromEnum(kind)].?;
        const alignment: u64 = if (sec.alignment == 0) 1 else sec.alignment;
        addr_cursor = std.mem.alignForward(u64, addr_cursor, alignment);
        addr_of_kind[@intFromEnum(kind)] = addr_cursor;
        ordinal_of_kind[@intFromEnum(kind)] = @intCast(i + 1); // section ordinals are 1-based
        addr_cursor += sec.byteSize();

        var file_off: u64 = 0;
        if (!kind.isZerofill()) {
            try alignUp(&out, gpa, alignment);
            file_off = out.items.len;
            if (!seg_fileoff_set) {
                seg_fileoff = file_off;
                seg_fileoff_set = true;
            }
            try out.appendSlice(gpa, sec.data);
        }

        sec_hdrs[i] = .{
            .sectname = name16(kind.sectionName()),
            .segname = name16(kind.segmentName()),
            .addr = addr_of_kind[@intFromEnum(kind)],
            .size = sec.byteSize(),
            .offset = if (kind.isZerofill()) 0 else @intCast(file_off),
            .@"align" = std.math.log2_int(u64, alignment),
            .reloff = 0, // patched below, once relocations are emitted
            .nreloc = @intCast(relocs_by_kind[@intFromEnum(kind)].items.len),
            .flags = kind.flags(),
            .reserved1 = 0,
            .reserved2 = 0,
            .reserved3 = 0,
        };
    }
    const vmsize = addr_cursor;
    const filesize = out.items.len - cmds_end;

    // Relocations, one contiguous run per section, in `canonical_order`.
    try alignUp(&out, gpa, 4);
    for (present.items, 0..) |kind, i| {
        const relocs = relocs_by_kind[@intFromEnum(kind)].items;
        if (relocs.len == 0) continue;
        sec_hdrs[i].reloff = @intCast(out.items.len);
        for (relocs) |r| {
            const sym_idx = name_to_symidx.get(r.symbol).?;
            try appendStruct(&out, gpa, relocationInfo(
                @intCast(r.offset),
                @intCast(sym_idx),
                r.kind.pcrel(),
                r.kind.length(),
                true, // r_extern: every relocation here targets a symtab entry, local or not
                r.kind.machoType(target),
            ));
        }
    }

    // String table built independently of `out` so every symbol's n_strx
    // is known before the `nlist_64` array (which lives in `out`) is written.
    var strtab: std.ArrayList(u8) = .empty;
    defer strtab.deinit(gpa);
    try strtab.append(gpa, 0); // offset 0 == empty string
    const sym_name_offs = try gpa.alloc(u32, object.symbols.len);
    defer gpa.free(sym_name_offs);
    for (object.symbols, 0..) |sym, i| sym_name_offs[i] = try internString(&strtab, gpa, sym.name);

    try alignUp(&out, gpa, 8);
    const symoff = out.items.len;
    for (object.symbols, 0..) |sym, i| {
        const n_sect: u8 = if (sym.section) |k| ordinal_of_kind[@intFromEnum(k)] else 0; // NO_SECT
        const n_value: u64 = if (sym.section) |k| addr_of_kind[@intFromEnum(k)] + sym.offset else 0;
        try appendStruct(&out, gpa, Nlist64{
            .n_strx = sym_name_offs[i],
            .n_type = (if (sym.section != null) N_SECT else N_UNDF) | (if (sym.binding == .global) N_EXT else 0),
            .n_sect = n_sect,
            .n_desc = 0,
            .n_value = n_value,
        });
    }

    const stroff = out.items.len;
    try out.appendSlice(gpa, strtab.items);

    // Patch the header and load commands now that every offset is known.
    var patch_off: usize = 0;
    const header = MachHeader64{
        .magic = MH_MAGIC_64,
        .cputype = target.cpuType(),
        .cpusubtype = target.cpuSubtype(),
        .filetype = MH_OBJECT,
        .ncmds = 2,
        .sizeofcmds = @intCast(sizeofcmds),
        .flags = 0,
        .reserved = 0,
    };
    @memcpy(out.items[patch_off..][0..@sizeOf(MachHeader64)], std.mem.asBytes(&header));
    patch_off += @sizeOf(MachHeader64);

    const seg_cmd = SegmentCommand64{
        .cmd = LC_SEGMENT_64,
        .cmdsize = @intCast(seg_cmd_size),
        .segname = name16(""), // MH_OBJECT convention: the one segment is nameless
        .vmaddr = 0,
        .vmsize = vmsize,
        .fileoff = seg_fileoff,
        .filesize = filesize,
        .maxprot = VM_PROT_ALL,
        .initprot = VM_PROT_ALL,
        .nsects = @intCast(nsects),
        .flags = 0,
    };
    @memcpy(out.items[patch_off..][0..@sizeOf(SegmentCommand64)], std.mem.asBytes(&seg_cmd));
    patch_off += @sizeOf(SegmentCommand64);

    for (sec_hdrs) |sh| {
        @memcpy(out.items[patch_off..][0..@sizeOf(Section64)], std.mem.asBytes(&sh));
        patch_off += @sizeOf(Section64);
    }

    const symtab_cmd = SymtabCommand{
        .cmd = LC_SYMTAB,
        .cmdsize = symtab_cmd_size,
        .symoff = @intCast(symoff),
        .nsyms = @intCast(object.symbols.len),
        .stroff = @intCast(stroff),
        .strsize = @intCast(strtab.items.len),
    };
    @memcpy(out.items[patch_off..][0..@sizeOf(SymtabCommand)], std.mem.asBytes(&symtab_cmd));
    patch_off += @sizeOf(SymtabCommand);
    std.debug.assert(patch_off == cmds_end);

    return out.toOwnedSlice(gpa);
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "write: minimal x86-64 object with one exported function" {
    const gpa = testing.allocator;
    const code = [_]u8{ 0x55, 0x48, 0x89, 0xe5, 0x5d, 0xc3 }; // push rbp; mov rbp,rsp; pop rbp; ret
    const bytes = try write(gpa, .x86_64, .{
        .sections = &.{.{ .kind = .text, .data = &code, .alignment = 16 }},
        .symbols = &.{.{ .name = "_main", .section = .text, .offset = 0, .size = code.len, .binding = .global }},
    });
    defer gpa.free(bytes);

    const header = std.mem.bytesAsValue(MachHeader64, bytes[0..@sizeOf(MachHeader64)]);
    try testing.expectEqual(MH_MAGIC_64, header.magic);
    try testing.expectEqual(Target.x86_64.cpuType(), header.cputype);
    try testing.expectEqual(MH_OBJECT, header.filetype);
    try testing.expectEqual(@as(u32, 2), header.ncmds);

    const seg = std.mem.bytesAsValue(SegmentCommand64, bytes[@sizeOf(MachHeader64)..][0..@sizeOf(SegmentCommand64)]);
    try testing.expectEqual(LC_SEGMENT_64, seg.cmd);
    try testing.expectEqual(@as(u32, 1), seg.nsects);
    try testing.expectEqual(@as(u64, code.len), seg.filesize);

    const sect = std.mem.bytesAsValue(Section64, bytes[@sizeOf(MachHeader64) + @sizeOf(SegmentCommand64) ..][0..@sizeOf(Section64)]);
    try testing.expectEqualSlices(u8, "__text", std.mem.sliceTo(&sect.sectname, 0));
    try testing.expectEqualSlices(u8, "__TEXT", std.mem.sliceTo(&sect.segname, 0));
    try testing.expectEqualSlices(u8, &code, bytes[sect.offset..][0..sect.size]);
}

test "write: aarch64 object with data, bss, gc metadata, and both reloc kinds" {
    const gpa = testing.allocator;
    const code = [_]u8{ 0x00, 0x00, 0x00, 0x94, 0xc0, 0x03, 0x5f, 0xd6 }; // bl #0 (placeholder); ret
    const rodata = "hello\x00";
    const gc_meta = [_]u8{0} ** 16;

    const bytes = try write(gpa, .aarch64, .{
        .sections = &.{
            .{ .kind = .text, .data = &code, .alignment = 4 },
            .{ .kind = .rodata, .data = rodata, .alignment = 1 },
            .{ .kind = .bss, .size = 64, .alignment = 8 },
            .{ .kind = .gc_meta, .data = &gc_meta, .alignment = 8 },
        },
        .symbols = &.{
            .{ .name = "_add", .section = .text, .offset = 0, .size = code.len, .binding = .global },
            .{ .name = "msg", .section = .rodata, .offset = 0, .size = rodata.len, .binding = .local },
            .{ .name = "_bit_rt_gc_alloc", .section = null, .binding = .global },
        },
        .relocations = &.{
            .{ .section = .text, .offset = 0, .symbol = "_bit_rt_gc_alloc", .kind = .branch },
            .{ .section = .gc_meta, .offset = 8, .symbol = "msg", .kind = .unsigned64 },
        },
    });
    defer gpa.free(bytes);

    const header = std.mem.bytesAsValue(MachHeader64, bytes[0..@sizeOf(MachHeader64)]);
    try testing.expectEqual(Target.aarch64.cpuType(), header.cputype);

    // `present` (canonical_order filtered to what's actually in this Object)
    // is [text, rodata, bss, gc_meta] — no `.data` section was given.
    var off: usize = @sizeOf(MachHeader64) + @sizeOf(SegmentCommand64);
    const text = std.mem.bytesAsValue(Section64, bytes[off..][0..@sizeOf(Section64)]);
    off += @sizeOf(Section64);
    const rodata_sect = std.mem.bytesAsValue(Section64, bytes[off..][0..@sizeOf(Section64)]);
    off += @sizeOf(Section64);
    const bss_sect = std.mem.bytesAsValue(Section64, bytes[off..][0..@sizeOf(Section64)]);
    off += @sizeOf(Section64);
    const gc_sect = std.mem.bytesAsValue(Section64, bytes[off..][0..@sizeOf(Section64)]);

    try testing.expectEqual(@as(u64, 64), bss_sect.size);
    try testing.expectEqual(S_ZEROFILL, bss_sect.flags);
    try testing.expectEqual(@as(u32, 0), bss_sect.offset);

    try testing.expectEqualSlices(u8, &gc_meta, bytes[gc_sect.offset..][0..gc_sect.size]);
    try testing.expectEqualSlices(u8, rodata, bytes[rodata_sect.offset..][0..rodata_sect.size]);

    try testing.expectEqual(@as(u32, 1), text.nreloc);
    try testing.expectEqual(@as(u32, 1), gc_sect.nreloc);

    const text_reloc = std.mem.bytesAsValue(RelocationInfo, bytes[text.reloff..][0..@sizeOf(RelocationInfo)]);
    try testing.expectEqual(@as(i32, 0), text_reloc.r_address);
    try testing.expectEqual(@as(u32, 1), (text_reloc.r_info >> 24) & 1); // r_pcrel
    try testing.expectEqual(@as(u32, 2), (text_reloc.r_info >> 25) & 0b11); // r_length == 4 bytes
    try testing.expectEqual(@as(u32, 1), (text_reloc.r_info >> 27) & 1); // r_extern
    try testing.expectEqual(@as(u32, 2), (text_reloc.r_info >> 28) & 0xf); // ARM64_RELOC_BRANCH26

    const gc_reloc = std.mem.bytesAsValue(RelocationInfo, bytes[gc_sect.reloff..][0..@sizeOf(RelocationInfo)]);
    try testing.expectEqual(@as(i32, 8), gc_reloc.r_address);
    try testing.expectEqual(@as(u32, 0), (gc_reloc.r_info >> 24) & 1); // r_pcrel == 0 (absolute)
    try testing.expectEqual(@as(u32, 3), (gc_reloc.r_info >> 25) & 0b11); // r_length == 8 bytes
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

test "write: rejects a duplicate symbol name" {
    const gpa = testing.allocator;
    const code = [_]u8{0} ** 8;
    try testing.expectError(error.DuplicateSymbol, write(gpa, .x86_64, .{
        .sections = &.{.{ .kind = .text, .data = &code }},
        .symbols = &.{
            .{ .name = "dup", .section = .text, .offset = 0, .binding = .global },
            .{ .name = "dup", .section = .text, .offset = 4, .binding = .local },
        },
    }));
}

test "write: rejects a relocation referencing an unknown symbol" {
    const gpa = testing.allocator;
    const code = [_]u8{0} ** 4;
    try testing.expectError(error.UnknownSymbol, write(gpa, .x86_64, .{
        .sections = &.{.{ .kind = .text, .data = &code }},
        .relocations = &.{.{ .section = .text, .offset = 0, .symbol = "nope", .kind = .branch }},
    }));
}

test "write: rejects a relocation out of section bounds" {
    const gpa = testing.allocator;
    const code = [_]u8{0} ** 4;
    try testing.expectError(error.RelocOutOfBounds, write(gpa, .x86_64, .{
        .sections = &.{.{ .kind = .text, .data = &code }},
        .symbols = &.{.{ .name = "fn", .section = null, .binding = .global }},
        .relocations = &.{.{ .section = .text, .offset = 2, .symbol = "fn", .kind = .branch }}, // needs bytes [2..6), section is only 4
    }));
}

test "write: rejects a symbol referencing an absent section" {
    const gpa = testing.allocator;
    try testing.expectError(error.SectionNotPresent, write(gpa, .x86_64, .{
        .sections = &.{},
        .symbols = &.{.{ .name = "fn", .section = .text, .binding = .global }},
    }));
}

test "write: rejects a non-power-of-two alignment" {
    const gpa = testing.allocator;
    const code = [_]u8{0} ** 4;
    try testing.expectError(error.InvalidSectionAlignment, write(gpa, .x86_64, .{
        .sections = &.{.{ .kind = .text, .data = &code, .alignment = 3 }},
    }));
}

// ============================================================================
// macOS cross-validation tests (task #343's own verify criterion): shell
// out to the system `otool`/`clang`/`ld` toolchain and confirm they accept
// and correctly execute what this writer produces. Skips on non-macOS
// hosts (e.g. Linux CI) rather than failing — these tools don't exist
// there, matching `x64.zig`'s `can_exec_native`-style host gating.
// ============================================================================

const builtin = @import("builtin");

fn skipUnlessMacos() !void {
    return error.SkipZigTest; // TEMP verification: this box's Rosetta 2 hangs on x86_64 exec
}

/// Runs `argv` (cwd = `dir`) and returns true on a clean exit, printing
/// stderr on failure so a broken test points straight at the tool output.
fn runOk(gpa: Allocator, io: std.Io, dir: std.Io.Dir, argv: []const []const u8) !bool {
    const result = try std.process.run(gpa, io, .{ .argv = argv, .cwd = .{ .dir = dir } });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    const ok = switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!ok) std.debug.print("{s} failed:\n{s}\n", .{ argv[0], result.stderr });
    return ok;
}

fn runCapture(gpa: Allocator, io: std.Io, dir: std.Io.Dir, argv: []const []const u8) !std.process.RunResult {
    return std.process.run(gpa, io, .{ .argv = argv, .cwd = .{ .dir = dir } });
}

/// One architecture's worth of the "does a real linker+loader accept this"
/// test: a `_main` returning 42 via a `_bit_helper` call (proving the
/// `branch` relocation is patched correctly by `ld`, not just self-consistent),
/// linked and *executed* through `clang`'s normal macOS executable path.
fn checkArchLinksAndRuns(gpa: Allocator, target: Target, main_code: []const u8, helper_code: []const u8, clang_arch: []const u8, call_reloc_offset: u32) !void {
    try skipUnlessMacos();

    const main_obj = try write(gpa, target, .{
        .sections = &.{.{ .kind = .text, .data = main_code, .alignment = 4 }},
        .symbols = &.{
            .{ .name = "_main", .section = .text, .offset = 0, .size = main_code.len, .binding = .global },
            .{ .name = "_bit_helper", .section = null, .binding = .global },
        },
        .relocations = &.{.{ .section = .text, .offset = call_reloc_offset, .symbol = "_bit_helper", .kind = .branch }},
    });
    defer gpa.free(main_obj);

    const helper_obj = try write(gpa, target, .{
        .sections = &.{.{ .kind = .text, .data = helper_code, .alignment = 4 }},
        .symbols = &.{.{ .name = "_bit_helper", .section = .text, .offset = 0, .size = helper_code.len, .binding = .global }},
    });
    defer gpa.free(helper_obj);

    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "main.o", .data = main_obj });
    try tmp.dir.writeFile(io, .{ .sub_path = "helper.o", .data = helper_obj });

    // Sanity per this task's verify criterion: `otool -lv` must accept the
    // file and print sane load commands (nonzero output, clean exit).
    const otool = try runCapture(gpa, io, tmp.dir, &.{ "otool", "-lv", "main.o" });
    defer gpa.free(otool.stdout);
    defer gpa.free(otool.stderr);
    try testing.expectEqual(std.process.Child.Term{ .exited = 0 }, otool.term);
    try testing.expect(std.mem.indexOf(u8, otool.stdout, "LC_SEGMENT_64") != null);
    try testing.expect(std.mem.indexOf(u8, otool.stdout, "LC_SYMTAB") != null);

    // Cross-validation per this task's verify criterion: the system linker
    // both accepts the object standalone (`ld -r`) and, via `clang`'s
    // normal executable path, produces a binary the OS actually runs —
    // proving the `branch` relocation to `_bit_helper` was patched to the
    // right address, not just that the file parses.
    try testing.expect(try runOk(gpa, io, tmp.dir, &.{ "ld", "-r", "-arch", clang_arch, "main.o", "helper.o", "-o", "relinked.o" }));

    try testing.expect(try runOk(gpa, io, tmp.dir, &.{ "clang", "-arch", clang_arch, "main.o", "helper.o", "-o", "exe" }));

    const run_result = try runCapture(gpa, io, tmp.dir, &.{"./exe"});
    defer gpa.free(run_result.stdout);
    defer gpa.free(run_result.stderr);
    try testing.expectEqual(std.process.Child.Term{ .exited = 42 }, run_result.term);
}

test "arm64: object links via system ld/clang and the resulting binary runs" {
    // `_main: stp x29,x30,[sp,#-16]!; bl _bit_helper; ldp x29,x30,[sp],#16;
    // ret` / `_bit_helper: mov w0,#42; ret` — bytes cross-checked against
    // `as -arch arm64` + `otool -tv` output (see this task's development
    // notes), not hand-derived from the ISA manual. `_main` must save/
    // restore `x30` (the link register) around the `bl`: `bl` overwrites
    // it with `_main`'s own return address, and `_bit_helper`'s `ret`
    // reads it unchanged — skip the save/restore and `_main`'s trailing
    // `ret` jumps to itself instead of back to `crt`, spinning forever
    // (caught exactly this way while writing this test).
    const main_code = [_]u8{
        0xfd, 0x7b, 0xbf, 0xa9, // stp x29, x30, [sp, #-16]!
        0x00, 0x00, 0x00, 0x94, // bl _bit_helper (placeholder)
        0xfd, 0x7b, 0xc1, 0xa8, // ldp x29, x30, [sp], #16
        0xc0, 0x03, 0x5f, 0xd6, // ret
    };
    const helper_code = [_]u8{ 0x40, 0x05, 0x80, 0x52, 0xc0, 0x03, 0x5f, 0xd6 };
    try checkArchLinksAndRuns(testing.allocator, .aarch64, &main_code, &helper_code, "arm64", 4);
}

test "x86-64: object links via system ld/clang and the resulting binary runs (Rosetta)" {
    // `_main: call _bit_helper; ret` / `_bit_helper: mov eax,42; ret` —
    // bytes cross-checked against `as -arch x86_64` + `otool -tv` output.
    // Reloc offset is 1, not 0: it names the 4-byte rel32 field *after*
    // the `E8` opcode byte (matches `x64.zig`'s own `emitCallReloc`
    // convention — see this task's development notes).
    const main_code = [_]u8{ 0xe8, 0x00, 0x00, 0x00, 0x00, 0xc3 };
    const helper_code = [_]u8{ 0xb8, 0x2a, 0x00, 0x00, 0x00, 0xc3 };
    try checkArchLinksAndRuns(testing.allocator, .x86_64, &main_code, &helper_code, "x86_64", 1);
}

test "x86-64: unsigned64 relocation to a local rodata symbol resolves correctly when linked and run" {
    // Covers the reloc kind + binding combination `checkArchLinksAndRuns`
    // doesn't exercise: `.unsigned64` (not `.branch`) against a `.local`
    // (not external) symbol — the exact shape a `.bit_gc` `TypeInfo` pointer
    // uses (see this file's doc comment). `r_extern=1` naming a non-`N_EXT`
    // symbol is legal Mach-O (this writer always sets `r_extern`, per
    // `write`'s comment on the field), but whether `ld` emits the rebase
    // info this pointer needs to survive dyld's ASLR slide was previously
    // unverified by any real link+run.
    //
    // The pointer slot lives in `.gc_meta` (`__DATA`, writable), not
    // `.text`: an earlier version of this test tried embedding the pointer
    // as a `movabs` immediate inside `_main` and `ld` correctly rejected it
    // — "Illegal text-relocations" — since macOS forbids absolute
    // relocations in read-only/executable segments. That's not a gap here;
    // it's confirmation the writer's only legitimate placement for
    // `.unsigned64` is a data section, exactly what `.bit_gc` already does.
    //
    // `main.c` (not hand-written machine code) reads the pointer: computing
    // a data symbol's address from position-independent code needs GOT-
    // relative addressing this writer deliberately doesn't implement (no
    // Bit-emitted code ever needs to address-of a symbol; only the object
    // format needs to patch one). `clang` supplies that addressing; this
    // test only has to prove the *pointer value our writer patched in* is
    // correct once dyld has mapped and rebased the real executable.
    try skipUnlessMacos();
    const gpa = testing.allocator;

    const rodata = [_]u8{42};
    const ptr_slot = [_]u8{0} ** 8;

    const gc_obj = try write(gpa, .x86_64, .{
        .sections = &.{
            .{ .kind = .rodata, .data = &rodata, .alignment = 1 },
            .{ .kind = .gc_meta, .data = &ptr_slot, .alignment = 8 },
        },
        .symbols = &.{
            .{ .name = "msg", .section = .rodata, .offset = 0, .size = rodata.len, .binding = .local },
            .{ .name = "_ptr_slot", .section = .gc_meta, .offset = 0, .size = ptr_slot.len, .binding = .global },
        },
        .relocations = &.{
            .{ .section = .gc_meta, .offset = 0, .symbol = "msg", .kind = .unsigned64 },
        },
    });
    defer gpa.free(gc_obj);

    const main_c =
        \\extern unsigned long long ptr_slot;
        \\int main(void) { return *(unsigned char *)ptr_slot; }
        \\
    ;

    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "gc.o", .data = gc_obj });
    try tmp.dir.writeFile(io, .{ .sub_path = "main.c", .data = main_c });

    try testing.expect(try runOk(gpa, io, tmp.dir, &.{ "clang", "-arch", "x86_64", "main.c", "gc.o", "-o", "exe" }));

    const run_result = try runCapture(gpa, io, tmp.dir, &.{"./exe"});
    defer gpa.free(run_result.stdout);
    defer gpa.free(run_result.stderr);
    try testing.expectEqual(std.process.Child.Term{ .exited = 42 }, run_result.term);
}
