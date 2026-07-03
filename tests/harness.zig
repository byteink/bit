//! Golden-file test harness (task #323).
//!
//! Discovers `tests/cases/*.bit` and checks each against its sibling
//! `<name>.expected`. The directive on line 1 selects the mode:
//!
//!   `// error` — compilation must fail; the rendered diagnostics (human format,
//!                ANSI off) must byte-match `.expected`.
//!   `// run`   — compile + execute, compare stdout to `.expected`. Skipped for
//!                now: the backend does not exist yet, so run-mode cases land as
//!                documentation and start executing when codegen arrives.
//!
//! A mismatch fails the build with a readable diff (via `expectEqualStrings`).

const std = @import("std");
const bitc = @import("bitc");
const build_options = @import("build_options");

const testing = std.testing;
const Io = std.Io;
const Dir = std.Io.Dir;

/// Upper bound on cases scanned per run — keeps the directory walk provably
/// bounded (Power of 10). Raise if the corpus ever approaches it.
const max_cases = 4096;

/// Upper bound on any single case/expected file.
const max_file_bytes = 1 << 20; // 1 MiB

const Directive = enum { run, err };
const Outcome = enum { checked, skipped };

test "golden cases" {
    const gpa = testing.allocator;
    const io = Io.Threaded.global_single_threaded.io();

    var dir = Dir.openDirAbsolute(io, build_options.cases_dir, .{ .iterate = true }) catch |e| {
        std.debug.print("cannot open cases dir '{s}': {s}\n", .{ build_options.cases_dir, @errorName(e) });
        return e;
    };
    defer dir.close(io);

    var it = dir.iterate();
    var scanned: u32 = 0;
    while (scanned < max_cases) : (scanned += 1) {
        const entry = (try it.next(io)) orelse break;
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".bit")) continue;

        // `entry.name` is invalidated by the next iterator step; copy it.
        const name = try gpa.dupe(u8, entry.name);
        defer gpa.free(name);

        _ = try checkCase(gpa, io, dir, name);
    }
    try testing.expect(scanned < max_cases); // corpus stayed within bound
}

fn checkCase(gpa: std.mem.Allocator, io: Io, dir: Dir, name: []const u8) !Outcome {
    const source = try dir.readFileAlloc(io, name, gpa, .limited(max_file_bytes));
    defer gpa.free(source);

    const directive = directiveOf(source) orelse {
        std.debug.print("case '{s}': line 1 must be '// run' or '// error'\n", .{name});
        return error.MissingDirective;
    };
    if (directive == .run) return .skipped;

    const report = try bitc.compileReport(gpa, name, source);
    defer gpa.free(report.text);

    if (!report.failed) {
        std.debug.print("case '{s}': expected compilation to fail, but no errors were produced\n", .{name});
        return error.ExpectedCompileError;
    }

    const expected_name = try std.fmt.allocPrint(gpa, "{s}.expected", .{name[0 .. name.len - ".bit".len]});
    defer gpa.free(expected_name);

    const expected = dir.readFileAlloc(io, expected_name, gpa, .limited(max_file_bytes)) catch |e| {
        std.debug.print("case '{s}': cannot read '{s}': {s}\n", .{ name, expected_name, @errorName(e) });
        return e;
    };
    defer gpa.free(expected);

    if (!std.mem.eql(u8, expected, report.text))
        std.debug.print("case '{s}' diagnostics mismatch:\n", .{name});
    try testing.expectEqualStrings(expected, report.text);
    return .checked;
}

/// Reads the line-1 directive. Matches the first line's leading token, ignoring a
/// trailing `\r` and any text after the keyword, so `// error: foo` still parses.
fn directiveOf(source: []const u8) ?Directive {
    const nl = std.mem.indexOfScalar(u8, source, '\n') orelse source.len;
    var line = source[0..nl];
    if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
    line = std.mem.trim(u8, line, " \t");
    if (std.mem.startsWith(u8, line, "// error")) return .err;
    if (std.mem.startsWith(u8, line, "// run")) return .run;
    return null;
}

test "directiveOf parses line-1 modes" {
    try testing.expectEqual(Directive.err, directiveOf("// error\nlet x = @\n").?);
    try testing.expectEqual(Directive.run, directiveOf("// run\r\nmain()\n").?);
    try testing.expectEqual(Directive.err, directiveOf("// error: stray byte").?);
    try testing.expectEqual(@as(?Directive, null), directiveOf("let x = 1\n"));
}
