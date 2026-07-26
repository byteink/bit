//! `bit build`/`check`/`run` resolving external-package imports through
//! bit.lock + the package cache (#1737). This is a selfhost-ONLY feature:
//! `selfhost/project.bit`'s loader is the only compiler that knows about
//! bit.lock at all, the Zig seed has no equivalent and never will. That rules
//! out `tests/imports.zig`'s shared harness — its own header is explicit that
//! "the seed's verdict is unconditional" (every project there must build under
//! BOTH compilers, with no gap-list escape on the seed side) — so this file
//! spawns the self-hosted `bit` directly instead, the way `tests/lintcmd.zig`
//! does for its own selfhost-only feature.
//!
//! Two real projects, each driven through the actual CLI (`bit run`,
//! `bit check`) as a subprocess with a controlled environment — proving the
//! wiring `selfhost/projectcheck.bit`'s own in-process self-check (which calls
//! `Loader`/`resolvePackageImport` directly) cannot reach on its own:
//! `main.bit`'s command dispatch, and `BIT_PKG_CACHE` actually taking effect
//! end to end.
//!
//!  - a locked, WARM-cache dependency: the lock entry's `url` names a host
//!    under `.invalid` (RFC 2606 — reserved so it can never resolve on any
//!    network, anywhere), so a successful `bit run` producing the fixture
//!    package's own output is proof the warm-cache path never dialed it.
//!    `BIT_PKG_CACHE` points the whole run at a scratch cache this file
//!    pre-populates with a real `git` checkout, so nothing reaches the
//!    developer's actual `~/.bit/pkg` either.
//!  - a project whose import has no bit.lock entry at all: `bit check` must
//!    exit non-zero with a diagnostic naming the missing dependency and
//!    `bit add`, never attempting a fetch.

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

/// Runs `bit_abs <args...>` from `cwd` under `env` — never the inherited
/// environment: this file controls `BIT_PKG_CACHE` precisely, and letting a
/// developer's real `~/.bit/pkg` or a proxy variable leak in would make the
/// "zero network" proof meaningless.
fn runBit(
    gpa: std.mem.Allocator,
    io: Io,
    timeout_s: u32,
    bit_abs: []const u8,
    cwd: []const u8,
    args: []const []const u8,
    env: *const std.process.Environ.Map,
) !Run {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.append(gpa, bit_abs);
    try argv.appendSlice(gpa, args);

    const outcome = try proc.run(gpa, io, timeout_s, .{
        .argv = argv.items,
        .cwd = .{ .path = cwd },
        .environ_map = env,
    });
    const result = switch (outcome) {
        .finished => |r| r,
        .timed_out => |limit| {
            std.debug.print("pmimports: 'bit' TIMED OUT\n", .{});
            proc.timedOutNote(limit, bit_abs);
            return error.PmImportsTimedOut;
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

/// A minimal environment for the `bit` subprocess: `PATH` so its own internal
/// `git` shell-out (pmfetch.bit's `runGit`) resolves, `TMPDIR` for that same
/// wrapper's scratch files, and `BIT_STDLIB`/`BIT_LIBBITRT` so `bit run` can
/// actually link and execute — never the parent's own environment.
///
/// `build_options.stdlib_dir`/`libbitrt_path` are relative to the BUILD
/// ROOT, but the `bit` subprocess this env is handed to runs with `cwd` set
/// to a scratch fixture directory (so a bare `bit.lock`/relative import
/// resolves against the FIXTURE, not this repo) — so a relative value here
/// would resolve against the wrong directory. Resolve both to absolute paths
/// up front, once, against this TEST process's own cwd (the build root).
fn baseEnv(gpa: std.mem.Allocator, io: Io) !std.process.Environ.Map {
    var env = std.process.Environ.Map.init(gpa);
    errdefer env.deinit();
    try env.put("PATH", "/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin");
    try env.put("TMPDIR", "/tmp");

    const stdlib_abs = try Dir.cwd().realPathFileAlloc(io, build_options.stdlib_dir, gpa);
    defer gpa.free(stdlib_abs);
    try env.put("BIT_STDLIB", stdlib_abs);

    if (build_options.libbitrt_path.len > 0) {
        const libbitrt_abs = try Dir.cwd().realPathFileAlloc(io, build_options.libbitrt_path, gpa);
        defer gpa.free(libbitrt_abs);
        try env.put("BIT_LIBBITRT", libbitrt_abs);
    }
    return env;
}

/// Runs a system tool (e.g. `git`) for fixture setup and asserts it exited 0.
fn sh(gpa: std.mem.Allocator, io: Io, cwd: []const u8, argv: []const []const u8) !void {
    const result = try std.process.run(gpa, io, .{ .argv = argv, .cwd = .{ .path = cwd } });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    switch (result.term) {
        .exited => |c| if (c != 0) {
            std.debug.print("pmimports fixture: git exited {d}\n{s}{s}\n", .{ c, result.stdout, result.stderr });
            return error.FixtureSetupFailed;
        },
        else => {
            std.debug.print("pmimports fixture: git died by signal\n", .{});
            return error.FixtureSetupFailed;
        },
    }
}

/// The trimmed stdout of `git -C dir rev-parse HEAD`, gpa-owned.
fn revParseHead(gpa: std.mem.Allocator, io: Io, dir: []const u8) ![]u8 {
    const result = try std.process.run(gpa, io, .{ .argv = &.{ "git", "-C", dir, "rev-parse", "HEAD" }, .cwd = .{ .path = dir } });
    defer gpa.free(result.stderr);
    defer gpa.free(result.stdout);
    if (result.term != .exited or result.term.exited != 0) return error.FixtureSetupFailed;
    return gpa.dupe(u8, std.mem.trim(u8, result.stdout, " \t\r\n"));
}

/// Builds a one-commit git repo at `<root>/pkgsrc` (the "upstream" package —
/// a real `.bit` module) and returns its HEAD sha, gpa-owned.
fn buildPkgSource(gpa: std.mem.Allocator, io: Io, root: []const u8) ![]u8 {
    const src = try std.fmt.allocPrint(gpa, "{s}/pkgsrc", .{root});
    defer gpa.free(src);
    try sh(gpa, io, root, &.{ "git", "init", "--quiet", "-b", "main", src });
    try sh(gpa, io, root, &.{ "git", "-C", src, "config", "user.email", "pmimports@example.com" });
    try sh(gpa, io, root, &.{ "git", "-C", src, "config", "user.name", "pmimports" });
    var srcDir = try Dir.cwd().openDir(io, src, .{});
    defer srcDir.close(io);
    try srcDir.writeFile(io, .{ .sub_path = "greet.bit", .data = "export function greet(): string {\n  return \"hi from pkg\\n\"\n}\n" });
    try sh(gpa, io, root, &.{ "git", "-C", src, "add", "greet.bit" });
    try sh(gpa, io, root, &.{ "git", "-C", src, "commit", "--quiet", "-m", "pkg fixture" });
    return revParseHead(gpa, io, src);
}

/// Warms `<cacheRoot>/<host>/<owner>/<repo>/<sha>` exactly the way
/// `pmfetch.bit`'s `fetchSha` does on a cold miss — a real `git init` +
/// `fetch --depth 1` + `checkout`, from `<root>/pkgsrc` — so the warm-cache
/// test starts from a cache state a real cold `bit build`/CI checkout would
/// itself have produced, not a hand-faked directory.
fn warmCache(gpa: std.mem.Allocator, io: Io, root: []const u8, cacheRoot: []const u8, host: []const u8, owner: []const u8, repo: []const u8, sha: []const u8) !void {
    const finalDir = try std.fmt.allocPrint(gpa, "{s}/{s}/{s}/{s}/{s}", .{ cacheRoot, host, owner, repo, sha });
    defer gpa.free(finalDir);
    const src = try std.fmt.allocPrint(gpa, "{s}/pkgsrc", .{root});
    defer gpa.free(src);
    try Dir.cwd().createDirPath(io, finalDir);
    try sh(gpa, io, root, &.{ "git", "init", "--quiet", finalDir });
    const srcUrl = try std.fmt.allocPrint(gpa, "file://{s}", .{src});
    defer gpa.free(srcUrl);
    try sh(gpa, io, root, &.{ "git", "-C", finalDir, "fetch", "--quiet", "--depth", "1", srcUrl, sha });
    try sh(gpa, io, root, &.{ "git", "-C", finalDir, "checkout", "--quiet", sha });
}

test "bit run: a locked, warm-cache dependency builds and runs with zero network access" {
    if (build_options.selfhost_bit.len == 0) return; // cross build: no runnable `bit`
    if (build_options.libbitrt_path.len == 0) return; // host is not a runtime target

    const gpa = testing.allocator;
    var threaded = Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const bit_abs = try selfbin.privateCopy(gpa, io, build_options.selfhost_bit);
    defer selfbin.release(gpa, io, bit_abs);
    const timeout_s = proc.timeoutSeconds(gpa);

    const root = try std.fmt.allocPrint(gpa, "/tmp/bit-pmimports-{x}", .{testing.random_seed});
    defer gpa.free(root);
    defer Dir.cwd().deleteTree(io, root) catch {};
    try Dir.cwd().createDirPath(io, root);

    const sha = try buildPkgSource(gpa, io, root);
    defer gpa.free(sha);

    // `pkg.pmimports.invalid` is under the IANA-reserved `.invalid` TLD
    // (RFC 2606 §2): it is guaranteed to never resolve on any real network, so
    // a successful build/run through this url proves the warm-cache path
    // never dialed it — `fetchSha`'s cache-hit branch (pmfetch.bit) never even
    // reads the url, only `host`/`owner`/`repo`/`sha`.
    const host = "pkg.pmimports.invalid";
    const owner = "acme";
    const repo = "pkg";
    const cacheRoot = try std.fmt.allocPrint(gpa, "{s}/cache", .{root});
    defer gpa.free(cacheRoot);
    try warmCache(gpa, io, root, cacheRoot, host, owner, repo, sha);

    const projDir = try std.fmt.allocPrint(gpa, "{s}/proj", .{root});
    defer gpa.free(projDir);
    try Dir.cwd().createDirPath(io, projDir);
    var proj = try Dir.cwd().openDir(io, projDir, .{});
    defer proj.close(io);

    const lock = try std.fmt.allocPrint(gpa,
        \\{{"pkg":{{"url":"https://{s}/{s}/{s}.git","commit":"{s}","requires":{{}}}}}}
    , .{ host, owner, repo, sha });
    defer gpa.free(lock);
    try proj.writeFile(io, .{ .sub_path = "bit.lock", .data = lock });
    const manifest = try std.fmt.allocPrint(gpa,
        \\{{"dependencies":{{"pkg":"{s}/{s}/{s}@{s}"}}}}
    , .{ host, owner, repo, sha });
    defer gpa.free(manifest);
    try proj.writeFile(io, .{ .sub_path = "bit.json", .data = manifest });
    try proj.writeFile(io, .{ .sub_path = "main.bit", .data = "import { greet } from \"pkg\"\nfunction main() {\n  print(greet())\n}\n" });

    var env = try baseEnv(gpa, io);
    defer env.deinit();
    try env.put("BIT_PKG_CACHE", cacheRoot);

    const start_ns = Io.Timestamp.now(io, .real).nanoseconds;
    const r = try runBit(gpa, io, timeout_s, bit_abs, projDir, &.{ "run", "main.bit" }, &env);
    defer r.deinit(gpa);
    const elapsed_ms = @divTrunc(Io.Timestamp.now(io, .real).nanoseconds - start_ns, 1_000_000);

    if (r.code != 0) std.debug.print("pmimports: 'bit run' exited {d}\nstdout: {s}\nstderr: {s}\n", .{ r.code, r.stdout, r.stderr });
    try testing.expectEqual(@as(u8, 0), r.code);
    try testing.expectEqualStrings("hi from pkg\n", r.stdout);
    // Generous slack over a COLD local `git rev-parse` + compile + link + run
    // (no caching, first execution) — nowhere near what dialing an
    // unreachable host would cost on top of that (a connection attempt, then
    // pmfetch.bit's 30s default fetch deadline). This only needs to rule out
    // "fell through to a fetch attempt", not pin an exact bound a slower or
    // more contended host would flake on.
    try testing.expect(elapsed_ms < 60_000);
}

test "bit check: a missing bit.lock entry fails naming the dependency, never fetching" {
    if (build_options.selfhost_bit.len == 0) return; // cross build: no runnable `bit`

    const gpa = testing.allocator;
    var threaded = Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const bit_abs = try selfbin.privateCopy(gpa, io, build_options.selfhost_bit);
    defer selfbin.release(gpa, io, bit_abs);
    const timeout_s = proc.timeoutSeconds(gpa);

    const root = try std.fmt.allocPrint(gpa, "/tmp/bit-pmimports-missing-{x}", .{testing.random_seed});
    defer gpa.free(root);
    defer Dir.cwd().deleteTree(io, root) catch {};
    try Dir.cwd().createDirPath(io, root);
    var proj = try Dir.cwd().openDir(io, root, .{});
    defer proj.close(io);

    // No bit.lock at all: `readLock` treats that as zero entries, not an error.
    try proj.writeFile(io, .{ .sub_path = "main.bit", .data = "import { x } from \"nope\"\nfunction main() {}\n" });

    var env = try baseEnv(gpa, io);
    defer env.deinit();
    // A cache root this run could never legitimately populate — if the
    // resolver ever fell through to a fetch attempt despite the missing lock
    // entry, it would show up here rather than silently succeeding against
    // the developer's real cache.
    const cacheRoot = try std.fmt.allocPrint(gpa, "{s}/cache-never-used", .{root});
    defer gpa.free(cacheRoot);
    try env.put("BIT_PKG_CACHE", cacheRoot);

    const r = try runBit(gpa, io, timeout_s, bit_abs, root, &.{ "check", "." }, &env);
    defer r.deinit(gpa);

    try testing.expectEqual(@as(u8, 1), r.code);
    try testing.expect(std.mem.indexOf(u8, r.stderr, "cannot find module \"nope\"") != null);
    try testing.expect(std.mem.indexOf(u8, r.stderr, "not declared in bit.lock") != null);
    try testing.expect(std.mem.indexOf(u8, r.stderr, "bit add") != null);
    // The cache root was never even created — the resolver rejected the
    // unlocked name before reaching anything that would fetch into it.
    try testing.expectError(error.FileNotFound, Dir.cwd().statFile(io, cacheRoot, .{}));
}
