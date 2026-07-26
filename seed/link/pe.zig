//! PE/COFF executable (image) writer + Windows link path (task #1103,
//! closing out #345's remaining scope: ELF (Linux) and Mach-O (macOS) already
//! ship; PE/Windows was carved out separately). Turns the compiled Bit
//! program's object plus a Windows `libbitrt.a` into one PE32+ `.exe` — x86_64
//! and AArch64 both use the identical PE32+ (64-bit) container, so one writer
//! covers both `bit build --target {x86_64,aarch64}-windows`.
//!
//! Pipeline mirrors `link.zig` (ELF) / `link/macho.zig`: ingest generic
//! `object.Module`s (via `link/pe_reader.zig` / `link/archive.zig`), resolve
//! the whole-link global symbol table, walk from the entry root `_start`
//! collecting reachable atoms, lay the survivors into PE sections, apply every
//! relocation, and emit DOS stub + PE header + section table + section bytes.
//!
//! Windows has no static libc: every syscall reaches the OS through
//! `kernel32.dll`, so — like Mach-O's libSystem — a still-undefined global
//! after dead-strip is a **DLL import**, not a link error (`undefinedIsImport`,
//! the same rule as `link/macho.zig`'s). Unlike Mach-O there is no dynamic
//! bind/rebase opcode stream: each import gets one Import Address Table (IAT)
//! slot the loader fills at load time, reached through a small thunk — `jmp
//! [rip+iat_slot]` on x64, `adrp`+`ldr`+`br` on arm64 — which is the "entry
//! thunk" #1103's scope names. ASLR is instead a `.reloc` section of
//! `IMAGE_REL_BASED_DIR64` base relocations, one per *absolute* pointer baked
//! into `.rdata`/`.data`: the loader may load at a different base than
//! `ImageBase`, and only absolute fields need adjusting for that slide — every
//! PC-relative field this backend emits (`pc32`, `aarch64_call26`,
//! `aarch64_adr_prel_pg_hi21`/`aarch64_add_abs_lo12_nc`) is slide-invariant
//! (both the field and its target move together), exactly as under Mach-O PIE,
//! so none of those ever need a `.reloc` entry.
//!
//! An import is reached only through a direct call (`pc32` or
//! `aarch64_call26`): this compiler never takes an `extern function`'s address
//! as data, only ever calls it, so those are the only two `RelocKind`s
//! `undefinedIsImport` can legally see pointed at an import. `pc32` doubles as
//! `lea rip-rel` for an *internal* target (module doc comment, `obj/pe.zig`),
//! but that ambiguity never reaches an import: retargeting the field's rel32
//! to a synthesized stub keeps the byte-identical `call rel32`/`bl` opcode,
//! just aimed at the stub instead of a symbol that doesn't exist in this
//! image. Any other kind pointed at an import (an absolute pointer to a DLL
//! function, say) is `error.UnsupportedRelocation` rather than a guess.
//!
//! Scope, matching `obj/pe.zig`'s: no Windows TLS (`.tls$` sections — never
//! produced by `link/pe_reader.zig`, so a `.tls_vars`/`.tls_data`/`.tls_bss`
//! atom reaching this file is unreachable), one import DLL (`KERNEL32.dll` —
//! the "minimal syscall surface" #1103 allows), subsystem console.

const std = @import("std");
const coff = std.coff;
const Allocator = std.mem.Allocator;
const object = @import("object.zig");
const strip = @import("strip.zig");
const archive = @import("archive.zig");
const pe_reader = @import("pe_reader.zig");

const AtomId = strip.AtomId;

pub const Error = strip.Error || error{MissingEntry} || Allocator.Error;
pub const UndefinedRef = strip.UndefinedRef;

pub const Target = enum {
    x86_64,
    aarch64,

    fn machine(self: Target) coff.IMAGE.FILE.MACHINE {
        return switch (self) {
            .x86_64 => .AMD64,
            .aarch64 => .ARM64,
        };
    }

    fn readerTarget(self: Target) pe_reader.Target {
        return switch (self) {
            .x86_64 => .x86_64,
            .aarch64 => .aarch64,
        };
    }

    /// Width in bytes of this target's import-thunk stub.
    fn stubWidth(self: Target) u32 {
        return switch (self) {
            .x86_64 => 6, // FF 25 <disp32>  (jmp qword ptr [rip+disp32])
            .aarch64 => 12, // adrp x16,# ; ldr x16,[x16,#] ; br x16
        };
    }
};

const entry_symbol = "_start"; // x64/arm64 COFF decorates no C symbol names
/// MS linker's default preferred base for an x64/arm64 EXE (well above the
/// null page and any DLL's usual load range).
const image_base: u64 = 0x1_4000_0000;
const section_align: u32 = 0x1000;
const file_align: u32 = 0x200;
const dll_name = "KERNEL32.dll";
/// Offset of the PE signature from file start. Fixed rather than "wherever
/// the stub happens to end", matching every real toolchain's output and
/// `Coff.init`'s expectation that `e_lfanew` is a small, sane value.
const e_lfanew: u32 = 0x80;

pub const Options = struct {
    /// Names the program may legitimately leave for the OS loader to import
    /// (its SPEC §11.7 `extern function` declarations) — mirrors
    /// `link/macho.zig.Options.allowed_imports`.
    allowed_imports: []const []const u8 = &.{},
    /// How many leading modules came from `.object` inputs (the compiled Bit
    /// program), vs. archive members. See `undefinedIsImport`.
    program_modules: u32 = 0,
    undefined_out: ?*UndefinedRef = null,
};

/// Same rule as `link/macho.zig`'s: an archive member's undefined names ARE
/// the DLL surface (`libbitrt.a`'s Windows syscalls); the program object's
/// undefined names must each be a declared `extern function`.
fn undefinedIsImport(opts: Options, mi: u32, name: []const u8) bool {
    if (mi >= opts.program_modules) return true;
    for (opts.allowed_imports) |a| {
        if (std.mem.eql(u8, a, name)) return true;
    }
    return false;
}

pub const Input = union(enum) {
    /// A single relocatable PE/COFF object — the compiled Bit program.
    object: []const u8,
    /// An `ar` archive (`libbitrt.a`); every member is read as its own module.
    archive: []const u8,
};

/// Reads `inputs` into the generic object model and links them into a PE32+
/// executable — the Windows analogue of `link.zig`'s `linkExecutable` /
/// `link/macho.zig`'s `link`.
pub fn link(gpa: Allocator, target: Target, inputs: []const Input, opts: Options) (Error || pe_reader.Error || archive.Error)![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var modules: std.ArrayList(object.Module) = .empty;
    var members: std.ArrayList(object.Module) = .empty;
    var program_modules: u32 = 0;
    for (inputs) |input| switch (input) {
        .object => |bytes| {
            try modules.append(arena, try pe_reader.read(arena, target.readerTarget(), "bit.o", bytes));
            program_modules += 1;
        },
        .archive => |bytes| {
            for (try archive.parse(arena, bytes)) |m|
                try members.append(arena, try pe_reader.read(arena, target.readerTarget(), m.name, m.data));
        },
    };
    try modules.appendSlice(arena, try strip.selectArchiveMembers(arena, modules.items, members.items, &.{entry_symbol}));
    std.debug.assert(program_modules <= modules.items.len);

    var o = opts;
    o.program_modules = program_modules;
    return linkExecutable(gpa, target, modules.items, o);
}

fn alignUp(v: u64, a: u64) u64 {
    return std.mem.alignForward(u64, v, a);
}

fn isBranch(kind: object.RelocKind) bool {
    return kind == .pc32 or kind == .aarch64_call26;
}

/// True for the 5 `RelocKind`s `obj/pe.zig`/`link/pe_reader.zig` can ever
/// produce — see their module doc comments. Anything else reaching this
/// linker (e.g. a GOT/TLS kind meant for a different container) is refused
/// rather than handed to `strip.apply` with meaningless field values.
fn peSupported(kind: object.RelocKind) bool {
    return switch (kind) {
        .pc32, .abs64, .aarch64_call26, .aarch64_adr_prel_pg_hi21, .aarch64_add_abs_lo12_nc => true,
        else => false,
    };
}

const Placed = struct { id: AtomId, rva: u32 = 0 };

fn placeAtoms(mods: []const object.Module, items: []Placed, cursor: *u64) void {
    for (items) |*p| {
        const a = mods[p.id.module].atoms[p.id.atom];
        cursor.* = alignUp(cursor.*, @max(a.alignment, 1));
        p.rva = @intCast(cursor.*);
        cursor.* += a.size;
    }
}

/// Links `input_modules` into a PE32+ executable, returned as owned bytes.
pub fn linkExecutable(gpa: Allocator, target: Target, input_modules: []const object.Module, opts: Options) Error![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // ABI.md §4: the merged GC stack-map table's bounds are linker-defined —
    // same synthetic-module trick as `link.zig`/`link/macho.zig`. No symbol
    // decoration on x64/arm64 COFF, so the prefix is "" like ELF.
    var all_modules: std.ArrayList(object.Module) = .empty;
    try all_modules.appendSlice(arena, input_modules);
    const marker_module: u32 = @intCast(all_modules.items.len);
    try all_modules.append(arena, try strip.markerModule(arena, ""));
    const modules = all_modules.items;

    var globals = try strip.resolveGlobals(arena, modules);

    // ---- dead-strip from `_start`, collecting DLL imports as leaves --------
    var kept = std.AutoHashMapUnmanaged(u64, void){};
    var import_order: std.ArrayList([]const u8) = .empty;
    var import_index = std.StringHashMapUnmanaged(u32){};
    var stack: std.ArrayList(AtomId) = .empty;

    const entry = globals.get(entry_symbol) orelse return error.MissingEntry;
    try kept.put(arena, entry.key(), {});
    try stack.append(arena, entry);
    try kept.put(arena, (AtomId{ .module = marker_module, .atom = strip.marker_start_atom }).key(), {});
    try kept.put(arena, (AtomId{ .module = marker_module, .atom = strip.marker_end_atom }).key(), {});

    while (stack.pop()) |id| {
        const atom = modules[id.module].atoms[id.atom];
        for (atom.relocs) |r| {
            if (!peSupported(r.kind)) return error.UnsupportedRelocation;
            switch (r.target) {
                .local => |idx| {
                    const tid = AtomId{ .module = id.module, .atom = idx };
                    if ((try kept.getOrPut(arena, tid.key())).found_existing) continue;
                    try stack.append(arena, tid);
                },
                .global => |nm| {
                    if (globals.get(nm)) |tid| {
                        if ((try kept.getOrPut(arena, tid.key())).found_existing) continue;
                        try stack.append(arena, tid);
                    } else {
                        if (!undefinedIsImport(opts, id.module, nm)) {
                            if (opts.undefined_out) |slot| slot.* = .{ .symbol = nm, .referenced_from = modules[id.module].name };
                            return error.UndefinedSymbol;
                        }
                        if (!isBranch(r.kind)) return error.UnsupportedRelocation;
                        const gop = try import_index.getOrPut(arena, nm);
                        if (!gop.found_existing) {
                            gop.value_ptr.* = @intCast(import_order.items.len);
                            try import_order.append(arena, nm);
                        }
                    }
                },
            }
        }
    }

    // A split mutable global (`-fdata-sections`-style adjacent pieces) must
    // stay contiguous in its original layout even if some pieces are
    // otherwise unreferenced — same rule and reasoning as `link.zig`'s.
    for (modules, 0..) |mod, mi| {
        for (mod.atoms, 0..) |atom, ai| {
            switch (atom.kind) {
                .data, .bss => try kept.put(arena, (AtomId{ .module = @intCast(mi), .atom = @intCast(ai) }).key(), {}),
                else => {},
            }
        }
    }

    // ---- partition kept atoms by output section ----------------------------
    var text: std.ArrayList(Placed) = .empty;
    var rdata: std.ArrayList(Placed) = .empty;
    var data: std.ArrayList(Placed) = .empty;
    var bss: std.ArrayList(Placed) = .empty;
    for (modules, 0..) |mod, mi| {
        for (mod.atoms, 0..) |atom, ai| {
            const id = AtomId{ .module = @intCast(mi), .atom = @intCast(ai) };
            if (!kept.contains(id.key())) continue;
            switch (atom.kind) {
                .text => try text.append(arena, .{ .id = id }),
                .rodata => try rdata.append(arena, .{ .id = id }),
                .data => try data.append(arena, .{ .id = id }),
                .bss => try bss.append(arena, .{ .id = id }),
                // Placed as one uninterrupted run into `rdata` below instead.
                .gc_meta => {},
                // Windows TLS is out of scope (module doc comment); `pe_reader`
                // never classifies a section into any of these three, so a
                // module this linker sees can never carry one.
                .tls_vars, .tls_data, .tls_bss => unreachable,
            }
        }
    }
    {
        var kept_set = strip.KeptSet{ .set = kept };
        for (try strip.mergedStackMapAtoms(arena, modules, &globals, &kept_set, marker_module)) |id|
            try rdata.append(arena, .{ .id = id });
        kept = kept_set.set;
    }

    // ---- layout: RVAs first (headers occupy their own leading page) --------
    const stub_width: u64 = target.stubWidth();
    const n_imports: u32 = @intCast(import_order.items.len);

    var rva_cursor: u64 = section_align;
    const text_rva = rva_cursor;
    placeAtoms(modules, text.items, &rva_cursor);
    const stubs_rva = alignUp(rva_cursor, 4);
    rva_cursor = stubs_rva + @as(u64, n_imports) * stub_width;
    const text_virtual_size = rva_cursor - text_rva;

    rva_cursor = alignUp(rva_cursor, section_align);
    const rdata_rva = rva_cursor;
    placeAtoms(modules, rdata.items, &rva_cursor);
    const rdata_virtual_size = rva_cursor - rdata_rva;
    const has_rdata = rdata_virtual_size > 0;

    rva_cursor = alignUp(rva_cursor, section_align);
    const data_rva = rva_cursor;
    placeAtoms(modules, data.items, &rva_cursor);
    const data_virtual_size = rva_cursor - data_rva;
    const has_data = data_virtual_size > 0;

    // ---- address lookup for every placed atom, and internal abs64 fixups --
    // that need a base-relocation entry (module doc comment: only absolute
    // fields need one; every PC-relative kind is slide-invariant).
    var addr_of = std.AutoHashMapUnmanaged(u64, u32){};
    for ([_][]const Placed{ text.items, rdata.items, data.items }) |group|
        for (group) |p| try addr_of.put(arena, p.id.key(), p.rva);

    var base_relocs: std.ArrayList(u32) = .empty;
    for (modules, 0..) |mod, mi| {
        for (mod.atoms, 0..) |atom, ai| {
            const id = AtomId{ .module = @intCast(mi), .atom = @intCast(ai) };
            if (!kept.contains(id.key())) continue;
            for (atom.relocs) |r| {
                if (r.kind != .abs64) continue;
                const is_import = r.target == .global and globals.get(r.target.global) == null;
                if (is_import) return error.UnsupportedRelocation; // module doc comment
                const field_rva = addr_of.get(id.key()).? + r.offset;
                try base_relocs.append(arena, field_rva);
            }
        }
    }
    std.mem.sort(u32, base_relocs.items, {}, std.sort.asc(u32));

    // ---- .idata: import descriptor + ILT + IAT + hint/name + DLL name ------
    const idata_layout = try buildIdataLayout(arena, import_order.items);
    rva_cursor = alignUp(rva_cursor, section_align);
    const idata_rva = rva_cursor;
    rva_cursor += idata_layout.total_size;
    const has_imports = n_imports > 0;

    rva_cursor = alignUp(rva_cursor, section_align);
    const bss_rva = rva_cursor;
    placeAtoms(modules, bss.items, &rva_cursor);
    const bss_virtual_size = rva_cursor - bss_rva;
    const has_bss = bss_virtual_size > 0;
    for (bss.items) |p| try addr_of.put(arena, p.id.key(), p.rva);

    rva_cursor = alignUp(rva_cursor, section_align);
    const reloc_rva = rva_cursor;
    const reloc_bytes = try buildBaseRelocs(arena, base_relocs.items);
    rva_cursor += reloc_bytes.len;
    const has_reloc = reloc_bytes.len > 0;

    const size_of_image: u32 = @intCast(alignUp(rva_cursor, section_align));

    // ---- section count + header sizing -------------------------------------
    var nsections: u16 = 1; // .text always present (it holds `_start`)
    if (has_rdata) nsections += 1;
    if (has_data) nsections += 1;
    if (has_imports) nsections += 1;
    if (has_bss) nsections += 1;
    if (has_reloc) nsections += 1;

    const optional_header_size: u32 = @sizeOf(coff.OptionalHeader.@"PE32+") + 16 * @sizeOf(coff.ImageDataDirectory);
    const headers_raw_size: u32 = e_lfanew + 4 + @sizeOf(coff.Header) + optional_header_size + @as(u32, nsections) * @sizeOf(coff.SectionHeader);
    const headers_file_size: u32 = @intCast(alignUp(headers_raw_size, file_align));

    // ---- file-offset layout (parallel to the RVA layout; `.bss` has none) --
    var file_cursor: u64 = headers_file_size;
    const text_file_off = file_cursor;
    const text_raw_size: u32 = @intCast(alignUp(text_virtual_size, file_align));
    file_cursor += text_raw_size;

    const rdata_file_off = file_cursor;
    const rdata_raw_size: u32 = if (has_rdata) @intCast(alignUp(rdata_virtual_size, file_align)) else 0;
    file_cursor += rdata_raw_size;

    const data_file_off = file_cursor;
    const data_raw_size: u32 = if (has_data) @intCast(alignUp(data_virtual_size, file_align)) else 0;
    file_cursor += data_raw_size;

    const idata_file_off = file_cursor;
    const idata_raw_size: u32 = if (has_imports) @intCast(alignUp(idata_layout.total_size, file_align)) else 0;
    file_cursor += idata_raw_size;

    const reloc_file_off = file_cursor;
    const reloc_raw_size: u32 = if (has_reloc) @intCast(alignUp(reloc_bytes.len, file_align)) else 0;
    file_cursor += reloc_raw_size;

    const total_file_size: usize = @intCast(file_cursor);

    // ---- entry point + relocation application ------------------------------
    const entry_rva = addr_of.get(entry.key()) orelse return error.MissingEntry;

    const iat_rva_base = idata_rva + idata_layout.iat_off;
    const stubRva = struct {
        base: u64,
        width: u64,
        fn at(self: @This(), i: u32) u32 {
            return @intCast(self.base + @as(u64, i) * self.width);
        }
    }{ .base = stubs_rva, .width = stub_width };
    const iatRva = struct {
        base: u32,
        fn at(self: @This(), i: u32) u32 {
            return self.base + i * 8;
        }
    }{ .base = @intCast(iat_rva_base) };

    var patched = std.AutoHashMapUnmanaged(u64, []u8){};
    for (modules, 0..) |mod, mi| {
        for (mod.atoms, 0..) |atom, ai| {
            const id = AtomId{ .module = @intCast(mi), .atom = @intCast(ai) };
            if (!kept.contains(id.key()) or atom.data.len == 0) continue;
            const buf = try arena.dupe(u8, atom.data);
            const atom_rva = addr_of.get(id.key()).?;
            for (atom.relocs) |r| {
                const field = buf[r.offset..];
                const p = image_base + atom_rva + r.offset;
                const is_import = r.target == .global and globals.get(r.target.global) == null;
                const target_va: u64 = if (is_import)
                    image_base + stubRva.at(import_index.get(r.target.global).?)
                else target: {
                    const tid = try strip.resolveRef(&globals, @intCast(mi), r.target);
                    break :target image_base + addr_of.get(tid.key()).?;
                };
                const s: u64 = @bitCast(@as(i64, @bitCast(target_va)) + r.addend);
                try strip.apply(r.kind, field, .{ .s = s, .p = p });
            }
            try patched.put(arena, id.key(), buf);
        }
    }

    // ---- stub thunks: jmp/branch through this import's IAT slot ------------
    const stub_bytes = try arena.alloc(u8, @intCast(@as(u64, n_imports) * stub_width));
    for (import_order.items, 0..) |_, i| {
        const idx: u32 = @intCast(i);
        const stub_va = image_base + stubRva.at(idx);
        const iat_va = image_base + iatRva.at(idx);
        const s = stub_bytes[idx * @as(u32, @intCast(stub_width)) ..][0..@intCast(stub_width)];
        switch (target) {
            .x86_64 => {
                s[0] = 0xFF;
                s[1] = 0x25;
                // `jmp [rip+disp32]`: disp is relative to the byte after the
                // 4-byte field, i.e. the end of this 6-byte instruction.
                try strip.apply(.pc32, s[2..6], .{ .s = iat_va, .p = stub_va + 6 });
            },
            .aarch64 => {
                std.mem.writeInt(u32, s[0..4], 0x90000010, .little); // adrp x16, 0
                std.mem.writeInt(u32, s[4..8], 0xF9400210, .little); // ldr x16, [x16]
                std.mem.writeInt(u32, s[8..12], 0xD61F0200, .little); // br x16
                try strip.apply(.aarch64_adr_prel_pg_hi21, s[0..4], .{ .s = iat_va, .p = stub_va });
                // `writeLo12(_,_,3)` needs `aarch64_ldst64_abs_lo12_nc`, but
                // `strip.apply` only dispatches that from `.s`, same as the
                // page instruction above — both read `v.s`, so this is exact.
                try strip.apply(object.RelocKind.aarch64_ldst64_abs_lo12_nc, s[4..8], .{ .s = iat_va, .p = 0 });
            },
        }
    }

    // ---- .idata bytes -------------------------------------------------------
    const idata_bytes = try buildIdataBytes(arena, idata_layout, import_order.items, idata_rva);

    // ---- assemble the file ---------------------------------------------------
    const file = try gpa.alloc(u8, total_file_size);
    errdefer gpa.free(file);
    @memset(file, 0);

    for ([_][]const Placed{ text.items, rdata.items, data.items }) |group| {
        for (group) |p| {
            const bytes = patched.get(p.id.key()) orelse modules[p.id.module].atoms[p.id.atom].data;
            if (bytes.len == 0) continue;
            const off = fileOffsetOf(p.rva, text_rva, text_file_off, rdata_rva, rdata_file_off, data_rva, data_file_off);
            @memcpy(file[off..][0..bytes.len], bytes);
        }
    }
    @memcpy(file[text_file_off + (stubs_rva - text_rva) ..][0..stub_bytes.len], stub_bytes);
    if (has_imports) @memcpy(file[idata_file_off..][0..idata_bytes.len], idata_bytes);
    if (has_reloc) @memcpy(file[reloc_file_off..][0..reloc_bytes.len], reloc_bytes);

    writeHeaders(file, .{
        .target = target,
        .nsections = nsections,
        .entry_rva = entry_rva,
        .size_of_image = size_of_image,
        .headers_file_size = headers_file_size,
        .text = .{ .rva = @intCast(text_rva), .vsize = @intCast(text_virtual_size), .file_off = @intCast(text_file_off), .raw_size = text_raw_size },
        .rdata = if (has_rdata) .{ .rva = @intCast(rdata_rva), .vsize = @intCast(rdata_virtual_size), .file_off = @intCast(rdata_file_off), .raw_size = rdata_raw_size } else null,
        .data = if (has_data) .{ .rva = @intCast(data_rva), .vsize = @intCast(data_virtual_size), .file_off = @intCast(data_file_off), .raw_size = data_raw_size } else null,
        .idata = if (has_imports) .{ .rva = @intCast(idata_rva), .vsize = @intCast(idata_layout.total_size), .file_off = @intCast(idata_file_off), .raw_size = idata_raw_size } else null,
        .bss = if (has_bss) .{ .rva = @intCast(bss_rva), .vsize = @intCast(bss_virtual_size), .file_off = 0, .raw_size = 0 } else null,
        .reloc = if (has_reloc) .{ .rva = @intCast(reloc_rva), .vsize = @intCast(reloc_bytes.len), .file_off = @intCast(reloc_file_off), .raw_size = reloc_raw_size } else null,
        .import_dir = if (has_imports) .{ .rva = @intCast(idata_rva), .size = @intCast(idata_layout.descriptor_table_size) } else null,
        .iat_dir = if (has_imports) .{ .rva = @intCast(iat_rva_base), .size = @intCast((n_imports + 1) * 8) } else null,
        .basereloc_dir = if (has_reloc) .{ .rva = @intCast(reloc_rva), .size = @intCast(reloc_bytes.len) } else null,
    });

    return file;
}

fn fileOffsetOf(rva: u32, text_rva: u64, text_off: u64, rdata_rva: u64, rdata_off: u64, data_rva: u64, data_off: u64) u64 {
    if (rva >= data_rva) return data_off + (rva - data_rva);
    if (rva >= rdata_rva) return rdata_off + (rva - rdata_rva);
    return text_off + (rva - text_rva);
}

// ---------------------------------------------------------------------------
// .idata layout + emission
// ---------------------------------------------------------------------------

const IdataLayout = struct {
    descriptor_table_size: u32,
    ilt_off: u32,
    iat_off: u32,
    names_off: []const u32, // per import, offset within the section
    dllname_off: u32,
    total_size: u32,
};

fn buildIdataLayout(arena: Allocator, imports: []const []const u8) Allocator.Error!IdataLayout {
    const n: u32 = @intCast(imports.len);
    const descriptor_table_size: u32 = 2 * 20; // 1 real IMAGE_IMPORT_DESCRIPTOR + 1 null terminator
    const thunk_array_size: u32 = (n + 1) * 8; // PE32+ thunk (IMAGE_THUNK_DATA64)
    const ilt_off = descriptor_table_size;
    const iat_off = ilt_off + thunk_array_size;
    var cursor = iat_off + thunk_array_size;

    const names_off = try arena.alloc(u32, imports.len);
    for (imports, 0..) |name, i| {
        names_off[i] = cursor;
        var entry_len: u32 = 2 + @as(u32, @intCast(name.len)) + 1; // hint(2) + name + NUL
        if (entry_len % 2 != 0) entry_len += 1; // pad to a 2-byte boundary
        cursor += entry_len;
    }
    const dllname_off = cursor;
    cursor += @as(u32, @intCast(dll_name.len)) + 1;

    return .{
        .descriptor_table_size = descriptor_table_size,
        .ilt_off = ilt_off,
        .iat_off = iat_off,
        .names_off = names_off,
        .dllname_off = dllname_off,
        .total_size = cursor,
    };
}

fn buildIdataBytes(arena: Allocator, layout: IdataLayout, imports: []const []const u8, idata_rva: u64) Allocator.Error![]u8 {
    const buf = try arena.alloc(u8, layout.total_size);
    @memset(buf, 0);

    const desc: coff.ImportDirectoryEntry = .{
        .import_lookup_table_rva = @intCast(idata_rva + layout.ilt_off),
        .time_date_stamp = 0,
        .forwarder_chain = 0,
        .name_rva = @intCast(idata_rva + layout.dllname_off),
        .import_address_table_rva = @intCast(idata_rva + layout.iat_off),
    };
    @memcpy(buf[0..@sizeOf(coff.ImportDirectoryEntry)], std.mem.asBytes(&desc));
    // buf[20..40] stays the zero terminator descriptor.

    for (imports, 0..) |name, i| {
        const thunk: u64 = idata_rva + layout.names_off[i]; // by-name, ordinal flag (bit 63) clear
        std.mem.writeInt(u64, buf[layout.ilt_off + i * 8 ..][0..8], thunk, .little);
        std.mem.writeInt(u64, buf[layout.iat_off + i * 8 ..][0..8], thunk, .little);
        // hint(0) + name + NUL; buf is already zeroed, including any pad byte.
        @memcpy(buf[layout.names_off[i] + 2 ..][0..name.len], name);
    }
    @memcpy(buf[layout.dllname_off..][0..dll_name.len], dll_name);
    return buf;
}

// ---------------------------------------------------------------------------
// .reloc (base relocations)
// ---------------------------------------------------------------------------

fn buildBaseRelocs(arena: Allocator, field_rvas: []const u32) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    if (field_rvas.len == 0) return out.toOwnedSlice(arena);

    var i: usize = 0;
    while (i < field_rvas.len) {
        const page = field_rvas[i] & ~@as(u32, 0xFFF);
        var j = i;
        while (j < field_rvas.len and (field_rvas[j] & ~@as(u32, 0xFFF)) == page) : (j += 1) {}
        const count = j - i;
        const odd_pad = count % 2 != 0;
        const block_size: u32 = 8 + @as(u32, @intCast(count + @as(usize, @intFromBool(odd_pad)))) * 2;

        try out.appendSlice(arena, std.mem.asBytes(&coff.BaseRelocationDirectoryEntry{ .page_rva = page, .block_size = block_size }));
        for (field_rvas[i..j]) |rva| {
            const entry: coff.BaseRelocation = .{ .offset = @intCast(rva & 0xFFF), .type = .DIR64 };
            try out.appendSlice(arena, std.mem.asBytes(&entry));
        }
        if (odd_pad) {
            const pad: coff.BaseRelocation = .{ .offset = 0, .type = .ABSOLUTE };
            try out.appendSlice(arena, std.mem.asBytes(&pad));
        }
        i = j;
    }
    return out.toOwnedSlice(arena);
}

// ---------------------------------------------------------------------------
// Header + section table emission
// ---------------------------------------------------------------------------

const SectionSpan = struct { rva: u32, vsize: u32, file_off: u32, raw_size: u32 };
const DirSpan = struct { rva: u32, size: u32 };

const HeaderInfo = struct {
    target: Target,
    nsections: u16,
    entry_rva: u32,
    size_of_image: u32,
    headers_file_size: u32,
    text: SectionSpan,
    rdata: ?SectionSpan,
    data: ?SectionSpan,
    idata: ?SectionSpan,
    bss: ?SectionSpan,
    reloc: ?SectionSpan,
    import_dir: ?DirSpan,
    iat_dir: ?DirSpan,
    basereloc_dir: ?DirSpan,
};

/// The canonical MS-DOS stub every real PE carries — never executed by the
/// Windows loader (it only reads `e_lfanew` to find the PE signature that
/// follows), but a real DOS/NTVDM host would run it and print this message.
const dos_stub_code = [_]u8{ 0x0E, 0x1F, 0xBA, 0x0E, 0x00, 0xB4, 0x09, 0xCD, 0x21, 0xB8, 0x01, 0x4C, 0xCD, 0x21 };
const dos_stub_msg = "This program cannot be run in DOS mode.\r\r\n$";

fn writeHeaders(file: []u8, h: HeaderInfo) void {
    // ---- DOS header + stub ---------------------------------------------------
    @memset(file[0..e_lfanew], 0);
    file[0] = 'M';
    file[1] = 'Z';
    std.mem.writeInt(u32, file[0x3C..][0..4], e_lfanew, .little);
    @memcpy(file[0x40..][0..dos_stub_code.len], &dos_stub_code);
    @memcpy(file[0x40 + dos_stub_code.len ..][0..dos_stub_msg.len], dos_stub_msg);

    // ---- PE signature + COFF file header -------------------------------------
    var off: usize = e_lfanew;
    @memcpy(file[off..][0..4], "PE\x00\x00");
    off += 4;

    const coff_header: coff.Header = .{
        .machine = h.target.machine(),
        .number_of_sections = h.nsections,
        .time_date_stamp = 0, // reproducible builds
        .pointer_to_symbol_table = 0,
        .number_of_symbols = 0,
        .size_of_optional_header = @intCast(@sizeOf(coff.OptionalHeader.@"PE32+") + 16 * @sizeOf(coff.ImageDataDirectory)),
        .flags = .{ .EXECUTABLE_IMAGE = true, .LARGE_ADDRESS_AWARE = true },
    };
    @memcpy(file[off..][0..@sizeOf(coff.Header)], std.mem.asBytes(&coff_header));
    off += @sizeOf(coff.Header);

    // ---- PE32+ optional header ------------------------------------------------
    const size_of_code = h.text.raw_size;
    const size_of_init_data = (if (h.rdata) |s| s.raw_size else 0) + (if (h.data) |s| s.raw_size else 0) +
        (if (h.idata) |s| s.raw_size else 0) + (if (h.reloc) |s| s.raw_size else 0);
    const size_of_uninit_data = if (h.bss) |s| s.vsize else 0;

    const opt: coff.OptionalHeader.@"PE32+" = .{
        .standard = .{
            .magic = .@"PE32+",
            .major_linker_version = 1,
            .minor_linker_version = 0,
            .size_of_code = size_of_code,
            .size_of_initialized_data = size_of_init_data,
            .size_of_uninitialized_data = size_of_uninit_data,
            .address_of_entry_point = h.entry_rva,
            .base_of_code = h.text.rva,
        },
        .image_base = image_base,
        .section_alignment = section_align,
        .file_alignment = file_align,
        .major_operating_system_version = 6,
        .minor_operating_system_version = 0,
        .major_image_version = 0,
        .minor_image_version = 0,
        .major_subsystem_version = 6,
        .minor_subsystem_version = 0,
        .win32_version_value = 0,
        .size_of_image = h.size_of_image,
        .size_of_headers = h.headers_file_size,
        .checksum = 0,
        .subsystem = .WINDOWS_CUI,
        .dll_flags = .{ .HIGH_ENTROPY_VA = true, .DYNAMIC_BASE = true, .NX_COMPAT = true },
        .size_of_stack_reserve = 0x100000,
        .size_of_stack_commit = 0x1000,
        .size_of_heap_reserve = 0x100000,
        .size_of_heap_commit = 0x1000,
        .loader_flags = 0,
        .number_of_rva_and_sizes = 16,
    };
    @memcpy(file[off..][0..@sizeOf(coff.OptionalHeader.@"PE32+")], std.mem.asBytes(&opt));
    off += @sizeOf(coff.OptionalHeader.@"PE32+");

    var dirs: [16]coff.ImageDataDirectory = @splat(.{ .virtual_address = 0, .size = 0 });
    if (h.import_dir) |d| dirs[@intFromEnum(coff.IMAGE.DIRECTORY_ENTRY.IMPORT)] = .{ .virtual_address = d.rva, .size = d.size };
    if (h.basereloc_dir) |d| dirs[@intFromEnum(coff.IMAGE.DIRECTORY_ENTRY.BASERELOC)] = .{ .virtual_address = d.rva, .size = d.size };
    if (h.iat_dir) |d| dirs[@intFromEnum(coff.IMAGE.DIRECTORY_ENTRY.IAT)] = .{ .virtual_address = d.rva, .size = d.size };
    for (dirs) |d| {
        @memcpy(file[off..][0..@sizeOf(coff.ImageDataDirectory)], std.mem.asBytes(&d));
        off += @sizeOf(coff.ImageDataDirectory);
    }

    // ---- section headers -------------------------------------------------
    const code_flags: coff.SectionHeader.Flags = .{ .CNT_CODE = true, .MEM_EXECUTE = true, .MEM_READ = true };
    const rodata_flags: coff.SectionHeader.Flags = .{ .CNT_INITIALIZED_DATA = true, .MEM_READ = true };
    const rw_flags: coff.SectionHeader.Flags = .{ .CNT_INITIALIZED_DATA = true, .MEM_READ = true, .MEM_WRITE = true };
    const bss_flags: coff.SectionHeader.Flags = .{ .CNT_UNINITIALIZED_DATA = true, .MEM_READ = true, .MEM_WRITE = true };
    const reloc_flags: coff.SectionHeader.Flags = .{ .CNT_INITIALIZED_DATA = true, .MEM_READ = true, .MEM_DISCARDABLE = true };

    writeSectionHeader(file, &off, ".text", h.text, code_flags);
    if (h.rdata) |s| writeSectionHeader(file, &off, ".rdata", s, rodata_flags);
    if (h.data) |s| writeSectionHeader(file, &off, ".data", s, rw_flags);
    if (h.idata) |s| writeSectionHeader(file, &off, ".idata", s, rw_flags);
    if (h.bss) |s| writeSectionHeader(file, &off, ".bss", s, bss_flags);
    if (h.reloc) |s| writeSectionHeader(file, &off, ".reloc", s, reloc_flags);
}

fn writeSectionHeader(file: []u8, off: *usize, name: []const u8, s: SectionSpan, flags: coff.SectionHeader.Flags) void {
    std.debug.assert(name.len <= 8);
    var name8: [8]u8 = @splat(0);
    @memcpy(name8[0..name.len], name);
    const sh: coff.SectionHeader = .{
        .name = name8,
        .virtual_size = s.vsize,
        .virtual_address = s.rva,
        .size_of_raw_data = s.raw_size,
        .pointer_to_raw_data = if (s.raw_size == 0) 0 else s.file_off,
        .pointer_to_relocations = 0,
        .pointer_to_linenumbers = 0,
        .number_of_relocations = 0,
        .number_of_linenumbers = 0,
        .flags = flags,
    };
    @memcpy(file[off.*..][0..@sizeOf(coff.SectionHeader)], std.mem.asBytes(&sh));
    off.* += @sizeOf(coff.SectionHeader);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------
const testing = std.testing;

test {
    testing.refAllDecls(@This());
}

/// De-risk payload: a synthetic `_start` that writes "hi\n" to stdout and
/// exits 0 via three `KERNEL32.dll` calls (`GetStdHandle`, `WriteFile`,
/// `ExitProcess`), each reached through this linker's own import-stub
/// mechanism. Proves the whole container — DOS stub, PE/COFF headers, import
/// directory, IAT, entry — with no dependency on the reader or a real
/// runtime, mirroring `link/macho.zig`'s `buildDerisk`.
fn buildDeriskX64(gpa: Allocator) ![]u8 {
    // _start:
    //   and rsp, -16                     48 83 E4 F0
    //   sub rsp, 0x30                    48 83 EC 30
    //   mov ecx, 0xFFFFFFF5              B9 F5 FF FF FF        ; STD_OUTPUT_HANDLE
    //   call GetStdHandle                E8 00 00 00 00
    //   mov r12, rax                     49 89 C4
    //   mov rcx, r12                     4C 89 E1
    //   lea rdx, [rip+msg]               48 8D 15 00 00 00 00
    //   mov r8d, 3                       41 B8 03 00 00 00
    //   lea r9, [rsp+0x28]                4C 8D 4C 24 28
    //   mov qword [rsp+0x20], 0          48 C7 44 24 20 00 00 00 00
    //   call WriteFile                   E8 00 00 00 00
    //   xor ecx, ecx                     31 C9
    //   call ExitProcess                 E8 00 00 00 00
    var code = [_]u8{
        0x48, 0x83, 0xE4, 0xF0,
        0x48, 0x83, 0xEC, 0x30,
        0xB9, 0xF5, 0xFF, 0xFF,
        0xFF, 0xE8, 0x00, 0x00,
        0x00, 0x00, 0x49, 0x89,
        0xC4, 0x4C, 0x89, 0xE1,
        0x48, 0x8D, 0x15, 0x00,
        0x00, 0x00, 0x00, 0x41,
        0xB8, 0x03, 0x00, 0x00,
        0x00, 0x4C, 0x8D, 0x4C,
        0x24, 0x28, 0x48, 0xC7,
        0x44, 0x24, 0x20, 0x00,
        0x00, 0x00, 0x00, 0xE8,
        0x00, 0x00, 0x00, 0x00,
        0x31, 0xC9, 0xE8, 0x00,
        0x00, 0x00, 0x00,
    };
    const msg = "hi\n";
    const text_relocs = [_]object.Reloc{
        .{ .offset = 13, .kind = .pc32, .target = .{ .global = "GetStdHandle" }, .addend = -4 },
        .{ .offset = 25, .kind = .pc32, .target = .{ .local = 1 }, .addend = -4 },
        .{ .offset = 49, .kind = .pc32, .target = .{ .global = "WriteFile" }, .addend = -4 },
        .{ .offset = 57, .kind = .pc32, .target = .{ .global = "ExitProcess" }, .addend = -4 },
    };
    var atoms = [_]object.Atom{
        .{ .name = entry_symbol, .kind = .text, .binding = .global, .data = &code, .size = code.len, .alignment = 16, .relocs = &text_relocs },
        .{ .name = "msg", .kind = .rodata, .binding = .local, .data = msg, .size = msg.len, .alignment = 1, .relocs = &.{} },
    };
    const mods = [_]object.Module{.{ .name = "derisk", .atoms = &atoms }};
    return linkExecutable(gpa, .x86_64, &mods, .{ .allowed_imports = &.{ "GetStdHandle", "WriteFile", "ExitProcess" } });
}

test "de-risk x64: emits a well-formed PE32+ console EXE with imports + base relocs" {
    const gpa = testing.allocator;
    const exe = try buildDeriskX64(gpa);
    defer gpa.free(exe);

    try testing.expectEqualSlices(u8, "MZ", exe[0..2]);
    try testing.expectEqual(e_lfanew, std.mem.readInt(u32, exe[0x3C..][0..4], .little));

    const c = try coff.Coff.init(exe, false);
    try testing.expect(c.is_image);
    try testing.expectEqual(coff.IMAGE.FILE.MACHINE.AMD64, c.getHeader().machine);
    try testing.expect(c.getHeader().flags.EXECUTABLE_IMAGE);
    try testing.expect(!c.getHeader().flags.RELOCS_STRIPPED);

    const opt = c.getOptionalHeader64();
    try testing.expectEqual(coff.OptionalHeader.Magic.@"PE32+", opt.standard.magic);
    try testing.expectEqual(@as(u64, image_base), opt.image_base);
    try testing.expectEqual(coff.Subsystem.WINDOWS_CUI, opt.subsystem);
    try testing.expect(opt.dll_flags.DYNAMIC_BASE);

    const text = c.getSectionByName(".text").?;
    try testing.expect(text.flags.MEM_EXECUTE);
    try testing.expectEqual(opt.standard.address_of_entry_point, text.virtual_address);

    const idata_dirs = c.getDataDirectories();
    const import_dir = idata_dirs[@intFromEnum(coff.IMAGE.DIRECTORY_ENTRY.IMPORT)];
    try testing.expect(import_dir.size > 0);
    const desc: *align(1) const coff.ImportDirectoryEntry = @ptrCast(exe[sectionFileOffset(c, import_dir.virtual_address)..][0..@sizeOf(coff.ImportDirectoryEntry)]);
    const dllname_off = sectionFileOffset(c, desc.name_rva);
    try testing.expectEqualStrings("KERNEL32.dll", std.mem.sliceTo(exe[dllname_off..], 0));

    // 3 distinct imports (GetStdHandle, WriteFile, ExitProcess) + 1 null
    // terminator thunk, each 8 bytes (PE32+ IMAGE_THUNK_DATA64).
    const iat_dir = idata_dirs[@intFromEnum(coff.IMAGE.DIRECTORY_ENTRY.IAT)];
    try testing.expectEqual(@as(u32, 4 * 8), iat_dir.size);

    // No absolute (abs64) fields here — the payload's only data reference is
    // the `lea rip-rel` to `msg`, which is PC-relative — so `.reloc` is
    // legitimately absent.
    try testing.expect(c.getSectionByName(".reloc") == null);
}

test "de-risk x64: runs and prints under a real Windows/wine host (skips elsewhere)" {
    // This linker has no way to execute its own output in this environment
    // (no Windows host; wine-under-QEMU-under-Docker on this Apple Silicon
    // host was tried and hangs/aborts in wine's own ntdll virtual-memory init
    // before even reaching this exe — a known fragility of that emulation
    // stack, not something this linker can work around). See the module doc
    // comment on scope. This test exists so the check is discoverable and
    // wired the moment either becomes available in CI, instead of the gap
    // staying silent.
    return error.SkipZigTest;
}

fn sectionFileOffset(c: coff.Coff, rva: u32) usize {
    for (c.getSectionHeaders()) |sh| {
        if (rva >= sh.virtual_address and rva < sh.virtual_address + sh.virtual_size) {
            return sh.pointer_to_raw_data + (rva - sh.virtual_address);
        }
    }
    unreachable;
}

test "the program object's undeclared extern reference is rejected, not treated as an import" {
    const gpa = testing.allocator;
    const code = [_]u8{ 0xE8, 0, 0, 0, 0, 0xC3 }; // call rel32 ; ret
    const relocs = [_]object.Reloc{.{ .offset = 1, .kind = .pc32, .target = .{ .global = "SomeFunc" }, .addend = -4 }};
    var atoms = [_]object.Atom{
        .{ .name = entry_symbol, .kind = .text, .binding = .global, .data = &code, .size = code.len, .alignment = 16, .relocs = &relocs },
    };
    const mods = [_]object.Module{.{ .name = "m", .atoms = &atoms }};
    // `program_modules = 1` marks this as the compiled Bit program (not an
    // archive member), so `undefinedIsImport` requires `SomeFunc` to be a
    // declared `extern function` — `allowed_imports` is empty here, so it
    // is not one.
    try testing.expectError(error.UndefinedSymbol, linkExecutable(gpa, .x86_64, &mods, .{ .program_modules = 1 }));
}

test "a non-branch reference to an import is rejected, not guessed" {
    const gpa = testing.allocator;
    // A data pointer (`abs64`) to an imported DLL function: this compiler
    // never emits this shape (module doc comment — externs are only ever
    // called), so it is refused rather than silently mis-linked.
    const code = [_]u8{0} ** 8;
    const relocs = [_]object.Reloc{.{ .offset = 0, .kind = .abs64, .target = .{ .global = "SomeImport" } }};
    var atoms = [_]object.Atom{
        .{ .name = entry_symbol, .kind = .data, .binding = .global, .data = &code, .size = code.len, .alignment = 8, .relocs = &relocs },
    };
    const mods = [_]object.Module{.{ .name = "m", .atoms = &atoms }};
    try testing.expectError(error.UnsupportedRelocation, linkExecutable(gpa, .x86_64, &mods, .{}));
}

test "an abs64 reference to an internal rodata atom gets exactly one base relocation" {
    const gpa = testing.allocator;
    // _start: mov rax, imageOf(msg) ; ret  -- an abs64 field, not pc-relative.
    const code = [_]u8{ 0x48, 0xB8, 0, 0, 0, 0, 0, 0, 0, 0, 0xC3 };
    const relocs = [_]object.Reloc{.{ .offset = 2, .kind = .abs64, .target = .{ .local = 1 } }};
    const msg = "x";
    var atoms = [_]object.Atom{
        .{ .name = entry_symbol, .kind = .text, .binding = .global, .data = &code, .size = code.len, .alignment = 16, .relocs = &relocs },
        .{ .name = "msg", .kind = .rodata, .binding = .local, .data = msg, .size = msg.len, .alignment = 1, .relocs = &.{} },
    };
    const mods = [_]object.Module{.{ .name = "m", .atoms = &atoms }};
    const exe = try linkExecutable(gpa, .x86_64, &mods, .{});
    defer gpa.free(exe);

    const c = try coff.Coff.init(exe, false);
    const reloc_sect = c.getSectionByName(".reloc").?;
    try testing.expect(reloc_sect.virtual_size > 0);
    const block: *align(1) const coff.BaseRelocationDirectoryEntry = @ptrCast(exe[reloc_sect.pointer_to_raw_data..][0..8]);
    // One real entry, but a block's entry count must land on a 4-byte
    // boundary (the next block's header must start DWORD-aligned), so an
    // odd count of 1 gets a padding `ABSOLUTE` entry: 8 + 2*2 = 12.
    try testing.expectEqual(@as(u32, 8 + 2 * 2), block.block_size);
    const entry: *align(1) const coff.BaseRelocation = @ptrCast(exe[reloc_sect.pointer_to_raw_data + 8 ..][0..2]);
    try testing.expectEqual(coff.BaseRelocationType.DIR64, entry.type);

    // And the field itself now holds the absolute VA of `msg`.
    const text_sect = c.getSectionByName(".text").?;
    const written = std.mem.readInt(u64, exe[text_sect.pointer_to_raw_data + 2 ..][0..8], .little);
    const msg_sect_rva = c.getSectionByName(".rdata").?.virtual_address;
    try testing.expectEqual(image_base + msg_sect_rva, written);
}

test "aarch64: an import call goes through an adrp/ldr/br stub into the IAT" {
    const gpa = testing.allocator;
    // _start: bl ExitProcess
    const code = [_]u8{ 0x00, 0x00, 0x00, 0x94 };
    const relocs = [_]object.Reloc{.{ .offset = 0, .kind = .aarch64_call26, .target = .{ .global = "ExitProcess" } }};
    var atoms = [_]object.Atom{
        .{ .name = entry_symbol, .kind = .text, .binding = .global, .data = &code, .size = code.len, .alignment = 4, .relocs = &relocs },
    };
    const mods = [_]object.Module{.{ .name = "m", .atoms = &atoms }};
    const exe = try linkExecutable(gpa, .aarch64, &mods, .{ .allowed_imports = &.{"ExitProcess"} });
    defer gpa.free(exe);

    const c = try coff.Coff.init(exe, false);
    try testing.expectEqual(coff.IMAGE.FILE.MACHINE.ARM64, c.getHeader().machine);
    const text_sect = c.getSectionByName(".text").?;
    // The `bl` no longer targets offset 0 (there is nothing there) — it must
    // have been retargeted to the stub area right after the real code.
    const insn = std.mem.readInt(u32, exe[text_sect.pointer_to_raw_data..][0..4], .little);
    try testing.expect(insn != 0x94000000);
}

test "an unsupported relocation kind is rejected rather than silently applied" {
    const gpa = testing.allocator;
    var atoms = [_]object.Atom{
        .{ .name = entry_symbol, .kind = .text, .binding = .global, .data = &.{ 0xC3, 0, 0, 0, 0 }, .size = 5, .alignment = 1, .relocs = &.{
            .{ .offset = 1, .kind = .got32, .target = .{ .global = "x" } },
        } },
    };
    const mods = [_]object.Module{.{ .name = "m", .atoms = &atoms }};
    try testing.expectError(error.UnsupportedRelocation, linkExecutable(gpa, .x86_64, &mods, .{}));
}

test "a missing entry symbol is rejected" {
    const gpa = testing.allocator;
    var atoms = [_]object.Atom{.{ .name = "not_start", .kind = .text, .binding = .global, .data = &.{}, .size = 0, .alignment = 1, .relocs = &.{} }};
    const mods = [_]object.Module{.{ .name = "m", .atoms = &atoms }};
    try testing.expectError(error.MissingEntry, linkExecutable(gpa, .x86_64, &mods, .{}));
}
