//! Type checker (spec/SPEC.md §14–§15): structural type identity via
//! interning, local type inference, structural interface satisfaction,
//! call/operator/generic checking, and expected-vs-found diagnostics.
//!
//! ## Architecture
//!
//! Types are **interned**: every distinct structural shape gets exactly one
//! `TypeId`, so type identity (§14.1) and equality are `TypeId` equality — no
//! deep structural comparison anywhere outside the interner itself. Composite
//! shapes (slice/array/map/tuple/func/chan) hash and compare by their
//! immediate child `TypeId`s only (already-canonical), never recursing into
//! what those ids represent; that's what makes recursive types (a struct
//! field referencing its own struct through a slice/map/chan/another struct —
//! legal per §13.3, reference types break value-cycles) tractable: a symbol's
//! `TypeId` slot is reserved *before* its fields are built, so a self- or
//! mutually-referential field resolves to the reserved id instead of
//! re-entering computation.
//!
//! One caveat, stated plainly rather than silently glossed over: struct and
//! interface types are memoized **one `TypeId` per declaring symbol**, not
//! deduped against a *different* symbol's identical shape when that shape was
//! itself built through a reference cycle. Two independently declared
//! non-recursive structs with identical field lists still correctly collapse
//! to one `TypeId` (the common case, handled by the general interning path).
//! Fully sound structural equality *through* arbitrary reference cycles is a
//! coinductive-equality problem — out of scope here; nothing in the language
//! surface depends on two separately-declared recursive types being `==`.
//!
//! ## Cross-module contract
//!
//! `TypeContext` is a project-lifetime object, created once by the driver and
//! threaded through one `checkModule` call per module, **in dependency
//! order** (mirroring `resolve.loadProject`'s own contract). Each call first
//! runs `collectDecls` over its own files, memoizing every declared type's
//! shape, every function/method signature, and every method set into `ctx`
//! keyed by `GlobalSymbol` — so a later, dependent module never needs the
//! AST of a module it imports from, only `ctx`'s already-finished summary
//! plus that module's `resolve.Module` for symbol metadata (name/kind).

const std = @import("std");
const ast = @import("ast.zig");
const lexer = @import("lexer.zig");
const diagnostics = @import("diagnostics.zig");
const resolve = @import("resolve.zig");

const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const Diagnostics = diagnostics.Diagnostics;
const Code = diagnostics.Code;
const Module = resolve.Module;
const ModuleId = resolve.ModuleId;
const ModuleFile = resolve.ModuleFile;
const SymbolId = resolve.SymbolId;
const Symbol = resolve.Symbol;

/// Every fallible operation in this file bottoms out in an allocator call
/// (mirrors `resolve.zig`'s own `Error` — see its doc comment for why this is
/// exact and not `anyerror`).
const Error = Allocator.Error;

// ============================================================================
// Cross-module symbol identity
// ============================================================================

/// A `resolve.SymbolId` is only unique within the module that produced it;
/// every table in this file keyed by "a symbol" uses this pair instead,
/// mirroring how `resolve.Symbol.imported_from` already threads module +
/// symbol together. `module == null` means "the module currently being
/// checked" is intentionally *not* used for map keys (see `pack`) — call
/// sites always have a concrete `ModuleId` available (the checker's own
/// module id is passed to it), so `pack` never has to special-case null.
pub const GlobalSymbol = struct {
    module: ModuleId,
    id: SymbolId,

    /// `pub`: lowering (`lower.zig`) keys its own func/instantiation tables by
    /// this same packed id, matching every table in `TypeContext` (see its
    /// doc comments) instead of inventing a parallel identity scheme.
    pub fn pack(self: GlobalSymbol) u64 {
        return (@as(u64, @intFromEnum(self.module)) << 32) | @as(u64, @intFromEnum(self.id));
    }
};

// ============================================================================
// Types
// ============================================================================

/// Canonical type handle. `invalid` (0) is the error-recovery sentinel: it is
/// assignable to/from everything and never itself triggers a diagnostic, so a
/// single bad subexpression doesn't cascade into a wall of follow-on errors.
pub const TypeId = enum(u32) { invalid = 0, _ };

pub const Prim = enum {
    i8,
    i16,
    i32,
    i64,
    u8,
    u16,
    u32,
    u64,
    f32,
    f64,
    bool,
    string,

    fn isInteger(self: Prim) bool {
        return switch (self) {
            .i8, .i16, .i32, .i64, .u8, .u16, .u32, .u64 => true,
            .f32, .f64, .bool, .string => false,
        };
    }
    fn isSigned(self: Prim) bool {
        return switch (self) {
            .i8, .i16, .i32, .i64 => true,
            else => false,
        };
    }
    fn isFloat(self: Prim) bool {
        return self == .f32 or self == .f64;
    }
    fn isNumeric(self: Prim) bool {
        return self.isInteger() or self.isFloat();
    }

    /// Inclusive representable range for integer prims (§15.4 constant
    /// representability). Unused for float/bool/string.
    fn intRange(self: Prim) struct { min: i128, max: i128 } {
        return switch (self) {
            .i8 => .{ .min = std.math.minInt(i8), .max = std.math.maxInt(i8) },
            .i16 => .{ .min = std.math.minInt(i16), .max = std.math.maxInt(i16) },
            .i32 => .{ .min = std.math.minInt(i32), .max = std.math.maxInt(i32) },
            .i64 => .{ .min = std.math.minInt(i64), .max = std.math.maxInt(i64) },
            .u8 => .{ .min = 0, .max = std.math.maxInt(u8) },
            .u16 => .{ .min = 0, .max = std.math.maxInt(u16) },
            .u32 => .{ .min = 0, .max = std.math.maxInt(u32) },
            .u64 => .{ .min = 0, .max = std.math.maxInt(u64) },
            .f32, .f64, .bool, .string => unreachable,
        };
    }
};

pub const Field = struct { name: []const u8, ty: TypeId, exported: bool };

/// A method signature. Shared shape for interface method sets (part of type
/// identity, §14.1) and struct/alias method sets (not part of identity —
/// stored separately in `TypeContext.method_sets`, §14.3).
pub const Method = struct {
    name: []const u8,
    params: []const TypeId,
    variadic: bool,
    result: TypeId,
};

pub const FuncShape = struct {
    params: []const TypeId,
    variadic: bool,
    result: TypeId,
};

pub const TypeData = union(enum) {
    invalid,
    /// The absent result type (§10.3: omitted result = "void"); never
    /// spellable in source and never assignable to/from anything but itself.
    void,
    untyped_int,
    untyped_float,
    untyped_rune,
    untyped_bool,
    untyped_string,
    /// The type of the literal `nil`, assignable to any nilable type (§14.2).
    untyped_nil,
    prim: Prim,
    slice: TypeId,
    array: struct { len: u64, elem: TypeId },
    map: struct { key: TypeId, val: TypeId },
    /// Two or more elements (§11: a tuple needs 2+; the parser collapses a
    /// parenthesized single type to that type directly).
    tuple: []const TypeId,
    func: FuncShape,
    chan: TypeId,
    /// Ordered field list — order is part of identity (§14.1).
    @"struct": []const Field,
    /// Method set, sorted by name for canonical hashing — order is *not*
    /// semantically meaningful (§14.3), only picked to make identity stable.
    interface: []const Method,
    /// A rigid, unbound generic parameter (or an interface's `Self`, §14.3).
    type_param: GlobalSymbol,
    /// A boxed fallible result value (§18.2) — not a real union, cannot be
    /// constructed except via `return`/`fail`, only produced by calling a
    /// fallible function and consumed by `?`/`catch`.
    fallible: struct { ok: TypeId, err: TypeId },
};

fn hashTypeData(data: TypeData) u64 {
    var h = std.hash.Wyhash.init(0xB17_C0DE);
    h.update(std.mem.asBytes(&@as(u8, @intFromEnum(std.meta.activeTag(data)))));
    switch (data) {
        .invalid, .void, .untyped_int, .untyped_float, .untyped_rune, .untyped_bool, .untyped_string, .untyped_nil => {},
        .prim => |p| h.update(std.mem.asBytes(&p)),
        .slice => |e| h.update(std.mem.asBytes(&e)),
        .chan => |e| h.update(std.mem.asBytes(&e)),
        .array => |a| {
            h.update(std.mem.asBytes(&a.len));
            h.update(std.mem.asBytes(&a.elem));
        },
        .map => |m| {
            h.update(std.mem.asBytes(&m.key));
            h.update(std.mem.asBytes(&m.val));
        },
        .tuple => |ts| for (ts) |t| h.update(std.mem.asBytes(&t)),
        .func => |f| {
            for (f.params) |p| h.update(std.mem.asBytes(&p));
            h.update(std.mem.asBytes(&f.variadic));
            h.update(std.mem.asBytes(&f.result));
        },
        .@"struct" => |fs| for (fs) |f| {
            h.update(f.name);
            h.update(std.mem.asBytes(&f.ty));
            h.update(std.mem.asBytes(&f.exported));
        },
        .interface => |ms| for (ms) |m| {
            h.update(m.name);
            for (m.params) |p| h.update(std.mem.asBytes(&p));
            h.update(std.mem.asBytes(&m.variadic));
            h.update(std.mem.asBytes(&m.result));
        },
        .type_param => |g| h.update(std.mem.asBytes(&g)),
        .fallible => |f| {
            h.update(std.mem.asBytes(&f.ok));
            h.update(std.mem.asBytes(&f.err));
        },
    }
    return h.final();
}

fn eqlTypeData(a: TypeData, b: TypeData) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .invalid, .void, .untyped_int, .untyped_float, .untyped_rune, .untyped_bool, .untyped_string, .untyped_nil => true,
        .prim => |p| p == b.prim,
        .slice => |e| e == b.slice,
        .chan => |e| e == b.chan,
        .array => |ar| ar.len == b.array.len and ar.elem == b.array.elem,
        .map => |m| m.key == b.map.key and m.val == b.map.val,
        .tuple => |ts| blk: {
            if (ts.len != b.tuple.len) break :blk false;
            for (ts, b.tuple) |x, y| if (x != y) break :blk false;
            break :blk true;
        },
        .func => |f| blk: {
            if (f.variadic != b.func.variadic or f.result != b.func.result) break :blk false;
            if (f.params.len != b.func.params.len) break :blk false;
            for (f.params, b.func.params) |x, y| if (x != y) break :blk false;
            break :blk true;
        },
        .@"struct" => |fs| blk: {
            if (fs.len != b.@"struct".len) break :blk false;
            for (fs, b.@"struct") |x, y| {
                if (!std.mem.eql(u8, x.name, y.name) or x.ty != y.ty or x.exported != y.exported) break :blk false;
            }
            break :blk true;
        },
        .interface => |ms| blk: {
            if (ms.len != b.interface.len) break :blk false;
            for (ms, b.interface) |x, y| {
                if (!std.mem.eql(u8, x.name, y.name) or x.variadic != y.variadic or x.result != y.result) break :blk false;
                if (x.params.len != y.params.len) break :blk false;
                for (x.params, y.params) |px, py| if (px != py) break :blk false;
            }
            break :blk true;
        },
        .type_param => |g| g.module == b.type_param.module and g.id == b.type_param.id,
        .fallible => |f| f.ok == b.fallible.ok and f.err == b.fallible.err,
    };
}

const TypeIndexCtx = struct {
    table: *const TypeTable,

    pub fn hash(self: TypeIndexCtx, id: TypeId) u64 {
        return hashTypeData(self.table.list.items[@intFromEnum(id)]);
    }
    pub fn eql(self: TypeIndexCtx, a: TypeId, b: TypeId) bool {
        return eqlTypeData(self.table.list.items[@intFromEnum(a)], self.table.list.items[@intFromEnum(b)]);
    }
};

/// The interning table. Composite `TypeData` payloads (slices of `Field`,
/// `Method`, `TypeId`) are arena-owned; the arena lives exactly as long as
/// the table.
const TypeTable = struct {
    gpa: Allocator,
    arena: std.heap.ArenaAllocator,
    list: std.ArrayList(TypeData) = .empty,
    index: std.HashMapUnmanaged(TypeId, void, TypeIndexCtx, std.hash_map.default_max_load_percentage) = .{},

    fn init(gpa: Allocator) TypeTable {
        return .{ .gpa = gpa, .arena = std.heap.ArenaAllocator.init(gpa) };
    }

    fn deinit(self: *TypeTable) void {
        self.list.deinit(self.gpa);
        self.index.deinit(self.gpa);
        self.arena.deinit();
        self.* = undefined;
    }

    fn get(self: *const TypeTable, id: TypeId) TypeData {
        return self.list.items[@intFromEnum(id)];
    }

    /// Reserves a fresh slot without interning it — used for struct/interface
    /// symbols so a self-referential field can resolve to a stable id before
    /// the shape is known (see module doc comment).
    fn reserve(self: *TypeTable, placeholder: TypeData) Error!TypeId {
        const idx: u32 = @intCast(self.list.items.len);
        try self.list.append(self.gpa, placeholder);
        return @enumFromInt(idx);
    }

    fn fill(self: *TypeTable, id: TypeId, data: TypeData) void {
        self.list.items[@intFromEnum(id)] = data;
    }

    /// Interns `data` (whose slices must already be arena-owned), deduping
    /// structurally-identical shapes so `TypeId` equality is type identity.
    fn intern(self: *TypeTable, data: TypeData) Error!TypeId {
        const candidate = try self.reserve(data);
        const ctx = TypeIndexCtx{ .table = self };
        const gop = try self.index.getOrPutContext(self.gpa, candidate, ctx);
        if (gop.found_existing) {
            _ = self.list.pop();
            return gop.key_ptr.*;
        }
        return candidate;
    }
};

/// One arena-dupe helper shared by every builder below.
fn dupe(arena: Allocator, comptime T: type, items: []const T) Error![]const T {
    return arena.dupe(T, items);
}

test "TypeTable interns structurally identical shapes and keeps distinct ones apart" {
    const gpa = std.testing.allocator;
    var tt = TypeTable.init(gpa);
    defer tt.deinit();

    const a = try tt.intern(.{ .prim = .i32 });
    const b = try tt.intern(.{ .prim = .i32 });
    const c = try tt.intern(.{ .prim = .i64 });
    try std.testing.expectEqual(a, b);
    try std.testing.expect(a != c);

    const s1 = try tt.intern(.{ .slice = a });
    const s2 = try tt.intern(.{ .slice = b });
    try std.testing.expectEqual(s1, s2);

    const fields = try dupe(tt.arena.allocator(), Field, &.{
        .{ .name = "x", .ty = a, .exported = false },
        .{ .name = "y", .ty = a, .exported = false },
    });
    const st1 = try tt.intern(.{ .@"struct" = fields });
    const fields2 = try dupe(tt.arena.allocator(), Field, &.{
        .{ .name = "x", .ty = a, .exported = false },
        .{ .name = "y", .ty = a, .exported = false },
    });
    const st2 = try tt.intern(.{ .@"struct" = fields2 });
    try std.testing.expectEqual(st1, st2); // same shape, different symbols -> same id

    const fields3 = try dupe(tt.arena.allocator(), Field, &.{
        .{ .name = "y", .ty = a, .exported = false },
        .{ .name = "x", .ty = a, .exported = false },
    });
    const st3 = try tt.intern(.{ .@"struct" = fields3 });
    try std.testing.expect(st3 != st1); // field order is part of identity
}

// ============================================================================
// TypeContext — the project-lifetime shared table (see module doc comment)
// ============================================================================

/// One instantiation record, kept "monomorphization-ready" for the IR lowering
/// stage: the generic declaration, its concrete type arguments, and the
/// resulting concrete `TypeId`.
pub const Instantiation = struct {
    generic: GlobalSymbol,
    args: []const TypeId,
    result: TypeId,
};

const MethodBucket = std.StringHashMapUnmanaged(Method);

pub const TypeContext = struct {
    gpa: Allocator,
    types: TypeTable,
    /// GlobalSymbol.pack() -> TypeId, for struct/interface (template, generics
    /// unbound) and type_alias declarations.
    decl_memo: std.AutoHashMapUnmanaged(u64, TypeId) = .{},
    /// GlobalSymbol.pack() -> signature, for every func_decl (free function or
    /// method) and every generic function's own template signature.
    func_sigs: std.AutoHashMapUnmanaged(u64, FuncShape) = .{},
    /// GlobalSymbol.pack() -> resolved type, for every top-level `const`. The
    /// only value binding memoized project-wide (a module's per-binding
    /// `var_types` dies with its `Checker`), so a dependent module can type a
    /// reference to an imported `const` — and lowering can inline it.
    const_types: std.AutoHashMapUnmanaged(u64, TypeId) = .{},
    /// TypeId (as u32) -> its method set, name-keyed. Deliberately separate
    /// from `TypeData.struct`/`.interface`: struct method sets are *not* part
    /// of type identity (§14.1 only lists fields), only of satisfaction
    /// checks (§14.3).
    method_sets: std.AutoHashMapUnmanaged(u32, MethodBucket) = .{},
    /// GlobalSymbol.pack() (a generic_param or interface `Self` symbol) -> its
    /// rigid `TypeId`.
    type_param_ids: std.AutoHashMapUnmanaged(u64, TypeId) = .{},
    /// GlobalSymbol.pack() -> instantiations of that generic, scanned linearly
    /// per lookup (bounded: realistic programs instantiate any one generic a
    /// handful of times) for exact `args` equality rather than a probabilistic
    /// hash key.
    inst_index: std.AutoHashMapUnmanaged(u64, std.ArrayList(Instantiation)) = .{},
    instantiations: std.ArrayList(Instantiation) = .empty,
    /// Best-effort display name for a struct/interface `TypeId`, set once from
    /// the first declaring symbol seen — cosmetic only (identity stays
    /// structural); falls back to a structural spelling when absent.
    display_names: std.AutoHashMapUnmanaged(u32, []const u8) = .{},
    /// GlobalSymbol.pack() (a struct/interface/alias/generic-function decl) ->
    /// its own generic parameter symbols, in declared order.
    decl_generics: std.AutoHashMapUnmanaged(u64, []const GlobalSymbol) = .{},
    /// GlobalSymbol.pack() (a generic parameter) -> the interface `TypeId`s it
    /// is bounded by (`<T: A & B>`).
    generic_bounds: std.AutoHashMapUnmanaged(u64, []const TypeId) = .{},
    /// interface `TypeId` (via `@intFromEnum`) -> the `GlobalSymbol` of that
    /// interface's own implicit `Self` (§14.3), captured by
    /// `buildInterfaceTemplate` the first time a method signature mentions
    /// it. Absent for interfaces that never use `Self`. `satisfies` and
    /// generic-bound method lookup both bind this to the concrete/rigid
    /// receiver before comparing or returning a method's signature.
    iface_self: std.AutoHashMapUnmanaged(u32, GlobalSymbol) = .{},

    prim_ids: std.EnumArray(Prim, TypeId) = undefined,
    void_id: TypeId = undefined,
    untyped_int_id: TypeId = undefined,
    untyped_float_id: TypeId = undefined,
    untyped_rune_id: TypeId = undefined,
    untyped_bool_id: TypeId = undefined,
    untyped_string_id: TypeId = undefined,
    untyped_nil_id: TypeId = undefined,
    /// The predeclared `error` interface (§10.6): `{ message(): string }`.
    error_id: TypeId = undefined,

    pub fn init(gpa: Allocator) Error!TypeContext {
        var self = TypeContext{ .gpa = gpa, .types = TypeTable.init(gpa) };
        std.debug.assert((try self.types.intern(.invalid)) == .invalid);
        self.void_id = try self.types.intern(.void);
        self.untyped_int_id = try self.types.intern(.untyped_int);
        self.untyped_float_id = try self.types.intern(.untyped_float);
        self.untyped_rune_id = try self.types.intern(.untyped_rune);
        self.untyped_bool_id = try self.types.intern(.untyped_bool);
        self.untyped_string_id = try self.types.intern(.untyped_string);
        self.untyped_nil_id = try self.types.intern(.untyped_nil);
        for (std.enums.values(Prim)) |p| self.prim_ids.set(p, try self.types.intern(.{ .prim = p }));

        const string_id = self.prim_ids.get(.string);
        const a = self.types.arena.allocator();
        const message_sig = try dupe(a, Method, &.{.{ .name = "message", .params = &.{}, .variadic = false, .result = string_id }});
        self.error_id = try self.types.intern(.{ .interface = message_sig });
        try self.display_names.put(self.gpa, @intFromEnum(self.error_id), "error");
        return self;
    }

    pub fn deinit(self: *TypeContext) void {
        self.types.deinit();
        self.decl_memo.deinit(self.gpa);
        self.func_sigs.deinit(self.gpa);
        self.const_types.deinit(self.gpa);
        var mit = self.method_sets.valueIterator();
        while (mit.next()) |bucket| bucket.deinit(self.gpa);
        self.method_sets.deinit(self.gpa);
        self.type_param_ids.deinit(self.gpa);
        var iit = self.inst_index.valueIterator();
        while (iit.next()) |list| list.deinit(self.gpa);
        self.inst_index.deinit(self.gpa);
        self.instantiations.deinit(self.gpa);
        self.display_names.deinit(self.gpa);
        self.decl_generics.deinit(self.gpa);
        self.generic_bounds.deinit(self.gpa);
        self.iface_self.deinit(self.gpa);
        self.* = undefined;
    }

    pub fn typeOf(self: *const TypeContext, id: TypeId) TypeData {
        return self.types.get(id);
    }

    /// Interns the fixed-length array type `elem[len]`. A thin public wrapper
    /// over the table's own interning (which the checker reaches directly);
    /// exposed so consumers that already hold a `TypeContext` — e.g. the
    /// codegen backends' tests — can name a real `.array` type without
    /// routing a source string through the whole front end.
    pub fn arrayType(self: *TypeContext, len: u64, elem: TypeId) Error!TypeId {
        return self.types.intern(.{ .array = .{ .len = len, .elem = elem } });
    }

    fn arena(self: *TypeContext) Allocator {
        return self.types.arena.allocator();
    }

    /// The rigid `TypeId` standing for generic-param/`Self` symbol `g`,
    /// creating and memoizing it on first use.
    fn typeParamId(self: *TypeContext, g: GlobalSymbol) Error!TypeId {
        const key = g.pack();
        if (self.type_param_ids.get(key)) |id| return id;
        const id = try self.types.intern(.{ .type_param = g });
        try self.type_param_ids.put(self.gpa, key, id);
        return id;
    }

    fn methodBucket(self: *TypeContext, receiver: TypeId) Error!*MethodBucket {
        const gop = try self.method_sets.getOrPut(self.gpa, @intFromEnum(receiver));
        if (!gop.found_existing) gop.value_ptr.* = .{};
        return gop.value_ptr;
    }

    /// The method set attached to `receiver` (empty if none). Structural
    /// (§14.3): keyed purely by `receiver`'s `TypeId`, so two differently
    /// named but shape-identical structs share one method set.
    pub fn methodsOf(self: *TypeContext, receiver: TypeId) ?*const MethodBucket {
        return self.method_sets.getPtr(@intFromEnum(receiver));
    }

    fn findInstantiation(self: *TypeContext, generic: GlobalSymbol, args: []const TypeId) ?TypeId {
        const list = self.inst_index.getPtr(generic.pack()) orelse return null;
        for (list.items) |inst| {
            if (inst.args.len != args.len) continue;
            var same = true;
            for (inst.args, args) |a, b| {
                if (a != b) {
                    same = false;
                    break;
                }
            }
            if (same) return inst.result;
        }
        return null;
    }

    fn recordInstantiation(self: *TypeContext, generic: GlobalSymbol, args: []const TypeId, result: TypeId) Error!void {
        const owned_args = try dupe(self.arena(), TypeId, args);
        const rec = Instantiation{ .generic = generic, .args = owned_args, .result = result };
        try self.instantiations.append(self.gpa, rec);
        const gop = try self.inst_index.getOrPut(self.gpa, generic.pack());
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(self.gpa, rec);
    }

    /// `pub`: the index into `instantiations` recording `(generic, args)`,
    /// found by the same bounded linear scan `findInstantiation` already does
    /// (never `null` right after a `recordInstantiation`/`instantiateFunc`
    /// call for that same pair). Lowering needs the index itself, not just
    /// the result `TypeId` `findInstantiation` returns: two *different*
    /// generic function instantiations can substitute to a structurally
    /// identical `.func` `TypeId` (interning dedupes by shape, not by
    /// source), so `result` alone can't tell two call sites' monomorphized
    /// bodies apart, only `(generic, args)` (equivalently, this index) can.
    pub fn findInstantiationIndex(self: *const TypeContext, generic: GlobalSymbol, args: []const TypeId) ?u32 {
        for (self.instantiations.items, 0..) |inst, i| {
            if (inst.generic.module != generic.module or inst.generic.id != generic.id) continue;
            if (inst.args.len != args.len) continue;
            var same = true;
            for (inst.args, args) |a, b| {
                if (a != b) {
                    same = false;
                    break;
                }
            }
            if (same) return @intCast(i);
        }
        return null;
    }

    /// `pub`: rebuilds `ty` with every `type_param` leaf bound in `env`
    /// replaced by its binding (§13.6), returning `ty` unchanged (no new
    /// allocation) when nothing in it needs substituting. Exposed on
    /// `TypeContext` (rather than kept private to `Checker`) because lowering
    /// needs the exact same operation: a generic function's body is
    /// type-checked exactly once, against its own template's unbound
    /// `type_param` ids (see `Checker.rebuiltOwnGenericEnv`); to lower one
    /// concrete monomorphization, lowering re-derives each body node's
    /// *concrete* type by calling this with the instantiation's own
    /// `(param symbol -> concrete arg)` bindings — see `lower.zig`'s module
    /// doc comment on generic function lowering.
    pub fn subst(self: *TypeContext, ty: TypeId, env: GenericEnv, depth: u32) Error!TypeId {
        if (env.len == 0) return ty;
        if (depth >= max_type_depth) return ty;
        const data = self.typeOf(ty);
        switch (data) {
            .type_param => |g| return envLookup(env, g) orelse ty,
            .slice => |e| {
                const ne = try self.subst(e, env, depth + 1);
                if (ne == e) return ty;
                return self.types.intern(.{ .slice = ne });
            },
            .chan => |e| {
                const ne = try self.subst(e, env, depth + 1);
                if (ne == e) return ty;
                return self.types.intern(.{ .chan = ne });
            },
            .array => |a| {
                const ne = try self.subst(a.elem, env, depth + 1);
                if (ne == a.elem) return ty;
                return self.types.intern(.{ .array = .{ .len = a.len, .elem = ne } });
            },
            .map => |m| {
                const nk = try self.subst(m.key, env, depth + 1);
                const nv = try self.subst(m.val, env, depth + 1);
                if (nk == m.key and nv == m.val) return ty;
                return self.types.intern(.{ .map = .{ .key = nk, .val = nv } });
            },
            .tuple => |ts| {
                var changed = false;
                var buf = try self.gpa.alloc(TypeId, ts.len);
                defer self.gpa.free(buf);
                for (ts, 0..) |t, i| {
                    buf[i] = try self.subst(t, env, depth + 1);
                    if (buf[i] != t) changed = true;
                }
                if (!changed) return ty;
                return self.types.intern(.{ .tuple = try dupe(self.arena(), TypeId, buf) });
            },
            .func => |f| {
                var changed = false;
                var buf = try self.gpa.alloc(TypeId, f.params.len);
                defer self.gpa.free(buf);
                for (f.params, 0..) |p, i| {
                    buf[i] = try self.subst(p, env, depth + 1);
                    if (buf[i] != p) changed = true;
                }
                const nr = try self.subst(f.result, env, depth + 1);
                if (nr != f.result) changed = true;
                if (!changed) return ty;
                return self.types.intern(.{ .func = .{ .params = try dupe(self.arena(), TypeId, buf), .variadic = f.variadic, .result = nr } });
            },
            .fallible => |f| {
                const nok = try self.subst(f.ok, env, depth + 1);
                const nerr = try self.subst(f.err, env, depth + 1);
                if (nok == f.ok and nerr == f.err) return ty;
                return self.types.intern(.{ .fallible = .{ .ok = nok, .err = nerr } });
            },
            // Struct/interface fields may reference the enclosing generic's
            // params too, but only when *instantiating* a generic struct;
            // `instantiateRecursive` handles those directly (it needs the
            // reserve-then-fill cycle guard, not plain rebuild-and-intern)
            // rather than going through here.
            .invalid, .void, .untyped_int, .untyped_float, .untyped_rune, .untyped_bool, .untyped_string, .untyped_nil, .prim, .@"struct", .interface => return ty,
        }
    }

    /// `pub`: substitutes every param and the result of `shape` — the
    /// per-`FuncShape` counterpart to `subst`, used by lowering to compute a
    /// monomorphized function's own concrete signature from its template
    /// `ctx.func_sigs` entry.
    pub fn substFuncShape(self: *TypeContext, shape: FuncShape, env: GenericEnv) Error!FuncShape {
        var params = try self.gpa.alloc(TypeId, shape.params.len);
        defer self.gpa.free(params);
        for (shape.params, 0..) |p, i| params[i] = try self.subst(p, env, 0);
        return .{ .params = try dupe(self.arena(), TypeId, params), .variadic = shape.variadic, .result = try self.subst(shape.result, env, 0) };
    }
};

test "TypeContext seeds primitives, void, and the predeclared error interface" {
    const gpa = std.testing.allocator;
    var ctx = try TypeContext.init(gpa);
    defer ctx.deinit();

    try std.testing.expectEqual(TypeId.invalid, @as(TypeId, .invalid));
    try std.testing.expectEqual(Prim.i32, ctx.typeOf(ctx.prim_ids.get(.i32)).prim);
    try std.testing.expectEqual(TypeData.void, ctx.typeOf(ctx.void_id));

    const err_shape = ctx.typeOf(ctx.error_id);
    try std.testing.expectEqual(@as(usize, 1), err_shape.interface.len);
    try std.testing.expectEqualStrings("message", err_shape.interface[0].name);
    try std.testing.expectEqual(ctx.prim_ids.get(.string), err_shape.interface[0].result);
}

// ============================================================================
// Checker — one module at a time
// ============================================================================

/// `sym` bound in the generic environment to concrete/rigid type `to` (see
/// `GenericEnv`). `pub`: lowering rebuilds one of these per generic
/// instantiation (from `Instantiation.args` zipped with `decl_generics`) to
/// drive `TypeContext.subst` over a template function body's checked types —
/// see `TypeContext.subst`'s doc comment.
pub const GenericBinding = struct { sym: GlobalSymbol, to: TypeId };
/// The generic parameters currently in scope while evaluating a type
/// expression: a struct/interface/function's own `<T, U: Bound>` list while
/// building its *template* shape (bound to their own rigid `type_param` ids),
/// or a call/instantiation site's concrete bindings while substituting one.
/// Always small (a handful of type parameters) — linear scan is simplest.
pub const GenericEnv = []const GenericBinding;

/// Cached per-method context — see `Checker.method_ctx`.
const MethodCtx = struct { recv_ty: TypeId, env: GenericEnv };

/// Packs a per-file node index into a module-wide-unique `u64` key (a bare
/// `ast.Index` collides across a multi-file module's files).
fn packFileNode(file_idx: usize, node: ast.Index) u64 {
    return (@as(u64, @intCast(file_idx)) << 32) | @as(u64, node);
}

fn envLookup(env: GenericEnv, g: GlobalSymbol) ?TypeId {
    for (env) |b| {
        if (b.sym.module == g.module and b.sym.id == g.id) return b.to;
    }
    return null;
}

/// Bounded recursion depth for type-expression evaluation and substitution —
/// real programs never approach this; hitting it means malformed/cyclic input
/// that upstream passes should already have rejected (Power of 10: bounded).
const max_type_depth = 128;

/// Dependencies needed to render a `TypeId` as text outside a live `Checker`
/// (the LSP's hover/completion has a `TypeContext` and a `resolve.Module` but
/// no `Checker` instance). Mirrors the subset of `Checker`'s own fields that
/// `describeType` needs.
pub const NameCtx = struct {
    gpa: Allocator,
    ctx: *const TypeContext,
    module_id: ModuleId,
    module: *const Module,
    all_modules: []const Module,
};

/// Renders `ty` as source-shaped text (`[]i32`, `map<string, Point>`, ...) —
/// the same rules `Checker.typeName` uses for its own "expected X, found Y"
/// diagnostics. Public so external consumers (the LSP's hover/completion) can
/// format an arbitrary `TypeId` without a live `Checker`.
pub fn describeType(nc: NameCtx, ty: TypeId) Error![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(nc.gpa);
    try appendTypeName(nc, &buf, ty, 0);
    return buf.toOwnedSlice(nc.gpa);
}

fn appendTypeName(nc: NameCtx, buf: *std.ArrayList(u8), ty: TypeId, depth: u32) Error!void {
    if (depth >= max_type_depth) return buf.appendSlice(nc.gpa, "...");
    switch (nc.ctx.typeOf(ty)) {
        .invalid => try buf.appendSlice(nc.gpa, "<error>"),
        .void => try buf.appendSlice(nc.gpa, "()"),
        .untyped_int => try buf.appendSlice(nc.gpa, "untyped int"),
        .untyped_float => try buf.appendSlice(nc.gpa, "untyped float"),
        .untyped_rune => try buf.appendSlice(nc.gpa, "untyped rune"),
        .untyped_bool => try buf.appendSlice(nc.gpa, "untyped bool"),
        .untyped_string => try buf.appendSlice(nc.gpa, "untyped string"),
        .untyped_nil => try buf.appendSlice(nc.gpa, "nil"),
        .prim => |p| try buf.appendSlice(nc.gpa, @tagName(p)),
        .slice => |e| {
            try buf.appendSlice(nc.gpa, "[]");
            try appendTypeName(nc, buf, e, depth + 1);
        },
        .chan => |e| {
            try buf.appendSlice(nc.gpa, "chan<");
            try appendTypeName(nc, buf, e, depth + 1);
            try buf.appendSlice(nc.gpa, ">");
        },
        .array => |a| {
            var num: [24]u8 = undefined;
            const s = std.fmt.bufPrint(&num, "[{d}]", .{a.len}) catch unreachable; // bounded: u64 max digits
            try buf.appendSlice(nc.gpa, s);
            try appendTypeName(nc, buf, a.elem, depth + 1);
        },
        .map => |m| {
            try buf.appendSlice(nc.gpa, "map<");
            try appendTypeName(nc, buf, m.key, depth + 1);
            try buf.appendSlice(nc.gpa, ", ");
            try appendTypeName(nc, buf, m.val, depth + 1);
            try buf.appendSlice(nc.gpa, ">");
        },
        .tuple => |ts| {
            try buf.appendSlice(nc.gpa, "(");
            for (ts, 0..) |t, i| {
                if (i != 0) try buf.appendSlice(nc.gpa, ", ");
                try appendTypeName(nc, buf, t, depth + 1);
            }
            try buf.appendSlice(nc.gpa, ")");
        },
        .func => |f| {
            try buf.appendSlice(nc.gpa, "(");
            for (f.params, 0..) |p, i| {
                if (i != 0) try buf.appendSlice(nc.gpa, ", ");
                try appendTypeName(nc, buf, p, depth + 1);
            }
            try buf.appendSlice(nc.gpa, ") => ");
            try appendTypeName(nc, buf, f.result, depth + 1);
        },
        .fallible => |f| {
            try appendTypeName(nc, buf, f.ok, depth + 1);
            try buf.appendSlice(nc.gpa, "!");
            if (f.err != nc.ctx.error_id) try appendTypeName(nc, buf, f.err, depth + 1);
        },
        .@"struct", .interface => {
            if (nc.ctx.display_names.get(@intFromEnum(ty))) |n| {
                try buf.appendSlice(nc.gpa, n);
            } else {
                try buf.appendSlice(nc.gpa, if (nc.ctx.typeOf(ty) == .@"struct") "struct{...}" else "interface{...}");
            }
        },
        .type_param => |g| {
            const owner = if (g.module == nc.module_id) nc.module else &nc.all_modules[@intFromEnum(g.module)];
            try buf.appendSlice(nc.gpa, owner.symbols.items[@intFromEnum(g.id)].name);
        },
    }
}

const Checker = struct {
    gpa: Allocator,
    diags: *Diagnostics,
    ctx: *TypeContext,
    files: []const ModuleFile,
    module: *const Module,
    module_id: ModuleId,
    all_modules: []const Module,
    node_types: [][]TypeId,
    /// SymbolId (this module only) -> its `let`/`const` initializer node, for
    /// the bounded constant evaluator (`constEval`, §15.4). Populated as each
    /// binding is seen, top-level ones during `collectDecls` (so order is
    /// irrelevant, §9) and local ones as their statement is checked. Moved into
    /// `CheckedModule` (not freed by `deinitLocal`) so lowering can inline a
    /// top-level `const`'s initializer — including one imported from another
    /// module — after this `Checker` goes out of scope.
    const_inits: std.AutoHashMapUnmanaged(SymbolId, ast.Index) = .{},
    /// SymbolId (this module only) -> resolved `TypeId`, for every
    /// `let`/`const`/`param`/`receiver` binding and every loop/catch/arrow
    /// binder. Populated by body-checking as each binding statement/binder is
    /// checked (always before any later reference — `resolve.zig`'s own
    /// `use_before_init` check already guarantees no read precedes its
    /// binding in program order), then consulted whenever a later `ident`
    /// node reads that symbol.
    var_types: std.AutoHashMapUnmanaged(SymbolId, TypeId) = .{},
    /// `(file_idx, func_decl node)` (packed, see `packFileNode`) -> the
    /// receiver `TypeId` and generic env `collectFuncDecl` already resolved
    /// once while building the method's signature. Body-checking reuses this
    /// instead of re-walking the receiver type node, which could otherwise
    /// double-emit a receiver-type diagnostic (e.g. a malformed generic
    /// receiver) once per pass.
    method_ctx: std.AutoHashMapUnmanaged(u64, MethodCtx) = .{},
    /// `(file_idx, call node)` (packed) -> the index into `ctx.instantiations`
    /// that call site's generic-function call resolved to (`checkGenericCall`
    /// populates this). `ctx.instantiations` alone dedupes by `(generic,
    /// args)`, not by call site, so lowering — which needs "which concrete
    /// function does *this* call node invoke" — can't recover that from `ctx`
    /// alone; this is the minimal per-call-site link back to it. Moved into
    /// `CheckedModule` (not freed by `deinitLocal`) so lowering can consume it
    /// after this `Checker` goes out of scope.
    call_insts: std.AutoHashMapUnmanaged(u64, u32) = .{},

    fn deinitLocal(self: *Checker) void {
        self.var_types.deinit(self.gpa);
        self.method_ctx.deinit(self.gpa);
    }

    // ---- symbol/module plumbing --------------------------------------------

    fn moduleOf(self: *const Checker, mid: ModuleId) *const Module {
        if (mid == self.module_id) return self.module;
        return &self.all_modules[@intFromEnum(mid)];
    }

    fn symbolOf(self: *const Checker, g: GlobalSymbol) Symbol {
        return self.moduleOf(g.module).symbols.items[@intFromEnum(g.id)];
    }

    /// Follows `import_item` re-export chains down to the real declaring
    /// symbol. Bounded: a chain longer than this implies a bug upstream (an
    /// actual cycle is already rejected by `resolve.zig`'s import-cycle
    /// check), not valid input.
    fn canonicalize(self: *const Checker, g: GlobalSymbol) GlobalSymbol {
        var cur = g;
        var guard: u32 = 0;
        while (guard < 64) : (guard += 1) {
            const sym = self.symbolOf(cur);
            if (sym.kind != .import_item) return cur;
            const target = sym.imported_from orelse return cur;
            cur = .{ .module = target.module, .id = target.symbol };
        }
        return cur;
    }

    /// The `GlobalSymbol` an identifier/type-name node was bound to by the
    /// resolver, canonicalized through re-exports. `null` for the blank
    /// identifier or any name the resolver already reported as undefined.
    fn nodeSymbol(self: *const Checker, file_idx: usize, node: ast.Index) ?GlobalSymbol {
        const sid = self.module.node_symbols[file_idx][node];
        if (sid == .none) return null;
        return self.canonicalize(.{ .module = self.module_id, .id = sid });
    }

    fn identText(mf: ModuleFile, node: ast.Index) []const u8 {
        const span = mf.tree.get(node).span;
        return mf.source[span.start..span.end];
    }

    fn emit(self: *Checker, mf: ModuleFile, node: ast.Index, code: Code, comptime fmt: []const u8, args: anytype, hint: ?[]const u8) Error!void {
        const span = mf.tree.get(node).span;
        // 512: comfortably fits two rendered type names (expected/found) plus
        // surrounding message text; see `typeName`.
        var buf: [512]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, fmt, args) catch fmt;
        try self.diags.report(code, span, msg, hint);
    }

    fn setType(self: *Checker, file_idx: usize, node: ast.Index, id: TypeId) void {
        self.node_types[file_idx][node] = id;
    }

    fn typeOfNode(self: *const Checker, file_idx: usize, node: ast.Index) TypeId {
        return self.node_types[file_idx][node];
    }

    // ---- generic-param / type_param substitution ---------------------------

    /// Rebuilds `ty` with every `type_param` leaf bound in `env` replaced by
    /// its binding (§13.6). Delegates to `TypeContext.subst` — moved there
    /// (task #336) because lowering needs the exact same substitution to
    /// re-derive a generic function body's *concrete* per-node types from its
    /// once-checked template types (see that function's doc comment); a
    /// second copy of this logic in `lower.zig` would be exactly the
    /// "reimplementing checker logic" the task warns against.
    fn subst(self: *Checker, ty: TypeId, env: GenericEnv, depth: u32) Error!TypeId {
        return self.ctx.subst(ty, env, depth);
    }

    // ---- type-expression evaluation (§11) -----------------------------------

    fn checkTypeIdent(self: *Checker, file_idx: usize, node: ast.Index, env: GenericEnv) Error!TypeId {
        const mf = self.files[file_idx];
        const gsym = self.nodeSymbol(file_idx, node) orelse return .invalid; // resolver already diagnosed
        const sym = self.symbolOf(gsym);
        switch (sym.kind) {
            .builtin_type => return builtinTypeId(self.ctx, sym.name) orelse .invalid,
            .generic_param => return envLookup(env, gsym) orelse try self.ctx.typeParamId(gsym),
            .struct_type, .interface_type, .type_alias => {
                const arity = self.declGenericArity(gsym);
                if (arity > 0) {
                    try self.emit(mf, node, .generic_arity_mismatch, "'{s}' needs {d} type argument(s); write '{s}<...>'", .{ sym.name, arity, sym.name }, null);
                    return .invalid;
                }
                return self.declTypeOf(gsym);
            },
            else => {
                try self.emit(mf, node, .type_mismatch, "'{s}' is not a type", .{sym.name}, null);
                return .invalid;
            },
        }
    }

    fn checkTypeGenericInst(self: *Checker, file_idx: usize, node: ast.Index, env: GenericEnv) Error!TypeId {
        const mf = self.files[file_idx];
        const k = mf.tree.kids(node); // [name_ident, type_args]
        const gsym = self.nodeSymbol(file_idx, k[0]) orelse return .invalid;
        const sym = self.symbolOf(gsym);
        const arg_nodes = mf.tree.kids(k[1]);
        var args = try self.gpa.alloc(TypeId, arg_nodes.len);
        defer self.gpa.free(args);
        for (arg_nodes, 0..) |an, i| args[i] = try self.checkType(file_idx, an, env);

        switch (sym.kind) {
            .struct_type, .interface_type, .type_alias => {},
            else => {
                try self.emit(mf, node, .type_mismatch, "'{s}' is not a generic type", .{sym.name}, null);
                return .invalid;
            },
        }
        const want = self.declGenericArity(gsym);
        if (want != args.len) {
            try self.emit(mf, node, .generic_arity_mismatch, "'{s}' expects {d} type argument(s), found {d}", .{ sym.name, want, args.len }, null);
            return .invalid;
        }
        return self.instantiateGeneric(gsym, args, mf, node);
    }

    /// Evaluates a `result_type` node (§10.3/§18.2): a plain type, or a
    /// `fallible` wrapper — the latter's `TypeId` is the *boxed* result value
    /// (§18.2), not the ok type directly.
    fn checkResultTypeNode(self: *Checker, file_idx: usize, node: ast.Index, env: GenericEnv) Error!TypeId {
        const mf = self.files[file_idx];
        if (mf.tree.get(node).tag == .fallible) {
            const k = mf.tree.kids(node); // [type, err_or_none]
            const ok = try self.checkType(file_idx, k[0], env);
            const err_ty = if (k[1] != ast.none) try self.checkType(file_idx, k[1], env) else self.ctx.error_id;
            return self.ctx.types.intern(.{ .fallible = .{ .ok = ok, .err = err_ty } });
        }
        return self.checkType(file_idx, node, env);
    }

    /// Evaluates any type-position AST node to its `TypeId` (§11's grammar).
    fn checkType(self: *Checker, file_idx: usize, node: ast.Index, env: GenericEnv) Error!TypeId {
        if (node == ast.none) return self.ctx.void_id;
        const mf = self.files[file_idx];
        const n = mf.tree.get(node);
        switch (n.tag) {
            .ident => return self.checkTypeIdent(file_idx, node, env),
            .generic_inst => return self.checkTypeGenericInst(file_idx, node, env),
            .slice_type => {
                const elem = try self.checkType(file_idx, mf.tree.kids(node)[0], env);
                return self.ctx.types.intern(.{ .slice = elem });
            },
            .array_type => {
                const k = mf.tree.kids(node); // [size_int, elem]
                const size_text = Checker.identText(mf, k[0]);
                const len_i128 = parseIntLiteral(size_text);
                const len: u64 = if (len_i128 < 0) 0 else @intCast(len_i128);
                const elem = try self.checkType(file_idx, k[1], env);
                return self.ctx.types.intern(.{ .array = .{ .len = len, .elem = elem } });
            },
            .map_type => {
                const k = mf.tree.kids(node);
                const key = try self.checkType(file_idx, k[0], env);
                const val = try self.checkType(file_idx, k[1], env);
                if (key != .invalid and !self.comparable(key)) {
                    try self.emit(mf, k[0], .not_comparable, "map key type must be comparable", .{}, null);
                }
                return self.ctx.types.intern(.{ .map = .{ .key = key, .val = val } });
            },
            .tuple_type => {
                const elem_nodes = mf.tree.kids(node);
                var elems = try self.gpa.alloc(TypeId, elem_nodes.len);
                defer self.gpa.free(elems);
                for (elem_nodes, 0..) |e, i| elems[i] = try self.checkType(file_idx, e, env);
                return self.ctx.types.intern(.{ .tuple = try dupe(self.ctx.arena(), TypeId, elems) });
            },
            .func_type => {
                const k = mf.tree.kids(node); // [type_list, result]
                const param_nodes = mf.tree.kids(k[0]);
                var params = try self.gpa.alloc(TypeId, param_nodes.len);
                defer self.gpa.free(params);
                for (param_nodes, 0..) |p, i| params[i] = try self.checkType(file_idx, p, env);
                const result = try self.checkResultTypeNode(file_idx, k[1], env);
                return self.ctx.types.intern(.{ .func = .{ .params = try dupe(self.ctx.arena(), TypeId, params), .variadic = false, .result = result } });
            },
            .chan_type => {
                const elem = try self.checkType(file_idx, mf.tree.kids(node)[0], env);
                return self.ctx.types.intern(.{ .chan = elem });
            },
            .void_type => return self.ctx.void_id, // the unit type `()` (§18.2, e.g. `()!`)
            else => return .invalid, // parser error-recovery poison node
        }
    }

    // ---- comparability / nilability (§14.6, §13.4) --------------------------

    fn isNilable(self: *Checker, ty: TypeId) bool {
        // A bare unbound/bounded type parameter can't be shown nilable: the
        // only types that can ever satisfy a `<T: I>` bound are structs
        // (§10.4, methods only attach to structs/aliases), and a struct's
        // zero value is never `nil` (§13.4) — so `T` itself never is either.
        return switch (self.ctx.typeOf(ty)) {
            .slice, .map, .chan, .func, .interface => true,
            else => false,
        };
    }

    fn comparable(self: *Checker, ty: TypeId) bool {
        return switch (self.ctx.typeOf(ty)) {
            .invalid => true,
            .prim => true, // numeric, bool, and string are all comparable (§14.6)
            .untyped_int, .untyped_float, .untyped_rune, .untyped_bool, .untyped_string, .untyped_nil => true,
            .interface, .type_param => true,
            .array => |a| self.comparable(a.elem),
            .tuple => |ts| blk: {
                for (ts) |t| if (!self.comparable(t)) break :blk false;
                break :blk true;
            },
            .@"struct" => |fields| blk: {
                for (fields) |f| if (!self.comparable(f.ty)) break :blk false;
                break :blk true;
            },
            .slice, .map, .func, .chan, .void, .fallible => false,
        };
    }

    fn hasOrdering(self: *Checker, ty: TypeId) bool {
        return switch (self.ctx.typeOf(ty)) {
            .prim => |p| p.isNumeric() or p == .string,
            .untyped_int, .untyped_float, .untyped_rune, .untyped_string => true,
            else => false,
        };
    }

    fn substMethod(self: *Checker, m: Method, env: GenericEnv) Error!Method {
        var params = try self.gpa.alloc(TypeId, m.params.len);
        defer self.gpa.free(params);
        for (m.params, 0..) |p, i| params[i] = try self.subst(p, env, 0);
        return .{
            .name = m.name,
            .params = try dupe(self.ctx.arena(), TypeId, params),
            .variadic = m.variadic,
            .result = try self.subst(m.result, env, 0),
        };
    }

    // ---- declared type templates (struct/interface/alias) ------------------

    fn declGenericArity(self: *Checker, gsym: GlobalSymbol) u32 {
        const gp = self.ctx.decl_generics.get(gsym.pack()) orelse return 0;
        return @intCast(gp.len);
    }

    /// The template `TypeId` for a struct/interface/alias declaration — its
    /// own generic params (if any) appear as unbound `type_param` leaves.
    /// Memoized; dependency-module symbols are always already memoized by the
    /// time this runs (see module doc comment), so a miss implies the symbol
    /// belongs to the module currently being checked.
    fn declTypeOf(self: *Checker, gsym: GlobalSymbol) Error!TypeId {
        if (self.ctx.decl_memo.get(gsym.pack())) |id| return id;
        std.debug.assert(gsym.module == self.module_id);
        const sym = self.symbolOf(gsym);
        return switch (sym.kind) {
            .struct_type => self.buildStructTemplate(gsym, sym),
            .interface_type => self.buildInterfaceTemplate(gsym, sym),
            .type_alias => self.buildAlias(gsym, sym),
            else => unreachable, // caller only reaches here for these three kinds
        };
    }

    /// Rebuilds a generic declaration's own env from `ctx.decl_generics`
    /// without re-running `buildOwnGenericEnv`'s bound-satisfaction
    /// diagnostics (already run once by `collectDecls`) — used when
    /// body-checking a generic function needs its own env a second time.
    /// `typeParamId` is a pure memo, so this is idempotent.
    fn rebuiltOwnGenericEnv(self: *Checker, gsym: GlobalSymbol) Error!GenericEnv {
        const params = self.ctx.decl_generics.get(gsym.pack()) orelse return &.{};
        if (params.len == 0) return &.{};
        var bindings = try self.gpa.alloc(GenericBinding, params.len);
        defer self.gpa.free(bindings);
        for (params, 0..) |p, i| bindings[i] = .{ .sym = p, .to = try self.ctx.typeParamId(p) };
        return dupe(self.ctx.arena(), GenericBinding, bindings);
    }

    /// Builds the `GenericEnv` for a declaration's own `<T, U: Bound>` list
    /// (empty if none), binding each param to its own rigid `type_param` id,
    /// and records the param symbols + any interface bounds into `ctx` for
    /// later instantiation-site arity/bound checks.
    fn buildOwnGenericEnv(self: *Checker, gsym: GlobalSymbol, file_idx: usize, generics_node: ast.Index) Error!GenericEnv {
        if (generics_node == ast.none) {
            try self.ctx.decl_generics.put(self.gpa, gsym.pack(), &.{});
            return &.{};
        }
        const mf = self.files[file_idx];
        const gp_nodes = mf.tree.kids(generics_node);
        var syms = try self.gpa.alloc(GlobalSymbol, gp_nodes.len);
        defer self.gpa.free(syms);
        var bindings = try self.gpa.alloc(GenericBinding, gp_nodes.len);

        for (gp_nodes, 0..) |gp, i| {
            const gk = mf.tree.kids(gp); // [name, constraint_or_none]
            const psym = self.nodeSymbol(file_idx, gk[0]).?;
            syms[i] = psym;
            bindings[i] = .{ .sym = psym, .to = try self.ctx.typeParamId(psym) };
        }
        try self.ctx.decl_generics.put(self.gpa, gsym.pack(), try dupe(self.ctx.arena(), GlobalSymbol, syms));
        const env: GenericEnv = try dupe(self.ctx.arena(), GenericBinding, bindings);
        self.gpa.free(bindings);

        for (gp_nodes, 0..) |gp, i| {
            const gk = mf.tree.kids(gp);
            if (gk[1] == ast.none) continue;
            var bounds: std.ArrayList(TypeId) = .empty;
            defer bounds.deinit(self.gpa);
            for (mf.tree.kids(gk[1])) |bound_name| {
                try bounds.append(self.gpa, try self.checkType(file_idx, bound_name, env));
            }
            try self.ctx.generic_bounds.put(self.gpa, syms[i].pack(), try dupe(self.ctx.arena(), TypeId, bounds.items));
        }
        return env;
    }

    fn buildStructTemplate(self: *Checker, gsym: GlobalSymbol, sym: Symbol) Error!TypeId {
        const placeholder = try self.ctx.types.reserve(.{ .@"struct" = &.{} });
        try self.ctx.decl_memo.put(self.gpa, gsym.pack(), placeholder);
        const mf = self.files[sym.file_idx];
        const k = mf.tree.kids(sym.decl); // [name, generics, field_list]
        const env = try self.buildOwnGenericEnv(gsym, sym.file_idx, k[1]);

        var fields: std.ArrayList(Field) = .empty;
        defer fields.deinit(self.gpa);
        for (mf.tree.kids(k[2])) |item| {
            const exported = mf.tree.get(item).tag == .@"export";
            const field_node = unwrapExport(mf, item);
            const fk = mf.tree.kids(field_node); // [name, type]
            const fty = try self.checkType(sym.file_idx, fk[1], env);
            try fields.append(self.gpa, .{ .name = Checker.identText(mf, fk[0]), .ty = fty, .exported = exported });
        }
        self.ctx.types.fill(placeholder, .{ .@"struct" = try dupe(self.ctx.arena(), Field, fields.items) });
        try setDisplayName(self.ctx, placeholder, sym.name);
        return placeholder;
    }

    /// Recursively looks for a bare-or-nested reference to `Self` within a
    /// method-signature type node. Only interface bodies inject `Self`
    /// (`resolve.zig`'s `resolveInterfaceDecl`), and only the interface
    /// whose method sigs are currently being resolved has it in scope, so
    /// any symbol named "Self" found here is unambiguously *this*
    /// interface's own — never a different interface's.
    fn findSelfSymbol(self: *Checker, file_idx: usize, node: ast.Index, depth: u32) ?GlobalSymbol {
        if (node == ast.none or depth >= max_type_depth) return null;
        const mf = self.files[file_idx];
        return switch (mf.tree.get(node).tag) {
            .ident => blk: {
                const gs = self.nodeSymbol(file_idx, node) orelse break :blk null;
                if (std.mem.eql(u8, self.symbolOf(gs).name, "Self")) break :blk gs;
                break :blk null;
            },
            .slice_type, .chan_type => self.findSelfSymbol(file_idx, mf.tree.kids(node)[0], depth + 1),
            .array_type => self.findSelfSymbol(file_idx, mf.tree.kids(node)[1], depth + 1),
            .fallible => self.findSelfSymbol(file_idx, mf.tree.kids(node)[0], depth + 1),
            .generic_inst => blk: {
                for (mf.tree.kids(mf.tree.kids(node)[1])) |a| {
                    if (self.findSelfSymbol(file_idx, a, depth + 1)) |s| break :blk s;
                }
                break :blk null;
            },
            else => null,
        };
    }

    /// Records `iface`'s own `Self` symbol (§14.3) the first time a method
    /// signature's `type_node` mentions it. A no-op once recorded, and a
    /// no-op if `type_node` doesn't reference `Self` at all.
    fn recordIfaceSelf(self: *Checker, iface: TypeId, file_idx: usize, type_node: ast.Index) Error!void {
        const key = @intFromEnum(iface);
        if (self.ctx.iface_self.contains(key)) return;
        const gs = self.findSelfSymbol(file_idx, type_node, 0) orelse return;
        try self.ctx.iface_self.put(self.gpa, key, gs);
    }

    fn buildInterfaceTemplate(self: *Checker, gsym: GlobalSymbol, sym: Symbol) Error!TypeId {
        const placeholder = try self.ctx.types.reserve(.{ .interface = &.{} });
        try self.ctx.decl_memo.put(self.gpa, gsym.pack(), placeholder);
        const mf = self.files[sym.file_idx];
        const k = mf.tree.kids(sym.decl); // [name, generics, method_sig_list]
        const env = try self.buildOwnGenericEnv(gsym, sym.file_idx, k[1]);

        var methods: std.ArrayList(Method) = .empty;
        defer methods.deinit(self.gpa);
        for (mf.tree.kids(k[2])) |sig_idx| {
            const sk = mf.tree.kids(sig_idx); // [name, params, result_or_none]
            var params: std.ArrayList(TypeId) = .empty;
            defer params.deinit(self.gpa);
            var variadic = false;
            for (mf.tree.kids(sk[1])) |p_idx| {
                const pk = mf.tree.kids(p_idx);
                try params.append(self.gpa, try self.checkType(sym.file_idx, pk[1], env));
                if (mf.tree.get(p_idx).tag == .param_rest) variadic = true;
                try self.recordIfaceSelf(placeholder, sym.file_idx, pk[1]);
            }
            const result = if (sk[2] != ast.none) try self.checkResultTypeNode(sym.file_idx, sk[2], env) else self.ctx.void_id;
            if (sk[2] != ast.none) try self.recordIfaceSelf(placeholder, sym.file_idx, sk[2]);
            try methods.append(self.gpa, .{
                .name = Checker.identText(mf, sk[0]),
                .params = try dupe(self.ctx.arena(), TypeId, params.items),
                .variadic = variadic,
                .result = result,
            });
        }
        insertionSortMethods(methods.items);
        self.ctx.types.fill(placeholder, .{ .interface = try dupe(self.ctx.arena(), Method, methods.items) });
        try setDisplayName(self.ctx, placeholder, sym.name);
        return placeholder;
    }

    fn buildAlias(self: *Checker, gsym: GlobalSymbol, sym: Symbol) Error!TypeId {
        // Aliases are transparent (§10.2): reserve nothing — the alias's
        // `TypeId` *is* its target's. A self-referential alias would only
        // arise from a value-embedding cycle, already rejected upstream by
        // `resolve.zig`'s `checkTypeCycles`.
        const mf = self.files[sym.file_idx];
        const k = mf.tree.kids(sym.decl); // [name, generics, type]
        try self.ctx.decl_memo.put(self.gpa, gsym.pack(), self.ctx.void_id); // placeholder to break re-entry
        const env = try self.buildOwnGenericEnv(gsym, sym.file_idx, k[1]);
        const target = try self.checkType(sym.file_idx, k[2], env);
        try self.ctx.decl_memo.put(self.gpa, gsym.pack(), target);
        return target;
    }

    // ---- generic instantiation ----------------------------------------------

    fn instantiateRecursive(self: *Checker, gsym: GlobalSymbol, args: []const TypeId, template: TypeId, env: GenericEnv) Error!TypeId {
        const shape = self.ctx.typeOf(template);
        const id = try self.ctx.types.reserve(switch (shape) {
            .@"struct" => TypeData{ .@"struct" = &.{} },
            .interface => TypeData{ .interface = &.{} },
            else => unreachable,
        });
        try self.ctx.recordInstantiation(gsym, args, id);
        switch (shape) {
            .@"struct" => |fields| {
                var nf = try self.gpa.alloc(Field, fields.len);
                defer self.gpa.free(nf);
                for (fields, 0..) |f, i| nf[i] = .{ .name = f.name, .ty = try self.subst(f.ty, env, 0), .exported = f.exported };
                self.ctx.types.fill(id, .{ .@"struct" = try dupe(self.ctx.arena(), Field, nf) });
            },
            .interface => |methods| {
                var nm = try self.gpa.alloc(Method, methods.len);
                defer self.gpa.free(nm);
                for (methods, 0..) |m, i| nm[i] = try self.substMethod(m, env);
                self.ctx.types.fill(id, .{ .interface = try dupe(self.ctx.arena(), Method, nm) });
            },
            else => unreachable,
        }
        if (self.ctx.methodsOf(template)) |bucket| {
            var it = bucket.iterator();
            while (it.next()) |entry| {
                const sm = try self.substMethod(entry.value_ptr.*, env);
                const dst = try self.ctx.methodBucket(id);
                try dst.put(self.gpa, sm.name, sm);
            }
        }
        try setDisplayName(self.ctx, id, self.symbolOf(gsym).name);
        return id;
    }

    /// Instantiates generic declaration `gsym` at concrete `args`, validating
    /// arity/bounds and recording a monomorphization-ready `Instantiation`.
    fn instantiateGeneric(self: *Checker, gsym: GlobalSymbol, args: []const TypeId, mf: ModuleFile, node: ast.Index) Error!TypeId {
        if (self.ctx.findInstantiation(gsym, args)) |id| return id;
        const gparams = self.ctx.decl_generics.get(gsym.pack()) orelse &[_]GlobalSymbol{};
        var env_buf = try self.gpa.alloc(GenericBinding, gparams.len);
        defer self.gpa.free(env_buf);
        for (gparams, 0..) |gp, i| env_buf[i] = .{ .sym = gp, .to = args[i] };

        for (gparams, 0..) |gp, i| {
            const bounds = self.ctx.generic_bounds.get(gp.pack()) orelse continue;
            for (bounds) |bound_iface| {
                if (!self.satisfies(args[i], bound_iface, env_buf)) {
                    try self.emit(mf, node, .missing_method, "type argument {d} does not satisfy its interface bound", .{i}, "check the interface's method set against this type");
                }
            }
        }

        const template = try self.declTypeOf(gsym);
        const sym = self.symbolOf(gsym);
        return switch (sym.kind) {
            .type_alias => blk: {
                const result = try self.subst(template, env_buf, 0);
                try self.ctx.recordInstantiation(gsym, args, result);
                break :blk result;
            },
            .struct_type, .interface_type => self.instantiateRecursive(gsym, args, template, env_buf),
            else => unreachable,
        };
    }

    // ---- structural interface satisfaction (§14.3) --------------------------

    /// Does `candidate` satisfy `iface`, substituting `self_env`'s bindings
    /// (the interface's own generics) plus `Self -> candidate` (§14.3: "with
    /// Self bound to S") into each method before comparing? Used both for
    /// real assignability checks and generic-bound validation.
    fn satisfies(self: *Checker, candidate: TypeId, iface: TypeId, self_env: GenericEnv) bool {
        if (candidate == .invalid or iface == .invalid) return true; // cascade suppression
        const shape = self.ctx.typeOf(iface);
        if (shape != .interface) return candidate == iface;

        var owned: ?[]GenericBinding = null;
        defer if (owned) |o| self.gpa.free(o);
        var merged: GenericEnv = self_env;
        if (self.ctx.iface_self.get(@intFromEnum(iface))) |self_sym| {
            const buf = self.gpa.alloc(GenericBinding, self_env.len + 1) catch return false;
            @memcpy(buf[0..self_env.len], self_env);
            buf[self_env.len] = .{ .sym = self_sym, .to = candidate };
            owned = buf;
            merged = buf;
        }

        for (shape.interface) |m| {
            const want = self.substMethod(m, merged) catch return false;
            const bucket = self.ctx.methodsOf(candidate) orelse return false;
            const have = bucket.get(want.name) orelse return false;
            if (!methodShapeEql(have, want)) return false;
        }
        return true;
    }

    /// Method lookup on a receiver whose type is an *unbound* generic
    /// parameter `g` (a `type_param` receiver inside a generic body, §13.5):
    /// searches `g`'s interface bounds for a method named `name`,
    /// substituting that bound's own `Self` (if used) to `recv_ty` — `g`
    /// already stands for "whatever concrete type ends up here", exactly
    /// what `Self` means once instantiated. Returns the method's `func`
    /// type, or `null` if no bound declares `name`.
    fn boundMethod(self: *Checker, recv_ty: TypeId, g: GlobalSymbol, name: []const u8) Error!?TypeId {
        const bounds = self.ctx.generic_bounds.get(g.pack()) orelse return null;
        for (bounds) |bound_iface| {
            const shape = self.ctx.typeOf(bound_iface);
            if (shape != .interface) continue;
            for (shape.interface) |m| {
                if (!std.mem.eql(u8, m.name, name)) continue;
                var env_buf: [1]GenericBinding = undefined;
                const env: GenericEnv = if (self.ctx.iface_self.get(@intFromEnum(bound_iface))) |self_sym| blk: {
                    env_buf[0] = .{ .sym = self_sym, .to = recv_ty };
                    break :blk env_buf[0..1];
                } else &.{};
                const sub = try self.substMethod(m, env);
                return try self.ctx.types.intern(.{ .func = .{ .params = sub.params, .variadic = sub.variadic, .result = sub.result } });
            }
        }
        return null;
    }

    /// Nearest method name on `candidate` to `wanted`, for a "did you mean"
    /// hint on a failed interface satisfaction check. `null` if nothing is
    /// close (bounded edit distance, small alphabet of short identifiers).
    fn closestMethodName(self: *Checker, candidate: TypeId, wanted: []const u8) ?[]const u8 {
        const bucket = self.ctx.methodsOf(candidate) orelse return null;
        var best: ?[]const u8 = null;
        var best_dist: usize = std.math.maxInt(usize);
        var it = bucket.keyIterator();
        while (it.next()) |name| {
            const d = editDistance(name.*, wanted);
            if (d < best_dist) {
                best_dist = d;
                best = name.*;
            }
        }
        if (best_dist > 3) return null; // too far apart to be a useful hint
        return best;
    }

    // ---- decl collection (runs once per module, before body checking) ------

    /// A method's *own* additional generic params (`function (r: T) foo<U>`,
    /// rare beyond the receiver's own params). Bound to fresh rigid ids but,
    /// unlike a real declaration, not memoized for arity lookups — a call
    /// site can't explicitly instantiate these, only the receiver's own
    /// params (if any) participate in the language's real generic story.
    fn buildLocalGenericEnv(self: *Checker, file_idx: usize, generics_node: ast.Index) Error!GenericEnv {
        if (generics_node == ast.none) return &.{};
        const mf = self.files[file_idx];
        const gp_nodes = mf.tree.kids(generics_node);
        var bindings = try self.gpa.alloc(GenericBinding, gp_nodes.len);
        defer self.gpa.free(bindings);
        for (gp_nodes, 0..) |gp, i| {
            const gk = mf.tree.kids(gp);
            const psym = self.nodeSymbol(file_idx, gk[0]).?;
            bindings[i] = .{ .sym = psym, .to = try self.ctx.typeParamId(psym) };
        }
        return dupe(self.ctx.arena(), GenericBinding, bindings);
    }

    fn collectFuncDecl(self: *Checker, file_idx: usize, idx: ast.Index) Error!void {
        const mf = self.files[file_idx];
        const k = mf.tree.kids(idx); // [recv, name, generics, params, result, body]
        const is_method = k[0] != ast.none;
        var gsym: ?GlobalSymbol = null;
        const env: GenericEnv = if (is_method)
            try self.buildLocalGenericEnv(file_idx, k[2])
        else blk: {
            gsym = self.nodeSymbol(file_idx, k[1]).?;
            break :blk try self.buildOwnGenericEnv(gsym.?, file_idx, k[2]);
        };

        const param_nodes = mf.tree.kids(k[3]);
        var params = try self.gpa.alloc(TypeId, param_nodes.len);
        defer self.gpa.free(params);
        var variadic = false;
        for (param_nodes, 0..) |p_idx, i| {
            const pk = mf.tree.kids(p_idx); // [name, type]
            params[i] = try self.checkType(file_idx, pk[1], env);
            if (mf.tree.get(p_idx).tag == .param_rest) variadic = true;
        }
        const result = if (k[4] != ast.none) try self.checkResultTypeNode(file_idx, k[4], env) else self.ctx.void_id;
        const shape = FuncShape{
            .params = try dupe(self.ctx.arena(), TypeId, params),
            .variadic = variadic,
            .result = result,
        };

        if (!is_method) {
            try self.ctx.func_sigs.put(self.gpa, gsym.?.pack(), shape);
            return;
        }

        const rk = mf.tree.kids(k[0]); // receiver: [name, type_name]
        const recv_ty = try self.checkType(file_idx, rk[1], env);
        if (recv_ty == .invalid) return; // receiver type already failed to resolve; don't cascade
        const name = Checker.identText(mf, k[1]);
        const method = Method{ .name = name, .params = shape.params, .variadic = shape.variadic, .result = shape.result };
        const bucket = try self.ctx.methodBucket(recv_ty);
        if (bucket.contains(name)) {
            try self.emit(mf, k[1], .duplicate_declaration, "method '{s}' is already declared for this type", .{name}, "rename or remove one of the declarations");
            return;
        }
        try bucket.put(self.gpa, name, method);
        try self.method_ctx.put(self.gpa, packFileNode(file_idx, idx), .{ .recv_ty = recv_ty, .env = env });
    }

    fn collectTopDecl(self: *Checker, file_idx: usize, idx: ast.Index) Error!void {
        const mf = self.files[file_idx];
        const inner = if (mf.tree.get(idx).tag == .@"export") mf.tree.kids(idx)[0] else idx;
        switch (mf.tree.get(inner).tag) {
            .struct_decl, .interface_decl, .type_alias => {
                const gsym = self.nodeSymbol(file_idx, mf.tree.kids(inner)[0]) orelse return;
                _ = try self.declTypeOf(gsym);
            },
            .func_decl => try self.collectFuncDecl(file_idx, inner),
            .let_decl, .const_decl => {
                for (mf.tree.kids(inner)) |binding_idx| {
                    const bk = mf.tree.kids(binding_idx); // [pattern, type_or_none, init_or_none]
                    if (mf.tree.get(bk[0]).tag != .ident or bk[2] == ast.none) continue;
                    if (self.nodeSymbol(file_idx, bk[0])) |gsym| try self.const_inits.put(self.gpa, gsym.id, bk[2]);
                }
            },
            else => {},
        }
    }

    /// Computes every declared type/signature for this module up front,
    /// regardless of whether local code uses it yet — a dependent module
    /// checked later needs it (see module doc comment), and body-checking
    /// needs every sibling declaration resolvable regardless of source order
    /// (§9: order-independent top-level declarations).
    fn collectDecls(self: *Checker) Error!void {
        for (self.files, 0..) |mf, file_idx| {
            for (mf.tree.kids(mf.tree.root)) |decl_idx| {
                if (decl_idx == ast.none) continue;
                try self.collectTopDecl(file_idx, decl_idx);
            }
        }
    }

    // ---- assignability, defaulting, and the bounded constant evaluator -----

    /// The concrete type an untyped constant assumes with no expected type to
    /// adapt to (§15.4). Anything else is returned unchanged.
    fn defaultType(self: *Checker, ty: TypeId) TypeId {
        if (ty == self.ctx.untyped_int_id) return self.ctx.prim_ids.get(.i64);
        if (ty == self.ctx.untyped_float_id) return self.ctx.prim_ids.get(.f64);
        if (ty == self.ctx.untyped_rune_id) return self.ctx.prim_ids.get(.i32);
        if (ty == self.ctx.untyped_bool_id) return self.ctx.prim_ids.get(.bool);
        if (ty == self.ctx.untyped_string_id) return self.ctx.prim_ids.get(.string);
        return ty;
    }

    fn isUntyped(self: *Checker, ty: TypeId) bool {
        return ty == self.ctx.untyped_int_id or ty == self.ctx.untyped_float_id or
            ty == self.ctx.untyped_rune_id or ty == self.ctx.untyped_bool_id or
            ty == self.ctx.untyped_string_id or ty == self.ctx.untyped_nil_id;
    }

    fn representable(self: *Checker, value: i128, to: TypeId) bool {
        const data = self.ctx.typeOf(to);
        if (data != .prim) return false;
        if (data.prim.isFloat()) return true; // int constant widened to float: always representable
        if (!data.prim.isInteger()) return false;
        const r = data.prim.intRange();
        return value >= r.min and value <= r.max;
    }

    /// Peels at most one leading unary `+`/`-` and reports the literal value
    /// underneath, for representability checks against a directly-written
    /// literal (§15.4). `null` for anything else — see module doc comment on
    /// the scope of constant folding here (direct literals only; compound
    /// constant expressions default-type instead of range-checking).
    fn literalValue(self: *Checker, file_idx: usize, node: ast.Index) ?i128 {
        const mf = self.files[file_idx];
        var n = node;
        var negate = false;
        if (mf.tree.get(n).tag == .unary) {
            const op: lexer.Kind = @enumFromInt(mf.tree.get(n).main);
            if (op != .minus and op != .plus) return null;
            negate = op == .minus;
            n = mf.tree.kids(n)[0];
        }
        const nn = mf.tree.get(n);
        const v: i128 = switch (nn.tag) {
            .int_lit => parseIntLiteral(Checker.identText(mf, n)),
            .rune_lit => parseRuneLiteral(Checker.identText(mf, n)),
            else => return null,
        };
        return if (negate) -v else v;
    }

    /// The real assignability entry point (§14.2): `node` is the source
    /// expression being assigned/passed, used to range-check a direct integer
    /// literal against a sized target; falls back to `assignable` (identity,
    /// interface satisfaction, or default-typed untyped constants) otherwise.
    fn assignableNode(self: *Checker, file_idx: usize, node: ast.Index, from: TypeId, to: TypeId) bool {
        if (from == .invalid or to == .invalid) return true;
        if ((from == self.ctx.untyped_int_id or from == self.ctx.untyped_rune_id) and self.ctx.typeOf(to) == .prim) {
            if (self.literalValue(file_idx, node)) |v| return self.representable(v, to);
        }
        return self.assignable(from, to);
    }

    /// Structural assignability (§14.2) with no source-literal awareness:
    /// identity, interface satisfaction, `nil` into a nilable type, or an
    /// untyped constant whose *default* type matches `to` exactly.
    fn assignable(self: *Checker, from: TypeId, to: TypeId) bool {
        if (from == .invalid or to == .invalid) return true;
        if (from == to) return true;
        if (self.ctx.typeOf(to) == .interface) return self.satisfies(from, to, &.{});
        if (from == self.ctx.untyped_nil_id) return self.isNilable(to);
        if (self.isUntyped(from)) {
            const def = self.defaultType(from);
            if (def == to) return true;
            // A float constant is representable in either float width; an
            // int/rune constant is representable in any numeric prim subject
            // to range (checked by `assignableNode` when a literal is handed
            // in — here, with no node, only exact-width float widening is safe).
            if (from == self.ctx.untyped_float_id and self.ctx.typeOf(to) == .prim) return self.ctx.typeOf(to).prim.isFloat();
            return false;
        }
        return false;
    }

    const ConstVal = union(enum) { int: i128, float: f64, boolean: bool, string };

    /// Bounded compile-time constant evaluator (§15.4): literals, unary
    /// +/-/! over a constant, binary arithmetic/bitwise ops over two integer
    /// constants, and references to other `const` bindings in this module.
    /// Returns `null` when `node` is not a compile-time constant expression.
    /// Deliberately narrow — see module doc comment: no float arithmetic
    /// folding, no cross-module consts, no string content decoding (only
    /// "is this constant at all", which a bare string literal always is).
    fn constEval(self: *Checker, file_idx: usize, node: ast.Index, depth: u32) ?ConstVal {
        if (depth >= max_type_depth) return null;
        const mf = self.files[file_idx];
        const n = mf.tree.get(node);
        switch (n.tag) {
            .int_lit => return .{ .int = parseIntLiteral(Checker.identText(mf, node)) },
            .rune_lit => return .{ .int = parseRuneLiteral(Checker.identText(mf, node)) },
            .float_lit => return .{ .float = parseFloatLiteral(Checker.identText(mf, node)) },
            .bool_lit => return .{ .boolean = std.mem.eql(u8, Checker.identText(mf, node), "true") },
            .string_lit, .raw_string_lit => return .string,
            .unary => {
                const operand = mf.tree.kids(node)[0];
                const v = self.constEval(file_idx, operand, depth + 1) orelse return null;
                const op: lexer.Kind = @enumFromInt(n.main);
                return switch (op) {
                    .minus => switch (v) {
                        .int => |x| .{ .int = -x },
                        .float => |x| .{ .float = -x },
                        else => null,
                    },
                    .plus => v,
                    .bang => switch (v) {
                        .boolean => |x| .{ .boolean = !x },
                        else => null,
                    },
                    else => null,
                };
            },
            .binary => {
                const k = mf.tree.kids(node);
                const a = self.constEval(file_idx, k[0], depth + 1) orelse return null;
                const b = self.constEval(file_idx, k[1], depth + 1) orelse return null;
                if (a != .int or b != .int) return null;
                const op: lexer.Kind = @enumFromInt(n.main);
                return switch (op) {
                    .plus => .{ .int = a.int + b.int },
                    .minus => .{ .int = a.int - b.int },
                    .star => .{ .int = a.int * b.int },
                    .slash => if (b.int == 0) null else .{ .int = @divTrunc(a.int, b.int) },
                    .percent => if (b.int == 0) null else .{ .int = @rem(a.int, b.int) },
                    .amp => .{ .int = a.int & b.int },
                    .pipe => .{ .int = a.int | b.int },
                    .caret => .{ .int = a.int ^ b.int },
                    .shl => if (b.int < 0 or b.int > 127) null else .{ .int = a.int << @intCast(b.int) },
                    .shr => if (b.int < 0 or b.int > 127) null else .{ .int = a.int >> @intCast(b.int) },
                    else => null,
                };
            },
            .ident => {
                const gsym = self.nodeSymbol(file_idx, node) orelse return null;
                if (gsym.module != self.module_id) return null; // cross-module folding: out of scope
                const sym = self.symbolOf(gsym);
                if (sym.kind != .const_binding) return null;
                const init_node = self.const_inits.get(gsym.id) orelse return null;
                return self.constEval(file_idx, init_node, depth + 1);
            },
            else => return null,
        }
    }

    // ---- body checking (§12–§13, §15–§18) ------------------------------------

    /// Per-function checking context, threaded **by value** through every
    /// statement/expression check — a Zig struct copy naturally "pops" when a
    /// recursive call returns, so `loop_depth`/`breakable_depth` never need
    /// manual restoring around a loop/switch/select body.
    const FnCtx = struct {
        env: GenericEnv,
        /// The function's declared result type — the *ok* type for a
        /// fallible function (never the boxed `.fallible` wrapper), `void_id`
        /// for one with no result type.
        result_ty: TypeId,
        /// Non-`.invalid` iff the enclosing function is fallible (§18.2): the
        /// concrete error type `fail`/`?` must produce/propagate.
        err_ty: TypeId = .invalid,
        /// Nesting depth of `for`/`while` — `continue` requires `> 0`.
        loop_depth: u32 = 0,
        /// Nesting depth of `for`/`while`/`switch`/`select` — `break` requires `> 0`.
        breakable_depth: u32 = 0,
    };

    // ---- type-name rendering (for expected-vs-found diagnostics) -----------

    fn typeName(self: *Checker, ty: TypeId) Error![]u8 {
        return describeType(.{
            .gpa = self.gpa,
            .ctx = self.ctx,
            .module_id = self.module_id,
            .module = self.module,
            .all_modules = self.all_modules,
        }, ty);
    }

    // ---- `bitc check --dump-types` (task #335 positive suite) --------------

    const TypeDumpEntry = struct { file_idx: usize, start: u32, text: []const u8, ty: TypeId };

    /// Appends one dump entry per name bound by binding-pattern `pat`
    /// (recursing through `tuple_pat` destructuring), using `pat`'s own
    /// already-`setType`'d node — see `bindSimple`/`bindPattern`.
    fn collectBindingIdents(self: *Checker, file_idx: usize, pat: ast.Index, out: *std.ArrayList(TypeDumpEntry)) Error!void {
        const mf = self.files[file_idx];
        if (mf.tree.get(pat).tag == .tuple_pat) {
            for (mf.tree.kids(pat)) |sub| try self.collectBindingIdents(file_idx, sub, out);
            return;
        }
        const span = mf.tree.get(pat).span;
        try out.append(self.gpa, .{ .file_idx = file_idx, .start = span.start, .text = mf.source[span.start..span.end], .ty = self.node_types[file_idx][pat] });
    }

    /// Renders the positive-suite surface named by task #335's Verify
    /// section: one `<line>:<col>: <source text>: <type>` line per
    /// `let`/`const` binding, lambda (arrow-fn) parameter, and call
    /// expression (whose type already reflects generic instantiation),
    /// sorted by source position across every file in this module. A
    /// golden diff against this output catches an inference regression at
    /// the exact expression it changed, not just "some diagnostic differs".
    fn dumpTypesText(self: *Checker) Error![]u8 {
        var entries: std.ArrayList(TypeDumpEntry) = .empty;
        defer entries.deinit(self.gpa);

        for (self.files, 0..) |mf, file_idx| {
            var idx: ast.Index = 0;
            // Bounded by this file's own node count (Power of 10: no
            // unbounded loop — `nodes.len` is fixed once parsing finishes).
            while (idx < mf.tree.nodes.len) : (idx += 1) {
                switch (mf.tree.get(idx).tag) {
                    .binding => try self.collectBindingIdents(file_idx, mf.tree.kids(idx)[0], &entries),
                    .arrow_p => {
                        const name = mf.tree.kids(idx)[0];
                        const span = mf.tree.get(name).span;
                        try entries.append(self.gpa, .{ .file_idx = file_idx, .start = span.start, .text = mf.source[span.start..span.end], .ty = self.node_types[file_idx][name] });
                    },
                    .call => {
                        const span = mf.tree.get(idx).span;
                        try entries.append(self.gpa, .{ .file_idx = file_idx, .start = span.start, .text = mf.source[span.start..span.end], .ty = self.node_types[file_idx][idx] });
                    },
                    else => {},
                }
            }
        }

        std.mem.sort(TypeDumpEntry, entries.items, {}, struct {
            fn lessThan(_: void, a: TypeDumpEntry, b: TypeDumpEntry) bool {
                if (a.file_idx != b.file_idx) return a.file_idx < b.file_idx;
                return a.start < b.start;
            }
        }.lessThan);

        var out: Writer.Allocating = .init(self.gpa);
        defer out.deinit();
        for (entries.items) |e| {
            const loc = locateOffset(self.files[e.file_idx].source, e.start);
            const tn = try self.typeName(e.ty);
            defer self.gpa.free(tn);
            // `Writer.Allocating` only ever fails on allocation, wrapped as
            // `WriteFailed` — translate back to this file's `Error` set.
            out.writer.print("{d}:{d}: {s}: {s}\n", .{ loc.line + 1, loc.col + 1, e.text, tn }) catch return Error.OutOfMemory;
        }
        return self.gpa.dupe(u8, out.written());
    }

    /// Emits `type_mismatch` with rendered expected/found type names.
    fn mismatch(self: *Checker, mf: ModuleFile, node: ast.Index, expected: TypeId, found: TypeId) Error!void {
        const en = try self.typeName(expected);
        defer self.gpa.free(en);
        const fnd = try self.typeName(found);
        defer self.gpa.free(fnd);
        try self.emit(mf, node, .type_mismatch, "expected '{s}', found '{s}'", .{ en, fnd }, null);
    }

    /// Checks `node`'s already-computed type `ty` against `target`, emitting
    /// `type_mismatch` on failure. `target == .invalid` means "no
    /// expectation" and is always a no-op (matches `.invalid`'s
    /// cascade-suppression contract throughout this file).
    fn expect(self: *Checker, file_idx: usize, node: ast.Index, ty: TypeId, target: TypeId) Error!void {
        if (target == .invalid) return;
        if (!self.assignableNode(file_idx, node, ty, target)) {
            try self.mismatch(self.files[file_idx], node, target, ty);
        }
    }

    fn emitOperandMismatch(self: *Checker, file_idx: usize, node: ast.Index, lty: TypeId, rty: TypeId) Error!void {
        const mf = self.files[file_idx];
        const ln = try self.typeName(lty);
        defer self.gpa.free(ln);
        const rn = try self.typeName(rty);
        defer self.gpa.free(rn);
        try self.emit(mf, node, .invalid_operand, "operator not defined for '{s}' and '{s}'", .{ ln, rn }, null);
    }

    fn notIndexable(self: *Checker, file_idx: usize, node: ast.Index, ty: TypeId) Error!void {
        const mf = self.files[file_idx];
        const n = try self.typeName(ty);
        defer self.gpa.free(n);
        try self.emit(mf, node, .not_indexable, "'{s}' cannot be indexed", .{n}, null);
    }

    fn stringish(self: *Checker, ty: TypeId) bool {
        if (ty == self.ctx.untyped_string_id) return true;
        const data = self.ctx.typeOf(ty);
        return data == .prim and data.prim == .string;
    }

    fn expectIntegerIndex(self: *Checker, file_idx: usize, node: ast.Index, ty: TypeId) Error!void {
        const ok = switch (self.ctx.typeOf(ty)) {
            .prim => |p| p.isInteger(),
            .untyped_int, .untyped_rune, .invalid => true,
            else => false,
        };
        if (!ok) {
            const n = try self.typeName(ty);
            defer self.gpa.free(n);
            try self.emit(self.files[file_idx], node, .invalid_operand, "index must be an integer, found '{s}'", .{n}, null);
        }
    }

    /// Resolves the common operand type for a binary/compound-assign op:
    /// identical concrete types match directly; an untyped constant on
    /// either side adapts to the other's concrete type (subject to
    /// representability for literals, §15.4); two untyped constants share a
    /// common type when their *default* types match. `.invalid` means "no
    /// valid common type" — the caller diagnoses.
    fn joinOperandTypes(self: *Checker, file_idx: usize, lhs: ast.Index, rhs: ast.Index, lty: TypeId, rty: TypeId) TypeId {
        if (lty == .invalid or rty == .invalid) return .invalid;
        if (lty == rty) return lty;
        const l_un = self.isUntyped(lty);
        const r_un = self.isUntyped(rty);
        if (l_un and !r_un) return if (self.assignableNode(file_idx, lhs, lty, rty)) rty else .invalid;
        if (r_un and !l_un) return if (self.assignableNode(file_idx, rhs, rty, lty)) lty else .invalid;
        if (l_un and r_un) return if (self.defaultType(lty) == self.defaultType(rty)) self.defaultType(lty) else .invalid;
        return .invalid;
    }

    fn binaryComparable(self: *Checker, file_idx: usize, k: []const ast.Index, lty: TypeId, rty: TypeId) bool {
        const joined = self.joinOperandTypes(file_idx, k[0], k[1], lty, rty);
        return joined != .invalid and self.comparable(joined);
    }

    fn checkNumericBinary(self: *Checker, file_idx: usize, node: ast.Index, k: []const ast.Index, lty: TypeId, rty: TypeId, require_integer: bool) Error!TypeId {
        const joined = self.joinOperandTypes(file_idx, k[0], k[1], lty, rty);
        const ok = joined != .invalid and switch (self.ctx.typeOf(joined)) {
            .prim => |p| if (require_integer) p.isInteger() else p.isNumeric(),
            .untyped_int, .untyped_rune => true,
            .untyped_float => !require_integer,
            else => false,
        };
        if (!ok) {
            try self.emitOperandMismatch(file_idx, node, lty, rty);
            return .invalid;
        }
        return joined;
    }

    // ---- generic function calls (§15.3) -------------------------------------

    /// Delegates to `TypeContext.substFuncShape` — see `subst`'s doc comment
    /// on why this moved out of `Checker`.
    fn substFuncShape(self: *Checker, shape: FuncShape, env: GenericEnv) Error!FuncShape {
        return self.ctx.substFuncShape(shape, env);
    }

    /// Mirrors `instantiateGeneric` for a generic *function* symbol: caches
    /// via the same `ctx.instantiations` ledger (task's "monomorphization-
    /// ready instantiation records"), keyed by the same `(generic, args)`
    /// pair, with the recorded "result" being the instantiated `.func`
    /// `TypeId` itself (unwrapped back to a `FuncShape` on a cache hit).
    fn instantiateFunc(self: *Checker, gsym: GlobalSymbol, args: []const TypeId, mf: ModuleFile, node: ast.Index) Error!FuncShape {
        if (self.ctx.findInstantiation(gsym, args)) |id| return self.ctx.typeOf(id).func;
        const gparams = self.ctx.decl_generics.get(gsym.pack()) orelse &[_]GlobalSymbol{};
        var env_buf = try self.gpa.alloc(GenericBinding, gparams.len);
        defer self.gpa.free(env_buf);
        for (gparams, 0..) |gp, i| env_buf[i] = .{ .sym = gp, .to = args[i] };

        for (gparams, 0..) |gp, i| {
            const bounds = self.ctx.generic_bounds.get(gp.pack()) orelse continue;
            for (bounds) |bound_iface| {
                if (!self.satisfies(args[i], bound_iface, env_buf)) {
                    try self.emit(mf, node, .missing_method, "type argument {d} does not satisfy its interface bound", .{i}, "check the interface's method set against this type");
                }
            }
        }

        const template = self.ctx.func_sigs.get(gsym.pack()) orelse FuncShape{ .params = &.{}, .variadic = false, .result = self.ctx.void_id };
        const shape = try self.substFuncShape(template, env_buf);
        const result_id = try self.ctx.types.intern(.{ .func = shape });
        try self.ctx.recordInstantiation(gsym, args, result_id);
        return shape;
    }

    /// Best-effort structural unification: binds each `type_param` leaf in
    /// `template` that belongs to `gparams` to the corresponding position in
    /// `actual`, keeping the first binding seen. Shape mismatches are
    /// silently skipped — the later per-argument assignability check
    /// (against whatever ends up bound, or nothing) surfaces the real
    /// diagnostic with a precise span, so unification itself never emits.
    fn unify(self: *Checker, template: TypeId, actual: TypeId, gparams: []const GlobalSymbol, bound: []?TypeId, depth: u32) void {
        if (depth >= max_type_depth or actual == .invalid) return;
        switch (self.ctx.typeOf(template)) {
            .type_param => |g| {
                for (gparams, 0..) |gp, i| {
                    if (gp.module == g.module and gp.id == g.id) {
                        if (bound[i] == null) bound[i] = actual;
                        return;
                    }
                }
            },
            .slice => |e| if (self.ctx.typeOf(actual) == .slice) self.unify(e, self.ctx.typeOf(actual).slice, gparams, bound, depth + 1),
            .chan => |e| if (self.ctx.typeOf(actual) == .chan) self.unify(e, self.ctx.typeOf(actual).chan, gparams, bound, depth + 1),
            .array => |a| if (self.ctx.typeOf(actual) == .array) self.unify(a.elem, self.ctx.typeOf(actual).array.elem, gparams, bound, depth + 1),
            .map => |m| if (self.ctx.typeOf(actual) == .map) {
                const am = self.ctx.typeOf(actual).map;
                self.unify(m.key, am.key, gparams, bound, depth + 1);
                self.unify(m.val, am.val, gparams, bound, depth + 1);
            },
            .tuple => |ts| if (self.ctx.typeOf(actual) == .tuple) {
                const ats = self.ctx.typeOf(actual).tuple;
                if (ats.len == ts.len) for (ts, ats) |tt, at| self.unify(tt, at, gparams, bound, depth + 1);
            },
            .func => |f| if (self.ctx.typeOf(actual) == .func) {
                const af = self.ctx.typeOf(actual).func;
                if (af.params.len == f.params.len) {
                    for (f.params, af.params) |tp, ap| self.unify(tp, ap, gparams, bound, depth + 1);
                    self.unify(f.result, af.result, gparams, bound, depth + 1);
                }
            },
            else => {},
        }
    }

    /// Links call-site `node` to the `(gsym, args)` instantiation it just
    /// resolved to — see `call_insts`'s doc comment. `instantiateFunc` just
    /// above always either found or recorded exactly this pair, so the index
    /// is always present.
    fn recordCallInstantiation(self: *Checker, file_idx: usize, node: ast.Index, gsym: GlobalSymbol, args: []const TypeId) Error!void {
        const idx = self.ctx.findInstantiationIndex(gsym, args).?;
        try self.call_insts.put(self.gpa, packFileNode(file_idx, node), idx);
    }

    fn checkGenericCall(self: *Checker, file_idx: usize, node: ast.Index, gsym: GlobalSymbol, type_args_node: ast.Index, arg_items: []const ast.Index, env: GenericEnv, fctx: FnCtx, expected: TypeId) Error!TypeId {
        _ = expected;
        const mf = self.files[file_idx];
        const template = self.ctx.func_sigs.get(gsym.pack()) orelse FuncShape{ .params = &.{}, .variadic = false, .result = self.ctx.void_id };

        if (type_args_node != ast.none) {
            const targ_nodes = mf.tree.kids(type_args_node);
            var targs = try self.gpa.alloc(TypeId, targ_nodes.len);
            defer self.gpa.free(targs);
            for (targ_nodes, 0..) |t, i| targs[i] = try self.checkType(file_idx, t, env);
            const want = self.declGenericArity(gsym);
            if (want != targs.len) {
                try self.emit(mf, node, .generic_arity_mismatch, "'{s}' expects {d} type argument(s), found {d}", .{ self.symbolOf(gsym).name, want, targs.len }, null);
                try self.checkArgsLoose(file_idx, arg_items, env, fctx);
                return .invalid;
            }
            const shape = try self.instantiateFunc(gsym, targs, mf, node);
            try self.recordCallInstantiation(file_idx, node, gsym, targs);
            try self.checkArgs(file_idx, node, shape, arg_items, env, fctx);
            return shape.result;
        }

        // Implicit inference (§15.3): unify each fixed param's template type
        // against its argument's natural (no expected-type push) type. A
        // `...spread` argument into a generic variadic call isn't unified
        // precisely (narrow gap: rare combination of two advanced features);
        // it's still type-checked, just not used to solve a type parameter.
        const gparams = self.ctx.decl_generics.get(gsym.pack()) orelse &[_]GlobalSymbol{};
        const bound = try self.gpa.alloc(?TypeId, gparams.len);
        defer self.gpa.free(bound);
        @memset(bound, null);

        const fixed = if (template.variadic) template.params.len - 1 else template.params.len;
        var natural = try self.gpa.alloc(TypeId, arg_items.len);
        defer self.gpa.free(natural);
        for (arg_items, 0..) |a, i| {
            natural[i] = try self.checkArgExprType(file_idx, a, env, fctx);
            const template_ty: ?TypeId = if (i < fixed) template.params[i] else if (template.variadic) template.params[template.params.len - 1] else null;
            if (template_ty) |tt| self.unify(tt, self.defaultType(natural[i]), gparams, bound, 0);
        }

        var args = try self.gpa.alloc(TypeId, gparams.len);
        defer self.gpa.free(args);
        var all_bound = true;
        for (bound, 0..) |b, i| {
            if (b) |t| {
                args[i] = t;
            } else {
                all_bound = false;
                try self.emit(mf, node, .cannot_infer_type, "cannot infer type argument for '{s}'; write it explicitly as '{s}<...>'", .{ self.symbolOf(gparams[i]).name, self.symbolOf(gsym).name }, null);
            }
        }
        if (!all_bound) return .invalid;

        const shape = try self.instantiateFunc(gsym, args, mf, node);
        try self.recordCallInstantiation(file_idx, node, gsym, args);
        // Arguments were already checked above for their *natural* types
        // (each `checkExpr` ran exactly once); only the assignability check
        // against the now-concrete substituted param type remains, reusing
        // that cached type rather than re-checking the expression — so a
        // broken argument is never double-diagnosed.
        for (arg_items, 0..) |a, i| {
            const inner = mf.tree.kids(a)[0];
            const param_ty: TypeId = if (i < fixed) shape.params[i] else if (shape.variadic) shape.params[shape.params.len - 1] else .invalid;
            if (param_ty != .invalid) try self.expect(file_idx, inner, natural[i], param_ty);
        }
        if (!shape.variadic and arg_items.len != shape.params.len) {
            try self.emit(mf, node, .arg_count_mismatch, "expected {d} argument(s), found {d}", .{ shape.params.len, arg_items.len }, null);
        } else if (shape.variadic and arg_items.len < fixed) {
            try self.emit(mf, node, .arg_count_mismatch, "expected at least {d} argument(s), found {d}", .{ fixed, arg_items.len }, null);
        }
        return shape.result;
    }

    // ---- calls, construction/conversion (§12.4, §12.9) ----------------------

    fn calleeIsType(self: *Checker, file_idx: usize, node: ast.Index) bool {
        const mf = self.files[file_idx];
        switch (mf.tree.get(node).tag) {
            .slice_type, .array_type, .map_type, .chan_type => return true,
            .ident => {
                const gsym = self.nodeSymbol(file_idx, node) orelse return false;
                return switch (self.symbolOf(gsym).kind) {
                    .builtin_type, .struct_type, .interface_type, .type_alias => true,
                    else => false,
                };
            },
            .generic_inst => {
                const gsym = self.nodeSymbol(file_idx, mf.tree.kids(node)[0]) orelse return false;
                return switch (self.symbolOf(gsym).kind) {
                    .struct_type, .interface_type, .type_alias => true,
                    else => false,
                };
            },
            else => return false,
        }
    }

    /// Unwraps an `arg`/`arg_spread` node and checks its inner expression
    /// with no expected type. Flags a bare spread outside a real variadic
    /// call site (constructors, generic-inference natural-typing) — a
    /// legitimate variadic spread is validated by `checkArgs` instead.
    fn checkArgExprType(self: *Checker, file_idx: usize, arg_node: ast.Index, env: GenericEnv, fctx: FnCtx) Error!TypeId {
        const mf = self.files[file_idx];
        const inner = mf.tree.kids(arg_node)[0];
        return self.checkExpr(file_idx, inner, env, fctx, .invalid);
    }

    /// Type-checks every argument with no further validation — used once a
    /// call has already been diagnosed as malformed, so each argument still
    /// gets a type without a cascade of secondary diagnostics.
    fn checkArgsLoose(self: *Checker, file_idx: usize, arg_items: []const ast.Index, env: GenericEnv, fctx: FnCtx) Error!void {
        for (arg_items) |a| _ = try self.checkArgExprType(file_idx, a, env, fctx);
    }

    fn expectNumeric(self: *Checker, file_idx: usize, node: ast.Index, ty: TypeId) Error!void {
        const ok = switch (self.ctx.typeOf(ty)) {
            .prim => |p| p.isNumeric(),
            .untyped_int, .untyped_float, .untyped_rune, .invalid => true,
            else => false,
        };
        if (!ok) {
            const n = try self.typeName(ty);
            defer self.gpa.free(n);
            try self.emit(self.files[file_idx], node, .invalid_operand, "expected a numeric value, found '{s}'", .{n}, null);
        }
    }

    /// A type used in call position converts or constructs (§12.9): numeric/
    /// string conversions, slice allocation `[]T(n[, m])`, empty map
    /// `map<K,V>()`, channel construction `chan<T>([cap])`. Anything else
    /// (struct, interface, array, tuple, func, a bare type param) isn't
    /// call-constructible per the grammar (structs use a composite literal).
    fn checkConstruction(self: *Checker, file_idx: usize, node: ast.Index, target: TypeId, arg_items: []const ast.Index, env: GenericEnv, fctx: FnCtx) Error!TypeId {
        const mf = self.files[file_idx];
        switch (self.ctx.typeOf(target)) {
            .prim => |p| {
                if (arg_items.len != 1) {
                    try self.emit(mf, node, .arg_count_mismatch, "conversion takes exactly 1 argument, found {d}", .{arg_items.len}, null);
                    try self.checkArgsLoose(file_idx, arg_items, env, fctx);
                    return target;
                }
                const arg_ty = try self.checkArgExprType(file_idx, arg_items[0], env, fctx);
                const ok = switch (self.ctx.typeOf(arg_ty)) {
                    .prim => |ap| p.isNumeric() and ap.isNumeric(),
                    .untyped_int, .untyped_float, .untyped_rune => p.isNumeric(),
                    .untyped_string => p == .string,
                    .slice => |e| p == .string and (e == self.ctx.prim_ids.get(.u8) or e == self.ctx.prim_ids.get(.i32)),
                    .invalid => true,
                    else => false,
                };
                if (!ok) {
                    const fname = try self.typeName(arg_ty);
                    defer self.gpa.free(fname);
                    try self.emit(mf, node, .invalid_operand, "cannot convert '{s}' to '{s}'", .{ fname, @tagName(p) }, null);
                }
                return target;
            },
            .slice => |elem| {
                if (arg_items.len == 1) {
                    const arg_ty = try self.checkArgExprType(file_idx, arg_items[0], env, fctx);
                    const arg_data = self.ctx.typeOf(arg_ty);
                    const is_string_conv = arg_data == .prim and arg_data.prim == .string and
                        (elem == self.ctx.prim_ids.get(.u8) or elem == self.ctx.prim_ids.get(.i32));
                    if (!is_string_conv) try self.expectNumeric(file_idx, arg_items[0], arg_ty);
                    return target;
                }
                if (arg_items.len == 2) {
                    for (arg_items) |a| {
                        const t = try self.checkArgExprType(file_idx, a, env, fctx);
                        try self.expectNumeric(file_idx, a, t);
                    }
                    return target;
                }
                try self.emit(mf, node, .arg_count_mismatch, "slice constructor takes 1 or 2 arguments, found {d}", .{arg_items.len}, null);
                try self.checkArgsLoose(file_idx, arg_items, env, fctx);
                return target;
            },
            .map => {
                if (arg_items.len != 0) {
                    try self.emit(mf, node, .arg_count_mismatch, "map constructor takes no arguments, found {d}", .{arg_items.len}, null);
                    try self.checkArgsLoose(file_idx, arg_items, env, fctx);
                }
                return target;
            },
            .chan => {
                if (arg_items.len > 1) {
                    try self.emit(mf, node, .arg_count_mismatch, "channel constructor takes 0 or 1 arguments, found {d}", .{arg_items.len}, null);
                    try self.checkArgsLoose(file_idx, arg_items, env, fctx);
                    return target;
                }
                if (arg_items.len == 1) {
                    const t = try self.checkArgExprType(file_idx, arg_items[0], env, fctx);
                    try self.expectNumeric(file_idx, arg_items[0], t);
                }
                return target;
            },
            else => {
                const name = try self.typeName(target);
                defer self.gpa.free(name);
                try self.emit(mf, node, .not_callable, "'{s}' cannot be constructed with '()'; use a composite literal", .{name}, null);
                try self.checkArgsLoose(file_idx, arg_items, env, fctx);
                return target;
            },
        }
    }

    /// Checks a concrete (non-generic, or already-substituted) call's
    /// arguments: at most one `...spread`, only as the final argument of a
    /// variadic call; count matching; per-argument assignability.
    fn checkArgs(self: *Checker, file_idx: usize, node: ast.Index, shape: FuncShape, arg_items: []const ast.Index, env: GenericEnv, fctx: FnCtx) Error!void {
        const mf = self.files[file_idx];
        const fixed = if (shape.variadic) shape.params.len - 1 else shape.params.len;
        var spread_idx: ?usize = null;
        for (arg_items, 0..) |a, i| {
            if (mf.tree.get(a).tag == .arg_spread) {
                if (spread_idx != null or !shape.variadic or i != arg_items.len - 1) {
                    try self.emit(mf, a, .invalid_spread, "'...' spread is only valid as the final argument of a variadic call", .{}, null);
                }
                spread_idx = i;
            }
        }

        if (spread_idx) |si| {
            if (si != fixed) {
                try self.emit(mf, node, .arg_count_mismatch, "expected {d} argument(s) before '...', found {d}", .{ fixed, si }, null);
            }
            var i: usize = 0;
            while (i < si and i < fixed) : (i += 1) {
                const inner = mf.tree.kids(arg_items[i])[0];
                const t = try self.checkExpr(file_idx, inner, env, fctx, shape.params[i]);
                try self.expect(file_idx, inner, t, shape.params[i]);
            }
            const spread_inner = mf.tree.kids(arg_items[si])[0];
            const spread_ty = try self.checkExpr(file_idx, spread_inner, env, fctx, .invalid);
            const want = try self.ctx.types.intern(.{ .slice = shape.params[shape.params.len - 1] });
            try self.expect(file_idx, spread_inner, spread_ty, want);
            return;
        }

        if (shape.variadic) {
            if (arg_items.len < fixed) {
                try self.emit(mf, node, .arg_count_mismatch, "expected at least {d} argument(s), found {d}", .{ fixed, arg_items.len }, null);
            }
        } else if (arg_items.len != fixed) {
            try self.emit(mf, node, .arg_count_mismatch, "expected {d} argument(s), found {d}", .{ fixed, arg_items.len }, null);
        }

        for (arg_items, 0..) |a, i| {
            const inner = mf.tree.kids(a)[0];
            const param_ty: TypeId = if (i < fixed) shape.params[i] else if (shape.variadic) shape.params[shape.params.len - 1] else .invalid;
            const t = try self.checkExpr(file_idx, inner, env, fctx, param_ty);
            if (param_ty != .invalid) try self.expect(file_idx, inner, t, param_ty);
        }
    }

    /// The 7 predeclared builtin functions (§5.3/§16): not user-declared, so
    /// dispatched by name rather than through `ctx.func_sigs`.
    fn checkBuiltinCall(self: *Checker, file_idx: usize, node: ast.Index, name: []const u8, arg_items: []const ast.Index, env: GenericEnv, fctx: FnCtx) Error!TypeId {
        const mf = self.files[file_idx];
        if (std.mem.eql(u8, name, "len") or std.mem.eql(u8, name, "cap")) {
            if (arg_items.len != 1) {
                try self.emit(mf, node, .arg_count_mismatch, "'{s}' takes exactly 1 argument, found {d}", .{ name, arg_items.len }, null);
            }
            try self.checkArgsLoose(file_idx, arg_items, env, fctx);
            return self.ctx.prim_ids.get(.i64);
        }
        if (std.mem.eql(u8, name, "append")) {
            if (arg_items.len == 0) {
                try self.emit(mf, node, .arg_count_mismatch, "'append' takes a slice and its new elements", .{}, null);
                return .invalid;
            }
            const slice_ty = try self.checkArgExprType(file_idx, arg_items[0], env, fctx);
            if (self.ctx.typeOf(slice_ty) != .slice) {
                if (slice_ty != .invalid) try self.notIndexable(file_idx, arg_items[0], slice_ty);
                try self.checkArgsLoose(file_idx, arg_items[1..], env, fctx);
                return .invalid;
            }
            const elem = self.ctx.typeOf(slice_ty).slice;
            for (arg_items[1..]) |a| {
                const inner = mf.tree.kids(a)[0];
                const t = try self.checkExpr(file_idx, inner, env, fctx, elem);
                try self.expect(file_idx, inner, t, elem);
            }
            return slice_ty;
        }
        if (std.mem.eql(u8, name, "delete")) {
            if (arg_items.len != 2) {
                try self.emit(mf, node, .arg_count_mismatch, "'delete' takes a map and a key, found {d} argument(s)", .{arg_items.len}, null);
                try self.checkArgsLoose(file_idx, arg_items, env, fctx);
                return self.ctx.void_id;
            }
            const map_ty = try self.checkArgExprType(file_idx, arg_items[0], env, fctx);
            if (self.ctx.typeOf(map_ty) != .map) {
                if (map_ty != .invalid) try self.notIndexable(file_idx, arg_items[0], map_ty);
                _ = try self.checkArgExprType(file_idx, arg_items[1], env, fctx);
                return self.ctx.void_id;
            }
            const key = self.ctx.typeOf(map_ty).map.key;
            const inner = mf.tree.kids(arg_items[1])[0];
            const t = try self.checkExpr(file_idx, inner, env, fctx, key);
            try self.expect(file_idx, inner, t, key);
            return self.ctx.void_id;
        }
        if (std.mem.eql(u8, name, "close")) {
            if (arg_items.len != 1) {
                try self.emit(mf, node, .arg_count_mismatch, "'close' takes exactly 1 argument, found {d}", .{arg_items.len}, null);
            } else {
                const t = try self.checkArgExprType(file_idx, arg_items[0], env, fctx);
                if (t != .invalid and self.ctx.typeOf(t) != .chan) {
                    const n = try self.typeName(t);
                    defer self.gpa.free(n);
                    try self.emit(mf, arg_items[0], .invalid_operand, "'close' requires a channel, found '{s}'", .{n}, null);
                }
            }
            return self.ctx.void_id;
        }
        if (std.mem.eql(u8, name, "panic")) {
            if (arg_items.len != 1) {
                try self.emit(mf, node, .arg_count_mismatch, "'panic' takes exactly 1 argument, found {d}", .{arg_items.len}, null);
            }
            try self.checkArgsLoose(file_idx, arg_items, env, fctx);
            return self.ctx.void_id;
        }
        if (std.mem.eql(u8, name, "print")) {
            if (arg_items.len != 1) {
                try self.emit(mf, node, .arg_count_mismatch, "'print' takes exactly 1 argument, found {d}", .{arg_items.len}, null);
            }
            if (arg_items.len >= 1) {
                const inner = mf.tree.kids(arg_items[0])[0];
                const t = try self.checkExpr(file_idx, inner, env, fctx, self.ctx.prim_ids.get(.string));
                try self.expect(file_idx, inner, t, self.ctx.prim_ids.get(.string));
            }
            return self.ctx.void_id;
        }
        if (std.mem.eql(u8, name, "assert")) {
            if (arg_items.len != 1 and arg_items.len != 2) {
                try self.emit(mf, node, .arg_count_mismatch, "'assert' takes a condition and an optional message, found {d} argument(s)", .{arg_items.len}, null);
            }
            if (arg_items.len >= 1) {
                const inner = mf.tree.kids(arg_items[0])[0];
                const t = try self.checkExpr(file_idx, inner, env, fctx, self.ctx.prim_ids.get(.bool));
                try self.expect(file_idx, inner, t, self.ctx.prim_ids.get(.bool));
            }
            if (arg_items.len >= 2) _ = try self.checkArgExprType(file_idx, arg_items[1], env, fctx);
            return self.ctx.void_id;
        }
        // Low-level filesystem primitives (ABI.md §14). Fixed signatures over
        // string/i64/bool; the fallible File/open/readFile ergonomics live in
        // std/fs, so these stay plain (errors surface as a -1 fd / byte count).
        const string_id = self.ctx.prim_ids.get(.string);
        const i64_id = self.ctx.prim_ids.get(.i64);
        const bool_id = self.ctx.prim_ids.get(.bool);
        if (std.mem.eql(u8, name, "fsOpen")) {
            try self.checkFixedArgs(file_idx, node, name, arg_items, &.{ string_id, bool_id }, env, fctx);
            return i64_id;
        }
        if (std.mem.eql(u8, name, "fsReadAll")) {
            try self.checkFixedArgs(file_idx, node, name, arg_items, &.{i64_id}, env, fctx);
            return string_id;
        }
        if (std.mem.eql(u8, name, "fsWrite")) {
            try self.checkFixedArgs(file_idx, node, name, arg_items, &.{ i64_id, string_id }, env, fctx);
            return i64_id;
        }
        if (std.mem.eql(u8, name, "fsClose")) {
            try self.checkFixedArgs(file_idx, node, name, arg_items, &.{i64_id}, env, fctx);
            return i64_id;
        }
        if (std.mem.eql(u8, name, "fsqrt")) {
            const f64_id = self.ctx.prim_ids.get(.f64);
            try self.checkFixedArgs(file_idx, node, name, arg_items, &.{f64_id}, env, fctx);
            return f64_id;
        }
        try self.checkArgsLoose(file_idx, arg_items, env, fctx);
        return .invalid;
    }

    /// Checks a fixed-arity builtin call: exactly `want.len` arguments, each
    /// assignable to its declared type. Used by the filesystem primitives.
    fn checkFixedArgs(self: *Checker, file_idx: usize, node: ast.Index, name: []const u8, arg_items: []const ast.Index, want: []const TypeId, env: GenericEnv, fctx: FnCtx) Error!void {
        const mf = self.files[file_idx];
        if (arg_items.len != want.len) {
            try self.emit(mf, node, .arg_count_mismatch, "'{s}' takes exactly {d} argument(s), found {d}", .{ name, want.len, arg_items.len }, null);
            try self.checkArgsLoose(file_idx, arg_items, env, fctx);
            return;
        }
        for (arg_items, want) |a, ty| {
            const inner = mf.tree.kids(a)[0];
            const t = try self.checkExpr(file_idx, inner, env, fctx, ty);
            try self.expect(file_idx, inner, t, ty);
        }
    }

    fn checkCall(self: *Checker, file_idx: usize, node: ast.Index, env: GenericEnv, fctx: FnCtx, expected: TypeId) Error!TypeId {
        const mf = self.files[file_idx];
        const k = mf.tree.kids(node); // [callee, type_args_or_none, args]
        const callee = k[0];
        const arg_items = mf.tree.kids(k[2]);

        if (self.calleeIsType(file_idx, callee)) {
            const target = try self.checkType(file_idx, callee, env);
            if (target == .invalid) {
                try self.checkArgsLoose(file_idx, arg_items, env, fctx);
                return .invalid;
            }
            return self.checkConstruction(file_idx, node, target, arg_items, env, fctx);
        }

        if (mf.tree.get(callee).tag == .ident) {
            if (self.nodeSymbol(file_idx, callee)) |gsym| {
                const sym = self.symbolOf(gsym);
                if (sym.kind == .builtin_func) {
                    self.setType(file_idx, callee, .invalid);
                    return self.checkBuiltinCall(file_idx, node, sym.name, arg_items, env, fctx);
                }
                if (sym.kind == .func and self.declGenericArity(gsym) > 0) {
                    return self.checkGenericCall(file_idx, node, gsym, k[1], arg_items, env, fctx, expected);
                }
            }
        }

        const callee_ty = try self.checkExpr(file_idx, callee, env, fctx, .invalid);
        if (self.ctx.typeOf(callee_ty) != .func) {
            if (callee_ty != .invalid) try self.emit(mf, callee, .not_callable, "value is not callable", .{}, null);
            try self.checkArgsLoose(file_idx, arg_items, env, fctx);
            return .invalid;
        }
        try self.checkArgs(file_idx, node, self.ctx.typeOf(callee_ty).func, arg_items, env, fctx);
        return self.ctx.typeOf(callee_ty).func.result;
    }

    // ---- other postfix/primary expressions -----------------------------------

    fn checkIndex(self: *Checker, file_idx: usize, node: ast.Index, env: GenericEnv, fctx: FnCtx) Error!TypeId {
        const mf = self.files[file_idx];
        const k = mf.tree.kids(node); // [recv, index_expr]
        const recv_ty = try self.checkExpr(file_idx, k[0], env, fctx, .invalid);
        if (recv_ty == .invalid) {
            _ = try self.checkExpr(file_idx, k[1], env, fctx, .invalid);
            return .invalid;
        }
        switch (self.ctx.typeOf(recv_ty)) {
            .slice => |elem| {
                const idx_ty = try self.checkExpr(file_idx, k[1], env, fctx, .invalid);
                try self.expectIntegerIndex(file_idx, k[1], idx_ty);
                return elem;
            },
            .array => |a| {
                const idx_ty = try self.checkExpr(file_idx, k[1], env, fctx, .invalid);
                try self.expectIntegerIndex(file_idx, k[1], idx_ty);
                return a.elem;
            },
            .map => |m| {
                const idx_ty = try self.checkExpr(file_idx, k[1], env, fctx, m.key);
                try self.expect(file_idx, k[1], idx_ty, m.key);
                return m.val;
            },
            .prim => |p| {
                if (p == .string) {
                    const idx_ty = try self.checkExpr(file_idx, k[1], env, fctx, .invalid);
                    try self.expectIntegerIndex(file_idx, k[1], idx_ty);
                    return self.ctx.prim_ids.get(.u8);
                }
                try self.notIndexable(file_idx, k[0], recv_ty);
                _ = try self.checkExpr(file_idx, k[1], env, fctx, .invalid);
                return .invalid;
            },
            else => {
                try self.notIndexable(file_idx, k[0], recv_ty);
                _ = try self.checkExpr(file_idx, k[1], env, fctx, .invalid);
                return .invalid;
            },
        }
    }

    fn checkSliceExpr(self: *Checker, file_idx: usize, node: ast.Index, env: GenericEnv, fctx: FnCtx) Error!TypeId {
        const mf = self.files[file_idx];
        const k = mf.tree.kids(node); // [recv, lo_or_none, hi_or_none]
        const recv_ty = try self.checkExpr(file_idx, k[0], env, fctx, .invalid);
        if (k[1] != ast.none) {
            const t = try self.checkExpr(file_idx, k[1], env, fctx, .invalid);
            try self.expectIntegerIndex(file_idx, k[1], t);
        }
        if (k[2] != ast.none) {
            const t = try self.checkExpr(file_idx, k[2], env, fctx, .invalid);
            try self.expectIntegerIndex(file_idx, k[2], t);
        }
        if (recv_ty == .invalid) return .invalid;
        switch (self.ctx.typeOf(recv_ty)) {
            .slice => return recv_ty,
            .array => |a| return self.ctx.types.intern(.{ .slice = a.elem }),
            .prim => |p| {
                if (p == .string) return recv_ty;
                try self.notIndexable(file_idx, k[0], recv_ty);
                return .invalid;
            },
            else => {
                try self.notIndexable(file_idx, k[0], recv_ty);
                return .invalid;
            },
        }
    }

    fn checkMember(self: *Checker, file_idx: usize, node: ast.Index, env: GenericEnv, fctx: FnCtx) Error!TypeId {
        const mf = self.files[file_idx];
        const k = mf.tree.kids(node); // [recv, name]
        if (mf.tree.get(k[0]).tag == .ident) {
            if (self.nodeSymbol(file_idx, k[0])) |gs| {
                if (self.symbolOf(gs).kind == .import_namespace) {
                    // Cross-module namespace member lookup isn't wired (no
                    // multi-file driver exists yet, task #347): resolves to
                    // `.invalid` rather than crashing.
                    return .invalid;
                }
            }
        }
        const recv_ty = try self.checkExpr(file_idx, k[0], env, fctx, .invalid);
        if (recv_ty == .invalid) return .invalid;
        const name = Checker.identText(mf, k[1]);

        const data = self.ctx.typeOf(recv_ty);
        if (data == .@"struct") {
            for (data.@"struct") |f| if (std.mem.eql(u8, f.name, name)) return f.ty;
        }
        if (self.ctx.methodsOf(recv_ty)) |bucket| {
            if (bucket.get(name)) |m| return self.ctx.types.intern(.{ .func = .{ .params = m.params, .variadic = m.variadic, .result = m.result } });
        }
        if (data == .interface) {
            for (data.interface) |m| if (std.mem.eql(u8, m.name, name)) return self.ctx.types.intern(.{ .func = .{ .params = m.params, .variadic = m.variadic, .result = m.result } });
        }
        if (data == .type_param) {
            if (try self.boundMethod(recv_ty, data.type_param, name)) |ft| return ft;
        }

        var hint_buf: [96]u8 = undefined;
        const hint_text: ?[]const u8 = if (self.closestMethodName(recv_ty, name)) |h|
            (std.fmt.bufPrint(&hint_buf, "did you mean '{s}'?", .{h}) catch null)
        else
            null;
        try self.emit(mf, k[1], .unknown_member, "no field or method '{s}' on this type", .{name}, hint_text);
        return .invalid;
    }

    fn checkTupleIndex(self: *Checker, file_idx: usize, node: ast.Index, env: GenericEnv, fctx: FnCtx) Error!TypeId {
        const mf = self.files[file_idx];
        const k = mf.tree.kids(node); // [recv, int_lit]
        const recv_ty = try self.checkExpr(file_idx, k[0], env, fctx, .invalid);
        if (recv_ty == .invalid) return .invalid;
        const data = self.ctx.typeOf(recv_ty);
        if (data != .tuple) {
            try self.notIndexable(file_idx, k[0], recv_ty);
            return .invalid;
        }
        const idx_val = parseIntLiteral(Checker.identText(mf, k[1]));
        if (idx_val < 0 or idx_val >= data.tuple.len) {
            try self.emit(mf, k[1], .tuple_index_out_of_range, "tuple index {d} out of range for a {d}-element tuple", .{ idx_val, data.tuple.len }, null);
            return .invalid;
        }
        return data.tuple[@intCast(idx_val)];
    }

    fn checkTypeAssert(self: *Checker, file_idx: usize, node: ast.Index, env: GenericEnv, fctx: FnCtx) Error!TypeId {
        const mf = self.files[file_idx];
        const k = mf.tree.kids(node); // [recv, type]
        const recv_ty = try self.checkExpr(file_idx, k[0], env, fctx, .invalid);
        const target = try self.checkType(file_idx, k[1], env);
        if (recv_ty != .invalid and self.ctx.typeOf(recv_ty) != .interface) {
            const n = try self.typeName(recv_ty);
            defer self.gpa.free(n);
            try self.emit(mf, k[0], .type_mismatch, "type assertion requires an interface value, found '{s}'", .{n}, null);
        }
        return target;
    }

    fn checkTryExpr(self: *Checker, file_idx: usize, node: ast.Index, env: GenericEnv, fctx: FnCtx) Error!TypeId {
        const mf = self.files[file_idx];
        const operand = mf.tree.kids(node)[0];
        const ty = try self.checkExpr(file_idx, operand, env, fctx, .invalid);
        if (fctx.err_ty == .invalid) {
            try self.emit(mf, node, .try_outside_fallible, "'?' is only valid inside a fallible function", .{}, null);
        }
        if (ty == .invalid) return .invalid;
        const data = self.ctx.typeOf(ty);
        if (data != .fallible) {
            const n = try self.typeName(ty);
            defer self.gpa.free(n);
            try self.emit(mf, operand, .type_mismatch, "'?' requires a fallible expression, found '{s}'", .{n}, null);
            return .invalid;
        }
        if (fctx.err_ty != .invalid and !self.assignable(data.fallible.err, fctx.err_ty)) {
            try self.mismatch(mf, node, fctx.err_ty, data.fallible.err);
        }
        return data.fallible.ok;
    }

    fn checkCatchDefault(self: *Checker, file_idx: usize, node: ast.Index, env: GenericEnv, fctx: FnCtx) Error!TypeId {
        const mf = self.files[file_idx];
        const k = mf.tree.kids(node); // [expr, default_expr]
        const ty = try self.checkExpr(file_idx, k[0], env, fctx, .invalid);
        const data = self.ctx.typeOf(ty);
        if (ty == .invalid or data != .fallible) {
            if (ty != .invalid) {
                const n = try self.typeName(ty);
                defer self.gpa.free(n);
                try self.emit(mf, k[0], .type_mismatch, "'catch' requires a fallible expression, found '{s}'", .{n}, null);
            }
            _ = try self.checkExpr(file_idx, k[1], env, fctx, .invalid);
            return .invalid;
        }
        const ok = data.fallible.ok;
        const dty = try self.checkExpr(file_idx, k[1], env, fctx, ok);
        try self.expect(file_idx, k[1], dty, ok);
        return ok;
    }

    fn checkCatchBind(self: *Checker, file_idx: usize, node: ast.Index, env: GenericEnv, fctx: FnCtx) Error!TypeId {
        const mf = self.files[file_idx];
        const k = mf.tree.kids(node); // [expr, err_ident, block]
        const ty = try self.checkExpr(file_idx, k[0], env, fctx, .invalid);
        var ok = self.ctx.void_id;
        var err_ty = self.ctx.error_id;
        if (ty != .invalid) {
            const data = self.ctx.typeOf(ty);
            if (data != .fallible) {
                const n = try self.typeName(ty);
                defer self.gpa.free(n);
                try self.emit(mf, k[0], .type_mismatch, "'catch' requires a fallible expression, found '{s}'", .{n}, null);
            } else {
                ok = data.fallible.ok;
                err_ty = data.fallible.err;
            }
        }
        try self.bindSimple(file_idx, k[1], err_ty);
        try self.checkCatchBlock(file_idx, k[2], ok, fctx);
        return ok;
    }

    /// Checks a `catch e { ... }` block: every statement but the last is a
    /// normal statement; the last, if a bare expression statement, supplies
    /// the catch's value (checked against `expected_ok`) — otherwise the
    /// block must divert control (§18.3: "must either produce a T ... or
    /// divert control").
    fn checkCatchBlock(self: *Checker, file_idx: usize, node: ast.Index, expected_ok: TypeId, fctx: FnCtx) Error!void {
        const mf = self.files[file_idx];
        const stmts = mf.tree.kids(node);
        if (stmts.len == 0) {
            try self.emit(mf, node, .catch_block_incomplete, "'catch' block must produce a value or divert control (return/fail/panic/break/continue)", .{}, null);
            return;
        }
        for (stmts[0 .. stmts.len - 1]) |s| try self.checkStmt(file_idx, s, fctx);
        const last = stmts[stmts.len - 1];
        if (mf.tree.get(last).tag == .expr_stmt) {
            const inner = mf.tree.kids(last)[0];
            const ty = try self.checkExpr(file_idx, inner, fctx.env, fctx, expected_ok);
            self.setType(file_idx, last, ty);
            try self.expect(file_idx, inner, ty, expected_ok);
            return;
        }
        try self.checkStmt(file_idx, last, fctx);
        if (!self.diverges(file_idx, last, true)) {
            try self.emit(mf, node, .catch_block_incomplete, "'catch' block must produce a value or divert control (return/fail/panic/break/continue)", .{}, null);
        }
    }

    fn checkArrowFn(self: *Checker, file_idx: usize, node: ast.Index, env: GenericEnv, fctx: FnCtx, expected: TypeId) Error!TypeId {
        _ = fctx;
        const mf = self.files[file_idx];
        const k = mf.tree.kids(node); // [arrow_params, body]
        const param_nodes = mf.tree.kids(k[0]);

        var expected_params: ?[]const TypeId = null;
        var expected_result: TypeId = .invalid;
        if (expected != .invalid and self.ctx.typeOf(expected) == .func) {
            const f = self.ctx.typeOf(expected).func;
            expected_params = f.params;
            expected_result = f.result;
        }

        var params = try self.gpa.alloc(TypeId, param_nodes.len);
        defer self.gpa.free(params);
        for (param_nodes, 0..) |p_idx, i| {
            const pk = mf.tree.kids(p_idx); // [name, type_or_none]
            var pty: TypeId = .invalid;
            if (pk[1] != ast.none) {
                pty = try self.checkType(file_idx, pk[1], env);
            } else if (expected_params) |eps| {
                if (i < eps.len) pty = eps[i];
            }
            if (pty == .invalid) {
                try self.emit(mf, p_idx, .cannot_infer_type, "cannot infer this parameter's type; add an explicit annotation", .{}, null);
            }
            params[i] = pty;
            try self.bindSimple(file_idx, pk[0], pty);
        }

        // A `=> block` body uses explicit `return` (§12.8); with no expected
        // function type there's nothing to check `return`s against — narrow
        // gap, matches real usage where an arrow fn is almost always passed
        // where an expected function type is available (a call argument, an
        // annotated binding).
        const inner_fctx = FnCtx{ .env = env, .result_ty = expected_result, .err_ty = .invalid };
        var result: TypeId = expected_result;
        if (mf.tree.get(k[1]).tag == .block) {
            try self.checkBlock(file_idx, k[1], inner_fctx);
            if (result == .invalid) result = self.ctx.void_id;
        } else {
            result = try self.checkExpr(file_idx, k[1], env, inner_fctx, expected_result);
            if (expected_result != .invalid) try self.expect(file_idx, k[1], result, expected_result);
        }

        return self.ctx.types.intern(.{ .func = .{ .params = try dupe(self.ctx.arena(), TypeId, params), .variadic = false, .result = result } });
    }

    // ---- composite/slice literals (§12.2, §12.3, §15.2) ----------------------

    fn checkCompositeInitLoose(self: *Checker, file_idx: usize, init_node: ast.Index, env: GenericEnv, fctx: FnCtx) Error!void {
        const mf = self.files[file_idx];
        switch (mf.tree.get(init_node).tag) {
            .field_inits => for (mf.tree.kids(init_node)) |fi| {
                _ = try self.checkExpr(file_idx, mf.tree.kids(fi)[1], env, fctx, .invalid);
            },
            .map_entries => for (mf.tree.kids(init_node)) |me| {
                const mk = mf.tree.kids(me);
                _ = try self.checkExpr(file_idx, mk[0], env, fctx, .invalid);
                _ = try self.checkExpr(file_idx, mk[1], env, fctx, .invalid);
            },
            .args => {
                for (mf.tree.kids(init_node)) |a| _ = try self.checkArgExprType(file_idx, a, env, fctx);
            },
            else => {},
        }
    }

    fn checkStructInit(self: *Checker, file_idx: usize, init_node: ast.Index, fields: []const Field, env: GenericEnv, fctx: FnCtx) Error!void {
        const mf = self.files[file_idx];
        for (mf.tree.kids(init_node)) |fi| {
            const fk = mf.tree.kids(fi); // [name, expr]
            const name = Checker.identText(mf, fk[0]);
            var found: ?Field = null;
            for (fields) |f| {
                if (std.mem.eql(u8, f.name, name)) {
                    found = f;
                    break;
                }
            }
            const fty = try self.checkExpr(file_idx, fk[1], env, fctx, if (found) |f| f.ty else .invalid);
            if (found) |f| {
                try self.expect(file_idx, fk[1], fty, f.ty);
            } else {
                try self.emit(mf, fk[0], .unknown_member, "no field '{s}' on this struct", .{name}, null);
            }
        }
    }

    fn checkSeqInit(self: *Checker, file_idx: usize, init_node: ast.Index, elem: TypeId, env: GenericEnv, fctx: FnCtx) Error!void {
        const mf = self.files[file_idx];
        for (mf.tree.kids(init_node)) |a| {
            const inner = mf.tree.kids(a)[0];
            const t = try self.checkExpr(file_idx, inner, env, fctx, elem);
            try self.expect(file_idx, inner, t, elem);
        }
    }

    fn checkMapInit(self: *Checker, file_idx: usize, init_node: ast.Index, key: TypeId, val: TypeId, env: GenericEnv, fctx: FnCtx) Error!void {
        const mf = self.files[file_idx];
        for (mf.tree.kids(init_node)) |me| {
            const mk = mf.tree.kids(me); // [key_expr, val_expr]
            const kt = try self.checkExpr(file_idx, mk[0], env, fctx, key);
            try self.expect(file_idx, mk[0], kt, key);
            const vt = try self.checkExpr(file_idx, mk[1], env, fctx, val);
            try self.expect(file_idx, mk[1], vt, val);
        }
    }

    fn checkCompositeLit(self: *Checker, file_idx: usize, node: ast.Index, env: GenericEnv, fctx: FnCtx) Error!TypeId {
        const mf = self.files[file_idx];
        const k = mf.tree.kids(node); // [type, init]
        const target = try self.checkType(file_idx, k[0], env);
        if (target == .invalid) {
            try self.checkCompositeInitLoose(file_idx, k[1], env, fctx);
            return .invalid;
        }
        switch (self.ctx.typeOf(target)) {
            .@"struct" => |fields| try self.checkStructInit(file_idx, k[1], fields, env, fctx),
            .slice => |elem| try self.checkSeqInit(file_idx, k[1], elem, env, fctx),
            .array => |a| {
                const items = mf.tree.kids(k[1]);
                if (items.len != a.len) {
                    try self.emit(mf, node, .arg_count_mismatch, "array literal has {d} element(s), expected {d}", .{ items.len, a.len }, null);
                }
                try self.checkSeqInit(file_idx, k[1], a.elem, env, fctx);
            },
            .map => |m| try self.checkMapInit(file_idx, k[1], m.key, m.val, env, fctx),
            else => try self.checkCompositeInitLoose(file_idx, k[1], env, fctx),
        }
        return target;
    }

    fn checkSliceLit(self: *Checker, file_idx: usize, node: ast.Index, env: GenericEnv, fctx: FnCtx, expected: TypeId) Error!TypeId {
        const mf = self.files[file_idx];
        const items = mf.tree.kids(node); // arg | arg_spread
        var elem_expected: TypeId = .invalid;
        if (expected != .invalid and self.ctx.typeOf(expected) == .slice) elem_expected = self.ctx.typeOf(expected).slice;

        if (elem_expected != .invalid) {
            for (items) |a| {
                const inner = mf.tree.kids(a)[0];
                const t = try self.checkExpr(file_idx, inner, env, fctx, elem_expected);
                try self.expect(file_idx, inner, t, elem_expected);
            }
            return expected;
        }

        if (items.len == 0) {
            try self.emit(mf, node, .cannot_infer_type, "cannot infer the element type of an empty slice literal; annotate the binding's type", .{}, null);
            return .invalid;
        }
        var elem: TypeId = .invalid;
        var mismatch_found = false;
        for (items, 0..) |a, i| {
            const inner = mf.tree.kids(a)[0];
            const t = try self.checkExpr(file_idx, inner, env, fctx, .invalid);
            if (i == 0) {
                elem = t;
            } else if (t != elem and self.defaultType(t) != self.defaultType(elem)) {
                mismatch_found = true;
            }
        }
        if (mismatch_found) {
            try self.emit(mf, node, .type_mismatch, "slice literal elements must share a common type", .{}, null);
            return .invalid;
        }
        return self.ctx.types.intern(.{ .slice = self.defaultType(elem) });
    }

    // ---- expression dispatch --------------------------------------------------

    fn checkIdentExpr(self: *Checker, file_idx: usize, node: ast.Index) Error!TypeId {
        const mf = self.files[file_idx];
        const gsym = self.nodeSymbol(file_idx, node) orelse return .invalid;
        const sym = self.symbolOf(gsym);
        switch (sym.kind) {
            .let_binding, .const_binding, .param, .receiver => {
                // A cross-module reference can only be to a top-level `const`
                // (imports expose nothing else that lives in `var_types`), and
                // its type is memoized project-wide in `ctx.const_types`; a
                // mutable cross-module `let` has no such entry and stays
                // `.invalid`. Same-module bindings read `var_types` directly.
                if (gsym.module != self.module_id) return self.ctx.const_types.get(gsym.pack()) orelse .invalid;
                return self.var_types.get(gsym.id) orelse .invalid;
            },
            .func => {
                const shape = self.ctx.func_sigs.get(gsym.pack()) orelse return .invalid;
                return self.ctx.types.intern(.{ .func = shape });
            },
            .struct_type, .interface_type, .type_alias, .builtin_type, .generic_param => {
                try self.emit(mf, node, .type_mismatch, "'{s}' is a type, not a value", .{sym.name}, null);
                return .invalid;
            },
            else => return .invalid,
        }
    }

    fn checkStrInterp(self: *Checker, file_idx: usize, node: ast.Index, env: GenericEnv, fctx: FnCtx) Error!TypeId {
        const mf = self.files[file_idx];
        for (mf.tree.kids(node)) |part| {
            if (mf.tree.get(part).tag == .str_part) continue;
            _ = try self.checkExpr(file_idx, part, env, fctx, .invalid);
        }
        return self.ctx.prim_ids.get(.string);
    }

    fn checkBinary(self: *Checker, file_idx: usize, node: ast.Index, env: GenericEnv, fctx: FnCtx) Error!TypeId {
        const mf = self.files[file_idx];
        const k = mf.tree.kids(node);
        const op: lexer.Kind = @enumFromInt(mf.tree.get(node).main);
        const lty = try self.checkExpr(file_idx, k[0], env, fctx, .invalid);
        const rty = try self.checkExpr(file_idx, k[1], env, fctx, .invalid);
        if (lty == .invalid or rty == .invalid) return .invalid;

        switch (op) {
            .amp_amp, .pipe_pipe => {
                const bool_ty = self.ctx.prim_ids.get(.bool);
                try self.expect(file_idx, k[0], lty, bool_ty);
                try self.expect(file_idx, k[1], rty, bool_ty);
                return bool_ty;
            },
            .eq_eq, .bang_eq => {
                if (!self.binaryComparable(file_idx, k, lty, rty)) try self.emitOperandMismatch(file_idx, node, lty, rty);
                return self.ctx.prim_ids.get(.bool);
            },
            .lt, .lt_eq, .gt, .gt_eq => {
                const joined = self.joinOperandTypes(file_idx, k[0], k[1], lty, rty);
                if (joined == .invalid or !self.hasOrdering(joined)) try self.emitOperandMismatch(file_idx, node, lty, rty);
                return self.ctx.prim_ids.get(.bool);
            },
            .amp, .pipe, .caret, .shl, .shr => return self.checkNumericBinary(file_idx, node, k, lty, rty, true),
            .plus => {
                if (self.stringish(lty) and self.stringish(rty)) return self.ctx.prim_ids.get(.string);
                return self.checkNumericBinary(file_idx, node, k, lty, rty, false);
            },
            .minus, .star, .slash, .percent => return self.checkNumericBinary(file_idx, node, k, lty, rty, false),
            else => return .invalid,
        }
    }

    fn checkUnary(self: *Checker, file_idx: usize, node: ast.Index, env: GenericEnv, fctx: FnCtx) Error!TypeId {
        const mf = self.files[file_idx];
        const operand = mf.tree.kids(node)[0];
        const op: lexer.Kind = @enumFromInt(mf.tree.get(node).main);
        if (op == .arrow_left) {
            const chan_ty = try self.checkExpr(file_idx, operand, env, fctx, .invalid);
            if (chan_ty == .invalid) return .invalid;
            if (self.ctx.typeOf(chan_ty) != .chan) {
                const n = try self.typeName(chan_ty);
                defer self.gpa.free(n);
                try self.emit(mf, operand, .invalid_operand, "receive requires a channel operand, found '{s}'", .{n}, null);
                return .invalid;
            }
            return self.ctx.typeOf(chan_ty).chan;
        }
        const ty = try self.checkExpr(file_idx, operand, env, fctx, .invalid);
        if (ty == .invalid) return .invalid;
        switch (op) {
            .bang => {
                const bool_ty = self.ctx.prim_ids.get(.bool);
                try self.expect(file_idx, operand, ty, bool_ty);
                return bool_ty;
            },
            .minus, .plus, .tilde => {
                const numeric = switch (self.ctx.typeOf(ty)) {
                    .prim => |p| p.isNumeric(),
                    .untyped_int, .untyped_float, .untyped_rune => true,
                    else => false,
                };
                if (!numeric) {
                    const n = try self.typeName(ty);
                    defer self.gpa.free(n);
                    try self.emit(mf, operand, .invalid_operand, "operator not defined for '{s}'", .{n}, null);
                    return .invalid;
                }
                return ty;
            },
            else => return .invalid,
        }
    }

    fn checkExpr(self: *Checker, file_idx: usize, node: ast.Index, env: GenericEnv, fctx: FnCtx, expected: TypeId) Error!TypeId {
        const mf = self.files[file_idx];
        const ty: TypeId = switch (mf.tree.get(node).tag) {
            .ident => try self.checkIdentExpr(file_idx, node),
            .int_lit => self.ctx.untyped_int_id,
            .float_lit => self.ctx.untyped_float_id,
            .rune_lit => self.ctx.untyped_rune_id,
            .bool_lit => self.ctx.untyped_bool_id,
            .string_lit, .raw_string_lit => self.ctx.untyped_string_id,
            .nil_lit => self.ctx.untyped_nil_id,
            .str_interp => try self.checkStrInterp(file_idx, node, env, fctx),
            .binary => try self.checkBinary(file_idx, node, env, fctx),
            .unary => try self.checkUnary(file_idx, node, env, fctx),
            .catch_default => try self.checkCatchDefault(file_idx, node, env, fctx),
            .catch_bind => try self.checkCatchBind(file_idx, node, env, fctx),
            .arrow_fn => try self.checkArrowFn(file_idx, node, env, fctx, expected),
            .call => try self.checkCall(file_idx, node, env, fctx, expected),
            .index => try self.checkIndex(file_idx, node, env, fctx),
            .slice_expr => try self.checkSliceExpr(file_idx, node, env, fctx),
            .member => try self.checkMember(file_idx, node, env, fctx),
            .tuple_index => try self.checkTupleIndex(file_idx, node, env, fctx),
            .type_assert => try self.checkTypeAssert(file_idx, node, env, fctx),
            .try_expr => try self.checkTryExpr(file_idx, node, env, fctx),
            .composite_lit => try self.checkCompositeLit(file_idx, node, env, fctx),
            .slice_lit => try self.checkSliceLit(file_idx, node, env, fctx, expected),
            else => .invalid, // parser error-recovery poison node
        };
        self.setType(file_idx, node, ty);
        return ty;
    }

    // ---- binder plumbing shared by `let`/`const`, loops, `select` -----------

    fn bindSimple(self: *Checker, file_idx: usize, node: ast.Index, ty: TypeId) Error!void {
        self.setType(file_idx, node, ty);
        if (self.nodeSymbol(file_idx, node)) |gs| try self.var_types.put(self.gpa, gs.id, ty);
    }

    /// Binds a `pat` (IDENT, `_`, or nested `tuple_pat`) against `ty`,
    /// destructuring positionally when both the pattern and `ty` are tuples
    /// of matching arity.
    fn bindPattern(self: *Checker, file_idx: usize, pat: ast.Index, ty: TypeId) Error!void {
        const mf = self.files[file_idx];
        if (mf.tree.get(pat).tag == .tuple_pat) {
            const subs = mf.tree.kids(pat);
            const data = self.ctx.typeOf(ty);
            if (ty != .invalid and data == .tuple and data.tuple.len == subs.len) {
                for (subs, data.tuple) |s, elem| try self.bindPattern(file_idx, s, elem);
            } else {
                if (ty != .invalid) try self.emit(mf, pat, .type_mismatch, "cannot destructure this value into {d} names", .{subs.len}, null);
                for (subs) |s| try self.bindPattern(file_idx, s, .invalid);
            }
            return;
        }
        try self.bindSimple(file_idx, pat, ty);
    }

    fn bindPattern2(self: *Checker, file_idx: usize, pat: ast.Index, first: TypeId, second: TypeId) Error!void {
        const subs = self.files[file_idx].tree.kids(pat);
        try self.bindPattern(file_idx, subs[0], first);
        try self.bindPattern(file_idx, subs[1], second);
    }

    /// Two-result forms (§12.6/§16.2): `m[k]` (map index) and `<-c` (channel
    /// receive) each carry an implicit `bool` "ok" second result, available
    /// only as the sole RHS of a 2-target destructure. Fully checks (and
    /// `setType`s) the map/channel operand itself; returns `null` — without
    /// checking anything — for any other expression, so the caller falls
    /// back to the ordinary single-value path.
    fn twoResultOf(self: *Checker, file_idx: usize, node: ast.Index, fctx: FnCtx) Error!?[2]TypeId {
        const mf = self.files[file_idx];
        const n = mf.tree.get(node);
        if (n.tag == .index) {
            const k = mf.tree.kids(node);
            const recv_ty = try self.checkExpr(file_idx, k[0], fctx.env, fctx, .invalid);
            if (self.ctx.typeOf(recv_ty) != .map) {
                self.setType(file_idx, node, .invalid);
                return null;
            }
            const map = self.ctx.typeOf(recv_ty).map;
            const idx_ty = try self.checkExpr(file_idx, k[1], fctx.env, fctx, map.key);
            try self.expect(file_idx, k[1], idx_ty, map.key);
            self.setType(file_idx, node, map.val);
            return .{ map.val, self.ctx.prim_ids.get(.bool) };
        }
        if (n.tag == .unary and @as(lexer.Kind, @enumFromInt(n.main)) == .arrow_left) {
            const operand = mf.tree.kids(node)[0];
            const chan_ty = try self.checkExpr(file_idx, operand, fctx.env, fctx, .invalid);
            var elem: TypeId = .invalid;
            if (self.ctx.typeOf(chan_ty) == .chan) {
                elem = self.ctx.typeOf(chan_ty).chan;
            } else if (chan_ty != .invalid) {
                try self.emit(mf, operand, .invalid_operand, "receive requires a channel operand", .{}, null);
            }
            self.setType(file_idx, node, elem);
            return .{ elem, self.ctx.prim_ids.get(.bool) };
        }
        return null;
    }

    // ---- bindings (`let`/`const`, top-level and local, §10.1) ---------------

    fn checkBinding(self: *Checker, file_idx: usize, idx: ast.Index, is_const: bool, is_top: bool, fctx: FnCtx) Error!void {
        const mf = self.files[file_idx];
        const k = mf.tree.kids(idx); // [pattern, type_or_none, init_or_none]
        const pat = k[0];
        const annotated: TypeId = if (k[1] != ast.none) try self.checkType(file_idx, k[1], fctx.env) else .invalid;

        if (k[2] == ast.none) {
            // `let x: T` with no initializer -> zero value of T (§13.4);
            // `const` always requires one (the parser already enforces it).
            try self.bindPattern(file_idx, pat, annotated);
            return;
        }
        const init_node = k[2];

        if (mf.tree.get(pat).tag == .tuple_pat and mf.tree.kids(pat).len == 2) {
            if (try self.twoResultOf(file_idx, init_node, fctx)) |two| {
                try self.bindPattern2(file_idx, pat, two[0], two[1]);
                if (is_const) {
                    if (is_top and self.constEval(file_idx, init_node, 0) == null) {
                        try self.emit(mf, init_node, .non_constant_expr, "top-level 'const' initializer must be a compile-time constant expression", .{}, null);
                    }
                }
                return;
            }
        }

        const init_ty = try self.checkExpr(file_idx, init_node, fctx.env, fctx, annotated);
        const bind_ty = if (annotated != .invalid) blk: {
            try self.expect(file_idx, init_node, init_ty, annotated);
            break :blk annotated;
        } else self.defaultType(init_ty);

        try self.bindPattern(file_idx, pat, bind_ty);

        if (is_const) {
            if (is_top and self.constEval(file_idx, init_node, 0) == null) {
                try self.emit(mf, init_node, .non_constant_expr, "top-level 'const' initializer must be a compile-time constant expression", .{}, null);
            }
            if (mf.tree.get(pat).tag == .ident) {
                if (self.nodeSymbol(file_idx, pat)) |gs| {
                    try self.const_inits.put(self.gpa, gs.id, init_node);
                    // Memoize the type project-wide so a dependent module can
                    // resolve a reference to this `const` (its own `var_types`
                    // dies with this `Checker`).
                    if (is_top) try self.ctx.const_types.put(self.gpa, gs.pack(), bind_ty);
                }
            }
        }
    }

    fn checkTopBinding(self: *Checker, file_idx: usize, idx: ast.Index) Error!void {
        const mf = self.files[file_idx];
        const is_const = mf.tree.get(idx).tag == .const_decl;
        const top_fctx = FnCtx{ .env = &.{}, .result_ty = self.ctx.void_id };
        for (mf.tree.kids(idx)) |binding_idx| try self.checkBinding(file_idx, binding_idx, is_const, true, top_fctx);
    }

    // ---- statements (§13.1) --------------------------------------------------

    fn checkAssignableLhs(self: *Checker, file_idx: usize, node: ast.Index) Error!void {
        const mf = self.files[file_idx];
        if (mf.tree.get(node).tag != .ident) return; // index/member lvalues: mutability is the receiver's, not a binding
        const gsym = self.nodeSymbol(file_idx, node) orelse return;
        const sym = self.symbolOf(gsym);
        if (sym.kind == .const_binding) {
            try self.emit(mf, node, .immutable_assignment, "cannot assign to '{s}': declared 'const'", .{sym.name}, null);
        }
    }

    fn checkExprStmt(self: *Checker, file_idx: usize, node: ast.Index, fctx: FnCtx) Error!void {
        const mf = self.files[file_idx];
        const inner = mf.tree.kids(node)[0];
        const n = mf.tree.get(inner);
        // `catch` is a valid statement: at statement position it is deliberate
        // error handling (the ok value is intentionally discarded, or the ok
        // type is `void`), not an accidentally-unused expression — the same
        // reason a bare `call` is allowed. (§18.3)
        const legal = n.tag == .call or n.tag == .try_expr or
            n.tag == .catch_default or n.tag == .catch_bind or
            (n.tag == .unary and @as(lexer.Kind, @enumFromInt(n.main)) == .arrow_left);
        if (!legal) {
            try self.emit(mf, node, .invalid_expr_statement, "expression result unused; only a call, channel receive, '?' chain, or 'catch' is a valid statement", .{}, null);
        }
        _ = try self.checkExpr(file_idx, inner, fctx.env, fctx, .invalid);
    }

    fn checkSpawnDefer(self: *Checker, file_idx: usize, node: ast.Index, fctx: FnCtx, is_spawn: bool) Error!void {
        const mf = self.files[file_idx];
        const inner = mf.tree.kids(node)[0];
        if (mf.tree.get(inner).tag != .call) {
            const word = if (is_spawn) "spawn" else "defer";
            try self.emit(mf, node, .expected_call_expr, "'{s}' requires a call expression", .{word}, null);
        }
        _ = try self.checkExpr(file_idx, inner, fctx.env, fctx, .invalid);
    }

    fn checkSendStmt(self: *Checker, file_idx: usize, node: ast.Index, fctx: FnCtx) Error!void {
        const mf = self.files[file_idx];
        const k = mf.tree.kids(node); // [chan_expr, value_expr]
        const chan_ty = try self.checkExpr(file_idx, k[0], fctx.env, fctx, .invalid);
        if (chan_ty == .invalid or self.ctx.typeOf(chan_ty) != .chan) {
            if (chan_ty != .invalid) {
                const n = try self.typeName(chan_ty);
                defer self.gpa.free(n);
                try self.emit(mf, k[0], .invalid_operand, "send requires a channel operand, found '{s}'", .{n}, null);
            }
            _ = try self.checkExpr(file_idx, k[1], fctx.env, fctx, .invalid);
            return;
        }
        const elem = self.ctx.typeOf(chan_ty).chan;
        const vty = try self.checkExpr(file_idx, k[1], fctx.env, fctx, elem);
        try self.expect(file_idx, k[1], vty, elem);
    }

    fn checkReturnStmt(self: *Checker, file_idx: usize, node: ast.Index, fctx: FnCtx) Error!void {
        const mf = self.files[file_idx];
        const exprs = mf.tree.kids(node);
        if (exprs.len == 0) {
            if (fctx.result_ty != self.ctx.void_id and fctx.result_ty != .invalid) {
                try self.emit(mf, node, .type_mismatch, "'return' needs a value: this function's result is not void", .{}, null);
            }
            return;
        }
        if (exprs.len == 1) {
            const t = try self.checkExpr(file_idx, exprs[0], fctx.env, fctx, fctx.result_ty);
            try self.expect(file_idx, exprs[0], t, fctx.result_ty);
            return;
        }
        // Multiple return expressions build a tuple result (§13.1).
        const result_data = self.ctx.typeOf(fctx.result_ty);
        var elems = try self.gpa.alloc(TypeId, exprs.len);
        defer self.gpa.free(elems);
        for (exprs, 0..) |e, i| {
            const target: TypeId = if (result_data == .tuple and i < result_data.tuple.len) result_data.tuple[i] else .invalid;
            const t = try self.checkExpr(file_idx, e, fctx.env, fctx, target);
            elems[i] = t;
            if (target != .invalid) try self.expect(file_idx, e, t, target);
        }
        if (fctx.result_ty != .invalid and (result_data != .tuple or result_data.tuple.len != exprs.len)) {
            const tup = try self.ctx.types.intern(.{ .tuple = try dupe(self.ctx.arena(), TypeId, elems) });
            try self.mismatch(mf, node, fctx.result_ty, tup);
        }
    }

    fn checkFailStmt(self: *Checker, file_idx: usize, node: ast.Index, fctx: FnCtx) Error!void {
        const mf = self.files[file_idx];
        const expr = mf.tree.kids(node)[0];
        const t = try self.checkExpr(file_idx, expr, fctx.env, fctx, fctx.err_ty);
        if (fctx.err_ty == .invalid) {
            try self.emit(mf, node, .fail_outside_fallible, "'fail' is only valid inside a fallible function", .{}, null);
            return;
        }
        try self.expect(file_idx, expr, t, fctx.err_ty);
    }

    fn checkIncDec(self: *Checker, file_idx: usize, node: ast.Index, fctx: FnCtx) Error!void {
        const mf = self.files[file_idx];
        const lhs = mf.tree.kids(node)[0];
        const t = try self.checkExpr(file_idx, lhs, fctx.env, fctx, .invalid);
        try self.checkAssignableLhs(file_idx, lhs);
        if (t == .invalid) return;
        const numeric = switch (self.ctx.typeOf(t)) {
            .prim => |p| p.isNumeric(),
            .untyped_int, .untyped_float, .untyped_rune => true,
            else => false,
        };
        if (!numeric) {
            const n = try self.typeName(t);
            defer self.gpa.free(n);
            try self.emit(mf, lhs, .invalid_operand, "'++'/'--' require a numeric operand, found '{s}'", .{n}, null);
        }
    }

    fn assignTo(self: *Checker, file_idx: usize, lhs: ast.Index, ty: TypeId, fctx: FnCtx) Error!void {
        const lty = try self.checkExpr(file_idx, lhs, fctx.env, fctx, .invalid);
        try self.checkAssignableLhs(file_idx, lhs);
        if (lty != .invalid) try self.expect(file_idx, lhs, ty, lty);
    }

    fn checkAssign(self: *Checker, file_idx: usize, node: ast.Index, fctx: FnCtx) Error!void {
        const mf = self.files[file_idx];
        const k = mf.tree.kids(node); // [lhs_list, rhs_list]
        const op: lexer.Kind = @enumFromInt(mf.tree.get(node).main);
        const lhs_items = mf.tree.kids(k[0]);
        const rhs_items = mf.tree.kids(k[1]);

        if (op != .eq) {
            if (lhs_items.len != 1 or rhs_items.len != 1) {
                try self.emit(mf, node, .arg_count_mismatch, "compound assignment requires exactly one operand on each side", .{}, null);
            }
            for (lhs_items) |l| {
                _ = try self.checkExpr(file_idx, l, fctx.env, fctx, .invalid);
                try self.checkAssignableLhs(file_idx, l);
            }
            for (rhs_items) |r| _ = try self.checkExpr(file_idx, r, fctx.env, fctx, .invalid);
            if (lhs_items.len == 1 and rhs_items.len == 1) {
                const lty = self.typeOfNode(file_idx, lhs_items[0]);
                const rty = self.typeOfNode(file_idx, rhs_items[0]);
                const bitwise = switch (op) {
                    .amp_eq, .pipe_eq, .caret_eq, .shl_eq, .shr_eq => true,
                    else => false,
                };
                const joined = self.joinOperandTypes(file_idx, lhs_items[0], rhs_items[0], lty, rty);
                const joined_ok = joined != .invalid and switch (self.ctx.typeOf(joined)) {
                    .prim => |p| if (bitwise) p.isInteger() else p.isNumeric(),
                    .untyped_int, .untyped_rune => true,
                    .untyped_float => !bitwise,
                    else => false,
                };
                const ok = joined_ok or (op == .plus_eq and self.stringish(lty) and self.stringish(rty));
                if (!ok) try self.emitOperandMismatch(file_idx, node, lty, rty);
            }
            return;
        }

        // `(v, ok) = m[k]` / `(v, ok) = <-c` (§12.6/§16.2): a 2-entry lhs
        // list where the single rhs is a two-result form.
        if (lhs_items.len == 2 and rhs_items.len == 1) {
            if (try self.twoResultOf(file_idx, rhs_items[0], fctx)) |two| {
                try self.assignTo(file_idx, lhs_items[0], two[0], fctx);
                try self.assignTo(file_idx, lhs_items[1], two[1], fctx);
                return;
            }
        }

        if (lhs_items.len != rhs_items.len) {
            try self.emit(mf, node, .arg_count_mismatch, "{d} target(s) but {d} value(s)", .{ lhs_items.len, rhs_items.len }, null);
        }
        const n = @min(lhs_items.len, rhs_items.len);
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const lty = try self.checkExpr(file_idx, lhs_items[i], fctx.env, fctx, .invalid);
            const rty = try self.checkExpr(file_idx, rhs_items[i], fctx.env, fctx, lty);
            try self.checkAssignableLhs(file_idx, lhs_items[i]);
            if (lty != .invalid) try self.expect(file_idx, rhs_items[i], rty, lty);
        }
        while (i < lhs_items.len) : (i += 1) _ = try self.checkExpr(file_idx, lhs_items[i], fctx.env, fctx, .invalid);
        while (i < rhs_items.len) : (i += 1) _ = try self.checkExpr(file_idx, rhs_items[i], fctx.env, fctx, .invalid);
    }

    fn checkBlock(self: *Checker, file_idx: usize, node: ast.Index, fctx: FnCtx) Error!void {
        for (self.files[file_idx].tree.kids(node)) |stmt| try self.checkStmt(file_idx, stmt, fctx);
    }

    fn checkStmtList(self: *Checker, file_idx: usize, node: ast.Index, fctx: FnCtx) Error!void {
        for (self.files[file_idx].tree.kids(node)) |stmt| try self.checkStmt(file_idx, stmt, fctx);
    }

    fn bindForOfBinder(self: *Checker, file_idx: usize, binder: ast.Index, is_tuple: bool, first: TypeId, second: ?TypeId) Error!void {
        const mf = self.files[file_idx];
        if (is_tuple) {
            const subs = mf.tree.kids(binder);
            if (subs.len == 2 and second != null) {
                try self.bindSimple(file_idx, subs[0], first);
                try self.bindSimple(file_idx, subs[1], second.?);
            } else {
                try self.emit(mf, binder, .type_mismatch, "this iteration binds a single value, not a pair", .{}, null);
                for (subs) |s| try self.bindSimple(file_idx, s, .invalid);
            }
            return;
        }
        if (second != null) {
            try self.emit(mf, binder, .type_mismatch, "iterating a map with 'of' needs a '(key, value)' binder", .{}, null);
        }
        try self.bindSimple(file_idx, binder, first);
    }

    fn checkForOf(self: *Checker, file_idx: usize, node: ast.Index, fctx: FnCtx) Error!void {
        const mf = self.files[file_idx];
        const k = mf.tree.kids(node); // [binder, iter, body]
        const iter_ty = try self.checkExpr(file_idx, k[1], fctx.env, fctx, .invalid);
        var inner = fctx;
        inner.loop_depth += 1;
        inner.breakable_depth += 1;

        const is_tuple_binder = mf.tree.get(k[0]).tag == .tuple_pat;
        switch (self.ctx.typeOf(iter_ty)) {
            .slice => |e| try self.bindForOfBinder(file_idx, k[0], is_tuple_binder, e, null),
            .array => |a| try self.bindForOfBinder(file_idx, k[0], is_tuple_binder, a.elem, null),
            .chan => |e| try self.bindForOfBinder(file_idx, k[0], is_tuple_binder, e, null),
            .map => |m| try self.bindForOfBinder(file_idx, k[0], is_tuple_binder, m.key, m.val),
            .invalid => try self.bindForOfBinder(file_idx, k[0], is_tuple_binder, .invalid, if (is_tuple_binder) .invalid else null),
            else => {
                try self.notIndexable(file_idx, k[1], iter_ty);
                try self.bindForOfBinder(file_idx, k[0], is_tuple_binder, .invalid, if (is_tuple_binder) .invalid else null);
            },
        }
        try self.checkBlock(file_idx, k[2], inner);
    }

    /// `for k in xs` binds the index/key domain (mirrors JS `for...in` vs
    /// `for...of`): slice/array/string -> the integer index; map -> the key.
    /// §16 only spells out the `of` channel-range form explicitly, so this
    /// reading is inferred from the keyword choice, not directly verified
    /// against a worked example.
    fn checkForIn(self: *Checker, file_idx: usize, node: ast.Index, fctx: FnCtx) Error!void {
        const mf = self.files[file_idx];
        const k = mf.tree.kids(node); // [name_ident, iter, body]
        const iter_ty = try self.checkExpr(file_idx, k[1], fctx.env, fctx, .invalid);
        var inner = fctx;
        inner.loop_depth += 1;
        inner.breakable_depth += 1;

        const bind_ty: TypeId = switch (self.ctx.typeOf(iter_ty)) {
            .slice, .array => self.ctx.prim_ids.get(.u64),
            .map => |m| m.key,
            .prim => |p| blk: {
                if (p == .string) break :blk self.ctx.prim_ids.get(.u64);
                try self.notIndexable(file_idx, k[1], iter_ty);
                break :blk .invalid;
            },
            .invalid => .invalid,
            else => blk: {
                try self.notIndexable(file_idx, k[1], iter_ty);
                break :blk .invalid;
            },
        };
        try self.bindSimple(file_idx, k[0], bind_ty);
        try self.checkBlock(file_idx, k[2], inner);
    }

    fn checkForC(self: *Checker, file_idx: usize, node: ast.Index, fctx: FnCtx) Error!void {
        const mf = self.files[file_idx];
        const k = mf.tree.kids(node); // [init_or_none, cond_or_none, post_or_none, body]
        if (k[0] != ast.none) try self.checkStmt(file_idx, k[0], fctx);
        if (k[1] != ast.none) {
            const t = try self.checkExpr(file_idx, k[1], fctx.env, fctx, self.ctx.prim_ids.get(.bool));
            try self.expect(file_idx, k[1], t, self.ctx.prim_ids.get(.bool));
        }
        var inner = fctx;
        inner.loop_depth += 1;
        inner.breakable_depth += 1;
        if (k[2] != ast.none) try self.checkStmt(file_idx, k[2], inner);
        try self.checkBlock(file_idx, k[3], inner);
    }

    fn checkWhileStmt(self: *Checker, file_idx: usize, node: ast.Index, fctx: FnCtx) Error!void {
        const mf = self.files[file_idx];
        const k = mf.tree.kids(node); // [cond, body]
        const t = try self.checkExpr(file_idx, k[0], fctx.env, fctx, self.ctx.prim_ids.get(.bool));
        try self.expect(file_idx, k[0], t, self.ctx.prim_ids.get(.bool));
        var inner = fctx;
        inner.loop_depth += 1;
        inner.breakable_depth += 1;
        try self.checkBlock(file_idx, k[1], inner);
    }

    fn checkIfStmt(self: *Checker, file_idx: usize, node: ast.Index, fctx: FnCtx) Error!void {
        const mf = self.files[file_idx];
        const k = mf.tree.kids(node); // [cond, then_block, else_or_none]
        const t = try self.checkExpr(file_idx, k[0], fctx.env, fctx, self.ctx.prim_ids.get(.bool));
        try self.expect(file_idx, k[0], t, self.ctx.prim_ids.get(.bool));
        try self.checkBlock(file_idx, k[1], fctx);
        if (k[2] == ast.none) return;
        if (mf.tree.get(k[2]).tag == .if_stmt) {
            try self.checkStmt(file_idx, k[2], fctx);
        } else {
            try self.checkBlock(file_idx, k[2], fctx);
        }
    }

    fn checkSwitchStmt(self: *Checker, file_idx: usize, node: ast.Index, fctx: FnCtx) Error!void {
        const mf = self.files[file_idx];
        const k = mf.tree.kids(node); // [subject_or_none, case_list]
        const subject_ty: TypeId = if (k[0] != ast.none)
            try self.checkExpr(file_idx, k[0], fctx.env, fctx, .invalid)
        else
            self.ctx.prim_ids.get(.bool);

        var inner = fctx;
        inner.breakable_depth += 1;
        for (mf.tree.kids(k[1])) |c| {
            switch (mf.tree.get(c).tag) {
                .switch_case => {
                    const ck = mf.tree.kids(c); // [expr_list, stmt_list]
                    for (mf.tree.kids(ck[0])) |e| {
                        const t = try self.checkExpr(file_idx, e, fctx.env, fctx, subject_ty);
                        if (subject_ty != .invalid) try self.expect(file_idx, e, t, subject_ty);
                    }
                    try self.checkStmtList(file_idx, ck[1], inner);
                },
                .switch_default => try self.checkStmtList(file_idx, mf.tree.kids(c)[0], inner),
                else => {},
            }
        }
    }

    fn checkComm(self: *Checker, file_idx: usize, node: ast.Index, fctx: FnCtx) Error!void {
        const mf = self.files[file_idx];
        switch (mf.tree.get(node).tag) {
            .send_stmt => try self.checkSendStmt(file_idx, node, fctx),
            .recv_bind => {
                const k = mf.tree.kids(node); // [binder_or_none, chan_expr]
                const chan_ty = try self.checkExpr(file_idx, k[1], fctx.env, fctx, .invalid);
                var elem: TypeId = .invalid;
                if (self.ctx.typeOf(chan_ty) == .chan) {
                    elem = self.ctx.typeOf(chan_ty).chan;
                } else if (chan_ty != .invalid) {
                    const n = try self.typeName(chan_ty);
                    defer self.gpa.free(n);
                    try self.emit(mf, k[1], .invalid_operand, "receive requires a channel operand, found '{s}'", .{n}, null);
                }
                if (k[0] == ast.none) return;
                if (mf.tree.get(k[0]).tag == .tuple_pat) {
                    try self.bindPattern2(file_idx, k[0], elem, self.ctx.prim_ids.get(.bool));
                } else {
                    try self.bindSimple(file_idx, k[0], elem);
                }
            },
            else => {},
        }
    }

    fn checkSelectStmt(self: *Checker, file_idx: usize, node: ast.Index, fctx: FnCtx) Error!void {
        const mf = self.files[file_idx];
        var inner = fctx;
        inner.breakable_depth += 1;
        for (mf.tree.kids(node)) |c| {
            switch (mf.tree.get(c).tag) {
                .comm_case => {
                    const ck = mf.tree.kids(c); // [comm, stmt_list]
                    try self.checkComm(file_idx, ck[0], inner);
                    try self.checkStmtList(file_idx, ck[1], inner);
                },
                .comm_default => try self.checkStmtList(file_idx, mf.tree.kids(c)[0], inner),
                else => {},
            }
        }
    }

    fn checkStmt(self: *Checker, file_idx: usize, node: ast.Index, fctx: FnCtx) Error!void {
        const mf = self.files[file_idx];
        switch (mf.tree.get(node).tag) {
            .block => try self.checkBlock(file_idx, node, fctx),
            .let_decl => for (mf.tree.kids(node)) |b| try self.checkBinding(file_idx, b, false, false, fctx),
            .const_decl => for (mf.tree.kids(node)) |b| try self.checkBinding(file_idx, b, true, false, fctx),
            .assign => try self.checkAssign(file_idx, node, fctx),
            .inc_stmt, .dec_stmt => try self.checkIncDec(file_idx, node, fctx),
            .expr_stmt => try self.checkExprStmt(file_idx, node, fctx),
            .send_stmt => try self.checkSendStmt(file_idx, node, fctx),
            .return_stmt => try self.checkReturnStmt(file_idx, node, fctx),
            .fail_stmt => try self.checkFailStmt(file_idx, node, fctx),
            .break_stmt => if (fctx.breakable_depth == 0) try self.emit(mf, node, .invalid_break_continue, "'break' outside a for/while/switch/select", .{}, null),
            .continue_stmt => if (fctx.loop_depth == 0) try self.emit(mf, node, .invalid_break_continue, "'continue' outside a for/while loop", .{}, null),
            .spawn_stmt => try self.checkSpawnDefer(file_idx, node, fctx, true),
            .defer_stmt => try self.checkSpawnDefer(file_idx, node, fctx, false),
            .if_stmt => try self.checkIfStmt(file_idx, node, fctx),
            .while_stmt => try self.checkWhileStmt(file_idx, node, fctx),
            .for_c => try self.checkForC(file_idx, node, fctx),
            .for_of => try self.checkForOf(file_idx, node, fctx),
            .for_in => try self.checkForIn(file_idx, node, fctx),
            .for_inf => {
                var inner = fctx;
                inner.loop_depth += 1;
                inner.breakable_depth += 1;
                try self.checkBlock(file_idx, mf.tree.kids(node)[0], inner);
            },
            .switch_stmt => try self.checkSwitchStmt(file_idx, node, fctx),
            .select_stmt => try self.checkSelectStmt(file_idx, node, fctx),
            else => {},
        }
    }

    // ---- return-path / divert-path completeness (§10.3, §18.3) --------------

    fn isPanicCall(self: *Checker, file_idx: usize, node: ast.Index) bool {
        const mf = self.files[file_idx];
        if (mf.tree.get(node).tag != .call) return false;
        const callee = mf.tree.kids(node)[0];
        if (mf.tree.get(callee).tag != .ident) return false;
        const gsym = self.nodeSymbol(file_idx, callee) orelse return false;
        const sym = self.symbolOf(gsym);
        return sym.kind == .builtin_func and std.mem.eql(u8, sym.name, "panic");
    }

    /// Does `node` (a loop body block) contain a `break`/`continue` that
    /// targets *this* loop — i.e. one not shadowed by a nested for/while/
    /// switch/select (whose own break/continue targets that inner construct
    /// instead)? Bounded depth, mirrors `diverges`'s own recursion shape.
    fn containsOwnBreak(self: *Checker, file_idx: usize, node: ast.Index) bool {
        return self.containsOwnBreakDepth(file_idx, node, 0);
    }

    fn containsOwnBreakDepth(self: *Checker, file_idx: usize, node: ast.Index, depth: u32) bool {
        if (depth >= max_type_depth) return false;
        const mf = self.files[file_idx];
        switch (mf.tree.get(node).tag) {
            .break_stmt => return true,
            .for_c, .for_of, .for_in, .for_inf, .while_stmt, .switch_stmt, .select_stmt => return false,
            .block, .stmt_list => {
                for (mf.tree.kids(node)) |s| if (self.containsOwnBreakDepth(file_idx, s, depth + 1)) return true;
                return false;
            },
            .if_stmt => {
                const k = mf.tree.kids(node);
                if (self.containsOwnBreakDepth(file_idx, k[1], depth + 1)) return true;
                if (k[2] != ast.none) return self.containsOwnBreakDepth(file_idx, k[2], depth + 1);
                return false;
            },
            else => return false,
        }
    }

    fn blockDiverges(self: *Checker, file_idx: usize, node: ast.Index, count_break_continue: bool) bool {
        for (self.files[file_idx].tree.kids(node)) |s| {
            if (self.diverges(file_idx, s, count_break_continue)) return true;
        }
        return false;
    }

    /// Does executing `node` (a statement or block) guarantee control never
    /// falls through past it? Used both for §10.3's "every path returns" and
    /// for `catch_bind`'s "block must ... divert control" rule (§18.3) — the
    /// two differ only in whether `break`/`continue` count as diverting
    /// (they do for a catch block, transferring control to an enclosing
    /// loop/switch exit; they don't by themselves guarantee a *function*
    /// returns, since `break` can simply fall through to code after its
    /// loop). Conservative: anything not provably terminating is treated as
    /// falling through, never the reverse — a missed `missing_return` is a
    /// bug, a spurious one just asks for a harmless explicit `return`.
    fn diverges(self: *Checker, file_idx: usize, node: ast.Index, count_break_continue: bool) bool {
        const mf = self.files[file_idx];
        switch (mf.tree.get(node).tag) {
            .return_stmt, .fail_stmt => return true,
            .break_stmt, .continue_stmt => return count_break_continue,
            .block => return self.blockDiverges(file_idx, node, count_break_continue),
            .expr_stmt => return self.isPanicCall(file_idx, mf.tree.kids(node)[0]),
            .if_stmt => {
                const k = mf.tree.kids(node);
                if (k[2] == ast.none) return false;
                return self.diverges(file_idx, k[1], count_break_continue) and self.diverges(file_idx, k[2], count_break_continue);
            },
            .while_stmt => {
                const k = mf.tree.kids(node);
                if (self.constEval(file_idx, k[0], 0)) |v| {
                    if (v == .boolean and v.boolean) return !self.containsOwnBreak(file_idx, k[1]);
                }
                return false;
            },
            .for_inf => return !self.containsOwnBreak(file_idx, mf.tree.kids(node)[0]),
            .for_c, .for_of, .for_in => return false, // never provably >0 iterations
            .switch_stmt => {
                const k = mf.tree.kids(node);
                var has_default = false;
                var all = true;
                for (mf.tree.kids(k[1])) |c| {
                    switch (mf.tree.get(c).tag) {
                        .switch_case => if (!self.blockDiverges(file_idx, mf.tree.kids(c)[1], count_break_continue)) {
                            all = false;
                        },
                        .switch_default => {
                            has_default = true;
                            if (!self.blockDiverges(file_idx, mf.tree.kids(c)[0], count_break_continue)) all = false;
                        },
                        else => {},
                    }
                }
                return has_default and all;
            },
            .select_stmt => {
                const clauses = mf.tree.kids(node);
                if (clauses.len == 0) return true; // `select {}` blocks forever
                for (clauses) |c| {
                    const sl = switch (mf.tree.get(c).tag) {
                        .comm_case => mf.tree.kids(c)[1],
                        .comm_default => mf.tree.kids(c)[0],
                        else => continue,
                    };
                    if (!self.blockDiverges(file_idx, sl, count_break_continue)) return false;
                }
                return true;
            },
            else => return false,
        }
    }

    // ---- function bodies & top-level driver ----------------------------------

    fn checkFuncBody(self: *Checker, file_idx: usize, idx: ast.Index) Error!void {
        const mf = self.files[file_idx];
        const k = mf.tree.kids(idx); // [recv, name, generics, params, result, body]
        if (k[5] == ast.none) return; // defensive: func_decl always carries a body
        const is_method = k[0] != ast.none;

        var env: GenericEnv = &.{};
        var params: []const TypeId = &.{};
        var result: TypeId = self.ctx.void_id;

        if (is_method) {
            const mc = self.method_ctx.get(packFileNode(file_idx, idx)) orelse return; // receiver type failed to resolve; already diagnosed
            env = mc.env;
            const name = Checker.identText(mf, k[1]);
            const bucket = self.ctx.methodsOf(mc.recv_ty) orelse return;
            const method = bucket.get(name) orelse return;
            params = method.params;
            result = method.result;

            const rk = mf.tree.kids(k[0]); // receiver: [name, type_name]
            try self.bindSimple(file_idx, rk[0], mc.recv_ty);
        } else {
            const gsym = self.nodeSymbol(file_idx, k[1]) orelse return;
            env = try self.rebuiltOwnGenericEnv(gsym);
            const shape = self.ctx.func_sigs.get(gsym.pack()) orelse return;
            params = shape.params;
            result = shape.result;
        }

        const param_nodes = mf.tree.kids(k[3]);
        for (param_nodes, 0..) |p_idx, i| {
            if (i >= params.len) break; // defensive: arities already matched at collection time
            const pk = mf.tree.kids(p_idx); // [name, type]
            // A variadic param's declared type (`params[i]`) is the element
            // type T; inside the body it's bound as `[]T` (§10.3).
            const bind_ty = if (mf.tree.get(p_idx).tag == .param_rest)
                try self.ctx.types.intern(.{ .slice = params[i] })
            else
                params[i];
            try self.bindSimple(file_idx, pk[0], bind_ty);
        }

        // §18.2: `result` here is the *boxed* value for a fallible signature
        // — unwrap to the ok type for `return`'s target and the err type for
        // `fail`/`?`.
        var result_ty = result;
        var err_ty: TypeId = .invalid;
        if (self.ctx.typeOf(result) == .fallible) {
            const f = self.ctx.typeOf(result).fallible;
            result_ty = f.ok;
            err_ty = f.err;
        }

        const fctx = FnCtx{ .env = env, .result_ty = result_ty, .err_ty = err_ty };
        try self.checkBlock(file_idx, k[5], fctx);

        if (result_ty != self.ctx.void_id and result_ty != .invalid and !self.diverges(file_idx, k[5], false)) {
            try self.emit(mf, k[1], .missing_return, "missing return: not every path returns a value", .{}, null);
        }
    }

    fn checkTopDecl(self: *Checker, file_idx: usize, idx: ast.Index) Error!void {
        const mf = self.files[file_idx];
        const inner = if (mf.tree.get(idx).tag == .@"export") mf.tree.kids(idx)[0] else idx;
        switch (mf.tree.get(inner).tag) {
            .func_decl => try self.checkFuncBody(file_idx, inner),
            .let_decl, .const_decl => try self.checkTopBinding(file_idx, inner),
            else => {}, // struct/interface/type_alias/import: nothing to body-check
        }
    }

    fn checkBodies(self: *Checker) Error!void {
        for (self.files, 0..) |mf, file_idx| {
            for (mf.tree.kids(mf.tree.root)) |decl_idx| {
                if (decl_idx == ast.none) continue;
                try self.checkTopDecl(file_idx, decl_idx);
            }
        }
    }
};

/// Decodes a `FLOAT_LIT` token's source text (§5.5). `_` separators are
/// stripped first; Zig's own float parser accepts both decimal and the
/// `0x1.8p3` hex-float form used here.
fn parseFloatLiteral(text: []const u8) f64 {
    var buf: [80]u8 = undefined;
    if (text.len > buf.len) return 0;
    var n: usize = 0;
    for (text) |c| {
        if (c == '_') continue;
        buf[n] = c;
        n += 1;
    }
    return std.fmt.parseFloat(f64, buf[0..n]) catch 0;
}

fn methodShapeEql(a: Method, b: Method) bool {
    if (a.variadic != b.variadic or a.result != b.result) return false;
    if (a.params.len != b.params.len) return false;
    for (a.params, b.params) |x, y| if (x != y) return false;
    return true;
}

/// Insertion sort by name — interface method sets are canonicalized this way
/// so identity (§14.1) doesn't depend on declaration order. Bounded: method
/// lists are small.
fn insertionSortMethods(items: []Method) void {
    var i: usize = 1;
    while (i < items.len) : (i += 1) {
        const key = items[i];
        var j = i;
        while (j > 0 and std.mem.order(u8, items[j - 1].name, key.name) == .gt) : (j -= 1) items[j] = items[j - 1];
        items[j] = key;
    }
}

fn setDisplayName(ctx: *TypeContext, id: TypeId, name: []const u8) Error!void {
    const gop = try ctx.display_names.getOrPut(ctx.gpa, @intFromEnum(id));
    if (!gop.found_existing) gop.value_ptr.* = name;
}

/// Bounded Levenshtein distance (both inputs are short identifiers).
fn editDistance(a: []const u8, b: []const u8) usize {
    const max_len = 64;
    if (a.len > max_len or b.len > max_len) return max_len;
    var prev: [max_len + 1]usize = undefined;
    var cur: [max_len + 1]usize = undefined;
    for (0..b.len + 1) |j| prev[j] = j;
    for (1..a.len + 1) |i| {
        cur[0] = i;
        for (1..b.len + 1) |j| {
            const cost: usize = if (a[i - 1] == b[j - 1]) 0 else 1;
            cur[j] = @min(@min(cur[j - 1] + 1, prev[j] + 1), prev[j - 1] + cost);
        }
        std.mem.swap([max_len + 1]usize, &prev, &cur);
    }
    return prev[b.len];
}


// ============================================================================
// Literal decoding (§5.4–§5.6) — bounded, trusts the lexer already validated
// digit/escape shape; used for untyped-constant representability (§15.4).
// ============================================================================

fn decodeDigit(c: u8) i128 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => 0,
    };
}

/// Decodes an `INT_LIT` token's source text (§5.4) to its arbitrary-precision
/// value. `_` separators are skipped; base prefixes select the radix.
pub fn parseIntLiteral(text: []const u8) i128 {
    var base: i128 = 10;
    var digits = text;
    if (text.len > 1 and text[0] == '0') {
        switch (text[1]) {
            'x', 'X' => {
                base = 16;
                digits = text[2..];
            },
            'o', 'O' => {
                base = 8;
                digits = text[2..];
            },
            'b', 'B' => {
                base = 2;
                digits = text[2..];
            },
            else => {},
        }
    }
    var value: i128 = 0;
    for (digits) |c| {
        if (c == '_') continue;
        value = value * base + decodeDigit(c);
    }
    return value;
}

/// Decodes a `RUNE_LIT` token's source text, quotes included, to its scalar
/// value (§5.6).
pub fn parseRuneLiteral(text: []const u8) i128 {
    if (text.len < 3) return 0;
    const inner = text[1 .. text.len - 1];
    if (inner.len == 0) return 0;
    if (inner[0] != '\\') {
        const len = std.unicode.utf8ByteSequenceLength(inner[0]) catch return inner[0];
        if (len > inner.len) return inner[0];
        const cp = std.unicode.utf8Decode(inner[0..len]) catch return inner[0];
        return cp;
    }
    if (inner.len < 2) return 0;
    return switch (inner[1]) {
        'n' => '\n',
        'r' => '\r',
        't' => '\t',
        '\\' => '\\',
        '\'' => '\'',
        '"' => '"',
        '0' => 0,
        'x' => if (inner.len >= 4) (std.fmt.parseInt(u8, inner[2..4], 16) catch 0) else 0,
        'u' => blk: {
            const close = std.mem.indexOfScalar(u8, inner, '}') orelse break :blk 0;
            if (close <= 3) break :blk 0;
            break :blk std.fmt.parseInt(u32, inner[3..close], 16) catch 0;
        },
        else => 0,
    };
}

test "literal decoders handle bases, separators, and rune escapes" {
    try std.testing.expectEqual(@as(i128, 42), parseIntLiteral("42"));
    try std.testing.expectEqual(@as(i128, 1000), parseIntLiteral("1_000"));
    try std.testing.expectEqual(@as(i128, 255), parseIntLiteral("0xFF"));
    try std.testing.expectEqual(@as(i128, 15), parseIntLiteral("0o17"));
    try std.testing.expectEqual(@as(i128, 10), parseIntLiteral("0b1010"));
    try std.testing.expectEqual(@as(i128, 'A'), parseRuneLiteral("'A'"));
    try std.testing.expectEqual(@as(i128, '\n'), parseRuneLiteral("'\\n'"));
    try std.testing.expectEqual(@as(i128, 0x41), parseRuneLiteral("'\\x41'"));
    try std.testing.expectEqual(@as(i128, 0x1F600), parseRuneLiteral("'\\u{1F600}'"));
}

// ============================================================================
// Checker — type-expression evaluation
// ============================================================================

/// Maps a `builtin_type` symbol's name (§5.3) to its `TypeId`, including the
/// fixed-size aliases (`int`/`uint`/`byte`/`rune`) and the predeclared `error`
/// interface. `null` for anything else.
fn builtinTypeId(ctx: *TypeContext, name: []const u8) ?TypeId {
    if (std.mem.eql(u8, name, "error")) return ctx.error_id;
    if (std.mem.eql(u8, name, "int")) return ctx.prim_ids.get(.i64);
    if (std.mem.eql(u8, name, "uint")) return ctx.prim_ids.get(.u64);
    if (std.mem.eql(u8, name, "byte")) return ctx.prim_ids.get(.u8);
    if (std.mem.eql(u8, name, "rune")) return ctx.prim_ids.get(.i32);
    inline for (std.meta.fields(Prim)) |f| {
        if (std.mem.eql(u8, name, f.name)) return ctx.prim_ids.get(@field(Prim, f.name));
    }
    return null;
}

/// Strips an `@"export"` wrapper (struct fields, interface use is unaffected).
fn unwrapExport(mf: ModuleFile, idx: ast.Index) ast.Index {
    return if (mf.tree.get(idx).tag == .@"export") mf.tree.kids(idx)[0] else idx;
}

// ============================================================================
// Public entry point
// ============================================================================

/// Per-node type annotations for one checked module. `TypeId.invalid` marks a
/// node with no type (a statement, a poisoned expression, ...). Outlives the
/// `TypeContext` it references only until `ctx.deinit()` — the two are always
/// freed together by convention (mirrors `SourceManager`/`Diagnostics`).
pub const CheckedModule = struct {
    gpa: Allocator,
    node_types: [][]TypeId,
    /// Set only when `checkModule` is called with `dump_types = true`: the
    /// `bitc check --dump-types` positive-suite surface (task #335's Verify
    /// section) — one line per `let`/`const` binding, lambda parameter, and
    /// call expression, sorted by source position. `null` otherwise so the
    /// normal compile path pays nothing for it.
    type_dump: ?[]u8 = null,
    /// Moved out of `Checker.call_insts` (see its doc comment) — lowering's
    /// only use for this module past `checkModule` returning.
    call_insts: std.AutoHashMapUnmanaged(u64, u32) = .{},
    /// Moved out of `Checker.const_inits` (see its doc comment) — lowering
    /// inlines a top-level `const`'s initializer by re-lowering the node this
    /// maps its symbol to.
    const_inits: std.AutoHashMapUnmanaged(SymbolId, ast.Index) = .{},

    pub fn deinit(self: *CheckedModule) void {
        for (self.node_types) |nt| self.gpa.free(nt);
        self.gpa.free(self.node_types);
        if (self.type_dump) |d| self.gpa.free(d);
        self.call_insts.deinit(self.gpa);
        self.const_inits.deinit(self.gpa);
        self.* = undefined;
    }

    pub fn typeOf(self: *const CheckedModule, file_idx: usize, node: ast.Index) TypeId {
        return self.node_types[file_idx][node];
    }

    /// The `ctx.instantiations` index a generic-function call node resolved
    /// to, if `node` is such a call — see `Checker.call_insts`.
    pub fn instantiationOf(self: *const CheckedModule, file_idx: usize, node: ast.Index) ?u32 {
        return self.call_insts.get(packFileNode(file_idx, node));
    }

    /// The initializer node of the top-level `const` bound to `sym` (a
    /// simple-`ident` binding in this module), or `null` — see
    /// `Checker.const_inits`. Lowering inlines it at each reference.
    pub fn constInitOf(self: *const CheckedModule, sym: SymbolId) ?ast.Index {
        return self.const_inits.get(sym);
    }
};

/// 0-based line/column for a byte `offset` into `source`. Mirrors
/// `diagnostics.SourceManager.locate` but works directly off a borrowed
/// source slice instead of a registered `FileId` — `dumpTypesText` only
/// ever has `ModuleFile.source` at hand, not a `SourceManager`.
fn locateOffset(source: []const u8, offset: u32) struct { line: u32, col: u32 } {
    var line: u32 = 0;
    var line_start: u32 = 0;
    var i: u32 = 0;
    // Bounded by `offset` (Power of 10): single pass, no unbounded loop.
    while (i < offset) : (i += 1) {
        if (source[i] == '\n') {
            line += 1;
            line_start = i + 1;
        }
    }
    return .{ .line = line, .col = offset - line_start };
}

/// Type-checks one already-resolved module. `ctx` is a project-lifetime
/// `TypeContext` shared across every module of one `bit build`-style
/// invocation; `module_id` is this module's own id in whatever `all_modules`
/// numbering the caller uses (mirroring `resolve.ModuleId`). Modules must be
/// checked in dependency order — the same order `resolve.loadProject` already
/// establishes — so that by the time a dependent module runs, `ctx` already
/// holds every type/signature/method-set its imports need (see module doc
/// comment).
pub fn checkModule(
    gpa: Allocator,
    diags: *Diagnostics,
    ctx: *TypeContext,
    files: []const ModuleFile,
    module: *const Module,
    module_id: ModuleId,
    all_modules: []const Module,
    dump_types: bool,
) Error!CheckedModule {
    const node_types = try gpa.alloc([]TypeId, files.len);
    var built: usize = 0;
    errdefer {
        for (node_types[0..built]) |nt| gpa.free(nt);
        gpa.free(node_types);
    }
    for (files, 0..) |mf, i| {
        const arr = try gpa.alloc(TypeId, mf.tree.nodes.len);
        @memset(arr, .invalid);
        node_types[i] = arr;
        built += 1;
    }

    var checker = Checker{
        .gpa = gpa,
        .diags = diags,
        .ctx = ctx,
        .files = files,
        .module = module,
        .module_id = module_id,
        .all_modules = all_modules,
        .node_types = node_types,
    };
    try checker.collectDecls();
    try checker.checkBodies();
    const dump = if (dump_types) try checker.dumpTypesText() else null;
    // `call_insts`/`const_inits` are moved out (not freed by `deinitLocal`,
    // which only ever owned the checking-time-only tables) into the returned
    // `CheckedModule`.
    const call_insts = checker.call_insts;
    const const_inits = checker.const_inits;
    checker.deinitLocal();
    return .{ .gpa = gpa, .node_types = node_types, .type_dump = dump, .call_insts = call_insts, .const_inits = const_inits };
}

const testing = std.testing;

fn parseOne(gpa: Allocator, diags: *Diagnostics, sm: *diagnostics.SourceManager, tree: *ast.Tree, path: []const u8, source: []const u8) !ModuleFile {
    const file = try sm.addFile(path, source);
    tree.* = try ast.Tree.init(gpa);
    const parser = @import("parser.zig");
    try parser.parse(gpa, tree, diags, file, source);
    return .{ .file = file, .source = source, .tree = tree };
}

test "collectDecls builds a struct's field types" {
    const gpa = testing.allocator;
    var sm = diagnostics.SourceManager.init(gpa);
    defer sm.deinit();
    var diags = Diagnostics.init(gpa, &sm);
    defer diags.deinit();

    var tree: ast.Tree = undefined;
    const src = "struct Point { x: f64; y: f64 }\n";
    const mf = try parseOne(gpa, &diags, &sm, &tree, "t.bit", src);
    defer tree.deinit();
    try testing.expect(!diags.hasErrors());

    var no_imports: resolve.ImportTable = .{};
    defer no_imports.deinit(gpa);
    const files = [_]ModuleFile{mf};
    var module = try resolve.resolveModule(gpa, &diags, &files, &no_imports, &.{}, null);
    defer module.deinit();
    try testing.expect(!diags.hasErrors());

    var ctx = try TypeContext.init(gpa);
    defer ctx.deinit();
    var checked = try checkModule(gpa, &diags, &ctx, &files, &module, @enumFromInt(0), &.{}, false);
    defer checked.deinit();
    try testing.expect(!diags.hasErrors());

    const point_sym = module.all_names.get("Point").?;
    const gsym = GlobalSymbol{ .module = @enumFromInt(0), .id = point_sym };
    const id = ctx.decl_memo.get(gsym.pack()).?;
    const shape = ctx.typeOf(id);
    try testing.expectEqual(@as(usize, 2), shape.@"struct".len);
    try testing.expectEqualStrings("x", shape.@"struct"[0].name);
    try testing.expectEqual(ctx.prim_ids.get(.f64), shape.@"struct"[0].ty);
}



test "constEval folds literals, unary, binary, and const references" {
    const gpa = testing.allocator;
    var sm = diagnostics.SourceManager.init(gpa);
    defer sm.deinit();
    var diags = Diagnostics.init(gpa, &sm);
    defer diags.deinit();
    var tree: ast.Tree = undefined;
    const src = "const a = 2 + 3 * 4\nconst b = a\n";
    const mf = try parseOne(gpa, &diags, &sm, &tree, "t.bit", src);
    defer tree.deinit();
    try testing.expect(!diags.hasErrors());

    var no_imports: resolve.ImportTable = .{};
    defer no_imports.deinit(gpa);
    const files = [_]ModuleFile{mf};
    var module = try resolve.resolveModule(gpa, &diags, &files, &no_imports, &.{}, null);
    defer module.deinit();

    var ctx = try TypeContext.init(gpa);
    defer ctx.deinit();
    var checker = Checker{
        .gpa = gpa, .diags = &diags, .ctx = &ctx, .files = &files, .module = &module,
        .module_id = @enumFromInt(0), .all_modules = &.{}, .node_types = try gpa.alloc([]TypeId, 1),
    };
    checker.node_types[0] = try gpa.alloc(TypeId, mf.tree.nodes.len);
    @memset(checker.node_types[0], .invalid);
    defer {
        gpa.free(checker.node_types[0]);
        gpa.free(checker.node_types);
        checker.const_inits.deinit(gpa); // normally moved into CheckedModule; freed by hand here
        checker.deinitLocal();
    }
    try checker.collectDecls();

    const a_id = module.all_names.get("a").?;
    const b_id = module.all_names.get("b").?;
    const a_init = checker.const_inits.get(a_id).?;
    const b_init = checker.const_inits.get(b_id).?;
    try testing.expectEqual(@as(i128, 14), checker.constEval(0, a_init, 0).?.int);
    try testing.expectEqual(@as(i128, 14), checker.constEval(0, b_init, 0).?.int);
    try testing.expect(checker.representable(14, ctx.prim_ids.get(.u8)));
    try testing.expect(!checker.representable(300, ctx.prim_ids.get(.u8)));
}
