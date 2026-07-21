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

pub const Error = error{ NoMain, FreestandingAlloc, FreestandingUnpinned, FreestandingImportedGlobal, UnsupportedTlsStorage } || x64.CodegenError || obj_elf.Error || obj_macho.Error || Allocator.Error;

/// §17.6: does this function belong in a freestanding object? A freestanding
/// emit keeps only the ROOT module's own code, so an imported module's
/// functions are left out and calls into them stay undefined relocations the
/// linker resolves against that module's own object. `is_extern` is skipped on
/// both paths: a declaration defines nothing either way.
fn emitsFunction(f: *const ir.Function, freestanding: bool) bool {
    if (f.is_extern) return false;
    return f.in_root_module or !freestanding;
}

/// §17.6: does this module-level cell belong in a freestanding object? Exactly
/// `emitsFunction`'s rule, one storage class down (#1630) — `lowerProject`
/// registers a cell for every module in the project, and an object that emits
/// an imported module's cells either collides with that module's own object or,
/// where the project-local ordinals in the mangled name differ, quietly gives
/// the two modules separate copies of one logical global.
fn emitsGlobal(g: ir.Global, freestanding: bool) bool {
    return g.in_root_module or !freestanding;
}

/// §17.6 + §11.9: the binding a definition this object emits should carry.
///
/// A freestanding object is one archive member among many, and the ONLY names
/// its siblings may reference are §11.9 pins — `firstUnpinnedImport` refuses
/// every other cross-object reference, precisely because no other spelling is
/// stable across two separate compilations. So everything a freestanding object
/// defines that is not pinned is module-private by construction, and exporting
/// it buys nothing while costing a collision the moment two modules happen to
/// declare a helper (`byteAt`, `strData`) or a cell of the same name (#1630,
/// #1631). Local binding states the truth the design already relies on.
///
/// A managed (non-freestanding) object is the whole program in one unit, where
/// these names are all the linker has to work with; that path keeps its
/// bindings exactly as before.
fn definitionBinding(comptime B: type, freestanding: bool, pinned: bool) B {
    if (freestanding and !pinned) return .local;
    return .global;
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

/// The Mach-O-spelled names this module legitimately leaves undefined for dyld
/// to bind — i.e. its §11.7 `extern function` declarations, which `lower.zig`
/// records as `is_extern` functions carrying the raw source name.
///
/// The linker cannot derive this set itself: an `extern function` and a symbol
/// the compiler simply misspelled are emitted identically (both are just
/// `N_UNDF | N_EXT`), so `is_extern` has to be carried across the object
/// boundary out of band. Without it the Mach-O linker has no way to tell a
/// legal dylib import from #1428's `_idg`. Caller owns the returned slice and
/// each name in it.
pub fn externImportNames(gpa: Allocator, module: *const ir.Module) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (out.items) |n| gpa.free(n);
        out.deinit(gpa);
    }
    for (module.funcs.items) |*f| {
        if (!f.is_extern) continue;
        try out.append(gpa, try std.fmt.allocPrint(gpa, "_{s}", .{f.name}));
    }
    return out.toOwnedSlice(gpa);
}

/// True if `name` is a §11.9 pinned symbol rather than a compiler-mangled one.
///
/// Exact, not a heuristic, because the two spellings are disjoint by
/// construction: every name lowering synthesizes for a non-root function
/// carries a `$` — an imported module's functions are qualified `m<id>$f`,
/// generic instantiations and methods append `$<n>`/`$t<n>`, and closures and
/// trampolines are `closure$<n>`-shaped — while E0079 restricts a pin to a C
/// identifier, which cannot contain `$`. Asserted by the unit test below so a
/// future mangling scheme that dropped the `$` would fail loudly here.
fn isPinnedName(name: []const u8) bool {
    return std.mem.indexOfScalar(u8, name, '$') == null;
}

/// True if this freestanding object defines `name` itself, so a reference to it
/// resolves inside the object and never reaches the linker.
fn definesName(module: *const ir.Module, name: []const u8) bool {
    for (module.funcs.items) |*f| {
        if (!emitsFunction(f, true)) continue;
        if (std.mem.eql(u8, f.name, name)) return true;
    }
    return false;
}

/// §17.6 + §11.9: the first mangled symbol this object would reference without
/// defining, or null when every outbound reference is resolvable.
///
/// The invariant is a property of the OBJECT, not of the call graph: a
/// freestanding object may emit an undefined reference only under a name some
/// sibling object can actually define. A cross-module call is emitted under the
/// callee's LOWERED name, and for an unpinned import that is `m<id>$f` — where
/// `<id>` is an ordinal THIS build assigned to the module. The sibling's own
/// freestanding object emits the same function bare, because there it is the
/// root, so the two spellings can never match and the reference stays undefined
/// forever. A pin is the only name both builds agree on, which is what makes
/// `@symbol` load-bearing for a multi-module runtime rather than decorative
/// (#1396, ABI.md §9).
///
/// Stated over names rather than over `in_root_module` deliberately. The two
/// agree on a correct lowering, but the name test also catches a *lowering* that
/// emits a reference matching no definition at all — which is the shape a
/// mis-pinned call site has, and it is silent wrongness the `in_root_module`
/// form cannot see. A `bit_rt_*` runtime symbol and a §11.7 `extern` both pass
/// for the same reason a pin does: their names carry no `$`.
///
/// This has to be refused at emit time, because neither later stage reports it
/// anywhere near its cause: an undefined symbol in an archive member nothing
/// references is dead-stripped rather than diagnosed, and on Darwin an
/// unresolved reference falls through to a libSystem import and aborts at dyld
/// load time. Both turn a naming mistake into a failure a reader cannot trace.
///
/// Only *referenced* imports are checked, not merely imported ones: after
/// inlining, a module may import a sibling it no longer calls, and refusing
/// that would be a false alarm about a symbol the object never names.
pub fn firstUnpinnedImport(module: *const ir.Module) ?[]const u8 {
    for (module.funcs.items) |*f| {
        if (!emitsFunction(f, true)) continue;
        var i: u32 = 0;
        while (i < f.insts.len) : (i += 1) {
            const name = switch (f.decode(@enumFromInt(i))) {
                .call => |c| module.func(c.func).name,
                .func_addr => |fa| module.func(fa.func).name,
                else => continue,
            };
            if (isPinnedName(name)) continue;
            if (definesName(module, name)) continue;
            return name;
        }
    }
    return null;
}

fn refuseUnpinnedImports(module: *const ir.Module) Error!void {
    if (firstUnpinnedImport(module) != null) return error.FreestandingUnpinned;
}

/// §17.6 + §11.11: the first module-level cell this freestanding object would
/// reference without emitting, or null when every `global_addr` lands on a cell
/// the object defines.
///
/// The data counterpart of `firstUnpinnedImport`, and refused for the same
/// reason (#1630): an imported module's cell is spelled `__bitg_<n>_name` with
/// `<n>` an ordinal THIS build assigned, so a sibling object — where the same
/// module is the root, under a different ordinal — can never define that name.
/// There is no `@symbol` pin for a cell, so unlike a call there is no correct
/// spelling to fall back on: a cross-module global reference is simply not
/// expressible in a freestanding object today, and saying so here is the only
/// place a reader learns it near the cause. The alternative is what this
/// replaced — emitting a private copy per object, which links and runs and
/// silently splits one logical global in two.
///
/// Reference-driven, not declaration-driven: `emitsGlobal` already drops the
/// imported cells nothing names, and refusing merely *importing* a module that
/// has state would be a false alarm about a symbol this object never mentions.
pub fn firstImportedGlobalRef(module: *const ir.Module) ?[]const u8 {
    for (module.funcs.items) |*f| {
        if (!emitsFunction(f, true)) continue;
        var i: u32 = 0;
        while (i < f.insts.len) : (i += 1) {
            const g = switch (f.decode(@enumFromInt(i))) {
                .global_addr => |ga| module.global(ga.global),
                else => continue,
            };
            if (emitsGlobal(g, true)) continue;
            return g.name;
        }
    }
    return null;
}

fn refuseImportedGlobalRefs(module: *const ir.Module) Error!void {
    if (firstImportedGlobalRef(module) != null) return error.FreestandingImportedGlobal;
}

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

/// Where one module-level variable (§11.11) landed in its blob.
const GlobalPlacement = struct { name: []const u8, offset: u64, size: u64 };

/// Appends the static image of every module-level variable in one *storage
/// class* to `data`, honouring each one's alignment, and returns where each
/// landed. The caller turns these into its own object format's symbols — the
/// two formats' `Symbol` types differ by one field, which is not worth a
/// comptime-generic indirection here.
///
/// Filtering by class rather than emitting all of them is what keeps the two
/// classes' blobs separate: `.process` cells go to `.data` (one cell for the
/// program), `.thread` cells go to the thread-local template (`.tdata` on ELF,
/// `__thread_data` on Mach-O) from which each OS thread gets its own copy. A
/// `.thread` cell's offset is therefore an offset *within the template*, never
/// a link-time address.
///
/// These cells are writable and **never scanned by the collector**, in both
/// classes: the checker has proved each one's type untraced, so neither blob
/// needs a pointer map or root registration. See SPEC §11.11.
fn placeGlobals(a: Allocator, module: *const ir.Module, storage: ir.GlobalStorage, data: *std.ArrayList(u8), freestanding: bool) Error![]const GlobalPlacement {
    var out: std.ArrayList(GlobalPlacement) = .empty;
    for (module.globals.items) |g| {
        if (g.storage != storage) continue;
        if (!emitsGlobal(g, freestanding)) continue; // §17.6 (#1630)
        while (data.items.len % g.alignment != 0) try data.append(a, 0);
        const off: u64 = data.items.len;
        try data.appendSlice(a, g.bytes);
        try out.append(a, .{ .name = try a.dupe(u8, g.name), .offset = off, .size = g.bytes.len });
    }
    return out.toOwnedSlice(a);
}

/// Appends every `.readonly` global's image to the object's `.rodata` blob and
/// returns where each landed, alongside the fixups its `relocs` imply — already
/// rebased from "offset within the global" to "offset within the blob", which is
/// what both object writers address relocations by.
///
/// Read-only globals share `.rodata` with the string-pool headers, `TypeInfo`
/// blobs and stack maps rather than getting a section of their own. That is
/// deliberate: `link/strip.zig` atomizes `.rodata` per symbol and lays the
/// survivors out by atom, so a separate section would buy nothing but one more
/// place for the section's own alignment to be wrong. It does mean the caller
/// must not pin the `.rodata` section's alignment at 8 any more — see
/// `globalsAlign`, and #1421 for what happens when a section is looser than the
/// cells it holds.
///
/// **Unlike the writable classes these are never GC-scanned and never need to
/// be**: a `.readonly` image cannot be mutated, so it cannot come to hold a
/// pointer to a moved object, and the only pointers it may contain are the
/// link-time ones below — addresses of other static data, not of heap objects.
fn placeReadonlyGlobals(
    a: Allocator,
    module: *const ir.Module,
    rodata: *std.ArrayList(u8),
    relocs: *std.ArrayList(GlobalFixup),
    freestanding: bool,
) Error![]const GlobalPlacement {
    var out: std.ArrayList(GlobalPlacement) = .empty;
    for (module.globals.items) |g| {
        if (g.storage != .readonly) continue;
        if (!emitsGlobal(g, freestanding)) continue; // §17.6 (#1630)
        while (rodata.items.len % g.alignment != 0) try rodata.append(a, 0);
        const off: u64 = rodata.items.len;
        try rodata.appendSlice(a, g.bytes);
        for (g.relocs) |r| {
            std.debug.assert(r.offset + 8 <= g.bytes.len);
            try relocs.append(a, .{ .offset = off + r.offset, .symbol = r.symbol, .addend = r.addend });
        }
        try out.append(a, .{ .name = try a.dupe(u8, g.name), .offset = off, .size = g.bytes.len });
    }
    return out.toOwnedSlice(a);
}

/// One `.rodata` pointer fixup, in the format-neutral form both object writers
/// take: a blob offset, a target symbol, an addend. Always `abs64`.
const GlobalFixup = struct { offset: u64, symbol: []const u8, addend: i64 };

/// The alignment a globals section must carry for the per-cell padding
/// `placeGlobals` inserts to survive into the loaded image.
///
/// Padding a cell to 16 *within* a section only lands it 16-aligned in memory if
/// the section is at least as aligned; otherwise every cell inherits the
/// section's own misalignment. That is precisely how §11.11's alignment
/// guarantee held on aarch64-macOS and silently failed on ELF (#1421): with the
/// section pinned at 8, every module cell sat at `addr % 16 == 8` on
/// x86_64-linux while the native test run looked correct.
///
/// Derived from the cells actually present rather than hardcoded, so the
/// section can never again be weaker than what `placeGlobals` assumed. The 8
/// floor keeps a module with no globals byte-identical to before.
fn globalsAlign(module: *const ir.Module, storage: ir.GlobalStorage, freestanding: bool) u32 {
    var want: u32 = 8;
    for (module.globals.items) |g| {
        if (g.storage != storage) continue;
        if (!emitsGlobal(g, freestanding)) continue; // §17.6 (#1630)
        want = @max(want, g.alignment);
    }
    return want;
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
    var gc: std.ArrayList(u8) = .empty;
    var symbols: std.ArrayList(obj_elf.Symbol) = .empty;
    var relocs: std.ArrayList(obj_elf.Relocation) = .empty;
    var defined = std.StringHashMapUnmanaged(void){};
    var stackmaps: std.ArrayList(common.FuncStackMap) = .empty;
    var emitted_names: std.ArrayList([]const u8) = .empty;
    if (freestanding) try refuseManagedMetadata(a, module);
    if (freestanding) try refuseUnpinnedImports(module);
    if (freestanding) try refuseImportedGlobalRefs(module);

    // ---- every function -> one .text symbol + its relocations -------------
    var main_void = false;
    var have_main = false;
    for (module.funcs.items) |*f| {
        // §11.7: a declaration, not a definition — emit no code and, decisively,
        // leave it OUT of `defined` so every call to it stays an undefined
        // symbol the linker resolves (Mach-O: a libSystem import).
        // §17.6: an imported module's function is skipped the same way.
        if (!emitsFunction(f, freestanding)) continue;
        var fc = try x64.compileFunction(gpa, module, f, .sysv);
        defer fc.deinit();
        const off: u64 = code.items.len;
        try code.appendSlice(a, fc.code);
        try symbols.append(a, .{ .name = try a.dupe(u8, f.name), .section = .text, .offset = off, .size = fc.code.len, .binding = definitionBinding(obj_elf.Binding, freestanding, f.is_pinned), .kind = .func });
        try defined.put(a, f.name, {});
        for (fc.relocs) |r| try relocs.append(a, .{
            .section = .text,
            .offset = off + r.offset,
            .symbol = try a.dupe(u8, r.symbol),
            .kind = switch (r.kind) {
                .call => .pc32,
                .abs64 => .abs64,
                .tpoff32 => .tpoff32,
            },
            .addend = switch (r.kind) {
                .call => -4,
                // The thread-pointer displacement is the symbol's own template
                // offset, so it takes no addend (§11.11).
                .abs64, .tpoff32 => 0,
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

    // ---- module-level state (§11.11) -> writable .data --------------------
    var data: std.ArrayList(u8) = .empty;
    for (try placeGlobals(a, module, .process, &data, freestanding)) |g| {
        try symbols.append(a, .{ .name = g.name, .section = .data, .offset = g.offset, .size = g.size, .binding = definitionBinding(obj_elf.Binding, freestanding, false), .kind = .object });
        try defined.put(a, g.name, {});
    }

    // ---- per-thread state (§11.11) -> the `.tdata` template ---------------
    // Every cell goes to `.tdata` even when its image is all zeros, rather
    // than splitting zero-valued ones into `.tbss`: the linker merges both
    // into one `PT_TLS` regardless, so the split would buy a little file size
    // in exchange for a second section whose offsets must stay consistent with
    // the first. `STT_TLS` is what makes each symbol's value an offset within
    // the template — the quantity the local-exec relocations add to the
    // thread pointer — rather than a link-time address.
    var tdata: std.ArrayList(u8) = .empty;
    for (try placeGlobals(a, module, .thread, &tdata, freestanding)) |g| {
        try symbols.append(a, .{ .name = g.name, .section = .tdata, .offset = g.offset, .size = g.size, .binding = definitionBinding(obj_elf.Binding, freestanding, false), .kind = .tls });
        try defined.put(a, g.name, {});
    }

    // ---- read-only module state (§11.11) -> .rodata -----------------------
    // Placed BEFORE the blobs so a table's own alignment padding is measured
    // from the start of the section, not from wherever the string pool happened
    // to end. `defined` gets each name so the undefined-externals pass below
    // does not then declare the table an unresolved import.
    var ro_fixups: std.ArrayList(GlobalFixup) = .empty;
    for (try placeReadonlyGlobals(a, module, &rodata, &ro_fixups, freestanding)) |g| {
        try symbols.append(a, .{ .name = g.name, .section = .rodata, .offset = g.offset, .size = g.size, .binding = definitionBinding(obj_elf.Binding, freestanding, false), .kind = .object });
        try defined.put(a, g.name, {});
    }
    // ELF is RELA: the addend rides in the relocation and the field bytes are
    // ignored, so the authored image is left exactly as written.
    for (ro_fixups.items) |f| {
        try relocs.append(a, .{ .section = .rodata, .offset = f.offset, .symbol = f.symbol, .kind = .abs64, .addend = f.addend });
    }

    try emitElfBlobs(a, module, &rodata, &gc, &symbols, &relocs, &defined, stackmaps.items, emitted_names.items, freestanding);

    var sections: std.ArrayList(obj_elf.Section) = .empty;
    try sections.append(a, .{ .kind = .text, .data = code.items, .alignment = 16 });
    if (rodata.items.len > 0) try sections.append(a, .{ .kind = .rodata, .data = rodata.items, .alignment = globalsAlign(module, .readonly, freestanding) });
    if (gc.items.len > 0) try sections.append(a, .{ .kind = .gc_meta, .data = gc.items, .alignment = 1 });
    if (data.items.len > 0) try sections.append(a, .{ .kind = .data, .data = data.items, .alignment = globalsAlign(module, .process, freestanding) });
    if (tdata.items.len > 0) try sections.append(a, .{ .kind = .tdata, .data = tdata.items, .alignment = globalsAlign(module, .thread, freestanding) });

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
    /// The `.bit_gc` GC stack-map section (ABI.md §4) — kept separate from
    /// `.rodata` because the linker must lay its atoms out contiguously.
    gc: *std.ArrayList(u8),
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

    // ---- GC stack-map entries (runtime/ABI.md §4) -> .bit_gc --------------
    // Per-MEMBER, not per-program: every object emits its own entries into the
    // dedicated `.bit_gc` section and the linker concatenates them between the
    // symbols it defines at the extent's ends. That is what lets an archive
    // member carry stack maps at all, which in turn is what lets a runtime
    // module reach a safepoint (ABI.md §4.1) — the whole point of the change.
    // No object defines `bit_stack_maps`: one global name owned by several
    // members would be a duplicate definition, so the linker owns it instead.
    //
    // One section, one LOCAL symbol per function — not one section per function,
    // which both object writers reject as a duplicate `SectionKind`. The readers
    // carve one atom per symbol offset, so per-function symbols are exactly what
    // makes the linker able to drop an entry whose function it dropped.
    {
        const code_relocs = try common.writeStackMaps(a, gc, stackmaps);
        for (code_relocs, 0..) |ro, fi| {
            const end: u64 = if (fi + 1 < code_relocs.len) code_relocs[fi + 1] else gc.items.len;
            const name = try std.fmt.allocPrint(a, "__bitsm_{d}", .{fi});
            try symbols.append(a, .{ .name = name, .section = .gc_meta, .offset = ro, .size = end - ro, .binding = .local, .kind = .object });
            try defined.put(a, name, {});
            // `writeStackMaps` records offsets against `gc` itself, so they are
            // already section-relative. The entry begins with its `code_addr`
            // field, so the entry's own offset IS the relocation's offset.
            try relocs.append(a, .{
                .section = .gc_meta,
                .offset = ro,
                .symbol = try a.dupe(u8, emitted_names[fi]),
                .kind = .abs64,
                .addend = 0,
            });
        }
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
    var gc: std.ArrayList(u8) = .empty;
    var symbols: std.ArrayList(obj_elf.Symbol) = .empty;
    var relocs: std.ArrayList(obj_elf.Relocation) = .empty;
    var defined = std.StringHashMapUnmanaged(void){};
    var stackmaps: std.ArrayList(common.FuncStackMap) = .empty;
    var emitted_names: std.ArrayList([]const u8) = .empty;
    if (freestanding) try refuseManagedMetadata(a, module);
    if (freestanding) try refuseUnpinnedImports(module);
    if (freestanding) try refuseImportedGlobalRefs(module);

    // ---- every function -> one .text symbol + its relocations -------------
    var main_void = false;
    var have_main = false;
    for (module.funcs.items) |*f| {
        // §11.7: a declaration, not a definition — emit no code and, decisively,
        // leave it OUT of `defined` so every call to it stays an undefined
        // symbol the linker resolves (Mach-O: a libSystem import).
        // §17.6: an imported module's function is skipped the same way.
        if (!emitsFunction(f, freestanding)) continue;
        var fc = try arm64.compileFunction(gpa, module, f);
        defer fc.deinit();
        const off: u64 = code.items.len;
        try code.appendSlice(a, fc.code);
        try symbols.append(a, .{ .name = try a.dupe(u8, f.name), .section = .text, .offset = off, .size = fc.code.len, .binding = definitionBinding(obj_elf.Binding, freestanding, f.is_pinned), .kind = .func });
        try defined.put(a, f.name, {});
        for (fc.relocs) |r| try relocs.append(a, .{
            .section = .text,
            .offset = off + r.offset,
            .symbol = try a.dupe(u8, r.symbol),
            .kind = switch (r.kind) {
                .branch => .aarch64_call26,
                .page21 => .aarch64_adr_prel_pg_hi21,
                .pageoff12 => .aarch64_add_abs_lo12_nc,
                .tprel_hi12 => .aarch64_tlsle_add_tprel_hi12,
                .tprel_lo12 => .aarch64_tlsle_add_tprel_lo12_nc,
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

    // ---- module-level state (§11.11) -> writable .data --------------------
    var data: std.ArrayList(u8) = .empty;
    for (try placeGlobals(a, module, .process, &data, freestanding)) |g| {
        try symbols.append(a, .{ .name = g.name, .section = .data, .offset = g.offset, .size = g.size, .binding = definitionBinding(obj_elf.Binding, freestanding, false), .kind = .object });
        try defined.put(a, g.name, {});
    }

    // ---- per-thread state (§11.11) -> the `.tdata` template ---------------
    // Every cell goes to `.tdata` even when its image is all zeros, rather
    // than splitting zero-valued ones into `.tbss`: the linker merges both
    // into one `PT_TLS` regardless, so the split would buy a little file size
    // in exchange for a second section whose offsets must stay consistent with
    // the first. `STT_TLS` is what makes each symbol's value an offset within
    // the template — the quantity the local-exec relocations add to the
    // thread pointer — rather than a link-time address.
    var tdata: std.ArrayList(u8) = .empty;
    for (try placeGlobals(a, module, .thread, &tdata, freestanding)) |g| {
        try symbols.append(a, .{ .name = g.name, .section = .tdata, .offset = g.offset, .size = g.size, .binding = definitionBinding(obj_elf.Binding, freestanding, false), .kind = .tls });
        try defined.put(a, g.name, {});
    }

    // ---- read-only module state (§11.11) -> .rodata -----------------------
    // Placed BEFORE the blobs so a table's own alignment padding is measured
    // from the start of the section, not from wherever the string pool happened
    // to end. `defined` gets each name so the undefined-externals pass below
    // does not then declare the table an unresolved import.
    var ro_fixups: std.ArrayList(GlobalFixup) = .empty;
    for (try placeReadonlyGlobals(a, module, &rodata, &ro_fixups, freestanding)) |g| {
        try symbols.append(a, .{ .name = g.name, .section = .rodata, .offset = g.offset, .size = g.size, .binding = definitionBinding(obj_elf.Binding, freestanding, false), .kind = .object });
        try defined.put(a, g.name, {});
    }
    // ELF is RELA: the addend rides in the relocation and the field bytes are
    // ignored, so the authored image is left exactly as written.
    for (ro_fixups.items) |f| {
        try relocs.append(a, .{ .section = .rodata, .offset = f.offset, .symbol = f.symbol, .kind = .abs64, .addend = f.addend });
    }

    try emitElfBlobs(a, module, &rodata, &gc, &symbols, &relocs, &defined, stackmaps.items, emitted_names.items, freestanding);

    var sections: std.ArrayList(obj_elf.Section) = .empty;
    try sections.append(a, .{ .kind = .text, .data = code.items, .alignment = 16 });
    if (rodata.items.len > 0) try sections.append(a, .{ .kind = .rodata, .data = rodata.items, .alignment = globalsAlign(module, .readonly, freestanding) });
    if (gc.items.len > 0) try sections.append(a, .{ .kind = .gc_meta, .data = gc.items, .alignment = 1 });
    if (data.items.len > 0) try sections.append(a, .{ .kind = .data, .data = data.items, .alignment = globalsAlign(module, .process, freestanding) });
    if (tdata.items.len > 0) try sections.append(a, .{ .kind = .tdata, .data = tdata.items, .alignment = globalsAlign(module, .thread, freestanding) });

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
    var gc: std.ArrayList(u8) = .empty;
    var symbols: std.ArrayList(obj_macho.Symbol) = .empty;
    var relocs: std.ArrayList(obj_macho.Relocation) = .empty;
    var defined = std.StringHashMapUnmanaged(void){};
    var stackmaps: std.ArrayList(common.FuncStackMap) = .empty;
    var emitted_names: std.ArrayList([]const u8) = .empty;
    if (freestanding) try refuseManagedMetadata(a, module);
    if (freestanding) try refuseUnpinnedImports(module);
    if (freestanding) try refuseImportedGlobalRefs(module);

    // Per-thread state (§11.11) is not emitted on Mach-O yet: it reaches a
    // thread-local through a `__thread_vars` `tlv_descriptor` and an indirect
    // call to its resolver thunk, not through a link-time offset, so it needs
    // both descriptor emission and call-clobber modelling in codegen. Refuse
    // explicitly — a `.thread` cell silently placed in `.data` would be one
    // process-wide cell wearing a per-thread name.
    //
    // This MUST precede function compilation, not merely global placement: the
    // codegen below emits ELF local-exec relocations for a `.thread`
    // `global_addr`, which the relocation mapping has no Mach-O spelling for
    // and rejects as `unreachable`. Refusing first is what makes that
    // `unreachable` sound.
    for (module.globals.items) |g| {
        if (g.storage == .thread) return error.UnsupportedTlsStorage;
    }

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
        var fc = try arm64.compileFunction(gpa, module, f);
        defer fc.deinit();
        const off: u64 = code.items.len;
        try code.appendSlice(a, fc.code);
        try symbols.append(a, .{ .name = try mac(a, f.name), .section = .text, .offset = off, .size = fc.code.len, .binding = definitionBinding(obj_macho.Binding, freestanding, f.is_pinned) });
        try defined.put(a, try mac(a, f.name), {});
        for (fc.relocs) |r| try relocs.append(a, .{
            .section = .text,
            .offset = off + r.offset,
            .symbol = try mac(a, r.symbol),
            .kind = switch (r.kind) {
                .branch => .branch,
                .page21 => .page21,
                .pageoff12 => .pageoff12,
                // Unreachable rather than dead: a `.thread` global is refused
                // before any function is compiled on this path (see the
                // `UnsupportedTlsStorage` guard below), so no ELF local-exec
                // relocation can reach a Mach-O object. Mach-O thread-locals
                // resolve through a TLV descriptor, not a tprel pair.
                .tprel_hi12, .tprel_lo12 => unreachable,
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

    // ---- GC stack-map entries (runtime/ABI.md §4) -> __DATA,__bit_gc ------
    // Per-MEMBER, not per-program (ABI.md §4.1): every object emits its own
    // entries and the linker concatenates them between the symbols it defines
    // at the extent's ends, so an archive member can carry stack maps and its
    // functions are free to reach safepoints. No object defines
    // `_bit_stack_maps` — one global name owned by several members would be a
    // duplicate definition, so the linker owns it instead.
    //
    // Each entry holds an absolute code pointer, so like the string/TypeInfo
    // blobs the section is in `__DATA` (dyld only rebases writable segments
    // under PIE). One section with one LOCAL symbol per function: the writer
    // rejects two sections of the same kind, and the reader carves one atom per
    // symbol, which is what lets the linker drop an entry whose function it
    // dropped.
    std.debug.assert(emitted_names.items.len == stackmaps.items.len);
    {
        const code_relocs = try common.writeStackMaps(a, &gc, stackmaps.items);
        for (code_relocs, 0..) |ro, fi| {
            const end: u64 = if (fi + 1 < code_relocs.len) code_relocs[fi + 1] else gc.items.len;
            const name = try mac(a, try std.fmt.allocPrint(a, "__bitsm_{d}", .{fi}));
            try symbols.append(a, .{ .name = name, .section = .gc_meta, .offset = ro, .size = end - ro, .binding = .local });
            try defined.put(a, name, {});
            // Offsets are already section-relative, and an entry starts with
            // its `code_addr` field — so the entry offset IS the reloc offset.
            try relocs.append(a, .{
                .section = .gc_meta,
                .offset = ro,
                .symbol = try mac(a, emitted_names.items[fi]),
                .kind = .unsigned64,
            });
        }
    }

    // ---- module-level state (§11.11) -> the same writable .data -----------
    for (try placeGlobals(a, module, .process, &data, freestanding)) |g| {
        const sym = try mac(a, g.name);
        try symbols.append(a, .{ .name = sym, .section = .data, .offset = g.offset, .size = g.size, .binding = definitionBinding(obj_macho.Binding, freestanding, false) });
        try defined.put(a, sym, {});
    }

    // ---- read-only module state (§11.11) -> the same .rodata --------------
    // Two format differences from the ELF path above, both of which are silent
    // wrongness if missed:
    //
    //  1. Every symbol name is `_`-prefixed, on the reference as well as on the
    //     definition — an unprefixed target would resolve against nothing.
    //  2. Mach-O relocations carry NO addend field; the addend lives in the
    //     field bytes and `link/macho_reader.zig` reads it back out from there.
    //     So it is written into the image here, where ELF leaves the image
    //     untouched and puts the addend in the RELA entry.
    var ro_fixups: std.ArrayList(GlobalFixup) = .empty;
    for (try placeReadonlyGlobals(a, module, &rodata, &ro_fixups, freestanding)) |g| {
        const sym = try mac(a, g.name);
        try symbols.append(a, .{ .name = sym, .section = .rodata, .offset = g.offset, .size = g.size, .binding = definitionBinding(obj_macho.Binding, freestanding, false) });
        try defined.put(a, sym, {});
    }
    for (ro_fixups.items) |f| {
        std.mem.writeInt(i64, rodata.items[@intCast(f.offset)..][0..8], f.addend, .little);
        try relocs.append(a, .{ .section = .rodata, .offset = f.offset, .symbol = try mac(a, f.symbol), .kind = .unsigned64 });
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
    if (rodata.items.len > 0) try sections.append(a, .{ .kind = .rodata, .data = rodata.items, .alignment = globalsAlign(module, .readonly, freestanding) });
    if (gc.items.len > 0) try sections.append(a, .{ .kind = .gc_meta, .data = gc.items, .alignment = 1 });
    if (data.items.len > 0) try sections.append(a, .{ .kind = .data, .data = data.items, .alignment = globalsAlign(module, .process, freestanding) });

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
const macho_reader = @import("link/macho_reader.zig");
const object = @import("link/object.zig");
const parser = @import("parser.zig");
const resolve = @import("resolve.zig");
const lower = @import("lower.zig");
const ast = @import("ast.zig");
const diagnostics = @import("diagnostics.zig");
const strip = @import("link/strip.zig");
const link = @import("link.zig");
const builtin = @import("builtin");
const elf = std.elf;

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

/// Appends a root-module `@nosplit` function whose body calls `target`, the
/// shape a runtime module has the moment it calls a sibling — the only shape
/// that can produce an unresolvable cross-module reference.
fn testAppendCaller(gpa: Allocator, module: *ir.Module, name: []const u8, target: ir.FuncId) !void {
    const i64_ty = module.ctx.prim_ids.get(.i64);
    var b = ir.FunctionBuilder.init(gpa);
    const entry = try b.newBlock();
    b.beginBlock(entry);
    const r = try b.call(i64_ty, target, &.{});
    try b.ret(&.{r});
    b.endBlock();
    var f = try b.finish(name, &.{}, i64_ty, false, .invalid, entry);
    f.is_nosplit = true;
    f.in_root_module = true;
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

/// The binding the emitted object gives the atom named `want`, or null if it
/// defines no such atom. Read back through the project's own ELF reader, so the
/// answer is the one the LINKER sees rather than one inferred from the writer.
fn testAtomBinding(gpa: Allocator, obj: []const u8, want: []const u8) !?object.Binding {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const mod = try elf_reader.read(arena_state.allocator(), .x86_64, "t.o", obj);
    for (mod.atoms) |atom| {
        if (std.mem.eql(u8, atom.name, want)) return atom.binding;
    }
    return null;
}

test "emit: a freestanding object holds only its own cells and exports only its pins" {
    // #1630 + #1631, the two linkage defects that stopped a Bit-sourced
    // libbitrt.a. Both are invisible to a single-object build and both are
    // SILENT in the shape that matters most:
    //
    //  - #1630: `lowerProject` registers a cell for every module, so without
    //    the filter each importer re-defines its imports' cells. Where the
    //    project-local ordinal in `__bitg_<n>_` happens to differ between two
    //    builds, both definitions survive the archive and the two modules then
    //    read and write DIFFERENT cells for one logical global.
    //  - #1631: a module-private helper took a plain global symbol equal to its
    //    source name, so two modules that each declare a `byteAt` collide.
    //
    // Asserted on BINDING, not just on presence: a cell or helper that is
    // defined-but-local cannot collide, and that is the property the archive
    // rests on. The managed half of each assertion is what keeps this about the
    // freestanding flag rather than about the symbol being unemittable.
    const gpa = testing.allocator;
    var ctx = try check.TypeContext.init(gpa);
    defer ctx.deinit();

    var module = ir.Module.init(gpa, &ctx);
    defer module.deinit();
    try testAppendFunc(gpa, &module, "helper", true); // private: the #1631 shape
    try testAppendFunc(gpa, &module, "bit_rt_thing", true);
    module.funcs.items[1].is_pinned = true; // §11.9: the one cross-object name
    // `addGlobal` takes ownership of both slices, so they must be heap-owned.
    _ = try module.addGlobal(try gpa.dupe(u8, "__bitg_0_mine"), try gpa.dupe(u8, &[_]u8{0} ** 8), 16, .process, true);
    _ = try module.addGlobal(try gpa.dupe(u8, "__bitg_1_theirs"), try gpa.dupe(u8, &[_]u8{0} ** 8), 16, .process, false);

    const free_obj = try emitObject(gpa, &module, false, true);
    defer gpa.free(free_obj);
    try testing.expectEqual(object.Binding.local, (try testAtomBinding(gpa, free_obj, "helper")).?);
    try testing.expectEqual(object.Binding.global, (try testAtomBinding(gpa, free_obj, "bit_rt_thing")).?);
    try testing.expectEqual(object.Binding.local, (try testAtomBinding(gpa, free_obj, "__bitg_0_mine")).?);
    try testing.expectEqual(@as(?object.Binding, null), try testAtomBinding(gpa, free_obj, "__bitg_1_theirs"));

    const whole_obj = try emitObject(gpa, &module, false, false);
    defer gpa.free(whole_obj);
    try testing.expectEqual(object.Binding.global, (try testAtomBinding(gpa, whole_obj, "helper")).?);
    try testing.expectEqual(object.Binding.global, (try testAtomBinding(gpa, whole_obj, "__bitg_0_mine")).?);
    try testing.expectEqual(object.Binding.global, (try testAtomBinding(gpa, whole_obj, "__bitg_1_theirs")).?);
}

test "emit: freestanding refuses a reference to another module's cell" {
    // #1630's other half, and the one that was LIVE: the inliner spliced
    // `runtime/root`'s pinned `rootBindMemory` into `runtime/root/darwin`'s
    // `boot`, leaving a `global_addr` on `runtime/root`'s `gcAddr`/`gcState`
    // inside an object that is not `runtime/root`. `opt.importsForeignState`
    // now stops that splice; this refuses the residue however it arises, so a
    // future pass that reintroduces the shape fails at emit instead of shipping
    // two cells for one global.
    const gpa = testing.allocator;
    var ctx = try check.TypeContext.init(gpa);
    defer ctx.deinit();

    var module = ir.Module.init(gpa, &ctx);
    defer module.deinit();
    const theirs = try module.addGlobal(try gpa.dupe(u8, "__bitg_1_theirs"), try gpa.dupe(u8, &[_]u8{0} ** 8), 16, .process, false);
    try testAppendGlobalReader(gpa, &module, "rootFn", theirs);

    try testing.expectError(error.FreestandingImportedGlobal, emitObject(gpa, &module, false, true));
    // Managed, the same module is one compilation unit and the cell is right
    // there — so this is about the object boundary, not about the reference.
    const whole_obj = try emitObject(gpa, &module, false, false);
    defer gpa.free(whole_obj);
    try testing.expect(try testObjectDefines(gpa, whole_obj, "rootFn"));
}

/// Appends a root-module `@nosplit` function whose body takes the address of
/// `g` — the shape an inlined cross-module accessor leaves behind.
fn testAppendGlobalReader(gpa: Allocator, module: *ir.Module, name: []const u8, g: ir.GlobalId) !void {
    const i64_ty = module.ctx.prim_ids.get(.i64);
    var b = ir.FunctionBuilder.init(gpa);
    const entry = try b.newBlock();
    b.beginBlock(entry);
    const addr = try b.globalAddr(i64_ty, g);
    try b.ret(&.{addr});
    b.endBlock();
    var f = try b.finish(name, &.{}, i64_ty, false, .invalid, entry);
    f.is_nosplit = true;
    f.in_root_module = true;
    try module.funcs.append(gpa, f);
}

test "emit: a globals section is at least as aligned as the cells it holds" {
    // §11.11 guarantees every module cell is 16-byte aligned, and `placeGlobals`
    // pads each cell to its own alignment — but padding WITHIN a section only
    // survives into the loaded image if the section is itself that aligned.
    //
    // This is asserted here, on the emitted object, rather than left to the
    // `run_module_state_align` golden, because that golden CANNOT catch it: the
    // suite runs host-native, and with the section pinned at 8 the guarantee
    // still held on aarch64-macOS while every cell sat at `addr % 16 == 8` on
    // x86_64-linux (#1421). A host-only guard would have been vacuous for the
    // one target that was broken.
    const gpa = testing.allocator;
    var ctx = try check.TypeContext.init(gpa);
    defer ctx.deinit();

    var module = ir.Module.init(gpa, &ctx);
    defer module.deinit();
    try testAppendFunc(gpa, &module, "rootFn", true);
    // `addGlobal` takes ownership of both slices, so they must be heap-owned.
    _ = try module.addGlobal(
        try gpa.dupe(u8, "__bitg_0_cell"),
        try gpa.dupe(u8, &[_]u8{0} ** 8),
        16,
        .process,
        true,
    );

    const obj = try emitObject(gpa, &module, false, false);
    defer gpa.free(obj);

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const mod = try elf_reader.read(arena_state.allocator(), .x86_64, "t.o", obj);

    var saw_data = false;
    for (mod.atoms) |atom| {
        if (atom.kind != .data) continue;
        saw_data = true;
        try testing.expect(atom.alignment >= 16);
    }
    // Guards the guard: an assertion over an empty set would pass for the wrong
    // reason if globals ever stopped landing in `.data`.
    try testing.expect(saw_data);
}

test "emit: a freestanding member carries its own stack maps, @nosplit or not" {
    // ABI.md §4.1, and the reason this mode stopped constraining the runtime.
    // §17.6 used to REFUSE a function that was neither `@nosplit` nor `@naked`,
    // because a freestanding object carried no stack map and an unscannable
    // frame is silent wrongness. That rule made `sched` unrepresentable:
    // #1429/#1431 removed `@nosplit` from `schedWorkerRun` precisely so
    // stop-the-world is sound. Now the member carries its own entries, so the
    // requirement is gone at its root — asserted as a POSITIVE property (the
    // entries exist) rather than merely as the absence of the old refusal.
    const gpa = testing.allocator;
    var ctx = try check.TypeContext.init(gpa);
    defer ctx.deinit();

    var module = ir.Module.init(gpa, &ctx);
    defer module.deinit();
    try testAppendFunc(gpa, &module, "managedFn", true);
    module.funcs.items[0].is_nosplit = false;

    const obj = try emitObject(gpa, &module, false, true);
    defer gpa.free(obj);
    try testing.expect(try testObjectDefines(gpa, obj, "managedFn"));

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const mod = try elf_reader.read(arena_state.allocator(), .x86_64, "t.o", obj);
    var entries: usize = 0;
    for (mod.atoms) |atom| {
        if (atom.kind == .gc_meta) entries += 1;
    }
    try testing.expectEqual(@as(usize, 1), entries);
}

test "emit: the ELF reader classifies .bit_gc by NAME, not by flags" {
    // THE TRAP this change is most likely to fall into, asserted through the
    // object reader so it is target-INDEPENDENT and fails on any host.
    //
    // `.bit_gc` is ALLOC+PROGBITS, non-writable and non-executable, so
    // `classify`'s flag rules land it on `.rodata` unless the name is checked
    // first. Nothing about that failure is visible in the emitted object, in
    // the link, or in any golden: the entries simply get interleaved with
    // unrelated read-only atoms, the merged extent stops being contiguous, and
    // the collector walks garbage between real entries. That is #1421's exact
    // shape — correct on one container, wrong on the other, goldens green
    // throughout — and the whole golden suite runs host-native, so it could
    // never have caught the ELF half on this machine.
    const gpa = testing.allocator;
    var ctx = try check.TypeContext.init(gpa);
    defer ctx.deinit();

    var module = ir.Module.init(gpa, &ctx);
    defer module.deinit();
    try testAppendFunc(gpa, &module, "a", true);
    try testAppendFunc(gpa, &module, "b", true);
    try testAppendFunc(gpa, &module, "c", true);

    const obj = try emitObject(gpa, &module, false, true);
    defer gpa.free(obj);

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const mod = try elf_reader.read(arena_state.allocator(), .x86_64, "t.o", obj);

    // One atom per FUNCTION, not one per module: this is what lets the linker
    // drop an entry whose function it dropped, instead of retaining every
    // runtime module wholesale in every image.
    var entries: usize = 0;
    for (mod.atoms) |atom| {
        if (atom.kind != .gc_meta) continue;
        entries += 1;
        // 1-aligned, or the linker would pad between entries and the runtime
        // would decode the padding as an entry.
        try testing.expectEqual(@as(u32, 1), atom.alignment);
        // Every entry names its function — the relocation the retention rule
        // and the runtime's code_addr both read.
        try testing.expectEqual(@as(usize, 1), atom.relocs.len);
        try testing.expectEqual(object.RelocKind.abs64, atom.relocs[0].kind);
    }
    try testing.expectEqual(@as(usize, 3), entries);
}

test "emit: the Mach-O reader classifies __bit_gc by NAME, not by segment" {
    // The Mach-O half of the trap above, and the one this host CAN run
    // natively — `macho_reader.classify` returns `.data` for anything in
    // `__DATA` unless the section name is tested first. Same silent failure:
    // entries scattered among unrelated `__DATA` atoms, no diagnostic.
    const gpa = testing.allocator;
    var ctx = try check.TypeContext.init(gpa);
    defer ctx.deinit();

    var module = ir.Module.init(gpa, &ctx);
    defer module.deinit();
    try testAppendFunc(gpa, &module, "a", true);
    try testAppendFunc(gpa, &module, "b", true);

    const obj = try emitMachoObject(gpa, &module, false, true);
    defer gpa.free(obj);

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const mod = try macho_reader.read(arena_state.allocator(), "t.o", obj);
    var entries: usize = 0;
    for (mod.atoms) |atom| {
        if (atom.kind != .gc_meta) continue;
        entries += 1;
        try testing.expectEqual(@as(usize, 1), atom.relocs.len);
    }
    try testing.expectEqual(@as(usize, 2), entries);
}

test "link: the merged table is bounded by linker-defined markers only" {
    // The property the merge exists for, asserted on the generic object model
    // so it holds for BOTH containers. Two separate "archive members" each
    // carrying entries must merge into ONE run: start marker, every retained
    // entry, end marker — with nothing interleaved and no per-member
    // terminator, which would stop the runtime's walk at the first member.
    const gpa = testing.allocator;

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Two members, each: one kept function + its entry, one DEAD function +
    // its entry. The dead entries must not survive — that is the retention
    // rule, and force-keeping entries instead would drag both dead functions
    // back in.
    var mods: std.ArrayList(object.Module) = .empty;
    for ([_][]const u8{ "m0", "m1" }) |mname| {
        const atoms = try arena.alloc(object.Atom, 4);
        const live = try std.fmt.allocPrint(arena, "{s}_live", .{mname});
        const dead = try std.fmt.allocPrint(arena, "{s}_dead", .{mname});
        atoms[0] = .{ .name = live, .kind = .text, .binding = .global, .data = &.{}, .size = 0, .alignment = 1, .relocs = &.{} };
        atoms[1] = .{ .name = dead, .kind = .text, .binding = .global, .data = &.{}, .size = 0, .alignment = 1, .relocs = &.{} };
        atoms[2] = .{ .name = "__bitsm_0", .kind = .gc_meta, .binding = .local, .data = &.{}, .size = 0, .alignment = 1, .relocs = try arena.dupe(object.Reloc, &.{.{ .offset = 0, .kind = .abs64, .target = .{ .local = 0 } }}) };
        atoms[3] = .{ .name = "__bitsm_1", .kind = .gc_meta, .binding = .local, .data = &.{}, .size = 0, .alignment = 1, .relocs = try arena.dupe(object.Reloc, &.{.{ .offset = 0, .kind = .abs64, .target = .{ .local = 1 } }}) };
        try mods.append(arena, .{ .name = mname, .atoms = atoms });
    }
    // The entry root reaches only each member's `_live`.
    const rt = try arena.alloc(object.Atom, 1);
    rt[0] = .{ .name = "_start", .kind = .text, .binding = .global, .data = &.{}, .size = 0, .alignment = 1, .relocs = try arena.dupe(object.Reloc, &.{
        .{ .offset = 0, .kind = .abs64, .target = .{ .global = "m0_live" } },
        .{ .offset = 8, .kind = .abs64, .target = .{ .global = "m1_live" } },
    }) };
    try mods.append(arena, .{ .name = "rt", .atoms = rt });

    const marker_module: u32 = @intCast(mods.items.len);
    try mods.append(arena, try strip.markerModule(arena, ""));
    const all = mods.items;

    var globals = try strip.resolveGlobals(arena, all);
    var kept = try strip.deadStrip(arena, all, &globals, &.{ "_start", strip.stackmaps_start_symbol, strip.stackmaps_end_symbol });
    defer kept.deinit(arena);
    const group = try strip.mergedStackMapAtoms(arena, all, &globals, &kept, marker_module);

    // start marker + one entry per LIVE function (2) + end marker.
    try testing.expectEqual(@as(usize, 4), group.len);
    try testing.expectEqualStrings(strip.stackmaps_start_symbol, all[group[0].module].atoms[group[0].atom].name);
    try testing.expectEqualStrings(strip.stackmaps_end_symbol, all[group[3].module].atoms[group[3].atom].name);
    // The interior is entries from BOTH members — the single-member case
    // cannot distinguish a working merge from a table that stops early.
    try testing.expect(group[1].module != group[2].module);
    for (group[1..3]) |id| {
        const atom = all[id.module].atoms[id.atom];
        try testing.expectEqual(object.SectionKind.gc_meta, atom.kind);
        // Each surviving entry describes a KEPT function...
        try testing.expect(kept.contains(try strip.resolveRef(&globals, id.module, atom.relocs[0].target)));
    }
    // ...and the dead functions stayed dead: retaining entries unconditionally
    // would have resurrected them through their own relocations.
    try testing.expect(!kept.contains(.{ .module = 0, .atom = 1 }));
    try testing.expect(!kept.contains(.{ .module = 1, .atom = 1 }));
}

test "emit: pinned and mangled names are disjoint sets" {
    // The invariant `firstUnpinnedImport` decides on. §11.9 restricts a pin to
    // a C identifier, and every name lowering synthesizes for a non-root
    // function carries a `$`. If a future mangling scheme dropped the `$`, an
    // unpinned import would masquerade as pinned and the refusal below would
    // silently stop firing — so the two spellings are asserted here directly.
    try testing.expect(isPinnedName("bit_rt_spin_acquire"));
    try testing.expect(isPinnedName("_bit_rt_alloc0"));
    try testing.expect(!isPinnedName("m0$libUnpinned")); // moduleQualified
    try testing.expect(!isPinnedName("m2$grow$3")); // generic instantiation
    try testing.expect(!isPinnedName("m1$reset$t26")); // method
    try testing.expect(!isPinnedName("closure$7")); // synthesized body
}

test "emit: freestanding refuses an unpinned cross-module call" {
    // #1408, the other half of §17.6's mechanism. Module scoping alone leaves a
    // call into an imported module as an undefined reference to that callee's
    // LOWERED name — `m<id>$f`, where `<id>` is an ordinal THIS build assigned.
    // The sibling's own freestanding object emits the same function BARE, since
    // there it is the root, so the two spellings can never match and the
    // reference is undefined forever.
    //
    // It has to be refused here because nothing downstream reports it usefully:
    // an undefined symbol in an archive member nothing references is
    // dead-stripped rather than diagnosed, and on Darwin an unresolved
    // reference falls through to a libSystem import and aborts at dyld load.
    const gpa = testing.allocator;
    var ctx = try check.TypeContext.init(gpa);
    defer ctx.deinit();

    var module = ir.Module.init(gpa, &ctx);
    defer module.deinit();
    try testAppendFunc(gpa, &module, "m0$importedFn", false);
    try testAppendCaller(gpa, &module, "rootFn", @enumFromInt(0));

    try testing.expectEqualStrings("m0$importedFn", firstUnpinnedImport(&module).?);
    try testing.expectError(error.FreestandingUnpinned, emitObject(gpa, &module, false, true));
    try testing.expectError(error.FreestandingUnpinned, emitObjectArm64Elf(gpa, &module, false, true));
    try testing.expectError(error.FreestandingUnpinned, emitMachoObject(gpa, &module, false, true));

    // Pin that same import — nothing else changes — and it emits, leaving the
    // call as an undefined reference the sibling's object can actually satisfy.
    // This is what makes the refusal a statement about PINNING rather than
    // about cross-module calls in general, which are the point of the mode.
    gpa.free(module.funcs.items[0].name);
    module.funcs.items[0].name = try gpa.dupe(u8, "bit_rt_imported");
    try testing.expect(firstUnpinnedImport(&module) == null);
    const obj = try emitObject(gpa, &module, false, true);
    defer gpa.free(obj);
    try testing.expect(try testObjectDefines(gpa, obj, "rootFn"));
    try testing.expect(!try testObjectDefines(gpa, obj, "bit_rt_imported"));
}

test "emit: a whole-program emit is unaffected by pinning" {
    // The refusal is scoped to §17.6. An ordinary build lowers every module
    // into one object and resolves the call internally, so an unpinned import
    // is not merely tolerated there — it is the normal case, and making the
    // check unconditional would break every multi-module program.
    const gpa = testing.allocator;
    var ctx = try check.TypeContext.init(gpa);
    defer ctx.deinit();

    var module = ir.Module.init(gpa, &ctx);
    defer module.deinit();
    try testAppendFunc(gpa, &module, "m0$importedFn", false);
    try testAppendCaller(gpa, &module, "rootFn", @enumFromInt(0));

    const obj = try emitObject(gpa, &module, false, false);
    defer gpa.free(obj);
    try testing.expect(try testObjectDefines(gpa, obj, "rootFn"));
    try testing.expect(try testObjectDefines(gpa, obj, "m0$importedFn"));
}

// ============================================================================
// #1447: read-only static data (`.rodata`) — see SPEC §11.11.
//
// THIS AREA HAS SILENTLY BROKEN TWICE. AArch64 `$d`/`$x` mapping symbols once
// corrupted a `.rodata` table so `log10` returned 5.6e31, and the linker once
// dropped the section bytes ahead of the first symbol so a `.cst8` lane vector
// read as zeros and `indexOfScalar` always returned 0. Both LINKED CLEANLY and
// returned wrong numbers.
//
// So nothing below is satisfied by "it built". Every assertion reads the
// EMITTED BYTES back out through the object reader and compares them to the
// authored image, for all three targets, on any host.
// ============================================================================

/// The image used by every `.rodata` test below. Chosen adversarially rather
/// than as zeros or a counting sequence: no byte repeats a neighbour, no 8-byte
/// window is all-zero, and the first and last bytes are distinctive — so a table
/// that is truncated, shifted by a few bytes, or has its leading run dropped
/// (the exact prior bug) cannot compare equal by luck.
const ro_image = [_]u8{
    0xDE, 0xAD, 0xBE, 0xEF, 0xCA, 0xFE, 0xBA, 0xBE,
    0x01, 0x23, 0x45, 0x67, 0x89, 0xAB, 0xCD, 0xEF,
    0xF0, 0x0D, 0xFA, 0xCE, 0xD1, 0xCE, 0x5E, 0xA1,
};

fn testRoModule(gpa: Allocator, module: *ir.Module) !void {
    try testAppendFunc(gpa, module, "rootFn", true);
    _ = try module.addGlobal(
        try gpa.dupe(u8, "__bitro_table"),
        try gpa.dupe(u8, &ro_image),
        16,
        .readonly,
        true,
    );
}

test "emit: a readonly global lands in .rodata with its bytes intact, on every target" {
    // The core of #1447, asserted through the object readers so it is
    // target-INDEPENDENT (#1421's rule) and fails on any host rather than only
    // on the host whose layout happens to expose the bug.
    //
    // Three separate claims, and each one has been a real bug in some project:
    //   1. the atom's section is `.rodata`, not `.data` — otherwise the whole
    //      feature is a no-op that happens to work;
    //   2. its bytes are EXACTLY the authored image — the two prior failures
    //      were both silent corruption of correct-looking output;
    //   3. the atom is at least as aligned as the cell asked for — #1421
    //      exactly, and `.rodata` was pinned at 8 while this cell wants 16.
    const gpa = testing.allocator;

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const Case = struct { name: []const u8, elf: ?elf_reader.Target };
    for ([_]Case{
        .{ .name = "x86_64-elf", .elf = .x86_64 },
        .{ .name = "aarch64-elf", .elf = .aarch64 },
        .{ .name = "aarch64-macho", .elf = null },
    }) |case| {
        var ctx = try check.TypeContext.init(gpa);
        defer ctx.deinit();
        var module = ir.Module.init(gpa, &ctx);
        defer module.deinit();
        try testRoModule(gpa, &module);

        const obj = if (case.elf) |t| switch (t) {
            .x86_64 => try emitObject(gpa, &module, false, false),
            .aarch64 => try emitObjectArm64Elf(gpa, &module, false, false),
        } else try emitMachoObject(gpa, &module, false, false);
        defer gpa.free(obj);

        // Mach-O decorates the symbol; ELF does not.
        const want_sym = if (case.elf == null) "___bitro_table" else "__bitro_table";
        const mod = if (case.elf) |t|
            try elf_reader.read(arena, t, "t.o", obj)
        else
            try macho_reader.read(arena, "t.o", obj);

        var found = false;
        for (mod.atoms) |atom| {
            if (!std.mem.eql(u8, atom.name, want_sym)) continue;
            found = true;
            errdefer std.debug.print("target {s}\n", .{case.name});
            // (1) genuinely read-only, not merely "somewhere".
            try testing.expectEqual(object.SectionKind.rodata, atom.kind);
            // (2) the bytes, verbatim. This is the assertion the two prior
            //     silent-wrongness bugs would each have failed.
            try testing.expectEqualSlices(u8, &ro_image, atom.data[0..atom.size]);
            // (3) alignment survived into the section (#1421).
            try testing.expect(atom.alignment >= 16);
        }
        // Anti-vacuity: without this, deleting the emission entirely would make
        // the loop body never run and the test pass.
        if (!found) {
            std.debug.print("target {s}: no .rodata atom named {s} was emitted at all\n", .{ case.name, want_sym });
            return error.ReadonlyGlobalNotEmitted;
        }
    }
}

test "emit: a module-level `const [N]T` lands in .rodata from SOURCE, on every target (#1231)" {
    // #1447 proved a readonly `ir.Global` reaches `.rodata`; this proves the
    // half #1231 adds — that the checker+lowerer turn a `const [N]T{...}` in
    // SOURCE into exactly such a global, with the authored bytes. Asserted
    // through the object readers so it is target-independent (#1421) and
    // fails on any host, NOT on a passing run: a wrong GC descriptor on a
    // rodata table is invisible at runtime (the collector ignores the pointer),
    // so program output would pass against a broken image.
    const gpa = testing.allocator;
    const src =
        \\const T: [4]u8 = [4]u8{ 10, 20, 30, 40 }
        \\function main() {
        \\  print("${T[0]}")
        \\}
        \\
    ;
    // A byte image with no repeated neighbour and no run, so a truncated or
    // shifted table cannot compare equal by luck.
    const want_bytes = [_]u8{ 10, 20, 30, 40 };

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const Case = struct { name: []const u8, elf: ?elf_reader.Target };
    for ([_]Case{
        .{ .name = "x86_64-elf", .elf = .x86_64 },
        .{ .name = "aarch64-elf", .elf = .aarch64 },
        .{ .name = "aarch64-macho", .elf = null },
    }) |case| {
        var sm = diagnostics.SourceManager.init(gpa);
        defer sm.deinit();
        var diags = diagnostics.Diagnostics.init(gpa, &sm);
        defer diags.deinit();

        var tree = try ast.Tree.init(gpa);
        defer tree.deinit();
        const file = try sm.addFile("t.bit", src);
        try parser.parse(gpa, &tree, &diags, file, src);
        try testing.expect(!diags.hasErrors());

        var files = [_]resolve.ModuleFile{.{ .file = file, .source = src, .tree = &tree }};
        var no_imports: resolve.ImportTable = .{};
        defer no_imports.deinit(gpa);
        var rmodule = try resolve.resolveModule(gpa, &diags, &files, &no_imports, &.{}, null);
        defer rmodule.deinit();
        try testing.expect(!diags.hasErrors());

        var ctx = try check.TypeContext.init(gpa);
        defer ctx.deinit();
        var checked = try check.checkModule(gpa, &diags, &ctx, &files, &rmodule, @enumFromInt(0), &.{}, false);
        defer checked.deinit();
        try testing.expect(!diags.hasErrors());

        var module = try lower.lowerModule(gpa, &ctx, &files, &checked, &rmodule);
        defer module.deinit();

        // (0) The lowerer produced a READONLY global with the authored image —
        // the boundary #1231 owns, before emission touches it.
        var lowered = false;
        for (module.globals.items) |g| {
            if (!std.mem.eql(u8, g.name, "__bitc_0_T")) continue;
            lowered = true;
            try testing.expectEqual(ir.GlobalStorage.readonly, g.storage);
            try testing.expectEqualSlices(u8, &want_bytes, g.bytes);
        }
        try testing.expect(lowered);

        const obj = if (case.elf) |t| switch (t) {
            .x86_64 => try emitObject(gpa, &module, false, false),
            .aarch64 => try emitObjectArm64Elf(gpa, &module, false, false),
        } else try emitMachoObject(gpa, &module, false, false);
        defer gpa.free(obj);

        const want_sym = if (case.elf == null) "___bitc_0_T" else "__bitc_0_T";
        const mod = if (case.elf) |t|
            try elf_reader.read(arena, t, "t.o", obj)
        else
            try macho_reader.read(arena, "t.o", obj);

        var found = false;
        for (mod.atoms) |atom| {
            if (!std.mem.eql(u8, atom.name, want_sym)) continue;
            found = true;
            errdefer std.debug.print("target {s}\n", .{case.name});
            try testing.expectEqual(object.SectionKind.rodata, atom.kind);
            try testing.expectEqualSlices(u8, &want_bytes, atom.data[0..atom.size]);
        }
        if (!found) {
            std.debug.print("target {s}: no .rodata atom named {s} was emitted from the const\n", .{ case.name, want_sym });
            return error.ConstArrayNotInRodata;
        }
    }
}

test "emit: a readonly global's relocation targets the right symbol at the right offset" {
    // The other half of #1447: a `[]T` slice header living in `.rodata` needs
    // its `buf` word filled in with the payload's link-time address, which only
    // the linker knows. Asserted on the emitted relocation rather than on a
    // linked image so it holds for every target on every host.
    const gpa = testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    for ([_]elf_reader.Target{ .x86_64, .aarch64 }) |t| {
        var ctx = try check.TypeContext.init(gpa);
        defer ctx.deinit();
        var module = ir.Module.init(gpa, &ctx);
        defer module.deinit();
        try testAppendFunc(gpa, &module, "rootFn", true);

        // The payload, then a 16-byte header whose first word points at it.
        _ = try module.addGlobal(try gpa.dupe(u8, "__bitro_buf"), try gpa.dupe(u8, &ro_image), 8, .readonly, true);
        const fixups = try gpa.alloc(ir.GlobalReloc, 1);
        fixups[0] = .{ .offset = 0, .symbol = try gpa.dupe(u8, "__bitro_buf"), .addend = 0 };
        _ = try module.addGlobalWithRelocs(
            try gpa.dupe(u8, "__bitro_hdr"),
            try gpa.dupe(u8, &[_]u8{0} ** 16),
            8,
            .readonly,
            fixups,
            true,
        );

        const obj = switch (t) {
            .x86_64 => try emitObject(gpa, &module, false, false),
            .aarch64 => try emitObjectArm64Elf(gpa, &module, false, false),
        };
        defer gpa.free(obj);
        const mod = try elf_reader.read(arena, t, "t.o", obj);

        var checked = false;
        for (mod.atoms) |atom| {
            if (!std.mem.eql(u8, atom.name, "__bitro_hdr")) continue;
            checked = true;
            try testing.expectEqual(object.SectionKind.rodata, atom.kind);
            try testing.expectEqual(@as(usize, 1), atom.relocs.len);
            const r = atom.relocs[0];
            // Rebased to the ATOM, not left as a blob offset — the bug that
            // would point the header at whatever else shares the section.
            try testing.expectEqual(@as(u32, 0), r.offset);
            try testing.expectEqual(object.RelocKind.abs64, r.kind);
            try testing.expectEqualStrings("__bitro_buf", r.target.global);
        }
        try testing.expect(checked);
    }
}

/// A self-contained `_start` that reads the FIRST BYTE of `__bitro_table` and
/// exits with it. No runtime, no libc, no archive — just enough to prove the
/// value a running program sees is the value that was authored.
///
/// It also serves a second, non-obvious purpose: `link.zig` dead-strips
/// `.rodata` at symbol granularity (only mutable-data atoms are kept
/// unconditionally), so an UNREFERENCED read-only global is correctly dropped.
/// Referencing it from the entry point is what makes it reachable, and is also
/// how a real program would reach it.
fn testRoEntryObject(gpa: Allocator, target: link.Target) ![]u8 {
    switch (target) {
        .x86_64_linux => {
            // movabs rdi, __bitro_table ; movzx edi, byte [rdi]
            // mov eax, 60 (SYS_exit)    ; syscall
            const code = [_]u8{
                0x48, 0xBF, 0,    0,    0,    0,    0,    0,    0,    0,
                0x0F, 0xB6, 0x3F, 0xB8, 0x3C, 0x00, 0x00, 0x00, 0x0F, 0x05,
            };
            const sections = [_]obj_elf.Section{.{ .kind = .text, .data = &code, .alignment = 16 }};
            const symbols = [_]obj_elf.Symbol{
                .{ .name = "_start", .section = .text, .offset = 0, .size = code.len, .binding = .global, .kind = .func },
                // Undefined here; the compiled object defines it.
                .{ .name = "__bitro_table", .section = null, .binding = .global },
            };
            const relocs = [_]obj_elf.Relocation{.{ .section = .text, .offset = 2, .symbol = "__bitro_table", .kind = .abs64, .addend = 0 }};
            return obj_elf.write(gpa, .x86_64, .{ .sections = &sections, .symbols = &symbols, .relocations = &relocs });
        },
        .aarch64_linux => {
            // adrp x0, table ; add x0, x0, :lo12:table ; ldrb w0, [x0]
            // movz x8, #93 (SYS_exit)  ; svc #0
            var code: [20]u8 = undefined;
            for ([_]u32{ 0x90000000, 0x91000000, 0x39400000, 0xD2800BA8, 0xD4000001 }, 0..) |w, i| {
                std.mem.writeInt(u32, code[i * 4 ..][0..4], w, .little);
            }
            const sections = [_]obj_elf.Section{.{ .kind = .text, .data = &code, .alignment = 16 }};
            const symbols = [_]obj_elf.Symbol{
                .{ .name = "_start", .section = .text, .offset = 0, .size = code.len, .binding = .global, .kind = .func },
                // Undefined here; the compiled object defines it.
                .{ .name = "__bitro_table", .section = null, .binding = .global },
            };
            const relocs = [_]obj_elf.Relocation{
                .{ .section = .text, .offset = 0, .symbol = "__bitro_table", .kind = .aarch64_adr_prel_pg_hi21, .addend = 0 },
                .{ .section = .text, .offset = 4, .symbol = "__bitro_table", .kind = .aarch64_add_abs_lo12_nc, .addend = 0 },
            };
            return obj_elf.write(gpa, .aarch64, .{ .sections = &sections, .symbols = &symbols, .relocations = &relocs });
        },
    }
}

test "link: a readonly global's bytes reach the executable in a NON-WRITABLE segment, and a program reads them back" {
    // The prior failures were both link-stage, not emit-stage: the object was
    // fine and the linked image was not. So the image itself is read back here,
    // at the virtual address the symbol resolves to, and compared byte for byte
    // — and then, where the host can execute it, the linked program is RUN and
    // its exit code checked against the authored value.
    //
    // The permission assertion is the part a running program could never make:
    // `.rodata` is only a real guarantee if the segment carries no `PF_W`.
    const gpa = testing.allocator;

    for ([_]link.Target{ .x86_64_linux, .aarch64_linux }) |target| {
        var ctx = try check.TypeContext.init(gpa);
        defer ctx.deinit();
        var module = ir.Module.init(gpa, &ctx);
        defer module.deinit();
        try testRoModule(gpa, &module);

        const obj = switch (target) {
            .x86_64_linux => try emitObject(gpa, &module, false, false),
            .aarch64_linux => try emitObjectArm64Elf(gpa, &module, false, false),
        };
        defer gpa.free(obj);
        const entry = try testRoEntryObject(gpa, target);
        defer gpa.free(entry);

        // No archive: the program is self-contained and needs no runtime, which
        // also keeps this independent of whether `zig build libbitrt` has run.
        const exe = try link.linkExecutable(gpa, target, &.{ .{ .object = obj }, .{ .object = entry } });
        defer gpa.free(exe);

        // Located by CONTENT, because our linker writes no symbol table into a
        // finished executable — and locating it this way is the stronger claim
        // anyway: it asserts the exact authored run is present, which is
        // precisely what the "linker dropped the bytes ahead of the first
        // symbol" bug destroyed. `ro_image` is 24 distinctive bytes, so an
        // incidental match is not a real possibility; the count is asserted to
        // be exactly one so a duplicated or partly-copied table also fails.
        const where = try findImageBytes(exe, &ro_image) orelse {
            std.debug.print("target {s}: the authored .rodata bytes are not in the linked image at all\n", .{@tagName(target)});
            return error.ReadonlyGlobalLost;
        };
        // (2) 16-byte alignment held all the way into the loaded image (#1421).
        try testing.expectEqual(@as(u64, 0), where.vaddr % 16);
        // (3) and the page it lands on is not writable. Without this, `.rodata`
        //     would be a section name rather than a guarantee.
        try testing.expect(where.writable == false);

        // (4) a real process reads the real value. Only possible natively; the
        //     cross half is covered by the x64/arm64 Linux gates.
        if (!hostRuns(target)) continue;
        const rc = try testRunLinked(gpa, "bit-rodata", exe);
        try testing.expectEqual(ro_image[0], rc);
    }
}

/// Whether this host can execute a `target` binary directly.
fn hostRuns(target: link.Target) bool {
    if (builtin.os.tag != .linux) return false;
    return switch (target) {
        .x86_64_linux => builtin.cpu.arch == .x86_64,
        .aarch64_linux => builtin.cpu.arch == .aarch64,
    };
}

/// Writes `exe` somewhere unique, execs it, returns its exit code.
///
/// The path carries the test seed and is published by rename, for the reason
/// recorded on `link.zig`'s `linkAndRun` (#1459): a fixed path that is written
/// and then exec'd races `fork` in a sibling worker (ETXTBSY), and on macOS a
/// reused path serves a CACHED code signature — which has already produced a
/// false pass in this project.
fn testRunLinked(gpa: Allocator, stem: []const u8, exe: []const u8) !u8 {
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const cwd = std.Io.Dir.cwd();

    const path = try std.fmt.allocPrintSentinel(gpa, "/tmp/{s}-{x}", .{ stem, testing.random_seed }, 0);
    defer gpa.free(path);
    const staging = try std.fmt.allocPrintSentinel(gpa, "{s}.staging", .{path}, 0);
    defer gpa.free(staging);

    try cwd.writeFile(io, .{ .sub_path = staging, .data = exe, .flags = .{ .permissions = .executable_file } });
    try cwd.rename(staging, cwd, path, io);
    defer cwd.deleteFile(io, path) catch {};

    const r = try std.process.run(gpa, io, .{ .argv = &.{path} });
    defer gpa.free(r.stdout);
    defer gpa.free(r.stderr);
    return switch (r.term) {
        .exited => |c| c,
        else => error.AbnormalExit,
    };
}

const ImageLocation = struct { vaddr: u64, file_off: usize, writable: bool };

/// Finds `pattern` in a linked ELF executable and reports where the loader will
/// map it: its virtual address and whether its `PT_LOAD` is writable. Returns
/// null if it is absent; errors if it appears more than once.
///
/// Walks the real program headers rather than trusting anything the linker said
/// in memory — the whole point of the caller is to check the linker's output
/// against an independent reading of it. Content search rather than symbol
/// lookup because a finished executable from this linker carries no `.symtab`.
fn findImageBytes(exe: []const u8, pattern: []const u8) !?ImageLocation {
    var file_off: ?usize = null;
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, exe, from, pattern)) |at| {
        if (file_off != null) return error.ReadonlyGlobalDuplicated;
        file_off = at;
        from = at + 1;
    }
    const off = file_off orelse return null;

    const ehdr = std.mem.bytesToValue(elf.Elf64_Ehdr, exe[0..@sizeOf(elf.Elf64_Ehdr)]);
    var p: usize = 0;
    while (p < ehdr.e_phnum) : (p += 1) {
        const ph = std.mem.bytesToValue(elf.Elf64_Phdr, exe[@intCast(ehdr.e_phoff + p * ehdr.e_phentsize)..][0..@sizeOf(elf.Elf64_Phdr)]);
        if (ph.p_type != elf.PT_LOAD) continue;
        if (off < ph.p_offset or off >= ph.p_offset + ph.p_filesz) continue;
        return .{
            .vaddr = ph.p_vaddr + (off - ph.p_offset),
            .file_off = off,
            .writable = (ph.p_flags & elf.PF_W) != 0,
        };
    }
    // Present in the file but in no loadable segment: it would not be in memory
    // at all. That is a failure, not an absence.
    return error.ReadonlyGlobalNotLoaded;
}
