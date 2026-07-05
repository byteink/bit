const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "bitc",
        .root_module = b.createModule(.{
            .root_source_file = b.path("compiler/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Build and run bitc");
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
            .root_source_file = b.path("compiler/diagnostics.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(diagnostics_tests).step);

    const lexer_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("compiler/lexer.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(lexer_tests).step);

    const ast_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("compiler/ast.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(ast_tests).step);

    const parser_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("compiler/parser.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(parser_tests).step);

    const resolve_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("compiler/resolve.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(resolve_tests).step);

    const fmt_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("compiler/fmt.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(fmt_tests).step);

    const regalloc_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("compiler/regalloc.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(regalloc_tests).step);

    const elf_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("compiler/obj/elf.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(elf_tests).step);

    // Rooted at `compiler/` (not `compiler/codegen/`) via the anchor file, so
    // `arm64.zig`/`common.zig`'s `../ir.zig`-style imports resolve — see that
    // file's doc comment. Covers both files: `arm64.zig` imports `common.zig`.
    const arm64_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("compiler/codegen_arm64_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(arm64_tests).step);

    // Rooted at `compiler/` (not `compiler/codegen/`) via the anchor file, so
    // `x64.zig`'s `../ir.zig`-style imports resolve — see that file's doc
    // comment. `compileFunction`'s native-execution tests self-skip off
    // x86-64 Linux (see `x64.zig`'s `can_exec_native`), so this is safe to
    // run on every CI host.
    const x64_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("compiler/codegen_x64_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(x64_tests).step);

    const opt_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("compiler/opt.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(opt_tests).step);

    // Rooted at `compiler/` (not `compiler/obj/`) via the anchor file, so
    // `pe.zig`'s `../codegen/x64.zig` import resolves — see that file's doc
    // comment and `obj_pe_test.zig`'s.
    const pe_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("compiler/obj_pe_test.zig"),
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
            .root_source_file = b.path("compiler/link.zig"),
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
            .root_source_file = b.path("compiler/obj/macho.zig"),
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
    golden_mod.addImport("bitc", exe.root_module);
    golden_mod.addOptions("build_options", golden_opts);

    const golden_tests = b.addTest(.{ .root_module = golden_mod });
    test_step.dependOn(&b.addRunArtifact(golden_tests).step);

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
    fuzz_tests.root_module.addImport("bitc", exe.root_module);
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
    crash_regression_tests.root_module.addImport("bitc", exe.root_module);
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
    fuzz_exe.root_module.addImport("bitc", exe.root_module);
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
    for (libbitrt_targets) |query| {
        const rt_target = b.resolveTargetQuery(query);
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
            .dest_dir = .{ .override = .{ .custom = b.fmt("lib/{s}", .{query.zigTriple(b.allocator) catch @panic("OOM")}) } },
        });
        libbitrt_step.dependOn(&install.step);
    }
}
