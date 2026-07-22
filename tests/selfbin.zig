//! A private, per-run copy of the self-hosted `bit` for a harness to exec
//! (#1644).
//!
//! ## The failure this removes
//!
//! `zig build test` came back RED with EVERY `[selfhost]` case failing and both
//! streams empty — a signature indistinguishable from "the self-hosted compiler
//! cannot build anything any more", and one that already cost a gate run. It is
//! not a compiler fault at all:
//!
//! - `build.zig` emits `bit` from a Run step marked `has_side_effects`. Zig
//!   derives such a step's output digest from the INPUT hash alone
//!   (`Step/Run.zig`: `if (has_side_effects) man.hash.final()`), so the path is
//!   the same `.zig-cache/o/<digest>/bit` on every invocation, and the child
//!   writes STRAIGHT INTO it — there is no temp-then-rename.
//! - So a second `zig build` sharing that cache root truncates and rewrites the
//!   exact file a live harness is exec'ing.
//! - macOS then kills the exec at once, before `main`, with
//!   `EXC_CRASH / SIGKILL (Code Signature Invalid)`, `namespace CODESIGNING`.
//!   Nine such reports for `bit` with `parentProc: test` sit in
//!   `~/Library/Logs/DiagnosticReports` from one evening alone.
//!
//! Measured directly: exec'ing a binary in a loop while `cp` rewrote that same
//! path gave 39 failures in 42 execs — 33x rc=137 (SIGKILL) with empty output,
//! 1x rc=138 (SIGBUS), 5x "cannot execute binary file". The same loop against
//! an in-place rewrite of IDENTICAL bytes gave 0 failures in 4400 execs, which
//! is why this is intermittent: only a rewrite that truncates is fatal.
//!
//! ## The fix
//!
//! Copy the compiler once, to a path unique to this process, and exec the copy.
//! The exec'd inode is then never a write target, so no concurrent build can
//! reach it — the same write-then-publish defence `seed/link.zig` already
//! applies to the binaries it runs. Two independent halves, because either
//! alone can be defeated:
//!
//!   1. a unique name, so nothing else addresses this path at all;
//!   2. copy to `.staging` and rename into place, so even a name collision
//!      cannot have one process writing an inode another is exec'ing.
//!
//! The copy is then PROVEN runnable (`--version` must exit 0) before any case
//! depends on it. That closes the remaining window: the source file may itself
//! have been mid-rewrite while we read it, and a torn copy would otherwise fail
//! the whole corpus with the very signature this file exists to prevent. A
//! bounded retry re-copies; the bound is a constant, so the loop terminates.

const std = @import("std");
const Io = std.Io;
const Dir = Io.Dir;

const proc = @import("proc.zig");

/// Copy attempts before giving up. A torn read of the source is a narrow race
/// that a re-read clears; if three consecutive copies are unrunnable the
/// problem is not concurrency and the caller should hear about it.
const max_attempts: u8 = 3;

/// Seconds allowed to the `--version` proof-of-life. It is one process start
/// and one line of output; a bound far above that is still a bound.
const probe_timeout_s: u32 = 60;

/// Copies `src` to a path only this process names, verifies the copy actually
/// runs, and returns that path. Caller owns it and must `release` it.
pub fn privateCopy(gpa: std.mem.Allocator, io: Io, src: []const u8) ![:0]const u8 {
    return copy(gpa, io, src, .report);
}

/// Whether a failed attempt explains itself on stderr. `.quiet` exists for the
/// unit test below and nothing else: an unconditional print on a PASSING test
/// makes Zig tag the whole step `failed command:` (#1468), which is its own
/// small false red — the very thing this file was written to stop.
const Voice = enum { report, quiet };

fn copy(gpa: std.mem.Allocator, io: Io, src: []const u8, voice: Voice) ![:0]const u8 {
    std.debug.assert(src.len > 0);

    var attempt: u8 = 0;
    while (attempt < max_attempts) : (attempt += 1) {
        const path = try uniquePath(gpa, io);
        errdefer gpa.free(path);

        if (publish(io, src, path)) |_| {
            if (try runs(gpa, io, path, voice)) return path;
        } else |e| {
            if (voice == .report)
                std.debug.print("selfbin: copying '{s}' failed: {s}\n", .{ src, @errorName(e) });
        }
        Dir.cwd().deleteFile(io, path) catch {};
        gpa.free(path);
    }

    if (voice == .report) std.debug.print(
        "selfbin: could not produce a runnable copy of '{s}' in {d} attempts.\n" ++
            "  The compiler this suite is meant to test is not executable, so every\n" ++
            "  [selfhost] case below would have failed for that reason and not its own.\n",
        .{ src, max_attempts },
    );
    return error.SelfhostCompilerUnusable;
}

/// Deletes the copy and frees the path. Failing to unlink is not worth failing
/// a suite over — the name is unique, so a leftover collides with nothing.
pub fn release(gpa: std.mem.Allocator, io: Io, path: [:0]const u8) void {
    Dir.cwd().deleteFile(io, path) catch {};
    gpa.free(path);
}

/// A name no other process on this box uses. Seeded from the real-time clock
/// like `seed/main.zig`'s `scratchNonce`, and drawn afresh on every attempt, so
/// a retry never re-uses the name that just failed.
fn uniquePath(gpa: std.mem.Allocator, io: Io) ![:0]const u8 {
    const ns: i96 = Io.Timestamp.now(io, .real).nanoseconds;
    var prng = std.Random.DefaultPrng.init(@bitCast(@as(i64, @truncate(ns))));
    return std.fmt.allocPrintSentinel(gpa, "/tmp/bit-selfhost-{x}", .{prng.random().int(u64)}, 0);
}

/// Copy to a staging name, then rename onto `path`. The exec'd name is never
/// opened for writing, so a reader of `path` can only ever see a whole file.
fn publish(io: Io, src: []const u8, path: [:0]const u8) !void {
    var buf: [std.fs.max_path_bytes + 16]u8 = undefined;
    const staging = try std.fmt.bufPrintZ(&buf, "{s}.staging", .{path});
    const cwd = Dir.cwd();
    try cwd.copyFile(src, cwd, staging, io, .{ .permissions = .executable_file });
    try cwd.rename(staging, cwd, path, io);
}

/// Proof of life. Anything other than a clean exit 0 means the copy is not
/// usable, and the reason is reported here rather than 93 cases later.
///
/// A spawn that fails outright (`error.InvalidExe` on a torn copy, `AccessDenied`
/// on a lost permission bit) is an unrunnable copy like any other, not a
/// harness error to propagate: propagating it would skip the retry that is the
/// whole point of probing.
fn runs(gpa: std.mem.Allocator, io: Io, path: [:0]const u8, voice: Voice) !bool {
    const outcome = proc.run(gpa, io, probe_timeout_s, .{ .argv = &.{ path, "--version" } }) catch |e| {
        if (voice == .report)
            std.debug.print("selfbin: the copy at '{s}' could not be spawned: {s}\n", .{ path, @errorName(e) });
        return false;
    };
    switch (outcome) {
        .timed_out => |limit| {
            if (voice == .quiet) return false;
            std.debug.print("selfbin: the copy at '{s}' did not answer --version\n", .{path});
            proc.timedOutNote(limit, path);
            return false;
        },
        .finished => |r| {
            defer gpa.free(r.stdout);
            defer gpa.free(r.stderr);
            if (r.term == .exited and r.term.exited == 0) return true;
            if (voice == .quiet) return false;
            std.debug.print("selfbin: the copy at '{s}' is not runnable:\n", .{path});
            proc.toolFailedNote(r.term, path, r.stdout, r.stderr);
            return false;
        },
    }
}

/// A stand-in "compiler": executable, exits 0 for `--version`, and — unlike a
/// system binary such as `/bin/echo` — carries no platform code signature that
/// would refuse to validate once copied out of its blessed location. Written
/// under a unique name for the same reason everything else here is.
fn writeStubTool(gpa: std.mem.Allocator, io: Io) ![:0]const u8 {
    const path = try uniquePath(gpa, io);
    errdefer gpa.free(path);
    try Dir.cwd().writeFile(io, .{
        .sub_path = path,
        .data = "#!/bin/sh\nexit 0\n",
        .flags = .{ .permissions = .executable_file },
    });
    return path;
}

test "a private copy is unique, runnable, and leaves no staging file behind" {
    const gpa = std.testing.allocator;
    var threaded = Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const src = try writeStubTool(gpa, io);
    defer release(gpa, io, src);

    const a = try privateCopy(gpa, io, src);
    defer release(gpa, io, a);
    const b = try privateCopy(gpa, io, src);
    defer release(gpa, io, b);

    // Uniqueness is the first of the two defences: two copies must never be the
    // same file, or one harness could truncate another's.
    try std.testing.expect(!std.mem.eql(u8, a, b));
    try std.testing.expect(!std.mem.eql(u8, a, src));
    try std.testing.expect(std.mem.startsWith(u8, a, "/tmp/bit-selfhost-"));

    // Staging must not survive: a leftover would accumulate one per run.
    var buf: [std.fs.max_path_bytes + 16]u8 = undefined;
    const staging = try std.fmt.bufPrintZ(&buf, "{s}.staging", .{a});
    try std.testing.expectError(error.FileNotFound, Dir.cwd().statFile(io, staging, .{}));
}

test "an unrunnable source is refused, not passed on to the corpus" {
    const gpa = std.testing.allocator;
    var threaded = Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // `/etc/hosts` copies fine and is not a program: this exercises the probe,
    // which is the half that catches a torn copy of a real compiler. Without it
    // the corpus would run against a broken binary and blame itself.
    try std.testing.expectError(
        error.SelfhostCompilerUnusable,
        copy(gpa, io, "/etc/hosts", .quiet),
    );
}
