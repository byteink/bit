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

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
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

    const runtime_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("runtime/alloc.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(runtime_tests).step);

    const sched_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("runtime/sched.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(sched_tests).step);

    const chan_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("runtime/chan.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(chan_tests).step);

    const root_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("runtime/root.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(root_tests).step);

    // Linux-only (see runtime/shims.zig's module doc comment): gated on the
    // resolved target's OS, not a runtime skip, since the file itself
    // `@compileError`s off non-Linux and so cannot even be built for e.g. a
    // macOS `-Dtarget`. Silently absent from `zig build test` on every other
    // host, same as this project's other target-gated modules.
    if (target.result.os.tag == .linux) {
        const shims_tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path("runtime/shims.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });
        test_step.dependOn(&b.addRunArtifact(shims_tests).step);
    }

    const diagnostics_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("seed/diagnostics.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(diagnostics_tests).step);

    const lexer_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("seed/lexer.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(lexer_tests).step);

    const ast_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("seed/ast.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(ast_tests).step);

    const parser_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("seed/parser.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(parser_tests).step);

    const resolve_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("seed/resolve.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(resolve_tests).step);

    const fmt_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("seed/fmt.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(fmt_tests).step);

    const regalloc_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("seed/regalloc.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(regalloc_tests).step);

    const elf_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("seed/obj/elf.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(elf_tests).step);

    // Rooted at `seed/` (not `seed/codegen/`) via the anchor file, so
    // `arm64.zig`/`common.zig`'s `../ir.zig`-style imports resolve — see that
    // file's doc comment. Covers both files: `arm64.zig` imports `common.zig`.
    const arm64_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("seed/codegen_arm64_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(arm64_tests).step);

    // Rooted at `seed/` (not `seed/codegen/`) via the anchor file, so
    // `x64.zig`'s `../ir.zig`-style imports resolve — see that file's doc
    // comment. `compileFunction`'s native-execution tests self-skip off
    // x86-64 Linux (see `x64.zig`'s `can_exec_native`), so this is safe to
    // run on every CI host.
    const x64_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("seed/codegen_x64_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(x64_tests).step);

    const opt_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("seed/opt.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(opt_tests).step);

    // Rooted at `seed/` (not `seed/obj/`) via the anchor file, so
    // `pe.zig`'s `../codegen/x64.zig` import resolves — see that file's doc
    // comment and `obj_pe_test.zig`'s.
    const pe_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("seed/obj_pe_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(pe_tests).step);

    // Rooted at the linker driver `link.zig`, which imports the whole `link/`
    // package (object/archive/elf_reader/strip) plus `obj/elf.zig`, so their
    // tests all come along. The end-to-end tests (link a real object against
    // `libbitrt.a` and run it) self-skip when `zig build libbitrt` hasn't
    // populated `zig-out/lib/`, or off x86-64 Linux where the ELF can't run.
    const link_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("seed/link.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(link_tests).step);

    // Standalone object writer (task #343): no imports outside `std`. Its
    // `otool`/`clang`/`ld` cross-validation tests self-skip off non-macOS
    // hosts (those tools don't exist there), so this is safe on every CI host.
    const macho_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("seed/obj/macho.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(macho_tests).step);

    // Golden-file harness: discovers tests/cases/*.bit and checks each against
    // its sibling .expected. The cases directory (absolute) is injected as a
    // build option so the runner is independent of the process cwd.
    const golden_opts = b.addOptions();
    golden_opts.addOption([]const u8, "cases_dir", b.pathFromRoot("tests/cases"));

    const golden_mod = b.createModule(.{
        .root_source_file = b.path("tests/harness.zig"),
        .target = target,
        .optimize = optimize,
    });
    golden_mod.addImport("bit", exe.root_module);
    golden_mod.addOptions("build_options", golden_opts);

    const golden_tests = b.addTest(.{ .root_module = golden_mod });
    test_step.dependOn(&b.addRunArtifact(golden_tests).step);

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
    test_step.dependOn(&b.addRunArtifact(stress_tests).step);

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
    selfhost_run.addArgs(&.{ "build", "selfhost", "-o" });
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
