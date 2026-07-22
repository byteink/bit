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
//!   `// fmt`   — `bit fmt` canonicalization must byte-match `.expected`
//!                (task #333's golden pairs: messy input -> canonical output).
//!   `// types` — compilation must succeed; `bit check --dump-types`'
//!                inferred-type dump must byte-match `.expected` (task #335's
//!                positive suite: nested lambdas, generic calls).
//!   `// tokens`— the `bit --dump-tokens` stream (kind + span, incl. ASI `;`)
//!                must byte-match `.expected`.
//!   `// ast`   — the `bit --dump-ast` s-expression must byte-match `.expected`.
//!   `// ir`    — the `bit --dump-ir` (post-opt SSA) must byte-match `.expected`.
//!                The last three are the deterministic, canonical dumps the
//!                self-host differential harness diffs the Zig and Bit compilers
//!                on (#1327/#1328/#1329); here they also guard the Zig dumps'
//!                own stability.
//!
//! A mismatch fails the build with a readable diff (via `expectEqualStrings`).
//!
//! THE `run`/`panic` CASES ARE BUILT BY **BOTH** COMPILERS (#1424). Until then
//! every case here was compiled by the bootstrap seed alone, so the largest
//! corpus in the project — 86 behavioural cases — said nothing about the
//! self-hosted `bit` the project exists to ship. That was not theoretical:
//! #1419 reverted the selfhost half of its own variadic fix and this suite
//! stayed green, because `tests/stress/*` (#1413) was the only corpus that had
//! been taught to drive both compilers. Do not "fix" a failure here by skipping
//! the case — a skip-list reads as coverage and is the hole this pass closes.
//!
//! The two compilers are driven differently on purpose. The seed is a Zig
//! module, so it compiles in-process (`bit.buildHostExecutable`, single file,
//! no prelude). Self-hosted `bit` is a Bit-compiled executable, so it is a
//! subprocess — and a subprocess build of a lone file is a whole-project build
//! of a one-file module (SPEC §17.1), which does get the prelude. The two
//! therefore compile slightly different programs, and that is the stronger
//! test: both must still reproduce the same `.expected`, and the self-hosted
//! side takes the path a real user takes. `BIT_LIBBITRT`/`BIT_STDLIB` hand it
//! the same archive the seed links, which also keeps the harness independent of
//! its working directory.
//!
//! EVERY SUBPROCESS HERE CARRIES A WALL-CLOCK DEADLINE (#1637). A `run` case
//! whose program hangs used to stall the whole suite with no output naming it —
//! strictly worse than a failure, because CI burns its own job timeout and the
//! log never says which case did it. `tests/proc.zig` bounds each spawn and
//! reports an expiry as its own outcome, so a hang is a red case naming itself.
//! See that file for the limit, how it was chosen, and the `BIT_TEST_TIMEOUT_S`
//! override.
//!
//! Every `run`/`fmt`/`types` case (i.e. every case that is valid Bit source,
//! per its own directive) also feeds a corpus-wide property check: fmt must
//! be idempotent and must never drop a comment (see "fmt corpus properties"
//! below) — `// error` cases are deliberately malformed and out of scope.

const std = @import("std");
const bit = @import("bit");
const build_options = @import("build_options");
const proc = @import("proc.zig");
const selfbin = @import("selfbin.zig");

const testing = std.testing;
const Io = std.Io;
const Dir = std.Io.Dir;

/// Upper bound on cases scanned per run — keeps the directory walk provably
/// bounded (Power of 10). Raise if the corpus ever approaches it.
const max_cases = 4096;

/// Upper bound on any single case/expected file.
const max_file_bytes = 1 << 20; // 1 MiB

const Directive = enum { run, panic, err, fmt, types, tokens, ast, ir };

/// `ran_both` is reported only by a `run`/`panic` case that actually built and
/// executed under BOTH compilers, so the suite can assert the self-hosted pass
/// matched something rather than trusting that it did.
const Outcome = enum { checked, ran_both, skipped };

/// Exit code the runtime uses for every panic (`runtime/root.zig`'s `fatal`,
/// SPEC.md §18.4). Matching it exactly — rather than merely "non-zero" — keeps
/// a crash (signal, 255) from passing as a panic.
const panic_exit_code: u8 = 2;

/// The self-hosted compiler this run execs — a PRIVATE COPY, never
/// `build_options.selfhost_bit` itself. A concurrent `zig build` rewrites that
/// artifact in place and macOS SIGKILLs the exec mid-flight, failing every case
/// with no output at all (#1644); see tests/selfbin.zig. Empty on a cross build,
/// where there is no runnable `bit`.
///
/// Module-scoped rather than threaded through `checkCase`: it is written once,
/// by the test below, before the first case runs, and only read afterwards.
var self_compiler: []const u8 = "";

test "golden cases" {
    const gpa = testing.allocator;
    const io = Io.Threaded.global_single_threaded.io();

    var copy_threaded = Io.Threaded.init(gpa, .{});
    defer copy_threaded.deinit();
    const copy: ?[:0]const u8 = if (build_options.selfhost_bit.len > 0)
        try selfbin.privateCopy(gpa, copy_threaded.io(), build_options.selfhost_bit)
    else
        null;
    defer if (copy) |p| selfbin.release(gpa, copy_threaded.io(), p);
    self_compiler = copy orelse "";

    var dir = Dir.openDirAbsolute(io, build_options.cases_dir, .{ .iterate = true }) catch |e| {
        std.debug.print("cannot open cases dir '{s}': {s}\n", .{ build_options.cases_dir, @errorName(e) });
        return e;
    };
    defer dir.close(io);

    var it = dir.iterate();
    var scanned: u32 = 0;
    var ran_both: u32 = 0;
    while (scanned < max_cases) : (scanned += 1) {
        const entry = (try it.next(io)) orelse break;
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".bit")) continue;

        // `entry.name` is invalidated by the next iterator step; copy it.
        const name = try gpa.dupe(u8, entry.name);
        defer gpa.free(name);

        if (try checkCase(gpa, io, dir, name) == .ran_both) ran_both += 1;
    }
    try testing.expect(scanned < max_cases); // corpus stayed within bound

    // On a host that can run binaries at all, the self-hosted pass must have
    // matched at least one case. Without this a directive-matching bug (or a
    // corpus that lost every `// run` case) would retire the whole second
    // compiler while the suite still reported green — the precise failure mode
    // #1424 was filed for.
    if (build_options.libbitrt_path.len > 0) try testing.expect(ran_both > 0);
}

fn checkCase(gpa: std.mem.Allocator, io: Io, dir: Dir, name: []const u8) !Outcome {
    const source = try dir.readFileAlloc(io, name, gpa, .limited(max_file_bytes));
    defer gpa.free(source);

    const directive = directiveOf(source) orelse {
        std.debug.print("case '{s}': line 1 must be '// run', '// panic', '// error', '// fmt', '// types', '// tokens', '// ast', or '// ir'\n", .{name});
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

            // A host that can link libbitrt is a native build, and a native
            // build always produces the self-hosted `bit`. Assert it rather
            // than degrading to the seed-only pass: a green suite must not be
            // able to mean "half of what it claims to check was not wired up",
            // which is precisely how #1419's selfhost revert went unnoticed.
            try testing.expect(build_options.selfhost_bit.len > 0);

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

            const stem = name[0 .. name.len - ".bit".len];
            const seed_bin = try std.fmt.allocPrintSentinel(gpa, "/tmp/bit-golden-seed-{s}-{x}", .{ stem, testing.random_seed }, 0);
            defer gpa.free(seed_bin);
            const self_bin = try std.fmt.allocPrintSentinel(gpa, "/tmp/bit-golden-self-{s}-{x}", .{ stem, testing.random_seed }, 0);
            defer gpa.free(self_bin);

            // ---- Phase 1: compile and write; nothing is exec'd yet.
            //
            // `74811a3`'s discipline, kept as this suite gained a second
            // compiler: never let a `fork` happen while this process holds a
            // write fd to a binary it is about to `execve`, because `fork`
            // copies the whole fd table and Linux refuses to exec an inode
            // whose writecount is nonzero (ETXTBSY). Driving self-hosted `bit`
            // means forking, so it goes FIRST — before this process opens
            // anything for writing — and the seed's `writeFile` (which forks
            // nothing) follows it. Doubling the builds doubled the exposure;
            // phase separation removes it by construction.
            // One read of the knob per case, shared by both the compile and the
            // two executions below.
            const timeout_s = proc.timeoutSeconds(gpa);

            defer Dir.cwd().deleteFile(run_io, self_bin) catch {};
            try buildWithSelfhost(gpa, run_io, name, self_bin, timeout_s);

            var discard: Io.Writer.Allocating = .init(gpa);
            defer discard.deinit();
            const exe = (try bit.buildHostExecutable(gpa, name, source, libbitrt, &discard.writer)) orelse {
                std.debug.print("case '{s}': expected compile to succeed, got diagnostics:\n{s}\n", .{ name, discard.written() });
                return error.RunCompileFailed;
            };
            defer gpa.free(exe);

            defer Dir.cwd().deleteFile(run_io, seed_bin) catch {};
            try Dir.cwd().writeFile(run_io, .{
                .sub_path = seed_bin,
                .data = exe,
                .flags = .{ .permissions = .executable_file },
            });

            // ---- Phase 2: exec only. Both compilers' output must satisfy the
            // same `.expected`.
            try runBinary(gpa, run_io, name, "seed", seed_bin, directive, expected, timeout_s);
            try runBinary(gpa, run_io, name, "selfhost", self_bin, directive, expected, timeout_s);
            return .ran_both;
        },
        .err => {
            const report = try bit.compileReport(gpa, name, source);
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
            const report = try bit.formatReport(gpa, name, source);
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
            const report = try bit.typesReport(gpa, name, source);
            defer gpa.free(report.text);
            if (report.failed) {
                std.debug.print("case '{s}': expected type-check to succeed, got diagnostics:\n{s}\n", .{ name, report.text });
                return error.TypeCheckFailed;
            }
            if (!std.mem.eql(u8, expected, report.text))
                std.debug.print("case '{s}' type-dump mismatch:\n", .{name});
            try testing.expectEqualStrings(expected, report.text);
        },
        .tokens => {
            const report = try bit.tokensReport(gpa, name, source);
            defer gpa.free(report.text);
            if (report.failed) {
                std.debug.print("case '{s}': expected lexing to succeed, got diagnostics:\n{s}\n", .{ name, report.text });
                return error.TokensFailed;
            }
            if (!std.mem.eql(u8, expected, report.text))
                std.debug.print("case '{s}' token-dump mismatch:\n", .{name});
            try testing.expectEqualStrings(expected, report.text);
        },
        .ast => {
            const report = try bit.parseReport(gpa, name, source);
            defer gpa.free(report.text);
            if (report.failed) {
                std.debug.print("case '{s}': expected parse to succeed, got diagnostics:\n{s}\n", .{ name, report.text });
                return error.AstParseFailed;
            }
            if (!std.mem.eql(u8, expected, report.text))
                std.debug.print("case '{s}' AST-dump mismatch:\n", .{name});
            try testing.expectEqualStrings(expected, report.text);
        },
        .ir => {
            const report = try bit.irReport(gpa, name, source, true);
            defer gpa.free(report.text);
            if (report.failed) {
                std.debug.print("case '{s}': expected lowering to succeed, got diagnostics:\n{s}\n", .{ name, report.text });
                return error.IrLowerFailed;
            }
            if (!std.mem.eql(u8, expected, report.text))
                std.debug.print("case '{s}' IR-dump mismatch:\n", .{name});
            try testing.expectEqualStrings(expected, report.text);
        },
    }
    return .checked;
}

/// Build one golden case with the self-hosted `bit`. It is a Bit-compiled
/// executable, not a Zig module this harness can import, so it is driven as a
/// subprocess. `BIT_LIBBITRT`/`BIT_STDLIB` hand it the same archive the seed
/// links and the real stdlib, which keeps the harness independent of its
/// working directory (sidestepping the installed-`bit`-libbitrt-CWD bug rather
/// than depending on it).
fn buildWithSelfhost(gpa: std.mem.Allocator, run_io: Io, name: []const u8, out_path: [:0]const u8, timeout_s: u32) !void {
    const case_path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ build_options.cases_dir, name });
    defer gpa.free(case_path);

    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    try env.put("BIT_LIBBITRT", build_options.libbitrt_path);
    try env.put("BIT_STDLIB", build_options.stdlib_dir);

    // The compiler is bounded too: a compiler that loops forever stalls the
    // suite exactly as a hung case binary does, and says even less about why.
    std.debug.assert(self_compiler.len > 0);
    const outcome = try proc.run(gpa, run_io, timeout_s, .{
        .argv = &.{ self_compiler, "build", case_path, "-o", out_path },
        .environ_map = &env,
    });
    const result = switch (outcome) {
        .finished => |r| r,
        .timed_out => |limit| {
            std.debug.print("case '{s}' [selfhost]: COMPILE TIMED OUT\n", .{name});
            proc.timedOutNote(limit, self_compiler);
            return error.SelfhostCompileTimedOut;
        },
    };
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);

    if (result.term == .exited and result.term.exited == 0) return;
    std.debug.print("case '{s}' [selfhost]: expected compile to succeed:\n", .{name});
    proc.toolFailedNote(result.term, self_compiler, result.stdout, result.stderr);
    return error.SelfhostCompileFailed;
}

/// Execute one compiler's binary for a `run`/`panic` case and hold it to the
/// case's `.expected`. `who` names the compiler so a failure says which of the
/// two produced it.
///
/// Three outcomes are kept apart on purpose. A DEADLINE EXPIRY is the machine
/// intervening and is reported as a timeout; a SIGNAL the program raised on
/// itself (SIGSEGV, SIGBUS, SIGABRT) is a *result* and is reported as a crash
/// naming the signal; anything else is an ordinary exit code. Folding a crash
/// into "timed out", or a timeout into a generic mismatch, sends the reader
/// hunting the wrong bug — which is the whole reason the timeout is a distinct
/// outcome rather than a synthesised term.
fn runBinary(
    gpa: std.mem.Allocator,
    run_io: Io,
    name: []const u8,
    who: []const u8,
    bin_path: [:0]const u8,
    directive: Directive,
    expected: []const u8,
    timeout_s: u32,
) !void {
    const outcome = try proc.run(gpa, run_io, timeout_s, .{ .argv = &.{bin_path} });
    const result = switch (outcome) {
        .finished => |r| r,
        .timed_out => |limit| {
            std.debug.print("case '{s}' [{s}]: TIMED OUT\n", .{ name, who });
            proc.timedOutNote(limit, bin_path);
            return error.RunTimedOut;
        },
    };
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    if (result.term == .signal) {
        std.debug.print("case '{s}' [{s}]: CRASHED\n", .{ name, who });
        proc.crashNote(result.term.signal);
        std.debug.print("stderr: {s}\n", .{result.stderr});
        return error.RunCrashed;
    }
    const code: u8 = switch (result.term) {
        .exited => |c| c,
        else => 255,
    };
    if (directive == .panic) {
        if (code != panic_exit_code) {
            std.debug.print("case '{s}' [{s}]: expected a panic (exit {d}), got exit {d}\nstderr: {s}\n", .{ name, who, panic_exit_code, code, result.stderr });
            return error.ExpectedPanic;
        }
        if (!std.mem.eql(u8, expected, result.stderr))
            std.debug.print("case '{s}' [{s}] stderr mismatch:\n", .{ name, who });
        try testing.expectEqualStrings(expected, result.stderr);
        return;
    }
    if (code != 0) {
        std.debug.print("case '{s}' [{s}]: binary exited with {d}\nstderr: {s}\n", .{ name, who, code, result.stderr });
        return error.RunFailed;
    }
    if (!std.mem.eql(u8, expected, result.stdout))
        std.debug.print("case '{s}' [{s}] stdout mismatch:\n", .{ name, who });
    try testing.expectEqualStrings(expected, result.stdout);
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
    if (std.mem.startsWith(u8, line, "// tokens")) return .tokens;
    if (std.mem.startsWith(u8, line, "// ast")) return .ast;
    if (std.mem.startsWith(u8, line, "// ir")) return .ir;
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

        const once = try bit.formatReport(gpa, name, source);
        defer gpa.free(once.text);
        if (once.failed) {
            std.debug.print("case '{s}': fmt failed on a case whose directive claims valid Bit source:\n{s}\n", .{ name, once.text });
            return error.FmtUnexpectedFailure;
        }

        const twice = try bit.formatReport(gpa, name, once.text);
        defer gpa.free(twice.text);
        try testing.expect(!twice.failed);
        if (!std.mem.eql(u8, once.text, twice.text))
            std.debug.print("case '{s}': fmt is not idempotent\n", .{name});
        try testing.expectEqualStrings(once.text, twice.text);

        const in_comments = try bit.commentCount(gpa, source);
        const out_comments = try bit.commentCount(gpa, once.text);
        if (in_comments != out_comments)
            std.debug.print("case '{s}': comment count in={d} out={d}\n", .{ name, in_comments, out_comments });
        try testing.expectEqual(in_comments, out_comments);
    }
    try testing.expect(scanned < max_cases);
}
