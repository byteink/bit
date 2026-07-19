//! AST → IR lowering (task #336): turns a type-checked, single-module AST
//! (`ast.Tree` + `resolve.Module` + `check.CheckedModule`) into `ir.Module`.
//!
//! ## Scope (v1)
//!
//! Covered, and exercised by this file's tests: arithmetic/compare/logical
//! (incl. short-circuit `&&`/`||`), `if`/`else`/`else if`, `while`, C-style
//! `for`, `for..of` over a slice or array, infinite `for`, `break`/`continue`,
//! assignment (ident/field/index lvalues, compound ops, `++`/`--`), struct
//! literals and field access, direct calls (free functions and monomorphized
//! generic functions), struct methods (static dispatch), interface method
//! calls (`call_iface`, dynamic dispatch by sorted method index), closures
//! (env-struct + fn-pointer pair, §18.3-ish), `defer` (LIFO, run before every
//! `return`/implicit fall-through), `spawn`, and string interpolation
//! (`string_concat` + `string_from_*` conversions, §5.7).
//!
//! Deliberately NOT covered (returns `error.UnsupportedConstruct`, never a
//! silently-wrong lowering): maps (construction and `for..in` — the
//! iteration protocol itself is still an open placeholder, see
//! `ir.RtFn.map_iter_init`'s doc comment); `select` (channels are not yet
//! lowered — #1146); slice re-slicing `s[lo:hi]` and the `[]T(n[, m])`
//! constructor (`slice_lit`/`[]T{...}`, `append`, dynamic index, and `len`/`cap`
//! all lower via the `slice_*` runtime calls — ABI.md §2); fallible functions'
//! `fail`/`?`/`catch`
//! (the `Result` calling convention is undecided — a plain `return` in a
//! fallible function still lowers fine, since it needs no convention beyond
//! "pass the ok value"); tuple-destructuring bindings; methods on a still-
//! generic struct receiver (e.g. `struct Stack<T>`, as opposed to a generic
//! *function* — which monomorphizes normally, see below); cross-module
//! imports (this module lowers exactly one `resolve.Module`, matching
//! `main.zig`'s current single-file-module driver).
//!
//! ## Monomorphization
//!
//! `checkModule` already discovers every generic-function instantiation a
//! module needs (`ctx.instantiations`, each call site linked via
//! `checked.instantiationOf`). Lowering does not re-derive this: for each
//! `Instantiation{generic, args, result}`, it builds a `GenericEnv` by zipping
//! `ctx.decl_generics.get(generic.pack())` (the template's own generic-param
//! symbols, in declared order) with `args`, then lowers the generic
//! function's body exactly once under that environment — every body node's
//! concrete type is `ctx.subst(checked.typeOf(...), env, 0)` rather than
//! `checked.typeOf(...)` directly (see `FnCtx.nodeType`). One `ir.Function`
//! is emitted per distinct instantiation, named `<name>$<index>`.
//!
//! ## Object layout (v1 — see also `ir.zig`'s module doc comment)
//!
//! `ir.Op.gc_alloc`/`field_get`/`field_set` need concrete byte offsets *at
//! lowering time*, ahead of any real codegen/target-ABI decision. This file
//! adopts the simplest self-consistent scheme that could work: every scalar
//! prim (`i8`..`u64`, `f32`, `f64`, `bool`) is stored inline at its natural
//! size/alignment; every other shape (`string`, `slice`, `array`, `map`,
//! `tuple`, `chan`, `struct`, `interface`, `func`/closure) is a single
//! 8-byte, GC-tracked opaque handle — "everything that isn't a bare number is
//! one boxed pointer." This is uniform and easy to get right (no recursive
//! layout, `fieldLayout` is a single non-recursive switch), at the cost of an
//! extra indirection a smarter ABI would avoid; refining it is later
//! codegen/ABI work, not this task's.
//!
//! ## Closures
//!
//! An `arrow_fn` lowers to a `(code, env)` pair via `ir.Op.make_closure`,
//! called through `ir.Op.call_value`. The env is a `gc_alloc`'d struct of
//! captured variables (or `const_nil` if nothing is captured), read inside
//! the closure's own `ir.Function` via `field_get` off an implicit leading
//! parameter. Capture analysis is deliberately coarse (v1): every name
//! currently in scope (minus the arrow's own parameters) is captured,
//! whether or not the body actually reads it — a safe over-approximation (an
//! unused capture is wasted, never wrong), avoiding a whole separate
//! free-variable AST walk. A later pass can prune it.
//!
//! ## SSA construction
//!
//! Blocks get **parameters** instead of phi nodes (see `ir.zig`'s module doc
//! comment). This file's `Env` is a flat, order-stable stack of `(name,
//! value, type)` bindings; at every merge point (`if`/`while`/`for`'s header
//! and exit blocks), the *entire* currently-live environment prefix is
//! threaded through as block params — again a simple, safe over-
//! approximation (some params end up unused because that name was never
//! reassigned in the branch) rather than a minimal-phi liveness analysis.

const std = @import("std");
const ast = @import("ast.zig");
const lexer = @import("lexer.zig");
const check = @import("check.zig");
const resolve = @import("resolve.zig");
const ir = @import("ir.zig");

/// Alignment of every module-level cell (§11.11).
///
/// 16, not the type's natural alignment, and the reason is the storage class's
/// stated purpose. §11.11 admits a fixed array `[N]U` precisely so the runtime
/// can carve its own memory out of one — and a green-thread stack is that use.
/// Both supported ABIs require a 16-byte-aligned stack pointer (AAPCS64 faults
/// on a misaligned `sp`; SysV x86-64 requires it at call boundaries), so an
/// 8-aligned array lands at `addr % 16 == 8` half the time and the fault
/// appears only for some declaration orders — a silent, order-dependent hazard
/// of exactly the kind §11.11's rule 1 exists to rule out.
///
/// A uniform 16 is what makes the guarantee statable and testable rather than
/// conditional on a cell's type or its neighbours. The cost is at most 8 bytes
/// of padding per cell in `.data`/`.bss`, which is nothing against the class of
/// fault it removes: module state is a handful of cells by construction.
const module_state_align: u32 = 16;

const Allocator = std.mem.Allocator;
const TypeId = check.TypeId;
const TypeContext = check.TypeContext;
const TypeData = check.TypeData;
const GlobalSymbol = check.GlobalSymbol;
const ModuleId = resolve.ModuleId;
const GenericEnv = check.GenericEnv;
const GenericBinding = check.GenericBinding;
const ModuleFile = resolve.ModuleFile;

pub const Error = error{
    /// Raised only for the deliberately-out-of-scope constructs named in the
    /// module doc comment — never for a construct this file claims to
    /// support (those, if genuinely broken, are bugs to fix, not to guard).
    UnsupportedConstruct,
} || Allocator.Error;

fn identTextOf(mf: ModuleFile, node: ast.Index) []const u8 {
    const span = mf.tree.get(node).span;
    return mf.source[span.start..span.end];
}

// ============================================================================
// Object layout (see module doc comment)
// ============================================================================

const FieldLayout = struct { size: u32, is_ptr: bool };

/// The in-memory size of a module-level `let`'s type (§11.11). Only the
/// untraced shapes the checker admits reach here: a scalar or raw `*T` is one
/// `fieldLayout` slot, and `[N]U` is `N` elements laid out at their natural
/// width — the same stride `index_get`/`index_set` use, which is what lets a
/// static cell stand in for a heap array without touching either op.
fn globalSize(ctx: *const TypeContext, ty: TypeId) u32 {
    const data = ctx.typeOf(ty);
    if (data == .array) return @intCast(data.array.len * fieldLayout(ctx.typeOf(data.array.elem)).size);
    return fieldLayout(data).size;
}

/// Renders a module-level `let`'s initial value into its static byte image
/// (§11.11). Little-endian: every target Bit emits for is.
fn globalImage(gpa: Allocator, ctx: *const TypeContext, ty: TypeId, init: check.ModuleStateInit) Error![]const u8 {
    const size = globalSize(ctx, ty);
    const buf = try gpa.alloc(u8, size);
    @memset(buf, 0);
    switch (init) {
        .zero => {},
        .boolean => |v| buf[0] = @intFromBool(v),
        .int => |v| std.mem.writeVarPackedInt(buf, 0, size * 8, @as(i64, @truncate(v)), .little),
        .float => |v| switch (size) {
            4 => std.mem.writeInt(u32, buf[0..4], @bitCast(@as(f32, @floatCast(v))), .little),
            else => std.mem.writeInt(u64, buf[0..8], @bitCast(v), .little),
        },
    }
    return buf;
}

fn fieldLayout(data: TypeData) FieldLayout {
    if (data == .prim) {
        return switch (data.prim) {
            .i8, .u8, .bool => .{ .size = 1, .is_ptr = false },
            .i16, .u16 => .{ .size = 2, .is_ptr = false },
            .i32, .u32, .f32 => .{ .size = 4, .is_ptr = false },
            .i64, .u64, .f64 => .{ .size = 8, .is_ptr = false },
            .string => .{ .size = 8, .is_ptr = true },
        };
    }
    // A raw pointer `*T` (§11.4) is a single word the GC must never follow:
    // 8 bytes, but is_ptr=false so its offset stays out of the pointer map.
    if (data == .ptr) return .{ .size = 8, .is_ptr = false };
    // A no-payload enum is a bare tag word; a payload-carrying one is a boxed
    // `{tag, payloadPtr}` handle (a GC ref).
    if (data == .@"enum") return .{ .size = 8, .is_ptr = check.enumBoxed(data.@"enum") };
    // slice/array/map/tuple/chan/struct/interface/func: uniform boxed handle.
    // void/untyped_*/invalid/type_param/fallible must never reach here in a
    // fully checked, monomorphized program.
    return .{ .size = 8, .is_ptr = true };
}

fn alignUp(v: u32, a: u32) u32 {
    return (v + a - 1) / a * a;
}

fn allIdents(tree: *const ast.Tree, nodes: []const ast.Index) bool {
    for (nodes) |n| if (tree.get(n).tag != .ident) return false;
    return true;
}

pub const StructLayout = struct {
    size: u32,
    field_offsets: []const u32,
    ptr_offsets: []const u32,

    fn deinit(self: *StructLayout, gpa: Allocator) void {
        gpa.free(self.field_offsets);
        gpa.free(self.ptr_offsets);
        self.* = undefined;
    }
};

fn layoutFields(gpa: Allocator, ctx: *TypeContext, fields: []const check.Field) Allocator.Error!StructLayout {
    const offsets = try gpa.alloc(u32, fields.len);
    errdefer gpa.free(offsets);
    var ptrs: std.ArrayList(u32) = .empty;
    errdefer ptrs.deinit(gpa);
    var cur: u32 = 0;
    for (fields, 0..) |f, i| {
        const fd = ctx.typeOf(f.ty);
        // A fixed-size array `[N]T` field is stored INLINE (value semantics,
        // SPEC §11.2): `N` contiguous elements right in this struct's body, not
        // a boxed handle. The element type is a scalar (checker-enforced), so
        // its size is a power of two — a valid alignment — and the inline
        // elements hold no GC references, so the field contributes no
        // `ptr_offsets`.
        if (fd == .array) {
            const el = fieldLayout(ctx.typeOf(fd.array.elem));
            cur = alignUp(cur, el.size);
            offsets[i] = cur;
            cur += @intCast(fd.array.len * el.size);
            continue;
        }
        const fl = fieldLayout(fd);
        cur = alignUp(cur, fl.size);
        offsets[i] = cur;
        if (fl.is_ptr) try ptrs.append(gpa, cur);
        cur += fl.size;
    }
    return .{ .size = alignUp(cur, 8), .field_offsets = offsets, .ptr_offsets = try ptrs.toOwnedSlice(gpa) };
}

// ============================================================================
// Env — SSA variable environment (see module doc comment)
// ============================================================================

const Binding = struct { name: []const u8, value: ir.ValueId, ty: TypeId };

const Env = struct {
    bindings: std.ArrayList(Binding) = .empty,

    fn deinit(self: *Env, gpa: Allocator) void {
        self.bindings.deinit(gpa);
    }
    fn mark(self: *const Env) usize {
        return self.bindings.items.len;
    }
    fn declare(self: *Env, gpa: Allocator, name: []const u8, value: ir.ValueId, ty: TypeId) Allocator.Error!void {
        try self.bindings.append(gpa, .{ .name = name, .value = value, .ty = ty });
    }
    fn restoreCount(self: *Env, n: usize) void {
        self.bindings.shrinkRetainingCapacity(n);
    }
    /// Last (innermost) binding matching `name`, or `null` if not in scope.
    fn lookup(self: *const Env, name: []const u8) ?usize {
        var i = self.bindings.items.len;
        while (i > 0) {
            i -= 1;
            if (std.mem.eql(u8, self.bindings.items[i].name, name)) return i;
        }
        return null;
    }
    fn snapshotValues(self: *const Env, gpa: Allocator, upto: usize) Allocator.Error![]ir.ValueId {
        const out = try gpa.alloc(ir.ValueId, upto);
        for (out, 0..) |*o, i| o.* = self.bindings.items[i].value;
        return out;
    }
    /// Restores bindings `[0, vals.len)`'s values to `vals` and discards
    /// anything declared past that — used to reset to a branch point's
    /// starting environment before lowering the next sibling branch.
    fn restoreValues(self: *Env, vals: []const ir.ValueId) void {
        for (vals, 0..) |v, i| self.bindings.items[i].value = v;
        self.bindings.shrinkRetainingCapacity(vals.len);
    }
};

/// One entry per enclosing `break`-able construct. `switch`/`select` are
/// break-able but not `continue`-able (SPEC §13.6): `continue` scans past
/// `.switch_like` frames to the innermost `.loop`. `exit_used` records whether
/// any `break` actually targeted this frame's exit — a switch whose every arm
/// `break`s has a live join even though no arm falls through.
const LoopKind = enum { loop, switch_like };
const LoopCtx = struct {
    exit: ir.BlockId,
    cont: ir.BlockId,
    pre_len: usize,
    kind: LoopKind = .loop,
    exit_used: bool = false,
};

/// A captured outer variable, snapshotted at `arrow_fn` lowering time (see
/// module doc comment on closures).
const Capture = struct { name: []const u8, ty: TypeId, value: ir.ValueId };

const DeferredCall = union(enum) {
    direct: struct { func: ir.FuncId, args: []ir.ValueId, result: TypeId },
    iface: struct { recv: ir.ValueId, method_index: u32, args: []ir.ValueId, result: TypeId },
    value: struct { callee: ir.ValueId, args: []ir.ValueId, result: TypeId },
    /// A deferred builtin (`print`/`assert`): replayed as its `rt_call` on
    /// return. Builtins bypass `resolveCallTarget`, so `lowerDefer` handles
    /// them separately (mirroring `lowerCall`'s builtin dispatch).
    builtin: struct { rt: ir.RtFn, args: []ir.ValueId, result: TypeId },

    fn deinit(self: DeferredCall, gpa: Allocator) void {
        switch (self) {
            inline else => |x| gpa.free(x.args),
        }
    }
};

/// `params` is the callee's declared parameter types (the *explicit* ones, so
/// a `direct_method`'s implicit receiver is excluded). `lowerCall` hints each
/// argument with its parameter type so an untyped literal (`rotr32(x, 4)`)
/// materializes at the parameter's type rather than its own default — see
/// `lowerSpawn` for the same reasoning; without it the inliner fuses a
/// mistyped argument into the callee's body and IR verification rejects it.
/// `params` is the callee's *declared* parameter list. For a variadic callee
/// the final entry is the element type `T`, not the `[]T` the callee actually
/// binds (§10.3) — `variadic` says so, and the call site is responsible for
/// collecting the trailing arguments into one slice before the call.
const CallTarget = union(enum) {
    direct: struct { func: ir.FuncId, result: TypeId, params: []const TypeId, variadic: bool },
    /// A struct method (static dispatch): `recv` is prepended to the user
    /// args as the callee's own leading parameter.
    direct_method: struct { func: ir.FuncId, recv: ir.ValueId, result: TypeId, params: []const TypeId, variadic: bool },
    iface: struct { recv: ir.ValueId, method_index: u32, result: TypeId, params: []const TypeId, variadic: bool },
    value: struct { callee: ir.ValueId, result: TypeId, params: []const TypeId, variadic: bool },

    const Sig = struct { result: TypeId, params: []const TypeId, variadic: bool };

    /// The resolved callee's signature. Every variant already carries it, and it
    /// is the ONLY correct source: the callee expression's own type is the
    /// unbound TEMPLATE for a generic instantiation (`ctx.typeOf(fty)` is
    /// `.invalid` there, so reading it panics) and says nothing at all for a
    /// method or interface callee.
    fn sig(self: CallTarget) Sig {
        return switch (self) {
            inline else => |t| .{ .result = t.result, .params = t.params, .variadic = t.variadic },
        };
    }
};

const MethodEntry = struct { ty: TypeId, name: []const u8, fid: ir.FuncId, result: TypeId, params: []const TypeId, variadic: bool };

// ============================================================================
// Lowerer — module-level driver and shared tables
// ============================================================================

/// One module's resolved+checked front-end outputs, as `lowerProject` consumes
/// them. The `checked`/`rmodule` must be the outputs of `check.checkModule` /
/// `resolve.resolveModule` over the same `files`, and the array index must be
/// the module's `ModuleId` (so cross-module `GlobalSymbol`s index it directly).
pub const ModuleInput = struct {
    files: []const ModuleFile,
    checked: *const check.CheckedModule,
    rmodule: *const resolve.Module,
};

pub const Lowerer = struct {
    gpa: Allocator,
    ctx: *TypeContext,
    /// Every module in the program, indexed by `ModuleId`. Lowering walks all
    /// of them into one `ir.Module`; cross-module calls resolve through the
    /// shared, module-qualified tables in `ctx` and `func_ids`.
    modules: []const ModuleInput,
    /// The module whose function is currently being lowered. `files`/`checked`/
    /// `rmodule` below are cursors into `modules[cur_module]`, re-pointed before
    /// each function so the per-function `FnCtx` code reads the right module
    /// without threading a module id through every call.
    cur_module: ModuleId = @enumFromInt(0),
    /// The build's root module (§17.6). Every lowered function is tagged
    /// `in_root_module = (cur_module == root)` so a freestanding emit can keep
    /// this module's own code and drop its imports'.
    root: ModuleId = @enumFromInt(0),
    files: []const ModuleFile,
    checked: *const check.CheckedModule,
    rmodule: *const resolve.Module,
    out: ir.Module,
    /// Non-generic func_decl `GlobalSymbol.pack()` -> its `ir.FuncId`.
    func_ids: std.AutoHashMapUnmanaged(u64, ir.FuncId) = .{},
    /// Index into `ctx.instantiations` -> its lowered `ir.FuncId`.
    inst_ids: std.AutoHashMapUnmanaged(u32, ir.FuncId) = .{},
    /// Module-level `let` `GlobalSymbol.pack()` -> its `ir.GlobalId` (§11.11).
    /// Filled by `registerGlobals` before any body is lowered, so a reference
    /// from a function declared above the `let` resolves just as well as one
    /// below it.
    global_ids: std.AutoHashMapUnmanaged(u64, ir.GlobalId) = .{},
    /// (struct TypeId, method name) -> declaring func_decl's `GlobalSymbol`.
    /// Linear-scanned (bounded by the program's total method count — see
    /// `lookupMethod`); built once by `buildMethodTable`.
    method_table: std.ArrayList(MethodEntry) = .empty,
    /// Global method-name -> dense id, the interface-dispatch key (ABI.md §2.1).
    /// Structural interfaces match by name, so a name is a sufficient dispatch
    /// key. Assigned on first use, shared across every type and call site.
    method_ids: std.StringHashMapUnmanaged(u32) = .{},
    layouts: std.AutoHashMapUnmanaged(u32, StructLayout) = .{},
    /// Closures are lowered lazily as their `arrow_fn` is encountered, mid-body.
    /// They cannot append straight into `out.funcs` — that would shift the
    /// `FuncId`s Pass A/A2/A3 reserved for the top-level/instantiation/method
    /// functions still being appended. Instead they collect here and get
    /// `FuncId`s past the reserved block (`reserved_count + index`), then are
    /// moved into `out.funcs` once the reserved block is fully appended.
    closure_funcs: std.ArrayList(ir.Function) = .empty,
    reserved_count: usize = 0,

    /// Trampolines synthesized for named functions used as first-class values,
    /// keyed by the function's packed `GlobalSymbol` so repeated references to
    /// the same function share one trampoline (see `funcValueTrampoline`).
    fn_value_tramps: std.AutoHashMapUnmanaged(u64, ir.FuncId) = .{},

    /// §17.6: does the function being lowered right now belong to the root
    /// module? Read straight off the cursor `setModule` maintains, so it is
    /// correct for a closure synthesized mid-body as well as for a top-level
    /// decl — a closure belongs to whichever module's code wrote it.
    fn inRoot(self: *const Lowerer) bool {
        return self.cur_module == self.root;
    }

    /// Appends a synthesized function (closure body or trampoline) to the
    /// pending closure list, tagged with the module that produced it. Every
    /// such function goes through here rather than touching `closure_funcs`
    /// directly, so a new trampoline kind cannot forget the tag.
    fn appendClosure(self: *Lowerer, f: ir.Function) Allocator.Error!void {
        var tagged = f;
        tagged.in_root_module = self.inRoot();
        try self.closure_funcs.append(self.gpa, tagged);
    }

    /// Pass A0: walk every module's top-level `let` declarations (§11.11) and
    /// give each one an `ir.Global` — a name, and the complete static byte
    /// image of its initial value.
    ///
    /// The checker has already proved (`checkModuleState`) that each of these
    /// is a single-name binding of an untraced type with a constant
    /// initializer, so this pass never has to diagnose: anything it cannot
    /// render would have been rejected upstream. Walking the AST rather than
    /// `rmodule.symbols` is deliberate — `let_binding` is also the kind of
    /// every *local* `let`, and only the top-level decl list distinguishes them.
    fn registerGlobals(self: *Lowerer, gpa: Allocator) Error!void {
        for (self.modules, 0..) |mod, mi| {
            for (mod.files, 0..) |mf, file_idx| {
                for (mf.tree.kids(mf.tree.root)) |decl_idx| {
                    if (decl_idx == ast.none) continue;
                    const inner = if (mf.tree.get(decl_idx).tag == .@"export") mf.tree.kids(decl_idx)[0] else decl_idx;
                    if (mf.tree.get(inner).tag != .let_decl) continue;
                    // §11.11: the declaration's storage class, which the parser
                    // recorded in `main` (`.process` for a plain `let`,
                    // `.thread` for `@threadlocal let`). Both classes obey the
                    // identical untraced-type/constant-initializer rules, so the
                    // checker needs no knowledge of the distinction — only the
                    // cell's placement differs, and that is decided right here.
                    const storage: ir.GlobalStorage = switch (@as(ast.GlobalStorage, @enumFromInt(mf.tree.get(inner).main))) {
                        .process => .process,
                        .thread => .thread,
                    };
                    for (mf.tree.kids(inner)) |bind| {
                        const pat = mf.tree.kids(bind)[0];
                        if (mf.tree.get(pat).tag != .ident) continue; // diagnosed by the checker
                        const sid = mod.rmodule.node_symbols[file_idx][pat];
                        if (sid == .none) continue;
                        const init = mod.checked.moduleStateOf(sid) orelse continue; // ditto
                        const ty = mod.checked.typeOf(file_idx, pat);
                        const gsym = GlobalSymbol{ .module = @enumFromInt(mi), .id = sid };
                        const name = try std.fmt.allocPrint(gpa, "__bitg_{d}_{s}", .{ mi, identTextOf(mf, pat) });
                        const bytes = try globalImage(gpa, self.ctx, ty, init);
                        const id = try self.out.addGlobal(name, bytes, module_state_align, storage);
                        try self.global_ids.put(gpa, gsym.pack(), id);
                    }
                }
            }
        }
    }

    /// Re-point the per-module cursors at `m` before lowering one of its
    /// functions, so `FnCtx` (which reads `self.l.files/checked/rmodule`) sees
    /// the right module without a module id threaded through every method.
    fn setModule(self: *Lowerer, m: ModuleId) void {
        self.cur_module = m;
        const mi = self.modules[@intFromEnum(m)];
        self.files = mi.files;
        self.checked = mi.checked;
        self.rmodule = mi.rmodule;
    }

    /// The resolve-level symbol a `GlobalSymbol` names, indexed in *its own*
    /// module's table — correct even when `gsym` is a cross-module reference and
    /// the cursor points elsewhere.
    fn symbolOf(self: *const Lowerer, gsym: GlobalSymbol) resolve.Symbol {
        return self.modules[@intFromEnum(gsym.module)].rmodule.symbols.items[@intFromEnum(gsym.id)];
    }

    /// Follows `import_item` re-export chains to the defining symbol. Bounded: a
    /// longer chain implies an upstream bug, not valid input — `resolve.zig`
    /// already rejects genuine import cycles.
    fn canonicalGlobal(self: *const Lowerer, g: GlobalSymbol) GlobalSymbol {
        var cur = g;
        var guard: u32 = 0;
        while (guard < 64) : (guard += 1) {
            const s = self.symbolOf(cur);
            if (s.kind != .import_item) return cur;
            const t = s.imported_from orelse return cur;
            cur = .{ .module = t.module, .id = t.symbol };
        }
        return cur;
    }

    fn lookupMethod(self: *const Lowerer, ty: TypeId, name: []const u8) ?MethodEntry {
        for (self.method_table.items) |e| {
            if (e.ty == ty and std.mem.eql(u8, e.name, name)) return e;
        }
        return null;
    }

    /// The global dispatch id for a method name, assigning the next dense id on
    /// first use. `name` is source-backed (lives for the whole compile), so it
    /// keys the map directly with no copy.
    fn methodId(self: *Lowerer, name: []const u8) Allocator.Error!u32 {
        const gop = try self.method_ids.getOrPut(self.gpa, name);
        if (!gop.found_existing) gop.value_ptr.* = self.method_ids.count() - 1;
        return gop.value_ptr.*;
    }

    /// Body layout of a boxed aggregate — a struct, or a tuple, which is laid
    /// out by exactly the same rules (ABI.md §1.1). A tuple carries no field
    /// names, so its elements are lifted into anonymous `check.Field`s purely to
    /// reuse `layoutFields`; nothing downstream reads those names.
    fn structLayout(self: *Lowerer, ty: TypeId) Error!StructLayout {
        const key: u32 = @intFromEnum(ty);
        if (self.layouts.get(key)) |l| return l;
        const data = self.ctx.typeOf(ty);
        std.debug.assert(data == .@"struct" or data == .tuple);
        const l = switch (data) {
            .@"struct" => |fields| try layoutFields(self.gpa, self.ctx, fields),
            .tuple => |elems| blk: {
                const fields = try self.gpa.alloc(check.Field, elems.len);
                defer self.gpa.free(fields);
                for (elems, 0..) |e, i| fields[i] = .{ .name = "", .ty = e, .exported = false };
                break :blk try layoutFields(self.gpa, self.ctx, fields);
            },
            else => unreachable,
        };
        try self.layouts.put(self.gpa, key, l);
        return l;
    }

    fn buildGenericEnv(self: *Lowerer, inst: check.Instantiation) Allocator.Error![]GenericBinding {
        const gparams = self.ctx.decl_generics.get(inst.generic.pack()) orelse &[_]GlobalSymbol{};
        const env = try self.gpa.alloc(GenericBinding, gparams.len);
        for (gparams, 0..) |gp, i| env[i] = .{ .sym = gp, .to = inst.args[i] };
        return env;
    }

    /// Lowers one non-generic or already-monomorphized free function body,
    /// resolving its signature from `ctx.func_sigs`. `gen_env` is empty for a
    /// non-generic function. Methods (which have no module symbol or func_sig)
    /// go through `lowerFunctionDecl` directly — see `lowerModule`'s method pass.
    fn lowerFunction(self: *Lowerer, gsym: GlobalSymbol, gen_env: GenericEnv, name: []const u8) Error!ir.Function {
        const sym = self.symbolOf(gsym);
        const template_shape = self.ctx.func_sigs.get(gsym.pack()) orelse return error.UnsupportedConstruct;
        const shape = if (gen_env.len > 0) try self.ctx.substFuncShape(template_shape, gen_env) else template_shape;
        return self.lowerFunctionDecl(sym.file_idx, sym.decl, shape, gen_env, name);
    }

    /// Lowers one function/method body given its resolved `shape` directly, so
    /// it serves both free functions (via `lowerFunction`) and methods (whose
    /// signature comes from the receiver's method set, not `func_sigs`). Binds
    /// the receiver (if the decl has one) as the leading parameter.
    /// §10.3.1: true if the func_decl carries `@want` in its trailing attr_list
    /// (the 7th child, elided for attr-less functions).
    fn funcHasAttr(mf: ModuleFile, decl: ast.Index, want: []const u8) bool {
        const k = mf.tree.kids(decl);
        if (k.len <= 6 or k[6] == ast.none) return false;
        for (mf.tree.kids(k[6])) |a| {
            const ak = mf.tree.kids(a); // [name_ident]
            if (std.mem.eql(u8, identTextOf(mf, ak[0]), want)) return true;
        }
        return false;
    }

    fn lowerFunctionDecl(self: *Lowerer, file_idx: usize, decl: ast.Index, shape: check.FuncShape, gen_env: GenericEnv, name: []const u8) Error!ir.Function {
        const mf = self.files[file_idx];
        const k = mf.tree.kids(decl); // [recv_or_none, name, generics, params, result_or_none, body, attrs_or_none]
        const is_naked = funcHasAttr(mf, decl, "naked");
        const is_nosplit = funcHasAttr(mf, decl, "nosplit");

        var b = ir.FunctionBuilder.init(self.gpa);
        errdefer b.deinit(self.gpa); // freed here only if lowering errors before finish
        const entry = try b.newBlock();
        b.beginBlock(entry);

        var env: Env = .{};
        defer env.deinit(self.gpa);

        var param_types: std.ArrayList(TypeId) = .empty;
        defer param_types.deinit(self.gpa);

        if (k[0] != ast.none) {
            const rk = mf.tree.kids(k[0]);
            const recv_ty_node = rk[1];
            if (mf.tree.get(recv_ty_node).tag != .ident) return error.UnsupportedConstruct;
            const recv_sid = self.rmodule.node_symbols[file_idx][recv_ty_node];
            if (recv_sid == .none) return error.UnsupportedConstruct;
            const recv_struct_ty = self.ctx.decl_memo.get((GlobalSymbol{ .module = self.cur_module, .id = recv_sid }).pack()) orelse
                return error.UnsupportedConstruct;
            try param_types.append(self.gpa, recv_struct_ty);
            const p = try b.addParam(recv_struct_ty);
            try env.declare(self.gpa, identTextOf(mf, rk[0]), p, recv_struct_ty);
        }

        const param_nodes = mf.tree.kids(k[3]);
        if (param_nodes.len != shape.params.len) return error.UnsupportedConstruct; // arity mismatch guard
        for (param_nodes, shape.params) |pn, pty| {
            const pk = mf.tree.kids(pn); // param: [name_ident, type]
            // `shape.params` holds a variadic param's *element* type T, but the
            // body binds it — and the ABI passes it — as `[]T` (§10.3), which
            // is what the checker bound the name to. Lowering the parameter as
            // T instead would declare a scalar the callee then reads a slice
            // header off of.
            const bind_ty = if (mf.tree.get(pn).tag == .param_rest)
                try self.ctx.sliceOf(pty)
            else
                pty;
            try param_types.append(self.gpa, bind_ty);
            const p = try b.addParam(bind_ty);
            try env.declare(self.gpa, identTextOf(mf, pk[0]), p, bind_ty);
        }

        var is_fallible = false;
        var result_ty = shape.result;
        var err_ty: TypeId = .invalid;
        const rdata = self.ctx.typeOf(shape.result);
        if (rdata == .fallible) {
            is_fallible = true;
            result_ty = rdata.fallible.ok;
            err_ty = rdata.fallible.err;
        }

        var fc: FnCtx = .{ .l = self, .gpa = self.gpa, .ctx = self.ctx, .b = &b, .env = &env, .file_idx = file_idx, .gen_env = gen_env, .result_ty = result_ty };
        if (is_fallible) {
            fc.fallible_ok = result_ty;
            fc.fallible_err = err_ty;
        }
        defer fc.deinit();

        try fc.lowerStmtList(k[5]);
        if (!fc.terminated) {
            // A naked fn must end in `return` (checker E0074 rule 2 + E0055 rule
            // 3), so this is unreachable for one — refuse rather than emit a
            // frameless object with no `ret` at all (Power-of-10: assert, don't
            // paper over). Lowering only runs on a clean check, so the invariant
            // holds; the assert guards a future relaxation of the body rule.
            std.debug.assert(!is_naked);
            // Falling off the end of a `()!` function is an ok-void return, so
            // clear the pending error before returning (§18: ok ⇒ slot null).
            try fc.runDefers();
            if (is_fallible) try fc.clearErr();
            try fc.emitRet(&.{});
        }
        b.endBlock();

        var f = try b.finish(name, param_types.items, result_ty, is_fallible, err_ty, entry);
        f.is_naked = is_naked;
        f.is_nosplit = is_nosplit;
        f.in_root_module = self.inRoot();
        return f;
    }

    /// Lowers one `arrow_fn`'s body as its own `ir.Function`, appended
    /// directly to `self.out.funcs` (closures are never forward-referenced
    /// before they exist, so — unlike top-level functions — they need no
    /// pre-reserved `FuncId`). Returns the new function's id.
    fn lowerClosureBody(self: *Lowerer, node: ast.Index, file_idx: usize, shape: check.FuncShape, gen_env: GenericEnv, captures: []const Capture, env_ty: TypeId, env_layout: StructLayout) Error!ir.FuncId {
        const mf = self.files[file_idx];
        const k = mf.tree.kids(node); // [arrow_params, body]

        var b = ir.FunctionBuilder.init(self.gpa);
        errdefer b.deinit(self.gpa); // freed here only if lowering errors before finish
        const entry = try b.newBlock();
        b.beginBlock(entry);

        var env: Env = .{};
        defer env.deinit(self.gpa);

        var param_types: std.ArrayList(TypeId) = .empty;
        defer param_types.deinit(self.gpa);

        // Block params must all precede any non-param instruction, so add the
        // env param + every arrow param first, then unpack captures (fieldGet).
        const env_param = try b.addParam(env_ty);
        try param_types.append(self.gpa, env_ty);

        const param_nodes = mf.tree.kids(k[0]);
        if (param_nodes.len != shape.params.len) return error.UnsupportedConstruct;
        for (param_nodes, shape.params) |pn, pty| {
            const pk = mf.tree.kids(pn); // arrow_p: [name_ident, type_or_none]
            try param_types.append(self.gpa, pty);
            const p = try b.addParam(pty);
            try env.declare(self.gpa, identTextOf(mf, pk[0]), p, pty);
        }

        for (captures, 0..) |c, i| {
            const fv = try b.fieldGet(c.ty, env_param, env_layout.field_offsets[i]);
            try env.declare(self.gpa, c.name, fv, c.ty);
        }

        var fc: FnCtx = .{ .l = self, .gpa = self.gpa, .ctx = self.ctx, .b = &b, .env = &env, .file_idx = file_idx, .gen_env = gen_env, .result_ty = shape.result };
        defer fc.deinit();

        const body = k[1];
        if (mf.tree.get(body).tag == .block) {
            try fc.lowerStmtList(body);
            if (!fc.terminated) {
                try fc.runDefers();
                try fc.emitRet(&.{});
            }
        } else {
            const v = try fc.lowerExpr(body);
            try fc.runDefers();
            try fc.emitRet(&.{v});
        }
        b.endBlock();

        // Past the reserved block so it never aliases a top-level/method FuncId;
        // moved into `out.funcs` after Pass B (see `closure_funcs`).
        const fid: ir.FuncId = @enumFromInt(self.reserved_count + self.closure_funcs.items.len);
        // Unique per-module name so each closure gets a distinct object symbol
        // (`finish` dupes the name, so the temporary is freed right after).
        const name = try std.fmt.allocPrint(self.gpa, "closure${d}", .{@intFromEnum(fid)});
        defer self.gpa.free(name);
        const f = try b.finish(name, param_types.items, shape.result, false, .invalid, entry);
        try self.appendClosure(f);
        return fid;
    }

    /// Synthesizes one `spawn` site's trampoline — the `TaskFn`-shaped function
    /// (`(thunk) -> void`, ABI.md §9) the scheduler actually invokes. It reads
    /// the packed arguments back out of the thunk and calls the spawned target.
    /// Appended to `closure_funcs` like a lowered arrow_fn, so it lands at a
    /// reserved `FuncId` and is emitted as its own object symbol.
    ///
    /// `direct_fn` distinguishes the two target shapes lowerSpawn packs:
    ///   - direct (a named function): call it by id — a top-level function has
    ///     no leading env parameter, so `call_value` (which threads an env)
    ///     would misalign every argument. The thunk holds only the args.
    ///   - closure/value (`direct_fn == null`): the thunk's field 0 is the
    ///     closure; unpack it and `call_value` it.
    /// `fn_ty` types the thunk pointer, `arg_tys` the packed args, `result_ty`
    /// the (discarded) callee result, `layout` the thunk struct lowerSpawn built.
    fn synthSpawnTrampoline(self: *Lowerer, fn_ty: TypeId, direct_fn: ?ir.FuncId, arg_tys: []const TypeId, result_ty: TypeId, layout: StructLayout) Error!ir.FuncId {
        var b = ir.FunctionBuilder.init(self.gpa);
        errdefer b.deinit(self.gpa);
        const entry = try b.newBlock();
        b.beginBlock(entry);

        // Single parameter: the packed-thunk pointer (TaskFn's `arg`). Block
        // params must precede any other instruction, so add it before the loads.
        const thunk = try b.addParam(fn_ty);

        const has_closure = direct_fn == null;
        const closure: ir.ValueId = if (has_closure)
            try b.fieldGet(fn_ty, thunk, layout.field_offsets[0])
        else
            undefined;
        const arg_base: usize = if (has_closure) 1 else 0;

        var call_args: std.ArrayList(ir.ValueId) = .empty;
        defer call_args.deinit(self.gpa);
        for (arg_tys, 0..) |t, ai| {
            try call_args.append(self.gpa, try b.fieldGet(t, thunk, layout.field_offsets[arg_base + ai]));
        }

        // Result is discarded (spawn has no return channel); the produced value
        // is dead and drops out in regalloc.
        if (direct_fn) |fid| {
            _ = try b.call(result_ty, fid, call_args.items);
        } else {
            _ = try b.callValue(result_ty, closure, call_args.items);
        }
        try b.ret(&.{});
        b.endBlock();

        const fid: ir.FuncId = @enumFromInt(self.reserved_count + self.closure_funcs.items.len);
        const name = try std.fmt.allocPrint(self.gpa, "spawn$trampoline${d}", .{@intFromEnum(fid)});
        defer self.gpa.free(name);
        const param_types = [_]TypeId{fn_ty};
        const f = try b.finish(name, &param_types, self.ctx.void_id, false, .invalid, entry);
        try self.appendClosure(f);
        return fid;
    }

    /// The trampoline that adapts a named top-level function to the closure
    /// calling convention, so the function can be used as a first-class value.
    /// `call_value` threads an env as the leading argument, but a named function
    /// has no env parameter (a *method* value reuses its receiver slot for this —
    /// see `lowerMember` — but a plain function has no such slot). The trampoline
    /// takes `(env, params…)`, ignores env, calls the target directly, and
    /// returns its result; a function reference then lowers to
    /// `make_closure(trampoline, nil)`. Cached per target so repeated references
    /// share one trampoline.
    fn funcValueTrampoline(self: *Lowerer, fn_ty: TypeId, gsym: GlobalSymbol, target: ir.FuncId, shape: check.FuncShape) Error!ir.FuncId {
        if (self.fn_value_tramps.get(gsym.pack())) |fid| return fid;

        var b = ir.FunctionBuilder.init(self.gpa);
        errdefer b.deinit(self.gpa);
        const entry = try b.newBlock();
        b.beginBlock(entry);

        var param_types: std.ArrayList(TypeId) = .empty;
        defer param_types.deinit(self.gpa);

        // Block params first: the ignored leading env, then one per target param.
        _ = try b.addParam(fn_ty);
        try param_types.append(self.gpa, fn_ty);
        var call_args: std.ArrayList(ir.ValueId) = .empty;
        defer call_args.deinit(self.gpa);
        for (shape.params) |pty| {
            try param_types.append(self.gpa, pty);
            try call_args.append(self.gpa, try b.addParam(pty));
        }

        const r = try b.call(shape.result, target, call_args.items);
        if (shape.result == self.ctx.void_id) {
            try b.ret(&.{});
        } else {
            try b.ret(&.{r});
        }
        b.endBlock();

        const fid: ir.FuncId = @enumFromInt(self.reserved_count + self.closure_funcs.items.len);
        const name = try std.fmt.allocPrint(self.gpa, "fnvalue$trampoline${d}", .{@intFromEnum(fid)});
        defer self.gpa.free(name);
        const f = try b.finish(name, param_types.items, shape.result, false, .invalid, entry);
        try self.appendClosure(f);
        try self.fn_value_tramps.put(self.gpa, gsym.pack(), fid);
        return fid;
    }

    /// An interface method taken as a *value* (`let f = shape.area`): a closure
    /// whose env is the interface receiver and whose code dispatches dynamically.
    /// Mirrors `funcValueTrampoline`, but the trampoline's first param is the
    /// receiver (used, not ignored) and the body is a `call_iface` on it rather
    /// than a static `call` — so the concrete method is resolved through the
    /// receiver's vtable at each invocation, exactly as an immediate `shape.area()`
    /// would (ABI.md §2.1). `make_closure(tramp, recv)` binds it.
    fn ifaceMethodTrampoline(self: *Lowerer, iface_ty: TypeId, method_index: u32, shape: check.FuncShape) Error!ir.FuncId {
        var b = ir.FunctionBuilder.init(self.gpa);
        errdefer b.deinit(self.gpa);
        const entry = try b.newBlock();
        b.beginBlock(entry);

        var param_types: std.ArrayList(TypeId) = .empty;
        defer param_types.deinit(self.gpa);

        // The env slot carries the interface receiver; it is the dispatch target.
        const recv = try b.addParam(iface_ty);
        try param_types.append(self.gpa, iface_ty);
        var call_args: std.ArrayList(ir.ValueId) = .empty;
        defer call_args.deinit(self.gpa);
        for (shape.params) |pty| {
            try param_types.append(self.gpa, pty);
            try call_args.append(self.gpa, try b.addParam(pty));
        }

        const r = try b.callIface(shape.result, recv, method_index, call_args.items);
        if (shape.result == self.ctx.void_id) {
            try b.ret(&.{});
        } else {
            try b.ret(&.{r});
        }
        b.endBlock();

        const fid: ir.FuncId = @enumFromInt(self.reserved_count + self.closure_funcs.items.len);
        const name = try std.fmt.allocPrint(self.gpa, "ifacemethod$trampoline${d}", .{@intFromEnum(fid)});
        defer self.gpa.free(name);
        const f = try b.finish(name, param_types.items, shape.result, false, .invalid, entry);
        try self.appendClosure(f);
        return fid;
    }
};

/// Lowers one already-resolved, type-checked, single-module program.
/// Single-module convenience wrapper — the front-end's one-module callers and
/// the existing tests keep working unchanged. `files`/`rmodule`/`checked` must
/// be the outputs of `resolve.resolveModule` and `check.checkModule` over the
/// same `files`.
pub fn lowerModule(gpa: Allocator, ctx: *TypeContext, files: []const ModuleFile, checked: *const check.CheckedModule, rmodule: *const resolve.Module) Error!ir.Module {
    return lowerProject(gpa, ctx, &.{.{ .files = files, .checked = checked, .rmodule = rmodule }}, @enumFromInt(0));
}

/// Lowers a whole program — the root module and every module it transitively
/// imports (`modules`, indexed by `ModuleId`) — into one `ir.Module`. Every
/// module's functions get `FuncId`s in a single global space, so a cross-module
/// call is an ordinary direct call; the shared, module-qualified `ctx` tables
/// (`func_sigs`, `instantiations`, `decl_generics`, `decl_memo`) supply every
/// module's signatures. `modules[0]` is the root (its `main` is the entry).
pub fn lowerProject(gpa: Allocator, ctx: *TypeContext, modules: []const ModuleInput, root: ModuleId) Error!ir.Module {
    std.debug.assert(modules.len >= 1);
    std.debug.assert(@intFromEnum(root) < modules.len);
    var l: Lowerer = .{
        .gpa = gpa,
        .ctx = ctx,
        .modules = modules,
        .root = root,
        .files = modules[0].files,
        .checked = modules[0].checked,
        .rmodule = modules[0].rmodule,
        .out = ir.Module.init(gpa, ctx),
    };
    errdefer l.out.deinit();
    defer l.func_ids.deinit(gpa);
    defer l.global_ids.deinit(gpa);
    defer l.fn_value_tramps.deinit(gpa);
    defer l.inst_ids.deinit(gpa);
    defer l.method_table.deinit(gpa);
    defer l.method_ids.deinit(gpa);
    defer {
        var it = l.layouts.valueIterator();
        while (it.next()) |lay| lay.deinit(gpa);
        l.layouts.deinit(gpa);
    }

    // Pass A0: every module-level `let` (§11.11) gets a `GlobalId` and a
    // static byte image, before any function body is lowered.
    try l.registerGlobals(gpa);

    // Pass A: every non-generic func in every module gets a `FuncId` up front
    // (stable module-then-symbol order), so forward/mutually-recursive and
    // cross-module direct calls always resolve. Pass A2: every generic
    // instantiation the checker discovered gets the next block of ids, in
    // `ctx.instantiations` order.
    var direct_syms: std.ArrayList(GlobalSymbol) = .empty;
    defer direct_syms.deinit(gpa);
    for (modules, 0..) |mod, mi| {
        for (mod.rmodule.symbols.items, 0..) |sym, sid| {
            if (sid == 0 or sym.kind != .func or sym.decl == ast.none) continue;
            const gsym = GlobalSymbol{ .module = @enumFromInt(mi), .id = @enumFromInt(sid) };
            if (ctx.decl_generics.get(gsym.pack())) |gens| {
                if (gens.len > 0) continue; // generic template, not directly lowered
            }
            try l.func_ids.put(gpa, gsym.pack(), @enumFromInt(direct_syms.items.len));
            try direct_syms.append(gpa, gsym);
        }
    }
    // Only *function* instantiations become lowered functions. `ctx.instantiations`
    // also holds generic type instantiations (struct/enum/interface), which
    // produce no code — a function template is exactly one with a `func_sigs`
    // entry. Skip the rest here and in Pass B so FuncIds stay dense and aligned;
    // call sites only ever look up function instantiations (via `call_insts`).
    const base = direct_syms.items.len;
    var func_inst_count: u32 = 0;
    for (ctx.instantiations.items, 0..) |inst, i| {
        if (!ctx.func_sigs.contains(inst.generic.pack())) continue;
        try l.inst_ids.put(gpa, @intCast(i), @enumFromInt(base + func_inst_count));
        func_inst_count += 1;
    }

    // Pass A3: methods on concrete structs, across every module. They are not
    // module symbols (§10.4, resolve.zig keeps them out of the flat namespace so
    // different types can reuse a method name), so their signature comes from
    // the receiver's method set and they get `FuncId`s after the instantiations.
    // `l.method_table` maps (receiver type, name) -> that id.
    const MethodDecl = struct { module: ModuleId, file_idx: usize, decl: ast.Index, name: []const u8, ty: TypeId, shape: check.FuncShape };
    var method_decls: std.ArrayList(MethodDecl) = .empty;
    defer method_decls.deinit(gpa);
    const method_base = base + func_inst_count;
    for (modules, 0..) |mod, mi| {
        for (mod.files, 0..) |mf, fidx| {
            for (mf.tree.kids(mf.tree.root)) |top| {
                if (top == ast.none) continue;
                const inner = if (mf.tree.get(top).tag == .@"export") mf.tree.kids(top)[0] else top;
                if (mf.tree.get(inner).tag != .func_decl) continue;
                const k = mf.tree.kids(inner); // [recv, name, generics, params, result, body]
                if (k[0] == ast.none) continue; // free function, handled by Pass A
                const rk = mf.tree.kids(k[0]); // receiver: [name, type_name]
                if (mf.tree.get(rk[1]).tag != .ident) continue; // generic-struct receiver: deferred
                const recv_sid = mod.rmodule.node_symbols[fidx][rk[1]];
                if (recv_sid == .none) continue;
                const recv_gsym = GlobalSymbol{ .module = @enumFromInt(mi), .id = recv_sid };
                if (ctx.decl_generics.get(recv_gsym.pack())) |gens| {
                    if (gens.len > 0) continue; // method on a generic struct: deferred
                }
                const recv_ty = ctx.decl_memo.get(recv_gsym.pack()) orelse continue;
                const name = identTextOf(mf, k[1]);
                const bucket = ctx.methodsOf(recv_ty) orelse continue;
                const method = bucket.get(name) orelse continue;
                const fid: ir.FuncId = @enumFromInt(method_base + method_decls.items.len);
                try l.method_table.append(gpa, .{ .ty = recv_ty, .name = name, .fid = fid, .result = method.result, .params = method.params, .variadic = method.variadic });
                try method_decls.append(gpa, .{ .module = @enumFromInt(mi), .file_idx = fidx, .decl = inner, .name = name, .ty = recv_ty, .shape = .{ .params = method.params, .variadic = method.variadic, .result = method.result } });
            }
        }
    }

    // Per-type method tables (ABI.md §2.1) from Pass A3's (type, name -> fid)
    // entries, one per distinct receiver type, each name assigned its global
    // dispatch id. `call_iface` resolves through these at runtime.
    {
        var tables: std.ArrayList(ir.MethodTable) = .empty;
        errdefer {
            for (tables.items) |t| gpa.free(t.methods);
            tables.deinit(gpa);
        }
        var seen: std.AutoHashMapUnmanaged(u32, void) = .{};
        defer seen.deinit(gpa);
        for (l.method_table.items) |e0| {
            const disc: u32 = @intFromEnum(e0.ty);
            if ((try seen.getOrPut(gpa, disc)).found_existing) continue;
            var methods: std.ArrayList(ir.MethodSlot) = .empty;
            errdefer methods.deinit(gpa);
            for (l.method_table.items) |e| {
                if (@intFromEnum(e.ty) != disc) continue;
                try methods.append(gpa, .{ .id = try l.methodId(e.name), .func = e.fid });
            }
            try tables.append(gpa, .{ .type_disc = disc, .methods = try methods.toOwnedSlice(gpa) });
        }
        l.out.method_tables = try tables.toOwnedSlice(gpa);
    }

    // Closures collected during Pass B are freed here only if lowering errors
    // before they are moved into `out.funcs` (success path clears the list).
    defer {
        for (l.closure_funcs.items) |*cf| cf.deinit(gpa);
        l.closure_funcs.deinit(gpa);
    }

    // Pass B: lower bodies in the exact same order as Pass A/A2/A3 assigned ids,
    // re-pointing the module cursor (`setModule`) before each. Every emitted
    // name is module-qualified for imported modules (`m<id>$`) so two modules'
    // same-named functions never collide at link; module 0 (the root) keeps its
    // bare names so `main` stays `main` and the single-module path is unchanged.
    l.reserved_count = method_base + method_decls.items.len;
    for (direct_syms.items) |gsym| {
        l.setModule(gsym.module);
        const sym = l.rmodule.symbols.items[@intFromEnum(gsym.id)];
        // §11.7: an `extern function` is a declaration. It keeps its FuncId (so
        // `call` resolves normally) but carries the RAW symbol name — module
        // qualification would rename the very symbol we mean to import.
        if (ctx.extern_fns.get(gsym.pack())) |ext_name| {
            const shape = ctx.func_sigs.get(gsym.pack()).?;
            try l.out.funcs.append(gpa, .{
                .name = try gpa.dupe(u8, ext_name),
                .param_types = try gpa.dupe(TypeId, shape.params),
                .result = shape.result,
                .is_fallible = false,
                .is_extern = true,
                // §17.6: tagged like any other function, though the emitters
                // skip an extern declaration on the `is_extern` test first —
                // the tag has to be right regardless of which test wins.
                .in_root_module = gsym.module == root,
                .err_ty = ctx.void_id,
                .blocks = &.{},
                .entry = @enumFromInt(0),
                .insts = .{},
                .extra = &.{},
            });
            continue;
        }
        // §11.9: `@symbol("name")` pins the link-level name. It bypasses module
        // qualification entirely — the `m<id>$` ordinal is assigned by whichever
        // build imports the module, so a qualified name is not stable enough to
        // be the symbol codegen calls a runtime primitive by.
        const pinned: ?[]const u8 = if (ctx.func_attrs.get(gsym.pack())) |fa| fa.symbol else null;
        const nm = if (pinned) |p| try gpa.dupe(u8, p) else try moduleQualified(gpa, gsym.module, root, sym.name);
        defer gpa.free(nm);
        const f = try l.lowerFunction(gsym, &.{}, nm);
        try l.out.funcs.append(gpa, f);
    }
    for (ctx.instantiations.items, 0..) |inst, i| {
        if (!ctx.func_sigs.contains(inst.generic.pack())) continue; // type instantiation: no code
        l.setModule(inst.generic.module);
        const env = try l.buildGenericEnv(inst);
        defer gpa.free(env);
        const sym = l.rmodule.symbols.items[@intFromEnum(inst.generic.id)];
        const nm = if (inst.generic.module == root)
            try std.fmt.allocPrint(gpa, "{s}${d}", .{ sym.name, i })
        else
            try std.fmt.allocPrint(gpa, "m{d}${s}${d}", .{ @intFromEnum(inst.generic.module), sym.name, i });
        defer gpa.free(nm);
        const f = try l.lowerFunction(inst.generic, env, nm);
        try l.out.funcs.append(gpa, f);
    }
    for (method_decls.items) |m| {
        l.setModule(m.module);
        const base_nm = try moduleQualified(gpa, m.module, root, m.name);
        defer gpa.free(base_nm);
        // Disambiguate by receiver type: distinct types may share a method name
        // (`area` on both Circle and Square), yet each needs a unique link symbol.
        // Every reference resolves through the method's FuncId, so the exact
        // spelling is free — it only has to be collision-proof.
        const nm = try std.fmt.allocPrint(gpa, "{s}$t{d}", .{ base_nm, @intFromEnum(m.ty) });
        defer gpa.free(nm);
        const f = try l.lowerFunctionDecl(m.file_idx, m.decl, m.shape, &.{}, nm);
        try l.out.funcs.append(gpa, f);
    }

    // Move closures into `out.funcs` at the FuncIds they were assigned
    // (`reserved_count + index`). Ownership transfers; clear so the defer above
    // does not double-free the now-moved functions.
    try l.out.funcs.appendSlice(gpa, l.closure_funcs.items);
    l.closure_funcs.clearRetainingCapacity();

    return l.out;
}

/// The link-level symbol name for a function `base` declared in `module`. The
/// root module keeps the bare name (so `main` stays `main` and the single-module
/// path is byte-identical); every imported module gets an `m<id>$` prefix so two
/// modules' same-named functions never collide. Always returns an owned copy —
/// `FunctionBuilder.finish` dupes it, so the caller frees this immediately after
/// lowering.
fn moduleQualified(gpa: Allocator, module: ModuleId, root: ModuleId, base: []const u8) Allocator.Error![]u8 {
    if (module == root) return gpa.dupe(u8, base);
    return std.fmt.allocPrint(gpa, "m{d}${s}", .{ @intFromEnum(module), base });
}

// ============================================================================
// FnCtx — per-function lowering (statements and expressions)
// ============================================================================

const FnCtx = struct {
    l: *Lowerer,
    gpa: Allocator,
    ctx: *TypeContext,
    b: *ir.FunctionBuilder,
    env: *Env,
    file_idx: usize,
    gen_env: GenericEnv,
    terminated: bool = false,
    /// Fallible-function context (SPEC §18). `fallible_err == .invalid` iff the
    /// enclosing function is not fallible; otherwise these hold the ok/err
    /// halves of its `T!` result — the ok type for the zero value a `fail`/`?`
    /// propagation returns, the err type for `?`/`catch` null-checks.
    fallible_ok: TypeId = .invalid,
    fallible_err: TypeId = .invalid,
    /// The enclosing function's declared result type, already generic-substituted
    /// and with any `!` unwrapped. `return a, b` boxes against *this* (ABI.md
    /// §1.1) rather than a tuple re-interned from the element expressions: an
    /// element may have widened to its declared type (an untyped literal being
    /// the common case), and the callee's promise is what callers destructure.
    result_ty: TypeId = .invalid,
    loop_stack: std.ArrayList(LoopCtx) = .empty,
    defers: std.ArrayList(DeferredCall) = .empty,

    fn deinit(self: *FnCtx) void {
        self.loop_stack.deinit(self.gpa);
        for (self.defers.items) |d| d.deinit(self.gpa);
        self.defers.deinit(self.gpa);
    }

    fn mf(self: *const FnCtx) ModuleFile {
        return self.l.files[self.file_idx];
    }
    fn tree(self: *const FnCtx) *const ast.Tree {
        return self.mf().tree;
    }
    fn kids(self: *const FnCtx, node: ast.Index) []const ast.Index {
        return self.tree().kids(node);
    }
    fn spanText(self: *const FnCtx, node: ast.Index) []const u8 {
        return identTextOf(self.mf(), node);
    }
    const identText = spanText;

    fn nodeType(self: *const FnCtx, node: ast.Index) Error!TypeId {
        const raw = self.l.checked.typeOf(self.file_idx, node);
        return self.ctx.subst(raw, self.gen_env, 0);
    }

    /// The `GlobalSymbol` an `ident`/type-name node resolved to, following
    /// import re-export chains — across module boundaries: when an `import_item`
    /// points into another module, the walk switches to that module's symbol
    /// table and carries its `ModuleId`, so a cross-module reference resolves to
    /// the defining module's symbol (its `func_id` / `func_sig` key). `null` for
    /// the blank identifier or an already-diagnosed undefined name.
    fn nodeSymbol(self: *const FnCtx, node: ast.Index) ?GlobalSymbol {
        const sid = self.l.rmodule.node_symbols[self.file_idx][node];
        if (sid == .none) return null;
        var mod = self.l.cur_module;
        var cur = sid;
        var guard: u32 = 0;
        while (guard < 64) : (guard += 1) {
            const s = self.l.modules[@intFromEnum(mod)].rmodule.symbols.items[@intFromEnum(cur)];
            if (s.kind != .import_item) break;
            const target = s.imported_from orelse break;
            mod = target.module;
            cur = target.symbol;
        }
        return .{ .module = mod, .id = cur };
    }

    /// The symbol a `member` node names when its receiver is a namespace import
    /// (`strings.toUpper` after `import strings from "std/strings"`): the export
    /// `toUpper` of that module, canonicalized through any re-export. `null` when
    /// the receiver is not a namespace, so ordinary field/method access falls
    /// through. The checker has already rejected an unexported name.
    fn namespaceMember(self: *const FnCtx, member: ast.Index) ?GlobalSymbol {
        const k = self.kids(member); // [recv, name]
        if (self.tree().get(k[0]).tag != .ident) return null;
        const ns = self.nodeSymbol(k[0]) orelse return null;
        const sym = self.l.symbolOf(ns);
        if (sym.kind != .import_namespace) return null;
        const mid = sym.namespace_module orelse return null;
        const exports = &self.l.modules[@intFromEnum(mid)].rmodule.exports;
        const target = exports.get(self.identText(k[1])) orelse return null;
        return self.l.canonicalGlobal(.{ .module = mid, .id = target });
    }

    // ---- block/terminator plumbing -----------------------------------------

    fn emitJump(self: *FnCtx, target: ir.BlockId, args: []const ir.ValueId) Error!void {
        try self.b.jump(target, args);
        self.terminated = true;
    }
    fn emitBr(self: *FnCtx, cond: ir.ValueId, then_blk: ir.BlockId, then_args: []const ir.ValueId, else_blk: ir.BlockId, else_args: []const ir.ValueId) Error!void {
        try self.b.br(cond, then_blk, then_args, else_blk, else_args);
        self.terminated = true;
    }
    fn emitRet(self: *FnCtx, vals: []const ir.ValueId) Error!void {
        try self.b.ret(vals);
        self.terminated = true;
    }
    fn emitUnreachable(self: *FnCtx) Error!void {
        try self.b.unreachableInst();
        self.terminated = true;
    }
    /// Ends the current (already-terminated) block and opens `next`.
    fn switchBlock(self: *FnCtx, next: ir.BlockId) void {
        self.b.endBlock();
        self.b.beginBlock(next);
        self.terminated = false;
    }

    fn zeroValue(self: *FnCtx, ty: TypeId) Error!ir.ValueId {
        const data = self.ctx.typeOf(ty);
        if (data == .prim) {
            return switch (data.prim) {
                .bool => self.b.constBool(ty, false),
                .f32, .f64 => self.b.constFloat(ty, 0),
                .string => blk: {
                    const idx = try self.l.out.internString("");
                    break :blk self.b.constString(ty, idx);
                },
                else => self.b.constInt(ty, 0),
            };
        }
        // A fixed-size array zero-value (`let a: [N]T`) is a fresh inline storage
        // block; `gc_alloc` hands back a zeroed body, so every element reads 0.
        if (data == .array) return self.newArray(ty);
        // A struct zero-value (`let s: S`) is a live, zeroed instance, not `nil`
        // (SPEC §13.4): allocate its body — the zeroed memory gives every scalar
        // field 0, every reference field null, and every inline array field a
        // zeroed block. This is what makes `let s: S; s.w[0] = …` well-defined.
        if (data == .@"struct") {
            const layout = try self.l.structLayout(ty);
            return self.b.gcAlloc(ty, layout.size, layout.ptr_offsets);
        }
        return self.b.constNil(ty);
    }

    // ---- fixed-size arrays (`[N]T`, SPEC §11.2) -----------------------------
    // An array value is a pointer to `N` inline, contiguous scalar elements
    // (the element type is checker-restricted to a scalar value type, so the
    // block holds no GC references). A standalone array is its own `gc_alloc`
    // body; as a struct field it lives inline in the parent's body. Value
    // semantics (deep copy on bind) are realized by cloning at each bind site.

    const ArrayShape = struct { len: u64, elem: TypeId, elem_size: u32, bytes: u32 };

    fn arrayShape(self: *const FnCtx, ty: TypeId) ArrayShape {
        const a = self.ctx.typeOf(ty).array;
        const es = fieldLayout(self.ctx.typeOf(a.elem)).size;
        return .{ .len = a.len, .elem = a.elem, .elem_size = es, .bytes = @intCast(a.len * es) };
    }

    /// A fresh, zeroed inline storage block for an `[N]T` value.
    fn newArray(self: *FnCtx, ty: TypeId) Error!ir.ValueId {
        const sh = self.arrayShape(ty);
        return self.b.gcAlloc(ty, sh.bytes, &.{});
    }

    /// Copy every element of the `[N]T` at `src` into the storage at `dst`
    /// (both are element-base pointers). Unrolled — `N` is a compile-time
    /// constant, and arrays are small; this keeps the copy branch-free with no
    /// extra basic blocks. Elements are scalars, so a plain load+store suffices.
    fn copyArrayElems(self: *FnCtx, dst: ir.ValueId, src: ir.ValueId, sh: ArrayShape) Error!void {
        const i64ty = self.ctx.prim_ids.get(.i64);
        var i: u64 = 0;
        while (i < sh.len) : (i += 1) {
            const idx = try self.b.constInt(i64ty, @intCast(i));
            const e = try self.b.indexGet(sh.elem, src, idx);
            try self.b.indexSet(dst, idx, e);
        }
    }

    /// An independent copy of the `[N]T` value `src`.
    ///
    /// Every source element is read *before* the destination is allocated:
    /// `src` may be an interior pointer into a struct whose last use was the
    /// field access that produced it, and `gc_alloc` is a safepoint — reading
    /// first keeps the loads off the far side of a collection that could free
    /// the parent. The elements are scalars, so holding them across the
    /// allocation is safe (they carry no references the GC must trace).
    fn cloneArray(self: *FnCtx, src: ir.ValueId, ty: TypeId) Error!ir.ValueId {
        const sh = self.arrayShape(ty);
        const i64ty = self.ctx.prim_ids.get(.i64);
        const elems = try self.gpa.alloc(ir.ValueId, @intCast(sh.len));
        defer self.gpa.free(elems);
        for (elems, 0..) |*e, i| {
            const idx = try self.b.constInt(i64ty, @intCast(i));
            e.* = try self.b.indexGet(sh.elem, src, idx);
        }
        const dst = try self.b.gcAlloc(ty, sh.bytes, &.{});
        for (elems, 0..) |e, i| {
            const idx = try self.b.constInt(i64ty, @intCast(i));
            try self.b.indexSet(dst, idx, e);
        }
        return dst;
    }

    /// The value to bind when an `[N]T`-typed expression is captured into a new
    /// location (let/assign to a local, call argument, return). A reference
    /// expression (identifier, field, index) names existing storage, so it must
    /// be cloned to honor value semantics; a fresh producer (array literal,
    /// call result) already owns distinct storage and is bound as-is. Non-array
    /// values pass through untouched.
    fn arrayValueForBind(self: *FnCtx, node: ast.Index, val: ir.ValueId, ty: TypeId) Error!ir.ValueId {
        if (self.ctx.typeOf(ty) != .array) return val;
        return switch (self.tree().get(node).tag) {
            .ident, .member, .index => try self.cloneArray(val, ty),
            else => val,
        };
    }

    /// Lower an array literal `[N]T{ e0, e1, ... }` into a fresh inline block,
    /// storing each (scalar) element in turn.
    fn lowerArrayElems(self: *FnCtx, array_ty: TypeId, items: []const ast.Index) Error!ir.ValueId {
        const sh = self.arrayShape(array_ty);
        const i64ty = self.ctx.prim_ids.get(.i64);
        const dst = try self.b.gcAlloc(array_ty, sh.bytes, &.{});
        for (items, 0..) |a, i| {
            const inner = self.kids(a)[0];
            const v = try self.lowerExprH(inner, sh.elem);
            const idx = try self.b.constInt(i64ty, @intCast(i));
            try self.b.indexSet(dst, idx, v);
        }
        return dst;
    }

    // ---- statements ---------------------------------------------------------

    fn lowerStmtList(self: *FnCtx, node: ast.Index) Error!void {
        for (self.kids(node)) |st| {
            if (self.terminated) break;
            try self.lowerStmt(st);
        }
    }

    fn lowerBlockScoped(self: *FnCtx, node: ast.Index) Error!void {
        const mark = self.env.mark();
        try self.lowerStmtList(node);
        self.env.restoreCount(mark);
    }

    fn lowerStmt(self: *FnCtx, node: ast.Index) Error!void {
        switch (self.tree().get(node).tag) {
            .let_decl, .const_decl => try self.lowerLetConst(node),
            .assign => try self.lowerAssign(node),
            .inc_stmt => try self.lowerIncDec(node, .add),
            .dec_stmt => try self.lowerIncDec(node, .sub),
            .expr_stmt => _ = try self.lowerExpr(self.kids(node)[0]),
            .return_stmt => try self.lowerReturn(node),
            .fail_stmt => try self.lowerFail(node),
            .break_stmt => try self.lowerBreak(),
            .continue_stmt => try self.lowerContinue(),
            .spawn_stmt => try self.lowerSpawn(node),
            .send_stmt => try self.lowerSend(node),
            .defer_stmt => try self.lowerDefer(node),
            .if_stmt => try self.lowerIf(node),
            .while_stmt => try self.lowerWhile(node),
            .for_c => try self.lowerForC(node),
            .for_of => try self.lowerForOf(node),
            .for_inf => try self.lowerForInf(node),
            .switch_stmt => try self.lowerSwitch(node),
            .match_stmt => try self.lowerMatch(node),
            .select_stmt => try self.lowerSelect(node),
            .block => try self.lowerBlockScoped(node),
            else => return error.UnsupportedConstruct, // for_in
        }
    }

    /// Interface widening (§14.3): a concrete value stored into an
    /// interface-typed slot carries the concrete struct as its IR value type
    /// while the slot's declared type is the interface. The two share one
    /// boxed-handle representation, so relabel the value to the interface type —
    /// a no-op cast, not a data change. Without it a control-flow merge
    /// (`if`/`catch`/loop join) creates its block param at the interface type
    /// while the incoming arg keeps the concrete type, and the IR verifier
    /// rejects the block-arg mismatch. The checker has already proven structural
    /// conformance; this only mirrors the interface type onto the lowered value.
    fn coerceToIface(self: *FnCtx, val: ir.ValueId, target: TypeId) Error!ir.ValueId {
        if (self.ctx.typeOf(target) != .interface) return val;
        if (self.b.valueType(val) == target) return val;
        // The relabel is only sound because the incoming value is *already* an
        // object pointer (a struct, another interface, or the null word); a
        // scalar here would put a non-pointer in a word the GC traces as a root
        // (SPEC §14.3). The checker rejects that — hold it.
        std.debug.assert(switch (self.ctx.typeOf(self.b.valueType(val))) {
            .@"struct", .interface, .untyped_nil => true,
            else => false,
        });
        return self.b.convert(target, val);
    }

    /// The address of `ty`'s static `TypeInfo` (ABI.md §2). Typed `u64`, not a
    /// reference: the descriptor is a `.rodata` constant, so a reference type
    /// would hand it to the collector as a root at the next safepoint.
    fn typeInfoOf(self: *FnCtx, ty: TypeId) Error!ir.ValueId {
        const layout = try self.l.structLayout(ty); // checker restricts assertion targets to structs
        return self.b.typeInfoAddr(self.ctx.prim_ids.get(.u64), @intFromEnum(ty), layout.size, layout.ptr_offsets);
    }

    /// Boxes `vals` into a fresh tuple record of type `tup_ty` (ABI.md §1.1).
    /// Same shape as a struct composite literal — `gc_alloc` of the laid-out body
    /// then one store per element — because a tuple *is* a struct without names.
    fn buildTuple(self: *FnCtx, tup_ty: TypeId, vals: []const ir.ValueId) Error!ir.ValueId {
        const layout = try self.l.structLayout(tup_ty);
        const elems = self.ctx.typeOf(tup_ty).tuple;
        std.debug.assert(elems.len == vals.len);
        const obj = try self.b.gcAlloc(tup_ty, layout.size, layout.ptr_offsets);
        for (vals, elems, 0..) |v, ety, i| {
            // An `[N]T` element lives inline in the body (§11.2), so it is
            // copied into place rather than stored as a handle.
            if (self.ctx.typeOf(ety) == .array) {
                const dst = try self.b.fieldGet(ety, obj, layout.field_offsets[i]);
                try self.copyArrayElems(dst, v, self.arrayShape(ety));
            } else {
                try self.b.fieldSet(obj, layout.field_offsets[i], v);
            }
        }
        return obj;
    }

    /// Reads element `idx` out of the boxed tuple `recv` (ABI.md §1.1).
    fn tupleElem(self: *FnCtx, tup_ty: TypeId, recv: ir.ValueId, idx: usize) Error!ir.ValueId {
        const layout = try self.l.structLayout(tup_ty);
        const elems = self.ctx.typeOf(tup_ty).tuple;
        return self.b.fieldGet(elems[idx], recv, layout.field_offsets[idx]);
    }

    /// The two-result forms: `<- c` (SPEC §16.2), `m[k]` (§12.6), `iface.(T)`
    /// (§14.4). Null if `node` is none of them — the caller then has a plain
    /// single-value initializer and a tuple pattern it cannot destructure.
    ///
    /// The chan and interface forms read their `ok` from a runtime call that
    /// reports the *immediately preceding* one (ABI.md §2.2/§11), so each pair is
    /// emitted back to back with nothing in between.
    fn lowerTwoResult(self: *FnCtx, node: ast.Index) Error!?[2]ir.ValueId {
        const n = self.tree().get(node);
        const k = self.kids(node);
        // In every form the node's own type is the *value* type (the checker
        // records the map's value / the channel's element / the assertion's
        // target there), and the second result is always `bool`.
        const val_ty = try self.nodeType(node);
        const ok_ty = self.ctx.prim_ids.get(.bool);
        switch (n.tag) {
            .unary => {
                const op: lexer.Kind = @enumFromInt(n.main);
                if (op != .arrow_left) return null;
                const ch = try self.lowerExpr(k[0]);
                const v = try self.rtCall(val_ty, .chan_recv, &.{ch});
                const ok = try self.rtCall(ok_ty, .chan_recv_ok, &.{});
                return .{ v, ok };
            },
            // A map lookup and its presence test are two independent probes of a
            // table that cannot change between them (no safepoint, no yield), so
            // no `ok` slot is needed — unlike the chan/interface forms.
            .index => {
                const recv_ty = try self.nodeType(k[0]);
                const recv_data = self.ctx.typeOf(recv_ty);
                if (recv_data != .map) return null;
                const m = try self.lowerExpr(k[0]);
                const key = try self.lowerExprH(k[1], recv_data.map.key);
                const v = try self.rtCall(val_ty, .map_get, &.{ m, key });
                const ok = try self.rtCall(ok_ty, .map_has, &.{ m, key });
                return .{ v, ok };
            },
            .type_assert => {
                const recv = try self.lowerExpr(k[0]);
                const info = try self.typeInfoOf(val_ty);
                const v = try self.rtCall(val_ty, .iface_as, &.{ recv, info });
                const ok = try self.rtCall(ok_ty, .iface_as_ok, &.{});
                return .{ v, ok };
            },
            else => return null,
        }
    }

    /// `let (v, ok) = <two-result>` (SPEC.md §12.6/§14.4/§16.2), or the general
    /// `let (a, b, ...) = <tuple>` destructure (§10.1).
    ///
    /// The two-result forms are tried first and only at arity 2: `m[k]` and
    /// `<- c` are *not* tuple-typed, they are a value plus a separate presence
    /// flag, so they can never fall through to the tuple path — and a
    /// tuple-valued expression can never be mistaken for one.
    fn lowerTwoResultLet(self: *FnCtx, bk: []const ast.Index) Error!void {
        const pats = self.kids(bk[0]);
        if (bk[2] == ast.none) return error.UnsupportedConstruct;
        if (pats.len == 2 and allIdents(self.tree(), pats)) {
            if (try self.lowerTwoResult(bk[2])) |two| {
                try self.declareUnlessBlank(pats[0], two[0], try self.nodeType(bk[2]));
                try self.declareUnlessBlank(pats[1], two[1], self.ctx.prim_ids.get(.bool));
                return;
            }
        }
        const tup_ty = try self.nodeType(bk[2]);
        const val = try self.lowerExpr(bk[2]);
        try self.destructureTuple(pats, tup_ty, val);
    }

    /// Binds each of `pats` to the corresponding element of the boxed tuple
    /// `val`, recursing into nested patterns (SPEC.md §10.1 `pat = IDENT | "_" |
    /// tuple_pat`). Arity is checker-enforced; a mismatch here is refused rather
    /// than read past the end of the layout.
    fn destructureTuple(self: *FnCtx, pats: []const ast.Index, tup_ty: TypeId, val: ir.ValueId) Error!void {
        const tdata = self.ctx.typeOf(tup_ty);
        if (tdata != .tuple or tdata.tuple.len != pats.len) return error.UnsupportedConstruct;
        for (pats, tdata.tuple, 0..) |p, ety, i| {
            // `_` discards: skip the load entirely rather than emit a dead one.
            if (self.tree().get(p).tag == .ident and std.mem.eql(u8, self.identText(p), "_")) continue;
            const ev = try self.tupleElem(tup_ty, val, i);
            try self.declareBinder(p, ev, ety);
        }
    }

    /// `(v, ok) = <two-result>` (SPEC.md §12.6/§14.4/§16.2) — as above, but the
    /// two targets are existing lvalues rather than fresh bindings. Both are
    /// resolved before the right-hand side runs, matching plain `=`.
    fn lowerTwoResultAssign(self: *FnCtx, targets: []const ast.Index, init_node: ast.Index) Error!void {
        // Every target is resolved before the right-hand side runs, matching
        // plain `=`, in both the two-result and the tuple case.
        const lvs = try self.gpa.alloc(Lvalue, targets.len);
        defer self.gpa.free(lvs);
        for (targets, 0..) |t, i| lvs[i] = try self.resolveLvalue(t);
        if (targets.len == 2) {
            if (try self.lowerTwoResult(init_node)) |two| {
                for (lvs, two) |lv, v| try self.writeLvalue(lv, v);
                return;
            }
        }
        const tup_ty = try self.nodeType(init_node);
        const tdata = self.ctx.typeOf(tup_ty);
        if (tdata != .tuple or tdata.tuple.len != targets.len) return error.UnsupportedConstruct;
        const val = try self.lowerExpr(init_node);
        for (lvs, 0..) |lv, i| try self.writeLvalue(lv, try self.tupleElem(tup_ty, val, i));
    }

    /// `_` discards its value (SPEC.md §5) — binding it would shadow the next `_`.
    fn declareUnlessBlank(self: *FnCtx, pat: ast.Index, val: ir.ValueId, ty: TypeId) Error!void {
        const name = self.identText(pat);
        if (std.mem.eql(u8, name, "_")) return;
        try self.env.declare(self.gpa, name, val, ty);
    }

    fn lowerLetConst(self: *FnCtx, node: ast.Index) Error!void {
        for (self.kids(node)) |bind| {
            const bk = self.kids(bind); // binding: [pattern, type_or_none, init_or_none]
            if (self.tree().get(bk[0]).tag == .tuple_pat) {
                try self.lowerTwoResultLet(bk);
                continue;
            }
            if (self.tree().get(bk[0]).tag != .ident) return error.UnsupportedConstruct;
            const ty = try self.nodeType(bk[0]);
            const raw = if (bk[2] != ast.none) blk: {
                const r = try self.lowerExprH(bk[2], ty);
                // Value semantics: binding an array from an existing location
                // takes an independent copy (a zero-init or fresh literal
                // already owns its storage).
                break :blk try self.arrayValueForBind(bk[2], r, ty);
            } else try self.zeroValue(ty);
            const val = try self.coerceToIface(raw, ty);
            try self.env.declare(self.gpa, self.identText(bk[0]), val, ty);
        }
    }

    fn resolveLvalue(self: *FnCtx, node: ast.Index) Error!Lvalue {
        switch (self.tree().get(node).tag) {
            .ident => {
                if (self.env.lookup(self.identText(node))) |idx| return .{ .local = idx };
                // Not a local: a module-level `let` (§11.11). Its cell is
                // written through the ordinary `field_set` at offset 0, the
                // same lvalue shape `*p = x` already uses.
                const gsym = self.nodeSymbol(node) orelse return error.UnsupportedConstruct;
                const sym = self.l.symbolOf(gsym);
                if (sym.kind != .let_binding or !sym.module_scoped) return error.UnsupportedConstruct;
                const addr = try self.globalAddrOf(gsym);
                return .{ .field = .{ .recv = addr, .ty = try self.nodeType(node), .offset = 0 } };
            },
            .member => {
                const k = self.kids(node);
                const recv_ty = try self.nodeType(k[0]);
                const data = self.ctx.typeOf(recv_ty);
                if (data != .@"struct") return error.UnsupportedConstruct;
                const name = self.identText(k[1]);
                for (data.@"struct", 0..) |f, i| {
                    if (!std.mem.eql(u8, f.name, name)) continue;
                    const recv_val = try self.lowerExpr(k[0]);
                    const layout = try self.l.structLayout(recv_ty);
                    return .{ .field = .{ .recv = recv_val, .ty = f.ty, .offset = layout.field_offsets[i] } };
                }
                return error.UnsupportedConstruct;
            },
            .index => {
                const k = self.kids(node);
                const recv_ty = try self.nodeType(k[0]);
                const recv_data = self.ctx.typeOf(recv_ty);
                if (recv_data == .map) {
                    const recv_val = try self.lowerExpr(k[0]);
                    const key_val = try self.lowerExprH(k[1], recv_data.map.key);
                    return .{ .map_elem = .{ .recv = recv_val, .key = key_val, .val_ty = recv_data.map.val } };
                }
                const is_slice = recv_data == .slice;
                const recv_val = try self.lowerExpr(k[0]);
                const idx_val = try self.lowerExpr(k[1]);
                const elem_ty = try self.nodeType(node);
                return .{ .elem = .{ .recv = recv_val, .index = idx_val, .ty = elem_ty, .is_slice = is_slice } };
            },
            // `*p = x` (§11.4): store one word at the pointed-at address. The
            // `.field` lvalue at offset 0 already writes via `field_set`.
            .unary => {
                const op: lexer.Kind = @enumFromInt(self.tree().get(node).main);
                if (op != .star) return error.UnsupportedConstruct;
                const p = try self.lowerExpr(self.kids(node)[0]);
                const elem_ty = try self.nodeType(node);
                return .{ .field = .{ .recv = p, .ty = elem_ty, .offset = 0 } };
            },
            else => return error.UnsupportedConstruct,
        }
    }
    /// The integer word type a float of type `ty` crosses the container word
    /// ABI as, or null when `ty` is not a float. `f32` uses `u32` so the
    /// `bitcast` on each side is a 32-bit transfer (`fmov s`/`movd`) — the
    /// stored word is zero-extended, so the round trip is exact.
    fn wordIntTy(self: *FnCtx, ty: TypeId) ?TypeId {
        const d = self.ctx.typeOf(ty);
        if (d == .untyped_float) return self.ctx.prim_ids.get(.u64);
        if (d != .prim) return null;
        return switch (d.prim) {
            .f64 => self.ctx.prim_ids.get(.u64),
            .f32 => self.ctx.prim_ids.get(.u32),
            else => null,
        };
    }

    /// The single lowering entry point for every `rt_call`. The container
    /// primitives declare their element operands and results as an untyped
    /// `u64` word (`ir.rtWordArgs`/`ir.rtReturnsWord`), so a float element must
    /// cross that boundary as its bit pattern, in an integer register. Emitting
    /// the `bitcast`s here — rather than letting codegen classify the operand
    /// by its Bit type — keeps the IR honest about the callee's actual C
    /// signature and fixes every backend at once. A non-word position, and any
    /// non-float type, passes straight through.
    fn rtCall(self: *FnCtx, ty: TypeId, rt: ir.RtFn, args: []const ir.ValueId) Error!ir.ValueId {
        const word_args = ir.rtWordArgs(rt);
        var buf: [8]ir.ValueId = undefined;
        std.debug.assert(args.len <= buf.len);
        var cast_args = args;
        if (word_args != 0) {
            @memcpy(buf[0..args.len], args);
            for (args, 0..) |a, i| {
                if (word_args & (@as(u32, 1) << @intCast(i)) == 0) continue;
                const wt = self.wordIntTy(self.b.valueType(a)) orelse continue;
                buf[i] = try self.b.unary(.bitcast, wt, a);
            }
            cast_args = buf[0..args.len];
        }
        if (ir.rtReturnsWord(rt)) {
            if (self.wordIntTy(ty)) |wt| {
                const word = try self.b.rtCall(wt, rt, cast_args);
                return self.b.unary(.bitcast, ty, word);
            }
        }
        return self.b.rtCall(ty, rt, cast_args);
    }

    fn readLvalue(self: *FnCtx, lv: Lvalue) Error!ir.ValueId {
        return switch (lv) {
            .local => |i| self.env.bindings.items[i].value,
            .field => |f| self.b.fieldGet(f.ty, f.recv, f.offset),
            .elem => |e| if (e.is_slice)
                self.rtCall(e.ty, .slice_get, &.{ e.recv, e.index })
            else
                self.b.indexGet(e.ty, e.recv, e.index),
            .map_elem => |e| self.rtCall(e.val_ty, .map_get, &.{ e.recv, e.key }),
        };
    }
    fn writeLvalue(self: *FnCtx, lv: Lvalue, val: ir.ValueId) Error!void {
        switch (lv) {
            // Reassigning an interface-typed local widens the concrete value to
            // the local's declared interface type so it stays merge-compatible
            // across later joins (see `coerceToIface`).
            .local => |i| self.env.bindings.items[i].value =
                try self.coerceToIface(val, self.env.bindings.items[i].ty),
            // An inline array field is written by copying the source elements
            // into its storage, not by storing a handle.
            .field => |f| if (self.ctx.typeOf(f.ty) == .array) {
                const dst = try self.b.fieldGet(f.ty, f.recv, f.offset);
                try self.copyArrayElems(dst, val, self.arrayShape(f.ty));
            } else try self.b.fieldSet(f.recv, f.offset, val),
            .elem => |e| if (e.is_slice) {
                _ = try self.rtCall(self.ctx.void_id, .slice_set, &.{ e.recv, e.index, val });
            } else try self.b.indexSet(e.recv, e.index, val),
            .map_elem => |e| _ = try self.rtCall(self.ctx.void_id, .map_set, &.{ e.recv, e.key, val }),
        }
    }

    fn lowerAssign(self: *FnCtx, node: ast.Index) Error!void {
        const op: lexer.Kind = @enumFromInt(self.tree().get(node).main);
        const k = self.kids(node); // [lhs_list, rhs_list]
        const lhs_items = self.kids(k[0]);
        const rhs_items = self.kids(k[1]);
        if (op != .eq) {
            std.debug.assert(lhs_items.len == 1 and rhs_items.len == 1);
            const lv = try self.resolveLvalue(lhs_items[0]);
            const cur = try self.readLvalue(lv);
            const ty = try self.nodeType(lhs_items[0]);
            const rhs_val = try self.lowerExprH(rhs_items[0], ty);
            const iop = try binOpFor(compoundBase(op), self.ctx.typeOf(ty));
            const result = try self.b.binary(iop, ty, cur, rhs_val);
            try self.writeLvalue(lv, result);
            return;
        }
        // `(v, ok) = <two-result>` (§12.6/§14.4/§16.2): the parser folds the
        // parenthesized target list into one `tuple_pat`.
        if (lhs_items.len == 1 and rhs_items.len == 1 and self.tree().get(lhs_items[0]).tag == .tuple_pat) {
            try self.lowerTwoResultAssign(self.kids(lhs_items[0]), rhs_items[0]);
            return;
        }
        // The same, unparenthesized (`v, ok = m[k]`). Any *other* 2-target,
        // 1-value assignment is an arity error the checker already rejected.
        if (lhs_items.len == 2 and rhs_items.len == 1) {
            try self.lowerTwoResultAssign(lhs_items, rhs_items[0]);
            return;
        }
        // Plain `=`: resolve every lvalue and evaluate every rhs before any
        // write, so `a, b = b, a` swaps rather than aliasing.
        const lvs = try self.gpa.alloc(Lvalue, lhs_items.len);
        defer self.gpa.free(lvs);
        for (lhs_items, 0..) |ln, i| lvs[i] = try self.resolveLvalue(ln);
        const vals = try self.gpa.alloc(ir.ValueId, rhs_items.len);
        defer self.gpa.free(vals);
        for (rhs_items, 0..) |rn, i| {
            const ty = try self.nodeType(lhs_items[i]);
            const raw = try self.lowerExprH(rn, ty);
            vals[i] = try self.arrayValueForBind(rn, raw, ty);
        }
        std.debug.assert(lvs.len == vals.len);
        for (lvs, vals) |lv, v| try self.writeLvalue(lv, v);
    }

    fn lowerIncDec(self: *FnCtx, node: ast.Index, op: ir.Op) Error!void {
        const lhs = self.kids(node)[0];
        const lv = try self.resolveLvalue(lhs);
        const ty = try self.nodeType(lhs);
        const cur = try self.readLvalue(lv);
        const one = try self.b.constInt(ty, 1);
        const result = try self.b.binary(op, ty, cur, one);
        try self.writeLvalue(lv, result);
    }

    fn declareBinder(self: *FnCtx, node: ast.Index, value: ir.ValueId, ty: TypeId) Error!void {
        // A nested `(a, b)` binder destructures the element it was bound to
        // (SPEC.md §10.1), so a tuple of tuples unpacks in one `let`.
        if (self.tree().get(node).tag == .tuple_pat)
            return self.destructureTuple(self.kids(node), ty, value);
        if (self.tree().get(node).tag != .ident) return error.UnsupportedConstruct;
        try self.declareUnlessBlank(node, value, ty);
    }

    fn lowerReturn(self: *FnCtx, node: ast.Index) Error!void {
        const exprs = self.kids(node);
        const vals = try self.gpa.alloc(ir.ValueId, exprs.len);
        defer self.gpa.free(vals);
        // Value semantics: returning an array from an existing location yields
        // an independent copy, so a caller cannot observe later mutation of a
        // local (and a returned local's storage is never aliased).
        // `return a, b` builds one boxed tuple and returns a single handle
        // (ABI.md §1.1) — a `ret` carries at most one value. Elements are lowered
        // against the *declared* element types, not their own inferred ones: an
        // untyped literal must widen to the element's width before it is stored,
        // and an element declared as an interface needs the same boxing a
        // single-value return would give it.
        if (exprs.len > 1) {
            const tup_ty = self.result_ty;
            const tdata = self.ctx.typeOf(tup_ty);
            // The checker rejects a multi-value return whose arity or element
            // types do not match the declared tuple result, so a mismatch here is
            // a checker bug rather than a program error — refuse instead of
            // emitting a box of the wrong shape.
            if (tdata != .tuple or tdata.tuple.len != exprs.len) return error.UnsupportedConstruct;
            for (exprs, tdata.tuple, 0..) |e, ety, i| {
                const raw = try self.arrayValueForBind(e, try self.lowerExprH(e, ety), ety);
                vals[i] = try self.coerceToIface(raw, ety);
            }
            const boxed = try self.buildTuple(tup_ty, vals);
            try self.runDefers();
            if (self.fallible_err != .invalid) try self.clearErr();
            try self.emitRet(&.{boxed});
            return;
        }
        for (exprs, 0..) |e, i| vals[i] = try self.arrayValueForBind(e, try self.lowerExpr(e), try self.nodeType(e));
        try self.runDefers();
        // A fallible function's ok return must leave the error slot null; clear
        // it after defers (a deferred fallible call may have set it — §11.6).
        if (self.fallible_err != .invalid) try self.clearErr();
        try self.emitRet(vals);
    }

    // ---- fallible-result error channel (SPEC §18) ---------------------------

    /// `err_set(e)` — record the pending error for the caller's `?`/`catch`.
    fn setErr(self: *FnCtx, val: ir.ValueId) Error!void {
        _ = try self.rtCall(self.ctx.void_id, .err_set, &.{val});
    }
    /// `err_set(nil)` — an ok return / handled `catch` clears the slot.
    fn clearErr(self: *FnCtx) Error!void {
        const nil = try self.b.constNil(self.ctx.error_id);
        try self.setErr(nil);
    }
    /// `err_get()` — read the pending error right after a fallible call.
    fn getErr(self: *FnCtx, err_ty: TypeId) Error!ir.ValueId {
        return self.rtCall(err_ty, .err_get, &.{});
    }
    /// Return from a fallible function on the err path: a zero ok value, or no
    /// value at all when the ok type is `void` (`()!`, §18.2).
    fn emitFallibleZeroRet(self: *FnCtx) Error!void {
        if (self.fallible_ok == self.ctx.void_id) return self.emitRet(&.{});
        const zero = try self.zeroValue(self.fallible_ok);
        try self.emitRet(&.{zero});
    }

    /// `fail e` (§18.3): evaluate the error, run defers, then publish it and
    /// return a zero ok value. The error is stored *after* defers so a deferred
    /// fallible call can't clobber it; it is computed *before* so its arguments
    /// see the state at the `fail`, matching Go-style `defer` timing.
    fn lowerFail(self: *FnCtx, node: ast.Index) Error!void {
        const errv = try self.lowerExprH(self.kids(node)[0], self.fallible_err);
        try self.runDefers();
        try self.setErr(errv);
        try self.emitFallibleZeroRet();
    }

    /// `expr?` (§18.3): lower the fallible call (its ok value lands normally),
    /// then branch on the error slot. On error, propagate — run defers, restore
    /// the error (defers may have overwritten the slot), and return zero ok. On
    /// ok, the expression's value is the call's ok result.
    fn lowerTryExpr(self: *FnCtx, node: ast.Index) Error!ir.ValueId {
        const operand = self.kids(node)[0];
        const fdata = self.ctx.typeOf(try self.nodeType(operand)).fallible;
        const okv = try self.lowerExpr(operand);
        const errv = try self.getErr(fdata.err);
        const is_err = try self.neNil(errv, fdata.err);

        const prop = try self.b.newBlock();
        const cont = try self.b.newBlock();
        try self.emitBr(is_err, prop, &.{}, cont, &.{});

        self.switchBlock(prop);
        try self.runDefers();
        try self.setErr(errv);
        try self.emitFallibleZeroRet();

        self.switchBlock(cont);
        return okv; // dominates `cont` (single predecessor), no block param needed
    }

    /// `expr catch default` / `expr catch e { ... }` (§18.3). Merges the ok
    /// value and the handled value at a join block. A `void` ok type carries no
    /// value, so no result param is threaded (the catch is a statement); the ok
    /// value, which dominates the join, stands in as the placeholder result.
    fn lowerCatch(self: *FnCtx, node: ast.Index, bind: bool) Error!ir.ValueId {
        const k = self.kids(node); // default: [expr, dflt]; bind: [expr, err_ident, block]
        const fdata = self.ctx.typeOf(try self.nodeType(k[0])).fallible;
        const is_void = fdata.ok == self.ctx.void_id;
        // Both join edges feed the ok slot (`okv` on success, `handled` on the
        // handled error), typed `fdata.ok`; widen a concrete value to an
        // interface ok type so both agree with the join param (see
        // `coerceToIface`).
        const okv = try self.coerceToIface(try self.lowerExpr(k[0]), fdata.ok);
        const errv = try self.getErr(fdata.err);
        const is_err = try self.neNil(errv, fdata.err);

        const pre_len = self.env.bindings.items.len;
        const orig = try self.env.snapshotValues(self.gpa, pre_len);
        defer self.gpa.free(orig);

        const err_blk = try self.b.newBlock();
        const join = try self.b.newBlock();

        // Each edge threads the unchanged locals, plus the value result unless
        // the ok type is `void` (nothing to merge).
        const ok_args = try self.catchEdgeArgs(orig, okv, is_void);
        defer self.gpa.free(ok_args);
        try self.emitBr(is_err, err_blk, &.{}, join, ok_args);

        self.switchBlock(err_blk);
        try self.clearErr(); // the error is handled here
        var handled: ?ir.ValueId = null;
        if (bind) {
            const mark = self.env.mark();
            try self.env.declare(self.gpa, self.identText(k[1]), errv, fdata.err);
            handled = try self.lowerCatchBlock(k[2], fdata.ok);
            self.env.restoreCount(mark);
        } else {
            handled = try self.lowerExprH(k[1], fdata.ok);
        }
        if (!self.terminated) {
            const err_vals = try self.env.snapshotValues(self.gpa, pre_len);
            defer self.gpa.free(err_vals);
            const merged = try self.coerceToIface(handled.?, fdata.ok);
            const args = try self.catchEdgeArgs(err_vals, merged, is_void);
            defer self.gpa.free(args);
            try self.emitJump(join, args);
        }
        self.env.restoreValues(orig);

        self.b.endBlock();
        self.b.beginBlock(join);
        try self.addLoopParams(pre_len);
        const result = if (is_void) okv else try self.b.addParam(fdata.ok);
        self.terminated = false;
        return result;
    }

    /// Builds a catch join edge's block-args: the threaded locals, plus the
    /// merged value unless the ok type is `void`. Caller owns the returned slice.
    fn catchEdgeArgs(self: *FnCtx, locals: []const ir.ValueId, value: ir.ValueId, is_void: bool) Error![]ir.ValueId {
        const n = locals.len + @intFromBool(!is_void);
        const args = try self.gpa.alloc(ir.ValueId, n);
        @memcpy(args[0..locals.len], locals);
        if (!is_void) args[locals.len] = value;
        return args;
    }

    /// Lowers a `catch e { ... }` block (§18.3): every statement but the last
    /// runs normally; a trailing bare expression is the handled value. Returns
    /// `null` when the block diverts (return/fail/panic/break/continue) — it
    /// then yields no value and must not emit into the terminated block.
    /// Mirrors the checker's `checkCatchBlock`.
    fn lowerCatchBlock(self: *FnCtx, node: ast.Index, ok_ty: TypeId) Error!?ir.ValueId {
        const stmts = self.kids(node);
        const last = stmts[stmts.len - 1];
        for (stmts[0 .. stmts.len - 1]) |s| {
            if (self.terminated) break;
            try self.lowerStmt(s);
        }
        if (self.terminated) return null;
        if (self.tree().get(last).tag == .expr_stmt) {
            return try self.lowerExprH(self.kids(last)[0], ok_ty);
        }
        try self.lowerStmt(last); // diverts (checker-guaranteed if not an expr)
        return null;
    }

    /// `x != nil` as a bool, for the fallible error-slot check.
    fn neNil(self: *FnCtx, val: ir.ValueId, ty: TypeId) Error!ir.ValueId {
        const nil = try self.b.constNil(ty);
        return self.b.binary(.icmp_ne, self.ctx.prim_ids.get(.bool), val, nil);
    }

    fn lowerBreak(self: *FnCtx) Error!void {
        // `break` targets the innermost break-able (loop or switch/select).
        const idx = self.loop_stack.items.len - 1;
        self.loop_stack.items[idx].exit_used = true;
        const top = self.loop_stack.items[idx];
        const vals = try self.env.snapshotValues(self.gpa, top.pre_len);
        defer self.gpa.free(vals);
        try self.emitJump(top.exit, vals);
    }
    fn lowerContinue(self: *FnCtx) Error!void {
        // `continue` targets the innermost loop, stepping past any switch/select
        // frames in between (the checker already rejects `continue` with no
        // enclosing loop, so a `.loop` frame is guaranteed present).
        var i = self.loop_stack.items.len;
        while (i > 0) {
            i -= 1;
            if (self.loop_stack.items[i].kind != .loop) continue;
            const top = self.loop_stack.items[i];
            const vals = try self.env.snapshotValues(self.gpa, top.pre_len);
            defer self.gpa.free(vals);
            try self.emitJump(top.cont, vals);
            return;
        }
        unreachable;
    }

    /// Re-adds the loop header's block params for names `[0, pre_len)`,
    /// rebinding `env` to them — shared by every loop header/exit block.
    fn addLoopParams(self: *FnCtx, pre_len: usize) Error!void {
        for (0..pre_len) |i| {
            const p = try self.b.addParam(self.env.bindings.items[i].ty);
            self.env.bindings.items[i].value = p;
        }
    }

    fn lowerIf(self: *FnCtx, node: ast.Index) Error!void {
        const k = self.kids(node); // [cond, then_block, else_or_none]
        const cond = try self.lowerExpr(k[0]);
        const pre_len = self.env.bindings.items.len;
        const orig = try self.env.snapshotValues(self.gpa, pre_len);
        defer self.gpa.free(orig);

        const then_blk = try self.b.newBlock();
        const join = try self.b.newBlock();
        const else_blk: ?ir.BlockId = if (k[2] != ast.none) try self.b.newBlock() else null;

        try self.emitBr(cond, then_blk, &.{}, else_blk orelse join, if (else_blk == null) orig else &.{});

        self.switchBlock(then_blk);
        try self.lowerBlockScoped(k[1]);
        // With no `else`, the `br`'s else edge targets `join` directly, so it is
        // always a predecessor (carrying `orig`) even when the then-branch
        // terminates — e.g. a guard clause `if (c) { return }`. Only a full
        // if/else where *both* arms terminate leaves `join` unreachable.
        var join_reachable = (else_blk == null);
        if (!self.terminated) {
            join_reachable = true;
            const then_vals = try self.env.snapshotValues(self.gpa, pre_len);
            defer self.gpa.free(then_vals);
            try self.emitJump(join, then_vals);
        }
        self.env.restoreValues(orig);

        if (else_blk) |eb| {
            self.switchBlock(eb);
            if (self.tree().get(k[2]).tag == .if_stmt) {
                try self.lowerIf(k[2]);
            } else {
                try self.lowerBlockScoped(k[2]);
            }
            if (!self.terminated) {
                join_reachable = true;
                const else_vals = try self.env.snapshotValues(self.gpa, pre_len);
                defer self.gpa.free(else_vals);
                try self.emitJump(join, else_vals);
            }
            self.env.restoreValues(orig);
        }

        self.b.endBlock();
        self.b.beginBlock(join);
        if (join_reachable) {
            try self.addLoopParams(pre_len);
            self.terminated = false;
        } else {
            try self.emitUnreachable();
        }
    }

    /// Emits `a == b` as a `bool` value. Strings compare via the runtime
    /// `string_eq`; floats via `fcmp_eq`; everything else (ints, runes, bools,
    /// references) via a word-wise `icmp_eq`.
    fn emitEq(self: *FnCtx, ty: TypeId, a: ir.ValueId, b: ir.ValueId) Error!ir.ValueId {
        const bool_ty = self.ctx.prim_ids.get(.bool);
        const data = self.ctx.typeOf(ty);
        if (data == .prim and data.prim == .string) return self.rtCall(bool_ty, .string_eq, &.{ a, b });
        const is_float = data == .prim and (data.prim == .f32 or data.prim == .f64);
        return self.b.binary(if (is_float) .fcmp_eq else .icmp_eq, bool_ty, a, b);
    }

    /// A `switch` lowers to a linear decision chain, mirroring Go semantics: no
    /// implicit fallthrough (each arm jumps straight to the join), `default`
    /// runs only when no `case` matched regardless of its source position, and
    /// arms `break` to the join. A subject-less `switch { case cond: … }` tests
    /// each `case` expression as a bool directly.
    ///
    /// ponytail: a multi-expression `case a, b:` ORs its comparisons rather than
    /// short-circuiting, so both `a` and `b` are evaluated even when `a`
    /// matches. Case expressions are constants in practice; revisit only if a
    /// side-effecting case expression ever needs Go's left-to-right stop.
    fn lowerSwitch(self: *FnCtx, node: ast.Index) Error!void {
        const k = self.kids(node); // [subject_or_none, case_list]
        const has_subject = k[0] != ast.none;
        const bool_ty = self.ctx.prim_ids.get(.bool);
        const subject_ty: TypeId = if (has_subject) try self.nodeType(k[0]) else bool_ty;
        const subject: ir.ValueId = if (has_subject) try self.lowerExprH(k[0], subject_ty) else undefined;

        const pre_len = self.env.bindings.items.len;
        const orig = try self.env.snapshotValues(self.gpa, pre_len);
        defer self.gpa.free(orig);

        const cases = self.kids(k[1]);
        var default_stmts: ast.Index = ast.none;
        var m: usize = 0; // count of non-default cases
        for (cases) |c| {
            switch (self.tree().get(c).tag) {
                .switch_case => m += 1,
                .switch_default => default_stmts = self.kids(c)[0],
                else => {},
            }
        }

        const join = try self.b.newBlock();
        const dflt = if (m > 0) try self.b.newBlock() else undefined;
        try self.loop_stack.append(self.gpa, .{ .exit = join, .cont = join, .pre_len = pre_len, .kind = .switch_like });
        var join_reachable = false;

        var seen: usize = 0;
        for (cases) |c| {
            if (self.tree().get(c).tag != .switch_case) continue;
            const ck = self.kids(c); // [expr_list, stmt_list]
            const exprs = self.kids(ck[0]);

            var cond = try self.matchExpr(has_subject, subject_ty, subject, exprs[0]);
            for (exprs[1..]) |e| {
                const next_cond = try self.matchExpr(has_subject, subject_ty, subject, e);
                cond = try self.b.binary(.bor, bool_ty, cond, next_cond);
            }

            const body_blk = try self.b.newBlock();
            const is_last = seen == m - 1;
            const next_blk = if (is_last) dflt else try self.b.newBlock();
            try self.emitBr(cond, body_blk, &.{}, next_blk, &.{});

            self.switchBlock(body_blk);
            self.env.restoreValues(orig);
            const mark = self.env.mark();
            try self.lowerStmtList(ck[1]);
            self.env.restoreCount(mark);
            if (!self.terminated) {
                join_reachable = true;
                const vals = try self.env.snapshotValues(self.gpa, pre_len);
                defer self.gpa.free(vals);
                try self.emitJump(join, vals);
            }
            self.env.restoreValues(orig);
            self.switchBlock(next_blk);
            seen += 1;
        }

        // Now positioned in the "no case matched" block (the `dflt` reached via
        // the last test's else edge, or the caller's own block when m == 0).
        self.env.restoreValues(orig);
        if (default_stmts != ast.none) {
            const mark = self.env.mark();
            try self.lowerStmtList(default_stmts);
            self.env.restoreCount(mark);
        }
        if (!self.terminated) {
            join_reachable = true;
            const vals = try self.env.snapshotValues(self.gpa, pre_len);
            defer self.gpa.free(vals);
            try self.emitJump(join, vals);
        }
        self.env.restoreValues(orig);

        const ctx = self.loop_stack.pop().?;
        if (ctx.exit_used) join_reachable = true;

        self.b.endBlock();
        self.b.beginBlock(join);
        if (join_reachable) {
            try self.addLoopParams(pre_len);
            self.terminated = false;
        } else {
            try self.emitUnreachable();
        }
    }

    /// `match (subject) { V => stmt, ... }` (§16.4). The subject lowers to its
    /// tag (a bare i64, Stage 1). Arms test `tag == variantIndex` in order; the
    /// checker guarantees exhaustiveness with no duplicates, so the final arm is
    /// the unconditional else. Env values an arm reassigns are carried to the
    /// join as block params (`addLoopParams`), mirroring `lowerSwitch`. `match`
    /// is not a break target — `break`/`continue` in an arm reach the enclosing
    /// loop via `loop_stack`, so none is pushed here.
    fn lowerMatch(self: *FnCtx, node: ast.Index) Error!void {
        const k = self.kids(node); // [subject, arm_list]
        const subject_ty = try self.nodeType(k[0]);
        const subject = try self.lowerExprH(k[0], subject_ty);
        const ed = self.ctx.typeOf(subject_ty);
        const variants: []const check.Variant = if (ed == .@"enum") ed.@"enum".variants else &.{};
        const boxed = ed == .@"enum" and check.enumBoxed(ed.@"enum");
        const arms = self.kids(k[1]);
        if (arms.len == 0) return; // subject wasn't an enum; checker already diagnosed

        // A boxed enum's value is the object pointer; its tag (an i64) is word
        // 0. A bare enum's value IS the tag (enum-typed). The compare operands
        // must share a type, so tag and each arm's constant use `tag_ty`.
        const i64ty = self.ctx.prim_ids.get(.i64);
        const tag_ty = if (boxed) i64ty else subject_ty;
        const tag = if (boxed) try self.b.fieldGet(tag_ty, subject, 0) else subject;

        const pre_len = self.env.bindings.items.len;
        const orig = try self.env.snapshotValues(self.gpa, pre_len);
        defer self.gpa.free(orig);

        const join = try self.b.newBlock();
        var join_reachable = false;

        // Every arm but the last: `tag == variant` selects the body, else the
        // next test. The last arm is the exhaustive fallthrough.
        for (arms[0 .. arms.len - 1]) |arm| {
            const ak = self.kids(arm); // [variant_pat, body]
            const arm_tag = variantTag(variants, self.identText(self.kids(ak[0])[0]));
            const body_blk = try self.b.newBlock();
            const next_blk = try self.b.newBlock();
            const cond = try self.emitEq(tag_ty, tag, try self.b.constInt(tag_ty, arm_tag));
            try self.emitBr(cond, body_blk, &.{}, next_blk, &.{});
            self.switchBlock(body_blk);
            try self.lowerMatchArm(arm, subject, variants, boxed, orig, pre_len, join, &join_reachable);
            self.switchBlock(next_blk);
        }
        try self.lowerMatchArm(arms[arms.len - 1], subject, variants, boxed, orig, pre_len, join, &join_reachable);

        self.b.endBlock();
        self.b.beginBlock(join);
        if (join_reachable) {
            try self.addLoopParams(pre_len);
            self.terminated = false;
        } else {
            try self.emitUnreachable();
        }
    }

    /// Lowers one match arm in the current block: binds the variant's payload
    /// (`V(a, b) =>` loads word `i` of the box into `a`/`b`), lowers the body,
    /// then carries any reassigned env to `join` (unless the body diverged).
    /// Restores the pre-match env afterward so the next arm starts clean.
    fn lowerMatchArm(self: *FnCtx, arm: ast.Index, subject: ir.ValueId, variants: []const check.Variant, boxed: bool, orig: []const ir.ValueId, pre_len: usize, join: ir.BlockId, join_reachable: *bool) Error!void {
        const ak = self.kids(arm); // [variant_pat, body]
        const vp = self.kids(ak[0]); // variant_pat: [name, binders_or_none]
        self.env.restoreValues(orig);
        const mark = self.env.mark();
        if (boxed and vp[1] != ast.none) {
            const v = findVariant(variants, self.identText(vp[0]));
            // The payload box lives at word 1 of the enum object; word `i` of
            // the box is binder `i`.
            const box = try self.b.fieldGet(self.ctx.prim_ids.get(.i64), subject, 8);
            for (self.kids(vp[1]), 0..) |b, i| {
                const bty = if (v != null and i < v.?.payload.len) v.?.payload[i] else self.ctx.prim_ids.get(.i64);
                const bv = try self.b.fieldGet(bty, box, @intCast(8 * i));
                try self.env.declare(self.gpa, self.identText(b), bv, bty);
            }
        }
        try self.lowerStmt(ak[1]);
        self.env.restoreCount(mark);
        if (!self.terminated) {
            join_reachable.* = true;
            const vals = try self.env.snapshotValues(self.gpa, pre_len);
            defer self.gpa.free(vals);
            try self.emitJump(join, vals);
        }
        self.env.restoreValues(orig);
    }

    /// `match` in expression position (§13.8): like `lowerMatch`, but each arm
    /// lowers its body *expression* to a value and jumps to the join carrying it
    /// as an extra block param (the same value-merge shape `lowerCatch` uses).
    /// The join's trailing param is the whole `match`'s value.
    fn lowerMatchExpr(self: *FnCtx, node: ast.Index) Error!ir.ValueId {
        const k = self.kids(node); // [subject, arm_list]
        const result_ty = try self.nodeType(node); // checkMatchExpr typed the match
        const subject_ty = try self.nodeType(k[0]);
        const subject = try self.lowerExprH(k[0], subject_ty);
        const ed = self.ctx.typeOf(subject_ty);
        const variants: []const check.Variant = if (ed == .@"enum") ed.@"enum".variants else &.{};
        const boxed = ed == .@"enum" and check.enumBoxed(ed.@"enum");
        const arms = self.kids(k[1]);
        const i64ty = self.ctx.prim_ids.get(.i64);
        const is_void = result_ty == self.ctx.void_id or result_ty == .invalid;
        if (arms.len == 0) return self.zeroValue(if (is_void) i64ty else result_ty); // checker already diagnosed

        const tag_ty = if (boxed) i64ty else subject_ty;
        const tag = if (boxed) try self.b.fieldGet(tag_ty, subject, 0) else subject;

        const pre_len = self.env.bindings.items.len;
        const orig = try self.env.snapshotValues(self.gpa, pre_len);
        defer self.gpa.free(orig);

        const join = try self.b.newBlock();
        var join_reachable = false;

        for (arms[0 .. arms.len - 1]) |arm| {
            const ak = self.kids(arm);
            const arm_tag = variantTag(variants, self.identText(self.kids(ak[0])[0]));
            const body_blk = try self.b.newBlock();
            const next_blk = try self.b.newBlock();
            const cond = try self.emitEq(tag_ty, tag, try self.b.constInt(tag_ty, arm_tag));
            try self.emitBr(cond, body_blk, &.{}, next_blk, &.{});
            self.switchBlock(body_blk);
            try self.lowerMatchExprArm(arm, subject, variants, boxed, orig, pre_len, join, result_ty, is_void, &join_reachable);
            self.switchBlock(next_blk);
        }
        try self.lowerMatchExprArm(arms[arms.len - 1], subject, variants, boxed, orig, pre_len, join, result_ty, is_void, &join_reachable);

        self.b.endBlock();
        self.b.beginBlock(join);
        if (!join_reachable) {
            // Every arm diverged (e.g. all `panic`): the match yields no value.
            const ph = try self.zeroValue(if (is_void) i64ty else result_ty);
            try self.emitUnreachable();
            return ph;
        }
        try self.addLoopParams(pre_len);
        const result = if (is_void) try self.b.constInt(i64ty, 0) else try self.b.addParam(result_ty);
        self.terminated = false;
        return result;
    }

    fn lowerMatchExprArm(self: *FnCtx, arm: ast.Index, subject: ir.ValueId, variants: []const check.Variant, boxed: bool, orig: []const ir.ValueId, pre_len: usize, join: ir.BlockId, result_ty: TypeId, is_void: bool, join_reachable: *bool) Error!void {
        const ak = self.kids(arm); // [variant_pat, body]
        const vp = self.kids(ak[0]); // variant_pat: [name, binders_or_none]
        self.env.restoreValues(orig);
        const mark = self.env.mark();
        if (boxed and vp[1] != ast.none) {
            const v = findVariant(variants, self.identText(vp[0]));
            const box = try self.b.fieldGet(self.ctx.prim_ids.get(.i64), subject, 8);
            for (self.kids(vp[1]), 0..) |b, i| {
                const bty = if (v != null and i < v.?.payload.len) v.?.payload[i] else self.ctx.prim_ids.get(.i64);
                const bv = try self.b.fieldGet(bty, box, @intCast(8 * i));
                try self.env.declare(self.gpa, self.identText(b), bv, bty);
            }
        }
        var val: ir.ValueId = undefined;
        // A match-as-expression merges each arm's value at the join, typed
        // `result_ty`; widen a concrete arm value to an interface result so it
        // agrees with the join param (see `coerceToIface`).
        if (is_void) _ = try self.lowerExpr(ak[1]) else val = try self.coerceToIface(try self.lowerExprH(ak[1], result_ty), result_ty);
        self.env.restoreCount(mark);
        if (!self.terminated) {
            join_reachable.* = true;
            const locals = try self.env.snapshotValues(self.gpa, pre_len);
            defer self.gpa.free(locals);
            const args = try self.catchEdgeArgs(locals, val, is_void);
            defer self.gpa.free(args);
            try self.emitJump(join, args);
        }
        self.env.restoreValues(orig);
    }

    /// `EnumName.Variant(args)` — allocate the payload box (word `i` = arg `i`,
    /// GC-tracing its ref fields) and wrap it in the enum object `{tag, box}`.
    fn lowerVariantConstruction(self: *FnCtx, node: ast.Index) Error!ir.ValueId {
        const k = self.kids(node); // [callee(member), type_args, args]
        const enum_ty = try self.nodeType(k[0]); // checkVariantConstruction typed the member as the enum
        const ed = self.ctx.typeOf(enum_ty);
        if (ed != .@"enum") return error.UnsupportedConstruct;
        const vname = self.identText(self.kids(k[0])[1]);
        const v = findVariant(ed.@"enum".variants, vname) orelse return error.UnsupportedConstruct;
        const tag = variantTag(ed.@"enum".variants, vname);
        const arg_nodes = self.kids(k[2]);

        var box: ?ir.ValueId = null;
        if (v.payload.len > 0) {
            var offs: std.ArrayList(u32) = .empty;
            defer offs.deinit(self.gpa);
            for (v.payload, 0..) |pty, i| {
                if (fieldLayout(self.ctx.typeOf(pty)).is_ptr) try offs.append(self.gpa, @intCast(8 * i));
            }
            const b = try self.b.gcAlloc(enum_ty, @intCast(8 * v.payload.len), offs.items);
            for (arg_nodes, 0..) |an, i| {
                if (self.tree().get(an).tag != .arg) return error.UnsupportedConstruct;
                const av = try self.lowerExprH(self.kids(an)[0], v.payload[i]);
                try self.b.fieldSet(b, @intCast(8 * i), av);
            }
            box = b;
        }
        return self.buildEnumObj(enum_ty, tag, box);
    }

    /// Builds a boxed enum object: `{ tag: i64 @0, payloadPtr @8 }` (16 bytes,
    /// the payload pointer at offset 8 is the one GC-traced word; null for a
    /// no-payload variant).
    fn buildEnumObj(self: *FnCtx, enum_ty: TypeId, tag: i64, payload: ?ir.ValueId) Error!ir.ValueId {
        const i64ty = self.ctx.prim_ids.get(.i64);
        const obj = try self.b.gcAlloc(enum_ty, 16, &.{8});
        try self.b.fieldSet(obj, 0, try self.b.constInt(i64ty, tag));
        try self.b.fieldSet(obj, 8, payload orelse try self.b.constInt(i64ty, 0));
        return obj;
    }

    /// The tag (declaration index) of the variant named `name`, or 0 if not
    /// found (the checker already rejected an unknown variant).
    fn variantTag(variants: []const check.Variant, name: []const u8) i64 {
        for (variants, 0..) |v, i| {
            if (std.mem.eql(u8, v.name, name)) return @intCast(i);
        }
        return 0;
    }

    fn findVariant(variants: []const check.Variant, name: []const u8) ?check.Variant {
        for (variants) |v| {
            if (std.mem.eql(u8, v.name, name)) return v;
        }
        return null;
    }

    /// One arm of a `switch`'s decision chain: `subject == e` for a value
    /// switch, or `e` itself (a bool) for a subject-less switch.
    fn matchExpr(self: *FnCtx, has_subject: bool, subject_ty: TypeId, subject: ir.ValueId, e: ast.Index) Error!ir.ValueId {
        if (!has_subject) return self.lowerExprH(e, self.ctx.prim_ids.get(.bool));
        const ev = try self.lowerExprH(e, subject_ty);
        return self.emitEq(subject_ty, subject, ev);
    }

    /// `select` (SPEC §16.3): each comm clause's channel operand (and a send
    /// case's value) is evaluated once, marshaled into a `select_alloc`'d
    /// descriptor buffer, and handed to the runtime `select`, which returns the
    /// fired case index (or `n` for `default`). The result then dispatches on
    /// that index exactly like a value `switch`, binding a recv case's received
    /// word before its body.
    fn lowerSelect(self: *FnCtx, node: ast.Index) Error!void {
        const cases = self.kids(node);
        const i64ty = self.ctx.prim_ids.get(.i64);
        const desc_size: u32 = 32; // sizeof(SelectCaseDesc): {dir, chan, word, ok}

        var n: usize = 0;
        var default_stmts: ast.Index = ast.none;
        for (cases) |c| switch (self.tree().get(c).tag) {
            .comm_case => n += 1,
            .comm_default => default_stmts = self.kids(c)[0],
            else => {},
        };
        const has_default = default_stmts != ast.none;

        // Pass 1: allocate the buffer and evaluate every comm exactly once.
        const nconst = try self.b.constInt(i64ty, @intCast(n));
        const buf = try self.rtCall(i64ty, .select_alloc, &.{nconst});
        {
            var i: usize = 0;
            for (cases) |c| {
                if (self.tree().get(c).tag != .comm_case) continue;
                const comm = self.kids(c)[0];
                const off: u32 = @intCast(i * desc_size);
                if (self.tree().get(comm).tag == .send_stmt) {
                    const sk = self.kids(comm); // [chan, value]
                    const elem_ty = self.ctx.typeOf(try self.nodeType(sk[0])).chan;
                    const ch = try self.lowerExpr(sk[0]);
                    const v = try self.lowerExprH(sk[1], elem_ty);
                    try self.b.fieldSet(buf, off + 0, try self.b.constInt(i64ty, 1)); // dir = send
                    try self.b.fieldSet(buf, off + 8, ch);
                    try self.b.fieldSet(buf, off + 16, v); // word = value to send
                } else { // recv_bind: [binder_or_none, chan]
                    const ch = try self.lowerExpr(self.kids(comm)[1]);
                    try self.b.fieldSet(buf, off + 0, try self.b.constInt(i64ty, 0)); // dir = recv
                    try self.b.fieldSet(buf, off + 8, ch);
                }
                i += 1;
            }
        }
        const hd = try self.b.constInt(i64ty, if (has_default) 1 else 0);
        const fired = try self.rtCall(i64ty, .select, &.{ buf, nconst, hd });

        // Pass 2: dispatch on `fired` (a value switch), binding recv results.
        const pre_len = self.env.bindings.items.len;
        const orig = try self.env.snapshotValues(self.gpa, pre_len);
        defer self.gpa.free(orig);
        const join = try self.b.newBlock();
        const dflt = if (n > 0) try self.b.newBlock() else undefined;
        try self.loop_stack.append(self.gpa, .{ .exit = join, .cont = join, .pre_len = pre_len, .kind = .switch_like });
        var join_reachable = false;

        var i: usize = 0;
        for (cases) |c| {
            if (self.tree().get(c).tag != .comm_case) continue;
            const comm = self.kids(c)[0];
            const body = self.kids(c)[1];
            const off: u32 = @intCast(i * desc_size);
            const cond = try self.emitEq(i64ty, fired, try self.b.constInt(i64ty, @intCast(i)));
            const body_blk = try self.b.newBlock();
            const next_blk = if (i == n - 1) dflt else try self.b.newBlock();
            try self.emitBr(cond, body_blk, &.{}, next_blk, &.{});

            self.switchBlock(body_blk);
            self.env.restoreValues(orig);
            const mark = self.env.mark();
            if (self.tree().get(comm).tag == .recv_bind) {
                const binder = self.kids(comm)[0];
                if (binder != ast.none) {
                    if (self.tree().get(binder).tag != .ident) return error.UnsupportedConstruct; // (v, ok) form: deferred
                    const elem_ty = self.ctx.typeOf(try self.nodeType(self.kids(comm)[1])).chan;
                    const rv = try self.b.fieldGet(elem_ty, buf, off + 16);
                    try self.env.declare(self.gpa, self.identText(binder), rv, elem_ty);
                }
            }
            try self.lowerStmtList(body);
            self.env.restoreCount(mark);
            if (!self.terminated) {
                join_reachable = true;
                const vals = try self.env.snapshotValues(self.gpa, pre_len);
                defer self.gpa.free(vals);
                try self.emitJump(join, vals);
            }
            self.env.restoreValues(orig);
            self.switchBlock(next_blk);
            i += 1;
        }

        // "default fired" block (or the caller's block when there are no cases).
        self.env.restoreValues(orig);
        if (has_default) {
            const mark = self.env.mark();
            try self.lowerStmtList(default_stmts);
            self.env.restoreCount(mark);
        }
        if (!self.terminated) {
            join_reachable = true;
            const vals = try self.env.snapshotValues(self.gpa, pre_len);
            defer self.gpa.free(vals);
            try self.emitJump(join, vals);
        }
        self.env.restoreValues(orig);

        const ctx = self.loop_stack.pop().?;
        if (ctx.exit_used) join_reachable = true;
        self.b.endBlock();
        self.b.beginBlock(join);
        if (join_reachable) {
            try self.addLoopParams(pre_len);
            self.terminated = false;
        } else {
            try self.emitUnreachable();
        }
    }

    fn lowerWhile(self: *FnCtx, node: ast.Index) Error!void {
        const k = self.kids(node); // [cond, body]
        const pre_len = self.env.bindings.items.len;
        const header = try self.b.newBlock();
        const body_blk = try self.b.newBlock();
        const exit_blk = try self.b.newBlock();

        {
            const entry_vals = try self.env.snapshotValues(self.gpa, pre_len);
            defer self.gpa.free(entry_vals);
            try self.emitJump(header, entry_vals);
        }
        self.switchBlock(header);
        try self.addLoopParams(pre_len);

        const cond = try self.lowerExpr(k[0]);
        {
            // `body_blk` has this `br` as its only predecessor and is dominated
            // by `header`, so it takes no params and reads the loop-carried
            // values straight from `header`'s. Only `exit_blk` is a real merge
            // (this edge plus every `break`), so it alone receives args here.
            const cur = try self.env.snapshotValues(self.gpa, pre_len);
            defer self.gpa.free(cur);
            try self.emitBr(cond, body_blk, &.{}, exit_blk, cur);
        }

        try self.loop_stack.append(self.gpa, .{ .exit = exit_blk, .cont = header, .pre_len = pre_len });
        self.switchBlock(body_blk);
        try self.lowerBlockScoped(k[1]);
        if (!self.terminated) {
            const back = try self.env.snapshotValues(self.gpa, pre_len);
            defer self.gpa.free(back);
            try self.emitJump(header, back);
        }
        _ = self.loop_stack.pop();

        self.b.endBlock();
        self.b.beginBlock(exit_blk);
        try self.addLoopParams(pre_len);
        self.terminated = false;
    }

    fn lowerForInf(self: *FnCtx, node: ast.Index) Error!void {
        const body = self.kids(node)[0];
        const pre_len = self.env.bindings.items.len;
        const header = try self.b.newBlock();
        const exit_blk = try self.b.newBlock();

        {
            const entry_vals = try self.env.snapshotValues(self.gpa, pre_len);
            defer self.gpa.free(entry_vals);
            try self.emitJump(header, entry_vals);
        }
        self.switchBlock(header);
        try self.addLoopParams(pre_len);

        try self.loop_stack.append(self.gpa, .{ .exit = exit_blk, .cont = header, .pre_len = pre_len });
        try self.lowerBlockScoped(body);
        _ = self.loop_stack.pop();
        if (!self.terminated) {
            const back = try self.env.snapshotValues(self.gpa, pre_len);
            defer self.gpa.free(back);
            try self.emitJump(header, back);
        }

        self.b.endBlock();
        self.b.beginBlock(exit_blk);
        try self.addLoopParams(pre_len);
        self.terminated = false;
    }

    fn lowerForC(self: *FnCtx, node: ast.Index) Error!void {
        const k = self.kids(node); // [init_or_none, cond_or_none, post_or_none, body]
        const outer_mark = self.env.mark();
        if (k[0] != ast.none) try self.lowerStmt(k[0]);

        const pre_len = self.env.bindings.items.len;
        const header = try self.b.newBlock();
        const body_blk = try self.b.newBlock();
        const post_blk = try self.b.newBlock();
        const exit_blk = try self.b.newBlock();

        {
            const entry_vals = try self.env.snapshotValues(self.gpa, pre_len);
            defer self.gpa.free(entry_vals);
            try self.emitJump(header, entry_vals);
        }
        self.switchBlock(header);
        try self.addLoopParams(pre_len);

        {
            const cur = try self.env.snapshotValues(self.gpa, pre_len);
            defer self.gpa.free(cur);
            // `body_blk` is dominated by `header` and reached only from here,
            // so it takes no params (see `lowerWhile`); `exit_blk` merges this
            // edge with every `break`, so it receives the carried values.
            if (k[1] != ast.none) {
                const cond = try self.lowerExpr(k[1]);
                try self.emitBr(cond, body_blk, &.{}, exit_blk, cur);
            } else {
                try self.emitJump(body_blk, &.{});
            }
        }

        try self.loop_stack.append(self.gpa, .{ .exit = exit_blk, .cont = post_blk, .pre_len = pre_len });
        self.switchBlock(body_blk);
        try self.lowerBlockScoped(k[3]);
        if (!self.terminated) {
            const cur = try self.env.snapshotValues(self.gpa, pre_len);
            defer self.gpa.free(cur);
            try self.emitJump(post_blk, cur);
        }
        _ = self.loop_stack.pop();

        self.switchBlock(post_blk);
        try self.addLoopParams(pre_len);
        if (k[2] != ast.none) try self.lowerStmt(k[2]);
        {
            const back = try self.env.snapshotValues(self.gpa, pre_len);
            defer self.gpa.free(back);
            try self.emitJump(header, back);
        }

        self.b.endBlock();
        self.b.beginBlock(exit_blk);
        try self.addLoopParams(pre_len);
        self.terminated = false;
        self.env.restoreCount(outer_mark);
    }

    fn lowerForOf(self: *FnCtx, node: ast.Index) Error!void {
        const k = self.kids(node); // [binder, iter_expr, body]
        const iter_val = try self.lowerExpr(k[1]);
        const iter_ty = try self.nodeType(k[1]);
        const data = self.ctx.typeOf(iter_ty);
        // A map iterates by slot cursor (`$idx` walks FULL slots via
        // `map_iter_*`, -1 = done), binding each key; a slice/array by a 0..len
        // counter, binding each element.
        const is_map = data == .map;
        const elem_ty = switch (data) {
            .slice => |e| e,
            .array => |a| a.elem,
            .map => |m| m.key,
            else => return error.UnsupportedConstruct,
        };
        const i64ty = self.ctx.prim_ids.get(.i64);
        const outer_mark = self.env.mark();
        // Carry the iterable as a hidden binding so it threads through the loop's
        // block params alongside `$idx`; reading the pre-header `iter_val` inside
        // the body is a stale SSA value once the header rebinds every carried
        // local to a block param.
        try self.env.declare(self.gpa, "$iter", iter_val, iter_ty);
        const start = if (is_map)
            try self.rtCall(i64ty, .map_iter_init, &.{iter_val})
        else
            try self.b.constInt(i64ty, 0);
        try self.env.declare(self.gpa, "$idx", start, i64ty);
        const pre_len = self.env.bindings.items.len;
        const idx_slot = pre_len - 1;
        const iter_slot = pre_len - 2;

        const header = try self.b.newBlock();
        const body_blk = try self.b.newBlock();
        const step_blk = try self.b.newBlock();
        const exit_blk = try self.b.newBlock();

        {
            const entry_vals = try self.env.snapshotValues(self.gpa, pre_len);
            defer self.gpa.free(entry_vals);
            try self.emitJump(header, entry_vals);
        }
        self.switchBlock(header);
        try self.addLoopParams(pre_len);

        const idx_val = self.env.bindings.items[idx_slot].value;
        const iter_cur = self.env.bindings.items[iter_slot].value;
        const bool_ty = self.ctx.prim_ids.get(.bool);
        // Map: continue while the slot cursor is >= 0. Slice/array: while idx < len.
        const cmp = if (is_map)
            try self.b.binary(.icmp_sge, bool_ty, idx_val, try self.b.constInt(i64ty, 0))
        else blk: {
            const len_val = if (data == .array)
                try self.b.constInt(i64ty, @intCast(data.array.len))
            else
                try self.b.sliceLen(i64ty, iter_cur);
            break :blk try self.b.binary(.icmp_slt, bool_ty, idx_val, len_val);
        };
        {
            // `body_blk` is dominated by `header` and reached only here, so it
            // takes no params (see `lowerWhile`); `exit_blk` merges this edge
            // with every `break`, so it receives the carried values.
            const cur = try self.env.snapshotValues(self.gpa, pre_len);
            defer self.gpa.free(cur);
            try self.emitBr(cmp, body_blk, &.{}, exit_blk, cur);
        }

        // `continue` targets `step_blk`, NOT `header`: the cursor advance lives
        // in the step, so jumping straight to the header would re-test the same
        // un-advanced index and spin forever (the #1243 infinite loop). This
        // mirrors `lowerForC`'s post block.
        try self.loop_stack.append(self.gpa, .{ .exit = exit_blk, .cont = step_blk, .pre_len = pre_len });
        self.switchBlock(body_blk);
        const body_mark = self.env.mark();
        if (is_map) {
            // `for (key, value) of m` (checker requires the pair binder). Read
            // both from the current FULL slot; a `_` sub is bound and left unread.
            const m = data.map;
            const subs = self.kids(k[0]); // tuple_pat: [key_binder, val_binder]
            const key_val = try self.rtCall(m.key, .map_key_at, &.{ iter_cur, idx_val });
            const val_val = try self.rtCall(m.val, .map_val_at, &.{ iter_cur, idx_val });
            try self.declareBinder(subs[0], key_val, m.key);
            try self.declareBinder(subs[1], val_val, m.val);
        } else {
            const elem_val = if (data == .slice)
                try self.rtCall(elem_ty, .slice_get, &.{ iter_cur, idx_val })
            else
                try self.b.indexGet(elem_ty, iter_cur, idx_val);
            try self.declareBinder(k[0], elem_val, elem_ty);
        }
        try self.lowerStmtList(k[2]);
        self.env.restoreCount(body_mark);
        _ = self.loop_stack.pop();
        // Normal fall-through joins `continue` at `step_blk`, carrying the
        // still-current (un-advanced) index.
        if (!self.terminated) {
            const cur = try self.env.snapshotValues(self.gpa, pre_len);
            defer self.gpa.free(cur);
            try self.emitJump(step_blk, cur);
        }

        // `step_blk` advances the cursor, then re-tests via the header. Its
        // predecessors (fall-through + every `continue`) pass their own carried
        // values, so read the index/iterator from *this* block's params.
        self.switchBlock(step_blk);
        try self.addLoopParams(pre_len);
        {
            const cur_idx = self.env.bindings.items[idx_slot].value;
            const step_iter = self.env.bindings.items[iter_slot].value;
            const next_idx = if (is_map)
                try self.rtCall(i64ty, .map_iter_next, &.{ step_iter, cur_idx })
            else
                try self.b.binary(.add, i64ty, cur_idx, try self.b.constInt(i64ty, 1));
            self.env.bindings.items[idx_slot].value = next_idx;
            const back = try self.env.snapshotValues(self.gpa, pre_len);
            defer self.gpa.free(back);
            try self.emitJump(header, back);
        }

        self.b.endBlock();
        self.b.beginBlock(exit_blk);
        try self.addLoopParams(pre_len);
        self.terminated = false;
        self.env.restoreCount(outer_mark);
    }

    // ---- calls ----------------------------------------------------------

    fn resolveCallTarget(self: *FnCtx, call_node: ast.Index, callee: ast.Index) Error!CallTarget {
        if (self.l.checked.instantiationOf(self.file_idx, call_node)) |idx| {
            const inst = self.ctx.instantiations.items[idx];
            const shape = self.ctx.typeOf(inst.result).func;
            const fid = self.l.inst_ids.get(idx).?;
            return .{ .direct = .{ .func = fid, .result = shape.result, .params = shape.params, .variadic = shape.variadic } };
        }

        const callee_tag = self.tree().get(callee).tag;
        if (callee_tag == .ident and self.env.lookup(self.identText(callee)) == null) {
            if (self.nodeSymbol(callee)) |gsym| {
                const sym = self.l.symbolOf(gsym);
                if (sym.kind == .func) {
                    const fid = self.l.func_ids.get(gsym.pack()) orelse return error.UnsupportedConstruct;
                    const shape = self.ctx.func_sigs.get(gsym.pack()).?;
                    return .{ .direct = .{ .func = fid, .result = shape.result, .params = shape.params, .variadic = shape.variadic } };
                }
            }
        }

        if (callee_tag == .member) {
            // `strings.toUpper(s)` — a namespace member is a direct cross-module
            // call, not a field or method of a receiver value.
            if (self.namespaceMember(callee)) |gsym| {
                if (self.l.symbolOf(gsym).kind == .func) {
                    const fid = self.l.func_ids.get(gsym.pack()) orelse return error.UnsupportedConstruct;
                    const shape = self.ctx.func_sigs.get(gsym.pack()).?;
                    return .{ .direct = .{ .func = fid, .result = shape.result, .params = shape.params, .variadic = shape.variadic } };
                }
            }
            const k = self.kids(callee); // [recv, name]
            const recv_ty = try self.nodeType(k[0]);
            const name = self.identText(k[1]);
            const data = self.ctx.typeOf(recv_ty);
            if (data == .interface) {
                for (data.interface) |m| {
                    if (!std.mem.eql(u8, m.name, name)) continue;
                    const recv_val = try self.lowerExpr(k[0]);
                    return .{ .iface = .{ .recv = recv_val, .method_index = try self.l.methodId(m.name), .result = m.result, .params = m.params, .variadic = m.variadic } };
                }
                return error.UnsupportedConstruct;
            }
            if (data == .@"struct") {
                for (data.@"struct") |f| {
                    if (!std.mem.eql(u8, f.name, name)) continue;
                    const recv_val = try self.lowerExpr(k[0]);
                    const layout = try self.l.structLayout(recv_ty);
                    var off: u32 = 0;
                    for (data.@"struct", 0..) |ff, i| if (std.mem.eql(u8, ff.name, name)) {
                        off = layout.field_offsets[i];
                    };
                    const fv = try self.b.fieldGet(f.ty, recv_val, off);
                    const fshape = self.ctx.typeOf(f.ty).func;
                    return .{ .value = .{ .callee = fv, .result = fshape.result, .params = fshape.params, .variadic = fshape.variadic } };
                }
                if (self.l.lookupMethod(recv_ty, name)) |entry| {
                    const recv_val = try self.lowerExpr(k[0]);
                    return .{ .direct_method = .{ .func = entry.fid, .recv = recv_val, .result = entry.result, .params = entry.params, .variadic = entry.variadic } };
                }
            }
            return error.UnsupportedConstruct;
        }

        const callee_val = try self.lowerExpr(callee);
        const callee_ty = try self.nodeType(callee);
        const shape = self.ctx.typeOf(callee_ty).func;
        return .{ .value = .{ .callee = callee_val, .result = shape.result, .params = shape.params, .variadic = shape.variadic } };
    }

    /// Lowers a call's argument list, materializing argument `i` at
    /// `param_tys[i]`. A `null` slice — or one shorter than the argument list —
    /// leaves the remaining arguments unhinted, which is only correct where the
    /// parameter type IS the untyped default (`syscall`'s `i64` words).
    ///
    /// The hint is what makes an untyped literal land at the callee's declared
    /// width. Without it `4.5` materializes at its default `f64` and a narrower
    /// parameter reads the wrong half of it — `float32Bits(4.5)` returned the
    /// f64 bit pattern (#1467). Same defect family as #1456/#1457: a literal
    /// lowered with no type hint is silently wrong, never diagnosed.
    fn lowerArgs(self: *FnCtx, args_node: ast.Index, param_tys: ?[]const TypeId) Error![]ir.ValueId {
        const arg_nodes = self.kids(args_node);
        const vals = try self.gpa.alloc(ir.ValueId, arg_nodes.len);
        errdefer self.gpa.free(vals);
        for (arg_nodes, 0..) |an, i| {
            if (self.tree().get(an).tag != .arg) return error.UnsupportedConstruct; // arg_spread: deferred
            const hint: ?TypeId = if (param_tys) |p| (if (i < p.len) p[i] else null) else null;
            vals[i] = try self.lowerExprH(self.kids(an)[0], hint);
        }
        return vals;
    }

    /// The declared parameter types of primitive builtin `name`, as TypeIds, for
    /// `lowerArgs` to hint with. `null` when `name` is not in `check.zig`'s
    /// `prim_sigs` — the caller then lowers unhinted.
    fn primParamTypes(self: *FnCtx, name: []const u8) Error!?[]const TypeId {
        const prims = check.primParams(name) orelse return null;
        const tys = try self.gpa.alloc(TypeId, prims.len);
        for (prims, 0..) |p, i| tys[i] = self.ctx.prim_ids.get(p);
        return tys;
    }

    fn lowerBuiltinCall(self: *FnCtx, node: ast.Index, name: []const u8) Error!ir.ValueId {
        const args_node = self.kids(node)[2];
        const arg_nodes = self.kids(args_node);
        const void_ty = self.ctx.void_id;
        if (std.mem.eql(u8, name, "panic")) {
            const v = try self.lowerExpr(self.kids(arg_nodes[0])[0]);
            // The call result is void and dead (panic never returns); return it
            // as the expression value rather than pushing a `const_nil` *after*
            // the `unreachable` terminator, which would leave a non-terminator
            // as the block's last instruction (endBlock asserts otherwise).
            const r = try self.rtCall(void_ty, .panic, &.{v});
            try self.emitUnreachable();
            return r;
        }
        if (std.mem.eql(u8, name, "print") or std.mem.eql(u8, name, "eprint")) {
            const v = try self.lowerExpr(self.kids(arg_nodes[0])[0]);
            const rt: ir.RtFn = if (std.mem.eql(u8, name, "print")) .print else .eprint;
            return self.rtCall(void_ty, rt, &.{v});
        }
        if (std.mem.eql(u8, name, "assert")) {
            // `assert(cond)` / `assert(cond, msg)`: `bool` and `string`, neither
            // of which an untyped literal defaults away from.
            const vals = try self.lowerArgs(args_node, null);
            defer self.gpa.free(vals);
            // `bit_rt_assert` has one frozen 2-arg signature (ABI.md §12), so the
            // 1-arg source form must still pass a message — otherwise the failing
            // path reads an undefined register as a string pointer.
            if (vals.len == 1) {
                const string_ty = self.ctx.prim_ids.get(.string);
                const idx = try self.l.out.internString("assertion failed");
                const msg = try self.b.constString(string_ty, idx);
                return self.rtCall(void_ty, .assert, &.{ vals[0], msg });
            }
            return self.rtCall(void_ty, .assert, vals);
        }
        if (std.mem.eql(u8, name, "len") or std.mem.eql(u8, name, "cap")) {
            const is_cap = std.mem.eql(u8, name, "cap");
            const arg = self.kids(arg_nodes[0])[0];
            // Default the arg type: `len("literal")` types the string literal as
            // `untyped_string`, which must dispatch like a concrete `string`.
            const arg_ty = self.defaultTy(try self.nodeType(arg));
            const i64ty = self.ctx.prim_ids.get(.i64);
            const data = self.ctx.typeOf(arg_ty);
            if (data == .array) return self.b.constInt(i64ty, @intCast(data.array.len)); // len == cap
            const v = try self.lowerExpr(arg);
            // Slice header is `{buf, len, off, cap, is_ref}`: `len` at +8
            // (`slice_len`, shared with `string`), `cap` at +24. `cap` is
            // slice-only.
            if (data == .slice) return if (is_cap) self.b.fieldGet(i64ty, v, 24) else self.b.sliceLen(i64ty, v);
            if (!is_cap and data == .map) return self.rtCall(i64ty, .map_len, &.{v});
            if (!is_cap and data == .prim and data.prim == .string) return self.b.sliceLen(i64ty, v);
            return error.UnsupportedConstruct;
        }
        if (std.mem.eql(u8, name, "delete")) {
            const mv = try self.lowerExpr(self.kids(arg_nodes[0])[0]);
            const key_ty = self.ctx.typeOf(try self.nodeType(self.kids(arg_nodes[0])[0])).map.key;
            const kv = try self.lowerExprH(self.kids(arg_nodes[1])[0], key_ty);
            return self.rtCall(void_ty, .map_delete, &.{ mv, kv });
        }
        if (std.mem.eql(u8, name, "close")) {
            // SPEC §16.2: `close(c)` marks the channel closed — pending and
            // subsequent receives drain, then yield `(zero, false)`. The checker
            // already proved the operand is a channel.
            const cv = try self.lowerExpr(self.kids(arg_nodes[0])[0]);
            return self.rtCall(void_ty, .chan_close, &.{cv});
        }
        if (atomicRmwOp(name) != null or std.mem.eql(u8, name, "atomicLoad") or
            std.mem.eql(u8, name, "atomicStore") or std.mem.eql(u8, name, "atomicCmpxchg"))
        {
            return self.lowerAtomic(node, name);
        }
        if (std.mem.eql(u8, name, "ptrOf")) return self.lowerPtrOf(node);
        if (std.mem.eql(u8, name, "entryOf")) return self.lowerEntryOf(node);
        // `syscall` (§11.8) is the one builtin with no `bit_rt_*` symbol behind
        // it — the backends emit the kernel trap inline — so it takes its own
        // op and deliberately never reaches `primRtFn` below.
        if (std.mem.eql(u8, name, "syscall")) {
            // Unhinted deliberately: `syscall` is variadic over `i64` words,
            // which is exactly what an untyped int literal already defaults to.
            const vals = try self.lowerArgs(args_node, null);
            defer self.gpa.free(vals);
            const i64ty = self.ctx.prim_ids.get(.i64);
            return self.b.syscall(i64ty, vals[0], vals[1..]);
        }
        if (std.mem.eql(u8, name, "append")) return self.lowerAppend(node);
        // Runtime primitives (fs §14, math §17, time §18, os §19): each maps 1:1
        // to a runtime call whose result the checker already typed. The arity and
        // operand types were enforced there (`check.zig`'s `prim_sigs`), so the
        // args lower generically.
        // Primitives that ARE a machine instruction rather than a runtime
        // call. Checked first, and single-operand by construction, so they
        // never reach `primRtFn`. See `primUnaryOp`.
        if (primUnaryOp(name)) |uop| {
            const ptys = try self.primParamTypes(name);
            defer if (ptys) |p| self.gpa.free(p);
            const vals = try self.lowerArgs(args_node, ptys);
            defer self.gpa.free(vals);
            std.debug.assert(vals.len == 1); // arity fixed by check.zig's `prim_sigs`
            return self.b.unary(uop, try self.nodeType(node), vals[0]);
        }
        if (primRtFn(name)) |rt| {
            const ptys = try self.primParamTypes(name);
            defer if (ptys) |p| self.gpa.free(p);
            const vals = try self.lowerArgs(args_node, ptys);
            defer self.gpa.free(vals);
            return self.rtCall(try self.nodeType(node), rt, vals);
        }
        return error.UnsupportedConstruct; // close: deferred
    }

    /// Name -> inline unary op for the primitives that are one hardware
    /// instruction on every backend. These deliberately do NOT appear in
    /// `prim_rt_fns`: an `rt_call` is a call, and a call is exactly what makes
    /// the corresponding `bit_rt_*` function unimplementable in Bit — its body
    /// would compile to a call to itself (`tests/rootpins.zig`). Being ops also
    /// makes them pure (foldable, dead-code-eliminable) and safepoint-free,
    /// which is what admits them inside `@nosplit` (see `check.zig`).
    ///
    /// `ffloor`/`fceil`/`ftrunc`/`fround` are here too, though they are one
    /// instruction only on AArch64 (`frintm`/`frintp`/`frintz`/`frinta`): the
    /// x86-64 form is `roundsd`, which is SSE4.1, and this backend emits
    /// nothing above SSE2. `x64.zig` expands them into a short SSE2 sequence
    /// rather than raising the baseline of every binary the compiler produces.
    /// An expansion is still not a call — no allocation, no safepoint — so the
    /// property that admits these inside `@nosplit` is unaffected.
    fn primUnaryOp(name: []const u8) ?ir.Op {
        return prim_unary_ops.get(name);
    }

    const prim_unary_ops = std.StaticStringMap(ir.Op).initComptime(.{
        .{ "fsqrt", ir.Op.fsqrt },
        .{ "floatBits", ir.Op.bitcast },
        .{ "float32Bits", ir.Op.bitcast },
        .{ "ffloor", ir.Op.ffloor },
        .{ "fceil", ir.Op.fceil },
        .{ "ftrunc", ir.Op.ftrunc },
        .{ "fround", ir.Op.fround },
    });

    /// Name -> runtime call for the fixed-arity primitive builtins. Mirrors
    /// `check.zig`'s `prim_sigs`, which types them; a primitive missing from
    /// either table is a compile-time-unreachable builtin.
    fn primRtFn(name: []const u8) ?ir.RtFn {
        return prim_rt_fns.get(name);
    }

    const prim_rt_fns = std.StaticStringMap(ir.RtFn).initComptime(.{
        .{ "fsOpen", ir.RtFn.fs_open },
        .{ "fsReadAll", ir.RtFn.fs_read_all },
        .{ "fsWrite", ir.RtFn.fs_write },
        .{ "fsClose", ir.RtFn.fs_close },
        .{ "fsAppend", ir.RtFn.fs_append },
        .{ "fsRead", ir.RtFn.fs_read },
        .{ "fsExists", ir.RtFn.fs_exists },
        .{ "fsIsDir", ir.RtFn.fs_is_dir },
        .{ "fsMkdir", ir.RtFn.fs_mkdir },
        .{ "fsRemove", ir.RtFn.fs_remove },
        .{ "fsListDir", ir.RtFn.fs_list_dir },
        .{ "netListen", ir.RtFn.net_listen },
        .{ "netLocalPort", ir.RtFn.net_local_port },
        .{ "netAccept", ir.RtFn.net_accept },
        .{ "netDial", ir.RtFn.net_dial },
        .{ "netRead", ir.RtFn.net_read },
        .{ "netWrite", ir.RtFn.net_write },
        .{ "netUdpBind", ir.RtFn.net_udp_bind },
        .{ "netUdpSend", ir.RtFn.net_udp_send },
        .{ "netUdpRecv", ir.RtFn.net_udp_recv },
        .{ "netUdpSenderHost", ir.RtFn.net_udp_sender_host },
        .{ "netUdpSenderPort", ir.RtFn.net_udp_sender_port },
        .{ "netResolve", ir.RtFn.net_resolve },
        .{ "fpow", ir.RtFn.pow },
        .{ "fatan2", ir.RtFn.atan2 },
        .{ "flog", ir.RtFn.log },
        .{ "flog2", ir.RtFn.log2 },
        .{ "flog10", ir.RtFn.log10 },
        .{ "timeMonoNs", ir.RtFn.time_mono_ns },
        .{ "timeUnixNs", ir.RtFn.time_unix_ns },
        .{ "timeSleepNs", ir.RtFn.time_sleep_ns },
        .{ "osArgc", ir.RtFn.os_argc },
        .{ "osArgAt", ir.RtFn.os_arg_at },
        .{ "osEnv", ir.RtFn.os_env },
        .{ "osExit", ir.RtFn.os_exit },
        .{ "cryptoRandomBytes", ir.RtFn.random_bytes },
        .{ "cryptoSecureZero", ir.RtFn.secure_zero },
        .{ "parseFloat", ir.RtFn.parse_float },
        .{ "fsChmod", ir.RtFn.fs_chmod },
        .{ "osRun", ir.RtFn.os_run },
        .{ "osRunTest", ir.RtFn.os_run_test },
        .{ "hostTarget", ir.RtFn.host_target },
        .{ "auxv", ir.RtFn.auxv },
    });

    /// `append(s, e1, e2, ...)`: folds each element through `slice_append`,
    /// threading the returned (possibly regrown) header so the caller's
    /// `s = append(s, ...)` observes the new length. The elements are checked
    /// against the slice's element type, so each lowers with that hint.
    fn lowerAppend(self: *FnCtx, node: ast.Index) Error!ir.ValueId {
        const arg_nodes = self.kids(self.kids(node)[2]);
        const slice_ty = try self.nodeType(self.kids(arg_nodes[0])[0]);
        const elem_ty = self.ctx.typeOf(slice_ty).slice;
        var acc = try self.lowerExpr(self.kids(arg_nodes[0])[0]);
        for (arg_nodes[1..]) |an| {
            const v = try self.lowerExprH(self.kids(an)[0], elem_ty);
            acc = try self.rtCall(slice_ty, .slice_append, &.{ acc, v });
        }
        return acc;
    }

    /// `atomicAdd`/`atomicSub`/`atomicAnd`/`atomicOr`/`atomicXchg` -> its IR op,
    /// or `null` for a non-rmw name. Mirrors `check.zig`'s `atomicArity`.
    fn atomicRmwOp(name: []const u8) ?ir.Op {
        if (std.mem.eql(u8, name, "atomicAdd")) return .atomic_rmw_add;
        if (std.mem.eql(u8, name, "atomicSub")) return .atomic_rmw_sub;
        if (std.mem.eql(u8, name, "atomicAnd")) return .atomic_rmw_and;
        if (std.mem.eql(u8, name, "atomicOr")) return .atomic_rmw_or;
        if (std.mem.eql(u8, name, "atomicXchg")) return .atomic_rmw_xchg;
        return null;
    }

    /// `ptrOf(s)` (§11.5): the byte address of `s`'s element 0, as a `*T`. The
    /// slice header is `{buf@0, len@8, off@16, cap@24, is_ref@32}` and each
    /// element occupies one 8-byte word, so element 0 sits at `buf + off*8`
    /// (nonzero `off` only after reslicing). The trailing `convert` retypes the
    /// address word from `i64` to `*T` — both are one int word (is_ref=0).
    fn lowerPtrOf(self: *FnCtx, node: ast.Index) Error!ir.ValueId {
        const arg_nodes = self.kids(self.kids(node)[2]);
        const arg = self.kids(arg_nodes[0])[0];
        // Module-level state (§11.11) has a static address: `global_addr` *is*
        // the answer, with no slice header to walk.
        if (self.tree().get(arg).tag == .ident) {
            if (self.nodeSymbol(arg)) |gsym| {
                const sym = self.l.symbolOf(gsym);
                if (sym.kind == .let_binding and sym.module_scoped) {
                    return self.b.convert(try self.nodeType(node), try self.globalAddrOf(gsym));
                }
            }
        }
        const s = try self.lowerExpr(arg);
        const i64ty = self.ctx.prim_ids.get(.i64);
        const buf = try self.b.fieldGet(i64ty, s, 0);
        const off = try self.b.fieldGet(i64ty, s, 16);
        const eight = try self.b.constInt(i64ty, 8);
        const byteoff = try self.b.binary(.mul, i64ty, off, eight);
        const addr = try self.b.binary(.add, i64ty, buf, byteoff);
        return self.b.convert(try self.nodeType(node), addr);
    }

    /// `entryOf(f)` (§11.10): `f`'s code address as a `*byte`, via the existing
    /// `func_addr` op — the same one `spawn` already uses to hand the runtime a
    /// trampoline, so the relocation and every backend's emission of it are
    /// unchanged and were already exercised on all three targets. This adds a
    /// source-level spelling, not a new mechanism.
    ///
    /// The checker (`checkEntryOf`) has already proved the operand is a direct
    /// reference to a non-generic, non-extern function declaration, so the symbol
    /// lookup here cannot legitimately fail; `UnsupportedConstruct` mirrors
    /// `resolveCallTarget`'s handling of the same impossible case rather than
    /// silently emitting a wrong address.
    fn lowerEntryOf(self: *FnCtx, node: ast.Index) Error!ir.ValueId {
        const arg_nodes = self.kids(self.kids(node)[2]);
        const inner = self.kids(arg_nodes[0])[0];
        const gsym = self.nodeSymbol(inner) orelse return error.UnsupportedConstruct;
        if (self.l.symbolOf(gsym).kind != .func) return error.UnsupportedConstruct;
        const fid = self.l.func_ids.get(gsym.pack()) orelse return error.UnsupportedConstruct;
        return self.b.funcAddr(try self.nodeType(node), fid);
    }

    /// Lowers an atomic builtin (§11.5) to its dedicated inline IR op. The
    /// element type `T` (an integer prim) is read straight off the `*T`
    /// argument's type — the same source `check.zig` validated against — and
    /// every value argument is lowered with `T` as its hint.
    fn lowerAtomic(self: *FnCtx, node: ast.Index, name: []const u8) Error!ir.ValueId {
        const arg_nodes = self.kids(self.kids(node)[2]);
        const ptr_inner = self.kids(arg_nodes[0])[0];
        const ptr = try self.lowerExpr(ptr_inner);
        const elem = self.ctx.typeOf(try self.nodeType(ptr_inner)).ptr;
        if (std.mem.eql(u8, name, "atomicLoad")) return self.b.atomicLoad(elem, ptr);
        if (std.mem.eql(u8, name, "atomicStore")) {
            const v = try self.lowerExprH(self.kids(arg_nodes[1])[0], elem);
            return self.b.atomicStore(ptr, v);
        }
        if (std.mem.eql(u8, name, "atomicCmpxchg")) {
            const old = try self.lowerExprH(self.kids(arg_nodes[1])[0], elem);
            const new = try self.lowerExprH(self.kids(arg_nodes[2])[0], elem);
            return self.b.atomicCmpxchg(self.ctx.prim_ids.get(.bool), ptr, old, new);
        }
        const op = atomicRmwOp(name).?;
        const v = try self.lowerExprH(self.kids(arg_nodes[1])[0], elem);
        return self.b.atomicRmw(op, elem, ptr, v);
    }

    /// `chan<T>()` / `chan<T>(n)`: construct a channel of capacity `n` (0 =
    /// unbuffered). `is_ref` marks whether the element word is a GC reference,
    /// so the runtime treats a buffered element as a root (ABI.md §11).
    fn lowerChanMake(self: *FnCtx, node: ast.Index) Error!ir.ValueId {
        const k = self.kids(node); // [callee, type_args, args]
        const chan_ty = try self.nodeType(node);
        const elem_ty = self.ctx.typeOf(chan_ty).chan;
        const i64ty = self.ctx.prim_ids.get(.i64);
        const arg_nodes = self.kids(k[2]);
        const cap = if (arg_nodes.len >= 1)
            try self.lowerExpr(self.kids(arg_nodes[0])[0])
        else
            try self.b.constInt(i64ty, 0);
        const is_ref = try self.b.constInt(i64ty, if (self.elemIsRef(elem_ty)) 1 else 0);
        return self.rtCall(chan_ty, .chan_make, &.{ cap, is_ref });
    }

    /// `[]T(n)` / `[]T(n, m)`: allocate a length-`n`, capacity-`m` (default `n`)
    /// slice, elements zeroed (SPEC §11). Reuses `slice_new`. A single `string`
    /// argument is instead the conversion `[]byte(s)` (SPEC §12.9), dispatched
    /// to `bytes_from_string` — the checker already accepts only a `[]u8` target
    /// for it.
    fn lowerSliceCtor(self: *FnCtx, node: ast.Index) Error!ir.ValueId {
        const k = self.kids(node); // [callee, type_args, args]
        const slice_ty = try self.nodeType(node);
        const elem_ty = self.ctx.typeOf(slice_ty).slice;
        const i64ty = self.ctx.prim_ids.get(.i64);
        const arg_nodes = self.kids(k[2]);
        if (arg_nodes.len == 1) {
            const arg = self.kids(arg_nodes[0])[0];
            // Default the arg type: a string literal types as `untyped_string`,
            // so `[]byte("hi")` must dispatch like `[]byte(s)` (see the checker's
            // matching note; same defect class as `len("literal")`).
            const at = self.ctx.typeOf(self.defaultTy(try self.nodeType(arg)));
            if (at == .prim and at.prim == .string) {
                const s = try self.lowerExprH(arg, self.ctx.prim_ids.get(.string));
                return self.rtCall(slice_ty, .bytes_from_string, &.{s});
            }
        }
        const len = try self.lowerExprH(self.kids(arg_nodes[0])[0], i64ty);
        const cap = if (arg_nodes.len >= 2) try self.lowerExprH(self.kids(arg_nodes[1])[0], i64ty) else len;
        const is_ref = try self.b.constInt(i64ty, if (self.elemIsRef(elem_ty)) 1 else 0);
        return self.rtCall(slice_ty, .slice_new, &.{ len, cap, is_ref });
    }

    fn lowerCall(self: *FnCtx, node: ast.Index) Error!ir.ValueId {
        const k = self.kids(node); // [callee, type_args_or_none, args]
        const callee = k[0];
        if (self.tree().get(callee).tag == .slice_type) return self.lowerSliceCtor(node);
        if (self.tree().get(callee).tag == .chan_type) return self.lowerChanMake(node);
        if (self.tree().get(callee).tag == .map_type) return self.lowerMapMake(node);
        if (self.tree().get(callee).tag == .ident and self.env.lookup(self.identText(callee)) == null) {
            if (self.nodeSymbol(callee)) |gsym| {
                const sym = self.l.symbolOf(gsym);
                if (sym.kind == .builtin_func) return self.lowerBuiltinCall(node, sym.name);
                // A prim-type name in call position is a conversion `T(x)`
                // (§12.9); struct/interface "construction" uses a composite
                // literal, never a call, so a `builtin_type` here is numeric.
                if (sym.kind == .builtin_type) return self.lowerConvert(node);
            }
        }
        // `EnumName.Variant(args)` / `Enum<Args>.Variant(args)` — construct a
        // payload-carrying variant.
        if (self.tree().get(callee).tag == .member) {
            const mk = self.kids(callee); // [recv, name]
            if (self.isEnumTypeRef(mk[0])) return self.lowerVariantConstruction(node);
        }
        const target = try self.resolveCallTarget(node, callee);
        const params: []const TypeId = switch (target) {
            inline else => |t| t.params,
        };
        const variadic: bool = switch (target) {
            inline else => |t| t.variadic,
        };
        // A variadic callee binds one `[]T`, so only the leading `fixed` params
        // take an argument each; everything after is collected into that slice.
        const fixed = if (variadic) params.len - 1 else params.len;
        const arg_nodes = self.kids(k[2]);
        if (arg_nodes.len < fixed) return error.UnsupportedConstruct; // arity already checked
        var args: std.ArrayList(ir.ValueId) = .empty;
        defer args.deinit(self.gpa);
        if (target == .direct_method) try args.append(self.gpa, target.direct_method.recv);
        // Hint each explicit argument with its parameter type so an untyped
        // literal materializes at the callee's declared type, not its own
        // default (see `CallTarget.params`).
        for (arg_nodes[0..fixed], 0..) |an, i| {
            if (self.tree().get(an).tag != .arg) return error.UnsupportedConstruct;
            const arg_expr = self.kids(an)[0];
            const av = try self.lowerExprH(arg_expr, params[i]);
            // Value semantics: an array argument is passed by copy, so the
            // callee cannot mutate the caller's storage.
            try args.append(self.gpa, try self.arrayValueForBind(arg_expr, av, try self.nodeType(arg_expr)));
        }
        if (variadic) try args.append(self.gpa, try self.lowerVariadicTail(params[params.len - 1], arg_nodes[fixed..]));
        // A fallible callee delivers its ok value in the normal return register
        // (the error rides the runtime slot — §18), so the call instruction's
        // result type is the ok type, never the boxed `T!`.
        return switch (target) {
            .direct => |d| self.b.call(self.okResult(d.result), d.func, args.items),
            .direct_method => |d| self.b.call(self.okResult(d.result), d.func, args.items),
            .iface => |x| self.b.callIface(self.okResult(x.result), x.recv, x.method_index, args.items),
            .value => |x| self.b.callValue(self.okResult(x.result), x.callee, args.items),
        };
    }

    /// Materializes a variadic call's trailing arguments as the single `[]T`
    /// value the callee binds (§10.3): `f(a, b, c)` against `...xs: T` passes
    /// one slice, never three scalars. A final `...s` spread (§12.4) forwards
    /// an existing slice unchanged rather than rebuilding it, which is also
    /// what makes the pass-through form aliasing-free.
    fn lowerVariadicTail(self: *FnCtx, elem_ty: TypeId, items: []const ast.Index) Error!ir.ValueId {
        const slice_ty = try self.ctx.sliceOf(elem_ty);
        if (items.len == 1 and self.tree().get(items[0]).tag == .arg_spread) {
            return self.lowerExprH(self.kids(items[0])[0], slice_ty);
        }
        // The checker restricts `...` to the final argument of a variadic call
        // (E0031 invalid_spread), so a spread anywhere in the collected tail
        // means the tree disagrees with what was checked.
        for (items) |it| if (self.tree().get(it).tag != .arg) return error.UnsupportedConstruct;
        return self.lowerSliceElems(slice_ty, items);
    }

    /// The ok half of a `T!` result, or `ty` unchanged when not fallible.
    fn okResult(self: *const FnCtx, ty: TypeId) TypeId {
        const data = self.ctx.typeOf(ty);
        return if (data == .fallible) data.fallible.ok else ty;
    }

    /// A numeric conversion `T(x)` (§12.9). An untyped-constant operand is
    /// materialized at its natural default type first (so `f64(5)` converts an
    /// i64, `i64(3.9)` converts an f64 — never an int literal typed as float or
    /// vice versa); an identical source type is a no-op; otherwise codegen
    /// performs the trunc/extend/float cast.
    fn lowerConvert(self: *FnCtx, node: ast.Index) Error!ir.ValueId {
        const arg = self.kids(self.kids(self.kids(node)[2])[0])[0]; // args -> arg -> inner
        const dst_ty = try self.nodeType(node);
        const raw_ty = try self.nodeType(arg);
        const src_ty = if (self.isUntypedTy(raw_ty)) self.defaultTy(raw_ty) else raw_ty;
        const src = try self.lowerExprH(arg, src_ty);
        if (src_ty == dst_ty) return src;
        // `string(b)` for a `[]u8` (SPEC §12.9) is a heap conversion, not a
        // numeric cast; the checker restricts the source to a byte slice.
        const dd = self.ctx.typeOf(dst_ty);
        if (dd == .prim and dd.prim == .string and self.ctx.typeOf(src_ty) == .slice) {
            return self.rtCall(dst_ty, .string_from_bytes, &.{src});
        }
        return self.b.convert(dst_ty, src);
    }

    /// `ch <- v`: send one word to a channel (blocks per SPEC §16.2).
    fn lowerSend(self: *FnCtx, node: ast.Index) Error!void {
        const k = self.kids(node); // [chan_expr, value_expr]
        const chan_ty = try self.nodeType(k[0]);
        const elem_ty = self.ctx.typeOf(chan_ty).chan;
        const ch = try self.lowerExpr(k[0]);
        const v = try self.lowerExprH(k[1], elem_ty);
        _ = try self.rtCall(self.ctx.void_id, .chan_send, &.{ ch, v });
    }

    /// `spawn f(args)` (ABI.md §9). `bit_rt_spawn` has a fixed 2-arg shape
    /// `(TaskFn, arg)`, so the spawned call's arguments cannot ride along
    /// natively. Codegen packs them (plus the closure, for a closure target)
    /// into one gc_alloc'd thunk and hands spawn a synthesized trampoline that
    /// unpacks the thunk and calls the target. `fn_ptr`/`arg` are that
    /// trampoline and its thunk, never `f` and its raw arguments.
    fn lowerSpawn(self: *FnCtx, node: ast.Index) Error!void {
        const call_node = self.kids(node)[0];
        const k = self.kids(call_node);
        const target = try self.resolveCallTarget(call_node, k[0]);

        // Two target shapes: a named function is called directly by the
        // trampoline (no env); a closure/fn-value is packed into the thunk and
        // called through `call_value`. Methods and interface values are out of
        // scope (task #1149).
        const direct_fn: ?ir.FuncId = switch (target) {
            .direct => |d| d.func,
            .value => null,
            .direct_method, .iface => return error.UnsupportedConstruct,
        };
        const closure_val: ?ir.ValueId = switch (target) {
            .value => |v| v.callee,
            else => null,
        };

        // Lower each argument with the callee's parameter type as the hint, and
        // type the thunk slot by that same parameter type — not by the argument
        // expression's own type. An untyped literal like `10` has type
        // `untyped_int`; storing it under that type and reloading it in the
        // trampoline would hand the callee an `untyped_int` where it declares
        // `i64`, and IR verification rejects the operand-type mismatch. The
        // parameter type is what the callee actually expects. Evaluate in source
        // order, before allocating the thunk.
        const shape = target.sig();
        // The thunk object's type, and the trampoline's env parameter. Built
        // from the RESOLVED signature rather than from the callee expression's
        // own type: for a generic instantiation the latter is the unbound
        // template, whose `typeOf` is `.invalid` — which is what the emitted IR
        // then carried. Interning the resolved shape reproduces exactly the
        // callee's own type for every non-generic spawn.
        const fty = try self.ctx.funcType(.{ .params = shape.params, .variadic = shape.variadic, .result = shape.result });
        const arg_nodes = self.kids(k[2]);
        // `spawn` packs one thunk slot per declared param, so a variadic callee
        // would need its tail collected first. Refuse explicitly: an arity-only
        // guard lets `spawn f(x)` against `...xs: T` through, and the thunk
        // would then hand the callee a scalar where it binds a `[]T`.
        if (shape.variadic) return error.UnsupportedConstruct; // variadic spawn out of scope
        if (arg_nodes.len != shape.params.len) return error.UnsupportedConstruct;
        var arg_vals: std.ArrayList(ir.ValueId) = .empty;
        defer arg_vals.deinit(self.gpa);
        var arg_tys: std.ArrayList(TypeId) = .empty;
        defer arg_tys.deinit(self.gpa);
        for (arg_nodes, 0..) |an, i| {
            if (self.tree().get(an).tag != .arg) return error.UnsupportedConstruct;
            const pty = shape.params[i];
            try arg_tys.append(self.gpa, pty);
            try arg_vals.append(self.gpa, try self.lowerExprH(self.kids(an)[0], pty));
        }

        // Thunk layout: [closure?] ++ args. `layoutFields` puts every ref field
        // (the closure, plus any ref-typed arg) into `ptr_offsets`, so the thunk
        // traces correctly once task-stack scanning lands (#1106).
        const has_closure = closure_val != null;
        const nfields = @as(usize, if (has_closure) 1 else 0) + arg_tys.items.len;
        const fields = try self.gpa.alloc(check.Field, nfields);
        defer self.gpa.free(fields);
        var fi: usize = 0;
        if (has_closure) {
            fields[0] = .{ .name = "fn", .ty = fty, .exported = false };
            fi = 1;
        }
        for (arg_tys.items) |t| {
            fields[fi] = .{ .name = "a", .ty = t, .exported = false };
            fi += 1;
        }
        var layout = try layoutFields(self.gpa, self.ctx, fields);
        defer layout.deinit(self.gpa);

        // Allocate and populate the thunk.
        const thunk = try self.b.gcAlloc(fty, layout.size, layout.ptr_offsets);
        if (closure_val) |cv| try self.b.fieldSet(thunk, layout.field_offsets[0], cv);
        const arg_base: usize = if (has_closure) 1 else 0;
        for (arg_vals.items, 0..) |v, ai| {
            try self.b.fieldSet(thunk, layout.field_offsets[arg_base + ai], v);
        }

        // Synthesize the trampoline, take its address, and spawn it.
        const tramp = try self.l.synthSpawnTrampoline(fty, direct_fn, arg_tys.items, shape.result, layout);
        const tramp_addr = try self.b.funcAddr(fty, tramp);
        _ = try self.rtCall(self.ctx.void_id, .spawn, &.{ tramp_addr, thunk });
    }

    fn lowerDefer(self: *FnCtx, node: ast.Index) Error!void {
        const call_node = self.kids(node)[0];
        const k = self.kids(call_node);
        // A builtin callee (`print`/`assert`) never resolves through
        // `resolveCallTarget` (see `lowerCall`), so route it here: evaluate the
        // args now (Go semantics) and stash the `rt_call` for `runDefers`.
        if (self.tree().get(k[0]).tag == .ident and self.env.lookup(self.identText(k[0])) == null) {
            if (self.nodeSymbol(k[0])) |gsym| {
                const sym = self.l.symbolOf(gsym);
                if (sym.kind == .builtin_func) return self.lowerDeferBuiltin(call_node, sym.name);
            }
        }
        const target = try self.resolveCallTarget(call_node, k[0]);
        var args: std.ArrayList(ir.ValueId) = .empty;
        if (target == .direct_method) try args.append(self.gpa, target.direct_method.recv);
        // The callee's declared parameter types are the hints, exactly as the
        // immediate-call and `spawn` paths do it. `defer` evaluates its
        // arguments NOW (Go semantics) but stashes the values, so an untyped
        // literal materialized at its default type here is handed to the callee
        // unchanged at `runDefers` time: `defer f(4.5)` against `f(x: f32)`
        // passed an f64 and the callee read its zero low half (#1467).
        const params = target.sig().params;
        for (self.kids(k[2]), 0..) |an, i| {
            if (self.tree().get(an).tag != .arg) {
                args.deinit(self.gpa);
                return error.UnsupportedConstruct;
            }
            const hint: ?TypeId = if (i < params.len) params[i] else null;
            try args.append(self.gpa, try self.lowerExprH(self.kids(an)[0], hint));
        }
        const owned = try args.toOwnedSlice(self.gpa);
        const entry: DeferredCall = switch (target) {
            .direct => |d| .{ .direct = .{ .func = d.func, .args = owned, .result = d.result } },
            .direct_method => |d| .{ .direct = .{ .func = d.func, .args = owned, .result = d.result } },
            .iface => |x| .{ .iface = .{ .recv = x.recv, .method_index = x.method_index, .args = owned, .result = x.result } },
            .value => |x| .{ .value = .{ .callee = x.callee, .args = owned, .result = x.result } },
        };
        try self.defers.append(self.gpa, entry);
    }

    /// Records a deferred `print`/`eprint`/`assert`. `panic` is excluded (it
    /// terminates control flow — deferring it is meaningless); value-returning
    /// builtins (`len`/`cap`/`append`) have no side effect worth deferring.
    fn lowerDeferBuiltin(self: *FnCtx, call_node: ast.Index, name: []const u8) Error!void {
        const rt: ir.RtFn = if (std.mem.eql(u8, name, "print"))
            .print
        else if (std.mem.eql(u8, name, "eprint"))
            .eprint
        else if (std.mem.eql(u8, name, "assert"))
            .assert
        else
            return error.UnsupportedConstruct;
        // `print`/`eprint` take a `string` and `assert` a `bool`; neither is a
        // type an untyped literal defaults away from, so no hint is needed.
        const args = try self.lowerArgs(self.kids(call_node)[2], null);
        try self.defers.append(self.gpa, .{ .builtin = .{ .rt = rt, .args = args, .result = self.ctx.void_id } });
    }

    fn runDefers(self: *FnCtx) Error!void {
        var i = self.defers.items.len;
        while (i > 0) {
            i -= 1;
            switch (self.defers.items[i]) {
                .direct => |x| _ = try self.b.call(x.result, x.func, x.args),
                .iface => |x| _ = try self.b.callIface(x.result, x.recv, x.method_index, x.args),
                .value => |x| _ = try self.b.callValue(x.result, x.callee, x.args),
                .builtin => |x| _ = try self.rtCall(x.result, x.rt, x.args),
            }
        }
    }

    // ---- expressions ------------------------------------------------------

    fn lowerExpr(self: *FnCtx, node: ast.Index) Error!ir.ValueId {
        return self.lowerExprH(node, null);
    }

    /// x64 pre-encoded bytes of an `asm_code` block (§11.6); an empty slice for
    /// an absent (`none`) sub-block.
    fn lowerAsmBytes(self: *FnCtx, code: ast.Index) Error![]u8 {
        if (code == ast.none) return self.gpa.alloc(u8, 0);
        const lits = self.kids(code);
        const out = try self.gpa.alloc(u8, lits.len);
        for (lits, 0..) |lit, i| out[i] = @intCast(check.parseIntLiteral(self.spanText(lit)) & 0xFF);
        return out;
    }

    /// arm64 pre-encoded 32-bit instruction words of an `asm_code` block.
    fn lowerAsmWords(self: *FnCtx, code: ast.Index) Error![]u32 {
        if (code == ast.none) return self.gpa.alloc(u32, 0);
        const lits = self.kids(code);
        const out = try self.gpa.alloc(u32, lits.len);
        for (lits, 0..) |lit, i| out[i] = @intCast(check.parseIntLiteral(self.spanText(lit)) & 0xFFFFFFFF);
        return out;
    }

    /// Register codes of an `asm_clobber` list, per `check.asmReg*`.
    fn lowerAsmRegs(self: *FnCtx, list: ast.Index, is_arm64: bool) Error![]u8 {
        if (list == ast.none) return self.gpa.alloc(u8, 0);
        const regs = self.kids(list);
        const out = try self.gpa.alloc(u8, regs.len);
        for (regs, 0..) |r, i| {
            const name = self.spanText(r);
            out[i] = (if (is_arm64) check.asmRegArm64(name) else check.asmRegX64(name)) orelse 0;
        }
        return out;
    }

    /// Lowers an `asm` block (§11.6) into a `Module.asm_blocks` entry plus the
    /// `Op.asm_stmt` that references it. Both target sub-blocks are pooled; the
    /// backend reads only its own arch's. The result type is the checker's
    /// recorded type for the `result` operand, or `.invalid` when there is none.
    fn lowerAsm(self: *FnCtx, node: ast.Index) Error!ir.ValueId {
        const k = self.kids(node); // [x64_code, arm64_code, result?, clob_x64, clob_arm64, input...]
        const inputs = k[5..];

        const in_x64 = try self.gpa.alloc(u8, inputs.len);
        const in_arm64 = try self.gpa.alloc(u8, inputs.len);
        const in_vals = try self.gpa.alloc(ir.ValueId, inputs.len);
        defer self.gpa.free(in_vals);
        for (inputs, 0..) |in_idx, i| {
            const ik = self.kids(in_idx); // [arm64_reg, x64_reg, value]
            in_arm64[i] = check.asmRegArm64(self.spanText(ik[0])) orelse 0;
            in_x64[i] = check.asmRegX64(self.spanText(ik[1])) orelse 0;
            in_vals[i] = try self.lowerExpr(ik[2]);
        }

        var has_result = false;
        var result_x64: u8 = 0;
        var result_arm64: u8 = 0;
        var ty: TypeId = .invalid;
        if (k[2] != ast.none) {
            const rk = self.kids(k[2]); // [arm64_reg, x64_reg, type]
            has_result = true;
            result_arm64 = check.asmRegArm64(self.spanText(rk[0])) orelse 0;
            result_x64 = check.asmRegX64(self.spanText(rk[1])) orelse 0;
            ty = try self.nodeType(node);
        }

        const block = try self.l.out.addAsmBlock(.{
            .x64_bytes = try self.lowerAsmBytes(k[0]),
            .arm64_words = try self.lowerAsmWords(k[1]),
            .has_result = has_result,
            .result_x64 = result_x64,
            .result_arm64 = result_arm64,
            .in_x64 = in_x64,
            .in_arm64 = in_arm64,
            .clob_x64 = try self.lowerAsmRegs(k[3], false),
            .clob_arm64 = try self.lowerAsmRegs(k[4], true),
        });
        return self.b.asmStmt(ty, block, in_vals);
    }

    /// Whether `ty` is one of the checker's untyped-constant sentinels (§15.4)
    /// — a type an int/float/rune/bool/string/nil literal carries until it is
    /// committed to a concrete type by its surrounding context.
    fn isUntypedTy(self: *const FnCtx, ty: TypeId) bool {
        return ty == self.ctx.untyped_int_id or ty == self.ctx.untyped_float_id or
            ty == self.ctx.untyped_rune_id or ty == self.ctx.untyped_bool_id or
            ty == self.ctx.untyped_string_id or ty == self.ctx.untyped_nil_id;
    }

    /// The concrete type an untyped constant assumes with no context to adapt
    /// to (§15.4). Mirrors `check.zig`'s `defaultType`; anything already
    /// concrete is returned unchanged.
    fn defaultTy(self: *const FnCtx, ty: TypeId) TypeId {
        if (ty == self.ctx.untyped_int_id) return self.ctx.prim_ids.get(.i64);
        if (ty == self.ctx.untyped_float_id) return self.ctx.prim_ids.get(.f64);
        if (ty == self.ctx.untyped_rune_id) return self.ctx.prim_ids.get(.i32);
        if (ty == self.ctx.untyped_bool_id) return self.ctx.prim_ids.get(.bool);
        if (ty == self.ctx.untyped_string_id) return self.ctx.prim_ids.get(.string);
        return ty;
    }

    /// The concrete type to materialize `node`'s value as. The checker records
    /// an *untyped* type on literal nodes and only commits the concrete type at
    /// the binder/operand/argument that consumes them; lowering must never emit
    /// an untyped-typed value (block params, operands, and args are all
    /// concrete, so an untyped value fails the IR verifier). Concrete node
    /// types pass through; an untyped node adopts `hint` when it is concrete
    /// (the assignability was already proven by the checker), else its default.
    fn materializeType(self: *FnCtx, node: ast.Index, hint: ?TypeId) Error!TypeId {
        const nt = try self.nodeType(node);
        if (!self.isUntypedTy(nt)) return nt;
        if (hint) |h| {
            if (h != .invalid and !self.isUntypedTy(h)) return h;
        }
        return self.defaultTy(nt);
    }

    /// Lowers `node`, materializing any untyped constant it produces at `hint`
    /// (see `materializeType`). `hint` is `null` where the context imposes no
    /// concrete type; `lowerExpr` is the null-hint shorthand.
    fn lowerExprH(self: *FnCtx, node: ast.Index, hint: ?TypeId) Error!ir.ValueId {
        return switch (self.tree().get(node).tag) {
            .int_lit => blk: {
                const ty = try self.materializeType(node, hint);
                break :blk self.b.constInt(ty, @truncate(check.parseIntLiteral(self.spanText(node))));
            },
            .rune_lit => blk: {
                const ty = try self.materializeType(node, hint);
                break :blk self.b.constInt(ty, @truncate(check.parseRuneLiteral(self.spanText(node))));
            },
            .float_lit => blk: {
                const ty = try self.materializeType(node, hint);
                break :blk self.b.constFloat(ty, try self.parseFloat(self.spanText(node)));
            },
            .bool_lit => blk: {
                const ty = try self.materializeType(node, hint);
                break :blk self.b.constBool(ty, std.mem.eql(u8, self.spanText(node), "true"));
            },
            .nil_lit => self.b.constNil(try self.materializeType(node, hint)),
            .string_lit => blk: {
                const ty = try self.materializeType(node, hint);
                const text = try self.unescapeString(self.spanText(node));
                defer self.gpa.free(text);
                const idx = try self.l.out.internString(text);
                break :blk self.b.constString(ty, idx);
            },
            .raw_string_lit => blk: {
                const ty = try self.materializeType(node, hint);
                const raw = self.spanText(node);
                const text = try self.normalizeRaw(raw[1 .. raw.len - 1]);
                defer self.gpa.free(text);
                const idx = try self.l.out.internString(text);
                break :blk self.b.constString(ty, idx);
            },
            .ident => self.lowerIdent(node),
            .binary => self.lowerBinary(node, hint),
            .unary => self.lowerUnary(node, hint),
            .asm_stmt => self.lowerAsm(node),
            .call => self.lowerCall(node),
            .member => self.lowerMember(node),
            .index => blk: {
                const k = self.kids(node);
                const recv = try self.lowerExpr(k[0]);
                const idxv = try self.lowerExpr(k[1]);
                const ty = try self.nodeType(node);
                const recv_data = self.ctx.typeOf(try self.nodeType(k[0]));
                // A dynamic `[]T` and a `string` both read a `{ptr,len,...}`
                // header through the bounds-checked runtime; a static `[N]T`
                // array is a direct data pointer (codegen op).
                if (recv_data == .slice)
                    break :blk self.rtCall(ty, .slice_get, &.{ recv, idxv });
                if (recv_data == .map)
                    break :blk self.rtCall(ty, .map_get, &.{ recv, idxv });
                if (recv_data == .prim and recv_data.prim == .string)
                    break :blk self.rtCall(ty, .string_byte, &.{ recv, idxv });
                break :blk self.b.indexGet(ty, recv, idxv);
            },
            .str_interp => self.lowerStrInterp(node),
            .composite_lit => self.lowerCompositeLit(node),
            .slice_lit => self.lowerSliceElems(try self.nodeType(node), self.kids(node)),
            .slice_expr => self.lowerSliceExpr(node),
            .arrow_fn => self.lowerArrowFn(node),
            .try_expr => self.lowerTryExpr(node),
            .catch_default => self.lowerCatch(node, false),
            .catch_bind => self.lowerCatch(node, true),
            .match_stmt => self.lowerMatchExpr(node),
            // The one-result assertion `iface.(T)` (SPEC §14.4): panics on a
            // mismatch. The two-result form never reaches here — a `tuple_pat`
            // target routes it through `lowerTwoResult` instead.
            .type_assert => blk: {
                const k = self.kids(node);
                const ty = try self.nodeType(node);
                const recv = try self.lowerExpr(k[0]);
                const info = try self.typeInfoOf(ty);
                break :blk self.rtCall(ty, .iface_assert, &.{ recv, info });
            },
            // `t.0` — a field read at the element's offset in the boxed tuple
            // (ABI.md §1.1). The checker has already range-checked the index
            // against the tuple's arity (E0059).
            .tuple_index => blk: {
                const k = self.kids(node);
                const tup_ty = try self.nodeType(k[0]);
                if (self.ctx.typeOf(tup_ty) != .tuple) break :blk error.UnsupportedConstruct;
                const idx = check.parseIntLiteral(self.spanText(k[1]));
                if (idx < 0 or idx >= self.ctx.typeOf(tup_ty).tuple.len) break :blk error.UnsupportedConstruct;
                const recv = try self.lowerExpr(k[0]);
                break :blk self.tupleElem(tup_ty, recv, @intCast(idx));
            },
            else => error.UnsupportedConstruct, // map literals
        };
    }

    fn lowerIdent(self: *FnCtx, node: ast.Index) Error!ir.ValueId {
        const name = self.identText(node);
        if (self.env.lookup(name)) |idx| return self.env.bindings.items[idx].value;
        const gsym = self.nodeSymbol(node) orelse return error.UnsupportedConstruct;
        const sym = self.l.symbolOf(gsym);
        if (sym.kind == .func) return self.lowerFuncValue(node, gsym); // a named function used as a value
        if (sym.kind == .let_binding and sym.module_scoped) return self.lowerGlobalRead(node, gsym);
        if (sym.kind != .const_binding) return error.UnsupportedConstruct;
        return self.lowerTopConst(gsym, sym.file_idx);
    }

    /// The address of a module-level `let`'s static cell (§11.11), as a raw
    /// pointer value. `global_addr` is pure address arithmetic — no load, no
    /// call, no safepoint — which is what makes module state reachable from a
    /// `@nosplit` body (§10.3.1).
    fn globalAddrOf(self: *FnCtx, gsym: GlobalSymbol) Error!ir.ValueId {
        const gid = self.l.global_ids.get(gsym.pack()) orelse return error.UnsupportedConstruct;
        return self.b.globalAddr(self.ctx.prim_ids.get(.i64), gid);
    }

    /// Reading a module-level `let`. An `[N]T` array *is* its base address in
    /// this IR (`index_get`/`index_set` take an element-base pointer), so the
    /// address is the value; every other admissible type is a single word held
    /// in the cell, so it takes one load — `field_get` at offset 0, the same op
    /// `*p` already lowers to.
    fn lowerGlobalRead(self: *FnCtx, node: ast.Index, gsym: GlobalSymbol) Error!ir.ValueId {
        const addr = try self.globalAddrOf(gsym);
        const ty = try self.nodeType(node);
        if (self.ctx.typeOf(ty) == .array) return addr;
        return self.b.fieldGet(ty, addr, 0);
    }

    /// A named top-level function referenced as a first-class value: wrap it in a
    /// closure over a trampoline (`funcValueTrampoline`) with a nil environment,
    /// so it is call-compatible with arrow closures and method values.
    fn lowerFuncValue(self: *FnCtx, node: ast.Index, gsym: GlobalSymbol) Error!ir.ValueId {
        const fty = try self.nodeType(node);
        const fid = self.l.func_ids.get(gsym.pack()) orelse return error.UnsupportedConstruct; // generic function (no monomorphized id): out of scope
        const shape = self.ctx.func_sigs.get(gsym.pack()).?;
        const tramp = try self.l.funcValueTrampoline(fty, gsym, fid, shape);
        const env = try self.b.constNil(fty);
        return self.b.makeClosure(fty, tramp, env);
    }

    /// Inlines a top-level `const`'s initializer at the reference site
    /// (re-lowered fresh each time — top-level consts are always
    /// constant-foldable expressions per the checker, so this is always
    /// valid, if occasionally redundant across multiple references).
    ///
    /// The initializer node comes from the const's own module's checked
    /// tables (`constInitOf`), so an imported `export const` works too. Both
    /// the module cursor and the file index are re-pointed at that module for
    /// the duration — every source read (`tree`/`nodeType`/`nodeSymbol`)
    /// indexes through `self.l.{files,checked,rmodule}[file_idx]` — then
    /// restored. The initializer lowers into the *current* function's IR
    /// builder regardless; only the source-reading context moves.
    fn lowerTopConst(self: *FnCtx, gsym: GlobalSymbol, file_idx: usize) Error!ir.ValueId {
        const mi = self.l.modules[@intFromEnum(gsym.module)];
        const init_node = mi.checked.constInitOf(gsym.id) orelse return error.UnsupportedConstruct;
        const saved_module = self.l.cur_module;
        const saved_file = self.file_idx;
        self.l.setModule(gsym.module);
        self.file_idx = file_idx;
        defer {
            self.l.setModule(saved_module);
            self.file_idx = saved_file;
        }
        return self.lowerExpr(init_node);
    }

    fn lowerShortCircuit(self: *FnCtx, op: lexer.Kind, lhs: ast.Index, rhs: ast.Index) Error!ir.ValueId {
        const bool_ty = self.ctx.prim_ids.get(.bool);
        const lval = try self.lowerExpr(lhs);
        const rhs_blk = try self.b.newBlock();
        const join = try self.b.newBlock();
        if (op == .amp_amp) {
            try self.emitBr(lval, rhs_blk, &.{}, join, &.{lval});
        } else {
            try self.emitBr(lval, join, &.{lval}, rhs_blk, &.{});
        }
        self.switchBlock(rhs_blk);
        const rval = try self.lowerExpr(rhs);
        try self.emitJump(join, &.{rval});
        self.switchBlock(join);
        return self.b.addParam(bool_ty);
    }

    fn lowerBinary(self: *FnCtx, node: ast.Index, hint: ?TypeId) Error!ir.ValueId {
        const op: lexer.Kind = @enumFromInt(self.tree().get(node).main);
        const k = self.kids(node);
        if (op == .amp_amp or op == .pipe_pipe) return self.lowerShortCircuit(op, k[0], k[1]);
        // Both operands share one concrete type: whichever side the checker
        // already typed concretely, else the arithmetic result's type (a
        // concrete hint carried in), else the constants' default. Comparisons
        // yield bool but still need matching concrete operands.
        const is_cmp = switch (op) {
            .eq_eq, .bang_eq, .lt, .lt_eq, .gt, .gt_eq => true,
            else => false,
        };
        const lty = try self.nodeType(k[0]);
        const rty = try self.nodeType(k[1]);
        // A comparison's `hint` is bool (the result), never the operand type,
        // so only arithmetic may adopt it for two untyped operands.
        const usable_hint = hint != null and hint.? != .invalid and !self.isUntypedTy(hint.?) and !is_cmp;
        const common: TypeId = if (!self.isUntypedTy(lty)) lty else if (!self.isUntypedTy(rty))
            rty
        else if (usable_hint)
            hint.?
        else
            self.defaultTy(lty);
        const cdata = self.ctx.typeOf(common);
        // Pointer arithmetic (§11.4): `p ± n` scales `n` by sizeOf(T) and offsets
        // the raw address. A `*T` is an int-classed word (is_ref=0), so this is a
        // plain integer add/sub. The scaled byte offset is retyped to the pointer
        // type with a no-op `convert` (both are one int word) so add/sub's operands
        // and result share a type, as the IR verifier requires.
        if (cdata == .ptr and (op == .plus or op == .minus)) {
            const elem_ty = cdata.ptr;
            const scale = fieldLayout(self.ctx.typeOf(elem_ty)).size;
            const base_val = try self.lowerExprH(k[0], common);
            const i64_ty = self.ctx.prim_ids.get(.i64);
            var off = try self.lowerExprH(k[1], i64_ty);
            if (scale != 1) {
                const sc = try self.b.constInt(i64_ty, @intCast(scale));
                off = try self.b.binary(.mul, i64_ty, off, sc);
            }
            const off_ptr = try self.b.convert(common, off);
            const iop: ir.Op = if (op == .plus) .add else .sub;
            return self.b.binary(iop, common, base_val, off_ptr);
        }
        if (cdata == .prim and cdata.prim == .string and (op == .eq_eq or op == .bang_eq or op == .plus)) {
            const sl = try self.lowerExprH(k[0], common);
            const sr = try self.lowerExprH(k[1], common);
            if (op == .plus) return self.rtCall(common, .string_concat, &.{ sl, sr });
            const bool_ty = self.ctx.prim_ids.get(.bool);
            const eq = try self.rtCall(bool_ty, .string_eq, &.{ sl, sr });
            if (op == .eq_eq) return eq;
            const f = try self.b.constBool(bool_ty, false); // `!=` is `(a == b) == false`
            return self.b.binary(.icmp_eq, bool_ty, eq, f);
        }
        const lval = try self.lowerExprH(k[0], common);
        const rval = try self.lowerExprH(k[1], common);
        // The result type must match the operands (`common`), which the IR
        // verifier enforces (`ty == lhs type`). `nodeType(node)` can't be used:
        // the checker leaves an all-untyped arithmetic node (`7 * 6`) typed
        // `untyped_int`, but the operands were just materialized as `common`
        // (e.g. `i64` from a send/param hint) — a mismatch. A comparison always
        // yields `bool` regardless of its operand type.
        const result_ty = if (is_cmp) self.ctx.prim_ids.get(.bool) else common;
        const iop = try binOpFor(op, cdata);
        return self.b.binary(iop, result_ty, lval, rval);
    }

    fn lowerUnary(self: *FnCtx, node: ast.Index, hint: ?TypeId) Error!ir.ValueId {
        const op: lexer.Kind = @enumFromInt(self.tree().get(node).main);
        const operand = self.kids(node)[0];
        if (op == .arrow_left) {
            // `<- ch`: receive one word. `bit_rt_chan_recv` returns `{value, ok}`
            // (ABI.md §11); the value word is the result. The two-result form
            // `v, ok = <- ch` needs tuple-destructuring lowering (deferred).
            const elem_ty = try self.nodeType(node);
            const ch = try self.lowerExpr(operand);
            return self.rtCall(elem_ty, .chan_recv, &.{ch});
        }
        if (op == .star) {
            // `*p` (§11.4): load one word from the pointed-at address. Reuses the
            // `field_get` op at offset 0 — a plain `base + 0` load, no GC barrier.
            const elem_ty = try self.nodeType(node);
            const p = try self.lowerExpr(operand);
            return self.b.fieldGet(elem_ty, p, 0);
        }
        const ty = try self.materializeType(node, hint);
        const val = try self.lowerExprH(operand, ty);
        if (op == .bang) {
            const f = try self.b.constBool(ty, false);
            return self.b.binary(.icmp_eq, ty, val, f);
        }
        const data = self.ctx.typeOf(ty);
        const is_float = data == .prim and (data.prim == .f32 or data.prim == .f64);
        const iop: ir.Op = switch (op) {
            .minus => if (is_float) .fneg else .neg,
            .tilde => .bnot,
            else => return error.UnsupportedConstruct,
        };
        return self.b.unary(iop, ty, val);
    }

    /// Whether `recv` names an enum *type* — a bare enum name or a turbofish
    /// `Enum<Args>` (`generic_inst`) — rather than a value-producing expression.
    /// A member/call on such a receiver is a variant reference/construction.
    fn isEnumTypeRef(self: *FnCtx, recv: ast.Index) bool {
        const base = switch (self.tree().get(recv).tag) {
            .ident => recv,
            .generic_inst => self.kids(recv)[0],
            else => return false,
        };
        if (self.tree().get(base).tag != .ident) return false;
        const gs = self.nodeSymbol(base) orelse return false;
        return self.l.symbolOf(gs).kind == .enum_type;
    }

    fn lowerMember(self: *FnCtx, node: ast.Index) Error!ir.ValueId {
        const k = self.kids(node); // [recv, name]
        const name = self.identText(k[1]);
        // `time.Millisecond` — a namespace member read as a value. Only an
        // exported `const` can be, exactly as for a bare identifier (`lowerIdent`);
        // a call goes through `resolveCallTarget` and never reaches here.
        if (self.namespaceMember(node)) |gsym| {
            const sym = self.l.symbolOf(gsym);
            if (sym.kind == .func) return self.lowerFuncValue(node, gsym); // imported function used as a value
            if (sym.kind != .const_binding) return error.UnsupportedConstruct;
            return self.lowerTopConst(gsym, sym.file_idx);
        }
        // `EnumName.Variant` / `Enum<Args>.Variant` — a variant reference lowers
        // to its tag (a bare i64 for a C-like enum, a `{tag, null}` object for a
        // boxed one). The member node itself was typed as the concrete enum by
        // `checkVariantRef`/`variantRefResult`, so its variant list gives the tag.
        if (self.isEnumTypeRef(k[0])) {
            const enum_ty = try self.nodeType(node);
            const ed = self.ctx.typeOf(enum_ty);
            if (ed == .@"enum") {
                for (ed.@"enum".variants, 0..) |v, i| {
                    if (!std.mem.eql(u8, v.name, name)) continue;
                    if (check.enumBoxed(ed.@"enum")) return self.buildEnumObj(enum_ty, @intCast(i), null);
                    return self.b.constInt(enum_ty, @intCast(i));
                }
            }
            return error.UnsupportedConstruct;
        }
        const recv_ty = try self.nodeType(k[0]);
        const data = self.ctx.typeOf(recv_ty);
        if (data == .@"struct") {
            for (data.@"struct", 0..) |f, i| {
                if (!std.mem.eql(u8, f.name, name)) continue;
                const recv_val = try self.lowerExpr(k[0]);
                const layout = try self.l.structLayout(recv_ty);
                return self.b.fieldGet(f.ty, recv_val, layout.field_offsets[i]);
            }
            if (self.l.lookupMethod(recv_ty, name)) |entry| {
                const recv_val = try self.lowerExpr(k[0]);
                const fty = try self.nodeType(node);
                return self.b.makeClosure(fty, entry.fid, recv_val);
            }
        }
        // An interface method taken as a value binds the receiver into a closure
        // that dispatches through its vtable (the checker typed this member as the
        // method's function type, so it is a real interface method here).
        if (data == .interface) {
            const fty = try self.nodeType(node);
            const shape = self.ctx.typeOf(fty).func;
            const method_index = try self.l.methodId(name);
            const recv_val = try self.lowerExpr(k[0]);
            const tramp = try self.l.ifaceMethodTrampoline(recv_ty, method_index, shape);
            return self.b.makeClosure(fty, tramp, recv_val);
        }
        return error.UnsupportedConstruct;
    }

    /// True when a value of `ty` is a single-word GC reference (mirrors
    /// `codegen/common.isRefType`): recorded in a slice header so #1106 can
    /// scan the element buffer. Value-typed elements wider than a word are
    /// boxed, so their word is a reference too.
    fn elemIsRef(self: *const FnCtx, ty: TypeId) bool {
        return switch (self.ctx.typeOf(ty)) {
            .prim => |p| p == .string,
            // A raw pointer `*T` (§11.4) is not a GC reference — never traced.
            .void, .untyped_int, .untyped_float, .untyped_rune, .untyped_bool, .untyped_string, .untyped_nil, .invalid, .type_param, .fallible, .ptr => false,
            else => true, // slice/array/map/tuple/chan/struct/interface/func
        };
    }

    /// Whether a map key type `K` is `string` — the sole reference key type
    /// (§14.6), and the one the runtime hashes/compares by bytes rather than by
    /// word. Drives both `bit_rt_map_new`'s `key_is_string` flag and its GC
    /// tracing of the key buffer.
    fn keyIsString(self: *const FnCtx, ty: TypeId) bool {
        const d = self.ctx.typeOf(ty);
        return d == .prim and d.prim == .string;
    }

    /// `map<K,V>()` / `map<K,V>{...}`: a fresh map. The `key_is_string` and
    /// `val_is_ref` flags (§14.6, ABI.md §12) come from K/V and are constant.
    fn lowerMapMake(self: *FnCtx, node: ast.Index) Error!ir.ValueId {
        const map_ty = try self.nodeType(node);
        const m = self.ctx.typeOf(map_ty).map;
        const i64ty = self.ctx.prim_ids.get(.i64);
        const kflag = try self.b.constInt(i64ty, if (self.keyIsString(m.key)) 1 else 0);
        const vflag = try self.b.constInt(i64ty, if (self.elemIsRef(m.val)) 1 else 0);
        return self.rtCall(map_ty, .map_new, &.{ kflag, vflag });
    }

    /// `map<K,V>{ k1: v1, ... }` (§12.3): build an empty map, then set each
    /// entry left-to-right (a later duplicate key overwrites, matching runtime
    /// insert semantics).
    fn lowerMapLit(self: *FnCtx, node: ast.Index, entries_node: ast.Index) Error!ir.ValueId {
        const map_ty = try self.nodeType(node);
        const m = self.ctx.typeOf(map_ty).map;
        const mv = try self.lowerMapMake(node);
        for (self.kids(entries_node)) |e| {
            const ek = self.kids(e); // map_entry: [key, val]
            const key = try self.lowerExprH(ek[0], m.key);
            const val = try self.lowerExprH(ek[1], m.val);
            _ = try self.rtCall(self.ctx.void_id, .map_set, &.{ mv, key, val });
        }
        return mv;
    }

    /// Builds a `[]T` from an element list (a bare `[a, b]` `slice_lit` or a
    /// typed `[]T{a, b}` composite): allocate a length-N slice, then store each
    /// element. `items` are `arg`/`arg_spread` wrappers; the element expression
    /// is each item's first child.
    fn lowerSliceElems(self: *FnCtx, slice_ty: TypeId, items: []const ast.Index) Error!ir.ValueId {
        const elem_ty = self.ctx.typeOf(slice_ty).slice;
        const i64ty = self.ctx.prim_ids.get(.i64);
        const n: i64 = @intCast(items.len);
        const len = try self.b.constInt(i64ty, n);
        const is_ref = try self.b.constInt(i64ty, if (self.elemIsRef(elem_ty)) 1 else 0);
        const s = try self.rtCall(slice_ty, .slice_new, &.{ len, len, is_ref });
        for (items, 0..) |a, i| {
            const inner = self.kids(a)[0];
            const v = try self.lowerExprH(inner, elem_ty);
            const idx = try self.b.constInt(i64ty, @intCast(i));
            _ = try self.rtCall(self.ctx.void_id, .slice_set, &.{ s, idx, v });
        }
        return s;
    }

    /// `s[lo:hi]` (SPEC §12.6). On a `[]T`, a new view sharing `s`'s buffer; on
    /// a `string`, a fresh copy of bytes `[lo, hi)` (string headers hold interior
    /// pointers, so a shared view can't keep its backing GC-alive). `lo` defaults
    /// to 0, `hi` to `len(s)` — the `len` field load is shared by both layouts.
    /// Re-slicing a `[N]T` array is deferred (arrays aren't yet constructible).
    fn lowerSliceExpr(self: *FnCtx, node: ast.Index) Error!ir.ValueId {
        const k = self.kids(node); // [recv, lo_or_none, hi_or_none]
        const recv_ty = try self.nodeType(k[0]);
        const rd = self.ctx.typeOf(recv_ty);
        const is_string = rd == .prim and rd.prim == .string;
        if (rd != .slice and !is_string) return error.UnsupportedConstruct;
        const i64ty = self.ctx.prim_ids.get(.i64);
        const recv = try self.lowerExpr(k[0]);
        const lo = if (k[1] != ast.none) try self.lowerExprH(k[1], i64ty) else try self.b.constInt(i64ty, 0);
        const hi = if (k[2] != ast.none) try self.lowerExprH(k[2], i64ty) else try self.b.sliceLen(i64ty, recv);
        const rt: ir.RtFn = if (is_string) .string_slice else .slice_slice;
        return self.rtCall(try self.nodeType(node), rt, &.{ recv, lo, hi });
    }

    fn lowerCompositeLit(self: *FnCtx, node: ast.Index) Error!ir.ValueId {
        const k = self.kids(node); // [type, init]
        const ty = try self.nodeType(node);
        const data = self.ctx.typeOf(ty);
        if (data == .slice) return self.lowerSliceElems(ty, self.kids(k[1])); // []T{...}
        if (data == .array) return self.lowerArrayElems(ty, self.kids(k[1])); // [N]T{...}
        if (data == .map) return self.lowerMapLit(node, k[1]); // map<K,V>{...}
        if (data != .@"struct") return error.UnsupportedConstruct;
        const init_node = k[1];
        if (self.tree().get(init_node).tag != .field_inits) return error.UnsupportedConstruct;
        const layout = try self.l.structLayout(ty);
        const obj = try self.b.gcAlloc(ty, layout.size, layout.ptr_offsets);
        for (self.kids(init_node)) |fi| {
            const fk = self.kids(fi); // field_init: [name_ident, expr]
            const name = self.identText(fk[0]);
            // The field's own type is the hint the initializer is lowered
            // under. Without it an untyped literal materializes at its DEFAULT
            // type — `4.5` as an `f64` — and the `field_set` then writes the
            // field's width from it, storing the low half of an f64 into an
            // `f32` field: a silent zero (#1457). The name lookup has no side
            // effects, so hoisting it above the lowering keeps evaluation order.
            const hint = blk: {
                for (data.@"struct") |f| {
                    if (std.mem.eql(u8, f.name, name)) break :blk f.ty;
                }
                break :blk null;
            };
            const val = if (hint) |h| try self.lowerExprH(fk[1], h) else try self.lowerExpr(fk[1]);
            var found = false;
            for (data.@"struct", 0..) |f, i| {
                if (!std.mem.eql(u8, f.name, name)) continue;
                // A fixed-size array field lives inline: copy the source
                // elements into the field's storage rather than storing a
                // handle. Omitted array fields stay zero (the body is zeroed).
                if (self.ctx.typeOf(f.ty) == .array) {
                    const dst = try self.b.fieldGet(f.ty, obj, layout.field_offsets[i]);
                    try self.copyArrayElems(dst, val, self.arrayShape(f.ty));
                } else {
                    try self.b.fieldSet(obj, layout.field_offsets[i], val);
                }
                found = true;
            }
            if (!found) return error.UnsupportedConstruct;
        }
        return obj;
    }

    fn lowerToString(self: *FnCtx, v: ir.ValueId, raw_ty: TypeId) Error!ir.ValueId {
        const string_ty = self.ctx.prim_ids.get(.string);
        // An interpolated literal (`"${1.5}"`, `"${42}"`) carries an untyped
        // type; the value was already materialized at its default type, so the
        // conversion must dispatch on that same default rather than fall through.
        const ty = self.defaultTy(raw_ty);
        const data = self.ctx.typeOf(ty);
        if (data == .prim) {
            return switch (data.prim) {
                .string => v,
                .bool => self.rtCall(string_ty, .string_from_bool, &.{v}),
                // `bit_rt_string_from_float` takes an `f64`, so an `f32` must be
                // widened first: passing a single leaves the callee's `d0`/`xmm0`
                // upper half undefined and it formats a denormal near zero (a
                // long all-zero fractional tail — #1457). The seed's own
                // conversion, not the callee's, because the C signature is `f64`.
                .f64 => self.rtCall(string_ty, .string_from_float, &.{v}),
                .f32 => self.rtCall(string_ty, .string_from_float, &.{
                    try self.b.convert(self.ctx.prim_ids.get(.f64), v),
                }),
                else => self.rtCall(string_ty, .string_from_int, &.{v}),
            };
        }
        // Everything else needs `show(): string` (§5.7). The checker enforces
        // it — signature included — through this same predicate (E0073), so a
        // wrong-shaped `show` can never be called here, and reaching the final
        // return means the checker let an unconvertible operand through.
        if (self.ctx.showMethod(ty) != null) {
            if (data == .interface) return self.b.callIface(string_ty, v, try self.l.methodId("show"), &.{});
            if (self.l.lookupMethod(ty, "show")) |entry| return self.b.call(string_ty, entry.fid, &.{v});
        }
        return error.UnsupportedConstruct;
    }

    fn lowerStrInterp(self: *FnCtx, node: ast.Index) Error!ir.ValueId {
        const parts = self.kids(node);
        const string_ty = self.ctx.prim_ids.get(.string);
        const vals = try self.gpa.alloc(ir.ValueId, parts.len);
        defer self.gpa.free(vals);
        for (parts, 0..) |p, i| {
            if (self.tree().get(p).tag == .str_part) {
                const text = try self.unescapeInner(self.spanText(p));
                defer self.gpa.free(text);
                const idx = try self.l.out.internString(text);
                vals[i] = try self.b.constString(string_ty, idx);
            } else {
                const v = try self.lowerExpr(p);
                const ty = try self.nodeType(p);
                vals[i] = try self.lowerToString(v, ty);
            }
        }
        // `string_concat` is binary; fold the parts left-to-right.
        var acc = vals[0];
        for (vals[1..]) |v| acc = try self.rtCall(string_ty, .string_concat, &.{ acc, v });
        return acc;
    }

    fn lowerArrowFn(self: *FnCtx, node: ast.Index) Error!ir.ValueId {
        const k = self.kids(node); // [arrow_params, body]
        const closure_ty = try self.nodeType(node);
        const shape = self.ctx.typeOf(closure_ty).func;

        var own_params: std.StringHashMapUnmanaged(void) = .{};
        defer own_params.deinit(self.gpa);
        for (self.kids(k[0])) |p| try own_params.put(self.gpa, self.identText(self.kids(p)[0]), {});

        var captures: std.ArrayList(Capture) = .empty;
        defer captures.deinit(self.gpa);
        var cap_seen: std.StringHashMapUnmanaged(void) = .{};
        defer cap_seen.deinit(self.gpa);
        var i = self.env.bindings.items.len;
        while (i > 0) {
            i -= 1;
            const bd = self.env.bindings.items[i];
            if (own_params.contains(bd.name) or cap_seen.contains(bd.name)) continue;
            try cap_seen.put(self.gpa, bd.name, {});
            try captures.append(self.gpa, .{ .name = bd.name, .ty = bd.ty, .value = bd.value });
        }

        const cap_fields = try self.gpa.alloc(check.Field, captures.items.len);
        defer self.gpa.free(cap_fields);
        for (captures.items, 0..) |c, ci| cap_fields[ci] = .{ .name = c.name, .ty = c.ty, .exported = false };
        var env_layout = try layoutFields(self.gpa, self.ctx, cap_fields);
        defer env_layout.deinit(self.gpa);

        const env_obj = if (captures.items.len == 0)
            try self.b.constNil(closure_ty)
        else blk: {
            const obj = try self.b.gcAlloc(closure_ty, env_layout.size, env_layout.ptr_offsets);
            for (captures.items, 0..) |c, ci| try self.b.fieldSet(obj, env_layout.field_offsets[ci], c.value);
            break :blk obj;
        };

        const fid = try self.l.lowerClosureBody(node, self.file_idx, shape, self.gen_env, captures.items, closure_ty, env_layout);
        return self.b.makeClosure(closure_ty, fid, env_obj);
    }

    // ---- literal helpers ---------------------------------------------------

    fn parseFloat(self: *FnCtx, text: []const u8) Error!f64 {
        _ = self;
        var buf: [128]u8 = undefined;
        var n: usize = 0;
        for (text) |c| {
            if (c == '_') continue;
            if (n >= buf.len) return error.UnsupportedConstruct; // pathological literal length guard
            buf[n] = c;
            n += 1;
        }
        return std.fmt.parseFloat(f64, buf[0..n]) catch error.UnsupportedConstruct;
    }

    fn unescapeInner(self: *FnCtx, s: []const u8) Error![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(self.gpa);
        var i: usize = 0;
        while (i < s.len) {
            const c = s[i];
            if (c != '\\') {
                try out.append(self.gpa, c);
                i += 1;
                continue;
            }
            i += 1;
            if (i >= s.len) break;
            const e = s[i];
            i += 1;
            switch (e) {
                'n' => try out.append(self.gpa, '\n'),
                't' => try out.append(self.gpa, '\t'),
                'r' => try out.append(self.gpa, '\r'),
                '0' => try out.append(self.gpa, 0),
                '\\', '"', '\'', '$' => try out.append(self.gpa, e),
                'x' => {
                    if (i + 2 > s.len) break;
                    const byte = std.fmt.parseInt(u8, s[i .. i + 2], 16) catch break;
                    try out.append(self.gpa, byte);
                    i += 2;
                },
                'u' => {
                    if (i >= s.len or s[i] != '{') break;
                    i += 1;
                    const start = i;
                    while (i < s.len and s[i] != '}') i += 1;
                    const cp = std.fmt.parseInt(u21, s[start..i], 16) catch break;
                    if (i < s.len) i += 1;
                    var buf4: [4]u8 = undefined;
                    const len = std.unicode.utf8Encode(cp, &buf4) catch break;
                    try out.appendSlice(self.gpa, buf4[0..len]);
                },
                else => try out.append(self.gpa, e),
            }
        }
        return out.toOwnedSlice(self.gpa);
    }

    fn unescapeString(self: *FnCtx, raw: []const u8) Error![]u8 {
        std.debug.assert(raw.len >= 2);
        return self.unescapeInner(raw[1 .. raw.len - 1]);
    }

    /// Raw strings have no escapes; only `CR LF` -> `LF` normalization (§5.7).
    fn normalizeRaw(self: *FnCtx, s: []const u8) Error![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(self.gpa);
        var i: usize = 0;
        while (i < s.len) {
            if (s[i] == '\r' and i + 1 < s.len and s[i + 1] == '\n') {
                try out.append(self.gpa, '\n');
                i += 2;
                continue;
            }
            try out.append(self.gpa, s[i]);
            i += 1;
        }
        return out.toOwnedSlice(self.gpa);
    }
};

const Lvalue = union(enum) {
    local: usize,
    field: struct { recv: ir.ValueId, ty: TypeId, offset: u32 },
    elem: struct { recv: ir.ValueId, index: ir.ValueId, ty: TypeId, is_slice: bool },
    map_elem: struct { recv: ir.ValueId, key: ir.ValueId, val_ty: TypeId },
};

/// The base arithmetic op a compound-assign token (`+=` etc.) applies.
fn compoundBase(op: lexer.Kind) lexer.Kind {
    return switch (op) {
        .plus_eq => .plus,
        .minus_eq => .minus,
        .star_eq => .star,
        .slash_eq => .slash,
        .percent_eq => .percent,
        .amp_eq => .amp,
        .pipe_eq => .pipe,
        .caret_eq => .caret,
        .shl_eq => .shl,
        .shr_eq => .shr,
        else => unreachable, // lowerAssign only calls this when op != .eq, and the parser accepts no other compound op
    };
}

fn binOpFor(op: lexer.Kind, data: TypeData) Error!ir.Op {
    const is_float = data == .prim and (data.prim == .f32 or data.prim == .f64);
    const is_signed = data == .prim and switch (data.prim) {
        .i8, .i16, .i32, .i64 => true,
        else => false,
    };
    return switch (op) {
        .plus => if (is_float) .fadd else .add,
        .minus => if (is_float) .fsub else .sub,
        .star => if (is_float) .fmul else .mul,
        .slash => if (is_float) .fdiv else if (is_signed) .sdiv else .udiv,
        .percent => if (is_signed) .srem else .urem,
        .amp => .band,
        .pipe => .bor,
        .caret => .bxor,
        .shl => .shl,
        .shr => if (is_signed) .ashr else .lshr,
        .eq_eq => if (is_float) .fcmp_eq else .icmp_eq,
        .bang_eq => if (is_float) .fcmp_ne else .icmp_ne,
        .lt => if (is_float) .fcmp_lt else if (is_signed) .icmp_slt else .icmp_ult,
        .lt_eq => if (is_float) .fcmp_le else if (is_signed) .icmp_sle else .icmp_ule,
        .gt => if (is_float) .fcmp_gt else if (is_signed) .icmp_sgt else .icmp_ugt,
        .gt_eq => if (is_float) .fcmp_ge else if (is_signed) .icmp_sge else .icmp_uge,
        else => error.UnsupportedConstruct,
    };
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

fn lowerSource(gpa: Allocator, source: []const u8) !struct { module: ir.Module, ctx: TypeContext } {
    const diagnostics = @import("diagnostics.zig");
    const parser = @import("parser.zig");

    var sm = diagnostics.SourceManager.init(gpa);
    defer sm.deinit();
    var diags = diagnostics.Diagnostics.init(gpa, &sm);
    defer diags.deinit();
    const file = try sm.addFile("t.bit", source);

    var tree = try ast.Tree.init(gpa);
    defer tree.deinit();
    try parser.parse(gpa, &tree, &diags, file, source);
    try testing.expect(!diags.hasErrors());

    const mf = ModuleFile{ .file = file, .source = source, .tree = &tree };
    var no_imports: resolve.ImportTable = .{};
    defer no_imports.deinit(gpa);
    const files = [_]ModuleFile{mf};

    var rmodule = try resolve.resolveModule(gpa, &diags, &files, &no_imports, &.{}, null);
    defer rmodule.deinit();
    try testing.expect(!diags.hasErrors());

    var ctx = try TypeContext.init(gpa);
    errdefer ctx.deinit();
    var checked = try check.checkModule(gpa, &diags, &ctx, &files, &rmodule, @enumFromInt(0), &.{}, false);
    defer checked.deinit();
    if (diags.hasErrors()) {
        var rendered: std.Io.Writer.Allocating = .init(gpa);
        defer rendered.deinit();
        try diags.renderAll(&rendered.writer);
        std.debug.print("checkModule diagnostics:\n{s}\n", .{rendered.written()});
    }
    try testing.expect(!diags.hasErrors());

    const module = try lowerModule(gpa, &ctx, &files, &checked, &rmodule);
    return .{ .module = module, .ctx = ctx };
}

test "lowers arithmetic and a direct call, verifier accepts it" {
    const gpa = testing.allocator;
    const src =
        \\function add(a: i64, b: i64): i64 { return a + b }
        \\function main(): i64 { return add(1, 2) }
        \\
    ;
    var out = try lowerSource(gpa, src);
    defer out.module.deinit();
    defer out.ctx.deinit();
    try ir.verify(gpa, &out.module);
    try testing.expectEqual(@as(usize, 2), out.module.funcs.items.len);
}

test "lowers if/else through a merge block" {
    const gpa = testing.allocator;
    const src =
        \\function abs(x: i64): i64 {
        \\  let r = x
        \\  if (x < 0) {
        \\    r = -x
        \\  } else {
        \\    r = x
        \\  }
        \\  return r
        \\}
        \\
    ;
    var out = try lowerSource(gpa, src);
    defer out.module.deinit();
    defer out.ctx.deinit();
    try ir.verify(gpa, &out.module);
}

test "lowers a while loop with a loop-carried variable" {
    const gpa = testing.allocator;
    const src =
        \\function sum(n: i64): i64 {
        \\  let total = 0
        \\  let i = 0
        \\  while (i < n) {
        \\    total += i
        \\    i++
        \\  }
        \\  return total
        \\}
        \\
    ;
    var out = try lowerSource(gpa, src);
    defer out.module.deinit();
    defer out.ctx.deinit();
    try ir.verify(gpa, &out.module);
}

test "lowers a for..of loop over a slice parameter" {
    const gpa = testing.allocator;
    const src =
        \\function total(xs: []i64): i64 {
        \\  let sum = 0
        \\  for x of xs {
        \\    sum += x
        \\  }
        \\  return sum
        \\}
        \\
    ;
    var out = try lowerSource(gpa, src);
    defer out.module.deinit();
    defer out.ctx.deinit();
    try ir.verify(gpa, &out.module);
}

test "lowers struct construction, field access, and a method call" {
    const gpa = testing.allocator;
    const src =
        \\struct Circle { r: f64 }
        \\function (c: Circle) area(): f64 { return c.r * c.r }
        \\function main(): f64 {
        \\  let c = Circle{r: 2.0}
        \\  return c.area()
        \\}
        \\
    ;
    var out = try lowerSource(gpa, src);
    defer out.module.deinit();
    defer out.ctx.deinit();
    try ir.verify(gpa, &out.module);
    try testing.expectEqual(@as(usize, 2), out.module.funcs.items.len);
}

test "monomorphizes a generic function per call-site instantiation" {
    const gpa = testing.allocator;
    const src =
        \\function identity<T>(x: T): T { return x }
        \\function main(): i64 {
        \\  let a = identity(1)
        \\  let b = identity(true)
        \\  if (b) { return a }
        \\  return 0
        \\}
        \\
    ;
    var out = try lowerSource(gpa, src);
    defer out.module.deinit();
    defer out.ctx.deinit();
    try ir.verify(gpa, &out.module);
    // main + 2 distinct instantiations of identity (i64, bool).
    try testing.expectEqual(@as(usize, 3), out.module.funcs.items.len);
}

test "lowers a closure that captures an outer variable" {
    const gpa = testing.allocator;
    const src =
        \\function main(): i64 {
        \\  let base = 10
        \\  let addBase = (x: i64) => x + base
        \\  return addBase(5)
        \\}
        \\
    ;
    var out = try lowerSource(gpa, src);
    defer out.module.deinit();
    defer out.ctx.deinit();
    try ir.verify(gpa, &out.module);
    try testing.expectEqual(@as(usize, 2), out.module.funcs.items.len); // main + the closure body
}

test "lowers defer to a LIFO call sequence before return" {
    const gpa = testing.allocator;
    const src =
        \\function noop(x: i64): i64 { return x }
        \\function main(): i64 {
        \\  defer noop(1)
        \\  defer noop(2)
        \\  return 0
        \\}
        \\
    ;
    var out = try lowerSource(gpa, src);
    defer out.module.deinit();
    defer out.ctx.deinit();
    try ir.verify(gpa, &out.module);
}

test "lowers string interpolation to a concat rt_call" {
    const gpa = testing.allocator;
    const src =
        \\function greet(name: string, age: i64): string {
        \\  return "hi ${name}, age ${age}"
        \\}
        \\
    ;
    var out = try lowerSource(gpa, src);
    defer out.module.deinit();
    defer out.ctx.deinit();
    try ir.verify(gpa, &out.module);
}

test "lowers channel construction, send, and receive" {
    const gpa = testing.allocator;
    const src =
        \\function main() {
        \\  let ch = chan<i64>(1)
        \\  ch <- 42
        \\  let v = <- ch
        \\  print("${v}")
        \\}
        \\
    ;
    var out = try lowerSource(gpa, src);
    defer out.module.deinit();
    defer out.ctx.deinit();
    try ir.verify(gpa, &out.module);
}

test "lowers a select with a recv case, a send case, and a default" {
    const gpa = testing.allocator;
    const src =
        \\function main() {
        \\  let a = chan<i64>(1)
        \\  let b = chan<i64>(1)
        \\  select {
        \\    case x = <- a:
        \\      print("${x}")
        \\    case b <- 1:
        \\      print("sent")
        \\    default:
        \\      print("idle")
        \\  }
        \\}
        \\
    ;
    var out = try lowerSource(gpa, src);
    defer out.module.deinit();
    defer out.ctx.deinit();
    try ir.verify(gpa, &out.module);
}

test "lowers a slice literal, append, indexed store, len, and reslice" {
    const gpa = testing.allocator;
    const src =
        \\function build(): i64 {
        \\  let xs = [1, 2, 3]
        \\  xs = append(xs, 4)
        \\  xs[0] = 9
        \\  let mid = xs[1:3]
        \\  return xs[0] + len(xs) + cap(xs) + mid[0]
        \\}
        \\
    ;
    var out = try lowerSource(gpa, src);
    defer out.module.deinit();
    defer out.ctx.deinit();
    try ir.verify(gpa, &out.module);
}

test "lowers a value switch with a multi-expression case and default" {
    const gpa = testing.allocator;
    const src =
        \\function classify(x: i64): i64 {
        \\  let r = 0
        \\  switch (x) {
        \\    case 1, 2: r = 10
        \\    case 3: r = 20
        \\    default: r = 30
        \\  }
        \\  return r
        \\}
        \\
    ;
    var out = try lowerSource(gpa, src);
    defer out.module.deinit();
    defer out.ctx.deinit();
    try ir.verify(gpa, &out.module);
}

test "lowers a switch whose every arm breaks (join reachable only via break)" {
    const gpa = testing.allocator;
    const src =
        \\function f(x: i64): i64 {
        \\  let r = 0
        \\  switch (x) {
        \\    case 1: {
        \\      r = 1
        \\      break
        \\    }
        \\    default: {
        \\      r = 2
        \\      break
        \\    }
        \\  }
        \\  return r
        \\}
        \\
    ;
    var out = try lowerSource(gpa, src);
    defer out.module.deinit();
    defer out.ctx.deinit();
    try ir.verify(gpa, &out.module);
}
