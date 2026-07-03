const std = @import("std");
const Io = std.Io;

const diagnostics = @import("diagnostics.zig");
const lexer = @import("lexer.zig");
const ast = @import("ast.zig");
const parser = @import("parser.zig");
const fmt = @import("fmt.zig");

/// Seed compiler version. Kept in sync with `build.zig.zon`.
pub const version = "0.0.0";

/// Upper bound on a single source file `bitc fmt` will read. Matches the
/// golden harness's own cap (tests/harness.zig max_file_bytes).
const max_fmt_file_bytes = 1 << 20; // 1 MiB

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const argv = try init.minimal.args.toSlice(init.arena.allocator());

    if (argv.len >= 2 and std.mem.eql(u8, argv[1], "fmt")) {
        var err_buf: [4096]u8 = undefined;
        var stderr_w: Io.File.Writer = .init(.stderr(), io, &err_buf);
        const failed = try runFmt(gpa, io, &stderr_w.interface, argv[2..]);
        try stderr_w.interface.flush();
        if (failed) return error.FormatFailed;
        return;
    }

    var buf: [64]u8 = undefined;
    var stdout: Io.File.Writer = .init(.stdout(), io, &buf);
    const out = &stdout.interface;
    try out.print("bitc {s}\n", .{version});
    try out.flush();
}

/// `bitc fmt <path>...`: reformats each file to Bit's one canonical style,
/// rewriting it in place only when the canonical text differs (idempotent:
/// an already-canonical file is never touched). A file that fails to parse
/// is left untouched and its diagnostics are rendered to `err_out`; returns
/// `true` iff any file failed, so the caller can pick a nonzero exit code —
/// every remaining path is still attempted, matching gofmt's per-file
/// independence.
fn runFmt(gpa: std.mem.Allocator, io: Io, err_out: *Io.Writer, paths: []const [:0]const u8) !bool {
    var any_failed = false;
    for (paths) |path| {
        const source = Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(max_fmt_file_bytes)) catch |e| {
            try err_out.print("bitc fmt: {s}: {s}\n", .{ path, @errorName(e) });
            any_failed = true;
            continue;
        };
        defer gpa.free(source);

        const result = try fmt.format(gpa, path, source);
        defer gpa.free(result.text);

        if (result.failed) {
            try err_out.writeAll(result.text);
            any_failed = true;
            continue;
        }
        if (std.mem.eql(u8, source, result.text)) continue;
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = result.text });
    }
    return any_failed;
}

/// Outcome of driving the front-end over a single source buffer.
pub const CompileReport = struct {
    /// Rendered diagnostics, human format, ANSI disabled (deterministic).
    /// Owned by the `gpa` passed to `compileReport`.
    text: []u8,
    /// True when any error-severity diagnostic was produced.
    failed: bool,
};

/// Drives every front-end stage that currently exists (lexer, parser) over
/// `source` and renders the resulting diagnostics. `path` labels the source in
/// diagnostics. The returned `text` is owned by `gpa`; `failed` reports whether
/// compilation would fail (any error-severity diagnostic).
///
/// ponytail: the checker pass appends here once it lands; the golden test
/// harness needs no change when it does.
pub fn compileReport(gpa: std.mem.Allocator, path: []const u8, source: []const u8) !CompileReport {
    var sm = diagnostics.SourceManager.init(gpa);
    defer sm.deinit();
    const file = try sm.addFile(path, source);

    var diags = diagnostics.Diagnostics.init(gpa, &sm);
    defer diags.deinit();

    var tree = try ast.Tree.init(gpa);
    defer tree.deinit();
    try parser.parse(gpa, &tree, &diags, file, source);

    var rendered: Io.Writer.Allocating = .init(gpa);
    defer rendered.deinit();
    try diags.renderAll(&rendered.writer);

    return .{ .text = try gpa.dupe(u8, rendered.written()), .failed = diags.hasErrors() };
}

/// Outcome of parsing a single source buffer for AST-dump golden tests.
pub const ParseReport = struct {
    /// The AST s-expression dump on success, or the rendered diagnostics on
    /// failure. Owned by the `gpa` passed to `parseReport`.
    text: []u8,
    failed: bool,
};

/// Parses `source` and returns either its AST dump (§9-§18 grammar) or, if
/// parsing produced any diagnostic, the rendered diagnostics instead.
pub fn parseReport(gpa: std.mem.Allocator, path: []const u8, source: []const u8) !ParseReport {
    var sm = diagnostics.SourceManager.init(gpa);
    defer sm.deinit();
    const file = try sm.addFile(path, source);

    var diags = diagnostics.Diagnostics.init(gpa, &sm);
    defer diags.deinit();

    var tree = try ast.Tree.init(gpa);
    defer tree.deinit();
    try parser.parse(gpa, &tree, &diags, file, source);

    if (diags.hasErrors()) {
        var rendered: Io.Writer.Allocating = .init(gpa);
        defer rendered.deinit();
        try diags.renderAll(&rendered.writer);
        return .{ .text = try gpa.dupe(u8, rendered.written()), .failed = true };
    }
    return .{ .text = try ast.dump(gpa, &tree, source), .failed = false };
}

/// Outcome of formatting a single source buffer for golden fmt tests.
pub const FormatReport = fmt.FormatResult;

/// Formats `source` to Bit's one canonical style (see fmt.zig). Thin
/// forwarder kept alongside `compileReport`/`parseReport` so the golden-test
/// harness only ever depends on this module's public surface.
pub fn formatReport(gpa: std.mem.Allocator, path: []const u8, source: []const u8) !FormatReport {
    return fmt.format(gpa, path, source);
}

/// Number of line/block comments in `source`, per fmt's own comment
/// re-derivation. Used by the golden-test harness to assert fmt drops none.
pub fn commentCount(gpa: std.mem.Allocator, source: []const u8) !usize {
    const comments = try fmt.collectComments(gpa, source);
    defer gpa.free(comments);
    return comments.len;
}

test "version string is non-empty" {
    try std.testing.expect(version.len > 0);
}

test "compileReport flags an error and renders its diagnostic" {
    const gpa = std.testing.allocator;
    const report = try compileReport(gpa, "t.bit", "let x = @\n");
    defer gpa.free(report.text);
    try std.testing.expect(report.failed);
    try std.testing.expectEqualStrings(
        "error[E0001]: unexpected character '@'\n" ++
            " --> t.bit:1:9\n" ++
            "  |\n" ++
            "1 | let x = @\n" ++
            "  |         ^ remove this character\n",
        report.text,
    );
}

test "compileReport reports success on clean source" {
    const gpa = std.testing.allocator;
    const report = try compileReport(gpa, "ok.bit", "let x = 1\n");
    defer gpa.free(report.text);
    try std.testing.expect(!report.failed);
    try std.testing.expectEqualStrings("", report.text);
}
