//! Crash/hang capture for fuzz targets (task #334).
//!
//! `call` drives `bit.parseReport` over one input and guarantees that any
//! fault — segfault, illegal instruction, trap, abort, or a hang — leaves the
//! triggering input on disk under `tests/fuzz/crashes/` before the process
//! dies, so it becomes a permanent regression case (see `fuzz.zig`).
//!
//! Two independent guards, because the failure modes need different tools:
//!   * A hang can't raise a signal, so a watchdog thread polls a "done" flag
//!     and force-exits if the call doesn't finish within `hang_timeout_ms`.
//!   * A real crash can't run a `defer` or unwind, so `onFatalSignal` runs
//!     inside the signal handler itself. It touches no allocator (the crash
//!     may have happened while one was mid-mutation) and no `std.Io`/`std.fs`
//!     (both may allocate) — only raw libc syscalls (`std.c`, async-signal-
//!     safe by POSIX contract) and a static buffer populated before the
//!     guarded call. The module links libc for exactly these four calls.
//!
//! Single-threaded assumption: `crash_buf`/`crash_len` are written by the
//! calling thread only; the watchdog thread only reads them, after the
//! spawn's happens-before edge has published them. Zig's fuzz engine drives
//! one `testOne` at a time per process today (see upstream `lib/fuzzer.zig`),
//! so concurrent calls to `call` are not a case this needs to handle.

const std = @import("std");
const build_options = @import("build_options");
const bit = @import("bit");

const Io = std.Io;

/// Upper bound on `.bit` files scanned from one directory — keeps the walk
/// provably bounded (Power of 10). Raise if a corpus ever approaches it.
const max_dir_files = 4096;

/// Reads every `*.bit` file directly under `dir_path` (non-recursive, bounded
/// scan; missing directory yields an empty result). Caller owns the returned
/// slice and each of its entries.
pub fn readBitFiles(gpa: std.mem.Allocator, io: Io, dir_path: []const u8) ![]const []const u8 {
    var dir = Io.Dir.openDirAbsolute(io, dir_path, .{ .iterate = true }) catch |e| switch (e) {
        error.FileNotFound => return &.{},
        else => return e,
    };
    defer dir.close(io);

    var files: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (files.items) |f| gpa.free(f);
        files.deinit(gpa);
    }

    var it = dir.iterate();
    var scanned: u32 = 0;
    while (scanned < max_dir_files) : (scanned += 1) {
        const entry = (try it.next(io)) orelse break;
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".bit")) continue;

        const name = try gpa.dupe(u8, entry.name);
        defer gpa.free(name);

        const bytes = try dir.readFileAlloc(io, name, gpa, .limited(1 << 20));
        try files.append(gpa, bytes);
    }
    try std.testing.expect(scanned < max_dir_files); // corpus stayed within bound
    return files.toOwnedSlice(gpa);
}

pub fn freeBitFiles(gpa: std.mem.Allocator, files: []const []const u8) void {
    for (files) |f| gpa.free(f);
    gpa.free(files);
}

/// Bounds each iteration's cost and the static crash buffer (Power of 10: no
/// unbounded resource use). Inputs larger than this are skipped rather than
/// truncated, so the fuzzer's own feedback loop learns to stop growing them.
pub const max_input_len = 1 << 16;

const hang_timeout_ms = 1000;
const poll_interval_ms = 10;
const max_poll_iterations = hang_timeout_ms / poll_interval_ms;

var crash_buf: [max_input_len]u8 = undefined;
var crash_len: usize = 0;
var handlers_installed = false;

/// Runs `bit.parseReport` over `input` under the crash/hang guard.
pub fn call(gpa: std.mem.Allocator, input: []const u8) anyerror!void {
    if (input.len > max_input_len) return;

    if (!handlers_installed) {
        handlers_installed = true;
        installHandlers();
    }

    @memcpy(crash_buf[0..input.len], input);
    crash_len = input.len;

    var done: std.atomic.Value(bool) = .init(false);
    const watchdog = try std.Thread.spawn(.{}, watch, .{&done});
    defer {
        done.store(true, .release);
        watchdog.join();
    }

    const report = bit.parseReport(gpa, "fuzz.bit", input) catch |err| {
        saveCrash("err");
        return err;
    };
    gpa.free(report.text);
}

fn watch(done: *std.atomic.Value(bool)) void {
    const io = std.Io.Threaded.global_single_threaded.io();
    var polled: u32 = 0;
    while (polled < max_poll_iterations) : (polled += 1) {
        if (done.load(.acquire)) return;
        std.Io.sleep(io, .fromMilliseconds(poll_interval_ms), .awake) catch return;
    }
    if (done.load(.acquire)) return;
    saveCrash("hang");
    std.process.exit(1);
}

fn installHandlers() void {
    const act: std.posix.Sigaction = .{
        .handler = .{ .handler = onFatalSignal },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    for ([_]std.posix.SIG{ .SEGV, .ILL, .BUS, .FPE, .ABRT }) |sig|
        std.posix.sigaction(sig, &act, null);
}

/// Signal-handler context: no allocation, no `std.Io`/`std.fs`, only raw
/// libc calls (async-signal-safe by POSIX contract) and the pre-populated
/// static buffer.
fn onFatalSignal(_: std.posix.SIG) callconv(.c) void {
    saveCrash("crash");
    std.c._exit(1);
}

/// Persists `crash_buf[0..crash_len]` under `crashes_dir`, named by content
/// hash so identical failures dedupe to one regression file. Safe to call
/// from a signal handler: fixed-size stack buffers and raw libc calls only.
fn saveCrash(comptime prefix: []const u8) void {
    const input = crash_buf[0..crash_len];
    const hash = fnv1a64(input);

    var path_buf: [std.fs.max_path_bytes:0]u8 = undefined;
    const path = std.fmt.bufPrintZ(&path_buf, "{s}/" ++ prefix ++ "-{x:0>16}.bit", .{
        build_options.crashes_dir,
        hash,
    }) catch return;

    const flags: std.c.O = .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true };
    const fd = std.c.open(path.ptr, flags, @as(c_uint, 0o644));
    if (fd < 0) return;
    defer _ = std.c.close(fd);

    var written: usize = 0;
    while (written < input.len) {
        const n = std.c.write(fd, input.ptr + written, input.len - written);
        if (n <= 0) return;
        written += @intCast(n);
    }
}

fn fnv1a64(bytes: []const u8) u64 {
    var hash: u64 = 0xcbf29ce484222325;
    for (bytes) |b| {
        hash ^= b;
        hash *%= 0x100000001b3;
    }
    return hash;
}
