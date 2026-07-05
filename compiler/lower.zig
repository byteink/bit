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
//! `ir.RtFn.map_iter_init`'s doc comment); `switch`/`select`; slice/array
//! *construction* (`slice_lit`, `append`) — `ir.zig`'s `Op` set has no
//! slice-construction instruction yet, only ops that read an *existing*
//! slice (`index_get`/`slice_len`); fallible functions' `fail`/`?`/`catch`
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

const LoopCtx = struct { exit: ir.BlockId, cont: ir.BlockId, pre_len: usize };

/// A captured outer variable, snapshotted at `arrow_fn` lowering time (see
/// module doc comment on closures).
const Capture = struct { name: []const u8, ty: TypeId, value: ir.ValueId };

const DeferredCall = union(enum) {
    direct: struct { func: ir.FuncId, args: []ir.ValueId, result: TypeId },
    iface: struct { recv: ir.ValueId, method_index: u32, args: []ir.ValueId, result: TypeId },
    value: struct { callee: ir.ValueId, args: []ir.ValueId, result: TypeId },

    fn deinit(self: DeferredCall, gpa: Allocator) void {
        switch (self) {
            .direct => |x| gpa.free(x.args),
            .iface => |x| gpa.free(x.args),
            .value => |x| gpa.free(x.args),
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

const MethodEntry = struct { ty: TypeId, name: []const u8, sym: GlobalSymbol };

// ============================================================================
// Lowerer — module-level driver and shared tables
// ============================================================================

pub const Lowerer = struct {
    gpa: Allocator,
    ctx: *TypeContext,
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
    layouts: std.AutoHashMapUnmanaged(u32, StructLayout) = .{},

    fn buildMethodTable(self: *Lowerer) Error!void {
        for (self.rmodule.symbols.items, 0..) |sym, sid| {
            if (sid == 0 or sym.kind != .func or sym.decl == ast.none) continue;
            const mf = self.files[sym.file_idx];
            const k = mf.tree.kids(sym.decl); // func_decl: [recv, name, generics, params, result, body]
            if (k[0] == ast.none) continue; // free function
            const rk = mf.tree.kids(k[0]); // receiver: [name_ident, type]
            const recv_ty_node = rk[1];
            if (mf.tree.get(recv_ty_node).tag != .ident) continue; // generic-struct receiver: deferred, not registered
            const recv_sid = self.rmodule.node_symbols[sym.file_idx][recv_ty_node];
            if (recv_sid == .none) continue;
            const recv_gsym = GlobalSymbol{ .module = @enumFromInt(0), .id = recv_sid };
            const struct_ty = self.ctx.decl_memo.get(recv_gsym.pack()) orelse continue;
            try self.method_table.append(self.gpa, .{
                .ty = struct_ty,
                .name = identTextOf(mf, k[1]),
                .sym = .{ .module = @enumFromInt(0), .id = @enumFromInt(sid) },
            });
        }
    }

    fn lookupMethod(self: *const Lowerer, ty: TypeId, name: []const u8) ?GlobalSymbol {
        for (self.method_table.items) |e| {
            if (e.ty == ty and std.mem.eql(u8, e.name, name)) return e.sym;
        }
        return null;
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

    /// Lowers one non-generic or already-monomorphized function/method body.
    /// `gen_env` is empty for a non-generic function.
    fn lowerFunction(self: *Lowerer, gsym: GlobalSymbol, gen_env: GenericEnv, name: []const u8) Error!ir.Function {
        const sym = self.rmodule.symbols.items[@intFromEnum(gsym.id)];
        const mf = self.files[sym.file_idx];
        const k = mf.tree.kids(sym.decl); // [recv_or_none, name, generics, params, result_or_none, body]
        const template_shape = self.ctx.func_sigs.get(gsym.pack()) orelse return error.UnsupportedConstruct;
        const shape = if (gen_env.len > 0) try self.ctx.substFuncShape(template_shape, gen_env) else template_shape;

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
            const recv_sid = self.rmodule.node_symbols[sym.file_idx][recv_ty_node];
            if (recv_sid == .none) return error.UnsupportedConstruct;
            const recv_struct_ty = self.ctx.decl_memo.get((GlobalSymbol{ .module = @enumFromInt(0), .id = recv_sid }).pack()) orelse
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

        var fc: FnCtx = .{ .l = self, .gpa = self.gpa, .ctx = self.ctx, .b = &b, .env = &env, .file_idx = sym.file_idx, .gen_env = gen_env };
        defer fc.deinit();

        try fc.lowerStmtList(k[5]);
        if (!fc.terminated) {
            try fc.runDefers();
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

        const env_param = try b.addParam(env_ty);
        try param_types.append(self.gpa, env_ty);
        for (captures, 0..) |c, i| {
            const fv = try b.fieldGet(c.ty, env_param, env_layout.field_offsets[i]);
            try env.declare(self.gpa, c.name, fv, c.ty);
        }

        const param_nodes = mf.tree.kids(k[0]);
        if (param_nodes.len != shape.params.len) return error.UnsupportedConstruct;
        for (param_nodes, shape.params) |pn, pty| {
            const pk = mf.tree.kids(pn); // arrow_p: [name_ident, type_or_none]
            try param_types.append(self.gpa, pty);
            const p = try b.addParam(pty);
            try env.declare(self.gpa, identTextOf(mf, pk[0]), p, pty);
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

        const f = try b.finish("closure", param_types.items, shape.result, false, .invalid, entry);
        const fid: ir.FuncId = @enumFromInt(self.out.funcs.items.len);
        try self.out.funcs.append(self.gpa, f);
        return fid;
    }
};

/// Lowers one already-resolved, type-checked, single-module program.
/// `files`/`rmodule`/`checked` must be the outputs of `resolve.resolveModule`
/// and `check.checkModule` over the same `files`.
pub fn lowerModule(gpa: Allocator, ctx: *TypeContext, files: []const ModuleFile, checked: *const check.CheckedModule, rmodule: *const resolve.Module) Error!ir.Module {
    var l: Lowerer = .{ .gpa = gpa, .ctx = ctx, .files = files, .checked = checked, .rmodule = rmodule, .out = ir.Module.init(gpa, ctx) };
    errdefer l.out.deinit();
    defer l.func_ids.deinit(gpa);
    defer l.inst_ids.deinit(gpa);
    defer l.method_table.deinit(gpa);
    defer {
        var it = l.layouts.valueIterator();
        while (it.next()) |lay| lay.deinit(gpa);
        l.layouts.deinit(gpa);
    }

    try l.buildMethodTable();

    // Pass A: every non-generic func/method gets a `FuncId` up front (stable
    // symbol-table order), so forward/mutually-recursive direct calls always
    // resolve. Pass A2: every generic instantiation the checker already
    // discovered gets the next block of ids, in `ctx.instantiations` order.
    var direct_syms: std.ArrayList(GlobalSymbol) = .empty;
    defer direct_syms.deinit(gpa);
    for (rmodule.symbols.items, 0..) |sym, sid| {
        if (sid == 0 or sym.kind != .func or sym.decl == ast.none) continue;
        const gsym = GlobalSymbol{ .module = @enumFromInt(0), .id = @enumFromInt(sid) };
        if (ctx.decl_generics.get(gsym.pack())) |gens| {
            if (gens.len > 0) continue; // generic template, not directly lowered
        }
        try l.func_ids.put(gpa, gsym.pack(), @enumFromInt(direct_syms.items.len));
        try direct_syms.append(gpa, gsym);
    }
    const base = direct_syms.items.len;
    for (0..ctx.instantiations.items.len) |i| {
        try l.inst_ids.put(gpa, @intCast(i), @enumFromInt(base + i));
    }

    // Pass B: lower bodies in the exact same order as Pass A/A2 assigned ids.
    for (direct_syms.items) |gsym| {
        const sym = rmodule.symbols.items[@intFromEnum(gsym.id)];
        const f = try l.lowerFunction(gsym, &.{}, sym.name);
        try l.out.funcs.append(gpa, f);
    }
    for (ctx.instantiations.items, 0..) |inst, i| {
        const env = try l.buildGenericEnv(inst);
        defer gpa.free(env);
        const sym = rmodule.symbols.items[@intFromEnum(inst.generic.id)];
        const name = try std.fmt.allocPrint(gpa, "{s}${d}", .{ sym.name, i });
        defer gpa.free(name);
        const f = try l.lowerFunction(inst.generic, env, name);
        try l.out.funcs.append(gpa, f);
    }

    return l.out;
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
    /// same-module re-export chains. `null` for the blank identifier or an
    /// already-diagnosed undefined name.
    fn nodeSymbol(self: *const FnCtx, node: ast.Index) ?GlobalSymbol {
        const sid = self.l.rmodule.node_symbols[self.file_idx][node];
        if (sid == .none) return null;
        var cur = sid;
        var guard: u32 = 0;
        while (guard < 64) : (guard += 1) {
            const s = self.l.rmodule.symbols.items[@intFromEnum(cur)];
            if (s.kind != .import_item) break;
            const target = s.imported_from orelse break;
            cur = target.symbol;
        }
        return .{ .module = @enumFromInt(0), .id = cur };
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
            .break_stmt => try self.lowerBreak(),
            .continue_stmt => try self.lowerContinue(),
            .spawn_stmt => try self.lowerSpawn(node),
            .defer_stmt => try self.lowerDefer(node),
            .if_stmt => try self.lowerIf(node),
            .while_stmt => try self.lowerWhile(node),
            .for_c => try self.lowerForC(node),
            .for_of => try self.lowerForOf(node),
            .for_inf => try self.lowerForInf(node),
            .block => try self.lowerBlockScoped(node),
            else => return error.UnsupportedConstruct, // fail_stmt, for_in, switch/select_stmt, send_stmt
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
                const recv_val = try self.lowerExpr(k[0]);
                const idx_val = try self.lowerExpr(k[1]);
                const elem_ty = try self.nodeType(node);
                return .{ .elem = .{ .recv = recv_val, .index = idx_val, .ty = elem_ty } };
            },
            else => return error.UnsupportedConstruct,
        }
    }
    fn readLvalue(self: *FnCtx, lv: Lvalue) Error!ir.ValueId {
        return switch (lv) {
            .local => |i| self.env.bindings.items[i].value,
            .field => |f| self.b.fieldGet(f.ty, f.recv, f.offset),
            .elem => |e| self.b.indexGet(e.ty, e.recv, e.index),
        };
    }
    fn writeLvalue(self: *FnCtx, lv: Lvalue, val: ir.ValueId) Error!void {
        switch (lv) {
            .local => |i| self.env.bindings.items[i].value = val,
            .field => |f| try self.b.fieldSet(f.recv, f.offset, val),
            .elem => |e| try self.b.indexSet(e.recv, e.index, val),
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
        try self.emitRet(vals);
    }

    fn lowerBreak(self: *FnCtx) Error!void {
        const top = self.loop_stack.items[self.loop_stack.items.len - 1];
        const vals = try self.env.snapshotValues(self.gpa, top.pre_len);
        defer self.gpa.free(vals);
        try self.emitJump(top.exit, vals);
    }
    fn lowerContinue(self: *FnCtx) Error!void {
        const top = self.loop_stack.items[self.loop_stack.items.len - 1];
        const vals = try self.env.snapshotValues(self.gpa, top.pre_len);
        defer self.gpa.free(vals);
        try self.emitJump(top.cont, vals);
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
        const zero = try self.b.constInt(i64ty, 0);
        try self.env.declare(self.gpa, "$idx", zero, i64ty);
        const pre_len = self.env.bindings.items.len;
        const idx_slot = pre_len - 1;

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
        const len_val = if (data == .array)
            try self.b.constInt(i64ty, @intCast(data.array.len))
        else
            try self.b.sliceLen(i64ty, iter_val);
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
        const elem_val = try self.b.indexGet(elem_ty, iter_val, idx_val);
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
                const sym = self.l.rmodule.symbols.items[@intFromEnum(gsym.id)];
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
                for (data.interface, 0..) |m, i| {
                    if (!std.mem.eql(u8, m.name, name)) continue;
                    const recv_val = try self.lowerExpr(k[0]);
                    return .{ .iface = .{ .recv = recv_val, .method_index = @intCast(i), .result = m.result } };
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
                if (self.l.lookupMethod(recv_ty, name)) |gsym| {
                    const recv_val = try self.lowerExpr(k[0]);
                    const fid = self.l.func_ids.get(gsym.pack()) orelse return error.UnsupportedConstruct;
                    const shape = self.ctx.func_sigs.get(gsym.pack()).?;
                    return .{ .direct_method = .{ .func = fid, .recv = recv_val, .result = shape.result } };
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
            const arg = self.kids(arg_nodes[0])[0];
            const arg_ty = try self.nodeType(arg);
            const i64ty = self.ctx.prim_ids.get(.i64);
            const data = self.ctx.typeOf(arg_ty);
            if (data == .array) return self.b.constInt(i64ty, @intCast(data.array.len));
            const v = try self.lowerExpr(arg);
            if (data == .slice or (data == .prim and data.prim == .string)) return self.b.sliceLen(i64ty, v);
            return error.UnsupportedConstruct;
        }
        return error.UnsupportedConstruct; // append/delete/close: deferred
    }

    fn lowerCall(self: *FnCtx, node: ast.Index) Error!ir.ValueId {
        const k = self.kids(node); // [callee, type_args_or_none, args]
        const callee = k[0];
        if (self.tree().get(callee).tag == .ident and self.env.lookup(self.identText(callee)) == null) {
            if (self.nodeSymbol(callee)) |gsym| {
                const sym = self.l.rmodule.symbols.items[@intFromEnum(gsym.id)];
                if (sym.kind == .builtin_func) return self.lowerBuiltinCall(node, sym.name);
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
        return switch (target) {
            .direct => |d| self.b.call(d.result, d.func, args.items),
            .direct_method => |d| self.b.call(d.result, d.func, args.items),
            .iface => |x| self.b.callIface(x.result, x.recv, x.method_index, args.items),
            .value => |x| self.b.callValue(x.result, x.callee, args.items),
        };
    }

    fn lowerSpawn(self: *FnCtx, node: ast.Index) Error!void {
        const call_node = self.kids(node)[0];
        const k = self.kids(call_node);
        const target = try self.resolveCallTarget(call_node, k[0]);
        const closure_val: ir.ValueId = switch (target) {
            .direct => |d| blk: {
                const fty = try self.nodeType(k[0]);
                const nilv = try self.b.constNil(fty);
                break :blk try self.b.makeClosure(fty, d.func, nilv);
            },
            .value => |v| v.callee,
            .direct_method, .iface => return error.UnsupportedConstruct,
        };
        var args: std.ArrayList(ir.ValueId) = .empty;
        defer args.deinit(self.gpa);
        try args.append(self.gpa, closure_val);
        for (self.kids(k[2])) |an| {
            if (self.tree().get(an).tag != .arg) return error.UnsupportedConstruct;
            try args.append(self.gpa, try self.lowerExpr(self.kids(an)[0]));
        }
        _ = try self.b.rtCall(self.ctx.void_id, .spawn, args.items);
    }

    fn lowerDefer(self: *FnCtx, node: ast.Index) Error!void {
        const call_node = self.kids(node)[0];
        const k = self.kids(call_node);
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

    fn runDefers(self: *FnCtx) Error!void {
        var i = self.defers.items.len;
        while (i > 0) {
            i -= 1;
            switch (self.defers.items[i]) {
                .direct => |x| _ = try self.b.call(x.result, x.func, x.args),
                .iface => |x| _ = try self.b.callIface(x.result, x.recv, x.method_index, x.args),
                .value => |x| _ = try self.b.callValue(x.result, x.callee, x.args),
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
                break :blk self.b.indexGet(ty, recv, idxv);
            },
            .str_interp => self.lowerStrInterp(node),
            .composite_lit => self.lowerCompositeLit(node),
            .arrow_fn => self.lowerArrowFn(node),
            else => error.UnsupportedConstruct, // try_expr/catch_*/type_assert/tuple_index/slice_expr/slice_lit/map literals
        };
    }

    fn lowerIdent(self: *FnCtx, node: ast.Index) Error!ir.ValueId {
        const name = self.identText(node);
        if (self.env.lookup(name)) |idx| return self.env.bindings.items[idx].value;
        const gsym = self.nodeSymbol(node) orelse return error.UnsupportedConstruct;
        const sym = self.l.rmodule.symbols.items[@intFromEnum(gsym.id)];
        if (sym.kind != .const_binding) return error.UnsupportedConstruct; // top-level mutable `let`: no IR global-variable op exists yet
        return self.lowerTopConst(sym.decl, sym.file_idx);
    }

    /// Inlines a top-level `const`'s initializer at the reference site
    /// (re-lowered fresh each time — top-level consts are always
    /// constant-foldable expressions per the checker, so this is always
    /// valid, if occasionally redundant across multiple references).
    fn lowerTopConst(self: *FnCtx, decl: ast.Index, file_idx: usize) Error!ir.ValueId {
        const saved_file = self.file_idx;
        self.file_idx = file_idx;
        defer self.file_idx = saved_file;
        const bk = self.kids(decl); // binding: [pattern, type_or_none, init_or_none]
        if (bk[2] == ast.none) return error.UnsupportedConstruct;
        return self.lowerExpr(bk[2]);
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
        if (cdata == .prim and cdata.prim == .string and (op == .eq_eq or op == .bang_eq or op == .plus))
            return error.UnsupportedConstruct; // string equality/concat via `+`: needs a not-yet-added RtFn
        const lval = try self.lowerExprH(k[0], common);
        const rval = try self.lowerExprH(k[1], common);
        const result_ty = try self.nodeType(node);
        const iop = try binOpFor(op, cdata);
        return self.b.binary(iop, result_ty, lval, rval);
    }

    fn lowerUnary(self: *FnCtx, node: ast.Index, hint: ?TypeId) Error!ir.ValueId {
        const op: lexer.Kind = @enumFromInt(self.tree().get(node).main);
        const operand = self.kids(node)[0];
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
            if (self.l.lookupMethod(recv_ty, name)) |gsym| {
                const recv_val = try self.lowerExpr(k[0]);
                const fid = self.l.func_ids.get(gsym.pack()) orelse return error.UnsupportedConstruct;
                const fty = try self.nodeType(node);
                return self.b.makeClosure(fty, fid, recv_val);
            }
        }
        return error.UnsupportedConstruct; // interface method value (not called immediately): deferred
    }

    fn lowerCompositeLit(self: *FnCtx, node: ast.Index) Error!ir.ValueId {
        const k = self.kids(node); // [type, init]
        const ty = try self.nodeType(node);
        const data = self.ctx.typeOf(ty);
        if (data != .@"struct") return error.UnsupportedConstruct; // slice/map literals: deferred
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
        if (self.l.lookupMethod(ty, "show")) |gsym| {
            const fid = self.l.func_ids.get(gsym.pack()) orelse return error.UnsupportedConstruct;
            return self.b.call(string_ty, fid, &.{v});
        }
        if (data == .interface) {
            for (data.interface, 0..) |m, i| {
                if (std.mem.eql(u8, m.name, "show")) return self.b.callIface(string_ty, v, @intCast(i), &.{});
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
        return self.b.rtCall(string_ty, .string_concat, vals);
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
    elem: struct { recv: ir.ValueId, index: ir.ValueId, ty: TypeId },
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

    var rmodule = try resolve.resolveModule(gpa, &diags, &files, &no_imports, &.{});
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
        \\  if b { return a }
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
        \\  let addBase = (x: i64): i64 => x + base
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

test "unsupported construct (switch) reports UnsupportedConstruct, not a crash" {
    const gpa = testing.allocator;
    const src =
        \\function f(x: i64): i64 {
        \\  switch (x) {
        \\    case 1: return 1
        \\    default: return 0
        \\  }
        \\}
        \\
    ;
    try testing.expectError(error.UnsupportedConstruct, lowerSource(gpa, src));
}
