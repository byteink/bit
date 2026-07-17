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

const std = @import("std");
const bit = @import("bit");
const build_options = @import("build_options");

const testing = std.testing;
const Io = std.Io;
const Dir = std.Io.Dir;

const max_programs = 256;

const Case = struct { name: []const u8, dir_abs: []const u8 };

/// A case that phase 1 compiled and wrote to disk, ready for phase 2 to run.
/// Outlives its per-case compile arena, so both fields come from the gpa.
const Built = struct {
    bin_path: [:0]const u8,
    expected: []const u8,

    fn deinit(b: Built, gpa: std.mem.Allocator) void {
        gpa.free(b.bin_path);
        gpa.free(b.expected);
    }
};

const Shared = struct {
    gpa: std.mem.Allocator,
    libbitrt: []const u8,
    cases: []const Case,
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
};

test "imports + prelude programs run with the expected output" {
    if (build_options.libbitrt_path.len == 0) return; // host not a runtime target

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

    const built = try gpa.alloc(?Built, cases.items.len);
    defer gpa.free(built);
    @memset(built, null);

    var shared: Shared = .{
        .gpa = gpa,
        .libbitrt = libbitrt,
        .cases = cases.items,
        .failed_reason = failed_reason,
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
    // Phase 1 compiles and writes every binary and forks nothing. Phase 2 runs
    // them and writes nothing. Once phase 2 begins no write fd to any of these
    // binaries exists anywhere in the process, so the race has no window left.
    // Both phases stay fully parallel, so the harness keeps its speedup.
    try runPool(gpa, &shared, buildWorker);
    shared.next.store(0, .monotonic);
    try runPool(gpa, &shared, runWorker);

    const failed = shared.failures.load(.monotonic);
    if (failed != 0) {
        std.debug.print("imports: {d}/{d} programs failed:", .{ failed, cases.items.len });
        for (cases.items, failed_reason) |c, reason| {
            if (reason) |r| std.debug.print(" {s}({s})", .{ c.name, r });
        }
        std.debug.print("\n", .{});
        return error.ImportsFailed;
    }
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
        sh.built[i] = buildProgram(arena.allocator(), sh.gpa, sh.libbitrt, c.name, c.dir_abs) catch |e| {
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
        runProgram(arena.allocator(), sh.cases[i].name, b) catch |e| {
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
    return .{ .bin_path = bin_path, .expected = expected };
}

fn runProgram(arena: std.mem.Allocator, name: []const u8, b: Built) !void {
    var threaded = Io.Threaded.init(arena, .{});
    defer threaded.deinit();
    const io = threaded.io();

    defer Dir.cwd().deleteFile(io, b.bin_path) catch {};

    const result = try std.process.run(arena, io, .{ .argv = &.{b.bin_path} });
    const code: u8 = switch (result.term) {
        .exited => |c| c,
        else => 255,
    };
    if (code != 0) {
        std.debug.print("imports '{s}': exited {d}\nstderr: {s}\n", .{ name, code, result.stderr });
        return error.ImportsRunFailed;
    }
    if (!std.mem.eql(u8, result.stdout, b.expected)) {
        std.debug.print("imports '{s}': output mismatch\n  expected: {s}\n  got:      {s}\n", .{ name, b.expected, result.stdout });
        return error.ImportsOutputMismatch;
    }
}
