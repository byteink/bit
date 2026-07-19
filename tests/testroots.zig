//! Orphaned-test-file gate: every `.zig` file under `seed/` and `runtime/` that
//! contains tests must have those tests collected by at least one wired test
//! root, or the build fails.
//!
//! ## Why this exists
//!
//! Twice in one day a file's tests turned out never to have executed:
//! `seed/link/macho.zig` (#1445), including its end-to-end "boots on macOS"
//! test, and `seed/lower.zig` + `seed/lsp.zig` (#1453) — 23 tests covering the
//! lowering pass, one of the largest modules in the seed, and the whole LSP.
//! All of them passed standalone; none had ever failed a build, because none
//! had ever run. Fixing the three files does nothing to stop the fourth, so the
//! actual deliverable is this check.
//!
//! ## Why it measures instead of reading imports
//!
//! The tempting rule — "a file the root merely imports doesn't collect" — is
//! wrong, and reasoning from it is how these survive review. Collection is
//! *partial*: `seed/check.zig`'s 11 tests DO run under the `seed/main.zig`
//! root, `seed/ir.zig`'s 4 under `seed/emit.zig`'s, `runtime/{net,rand,gc}`'s
//! under `runtime/root.zig`'s — while `lower.zig` and `lsp.zig` fell through
//! every root. Import-graph reachability calls all of those covered and cannot
//! tell the two groups apart.
//!
//! So the gate asks the compiler. For each wired root it runs `zig test` with
//! `tests/list_test_runner.zig`, which prints `builtin.test_functions` — the
//! very list the real runner would execute — and runs nothing. What comes back
//! is an observation, not a prediction.
//!
//! ## The namespace mapping
//!
//! A collected test is named `<namespace>.test.<title>`, where `<namespace>` is
//! the file's path relative to its module root, `/` → `.`, `.zig` dropped. So
//! `seed/link/object.zig` collected under a `seed/`-rooted module appears as
//! `link.object`. The same file can carry different namespaces under different
//! roots (`seed/obj/elf.zig` is `elf` as its own root and `obj.elf` under
//! `seed/link.zig`), so coverage is decided per (root, file) pair.
//!
//! ## What a failure means
//!
//! A named file's tests are dead weight: they pass in isolation, they read as
//! coverage, and they can never fail the build. Wire the file into a root in
//! `build.zig`'s `test_roots` table — directly if it roots cleanly, or via an
//! anchor file if its relative imports need a wider root (see
//! `seed/codegen_x64_test.zig`). This gate also backstops the namespace filter
//! on the `seed/lower_lsp_test.zig` entry: if that filter stops matching, the
//! entry silently runs zero tests, and it surfaces here as an orphan.

const std = @import("std");
const build_options = @import("build_options");

const testing = std.testing;
const Io = std.Io;
const Dir = std.Io.Dir;

/// Directories swept for test-bearing files. Anything else (`tests/`,
/// `selfhost/`) is out of scope: the harnesses under `tests/` are themselves
/// roots, and `selfhost/` is Bit, not Zig.
const swept_dirs = [_][]const u8{ "seed", "runtime" };

/// Files excluded from the sweep, each with the reason. Kept explicit and
/// short: an exception that is merely convenient is how a gate rots.
///
/// The host-gated entry is stated rather than silently skipped on purpose.
/// #1438 audited the stress corpus on macOS and missed `tlsstate` because the
/// host skipped it — an audit inherits its host's blind spot unless it says out
/// loud what it did not look at.
///
/// "Out loud" is this table plus the failure report, not a line on every green
/// build: printing it unconditionally made Zig tag a passing step `failed
/// command:` (#1468). `unless_os` is mandatory so the disclosure is enforced
/// rather than merely narrated.
const Exception = struct {
    path: []const u8,
    /// The OS on which this file IS swept. Excused only on other hosts.
    ///
    /// Mandatory, and asserted below. An exception excused on every host is a
    /// permanent coverage hole wearing the costume of a documented one — the
    /// exact shape #1453 exists to prevent. Every excuse must name a host that
    /// makes good on it.
    unless_os: []const u8,
    why: []const u8,
};
const exceptions = [_]Exception{
    .{
        .path = "runtime/shims.zig",
        .unless_os = "linux",
        .why = "@compileError's off Linux, so it cannot be built (let alone collected) on this host; it IS wired and measured on a Linux host",
    },
};

/// Max bytes read from a source file when looking for test blocks. The largest
/// file in the sweep is well under this; a file that exceeds it is a bug in
/// this constant, not a reason to grow it silently, so it is asserted.
const max_source_bytes = 4 << 20;

/// Upper bound on files swept. Guards the walk against an unbounded directory
/// tree; ~41 files carry tests today across ~90 total.
const max_swept_files = 4096;

const Namespace = []const u8;

/// `seed/link/object.zig` relative to root dir `seed` -> `link.object`.
fn namespaceFor(gpa: std.mem.Allocator, root_dir: []const u8, file: []const u8) !?Namespace {
    if (!std.mem.startsWith(u8, file, root_dir)) return null;
    if (file.len <= root_dir.len or file[root_dir.len] != '/') return null;
    const rel = file[root_dir.len + 1 ..];
    if (!std.mem.endsWith(u8, rel, ".zig")) return null;
    const stem = rel[0 .. rel.len - ".zig".len];
    const ns = try gpa.dupe(u8, stem);
    for (ns) |*c| {
        if (c.* == '/') c.* = '.';
    }
    return ns;
}

/// The namespace part of a collected test's fully-qualified name.
///
/// Zig spells the two kinds of test block differently, and missing the second
/// makes every anchor file (`test { _ = @import("..."); }`) look orphaned:
///   - named:   `link.object.test.reads an archive member`
///   - unnamed: `codegen_arm64_test.test_0`
fn namespaceOfTestName(name: []const u8) ?[]const u8 {
    if (std.mem.indexOf(u8, name, ".test.")) |cut| return name[0..cut];

    // `.test_<digits>`, and only as a suffix — a namespace could legitimately
    // contain the substring elsewhere.
    const marker = ".test_";
    const at = std.mem.lastIndexOf(u8, name, marker) orelse return null;
    const digits = name[at + marker.len ..];
    if (digits.len == 0) return null;
    for (digits) |c| if (!std.ascii.isDigit(c)) return null;
    return name[0..at];
}

/// The directory a module rooted at `root_file` resolves imports against.
fn rootDirOf(root_file: []const u8) []const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, root_file, '/') orelse return ".";
    return root_file[0..slash];
}

/// True when the file declares at least one *named* test block (`test "..."`).
///
/// Named only, on purpose. An unnamed `test { _ = @import("x.zig"); }` block
/// asserts nothing — it is the anchor idiom for pulling a file into a wider
/// module root (`seed/codegen_x64_test.zig` and friends). Counting those would
/// make every anchor demand coverage of itself, and Zig does not apply
/// `--test-filter` to them anyway, so they cannot be reasoned about the same
/// way. What this gate protects is test cases, and a test case has a name.
///
/// Deliberately textual: the question is "does this file claim to have tests",
/// so a file whose tests are commented out is not this gate's problem.
fn hasTests(src: []const u8) bool {
    var it = std.mem.splitScalar(u8, src, '\n');
    while (it.next()) |line| {
        const t = std.mem.trimStart(u8, line, " \t");
        if (!std.mem.startsWith(u8, t, "test")) continue;
        const rest = std.mem.trimStart(u8, t["test".len..], " \t");
        if (rest.len != 0 and rest[0] == '"') return true;
    }
    return false;
}

fn excusedReason(path: []const u8) ?[]const u8 {
    for (exceptions) |e| {
        if (!std.mem.eql(u8, e.path, path)) continue;
        if (std.mem.eql(u8, e.unless_os, build_options.host_os)) continue;
        return e.why;
    }
    return null;
}

/// Every namespace the given root actually collects, per the compiler.
/// True when `name` would actually be executed under `filters` (newline-joined,
/// empty = unfiltered). Mirrors `--test-filter`: a substring match on the
/// fully-qualified name, any one of which is enough.
fn passesFilter(name: []const u8, filters: []const u8) bool {
    if (filters.len == 0) return true;
    var it = std.mem.splitScalar(u8, filters, '\n');
    while (it.next()) |f| {
        if (f.len == 0) continue;
        if (std.mem.indexOf(u8, name, f) != null) return true;
    }
    return false;
}

/// Every namespace the given root actually *executes*, per the compiler.
///
/// Filters are applied here rather than ignored, because the question this gate
/// answers is "do these tests run", not "does something collect them". A root
/// whose filter matches nothing collects plenty and runs none.
fn collectedNamespaces(
    gpa: std.mem.Allocator,
    io: Io,
    root_file: []const u8,
    filters: []const u8,
) !std.StringHashMapUnmanaged(void) {
    var out: std.StringHashMapUnmanaged(void) = .empty;
    errdefer out.deinit(gpa);

    const abs_root = try std.fs.path.join(gpa, &.{ build_options.repo_root, root_file });
    defer gpa.free(abs_root);

    const result = try std.process.run(gpa, io, .{
        .argv = &.{
            build_options.zig_exe,
            "test",
            abs_root,
            "--test-runner",
            build_options.list_runner,
            "--global-cache-dir",
            build_options.global_cache_root,
            "--cache-dir",
            build_options.local_cache_root,
        },
        .stdout_limit = .limited(8 << 20),
        .stderr_limit = .limited(1 << 20),
    });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);

    // A root that will not even build is a hard failure, not an orphan: the gate
    // would otherwise report every file under it as uncovered and bury the real
    // error. Report the compiler's own message.
    if (result.term != .exited or result.term.exited != 0) {
        std.debug.print(
            "testroots: listing tests for root '{s}' failed ({any}):\n{s}\n",
            .{ root_file, result.term, result.stderr },
        );
        return error.TestRootDoesNotBuild;
    }

    var it = std.mem.splitScalar(u8, result.stdout, '\n');
    while (it.next()) |line| {
        const name = std.mem.trim(u8, line, " \r\t");
        if (name.len == 0) continue;
        if (!passesFilter(name, filters)) continue;
        const ns = namespaceOfTestName(name) orelse continue;
        const gop = try out.getOrPut(gpa, ns);
        if (!gop.found_existing) gop.key_ptr.* = try gpa.dupe(u8, ns);
    }
    return out;
}

/// Every `.zig` file under the swept dirs, repo-relative, that declares tests.
fn sweepTestBearingFiles(gpa: std.mem.Allocator, io: Io) !std.ArrayList([]const u8) {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(gpa);

    var seen: usize = 0;
    for (swept_dirs) |dir_name| {
        const abs = try std.fs.path.join(gpa, &.{ build_options.repo_root, dir_name });
        defer gpa.free(abs);

        var dir = try Dir.openDirAbsolute(io, abs, .{ .iterate = true });
        defer dir.close(io);

        var walker = try dir.walk(gpa);
        defer walker.deinit();

        while (try walker.next(io)) |entry| {
            seen += 1;
            try testing.expect(seen <= max_swept_files);
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.basename, ".zig")) continue;

            const src = try entry.dir.readFileAlloc(io, entry.basename, gpa, .limited(max_source_bytes));
            defer gpa.free(src);
            if (!hasTests(src)) continue;

            const rel = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ dir_name, entry.path });
            errdefer gpa.free(rel);
            // Walker paths are host-native; the rest of this gate compares them
            // against POSIX-style paths from build.zig.
            for (rel) |*c| {
                if (c.* == '\\') c.* = '/';
            }
            try out.append(gpa, rel);
        }
    }
    std.mem.sort([]const u8, out.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);
    return out;
}

test "every test-bearing file under seed/ and runtime/ is collected by a wired root" {
    // A dedicated `Io.Threaded` over an arena, matching tests/diffimports.zig:
    // `std.process.run`'s spawn arena is backed by the io's allocator, and
    // mixing the global io's allocator with the per-test allocator trips the
    // leak detector.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const gpa = arena_state.allocator();

    var threaded = Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var files = try sweepTestBearingFiles(gpa, io);
    defer {
        for (files.items) |f| gpa.free(f);
        files.deinit(gpa);
    }
    // A sweep that finds nothing would vacuously pass. It must find the files we
    // know carry tests.
    try testing.expect(files.items.len >= 20);

    // Measure each root once, then decide coverage per (root, file) pair.
    var per_root: std.ArrayList(std.StringHashMapUnmanaged(void)) = .empty;
    defer {
        for (per_root.items) |*m| {
            var it = m.keyIterator();
            while (it.next()) |k| gpa.free(k.*);
            m.deinit(gpa);
        }
        per_root.deinit(gpa);
    }
    try testing.expect(build_options.roots.len >= 10);
    try testing.expectEqual(build_options.roots.len, build_options.root_filters.len);
    for (build_options.roots, build_options.root_filters) |root_file, filters| {
        try per_root.append(gpa, try collectedNamespaces(gpa, io, root_file, filters));
    }

    var orphans: std.ArrayList([]const u8) = .empty;
    defer orphans.deinit(gpa);
    // Excusals are recorded, not printed. A green build must write nothing to
    // stderr: Zig's build runner tags any step that produced stderr with
    // `failed command:`, so a chatty passing gate ends every green build with
    // the word "failed" (#1468) and teaches the reader to skim past it. The
    // disclosure #1438 asked for is preserved two ways that cost nothing when
    // green — the excusals print inside the failure report below, and the
    // "every excuse names a host that honours it" rule is asserted outright.
    var excusals: std.ArrayList([]const u8) = .empty;
    defer excusals.deinit(gpa);

    for (files.items) |file| {
        if (excusedReason(file)) |why| {
            try excusals.append(gpa, try std.fmt.allocPrint(gpa, "{s} ({s})", .{ file, why }));
            continue;
        }
        var covered = false;
        for (build_options.roots, per_root.items) |root_file, collected| {
            const ns = try namespaceFor(gpa, rootDirOf(root_file), file) orelse continue;
            defer gpa.free(ns);
            if (collected.contains(ns)) {
                covered = true;
                break;
            }
        }
        if (!covered) try orphans.append(gpa, file);
    }

    if (orphans.items.len != 0) {
        std.debug.print(
            \\
            \\testroots: {d} of {d} test-bearing file(s) declare tests that NO wired
            \\test root collects. Their tests pass standalone, read as coverage, and
            \\can never fail the build. Wire each into build.zig's `test_roots` table
            \\— directly, or via an anchor file if its relative imports need a wider
            \\module root.
            \\
        , .{ orphans.items.len, files.items.len });
        for (orphans.items) |f| std.debug.print("  orphaned: {s}\n", .{f});
        // What this host did NOT look at belongs in the failure report: an audit
        // inherits its host's blind spot unless it says so out loud (#1438).
        for (excusals.items) |e| std.debug.print("  not swept on this host: {s}\n", .{e});
        std.debug.print("\n", .{});
        return error.OrphanedTestFile;
    }
}

test "every excuse names a host that honours it" {
    // An exception with no `unless_os` would be excused everywhere, covering
    // nothing on every host while reading as a documented, bounded gap. The
    // field is non-optional so this cannot be forgotten, and a blank one is
    // rejected here rather than being quietly treated as "always excused".
    for (exceptions) |e| {
        try testing.expect(e.unless_os.len != 0);
        try testing.expect(e.why.len != 0);
        try testing.expect(e.path.len != 0);
    }
}

test "namespaceFor maps a nested path to its dotted namespace" {
    const gpa = std.testing.allocator;

    const nested = (try namespaceFor(gpa, "seed", "seed/link/object.zig")).?;
    defer gpa.free(nested);
    try testing.expectEqualStrings("link.object", nested);

    const flat = (try namespaceFor(gpa, "seed", "seed/lower.zig")).?;
    defer gpa.free(flat);
    try testing.expectEqualStrings("lower", flat);

    // A file outside the root dir has no namespace under it. Without this the
    // gate would happily match `runtime/gc.zig` against a `seed/` root.
    try testing.expect(try namespaceFor(gpa, "seed", "runtime/gc.zig") == null);
    // Prefix-but-not-a-directory must not match either.
    try testing.expect(try namespaceFor(gpa, "seed", "seedling/x.zig") == null);
}

test "hasTests counts named test blocks only" {
    try testing.expect(hasTests("test \"a thing\" {\n}\n"));
    try testing.expect(hasTests("    test \"indented\" {\n    }\n"));
    // The anchor idiom: asserts nothing, so it is not coverage to protect.
    try testing.expect(!hasTests("test {\n    _ = @import(\"x.zig\");\n}\n"));
    try testing.expect(!hasTests("const testing = std.testing;\n"));
    try testing.expect(!hasTests("// test \"commented out\" {}\n"));
    try testing.expect(!hasTests("fn tester() void {}\n"));
}

test "namespaceOfTestName handles named and unnamed test blocks" {
    try testing.expectEqualStrings(
        "link.object",
        namespaceOfTestName("link.object.test.reads an archive member").?,
    );
    // Anchor files carry only an unnamed block. Missing this form made every
    // anchor in the tree read as orphaned.
    try testing.expectEqualStrings("codegen_arm64_test", namespaceOfTestName("codegen_arm64_test.test_0").?);
    try testing.expectEqualStrings("lower", namespaceOfTestName("lower.test_12").?);
    // `.test_` must be a suffix with digits, not merely present.
    try testing.expect(namespaceOfTestName("a.test_x.b") == null);
    try testing.expect(namespaceOfTestName("nothing here") == null);
}

test "passesFilter models --test-filter, including the stale-filter case" {
    try testing.expect(passesFilter("lower.test.anything", ""));
    try testing.expect(passesFilter("lower.test.anything", "lower.test.\nlsp.test."));
    try testing.expect(passesFilter("lsp.test.anything", "lower.test.\nlsp.test."));
    // The case that made this gate wrong before it was fixed: a filter that no
    // longer matches leaves a root that builds and runs nothing.
    try testing.expect(!passesFilter("lower.test.anything", "NOPE.test."));
    try testing.expect(!passesFilter("parser.test.anything", "lower.test.\nlsp.test."));
}

test "rootDirOf yields the module root directory" {
    try testing.expectEqualStrings("seed", rootDirOf("seed/lower.zig"));
    try testing.expectEqualStrings("seed/obj", rootDirOf("seed/obj/elf.zig"));
    try testing.expectEqualStrings(".", rootDirOf("build.zig"));
}
