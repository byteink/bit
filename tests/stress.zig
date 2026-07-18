//! Concurrency + GC stress suite (task #350): the production-readiness gate for
//! the runtime. Each subdirectory of `tests/stress/` is a Bit program that
//! hammers spawn / channels / select / the collector under load and prints a
//! single deterministic line encoding its own correctness (a checksum, a sum).
//!
//! Every program is run **twice** — once with the default collector policy, and
//! once under `BIT_GC=stress`, which collects at every safepoint. The second run
//! is a precise-rooting oracle: any root the compiler or runtime fails to report
//! is swept the instant it stops being marked, so a rooting bug that a rare
//! production collection would only occasionally hit becomes a deterministic
//! wrong answer here. Both runs must reproduce the program's `.expected` output.
//!
//! Skipped when the host is not a supported runtime target (no libbitrt to link
//! against), mirroring the golden `// run` cases and the examples guard.

const std = @import("std");
const builtin = @import("builtin");
const bit = @import("bit");
const build_options = @import("build_options");

const testing = std.testing;
const Io = std.Io;
const Dir = std.Io.Dir;

/// Upper bound on programs scanned — keeps the directory walk provably bounded
/// (Power of 10).
const max_programs = 256;

test "stress programs pass under default and BIT_GC=stress" {
    if (build_options.libbitrt_path.len == 0) return; // host not a runtime target

    const gpa = testing.allocator;
    const io = Io.Threaded.global_single_threaded.io();

    var dir = Dir.openDirAbsolute(io, build_options.stress_dir, .{ .iterate = true }) catch |e| {
        std.debug.print("cannot open stress dir '{s}': {s}\n", .{ build_options.stress_dir, @errorName(e) });
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

        const name = try gpa.dupe(u8, entry.name); // invalidated by the next step
        defer gpa.free(name);
        const dir_abs = try std.fs.path.join(gpa, &.{ build_options.stress_dir, name });
        defer gpa.free(dir_abs);

        try runStress(gpa, io, name, dir_abs, libbitrt);
    }
    try testing.expect(scanned < max_programs);
}

fn runStress(gpa: std.mem.Allocator, io: Io, name: []const u8, dir_abs: []const u8, libbitrt: []const u8) !void {
    // A program that can only run on Darwin marks itself with a `darwin-only`
    // file. `extern function` (SPEC §11.7) is the case that needs this: Bit's
    // ELF output is a fully static binary with no dynamic symbol table, so an
    // extern symbol has nothing to resolve against and the compiler rejects it
    // outright — the program is not merely expected to fail, it cannot compile.
    if (builtin.target.os.tag != .macos) {
        const marker = try std.fmt.allocPrint(gpa, "{s}/darwin-only", .{dir_abs});
        defer gpa.free(marker);
        if (Dir.cwd().access(io, marker, .{})) |_| return else |_| {}
    }

    var discard: Io.Writer.Allocating = .init(gpa);
    defer discard.deinit();
    const exe = (try bit.buildHostModule(gpa, io, dir_abs, libbitrt, &discard.writer)) orelse {
        std.debug.print("stress '{s}': compile failed:\n{s}\n", .{ name, discard.written() });
        return error.StressCompileFailed;
    };
    defer gpa.free(exe);

    const expected_path = try std.fmt.allocPrint(gpa, "{s}/{s}.expected", .{ dir_abs, name });
    defer gpa.free(expected_path);
    const expected = try Dir.cwd().readFileAlloc(io, expected_path, gpa, .limited(64 << 10));
    defer gpa.free(expected);

    const bin_path = try std.fmt.allocPrintSentinel(gpa, "/tmp/bit-stress-{s}-{x}", .{ name, testing.random_seed }, 0);
    defer gpa.free(bin_path);

    // Per-test io over `gpa` so `std.process.run`'s spawn arena does not trip
    // `testing.allocator`'s leak detector (same rationale as the examples guard).
    var run_threaded = Io.Threaded.init(gpa, .{});
    defer run_threaded.deinit();
    const run_io = run_threaded.io();

    try Dir.cwd().writeFile(run_io, .{ .sub_path = bin_path, .data = exe, .flags = .{ .permissions = .executable_file } });
    defer Dir.cwd().deleteFile(run_io, bin_path) catch {};

    try runOnce(gpa, run_io, name, bin_path, expected, null);

    var stress_env = std.process.Environ.Map.init(gpa);
    defer stress_env.deinit();
    try stress_env.put("BIT_GC", "stress");
    try runOnce(gpa, run_io, name, bin_path, expected, &stress_env);
}

fn runOnce(gpa: std.mem.Allocator, run_io: Io, name: []const u8, bin_path: [:0]const u8, expected: []const u8, env: ?*const std.process.Environ.Map) !void {
    const mode = if (env == null) "default" else "BIT_GC=stress";
    const result = try std.process.run(gpa, run_io, .{ .argv = &.{bin_path}, .environ_map = env });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);

    const code: u8 = switch (result.term) {
        .exited => |c| c,
        else => 255,
    };
    if (code != 0) {
        std.debug.print("stress '{s}' [{s}]: exited {d}\nstderr: {s}\n", .{ name, mode, code, result.stderr });
        return error.StressRunFailed;
    }
    if (!std.mem.eql(u8, result.stdout, expected)) {
        std.debug.print("stress '{s}' [{s}]: output mismatch\n  expected: {s}\n  got:      {s}\n", .{ name, mode, expected, result.stdout });
        return error.StressOutputMismatch;
    }
}
