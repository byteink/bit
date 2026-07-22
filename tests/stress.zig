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
//! SO THE STRESS RUN NOW ASSERTS ITS OWN ORACLE IS LIVE (#1438). Every
//! `BIT_GC=stress` run sets `BIT_GC_STATS=1` and requires a non-zero collection
//! count. The paragraph above stated that rule from the day this suite was
//! written and nothing enforced it, so four programs sat here reading as
//! stress-verified with the collector never once running. A program that is
//! legitimately straight-line — one proving something about emission or linking
//! rather than about rooting — declares that by carrying a `no-collect` file
//! whose contents say why. The marker must be non-empty: the point is that
//! inertness is DECLARED and argued, never inherited by accident.
//!
//! #1438 is also why the suite must never be replaced by `BIT_GC=stress bit run
//! <dir>`. Self-hosted `bit` is itself a Bit program, so that command applies
//! the policy to THE COMPILER, which then collects at every back-edge of its own
//! compilation — hundreds of thousands of collections for a six-line input,
//! indistinguishable from a hang. Build first, run the binary second, which is
//! exactly what this harness does.
//!
//! THE QUIC/TLS HOLE (#1475), AND WHY IT WAS SHAPED THE WAY IT IS. The
//! networking stack is the largest and most concurrent part of the stdlib, so its
//! absence from the precise-rooting oracle is exactly the kind of exemption that
//! must be written down rather than inferred from an empty directory listing.
//!
//! It was filed on the observation that `tests/imports/quicconn` exceeds 300s
//! under `BIT_GC=stress`, with the #1462 precedent in mind — a thread that
//! reaches no safepoint burns a full 8M-iteration rendezvous per collection. That
//! is NOT what this is, and the measurements say so rather than intuition
//! (arm64-macOS, all with the binary built first and the policy applied to THAT):
//!
//!   - `BIT_GC_STATS=1` over the first 100s: 596,630 collections, `stw_abandoned`
//!     = 0. Not one rendezvous expired, so no thread is failing the `blocked`
//!     contract. The process sits at 100% CPU with CPU time tracking elapsed
//!     time — it is compute-bound and progressing, not wedged.
//!   - Payload size is irrelevant. Shrinking the 96 KiB transfer to 1 byte leaves
//!     a run that is 1.2s by default and still had not finished its first
//!     handshake after 300s of stress. So the cost is not in the data path.
//!   - It is not QUIC's, and not concurrency's. `tests/imports/cryptorsa` — no
//!     sockets, no spawn, no channels — goes from 2.4s to over 120s under the
//!     same policy.
//!
//! So the cause is plain arithmetic, not a defect: stress collects at EVERY
//! safepoint, each collection is a full mark-sweep of the whole live heap
//! (~0.17ms at quicconn's ~926 KB live set), and a QUIC-TLS handshake is
//! RSA-2048 plus X25519 plus the record path — millions of loop back-edges, hence
//! millions of collections. Any loop-dense compute workload in Bit costs the same
//! two to three orders of magnitude here; QUIC merely does more of it than
//! anything else in the tree.
//!
//! THE HOLE IS NOW PART-CLOSED, AND THE REMAINDER IS STILL DECLARED (#1483).
//! The second, unrelated blocker named here — self-hosted `bit` could not build
//! *any* program importing `std/quic`, refusing to lower 10 functions — was two
//! lowering defects (bound struct-method values; a generic-enum scrutinee read
//! from a struct field), both fixed. `tests/stress/quicwire` followed: the QUIC
//! packet and frame path — Initial keys, header codec, AEAD payload protection,
//! header protection, frame encode/parse — with every intermediate a fresh
//! `[]byte` moved between spawned tasks over an unbuffered channel and taken
//! with `select`. Measured at 1,491,425 collections per stress run, so those
//! buffers are genuinely under the oracle rather than nominally in the suite.
//!
//! WHAT REMAINS UNCOVERED is the handshake and the connection loop itself — its
//! ticker and the listener demux. That part is not gated on a compiler defect
//! any more; it is the arithmetic above, and it has no cheap form. Do not
//! "solve" it by lowering quicconn's payload or by running quicconn here with a
//! longer timeout — neither buys any rooting coverage, and the first reads as if
//! it did.
//!
//! EVERY SUBPROCESS HERE CARRIES A WALL-CLOCK DEADLINE (#1637). This is the
//! corpus most able to hang — spawn, channels, select, park/unpark — and a
//! program that deadlocks used to stall the whole suite with no output naming
//! it, which is strictly worse than a failure. `tests/proc.zig` bounds each
//! spawn and reports an expiry as its own outcome, distinct from a crash and
//! from an output mismatch. See that file for the limit, how it was chosen
//! against this corpus's own measured worst case (`quicwire` under
//! `BIT_GC=stress`), and the `BIT_TEST_TIMEOUT_S` override.
//!
//! Skipped when the host is not a supported runtime target (no libbitrt to link
//! against), mirroring the golden `// run` cases and the examples guard.

const std = @import("std");
const builtin = @import("builtin");
const bit = @import("bit");
const build_options = @import("build_options");
const proc = @import("proc.zig");
const selfbin = @import("selfbin.zig");

const testing = std.testing;
const Io = std.Io;
const Dir = std.Io.Dir;

/// Upper bound on programs scanned — keeps the directory walk provably bounded
/// (Power of 10).
const max_programs = 256;

/// The self-hosted compiler this run execs — a PRIVATE COPY, never
/// `build_options.selfhost_bit` itself. A concurrent `zig build` rewrites that
/// artifact in place and macOS SIGKILLs the exec, failing every case with no
/// output at all (#1644); see tests/selfbin.zig.
///
/// Module-scoped rather than threaded through `runStress`: written once, by the
/// test below, before the first program is built, and only read afterwards.
var self_compiler: []const u8 = "";

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

    // Exec a PRIVATE COPY of `bit`, never the build system's own artifact: a
    // concurrent `zig build` rewrites that file in place and macOS SIGKILLs the
    // exec, failing every case with no output (#1644). See tests/selfbin.zig.
    var copy_threaded = Io.Threaded.init(gpa, .{});
    defer copy_threaded.deinit();
    const copy = try selfbin.privateCopy(gpa, copy_threaded.io(), build_options.selfhost_bit);
    defer selfbin.release(gpa, copy_threaded.io(), copy);
    self_compiler = copy;

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
    // One read of the knob per program, shared by the compile and all four runs.
    const timeout_s = proc.timeoutSeconds(gpa);

    defer Dir.cwd().deleteFile(run_io, self_bin) catch {};
    try buildWithSelfhost(gpa, run_io, name, dir_abs, self_bin, timeout_s);

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

    // A program that cannot reach a safepoint where it matters says so in a
    // `no-collect` file, and says why in its contents. Read here rather than in
    // `runOnce` so a malformed marker fails once per program, not once per run.
    const no_collect = try readNoCollect(gpa, run_io, name, dir_abs);
    defer if (no_collect) |m| gpa.free(m);

    // ---- Phase 2: exec only. Both compilers' output must satisfy `.expected`
    // identically, under both collector policies.
    try runBoth(gpa, run_io, name, "seed", seed_bin, expected, no_collect != null, timeout_s);
    try runBoth(gpa, run_io, name, "selfhost", self_bin, expected, no_collect != null, timeout_s);
}

/// The declared-inert marker: `null` when the program must collect, otherwise
/// its stated reason. An empty marker is an error — a bare file would let a
/// program opt out of the oracle without anyone having to justify it, which is
/// the failure mode the marker exists to prevent.
fn readNoCollect(gpa: std.mem.Allocator, run_io: Io, name: []const u8, dir_abs: []const u8) !?[]u8 {
    const marker_path = try std.fmt.allocPrint(gpa, "{s}/no-collect", .{dir_abs});
    defer gpa.free(marker_path);

    const body = Dir.cwd().readFileAlloc(run_io, marker_path, gpa, .limited(4 << 10)) catch return null;
    errdefer gpa.free(body);
    if (std.mem.trim(u8, body, " \t\r\n").len == 0) {
        std.debug.print("stress '{s}': 'no-collect' marker is empty — state why the collector cannot run\n", .{name});
        return error.StressEmptyNoCollectMarker;
    }
    return body;
}

/// Build `dir_abs` with the self-hosted `bit`. It is a Bit-compiled executable,
/// not a Zig module this harness can import, so it is driven as a subprocess.
/// `BIT_LIBBITRT`/`BIT_STDLIB` hand it the same archive and stdlib the seed pass
/// is handed, which both puts the two compilers on identical inputs and keeps
/// the harness independent of its working directory.
fn buildWithSelfhost(gpa: std.mem.Allocator, run_io: Io, name: []const u8, dir_abs: []const u8, out_path: [:0]const u8, timeout_s: u32) !void {
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    try env.put("BIT_LIBBITRT", build_options.libbitrt_path);
    try env.put("BIT_STDLIB", build_options.stdlib_dir);

    // The compiler is bounded too: a compiler that loops forever stalls the
    // suite exactly as a deadlocked stress program does, and says even less.
    std.debug.assert(self_compiler.len > 0);
    const outcome = try proc.run(gpa, run_io, timeout_s, .{
        .argv = &.{ self_compiler, "build", dir_abs, "-o", out_path },
        .environ_map = &env,
    });
    const result = switch (outcome) {
        .finished => |r| r,
        .timed_out => |limit| {
            std.debug.print("stress '{s}' [selfhost]: COMPILE TIMED OUT\n", .{name});
            proc.timedOutNote(limit, self_compiler);
            return error.StressSelfhostCompileTimedOut;
        },
    };
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);

    if (result.term == .exited and result.term.exited == 0) return;
    std.debug.print("stress '{s}' [selfhost]: compile failed:\n", .{name});
    proc.toolFailedNote(result.term, self_compiler, result.stdout, result.stderr);
    return error.StressSelfhostCompileFailed;
}

/// Both collector policies for one compiler's binary. The stress pass also
/// carries `BIT_GC_STATS=1` so the run can prove the collector actually ran.
fn runBoth(gpa: std.mem.Allocator, run_io: Io, name: []const u8, who: []const u8, bin_path: [:0]const u8, expected: []const u8, no_collect: bool, timeout_s: u32) !void {
    try runOnce(gpa, run_io, name, who, bin_path, expected, null, no_collect, timeout_s);

    var stress_env = std.process.Environ.Map.init(gpa);
    defer stress_env.deinit();
    try stress_env.put("BIT_GC", "stress");
    try stress_env.put("BIT_GC_STATS", "1");
    try runOnce(gpa, run_io, name, who, bin_path, expected, &stress_env, no_collect, timeout_s);
}

/// The prefix `gc.zig` writes per collection under `BIT_GC_STATS`. Counting
/// these is what makes the stress pass an oracle rather than a second default
/// run — see the header.
const collection_line = "[bit-gc] collection ";

fn runOnce(
    gpa: std.mem.Allocator,
    run_io: Io,
    name: []const u8,
    who: []const u8,
    bin_path: [:0]const u8,
    expected: []const u8,
    env: ?*const std.process.Environ.Map,
    no_collect: bool,
    timeout_s: u32,
) !void {
    const stress = env != null;
    const policy = if (stress) "BIT_GC=stress" else "default";
    const mode = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ who, policy });
    defer gpa.free(mode);
    const outcome = try proc.run(gpa, run_io, timeout_s, .{ .argv = &.{bin_path}, .environ_map = env });
    const result = switch (outcome) {
        .finished => |r| r,
        // A deadlock is the failure this corpus exists to catch, so it must be
        // named as one — not left as an unexplained stall, and not confused
        // with the crash case immediately below.
        .timed_out => |limit| {
            std.debug.print("stress '{s}' [{s}]: TIMED OUT\n", .{ name, mode });
            proc.timedOutNote(limit, bin_path);
            return error.StressRunTimedOut;
        },
    };
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    if (result.term == .signal) {
        std.debug.print("stress '{s}' [{s}]: CRASHED\n", .{ name, mode });
        proc.crashNote(result.term.signal);
        std.debug.print("stderr: {s}\n", .{result.stderr});
        return error.StressRunCrashed;
    }

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
    if (!stress or no_collect) return;

    // The oracle check. A zero count means every root this program cares about
    // was re-proven live exactly never, so the run above says nothing at all
    // about rooting — regardless of how much it allocated.
    const collections = std.mem.count(u8, result.stderr, collection_line);
    if (collections == 0) {
        std.debug.print(
            "stress '{s}' [{s}]: the collector never ran, so this run verified nothing about rooting.\n" ++
                "  Give the program a loop where the roots it cares about are live, or — if it is\n" ++
                "  proving something about emission or linking rather than rooting — add a\n" ++
                "  'no-collect' file to its directory stating why.\n",
            .{ name, mode },
        );
        return error.StressCollectorInert;
    }
}
