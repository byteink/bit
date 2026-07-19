//! A `zig test` runner that lists the tests a root collects instead of running
//! them. Used only by `tests/testroots.zig`, the orphaned-test-file gate.
//!
//! This exists because test collection cannot be derived from the import graph.
//! It is *partial*: `seed/check.zig`'s tests are collected under the
//! `seed/main.zig` root, `seed/ir.zig`'s under `seed/emit.zig`'s, and
//! `runtime/{net,rand,gc}.zig`'s under `runtime/root.zig`'s — while
//! `seed/lower.zig` and `seed/lsp.zig` were collected by no root at all and so
//! never executed (#1453), exactly as `seed/link/macho.zig` had not (#1445).
//! Reading imports would have called all of those covered. The only way to know
//! is to ask the compiler which tests a given root actually produced, which is
//! what `builtin.test_functions` is — the same list the real runner executes.
//!
//! Prints one fully-qualified test name per line to stdout, runs nothing, and
//! always exits 0. Names are `<namespace>.test.<title>`, where `<namespace>` is
//! the file's path relative to the module root with `/` replaced by `.` and the
//! `.zig` suffix dropped (`seed/link/object.zig` under a `seed/`-rooted module
//! is `link.object`). The gate reconstructs that mapping to decide coverage.
const std = @import("std");
const builtin = @import("builtin");

pub fn main() !void {
    var buf: [4096]u8 = undefined;
    var stdout: std.Io.File.Writer = .initStreaming(
        .stdout(),
        std.Io.Threaded.global_single_threaded.io(),
        &buf,
    );
    for (builtin.test_functions) |t| try stdout.interface.print("{s}\n", .{t.name});
    try stdout.interface.flush();
}
