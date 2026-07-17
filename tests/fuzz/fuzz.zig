//! Fuzz target declaration for the lexer + parser (task #334).
//!
//! Invariant under test: `bit.parseReport` never crashes and never hangs on
//! arbitrary bytes — it always returns either an AST dump or diagnostics
//! (`guard.call` enforces this; see its doc comment for how).
//!
//! `zig build test` runs this file built plain (no `-ffuzz`), which per
//! `std.testing.fuzz`'s own contract just replays the seed corpus once — a
//! cheap sanity check. This is deliberately the *only* place `std.testing.fuzz`
//! is used: Zig's native `-ffuzz` + `zig build --fuzz` coverage-guided engine
//! segfaults inside its own runtime as of 0.16.0 whenever a fuzz test seeds a
//! non-empty corpus (upstream ziglang/zig#26040), so `zig build fuzz` runs the
//! bounded mutation driver in mutate.zig instead — see its header for the
//! full rationale and the upgrade path once upstream fixes this.
//!
//! This file holds exactly one `test`, since ziglang/zig#26040 also flagged
//! segfaults with more than one test in a fuzz-instrumented binary. The
//! saved-crash regression replay lives in `crash_regression.zig` instead.

const std = @import("std");
const build_options = @import("build_options");
const bit = @import("bit");
const guard = @import("guard.zig");

const Io = std.Io;

fn testOne(_: void, smith: *std.testing.Smith) anyerror!void {
    var buf: [guard.max_input_len]u8 = undefined;
    const len = smith.slice(&buf);
    try guard.call(std.testing.allocator, buf[0..len]);
}

test "fuzz lexer+parser" {
    const gpa = std.testing.allocator;
    const io = Io.Threaded.global_single_threaded.io();

    const seeds = try guard.readBitFiles(gpa, io, build_options.cases_dir);
    defer guard.freeBitFiles(gpa, seeds);

    try std.testing.fuzz({}, testOne, .{ .corpus = seeds });
}
