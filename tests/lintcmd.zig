//! `bit lint` CLI contract (#1380): exit codes, path walk, the summary line,
//! `--json`, `--stats`.
//!
//! This harness execs the SELF-HOSTED `bit` — lint is selfhost-only (LINT.md
//! §9), and none of what it asserts is reachable from inside the process that
//! would produce it: an exit code is observable only to a parent, and stdout
//! and stderr are only distinguishable from outside. `compiler/lintcheck.bit`
//! covers everything below that line (the directive reader, the rule, the
//! renderers) and runs under the same `zig build test`.
//!
//! Exit codes are a CI contract, so every one of the three is asserted here,
//! against a fixture that produces it for the documented reason.
//!
//! Exec's a private per-run copy of the compiler (`tests/selfbin.zig`, #1644)
//! rather than the build artifact directly — a second concurrent `zig build`
//! truncates that artifact in place and macOS kills a live exec of it with no
//! output, a false red indistinguishable from "the compiler is broken". Every
//! spawn carries the shared `tests/proc.zig` deadline (#1652/#1672): a hung
//! `bit lint` used to block `zig build test` forever with no case named.

const std = @import("std");
const build_options = @import("build_options");

const testing = std.testing;
const Io = std.Io;
const Dir = std.Io.Dir;

const proc = @import("proc.zig");
const selfbin = @import("selfbin.zig");

const Run = struct {
    code: u8,
    stdout: []u8,
    stderr: []u8,

    fn deinit(self: Run, gpa: std.mem.Allocator) void {
        gpa.free(self.stdout);
        gpa.free(self.stderr);
    }
};

/// Runs `bit lint <args...>` with `cwd` as the working directory. A signalled
/// exit is reported as 255 so it can never be mistaken for one of 0/1/2. A
/// timeout is never folded into that bucket: it is a distinct, named failure
/// (see `tests/proc.zig`'s header), so it returns an error instead of a `Run`.
fn runLint(
    gpa: std.mem.Allocator,
    io: Io,
    timeout_s: u32,
    bit_abs: []const u8,
    cwd: []const u8,
    args: []const []const u8,
) !Run {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.append(gpa, bit_abs);
    try argv.append(gpa, "lint");
    try argv.appendSlice(gpa, args);

    const outcome = try proc.run(gpa, io, timeout_s, .{
        .argv = argv.items,
        .cwd = .{ .path = cwd },
    });
    const result = switch (outcome) {
        .finished => |r| r,
        .timed_out => |limit| {
            std.debug.print("lintcmd: 'bit lint' TIMED OUT\n", .{});
            proc.timedOutNote(limit, bit_abs);
            return error.LintTimedOut;
        },
    };
    return .{
        .code = switch (result.term) {
            .exited => |c| c,
            else => 255,
        },
        .stdout = result.stdout,
        .stderr = result.stderr,
    };
}

/// A throwaway tree under /tmp. Returns its path; the caller deletes it.
fn makeFixture(gpa: std.mem.Allocator, io: Io) ![]u8 {
    const root = try std.fmt.allocPrint(gpa, "/tmp/bit-lintcmd-{x}", .{testing.random_seed});
    errdefer gpa.free(root);
    try Dir.cwd().createDirPath(io, root);

    var dir = try Dir.cwd().openDir(io, root, .{});
    defer dir.close(io);
    try dir.createDirPath(io, "sub");

    // 900 lines, no directive: one E0200 finding against the 800 default.
    var big: std.ArrayList(u8) = .empty;
    defer big.deinit(gpa);
    try big.appendSlice(gpa, "// a file over the default limit\n");
    for (0..899) |_| try big.appendSlice(gpa, "let x = 1\n");
    try dir.writeFile(io, .{ .sub_path = "big.bit", .data = big.items });

    // The same size, with the override that freezes it there: no finding, and
    // one override in the accounting.
    var raised: std.ArrayList(u8) = .empty;
    defer raised.deinit(gpa);
    try raised.appendSlice(gpa, "// bit:lint max-file-lines=900 -- pre-dates lint\n");
    for (0..899) |_| try raised.appendSlice(gpa, "let y = 2\n");
    try dir.writeFile(io, .{ .sub_path = "raised.bit", .data = raised.items });

    try dir.writeFile(io, .{ .sub_path = "sub/small.bit", .data = "let z = 3\n" });
    // Not a `.bit` file: the walk must not pick it up. It is 900 lines, so if
    // the extension filter ever breaks, this fixture fires rather than passing.
    var noise: std.ArrayList(u8) = .empty;
    defer noise.deinit(gpa);
    for (0..900) |_| try noise.appendSlice(gpa, "not bit\n");
    try dir.writeFile(io, .{ .sub_path = "readme.txt", .data = noise.items });

    return root;
}

test "bit lint: exit 1 on a finding, exit 0 once an override covers it" {
    if (build_options.selfhost_bit.len == 0) return; // cross build: no runnable `bit`

    const gpa = testing.allocator;
    var threaded = Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const bit_abs = try selfbin.privateCopy(gpa, io, build_options.selfhost_bit);
    defer selfbin.release(gpa, io, bit_abs);
    const timeout_s = proc.timeoutSeconds(gpa);

    const root = try makeFixture(gpa, io);
    defer gpa.free(root);
    defer Dir.cwd().deleteTree(io, root) catch {};

    // The whole tree: big.bit is over, raised.bit is covered by its override.
    {
        const r = try runLint(gpa, io, timeout_s, bit_abs, root, &.{"."});
        defer r.deinit(gpa);
        try testing.expectEqual(@as(u8, 1), r.code);
        try testing.expect(std.mem.indexOf(u8, r.stderr, "warning[E0200]") != null);
        try testing.expect(std.mem.indexOf(u8, r.stderr, "file is 900 lines, limit is 800") != null);
        // The hint must teach the form WITH the reason placeholder; without it,
        // the form it teaches would itself exit 2 on first use.
        try testing.expect(std.mem.indexOf(u8, r.stderr, "max-file-lines=900 -- <reason>") != null);
        // Exactly one finding: raised.bit is the same size and must not fire,
        // and readme.txt is not a .bit file and must not be walked at all.
        try testing.expect(std.mem.indexOf(u8, r.stderr, "lint: 1 findings, 1 overrides active") != null);
        try testing.expect(std.mem.indexOf(u8, r.stderr, "readme.txt") == null);
    }

    // A clean subtree still prints the summary, and exits 0.
    {
        const r = try runLint(gpa, io, timeout_s, bit_abs, root, &.{"sub"});
        defer r.deinit(gpa);
        try testing.expectEqual(@as(u8, 0), r.code);
        try testing.expect(std.mem.indexOf(u8, r.stderr, "lint: 0 findings, 0 overrides active") != null);
    }

    // No path argument means `.`, so it must agree with the explicit form.
    {
        const r = try runLint(gpa, io, timeout_s, bit_abs, root, &.{});
        defer r.deinit(gpa);
        try testing.expectEqual(@as(u8, 1), r.code);
        try testing.expect(std.mem.indexOf(u8, r.stderr, "lint: 1 findings, 1 overrides active") != null);
    }

    // A single file names exactly that file.
    {
        const r = try runLint(gpa, io, timeout_s, bit_abs, root, &.{"raised.bit"});
        defer r.deinit(gpa);
        try testing.expectEqual(@as(u8, 0), r.code);
        try testing.expect(std.mem.indexOf(u8, r.stderr, "lint: 0 findings, 1 overrides active") != null);
    }
}

test "bit lint: --json goes to stdout in the check --json shape" {
    if (build_options.selfhost_bit.len == 0) return;

    const gpa = testing.allocator;
    var threaded = Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const bit_abs = try selfbin.privateCopy(gpa, io, build_options.selfhost_bit);
    defer selfbin.release(gpa, io, bit_abs);
    const timeout_s = proc.timeoutSeconds(gpa);

    const root = try makeFixture(gpa, io);
    defer gpa.free(root);
    defer Dir.cwd().deleteTree(io, root) catch {};

    const r = try runLint(gpa, io, timeout_s, bit_abs, root, &.{ "--json", "." });
    defer r.deinit(gpa);
    try testing.expectEqual(@as(u8, 1), r.code);

    // Parses, and carries the keys `bit check --json` emits (diagnostics.zig
    // writeJson). Parsing it is the assertion that matters: a consumer that
    // cannot parse it is the whole failure mode.
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, std.mem.trim(u8, r.stdout, " \n"), .{});
    defer parsed.deinit();
    const arr = parsed.value.array;
    try testing.expectEqual(@as(usize, 1), arr.items.len);
    const d = arr.items[0].object;
    try testing.expectEqualStrings("E0200", d.get("code").?.string);
    try testing.expectEqualStrings("warning", d.get("severity").?.string);
    try testing.expectEqualStrings("./big.bit", d.get("file").?.string);
    try testing.expect(d.get("message") != null);
    try testing.expect(d.get("hint") != null);
    const start = d.get("range").?.object.get("start").?.object;
    try testing.expectEqual(@as(i64, 0), start.get("line").?.integer);
    try testing.expectEqual(@as(i64, 0), start.get("character").?.integer);

    // The summary stays on stderr so the JSON can be piped unfiltered.
    try testing.expect(std.mem.indexOf(u8, r.stdout, "lint:") == null);
    try testing.expect(std.mem.indexOf(u8, r.stderr, "lint: 1 findings") != null);
}

test "bit lint: --stats lists the overrides in force and reports no findings" {
    if (build_options.selfhost_bit.len == 0) return;

    const gpa = testing.allocator;
    var threaded = Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const bit_abs = try selfbin.privateCopy(gpa, io, build_options.selfhost_bit);
    defer selfbin.release(gpa, io, bit_abs);
    const timeout_s = proc.timeoutSeconds(gpa);

    const root = try makeFixture(gpa, io);
    defer gpa.free(root);
    defer Dir.cwd().deleteTree(io, root) catch {};

    const r = try runLint(gpa, io, timeout_s, bit_abs, root, &.{ "--stats", "." });
    defer r.deinit(gpa);
    // Findings are suppressed, so the run is clean even though big.bit is over.
    try testing.expectEqual(@as(u8, 0), r.code);
    try testing.expect(std.mem.indexOf(u8, r.stdout, "./raised.bit: max-file-lines=900") != null);
    try testing.expect(std.mem.indexOf(u8, r.stderr, "E0200") == null);
    // The count still covers every file walked, not only files with findings.
    try testing.expect(std.mem.indexOf(u8, r.stderr, "lint: 0 findings, 1 overrides active") != null);
}

test "bit lint: exit 2 on a usage error, an unreadable path, and a bad directive" {
    if (build_options.selfhost_bit.len == 0) return;

    const gpa = testing.allocator;
    var threaded = Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const bit_abs = try selfbin.privateCopy(gpa, io, build_options.selfhost_bit);
    defer selfbin.release(gpa, io, bit_abs);
    const timeout_s = proc.timeoutSeconds(gpa);

    const root = try makeFixture(gpa, io);
    defer gpa.free(root);
    defer Dir.cwd().deleteTree(io, root) catch {};

    // Usage error: an unknown flag is never taken for a path.
    {
        const r = try runLint(gpa, io, timeout_s, bit_abs, root, &.{ "--quiet", "." });
        defer r.deinit(gpa);
        try testing.expectEqual(@as(u8, 2), r.code);
        try testing.expect(std.mem.indexOf(u8, r.stderr, "unknown flag '--quiet'") != null);
    }

    // Unreadable path: named by the user and not read is a hole in the run.
    {
        const r = try runLint(gpa, io, timeout_s, bit_abs, root, &.{"no/such/path"});
        defer r.deinit(gpa);
        try testing.expectEqual(@as(u8, 2), r.code);
        try testing.expect(std.mem.indexOf(u8, r.stderr, "no such file or directory") != null);
    }

    var dir = try Dir.cwd().openDir(io, root, .{});
    defer dir.close(io);

    // Each of the four directive error classes (LINT.md §5.2), one at a time,
    // and each must take down the whole run — a directive that quietly does
    // nothing is how a lint rule dies.
    const cases = [_]struct { src: []const u8, code: []const u8, needle: []const u8 }{
        .{ .src = "// bit:lint max-file-lines 900 -- nope\n", .code = "E0299", .needle = "malformed lint directive" },
        .{ .src = "// bit:lint max-file-lines=900\n", .code = "E0299", .needle = "has no reason" },
        .{ .src = "// bit:lint max-file-lines=900 --   \n", .code = "E0299", .needle = "reason is empty" },
        .{ .src = "// bit:lint max-fyle-lines=900 -- typo\n", .code = "E0298", .needle = "unknown lint rule" },
    };
    for (cases) |c| {
        try dir.writeFile(io, .{ .sub_path = "bad.bit", .data = c.src });
        const r = try runLint(gpa, io, timeout_s, bit_abs, root, &.{"."});
        defer r.deinit(gpa);
        try testing.expectEqual(@as(u8, 2), r.code);
        try testing.expect(std.mem.indexOf(u8, r.stderr, c.code) != null);
        try testing.expect(std.mem.indexOf(u8, r.stderr, c.needle) != null);
        // Findings are reported INSTEAD of directive errors, never alongside:
        // a broken override set would produce a finding set nobody asked for.
        try testing.expect(std.mem.indexOf(u8, r.stderr, "E0200") == null);
    }
    try dir.deleteFile(io, "bad.bit");

    // And with every directive fixed, the same tree is back to exit 1.
    {
        const r = try runLint(gpa, io, timeout_s, bit_abs, root, &.{"."});
        defer r.deinit(gpa);
        try testing.expectEqual(@as(u8, 1), r.code);
    }
}
