//! PE/COFF relocatable object reader (task #1103, closing out #345's
//! remaining scope): parses whatever `obj/pe.zig` emits back into
//! `link/object.zig`'s generic `Module`/`Atom` IR via `atomizeModule` — the
//! Windows sibling of `link/elf_reader.zig`/`link/macho_reader.zig`.
//!
//! Built on `std.coff.Coff`, the same parser `obj/pe.zig`'s own tests use to
//! validate its output, rather than a hand-rolled byte decoder — it already
//! normalizes the COFF header/section-table/symbol-table layout and is
//! exercised elsewhere in this codebase (`seed/lsp.zig`'s PDB path is
//! unrelated; the relevant precedent is `obj/pe.zig`'s test block).
//!
//! Scope is deliberately "whatever `obj/pe.zig` itself emits", verified by
//! round-tripping through it in this file's tests — there is no Windows
//! toolchain or real `libbitrt.a` Windows build available in this
//! environment to widen the scope against (contrast `elf_reader.zig`'s test
//! against a real `zig build libbitrt` output, and `macho_reader.zig`'s
//! against a real Mach-O `libbitrt.a`). Two real-toolchain shapes this
//! reader deliberately does NOT support, and fails loudly on rather than
//! guessing: COMDAT/section-definition symbols (`IMAGE_SYM_CLASS_SECTION`,
//! never emitted by `obj/pe.zig`) and weak externals
//! (`IMAGE_SYM_CLASS_WEAK_EXTERNAL`, likewise). Both are `error.UnsupportedSymbol`.

const std = @import("std");
const coff = std.coff;
const Allocator = std.mem.Allocator;
const object = @import("object.zig");

pub const Target = enum {
    x86_64,
    aarch64,

    fn machine(self: Target) coff.IMAGE.FILE.MACHINE {
        return switch (self) {
            .x86_64 => .AMD64,
            .aarch64 => .ARM64,
        };
    }

    /// Same reasoning as `elf_reader.Target.minTextAlign`: AArch64 instruction
    /// fetch faults on a misaligned PC, x86-64 has no such requirement.
    fn minTextAlign(self: Target) u32 {
        return switch (self) {
            .x86_64 => 1,
            .aarch64 => 4,
        };
    }
};

pub const Error = error{
    OutOfMemory,
    Truncated,
    /// Wrong machine type, or carries a nonzero `SizeOfOptionalHeader` — an
    /// image (or another COFF variant this reader doesn't support), not the
    /// plain relocatable object this reader parses.
    UnsupportedCoff,
    Malformed,
    UnsupportedSymbol,
    UnsupportedRelocation,
    NoCoveringSymbol,
};

pub fn read(gpa: Allocator, target: Target, name: []const u8, bytes: []const u8) Error!object.Module {
    if (bytes.len < FILE_HEADER_SIZE) return error.Truncated;
    // Deliberately NOT `coff.Coff.init`: that constructor's `is_image`
    // detection peeks a `PE\0\0` signature at a file offset read out of bytes
    // [0x3C..0x40), a convention that exists ONLY for images (`e_lfanew` in
    // the DOS header). A bare relocatable object has no DOS header at all, so
    // those four bytes are just whatever this writer happened to place there
    // — ordinary section-table content — and reading them as a jump target
    // spuriously reports `EndOfStream` on a perfectly well-formed object
    // whenever that content forms a large value. `obj/pe.zig`'s own tests
    // sidestep this the same way: an object's COFF header always starts at
    // file offset 0, so that is supplied directly rather than "discovered".
    const c: coff.Coff = .{ .data = bytes, .is_loaded = false, .is_image = false, .coff_header_offset = 0 };
    const header = c.getHeader();
    if (header.machine != target.machine()) return error.UnsupportedCoff;
    // A relocatable object carries no optional header at all (`obj/pe.zig`'s
    // module doc comment: "no optional header ... since none of that applies
    // to object files"). An image (or any format variant that does carry
    // one) is refused here rather than misread as an object.
    if (header.size_of_optional_header != 0) return error.UnsupportedCoff;

    // `Coff.getSectionHeaders`/`getSymtab` slice `data` at these offsets with
    // no bounds check of their own (a raw pointer cast, in the section-header
    // case) — validate both ranges ourselves before trusting either.
    const sh_off: u64 = FILE_HEADER_SIZE + @as(u64, header.size_of_optional_header);
    if (sh_off + @as(u64, header.number_of_sections) * SECTION_HEADER_SIZE > bytes.len) return error.Truncated;
    if (@as(u64, header.pointer_to_symbol_table) + @as(u64, header.number_of_symbols) * SYMBOL_ENTRY_SIZE > bytes.len) return error.Truncated;

    const shdrs = c.getSectionHeaders();

    var raw_sections: std.ArrayList(object.RawSection) = .empty;
    defer raw_sections.deinit(gpa);
    const section_map = try gpa.alloc(?u32, shdrs.len);
    defer gpa.free(section_map);
    @memset(section_map, null);

    for (shdrs, 0..) |sh, i| {
        const sec_name = c.getSectionName(&sh) catch return error.Malformed;
        const kind = classify(sec_name, sh.flags) orelse continue;
        section_map[i] = @intCast(raw_sections.items.len);
        const sec_align: u32 = sh.getAlignment() orelse 1;
        try raw_sections.append(gpa, .{
            .name = sec_name,
            .kind = kind,
            .data = if (kind.isBss()) &.{} else try sectionBytes(bytes, sh),
            .size = sh.size_of_raw_data,
            .alignment = if (kind == .text) @max(sec_align, target.minTextAlign()) else sec_align,
        });
    }

    // ---- symbol table: one pass, skipping each symbol's own aux records ----
    const SymInfo = union(enum) {
        undefined_: []const u8,
        raw: u32, // index into raw_symbols
        ignored, // aux record slot, or a class this reader refuses
    };
    const sym_count = header.number_of_symbols;
    const sym_infos = try gpa.alloc(SymInfo, sym_count);
    defer gpa.free(sym_infos);

    var raw_symbols: std.ArrayList(object.RawSymbol) = .empty;
    defer raw_symbols.deinit(gpa);

    const symtab = c.getSymtab();
    const strtab = c.getStrtab() catch return error.Malformed;
    if (sym_count > 0 and symtab == null) return error.Malformed;

    var i: u32 = 0;
    while (i < sym_count) {
        const sym = symtab.?.at(i, .symbol).symbol;
        const aux = sym.number_of_aux_symbols;
        if (@as(u64, i) + 1 + aux > sym_count) return error.Malformed;

        // NOT `sym.getName()`: for an inline (<=8 byte) name it returns a
        // slice into `sym.name`, a byte array living in THIS loop's local
        // `sym` copy (`Symtab.at` returns `Record` by value) — storing that
        // slice into `raw_symbols` below would dangle the moment the next
        // iteration reuses the stack slot. Slice the real file buffer at the
        // symbol's own offset instead; the string-table path is unaffected
        // (`Strtab.get` already slices `c.data`, a real subrange of `bytes`).
        const sym_name = try symbolNameAt(header, bytes, i, strtab);

        switch (sym.section_number) {
            .UNDEFINED => sym_infos[i] = .{ .undefined_ = sym_name },
            .ABSOLUTE, .DEBUG => return error.UnsupportedSymbol,
            else => |sn| {
                const sec_idx = @as(u32, @intFromEnum(sn)) - 1; // 1-based
                if (sec_idx >= shdrs.len) return error.Malformed;
                switch (sym.storage_class) {
                    .EXTERNAL, .STATIC => {
                        if (section_map[sec_idx]) |mapped| {
                            const text_align = target.minTextAlign();
                            const sec_align: u32 = shdrs[sec_idx].getAlignment() orelse 1;
                            const alignment = if (raw_sections.items[mapped].kind == .text) @max(sec_align, text_align) else sec_align;
                            sym_infos[i] = .{ .raw = @intCast(raw_symbols.items.len) };
                            try raw_symbols.append(gpa, .{
                                .name = sym_name,
                                .section = mapped,
                                .offset = sym.value,
                                // COFF's regular `IMAGE_SYMBOL.Value` carries
                                // no size; `atomizeModule` infers extent from
                                // the next symbol's offset (same as Mach-O
                                // `nlist`).
                                .size = 0,
                                .binding = if (sym.storage_class == .EXTERNAL) .global else .local,
                                .alignment = alignment,
                            });
                        } else {
                            sym_infos[i] = .ignored;
                        }
                    },
                    // `SECTION` (COMDAT/section-definition) and
                    // `WEAK_EXTERNAL` are real COFF shapes this writer never
                    // produces and this reader does not attempt to guess at
                    // (module doc comment) — refuse loudly rather than
                    // silently misresolving a relocation into one.
                    .SECTION, .WEAK_EXTERNAL => return error.UnsupportedSymbol,
                    else => sym_infos[i] = .ignored,
                }
            },
        }
        var j: u32 = 0;
        while (j < aux) : (j += 1) sym_infos[i + 1 + j] = .ignored;
        i += 1 + aux;
    }

    // ---- relocations: one contiguous run per section header ---------------
    var raw_relocs: std.ArrayList(object.RawReloc) = .empty;
    defer raw_relocs.deinit(gpa);

    for (shdrs, 0..) |sh, sec_idx| {
        if (sh.number_of_relocations == 0) continue;
        const owner = section_map[sec_idx] orelse continue; // target section dropped: its relocs are moot
        if (@as(u64, sh.pointer_to_relocations) + @as(u64, sh.number_of_relocations) * RELOC_ENTRY_SIZE > bytes.len) return error.Truncated;

        var r: u16 = 0;
        while (r < sh.number_of_relocations) : (r += 1) {
            const off = sh.pointer_to_relocations + @as(u32, r) * RELOC_ENTRY_SIZE;
            const va = std.mem.readInt(u32, bytes[off..][0..4], .little);
            const sym_idx = std.mem.readInt(u32, bytes[off + 4 ..][0..4], .little);
            const rtype = std.mem.readInt(u16, bytes[off + 8 ..][0..2], .little);
            if (sym_idx >= sym_count) return error.Malformed;

            const kind_addend = try relocKind(target, rtype);
            const info = sym_infos[sym_idx];
            switch (info) {
                .ignored => return error.Malformed,
                .undefined_ => |sym_name| try raw_relocs.append(gpa, .{
                    .section = owner,
                    .offset = va,
                    .kind = kind_addend.kind,
                    .target = .{ .global = sym_name },
                    .addend = kind_addend.addend,
                }),
                .raw => |raw_idx| {
                    const target_binding = raw_symbols.items[raw_idx].binding;
                    try raw_relocs.append(gpa, .{
                        .section = owner,
                        .offset = va,
                        .kind = kind_addend.kind,
                        .target = if (target_binding == .global)
                            .{ .global = raw_symbols.items[raw_idx].name }
                        else
                            .{ .symbol = raw_idx },
                        .addend = kind_addend.addend,
                    });
                },
            }
        }
    }

    return object.atomizeModule(gpa, name, raw_sections.items, raw_symbols.items, raw_relocs.items);
}

const FILE_HEADER_SIZE: u32 = 20;
const SECTION_HEADER_SIZE: u32 = 40;
const SYMBOL_ENTRY_SIZE: u32 = 18;
const RELOC_ENTRY_SIZE: u32 = 10;

fn classify(name: []const u8, flags: coff.SectionHeader.Flags) ?object.SectionKind {
    if (std.mem.eql(u8, name, ".bit_gc")) return .gc_meta;
    if (flags.CNT_UNINITIALIZED_DATA) return .bss;
    if (flags.CNT_CODE) return .text;
    if (flags.CNT_INITIALIZED_DATA) return if (flags.MEM_WRITE) .data else .rodata;
    return null; // debug info, `.drectve`, or any other non-loadable section
}

const KindAddend = struct { kind: object.RelocKind, addend: i64 };

/// Translates one COFF relocation type into the generic linker IR's
/// `RelocKind` plus its fixed implicit addend — see `obj/pe.zig`'s module
/// doc comment for why COFF stores no explicit addend field: every type's
/// "addend" is a constant baked into its definition by the PE/COFF spec
/// (`REL32` = `S - (P + 4)`; every AArch64 instruction-field kind here is
/// relative to the instruction's own address, offset 0).
fn relocKind(target: Target, r_type: u16) Error!KindAddend {
    return switch (target) {
        .x86_64 => switch (@as(coff.IMAGE.REL.AMD64, @enumFromInt(r_type))) {
            .REL32 => .{ .kind = .pc32, .addend = -4 },
            .ADDR64 => .{ .kind = .abs64, .addend = 0 },
            else => error.UnsupportedRelocation,
        },
        .aarch64 => switch (@as(coff.IMAGE.REL.ARM64, @enumFromInt(r_type))) {
            .BRANCH26 => .{ .kind = .aarch64_call26, .addend = 0 },
            .PAGEBASE_REL21 => .{ .kind = .aarch64_adr_prel_pg_hi21, .addend = 0 },
            .PAGEOFFSET_12A => .{ .kind = .aarch64_add_abs_lo12_nc, .addend = 0 },
            .ADDR64 => .{ .kind = .abs64, .addend = 0 },
            else => error.UnsupportedRelocation,
        },
    };
}

/// Reads symbol table entry `i`'s name directly out of `bytes` — see the
/// call site for why `std.coff.Symbol.getName()` is unsafe to use here for
/// an inline name.
fn symbolNameAt(header: coff.Header, bytes: []const u8, i: u32, strtab: ?coff.Strtab) Error![]const u8 {
    const off = header.pointer_to_symbol_table + i * SYMBOL_ENTRY_SIZE;
    const raw = bytes[off..][0..8];
    if (!std.mem.eql(u8, raw[0..4], &[_]u8{ 0, 0, 0, 0 })) {
        const len = std.mem.indexOfScalar(u8, raw, 0) orelse raw.len;
        return raw[0..len];
    }
    const name_off = std.mem.readInt(u32, raw[4..8], .little);
    const st = strtab orelse return error.Malformed;
    if (name_off >= st.buffer.len) return error.Malformed;
    return st.get(name_off);
}

fn sectionBytes(file: []const u8, sh: coff.SectionHeader) error{Truncated}![]const u8 {
    if (sh.pointer_to_raw_data == 0) return &.{};
    if (@as(u64, sh.pointer_to_raw_data) + sh.size_of_raw_data > file.len) return error.Truncated;
    return file[sh.pointer_to_raw_data..][0..sh.size_of_raw_data];
}

const testing = std.testing;
const pe = @import("../obj/pe.zig");

test "rejects arbitrary bytes long enough for a header, via the machine-type check" {
    const garbage = "not a coff object at all, but padded out long enough to fill a header";
    try testing.expect(garbage.len >= FILE_HEADER_SIZE);
    try testing.expectError(error.UnsupportedCoff, read(testing.allocator, .x86_64, "t", garbage));
}

test "rejects an image (nonzero SizeOfOptionalHeader) rather than misreading it as an object" {
    var hdr = [_]u8{0} ** FILE_HEADER_SIZE;
    std.mem.writeInt(u16, hdr[0..2], @intFromEnum(coff.IMAGE.FILE.MACHINE.AMD64), .little);
    std.mem.writeInt(u16, hdr[16..18], 0xF0, .little); // SizeOfOptionalHeader: PE32+'s real size
    try testing.expectError(error.UnsupportedCoff, read(testing.allocator, .x86_64, "t", &hdr));
}

test "rejects a truncated buffer too short to contain a COFF header" {
    try testing.expectError(error.Truncated, read(testing.allocator, .x86_64, "t", "short"));
}

test "reads back obj/pe.zig's own output: one function, no relocs" {
    const gpa = testing.allocator;
    const code = [_]u8{ 0x55, 0xC3 };
    var symbols = [_]pe.Symbol{.{ .name = "main", .section = .text, .size = code.len, .binding = .global, .kind = .func }};
    var sections = [_]pe.Section{.{ .kind = .text, .data = &code, .alignment = 16 }};
    const bytes = try pe.write(gpa, .x86_64, .{ .sections = &sections, .symbols = &symbols });
    defer gpa.free(bytes);

    const mod = try read(gpa, .x86_64, "bit.o", bytes);
    defer {
        for (mod.atoms) |atom| gpa.free(atom.relocs);
        gpa.free(mod.atoms);
    }
    try testing.expectEqual(@as(usize, 1), mod.atoms.len);
    try testing.expectEqualStrings("main", mod.atoms[0].name);
    try testing.expectEqual(object.Binding.global, mod.atoms[0].binding);
    try testing.expectEqualSlices(u8, &code, mod.atoms[0].data);
}

test "reads back a pc32 call to an undefined runtime symbol as a global reloc with addend -4" {
    const gpa = testing.allocator;
    const code = [_]u8{ 0xE8, 0, 0, 0, 0 };
    var symbols = [_]pe.Symbol{
        .{ .name = "main", .section = .text, .size = code.len, .binding = .global, .kind = .func },
        .{ .name = "bit_rt_alloc", .section = null, .binding = .global },
    };
    var relocs = [_]pe.Relocation{.{ .section = .text, .offset = 1, .symbol = "bit_rt_alloc", .kind = .pc32 }};
    var sections = [_]pe.Section{.{ .kind = .text, .data = &code, .alignment = 16 }};
    const bytes = try pe.write(gpa, .x86_64, .{ .sections = &sections, .symbols = &symbols, .relocations = &relocs });
    defer gpa.free(bytes);

    const mod = try read(gpa, .x86_64, "bit.o", bytes);
    defer {
        for (mod.atoms) |atom| gpa.free(atom.relocs);
        gpa.free(mod.atoms);
    }
    try testing.expectEqual(@as(usize, 1), mod.atoms[0].relocs.len);
    const r = mod.atoms[0].relocs[0];
    try testing.expectEqual(@as(u32, 1), r.offset);
    try testing.expectEqual(object.RelocKind.pc32, r.kind);
    try testing.expectEqual(@as(i64, -4), r.addend);
    try testing.expectEqualStrings("bit_rt_alloc", r.target.global);
}

test "reads back data/rodata/bss/gc_meta sections and an abs64 internal reloc" {
    const gpa = testing.allocator;
    const code = [_]u8{0xC3};
    const rodata = "hi\x00\x00";
    const ptr = [_]u8{0} ** 8;
    const gc = [_]u8{0xAB} ** 8;
    var symbols = [_]pe.Symbol{
        .{ .name = "main", .section = .text, .size = code.len, .binding = .global, .kind = .func },
        .{ .name = "msg", .section = .rodata, .size = rodata.len, .binding = .local },
        .{ .name = "vt", .section = .data, .size = ptr.len, .binding = .global, .kind = .object },
        .{ .name = "buf", .section = .bss, .size = 64, .binding = .local },
        .{ .name = "bit_type_info$Foo", .section = .gc_meta, .size = gc.len, .binding = .local },
    };
    var relocs = [_]pe.Relocation{.{ .section = .data, .offset = 0, .symbol = "msg", .kind = .abs64 }};
    var sections = [_]pe.Section{
        .{ .kind = .text, .data = &code, .alignment = 16 },
        .{ .kind = .data, .data = &ptr, .alignment = 8 },
        .{ .kind = .rodata, .data = rodata, .alignment = 1 },
        .{ .kind = .bss, .size = 64, .alignment = 8 },
        .{ .kind = .gc_meta, .data = &gc, .alignment = 8 },
    };
    const bytes = try pe.write(gpa, .x86_64, .{ .sections = &sections, .symbols = &symbols, .relocations = &relocs });
    defer gpa.free(bytes);

    const mod = try read(gpa, .x86_64, "bit.o", bytes);
    defer {
        for (mod.atoms) |atom| gpa.free(atom.relocs);
        gpa.free(mod.atoms);
    }
    try testing.expectEqual(@as(usize, 5), mod.atoms.len);
    var found_bss = false;
    var found_gc = false;
    for (mod.atoms) |atom| {
        if (std.mem.eql(u8, atom.name, "buf")) {
            found_bss = true;
            try testing.expectEqual(@as(usize, 0), atom.data.len);
            try testing.expectEqual(@as(u32, 64), atom.size);
        }
        if (std.mem.eql(u8, atom.name, "bit_type_info$Foo")) {
            found_gc = true;
            try testing.expectEqual(object.SectionKind.gc_meta, atom.kind);
        }
        if (std.mem.eql(u8, atom.name, "vt")) {
            try testing.expectEqual(@as(usize, 1), atom.relocs.len);
            try testing.expectEqual(object.RelocKind.abs64, atom.relocs[0].kind);
            try testing.expectEqual(@as(i64, 0), atom.relocs[0].addend);
        }
    }
    try testing.expect(found_bss);
    try testing.expect(found_gc);
}

test "aarch64: BRANCH26/PAGEBASE_REL21/PAGEOFFSET_12A round-trip with zero addend" {
    const gpa = testing.allocator;
    const code = [_]u8{
        0x01, 0x00, 0x00, 0x90,
        0x21, 0x00, 0x00, 0x91,
        0x00, 0x00, 0x00, 0x94,
    };
    var symbols = [_]pe.Symbol{
        .{ .name = "start", .section = .text, .size = code.len, .binding = .global, .kind = .func },
        .{ .name = "msg", .section = .rodata, .size = 4, .binding = .local },
        .{ .name = "callee", .section = null, .binding = .global },
    };
    var relocs = [_]pe.Relocation{
        .{ .section = .text, .offset = 0, .symbol = "msg", .kind = .aarch64_adr_prel_pg_hi21 },
        .{ .section = .text, .offset = 4, .symbol = "msg", .kind = .aarch64_add_abs_lo12_nc },
        .{ .section = .text, .offset = 8, .symbol = "callee", .kind = .aarch64_call26 },
    };
    var sections = [_]pe.Section{
        .{ .kind = .text, .data = &code, .alignment = 4 },
        .{ .kind = .rodata, .data = "msg\x00", .alignment = 4 },
    };
    const bytes = try pe.write(gpa, .aarch64, .{ .sections = &sections, .symbols = &symbols, .relocations = &relocs });
    defer gpa.free(bytes);

    const mod = try read(gpa, .aarch64, "bit.o", bytes);
    defer {
        for (mod.atoms) |atom| gpa.free(atom.relocs);
        gpa.free(mod.atoms);
    }
    const start = mod.atoms[0];
    try testing.expectEqualStrings("start", start.name);
    try testing.expectEqual(@as(usize, 3), start.relocs.len);
    try testing.expectEqual(object.RelocKind.aarch64_adr_prel_pg_hi21, start.relocs[0].kind);
    try testing.expectEqual(object.RelocKind.aarch64_add_abs_lo12_nc, start.relocs[1].kind);
    try testing.expectEqual(object.RelocKind.aarch64_call26, start.relocs[2].kind);
    try testing.expectEqualStrings("callee", start.relocs[2].target.global);
}

test "rejects a machine mismatch rather than silently reading the wrong arch" {
    const gpa = testing.allocator;
    const code = [_]u8{0xC3};
    var sections = [_]pe.Section{.{ .kind = .text, .data = &code, .alignment = 16 }};
    const bytes = try pe.write(gpa, .aarch64, .{ .sections = &sections });
    defer gpa.free(bytes);
    try testing.expectError(error.UnsupportedCoff, read(gpa, .x86_64, "t", bytes));
}
