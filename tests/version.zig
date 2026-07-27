//! `bit version` (#1451).
//!
//! Two defects this guards, both of which shipped:
//!
//! 1. There was no real `version` subcommand. `bit version` only APPEARED to
//!    work because every unrecognized argument fell through to the banner,
//!    which happens to carry a version string — so `bit vresion` behaved
//!    identically. Asserting the happy path alone would still pass against that
//!    bug, so the typo case is asserted too: it must be a usage error and it
//!    must not print a version.
//!
//! 2. The two compilers disagreed about the version (`seed/main.zig` said
//!    "0.0.0" while `selfhost/version.bit` said "0.1.0-stub"). Both now derive
//!    from `selfhost/version.bit`, so this compares their actual output bytes
//!    rather than trusting that wiring.
//!
//! The expected string comes from `build_options`, which `build.zig` parses out
//! of `selfhost/version.bit` — the same value it stamps into both binaries.
//! That is deliberately not a hardcoded literal here: a release build overrides
//! it with `-Dversion=`, and this must hold for that build too.
//!
//! `seed_bit` is a normal Zig compile artifact (published by rename, like every
//! other `zig build` output) and is exec'd directly. `selfhost_bit` is emitted
//! by a `has_side_effects` Run step that rewrites the SAME path in place on
//! every build, so it is exec'd only via a private per-run copy
//! (`tests/selfbin.zig`, #1644) — otherwise a second concurrent `zig build`
//! truncates the very file this test is running, and macOS kills the exec with
//! no output. Every spawn, either binary, carries the shared `tests/proc.zig`
//! deadline (#1652/#1672).

const std = @import("std");
const build_options = @import("build_options");

const testing = std.testing;
const Io = std.Io;

const proc = @import("proc.zig");
const selfbin = @import("selfbin.zig");

/// Runs `bin` with `args` and returns the completed process. Caller frees
/// `stdout` and `stderr`. A timeout is never folded into a term: it is a
/// distinct, named failure (see `tests/proc.zig`'s header).
fn run(gpa: std.mem.Allocator, io: Io, timeout_s: u32, bin: []const u8, args: []const []const u8) !std.process.RunResult {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.append(gpa, bin);
    try argv.appendSlice(gpa, args);
    const outcome = try proc.run(gpa, io, timeout_s, .{ .argv = argv.items });
    return switch (outcome) {
        .finished => |r| r,
        .timed_out => |limit| {
            std.debug.print("version: '{s}' TIMED OUT\n", .{bin});
            proc.timedOutNote(limit, bin);
            return error.VersionTimedOut;
        },
    };
}

/// The exit status, or null when the process died by signal. A signal death is
/// never a pass: it is the failure mode that makes an exit-code-only assertion
/// meaningless.
fn exitCode(term: std.process.Child.Term) ?u8 {
    return switch (term) {
        .exited => |c| c,
        else => null,
    };
}

/// Asserts `bin version` prints exactly `bit <expected>` on stdout and exits 0.
fn expectVersionLine(gpa: std.mem.Allocator, io: Io, timeout_s: u32, bin: []const u8, flag: []const u8) !void {
    const r = try run(gpa, io, timeout_s, bin, &.{flag});
    defer gpa.free(r.stdout);
    defer gpa.free(r.stderr);

    const code = exitCode(r.term) orelse {
        std.debug.print("version: {s} {s} died by signal\n", .{ bin, flag });
        return error.VersionDiedBySignal;
    };
    if (code != 0) {
        std.debug.print("version: {s} {s} exited {d}: {s}\n", .{ bin, flag, code, r.stderr });
        return error.VersionExitedNonZero;
    }

    const want = try std.fmt.allocPrint(gpa, "bit {s}\n", .{build_options.expected_version});
    defer gpa.free(want);
    testing.expectEqualStrings(want, r.stdout) catch |e| {
        std.debug.print("version: {s} {s} printed the wrong line\n", .{ bin, flag });
        return e;
    };
}

test "bit version: the seed reports the stamped version" {
    const gpa = testing.allocator;
    var threaded = Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const timeout_s = proc.timeoutSeconds(gpa);
    try testing.expect(build_options.expected_version.len > 0);
    for ([_][]const u8{ "version", "--version", "-V" }) |flag| {
        try expectVersionLine(gpa, io, timeout_s, build_options.seed_bit, flag);
    }
}

test "bit version: the self-hosted compiler reports the same version as the seed" {
    if (build_options.selfhost_bit.len == 0) return; // cross build: no self-hosted bit

    const gpa = testing.allocator;
    var threaded = Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const timeout_s = proc.timeoutSeconds(gpa);

    const self_bit = try selfbin.privateCopy(gpa, io, build_options.selfhost_bit);
    defer selfbin.release(gpa, io, self_bit);

    for ([_][]const u8{ "version", "--version", "-V" }) |flag| {
        try expectVersionLine(gpa, io, timeout_s, self_bit, flag);
    }

    // Byte-for-byte between the two compilers, not merely "each matches the
    // build option": the differential harnesses compare these two binaries, and
    // a version skew between them is exactly what #1451 found.
    const seed = try run(gpa, io, timeout_s, build_options.seed_bit, &.{"version"});
    defer gpa.free(seed.stdout);
    defer gpa.free(seed.stderr);
    const self = try run(gpa, io, timeout_s, self_bit, &.{"version"});
    defer gpa.free(self.stdout);
    defer gpa.free(self.stderr);
    try testing.expectEqualStrings(seed.stdout, self.stdout);
}

test "bit: no arguments is a usage error, not a self-test" {
    // #1827: `bit` with no arguments ran the in-Bit self-check suite. That was
    // correct while the binary was a bootstrap artifact and wrong once it shipped:
    // a user who typed `bit` got lock-file test fixtures on stdout
    // ("pmlock check: no stale fixture to remove") and a wait long enough to look
    // like a hang. Asserting the exit code alone would not catch a regression here
    // — selfcheck also exits 0 on success — so stdout must be empty and the
    // fixture string must be absent.
    //
    // SELF-HOSTED ONLY, deliberately. The seed prints its version banner on
    // no-args and exits 0; it is the bootstrap oracle, is not distributed to
    // anyone, and is slated for retirement, so aligning its CLI ergonomics buys
    // nothing and touches the one binary the whole bootstrap trusts.
    if (build_options.selfhost_bit.len == 0) return; // cross build: no self-hosted bit

    const gpa = testing.allocator;
    var threaded = Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const timeout_s = proc.timeoutSeconds(gpa);

    const self_bit = try selfbin.privateCopy(gpa, io, build_options.selfhost_bit);
    defer selfbin.release(gpa, io, self_bit);

    const r = try run(gpa, io, timeout_s, self_bit, &.{});
    defer gpa.free(r.stdout);
    defer gpa.free(r.stderr);

    const code = exitCode(r.term) orelse {
        std.debug.print("version: {s} with no args died by signal\n", .{self_bit});
        return error.NoArgsDiedBySignal;
    };
    if (code != 2) {
        std.debug.print("version: {s} with no args exited {d}, want 2\n", .{ self_bit, code });
        return error.NoArgsNotAUsageError;
    }
    try testing.expectEqualStrings("", r.stdout);
    try testing.expect(std.mem.indexOf(u8, r.stderr, "usage: bit") != null);
    // The exact fixture line a user reported seeing. Named rather than implied, so
    // this fails loudly if any self-check output ever reaches a bare invocation.
    try testing.expect(std.mem.indexOf(u8, r.stdout, "pmlock check") == null);
    try testing.expect(std.mem.indexOf(u8, r.stderr, "pmlock check") == null);
}

// There is deliberately NO `bit selfcheck` test here, and the reason is COST, not
// correctness. `zig build test-selfcheck` already runs that exact subcommand and
// requires exit 0, so a second one adds no coverage — and selfcheck takes ~79s
// standalone, so a second concurrent runner under full-suite load blew the 300s
// `tests/proc.zig` deadline and reported `TIMED OUT` (measured, twice).
//
// The first attempt at this test failed for a DIFFERENT reason — pmlockcheck.bit's
// fixed /tmp fixture paths raced, 2 failures in 9 concurrent runs. That is fixed
// (#1828, per-process nonce), so concurrent selfchecks are now safe; they are just
// too slow to be worth duplicating. Raising BIT_TEST_TIMEOUT_S to accommodate a
// redundant test would weaken the deadline for every other harness.

test "bit version: a typo'd subcommand is a usage error, not the banner" {
    const gpa = testing.allocator;
    var threaded = Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const timeout_s = proc.timeoutSeconds(gpa);

    var self_bit: ?[:0]const u8 = null;
    defer if (self_bit) |p| selfbin.release(gpa, io, p);
    if (build_options.selfhost_bit.len > 0)
        self_bit = try selfbin.privateCopy(gpa, io, build_options.selfhost_bit);

    var bins: std.ArrayList([]const u8) = .empty;
    defer bins.deinit(gpa);
    try bins.append(gpa, build_options.seed_bit);
    if (self_bit) |p| try bins.append(gpa, p);

    for (bins.items) |bin| {
        const r = try run(gpa, io, timeout_s, bin, &.{"vresion"});
        defer gpa.free(r.stdout);
        defer gpa.free(r.stderr);

        const code = exitCode(r.term) orelse {
            std.debug.print("version: {s} vresion died by signal\n", .{bin});
            return error.TypoDiedBySignal;
        };
        if (code != 2) {
            std.debug.print("version: {s} vresion exited {d}, want 2\n", .{ bin, code });
            return error.TypoNotAUsageError;
        }
        // The original bug: the typo printed the version banner on stdout.
        // Asserting the exit code alone would not have caught it.
        try testing.expectEqualStrings("", r.stdout);
        try testing.expect(std.mem.indexOf(u8, r.stderr, "unknown subcommand") != null);
    }
}
