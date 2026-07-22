//! Per-case wall-clock deadline for every subprocess a test harness spawns
//! (#1637).
//!
//! ## Why
//!
//! Both `tests/harness.zig` and `tests/stress.zig` used to call
//! `std.process.run` with no deadline, so a case whose program hangs — an
//! infinite loop, a deadlocked channel, a spliced `ret` that returns with the
//! link register unrestored — stalled the entire suite with no output naming
//! the case. That is strictly worse than a failure: CI burns its own job
//! timeout and the log does not say which case did it, and two hangs in a
//! single session (a `sleep()` that never returned, a QUIC teardown) had
//! exactly that shape. A hang must be a RED CASE, not a missing verdict.
//!
//! ## The three properties this gives up nothing on
//!
//! - **Only our own PID is killed.** `std.process.run` holds the `Child` it
//!   spawned and its `defer child.kill(io)` signals that pid and reaps it.
//!   Nothing here matches on process names: a `pkill -f`-style rule is a
//!   machine-global matcher for an agent-local intent and has already killed a
//!   peer agent's verification run in this repo. There is no such matcher in
//!   this file, and there must never be one.
//!
//! - **The bound is a single absolute deadline, so it is provably bounded**
//!   (Power of 10). `std.process.run` passes its `timeout` to *every*
//!   `MultiReader.fill` iteration, so a `.duration` would restart the clock on
//!   each chunk of output and a chatty hung program could out-run it forever.
//!   `deadlineFromNow` therefore resolves the limit to a `.deadline` timestamp
//!   ONCE, before the spawn, on the monotonic `awake` clock — every subsequent
//!   fill shares that one instant and total wall time cannot exceed it.
//!
//! - **A crash stays a crash.** A timeout is reported as its own `Outcome`
//!   variant and never as a term, so a program killed by SIGSEGV/SIGBUS/ABRT
//!   still arrives at the caller as `.finished` with a `.signal` term. Only
//!   the machine intervening produces `.timed_out`. Scoring a segfault as a
//!   timeout would send the reader hunting the wrong bug.
//!
//! ## The limit
//!
//! `default_timeout_s` is deliberately far above anything the corpus does.
//! Measured on this host (arm64-macOS, 18 logical CPUs, load average ~4, i.e.
//! already sharing the box with another agent) the slowest single subprocess in
//! either harness is `tests/stress/quicwire` under `BIT_GC=stress` at 38.3s;
//! the runner-up is `polloneshotdarwin` at 13.1s and everything else is under
//! 3s. 300s leaves the worst case a ~7.8x margin. A timeout that fires on a
//! merely-slow case is worse than no timeout at all — it manufactures a red
//! that costs someone a day — so the number is chosen against the slowest case
//! plus contention headroom, not against the average.
//!
//! Override with `BIT_TEST_TIMEOUT_S` when a host is slower still, or set it to
//! `0` to disable the deadline entirely and restore the old block-forever
//! behaviour (which is how the guard itself is mutation-tested).

const std = @import("std");

const Io = std.Io;

/// Wall-clock seconds allowed to any one spawned subprocess. See the header for
/// how this number was chosen.
pub const default_timeout_s: u32 = 300;

/// Environment variable that overrides `default_timeout_s`. `0` disables the
/// deadline.
pub const timeout_env_var = "BIT_TEST_TIMEOUT_S";

/// Ceiling on the override, so a typo (`BIT_TEST_TIMEOUT_S=30000000`) cannot
/// quietly reinstate an unbounded wait. One hour is far past any legitimate
/// case and still terminates.
pub const max_timeout_s: u32 = 3600;

/// What a spawned subprocess did. `.timed_out` is a distinct outcome rather
/// than a synthesised failure term precisely so callers cannot confuse it with
/// a signal the program raised on itself.
pub const Outcome = union(enum) {
    finished: std.process.RunResult,
    /// The deadline expired and the child was killed. Carries the limit that
    /// was exceeded so the report can name it.
    timed_out: u32,
};

/// Reads the per-subprocess limit, in seconds. `0` means "no deadline".
///
/// Errors on the environment are treated as "not set": this is a test-harness
/// knob, and failing the suite because the environment could not be enumerated
/// would be a worse failure than falling back to a working default.
pub fn timeoutSeconds(gpa: std.mem.Allocator) u32 {
    const raw = std.testing.environ.getAlloc(gpa, timeout_env_var) catch return default_timeout_s;
    defer gpa.free(raw);
    return parseTimeout(raw) orelse {
        // Only a non-empty value that failed to parse is worth a word; an unset
        // or blank variable is the normal case. Kept out of `parseTimeout` so
        // the unit test below can exercise the garbage input without printing
        // on a green build — an unconditional print makes Zig tag a passing
        // step `failed command:` (#1468).
        if (std.mem.trim(u8, raw, " \t\r\n").len > 0)
            std.debug.print("{s}='{s}' is not a number; using the {d}s default\n", .{ timeout_env_var, raw, default_timeout_s });
        return default_timeout_s;
    };
}

/// The override's whole interpretation, split out so it is testable without
/// mutating this process's environment. `null` means "unusable, fall back to
/// the default"; anything above `max_timeout_s` is clamped; `0` disables.
fn parseTimeout(raw: []const u8) ?u32 {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return null;
    const parsed = std.fmt.parseInt(u32, trimmed, 10) catch return null;
    return @min(parsed, max_timeout_s);
}

/// Spawns `options.argv` and collects its output, killing it and reporting
/// `.timed_out` if `timeout_s` wall-clock seconds pass first.
///
/// `options.timeout` is ignored and overwritten: the whole point is that the
/// bound is resolved to one absolute instant here rather than being restarted
/// per read.
pub fn run(
    gpa: std.mem.Allocator,
    io: Io,
    timeout_s: u32,
    options: std.process.RunOptions,
) !Outcome {
    var opts = options;
    opts.timeout = if (timeout_s == 0) .none else .{
        .deadline = .fromNow(io, .{ .raw = .fromSeconds(timeout_s), .clock = .awake }),
    };
    const result = std.process.run(gpa, io, opts) catch |e| switch (e) {
        error.Timeout => return .{ .timed_out = timeout_s },
        else => return e,
    };
    return .{ .finished = result };
}

/// Name of the signal that killed a child, e.g. `SEGV`.
///
/// `std.enums.tagName` rather than `@tagName`: `std.posix.SIG` is a
/// non-exhaustive enum, so `@tagName` of a value it does not name is illegal
/// behaviour — and the values worth reporting here (a runtime-specific or
/// platform-specific signal) are exactly the ones most likely to be unnamed.
pub fn signalName(sig: std.posix.SIG) []const u8 {
    if (@typeInfo(@TypeOf(sig)) != .@"enum") return "signal";
    return std.enums.tagName(@TypeOf(sig), sig) orelse "unnamed";
}

/// The one-line explanation printed when a child died of a signal it raised on
/// itself. SIGSEGV/SIGBUS/SIGABRT are RESULTS — the program's own verdict about
/// itself — and must never be scored as a timeout or as inconclusive.
pub fn crashNote(sig: std.posix.SIG) void {
    std.debug.print(
        "  killed by SIG{s} ({d}). This is a CRASH the program caused, not a timeout.\n",
        .{ signalName(sig), @intFromEnum(sig) },
    );
}

/// The one-line explanation printed when a case is killed by the deadline.
/// Callers add the case name and which compiler produced the binary.
pub fn timedOutNote(limit_s: u32, argv0: []const u8) void {
    std.debug.print(
        "  timed out after {d}s and was killed: '{s}' never terminated.\n" ++
            "  This is a HANG, not an output mismatch. Raise " ++ timeout_env_var ++
            " if the host is merely slow.\n",
        .{ limit_s, argv0 },
    );
}

/// Reports a COMPILER subprocess that did not exit 0, and says which kind of
/// "did not exit 0" it was.
///
/// A compile that fails by exiting non-zero has diagnostics to show. A compile
/// that dies by SIGNAL has nothing to show, because the tool never reached
/// `main` — and printing its two empty streams under a "compile failed:" header
/// produces the single most misleading line this harness can emit: an
/// all-cases red with no text, which reads exactly like "the self-hosted
/// compiler broke on every program in the corpus".
///
/// The instance that has actually happened here (#1644, reproduced) is SIGKILL
/// with both streams empty. macOS kills an exec immediately, before `main`,
/// with `EXC_CRASH / SIGKILL (Code Signature Invalid)` when the binary's file
/// is truncated and rewritten underneath it. `bit` is emitted by a
/// `has_side_effects` Run step, which Zig writes DIRECTLY to a deterministic
/// `.zig-cache/o/<digest>/bit` on every invocation with no temp-and-rename — so
/// a second concurrent `zig build` sharing that cache root truncates the very
/// file a live harness is exec'ing. `tests/selfbin.zig` removes the cause; this
/// note is the backstop for every other way a tool can be killed.
pub fn toolFailedNote(
    term: std.process.Child.Term,
    tool: []const u8,
    stdout: []const u8,
    stderr: []const u8,
) void {
    switch (term) {
        .exited => |code| std.debug.print("  exited {d}\n{s}{s}\n", .{ code, stdout, stderr }),
        .signal, .stopped => |sig| {
            std.debug.print(
                "  KILLED BY SIG{s} ({d}) — the tool did not run to completion.\n",
                .{ signalName(sig), @intFromEnum(sig) },
            );
            if (stdout.len == 0 and stderr.len == 0) std.debug.print(
                "  It produced NO output at all, so this is NOT a compile error and NOT\n" ++
                    "  evidence that '{s}' is broken. A signal death before any output means\n" ++
                    "  the process was killed from outside: on macOS the usual cause is the\n" ++
                    "  binary's file being rewritten while it was exec'd (run only ONE\n" ++
                    "  `zig build` at a time per cache root), or the box running out of memory.\n",
                .{tool},
            ) else std.debug.print("{s}{s}\n", .{ stdout, stderr });
        },
        .unknown => |raw| std.debug.print(
            "  terminated abnormally (raw status {d}); no output to report.\n{s}{s}\n",
            .{ raw, stdout, stderr },
        ),
    }
}

test "parseTimeout: unset, explicit, disable, clamp, garbage" {
    try std.testing.expectEqual(@as(?u32, null), parseTimeout(""));
    try std.testing.expectEqual(@as(?u32, null), parseTimeout("  \n"));
    try std.testing.expectEqual(@as(?u32, 45), parseTimeout("45"));
    try std.testing.expectEqual(@as(?u32, 45), parseTimeout(" 45\n"));
    try std.testing.expectEqual(@as(?u32, 0), parseTimeout("0")); // the disable escape hatch
    try std.testing.expectEqual(@as(?u32, max_timeout_s), parseTimeout("30000000")); // clamped, never unbounded
    try std.testing.expectEqual(@as(?u32, null), parseTimeout("soon"));
    try std.testing.expect(default_timeout_s > 0 and default_timeout_s <= max_timeout_s);
}
