//! Concurrency + GC stress suite (task #350): the production-readiness gate for
//! the runtime. Each subdirectory of `tests/stress/` is a Bit program that
//! hammers spawn / channels / select / the collector under load and prints a
//! single deterministic line encoding its own correctness (a checksum, a sum).
//!
//! Every program is built by **both compilers** — the bootstrap seed `bit-seed`
//! (in-process, via `bit.buildHostProject`) and the self-hosted `bit` (as a
//! subprocess, since it is a Bit-compiled binary and not a Zig module) — and
//! each of the two binaries is then run **twice**: once with the default
//! collector policy, and once under `BIT_GC=stress`, which collects at every
//! safepoint. The stress run is a precise-rooting oracle: any root the compiler
//! or runtime fails to report is swept the instant it stops being marked, so a
//! rooting bug that a rare production collection would only occasionally hit
//! becomes a deterministic wrong answer here. All four runs must reproduce the
//! program's `.expected` output.
//!
//! THE SELF-HOSTED PASS IS THE POINT OF THE SUITE, NOT AN EXTRA (#1413). This
//! harness drove only the seed until then — the retired compiler — so the
//! production-readiness gate for the runtime said nothing whatsoever about the
//! compiler the project exists to ship, and gate #1369 (self-hosted `bit` builds
//! the runtime) rested on a suite that never asked. That was not theoretical:
//! #1414 is two runtime modules the seed builds and self-hosted `bit` does not.
//! Do not "fix" a failure here by skipping the program — a skip-list reads as
//! coverage and is exactly the hole this pass was added to close.
//!
//! THE ORACLE IS ONLY AS DENSE AS THE SAFEPOINTS, and a program must earn it.
//! Codegen emits `bit_rt_safepoint` at loop back-edges (runtime/ABI.md §4);
//! `bit_rt_alloc` does NOT poll, so allocating does not by itself collect. A
//! straight-line program therefore runs ZERO collections under `BIT_GC=stress`
//! no matter how much it allocates, and its second run verifies nothing about
//! rooting — it is the same run twice. A program here that means to exercise the
//! collector must own a loop at the point where the roots it cares about are
//! live; `BIT_GC_STATS=1` reports the collection count and is the way to confirm
//! that rather than assume it. #1409 was filed on the strength of the assumption
//! and did not survive it.
//!
//! Skipped when the host is not a supported runtime target (no libbitrt to link
//! against), mirroring the golden `// run` cases and the examples guard.

const std = @import("std");
const builtin = @import("builtin");
const bit = @import("bit");
const build_options = @import("build_options");

const testing = std.testing;
const Io = std.Io;
const Dir = std.Io.Dir;

/// Upper bound on programs scanned — keeps the directory walk provably bounded
/// (Power of 10).
const max_programs = 256;

test "stress programs pass under default and BIT_GC=stress" {
    if (build_options.libbitrt_path.len == 0) return; // host not a runtime target

    // A host that can link libbitrt is a native build, and a native build always
    // produces the self-hosted `bit`. Assert it rather than degrading to the
    // seed-only pass: a self-hosted pass that quietly did not happen is exactly
    // the shape of #1413, and a green suite must not be able to mean "half of
    // what it claims to check was not wired up".
    try testing.expect(build_options.selfhost_bit.len > 0);

    const gpa = testing.allocator;
    const io = Io.Threaded.global_single_threaded.io();

    var dir = Dir.openDirAbsolute(io, build_options.stress_dir, .{ .iterate = true }) catch |e| {
        std.debug.print("cannot open stress dir '{s}': {s}\n", .{ build_options.stress_dir, @errorName(e) });
        return e;
    };
    defer dir.close(io);

    const libbitrt = Dir.cwd().readFileAlloc(io, build_options.libbitrt_path, gpa, .limited(16 << 20)) catch |e| {
        std.debug.print("cannot read libbitrt '{s}': {s}\n", .{ build_options.libbitrt_path, @errorName(e) });
        return e;
    };
    defer gpa.free(libbitrt);

    var it = dir.iterate();
    var scanned: u32 = 0;
    while (scanned < max_programs) : (scanned += 1) {
        const entry = (try it.next(io)) orelse break;
        if (entry.kind != .directory) continue;

        const name = try gpa.dupe(u8, entry.name); // invalidated by the next step
        defer gpa.free(name);
        const dir_abs = try std.fs.path.join(gpa, &.{ build_options.stress_dir, name });
        defer gpa.free(dir_abs);

        try runStress(gpa, io, name, dir_abs, libbitrt);
    }
    try testing.expect(scanned < max_programs);
}

fn runStress(gpa: std.mem.Allocator, io: Io, name: []const u8, dir_abs: []const u8, libbitrt: []const u8) !void {
    // A program that can only run on Darwin marks itself with a `darwin-only`
    // file. `extern function` (SPEC §11.7) is the case that needs this: Bit's
    // ELF output is a fully static binary with no dynamic symbol table, so an
    // extern symbol has nothing to resolve against and the compiler rejects it
    // outright — the program is not merely expected to fail, it cannot compile.
    if (builtin.target.os.tag != .macos) {
        const darwin_marker = try std.fmt.allocPrint(gpa, "{s}/darwin-only", .{dir_abs});
        defer gpa.free(darwin_marker);
        if (Dir.cwd().access(io, darwin_marker, .{})) |_| return else |_| {}
    }

    // The mirror case: a program exercising an OS-specific primitive (§11.8
    // `syscall`) marks itself with a `linux-only` file. It neither compiles nor
    // runs elsewhere, so a non-Linux host skips it rather than failing. Same
    // spirit as the suite-level `libbitrt_path` guard above, one level finer.
    const linux_marker = try std.fmt.allocPrint(gpa, "{s}/linux-only", .{dir_abs});
    defer gpa.free(linux_marker);
    const linux_only = if (Dir.cwd().statFile(io, linux_marker, .{})) |_| true else |_| false;
    if (linux_only and builtin.target.os.tag != .linux) return;

    const expected_path = try std.fmt.allocPrint(gpa, "{s}/{s}.expected", .{ dir_abs, name });
    defer gpa.free(expected_path);
    const expected = try Dir.cwd().readFileAlloc(io, expected_path, gpa, .limited(64 << 10));
    defer gpa.free(expected);

    const seed_bin = try std.fmt.allocPrintSentinel(gpa, "/tmp/bit-stress-seed-{s}-{x}", .{ name, testing.random_seed }, 0);
    defer gpa.free(seed_bin);
    const self_bin = try std.fmt.allocPrintSentinel(gpa, "/tmp/bit-stress-self-{s}-{x}", .{ name, testing.random_seed }, 0);
    defer gpa.free(self_bin);

    // Per-test io over `gpa` so `std.process.run`'s spawn arena does not trip
    // `testing.allocator`'s leak detector (same rationale as the examples guard).
    var run_threaded = Io.Threaded.init(gpa, .{});
    defer run_threaded.deinit();
    const run_io = run_threaded.io();

    // ---- Phase 1: compile, write, fork nothing that could inherit a write fd.
    //
    // `74811a3`'s discipline, kept as this suite gained a second compiler: never
    // let a `fork` happen while this process holds a write fd to a binary it is
    // about to `execve`, because `fork` copies the whole fd table and Linux
    // refuses to exec an inode whose writecount is nonzero (ETXTBSY). Driving
    // self-hosted `bit` means forking, so it goes FIRST — before this process
    // opens anything for writing — and the seed's `writeFile` (which forks
    // nothing) follows it. No exec of a stress binary happens until phase 2, by
    // which point no write fd to either of them exists anywhere.
    defer Dir.cwd().deleteFile(run_io, self_bin) catch {};
    try buildWithSelfhost(gpa, run_io, name, dir_abs, self_bin);

    var discard: Io.Writer.Allocating = .init(gpa);
    defer discard.deinit();
    // Whole-project build, not the single-module entry: a stress program is a
    // directory, so it gets the prelude and may import another module — which
    // `spinlock` does, pulling the lock under test straight out of `runtime/`
    // instead of testing a stale copy of it.
    const exe = (try bit.buildHostProject(gpa, io, dir_abs, build_options.stdlib_dir, name, libbitrt, &discard.writer)) orelse {
        std.debug.print("stress '{s}' [seed]: compile failed:\n{s}\n", .{ name, discard.written() });
        return error.StressCompileFailed;
    };
    defer gpa.free(exe);

    defer Dir.cwd().deleteFile(run_io, seed_bin) catch {};
    try Dir.cwd().writeFile(run_io, .{ .sub_path = seed_bin, .data = exe, .flags = .{ .permissions = .executable_file } });

    // ---- Phase 2: exec only. Both compilers' output must satisfy `.expected`
    // identically, under both collector policies.
    try runBoth(gpa, run_io, name, "seed", seed_bin, expected);
    try runBoth(gpa, run_io, name, "selfhost", self_bin, expected);
}

/// Build `dir_abs` with the self-hosted `bit`. It is a Bit-compiled executable,
/// not a Zig module this harness can import, so it is driven as a subprocess.
/// `BIT_LIBBITRT`/`BIT_STDLIB` hand it the same archive and stdlib the seed pass
/// is handed, which both puts the two compilers on identical inputs and keeps
/// the harness independent of its working directory.
fn buildWithSelfhost(gpa: std.mem.Allocator, run_io: Io, name: []const u8, dir_abs: []const u8, out_path: [:0]const u8) !void {
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    try env.put("BIT_LIBBITRT", build_options.libbitrt_path);
    try env.put("BIT_STDLIB", build_options.stdlib_dir);

    const result = try std.process.run(gpa, run_io, .{
        .argv = &.{ build_options.selfhost_bit, "build", dir_abs, "-o", out_path },
        .environ_map = &env,
    });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);

    const ok = switch (result.term) {
        .exited => |c| c == 0,
        else => false,
    };
    if (ok) return;
    std.debug.print("stress '{s}' [selfhost]: compile failed:\n{s}{s}\n", .{ name, result.stdout, result.stderr });
    return error.StressSelfhostCompileFailed;
}

/// Both collector policies for one compiler's binary.
fn runBoth(gpa: std.mem.Allocator, run_io: Io, name: []const u8, who: []const u8, bin_path: [:0]const u8, expected: []const u8) !void {
    try runOnce(gpa, run_io, name, who, bin_path, expected, null);

    var stress_env = std.process.Environ.Map.init(gpa);
    defer stress_env.deinit();
    try stress_env.put("BIT_GC", "stress");
    try runOnce(gpa, run_io, name, who, bin_path, expected, &stress_env);
}

fn runOnce(gpa: std.mem.Allocator, run_io: Io, name: []const u8, who: []const u8, bin_path: [:0]const u8, expected: []const u8, env: ?*const std.process.Environ.Map) !void {
    const policy = if (env == null) "default" else "BIT_GC=stress";
    const mode = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ who, policy });
    defer gpa.free(mode);
    const result = try std.process.run(gpa, run_io, .{ .argv = &.{bin_path}, .environ_map = env });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);

    const code: u8 = switch (result.term) {
        .exited => |c| c,
        else => 255,
    };
    if (code != 0) {
        std.debug.print("stress '{s}' [{s}]: exited {d}\nstderr: {s}\n", .{ name, mode, code, result.stderr });
        return error.StressRunFailed;
    }
    if (!std.mem.eql(u8, result.stdout, expected)) {
        std.debug.print("stress '{s}' [{s}]: output mismatch\n  expected: {s}\n  got:      {s}\n", .{ name, mode, expected, result.stdout });
        return error.StressOutputMismatch;
    }
}
