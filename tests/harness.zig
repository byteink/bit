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
//!   `// panic` — compile + execute; the program must panic: exit code 2 and
//!                stderr byte-matching `.expected` (SPEC.md §18.4). This is the
//!                only mode that can observe a panic *message*, so it is how the
//!                runtime's failure paths — failed `assert`, index out of range,
//!                divide by zero — are held to the text they promise.
//!   `// fmt`   — `bitc fmt` canonicalization must byte-match `.expected`
//!                (task #333's golden pairs: messy input -> canonical output).
//!   `// types` — compilation must succeed; `bitc check --dump-types`'
//!                inferred-type dump must byte-match `.expected` (task #335's
//!                positive suite: nested lambdas, generic calls).
//!
//! A mismatch fails the build with a readable diff (via `expectEqualStrings`).
//!
//! Every `run`/`fmt`/`types` case (i.e. every case that is valid Bit source,
//! per its own directive) also feeds a corpus-wide property check: fmt must
//! be idempotent and must never drop a comment (see "fmt corpus properties"
//! below) — `// error` cases are deliberately malformed and out of scope.

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

const Directive = enum { run, panic, err, fmt, types };
const Outcome = enum { checked, skipped };

/// Exit code the runtime uses for every panic (`runtime/root.zig`'s `fatal`,
/// SPEC.md §18.4). Matching it exactly — rather than merely "non-zero" — keeps
/// a crash (signal, 255) from passing as a panic.
const panic_exit_code: u8 = 2;

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
        std.debug.print("case '{s}': line 1 must be '// run', '// error', '// fmt', or '// types'\n", .{name});
        return error.MissingDirective;
    };

    const expected_name = try std.fmt.allocPrint(gpa, "{s}.expected", .{name[0 .. name.len - ".bit".len]});
    defer gpa.free(expected_name);

    const expected = dir.readFileAlloc(io, expected_name, gpa, .limited(max_file_bytes)) catch |e| {
        std.debug.print("case '{s}': cannot read '{s}': {s}\n", .{ name, expected_name, @errorName(e) });
        return e;
    };
    defer gpa.free(expected);

    switch (directive) {
        .run, .panic => {
            // Skip when the host is not a supported runtime target (no archive
            // to link against — build.zig leaves `libbitrt_path` empty then).
            if (build_options.libbitrt_path.len == 0) return .skipped;

            // A dedicated `Io.Threaded` over `gpa` (not the shared global io):
            // `std.process.run`'s spawn arena is backed by the io's allocator,
            // and mixing the global io's allocator with the per-test
            // `testing.allocator` trips its leak detector. This mirrors the e2e
            // test in main.zig.
            var run_threaded = Io.Threaded.init(gpa, .{});
            defer run_threaded.deinit();
            const run_io = run_threaded.io();

            const libbitrt = Dir.cwd().readFileAlloc(run_io, build_options.libbitrt_path, gpa, .limited(16 << 20)) catch |e| {
                std.debug.print("case '{s}': cannot read libbitrt '{s}': {s}\n", .{ name, build_options.libbitrt_path, @errorName(e) });
                return e;
            };
            defer gpa.free(libbitrt);

            var discard: Io.Writer.Allocating = .init(gpa);
            defer discard.deinit();
            const exe = (try bitc.buildHostExecutable(gpa, name, source, libbitrt, &discard.writer)) orelse {
                std.debug.print("case '{s}': expected compile to succeed, got diagnostics:\n{s}\n", .{ name, discard.written() });
                return error.RunCompileFailed;
            };
            defer gpa.free(exe);

            const stem = name[0 .. name.len - ".bit".len];
            const bin_path = try std.fmt.allocPrintSentinel(gpa, "/tmp/bit-golden-{s}", .{stem}, 0);
            defer gpa.free(bin_path);
            try Dir.cwd().writeFile(run_io, .{
                .sub_path = bin_path,
                .data = exe,
                .flags = .{ .permissions = .executable_file },
            });
            defer Dir.cwd().deleteFile(run_io, bin_path) catch {};

            const result = try std.process.run(gpa, run_io, .{ .argv = &.{bin_path} });
            defer gpa.free(result.stdout);
            defer gpa.free(result.stderr);
            const code: u8 = switch (result.term) {
                .exited => |c| c,
                else => 255,
            };
            if (directive == .panic) {
                if (code != panic_exit_code) {
                    std.debug.print("case '{s}': expected a panic (exit {d}), got exit {d}\nstderr: {s}\n", .{ name, panic_exit_code, code, result.stderr });
                    return error.ExpectedPanic;
                }
                if (!std.mem.eql(u8, expected, result.stderr))
                    std.debug.print("case '{s}' stderr mismatch:\n", .{name});
                try testing.expectEqualStrings(expected, result.stderr);
                return .checked;
            }
            if (code != 0) {
                std.debug.print("case '{s}': binary exited with {d}\nstderr: {s}\n", .{ name, code, result.stderr });
                return error.RunFailed;
            }
            if (!std.mem.eql(u8, expected, result.stdout))
                std.debug.print("case '{s}' stdout mismatch:\n", .{name});
            try testing.expectEqualStrings(expected, result.stdout);
        },
        .err => {
            const report = try bitc.compileReport(gpa, name, source);
            defer gpa.free(report.text);
            if (!report.failed) {
                std.debug.print("case '{s}': expected compilation to fail, but no errors were produced\n", .{name});
                return error.ExpectedCompileError;
            }
            if (!std.mem.eql(u8, expected, report.text))
                std.debug.print("case '{s}' diagnostics mismatch:\n", .{name});
            try testing.expectEqualStrings(expected, report.text);
        },
        .fmt => {
            const report = try bitc.formatReport(gpa, name, source);
            defer gpa.free(report.text);
            if (report.failed) {
                std.debug.print("case '{s}': expected fmt to succeed, got diagnostics:\n{s}\n", .{ name, report.text });
                return error.FmtParseFailed;
            }
            if (!std.mem.eql(u8, expected, report.text))
                std.debug.print("case '{s}' fmt mismatch:\n", .{name});
            try testing.expectEqualStrings(expected, report.text);
        },
        .types => {
            const report = try bitc.typesReport(gpa, name, source);
            defer gpa.free(report.text);
            if (report.failed) {
                std.debug.print("case '{s}': expected type-check to succeed, got diagnostics:\n{s}\n", .{ name, report.text });
                return error.TypeCheckFailed;
            }
            if (!std.mem.eql(u8, expected, report.text))
                std.debug.print("case '{s}' type-dump mismatch:\n", .{name});
            try testing.expectEqualStrings(expected, report.text);
        },
    }
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
    // Before `// run`: `startsWith` would never reach a `// panic` case, but an
    // ordering bug here would silently downgrade it to a stdout comparison.
    if (std.mem.startsWith(u8, line, "// panic")) return .panic;
    if (std.mem.startsWith(u8, line, "// run")) return .run;
    if (std.mem.startsWith(u8, line, "// fmt")) return .fmt;
    if (std.mem.startsWith(u8, line, "// types")) return .types;
    return null;
}

test "directiveOf parses line-1 modes" {
    try testing.expectEqual(Directive.err, directiveOf("// error\nlet x = @\n").?);
    try testing.expectEqual(Directive.run, directiveOf("// run\r\nmain()\n").?);
    try testing.expectEqual(Directive.panic, directiveOf("// panic\nmain()\n").?);
    try testing.expectEqual(Directive.fmt, directiveOf("// fmt\nlet x=1\n").?);
    try testing.expectEqual(Directive.types, directiveOf("// types\nlet x=1\n").?);
    try testing.expectEqual(Directive.err, directiveOf("// error: stray byte").?);
    try testing.expectEqual(@as(?Directive, null), directiveOf("let x = 1\n"));
}

// Property check over every valid-Bit-source case (`run` and `fmt`
// directives; `error` cases are deliberately malformed and out of scope):
// fmt must succeed, must be idempotent (fmt(fmt(x)) == fmt(x)), and must
// never drop a comment (comment count in == out). Covers task #333's
// idempotence and comment-preservation verification over the whole corpus.
test "fmt corpus properties: idempotent, preserves every comment" {
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

        const name = try gpa.dupe(u8, entry.name);
        defer gpa.free(name);

        const source = try dir.readFileAlloc(io, name, gpa, .limited(max_file_bytes));
        defer gpa.free(source);

        const directive = directiveOf(source) orelse return error.MissingDirective;
        if (directive == .err) continue;

        const once = try bitc.formatReport(gpa, name, source);
        defer gpa.free(once.text);
        if (once.failed) {
            std.debug.print("case '{s}': fmt failed on a case whose directive claims valid Bit source:\n{s}\n", .{ name, once.text });
            return error.FmtUnexpectedFailure;
        }

        const twice = try bitc.formatReport(gpa, name, once.text);
        defer gpa.free(twice.text);
        try testing.expect(!twice.failed);
        if (!std.mem.eql(u8, once.text, twice.text))
            std.debug.print("case '{s}': fmt is not idempotent\n", .{name});
        try testing.expectEqualStrings(once.text, twice.text);

        const in_comments = try bitc.commentCount(gpa, source);
        const out_comments = try bitc.commentCount(gpa, once.text);
        if (in_comments != out_comments)
            std.debug.print("case '{s}': comment count in={d} out={d}\n", .{ name, in_comments, out_comments });
        try testing.expectEqual(in_comments, out_comments);
    }
    try testing.expect(scanned < max_cases);
}
