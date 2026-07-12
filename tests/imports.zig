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
const bitc = @import("bitc");
const build_options = @import("build_options");

const testing = std.testing;
const Io = std.Io;
const Dir = std.Io.Dir;

const max_programs = 256;

const Case = struct { name: []const u8, dir_abs: []const u8 };

const Shared = struct {
    libbitrt: []const u8,
    cases: []const Case,
    next: std.atomic.Value(usize) = .init(0),
    failures: std.atomic.Value(usize) = .init(0),
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

    var shared: Shared = .{ .libbitrt = libbitrt, .cases = cases.items };

    const want = std.Thread.getCpuCount() catch 4;
    const nthreads = @min(@max(want, 1), cases.items.len);
    if (nthreads <= 1) {
        worker(&shared);
    } else {
        const threads = try gpa.alloc(std.Thread, nthreads);
        defer gpa.free(threads);
        var spawned: usize = 0;
        while (spawned < nthreads) : (spawned += 1) {
            threads[spawned] = std.Thread.spawn(.{}, worker, .{&shared}) catch break;
        }
        // Any that spawned run the work; if none did, run inline on this thread.
        if (spawned == 0) worker(&shared);
        for (threads[0..spawned]) |t| t.join();
    }

    const failed = shared.failures.load(.monotonic);
    if (failed != 0) {
        std.debug.print("imports: {d}/{d} programs failed\n", .{ failed, cases.items.len });
        return error.ImportsFailed;
    }
}

fn worker(sh: *Shared) void {
    while (true) {
        const i = sh.next.fetchAdd(1, .monotonic);
        if (i >= sh.cases.len) break;
        const c = sh.cases[i];
        // One arena per case: the compile allocates a lot and frees nothing;
        // deinit reclaims it all at once, so no per-allocation bookkeeping.
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        runProgram(arena.allocator(), sh.libbitrt, c.name, c.dir_abs) catch {
            _ = sh.failures.fetchAdd(1, .monotonic);
        };
    }
}

fn runProgram(gpa: std.mem.Allocator, libbitrt: []const u8, name: []const u8, dir_abs: []const u8) !void {
    // Each worker gets its own Io: the shared single-threaded one is not
    // reentrant, and compile + run must not race across threads.
    var threaded = Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var discard: Io.Writer.Allocating = .init(gpa);
    defer discard.deinit();
    const exe = (try bitc.buildHostProject(gpa, io, dir_abs, build_options.stdlib_dir, name, libbitrt, &discard.writer)) orelse {
        std.debug.print("imports '{s}': compile failed:\n{s}\n", .{ name, discard.written() });
        return error.ImportsCompileFailed;
    };

    const expected_path = try std.fmt.allocPrint(gpa, "{s}/expected", .{dir_abs});
    const expected = try Dir.cwd().readFileAlloc(io, expected_path, gpa, .limited(64 << 10));

    // Unique per case (name is unique), so parallel workers never collide.
    const bin_path = try std.fmt.allocPrintSentinel(gpa, "/tmp/bit-imports-{s}-{x}", .{ name, testing.random_seed }, 0);
    try Dir.cwd().writeFile(io, .{ .sub_path = bin_path, .data = exe, .flags = .{ .permissions = .executable_file } });
    defer Dir.cwd().deleteFile(io, bin_path) catch {};

    const result = try std.process.run(gpa, io, .{ .argv = &.{bin_path} });
    const code: u8 = switch (result.term) {
        .exited => |c| c,
        else => 255,
    };
    if (code != 0) {
        std.debug.print("imports '{s}': exited {d}\nstderr: {s}\n", .{ name, code, result.stderr });
        return error.ImportsRunFailed;
    }
    if (!std.mem.eql(u8, result.stdout, expected)) {
        std.debug.print("imports '{s}': output mismatch\n  expected: {s}\n  got:      {s}\n", .{ name, expected, result.stdout });
        return error.ImportsOutputMismatch;
    }
}
