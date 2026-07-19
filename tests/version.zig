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

const std = @import("std");
const build_options = @import("build_options");

const testing = std.testing;
const Io = std.Io;

/// Runs `bin` with `args` and returns the completed process. Caller frees
/// `stdout` and `stderr`.
fn run(gpa: std.mem.Allocator, io: Io, bin: []const u8, args: []const []const u8) !std.process.RunResult {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.append(gpa, bin);
    try argv.appendSlice(gpa, args);
    return std.process.run(gpa, io, .{ .argv = argv.items });
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
fn expectVersionLine(gpa: std.mem.Allocator, io: Io, bin: []const u8, flag: []const u8) !void {
    const r = try run(gpa, io, bin, &.{flag});
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

    try testing.expect(build_options.expected_version.len > 0);
    for ([_][]const u8{ "version", "--version", "-V" }) |flag| {
        try expectVersionLine(gpa, io, build_options.seed_bit, flag);
    }
}

test "bit version: the self-hosted compiler reports the same version as the seed" {
    if (build_options.selfhost_bit.len == 0) return; // cross build: no self-hosted bit

    const gpa = testing.allocator;
    var threaded = Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    for ([_][]const u8{ "version", "--version", "-V" }) |flag| {
        try expectVersionLine(gpa, io, build_options.selfhost_bit, flag);
    }

    // Byte-for-byte between the two compilers, not merely "each matches the
    // build option": the differential harnesses compare these two binaries, and
    // a version skew between them is exactly what #1451 found.
    const seed = try run(gpa, io, build_options.seed_bit, &.{"version"});
    defer gpa.free(seed.stdout);
    defer gpa.free(seed.stderr);
    const self = try run(gpa, io, build_options.selfhost_bit, &.{"version"});
    defer gpa.free(self.stdout);
    defer gpa.free(self.stderr);
    try testing.expectEqualStrings(seed.stdout, self.stdout);
}

test "bit version: a typo'd subcommand is a usage error, not the banner" {
    const gpa = testing.allocator;
    var threaded = Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var bins: std.ArrayList([]const u8) = .empty;
    defer bins.deinit(gpa);
    try bins.append(gpa, build_options.seed_bit);
    if (build_options.selfhost_bit.len > 0) try bins.append(gpa, build_options.selfhost_bit);

    for (bins.items) |bin| {
        const r = try run(gpa, io, bin, &.{"vresion"});
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
