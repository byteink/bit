//! Doc-tests: every ```bit block in `docs/` must typecheck (#351).
//!
//! Documentation that does not compile is worse than no documentation, because
//! a reader trusts it. Each fenced `bit` block is written to a scratch module
//! and run through the real front end against the real prelude and `std/*`.
//!
//! Checked, not built: a snippet is a *module*, not a program, so it has no
//! `main` to link. That is exactly what lets a doc show one function in
//! isolation.
//!
//! **A page's blocks are one module by default.** They are concatenated in
//! order, then checked once — because that is how a reference page reads:
//! `interfaces.md` declares `interface Shape` in one block and implements it
//! three blocks later. It also means such a page cannot declare a name twice.
//!
//! A page whose blocks are *separate programs* — a tutorial, where each snippet
//! is a whole `main` you could run — says so with `<!-- doctest: per-block -->`
//! near the top, and each of its blocks is then checked on its own.
//!
//! A block that cannot join that module — a signature naming types it does not
//! define, a statement outside any function, a sketch that deliberately does not
//! compile — is fenced ```` ```bit ignore ````. It still highlights as Bit (the
//! first word of the info string is the language), it just is not checked. Reach
//! for `ignore` only when the snippet genuinely cannot be made real; the whole
//! point of this harness is that documentation which claims to be Bit *is* Bit.

const std = @import("std");
const bit = @import("bit");
const build_options = @import("build_options");

const testing = std.testing;
const Io = std.Io;
const Dir = std.Io.Dir;

/// Bounds on the walk, so the traversal is provably finite (Power of 10).
const max_files = 256;
const max_blocks_per_file = 128;
const max_file_bytes = 1 << 20;

const fence_tag = "```bit";
const fence_close = "```";

/// A page carrying this marker has its blocks checked one at a time, rather
/// than joined into a single module.
const per_block_marker = "<!-- doctest: per-block -->";

/// The checkable `bit` code blocks in `md` — those fenced ```` ```bit ```` and
/// not marked `ignore`. Each returned slice borrows from `md`.
fn extractBlocks(gpa: std.mem.Allocator, md: []const u8) ![][]const u8 {
    var blocks: std.ArrayList([]const u8) = .empty;
    errdefer blocks.deinit(gpa);

    var rest = md;
    while (blocks.items.len < max_blocks_per_file) {
        const tag_rel = std.mem.indexOf(u8, rest, fence_tag) orelse break;
        const at_line_start = tag_rel == 0 or rest[tag_rel - 1] == '\n';
        const after_tag = rest[tag_rel + fence_tag.len ..];

        // The rest of the fence line is the info string's remaining words.
        const nl = std.mem.indexOfScalar(u8, after_tag, '\n') orelse break;
        const info = std.mem.trim(u8, after_tag[0..nl], " \t\r");
        const body = after_tag[nl + 1 ..];

        // Checkable iff the info string is exactly ```` ```bit ````. `ignore`
        // marks a Bit block that is not checked; anything else (e.g. a
        // hypothetical ```` ```bitrot ````) is not a Bit fence at all.
        const checkable = at_line_start and info.len == 0;

        const close_rel = std.mem.indexOf(u8, body, "\n" ++ fence_close) orelse break;
        if (checkable) try blocks.append(gpa, body[0..close_rel]);
        rest = body[close_rel..];
    }
    return blocks.toOwnedSlice(gpa);
}

/// Typechecks `source` as a module in `scratch_dir`. Returns the rendered
/// diagnostics on failure, else null.
fn checkSource(gpa: std.mem.Allocator, io: Io, scratch_dir: []const u8, source: []const u8) !?[]u8 {
    const main_path = try std.fs.path.join(gpa, &.{ scratch_dir, "main.bit" });
    defer gpa.free(main_path);
    try Dir.cwd().writeFile(io, .{ .sub_path = main_path, .data = source });

    var report: Io.Writer.Allocating = .init(gpa);
    errdefer report.deinit();
    // `null`: the snippet is written into a scratch directory of its own, so the
    // root module is that whole directory (not a lone file, SPEC §17.1).
    const failed = try bit.checkHostProject(gpa, io, scratch_dir, null, build_options.stdlib_dir, &report.writer);
    if (!failed) {
        report.deinit();
        return null;
    }
    return try report.toOwnedSlice();
}

/// A page's blocks, joined into one module in document order.
fn joinBlocks(gpa: std.mem.Allocator, blocks: []const []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (blocks) |b| {
        try out.appendSlice(gpa, b);
        try out.appendSlice(gpa, "\n\n");
    }
    return out.toOwnedSlice(gpa);
}

test "every ```bit block in docs/ typechecks" {
    const gpa = testing.allocator;
    const io = Io.Threaded.global_single_threaded.io();

    const scratch = try std.fmt.allocPrint(gpa, "/tmp/bit-doctest-{x}", .{testing.random_seed});
    defer gpa.free(scratch);
    Dir.cwd().deleteTree(io, scratch) catch {};
    try Dir.cwd().createDirPath(io, scratch);
    defer Dir.cwd().deleteTree(io, scratch) catch {};

    var dir = try Dir.openDirAbsolute(io, build_options.docs_dir, .{ .iterate = true });
    defer dir.close(io);

    var walker = try dir.walk(gpa);
    defer walker.deinit();

    var files: u32 = 0;
    var checked: u32 = 0;
    var failures: u32 = 0;
    while (files < max_files) : (files += 1) {
        const entry = (try walker.next(io)) orelse break;
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".md")) continue;

        const md = try entry.dir.readFileAlloc(io, entry.basename, gpa, .limited(max_file_bytes));
        defer gpa.free(md);

        const blocks = try extractBlocks(gpa, md);
        defer gpa.free(blocks);
        if (blocks.len == 0) continue;
        checked += @intCast(blocks.len);

        if (std.mem.indexOf(u8, md, per_block_marker) != null) {
            for (blocks, 0..) |snippet, i| {
                if (try checkSource(gpa, io, scratch, snippet)) |report| {
                    defer gpa.free(report);
                    failures += 1;
                    std.debug.print("\ndocs: {s} block #{d} does not typecheck:\n{s}\n--- snippet ---\n{s}\n", .{ entry.path, i + 1, report, snippet });
                }
            }
            continue;
        }

        const module = try joinBlocks(gpa, blocks);
        defer gpa.free(module);
        if (try checkSource(gpa, io, scratch, module)) |report| {
            defer gpa.free(report);
            failures += 1;
            std.debug.print("\ndocs: {s} ({d} blocks, joined) does not typecheck:\n{s}\n--- joined module ---\n{s}\n", .{ entry.path, blocks.len, report, module });
        }
    }
    try testing.expect(files < max_files);
    try testing.expect(checked > 0); // the harness must actually find blocks
    try testing.expectEqual(@as(u32, 0), failures);
}

test "extractBlocks takes ```bit, skips ```bit ignore and other fences" {
    const gpa = testing.allocator;
    const md =
        \\intro
        \\```bit
        \\let a = 1
        \\```
        \\prose
        \\```
        \\not bit
        \\```
        \\```bit ignore
        \\this need not compile
        \\```
        \\```bit
        \\let b = 2
        \\```
    ;
    const blocks = try extractBlocks(gpa, md);
    defer gpa.free(blocks);
    try testing.expectEqual(@as(usize, 2), blocks.len);
    try testing.expectEqualStrings("let a = 1", blocks[0]);
    try testing.expectEqualStrings("let b = 2", blocks[1]);
}
