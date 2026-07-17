//! Std-stream writer gate: no `Io.File.Writer`/`Io.File.Reader` over stdin,
//! stdout, or stderr may be built with `.init`.
//!
//! `.init` selects `.positional` mode, which p{read,write}s from the handle's
//! OWN offset — starting at 0 — instead of the fd's shared offset. That is
//! correct for a file the process opened and owns, and wrong for an inherited
//! std stream: two writers on one stderr (ours rendering diagnostics, then the
//! runtime printing `error: CheckFailed`) each begin at byte 0, so the second
//! silently overwrites the front of the first. It cost every rendered
//! diagnostic its first 19 bytes whenever stderr was a regular file.
//!
//! A tty and a pipe are not seekable, so positional mode falls back to
//! streaming and the corruption vanishes — which is exactly why this needs a
//! static gate rather than a behavioural test. It reproduces only under a
//! redirect to a real file: CI logs, `2>err.txt`, the self-host differentials.
//! `.initStreaming` is the correct constructor for a std stream.
//!
//! Sources are read at runtime, so the build cache cannot see an edit; the
//! runner is marked `has_side_effects` in build.zig so a reintroduced `.init`
//! can never be cache-skipped into a false pass.

const std = @import("std");
const build_options = @import("build_options");

const testing = std.testing;
const Io = std.Io;
const Dir = std.Io.Dir;

/// Bounds on the walk, keeping it provably finite (Power of 10).
const max_files = 512;
const max_file_bytes = 1 << 20;

/// The banned constructions. `.initStreaming(.stdout()` does not match any of
/// these — the needle includes `.init(` exactly.
const banned = [_][]const u8{
    ".init(.stdout()",
    ".init(.stderr()",
    ".init(.stdin()",
};

/// Scans every `.zig` file under `root`, counting occurrences of a banned
/// construction and reporting each one's file and line.
fn checkTree(gpa: std.mem.Allocator, io: Io, root: []const u8, seen: *u32, failures: *u32) !void {
    var dir = try Dir.openDirAbsolute(io, root, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".zig")) continue;
        // This gate spells the banned constructions out to search for them, so
        // scanning itself would report three permanent hits.
        if (std.mem.eql(u8, entry.basename, "stdstream_check.zig")) continue;
        if (seen.* >= max_files) return error.TooManyFiles;
        seen.* += 1;
        const source = try entry.dir.readFileAlloc(io, entry.basename, gpa, .limited(max_file_bytes));
        defer gpa.free(source);
        for (banned) |needle| {
            var line: u32 = 1;
            var i: usize = 0;
            while (i < source.len) : (i += 1) {
                if (source[i] == '\n') line += 1;
                if (!std.mem.startsWith(u8, source[i..], needle)) continue;
                failures.* += 1;
                std.debug.print(
                    "{s}/{s}:{d}: '{s}' builds a POSITIONAL handle on a std stream; use .initStreaming\n",
                    .{ root, entry.path, line, needle },
                );
            }
        }
    }
}

test "no positional handles on std streams" {
    const gpa = testing.allocator;
    const io = Io.Threaded.global_single_threaded.io();

    var seen: u32 = 0;
    var failures: u32 = 0;
    try checkTree(gpa, io, build_options.compiler_dir, &seen, &failures);
    try checkTree(gpa, io, build_options.tests_dir, &seen, &failures);
    try checkTree(gpa, io, build_options.runtime_dir, &seen, &failures);

    // A walk that found nothing would pass vacuously forever.
    try testing.expect(seen > 0);
    try testing.expectEqual(@as(u32, 0), failures);
}
