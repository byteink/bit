const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const Io = std.Io;

const diagnostics = @import("diagnostics.zig");
const lexer = @import("lexer.zig");
/// `pub` so the AST tag-set parity gate (tests/ast_tags.zig) can enumerate
/// `Tag` by reflection instead of parsing ast.zig — a text scan of that file
/// silently misses `@"export"`.
pub const ast = @import("ast.zig");
const parser = @import("parser.zig");
const resolve = @import("resolve.zig");
const check = @import("check.zig");
const lower = @import("lower.zig");
const ir = @import("ir.zig");
const opt = @import("opt.zig");
pub const testgen = @import("testgen.zig");
pub const doc = @import("doc.zig");
const emit = @import("emit.zig");
const link = @import("link.zig");
const archive = @import("link/archive.zig");
const macho = @import("link/macho.zig");
/// `pub` for the runtime-pin cycle gate (tests/rootpins.zig): it reads back an
/// object this compiler just emitted, which is the only way to see the symbol a
/// call actually lands on rather than the name the source spells. Both readers,
/// because a `darwin/` provider cannot be emitted for a Linux target at all
/// (the checker refuses `extern function` there, even uncalled), so covering
/// both platform halves means reading both object formats.
pub const elf_reader = @import("link/elf_reader.zig");
pub const macho_reader = @import("link/macho_reader.zig");
pub const fmt = @import("fmt.zig");
const lsp = @import("lsp.zig");

/// The toolchain version, parsed by `build.zig` out of `selfhost/version.bit` —
/// the single source of truth both compilers share (#1451). It is NOT a second
/// copy: this file no longer names a version at all, so the seed cannot drift
/// from the self-hosted `bit` the way it had (seed "0.0.0" vs selfhost
/// "0.1.0-stub"). Overridden for a release by `zig build -Dversion=X.Y.Z`.
pub const version = build_options.version;

/// Upper bound on a single source file `bit fmt` will read. Matches the
/// golden harness's own cap (tests/harness.zig max_file_bytes).
const max_fmt_file_bytes = 1 << 20; // 1 MiB

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const argv = try init.minimal.args.toSlice(init.arena.allocator());

    // Every std-stream writer below is `.initStreaming`, never the `.init`
    // default: `.init` selects `.positional` mode, which pwrites from the
    // writer's OWN offset starting at 0 rather than the fd's shared offset. Two
    // writers on one inherited stderr — ours, then the runtime's `error: X` —
    // therefore both start at byte 0, and the second silently overwrites the
    // first (a 19-byte "error: CheckFailed\n" ate the front of every rendered
    // diagnostic). A tty or pipe is not seekable, so the mode falls back and the
    // corruption appears only once output is redirected to a file: CI logs, and
    // the self-host differentials.
    if (argv.len >= 2 and std.mem.eql(u8, argv[1], "fmt")) {
        var err_buf: [4096]u8 = undefined;
        var stderr_w: Io.File.Writer = .initStreaming(.stderr(), io, &err_buf);
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
        var stderr_w: Io.File.Writer = .initStreaming(.stderr(), io, &err_buf);
        const code = runBuildOrRun(gpa, io, &stderr_w.interface, is_run, argv[2..]) catch |e| {
            try stderr_w.interface.print("bit {s}: {s}\n", .{ argv[1], @errorName(e) });
            try stderr_w.interface.flush();
            return error.BuildFailed;
        };
        try stderr_w.interface.flush();
        if (code != 0) std.process.exit(code);
        return;
    }

    if (argv.len >= 2 and std.mem.eql(u8, argv[1], "ar")) {
        var err_buf: [4096]u8 = undefined;
        var stderr_w: Io.File.Writer = .initStreaming(.stderr(), io, &err_buf);
        const code = runAr(gpa, io, &stderr_w.interface, argv[2..]) catch |e| {
            try stderr_w.interface.print("bit ar: {s}\n", .{@errorName(e)});
            try stderr_w.interface.flush();
            return error.ArchiveFailed;
        };
        try stderr_w.interface.flush();
        if (code != 0) std.process.exit(code);
        return;
    }

    if (argv.len >= 2 and std.mem.eql(u8, argv[1], "test")) {
        var out_buf: [4096]u8 = undefined;
        var stdout_w: Io.File.Writer = .initStreaming(.stdout(), io, &out_buf);
        var err_buf: [4096]u8 = undefined;
        var stderr_w: Io.File.Writer = .initStreaming(.stderr(), io, &err_buf);
        const code = runTest(gpa, io, &stdout_w.interface, &stderr_w.interface, init.environ_map, argv[2..]) catch |e| {
            try stderr_w.interface.print("bit test: {s}\n", .{@errorName(e)});
            try stderr_w.interface.flush();
            return error.TestFailed;
        };
        try stdout_w.interface.flush();
        try stderr_w.interface.flush();
        if (code != 0) std.process.exit(code);
        return;
    }

    if (argv.len >= 2 and std.mem.eql(u8, argv[1], "doc")) {
        var err_buf: [4096]u8 = undefined;
        var stderr_w: Io.File.Writer = .initStreaming(.stderr(), io, &err_buf);
        var out_buf: [4096]u8 = undefined;
        var stdout_w: Io.File.Writer = .initStreaming(.stdout(), io, &out_buf);
        const failed = runDoc(gpa, io, &stdout_w.interface, &stderr_w.interface, argv[2..]) catch |e| {
            try stderr_w.interface.print("bit doc: {s}\n", .{@errorName(e)});
            try stderr_w.interface.flush();
            return error.DocFailed;
        };
        try stdout_w.interface.flush();
        try stderr_w.interface.flush();
        if (failed) return error.DocFailed;
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
        var stdout_w: Io.File.Writer = .initStreaming(.stdout(), io, &out_buf);
        var err_buf: [4096]u8 = undefined;
        var stderr_w: Io.File.Writer = .initStreaming(.stderr(), io, &err_buf);
        const failed = try runCheck(gpa, io, &stdout_w.interface, &stderr_w.interface, dump_types, rest);
        try stdout_w.interface.flush();
        try stderr_w.interface.flush();
        if (failed) return error.CheckFailed;
        return;
    }

    // Single-file front-end dumps (`--dump-tokens|-ast|-types|-ir|-ir-pre`): the
    // deterministic, canonical surfaces the self-host differential harness diffs
    // the Zig and Bit compilers on. Front end only; no libbitrt.
    if (argv.len >= 2 and std.mem.startsWith(u8, argv[1], "--dump-")) {
        var out_buf: [4096]u8 = undefined;
        var stdout_w: Io.File.Writer = .initStreaming(.stdout(), io, &out_buf);
        var err_buf: [4096]u8 = undefined;
        var stderr_w: Io.File.Writer = .initStreaming(.stderr(), io, &err_buf);
        const failed = try runDump(gpa, io, &stdout_w.interface, &stderr_w.interface, argv[1], argv[2..]);
        try stdout_w.interface.flush();
        try stderr_w.interface.flush();
        if (failed) return error.CheckFailed;
        return;
    }

    // A real `version` subcommand (#1451). It used to only APPEAR to work:
    // every unrecognized argument fell through to the banner below, so
    // `bit version` and `bit vresion` printed the same thing. The line is
    // byte-identical to the self-hosted `bit`'s — both read the same
    // `selfhost/version.bit` — so an installer or differential harness can
    // compare the two compilers directly.
    if (argv.len >= 2 and (std.mem.eql(u8, argv[1], "version") or
        std.mem.eql(u8, argv[1], "--version") or std.mem.eql(u8, argv[1], "-V")))
    {
        var vbuf: [64]u8 = undefined;
        var vout: Io.File.Writer = .initStreaming(.stdout(), io, &vbuf);
        try vout.interface.print("bit {s}\n", .{version});
        try vout.interface.flush();
        return;
    }

    // Anything else with arguments is a usage error, not the banner.
    if (argv.len >= 2) {
        var ebuf: [256]u8 = undefined;
        var eout: Io.File.Writer = .initStreaming(.stderr(), io, &ebuf);
        try eout.interface.print(
            "bit: unknown subcommand '{s}'\nusage: bit <build|run|check|test|fmt|doc|ar|lsp|version> ...\n",
            .{argv[1]},
        );
        try eout.interface.flush();
        std.process.exit(2);
    }

    var buf: [64]u8 = undefined;
    var stdout: Io.File.Writer = .initStreaming(.stdout(), io, &buf);
    const out = &stdout.interface;
    try out.print("bit {s}\n", .{version});
    try out.flush();
}

/// Upper bound on a `.bit` source file `bit build`/`bit run` will read.
const max_source_bytes = 8 << 20; // 8 MiB

/// A per-invocation nonce for scratch paths that are WRITTEN and then EXEC'd
/// (`bit run`, `bit test`). A fixed name lets two concurrent processes clobber
/// one file while the other execs it — ETXTBSY, or worse a binary that is half
/// one build and half another, surfacing as a hang rather than an error (#1459,
/// #1463). Seeding from the wall clock is sufficient here: the collision window
/// is one nanosecond between two independently launched processes, and the
/// consequence of the astronomically unlikely tie is a retryable failure, not a
/// wrong answer.
fn scratchNonce(io: Io) u64 {
    const ns: i96 = Io.Timestamp.now(io, .real).nanoseconds;
    var prng = std.Random.DefaultPrng.init(@bitCast(@as(i64, @truncate(ns))));
    return prng.random().int(u64);
}

/// Location of the runtime archive, relative to the build root.
///
/// Deliberately still cwd-relative after #1452 gave the SHIPPED compiler
/// install-prefix resolution. `bit-seed` is a bootstrap and differential-oracle
/// artifact: it is never packaged, never installed, and is only ever run from
/// the build root by `build.zig` and the harnesses. Teaching it to resolve
/// against its own location would buy nothing and would change the paths every
/// differential runs on. The self-hosted `bit` in `selfhost/main.bit` is the
/// one users get, and it resolves properly there.
/// The native binary target `bit build`/`run` produces. Defaults to whichever
/// host is running this `bit` (so `bit run` on a Mac execs an arm64 binary, on
/// Linux an x86-64 one); `--target` cross-produces the other, which only its
/// own host can execute (so `bit run` for a foreign target just builds).
/// `pub` so the runtime-pin cycle gate (tests/rootpins.zig) can ask for an ELF
/// object on any host — the property it checks is target-independent, but only
/// the ELF reader below can be pointed at an arbitrary target's output.
pub const BuildTarget = enum {
    x86_64_linux,
    aarch64_linux,
    aarch64_macos,

    fn parse(s: []const u8) ?BuildTarget {
        if (std.mem.eql(u8, s, "x86_64-linux")) return .x86_64_linux;
        if (std.mem.eql(u8, s, "aarch64-linux") or std.mem.eql(u8, s, "arm64-linux")) return .aarch64_linux;
        if (std.mem.eql(u8, s, "aarch64-macos") or std.mem.eql(u8, s, "arm64-macos")) return .aarch64_macos;
        return null;
    }

    /// The CLI spelling, for diagnostics that name a target back to the user.
    fn name(self: BuildTarget) []const u8 {
        return switch (self) {
            .x86_64_linux => "x86_64-linux",
            .aarch64_linux => "aarch64-linux",
            .aarch64_macos => "aarch64-macos",
        };
    }
};

/// The target matching the host this `bit` binary itself runs on — the default
/// `bit build`/`run` target, and the only one `bit run` can `exec` directly.
/// Keyed on both OS and arch: a Linux host can be x86-64 or AArch64.
const host_target: BuildTarget = switch (builtin.target.os.tag) {
    .macos => .aarch64_macos,
    else => switch (builtin.target.cpu.arch) {
        .aarch64 => .aarch64_linux,
        else => .x86_64_linux,
    },
};

fn libbitrtPath(target: BuildTarget) []const u8 {
    return switch (target) {
        .x86_64_linux => "zig-out/lib/x86_64-linux/libbitrt.a",
        .aarch64_linux => "zig-out/lib/aarch64-linux/libbitrt.a",
        .aarch64_macos => "zig-out/lib/aarch64-macos/libbitrt.a",
    };
}

/// Where `std/*` imports resolve, relative to the cwd. Cwd-relative for the
/// same reason as `libbitrtPath` above: the seed is never installed.
const stdlib_dir = "stdlib";

/// `bit build <file.bit> [-o out]` / `bit run <file.bit>`: the full pipeline to
/// a native binary. Returns the exit code to propagate — 0 after a build, the
/// program's own exit code after a run. Compile diagnostics go to `err_out`;
/// a compile error returns exit code 1, a usage error 2 (SPEC/#347 §Scope).
fn runBuildOrRun(gpa: std.mem.Allocator, io: Io, err_out: *Io.Writer, is_run: bool, args: []const [:0]const u8) !u8 {
    // Parse: one positional <file.bit>, plus `-o <out>` and `--target <t>` in
    // any order.
    var src_path: ?[]const u8 = null;
    var out_path: ?[]const u8 = null;
    var emit_obj = false;
    var freestanding = false;
    var target: BuildTarget = host_target;
    var ai: usize = 0;
    while (ai < args.len) {
        const arg = args[ai];
        if (std.mem.eql(u8, arg, "-o") and ai + 1 < args.len) {
            out_path = args[ai + 1];
            ai += 2;
        } else if (std.mem.eql(u8, arg, "--emit-obj") or std.mem.eql(u8, arg, "-c")) {
            emit_obj = true;
            ai += 1;
        } else if (std.mem.eql(u8, arg, "--freestanding")) {
            freestanding = true;
            ai += 1;
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
        try err_out.writeAll("usage: bit build|run <file.bit> [-o out] [--emit-obj [--freestanding]] [--target x86_64-linux|aarch64-linux|aarch64-macos]\n");
        return 2;
    };
    if (emit_obj and is_run) {
        try err_out.writeAll("bit: --emit-obj produces an object, not a program: use `bit build`\n");
        return 2;
    }
    // §17.6: freestanding describes an archive MEMBER — a module compiled with
    // no prelude and emitted alone. There is no such thing as a freestanding
    // executable today (nothing would boot it), so rather than quietly implying
    // `--emit-obj`, require it: the combination the user meant is the only one
    // that means anything.
    if (freestanding and !emit_obj) {
        try err_out.writeAll("bit: --freestanding emits an archive member: pass --emit-obj\n");
        return 2;
    }

    // `bit run` of a foreign-target binary cannot exec here, so there is nothing
    // to run. It used to build anyway and fall through to the build path, which
    // writes the artifact into the CWD under the source stem — a silent
    // multi-hundred-KB drop in the working tree from a command that only ever
    // promised to run something and throw it away (#1463: `git add -A` nearly
    // committed one). Refuse, unless `-o` says where the user actually wants it:
    // an explicit destination is a request, the cwd stem is litter.
    //
    // Checked here rather than after linking so it costs nothing: there is no
    // point compiling and linking a whole program in order to then decline it.
    if (is_run and target != host_target and out_path == null) {
        try err_out.print("bit: cannot run a {s} binary on this host: use `bit build` (add -o to choose where it lands)\n", .{@tagName(target)});
        return 2;
    }

    // An object is emitted, never linked, so it needs no runtime archive — and
    // must not demand one, since a Bit-sourced libbitrt.a is exactly what this
    // path exists to build (#1397).
    const lib: []const u8 = if (emit_obj) "" else Io.Dir.cwd().readFileAlloc(io, libbitrtPath(target), gpa, .unlimited) catch |e| {
        try err_out.print("bit: runtime archive {s}: {s} (set BIT_LIBBITRT)\n", .{ libbitrtPath(target), @errorName(e) });
        return 1;
    };
    defer if (!emit_obj) gpa.free(lib);

    // The object identifier / default output name is the module's own name: the
    // directory's basename for a directory module, or the file stem otherwise —
    // `stem` yields both ("examples/countdown" -> "countdown", "a.bit" -> "a").
    const ident = std.fs.path.stem(src);

    // Both a directory and a lone file are modules (SPEC §17.1), so both take
    // the same whole-project pipeline and both get the prelude and imports. A
    // file differs only in which files the root module contains: exactly that
    // one, never its siblings. Building a lone file "directly" instead is what
    // made `bit run hello.bit` — the tutorial's first line — fail with
    // "undefined name 'println'": the prelude only ever reached a directory.
    const stat = Io.Dir.cwd().statFile(io, src, .{}) catch |e| {
        try err_out.print("bit: {s}: {s}\n", .{ src, @errorName(e) });
        return 1;
    };
    const root_src = if (stat.kind == .directory) src else std.fs.path.dirname(src) orelse ".";
    const root_only: ?[]const u8 = if (stat.kind == .directory) null else std.fs.path.basename(src);
    const root_abs = try absFromCwd(gpa, io, root_src);
    defer gpa.free(root_abs);
    // Best-effort: a build without a stdlib checkout still works (std/*
    // imports then error cleanly); only a real stdlib dir enables them.
    //
    // §17.6: freestanding withholds the stdlib root entirely, which is the
    // whole mechanism — `loadProject` loads the prelude FROM that root, so a
    // null root means no prelude is loaded and no `std/*` import resolves. A
    // module that reaches for `println` (or imports `std/io`) then fails in the
    // resolver with an ordinary undefined-name diagnostic, because the name
    // genuinely is not in scope. That is the point: the managed/unmanaged
    // boundary is enforced by absence, not by a list of forbidden names the
    // checker would have to keep in sync with the prelude.
    const std_root: ?[]u8 = if (freestanding) null else absFromCwd(gpa, io, stdlib_dir) catch null;
    defer if (std_root) |s| gpa.free(s);
    const exe = (try buildProject(gpa, io, root_abs, root_only, std_root, ident, lib, target, err_out, null, emit_obj, freestanding)) orelse return 1;
    defer gpa.free(exe);

    // An object is not executable: write it plain, defaulting to `<stem>.o`.
    if (emit_obj) {
        const obj_default = try std.fmt.allocPrint(gpa, "{s}.o", .{ident});
        defer gpa.free(obj_default);
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = out_path orelse obj_default, .data = exe });
        return 0;
    }

    // `bit run` on a binary this host can exec runs it and throws it away, like
    // `zig run` — it must never litter the cwd.
    if (is_run and target == host_target) {
        // Unique per invocation: two concurrent `bit run`s of a same-named
        // module otherwise write and exec ONE path, which is the ETXTBSY/
        // clobber shape #1459 records for `seed/link.zig`.
        const tmp = try std.fmt.allocPrintSentinel(gpa, "/tmp/bit-run-{s}-{x}", .{ std.fs.path.stem(src), scratchNonce(io) }, 0);
        defer gpa.free(tmp);
        try Io.Dir.cwd().writeFile(io, .{
            .sub_path = tmp,
            .data = exe,
            .flags = .{ .permissions = .executable_file },
        });
        defer Io.Dir.cwd().deleteFile(io, tmp) catch {};
        var child = try std.process.spawn(io, .{ .argv = &.{tmp} });
        return switch (try child.wait(io)) {
            .exited => |c| c,
            else => 1,
        };
    }

    // Output binary: `-o`, else the source stem, written to the cwd.
    const dest = out_path orelse std.fs.path.stem(src);
    try Io.Dir.cwd().writeFile(io, .{
        .sub_path = dest,
        .data = exe,
        .flags = .{ .permissions = .executable_file },
    });
    return 0;
}

/// `bit ar <out.a> <obj...> [--target t]`: bundles already-emitted relocatable
/// objects into an `ar` archive (#1398), the `ar rcs` half of the toolchain that
/// `bit build --emit-obj` feeds. The name encoding follows the target's own
/// convention — BSD for Mach-O, GNU for ELF — which is what `link.zig`'s reader
/// and every platform `ar` expect. Each member is named by its file's basename.
fn runAr(gpa: std.mem.Allocator, io: Io, err_out: *Io.Writer, args: []const [:0]const u8) !u8 {
    var out_path: ?[]const u8 = null;
    var target: BuildTarget = host_target;
    var inputs: std.ArrayList([]const u8) = .empty;
    defer inputs.deinit(gpa);
    var ai: usize = 0;
    while (ai < args.len) {
        if ((std.mem.eql(u8, args[ai], "--target") or std.mem.eql(u8, args[ai], "-t")) and ai + 1 < args.len) {
            target = BuildTarget.parse(args[ai + 1]) orelse {
                try err_out.print("bit ar: unknown target '{s}'\n", .{args[ai + 1]});
                return 2;
            };
            ai += 2;
            continue;
        }
        if (out_path == null) out_path = args[ai] else try inputs.append(gpa, args[ai]);
        ai += 1;
    }
    const out = out_path orelse {
        try err_out.writeAll("usage: bit ar <out.a> <obj.o...> [--target x86_64-linux|aarch64-linux|aarch64-macos]\n");
        return 2;
    };
    if (inputs.items.len == 0) {
        try err_out.writeAll("bit ar: no input objects\n");
        return 2;
    }

    var members: std.ArrayList(archive.Member) = .empty;
    defer {
        for (members.items) |m| gpa.free(m.data);
        members.deinit(gpa);
    }
    for (inputs.items) |path| {
        const data = Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited) catch |e| {
            try err_out.print("bit ar: {s}: {s}\n", .{ path, @errorName(e) });
            return 1;
        };
        try members.append(gpa, .{ .name = std.fs.path.basename(path), .data = data });
    }

    const format: archive.Format = if (target == .aarch64_macos) .bsd else .gnu;
    const bytes = try archive.write(gpa, format, members.items);
    defer gpa.free(bytes);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = out, .data = bytes });
    return 0;
}

/// `bit test <file.bit|dir>`: compiles the module with a synthetic `main` that
/// dispatches to one test (see `testgen.zig`), then execs that binary once per
/// discovered test with `BIT_TEST_INDEX` set. One process per test is what makes
/// a failing `assert` attributable: it panics, so an in-process loop would take
/// the remaining tests down with it.
///
/// Prints `ok`/`FAIL` per test and a summary; exit code 0 iff every test passed.
/// Always builds for the host — a cross-compiled test binary could not be run.
fn runTest(gpa: std.mem.Allocator, io: Io, out: *Io.Writer, err_out: *Io.Writer, environ_map: *std.process.Environ.Map, args: []const [:0]const u8) !u8 {
    const src = if (args.len >= 1) args[0] else {
        try err_out.writeAll("usage: bit test <file.bit|dir>\n");
        return 2;
    };

    const lib = Io.Dir.cwd().readFileAlloc(io, libbitrtPath(host_target), gpa, .unlimited) catch |e| {
        try err_out.print("bit: runtime archive {s}: {s}\n", .{ libbitrtPath(host_target), @errorName(e) });
        return 1;
    };
    defer gpa.free(lib);

    const ident = std.fs.path.stem(src);
    const stat = Io.Dir.cwd().statFile(io, src, .{}) catch |e| {
        try err_out.print("bit: {s}: {s}\n", .{ src, @errorName(e) });
        return 1;
    };

    // Same rule as `bit build` (SPEC §17.1): a lone file is a module of one
    // file, so `bit test math.bit` — the tutorial's form — gets the prelude and
    // `std/testing` like a directory does.
    var tests: []testgen.Test = &.{};
    const root_src = if (stat.kind == .directory) src else std.fs.path.dirname(src) orelse ".";
    const root_only: ?[]const u8 = if (stat.kind == .directory) null else std.fs.path.basename(src);
    const root_abs = try absFromCwd(gpa, io, root_src);
    defer gpa.free(root_abs);
    const std_root: ?[]u8 = absFromCwd(gpa, io, stdlib_dir) catch null;
    defer if (std_root) |s| gpa.free(s);
    const exe = (try buildProject(gpa, io, root_abs, root_only, std_root, ident, lib, host_target, err_out, &tests, false, false)) orelse return 1;
    defer gpa.free(exe);
    defer testgen.freeTests(gpa, tests);

    if (tests.len == 0) {
        try out.print("no tests in {s} (a test is a top-level `function test_<name>()`)\n", .{src});
        return 0;
    }

    // Disambiguated for the same reason as `bit run`'s path above (#1459/#1463):
    // two concurrent `bit test` runs of same-named modules must not write and
    // exec one file.
    const tmp = try std.fmt.allocPrintSentinel(gpa, "/tmp/bit-test-{s}-{x}", .{ ident, scratchNonce(io) }, 0);
    defer gpa.free(tmp);
    try Io.Dir.cwd().writeFile(io, .{
        .sub_path = tmp,
        .data = exe,
        .flags = .{ .permissions = .executable_file },
    });
    defer Io.Dir.cwd().deleteFile(io, tmp) catch {};

    var passed: usize = 0;
    for (tests, 0..) |t, i| {
        var idx_buf: [24]u8 = undefined;
        try environ_map.put("BIT_TEST_INDEX", try std.fmt.bufPrint(&idx_buf, "{d}", .{i}));

        // The child inherits stdio, so its own output and any panic message land
        // before this test's verdict — flush ours first to keep them in order.
        try out.flush();
        var child = try std.process.spawn(io, .{ .argv = &.{tmp}, .environ_map = environ_map });
        const ok = switch (try child.wait(io)) {
            .exited => |c| c == 0,
            else => false, // killed by a signal: a panic, or a crash
        };
        if (ok) passed += 1;
        try out.print("{s} {s}\n", .{ if (ok) "ok  " else "FAIL", t.name });
    }

    const failed = tests.len - passed;
    try out.print("\n{d} test{s}: {d} passed, {d} failed\n", .{ tests.len, if (tests.len == 1) "" else "s", passed, failed });
    return if (failed == 0) 0 else 1;
}

/// Builds `source` into a native executable's bytes for the host target,
/// linking `libbitrt` — the entry the golden `// run` harness uses. Returns
/// `null` (diagnostics written to `err_out`) if compilation failed.
pub fn buildHostExecutable(gpa: std.mem.Allocator, path: []const u8, source: []const u8, libbitrt: []const u8, err_out: *Io.Writer) !?[]u8 {
    return buildExecutable(gpa, path, source, libbitrt, host_target, err_out);
}

/// Like `buildHostExecutable`, but with the `bit test` entry injected: the
/// binary runs the single test named by `BIT_TEST_INDEX`. Writes the discovered
/// tests to `tests_out` (caller frees via `testgen.freeTests`). The `bit test`
/// harness test drives the runner through this.
pub fn buildHostTestExecutable(gpa: std.mem.Allocator, path: []const u8, source: []const u8, libbitrt: []const u8, err_out: *Io.Writer, tests_out: *[]testgen.Test) !?[]u8 {
    const one = [_]SrcFile{.{ .path = path, .source = source }};
    return buildModule(gpa, &one, std.fs.path.stem(path), libbitrt, host_target, err_out, tests_out);
}

/// Runs the front end (parse -> resolve -> check) over a directory module,
/// without lowering or codegen. Returns whether it failed, having rendered the
/// diagnostics to `err_out`.
///
/// This is what the documentation doc-tests need: a snippet is a module, not a
/// program, so it has no `main` to link — but it must still typecheck against
/// the real prelude and the real `std/*`.
pub fn checkHostProject(gpa: std.mem.Allocator, io: Io, root_abs: []const u8, root_only: ?[]const u8, std_root: ?[]const u8, err_out: *Io.Writer) !bool {
    var sm = diagnostics.SourceManager.init(gpa);
    defer sm.deinit();
    var diags = diagnostics.Diagnostics.init(gpa, &sm);
    defer diags.deinit();

    var project = try resolve.loadProject(gpa, io, &diags, &sm, root_abs, root_only, std_root, .{});
    defer project.deinit();
    if (diags.hasErrors()) {
        _ = try renderFail(gpa, &diags, err_out);
        return true;
    }

    const n = project.modules.items.len;
    var ctx = try check.TypeContext.init(gpa);
    defer ctx.deinit();
    const checked = try gpa.alloc(check.CheckedModule, n);
    var checked_built: usize = 0;
    defer {
        for (checked[0..checked_built]) |*c| c.deinit();
        gpa.free(checked);
    }
    for (0..n) |i| {
        checked[i] = try check.checkModule(gpa, &diags, &ctx, project.module_files.items[i], &project.modules.items[i], @enumFromInt(i), project.modules.items, false);
        checked_built += 1;
        if (diags.hasErrors()) {
            _ = try renderFail(gpa, &diags, err_out);
            return true;
        }
    }
    return false;
}

/// `buildHostTestExecutable` for a directory module, so the tests can import
/// `std/testing` and the rest of the stdlib. `null`: this harness always names a
/// project directory, never a lone file (SPEC §17.1).
pub fn buildHostTestProject(gpa: std.mem.Allocator, io: Io, root_abs: []const u8, std_root: ?[]const u8, ident: []const u8, libbitrt: []const u8, err_out: *Io.Writer, tests_out: *[]testgen.Test) !?[]u8 {
    return buildProject(gpa, io, root_abs, null, std_root, ident, libbitrt, host_target, err_out, tests_out, false, false);
}

/// One source file of the module being built: its path (for diagnostics and
/// naming) and contents. Both are owned by whoever produced the `SrcFile`.
const SrcFile = struct { path: []const u8, source: []const u8 };

/// Upper bound on `.bit` files in one module directory — keeps the directory
/// walk provably bounded (Power of 10). Raise if a real module approaches it.
const max_module_files = 1024;

/// Resolves the `bit build`/`run` argument to the module's source files. A
/// directory is the module (SPEC §17.1): every `.bit` file directly inside,
/// sorted by name so the build is deterministic. A plain path is a single-file
/// module. Returns `null` (diagnostics already written to `err_out`) on an I/O
/// error or an empty module directory. The caller owns and frees each
/// `path`/`source` and the returned slice.
fn gatherModule(gpa: std.mem.Allocator, io: Io, src: []const u8, err_out: *Io.Writer) !?[]SrcFile {
    const stat = Io.Dir.cwd().statFile(io, src, .{}) catch |e| {
        try err_out.print("bit: {s}: {s}\n", .{ src, @errorName(e) });
        return null;
    };
    if (stat.kind != .directory) {
        const source = Io.Dir.cwd().readFileAlloc(io, src, gpa, .limited(max_source_bytes)) catch |e| {
            try err_out.print("bit: {s}: {s}\n", .{ src, @errorName(e) });
            return null;
        };
        const out = try gpa.alloc(SrcFile, 1);
        out[0] = .{ .path = try gpa.dupe(u8, src), .source = source };
        return out;
    }

    var dir = Io.Dir.cwd().openDir(io, src, .{ .iterate = true }) catch |e| {
        try err_out.print("bit: {s}: {s}\n", .{ src, @errorName(e) });
        return null;
    };
    defer dir.close(io);

    var list: std.ArrayList(SrcFile) = .empty;
    errdefer {
        for (list.items) |f| {
            gpa.free(f.path);
            gpa.free(f.source);
        }
        list.deinit(gpa);
    }

    var it = dir.iterate();
    var scanned: u32 = 0;
    while (scanned < max_module_files) : (scanned += 1) {
        const entry = (try it.next(io)) orelse break;
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".bit")) continue;

        const path = try std.fs.path.join(gpa, &.{ src, entry.name });
        const source = dir.readFileAlloc(io, entry.name, gpa, .limited(max_source_bytes)) catch |e| {
            try err_out.print("bit: {s}: {s}\n", .{ path, @errorName(e) });
            gpa.free(path);
            return null;
        };
        list.append(gpa, .{ .path = path, .source = source }) catch |e| {
            gpa.free(path);
            gpa.free(source);
            return e;
        };
    }
    std.debug.assert(scanned < max_module_files);

    if (list.items.len == 0) {
        try err_out.print("bit: {s}: no .bit files in module directory\n", .{src});
        list.deinit(gpa);
        return null;
    }

    const out = try list.toOwnedSlice(gpa);
    std.mem.sort(SrcFile, out, {}, lessByPath);
    return out;
}

fn lessByPath(_: void, a: SrcFile, b: SrcFile) bool {
    return std.mem.lessThan(u8, a.path, b.path);
}

/// Directory-or-file module build for the host target — the entry the examples
/// guard uses so it exercises the real `bit build <dir>` path (gather + parse +
/// resolve/check/lower over the whole directory), not just a single file. A
/// directory is a module (SPEC §17.1). Returns `null` (diagnostics written to
/// `err_out`) on an I/O or compile error.
pub fn buildHostModule(gpa: std.mem.Allocator, io: Io, path: []const u8, libbitrt: []const u8, err_out: *Io.Writer) !?[]u8 {
    const inputs = (try gatherModule(gpa, io, path, err_out)) orelse return null;
    defer {
        for (inputs) |f| {
            gpa.free(f.path);
            gpa.free(f.source);
        }
        gpa.free(inputs);
    }
    return buildModule(gpa, inputs, std.fs.path.stem(path), libbitrt, host_target, err_out, null);
}

/// Whole-project build for the host target — the entry the imports/prelude
/// harness uses so it exercises the real multi-module pipeline (`loadProject` +
/// per-module check + `lowerProject`). `root_abs`/`std_root` must be absolute
/// (`std_root` null for no stdlib). Returns `null` (diagnostics to `err_out`) on
/// any front-end error.
pub fn buildHostProject(gpa: std.mem.Allocator, io: Io, root_abs: []const u8, std_root: ?[]const u8, ident: []const u8, libbitrt: []const u8, err_out: *Io.Writer) !?[]u8 {
    // `null`: this harness always names a project directory, never a lone file.
    return buildProject(gpa, io, root_abs, null, std_root, ident, libbitrt, host_target, err_out, null, false, false);
}

/// Single-file convenience entry (the golden `// run` harness uses this): one
/// buffer, one module. Delegates to `buildModule`.
fn buildExecutable(gpa: std.mem.Allocator, path: []const u8, source: []const u8, libbitrt: []const u8, target: BuildTarget, err_out: *Io.Writer) !?[]u8 {
    const one = [_]SrcFile{.{ .path = path, .source = source }};
    return buildModule(gpa, &one, std.fs.path.stem(path), libbitrt, target, err_out, null);
}

/// Absolute path of `rel` (an existing file/dir) resolved against the process
/// cwd. Callers own the result. `loadProject` and the `std/*` root both need
/// absolute paths (the module loader uses `openDirAbsolute`); the CLI hands us
/// cwd-relative paths. Errors if `rel` does not exist.
/// `bit doc [--json] <module-dir>`: the module's exported symbols, derived from
/// the checker rather than from a list somebody has to remember to update.
/// Returns `true` iff the module failed to compile.
fn runDoc(gpa: std.mem.Allocator, io: Io, out: *Io.Writer, err_out: *Io.Writer, args: []const [:0]const u8) !bool {
    var rest = args;
    var as_json = false;
    if (rest.len >= 1 and std.mem.eql(u8, rest[0], "--json")) {
        as_json = true;
        rest = rest[1..];
    }
    if (rest.len != 1) {
        try err_out.writeAll("usage: bit doc [--json] <module-dir>\n");
        return true;
    }

    const root_abs = try absFromCwd(gpa, io, rest[0]);
    defer gpa.free(root_abs);
    const std_root: ?[]u8 = absFromCwd(gpa, io, stdlib_dir) catch null;
    defer if (std_root) |s| gpa.free(s);

    var d = (try doc.moduleDoc(gpa, io, root_abs, std_root, err_out)) orelse return true;
    defer d.deinit();

    if (as_json) {
        try doc.writeJson(d, out);
        return false;
    }
    for (d.symbols) |s| try out.print("{s} {s} {s}\n", .{ s.kind.text(), s.name, s.type_text });
    return false;
}

fn absFromCwd(gpa: std.mem.Allocator, io: Io, rel: []const u8) ![]u8 {
    const abs = try Io.Dir.cwd().realPathFileAlloc(io, rel, gpa);
    defer gpa.free(abs);
    return gpa.dupe(u8, abs);
}

/// Builds a whole project — a root module directory plus every module it
/// imports (relative `./` and `std/*`) — into a native executable. Loads the
/// import graph (`resolve.loadProject`), type-checks every module in dependency
/// order into one shared `TypeContext`, lowers the whole graph into one
/// `ir.Module` (`lower.lowerProject`), then codegens + links. `root_abs` and
/// `std_root` must be absolute (or `std_root` null for no stdlib). Returns
/// `null` (diagnostics rendered to `err_out`) on any front-end error.
/// With `emit_obj`, stops one step short: returns the relocatable object itself
/// instead of a linked executable, requires no `main`, and never touches
/// `libbitrt` (#1397 — the archive-member path).
pub fn buildProject(gpa: std.mem.Allocator, io: Io, root_abs: []const u8, root_only: ?[]const u8, std_root: ?[]const u8, ident: []const u8, libbitrt: []const u8, target: BuildTarget, err_out: *Io.Writer, tests_out: ?*[]testgen.Test, emit_obj: bool, freestanding: bool) !?[]u8 {
    // §17.6 is an object-only mode; the caller rejects the other combination.
    std.debug.assert(!freestanding or emit_obj);
    var sm = diagnostics.SourceManager.init(gpa);
    defer sm.deinit();
    var diags = diagnostics.Diagnostics.init(gpa, &sm);
    defer diags.deinit();

    var project = try resolve.loadProject(gpa, io, &diags, &sm, root_abs, root_only, std_root, .{});
    defer project.deinit();
    if (diags.hasErrors()) return try renderFail(gpa, &diags, err_out);

    const n = project.modules.items.len;
    std.debug.assert(n >= 1);

    // Check every module in dependency order (loaded imports-first, so index
    // order suffices) into one shared TypeContext — cross-module type info
    // accumulates as module-qualified keys the lowerer then reads.
    var ctx = try check.TypeContext.init(gpa);
    defer ctx.deinit();
    const checked = try gpa.alloc(check.CheckedModule, n);
    var checked_built: usize = 0;
    defer {
        for (checked[0..checked_built]) |*c| c.deinit();
        gpa.free(checked);
    }
    for (0..n) |i| {
        checked[i] = try check.checkModule(gpa, &diags, &ctx, project.module_files.items[i], &project.modules.items[i], @enumFromInt(i), project.modules.items, false);
        checked_built += 1;
        if (diags.hasErrors()) return try renderFail(gpa, &diags, err_out);
    }

    {
        var rejected = false;
        for (0..n) |i| {
            if (try rejectExternForTarget(gpa, &diags, project.module_files.items[i], target, libbitrt)) rejected = true;
        }
        if (rejected) return try renderFail(gpa, &diags, err_out);
    }

    const inputs = try gpa.alloc(lower.ModuleInput, n);
    defer gpa.free(inputs);
    for (0..n) |i| inputs[i] = .{ .files = project.module_files.items[i], .checked = &checked[i], .rmodule = &project.modules.items[i] };

    var module = try lower.lowerProject(gpa, &ctx, inputs, project.root);
    defer module.deinit();
    if (tests_out) |out| out.* = try testgen.injectTestMain(gpa, &module);
    try opt.optimizeModule(gpa, &module, .o1);

    switch (target) {
        .x86_64_linux => {
            const object = emit.emitObject(gpa, &module, !emit_obj, freestanding) catch |e| switch (e) {
                error.FreestandingAlloc, error.FreestandingUnpinned => return try freestandingRefused(err_out, e, &module),
                else => return e,
            };
            if (emit_obj) return object;
            defer gpa.free(object);
            return try link.linkExecutable(gpa, .x86_64_linux, &.{ .{ .object = object }, .{ .archive = libbitrt } });
        },
        .aarch64_linux => {
            const object = emit.emitObjectArm64Elf(gpa, &module, !emit_obj, freestanding) catch |e| switch (e) {
                error.FreestandingAlloc, error.FreestandingUnpinned => return try freestandingRefused(err_out, e, &module),
                else => return e,
            };
            if (emit_obj) return object;
            defer gpa.free(object);
            return try link.linkExecutable(gpa, .aarch64_linux, &.{ .{ .object = object }, .{ .archive = libbitrt } });
        },
        .aarch64_macos => {
            // §11.8: `syscall()` has no Darwin encoding — report it as a
            // diagnostic (exit 1), not a raw propagated error.
            const object = emit.emitMachoObject(gpa, &module, !emit_obj, freestanding) catch |e| switch (e) {
                error.SyscallUnsupportedTarget => return try syscallUnsupported(err_out),
                error.FreestandingAlloc, error.FreestandingUnpinned => return try freestandingRefused(err_out, e, &module),
                else => return e,
            };
            if (emit_obj) return object;
            defer gpa.free(object);
            return try machoLink(gpa, err_out, &module, object, libbitrt, ident);
        },
    }
}

/// Drives a module's source files through the whole compiler — front-end
/// (parse each file, then resolve + check the files as one namespace), then
/// lower -> optimize -> codegen/object -> link — into a runnable executable's
/// bytes. `ident` names the produced object. Returns `null` (after rendering
/// diagnostics to `err_out`) if any stage before codegen reported an error;
/// the caller maps that to exit code 1.
fn buildModule(gpa: std.mem.Allocator, inputs: []const SrcFile, ident: []const u8, libbitrt: []const u8, target: BuildTarget, err_out: *Io.Writer, tests_out: ?*[]testgen.Test) !?[]u8 {
    std.debug.assert(inputs.len >= 1);

    var sm = diagnostics.SourceManager.init(gpa);
    defer sm.deinit();
    var diags = diagnostics.Diagnostics.init(gpa, &sm);
    defer diags.deinit();

    const trees = try gpa.alloc(ast.Tree, inputs.len);
    var trees_built: usize = 0;
    defer {
        for (trees[0..trees_built]) |*t| t.deinit();
        gpa.free(trees);
    }
    const files = try gpa.alloc(resolve.ModuleFile, inputs.len);
    defer gpa.free(files);

    for (inputs, 0..) |in, i| {
        const file = try sm.addFile(in.path, in.source);
        trees[i] = try ast.Tree.init(gpa);
        trees_built += 1;
        try parser.parse(gpa, &trees[i], &diags, file, in.source);
        files[i] = .{ .file = file, .source = in.source, .tree = &trees[i] };
    }

    var no_imports: resolve.ImportTable = .{};
    defer no_imports.deinit(gpa);

    if (diags.hasErrors()) return try renderFail(gpa, &diags, err_out);

    var rmodule = try resolve.resolveModule(gpa, &diags, files, &no_imports, &.{}, null);
    defer rmodule.deinit();
    if (diags.hasErrors()) return try renderFail(gpa, &diags, err_out);

    var ctx = try check.TypeContext.init(gpa);
    defer ctx.deinit();
    var checked = try check.checkModule(gpa, &diags, &ctx, files, &rmodule, @enumFromInt(0), &.{}, false);
    defer checked.deinit();
    if (diags.hasErrors()) return try renderFail(gpa, &diags, err_out);

    if (try rejectExternForTarget(gpa, &diags, files, target, libbitrt)) return try renderFail(gpa, &diags, err_out);

    var module = try lower.lowerModule(gpa, &ctx, files, &checked, &rmodule);
    defer module.deinit();
    if (tests_out) |out| out.* = try testgen.injectTestMain(gpa, &module);
    try opt.optimizeModule(gpa, &module, .o1);

    switch (target) {
        .x86_64_linux => {
            const object = try emit.emitObject(gpa, &module, true, false);
            defer gpa.free(object);
            return try link.linkExecutable(gpa, .x86_64_linux, &.{ .{ .object = object }, .{ .archive = libbitrt } });
        },
        .aarch64_linux => {
            const object = try emit.emitObjectArm64Elf(gpa, &module, true, false);
            defer gpa.free(object);
            return try link.linkExecutable(gpa, .aarch64_linux, &.{ .{ .object = object }, .{ .archive = libbitrt } });
        },
        .aarch64_macos => {
            // §11.8: `syscall()` has no Darwin encoding — report it as a
            // diagnostic (exit 1), not a raw propagated error.
            const object = emit.emitMachoObject(gpa, &module, true, false) catch |e| switch (e) {
                error.SyscallUnsupportedTarget => return try syscallUnsupported(err_out),
                else => return e,
            };
            defer gpa.free(object);
            return try machoLink(gpa, err_out, &module, object, libbitrt, ident);
        },
    }
}

/// §11.7: `extern function` binds a Bit name to a raw external symbol. On
/// Mach-O that symbol is bound by dyld at load time and anything is admissible.
/// Bit's ELF output has no load-time resolution at all — no interpreter, no
/// dynamic symbol table, no libc — but that is not the same as no resolution:
/// the static link already merges `libbitrt.a`, and a symbol **defined inside
/// that archive** resolves through the very same global symbol table as the
/// runtime's own calls.
///
/// So the predicate is archive membership, not the platform. A symbol present
/// in the archive is accepted; one that is absent is still rejected here, with
/// a real diagnostic naming it, rather than failing deep inside the linker.
/// `libbitrt` empty (`bit build-obj`, which reads no archive) means membership
/// is undecidable, and an undecided case must REJECT — accepting on unknown
/// would trade a compile error for a link error or a silent crash.
///
/// The gate lives here, not in the checker, because the checker is deliberately
/// target-independent (it runs once and its output feeds every backend); this
/// is the first point where the selected target and the AST are both in hand,
/// and the archive path is a pure function of the target. Returns true if
/// anything was rejected.
fn rejectExternForTarget(gpa: std.mem.Allocator, diags: *diagnostics.Diagnostics, files: []const resolve.ModuleFile, target: BuildTarget, libbitrt: []const u8) !bool {
    if (target == .aarch64_macos) return false;
    const link_target: link.Target = switch (target) {
        .x86_64_linux => .x86_64_linux,
        .aarch64_linux => .aarch64_linux,
        .aarch64_macos => unreachable,
    };
    var found = false;
    for (files) |mf| {
        for (mf.tree.kids(mf.tree.root)) |top| {
            if (top == ast.none) continue;
            const inner = if (mf.tree.get(top).tag == .@"export") mf.tree.kids(top)[0] else top;
            if (mf.tree.get(inner).tag != .extern_fn_decl) continue;
            // §11.7: an extern's Bit name IS the symbol, verbatim and never
            // module-qualified, so the declaration's identifier is exactly what
            // the linker will look for.
            const name_node = mf.tree.kids(inner)[0];
            const name_span = mf.tree.get(name_node).span;
            const symbol = mf.source[name_span.start..name_span.end];
            if (link.archiveDefines(gpa, link_target, libbitrt, symbol)) continue;

            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "'extern function' {s} is not defined in the runtime archive for target {s}", .{ symbol, target.name() }) catch "'extern function': undefined symbol for this target";
            try diags.report(.extern_unsupported_target, mf.tree.get(inner).span, msg, "the Linux output is fully static: only a symbol already inside libbitrt.a can be resolved");
            found = true;
        }
    }
    return found;
}

/// The §11.8 Darwin rejection, rendered like any other build failure: a
/// message plus a `null` result, which the caller maps to exit code 1.
/// The Mach-O link, with #1445's undefined-symbol gate wired up: the program's
/// §11.7 `extern function` declarations are the only names it may legitimately
/// leave for dyld, and anything else it leaves undefined is refused here with
/// the symbol and the referencing module named.
///
/// Returns `null` (having printed) when the link is refused, mirroring every
/// other build failure in this file.
fn machoLink(
    gpa: std.mem.Allocator,
    err_out: *Io.Writer,
    module: *const ir.Module,
    object: []const u8,
    libbitrt: []const u8,
    ident: []const u8,
) !?[]u8 {
    const allowed = try emit.externImportNames(gpa, module);
    defer {
        for (allowed) |n| gpa.free(n);
        gpa.free(allowed);
    }

    var undef: macho.UndefinedRef = .{ .symbol = "?", .referenced_from = "?" };
    return macho.link(gpa, &.{ .{ .object = object }, .{ .archive = libbitrt } }, .{
        .identifier = ident,
        .allowed_imports = allowed,
        .undefined_out = &undef,
    }) catch |e| switch (e) {
        error.UndefinedSymbol => {
            try err_out.print(
                "bit: undefined symbol '{s}', referenced from {s}\n" ++
                    "bit: nothing in the link set defines it and no 'extern function' declares it, so this is a compiler bug rather than a missing library (SPEC \xc2\xa711.7)\n",
                .{ undef.symbol, undef.referenced_from },
            );
            return null;
        },
        else => return e,
    };
}

fn syscallUnsupported(err_out: *Io.Writer) !?[]u8 {
    try err_out.writeAll("bit: 'syscall' is not supported on aarch64-macos: Darwin publishes no stable syscall numbers (SPEC \xc2\xa711.8)\n");
    return null;
}

/// §17.6: a freestanding object contributes code and nothing else to a link —
/// it carries no GC type descriptors and no stack-map table, because both are
/// whole-program tables that exactly one object may define. Code that would
/// need either is refused here rather than emitted without it, which would be
/// silent wrongness: an allocation with no descriptor, or a frame the collector
/// cannot scan.
fn freestandingRefused(err_out: *Io.Writer, e: anyerror, module: *const ir.Module) !?[]u8 {
    // §11.9: naming the callee is what makes this one actionable — the fix is
    // to add `@symbol` to THAT declaration, and a runtime module makes enough
    // cross-module calls that "some import is unpinned" would not locate it.
    if (e == error.FreestandingUnpinned) {
        const name = emit.firstUnpinnedImport(module) orelse "?";
        try err_out.print("bit: --freestanding: this module references '{s}', a mangled cross-module symbol no sibling object can define; every runtime function another module calls must be pinned with @symbol (SPEC \xc2\xa711.9, ABI.md \xc2\xa79)\n", .{name});
        return null;
    }
    const why = switch (e) {
        error.FreestandingAlloc => "allocates on the managed heap (a struct, slice, string or closure value)",
        else => "has a function that is neither @nosplit nor @naked; freestanding code carries no GC stack maps (SPEC \xc2\xa710.3)",
    };
    try err_out.print("bit: --freestanding: this module {s}\n", .{why});
    return null;
}

fn renderFail(gpa: std.mem.Allocator, diags: *diagnostics.Diagnostics, err_out: *Io.Writer) !?[]u8 {
    var rendered: Io.Writer.Allocating = .init(gpa);
    defer rendered.deinit();
    try diags.renderAll(&rendered.writer);
    try err_out.writeAll(rendered.written());
    return null;
}

/// `bit fmt [--check] <path>...`: reformats each file to Bit's one canonical
/// style, rewriting it in place only when the canonical text differs (idempotent:
/// an already-canonical file is never touched). A file that fails to parse
/// is left untouched and its diagnostics are rendered to `err_out`; returns
/// `true` iff any file failed, so the caller can pick a nonzero exit code —
/// every remaining path is still attempted, matching gofmt's per-file
/// independence.
///
/// `--check` writes nothing and instead names every file that is not already
/// canonical, failing if any is. Without it there is no way to *gate* on format:
/// a CI step that ran the rewriting form would quietly reformat its checkout and
/// then report success, which is the opposite of enforcement (cf. `gofmt -l`,
/// `zig fmt --check`).
fn runFmt(gpa: std.mem.Allocator, io: Io, err_out: *Io.Writer, args: []const [:0]const u8) !bool {
    var any_failed = false;
    var check_only = false;
    var paths = args;
    if (paths.len > 0 and std.mem.eql(u8, paths[0], "--check")) {
        check_only = true;
        paths = paths[1..];
    }
    for (paths) |path| {
        const source = Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(max_fmt_file_bytes)) catch |e| {
            try err_out.print("bit fmt: {s}: {s}\n", .{ path, @errorName(e) });
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
        if (check_only) {
            try err_out.print("{s}\n", .{path});
            any_failed = true;
            continue;
        }
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = result.text });
    }
    return any_failed;
}

/// `bit check [--dump-types] <path>...`: type-checks each path independently.
/// A directory is a whole project (prelude + std imports, cross-module) via
/// `checkHostProject`, matching `bit build <dir>`; a plain file is its own
/// single-file module (matches `compileReport`'s scope). Diagnostics go to
/// `err_out`; with `dump_types`, a clean file's inferred types print to `out`
/// instead of producing no output — `--dump-types` is single-file only and is
/// rejected on a directory. Returns `true` iff any path failed, mirroring
/// `runFmt`'s per-path-independence contract.
fn runCheck(gpa: std.mem.Allocator, io: Io, out: *Io.Writer, err_out: *Io.Writer, dump_types: bool, paths: []const [:0]const u8) !bool {
    var any_failed = false;
    for (paths) |path| {
        // A directory is a project (prelude + std imports), so it takes the
        // whole-project front-end like `bit build <dir>`; only a plain file
        // goes through the single-file report path. `--dump-types` has no
        // project form yet — it dumps single files only (see --help).
        const stat = Io.Dir.cwd().statFile(io, path, .{}) catch |e| {
            try err_out.print("bit check: {s}: {s}\n", .{ path, @errorName(e) });
            any_failed = true;
            continue;
        };
        if (stat.kind == .directory) {
            if (dump_types) {
                try err_out.print("bit check: {s}: --dump-types applies to single files, not projects\n", .{path});
                any_failed = true;
                continue;
            }
            const root_abs = try absFromCwd(gpa, io, path);
            defer gpa.free(root_abs);
            const std_root: ?[]u8 = absFromCwd(gpa, io, stdlib_dir) catch null;
            defer if (std_root) |s| gpa.free(s);
            if (try checkHostProject(gpa, io, root_abs, null, std_root, err_out)) any_failed = true;
            continue;
        }

        // A lone file is a module too (SPEC §17.1), and `check` is `build`'s
        // front end — so it takes the same path and sees the same prelude. If it
        // did not, `bit check hello.bit` would reject the very program
        // `bit build hello.bit` compiles.
        if (!dump_types) {
            const root_abs = try absFromCwd(gpa, io, std.fs.path.dirname(path) orelse ".");
            defer gpa.free(root_abs);
            const std_root: ?[]u8 = absFromCwd(gpa, io, stdlib_dir) catch null;
            defer if (std_root) |s| gpa.free(s);
            if (try checkHostProject(gpa, io, root_abs, std.fs.path.basename(path), std_root, err_out)) any_failed = true;
            continue;
        }

        // `--dump-types` stays a single-file, prelude-free front-end dump: it is
        // a self-host differential surface (scripts/selfhost-difftypes.sh), not a
        // user-facing check, and both compilers must render it identically.
        const source = Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(max_fmt_file_bytes)) catch |e| {
            try err_out.print("bit check: {s}: {s}\n", .{ path, @errorName(e) });
            any_failed = true;
            continue;
        };
        defer gpa.free(source);

        const report = try typesReport(gpa, path, source);
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

/// `bit --dump-<mode> <file.bit>`: prints one front-end dump to stdout, or the
/// rendered diagnostics to stderr on a front-end error. Each mode is a
/// deterministic, canonical rendering used by the self-host differential
/// harness. Returns `true` on any failure (usage, I/O, or a front-end error).
fn runDump(gpa: std.mem.Allocator, io: Io, out: *Io.Writer, err_out: *Io.Writer, mode: []const u8, paths: []const [:0]const u8) !bool {
    if (paths.len == 0) {
        try err_out.print("usage: bit {s} <file.bit>\n", .{mode});
        return true;
    }
    const source = Io.Dir.cwd().readFileAlloc(io, paths[0], gpa, .limited(max_fmt_file_bytes)) catch |e| {
        try err_out.print("bit {s}: {s}: {s}\n", .{ mode, paths[0], @errorName(e) });
        return true;
    };
    defer gpa.free(source);

    // `parseReport`/`tokensReport`/... each return a `{ text, failed }` of a
    // distinct nominal type, so extract the two fields per branch rather than
    // unify the type.
    var text: []u8 = undefined;
    var failed: bool = undefined;
    if (std.mem.eql(u8, mode, "--dump-tokens")) {
        const r = try tokensReport(gpa, paths[0], source);
        text = r.text;
        failed = r.failed;
    } else if (std.mem.eql(u8, mode, "--dump-ast")) {
        const r = try parseReport(gpa, paths[0], source);
        text = r.text;
        failed = r.failed;
    } else if (std.mem.eql(u8, mode, "--dump-types")) {
        const r = try typesReport(gpa, paths[0], source);
        text = r.text;
        failed = r.failed;
    } else if (std.mem.eql(u8, mode, "--dump-ir")) {
        const r = try irReport(gpa, paths[0], source, true);
        text = r.text;
        failed = r.failed;
    } else if (std.mem.eql(u8, mode, "--dump-ir-pre")) {
        const r = try irReport(gpa, paths[0], source, false);
        text = r.text;
        failed = r.failed;
    } else if (std.mem.eql(u8, mode, "--dump-diags")) {
        // Front-end (lex + parse) diagnostics only — the payload, not a failure
        // channel — so it always goes to stdout (exit 0) for the self-host error
        // differential against `bit2 --dump-diags`.
        const r = try diagsReport(gpa, paths[0], source);
        text = r.text;
        failed = false;
    } else {
        try err_out.print("bit: unknown dump mode '{s}' (--dump-tokens|--dump-ast|--dump-types|--dump-ir|--dump-ir-pre|--dump-diags)\n", .{mode});
        return true;
    }
    defer gpa.free(text);

    if (failed) {
        try err_out.writeAll(text);
        return true;
    }
    try out.writeAll(text);
    return false;
}

/// Front-end (lexer + parser) diagnostics for a single source buffer, always
/// rendered (empty on a clean file). Backs `--dump-diags` for the self-host
/// Stage-1 error differential: `bit2` implements only the front-end, so this
/// deliberately stops before resolve/check (whose diagnostics `bit2` cannot
/// yet reproduce). `text` is owned by `gpa`.
pub fn diagsReport(gpa: std.mem.Allocator, path: []const u8, source: []const u8) !CompileReport {
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

        var module = try resolve.resolveModule(gpa, &diags, &files, &no_imports, &.{}, null);
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
/// success) — the `bit check --dump-types` positive-suite surface named by
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

        var module = try resolve.resolveModule(gpa, &diags, &files, &no_imports, &.{}, null);
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

/// Lexes `source` and renders one token per line — `<kind> <start>..<end>` —
/// including the lexer's ASI-synthesized `;` tokens (§7), so the dump is
/// exactly the stream the parser consumes. Deterministic (kind + byte span
/// only, no pointers), which is what the self-host differential harness diffs
/// the Zig and Bit lexers on. `failed` is true iff the lexer emitted any
/// error-severity diagnostic. `text` is owned by `gpa`.
pub fn tokensReport(gpa: std.mem.Allocator, path: []const u8, source: []const u8) !CompileReport {
    var sm = diagnostics.SourceManager.init(gpa);
    defer sm.deinit();
    const file = try sm.addFile(path, source);
    var diags = diagnostics.Diagnostics.init(gpa, &sm);
    defer diags.deinit();

    var lx = lexer.Lexer.init(file, source, &diags);
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    // Bounded (Power of 10): every `next()` either advances past a source byte
    // or is an ASI/eof synthesis; a semicolon can be inserted per line, so the
    // token count cannot exceed twice the byte length plus the final eof.
    const bound = source.len * 2 + 2;
    var guard: usize = 0;
    while (guard <= bound) : (guard += 1) {
        const tok = try lx.next();
        try out.writer.print("{s} {d}..{d}\n", .{ @tagName(tok.kind), tok.span.start, tok.span.end });
        if (tok.kind == .eof) break;
    }
    return .{ .text = try gpa.dupe(u8, out.written()), .failed = diags.hasErrors() };
}

/// Drives the front-end through lowering (and, when `optimize`, the optimizer)
/// and renders the SSA IR (`ir.dump`) — the self-host stage-2 differential
/// surface. On any front-end diagnostic, returns the rendered diagnostics with
/// `failed = true` instead. `text` is owned by `gpa`.
pub fn irReport(gpa: std.mem.Allocator, path: []const u8, source: []const u8, optimize: bool) !CompileReport {
    var sm = diagnostics.SourceManager.init(gpa);
    defer sm.deinit();
    const file = try sm.addFile(path, source);
    var diags = diagnostics.Diagnostics.init(gpa, &sm);
    defer diags.deinit();

    var tree = try ast.Tree.init(gpa);
    defer tree.deinit();
    try parser.parse(gpa, &tree, &diags, file, source);

    fail: {
        if (diags.hasErrors()) break :fail;
        const mf = resolve.ModuleFile{ .file = file, .source = source, .tree = &tree };
        var no_imports: resolve.ImportTable = .{};
        defer no_imports.deinit(gpa);
        const files = [_]resolve.ModuleFile{mf};

        var rmodule = try resolve.resolveModule(gpa, &diags, &files, &no_imports, &.{}, null);
        defer rmodule.deinit();
        if (diags.hasErrors()) break :fail;

        var ctx = try check.TypeContext.init(gpa);
        defer ctx.deinit();
        var checked = try check.checkModule(gpa, &diags, &ctx, &files, &rmodule, @enumFromInt(0), &.{}, false);
        defer checked.deinit();
        if (diags.hasErrors()) break :fail;

        var module = try lower.lowerModule(gpa, &ctx, &files, &checked, &rmodule);
        defer module.deinit();
        if (optimize) try opt.optimizeModule(gpa, &module, .o1);
        return .{ .text = try ir.dump(gpa, &module), .failed = false };
    }

    var rendered: Io.Writer.Allocating = .init(gpa);
    defer rendered.deinit();
    try diags.renderAll(&rendered.writer);
    return .{ .text = try gpa.dupe(u8, rendered.written()), .failed = true };
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
    // `#` is the stray byte here: `@` became a real token with §10.3.1 attributes.
    const report = try compileReport(gpa, "t.bit", "let x = #\n");
    defer gpa.free(report.text);
    try std.testing.expect(report.failed);
    try std.testing.expectEqualStrings(
        "error[E0001]: unexpected character '#'\n" ++
            " --> t.bit:1:9\n" ++
            "  |\n" ++
            "1 | let x = #\n" ++
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

test "check routes a directory to the project checker (#1156)" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const cwd = Io.Dir.cwd();

    // A directory used to fail with `IsDir` before it ever reached the checker.
    //
    // Disambiguated (#1459): two concurrent build trees otherwise share one
    // directory, and each `deleteTree`s it out from under the other. The nonce
    // is on TOP of `random_seed` because this is the one fixture where a seed
    // collision is not merely unlikely-and-harmless: unlike the exec paths,
    // which are additionally protected by write-then-rename, two runs here
    // genuinely destroy each other's tree. Measured — with the seed alone this
    // was the sole surviving casualty of a deliberately same-seeded pair.
    const dir = try std.fmt.allocPrintSentinel(gpa, "/tmp/bit-check-dir-test-{x}-{x}", .{ std.testing.random_seed, scratchNonce(io) }, 0);
    defer gpa.free(dir);
    cwd.deleteTree(io, dir) catch {};
    try cwd.createDirPath(io, dir);
    defer cwd.deleteTree(io, dir) catch {};
    const main_path = try std.fmt.allocPrint(gpa, "{s}/main.bit", .{dir});
    defer gpa.free(main_path);

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var err: Io.Writer.Allocating = .init(gpa);
    defer err.deinit();

    // Clean project: exits ok, no diagnostics.
    try cwd.writeFile(io, .{ .sub_path = main_path, .data = "function main() {\n  print(\"ok\")\n}\n" });
    try std.testing.expect(!try runCheck(gpa, io, &out.writer, &err.writer, false, &.{dir}));
    try std.testing.expectEqualStrings("", err.written());

    // Same directory with a type error: fails with the located E-code, proving
    // the directory reached the real checker rather than dying on `IsDir`.
    err.clearRetainingCapacity();
    try cwd.writeFile(io, .{ .sub_path = main_path, .data = "function main() {\n  let x: i64 = \"nope\"\n  print(x)\n}\n" });
    try std.testing.expect(try runCheck(gpa, io, &out.writer, &err.writer, false, &.{dir}));
    try std.testing.expect(std.mem.indexOf(u8, err.written(), "E0041") != null);

    // --dump-types stays single-file only: a directory is rejected, not crashed.
    err.clearRetainingCapacity();
    try std.testing.expect(try runCheck(gpa, io, &out.writer, &err.writer, true, &.{dir}));
    try std.testing.expect(std.mem.indexOf(u8, err.written(), "single files") != null);
}

test "build: a printing program compiles, links, and runs" {
    if (builtin.cpu.arch != .x86_64 or builtin.os.tag != .linux) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const lib = Io.Dir.cwd().readFileAlloc(io, libbitrtPath(.x86_64_linux), gpa, .unlimited) catch
        return error.SkipZigTest; // `zig build libbitrt` not run here
    defer gpa.free(lib);

    var discard: Io.Writer.Allocating = .init(gpa);
    defer discard.deinit();
    const src = "function main() {\n  print(\"hi from bit\")\n}\n";
    const exe = (try buildExecutable(gpa, "e2e.bit", src, lib, .x86_64_linux, &discard.writer)) orelse return error.CompileFailed;
    defer gpa.free(exe);

    // Disambiguated and published by rename, for the reasons on `linkAndRun`
    // in seed/link.zig (#1459): a fixed name that is written and then exec'd is
    // a clobber/ETXTBSY hazard between concurrent build trees.
    const path = try std.fmt.allocPrintSentinel(gpa, "/tmp/bit-e2e-test-{x}", .{std.testing.random_seed}, 0);
    defer gpa.free(path);
    const staging = try std.fmt.allocPrintSentinel(gpa, "{s}.staging", .{path}, 0);
    defer gpa.free(staging);
    try Io.Dir.cwd().writeFile(io, .{
        .sub_path = staging,
        .data = exe,
        .flags = .{ .permissions = .executable_file },
    });
    try Io.Dir.cwd().rename(staging, Io.Dir.cwd(), path, io);
    defer Io.Dir.cwd().deleteFile(io, path) catch {};

    const result = try std.process.run(gpa, io, .{ .argv = &.{path} });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    try std.testing.expectEqual(@as(u8, 0), switch (result.term) {
        .exited => |c| c,
        else => 1,
    });
    try std.testing.expectEqualStrings("hi from bit", result.stdout);
}

test "run of a foreign target refuses instead of dropping a binary in the cwd (#1463)" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const cwd = Io.Dir.cwd();

    // A cross target that is definitely not this host, whichever host this is.
    const foreign: BuildTarget = if (host_target == .aarch64_macos) .x86_64_linux else .aarch64_macos;

    // The stem is what the old code used as the cwd destination, so a
    // regression drops a file at exactly this name next to the test runner.
    // Unique per run so a leftover from another worktree cannot mask it.
    const stem = try std.fmt.allocPrint(gpa, "bit-runlitter-{x}", .{std.testing.random_seed});
    defer gpa.free(stem);
    const dir = try std.fmt.allocPrint(gpa, "/tmp/{s}", .{stem});
    defer gpa.free(dir);
    const dir_z = try std.fmt.allocPrintSentinel(gpa, "{s}", .{dir}, 0);
    defer gpa.free(dir_z);

    cwd.deleteTree(io, dir) catch {};
    try cwd.createDirPath(io, dir);
    defer cwd.deleteTree(io, dir) catch {};
    const main_bit = try std.fmt.allocPrint(gpa, "{s}/main.bit", .{dir});
    defer gpa.free(main_bit);
    try cwd.writeFile(io, .{ .sub_path = main_bit, .data = "function main() {\n  print(\"x\")\n}\n" });

    var err: Io.Writer.Allocating = .init(gpa);
    defer err.deinit();

    const target_z = try std.fmt.allocPrintSentinel(gpa, "{s}", .{@tagName(foreign)}, 0);
    defer gpa.free(target_z);
    // `--target` takes the CLI spelling (dashes), not the enum tag.
    const target_cli = try std.fmt.allocPrintSentinel(gpa, "{s}", .{switch (foreign) {
        .x86_64_linux => "x86_64-linux",
        .aarch64_linux => "aarch64-linux",
        .aarch64_macos => "aarch64-macos",
    }}, 0);
    defer gpa.free(target_cli);

    const rc = try runBuildOrRun(gpa, io, &err.writer, true, &.{ dir_z, "--target", target_cli });

    // The actual point of the ticket FIRST: nothing was written to the cwd.
    // The old code built the program and wrote it here under `stem`.
    try std.testing.expectError(error.FileNotFound, cwd.statFile(io, stem, .{}));

    // Refused, and said why. Kept as a second assertion because it holds even
    // on a host with no cross-target libbitrt, where the mutated code would
    // fail to build rather than litter — the refusal must be a decision, not an
    // accident of a missing runtime archive.
    try std.testing.expectEqual(@as(u8, 2), rc);
    try std.testing.expect(std.mem.indexOf(u8, err.written(), "bit build") != null);
}

/// A symbol no runtime will ever export, used as the negative pole of the
/// §11.7 gate below. Deliberately `bit_rt_`-prefixed: if the predicate ever
/// degraded into a prefix match rather than real archive membership, a name
/// outside that namespace would still be rejected and the test would pass for
/// the wrong reason.
const absent_symbol = "bit_rt_no_such_symbol_exists_anywhere";

test "E0078 admits a runtime-archive symbol on Linux and still rejects an absent one" {
    // SPEC §11.7. The rule under test is ARCHIVE MEMBERSHIP, not the platform:
    // a fully static ELF has no load-time resolution, but the static link does
    // already merge `libbitrt.a`, and a symbol defined inside it resolves like
    // any other cross-module reference.
    //
    // Both directions are asserted over the SAME target and the SAME archive,
    // so neither can pass by accident: a gate that always rejected would fail
    // the first half, and one that always accepted would fail the second. Run
    // for both Linux triples, because the archive is read per-target and a
    // reader bug on one arch is exactly the class this project keeps paying for.
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var checked: usize = 0;
    for ([_]BuildTarget{ .x86_64_linux, .aarch64_linux }) |target| {
        const lib = Io.Dir.cwd().readFileAlloc(io, libbitrtPath(target), gpa, .unlimited) catch
            continue; // `zig build libbitrt` not run for this target here
        defer gpa.free(lib);
        checked += 1;

        // --- accepted: defined in libbitrt.a, so the link can resolve it -----
        // Called, not merely declared: a declaration alone would prove the gate
        // let it through, while the call proves the LINK really resolved the
        // symbol. An undefined reference fails inside `linkExecutable`.
        var ok_err: Io.Writer.Allocating = .init(gpa);
        defer ok_err.deinit();
        const ok_src =
            \\extern function bit_rt_gc_blocking_begin()
            \\extern function bit_rt_gc_blocking_end()
            \\function main() {
            \\  bit_rt_gc_blocking_begin()
            \\  bit_rt_gc_blocking_end()
            \\}
            \\
        ;
        const exe = (try buildExecutable(gpa, "externok.bit", ok_src, lib, target, &ok_err.writer)) orelse {
            std.debug.print("target {s}: rejected a symbol libbitrt.a defines:\n{s}\n", .{ target.name(), ok_err.written() });
            return error.LegitimateExternRejected;
        };
        defer gpa.free(exe);
        try std.testing.expect(exe.len > 0);

        // --- rejected: absent from the archive ------------------------------
        var bad_err: Io.Writer.Allocating = .init(gpa);
        defer bad_err.deinit();
        const bad_src = try std.fmt.allocPrint(gpa,
            \\extern function {s}()
            \\function main() {{
            \\  {s}()
            \\}}
            \\
        , .{ absent_symbol, absent_symbol });
        defer gpa.free(bad_src);
        try std.testing.expect(try buildExecutable(gpa, "externbad.bit", bad_src, lib, target, &bad_err.writer) == null);
        // Scored on the REASON: it must be E0078 naming the symbol, not some
        // unrelated failure that also happens to return null.
        try std.testing.expect(std.mem.indexOf(u8, bad_err.written(), "E0078") != null);
        try std.testing.expect(std.mem.indexOf(u8, bad_err.written(), absent_symbol) != null);

        // --- undecidable: no archive in the link must fall back to REJECTION --
        // `bit build-obj` reads no archive. Accepting on unknown would trade a
        // compile error for a link error or a silent crash, so the same source
        // that was accepted above must be refused with an empty archive.
        var none_err: Io.Writer.Allocating = .init(gpa);
        defer none_err.deinit();
        try std.testing.expect(try buildExecutable(gpa, "externok.bit", ok_src, "", target, &none_err.writer) == null);
        try std.testing.expect(std.mem.indexOf(u8, none_err.written(), "E0078") != null);
    }

    // Anti-vacuity: a loop that ran zero times would pass while asserting
    // nothing — the failure mode this codebase has hit eleven times.
    if (checked == 0) return error.SkipZigTest;
}

test "archiveDefines answers membership, not mere reference" {
    // The predicate itself, isolated from the diagnostic. `bit_rt_gc_blocking_begin`
    // is DEFINED by the archive; `absent_symbol` is in neither. The third case is
    // the one that makes this non-trivial: `strip.resolveGlobals` keys on defining
    // ATOMS, so a member that only CALLS a symbol must not count as defining it.
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var checked: usize = 0;
    for ([_]BuildTarget{ .x86_64_linux, .aarch64_linux }) |target| {
        const lt: link.Target = switch (target) {
            .x86_64_linux => .x86_64_linux,
            .aarch64_linux => .aarch64_linux,
            .aarch64_macos => unreachable,
        };
        const lib = Io.Dir.cwd().readFileAlloc(io, libbitrtPath(target), gpa, .unlimited) catch continue;
        defer gpa.free(lib);
        checked += 1;

        try std.testing.expect(link.archiveDefines(gpa, lt, lib, "bit_rt_gc_blocking_begin"));
        try std.testing.expect(!link.archiveDefines(gpa, lt, lib, absent_symbol));
        // Undecidable inputs answer false rather than erroring — the caller's
        // only sound response to "unknown" is to reject.
        try std.testing.expect(!link.archiveDefines(gpa, lt, "", "bit_rt_gc_blocking_begin"));
        try std.testing.expect(!link.archiveDefines(gpa, lt, "not an ar archive at all", "bit_rt_gc_blocking_begin"));
    }
    if (checked == 0) return error.SkipZigTest;
}
