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
}
