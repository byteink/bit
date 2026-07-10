//! The `bit test` runner (#1105): test discovery and per-test pass/fail.
//!
//! Drives the same machinery the CLI does — `buildHostTestExecutable` compiles
//! the module with `testgen`'s synthetic `main` and reports the discovered
//! tests, then each test is run by exec'ing that binary with `BIT_TEST_INDEX`
//! set. A test passes iff its process exits 0; a failed `assert` panics, which
//! is exactly why the runner spawns one process per test.

const std = @import("std");
const bitc = @import("bitc");
const build_options = @import("build_options");

const testing = std.testing;
const Io = std.Io;
const Dir = std.Io.Dir;

const source =
    \\function test_passes() {
    \\  assert(1 + 1 == 2, "arithmetic")
    \\}
    \\
    \\function test_also_passes() {
    \\  assert(len("abc") == 3)
    \\}
    \\
    \\function test_fails() {
    \\  assert(1 == 2, "one is not two")
    \\}
    \\
    \\function helper(): i64 {
    \\  return 1
    \\}
;

/// Runs test `index` of `bin_path` in its own process; returns whether it passed.
fn runOne(gpa: std.mem.Allocator, run_io: Io, bin_path: [:0]const u8, index: usize) !bool {
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    var buf: [24]u8 = undefined;
    try env.put("BIT_TEST_INDEX", try std.fmt.bufPrint(&buf, "{d}", .{index}));

    const result = try std.process.run(gpa, run_io, .{ .argv = &.{bin_path}, .environ_map = &env });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    return switch (result.term) {
        .exited => |c| c == 0,
        else => false, // signalled: the panic from a failed assert
    };
}

test "bit test: discovers test_ functions and reports pass/fail per test" {
    if (build_options.libbitrt_path.len == 0) return; // host not a runtime target

    const gpa = testing.allocator;
    const io = Io.Threaded.global_single_threaded.io();

    const libbitrt = try Dir.cwd().readFileAlloc(io, build_options.libbitrt_path, gpa, .limited(16 << 20));
    defer gpa.free(libbitrt);

    var discard: Io.Writer.Allocating = .init(gpa);
    defer discard.deinit();

    var tests: []bitc.testgen.Test = &.{};
    const exe = (try bitc.buildHostTestExecutable(gpa, "testcmd.bit", source, libbitrt, &discard.writer, &tests)) orelse {
        std.debug.print("bit test fixture: compile failed:\n{s}\n", .{discard.written()});
        return error.TestCompileFailed;
    };
    defer gpa.free(exe);
    defer bitc.testgen.freeTests(gpa, tests);

    // Discovery: only the three `test_` functions, in source order. `helper` and
    // the synthetic `main` are not tests.
    try testing.expectEqual(@as(usize, 3), tests.len);
    try testing.expectEqualStrings("test_passes", tests[0].name);
    try testing.expectEqualStrings("test_also_passes", tests[1].name);
    try testing.expectEqualStrings("test_fails", tests[2].name);

    // Per-test io over `gpa` so `std.process.run`'s spawn arena does not trip
    // `testing.allocator`'s leak detector (same rationale as the stress guard).
    var run_threaded = Io.Threaded.init(gpa, .{});
    defer run_threaded.deinit();
    const run_io = run_threaded.io();

    const bin_path = "/tmp/bit-testcmd-fixture";
    try Dir.cwd().writeFile(run_io, .{ .sub_path = bin_path, .data = exe, .flags = .{ .permissions = .executable_file } });
    defer Dir.cwd().deleteFile(run_io, bin_path) catch {};

    try testing.expect(try runOne(gpa, run_io, bin_path, 0)); // test_passes
    try testing.expect(try runOne(gpa, run_io, bin_path, 1)); // test_also_passes
    try testing.expect(!try runOne(gpa, run_io, bin_path, 2)); // test_fails: assert panics

    // An unset/out-of-range index dispatches to nothing and exits cleanly, so a
    // test binary run by hand is a harmless no-op.
    try testing.expect(try runOne(gpa, run_io, bin_path, 99));
}
