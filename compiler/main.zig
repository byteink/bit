const std = @import("std");
const Io = std.Io;

const diagnostics = @import("diagnostics.zig");
const lexer = @import("lexer.zig");
const ast = @import("ast.zig");
const parser = @import("parser.zig");
const resolve = @import("resolve.zig");
const check = @import("check.zig");
const lower = @import("lower.zig");
const opt = @import("opt.zig");
const emit = @import("emit.zig");
const link = @import("link.zig");
const macho = @import("link/macho.zig");
const fmt = @import("fmt.zig");
const lsp = @import("lsp.zig");

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

    if (argv.len >= 2 and std.mem.eql(u8, argv[1], "lsp")) {
        return lsp.run(gpa, io);
    }

    if (argv.len >= 2 and (std.mem.eql(u8, argv[1], "build") or std.mem.eql(u8, argv[1], "run"))) {
        const is_run = std.mem.eql(u8, argv[1], "run");
        var err_buf: [4096]u8 = undefined;
        var stderr_w: Io.File.Writer = .init(.stderr(), io, &err_buf);
        const code = runBuildOrRun(gpa, io, &stderr_w.interface, is_run, argv[2..]) catch |e| {
            try stderr_w.interface.print("bit {s}: {s}\n", .{ argv[1], @errorName(e) });
            try stderr_w.interface.flush();
            return error.BuildFailed;
        };
        try stderr_w.interface.flush();
        if (code != 0) std.process.exit(code);
        return;
    }

    if (argv.len >= 2 and std.mem.eql(u8, argv[1], "check")) {
        var rest = argv[2..];
        var dump_types = false;
        if (rest.len >= 1 and std.mem.eql(u8, rest[0], "--dump-types")) {
            dump_types = true;
            rest = rest[1..];
        }
        var out_buf: [4096]u8 = undefined;
        var stdout_w: Io.File.Writer = .init(.stdout(), io, &out_buf);
        var err_buf: [4096]u8 = undefined;
        var stderr_w: Io.File.Writer = .init(.stderr(), io, &err_buf);
        const failed = try runCheck(gpa, io, &stdout_w.interface, &stderr_w.interface, dump_types, rest);
        try stdout_w.interface.flush();
        try stderr_w.interface.flush();
        if (failed) return error.CheckFailed;
        return;
    }

    var buf: [64]u8 = undefined;
    var stdout: Io.File.Writer = .init(.stdout(), io, &buf);
    const out = &stdout.interface;
    try out.print("bitc {s}\n", .{version});
    try out.flush();
}

/// Upper bound on a `.bit` source file `bit build`/`bit run` will read.
const max_source_bytes = 8 << 20; // 8 MiB

/// Location of the runtime archive. // ponytail: fixed dev-build path;
/// resolve relative to the `bit` binary's own install prefix, and honor an
/// env override, once packaging (#358) lands.
/// The native binary target `bit build`/`run` produces. Defaults to the host
/// (x86-64 Linux); `--target aarch64-macos` cross-produces an Apple-Silicon
/// Mach-O (which only a Mac can execute, so `bit run` for it just builds).
const BuildTarget = enum {
    x86_64_linux,
    aarch64_macos,

    fn parse(s: []const u8) ?BuildTarget {
        if (std.mem.eql(u8, s, "x86_64-linux")) return .x86_64_linux;
        if (std.mem.eql(u8, s, "aarch64-macos") or std.mem.eql(u8, s, "arm64-macos")) return .aarch64_macos;
        return null;
    }
};

fn libbitrtPath(target: BuildTarget) []const u8 {
    return switch (target) {
        .x86_64_linux => "zig-out/lib/x86_64-linux/libbitrt.a",
        .aarch64_macos => "zig-out/lib/aarch64-macos/libbitrt.a",
    };
}

/// `bit build <file.bit> [-o out]` / `bit run <file.bit>`: the full pipeline to
/// a native binary. Returns the exit code to propagate — 0 after a build, the
/// program's own exit code after a run. Compile diagnostics go to `err_out`;
/// a compile error returns exit code 1, a usage error 2 (SPEC/#347 §Scope).
fn runBuildOrRun(gpa: std.mem.Allocator, io: Io, err_out: *Io.Writer, is_run: bool, args: []const [:0]const u8) !u8 {
    // Parse: one positional <file.bit>, plus `-o <out>` and `--target <t>` in
    // any order.
    var src_path: ?[]const u8 = null;
    var out_path: ?[]const u8 = null;
    var target: BuildTarget = .x86_64_linux;
    var ai: usize = 0;
    while (ai < args.len) {
        const arg = args[ai];
        if (std.mem.eql(u8, arg, "-o") and ai + 1 < args.len) {
            out_path = args[ai + 1];
            ai += 2;
        } else if ((std.mem.eql(u8, arg, "--target") or std.mem.eql(u8, arg, "-t")) and ai + 1 < args.len) {
            target = BuildTarget.parse(args[ai + 1]) orelse {
                try err_out.print("bit: unknown target '{s}' (x86_64-linux | aarch64-macos)\n", .{args[ai + 1]});
                return 2;
            };
            ai += 2;
        } else {
            if (src_path == null) src_path = arg;
            ai += 1;
        }
    }
    const src = src_path orelse {
        try err_out.writeAll("usage: bit build|run <file.bit> [-o out] [--target x86_64-linux|aarch64-macos]\n");
        return 2;
    };

    const source = Io.Dir.cwd().readFileAlloc(io, src, gpa, .limited(max_source_bytes)) catch |e| {
        try err_out.print("bit: {s}: {s}\n", .{ src, @errorName(e) });
        return 1;
    };
    defer gpa.free(source);

    const lib = Io.Dir.cwd().readFileAlloc(io, libbitrtPath(target), gpa, .unlimited) catch |e| {
        try err_out.print("bit: runtime archive {s}: {s} (set BIT_LIBBITRT)\n", .{ libbitrtPath(target), @errorName(e) });
        return 1;
    };
    defer gpa.free(lib);

    const exe = (try buildExecutable(gpa, src, source, lib, target, err_out)) orelse return 1;
    defer gpa.free(exe);

    // Output binary: `-o`, else the source stem, written to the cwd.
    const dest = out_path orelse std.fs.path.stem(src);
    const dest_z = try gpa.dupeZ(u8, dest);
    defer gpa.free(dest_z);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = dest_z, .data = exe });
    _ = std.os.linux.fchmodat(std.os.linux.AT.FDCWD, dest_z, 0o755);

    // A cross-produced macOS binary cannot run on this (Linux) host; `bit run`
    // for it just builds.
    if (!is_run or target != .x86_64_linux) return 0;

    // Run it: `execve` needs a slash to resolve a path against the cwd.
    const run_path = try std.fmt.allocPrintSentinel(gpa, "./{s}", .{dest_z}, 0);
    defer gpa.free(run_path);
    var child = try std.process.spawn(io, .{ .argv = &.{run_path} });
    return switch (try child.wait(io)) {
        .exited => |c| c,
        else => 1,
    };
}

/// Drives one source buffer through the whole compiler — front-end (parse,
/// resolve, check), then lower -> optimize -> codegen/object -> link — into a
/// runnable executable's bytes. Returns `null` (after rendering diagnostics to
/// `err_out`) if any stage before codegen reported an error; the caller maps
/// that to exit code 1.
fn buildExecutable(gpa: std.mem.Allocator, path: []const u8, source: []const u8, libbitrt: []const u8, target: BuildTarget, err_out: *Io.Writer) !?[]u8 {
    var sm = diagnostics.SourceManager.init(gpa);
    defer sm.deinit();
    const file = try sm.addFile(path, source);
    var diags = diagnostics.Diagnostics.init(gpa, &sm);
    defer diags.deinit();

    var tree = try ast.Tree.init(gpa);
    defer tree.deinit();
    try parser.parse(gpa, &tree, &diags, file, source);

    const mf = resolve.ModuleFile{ .file = file, .source = source, .tree = &tree };
    const files = [_]resolve.ModuleFile{mf};
    var no_imports: resolve.ImportTable = .{};
    defer no_imports.deinit(gpa);

    if (diags.hasErrors()) return try renderFail(gpa, &diags, err_out);

    var rmodule = try resolve.resolveModule(gpa, &diags, &files, &no_imports, &.{});
    defer rmodule.deinit();
    if (diags.hasErrors()) return try renderFail(gpa, &diags, err_out);

    var ctx = try check.TypeContext.init(gpa);
    defer ctx.deinit();
    var checked = try check.checkModule(gpa, &diags, &ctx, &files, &rmodule, @enumFromInt(0), &.{}, false);
    defer checked.deinit();
    if (diags.hasErrors()) return try renderFail(gpa, &diags, err_out);

    var module = try lower.lowerModule(gpa, &ctx, &files, &checked, &rmodule);
    defer module.deinit();
    try opt.optimizeModule(gpa, &module, .o1);

    switch (target) {
        .x86_64_linux => {
            const object = try emit.emitObject(gpa, &module);
            defer gpa.free(object);
            return try link.linkExecutable(gpa, .x86_64_linux, &.{ .{ .object = object }, .{ .archive = libbitrt } });
        },
        .aarch64_macos => {
            const object = try emit.emitMachoObject(gpa, &module);
            defer gpa.free(object);
            const ident = std.fs.path.stem(path);
            return try macho.link(gpa, &.{ .{ .object = object }, .{ .archive = libbitrt } }, .{ .identifier = ident });
        },
    }
}

fn renderFail(gpa: std.mem.Allocator, diags: *diagnostics.Diagnostics, err_out: *Io.Writer) !?[]u8 {
    var rendered: Io.Writer.Allocating = .init(gpa);
    defer rendered.deinit();
    try diags.renderAll(&rendered.writer);
    try err_out.writeAll(rendered.written());
    return null;
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

/// `bitc check [--dump-types] <path>...`: type-checks each file independently
/// (each is its own single-file module — matches `compileReport`'s scope).
/// Diagnostics go to `err_out`; with `dump_types`, a clean file's inferred
/// types print to `out` instead of producing no output. Returns `true` iff
/// any file failed, mirroring `runFmt`'s per-file-independence contract.
fn runCheck(gpa: std.mem.Allocator, io: Io, out: *Io.Writer, err_out: *Io.Writer, dump_types: bool, paths: []const [:0]const u8) !bool {
    var any_failed = false;
    for (paths) |path| {
        const source = Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(max_fmt_file_bytes)) catch |e| {
            try err_out.print("bitc check: {s}: {s}\n", .{ path, @errorName(e) });
            any_failed = true;
            continue;
        };
        defer gpa.free(source);

        const report = if (dump_types) try typesReport(gpa, path, source) else try compileReport(gpa, path, source);
        defer gpa.free(report.text);

        if (report.failed) {
            try err_out.writeAll(report.text);
            any_failed = true;
            continue;
        }
        try out.writeAll(report.text);
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

/// Drives every front-end stage (lexer, parser, symbol resolution, type
/// checker) over a single-file `source` and renders the resulting
/// diagnostics. `path` labels the source in diagnostics. The returned `text`
/// is owned by `gpa`; `failed` reports whether compilation would fail (any
/// error-severity diagnostic).
///
/// Each stage only runs if the previous one produced no errors: resolve and
/// check both assume a syntactically valid tree, and check assumes resolved
/// symbols, so running them over a broken tree would cascade into noise
/// rather than the single precise diagnostic a golden case expects.
pub fn compileReport(gpa: std.mem.Allocator, path: []const u8, source: []const u8) !CompileReport {
    var sm = diagnostics.SourceManager.init(gpa);
    defer sm.deinit();
    const file = try sm.addFile(path, source);

    var diags = diagnostics.Diagnostics.init(gpa, &sm);
    defer diags.deinit();

    var tree = try ast.Tree.init(gpa);
    defer tree.deinit();
    try parser.parse(gpa, &tree, &diags, file, source);

    if (!diags.hasErrors()) resolve_and_check: {
        const mf = resolve.ModuleFile{ .file = file, .source = source, .tree = &tree };
        var no_imports: resolve.ImportTable = .{};
        defer no_imports.deinit(gpa);
        const files = [_]resolve.ModuleFile{mf};

        var module = try resolve.resolveModule(gpa, &diags, &files, &no_imports, &.{});
        defer module.deinit();
        if (diags.hasErrors()) break :resolve_and_check;

        var ctx = try check.TypeContext.init(gpa);
        defer ctx.deinit();
        var checked = try check.checkModule(gpa, &diags, &ctx, &files, &module, @enumFromInt(0), &.{}, false);
        defer checked.deinit();
    }

    var rendered: Io.Writer.Allocating = .init(gpa);
    defer rendered.deinit();
    try diags.renderAll(&rendered.writer);

    return .{ .text = try gpa.dupe(u8, rendered.written()), .failed = diags.hasErrors() };
}

/// Drives the front-end through the type checker with `dump_types = true`
/// and renders either its diagnostics (on failure) or its type dump (on
/// success) — the `bitc check --dump-types` positive-suite surface named by
/// task #335's Verify section. `text` is owned by `gpa`.
pub fn typesReport(gpa: std.mem.Allocator, path: []const u8, source: []const u8) !CompileReport {
    var sm = diagnostics.SourceManager.init(gpa);
    defer sm.deinit();
    const file = try sm.addFile(path, source);

    var diags = diagnostics.Diagnostics.init(gpa, &sm);
    defer diags.deinit();

    var tree = try ast.Tree.init(gpa);
    defer tree.deinit();
    try parser.parse(gpa, &tree, &diags, file, source);

    var dump: ?[]u8 = null;
    if (!diags.hasErrors()) resolve_and_check: {
        const mf = resolve.ModuleFile{ .file = file, .source = source, .tree = &tree };
        var no_imports: resolve.ImportTable = .{};
        defer no_imports.deinit(gpa);
        const files = [_]resolve.ModuleFile{mf};

        var module = try resolve.resolveModule(gpa, &diags, &files, &no_imports, &.{});
        defer module.deinit();
        if (diags.hasErrors()) break :resolve_and_check;

        var ctx = try check.TypeContext.init(gpa);
        defer ctx.deinit();
        var checked = try check.checkModule(gpa, &diags, &ctx, &files, &module, @enumFromInt(0), &.{}, true);
        defer checked.deinit();
        if (!diags.hasErrors()) dump = try gpa.dupe(u8, checked.type_dump.?);
    }

    if (dump) |d| return .{ .text = d, .failed = false };

    var rendered: Io.Writer.Allocating = .init(gpa);
    defer rendered.deinit();
    try diags.renderAll(&rendered.writer);
    return .{ .text = try gpa.dupe(u8, rendered.written()), .failed = true };
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

test "build: a printing program compiles, links, and runs" {
    const builtin = @import("builtin");
    if (builtin.cpu.arch != .x86_64 or builtin.os.tag != .linux) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const lib = Io.Dir.cwd().readFileAlloc(io, libbitrtPath(), gpa, .unlimited) catch
        return error.SkipZigTest; // `zig build libbitrt` not run here
    defer gpa.free(lib);

    var discard: Io.Writer.Allocating = .init(gpa);
    defer discard.deinit();
    const src = "function main() {\n  print(\"hi from bit\")\n}\n";
    const exe = (try buildExecutable(gpa, "e2e.bit", src, lib, &discard.writer)) orelse return error.CompileFailed;
    defer gpa.free(exe);

    const path = "/tmp/bit-e2e-test";
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = exe });
    _ = std.os.linux.fchmodat(std.os.linux.AT.FDCWD, path, 0o755);

    const result = try std.process.run(gpa, io, .{ .argv = &.{path} });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    try std.testing.expectEqual(@as(u8, 0), switch (result.term) {
        .exited => |c| c,
        else => 1,
    });
    try std.testing.expectEqualStrings("hi from bit", result.stdout);
}
