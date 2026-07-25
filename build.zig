const std = @import("std");

/// Wires the host `libbitrt.a` into a test harness as the `libbitrt_path` build
/// option. `bin` is the freshly-built runtime archive (the `lib`'s emitted
/// binary) when the host is a supported runtime target, else null. Uses
/// `addOptionPath` rather than a static install-path string on purpose: it both
/// resolves the option to the *current* archive and records a build-graph
/// dependency on it, so a harness can never link a stale, ABI-mismatched runtime
/// (a mismatch links a malformed binary the kernel then kills by signal). The
/// archive is rebuilt and the path re-resolved whenever a runtime source
/// changes. When the host is not a runtime target the option is the empty
/// string and the harness self-skips.
fn wireLibbitrt(opts: *std.Build.Step.Options, bin: ?std.Build.LazyPath) void {
    if (bin) |lp| opts.addOptionPath("libbitrt_path", lp) else opts.addOption([]const u8, "libbitrt_path", "");
}

/// Gives an already-constructed test RUN its own independently-runnable step
/// (mirroring test-stress/test-imports), without building a second artifact —
/// the umbrella `test` step and the named step both depend on the same `run`.
fn addNamedRun(b: *std.Build, run: *std.Build.Step.Run, name: []const u8, desc: []const u8) void {
    b.step(name, desc).dependOn(&run.step);
}

/// Rebuild-cache gate (#1796): `libbitrt.a` and the self-hosted `bit` are each
/// produced by a step that reads its true sources at runtime (`root.zig`'s
/// `runtime/**/*.zig` today, `selfhost/**/*.bit` always) — invisible to Zig's
/// own build cache, so both were forced with `has_side_effects = true` and
/// paid their full cost on every invocation regardless of change. This
/// computes a content fingerprint over the REAL inputs and compares it to a
/// stamp file so an unchanged tree can skip straight to the existing
/// artifact. Correctness rule: any read/parse/missing-file surprise reports
/// "changed" (falls back to a full rebuild) — never the reverse. Over-hashing
/// is deliberate too: `build.zig` and `.zigversion` are folded in because a
/// flag or toolchain change can alter the output without touching a single
/// `.bit`/`.zig` source file.
///
/// Hashes every regular file under each of `dirs` (recursive, no extension
/// filter — a new file type silently joining the input set is exactly the
/// failure mode to avoid) plus every path in `extra_files`, sorted by
/// slash-joined relative path so host walk order never perturbs the digest.
/// `fold_in`, when given, is mixed in as one more entry (e.g. a prerequisite
/// gate's own fingerprint), so a change to libbitrt is visible to the
/// self-host gate without re-reading libbitrt.a's bytes.
fn fingerprintTree(
    b: *std.Build,
    dirs: []const []const u8,
    extra_files: []const []const u8,
    fold_in: ?[64]u8,
) [64]u8 {
    const io = b.graph.io;
    var rel_paths: std.ArrayList([]const u8) = .empty;
    defer rel_paths.deinit(b.allocator);

    for (dirs) |dir_rel| {
        var dir = b.build_root.handle.openDir(io, dir_rel, .{ .iterate = true }) catch
            @panic("build: fingerprint gate cannot open a required source directory");
        defer dir.close(io);
        var walker = dir.walk(b.allocator) catch @panic("OOM");
        defer walker.deinit();
        while (walker.next(io) catch @panic("build: fingerprint gate walk failed")) |entry| {
            if (entry.kind != .file) continue;
            rel_paths.append(b.allocator, std.fmt.allocPrint(b.allocator, "{s}/{s}", .{ dir_rel, entry.path }) catch @panic("OOM")) catch @panic("OOM");
        }
    }
    for (extra_files) |f| rel_paths.append(b.allocator, f) catch @panic("OOM");

    std.mem.sort([]const u8, rel_paths.items, {}, struct {
        fn lessThan(_: void, a: []const u8, bb: []const u8) bool {
            return std.mem.order(u8, a, bb) == .lt;
        }
    }.lessThan);

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    for (rel_paths.items) |rel| {
        hasher.update(rel);
        hasher.update(&.{0});
        const data = b.build_root.handle.readFileAlloc(io, rel, b.allocator, .limited(32 << 20)) catch
            @panic("build: fingerprint gate cannot read a required source file");
        defer b.allocator.free(data);
        hasher.update(data);
        hasher.update(&.{0});
    }
    if (fold_in) |f| {
        hasher.update("<fold-in>");
        hasher.update(&f);
    }
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    return std.fmt.bytesToHex(digest, .lower);
}

/// Reads the stamp `name` under the build cache root and reports whether it
/// equals `fingerprint_hex` AND every path in `artifact_paths` (absolute)
/// still exists. Any missing stamp, mismatch, unreadable stamp, or missing
/// artifact means "must rebuild" — the safe default on every failure path.
fn fingerprintMatchesStamp(
    b: *std.Build,
    stamp_name: []const u8,
    fingerprint_hex: [64]u8,
    artifact_paths: []const []const u8,
) bool {
    const io = b.graph.io;
    const stamped = b.cache_root.handle.readFileAlloc(io, stamp_name, b.allocator, .limited(256)) catch return false;
    defer b.allocator.free(stamped);
    const trimmed = std.mem.trim(u8, stamped, " \t\r\n");
    if (!std.mem.eql(u8, trimmed, &fingerprint_hex)) return false;
    for (artifact_paths) |p| {
        std.Io.Dir.accessAbsolute(io, p, .{}) catch return false;
    }
    return true;
}

/// A custom build step that writes `fingerprint_hex` to a stamp file under the
/// build cache root. Wired as a dependant of the real rebuild's completion
/// steps ONLY, so it runs — and the stamp updates — only once those steps
/// have actually succeeded; a failed or interrupted rebuild must never leave
/// a stamp that reads as fresh on the next invocation.
const RecordFingerprint = struct {
    step: std.Build.Step,
    stamp_name: []const u8,
    fingerprint_hex: [64]u8,

    fn create(b: *std.Build, name: []const u8, stamp_name: []const u8, fingerprint_hex: [64]u8) *RecordFingerprint {
        const self = b.allocator.create(RecordFingerprint) catch @panic("OOM");
        self.* = .{
            .step = std.Build.Step.init(.{
                .id = .custom,
                .name = name,
                .owner = b,
                .makeFn = make,
            }),
            .stamp_name = stamp_name,
            .fingerprint_hex = fingerprint_hex,
        };
        return self;
    }

    fn make(step: *std.Build.Step, options: std.Build.Step.MakeOptions) anyerror!void {
        _ = options;
        const self: *RecordFingerprint = @fieldParentPtr("step", step);
        step.owner.cache_root.handle.writeFile(step.owner.graph.io, .{
            .sub_path = self.stamp_name,
            .data = &self.fingerprint_hex,
        }) catch @panic("build: fingerprint gate cannot write its stamp file");
    }
};

/// Extracts the toolchain version from `selfhost/version.bit`, the single
/// source of truth both compilers report (#1451). The self-hosted `bit`
/// compiles that constant directly; the Zig seed cannot, so its copy is parsed
/// out here and handed over as a build option — that is what keeps the two from
/// drifting, as they had (seed "0.0.0" vs selfhost "0.1.0-stub").
///
/// Reading a checked-in file rather than asking git is the whole point: a
/// release tarball has no `.git`, no tag and no network, and must still build
/// and report its own version. Nothing in this build graph shells out to git.
fn readVersionBit(b: *std.Build) []const u8 {
    const src = b.build_root.handle.readFileAlloc(
        b.graph.io,
        "selfhost/version.bit",
        b.allocator,
        .limited(64 << 10),
    ) catch @panic("build: cannot read selfhost/version.bit");
    // Line-based, and comment lines are skipped: the file documents its own
    // required shape, so a whole-file `indexOf` matches the DOC COMMENT first
    // and stamps the placeholder as the version. It did — `bit-seed version`
    // printed `bit ...` — which is why this scans declarations only.
    const marker = "const bitVersion: string = \"";
    var lines = std.mem.tokenizeScalar(u8, src, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (std.mem.startsWith(u8, trimmed, "//")) continue;
        if (!std.mem.startsWith(u8, trimmed, marker)) continue;
        const rest = trimmed[marker.len..];
        const end = std.mem.indexOfScalar(u8, rest, '"') orelse
            @panic("build: selfhost/version.bit has an unterminated version literal");
        if (end == 0) @panic("build: selfhost/version.bit declares an empty version");
        return b.allocator.dupe(u8, rest[0..end]) catch @panic("OOM");
    }
    @panic("build: selfhost/version.bit lost its `const bitVersion: string = \"...\"` declaration");
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});

    // `-Dversion=X.Y.Z` is the ONLY difference between a local build and a
    // release build: it overrides the checked-in default for both compilers at
    // once (the seed via `seed_opts` below, the self-hosted `bit` via the staged
    // `version.bit` at the tail of this function). Never patch the source file
    // in CI — that makes the tree dirty and the two paths diverge.
    const version_default = readVersionBit(b);
    const version = b.option([]const u8, "version", "Toolchain version to stamp into both compilers (default: selfhost/version.bit)") orelse version_default;
    // Default to ReleaseSafe, not Debug. In Debug, std's DebugAllocator captures
    // a DWARF stack trace on every allocation for leak detection; the compiler
    // allocates heavily, so a plain `zig build` compiler spent ~38s on the crypto
    // tree almost entirely in stack unwinding. ReleaseSafe keeps every safety
    // check (bounds, overflow, unreachable) but drops the per-alloc capture,
    // cutting that same compile to <1s. Pass `-Doptimize=Debug` for leak checks.
    // (standardOptimizeOption's preferred_optimize_mode only rebinds -Drelease and
    // still defaults to Debug, so bind -Doptimize directly with a ReleaseSafe default.)
    const optimize = b.option(
        std.builtin.OptimizeMode,
        "optimize",
        "Prioritize performance, safety, or binary size (default: ReleaseSafe)",
    ) orelse .ReleaseSafe;

    // The seed compiler, now retired to `seed/` and installed as `bit-seed`: a
    // bootstrap-only artifact that compiles the self-hosted `bit` (below) and
    // serves as the differential oracle. The canonical `bit` is the self-hosted
    // compiler under `selfhost/`.
    const exe = b.addExecutable(.{
        .name = "bit-seed",
        .root_module = b.createModule(.{
            .root_source_file = b.path("seed/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    // The seed's own version string, parsed out of selfhost/version.bit above so
    // `bit-seed version` and `bit version` print the same bytes (#1451).
    const seed_opts = b.addOptions();
    seed_opts.addOption([]const u8, "version", version);
    exe.root_module.addOptions("build_options", seed_opts);

    const seed_install = b.addInstallArtifact(exe, .{});
    b.getInstallStep().dependOn(&seed_install.step);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Build and run bit");
    run_step.dependOn(&run_cmd.step);

    const unit_tests = b.addTest(.{ .root_module = exe.root_module });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    // Test RUN steps that read a runtime archive straight out of
    // `zig-out/lib/<triple>/` instead of taking it as a build option (#1486).
    // Those are the seed's own roots — `main.zig`'s E0078/`archiveDefines`
    // tests, `link.zig`, `link/elf_reader.zig`, `link/macho*.zig` — and they
    // name the path as a cwd-relative string, so no `addOptionPath` edge exists
    // to keep what they read fresh. Collected here and wired to every
    // `libbitrt` install at the tail, once those installs are declared.
    //
    // The edge has to land on the RUN step, not on `test_step`: `test_step`
    // depending on an install only puts both in the same graph, and the build
    // runner is free to run them concurrently — the harness then reads the
    // archive mid-install. That is the #1229 shape, and it is why the old
    // `test_step.dependOn(host_libbitrt_install)` was not enough.
    var archive_readers: std.ArrayList(*std.Build.Step) = .empty;
    archive_readers.append(b.allocator, &run_unit_tests.step) catch @panic("OOM");

    // Every `seed/` and `runtime/` unit-test root, declared once.
    //
    // Single-sourced deliberately. `tests/testroots.zig` measures which test
    // namespaces each of these roots actually collects, and fails the build if a
    // test-bearing file under `seed/` or `runtime/` is collected by none of
    // them. That gate is only as good as its idea of what the roots are, so the
    // list it reads and the list `zig build test` runs have to be the same list
    // — a hand-kept second copy sitting next to the real entries is precisely
    // the kind of thing that looks authoritative and silently drifts. Adding a
    // root here wires it and tells the gate about it in one edit.
    const TestRoot = struct {
        path: []const u8,
        /// Restricts execution to test names starting with one of these.
        /// Empty runs everything the root collects.
        filters: []const []const u8 = &.{},
        /// `runtime/shims.zig` `@compileError`s off Linux (see its module doc
        /// comment), so it can't even be built for another host. Gated on the
        /// resolved target rather than skipped at runtime, and dropped from the
        /// gate's root set too so the two never disagree about what ran.
        linux_only: bool = false,
        /// Wired above rather than by the loop: the `main.zig` root reuses the
        /// compiler's own module. Listed here so the gate still sees it.
        wired_above: bool = false,
    };
    const test_roots = [_]TestRoot{
        .{ .path = "seed/main.zig", .wired_above = true },

        .{ .path = "runtime/alloc.zig" },
        .{ .path = "runtime/sched.zig" },
        .{ .path = "runtime/chan.zig" },
        .{ .path = "runtime/root.zig" },
        .{ .path = "runtime/shims.zig", .linux_only = true },

        .{ .path = "seed/diagnostics.zig" },
        .{ .path = "seed/lexer.zig" },
        .{ .path = "seed/ast.zig" },
        .{ .path = "seed/parser.zig" },
        .{ .path = "seed/resolve.zig" },
        .{ .path = "seed/fmt.zig" },
        .{ .path = "seed/regalloc.zig" },
        .{ .path = "seed/obj/elf.zig" },
        .{ .path = "seed/opt.zig" },

        // §17.6 module-scoped emission. Needs its own entry like every other
        // file here: `unit_tests` is rooted at `main.zig`, and a test in a file
        // that root merely imports is not necessarily collected — a test added
        // to `emit.zig` without this could silently never run.
        .{ .path = "seed/emit.zig" },

        // Rooted at `seed/` (not `seed/codegen/`) via anchor files, so
        // `arm64.zig`/`x64.zig`/`common.zig`'s `../ir.zig`-style imports
        // resolve — a module rooted at `seed/codegen/` would have them escape
        // its root, which Zig rejects. `compileFunction`'s native-execution
        // tests self-skip off x86-64 Linux (see `x64.zig`'s `can_exec_native`),
        // so both are safe to run on every CI host.
        .{ .path = "seed/codegen_arm64_test.zig" },
        .{ .path = "seed/codegen_x64_test.zig" },

        // `obj/pe.zig` has no imports outside `std`, but `main.zig` doesn't
        // import it either, so it still needs its own root to be collected.
        .{ .path = "seed/obj_pe_test.zig" },

        // The Windows PE/COFF object reader + executable linker (task #1103).
        // Same anchor reason as `link_macho_test.zig`: `main.zig` does not
        // import either file yet, and `pe_reader.zig`'s own `../obj/pe.zig`
        // import needs a module rooted at `seed/`, not `seed/link/`.
        .{ .path = "seed/link_pe_test.zig" },

        // The ELF linker driver, which imports the whole `link/` package
        // (object/archive/elf_reader/strip) plus `obj/elf.zig`, so their tests
        // come along. The end-to-end tests (link a real object against
        // `libbitrt.a` and run it) self-skip when `zig build libbitrt` hasn't
        // populated `zig-out/lib/`, or off x86-64 Linux where the ELF can't run.
        .{ .path = "seed/link.zig" },

        // The Mach-O linker driver needs its OWN entry: `link.zig` is the ELF
        // driver and never imports `link/macho.zig`. Between that and the
        // main.zig root not collecting it, this file's tests — including the
        // end-to-end "boots on macOS" one — had never run at all (#1445).
        // Anchored at `seed/` so `../obj/macho.zig` resolves.
        .{ .path = "seed/link_macho_test.zig" },

        // Standalone object writer (task #343): no imports outside `std`. Its
        // `otool`/`clang`/`ld` cross-validation tests self-skip off non-macOS
        // hosts (those tools don't exist there), so this is safe everywhere.
        .{ .path = "seed/obj/macho.zig" },

        // The lowering pass and the language server. Both fell through every
        // other root — 23 tests that had never executed (#1453), 14 of them
        // covering `lower.zig`, one of the largest modules in the seed.
        //
        // Filtered to those two namespaces on purpose. The anchor's module
        // collects 100+ tests, but all but 23 are `lexer`/`parser`/`resolve`/
        // `check`/`fmt`/`ir` tests already running under their own entries;
        // unfiltered, this one root would add ~160 duplicate executions to an
        // already-slow suite. If the filter ever stops matching — a rename, say
        // — the gate reports `lower`/`lsp` as orphaned rather than going quiet.
        .{ .path = "seed/lower_lsp_test.zig", .filters = &.{ "lower.test.", "lsp.test." } },
    };

    // The subset that applies to this host, shared by the loop below and the
    // gate, so neither can believe a root ran that the other skipped.
    var applicable_roots: std.ArrayList([]const u8) = .empty;
    defer applicable_roots.deinit(b.allocator);
    // Filters, newline-joined per root and positionally aligned with
    // `applicable_roots` (empty string = unfiltered). The gate has to model the
    // filter, not just the root: a filter that stops matching leaves an entry
    // that builds fine and runs zero tests, which is the same vacuous guard
    // this task was opened to remove.
    var applicable_filters: std.ArrayList([]const u8) = .empty;
    defer applicable_filters.deinit(b.allocator);

    for (test_roots) |r| {
        if (r.linux_only and target.result.os.tag != .linux) continue;
        applicable_roots.append(b.allocator, r.path) catch @panic("OOM");
        applicable_filters.append(
            b.allocator,
            std.mem.join(b.allocator, "\n", r.filters) catch @panic("OOM"),
        ) catch @panic("OOM");
        if (r.wired_above) continue;
        const t = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(r.path),
                .target = target,
                .optimize = optimize,
            }),
            .filters = r.filters,
        });
        const t_run = b.addRunArtifact(t);
        archive_readers.append(b.allocator, &t_run.step) catch @panic("OOM");
        test_step.dependOn(&t_run.step);
    }

    // Orphaned-test-file gate (#1453): fails the build when a `.zig` file under
    // `seed/` or `runtime/` contains tests that no wired root collects. Both
    // #1445 and #1453 were exactly that, and both had shipped for months
    // reading as coverage. Reachability is MEASURED, never derived from the
    // import graph — see tests/testroots.zig and tests/list_test_runner.zig.
    const testroots_opts = b.addOptions();
    testroots_opts.addOption([]const u8, "repo_root", b.pathFromRoot("."));
    // The seed's generated `build_options.zig`, so the gate can hand each root
    // the same module `build.zig` gives the compiler (#1451).
    testroots_opts.addOptionPath("build_options_zig", seed_opts.getOutput());
    testroots_opts.addOption([]const u8, "zig_exe", b.graph.zig_exe);
    // The gate spawns `zig test` itself. A test runner's environment need not
    // carry HOME, and without it the child cannot resolve its own cache
    // directory (`AppDataDirUnavailable`), so hand it both roots explicitly
    // rather than depending on inherited environment.
    testroots_opts.addOption([]const u8, "global_cache_root", b.graph.global_cache_root.path orelse ".");
    testroots_opts.addOption([]const u8, "local_cache_root", b.cache_root.path orelse ".");
    testroots_opts.addOption([]const []const u8, "roots", applicable_roots.items);
    testroots_opts.addOption([]const []const u8, "root_filters", applicable_filters.items);
    testroots_opts.addOption([]const u8, "host_os", @tagName(target.result.os.tag));
    testroots_opts.addOptionPath("list_runner", b.path("tests/list_test_runner.zig"));

    const testroots_mod = b.createModule(.{
        .root_source_file = b.path("tests/testroots.zig"),
        .target = target,
        .optimize = optimize,
    });
    testroots_mod.addOptions("build_options", testroots_opts);

    const testroots_tests = b.addTest(.{ .root_module = testroots_mod });
    const testroots_run = b.addRunArtifact(testroots_tests);
    // Spawns `zig test` per root, so its result depends on the state of the
    // source tree rather than on its own inputs alone — same reason rootpins
    // below opts out of the build cache.
    testroots_run.has_side_effects = true;
    test_step.dependOn(&testroots_run.step);
    b.step("testroots", "Orphaned-test-file gate (tests/testroots.zig)").dependOn(&testroots_run.step);

    // Golden-file harness: discovers tests/cases/*.bit and checks each against
    // its sibling .expected. The cases directory (absolute) is injected as a
    // build option so the runner is independent of the process cwd.
    const golden_opts = b.addOptions();
    golden_opts.addOption([]const u8, "cases_dir", b.pathFromRoot("tests/cases"));
    // The `run`/`panic` cases are also built by the self-hosted `bit` as a
    // subprocess (#1424), which takes the whole-project path even for a lone
    // file — so it needs the real stdlib to resolve the prelude from.
    golden_opts.addOption([]const u8, "stdlib_dir", b.pathFromRoot("stdlib"));

    const golden_mod = b.createModule(.{
        .root_source_file = b.path("tests/harness.zig"),
        .target = target,
        .optimize = optimize,
    });
    golden_mod.addImport("bit", exe.root_module);
    golden_mod.addOptions("build_options", golden_opts);

    const golden_tests = b.addTest(.{ .root_module = golden_mod });
    const golden_run = b.addRunArtifact(golden_tests);
    // `tests/cases/*` and the selfhost sources are read at runtime, so neither a
    // new case nor an edit to a ported module is visible to the build cache;
    // without this a cache skip could quietly retire the whole corpus — and now
    // the second compiler with it.
    golden_run.has_side_effects = true;
    test_step.dependOn(&golden_run.step);
    addNamedRun(b, golden_run, "test-golden", "run the golden tests/cases/*.bit harness only");
    // `selfhost_bit` is wired in at the tail, next to the artifact it names.

    // Examples guard: discovers examples/*.bit and compiles + runs each so the
    // showcase can never rot as the language grows. No .expected files — this
    // only asserts they build and exit 0; output correctness stays the golden
    // corpus's job. Shares the host libbitrt archive wired in at the tail.
    const examples_opts = b.addOptions();
    examples_opts.addOption([]const u8, "examples_dir", b.pathFromRoot("examples"));
    examples_opts.addOption([]const u8, "stdlib_dir", b.pathFromRoot("stdlib"));

    const examples_mod = b.createModule(.{
        .root_source_file = b.path("tests/examples.zig"),
        .target = target,
        .optimize = optimize,
    });
    examples_mod.addImport("bit", exe.root_module);
    examples_mod.addOptions("build_options", examples_opts);

    const examples_tests = b.addTest(.{ .root_module = examples_mod });
    const examples_run = b.addRunArtifact(examples_tests);
    // examples/* and stdlib/* are read at runtime (like the imports harness), so
    // a new or edited example is invisible to the build cache; without this the
    // run is cache-skipped and a broken example passes silently.
    examples_run.has_side_effects = true;
    test_step.dependOn(&examples_run.step);
    addNamedRun(b, examples_run, "test-examples", "run the examples/*.bit build+run guard only");

    // Runtime-pin cycle gate (#1367): emits each ported runtime module as an
    // ELF object and refuses any pinned ABI definition that references the very
    // symbol #1369's rename will turn it into — i.e. a function that will become
    // unbounded self-recursion the moment `runtime/root.zig` is retired. The
    // trap is that a Bit primitive (`ffloor`, `floatBits`, `hostTarget`, ...) is
    // NOT an instruction: it lowers to a call to the `bit_rt_*` symbol being
    // ported, so "return ffloor(x)" reads as a one-line port and is a cycle.
    // See tests/rootpins.zig's header for why no other gate can see this.
    const rootpins_opts = b.addOptions();
    rootpins_opts.addOption([]const u8, "repo_root", b.pathFromRoot("."));
    rootpins_opts.addOption([]const u8, "stdlib_dir", b.pathFromRoot("stdlib"));

    const rootpins_mod = b.createModule(.{
        .root_source_file = b.path("tests/rootpins.zig"),
        .target = target,
        .optimize = optimize,
    });
    rootpins_mod.addImport("bit", exe.root_module);
    rootpins_mod.addOptions("build_options", rootpins_opts);

    const rootpins_tests = b.addTest(.{ .root_module = rootpins_mod });
    const rootpins_run = b.addRunArtifact(rootpins_tests);
    // runtime/**/*.bit is read at run time, so an edit there is invisible to the
    // build cache — without this a newly-introduced cycle is cache-skipped.
    rootpins_run.has_side_effects = true;
    test_step.dependOn(&rootpins_run.step);
    // Also its own step: this gate is the one a runtime port wants to re-run on
    // every edit, and mutation-testing it through the full `test` step costs
    // minutes per mutation.
    b.step("rootpins", "Runtime-pin cycle gate (tests/rootpins.zig)").dependOn(&rootpins_run.step);

    // Runtime-ABI gates (#1655/#1658/#1662): register-class agreement between a
    // pin and the `root.zig` export it replaces, poll-freedom of the runtime
    // subtrees an ABI pin reaches, and ABI membership (every Zig export has a
    // Bit provider). `bit_rt_parse_float` is the register-class defect this
    // caught: Zig returned `f64` in `d0`/`xmm0`, the Bit pin returned `u64` in
    // `x0`/`rax` — so against a Bit-built `libbitrt.a` every float literal in
    // every program folded to 0.0 while integers stayed correct. No
    // object-level or differential gate can see a C type; see
    // tests/rootabi.zig's header. Split under #1674 into tests/rootabi.zig
    // (register-class + shared entry point), tests/rootabi_shared.zig (parsing
    // helpers), tests/rootabi_pollfree.zig and tests/rootabi_membership.zig —
    // the latter two are anchored into this same test binary via
    // `_ = @import(...)` in tests/rootabi.zig, so this module still needs only
    // its one root_source_file below.
    const rootabi_opts = b.addOptions();
    rootabi_opts.addOption([]const u8, "repo_root", b.pathFromRoot("."));

    const rootabi_mod = b.createModule(.{
        .root_source_file = b.path("tests/rootabi.zig"),
        .target = target,
        .optimize = optimize,
    });
    rootabi_mod.addImport("bit", exe.root_module);
    rootabi_mod.addOptions("build_options", rootabi_opts);

    const rootabi_tests = b.addTest(.{ .root_module = rootabi_mod });
    const rootabi_run = b.addRunArtifact(rootabi_tests);
    // Both halves are read at run time (runtime/root.zig + runtime/**/*.bit), so
    // an edit to either is invisible to the build cache.
    rootabi_run.has_side_effects = true;
    test_step.dependOn(&rootabi_run.step);
    b.step("rootabi", "Runtime-ABI gates: register-class, poll-free, ABI membership (tests/rootabi*.zig)").dependOn(&rootabi_run.step);

    // Stop-the-world wiring gate (#1639): the collector `runtime/stw` implements
    // must actually be REACHED by a booted program. It was not — nothing bound
    // the World registry or the three root sources, so a fully-Bit `libbitrt.a`
    // reported 0 collections against the Zig runtime's 65536 while every example
    // still ran byte-identically. Pre-G2 the property has no run-time signal at
    // all (the live `bit_rt_safepoint` is still root.zig's), so it is checked on
    // the emitted objects. See tests/stwwiring.zig's header.
    const stwwiring_opts = b.addOptions();
    stwwiring_opts.addOption([]const u8, "repo_root", b.pathFromRoot("."));
    stwwiring_opts.addOption([]const u8, "stdlib_dir", b.pathFromRoot("stdlib"));

    const stwwiring_mod = b.createModule(.{
        .root_source_file = b.path("tests/stwwiring.zig"),
        .target = target,
        .optimize = optimize,
    });
    stwwiring_mod.addImport("bit", exe.root_module);
    stwwiring_mod.addOptions("build_options", stwwiring_opts);

    const stwwiring_tests = b.addTest(.{ .root_module = stwwiring_mod });
    const stwwiring_run = b.addRunArtifact(stwwiring_tests);
    // Same cache reason as rootpins: runtime/**/*.bit is read at run time.
    stwwiring_run.has_side_effects = true;
    test_step.dependOn(&stwwiring_run.step);
    b.step("stwwiring", "Stop-the-world wiring gate (tests/stwwiring.zig)").dependOn(&stwwiring_run.step);

    // Import-set differential (#1436): the two compilers must emit the same
    // UNDEFINED symbols for the same source. `extern function close` built clean
    // under both and SIGSEGV'd under self-hosted `bit` only, because its
    // lowering dispatched builtins on the callee's SOURCE TEXT and sent the call
    // to `bit_rt_chan_close` — so the `_close` import simply disappeared. No
    // dump differential can see that (the AST and types are identical), and the
    // golden corpus could not either, because nothing in it used `extern` in
    // that shape. See tests/diffimports.zig's header.
    const diffimports_opts = b.addOptions();
    diffimports_opts.addOption([]const u8, "repo_root", b.pathFromRoot("."));
    diffimports_opts.addOption([]const u8, "stdlib_dir", b.pathFromRoot("stdlib"));

    const diffimports_mod = b.createModule(.{
        .root_source_file = b.path("tests/diffimports.zig"),
        .target = target,
        .optimize = optimize,
    });
    diffimports_mod.addImport("bit", exe.root_module);
    diffimports_mod.addOptions("build_options", diffimports_opts);

    const diffimports_tests = b.addTest(.{ .root_module = diffimports_mod });
    const diffimports_run = b.addRunArtifact(diffimports_tests);
    // The fixtures are .bit files read at run time, so an edit to one is
    // invisible to the build cache — same reason as rootpins above.
    diffimports_run.has_side_effects = true;
    // `selfhost_bit` is wired in at the tail, next to the artifact it names.
    //
    // Now WIRED (#1436 fixed). It was committed unwired because it was red while
    // the defect was present — self-hosted `lowerCall`/`checkCall`/`vCall` tested
    // the predeclared builtins against the callee's SOURCE TEXT before consulting
    // the resolved declaration, so a user `extern function close` lowered to
    // `bit_rt_chan_close`. All four sites now use the seed's precedence (local
    // binding > user declaration > builtin), and the gate is green.
    b.step("diffimports", "Import-set differential gate (tests/diffimports.zig)").dependOn(&diffimports_run.step);
    test_step.dependOn(&diffimports_run.step);

    // Format gate for the Zig sources. A formatter nothing enforces is a
    // suggestion: six files had already drifted before this landed. `--check`
    // (never a rewrite) is the point — a gate that reformatted its own checkout
    // would report success and enforce nothing.
    //
    // The Bit sources are NOT gated yet. `bit fmt` and the committed .bit tree
    // disagree on 73 of 122 files, and the disagreements are formatter bugs, not
    // drift (it explodes hand-grouped constant tables to one element per line,
    // and mangles a body whose single statement is a multi-line `match`).
    // Gating that would enshrine bad output. See the tracking task.
    const fmt_check = b.addFmt(.{
        .paths = &.{ "build.zig", "seed", "runtime", "tests" },
        .check = true,
    });
    test_step.dependOn(&fmt_check.step);

    // Concurrency + GC stress suite (task #350): compiles + runs each
    // tests/stress/* program twice — default policy and BIT_GC=stress (collect
    // every safepoint) — and diffs stdout against its `.expected`. The
    // production-readiness gate for spawn/channels/select/GC under load. Shares
    // the host libbitrt archive wired in at the tail.
    const stress_opts = b.addOptions();
    stress_opts.addOption([]const u8, "stress_dir", b.pathFromRoot("tests/stress"));
    // Stress programs build through the whole-project pipeline (like examples
    // and imports), so one may `import` another module — `tests/stress/spinlock`
    // pulls in the Bit runtime lock from `runtime/` rather than copying it.
    stress_opts.addOption([]const u8, "stdlib_dir", b.pathFromRoot("stdlib"));

    const stress_mod = b.createModule(.{
        .root_source_file = b.path("tests/stress.zig"),
        .target = target,
        .optimize = optimize,
    });
    stress_mod.addImport("bit", exe.root_module);
    stress_mod.addOptions("build_options", stress_opts);

    const stress_tests = b.addTest(.{ .root_module = stress_mod });
    const stress_run = b.addRunArtifact(stress_tests);
    // The `tests/stress/*` programs are read at runtime, so a new program is
    // invisible to the build cache — same reason the imports harness sets this.
    // It matters more now that the run also drives the self-hosted `bit`, whose
    // sources are equally invisible: a cache-skipped run would quietly stop
    // checking the compiler this pass exists to check.
    stress_run.has_side_effects = true;
    test_step.dependOn(&stress_run.step);

    // Scoped runner, same rationale as `test-imports`: this corpus now builds
    // every program with both compilers, making it the slowest harness here and
    // the one most worth running alone while chasing a self-hosted build failure.
    const test_stress_step = b.step("test-stress", "run the tests/stress/* harness only");
    test_stress_step.dependOn(&stress_run.step);
    // `selfhost_bit` is wired in at the tail, next to the artifact it names.

    // GC differential (#1363): drives runtime/gc.zig through the same scripted
    // sequence tests/stress/gcbit drives runtime/gc/gc.bit through, and asserts
    // both render the same table. The golden file is a shared oracle — the
    // stress suite above checks the Bit collector against it, this checks the
    // Zig collector against it, and neither is derived from the other. Front end
    // only on this side: it links runtime/gc.zig directly, so it needs no
    // libbitrt.
    const gcdiff_mod = b.createModule(.{
        .root_source_file = b.path("tests/gcdiff.zig"),
        .target = target,
        .optimize = optimize,
    });
    gcdiff_mod.addImport("gc", b.createModule(.{
        .root_source_file = b.path("runtime/gc.zig"),
        .target = target,
        .optimize = optimize,
    }));
    gcdiff_mod.addOptions("build_options", stress_opts);

    const gcdiff_tests = b.addTest(.{ .root_module = gcdiff_mod });
    const gcdiff_run = b.addRunArtifact(gcdiff_tests);
    test_step.dependOn(&gcdiff_run.step);
    addNamedRun(b, gcdiff_run, "test-gcdiff", "run the GC differential (tests/gcdiff.zig) only");

    // `bit version` (#1451): both compilers must report the stamped version, and
    // a typo'd subcommand must be a usage error rather than the banner it used
    // to fall through to. `selfhost_bit` is wired in at the tail, next to the
    // artifact it names.
    const version_opts = b.addOptions();
    version_opts.addOption([]const u8, "expected_version", version);
    version_opts.addOptionPath("seed_bit", exe.getEmittedBin());
    const version_mod = b.createModule(.{
        .root_source_file = b.path("tests/version.zig"),
        .target = target,
        .optimize = optimize,
    });
    version_mod.addOptions("build_options", version_opts);
    const version_tests = b.addTest(.{ .root_module = version_mod });
    const version_run = b.addRunArtifact(version_tests);
    test_step.dependOn(&version_run.step);
    addNamedRun(b, version_run, "test-version", "run the `bit version` contract (tests/version.zig) only");

    // `bit test` runner (#1105): discovers `test_` functions and runs each in
    // its own process (a failed `assert` panics). Shares the host libbitrt
    // archive wired in at the tail.
    const testcmd_opts = b.addOptions();
    testcmd_opts.addOption([]const u8, "testproj_dir", b.pathFromRoot("tests/testproj"));
    testcmd_opts.addOption([]const u8, "stdlib_dir", b.pathFromRoot("stdlib"));
    const testcmd_mod = b.createModule(.{
        .root_source_file = b.path("tests/testcmd.zig"),
        .target = target,
        .optimize = optimize,
    });
    testcmd_mod.addImport("bit", exe.root_module);
    testcmd_mod.addOptions("build_options", testcmd_opts);

    const testcmd_tests = b.addTest(.{ .root_module = testcmd_mod });
    const testcmd_run = b.addRunArtifact(testcmd_tests);
    test_step.dependOn(&testcmd_run.step);
    addNamedRun(b, testcmd_run, "test-testcmd", "run the `bit test` runner contract (tests/testcmd.zig) only");

    // `bit lint` CLI contract (#1380): exit codes, path walk, summary line,
    // `--json`, `--stats`. Execs the SELF-HOSTED `bit` (lint is selfhost-only),
    // so `selfhost_bit` is wired in at the tail next to the artifact it names —
    // empty on a cross build, where there is no runnable `bit` to drive.
    const lintcmd_opts = b.addOptions();
    const lintcmd_mod = b.createModule(.{
        .root_source_file = b.path("tests/lintcmd.zig"),
        .target = target,
        .optimize = optimize,
    });
    lintcmd_mod.addOptions("build_options", lintcmd_opts);

    const lintcmd_tests = b.addTest(.{ .root_module = lintcmd_mod });
    const lintcmd_run = b.addRunArtifact(lintcmd_tests);
    // The fixtures are written to /tmp at run time, invisible to the build
    // cache — same reason as rootpins and diffimports.
    lintcmd_run.has_side_effects = true;
    b.step("test-lint", "run the `bit lint` CLI contract only (tests/lintcmd.zig)").dependOn(&lintcmd_run.step);
    test_step.dependOn(&lintcmd_run.step);

    // std/os args + environment round-trip (#354): one program run twice under
    // a controlled environment. Shares the host libbitrt archive.
    const osenv_opts = b.addOptions();
    osenv_opts.addOption([]const u8, "osenv_dir", b.pathFromRoot("tests/osenv"));
    osenv_opts.addOption([]const u8, "stdlib_dir", b.pathFromRoot("stdlib"));
    const osenv_mod = b.createModule(.{
        .root_source_file = b.path("tests/osenv.zig"),
        .target = target,
        .optimize = optimize,
    });
    osenv_mod.addImport("bit", exe.root_module);
    osenv_mod.addOptions("build_options", osenv_opts);

    const osenv_tests = b.addTest(.{ .root_module = osenv_mod });
    const osenv_run = b.addRunArtifact(osenv_tests);
    test_step.dependOn(&osenv_run.step);
    addNamedRun(b, osenv_run, "test-osenv", "run the std/os args+environment round-trip (tests/osenv.zig) only");

    // Doc-tests (#351): every ```bit block under docs/ must typecheck against
    // the real prelude and std/*. Front end only — a snippet is a module, not a
    // program, so it has no `main` to link. Needs no libbitrt.
    const docs_opts = b.addOptions();
    docs_opts.addOption([]const u8, "docs_dir", b.pathFromRoot("docs"));
    docs_opts.addOption([]const u8, "stdlib_dir", b.pathFromRoot("stdlib"));
    const docs_mod = b.createModule(.{
        .root_source_file = b.path("tests/docs.zig"),
        .target = target,
        .optimize = optimize,
    });
    docs_mod.addImport("bit", exe.root_module);
    docs_mod.addOptions("build_options", docs_opts);

    const docs_tests = b.addTest(.{ .root_module = docs_mod });
    const docs_run = b.addRunArtifact(docs_tests);
    test_step.dependOn(&docs_run.step);
    addNamedRun(b, docs_run, "test-docs", "run the doc-snippet typecheck gate (tests/docs.zig) only");

    // Stdlib doc coverage (#356): every symbol `bit doc` reports as exported must
    // have a section in `docs/stdlib/<module>.md`. Shares the docs options (same
    // `docs_dir` + `stdlib_dir`). Front end only — needs no libbitrt.
    const stdlib_docs_mod = b.createModule(.{
        .root_source_file = b.path("tests/stdlib_docs.zig"),
        .target = target,
        .optimize = optimize,
    });
    stdlib_docs_mod.addImport("bit", exe.root_module);
    stdlib_docs_mod.addOptions("build_options", docs_opts);

    const stdlib_docs_tests = b.addTest(.{ .root_module = stdlib_docs_mod });
    const stdlib_docs_run = b.addRunArtifact(stdlib_docs_tests);
    // #1528's fixture is written to /tmp at run time, invisible to the build
    // cache — same reason as lintcmd, rootpins and diffimports.
    stdlib_docs_run.has_side_effects = true;
    b.step("test-stdlib-docs", "run the stdlib doc-coverage gate only (tests/stdlib_docs.zig)").dependOn(&stdlib_docs_run.step);
    test_step.dependOn(&stdlib_docs_run.step);

    // AST tag-set parity (#1420): seed and selfhost must declare the same node
    // tags, each parser-reachable. #1418's `ParamRest` false positive — selfhost
    // refusing a construct the seed accepts — was invisible to every existing
    // differential because no corpus file used it. A NAME comparison only; see
    // the file header for what it deliberately does not prove. Front end only.
    const ast_tags_opts = b.addOptions();
    ast_tags_opts.addOption([]const u8, "selfhost_ast", b.pathFromRoot("selfhost/ast.bit"));
    // The parser is spread over `selfhost/parser*.bit` siblings (#1503), which are
    // one module. Pass the directory and let the test concatenate them: naming a
    // single file here made the gate silently vacuous the moment parser.bit was
    // split — every tag read as unreachable because the scanned file no longer
    // held the parsing code.
    ast_tags_opts.addOption([]const u8, "selfhost_dir", b.pathFromRoot("selfhost"));
    ast_tags_opts.addOption([]const u8, "seed_parser", b.pathFromRoot("seed/parser.zig"));

    const ast_tags_mod = b.createModule(.{
        .root_source_file = b.path("tests/ast_tags.zig"),
        .target = target,
        .optimize = optimize,
    });
    ast_tags_mod.addImport("bit", exe.root_module);
    ast_tags_mod.addOptions("build_options", ast_tags_opts);

    const ast_tags_tests = b.addTest(.{ .root_module = ast_tags_mod });
    const ast_tags_run = b.addRunArtifact(ast_tags_tests);
    // The three sources are read at RUNTIME, so edits to them are invisible to
    // the build cache; without this a stale pass survives a tag being removed —
    // a gate that cannot fail is worse than no gate.
    ast_tags_run.has_side_effects = true;
    test_step.dependOn(&ast_tags_run.step);

    // Scoped runner, same precedent as `test-stress` / `test-imports`.
    const ast_tags_step = b.step("test-ast-tags", "run the AST tag-set parity gate only");
    ast_tags_step.dependOn(&ast_tags_run.step);

    // Format gate (#1266): every `.bit` source under stdlib/ and examples/ must
    // already be `bit fmt`-canonical (tests/cases/ is excluded — see the file
    // header). Front end only — needs no libbitrt.
    const fmt_check_opts = b.addOptions();
    fmt_check_opts.addOption([]const u8, "stdlib_dir", b.pathFromRoot("stdlib"));
    fmt_check_opts.addOption([]const u8, "examples_dir", b.pathFromRoot("examples"));
    const fmt_check_mod = b.createModule(.{
        .root_source_file = b.path("tests/fmt_check.zig"),
        .target = target,
        .optimize = optimize,
    });
    fmt_check_mod.addImport("bit", exe.root_module);
    fmt_check_mod.addOptions("build_options", fmt_check_opts);

    const fmt_check_run = b.addRunArtifact(b.addTest(.{ .root_module = fmt_check_mod }));
    // .bit sources are read at runtime, so an edit is invisible to the build
    // cache; without this the run is cache-skipped and drift passes silently.
    fmt_check_run.has_side_effects = true;
    test_step.dependOn(&fmt_check_run.step);
    addNamedRun(b, fmt_check_run, "test-fmt", "run the Bit-source fmt-canonical gate (tests/fmt_check.zig) only");

    // Std-stream writer gate: `.init(.stderr())` builds a POSITIONAL handle that
    // pwrites from offset 0, so a second writer on the same fd overwrites the
    // first. Invisible on a tty or pipe, corrupts every diagnostic under a
    // redirect — a static gate is the only thing that catches it.
    const stdstream_opts = b.addOptions();
    stdstream_opts.addOption([]const u8, "compiler_dir", b.pathFromRoot("seed"));
    stdstream_opts.addOption([]const u8, "tests_dir", b.pathFromRoot("tests"));
    stdstream_opts.addOption([]const u8, "runtime_dir", b.pathFromRoot("runtime"));
    const stdstream_mod = b.createModule(.{
        .root_source_file = b.path("tests/stdstream_check.zig"),
        .target = target,
        .optimize = optimize,
    });
    stdstream_mod.addOptions("build_options", stdstream_opts);

    const stdstream_run = b.addRunArtifact(b.addTest(.{ .root_module = stdstream_mod }));
    // Sources are read at runtime, invisible to the build cache (as above).
    stdstream_run.has_side_effects = true;
    test_step.dependOn(&stdstream_run.step);
    addNamedRun(b, stdstream_run, "test-stdstream", "run the std-stream positional-writer gate (tests/stdstream_check.zig) only");

    // Multi-module imports + prelude guard (#1153): builds + runs each
    // tests/imports/* program through the whole-project pipeline (relative and
    // std/* imports, auto-imported prelude) and diffs stdout. `stdlib_dir` is
    // where `std/*` resolves; `imports_dir` holds the programs.
    const imports_filter = b.option([]const u8, "imports-filter", "run only the named tests/imports/* project") orelse "";
    const imports_opts = b.addOptions();
    imports_opts.addOption([]const u8, "imports_dir", b.pathFromRoot("tests/imports"));
    imports_opts.addOption([]const u8, "stdlib_dir", b.pathFromRoot("stdlib"));
    imports_opts.addOption([]const u8, "imports_filter", imports_filter);
    // The checked-in set of projects the self-hosted `bit` is allowed to fail on
    // (#1484). Gating on the SET, not a count, so a gap closing while another
    // opens cannot cancel out — same contract as tests/selfhost-ir-gaps.txt.
    imports_opts.addOption([]const u8, "selfhost_gaps", b.pathFromRoot("tests/selfhost-imports-gaps.txt"));

    const imports_mod = b.createModule(.{
        .root_source_file = b.path("tests/imports.zig"),
        .target = target,
        .optimize = optimize,
    });
    imports_mod.addImport("bit", exe.root_module);
    imports_mod.addOptions("build_options", imports_opts);

    const imports_tests = b.addTest(.{ .root_module = imports_mod });
    const imports_run = b.addRunArtifact(imports_tests);
    // The `tests/imports/*` projects and `stdlib/*` sources are read at runtime,
    // so a new KAT dir or an edited stdlib file is invisible to the build cache;
    // without this the run is cache-skipped and new tests silently never execute.
    imports_run.has_side_effects = true;
    test_step.dependOn(&imports_run.step);

    // Scoped runner: `zig build test-imports` runs only the imports harness
    // (the always-rerun, largest chunk of `zig build test`); add
    // `-Dimports-filter=<name>` to gate a single KAT in seconds during a
    // per-task edit loop, without the 200+ golden/example/unit runs.
    const test_imports_step = b.step("test-imports", "run the tests/imports/* harness only (see -Dimports-filter)");
    test_imports_step.dependOn(&imports_run.step);

    // Fuzz harness (task #334): lexer+parser must never crash/hang on
    // arbitrary bytes. Two separate compilations of fuzz.zig, because
    // `-ffuzz` instrumentation changes runtime behavior, not just codegen:
    // `std.testing.fuzz` blocks forever waiting for the build system's fuzz
    // coordinator whenever the module is built with `.fuzz = true`, coordinator
    // or not. So the plain build (no `.fuzz`) is what `zig build test` runs —
    // it just replays the seed corpus once, finite. The instrumented build
    // only ever gets invoked as `zig build fuzz --fuzz` (or `--fuzz=N`), which
    // is what actually drives the coordinator.
    const fuzz_opts = b.addOptions();
    fuzz_opts.addOption([]const u8, "cases_dir", b.pathFromRoot("tests/cases"));
    fuzz_opts.addOption([]const u8, "crashes_dir", b.pathFromRoot("tests/fuzz/crashes"));

    const fuzz_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/fuzz/fuzz.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true, // guard.zig's signal handler needs raw libc calls
        }),
    });
    fuzz_tests.root_module.addImport("bit", exe.root_module);
    fuzz_tests.root_module.addOptions("build_options", fuzz_opts);
    test_step.dependOn(&b.addRunArtifact(fuzz_tests).step);

    // Saved-crash regression replay: deliberately kept in its own always-plain
    // binary, never built with `-ffuzz` — Zig's native fuzzer segfaults when a
    // fuzz-instrumented binary contains more than one `test` declaration
    // (upstream ziglang/zig#26040), and this test doesn't call
    // `std.testing.fuzz` anyway, so it has nothing to gain from instrumentation.
    const crash_regression_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/fuzz/crash_regression.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    crash_regression_tests.root_module.addImport("bit", exe.root_module);
    crash_regression_tests.root_module.addOptions("build_options", fuzz_opts);
    test_step.dependOn(&b.addRunArtifact(crash_regression_tests).step);

    // `zig build fuzz [-- <seconds>]`: bounded mutation-based fuzz run over
    // the same target and corpus (see tests/fuzz/mutate.zig's header for why
    // this isn't Zig's native coverage-guided `--fuzz` engine). Defaults to
    // 60s, matching the CI smoke pass; pass e.g. `-- 600` for a 10-minute run.
    const fuzz_exe = b.addExecutable(.{
        .name = "bit-fuzz",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/fuzz/mutate.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    fuzz_exe.root_module.addImport("bit", exe.root_module);
    fuzz_exe.root_module.addOptions("build_options", fuzz_opts);

    const run_fuzz = b.addRunArtifact(fuzz_exe);
    if (b.args) |args| run_fuzz.addArgs(args);
    const fuzz_step = b.step("fuzz", "Mutation-fuzz the lexer+parser (default 60s; pass -- <seconds> to override)");
    fuzz_step.dependOn(&run_fuzz.step);

    // `zig build libbitrt`: the runtime archive the static linker (task #345)
    // consumes, one `libbitrt.a` per target this runtime actually supports.
    // Fixed target queries, not `-Dtarget` — the point is to produce every
    // supported target's archive in one invocation regardless of host.
    // Windows and other architectures are deliberately absent: `sched.zig`
    // and `root.zig` both `@compileError` outside POSIX x86-64/ARM64 today
    // (see their module doc comments) — Windows lands when the scheduler
    // and GC gain Windows support, not before.
    const libbitrt_step = b.step("libbitrt", "Build libbitrt.a for every target this runtime supports");
    const libbitrt_targets = [_]std.Target.Query{
        .{ .cpu_arch = .x86_64, .os_tag = .linux },
        .{ .cpu_arch = .aarch64, .os_tag = .linux },
        .{ .cpu_arch = .x86_64, .os_tag = .macos },
        .{ .cpu_arch = .aarch64, .os_tag = .macos },
    };
    // The host test target always matches one of the four above, so every test
    // harness reuses that archive to link and execute real binaries under
    // `zig build test`. Captured in the loop as the runtime `lib`'s emitted
    // binary (a LazyPath into the build cache, always the fresh archive), not
    // the install-path string — see `wireLibbitrt`. Stays null (harnesses skip)
    // if the host is not a supported runtime target. `host_libbitrt_install` is
    // kept so `zig build test` still populates `zig-out/lib/<triple>/` for the
    // CLI-path end-to-end tests (link.zig, main.zig) that read it there.
    var host_libbitrt_bin: ?std.Build.LazyPath = null;
    var host_libbitrt_install: ?*std.Build.Step = null;
    // Set only when the gate below actually rebuilds (non-null), so a caller
    // that reaches libbitrt only as a `selfhost` dependency (rather than via
    // `zig build libbitrt`/`test` directly) can still make sure the stamp gets
    // recorded once that rebuild succeeds.
    var libbitrt_record_step: ?*std.Build.Step = null;

    // Rebuild-cache gate (#1796): the archive's real inputs today are
    // `runtime/**/*.zig` (root.zig's import graph); `seed/**` is included too
    // since the seed compiler becomes the thing reading `runtime/**/*.bit`
    // once the parked G3 rewrite (Bit objects instead of root.zig) lands —
    // gating on source freshness rather than on how the archive is assembled
    // is what lets this survive that rewrite unchanged. `build.zig` and
    // `.zigversion` are folded in because a flag or toolchain bump can change
    // the output without touching a single source file.
    const libbitrt_fp = fingerprintTree(b, &.{ "runtime", "seed" }, &.{ "build.zig", ".zigversion" }, null);
    var libbitrt_artifact_paths: [libbitrt_targets.len][]const u8 = undefined;
    for (libbitrt_targets, 0..) |q, i| {
        const t = q.zigTriple(b.allocator) catch @panic("OOM");
        libbitrt_artifact_paths[i] = b.getInstallPath(.{ .custom = b.fmt("lib/{s}", .{t}) }, "libbitrt.a");
    }
    const libbitrt_skip = fingerprintMatchesStamp(b, "fp-libbitrt.stamp", libbitrt_fp, &libbitrt_artifact_paths);

    if (libbitrt_skip) {
        // Fingerprint unchanged since the last successful build and every
        // archive it produced is still on disk: reuse them untouched instead
        // of re-running `zig build-lib` + install for all four targets.
        // `.cwd_relative` carries no step dependency on purpose — nothing
        // writes these files this invocation, so there is no #1229-style race
        // to guard against.
        for (libbitrt_targets, 0..) |query, i| {
            if (query.cpu_arch == target.result.cpu.arch and query.os_tag == target.result.os.tag) {
                host_libbitrt_bin = .{ .cwd_relative = libbitrt_artifact_paths[i] };
            }
        }
    } else {
        var libbitrt_installs: [libbitrt_targets.len]*std.Build.Step = undefined;
        for (libbitrt_targets, 0..) |query, install_idx| {
            const rt_target = b.resolveTargetQuery(query);
            const triple = query.zigTriple(b.allocator) catch @panic("OOM");
            // The runtime archive's build settings are fixed regardless of the
            // top-level `-Doptimize` a user passes: the static linker (#345)
            // consumes this, and its object reader deliberately handles only the
            // minimal, no-unwind relocation/section set a stripped ReleaseSmall
            // runtime produces. ReleaseSmall + strip drops DWARF/`__eh_frame`;
            // `.unwind_tables = .none` drops `__compact_unwind` (ABI.md §12
            // promises no backtrace/unwind contract anyway). `.pic = false` on
            // Linux keeps every code reference a plain absolute/PC-relative reloc
            // — no GOT/PLT — since a static zero-dynamic-linker ELF never needs
            // it. Darwin mandates PIC (the toolchain refuses `-fno-PIC`), so the
            // macOS archives keep it and the linker's Mach-O reader handles the
            // GOT-page reloc pair that entails.
            const lib = b.addLibrary(.{
                .linkage = .static,
                .name = "bitrt",
                .root_module = b.createModule(.{
                    .root_source_file = b.path("runtime/root.zig"),
                    .target = rt_target,
                    .optimize = .ReleaseSmall,
                    .strip = true,
                    .unwind_tables = .none,
                    .pic = if (query.os_tag == .macos) null else false,
                    // The green-thread context switch (sched.zig) rewrites `rsp` to
                    // another stack mid-function. The x86-64 red zone — 128 bytes
                    // below `rsp` that leaf code may use without reserving — is not
                    // preserved across that stack swap, so a value the compiler
                    // parked in the outgoing stack's red zone is read back from the
                    // incoming stack's red zone (garbage). Disable it for the
                    // runtime; ARM64 has no red zone, so this is x86-64's concern.
                    .red_zone = false,
                }),
            });
            // Bundle compiler-rt into the archive so the static linker (#345)
            // finds correct `memcpy`/`memset`/`memmove`/`__divti3` there rather
            // than us hand-rolling them (a naive Zig `memcpy` recurses: `@memcpy`
            // lowers back to a `memcpy` call). `runtime/shims.zig` then only has
            // to supply the two symbols compiler-rt does not: `strlen` and
            // `getauxval`.
            lib.bundle_compiler_rt = true;
            // One section per function/global so the linker's symbol-granularity
            // dead-strip is sound: without this, a call to a function inside a
            // shared `.text` is a `.text + offset` section relocation whose
            // PC-relative addend (offset - 4) lands in the *previous* function's
            // atom, dropping the real target and misresolving the call. With each
            // symbol in its own section, a reference names that symbol's own
            // section at offset 0 (unambiguous), exactly as `--gc-sections` needs.
            lib.link_function_sections = true;
            lib.link_data_sections = true;
            const install = b.addInstallArtifact(lib, .{
                .dest_dir = .{ .override = .{ .custom = b.fmt("lib/{s}", .{triple}) } },
            });
            libbitrt_step.dependOn(&install.step);
            // Make `zig build test` produce every archive its harnesses read out of
            // `zig-out/lib/`, not just the host's (#1486). Before this only the host
            // archive was installed under `test`, so the seed's cross-target tests
            // read whatever an earlier `zig build libbitrt` happened to leave on
            // disk: absent on a clean checkout (they self-skip, asserting nothing)
            // or stale after a runtime edit (they fail, and the failure reads as a
            // compiler regression). All four targets rather than only the three
            // read today, so a test that starts reading the fourth is covered by
            // construction.
            for (archive_readers.items) |reader| reader.dependOn(&install.step);

            libbitrt_installs[install_idx] = &install.step;
            if (query.cpu_arch == target.result.cpu.arch and query.os_tag == target.result.os.tag) {
                host_libbitrt_bin = lib.getEmittedBin();
                host_libbitrt_install = &install.step;
            }
        }

        // Only reached once every target above succeeded, so a stamp is never
        // written for a failed or partial rebuild.
        const libbitrt_record = RecordFingerprint.create(b, "record libbitrt fingerprint", "fp-libbitrt.stamp", libbitrt_fp);
        for (libbitrt_installs) |s| libbitrt_record.step.dependOn(s);
        libbitrt_step.dependOn(&libbitrt_record.step);
        test_step.dependOn(&libbitrt_record.step);
        libbitrt_record_step = &libbitrt_record.step;
    }

    // Wire the fresh host archive into every harness that links + runs real
    // binaries. `wireLibbitrt` uses the emitted-bin LazyPath, so each harness
    // carries a build-graph dependency on the current archive and can never
    // link a stale one. The old design passed the `zig-out` install-path string
    // and only ordered the harness *compile* after the install step; when that
    // compile was cached the harness could run before the install refreshed
    // `zig-out`, linking a stale, ABI-mismatched runtime whose malformed binary
    // the kernel then killed by signal (#1229).
    wireLibbitrt(golden_opts, host_libbitrt_bin);
    wireLibbitrt(examples_opts, host_libbitrt_bin);
    wireLibbitrt(stress_opts, host_libbitrt_bin);
    wireLibbitrt(testcmd_opts, host_libbitrt_bin);
    wireLibbitrt(osenv_opts, host_libbitrt_bin);
    wireLibbitrt(imports_opts, host_libbitrt_bin);
    // #1445's link-acceptance half needs a real archive: the import-set half
    // only emits objects and never links.
    wireLibbitrt(diffimports_opts, host_libbitrt_bin);

    // The CLI-path end-to-end tests (link.zig, main.zig, link/elf_reader.zig,
    // link/macho*.zig) that read `zig-out/lib/<triple>/` are now ordered after
    // EVERY archive install by the `archive_readers` loop above, which both
    // keeps them from self-skipping and keeps them from reading a stale archive
    // (#1486). It replaces a bare `test_step.dependOn(host_libbitrt_install)`,
    // which named only the host archive and left the install unordered against
    // the harness runs.

    // The canonical `bit`: the self-hosted bit-in-Bit compiler under `selfhost/`,
    // compiled by the bootstrap seed (`bit-seed`) and installed as `bit`. This is
    // the compiler that retires the seed (epic #363-#365). Building it means
    // RUNNING the seed to compile selfhost/, so it only works when the seed
    // targets the build host — a cross-compile (`-Dtarget=` for another machine)
    // cannot exec it. So a NATIVE `zig build` produces `bit` in the default
    // install; a cross build produces only `bit-seed` (use `bit-seed build
    // selfhost --target <t>` to cross-produce a self-hosted bit). The seed is
    // always kept alongside as `bit-seed` for bootstrap + the differentials.
    // Runs from the build root so the seed resolves both `selfhost/` and the host
    // `zig-out/lib/<triple>/libbitrt.a`. Depends on the seed's install
    // specifically (not the whole install step) to stay cycle-free.
    const native = target.result.cpu.arch == b.graph.host.result.cpu.arch and
        target.result.os.tag == b.graph.host.result.os.tag;

    // Rebuild-cache gate (#1796): selfhost/**/*.bit are the compiler's real
    // sources; the resulting `bit` binary also links in the just-built host
    // libbitrt.a, so `libbitrt_fp` (computed above) is folded in rather than
    // re-hashing that archive's own bytes. Skipped on a cross build (can't
    // exec a cross-built seed to find out anyway) and on a `-Dversion=`
    // override (a release build, not the hot dev-iteration loop this gate
    // targets) — both fall through to the unconditional rebuild below exactly
    // as before.
    const selfhost_gate_applies = native and !b.user_input_options.contains("version");
    const selfhost_artifact_path = b.getInstallPath(.bin, "bit");
    const selfhost_fp = if (selfhost_gate_applies)
        fingerprintTree(b, &.{"selfhost"}, &.{ "build.zig", ".zigversion" }, libbitrt_fp)
    else
        [_]u8{0} ** 64;
    const selfhost_skip = selfhost_gate_applies and
        fingerprintMatchesStamp(b, "fp-selfhost.stamp", selfhost_fp, &.{selfhost_artifact_path});

    const selfhost_step = b.step("selfhost", "Build the self-hosted compiler (selfhost/) with the seed bit-seed → bit");
    var selfhosted: std.Build.LazyPath = undefined;

    if (selfhost_skip) {
        // Fingerprint unchanged and the previously-built `bit` is still on
        // disk: skip re-running the seed over selfhost/ entirely. No step
        // dependency on `.cwd_relative` on purpose — nothing writes this file
        // this invocation.
        selfhosted = .{ .cwd_relative = selfhost_artifact_path };
    } else {
        const selfhost_run = b.addRunArtifact(exe);
        selfhost_run.addArg("build");
        if (b.user_input_options.contains("version")) {
            // `-Dversion=` given: compile a COPY of selfhost/ whose `version.bit`
            // carries the override, so the self-hosted `bit` reports exactly what
            // the seed reports (#1451). Only on the override path — an ordinary
            // build compiles the real source tree, unstaged, so the common case
            // gains no copy step and no new way to go stale.
            const staged = b.addWriteFiles();
            // The real `version.bit` MUST be excluded, not merely overwritten:
            // WriteFile emits its added files first and its copied directories
            // second, so an unexcluded copy silently clobbers the stamped file and
            // the release binary reports the development version (it did).
            _ = staged.addCopyDirectory(b.path("selfhost"), "", .{ .exclude_extensions = &.{"version.bit"} });
            _ = staged.add("version.bit", b.fmt(
                "// Generated by build.zig from -Dversion=. Source of truth: selfhost/version.bit.\nconst bitVersion: string = \"{s}\"\n",
                .{version},
            ));
            selfhost_run.addDirectoryArg(staged.getDirectory());
        } else {
            selfhost_run.addArg("selfhost");
        }
        selfhost_run.addArg("-o");
        selfhosted = selfhost_run.addOutputFileArg("bit");
        selfhost_run.step.dependOn(&seed_install.step);
        if (host_libbitrt_install) |inst| selfhost_run.step.dependOn(inst);
        // `zig build selfhost` alone reaches libbitrt only as this dependency —
        // never through `libbitrt_step`/`test_step` — so without this its
        // rebuild would go unrecorded and the next libbitrt-only invocation
        // would needlessly redo it (safe, just not free).
        if (libbitrt_record_step) |s| selfhost_step.dependOn(s);
        // The seed reads selfhost/*.bit at runtime, invisible to the build cache, so
        // an edit to a ported module wouldn't re-trigger the build — force it.
        selfhost_run.has_side_effects = true;
        const install_bit = b.addInstallBinFile(selfhosted, "bit");
        // Only pull `bit` into the default install on a native build (see above).
        if (native) b.getInstallStep().dependOn(&install_bit.step);
        selfhost_step.dependOn(&install_bit.step);

        // Only reached once the rebuild above succeeded, so a stamp is never
        // written for a failed or partial build.
        if (selfhost_gate_applies) {
            const selfhost_record = RecordFingerprint.create(b, "record selfhost fingerprint", "fp-selfhost.stamp", selfhost_fp);
            selfhost_record.step.dependOn(&install_bit.step);
            selfhost_step.dependOn(&selfhost_record.step);
            test_step.dependOn(&selfhost_record.step);
        }
    }

    // Hand the stress harness the self-hosted compiler so it builds every stress
    // program with BOTH compilers (#1413). Until this, the suite drove only the
    // seed, so nothing in `zig build test` would have noticed if self-hosted
    // `bit` could not build a runtime module at all — and #1414 is two runtime
    // modules where it cannot. Passing the LazyPath (not a `zig-out` string)
    // gives the harness a build-graph edge on the freshly-built `bit`, the same
    // reason `wireLibbitrt` uses the emitted-bin path rather than the install
    // path. Empty on a cross build: producing `bit` means EXECING the seed,
    // which a cross-built seed cannot do, and the cross-built harness could not
    // run either way — so the harness asserts non-empty once it knows it is a
    // host it can actually run on, rather than degrading to a seed-only pass.
    //
    // The golden corpus takes the same wiring for the same reason (#1424): it
    // is the largest corpus in the project and it drove only the seed, so
    // reverting the selfhost half of #1419's variadic fix left `zig build test`
    // green. Same LazyPath, same "empty only on a cross build" contract.
    // Install-prefix path resolution (#1452): the shipped `bit` must find its
    // stdlib and runtime archive from its OWN location, through a bare symlink,
    // with no environment set — the property every installer depends on.
    // `selfhost_bit` is wired in at the tail, next to the artifact it names.
    const pathresolve_opts = b.addOptions();
    pathresolve_opts.addOption([]const u8, "stdlib_dir", b.pathFromRoot("stdlib"));
    wireLibbitrt(pathresolve_opts, host_libbitrt_bin);
    const pathresolve_mod = b.createModule(.{
        .root_source_file = b.path("tests/pathresolve.zig"),
        .target = target,
        .optimize = optimize,
    });
    pathresolve_mod.addOptions("build_options", pathresolve_opts);
    const pathresolve_tests = b.addTest(.{ .root_module = pathresolve_mod });
    const pathresolve_run = b.addRunArtifact(pathresolve_tests);
    test_step.dependOn(&pathresolve_run.step);
    addNamedRun(b, pathresolve_run, "test-pathresolve", "run the install-prefix path-resolution gate (tests/pathresolve.zig) only");

    // External-package imports through bit.lock + the pkg cache (#1737):
    // selfhost-only (the seed has no bit.lock equivalent), so this drives the
    // self-hosted `bit` directly through its real CLI rather than the shared
    // tests/imports.zig harness (which requires the seed to build every
    // project there too). `selfhost_bit` is wired in at the tail, next to the
    // artifact it names, same as lintcmd/pathresolve above.
    const pmimports_opts = b.addOptions();
    pmimports_opts.addOption([]const u8, "stdlib_dir", b.pathFromRoot("stdlib"));
    wireLibbitrt(pmimports_opts, host_libbitrt_bin);
    const pmimports_mod = b.createModule(.{
        .root_source_file = b.path("tests/pmimports.zig"),
        .target = target,
        .optimize = optimize,
    });
    pmimports_mod.addOptions("build_options", pmimports_opts);
    const pmimports_tests = b.addTest(.{ .root_module = pmimports_mod });
    const pmimports_run = b.addRunArtifact(pmimports_tests);
    // The fixtures are written to /tmp at run time, invisible to the build
    // cache — same reason as lintcmd, rootpins and diffimports.
    pmimports_run.has_side_effects = true;
    b.step("test-pmimports", "run the package-manager import-resolution CLI contract only (tests/pmimports.zig)").dependOn(&pmimports_run.step);
    test_step.dependOn(&pmimports_run.step);

    if (native) {
        stress_opts.addOptionPath("selfhost_bit", selfhosted);
        golden_opts.addOptionPath("selfhost_bit", selfhosted);
        // #1484: the imports harness drove the SEED only, so #1483 (an entire
        // stdlib module the self-hosted `bit` could not lower) stayed green
        // through every `zig build test` while tests/imports/quicconn built it.
        imports_opts.addOptionPath("selfhost_bit", selfhosted);
        diffimports_opts.addOptionPath("selfhost_bit", selfhosted);
        lintcmd_opts.addOptionPath("selfhost_bit", selfhosted);
        version_opts.addOptionPath("selfhost_bit", selfhosted);
        pathresolve_opts.addOptionPath("selfhost_bit", selfhosted);
        pmimports_opts.addOptionPath("selfhost_bit", selfhosted);
    } else {
        stress_opts.addOption([]const u8, "selfhost_bit", "");
        golden_opts.addOption([]const u8, "selfhost_bit", "");
        imports_opts.addOption([]const u8, "selfhost_bit", "");
        diffimports_opts.addOption([]const u8, "selfhost_bit", "");
        lintcmd_opts.addOption([]const u8, "selfhost_bit", "");
        version_opts.addOption([]const u8, "selfhost_bit", "");
        pathresolve_opts.addOption([]const u8, "selfhost_bit", "");
        pmimports_opts.addOption([]const u8, "selfhost_bit", "");
    }

    // Gate the self-host: `zig build test` (and the x86_64 gate) builds the
    // self-hosted `bit` from the current selfhost/ sources and runs it. Its
    // `main` runs the in-Bit self-checks (selfhost/selfcheck.bit) — a failed
    // assert panics (exit 2) and fails the build, so a regression in a ported
    // module is caught on both arm64 and x86_64. `bit` targets the host, so it
    // always execs here. `has_side_effects` keeps it from being cache-skipped.
    const selfhost_selfcheck = std.Build.Step.Run.create(b, "run self-hosted bit self-checks");
    selfhost_selfcheck.addFileArg(selfhosted);
    selfhost_selfcheck.has_side_effects = true;
    selfhost_selfcheck.expectExitCode(0);
    test_step.dependOn(&selfhost_selfcheck.step);
    addNamedRun(b, selfhost_selfcheck, "test-selfcheck", "run the self-hosted bit self-checks (selfhost/selfcheck.bit) only");
}
