//! Examples compile-and-run guard.
//!
//! Discovers `examples/*.bit` and, for each, compiles it and runs the produced
//! binary, asserting the compile succeeds and the process exits 0. Unlike the
//! golden harness (tests/harness.zig) there are no directives and no
//! `.expected` files: examples are a showcase, not an output oracle, so the
//! only contract is "every example still builds and runs as the language
//! grows". Output correctness stays the golden corpus's job.
//!
//! Skipped when the host is not a supported runtime target (no libbitrt to link
//! against — build.zig leaves `libbitrt_path` empty then), mirroring the golden
//! `// run` cases.

const std = @import("std");
const bitc = @import("bitc");
const build_options = @import("build_options");

const testing = std.testing;
const Io = std.Io;
const Dir = std.Io.Dir;

/// Upper bound on examples scanned — keeps the directory walk provably bounded
/// (Power of 10). Raise if the folder ever approaches it.
const max_examples = 1024;

test "examples compile and run" {
    // No archive to link against: the host is not a supported runtime target,
    // so there is nothing to execute. The golden `// run` cases skip the same
    // way; treat the whole suite as skipped rather than a failure.
    if (build_options.libbitrt_path.len == 0) return;

    const gpa = testing.allocator;
    const io = Io.Threaded.global_single_threaded.io();

    var dir = Dir.openDirAbsolute(io, build_options.examples_dir, .{ .iterate = true }) catch |e| {
        std.debug.print("cannot open examples dir '{s}': {s}\n", .{ build_options.examples_dir, @errorName(e) });
        return e;
    };
    defer dir.close(io);

    const libbitrt = Dir.cwd().readFileAlloc(io, build_options.libbitrt_path, gpa, .limited(16 << 20)) catch |e| {
        std.debug.print("cannot read libbitrt '{s}': {s}\n", .{ build_options.libbitrt_path, @errorName(e) });
        return e;
    };
    defer gpa.free(libbitrt);

    // Each example is its own module: a subdirectory of examples/ holding one
    // `.bit` file (SPEC §17.1 — a module is a directory, and §17.4 — the root
    // module declares exactly one `main`). A flat folder of standalone programs
    // would put many `main`s in one namespace and fail resolve. Build each the
    // way `bit run <dir>` does — over the whole directory.
    var it = dir.iterate();
    var scanned: u32 = 0;
    while (scanned < max_examples) : (scanned += 1) {
        const entry = (try it.next(io)) orelse break;
        if (entry.kind != .directory) continue;

        // `entry.name` is invalidated by the next iterator step; copy it.
        const sub = try gpa.dupe(u8, entry.name);
        defer gpa.free(sub);

        const dir_abs = try std.fs.path.join(gpa, &.{ build_options.examples_dir, sub });
        defer gpa.free(dir_abs);

        try runExample(gpa, io, sub, dir_abs, libbitrt);
    }
    try testing.expect(scanned < max_examples); // folder stayed within bound
}

fn runExample(gpa: std.mem.Allocator, io: Io, name: []const u8, dir_abs: []const u8, libbitrt: []const u8) !void {
    var discard: Io.Writer.Allocating = .init(gpa);
    defer discard.deinit();
    const exe = (try bitc.buildHostModule(gpa, io, dir_abs, libbitrt, &discard.writer)) orelse {
        std.debug.print("example '{s}': expected compile to succeed, got diagnostics:\n{s}\n", .{ name, discard.written() });
        return error.ExampleCompileFailed;
    };
    defer gpa.free(exe);

    // A dedicated `Io.Threaded` over `gpa` (not the shared global io):
    // `std.process.run`'s spawn arena is backed by the io's allocator, and
    // mixing the global io's allocator with the per-test `testing.allocator`
    // trips its leak detector. Mirrors the golden run harness.
    var run_threaded = Io.Threaded.init(gpa, .{});
    defer run_threaded.deinit();
    const run_io = run_threaded.io();

    const bin_path = try std.fmt.allocPrintSentinel(gpa, "/tmp/bit-example-{s}", .{name}, 0);
    defer gpa.free(bin_path);
    try Dir.cwd().writeFile(run_io, .{
        .sub_path = bin_path,
        .data = exe,
        .flags = .{ .permissions = .executable_file },
    });
    defer Dir.cwd().deleteFile(run_io, bin_path) catch {};

    const result = try std.process.run(gpa, run_io, .{ .argv = &.{bin_path} });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    const code: u8 = switch (result.term) {
        .exited => |c| c,
        else => 255,
    };
    if (code != 0) {
        std.debug.print("example '{s}': binary exited with {d}\nstderr: {s}\n", .{ name, code, result.stderr });
        return error.ExampleRunFailed;
    }
}
