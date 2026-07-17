//! Format gate (#1266): every committed `.bit` source under `stdlib/` and
//! `examples/` must already be in `bit fmt`'s one canonical form. A drifted
//! source fails the build, the same way `zig fmt --check` guards the compiler.
//!
//! `tests/cases/` is excluded on purpose: its `// fmt` cases are deliberately
//! *un*formatted input to the formatter, and its `// error` cases include
//! sources that do not parse — gating either would be self-contradictory.
//!
//! Sources are read at runtime, so the build cache cannot see an edit; the
//! runner is marked `has_side_effects` in build.zig so a drifted file can never
//! be cache-skipped into a false pass.

const std = @import("std");
const bit = @import("bit");
const build_options = @import("build_options");

const testing = std.testing;
const Io = std.Io;
const Dir = std.Io.Dir;

/// Bounds on the walk, keeping it provably finite (Power of 10).
const max_files = 512;
const max_file_bytes = 1 << 20;

/// Formats every `.bit` file under `root` and counts the ones that are not
/// already canonical (or do not parse). `seen`/`failures` accumulate across
/// both trees so the caller can assert the walk found sources and none drifted.
fn checkTree(gpa: std.mem.Allocator, io: Io, root: []const u8, seen: *u32, failures: *u32) !void {
    var dir = try Dir.openDirAbsolute(io, root, .{ .iterate = true });
    defer dir.close(io);

    var walker = try dir.walk(gpa);
    defer walker.deinit();

    var files: u32 = 0;
    while (files < max_files) : (files += 1) {
        const entry = (try walker.next(io)) orelse break;
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".bit")) continue;

        const src = try entry.dir.readFileAlloc(io, entry.basename, gpa, .limited(max_file_bytes));
        defer gpa.free(src);

        const res = try bit.fmt.format(gpa, entry.path, src);
        defer gpa.free(res.text);
        seen.* += 1;

        if (res.failed) {
            failures.* += 1;
            std.debug.print("\nfmt_check: {s} does not parse:\n{s}\n", .{ entry.path, res.text });
            continue;
        }
        if (!std.mem.eql(u8, res.text, src)) {
            failures.* += 1;
            std.debug.print("\nfmt_check: {s} is not canonically formatted — run `bit fmt {s}`\n", .{ entry.path, entry.path });
        }
    }
    try testing.expect(files < max_files); // guard: the tree must not overflow the bound
}

test "every stdlib/ and examples/ source is canonically formatted" {
    const gpa = testing.allocator;
    const io = Io.Threaded.global_single_threaded.io();

    var seen: u32 = 0;
    var failures: u32 = 0;
    try checkTree(gpa, io, build_options.stdlib_dir, &seen, &failures);
    try checkTree(gpa, io, build_options.examples_dir, &seen, &failures);

    try testing.expect(seen > 0); // the walk must actually find sources
    try testing.expectEqual(@as(u32, 0), failures);
}
