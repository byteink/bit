//! Replays every crash saved under tests/fuzz/crashes/ (task #334).
//!
//! Split out of fuzz.zig and kept permanently plain (never built with
//! `-ffuzz`): Zig's native fuzzer segfaults when a fuzz-instrumented binary
//! contains more than one `test` declaration (upstream ziglang/zig#26040),
//! and this isn't a fuzz test itself — it's a fixed, deterministic corpus
//! replay, so `zig build test` is exactly where it belongs.

const std = @import("std");
const build_options = @import("build_options");
const guard = @import("guard.zig");

const Io = std.Io;

test "crash regression corpus" {
    const gpa = std.testing.allocator;
    const io = Io.Threaded.global_single_threaded.io();

    const crashes = try guard.readBitFiles(gpa, io, build_options.crashes_dir);
    defer guard.freeBitFiles(gpa, crashes);

    for (crashes) |input| try guard.call(gpa, input);
}
