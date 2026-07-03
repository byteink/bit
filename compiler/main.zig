const std = @import("std");
const Io = std.Io;

const diagnostics = @import("diagnostics.zig");
const lexer = @import("lexer.zig");
const ast = @import("ast.zig");
const parser = @import("parser.zig");

/// Seed compiler version. Kept in sync with `build.zig.zon`.
pub const version = "0.0.0";

pub fn main(init: std.process.Init) !void {
    var buf: [64]u8 = undefined;
    var stdout: Io.File.Writer = .init(.stdout(), init.io, &buf);
    const out = &stdout.interface;
    try out.print("bitc {s}\n", .{version});
    try out.flush();
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
