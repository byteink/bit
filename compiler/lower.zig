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
    // slice/array/map/tuple/chan/struct/interface/func: uniform boxed handle.
    // void/untyped_*/invalid/type_param/fallible must never reach here in a
    // fully checked, monomorphized program.
    return .{ .size = 8, .is_ptr = true };
}

fn alignUp(v: u32, a: u32) u32 {
    return (v + a - 1) / a * a;
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
        const fl = fieldLayout(ctx.typeOf(f.ty));
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

const CallTarget = union(enum) {
    direct: struct { func: ir.FuncId, result: TypeId },
    /// A struct method (static dispatch): `recv` is prepended to the user
    /// args as the callee's own leading parameter.
    direct_method: struct { func: ir.FuncId, recv: ir.ValueId, result: TypeId },
    iface: struct { recv: ir.ValueId, method_index: u32, result: TypeId },
    value: struct { callee: ir.ValueId, result: TypeId },
};

const MethodEntry = struct { ty: TypeId, name: []const u8, fid: ir.FuncId, result: TypeId };

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
    files: []const ModuleFile,
    checked: *const check.CheckedModule,
    rmodule: *const resolve.Module,
    out: ir.Module,
    /// Non-generic func_decl `GlobalSymbol.pack()` -> its `ir.FuncId`.
    func_ids: std.AutoHashMapUnmanaged(u64, ir.FuncId) = .{},
    /// Index into `ctx.instantiations` -> its lowered `ir.FuncId`.
    inst_ids: std.AutoHashMapUnmanaged(u32, ir.FuncId) = .{},
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

    fn structLayout(self: *Lowerer, ty: TypeId) Error!StructLayout {
        const key: u32 = @intFromEnum(ty);
        if (self.layouts.get(key)) |l| return l;
        const data = self.ctx.typeOf(ty);
        std.debug.assert(data == .@"struct");
        const l = try layoutFields(self.gpa, self.ctx, data.@"struct");
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
    fn lowerFunctionDecl(self: *Lowerer, file_idx: usize, decl: ast.Index, shape: check.FuncShape, gen_env: GenericEnv, name: []const u8) Error!ir.Function {
        const mf = self.files[file_idx];
        const k = mf.tree.kids(decl); // [recv_or_none, name, generics, params, result_or_none, body]

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
        if (param_nodes.len != shape.params.len) return error.UnsupportedConstruct; // variadic mismatch guard
        for (param_nodes, shape.params) |pn, pty| {
            const pk = mf.tree.kids(pn); // param: [name_ident, type]
            try param_types.append(self.gpa, pty);
            const p = try b.addParam(pty);
            try env.declare(self.gpa, identTextOf(mf, pk[0]), p, pty);
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

        var fc: FnCtx = .{ .l = self, .gpa = self.gpa, .ctx = self.ctx, .b = &b, .env = &env, .file_idx = file_idx, .gen_env = gen_env };
        if (is_fallible) {
            fc.fallible_ok = result_ty;
            fc.fallible_err = err_ty;
        }
        defer fc.deinit();

        try fc.lowerStmtList(k[5]);
        if (!fc.terminated) {
            // Falling off the end of a `()!` function is an ok-void return, so
            // clear the pending error before returning (§18: ok ⇒ slot null).
            try fc.runDefers();
            if (is_fallible) try fc.clearErr();
            try fc.emitRet(&.{});
        }
        b.endBlock();

        return b.finish(name, param_types.items, result_ty, is_fallible, err_ty, entry);
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

        var fc: FnCtx = .{ .l = self, .gpa = self.gpa, .ctx = self.ctx, .b = &b, .env = &env, .file_idx = file_idx, .gen_env = gen_env };
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
        try self.closure_funcs.append(self.gpa, f);
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
        try self.closure_funcs.append(self.gpa, f);
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
        .files = modules[0].files,
        .checked = modules[0].checked,
        .rmodule = modules[0].rmodule,
        .out = ir.Module.init(gpa, ctx),
    };
    errdefer l.out.deinit();
    defer l.func_ids.deinit(gpa);
    defer l.inst_ids.deinit(gpa);
    defer l.method_table.deinit(gpa);
    defer l.method_ids.deinit(gpa);
    defer {
        var it = l.layouts.valueIterator();
        while (it.next()) |lay| lay.deinit(gpa);
        l.layouts.deinit(gpa);
    }

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
    const base = direct_syms.items.len;
    for (0..ctx.instantiations.items.len) |i| {
        try l.inst_ids.put(gpa, @intCast(i), @enumFromInt(base + i));
    }

    // Pass A3: methods on concrete structs, across every module. They are not
    // module symbols (§10.4, resolve.zig keeps them out of the flat namespace so
    // different types can reuse a method name), so their signature comes from
    // the receiver's method set and they get `FuncId`s after the instantiations.
    // `l.method_table` maps (receiver type, name) -> that id.
    const MethodDecl = struct { module: ModuleId, file_idx: usize, decl: ast.Index, name: []const u8, ty: TypeId, shape: check.FuncShape };
    var method_decls: std.ArrayList(MethodDecl) = .empty;
    defer method_decls.deinit(gpa);
    const method_base = base + ctx.instantiations.items.len;
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
                try l.method_table.append(gpa, .{ .ty = recv_ty, .name = name, .fid = fid, .result = method.result });
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
        const nm = try moduleQualified(gpa, gsym.module, root, sym.name);
        defer gpa.free(nm);
        const f = try l.lowerFunction(gsym, &.{}, nm);
        try l.out.funcs.append(gpa, f);
    }
    for (ctx.instantiations.items, 0..) |inst, i| {
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
        return self.b.constNil(ty);
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
            .select_stmt => try self.lowerSelect(node),
            .block => try self.lowerBlockScoped(node),
            else => return error.UnsupportedConstruct, // for_in
        }
    }

    fn lowerLetConst(self: *FnCtx, node: ast.Index) Error!void {
        for (self.kids(node)) |bind| {
            const bk = self.kids(bind); // binding: [pattern, type_or_none, init_or_none]
            if (self.tree().get(bk[0]).tag != .ident) return error.UnsupportedConstruct; // tuple destructuring: deferred
            const ty = try self.nodeType(bk[0]);
            const val = if (bk[2] != ast.none) try self.lowerExprH(bk[2], ty) else try self.zeroValue(ty);
            try self.env.declare(self.gpa, self.identText(bk[0]), val, ty);
        }
    }

    fn resolveLvalue(self: *FnCtx, node: ast.Index) Error!Lvalue {
        switch (self.tree().get(node).tag) {
            .ident => {
                const idx = self.env.lookup(self.identText(node)) orelse return error.UnsupportedConstruct;
                return .{ .local = idx };
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
                const is_slice = self.ctx.typeOf(try self.nodeType(k[0])) == .slice;
                const recv_val = try self.lowerExpr(k[0]);
                const idx_val = try self.lowerExpr(k[1]);
                const elem_ty = try self.nodeType(node);
                return .{ .elem = .{ .recv = recv_val, .index = idx_val, .ty = elem_ty, .is_slice = is_slice } };
            },
            else => return error.UnsupportedConstruct,
        }
    }
    fn readLvalue(self: *FnCtx, lv: Lvalue) Error!ir.ValueId {
        return switch (lv) {
            .local => |i| self.env.bindings.items[i].value,
            .field => |f| self.b.fieldGet(f.ty, f.recv, f.offset),
            .elem => |e| if (e.is_slice)
                self.b.rtCall(e.ty, .slice_get, &.{ e.recv, e.index })
            else
                self.b.indexGet(e.ty, e.recv, e.index),
        };
    }
    fn writeLvalue(self: *FnCtx, lv: Lvalue, val: ir.ValueId) Error!void {
        switch (lv) {
            .local => |i| self.env.bindings.items[i].value = val,
            .field => |f| try self.b.fieldSet(f.recv, f.offset, val),
            .elem => |e| if (e.is_slice) {
                _ = try self.b.rtCall(self.ctx.void_id, .slice_set, &.{ e.recv, e.index, val });
            } else try self.b.indexSet(e.recv, e.index, val),
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
        // Plain `=`: resolve every lvalue and evaluate every rhs before any
        // write, so `a, b = b, a` swaps rather than aliasing.
        const lvs = try self.gpa.alloc(Lvalue, lhs_items.len);
        defer self.gpa.free(lvs);
        for (lhs_items, 0..) |ln, i| lvs[i] = try self.resolveLvalue(ln);
        const vals = try self.gpa.alloc(ir.ValueId, rhs_items.len);
        defer self.gpa.free(vals);
        for (rhs_items, 0..) |rn, i| vals[i] = try self.lowerExprH(rn, try self.nodeType(lhs_items[i]));
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
        if (self.tree().get(node).tag != .ident) return error.UnsupportedConstruct; // tuple binder: deferred
        try self.env.declare(self.gpa, self.identText(node), value, ty);
    }

    fn lowerReturn(self: *FnCtx, node: ast.Index) Error!void {
        const exprs = self.kids(node);
        const vals = try self.gpa.alloc(ir.ValueId, exprs.len);
        defer self.gpa.free(vals);
        for (exprs, 0..) |e, i| vals[i] = try self.lowerExpr(e);
        try self.runDefers();
        // A fallible function's ok return must leave the error slot null; clear
        // it after defers (a deferred fallible call may have set it — §18.5).
        if (self.fallible_err != .invalid) try self.clearErr();
        try self.emitRet(vals);
    }

    // ---- fallible-result error channel (SPEC §18) ---------------------------

    /// `err_set(e)` — record the pending error for the caller's `?`/`catch`.
    fn setErr(self: *FnCtx, val: ir.ValueId) Error!void {
        _ = try self.b.rtCall(self.ctx.void_id, .err_set, &.{val});
    }
    /// `err_set(nil)` — an ok return / handled `catch` clears the slot.
    fn clearErr(self: *FnCtx) Error!void {
        const nil = try self.b.constNil(self.ctx.error_id);
        try self.setErr(nil);
    }
    /// `err_get()` — read the pending error right after a fallible call.
    fn getErr(self: *FnCtx, err_ty: TypeId) Error!ir.ValueId {
        return self.b.rtCall(err_ty, .err_get, &.{});
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
        const okv = try self.lowerExpr(k[0]);
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
            const args = try self.catchEdgeArgs(err_vals, handled.?, is_void);
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
        if (data == .prim and data.prim == .string) return self.b.rtCall(bool_ty, .string_eq, &.{ a, b });
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
        const buf = try self.b.rtCall(i64ty, .select_alloc, &.{nconst});
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
        const fired = try self.b.rtCall(i64ty, .select, &.{ buf, nconst, hd });

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
        const elem_ty = switch (data) {
            .slice => |e| e,
            .array => |a| a.elem,
            else => return error.UnsupportedConstruct,
        };
        const i64ty = self.ctx.prim_ids.get(.i64);
        const outer_mark = self.env.mark();
        // Carry the iterable as a hidden binding so it threads through the loop's
        // block params alongside `$idx`; reading the pre-header `iter_val` inside
        // the body is a stale SSA value once the header rebinds every carried
        // local to a block param.
        try self.env.declare(self.gpa, "$iter", iter_val, iter_ty);
        const zero = try self.b.constInt(i64ty, 0);
        try self.env.declare(self.gpa, "$idx", zero, i64ty);
        const pre_len = self.env.bindings.items.len;
        const idx_slot = pre_len - 1;
        const iter_slot = pre_len - 2;

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

        const idx_val = self.env.bindings.items[idx_slot].value;
        const iter_cur = self.env.bindings.items[iter_slot].value;
        const len_val = if (data == .array)
            try self.b.constInt(i64ty, @intCast(data.array.len))
        else
            try self.b.sliceLen(i64ty, iter_cur);
        const cmp = try self.b.binary(.icmp_slt, self.ctx.prim_ids.get(.bool), idx_val, len_val);
        {
            // `body_blk` is dominated by `header` and reached only here, so it
            // takes no params (see `lowerWhile`); `exit_blk` merges this edge
            // with every `break`, so it receives the carried values.
            const cur = try self.env.snapshotValues(self.gpa, pre_len);
            defer self.gpa.free(cur);
            try self.emitBr(cmp, body_blk, &.{}, exit_blk, cur);
        }

        try self.loop_stack.append(self.gpa, .{ .exit = exit_blk, .cont = header, .pre_len = pre_len });
        self.switchBlock(body_blk);
        const elem_val = if (data == .slice)
            try self.b.rtCall(elem_ty, .slice_get, &.{ iter_cur, idx_val })
        else
            try self.b.indexGet(elem_ty, iter_cur, idx_val);
        const body_mark = self.env.mark();
        try self.declareBinder(k[0], elem_val, elem_ty);
        try self.lowerStmtList(k[2]);
        self.env.restoreCount(body_mark);
        _ = self.loop_stack.pop();
        if (!self.terminated) {
            const one = try self.b.constInt(i64ty, 1);
            const next_idx = try self.b.binary(.add, i64ty, self.env.bindings.items[idx_slot].value, one);
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
            return .{ .direct = .{ .func = fid, .result = shape.result } };
        }

        const callee_tag = self.tree().get(callee).tag;
        if (callee_tag == .ident and self.env.lookup(self.identText(callee)) == null) {
            if (self.nodeSymbol(callee)) |gsym| {
                const sym = self.l.symbolOf(gsym);
                if (sym.kind == .func) {
                    const fid = self.l.func_ids.get(gsym.pack()) orelse return error.UnsupportedConstruct;
                    const shape = self.ctx.func_sigs.get(gsym.pack()).?;
                    return .{ .direct = .{ .func = fid, .result = shape.result } };
                }
            }
        }

        if (callee_tag == .member) {
            const k = self.kids(callee); // [recv, name]
            const recv_ty = try self.nodeType(k[0]);
            const name = self.identText(k[1]);
            const data = self.ctx.typeOf(recv_ty);
            if (data == .interface) {
                for (data.interface) |m| {
                    if (!std.mem.eql(u8, m.name, name)) continue;
                    const recv_val = try self.lowerExpr(k[0]);
                    return .{ .iface = .{ .recv = recv_val, .method_index = try self.l.methodId(m.name), .result = m.result } };
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
                    return .{ .value = .{ .callee = fv, .result = fshape.result } };
                }
                if (self.l.lookupMethod(recv_ty, name)) |entry| {
                    const recv_val = try self.lowerExpr(k[0]);
                    return .{ .direct_method = .{ .func = entry.fid, .recv = recv_val, .result = entry.result } };
                }
            }
            return error.UnsupportedConstruct;
        }

        const callee_val = try self.lowerExpr(callee);
        const callee_ty = try self.nodeType(callee);
        const shape = self.ctx.typeOf(callee_ty).func;
        return .{ .value = .{ .callee = callee_val, .result = shape.result } };
    }

    fn lowerArgs(self: *FnCtx, args_node: ast.Index) Error![]ir.ValueId {
        const arg_nodes = self.kids(args_node);
        const vals = try self.gpa.alloc(ir.ValueId, arg_nodes.len);
        errdefer self.gpa.free(vals);
        for (arg_nodes, 0..) |an, i| {
            if (self.tree().get(an).tag != .arg) return error.UnsupportedConstruct; // arg_spread: deferred
            vals[i] = try self.lowerExpr(self.kids(an)[0]);
        }
        return vals;
    }

    fn lowerBuiltinCall(self: *FnCtx, node: ast.Index, name: []const u8) Error!ir.ValueId {
        const args_node = self.kids(node)[2];
        const arg_nodes = self.kids(args_node);
        const void_ty = self.ctx.void_id;
        if (std.mem.eql(u8, name, "panic")) {
            const v = try self.lowerExpr(self.kids(arg_nodes[0])[0]);
            _ = try self.b.rtCall(void_ty, .panic, &.{v});
            try self.emitUnreachable();
            return self.b.constNil(void_ty);
        }
        if (std.mem.eql(u8, name, "print")) {
            const v = try self.lowerExpr(self.kids(arg_nodes[0])[0]);
            return self.b.rtCall(void_ty, .print, &.{v});
        }
        if (std.mem.eql(u8, name, "assert")) {
            const vals = try self.lowerArgs(args_node);
            defer self.gpa.free(vals);
            return self.b.rtCall(void_ty, .assert, vals);
        }
        if (std.mem.eql(u8, name, "len") or std.mem.eql(u8, name, "cap")) {
            const is_cap = std.mem.eql(u8, name, "cap");
            const arg = self.kids(arg_nodes[0])[0];
            const arg_ty = try self.nodeType(arg);
            const i64ty = self.ctx.prim_ids.get(.i64);
            const data = self.ctx.typeOf(arg_ty);
            if (data == .array) return self.b.constInt(i64ty, @intCast(data.array.len)); // len == cap
            const v = try self.lowerExpr(arg);
            // Slice header is `{buf, len, off, cap, is_ref}`: `len` at +8
            // (`slice_len`, shared with `string`), `cap` at +24. `cap` is
            // slice-only.
            if (data == .slice) return if (is_cap) self.b.fieldGet(i64ty, v, 24) else self.b.sliceLen(i64ty, v);
            if (!is_cap and data == .prim and data.prim == .string) return self.b.sliceLen(i64ty, v);
            return error.UnsupportedConstruct;
        }
        if (std.mem.eql(u8, name, "append")) return self.lowerAppend(node);
        // Filesystem primitives (ABI.md §14): each maps 1:1 to a runtime call,
        // result typed by the checker (i64 fd/count or a fresh string).
        const fs_rt: ?ir.RtFn = if (std.mem.eql(u8, name, "fsOpen"))
            .fs_open
        else if (std.mem.eql(u8, name, "fsReadAll"))
            .fs_read_all
        else if (std.mem.eql(u8, name, "fsWrite"))
            .fs_write
        else if (std.mem.eql(u8, name, "fsClose"))
            .fs_close
        else
            null;
        if (fs_rt) |rt| {
            const vals = try self.lowerArgs(args_node);
            defer self.gpa.free(vals);
            return self.b.rtCall(try self.nodeType(node), rt, vals);
        }
        if (std.mem.eql(u8, name, "fsqrt")) {
            const v = try self.lowerExpr(self.kids(arg_nodes[0])[0]);
            return self.b.rtCall(try self.nodeType(node), .sqrt, &.{v});
        }
        return error.UnsupportedConstruct; // delete/close: deferred
    }

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
            acc = try self.b.rtCall(slice_ty, .slice_append, &.{ acc, v });
        }
        return acc;
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
        return self.b.rtCall(chan_ty, .chan_make, &.{ cap, is_ref });
    }

    /// `[]T(n)` / `[]T(n, m)`: allocate a length-`n`, capacity-`m` (default `n`)
    /// slice, elements zeroed (SPEC §11). Reuses `slice_new`.
    fn lowerSliceCtor(self: *FnCtx, node: ast.Index) Error!ir.ValueId {
        const k = self.kids(node); // [callee, type_args, args]
        const slice_ty = try self.nodeType(node);
        const elem_ty = self.ctx.typeOf(slice_ty).slice;
        const i64ty = self.ctx.prim_ids.get(.i64);
        const arg_nodes = self.kids(k[2]);
        const len = try self.lowerExprH(self.kids(arg_nodes[0])[0], i64ty);
        const cap = if (arg_nodes.len >= 2) try self.lowerExprH(self.kids(arg_nodes[1])[0], i64ty) else len;
        const is_ref = try self.b.constInt(i64ty, if (self.elemIsRef(elem_ty)) 1 else 0);
        return self.b.rtCall(slice_ty, .slice_new, &.{ len, cap, is_ref });
    }

    fn lowerCall(self: *FnCtx, node: ast.Index) Error!ir.ValueId {
        const k = self.kids(node); // [callee, type_args_or_none, args]
        const callee = k[0];
        if (self.tree().get(callee).tag == .slice_type) return self.lowerSliceCtor(node);
        if (self.tree().get(callee).tag == .chan_type) return self.lowerChanMake(node);
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
        const target = try self.resolveCallTarget(node, callee);
        var args: std.ArrayList(ir.ValueId) = .empty;
        defer args.deinit(self.gpa);
        if (target == .direct_method) try args.append(self.gpa, target.direct_method.recv);
        for (self.kids(k[2])) |an| {
            if (self.tree().get(an).tag != .arg) return error.UnsupportedConstruct;
            try args.append(self.gpa, try self.lowerExpr(self.kids(an)[0]));
        }
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
        return self.b.convert(dst_ty, src);
    }

    /// `ch <- v`: send one word to a channel (blocks per SPEC §16.2).
    fn lowerSend(self: *FnCtx, node: ast.Index) Error!void {
        const k = self.kids(node); // [chan_expr, value_expr]
        const chan_ty = try self.nodeType(k[0]);
        const elem_ty = self.ctx.typeOf(chan_ty).chan;
        const ch = try self.lowerExpr(k[0]);
        const v = try self.lowerExprH(k[1], elem_ty);
        _ = try self.b.rtCall(self.ctx.void_id, .chan_send, &.{ ch, v });
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
        const fty = try self.nodeType(k[0]);

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
        const shape = self.ctx.typeOf(fty).func;
        const arg_nodes = self.kids(k[2]);
        if (arg_nodes.len != shape.params.len) return error.UnsupportedConstruct; // variadic spawn out of scope
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
        _ = try self.b.rtCall(self.ctx.void_id, .spawn, &.{ tramp_addr, thunk });
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
        for (self.kids(k[2])) |an| {
            if (self.tree().get(an).tag != .arg) {
                args.deinit(self.gpa);
                return error.UnsupportedConstruct;
            }
            try args.append(self.gpa, try self.lowerExpr(self.kids(an)[0]));
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

    /// Records a deferred `print`/`assert`. `panic` is excluded (it terminates
    /// control flow — deferring it is meaningless); value-returning builtins
    /// (`len`/`cap`/`append`) have no side effect worth deferring.
    fn lowerDeferBuiltin(self: *FnCtx, call_node: ast.Index, name: []const u8) Error!void {
        const rt: ir.RtFn = if (std.mem.eql(u8, name, "print"))
            .print
        else if (std.mem.eql(u8, name, "assert"))
            .assert
        else
            return error.UnsupportedConstruct;
        const args = try self.lowerArgs(self.kids(call_node)[2]);
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
                .builtin => |x| _ = try self.b.rtCall(x.result, x.rt, x.args),
            }
        }
    }

    // ---- expressions ------------------------------------------------------

    fn lowerExpr(self: *FnCtx, node: ast.Index) Error!ir.ValueId {
        return self.lowerExprH(node, null);
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
                    break :blk self.b.rtCall(ty, .slice_get, &.{ recv, idxv });
                if (recv_data == .prim and recv_data.prim == .string)
                    break :blk self.b.rtCall(ty, .string_byte, &.{ recv, idxv });
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
            else => error.UnsupportedConstruct, // type_assert/tuple_index/map literals
        };
    }

    fn lowerIdent(self: *FnCtx, node: ast.Index) Error!ir.ValueId {
        const name = self.identText(node);
        if (self.env.lookup(name)) |idx| return self.env.bindings.items[idx].value;
        const gsym = self.nodeSymbol(node) orelse return error.UnsupportedConstruct;
        const sym = self.l.symbolOf(gsym);
        if (sym.kind != .const_binding) return error.UnsupportedConstruct; // top-level mutable `let`: no IR global-variable op exists yet
        return self.lowerTopConst(gsym, sym.file_idx);
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
        if (cdata == .prim and cdata.prim == .string and (op == .eq_eq or op == .bang_eq or op == .plus)) {
            const sl = try self.lowerExprH(k[0], common);
            const sr = try self.lowerExprH(k[1], common);
            if (op == .plus) return self.b.rtCall(common, .string_concat, &.{ sl, sr });
            const bool_ty = self.ctx.prim_ids.get(.bool);
            const eq = try self.b.rtCall(bool_ty, .string_eq, &.{ sl, sr });
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
            return self.b.rtCall(elem_ty, .chan_recv, &.{ch});
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

    fn lowerMember(self: *FnCtx, node: ast.Index) Error!ir.ValueId {
        const k = self.kids(node); // [recv, name]
        const recv_ty = try self.nodeType(k[0]);
        const data = self.ctx.typeOf(recv_ty);
        const name = self.identText(k[1]);
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
        return error.UnsupportedConstruct; // interface method value (not called immediately): deferred
    }

    /// True when a value of `ty` is a single-word GC reference (mirrors
    /// `codegen/common.isRefType`): recorded in a slice header so #1106 can
    /// scan the element buffer. Value-typed elements wider than a word are
    /// boxed, so their word is a reference too.
    fn elemIsRef(self: *const FnCtx, ty: TypeId) bool {
        return switch (self.ctx.typeOf(ty)) {
            .prim => |p| p == .string,
            .void, .untyped_int, .untyped_float, .untyped_rune, .untyped_bool, .untyped_string, .untyped_nil, .invalid, .type_param, .fallible => false,
            else => true, // slice/array/map/tuple/chan/struct/interface/func
        };
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
        const s = try self.b.rtCall(slice_ty, .slice_new, &.{ len, len, is_ref });
        for (items, 0..) |a, i| {
            const inner = self.kids(a)[0];
            const v = try self.lowerExprH(inner, elem_ty);
            const idx = try self.b.constInt(i64ty, @intCast(i));
            _ = try self.b.rtCall(self.ctx.void_id, .slice_set, &.{ s, idx, v });
        }
        return s;
    }

    /// `s[lo:hi]` (SPEC §12.6): a new `[]T` view sharing `s`'s buffer. `lo`
    /// defaults to 0, `hi` to `len(s)`. Only a slice base is supported here;
    /// re-slicing a `[N]T` array or a `string` is deferred (#1147).
    fn lowerSliceExpr(self: *FnCtx, node: ast.Index) Error!ir.ValueId {
        const k = self.kids(node); // [recv, lo_or_none, hi_or_none]
        const recv_ty = try self.nodeType(k[0]);
        if (self.ctx.typeOf(recv_ty) != .slice) return error.UnsupportedConstruct;
        const i64ty = self.ctx.prim_ids.get(.i64);
        const recv = try self.lowerExpr(k[0]);
        const lo = if (k[1] != ast.none) try self.lowerExprH(k[1], i64ty) else try self.b.constInt(i64ty, 0);
        const hi = if (k[2] != ast.none) try self.lowerExprH(k[2], i64ty) else try self.b.sliceLen(i64ty, recv);
        return self.b.rtCall(try self.nodeType(node), .slice_slice, &.{ recv, lo, hi });
    }

    fn lowerCompositeLit(self: *FnCtx, node: ast.Index) Error!ir.ValueId {
        const k = self.kids(node); // [type, init]
        const ty = try self.nodeType(node);
        const data = self.ctx.typeOf(ty);
        if (data == .slice) return self.lowerSliceElems(ty, self.kids(k[1])); // []T{...}
        if (data != .@"struct") return error.UnsupportedConstruct; // map literals: deferred
        const init_node = k[1];
        if (self.tree().get(init_node).tag != .field_inits) return error.UnsupportedConstruct;
        const layout = try self.l.structLayout(ty);
        const obj = try self.b.gcAlloc(ty, layout.size, layout.ptr_offsets);
        for (self.kids(init_node)) |fi| {
            const fk = self.kids(fi); // field_init: [name_ident, expr]
            const name = self.identText(fk[0]);
            const val = try self.lowerExpr(fk[1]);
            var found = false;
            for (data.@"struct", 0..) |f, i| {
                if (!std.mem.eql(u8, f.name, name)) continue;
                try self.b.fieldSet(obj, layout.field_offsets[i], val);
                found = true;
            }
            if (!found) return error.UnsupportedConstruct;
        }
        return obj;
    }

    fn lowerToString(self: *FnCtx, v: ir.ValueId, ty: TypeId) Error!ir.ValueId {
        const string_ty = self.ctx.prim_ids.get(.string);
        const data = self.ctx.typeOf(ty);
        if (data == .prim) {
            return switch (data.prim) {
                .string => v,
                .bool => self.b.rtCall(string_ty, .string_from_bool, &.{v}),
                .f32, .f64 => self.b.rtCall(string_ty, .string_from_float, &.{v}),
                else => self.b.rtCall(string_ty, .string_from_int, &.{v}),
            };
        }
        if (self.l.lookupMethod(ty, "show")) |entry| {
            return self.b.call(string_ty, entry.fid, &.{v});
        }
        if (data == .interface) {
            for (data.interface) |m| {
                if (std.mem.eql(u8, m.name, "show")) return self.b.callIface(string_ty, v, try self.l.methodId(m.name), &.{});
            }
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
        for (vals[1..]) |v| acc = try self.b.rtCall(string_ty, .string_concat, &.{ acc, v });
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
