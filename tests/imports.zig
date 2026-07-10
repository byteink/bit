//! Multi-module imports + prelude guard (#1153).
//!
//! Each direct subdirectory of `tests/imports/` is a root module (its `main`);
//! it may import project-relative modules (`./util`) and standard-library
//! modules (`std/core`), and it sees the auto-imported prelude. The harness
//! builds each through the real whole-project pipeline (`buildHostProject` ->
//! loadProject + per-module check + lowerProject), runs it, and diffs stdout
//! against the module's `expected` file — so cross-module lowering and the
//! prelude can never silently regress.
//!
//! Skipped when the host is not a supported runtime target (no libbitrt), like
//! the golden `// run` cases and the other guards.

const std = @import("std");
const bitc = @import("bitc");
const build_options = @import("build_options");

const testing = std.testing;
const Io = std.Io;
const Dir = std.Io.Dir;

const max_programs = 256;

test "imports + prelude programs run with the expected output" {
    if (build_options.libbitrt_path.len == 0) return; // host not a runtime target

    const gpa = testing.allocator;
    const io = Io.Threaded.global_single_threaded.io();

    var dir = Dir.openDirAbsolute(io, build_options.imports_dir, .{ .iterate = true }) catch |e| {
        std.debug.print("cannot open imports dir '{s}': {s}\n", .{ build_options.imports_dir, @errorName(e) });
        return e;
    };
    defer dir.close(io);

    const libbitrt = Dir.cwd().readFileAlloc(io, build_options.libbitrt_path, gpa, .limited(16 << 20)) catch |e| {
        std.debug.print("cannot read libbitrt '{s}': {s}\n", .{ build_options.libbitrt_path, @errorName(e) });
        return e;
    };
    defer gpa.free(libbitrt);

    var it = dir.iterate();
    var scanned: u32 = 0;
    while (scanned < max_programs) : (scanned += 1) {
        const entry = (try it.next(io)) orelse break;
        if (entry.kind != .directory) continue;

        const name = try gpa.dupe(u8, entry.name);
        defer gpa.free(name);
        const dir_abs = try std.fs.path.join(gpa, &.{ build_options.imports_dir, name });
        defer gpa.free(dir_abs);

        try runProgram(gpa, io, name, dir_abs, libbitrt);
    }
    try testing.expect(scanned < max_programs);
}

fn runProgram(gpa: std.mem.Allocator, io: Io, name: []const u8, dir_abs: []const u8, libbitrt: []const u8) !void {
    var discard: Io.Writer.Allocating = .init(gpa);
    defer discard.deinit();
    const exe = (try bitc.buildHostProject(gpa, io, dir_abs, build_options.stdlib_dir, name, libbitrt, &discard.writer)) orelse {
        std.debug.print("imports '{s}': compile failed:\n{s}\n", .{ name, discard.written() });
        return error.ImportsCompileFailed;
    };
    defer gpa.free(exe);

    const expected_path = try std.fmt.allocPrint(gpa, "{s}/expected", .{dir_abs});
    defer gpa.free(expected_path);
    const expected = try Dir.cwd().readFileAlloc(io, expected_path, gpa, .limited(64 << 10));
    defer gpa.free(expected);

    var run_threaded = Io.Threaded.init(gpa, .{});
    defer run_threaded.deinit();
    const run_io = run_threaded.io();

    const bin_path = try std.fmt.allocPrintSentinel(gpa, "/tmp/bit-imports-{s}-{x}", .{ name, testing.random_seed }, 0);
    defer gpa.free(bin_path);
    try Dir.cwd().writeFile(run_io, .{ .sub_path = bin_path, .data = exe, .flags = .{ .permissions = .executable_file } });
    defer Dir.cwd().deleteFile(run_io, bin_path) catch {};

    const result = try std.process.run(gpa, run_io, .{ .argv = &.{bin_path} });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    const code: u8 = switch (result.term) {
        .exited => |c| c,
        else => 255,
    };
    if (code != 0) {
        std.debug.print("imports '{s}': exited {d}\nstderr: {s}\n", .{ name, code, result.stderr });
        return error.ImportsRunFailed;
    }
    if (!std.mem.eql(u8, result.stdout, expected)) {
        std.debug.print("imports '{s}': output mismatch\n  expected: {s}\n  got:      {s}\n", .{ name, expected, result.stdout });
        return error.ImportsOutputMismatch;
    }
}
