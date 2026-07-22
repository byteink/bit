//! Multi-module imports + prelude guard (#1153).
//!
//! Each direct subdirectory of `tests/imports/` is a root module (its `main`);
//! it may import project-relative modules (`./util`) and standard-library
//! modules (`std/core`), and it sees the auto-imported prelude. The harness
//! builds each through the real whole-project pipeline (`buildHostProject` ->
//! loadProject + per-module check + lowerProject), runs it, and diffs stdout
//! against the module's `expected` file — so cross-module lowering and the
//! prelude can never silently regress.
//!
//! The cases are independent, and the compiler holds no global mutable state,
//! so they run on a pool of `getCpuCount` worker threads — each with its own
//! arena and `Io`, and a per-case output binary. The 200+ full compile+link+run
//! cycles are the bulk of `zig build test`; fanning them across cores is a
//! near-linear speedup. Pass `-Dimports-filter=<name>` to run one project.
//!
//! Skipped when the host is not a supported runtime target (no libbitrt), like
//! the golden `// run` cases and the other guards.
//!
//! Both processes each case spawns — the self-hosted compiler's `bit build` and
//! each built binary — carry the shared deadline from `tests/proc.zig` (#1652).
//! This corpus is where this repo's real indefinite stalls came from (#1475's
//! `quicconn` teardown), and with 90+ projects on a worker pool a single hang
//! takes the whole suite down with no line naming the culprit. The seed's own
//! compile is in-process and is not bounded here.

const std = @import("std");
const bit = @import("bit");
const build_options = @import("build_options");
const proc = @import("proc.zig");

const testing = std.testing;
const Io = std.Io;
const Dir = std.Io.Dir;

const max_programs = 256;

const Case = struct { name: []const u8, dir_abs: []const u8 };

/// A case that phase 1 compiled and wrote to disk, ready for phase 2 to run.
/// Outlives its per-case compile arena, so every field comes from the gpa.
///
/// TWO binaries per case (#1484): one from the seed (in-process `buildHostProject`)
/// and one from the self-hosted `bit`. Phase 2 runs both and diffs both against
/// the same `expected`.
const Built = struct {
    bin_path: [:0]const u8,
    /// Null when the self-hosted compiler refused the project. Recorded rather
    /// than thrown, so the run can compare the whole self-hosted failure SET
    /// against the checked-in expectations in one pass.
    selfhost_bin_path: ?[:0]const u8,
    expected: []const u8,

    fn deinit(b: Built, gpa: std.mem.Allocator) void {
        gpa.free(b.bin_path);
        if (b.selfhost_bin_path) |p| gpa.free(p);
        gpa.free(b.expected);
    }
};

const Shared = struct {
    gpa: std.mem.Allocator,
    libbitrt: []const u8,
    cases: []const Case,
    /// Wall-clock seconds allowed to any one child. Read once on the main thread
    /// before either pool starts: the limit is a property of the host, and a
    /// worker re-reading the environment could disagree with its siblings.
    timeout_s: u32,
    next: std.atomic.Value(usize) = .init(0),
    failures: std.atomic.Value(usize) = .init(0),
    // Phase 1's output, phase 2's input. Null = that case never built.
    built: []?Built,
    // Per-case failure reason, parallel to `cases` (null = passed). Several
    // failure paths in `runProgram` are bare `try`s that print nothing (a failed
    // `std.process.run`, a missing `expected`, an unwritable binary), so a run
    // could report "1/85 programs failed" while naming neither the case nor the
    // reason. Recording the error name here and folding it into the final
    // (captured) failure message makes every failure self-describing. Each slot
    // is written by the single worker that claimed that index — no lock needed.
    failed_reason: []?[]const u8,
    // The self-hosted half, kept apart from the seed's tally (#1484). A slot
    // holds the error name if `bit` could not build or could not correctly run
    // that project, else null. Judged against `tests/selfhost-imports-gaps.txt`
    // after both phases, because the verdict is about the SET.
    selfhost_reason: []?[]const u8,
};

test "imports + prelude programs run with the expected output" {
    if (build_options.libbitrt_path.len == 0) return; // host not a runtime target

    // A host that can link libbitrt is a native build, and a native build always
    // produces the self-hosted `bit`. Asserted rather than degraded to a
    // seed-only pass: #1484 is precisely a harness that returned green while
    // half of what it claimed to check never ran. Same contract as
    // tests/stress.zig — an unwired selfhost path is a failure, not a skip.
    try testing.expect(build_options.selfhost_bit.len > 0);

    const gpa = testing.allocator;
    const io = Io.Threaded.global_single_threaded.io();

    var dir = Dir.openDirAbsolute(io, build_options.imports_dir, .{ .iterate = true }) catch |e| {
        std.debug.print("cannot open imports dir '{s}': {s}\n", .{ build_options.imports_dir, @errorName(e) });
        return e;
    };
    defer dir.close(io);

    // Read once; shared read-only across workers.
    const libbitrt = Dir.cwd().readFileAlloc(io, build_options.libbitrt_path, gpa, .limited(16 << 20)) catch |e| {
        std.debug.print("cannot read libbitrt '{s}': {s}\n", .{ build_options.libbitrt_path, @errorName(e) });
        return e;
    };
    defer gpa.free(libbitrt);

    // Collect the case list (optionally filtered to a single project).
    var cases: std.ArrayList(Case) = .empty;
    defer {
        for (cases.items) |c| {
            gpa.free(c.name);
            gpa.free(c.dir_abs);
        }
        cases.deinit(gpa);
    }
    const filter = build_options.imports_filter;
    var it = dir.iterate();
    var scanned: u32 = 0;
    while (scanned < max_programs) : (scanned += 1) {
        const entry = (try it.next(io)) orelse break;
        if (entry.kind != .directory) continue;
        if (filter.len != 0 and !std.mem.eql(u8, filter, entry.name)) continue;
        const name = try gpa.dupe(u8, entry.name);
        const dir_abs = try std.fs.path.join(gpa, &.{ build_options.imports_dir, name });
        try cases.append(gpa, .{ .name = name, .dir_abs = dir_abs });
    }
    try testing.expect(scanned < max_programs);
    if (filter.len != 0 and cases.items.len == 0) {
        std.debug.print("imports: -Dimports-filter='{s}' matched no project\n", .{filter});
        return error.ImportsFilterNoMatch;
    }
    if (cases.items.len == 0) return;

    const failed_reason = try gpa.alloc(?[]const u8, cases.items.len);
    defer gpa.free(failed_reason);
    @memset(failed_reason, null);

    const selfhost_reason = try gpa.alloc(?[]const u8, cases.items.len);
    defer gpa.free(selfhost_reason);
    @memset(selfhost_reason, null);

    const built = try gpa.alloc(?Built, cases.items.len);
    defer gpa.free(built);
    @memset(built, null);

    var shared: Shared = .{
        .gpa = gpa,
        .libbitrt = libbitrt,
        .cases = cases.items,
        .timeout_s = proc.timeoutSeconds(gpa),
        .failed_reason = failed_reason,
        .selfhost_reason = selfhost_reason,
        .built = built,
    };
    defer for (built) |b| if (b) |x| x.deinit(gpa);

    // Two phases, and the barrier between them is load-bearing — it is what keeps
    // `execve` off an inode that is still open for writing somewhere.
    //
    // `fork` duplicates the whole fd table, so a child spawned by worker B between
    // its `fork` and its `execve` holds a copy of every fd worker A had open at
    // that instant — including A's write fd to the binary A is about to run. Linux
    // refuses to `execve` an inode whose writecount is nonzero, so A's exec then
    // fails with ETXTBSY (Zig: `error.FileBusy`). O_CLOEXEC does not help: it only
    // closes the fd *at* execve, which is after the window that does the damage.
    // The paths are already unique per case, so this was never a filename
    // collision — it is purely fd inheritance, and it needs a writer thread and a
    // forking thread to overlap.
    //
    // Phase 1 compiles and writes every binary. Phase 2 runs them and writes
    // nothing. Once phase 2 begins no write fd to any of these binaries exists
    // anywhere in the process, so the race has no window left. Both phases stay
    // fully parallel, so the harness keeps its speedup.
    //
    // Phase 1 does now fork, once per case, to drive the self-hosted `bit`
    // (#1484) — and that is still safe, because the hazard is a LIVE child
    // holding an inherited write fd at the moment of an `execve`. `process.run`
    // reaps its child before returning and `runPool` joins every worker before
    // phase 2 starts, so by the first `execve` of a built binary no phase-1
    // child exists to hold anything open. What must not happen is a fork and an
    // exec of these binaries overlapping, and the barrier still forbids that.
    try runPool(gpa, &shared, buildWorker);
    shared.next.store(0, .monotonic);
    try runPool(gpa, &shared, runWorker);

    const failed = shared.failures.load(.monotonic);
    if (failed != 0) {
        std.debug.print("imports [seed]: {d}/{d} programs failed:", .{ failed, cases.items.len });
        for (cases.items, failed_reason) |c, reason| {
            if (reason) |r| std.debug.print(" {s}({s})", .{ c.name, r });
        }
        std.debug.print("\n", .{});
        return error.ImportsFailed;
    }

    try judgeSelfhost(gpa, io, cases.items, selfhost_reason, filter);
}

/// The self-hosted verdict (#1484): the set of projects `bit` failed on must
/// equal the checked-in expectation exactly.
///
/// A count would not do. With eleven projects blocked on one lowering gap, a
/// count stays put while a gap closes and a regression opens in its place, and
/// the two runs read identically — the same defect #1469 fixed in
/// `selfhost-diffir.sh`. So a name that ENTERS the failure set fails the gate,
/// and a name that LEAVES it fails too, which is what forces the list to be
/// pruned as the self-hosted compiler catches up.
fn judgeSelfhost(
    gpa: std.mem.Allocator,
    io: Io,
    cases: []const Case,
    reasons: []const ?[]const u8,
    filter: []const u8,
) !void {
    const text = Dir.cwd().readFileAlloc(io, build_options.selfhost_gaps, gpa, .limited(64 << 10)) catch |e| {
        std.debug.print("imports: cannot read expected-gap list '{s}': {s}\n", .{ build_options.selfhost_gaps, @errorName(e) });
        return e;
    };
    defer gpa.free(text);

    var entered: usize = 0;
    var stale: usize = 0;
    var held: usize = 0;

    for (cases, reasons) |c, reason| {
        const expected = gapListed(text, c.name);
        if (reason) |r| {
            if (expected) {
                held += 1;
                std.debug.print("imports [selfhost]: known gap still open: {s} ({s})\n", .{ c.name, r });
            } else {
                entered += 1;
                std.debug.print("imports [selfhost]: REGRESSION {s} ({s}) — not in {s}\n", .{ c.name, r, build_options.selfhost_gaps });
            }
        } else if (expected) {
            stale += 1;
            std.debug.print("imports [selfhost]: STALE gap {s} now builds and runs — delete it from {s}\n", .{ c.name, build_options.selfhost_gaps });
        }
    }

    std.debug.print(
        "imports [selfhost]: {d}/{d} projects OK, {d} known gap(s) held, {d} regression(s), {d} stale\n",
        .{ cases.len - held - entered, cases.len, held, entered, stale },
    );

    if (entered != 0) return error.ImportsSelfhostRegression;
    // With `-Dimports-filter` the case list is a single project, so every OTHER
    // listed gap is absent rather than closed; a stale verdict would be a lie.
    if (stale != 0 and filter.len == 0) return error.ImportsSelfhostStaleGap;
}

/// Whether `name` appears in the gap list. Lines are `name  # reason`; blank
/// lines and full-line comments are ignored.
fn gapListed(text: []const u8, name: []const u8) bool {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const no_comment = if (std.mem.indexOfScalar(u8, raw, '#')) |h| raw[0..h] else raw;
        const entry = std.mem.trim(u8, no_comment, " \t\r");
        if (entry.len == 0) continue;
        if (std.mem.eql(u8, entry, name)) return true;
    }
    return false;
}

/// Runs `f` over the case list on a pool of `getCpuCount` workers, and does not
/// return until every worker has finished — the barrier the phase split needs.
fn runPool(gpa: std.mem.Allocator, sh: *Shared, comptime f: fn (*Shared) void) !void {
    const want = std.Thread.getCpuCount() catch 4;
    const nthreads = @min(@max(want, 1), sh.cases.len);
    if (nthreads <= 1) {
        f(sh);
        return;
    }
    const threads = try gpa.alloc(std.Thread, nthreads);
    defer gpa.free(threads);
    var spawned: usize = 0;
    while (spawned < nthreads) : (spawned += 1) {
        threads[spawned] = std.Thread.spawn(.{}, f, .{sh}) catch break;
    }
    // Any that spawned run the work; if none did, run inline on this thread.
    if (spawned == 0) f(sh);
    for (threads[0..spawned]) |t| t.join();
}

/// Phase 1: compile each case and write its binary. Spawns no process, so no
/// sibling `fork` can capture the write fds these workers hold.
fn buildWorker(sh: *Shared) void {
    while (true) {
        const i = sh.next.fetchAdd(1, .monotonic);
        if (i >= sh.cases.len) break;
        const c = sh.cases[i];
        // One arena per case: the compile allocates a lot and frees nothing;
        // deinit reclaims it all at once, so no per-allocation bookkeeping. The
        // two values phase 2 needs outlive it, so they come from the gpa.
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        sh.built[i] = buildProgram(arena.allocator(), sh.gpa, sh.libbitrt, c.name, c.dir_abs, sh.timeout_s, &sh.selfhost_reason[i]) catch |e| {
            _ = sh.failures.fetchAdd(1, .monotonic);
            sh.failed_reason[i] = @errorName(e);
            continue;
        };
    }
}

/// Phase 2: run each built binary and diff its stdout. Writes no files, so no
/// `execve` here can find its own inode still open for writing.
fn runWorker(sh: *Shared) void {
    while (true) {
        const i = sh.next.fetchAdd(1, .monotonic);
        if (i >= sh.cases.len) break;
        const b = sh.built[i] orelse continue; // never built; phase 1 already counted it
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        runProgram(arena.allocator(), sh.cases[i].name, b, sh.timeout_s, &sh.selfhost_reason[i]) catch |e| {
            _ = sh.failures.fetchAdd(1, .monotonic);
            sh.failed_reason[i] = @errorName(e);
        };
    }
}

fn buildProgram(
    arena: std.mem.Allocator,
    gpa: std.mem.Allocator,
    libbitrt: []const u8,
    name: []const u8,
    dir_abs: []const u8,
    timeout_s: u32,
    selfhost_reason: *?[]const u8,
) !Built {
    // Each worker gets its own Io: the shared single-threaded one is not
    // reentrant, and compile + run must not race across threads.
    var threaded = Io.Threaded.init(arena, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var discard: Io.Writer.Allocating = .init(arena);
    defer discard.deinit();
    const exe = (try bit.buildHostProject(arena, io, dir_abs, build_options.stdlib_dir, name, libbitrt, &discard.writer)) orelse {
        std.debug.print("imports '{s}': compile failed:\n{s}\n", .{ name, discard.written() });
        return error.ImportsCompileFailed;
    };

    const expected_path = try std.fmt.allocPrint(arena, "{s}/expected", .{dir_abs});
    const expected = try Dir.cwd().readFileAlloc(io, expected_path, gpa, .limited(64 << 10));
    errdefer gpa.free(expected);

    // Unique per case (name is unique), so parallel workers never collide.
    const bin_path = try std.fmt.allocPrintSentinel(gpa, "/tmp/bit-imports-{s}-{x}", .{ name, testing.random_seed }, 0);
    errdefer gpa.free(bin_path);

    try Dir.cwd().writeFile(io, .{ .sub_path = bin_path, .data = exe, .flags = .{ .permissions = .executable_file } });

    // The same project through the self-hosted compiler, to its own path. A
    // failure here is a real failure: `bit` must build everything the seed can.
    const selfhost_bin_path = try std.fmt.allocPrintSentinel(gpa, "/tmp/bit-imports-{s}-{x}-selfhost", .{ name, testing.random_seed }, 0);
    errdefer gpa.free(selfhost_bin_path);
    buildSelfhost(arena, io, name, dir_abs, selfhost_bin_path, timeout_s) catch |e| {
        selfhost_reason.* = @errorName(e);
        gpa.free(selfhost_bin_path);
        return .{ .bin_path = bin_path, .selfhost_bin_path = null, .expected = expected };
    };

    return .{ .bin_path = bin_path, .selfhost_bin_path = selfhost_bin_path, .expected = expected };
}

/// Compiles `dir_abs` with the self-hosted `bit` binary to `out_path`. It finds
/// its stdlib and runtime archive from the environment, like tests/stress.zig.
fn buildSelfhost(
    arena: std.mem.Allocator,
    io: Io,
    name: []const u8,
    dir_abs: []const u8,
    out_path: [:0]const u8,
    timeout_s: u32,
) !void {
    var env = std.process.Environ.Map.init(arena);
    defer env.deinit();
    try env.put("BIT_LIBBITRT", build_options.libbitrt_path);
    try env.put("BIT_STDLIB", build_options.stdlib_dir);

    // The compiler is bounded too: a compiler that loops forever stalls the
    // suite exactly as a hung program does, and says even less about why.
    const outcome = try proc.run(arena, io, timeout_s, .{
        .argv = &.{ build_options.selfhost_bit, "build", dir_abs, "-o", out_path },
        .environ_map = &env,
    });
    const result = switch (outcome) {
        .finished => |r| r,
        .timed_out => |limit| {
            std.debug.print("imports '{s}' [selfhost]: COMPILE TIMED OUT\n", .{name});
            proc.timedOutNote(limit, build_options.selfhost_bit);
            return error.ImportsSelfhostCompileTimedOut;
        },
    };
    const ok = switch (result.term) {
        .exited => |c| c == 0,
        else => false,
    };
    if (ok) return;
    std.debug.print("imports '{s}' [selfhost]: compile failed:\n{s}{s}\n", .{ name, result.stdout, result.stderr });
    return error.ImportsSelfhostCompileFailed;
}

fn runProgram(arena: std.mem.Allocator, name: []const u8, b: Built, timeout_s: u32, selfhost_reason: *?[]const u8) !void {
    var threaded = Io.Threaded.init(arena, .{});
    defer threaded.deinit();
    const io = threaded.io();

    defer Dir.cwd().deleteFile(io, b.bin_path) catch {};
    defer if (b.selfhost_bin_path) |p| Dir.cwd().deleteFile(io, p) catch {};

    // The seed's verdict is unconditional. The self-hosted one is recorded and
    // judged against the expected-gap set once every case has reported.
    try runOne(arena, io, name, "seed", b.bin_path, b.expected, timeout_s);
    if (b.selfhost_bin_path) |p| {
        runOne(arena, io, name, "selfhost", p, b.expected, timeout_s) catch |e| {
            selfhost_reason.* = @errorName(e);
        };
    }
}

/// One built binary against `expected`. `who` names the compiler that produced
/// it, so a failure says which of the two is wrong without a second run.
///
/// Three outcomes are kept apart, as in the golden harness: a DEADLINE expiry is
/// the machine intervening and reads as a hang; a SIGNAL the program raised on
/// itself (SIGSEGV/SIGBUS/SIGABRT) is a result and reads as a crash naming the
/// signal; anything else is an ordinary exit code.
fn runOne(
    arena: std.mem.Allocator,
    io: Io,
    name: []const u8,
    who: []const u8,
    bin_path: [:0]const u8,
    expected: []const u8,
    timeout_s: u32,
) !void {
    const outcome = try proc.run(arena, io, timeout_s, .{ .argv = &.{bin_path} });
    const result = switch (outcome) {
        .finished => |r| r,
        .timed_out => |limit| {
            std.debug.print("imports '{s}' [{s}]: TIMED OUT\n", .{ name, who });
            proc.timedOutNote(limit, bin_path);
            return error.ImportsRunTimedOut;
        },
    };
    if (result.term == .signal) {
        std.debug.print("imports '{s}' [{s}]: CRASHED\n", .{ name, who });
        proc.crashNote(result.term.signal);
        std.debug.print("stderr: {s}\n", .{result.stderr});
        return error.ImportsRunCrashed;
    }
    const code: u8 = switch (result.term) {
        .exited => |c| c,
        else => 255,
    };
    if (code != 0) {
        std.debug.print("imports '{s}' [{s}]: exited {d}\nstderr: {s}\n", .{ name, who, code, result.stderr });
        return error.ImportsRunFailed;
    }
    if (!std.mem.eql(u8, result.stdout, expected)) {
        std.debug.print("imports '{s}' [{s}]: output mismatch\n  expected: {s}\n  got:      {s}\n", .{ name, who, expected, result.stdout });
        return error.ImportsOutputMismatch;
    }
}
