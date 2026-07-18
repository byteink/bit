//! Back-end adapter (task #347): turns a lowered `ir.Module` into relocatable
//! object bytes. Codegen's per-function `FuncCode` (machine code + call/abs
//! relocations) is concatenated into `.text`; the module's string pool becomes
//! `.rodata` (`{ptr,len}` headers + bytes, the v1 static-string layout); a
//! `bit_main` entry trampoline calls the user's `main` and yields its `i32`
//! (or 0 for a `void` main) as the process exit code the runtime's `_start`
//! expects (runtime/ABI.md). Every relocation target the object does not itself
//! define (runtime `bit_rt_*` symbols) is emitted as an undefined external so
//! the object writer accepts it and the linker resolves it against `libbitrt.a`.
//!
//! x86-64 only for now; the ARM64 path joins when its Mach-O writer lands.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ir = @import("ir.zig");
const x64 = @import("codegen/x64.zig");
const arm64 = @import("codegen/arm64.zig");
const common = @import("codegen/common.zig");
const obj_elf = @import("obj/elf.zig");
const obj_macho = @import("obj/macho.zig");

pub const Error = error{ NoMain, FreestandingAlloc, FreestandingSafepoint } || x64.CodegenError || obj_elf.Error || obj_macho.Error || Allocator.Error;

/// §17.6: may this function go into a freestanding object? A freestanding
/// object carries no `bit_stack_maps`, so the collector could not scan the
/// frame of a function it contains — which is sound only for a function that
/// can never be on the stack when a collection begins.
///
/// The test is the DECLARATION (`@nosplit`/`@naked`), not the emitted safepoint
/// list, and the difference matters. Codegen records a safepoint at every
/// surviving call, because in general a callee may collect; `@nosplit`
/// suppresses only the back-edge one. So "has no safepoints" is true of almost
/// nothing that calls anything — it would reject a runtime module the moment it
/// called a sibling, which is the entire case this mode exists for. What
/// actually makes the missing stack map sound is §10.3's standing obligation on
/// `@nosplit`: it may not allocate and may not reach a safepoint, so no
/// collection can begin beneath it. Requiring the attribute makes that
/// obligation explicit in the source and checkable by reading it.
fn freestandingEligible(f: *const ir.Function) bool {
    return f.is_nosplit or f.is_naked;
}

/// §17.6: does this function belong in a freestanding object? A freestanding
/// emit keeps only the ROOT module's own code, so an imported module's
/// functions are left out and calls into them stay undefined relocations the
/// linker resolves against that module's own object. `is_extern` is skipped on
/// both paths: a declaration defines nothing either way.
fn emitsFunction(f: *const ir.Function, freestanding: bool) bool {
    if (f.is_extern) return false;
    return f.in_root_module or !freestanding;
}

/// §17.6: refuses a module that needs the managed runtime's whole-program
/// tables, which a freestanding object cannot carry — a `TypeInfo` descriptor
/// is a global symbol every sibling member describing the same layout would
/// also define, and there is exactly one `bit_stack_maps` per link.
///
/// Runs BEFORE codegen, ahead of the per-function safepoint check, because
/// allocating is the cause and reaching a safepoint is usually its consequence:
/// diagnosing the consequence would send the reader off to add `@nosplit` to a
/// function whose real problem is that it allocates.
fn refuseManagedMetadata(a: Allocator, module: *const ir.Module) Error!void {
    if ((try collectTypeInfos(a, module, true)).len > 0) return error.FreestandingAlloc;
}

/// Symbol naming the module's GC stack-map table (`runtime/ABI.md` §4); the
/// runtime reads it via a `bit_stack_maps` extern to walk Bit frames at a
/// collection. Mach-O prefixes it `_` like every other symbol.
const stackmaps_symbol = "bit_stack_maps";

/// Builds one function's arch-neutral stack-map view (arena-owned) from its
/// backend `FuncCode` records. `Sp` is the backend's `SafepointEntry` type;
/// its `regs` are physical registers whose numbers (`@intFromEnum`) the
/// runtime indexes directly. `frame_offsets` are already frame-pointer-relative
/// (both backends normalize to that). Kept generic because x86-64 and ARM64
/// carry structurally identical records under distinct `Reg` enums.
fn stackMapOf(a: Allocator, code_size: usize, saved: []const common.SavedReg, comptime Sp: type, safepoints: []const Sp) Allocator.Error!common.FuncStackMap {
    const views = try a.alloc(common.SafepointView, safepoints.len);
    for (safepoints, 0..) |sp, i| {
        const regs = try a.alloc(u16, sp.regs.len);
        for (sp.regs, 0..) |r, ri| regs[ri] = @intFromEnum(r);
        views[i] = .{ .ret_offset = sp.code_offset, .slots = try a.dupe(i32, sp.frame_offsets), .regs = regs };
    }
    return .{ .code_size = @intCast(code_size), .saved = try a.dupe(common.SavedReg, saved), .safepoints = views };
}

/// One distinct `TypeInfo` blob the runtime's `bit_rt_gc_alloc` reads
/// (runtime/gc.zig). `disc` is the type discriminator (`@intFromEnum(TypeId)` of
/// the allocation's result type) — descriptors are per type, not per layout, so
/// each type's method table (ABI.md §2.1) attaches to the right one. `size` is
/// the body size; `ptr_offsets` the byte offsets of pointer fields the GC scans.
const TypeInfoLayout = struct { disc: u32, size: u32, ptr_offsets: []const u32 };

/// Every distinct `TypeInfo` in the module, deduped by its symbol name (so a
/// type used at many allocation sites shares one blob). Bytes owned by `a`.
fn collectTypeInfos(a: Allocator, module: *const ir.Module, freestanding: bool) Allocator.Error![]TypeInfoLayout {
    var seen = std.StringHashMapUnmanaged(void){};
    var out: std.ArrayList(TypeInfoLayout) = .empty;
    for (module.funcs.items) |*f| {
        // §17.6: a descriptor is only needed for code this object emits.
        if (!emitsFunction(f, freestanding)) continue;
        var i: u32 = 0;
        while (i < f.insts.len) : (i += 1) {
            // A `make_closure` allocates the fixed 16-byte `{code, env}` cell
            // (see x64/arm64 codegen); its env pointer at +8 is the one GC field.
            const layout: TypeInfoLayout = switch (f.insts.items(.op)[i]) {
                .gc_alloc => blk: {
                    const g = f.decode(@enumFromInt(i)).gc_alloc;
                    break :blk .{ .disc = @intFromEnum(f.valueType(@enumFromInt(i))), .size = g.size, .ptr_offsets = g.ptr_offsets };
                },
                .make_closure => .{ .disc = @intFromEnum(f.valueType(@enumFromInt(i))), .size = 16, .ptr_offsets = &.{8} },
                // A type assertion references a descriptor without allocating
                // one, so its target's blob must be emitted here too — the
                // target may never be `gc_alloc`ed in this module.
                .type_info => blk: {
                    const t = f.decode(@enumFromInt(i)).type_info;
                    break :blk .{ .disc = t.disc, .size = t.size, .ptr_offsets = t.ptr_offsets };
                },
                else => continue,
            };
            const name = try ir.typeInfoSymbol(a, layout.disc, layout.size, layout.ptr_offsets);
            if (seen.contains(name)) continue;
            try seen.put(a, name, {});
            try out.append(a, layout);
        }
    }
    return out.toOwnedSlice(a);
}

/// A function-pointer relocation site inside a method table: patch `off` to the
/// absolute address of the `.text` symbol `sym`.
const FnReloc = struct { off: u64, sym: []const u8 };

/// A type's emitted method table (ABI.md §2.1): the local array symbol, its
/// rodata offset/size, and the per-entry `fn` relocation sites. Empty
/// (`sym.len == 0`) for a type with no methods.
const EmittedMethods = struct { sym: []const u8, off: u64, size: usize, relocs: []const FnReloc };

/// Appends a type's method table to `rodata` as `Method[]` (`{ u64 id, u64 fn }`
/// each) and returns its placement + `fn` reloc sites. Format-neutral: the ELF
/// and Mach-O emitters each turn `relocs` into their own abs64/unsigned64
/// relocation records, keeping the byte layout identical across formats.
fn emitMethodTable(a: Allocator, module: *const ir.Module, rodata: *std.ArrayList(u8), disc: u32, ti_symbol: []const u8) Error!EmittedMethods {
    const mt = module.methodTable(disc) orelse return .{ .sym = "", .off = 0, .size = 0, .relocs = &.{} };
    while (rodata.items.len % 8 != 0) try rodata.append(a, 0);
    const base: u64 = rodata.items.len;
    var relocs: std.ArrayList(FnReloc) = .empty;
    for (mt.methods) |m| {
        var b: [8]u8 = undefined;
        std.mem.writeInt(u64, &b, m.id, .little);
        try rodata.appendSlice(a, &b); // id
        try relocs.append(a, .{ .off = rodata.items.len, .sym = module.func(m.func).name });
        try rodata.appendSlice(a, &(.{0} ** 8)); // fn — filled by the reloc
    }
    const name = try std.fmt.allocPrint(a, "{s}_methods", .{ti_symbol});
    return .{ .sym = name, .off = base, .size = mt.methods.len * 16, .relocs = try relocs.toOwnedSlice(a) };
}

/// Emits `module` as an x86-64 ELF relocatable object. The returned bytes are
/// owned by `gpa`; with `with_entry` the module's `main` becomes the runtime
/// entry, otherwise no `main` is required and no trampoline is emitted (#1397 —
/// the plain relocatable an archive member is made of).
pub fn emitObject(gpa: Allocator, module: *const ir.Module, with_entry: bool, freestanding: bool) Error![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var code: std.ArrayList(u8) = .empty;
    var rodata: std.ArrayList(u8) = .empty;
    var symbols: std.ArrayList(obj_elf.Symbol) = .empty;
    var relocs: std.ArrayList(obj_elf.Relocation) = .empty;
    var defined = std.StringHashMapUnmanaged(void){};
    var stackmaps: std.ArrayList(common.FuncStackMap) = .empty;
    var emitted_names: std.ArrayList([]const u8) = .empty;
    if (freestanding) try refuseManagedMetadata(a, module);

    // ---- every function -> one .text symbol + its relocations -------------
    var main_void = false;
    var have_main = false;
    for (module.funcs.items) |*f| {
        // §11.7: a declaration, not a definition — emit no code and, decisively,
        // leave it OUT of `defined` so every call to it stays an undefined
        // symbol the linker resolves (Mach-O: a libSystem import).
        // §17.6: an imported module's function is skipped the same way.
        if (!emitsFunction(f, freestanding)) continue;
        if (freestanding and !freestandingEligible(f)) return error.FreestandingSafepoint;
        var fc = try x64.compileFunction(gpa, module, f, .sysv);
        defer fc.deinit();
        const off: u64 = code.items.len;
        try code.appendSlice(a, fc.code);
        try symbols.append(a, .{ .name = try a.dupe(u8, f.name), .section = .text, .offset = off, .size = fc.code.len, .binding = .global, .kind = .func });
        try defined.put(a, f.name, {});
        for (fc.relocs) |r| try relocs.append(a, .{
            .section = .text,
            .offset = off + r.offset,
            .symbol = try a.dupe(u8, r.symbol),
            .kind = switch (r.kind) {
                .call => .pc32,
                .abs64 => .abs64,
            },
            .addend = switch (r.kind) {
                .call => -4,
                .abs64 => 0,
            },
        });
        try stackmaps.append(a, try stackMapOf(a, fc.code.len, fc.saved_regs, x64.SafepointEntry, fc.safepoints));
        try emitted_names.append(a, f.name);
        if (std.mem.eql(u8, f.name, "main")) {
            have_main = true;
            main_void = module.ctx.typeOf(f.result) == .void;
        }
    }
    if (with_entry) {
        if (!have_main) return error.NoMain;

        // ---- bit_main entry trampoline ------------------------------------
        // On entry rsp%16==8 (the call into bit_main pushed a return address); a
        // single `sub rsp,8` re-aligns it so the SysV call below is 16-aligned.
        //   sub rsp,8 ; call main ; [xor eax,eax if void] ; add rsp,8 ; ret
        const tramp: u64 = code.items.len;
        try code.appendSlice(a, &.{ 0x48, 0x83, 0xEC, 0x08 });
        try code.append(a, 0xE8);
        const call_field: u64 = code.items.len;
        try code.appendSlice(a, &.{ 0, 0, 0, 0 });
        try relocs.append(a, .{ .section = .text, .offset = call_field, .symbol = "main", .kind = .pc32, .addend = -4 });
        if (main_void) try code.appendSlice(a, &.{ 0x31, 0xC0 }); // void main -> exit 0
        try code.appendSlice(a, &.{ 0x48, 0x83, 0xC4, 0x08, 0xC3 });
        try symbols.append(a, .{ .name = "bit_main", .section = .text, .offset = tramp, .size = code.items.len - tramp, .binding = .global, .kind = .func });
        try defined.put(a, "bit_main", {});
    }

    try emitElfBlobs(a, module, &rodata, &symbols, &relocs, &defined, stackmaps.items, emitted_names.items, freestanding);

    var sections: std.ArrayList(obj_elf.Section) = .empty;
    try sections.append(a, .{ .kind = .text, .data = code.items, .alignment = 16 });
    if (rodata.items.len > 0) try sections.append(a, .{ .kind = .rodata, .data = rodata.items, .alignment = 8 });

    return obj_elf.write(gpa, .x86_64, .{ .sections = sections.items, .symbols = symbols.items, .relocations = relocs.items });
}

/// Emits the arch-independent ELF data — string-pool headers, gc_alloc TypeInfo
/// blobs (`extern struct TypeInfo { size, ptr_offsets_ptr, ptr_offsets_len,
/// name_ptr, name_len, methods_ptr, methods_len }`, preceded by its usize[]
/// offsets and any Method[] table, ABI.md §2.1), and the GC stack-map table —
/// all into `.rodata` with `abs64` pointer relocations — then declares an
/// undefined extern for every referenced-but-undefined symbol (the runtime
/// `bit_rt_*` calls). Shared by `emitObject` (x86-64) and `emitObjectArm64Elf`;
/// their only differences (codegen, the entry trampoline, the code-relocation
/// kinds) are all handled by the caller before this runs.
fn emitElfBlobs(
    a: Allocator,
    module: *const ir.Module,
    rodata: *std.ArrayList(u8),
    symbols: *std.ArrayList(obj_elf.Symbol),
    relocs: *std.ArrayList(obj_elf.Relocation),
    defined: *std.StringHashMapUnmanaged(void),
    stackmaps: []const common.FuncStackMap,
    /// The `.text` symbol names, in `stackmaps` order — NOT `module.funcs`
    /// order, which skips declarations and (freestanding) imported modules.
    emitted_names: []const []const u8,
    freestanding: bool,
) !void {
    std.debug.assert(emitted_names.len == stackmaps.len);
    // §17.6: a freestanding object is one archive member among many, so every
    // symbol it defines globally is a symbol some sibling member may define
    // too. A string literal has no external linkage — nothing outside this
    // object ever names `__bitstr_N` — so the header goes local and two
    // members' literals stop colliding at link.
    //
    // NOT REACHABLE TODAY, and deliberately kept: §10.3's `@nosplit` whitelist
    // admits no string operation, so a freestanding module's string pool is
    // always empty and this branch never fires. It is here because the whitelist
    // has to widen for #1363/#1364 (gc/sched need `asm`), and the day a literal
    // becomes reachable the global binding would surface as a `__bitstr_0`
    // duplicate between two members — a failure whose symptom points nowhere
    // near its cause.
    const blob_binding: obj_elf.Binding = if (freestanding) .local else .global;

    // ---- string pool -> .rodata headers + bytes ---------------------------
    for (module.string_pool.items, 0..) |s, i| {
        const data_off: u64 = rodata.items.len;
        try rodata.appendSlice(a, s);
        const data_name = try std.fmt.allocPrint(a, "__bitstr_{d}_data", .{i});
        try symbols.append(a, .{ .name = data_name, .section = .rodata, .offset = data_off, .size = s.len, .binding = .local, .kind = .object });
        try defined.put(a, data_name, {});

        while (rodata.items.len % 8 != 0) try rodata.append(a, 0);
        const hdr_off: u64 = rodata.items.len;
        try rodata.appendSlice(a, &(.{0} ** 8)); // ptr — filled by the reloc below
        var lenbuf: [8]u8 = undefined;
        std.mem.writeInt(u64, &lenbuf, s.len, .little);
        try rodata.appendSlice(a, &lenbuf); // len
        const hdr_name = try std.fmt.allocPrint(a, "__bitstr_{d}", .{i});
        try symbols.append(a, .{ .name = hdr_name, .section = .rodata, .offset = hdr_off, .size = 16, .binding = blob_binding, .kind = .object });
        try defined.put(a, hdr_name, {});
        try relocs.append(a, .{ .section = .rodata, .offset = hdr_off, .symbol = data_name, .kind = .abs64, .addend = 0 });
    }

    // ---- gc_alloc TypeInfo blobs -> .rodata -------------------------------
    // §17.6: `refuseManagedMetadata` already rejected a freestanding module
    // that needs any of these, so this list is empty on that path.
    for (try collectTypeInfos(a, module, freestanding)) |ti| {
        const name = try ir.typeInfoSymbol(a, ti.disc, ti.size, ti.ptr_offsets);
        var offs_name: []const u8 = "";
        if (ti.ptr_offsets.len > 0) {
            while (rodata.items.len % 8 != 0) try rodata.append(a, 0);
            const offs_off: u64 = rodata.items.len;
            for (ti.ptr_offsets) |off| {
                var b: [8]u8 = undefined;
                std.mem.writeInt(u64, &b, off, .little);
                try rodata.appendSlice(a, &b);
            }
            offs_name = try std.fmt.allocPrint(a, "{s}_offs", .{name});
            try symbols.append(a, .{ .name = offs_name, .section = .rodata, .offset = offs_off, .size = ti.ptr_offsets.len * 8, .binding = .local, .kind = .object });
            try defined.put(a, offs_name, {});
        }
        const tname = module.ctx.display_names.get(ti.disc) orelse "";
        var name_sym: []const u8 = "";
        if (tname.len > 0) {
            const nm_off: u64 = rodata.items.len;
            try rodata.appendSlice(a, tname);
            name_sym = try std.fmt.allocPrint(a, "{s}_name", .{name});
            try symbols.append(a, .{ .name = name_sym, .section = .rodata, .offset = nm_off, .size = tname.len, .binding = .local, .kind = .object });
            try defined.put(a, name_sym, {});
        }
        const methods = try emitMethodTable(a, module, rodata, ti.disc, name);
        if (methods.sym.len > 0) {
            try symbols.append(a, .{ .name = methods.sym, .section = .rodata, .offset = methods.off, .size = methods.size, .binding = .local, .kind = .object });
            try defined.put(a, methods.sym, {});
        }
        while (rodata.items.len % 8 != 0) try rodata.append(a, 0);
        const ti_off: u64 = rodata.items.len;
        var field: [8]u8 = undefined;
        std.mem.writeInt(u64, &field, ti.size, .little);
        try rodata.appendSlice(a, &field); // size
        try rodata.appendSlice(a, &(.{0} ** 8)); // ptr_offsets_ptr (reloc below if any)
        std.mem.writeInt(u64, &field, ti.ptr_offsets.len, .little);
        try rodata.appendSlice(a, &field); // ptr_offsets_len
        try rodata.appendSlice(a, &(.{0} ** 8)); // name_ptr (reloc below if any)
        std.mem.writeInt(u64, &field, tname.len, .little);
        try rodata.appendSlice(a, &field); // name_len
        try rodata.appendSlice(a, &(.{0} ** 8)); // methods_ptr (reloc below if any)
        std.mem.writeInt(u64, &field, methods.size / 16, .little);
        try rodata.appendSlice(a, &field); // methods_len
        try symbols.append(a, .{ .name = name, .section = .rodata, .offset = ti_off, .size = 56, .binding = .global, .kind = .object });
        try defined.put(a, name, {});
        if (ti.ptr_offsets.len > 0)
            try relocs.append(a, .{ .section = .rodata, .offset = ti_off + 8, .symbol = offs_name, .kind = .abs64, .addend = 0 });
        if (name_sym.len > 0)
            try relocs.append(a, .{ .section = .rodata, .offset = ti_off + 24, .symbol = name_sym, .kind = .abs64, .addend = 0 });
        if (methods.sym.len > 0)
            try relocs.append(a, .{ .section = .rodata, .offset = ti_off + 40, .symbol = methods.sym, .kind = .abs64, .addend = 0 });
        for (methods.relocs) |r|
            try relocs.append(a, .{ .section = .rodata, .offset = r.off, .symbol = r.sym, .kind = .abs64, .addend = 0 });
    }

    // ---- GC stack-map table (runtime/ABI.md §4) -> .rodata ----------------
    // §17.6: `bit_stack_maps` is a whole-PROGRAM table under one fixed name the
    // runtime reads, so exactly one object in a link may define it — never an
    // archive member. A freestanding object emits none and instead refuses any
    // function that would need an entry (below), so nothing is silently lost.
    if (!freestanding) {
        const blob_off: u64 = rodata.items.len;
        const code_relocs = try common.writeStackMaps(a, rodata, stackmaps);
        try symbols.append(a, .{ .name = stackmaps_symbol, .section = .rodata, .offset = blob_off, .size = rodata.items.len - blob_off, .binding = .global, .kind = .object });
        try defined.put(a, stackmaps_symbol, {});
        // `writeStackMaps` records offsets against `rodata` itself, so they are
        // already section-relative — do not add `blob_off` again.
        for (code_relocs, 0..) |ro, fi| try relocs.append(a, .{
            .section = .rodata,
            .offset = ro,
            .symbol = try a.dupe(u8, emitted_names[fi]),
            .kind = .abs64,
            .addend = 0,
        });
    }

    // ---- undefined externals (runtime `bit_rt_*` symbols) -----------------
    var externs = std.StringHashMapUnmanaged(void){};
    for (relocs.items) |r| {
        if (defined.contains(r.symbol) or externs.contains(r.symbol)) continue;
        try externs.put(a, r.symbol, {});
        try symbols.append(a, .{ .name = r.symbol, .section = null, .binding = .global, .kind = .notype });
    }
}

/// Emits `module` as an AArch64 ELF relocatable object — the arm64-linux
/// analogue of `emitObject`. Same non-PIE static data layout (string/TypeInfo/
/// stack-map blobs in `.rodata`, absolute pointers via `abs64` — shared through
/// `emitElfBlobs`), but the function bodies and the `bit_main` entry trampoline
/// use AArch64 encodings, and code relocations are the ADRP/ADD/BL kinds arm64
/// codegen emits.
pub fn emitObjectArm64Elf(gpa: Allocator, module: *const ir.Module, with_entry: bool, freestanding: bool) Error![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var code: std.ArrayList(u8) = .empty;
    var rodata: std.ArrayList(u8) = .empty;
    var symbols: std.ArrayList(obj_elf.Symbol) = .empty;
    var relocs: std.ArrayList(obj_elf.Relocation) = .empty;
    var defined = std.StringHashMapUnmanaged(void){};
    var stackmaps: std.ArrayList(common.FuncStackMap) = .empty;
    var emitted_names: std.ArrayList([]const u8) = .empty;
    if (freestanding) try refuseManagedMetadata(a, module);

    // ---- every function -> one .text symbol + its relocations -------------
    var main_void = false;
    var have_main = false;
    for (module.funcs.items) |*f| {
        // §11.7: a declaration, not a definition — emit no code and, decisively,
        // leave it OUT of `defined` so every call to it stays an undefined
        // symbol the linker resolves (Mach-O: a libSystem import).
        // §17.6: an imported module's function is skipped the same way.
        if (!emitsFunction(f, freestanding)) continue;
        if (freestanding and !freestandingEligible(f)) return error.FreestandingSafepoint;
        var fc = try arm64.compileFunction(gpa, module, f);
        defer fc.deinit();
        const off: u64 = code.items.len;
        try code.appendSlice(a, fc.code);
        try symbols.append(a, .{ .name = try a.dupe(u8, f.name), .section = .text, .offset = off, .size = fc.code.len, .binding = .global, .kind = .func });
        try defined.put(a, f.name, {});
        for (fc.relocs) |r| try relocs.append(a, .{
            .section = .text,
            .offset = off + r.offset,
            .symbol = try a.dupe(u8, r.symbol),
            .kind = switch (r.kind) {
                .branch => .aarch64_call26,
                .page21 => .aarch64_adr_prel_pg_hi21,
                .pageoff12 => .aarch64_add_abs_lo12_nc,
            },
            .addend = 0,
        });
        try stackmaps.append(a, try stackMapOf(a, fc.code.len, fc.saved_regs, arm64.SafepointEntry, fc.safepoints));
        try emitted_names.append(a, f.name);
        if (std.mem.eql(u8, f.name, "main")) {
            have_main = true;
            main_void = module.ctx.typeOf(f.result) == .void;
        }
    }
    if (with_entry) {
        if (!have_main) return error.NoMain;

        // ---- bit_main entry trampoline (AArch64) --------------------------
        //   stp x29,x30,[sp,#-16]! ; bl main ; [movz w0,#0 if void] ; ldp ; ret
        const tramp: u64 = code.items.len;
        try appendWord(&code, a, 0xA9BF7BFD); // stp x29, x30, [sp, #-16]!
        const call_field: u64 = code.items.len;
        try appendWord(&code, a, 0x94000000); // bl main (placeholder)
        try relocs.append(a, .{ .section = .text, .offset = call_field, .symbol = "main", .kind = .aarch64_call26, .addend = 0 });
        if (main_void) try appendWord(&code, a, 0x52800000); // movz w0, #0
        try appendWord(&code, a, 0xA8C17BFD); // ldp x29, x30, [sp], #16
        try appendWord(&code, a, 0xD65F03C0); // ret
        try symbols.append(a, .{ .name = "bit_main", .section = .text, .offset = tramp, .size = code.items.len - tramp, .binding = .global, .kind = .func });
        try defined.put(a, "bit_main", {});
    }

    try emitElfBlobs(a, module, &rodata, &symbols, &relocs, &defined, stackmaps.items, emitted_names.items, freestanding);

    var sections: std.ArrayList(obj_elf.Section) = .empty;
    try sections.append(a, .{ .kind = .text, .data = code.items, .alignment = 16 });
    if (rodata.items.len > 0) try sections.append(a, .{ .kind = .rodata, .data = rodata.items, .alignment = 8 });

    return obj_elf.write(gpa, .aarch64, .{ .sections = sections.items, .symbols = symbols.items, .relocations = relocs.items });
}

/// Emits `module` as an ARM64 Mach-O relocatable object (macOS). Same shape as
/// `emitObject` above, with three format differences: every symbol name is
/// `_`-prefixed (the Mach-O ABI convention `libbitrt` for macOS also follows),
/// the entry trampoline and address-of use AArch64 encodings, and a
/// `const_string` header address is materialized by a PC-relative `ADRP`/`ADD`
/// pair (`page21`/`pageoff12`) rather than x86-64's absolute `movabs`.
pub fn emitMachoObject(gpa: Allocator, module: *const ir.Module, with_entry: bool, freestanding: bool) Error![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var code: std.ArrayList(u8) = .empty;
    var rodata: std.ArrayList(u8) = .empty;
    var data: std.ArrayList(u8) = .empty;
    var symbols: std.ArrayList(obj_macho.Symbol) = .empty;
    var relocs: std.ArrayList(obj_macho.Relocation) = .empty;
    var defined = std.StringHashMapUnmanaged(void){};
    var stackmaps: std.ArrayList(common.FuncStackMap) = .empty;
    var emitted_names: std.ArrayList([]const u8) = .empty;
    if (freestanding) try refuseManagedMetadata(a, module);

    const mac = struct {
        fn prefix(al: Allocator, name: []const u8) ![]u8 {
            return std.fmt.allocPrint(al, "_{s}", .{name});
        }
    }.prefix;

    // §11.8: `syscall()` is Linux-only. The arm64 backend is shared with
    // aarch64-linux, so the target-specific rejection belongs here, on the
    // Mach-O path — the one place that knows the OS. Rejecting before any code
    // is emitted keeps the failure a clean diagnostic rather than a partly
    // written object.
    for (module.funcs.items) |*f| {
        // §17.6: only code this object actually emits can carry the instruction
        // — rejecting on a module that is not even being emitted would fail a
        // perfectly valid freestanding build for a sibling's Linux-only code.
        if (!emitsFunction(f, freestanding)) continue;
        for (f.insts.items(.op)) |op| {
            if (op == .syscall) return error.SyscallUnsupportedTarget;
        }
    }

    // ---- every function -> one __text symbol + its relocations ------------
    var main_void = false;
    var have_main = false;
    for (module.funcs.items) |*f| {
        // §11.7: a declaration, not a definition — emit no code and, decisively,
        // leave it OUT of `defined` so every call to it stays an undefined
        // symbol the linker resolves (Mach-O: a libSystem import).
        // §17.6: an imported module's function is skipped the same way.
        if (!emitsFunction(f, freestanding)) continue;
        if (freestanding and !freestandingEligible(f)) return error.FreestandingSafepoint;
        var fc = try arm64.compileFunction(gpa, module, f);
        defer fc.deinit();
        const off: u64 = code.items.len;
        try code.appendSlice(a, fc.code);
        try symbols.append(a, .{ .name = try mac(a, f.name), .section = .text, .offset = off, .size = fc.code.len, .binding = .global });
        try defined.put(a, try mac(a, f.name), {});
        for (fc.relocs) |r| try relocs.append(a, .{
            .section = .text,
            .offset = off + r.offset,
            .symbol = try mac(a, r.symbol),
            .kind = switch (r.kind) {
                .branch => .branch,
                .page21 => .page21,
                .pageoff12 => .pageoff12,
            },
        });
        try stackmaps.append(a, try stackMapOf(a, fc.code.len, fc.saved_regs, arm64.SafepointEntry, fc.safepoints));
        try emitted_names.append(a, f.name);
        if (std.mem.eql(u8, f.name, "main")) {
            have_main = true;
            main_void = module.ctx.typeOf(f.result) == .void;
        }
    }
    if (with_entry) {
        if (!have_main) return error.NoMain;

        // ---- _bit_main entry trampoline (AArch64) -------------------------
        //   stp x29,x30,[sp,#-16]! ; bl _main ; [mov w0,#0 if void] ; ldp ; ret
        const tramp: u64 = code.items.len;
        try appendWord(&code, a, 0xA9BF7BFD); // stp x29, x30, [sp, #-16]!
        const call_field: u64 = code.items.len;
        try appendWord(&code, a, 0x94000000); // bl _main (placeholder)
        try relocs.append(a, .{ .section = .text, .offset = call_field, .symbol = "_main", .kind = .branch });
        if (main_void) try appendWord(&code, a, 0x52800000); // movz w0, #0
        try appendWord(&code, a, 0xA8C17BFD); // ldp x29, x30, [sp], #16
        try appendWord(&code, a, 0xD65F03C0); // ret
        try symbols.append(a, .{ .name = "_bit_main", .section = .text, .offset = tramp, .size = code.items.len - tramp, .binding = .global });
        try defined.put(a, "_bit_main", {});
    }

    // ---- string pool -> read-only bytes + a writable {ptr,len} header -----
    // The bytes are read-only (`__const`), but the header holds an absolute
    // pointer to them: under macOS's PIE model dyld can only rebase a pointer
    // that lives in a *writable* segment, so the header goes in `.data`, not
    // `.rodata` (where dyld would leave its link-time value unslid — a wild
    // pointer into the unmapped pre-slide image).
    for (module.string_pool.items, 0..) |s, i| {
        const data_off: u64 = rodata.items.len;
        try rodata.appendSlice(a, s);
        const data_name = try std.fmt.allocPrint(a, "___bitstr_{d}_data", .{i});
        try symbols.append(a, .{ .name = data_name, .section = .rodata, .offset = data_off, .size = s.len, .binding = .local });
        try defined.put(a, data_name, {});

        while (data.items.len % 8 != 0) try data.append(a, 0);
        const hdr_off: u64 = data.items.len;
        try data.appendSlice(a, &(.{0} ** 8)); // ptr — filled by the reloc (rebased by dyld)
        var lenbuf: [8]u8 = undefined;
        std.mem.writeInt(u64, &lenbuf, s.len, .little);
        try data.appendSlice(a, &lenbuf); // len
        const hdr_name = try std.fmt.allocPrint(a, "___bitstr_{d}", .{i});
        // §17.6: local in a freestanding object — see `emitElfBlobs`.
        try symbols.append(a, .{ .name = hdr_name, .section = .data, .offset = hdr_off, .size = 16, .binding = if (freestanding) .local else .global });
        try defined.put(a, hdr_name, {});
        try relocs.append(a, .{ .section = .data, .offset = hdr_off, .symbol = data_name, .kind = .unsigned64 });
    }

    // ---- gc_alloc TypeInfo blobs ------------------------------------------
    // The TypeInfo holds an absolute ptr_offsets pointer, so — like the string
    // headers — it lives in writable `.data` (dyld only rebases writable
    // segments under PIE); the plain offsets array stays in read-only `.rodata`.
    // §17.6: empty on the freestanding path — see `refuseManagedMetadata`.
    for (try collectTypeInfos(a, module, freestanding)) |ti| {
        const name = try ir.typeInfoSymbol(a, ti.disc, ti.size, ti.ptr_offsets);
        var offs_name: []const u8 = "";
        if (ti.ptr_offsets.len > 0) {
            while (rodata.items.len % 8 != 0) try rodata.append(a, 0);
            const offs_off: u64 = rodata.items.len;
            for (ti.ptr_offsets) |off| {
                var b: [8]u8 = undefined;
                std.mem.writeInt(u64, &b, off, .little);
                try rodata.appendSlice(a, &b);
            }
            offs_name = try mac(a, try std.fmt.allocPrint(a, "{s}_offs", .{name}));
            try symbols.append(a, .{ .name = offs_name, .section = .rodata, .offset = offs_off, .size = ti.ptr_offsets.len * 8, .binding = .local });
            try defined.put(a, offs_name, {});
        }
        const tname = module.ctx.display_names.get(ti.disc) orelse "";
        var name_sym: []const u8 = "";
        if (tname.len > 0) {
            const nm_off: u64 = rodata.items.len;
            try rodata.appendSlice(a, tname);
            name_sym = try mac(a, try std.fmt.allocPrint(a, "{s}_name", .{name}));
            try symbols.append(a, .{ .name = name_sym, .section = .rodata, .offset = nm_off, .size = tname.len, .binding = .local });
            try defined.put(a, name_sym, {});
        }
        // Method table (ABI.md §2.1) holds absolute fn pointers, so it also lives
        // in writable `.data` (dyld rebases). `emitMethodTable` writes the bytes;
        // symbol + fn relocs are mangled/tagged here for the Mach-O format.
        const methods = try emitMethodTable(a, module, &data, ti.disc, name);
        var methods_name: []const u8 = "";
        if (methods.sym.len > 0) {
            methods_name = try mac(a, methods.sym);
            try symbols.append(a, .{ .name = methods_name, .section = .data, .offset = methods.off, .size = methods.size, .binding = .local });
            try defined.put(a, methods_name, {});
            for (methods.relocs) |r|
                try relocs.append(a, .{ .section = .data, .offset = r.off, .symbol = try mac(a, r.sym), .kind = .unsigned64 });
        }
        while (data.items.len % 8 != 0) try data.append(a, 0);
        const ti_off: u64 = data.items.len;
        var field: [8]u8 = undefined;
        std.mem.writeInt(u64, &field, ti.size, .little);
        try data.appendSlice(a, &field); // size
        try data.appendSlice(a, &(.{0} ** 8)); // ptr_offsets_ptr (rebased by dyld if any)
        std.mem.writeInt(u64, &field, ti.ptr_offsets.len, .little);
        try data.appendSlice(a, &field); // ptr_offsets_len
        try data.appendSlice(a, &(.{0} ** 8)); // name_ptr (rebased by dyld if any)
        std.mem.writeInt(u64, &field, tname.len, .little);
        try data.appendSlice(a, &field); // name_len
        try data.appendSlice(a, &(.{0} ** 8)); // methods_ptr (rebased by dyld if any)
        std.mem.writeInt(u64, &field, methods.size / 16, .little);
        try data.appendSlice(a, &field); // methods_len
        const ti_name = try mac(a, name);
        try symbols.append(a, .{ .name = ti_name, .section = .data, .offset = ti_off, .size = 56, .binding = .global });
        try defined.put(a, ti_name, {});
        if (ti.ptr_offsets.len > 0)
            try relocs.append(a, .{ .section = .data, .offset = ti_off + 8, .symbol = offs_name, .kind = .unsigned64 });
        if (name_sym.len > 0)
            try relocs.append(a, .{ .section = .data, .offset = ti_off + 24, .symbol = name_sym, .kind = .unsigned64 });
        if (methods.sym.len > 0)
            try relocs.append(a, .{ .section = .data, .offset = ti_off + 40, .symbol = methods_name, .kind = .unsigned64 });
    }

    // ---- GC stack-map table (runtime/ABI.md §4) ---------------------------
    // Like the string/TypeInfo blobs, each entry holds an absolute code
    // pointer, so the table lives in writable `.data` (dyld only rebases
    // writable segments under PIE); the runtime reads it via `_bit_stack_maps`.
    std.debug.assert(emitted_names.items.len == stackmaps.items.len);
    // §17.6: a whole-program table under a fixed name — never an archive
    // member's to define. See `emitElfBlobs`.
    if (!freestanding) {
        const blob_off: u64 = data.items.len;
        const code_relocs = try common.writeStackMaps(a, &data, stackmaps.items);
        const sym = try mac(a, stackmaps_symbol);
        try symbols.append(a, .{ .name = sym, .section = .data, .offset = blob_off, .size = data.items.len - blob_off, .binding = .global });
        try defined.put(a, sym, {});
        // `writeStackMaps` records offsets against `data` itself — already
        // section-relative, so no `blob_off` adjustment.
        for (code_relocs, 0..) |ro, fi| try relocs.append(a, .{
            .section = .data,
            .offset = ro,
            .symbol = try mac(a, emitted_names.items[fi]),
            .kind = .unsigned64,
        });
    }

    // ---- undefined externals for runtime symbols --------------------------
    var externs = std.StringHashMapUnmanaged(void){};
    for (relocs.items) |r| {
        if (defined.contains(r.symbol) or externs.contains(r.symbol)) continue;
        try externs.put(a, r.symbol, {});
        try symbols.append(a, .{ .name = r.symbol, .section = null, .binding = .global });
    }

    var sections: std.ArrayList(obj_macho.Section) = .empty;
    try sections.append(a, .{ .kind = .text, .data = code.items, .alignment = 4 });
    if (rodata.items.len > 0) try sections.append(a, .{ .kind = .rodata, .data = rodata.items, .alignment = 8 });
    if (data.items.len > 0) try sections.append(a, .{ .kind = .data, .data = data.items, .alignment = 8 });

    return obj_macho.write(gpa, .aarch64, .{ .sections = sections.items, .symbols = symbols.items, .relocations = relocs.items });
}

fn appendWord(list: *std.ArrayList(u8), gpa: Allocator, w: u32) !void {
    var b: [4]u8 = undefined;
    std.mem.writeInt(u32, &b, w, .little);
    try list.appendSlice(gpa, &b);
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;
const check = @import("check.zig");
const elf_reader = @import("link/elf_reader.zig");

/// Appends a trivial `@nosplit` function named `name`, tagged as belonging (or
/// not) to the root module — the two-module shape `lowerProject` produces when
/// the root imports something, reduced to the one field the emitter reads.
fn testAppendFunc(gpa: Allocator, module: *ir.Module, name: []const u8, in_root: bool) !void {
    const i64_ty = module.ctx.prim_ids.get(.i64);
    var b = ir.FunctionBuilder.init(gpa);
    const entry = try b.newBlock();
    b.beginBlock(entry);
    const one = try b.constInt(i64_ty, 1);
    try b.ret(&.{one});
    b.endBlock();
    var f = try b.finish(name, &.{}, i64_ty, false, .invalid, entry);
    f.is_nosplit = true; // §17.6 requires it of every emitted function
    f.in_root_module = in_root;
    try module.funcs.append(gpa, f);
}

/// True if the emitted object defines a `.text` symbol named `want`.
fn testObjectDefines(gpa: Allocator, obj: []const u8, want: []const u8) !bool {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const mod = try elf_reader.read(arena_state.allocator(), .x86_64, "t.o", obj);
    for (mod.atoms) |atom| {
        if (atom.kind == .text and std.mem.eql(u8, atom.name, want)) return true;
    }
    return false;
}

test "emit: a freestanding object holds only the root module's functions" {
    // §17.6, the invariant a Bit-sourced libbitrt.a rests on. Two modules'
    // functions share one `ir.Module` after `lowerProject`, so without the
    // filter BOTH objects define BOTH functions and archiving them is an
    // immediate DuplicateSymbol — the exact failure #1397/#1398 hit.
    //
    // Asserted through the project's own ELF reader rather than by scanning
    // bytes, so this checks what the LINKER will see: a defined `.text` atom.
    const gpa = testing.allocator;
    var ctx = try check.TypeContext.init(gpa);
    defer ctx.deinit();

    var module = ir.Module.init(gpa, &ctx);
    defer module.deinit();
    try testAppendFunc(gpa, &module, "rootFn", true);
    try testAppendFunc(gpa, &module, "importedFn", false);

    const free_obj = try emitObject(gpa, &module, false, true);
    defer gpa.free(free_obj);
    try testing.expect(try testObjectDefines(gpa, free_obj, "rootFn"));
    try testing.expect(!try testObjectDefines(gpa, free_obj, "importedFn"));

    // The same module emitted normally keeps both — so the assertion above is
    // about the freestanding flag, not about the function being unemittable.
    const whole_obj = try emitObject(gpa, &module, false, false);
    defer gpa.free(whole_obj);
    try testing.expect(try testObjectDefines(gpa, whole_obj, "rootFn"));
    try testing.expect(try testObjectDefines(gpa, whole_obj, "importedFn"));
}

test "emit: freestanding refuses a function that is neither @nosplit nor @naked" {
    // §17.6: such a function needs a stack map, and a freestanding object has
    // no `bit_stack_maps` to put one in. Emitting it anyway would leave a frame
    // the collector cannot scan — silent wrongness, so it is a refusal.
    const gpa = testing.allocator;
    var ctx = try check.TypeContext.init(gpa);
    defer ctx.deinit();

    var module = ir.Module.init(gpa, &ctx);
    defer module.deinit();
    try testAppendFunc(gpa, &module, "managedFn", true);
    module.funcs.items[0].is_nosplit = false;

    try testing.expectError(error.FreestandingSafepoint, emitObject(gpa, &module, false, true));
    // Not freestanding: the very same module emits fine.
    const obj = try emitObject(gpa, &module, false, false);
    defer gpa.free(obj);
    try testing.expect(try testObjectDefines(gpa, obj, "managedFn"));
}
