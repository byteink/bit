//! PE/COFF object writer (task #344): turns compiled `x64.FuncCode`s into a
//! relocatable Windows `.obj` that MSVC `link.exe`/LLVM `lld-link` can
//! consume. Format: Microsoft PE Format spec, "COFF File Header (Object and
//! Image)" through "COFF Relocations (Object Only)" — no optional header, no
//! section-data directory, since none of that applies to object files.
//!
//! Scope matches what `x64.zig` actually emits today (see its module doc
//! comment and `codegen/common.zig`'s `Reloc`): one `.text` section holding
//! every function's code back to back, plus an `IMAGE_REL_AMD64_REL32`
//! relocation per call site. There is no data/bss section because nothing in
//! the current codegen lowers to static data yet (`const_string`, `gc_alloc`
//! both still return `error.UnsupportedConstruct`) — add one the day a
//! backend starts emitting initialized data.
//!
//! Every defined function becomes an `IMAGE_SYM_CLASS_EXTERNAL` symbol (the
//! static linker, #345, resolves cross-object calls by name); every call
//! target not defined in this module becomes an external symbol with
//! `IMAGE_SYM_UNDEFINED` section number, resolved at link time against
//! another Bit object or `libbitrt.a`.

const std = @import("std");
const x64 = @import("../codegen/x64.zig");

const Allocator = std.mem.Allocator;

const IMAGE_FILE_MACHINE_AMD64: u16 = 0x8664;

/// `.text`: code + initialized, readable, executable, 16-byte aligned.
const TEXT_SECTION_FLAGS: u32 =
    0x00000020 | // IMAGE_SCN_CNT_CODE
    0x00500000 | // IMAGE_SCN_ALIGN_16BYTES
    0x20000000 | // IMAGE_SCN_MEM_EXECUTE
    0x40000000; // IMAGE_SCN_MEM_READ

const IMAGE_REL_AMD64_REL32: u16 = 0x0004;
const IMAGE_SYM_CLASS_EXTERNAL: u8 = 2;
/// Complex type FUNCTION (0x20) | base type NULL (0x00) — the value MS
/// tools write for any symbol that names a function, defined or not.
const IMAGE_SYM_TYPE_FUNCTION: u16 = 0x0020;
/// Section number for a not-yet-resolved external symbol.
const IMAGE_SYM_UNDEFINED: u16 = 0;
/// 1-based index of `.text`, the only section this writer emits.
const TEXT_SECTION_NUMBER: u16 = 1;

const FILE_HEADER_SIZE: u32 = 20;
const SECTION_HEADER_SIZE: u32 = 40;
const RELOC_ENTRY_SIZE: u32 = 10;
const SYMBOL_ENTRY_SIZE: u32 = 18;
const TEXT_ALIGN: u32 = 16;

pub const Error = Allocator.Error || error{
    /// COFF's `NumberOfRelocations` is a `u16`; a section needing more than
    /// 65535 requires the `IMAGE_SCN_LNK_NRELOC_OVFL` extended-count scheme,
    /// which this writer doesn't implement (no real Bit module comes close).
    TooManyRelocations,
};

/// One entry in the symbol table being built: a Bit function's own name
/// (`defined`, `text_offset` meaningful) or an external reference resolved
/// at link time (another Bit function or a `bit_rt_*` runtime symbol).
const Sym = struct {
    name: []const u8,
    defined: bool,
    text_offset: u32,
};

const RelocOut = struct {
    virtual_address: u32,
    symbol_index: u32,
};

/// Emits a COFF object containing every function in `funcs` into `.text`.
/// Caller owns the returned buffer (`gpa.free`).
pub fn write(gpa: Allocator, funcs: []const x64.FuncCode) Error![]u8 {
    // ---- 1. Lay out `.text`: functions back to back, record start offsets.
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    const text_offsets = try gpa.alloc(u32, funcs.len);
    defer gpa.free(text_offsets);
    for (funcs, 0..) |f, i| {
        text_offsets[i] = @intCast(text.items.len);
        try text.appendSlice(gpa, f.code);
    }

    // ---- 2. Symbol table: every defined function first (a full pass before
    // any reloc is examined, so a call to a function defined *later* in
    // `funcs` still resolves to a defined symbol, not a spurious external),
    // then every distinct external symbol a relocation refers to.
    var syms: std.ArrayList(Sym) = .empty;
    defer syms.deinit(gpa);
    var sym_index: std.StringHashMapUnmanaged(u32) = .empty;
    defer sym_index.deinit(gpa);

    for (funcs, 0..) |f, i| {
        try sym_index.put(gpa, f.name, @intCast(syms.items.len));
        try syms.append(gpa, .{ .name = f.name, .defined = true, .text_offset = text_offsets[i] });
    }
    for (funcs) |f| {
        for (f.relocs) |r| {
            if (sym_index.contains(r.symbol)) continue;
            try sym_index.put(gpa, r.symbol, @intCast(syms.items.len));
            try syms.append(gpa, .{ .name = r.symbol, .defined = false, .text_offset = 0 });
        }
    }

    // ---- 3. Relocations, in function order, `VirtualAddress` relative to
    // the start of `.text` (a call's reloc offset is relative to its own
    // function's code, per `x64.zig`'s `FuncCode.relocs` doc comment).
    var relocs: std.ArrayList(RelocOut) = .empty;
    defer relocs.deinit(gpa);
    for (funcs, 0..) |f, i| {
        for (f.relocs) |r| {
            try relocs.append(gpa, .{
                .virtual_address = text_offsets[i] + r.offset,
                .symbol_index = sym_index.get(r.symbol).?,
            });
        }
    }
    if (relocs.items.len > std.math.maxInt(u16)) return error.TooManyRelocations;

    // ---- 4. String table: COFF's inline `Symbol.Name[8]` can't hold a name
    // longer than 8 bytes, so those go here instead — a 4-byte size prefix
    // (self-inclusive) followed by NUL-terminated names; offset 0 is
    // reserved (never valid) so a short name's `str_offsets` entry of 0
    // doubles as "use the inline Name[8] field".
    var strtab: std.ArrayList(u8) = .empty;
    defer strtab.deinit(gpa);
    try strtab.appendSlice(gpa, &.{ 0, 0, 0, 0 }); // patched once final size is known
    const str_offsets = try gpa.alloc(u32, syms.items.len);
    defer gpa.free(str_offsets);
    for (syms.items, 0..) |s, i| {
        if (s.name.len <= 8) {
            str_offsets[i] = 0;
            continue;
        }
        str_offsets[i] = @intCast(strtab.items.len);
        try strtab.appendSlice(gpa, s.name);
        try strtab.append(gpa, 0);
    }
    std.mem.writeInt(u32, strtab.items[0..4], @intCast(strtab.items.len), .little);

    // ---- 5. File layout. Header + one section header is already a multiple
    // of 4, but compute generically rather than assume it.
    const header_end = FILE_HEADER_SIZE + SECTION_HEADER_SIZE;
    const text_start = std.mem.alignForward(u32, header_end, TEXT_ALIGN);
    const reloc_start = text_start + @as(u32, @intCast(text.items.len));
    const reloc_size = @as(u32, @intCast(relocs.items.len)) * RELOC_ENTRY_SIZE;
    const symtab_start = reloc_start + reloc_size;
    const symtab_size = @as(u32, @intCast(syms.items.len)) * SYMBOL_ENTRY_SIZE;
    const strtab_start = symtab_start + symtab_size;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    // ---- File header (IMAGE_FILE_HEADER, no optional header: object file).
    try appendU16(&out, gpa, IMAGE_FILE_MACHINE_AMD64);
    try appendU16(&out, gpa, 1); // NumberOfSections
    try appendU32(&out, gpa, 0); // TimeDateStamp: 0 for reproducible builds
    try appendU32(&out, gpa, if (syms.items.len == 0) 0 else symtab_start);
    try appendU32(&out, gpa, @intCast(syms.items.len));
    try appendU16(&out, gpa, 0); // SizeOfOptionalHeader
    try appendU16(&out, gpa, 0); // Characteristics

    // ---- Section header: `.text`.
    const text_name = paddedName8(".text");
    try out.appendSlice(gpa, &text_name);
    try appendU32(&out, gpa, 0); // VirtualSize: unused in object files
    try appendU32(&out, gpa, 0); // VirtualAddress: unused in object files
    try appendU32(&out, gpa, @intCast(text.items.len));
    try appendU32(&out, gpa, if (text.items.len == 0) 0 else text_start);
    try appendU32(&out, gpa, if (relocs.items.len == 0) 0 else reloc_start);
    try appendU32(&out, gpa, 0); // PointerToLinenumbers: deprecated
    try appendU16(&out, gpa, @intCast(relocs.items.len));
    try appendU16(&out, gpa, 0); // NumberOfLinenumbers: deprecated
    try appendU32(&out, gpa, TEXT_SECTION_FLAGS);

    std.debug.assert(out.items.len <= text_start);
    try out.appendNTimes(gpa, 0, text_start - out.items.len);

    // ---- `.text` raw data.
    try out.appendSlice(gpa, text.items);

    // ---- Relocations.
    for (relocs.items) |r| {
        try appendU32(&out, gpa, r.virtual_address);
        try appendU32(&out, gpa, r.symbol_index);
        try appendU16(&out, gpa, IMAGE_REL_AMD64_REL32);
    }

    // ---- Symbol table.
    for (syms.items, 0..) |s, i| {
        if (s.name.len <= 8) {
            const name_buf = paddedName8(s.name);
            try out.appendSlice(gpa, &name_buf);
        } else {
            try appendU32(&out, gpa, 0);
            try appendU32(&out, gpa, str_offsets[i]);
        }
        try appendU32(&out, gpa, s.text_offset); // Value
        try appendU16(&out, gpa, if (s.defined) TEXT_SECTION_NUMBER else IMAGE_SYM_UNDEFINED);
        try appendU16(&out, gpa, IMAGE_SYM_TYPE_FUNCTION);
        try out.append(gpa, IMAGE_SYM_CLASS_EXTERNAL);
        try out.append(gpa, 0); // NumberOfAuxSymbols
    }

    // ---- String table.
    try out.appendSlice(gpa, strtab.items);

    std.debug.assert(out.items.len == strtab_start + strtab.items.len);
    return out.toOwnedSlice(gpa);
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

fn fakeFunc(name: []const u8, code: []const u8, relocs: []const x64.Reloc) x64.FuncCode {
    return .{
        .gpa = testing.allocator,
        .name = name,
        .code = @constCast(code),
        .relocs = @constCast(relocs),
        .safepoints = &.{},
        .frame_size = 0,
    };
}

test "empty module: valid header, zero sections worth of content, no symtab" {
    const bytes = try write(testing.allocator, &.{});
    defer testing.allocator.free(bytes);

    try testing.expectEqual(@as(u16, IMAGE_FILE_MACHINE_AMD64), readU16(bytes, 0));
    try testing.expectEqual(@as(u16, 1), readU16(bytes, 2)); // NumberOfSections
    try testing.expectEqual(@as(u32, 0), readU32(bytes, 8)); // PointerToSymbolTable
    try testing.expectEqual(@as(u32, 0), readU32(bytes, 12)); // NumberOfSymbols

    const sect = bytes[FILE_HEADER_SIZE..][0..SECTION_HEADER_SIZE];
    try testing.expectEqualSlices(u8, ".text\x00\x00\x00", sect[0..8]);
    try testing.expectEqual(@as(u32, 0), readU32(sect, 16)); // SizeOfRawData
    try testing.expectEqual(@as(u32, 0), readU32(sect, 20)); // PointerToRawData
    try testing.expectEqual(@as(u32, 0), readU32(sect, 24)); // PointerToRelocations
    try testing.expectEqual(@as(u16, 0), readU16(sect, 32)); // NumberOfRelocations
}

test "one defined function, no relocs: symbol points at its .text offset" {
    const code = [_]u8{ 0x55, 0xC3 }; // push rbp; ret
    var funcs = [_]x64.FuncCode{fakeFunc("main", &code, &.{})};
    const bytes = try write(testing.allocator, &funcs);
    defer testing.allocator.free(bytes);

    const sect = bytes[FILE_HEADER_SIZE..][0..SECTION_HEADER_SIZE];
    const text_start = readU32(sect, 20);
    try testing.expectEqualSlices(u8, &code, bytes[text_start..][0..code.len]);

    const symtab_start = readU32(bytes, 8);
    try testing.expectEqual(@as(u32, 1), readU32(bytes, 12)); // NumberOfSymbols
    const sym = bytes[symtab_start..][0..SYMBOL_ENTRY_SIZE];
    try testing.expectEqualSlices(u8, "main\x00\x00\x00\x00", sym[0..8]);
    try testing.expectEqual(@as(u32, 0), readU32(sym, 8)); // Value: offset 0 in .text
    try testing.expectEqual(@as(u16, TEXT_SECTION_NUMBER), readU16(sym, 12));
    try testing.expectEqual(@as(u16, IMAGE_SYM_TYPE_FUNCTION), readU16(sym, 14));
    try testing.expectEqual(@as(u8, IMAGE_SYM_CLASS_EXTERNAL), sym[16]);
}

test "call to another function in this module resolves as defined, not external" {
    const caller_code = [_]u8{ 0xE8, 0, 0, 0, 0 }; // call rel32 (patched by linker)
    const callee_code = [_]u8{0xC3}; // ret
    var funcs = [_]x64.FuncCode{
        fakeFunc("caller", &caller_code, &.{.{ .offset = 1, .symbol = "callee" }}),
        fakeFunc("callee", &callee_code, &.{}),
    };
    const bytes = try write(testing.allocator, &funcs);
    defer testing.allocator.free(bytes);

    try testing.expectEqual(@as(u32, 2), readU32(bytes, 12)); // NumberOfSymbols: no external added

    const sect = bytes[FILE_HEADER_SIZE..][0..SECTION_HEADER_SIZE];
    try testing.expectEqual(@as(u16, 1), readU16(sect, 32)); // NumberOfRelocations
    const reloc_start = readU32(sect, 24);
    const reloc = bytes[reloc_start..][0..RELOC_ENTRY_SIZE];
    try testing.expectEqual(@as(u32, 1), readU32(reloc, 0)); // VirtualAddress: caller's offset (0) + 1
    try testing.expectEqual(@as(u32, 1), readU32(reloc, 4)); // SymbolTableIndex: "callee" is symbol 1
    try testing.expectEqual(@as(u16, IMAGE_REL_AMD64_REL32), readU16(reloc, 8));

    const symtab_start = readU32(bytes, 8);
    const callee_sym = bytes[symtab_start + SYMBOL_ENTRY_SIZE ..][0..SYMBOL_ENTRY_SIZE];
    try testing.expectEqual(@as(u16, TEXT_SECTION_NUMBER), readU16(callee_sym, 12));
}

test "call to an undefined runtime symbol adds an external symbol at section 0" {
    const code = [_]u8{ 0xE8, 0, 0, 0, 0 };
    var funcs = [_]x64.FuncCode{
        fakeFunc("main", &code, &.{.{ .offset = 1, .symbol = "rt_alloc" }}), // 8 bytes: fits inline, no strtab
    };
    const bytes = try write(testing.allocator, &funcs);
    defer testing.allocator.free(bytes);

    try testing.expectEqual(@as(u32, 2), readU32(bytes, 12));
    const symtab_start = readU32(bytes, 8);
    const ext_sym = bytes[symtab_start + SYMBOL_ENTRY_SIZE ..][0..SYMBOL_ENTRY_SIZE];
    try testing.expectEqualSlices(u8, "rt_alloc", ext_sym[0..8]);
    try testing.expectEqual(@as(u32, 0), readU32(ext_sym, 8)); // Value
    try testing.expectEqual(@as(u16, IMAGE_SYM_UNDEFINED), readU16(ext_sym, 12));
    try testing.expectEqual(@as(u8, IMAGE_SYM_CLASS_EXTERNAL), ext_sym[16]);
}

test "symbol name longer than 8 bytes spills into the string table" {
    const code = [_]u8{0xC3};
    const long_name = "a_very_long_bit_function_name";
    var funcs = [_]x64.FuncCode{fakeFunc(long_name, &code, &.{})};
    const bytes = try write(testing.allocator, &funcs);
    defer testing.allocator.free(bytes);

    const symtab_start = readU32(bytes, 8);
    const sym = bytes[symtab_start..][0..SYMBOL_ENTRY_SIZE];
    try testing.expectEqual(@as(u32, 0), readU32(sym, 0)); // zero word marks "look in strtab"
    const name_off = readU32(sym, 4);

    const strtab_start = symtab_start + SYMBOL_ENTRY_SIZE;
    const strtab_size = readU32(bytes, strtab_start);
    try testing.expectEqual(@as(usize, strtab_size), bytes.len - strtab_start);
    const name_ptr = bytes[strtab_start + name_off ..];
    const end = std.mem.indexOfScalar(u8, name_ptr, 0).?;
    try testing.expectEqualStrings(long_name, name_ptr[0..end]);
}

test "round-trips through std.coff's own field layout" {
    const code = [_]u8{ 0x55, 0xC3 };
    var funcs = [_]x64.FuncCode{
        fakeFunc("a_very_long_bit_function_name", &code, &.{.{ .offset = 0, .symbol = "bit_rt_safepoint" }}),
    };
    const bytes = try write(testing.allocator, &funcs);
    defer testing.allocator.free(bytes);

    const coff: std.coff.Coff = .{ .data = bytes, .is_loaded = false, .is_image = false, .coff_header_offset = 0 };
    const header = coff.getHeader();
    try testing.expectEqual(std.coff.IMAGE.FILE.MACHINE.AMD64, header.machine);
    try testing.expectEqual(@as(u16, 1), header.number_of_sections);
    try testing.expectEqual(@as(u32, 2), header.number_of_symbols);

    const sections = coff.getSectionHeaders();
    try testing.expectEqual(@as(usize, 1), sections.len);
    try testing.expectEqualStrings(".text", sections[0].getName().?);
    try testing.expect(sections[0].isCode());

    const symtab = coff.getSymtab().?;
    try testing.expectEqual(@as(usize, 2), symtab.len());
    const strtab = (try coff.getStrtab()).?;
    const first = symtab.at(0, .symbol).symbol;
    try testing.expectEqualStrings("a_very_long_bit_function_name", strtab.get(first.getNameOffset().?));
}
