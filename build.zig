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

        // Same anchor reason: `pe.zig`'s `../codegen/x64.zig` import.
        .{ .path = "seed/obj_pe_test.zig" },

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
        test_step.dependOn(&b.addRunArtifact(t).step);
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
    test_step.dependOn(&b.addRunArtifact(gcdiff_tests).step);

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
    test_step.dependOn(&b.addRunArtifact(version_tests).step);

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
    test_step.dependOn(&b.addRunArtifact(testcmd_tests).step);

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
    test_step.dependOn(&b.addRunArtifact(osenv_tests).step);

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
    test_step.dependOn(&b.addRunArtifact(docs_tests).step);

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
    test_step.dependOn(&b.addRunArtifact(stdlib_docs_tests).step);

    // AST tag-set parity (#1420): seed and selfhost must declare the same node
    // tags, each parser-reachable. #1418's `ParamRest` false positive — selfhost
    // refusing a construct the seed accepts — was invisible to every existing
    // differential because no corpus file used it. A NAME comparison only; see
    // the file header for what it deliberately does not prove. Front end only.
    const ast_tags_opts = b.addOptions();
    ast_tags_opts.addOption([]const u8, "selfhost_ast", b.pathFromRoot("selfhost/ast.bit"));
    ast_tags_opts.addOption([]const u8, "selfhost_parser", b.pathFromRoot("selfhost/parser.bit"));
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
    for (libbitrt_targets) |query| {
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

        if (query.cpu_arch == target.result.cpu.arch and query.os_tag == target.result.os.tag) {
            host_libbitrt_bin = lib.getEmittedBin();
            host_libbitrt_install = &install.step;
        }
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

    // Still install the host archive under `zig build test` so the CLI-path
    // end-to-end tests (link.zig, main.zig) that read `zig-out/lib/<triple>/`
    // keep running rather than self-skipping. Harnesses no longer read that
    // path — they link the emitted-bin archive above — so this is only for
    // those `zig-out`-reading tests.
    if (host_libbitrt_install) |inst| test_step.dependOn(inst);

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
    const selfhosted = selfhost_run.addOutputFileArg("bit");
    selfhost_run.step.dependOn(&seed_install.step);
    if (host_libbitrt_install) |inst| selfhost_run.step.dependOn(inst);
    // The seed reads selfhost/*.bit at runtime, invisible to the build cache, so
    // an edit to a ported module wouldn't re-trigger the build — force it.
    selfhost_run.has_side_effects = true;
    const install_bit = b.addInstallBinFile(selfhosted, "bit");
    // Only pull `bit` into the default install on a native build (see above).
    if (native) b.getInstallStep().dependOn(&install_bit.step);

    const selfhost_step = b.step("selfhost", "Build the self-hosted compiler (selfhost/) with the seed bit-seed → bit");
    selfhost_step.dependOn(&install_bit.step);

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
    test_step.dependOn(&b.addRunArtifact(pathresolve_tests).step);

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
    } else {
        stress_opts.addOption([]const u8, "selfhost_bit", "");
        golden_opts.addOption([]const u8, "selfhost_bit", "");
        imports_opts.addOption([]const u8, "selfhost_bit", "");
        diffimports_opts.addOption([]const u8, "selfhost_bit", "");
        lintcmd_opts.addOption([]const u8, "selfhost_bit", "");
        version_opts.addOption([]const u8, "selfhost_bit", "");
        pathresolve_opts.addOption([]const u8, "selfhost_bit", "");
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
}
