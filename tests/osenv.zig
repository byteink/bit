//! `std/os` argument + environment access (#354).
//!
//! Runs one Bit program twice with a controlled environment: the probe variable
//! unset, then set. That round-trip is what proves `osEnv` reads the real
//! process environment rather than a snapshot taken before `main`.

const std = @import("std");
const bit = @import("bit");
const build_options = @import("build_options");

const testing = std.testing;
const Io = std.Io;
const Dir = std.Io.Dir;

/// Runs `bin_path` with `probe` bound to BIT_OSENV_PROBE (or unset when null)
/// and returns its stdout. Caller frees.
fn runWithProbe(gpa: std.mem.Allocator, run_io: Io, bin_path: [:0]const u8, probe: ?[]const u8) ![]u8 {
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    if (probe) |p| try env.put("BIT_OSENV_PROBE", p);

    const result = try std.process.run(gpa, run_io, .{ .argv = &.{bin_path}, .environ_map = &env });
    defer gpa.free(result.stderr);
    errdefer gpa.free(result.stdout);
    switch (result.term) {
        .exited => |c| if (c != 0) {
            std.debug.print("osenv: exited {d}\nstderr: {s}\n", .{ c, result.stderr });
            return error.OsEnvRunFailed;
        },
        else => return error.OsEnvRunFailed,
    }
    return result.stdout;
}

test "std/os: args and environment round-trip" {
    if (build_options.libbitrt_path.len == 0) return; // host not a runtime target

    const gpa = testing.allocator;
    const io = Io.Threaded.global_single_threaded.io();

    const libbitrt = try Dir.cwd().readFileAlloc(io, build_options.libbitrt_path, gpa, .limited(16 << 20));
    defer gpa.free(libbitrt);

    var discard: Io.Writer.Allocating = .init(gpa);
    defer discard.deinit();
    const exe = (try bit.buildHostProject(gpa, io, build_options.osenv_dir, build_options.stdlib_dir, "osenv", libbitrt, &discard.writer)) orelse {
        std.debug.print("osenv fixture: compile failed:\n{s}\n", .{discard.written()});
        return error.OsEnvCompileFailed;
    };
    defer gpa.free(exe);

    // Per-test io over `gpa` so `std.process.run`'s spawn arena does not trip
    // `testing.allocator`'s leak detector (same rationale as the stress guard).
    var run_threaded = Io.Threaded.init(gpa, .{});
    defer run_threaded.deinit();
    const run_io = run_threaded.io();

    const bin_path = try std.fmt.allocPrintSentinel(gpa, "/tmp/bit-osenv-fixture-{x}", .{testing.random_seed}, 0);
    defer gpa.free(bin_path);
    try Dir.cwd().writeFile(run_io, .{ .sub_path = bin_path, .data = exe, .flags = .{ .permissions = .executable_file } });
    defer Dir.cwd().deleteFile(run_io, bin_path) catch {};

    // argv is just the program itself; the probe is unset, so it reads empty
    // and `envOr` falls back.
    const unset = try runWithProbe(gpa, run_io, bin_path, null);
    defer gpa.free(unset);
    try testing.expectEqualStrings(
        \\argc=1
        \\arg0_nonempty=true
        \\args_len_matches=true
        \\probe=[]
        \\fallback=default
        \\
    , unset);

    // Same binary, same argv — only the environment differs.
    const set = try runWithProbe(gpa, run_io, bin_path, "hello world");
    defer gpa.free(set);
    try testing.expectEqualStrings(
        \\argc=1
        \\arg0_nonempty=true
        \\args_len_matches=true
        \\probe=[hello world]
        \\fallback=default
        \\
    , set);
}
