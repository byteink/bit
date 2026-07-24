//! PE/COFF relocatable object writer (task #344, generalized under #1103 to
//! close out #345's remaining scope). Emits a Windows `.obj` that MSVC
//! `link.exe`/LLVM `lld-link` — and this project's own `link/pe.zig` — can
//! consume.
//!
//! Mirrors `elf.zig`/`macho.zig`'s public shape (`Target`, `SectionKind`,
//! `canonical_order`, `Section`, `Symbol`, `RelocKind`, `Relocation`,
//! `Object`, `write`) so a caller (`emit.zig`, or this file's own tests) can
//! treat every object-writer sibling uniformly. Deliberately decoupled from
//! `codegen/x64.zig`/`codegen/arm64.zig`, same as its siblings: this file
//! knows nothing of `ir.zig`, physical registers, or instruction encoding —
//! only the generic shape every object file needs.
//!
//! Two shape differences from `elf.zig`, both format-driven:
//!
//! - **No stored addend.** ELF x86-64 objects are RELA (an explicit signed
//!   addend rides in each relocation entry); COFF relocations carry no such
//!   field at all — every type's "addend" is a fixed constant baked into its
//!   definition (`IMAGE_REL_AMD64_REL32` is always computed as
//!   `S - (P + 4)`, the "byte following the relocation" per the Microsoft PE
//!   Format spec's COFF Relocations table; an AArch64 instruction-field
//!   relocation like `BRANCH26`/`PAGEBASE_REL21` is always relative to the
//!   instruction's own address, no offset). So `Relocation` here has no
//!   `addend`; `link/pe_reader.zig` is what reconstructs the generic linker
//!   IR's explicit addend from each type's known fixed constant.
//! - **Symbol table index == `Object.symbols` index**, with no reordering.
//!   COFF has no `sh_info`-style local/global boundary field the way ELF's
//!   `SHT_SYMTAB` does (`elf.zig`'s locals-before-globals reordering exists
//!   only to satisfy that), and — unlike ELF's mandatory null symbol at
//!   index 0 — a COFF symbol table has no reserved leading slot either. A
//!   relocation's `SymbolTableIndex` is therefore exactly its target's index
//!   in `Object.symbols`.
//!
//! Machine types and relocation numbers are transcribed from Zig's own
//! `std.coff` (`IMAGE.FILE.MACHINE`, `IMAGE.REL.AMD64`, `IMAGE.REL.ARM64`),
//! not from memory — this file's tests round-trip every case through
//! `std.coff.Coff` to confirm the two agree.

const std = @import("std");
const coff = std.coff;
const Allocator = std.mem.Allocator;

pub const Target = enum {
    x86_64,
    aarch64,

    fn machine(self: Target) coff.IMAGE.FILE.MACHINE {
        return switch (self) {
            .x86_64 => .AMD64,
            .aarch64 => .ARM64,
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
            // COFF/PE convention names the read-only data section `.rdata`,
            // not `.rodata` (see any MSVC/lld-link output).
            .rodata => ".rdata",
            .bss => ".bss",
            .gc_meta => ".bit_gc",
        };
    }

    /// `IMAGE_SCN_*` characteristics, minus the alignment nibble (added by
    /// the caller via `alignFlags`, since it depends on `Section.alignment`).
    fn baseFlags(self: SectionKind) u32 {
        const cnt_code: u32 = 0x00000020;
        const cnt_init: u32 = 0x00000040;
        const cnt_uninit: u32 = 0x00000080;
        const mem_execute: u32 = 0x20000000;
        const mem_read: u32 = 0x40000000;
        const mem_write: u32 = 0x80000000;
        return switch (self) {
            .text => cnt_code | mem_execute | mem_read,
            .data => cnt_init | mem_read | mem_write,
            .rodata => cnt_init | mem_read,
            .bss => cnt_uninit | mem_read | mem_write,
            // ABI.md §4: allocated + readable, never written or executed —
            // matches `elf.zig`'s `.bit_gc` (`SHF_ALLOC` only).
            .gc_meta => cnt_init | mem_read,
        };
    }

    fn isBss(self: SectionKind) bool {
        return self == .bss;
    }
};

const num_kinds = @typeInfo(SectionKind).@"enum".fields.len;

/// Fixed emission order — spelled out explicitly, not derived from enum
/// declaration order, so reordering `SectionKind`'s declaration can never
/// silently reorder the file layout. Mirrors `elf.zig`'s `canonical_order`.
const canonical_order = [_]SectionKind{ .text, .data, .rodata, .bss, .gc_meta };

/// One section's content. `.bss` is the only kind with no file bytes: give
/// it `size` and leave `data` empty (its contents are implicitly zero).
pub const Section = struct {
    kind: SectionKind,
    data: []const u8 = &.{},
    size: u64 = 0,
    /// 0 or a power of two; 0 means "no constraint" and is normalized to 1.
    alignment: u32 = 1,

    fn byteSize(self: Section) u64 {
        return if (self.kind.isBss()) self.size else self.data.len;
    }
};

pub const Binding = enum { local, global };
pub const SymKind = enum { notype, object, func };

/// `section == null` names an external symbol (a runtime `bit_rt_*` export,
/// a `kernel32` import, or another Bit module's function) the linker must
/// resolve — it carries no offset/size and must be `.global`: nothing else
/// can ever define an undefined local.
pub const Symbol = struct {
    name: []const u8,
    section: ?SectionKind,
    offset: u64 = 0,
    size: u64 = 0,
    binding: Binding,
    kind: SymKind = .notype,
};

/// Every relocation kind this writer knows how to encode — the subset of
/// `elf.zig`'s `RelocKind` this project's own codegen actually emits, minus
/// the TLS kinds (Windows TLS is a wholly different mechanism — `.tls$`
/// sections plus a `_tls_used` directory entry — not yet in scope; see the
/// module doc comment's note on addends for why no kind here carries one).
pub const RelocKind = enum {
    /// x86-64 `call rel32`/`lea rip-rel`: `IMAGE_REL_AMD64_REL32`, a 4-byte
    /// field the linker sets to `S - (P + 4)`.
    pc32,
    /// `IMAGE_REL_AMD64_ADDR64` / `IMAGE_REL_ARM64_ADDR64`: an 8-byte
    /// absolute VA (e.g. a `TypeInfo.name_ptr` in `.bit_gc`).
    abs64,
    /// ARM64 `BL`'s 26-bit PC-relative immediate: `IMAGE_REL_ARM64_BRANCH26`.
    aarch64_call26,
    /// ARM64 `ADRP`'s page immediate: `IMAGE_REL_ARM64_PAGEBASE_REL21`.
    aarch64_adr_prel_pg_hi21,
    /// ARM64 `ADD` (immediate) low-12 bits, unsigned, un-scaled:
    /// `IMAGE_REL_ARM64_PAGEOFFSET_12A`.
    aarch64_add_abs_lo12_nc,

    fn width(self: RelocKind) u32 {
        return switch (self) {
            .pc32, .aarch64_call26, .aarch64_adr_prel_pg_hi21, .aarch64_add_abs_lo12_nc => 4,
            .abs64 => 8,
        };
    }

    fn coffType(self: RelocKind, target: Target) ?u16 {
        return switch (self) {
            .pc32 => if (target == .x86_64) @intFromEnum(coff.IMAGE.REL.AMD64.REL32) else null,
            .abs64 => switch (target) {
                .x86_64 => @intFromEnum(coff.IMAGE.REL.AMD64.ADDR64),
                .aarch64 => @intFromEnum(coff.IMAGE.REL.ARM64.ADDR64),
            },
            .aarch64_call26 => if (target == .aarch64) @intFromEnum(coff.IMAGE.REL.ARM64.BRANCH26) else null,
            .aarch64_adr_prel_pg_hi21 => if (target == .aarch64) @intFromEnum(coff.IMAGE.REL.ARM64.PAGEBASE_REL21) else null,
            .aarch64_add_abs_lo12_nc => if (target == .aarch64) @intFromEnum(coff.IMAGE.REL.ARM64.PAGEOFFSET_12A) else null,
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
    /// A `Section.alignment` is neither 0 nor a power of two, or exceeds
    /// COFF's largest encodable section alignment (8192 bytes).
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
    /// COFF's `NumberOfRelocations` is a `u16` per section; a section needing
    /// more than 65535 requires the `IMAGE_SCN_LNK_NRELOC_OVFL` extended-count
    /// scheme, which this writer doesn't implement (no real Bit module comes
    /// close).
    TooManyRelocations,
} || Allocator.Error;

const FILE_HEADER_SIZE: u32 = 20;
const SECTION_HEADER_SIZE: u32 = 40;
const RELOC_ENTRY_SIZE: u32 = 10;
const SYMBOL_ENTRY_SIZE: u32 = 18;

/// `IMAGE_SYM_CLASS_STATIC`/`IMAGE_SYM_CLASS_EXTERNAL` — MS tools' storage
/// class for a section-local vs. externally-visible symbol.
const IMAGE_SYM_CLASS_STATIC: u8 = 3;
const IMAGE_SYM_CLASS_EXTERNAL: u8 = 2;
/// Complex type FUNCTION (0x20) | base type NULL (0x00), MS tools' value for
/// any symbol naming a function. Data symbols use `IMAGE_SYM_TYPE_NULL` (0).
const IMAGE_SYM_TYPE_FUNCTION: u16 = 0x0020;
const IMAGE_SYM_TYPE_NULL: u16 = 0x0000;
/// Section number for a not-yet-resolved external symbol.
const IMAGE_SYM_UNDEFINED: u16 = 0;

fn alignNibble(bytes: u32) Error!u32 {
    if (bytes > 8192) return error.InvalidSectionAlignment;
    // `coff.SectionHeader.Flags.Align`: NONE=0, then 1<<(n-1) bytes for n=1..14.
    return @ctz(bytes) + 1;
}

/// Emits a complete COFF object for `object`, targeting the given
/// architecture. Returned slice is owned by the caller (`gpa.free`).
pub fn write(gpa: Allocator, target: Target, object: Object) Error![]u8 {
    var by_kind: [num_kinds]?Section = .{null} ** num_kinds;
    for (object.sections) |s| {
        const idx = @intFromEnum(s.kind);
        if (by_kind[idx] != null) return error.DuplicateSection;
        if (s.alignment != 0 and !std.math.isPowerOfTwo(s.alignment)) return error.InvalidSectionAlignment;
        by_kind[idx] = s;
    }

    // Symbol table index == `object.symbols` index (module doc comment): no
    // reordering, so validation and the emitted table share one pass order.
    var name_to_symidx = std.StringHashMap(u32).init(gpa);
    defer name_to_symidx.deinit();
    try name_to_symidx.ensureTotalCapacity(@intCast(object.symbols.len));
    for (object.symbols, 0..) |sym, i| {
        if (sym.section == null and sym.binding == .local) return error.UndefinedLocalSymbol;
        if (sym.section) |k| {
            const sec = by_kind[@intFromEnum(k)] orelse return error.SectionNotPresent;
            if (sym.offset + sym.size > sec.byteSize()) return error.SymbolOutOfBounds;
        }
        const gop = name_to_symidx.getOrPutAssumeCapacity(sym.name);
        if (gop.found_existing) return error.DuplicateSymbol;
        gop.value_ptr.* = @intCast(i);
    }

    // Relocations, bucketed by section (each section's own contiguous
    // `IMAGE_RELOCATION` run), in the caller's original relative order.
    var relocs_by_kind: [num_kinds]std.ArrayList(Relocation) = undefined;
    for (&relocs_by_kind) |*l| l.* = .empty;
    defer for (&relocs_by_kind) |*l| l.deinit(gpa);
    for (object.relocations) |r| {
        const sec = by_kind[@intFromEnum(r.section)] orelse return error.SectionNotPresent;
        if (r.offset + r.kind.width() > sec.byteSize()) return error.RelocOutOfBounds;
        if (r.kind.coffType(target) == null) return error.RelocKindUnsupportedForTarget;
        if (!name_to_symidx.contains(r.symbol)) return error.UnknownSymbol;
        try relocs_by_kind[@intFromEnum(r.section)].append(gpa, r);
        if (relocs_by_kind[@intFromEnum(r.section)].items.len > std.math.maxInt(u16)) return error.TooManyRelocations;
    }

    var present: std.ArrayList(SectionKind) = .empty;
    defer present.deinit(gpa);
    for (canonical_order) |k| if (by_kind[@intFromEnum(k)] != null) try present.append(gpa, k);
    const nsections: u32 = @intCast(present.items.len);

    // ---- file layout: header, section headers, then each section's raw
    // data (aligned to its own `Section.alignment`), then relocations, then
    // the symbol table, then the string table.
    const header_end = FILE_HEADER_SIZE + nsections * SECTION_HEADER_SIZE;
    var section_file_off: [num_kinds]u32 = .{0} ** num_kinds;
    var cursor: u32 = header_end;
    for (present.items) |k| {
        const sec = by_kind[@intFromEnum(k)].?;
        if (sec.kind.isBss()) continue; // no file bytes
        const alignment: u32 = if (sec.alignment == 0) 1 else sec.alignment;
        cursor = @intCast(std.mem.alignForward(u32, cursor, alignment));
        section_file_off[@intFromEnum(k)] = cursor;
        cursor += @intCast(sec.data.len);
    }
    var reloc_file_off: [num_kinds]u32 = .{0} ** num_kinds;
    for (present.items) |k| {
        const list = relocs_by_kind[@intFromEnum(k)];
        if (list.items.len == 0) continue;
        reloc_file_off[@intFromEnum(k)] = cursor;
        cursor += @intCast(list.items.len * RELOC_ENTRY_SIZE);
    }
    const symtab_start = cursor;
    const symtab_size = @as(u32, @intCast(object.symbols.len)) * SYMBOL_ENTRY_SIZE;

    // ---- string table: names longer than 8 bytes spill here (a leading
    // 4-byte self-inclusive size, then NUL-terminated names; offset 0 is
    // reserved so a short name's inline `Name[8]` stays distinguishable).
    var strtab: std.ArrayList(u8) = .empty;
    defer strtab.deinit(gpa);
    try strtab.appendSlice(gpa, &.{ 0, 0, 0, 0 });
    const str_offsets = try gpa.alloc(u32, object.symbols.len);
    defer gpa.free(str_offsets);
    for (object.symbols, 0..) |s, i| {
        if (s.name.len <= 8) {
            str_offsets[i] = 0;
            continue;
        }
        str_offsets[i] = @intCast(strtab.items.len);
        try strtab.appendSlice(gpa, s.name);
        try strtab.append(gpa, 0);
    }
    std.mem.writeInt(u32, strtab.items[0..4], @intCast(strtab.items.len), .little);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    // ---- COFF file header (no optional header: object file).
    try appendU16(&out, gpa, @intFromEnum(target.machine()));
    try appendU16(&out, gpa, @intCast(nsections));
    try appendU32(&out, gpa, 0); // TimeDateStamp: 0 for reproducible builds
    try appendU32(&out, gpa, if (object.symbols.len == 0) 0 else symtab_start);
    try appendU32(&out, gpa, @intCast(object.symbols.len));
    try appendU16(&out, gpa, 0); // SizeOfOptionalHeader
    try appendU16(&out, gpa, 0); // Characteristics

    // ---- section headers.
    for (present.items) |k| {
        const sec = by_kind[@intFromEnum(k)].?;
        const alignment: u32 = if (sec.alignment == 0) 1 else sec.alignment;
        try out.appendSlice(gpa, &paddedName8(k.sectionName()));
        try appendU32(&out, gpa, 0); // VirtualSize: unused in object files
        try appendU32(&out, gpa, 0); // VirtualAddress: unused in object files
        try appendU32(&out, gpa, @intCast(sec.byteSize()));
        try appendU32(&out, gpa, section_file_off[@intFromEnum(k)]);
        try appendU32(&out, gpa, reloc_file_off[@intFromEnum(k)]);
        try appendU32(&out, gpa, 0); // PointerToLinenumbers: deprecated
        try appendU16(&out, gpa, @intCast(relocs_by_kind[@intFromEnum(k)].items.len));
        try appendU16(&out, gpa, 0); // NumberOfLinenumbers: deprecated
        try appendU32(&out, gpa, sec.kind.baseFlags() | (try alignNibble(alignment) << 20));
    }

    // ---- section raw data, in the same order as the headers above.
    for (present.items) |k| {
        const sec = by_kind[@intFromEnum(k)].?;
        if (sec.kind.isBss()) continue;
        std.debug.assert(out.items.len <= section_file_off[@intFromEnum(k)]);
        try out.appendNTimes(gpa, 0, section_file_off[@intFromEnum(k)] - out.items.len);
        try out.appendSlice(gpa, sec.data);
    }

    // ---- relocations, one contiguous run per section.
    for (present.items) |k| {
        for (relocs_by_kind[@intFromEnum(k)].items) |r| {
            try appendU32(&out, gpa, @intCast(r.offset));
            try appendU32(&out, gpa, name_to_symidx.get(r.symbol).?);
            try appendU16(&out, gpa, r.kind.coffType(target).?);
        }
    }

    // ---- symbol table, in `object.symbols`' own order.
    for (object.symbols, 0..) |s, i| {
        if (s.name.len <= 8) {
            try out.appendSlice(gpa, &paddedName8(s.name));
        } else {
            try appendU32(&out, gpa, 0);
            try appendU32(&out, gpa, str_offsets[i]);
        }
        try appendU32(&out, gpa, @intCast(s.offset)); // Value
        try appendU16(&out, gpa, if (s.section) |k| @intCast(@as(u16, @intCast(indexOf(present.items, k) + 1))) else IMAGE_SYM_UNDEFINED);
        try appendU16(&out, gpa, if (s.kind == .func) IMAGE_SYM_TYPE_FUNCTION else IMAGE_SYM_TYPE_NULL);
        try out.append(gpa, if (s.binding == .global) IMAGE_SYM_CLASS_EXTERNAL else IMAGE_SYM_CLASS_STATIC);
        try out.append(gpa, 0); // NumberOfAuxSymbols
    }

    // ---- string table.
    try out.appendSlice(gpa, strtab.items);

    std.debug.assert(out.items.len == symtab_start + symtab_size + strtab.items.len);
    return out.toOwnedSlice(gpa);
}

/// 1-based index of `k` within `present` (the order the section table was
/// emitted in), for a defined symbol's `SectionNumber`.
fn indexOf(present: []const SectionKind, k: SectionKind) usize {
    for (present, 0..) |p, i| if (p == k) return i;
    unreachable; // caller already proved `k` is in `by_kind`/`present`
}

fn paddedName8(name: []const u8) [8]u8 {
    std.debug.assert(name.len <= 8);
    var buf: [8]u8 = @splat(0);
    @memcpy(buf[0..name.len], name);
    return buf;
}

fn appendU16(out: *std.ArrayList(u8), gpa: Allocator, v: u16) Allocator.Error!void {
    try out.appendSlice(gpa, &.{ @truncate(v), @truncate(v >> 8) });
}

fn appendU32(out: *std.ArrayList(u8), gpa: Allocator, v: u32) Allocator.Error!void {
    try out.appendSlice(gpa, &.{ @truncate(v), @truncate(v >> 8), @truncate(v >> 16), @truncate(v >> 24) });
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

fn readU16(data: []const u8, off: usize) u16 {
    return std.mem.readInt(u16, data[off..][0..2], .little);
}
fn readU32(data: []const u8, off: usize) u32 {
    return std.mem.readInt(u32, data[off..][0..4], .little);
}

test "empty module: valid header, zero sections, no symtab" {
    const bytes = try write(testing.allocator, .x86_64, .{ .sections = &.{} });
    defer testing.allocator.free(bytes);

    try testing.expectEqual(@as(u16, 0x8664), readU16(bytes, 0));
    try testing.expectEqual(@as(u16, 0), readU16(bytes, 2)); // NumberOfSections
    try testing.expectEqual(@as(u32, 0), readU32(bytes, 8)); // PointerToSymbolTable
    try testing.expectEqual(@as(u32, 0), readU32(bytes, 12)); // NumberOfSymbols
    // Header only, plus the string table's mandatory 4-byte self-inclusive
    // size prefix (empty string table): no sections, no symbols.
    try testing.expectEqual(@as(usize, FILE_HEADER_SIZE + 4), bytes.len);
}

test "one .text function, no relocs: symbol points at its section offset" {
    const code = [_]u8{ 0x55, 0xC3 }; // push rbp; ret
    var symbols = [_]Symbol{.{ .name = "main", .section = .text, .offset = 0, .size = code.len, .binding = .global, .kind = .func }};
    var sections = [_]Section{.{ .kind = .text, .data = &code, .alignment = 16 }};
    const bytes = try write(testing.allocator, .x86_64, .{ .sections = &sections, .symbols = &symbols });
    defer testing.allocator.free(bytes);

    const sect = bytes[FILE_HEADER_SIZE..][0..SECTION_HEADER_SIZE];
    try testing.expectEqualSlices(u8, ".text\x00\x00\x00", sect[0..8]);
    const text_start = readU32(sect, 20);
    try testing.expectEqualSlices(u8, &code, bytes[text_start..][0..code.len]);

    const symtab_start = readU32(bytes, 8);
    try testing.expectEqual(@as(u32, 1), readU32(bytes, 12));
    const sym = bytes[symtab_start..][0..SYMBOL_ENTRY_SIZE];
    try testing.expectEqualSlices(u8, "main\x00\x00\x00\x00", sym[0..8]);
    try testing.expectEqual(@as(u32, 0), readU32(sym, 8)); // Value
    try testing.expectEqual(@as(u16, 1), readU16(sym, 12)); // SectionNumber: 1st (only) section
    try testing.expectEqual(@as(u16, IMAGE_SYM_TYPE_FUNCTION), readU16(sym, 14));
    try testing.expectEqual(@as(u8, IMAGE_SYM_CLASS_EXTERNAL), sym[16]);
}

test "call to an undefined runtime symbol adds an external symbol at section 0" {
    const code = [_]u8{ 0xE8, 0, 0, 0, 0 };
    var symbols = [_]Symbol{
        .{ .name = "main", .section = .text, .offset = 0, .size = code.len, .binding = .global, .kind = .func },
        .{ .name = "bit_rt_alloc", .section = null, .binding = .global },
    };
    var relocs = [_]Relocation{.{ .section = .text, .offset = 1, .symbol = "bit_rt_alloc", .kind = .pc32 }};
    var sections = [_]Section{.{ .kind = .text, .data = &code, .alignment = 16 }};
    const bytes = try write(testing.allocator, .x86_64, .{ .sections = &sections, .symbols = &symbols, .relocations = &relocs });
    defer testing.allocator.free(bytes);

    const symtab_start = readU32(bytes, 8);
    const ext_sym = bytes[symtab_start + SYMBOL_ENTRY_SIZE ..][0..SYMBOL_ENTRY_SIZE];
    try testing.expectEqual(@as(u32, 0), readU32(ext_sym, 0)); // zero word: name lives in strtab
    try testing.expectEqual(@as(u16, IMAGE_SYM_UNDEFINED), readU16(ext_sym, 12));

    const sect = bytes[FILE_HEADER_SIZE..][0..SECTION_HEADER_SIZE];
    try testing.expectEqual(@as(u16, 1), readU16(sect, 32)); // NumberOfRelocations
    const reloc_start = readU32(sect, 24);
    const reloc = bytes[reloc_start..][0..RELOC_ENTRY_SIZE];
    try testing.expectEqual(@as(u32, 1), readU32(reloc, 0)); // VirtualAddress
    try testing.expectEqual(@as(u32, 1), readU32(reloc, 4)); // SymbolTableIndex: "bit_rt_alloc" is symbol 1
    try testing.expectEqual(@as(u16, 0x0004), readU16(reloc, 8)); // IMAGE_REL_AMD64_REL32
}

test "data/rodata/bss/gc_meta all round-trip through std.coff's own field layout" {
    const code = [_]u8{ 0x55, 0xC3 };
    const rodata = "hello\n";
    const data = [_]u8{0} ** 8;
    const gc = [_]u8{0xAB} ** 8;
    var symbols = [_]Symbol{
        .{ .name = "main", .section = .text, .size = code.len, .binding = .global, .kind = .func },
        .{ .name = "msg", .section = .rodata, .size = rodata.len, .binding = .local },
        .{ .name = "counter", .section = .data, .size = data.len, .binding = .global, .kind = .object },
        .{ .name = "buf", .section = .bss, .size = 64, .binding = .local },
        .{ .name = "bit_type_info$Foo", .section = .gc_meta, .size = gc.len, .binding = .local },
    };
    var relocs = [_]Relocation{.{ .section = .data, .offset = 0, .symbol = "msg", .kind = .abs64 }};
    var sections = [_]Section{
        .{ .kind = .text, .data = &code, .alignment = 16 },
        .{ .kind = .data, .data = &data, .alignment = 8 },
        .{ .kind = .rodata, .data = rodata, .alignment = 1 },
        .{ .kind = .bss, .size = 64, .alignment = 8 },
        .{ .kind = .gc_meta, .data = &gc, .alignment = 8 },
    };
    const bytes = try write(testing.allocator, .x86_64, .{ .sections = &sections, .symbols = &symbols, .relocations = &relocs });
    defer testing.allocator.free(bytes);

    const c: coff.Coff = .{ .data = bytes, .is_loaded = false, .is_image = false, .coff_header_offset = 0 };
    const header = c.getHeader();
    try testing.expectEqual(coff.IMAGE.FILE.MACHINE.AMD64, header.machine);
    try testing.expectEqual(@as(u16, 5), header.number_of_sections);
    try testing.expectEqual(@as(u32, 5), header.number_of_symbols);

    const sections_out = c.getSectionHeaders();
    try testing.expectEqual(@as(usize, 5), sections_out.len);
    try testing.expectEqualStrings(".text", sections_out[0].getName().?);
    try testing.expectEqualStrings(".data", sections_out[1].getName().?);
    try testing.expectEqualStrings(".rdata", sections_out[2].getName().?);
    try testing.expectEqualStrings(".bss", sections_out[3].getName().?);
    try testing.expectEqualStrings(".bit_gc", sections_out[4].getName().?);
    try testing.expect(sections_out[0].isCode());
    // `.bss` carries a size but no file bytes: PointerToRawData is 0.
    try testing.expectEqual(@as(u32, 64), sections_out[3].size_of_raw_data);
    try testing.expectEqual(@as(u32, 0), sections_out[3].pointer_to_raw_data);
    // `getSectionData`/`Alloc` key off `virtual_size`, an image-only field
    // (always 0 in an object file per this writer, matching real toolchains);
    // for objects the raw bytes live at `pointer_to_raw_data`/`size_of_raw_data`.
    const data_sect = sections_out[1];
    try testing.expectEqualSlices(u8, &data, bytes[data_sect.pointer_to_raw_data..][0..data_sect.size_of_raw_data]);

    const symtab = c.getSymtab().?;
    try testing.expectEqual(@as(usize, 5), symtab.len());
    const counter = symtab.at(2, .symbol).symbol;
    try testing.expectEqualStrings("counter", counter.getName().?);
    try testing.expectEqual(@as(u16, 2), @intFromEnum(counter.section_number));
}

test "aarch64: BRANCH26/PAGEBASE_REL21/PAGEOFFSET_12A/ADDR64 all encode and round-trip" {
    // adrp x1, msg ; add x1, x1, msg ; bl callee
    const code = [_]u8{
        0x01, 0x00, 0x00, 0x90,
        0x21, 0x00, 0x00, 0x91,
        0x00, 0x00, 0x00, 0x94,
    };
    const ptr = [_]u8{0} ** 8;
    var symbols = [_]Symbol{
        .{ .name = "start", .section = .text, .size = code.len, .binding = .global, .kind = .func },
        .{ .name = "msg", .section = .rodata, .size = 4, .binding = .local },
        .{ .name = "callee", .section = null, .binding = .global },
        .{ .name = "vt", .section = .data, .size = ptr.len, .binding = .global },
    };
    var relocs = [_]Relocation{
        .{ .section = .text, .offset = 0, .symbol = "msg", .kind = .aarch64_adr_prel_pg_hi21 },
        .{ .section = .text, .offset = 4, .symbol = "msg", .kind = .aarch64_add_abs_lo12_nc },
        .{ .section = .text, .offset = 8, .symbol = "callee", .kind = .aarch64_call26 },
        .{ .section = .data, .offset = 0, .symbol = "msg", .kind = .abs64 },
    };
    var sections = [_]Section{
        .{ .kind = .text, .data = &code, .alignment = 4 },
        .{ .kind = .data, .data = &ptr, .alignment = 8 },
        .{ .kind = .rodata, .data = "msg\x00", .alignment = 4 },
    };
    const bytes = try write(testing.allocator, .aarch64, .{ .sections = &sections, .symbols = &symbols, .relocations = &relocs });
    defer testing.allocator.free(bytes);

    const c: coff.Coff = .{ .data = bytes, .is_loaded = false, .is_image = false, .coff_header_offset = 0 };
    try testing.expectEqual(coff.IMAGE.FILE.MACHINE.ARM64, c.getHeader().machine);

    const text_sect = c.getSectionByName(".text").?;
    try testing.expectEqual(@as(u16, 3), text_sect.number_of_relocations);
    const relocs_off = text_sect.pointer_to_relocations;
    try testing.expectEqual(@as(u16, @intFromEnum(coff.IMAGE.REL.ARM64.PAGEBASE_REL21)), readU16(bytes, relocs_off + 8));
    try testing.expectEqual(@as(u16, @intFromEnum(coff.IMAGE.REL.ARM64.PAGEOFFSET_12A)), readU16(bytes, relocs_off + RELOC_ENTRY_SIZE + 8));
    try testing.expectEqual(@as(u16, @intFromEnum(coff.IMAGE.REL.ARM64.BRANCH26)), readU16(bytes, relocs_off + 2 * RELOC_ENTRY_SIZE + 8));

    const data_sect = c.getSectionByName(".data").?;
    try testing.expectEqual(@as(u16, 1), data_sect.number_of_relocations);
    try testing.expectEqual(@as(u16, @intFromEnum(coff.IMAGE.REL.ARM64.ADDR64)), readU16(bytes, data_sect.pointer_to_relocations + 8));
}

test "a pc32 reloc unsupported on aarch64 is rejected, not silently dropped" {
    const code = [_]u8{ 0, 0, 0, 0 };
    var symbols = [_]Symbol{
        .{ .name = "f", .section = .text, .size = code.len, .binding = .global, .kind = .func },
        .{ .name = "g", .section = null, .binding = .global },
    };
    var relocs = [_]Relocation{.{ .section = .text, .offset = 0, .symbol = "g", .kind = .pc32 }};
    var sections = [_]Section{.{ .kind = .text, .data = &code, .alignment = 4 }};
    try testing.expectError(error.RelocKindUnsupportedForTarget, write(testing.allocator, .aarch64, .{ .sections = &sections, .symbols = &symbols, .relocations = &relocs }));
}

test "two sections claiming the same kind is rejected" {
    var sections = [_]Section{ .{ .kind = .text }, .{ .kind = .text } };
    try testing.expectError(error.DuplicateSection, write(testing.allocator, .x86_64, .{ .sections = &sections }));
}

test "a local symbol with no defining section is rejected" {
    var symbols = [_]Symbol{.{ .name = "x", .section = null, .binding = .local }};
    try testing.expectError(error.UndefinedLocalSymbol, write(testing.allocator, .x86_64, .{ .sections = &.{}, .symbols = &symbols }));
}

test "symbol name longer than 8 bytes spills into the string table" {
    const code = [_]u8{0xC3};
    const long_name = "a_very_long_bit_function_name";
    var symbols = [_]Symbol{.{ .name = long_name, .section = .text, .size = code.len, .binding = .global, .kind = .func }};
    var sections = [_]Section{.{ .kind = .text, .data = &code, .alignment = 16 }};
    const bytes = try write(testing.allocator, .x86_64, .{ .sections = &sections, .symbols = &symbols });
    defer testing.allocator.free(bytes);

    const c: coff.Coff = .{ .data = bytes, .is_loaded = false, .is_image = false, .coff_header_offset = 0 };
    const symtab = c.getSymtab().?;
    const strtab = (try c.getStrtab()).?;
    const sym = symtab.at(0, .symbol).symbol;
    try testing.expectEqualStrings(long_name, strtab.get(sym.getNameOffset().?));
}
