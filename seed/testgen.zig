//! Test-entry generation for `bit test` (#1105).
//!
//! A test is a top-level `function test_<name>()` in the *root* module: no
//! parameters, no result, not fallible (SPEC §19). Discovery is a scan of the
//! lowered module rather than a source pass, because lowering has already
//! resolved names — root-module functions keep their bare names while imported
//! ones are module-qualified (`m<id>$…`), so a bare `test_` prefix names exactly
//! the root module's tests and never a stdlib helper's.
//!
//! The runner needs one process per test (a failed `assert` panics and takes the
//! process with it), so instead of looping in-process we synthesize a `main`
//! that asks the runtime which single test to run and dispatches to it:
//!
//!     main() {
//!       i = bit_rt_test_index()      // BIT_TEST_INDEX, or -1
//!       if i == 0 { test_a() }
//!       else if i == 1 { test_b() }
//!       ...
//!       return
//!     }
//!
//! `bit test` then execs the produced binary once per test with `BIT_TEST_INDEX`
//! set. An out-of-range (or unset, `-1`) index falls through every check and
//! returns cleanly, so running a test binary by hand is a harmless no-op.

const std = @import("std");
const ir = @import("ir.zig");
const check = @import("check.zig");

/// A discovered test: its Bit name (owned — the lowered module that supplied it
/// is freed before the runner reports) and the function to call.
pub const Test = struct { name: []const u8, func: ir.FuncId };

/// Frees the slice returned by `injectTestMain`, including each owned name.
pub fn freeTests(gpa: std.mem.Allocator, tests: []const Test) void {
    for (tests) |t| gpa.free(t.name);
    gpa.free(tests);
}

/// Upper bound on tests in one module — keeps the dispatch chain provably
/// bounded (Power of 10). Raise if a real module approaches it.
pub const max_tests = 4096;

/// Whether `f` is a root-module test declaration. Instantiated generics and
/// methods carry a `$` in their emitted name; a test is a plain function.
fn isTest(f: *const ir.Function, void_id: check.TypeId) bool {
    if (!std.mem.startsWith(u8, f.name, "test_")) return false;
    if (std.mem.indexOfScalar(u8, f.name, '$') != null) return false;
    return f.param_types.len == 0 and f.result == void_id and !f.is_fallible;
}

/// Discovers the root module's tests and appends a synthetic `main` dispatching
/// to them. Any pre-existing `main` is renamed (a test module is not a program),
/// so exactly one `main` reaches the object writer.
///
/// Returns the discovered tests in dispatch order — index `i` in this slice is
/// the `BIT_TEST_INDEX` that runs it. Caller owns the slice (not the names).
pub fn injectTestMain(gpa: std.mem.Allocator, module: *ir.Module) ![]Test {
    const void_id = module.ctx.void_id;

    var tests: std.ArrayList(Test) = .empty;
    errdefer {
        for (tests.items) |t| gpa.free(t.name);
        tests.deinit(gpa);
    }
    for (module.funcs.items, 0..) |*f, i| {
        if (!isTest(f, void_id)) continue;
        if (tests.items.len == max_tests) return error.TooManyTests;
        try tests.append(gpa, .{ .name = try gpa.dupe(u8, f.name), .func = @enumFromInt(i) });
    }

    // A test module's own `main`, if any, is not the entry: rename it so the
    // synthetic one below is the only `main` symbol in the object. It stays a
    // normal (unreferenced) function and the linker's dead-strip drops it.
    for (module.funcs.items) |*f| {
        if (!std.mem.eql(u8, f.name, "main")) continue;
        const renamed = try gpa.dupe(u8, "__bit_module_main");
        gpa.free(f.name); // owned by the Function, same as its own deinit frees
        f.name = renamed;
        break;
    }

    var entry_fn = try buildDispatch(gpa, module.ctx, tests.items);
    // §17.6: the synthesized entry belongs to the module being built. `bit test`
    // never emits freestanding, so nothing reads this today — but leaving the
    // default would quietly mark the program's own entry "not mine".
    entry_fn.in_root_module = true;
    try module.funcs.append(gpa, entry_fn);
    return tests.toOwnedSlice(gpa);
}

/// Builds `main`: read the wanted index once, then walk a linear chain of
/// equality checks. `idx` is defined in the entry block, which dominates every
/// check block, so no block parameters are needed to thread it through.
fn buildDispatch(gpa: std.mem.Allocator, ctx: *check.TypeContext, tests: []const Test) !ir.Function {
    const i64_ty = ctx.prim_ids.get(.i64);
    const bool_ty = ctx.prim_ids.get(.bool);
    const void_ty = ctx.void_id;

    var b = ir.FunctionBuilder.init(gpa);
    errdefer b.deinit(gpa);

    const entry = try b.newBlock();

    if (tests.len == 0) {
        b.beginBlock(entry);
        try b.ret(&.{});
        b.endBlock();
        return b.finish("main", &.{}, void_ty, false, .invalid, entry);
    }

    // One `call_i` per test plus one shared `done`; `check_i` for i >= 1 (the
    // first check lives in the entry block, after the runtime call).
    const call_blocks = try gpa.alloc(ir.BlockId, tests.len);
    defer gpa.free(call_blocks);
    const check_blocks = try gpa.alloc(ir.BlockId, tests.len);
    defer gpa.free(check_blocks);
    for (call_blocks) |*c| c.* = try b.newBlock();
    check_blocks[0] = entry; // test 0's check lives in the entry block; never read
    for (check_blocks[1..]) |*c| c.* = try b.newBlock();
    const done = try b.newBlock();

    // entry: idx = test_index(); if idx == 0 -> call_0 else -> check_1 (or done)
    b.beginBlock(entry);
    const idx = try b.rtCall(i64_ty, .test_index, &.{});
    const zero = try b.constInt(i64_ty, 0);
    const eq0 = try b.binary(.icmp_eq, bool_ty, idx, zero);
    try b.br(eq0, call_blocks[0], &.{}, if (tests.len > 1) check_blocks[1] else done, &.{});
    b.endBlock();

    var i: usize = 1;
    while (i < tests.len) : (i += 1) {
        b.beginBlock(check_blocks[i]);
        const k = try b.constInt(i64_ty, @intCast(i));
        const eq = try b.binary(.icmp_eq, bool_ty, idx, k);
        try b.br(eq, call_blocks[i], &.{}, if (i + 1 < tests.len) check_blocks[i + 1] else done, &.{});
        b.endBlock();
    }

    for (tests, call_blocks) |t, blk| {
        b.beginBlock(blk);
        _ = try b.call(void_ty, t.func, &.{});
        try b.jump(done, &.{});
        b.endBlock();
    }

    b.beginBlock(done);
    try b.ret(&.{});
    b.endBlock();

    return b.finish("main", &.{}, void_ty, false, .invalid, entry);
}
