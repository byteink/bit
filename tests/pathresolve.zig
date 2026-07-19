//! Install-prefix path resolution for the shipped compiler (#1452).
//!
//! `bin/bit` used to resolve `stdlib/` and `libbitrt.a` against the CURRENT
//! WORKING DIRECTORY, which is a development-tree assumption: an installed
//! `bit` invoked from a user's own directory found neither. Every installer
//! (#359 brew, #360 curl|sh, #361 winget) therefore had to ship a wrapper
//! script or a profile export setting `BIT_STDLIB`/`BIT_LIBBITRT`.
//!
//! What this asserts is exactly the shape that was broken, and exactly the
//! shape the installers need:
//!
//!   * a prefix laid out like the release artifact (`bin/bit`, `stdlib/`,
//!     `lib/<triple>/libbitrt.a`),
//!   * reached through a BARE SYMLINK, the way a `PATH` install works — the
//!     symlink's own directory is not the install root, so this fails unless
//!     the binary resolves its own path through symlinks,
//!   * with `BIT_STDLIB` and `BIT_LIBBITRT` explicitly REMOVED from the
//!     environment, so nothing can pass by inheriting the harness's own
//!     wiring,
//!   * from TWO different working directories, neither of them the prefix and
//!     neither the build tree. One cwd would not distinguish a fix from a
//!     coincidence: cwd-dependence is the precise failure mode here.

const std = @import("std");
const build_options = @import("build_options");

const testing = std.testing;
const Io = std.Io;
const Dir = std.Io.Dir;

/// The `<triple>` component of the shipped `lib/<triple>/libbitrt.a`, spelled
/// the way `bit --target` spells it (this is the compiler's own naming, not
/// `uname -m`).
const host_triple = switch (@import("builtin").target.os.tag) {
    .macos => "aarch64-macos",
    else => switch (@import("builtin").target.cpu.arch) {
        .aarch64 => "aarch64-linux",
        else => "x86_64-linux",
    },
};

const program = "function main() {\n  print(\"resolved\\n\")\n}\n";

/// Runs `bit run <src>` from `cwd` with the two override variables removed, and
/// asserts the program built and printed. `bit` is reached through `bit_path`,
/// which the caller points at a symlink.
fn expectRunsFrom(gpa: std.mem.Allocator, io: Io, bit_path: []const u8, cwd: []const u8, src: []const u8) !void {
    // An EMPTY environment, not the inherited one minus two keys. The harness
    // itself exports `BIT_STDLIB`/`BIT_LIBBITRT` for other suites, and this
    // test is meaningless if either leaks in — starting from nothing is the
    // only way to be sure the binary found its own files unaided. `bit` is
    // invoked by absolute path, so it needs no PATH.
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();

    const r = try std.process.run(gpa, io, .{
        .argv = &.{ bit_path, "run", src },
        .cwd = .{ .path = cwd },
        .environ_map = &env,
    });
    defer gpa.free(r.stdout);
    defer gpa.free(r.stderr);

    switch (r.term) {
        .exited => |c| if (c != 0) {
            std.debug.print(
                "pathresolve: `bit run` from cwd {s} exited {d}\nstderr: {s}\n",
                .{ cwd, c, r.stderr },
            );
            return error.ResolveFromCwdFailed;
        },
        else => {
            std.debug.print("pathresolve: `bit run` from cwd {s} died by signal\n", .{cwd});
            return error.ResolveDiedBySignal;
        },
    }
    try testing.expectEqualStrings("resolved\n", r.stdout);
}

test "installed bit resolves stdlib and libbitrt from its own location, not the cwd" {
    if (build_options.selfhost_bit.len == 0) return; // cross build: no self-hosted bit
    if (build_options.libbitrt_path.len == 0) return; // host is not a runtime target

    const gpa = testing.allocator;
    var threaded = Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // A unique root per run. macOS caches a code signature per path, so reusing
    // a fixed path can validate a stale binary and pass without having tested
    // this build at all.
    const root = try std.fmt.allocPrint(gpa, "/tmp/bit-pathresolve-{x}", .{std.testing.random_seed});
    defer gpa.free(root);
    defer Dir.cwd().deleteTree(io, root) catch {};

    const cwd = Dir.cwd();
    // The install prefix is a SUBDIRECTORY of the scratch root, and the `PATH`
    // directory holding the symlink is a sibling OUTSIDE it — the way a real
    // install looks (`/opt/bit-x.y.z` reached via `/usr/local/bin/bit`). If the
    // symlink lived inside the prefix, resolving the symlink's own directory
    // would land on a valid prefix by accident and the symlink-resolution
    // property this test exists to check would never actually be exercised.
    const prefix = try std.fmt.allocPrint(gpa, "{s}/prefix", .{root});
    defer gpa.free(prefix);
    const bin_dir = try std.fmt.allocPrint(gpa, "{s}/bin", .{prefix});
    defer gpa.free(bin_dir);
    const lib_dir = try std.fmt.allocPrint(gpa, "{s}/lib/{s}", .{ prefix, host_triple });
    defer gpa.free(lib_dir);
    const link_dir = try std.fmt.allocPrint(gpa, "{s}/pathdir", .{root});
    defer gpa.free(link_dir);
    for ([_][]const u8{ bin_dir, lib_dir, link_dir }) |d| try cwd.createDirPath(io, d);

    // The compiler itself, copied (not symlinked) into `bin/` so the prefix is
    // a real install rather than a pointer back into the build tree.
    const bit_dst = try std.fmt.allocPrint(gpa, "{s}/bit", .{bin_dir});
    defer gpa.free(bit_dst);
    try cwd.copyFile(build_options.selfhost_bit, cwd, bit_dst, io, .{ .permissions = .executable_file });

    const lib_dst = try std.fmt.allocPrint(gpa, "{s}/libbitrt.a", .{lib_dir});
    defer gpa.free(lib_dst);
    try cwd.copyFile(build_options.libbitrt_path, cwd, lib_dst, io, .{});

    // `stdlib/` is symlinked rather than deep-copied: what is under test is
    // where the compiler LOOKS, not how the bytes got there.
    const std_dst = try std.fmt.allocPrint(gpa, "{s}/stdlib", .{prefix});
    defer gpa.free(std_dst);
    try cwd.symLink(io, build_options.stdlib_dir, std_dst, .{ .is_directory = true });

    // The bare `PATH` symlink — the thing an installer actually creates, and
    // the reason `selfExe()` must resolve symlinks.
    const link = try std.fmt.allocPrint(gpa, "{s}/bit", .{link_dir});
    defer gpa.free(link);
    try cwd.symLink(io, bit_dst, link, .{});

    // Two unrelated working directories. Each gets its own source STEM because
    // `bit run` names its temporary output after the stem, so a shared name
    // would let the two runs collide.
    for ([_][]const u8{ "one", "two" }) |name| {
        const work = try std.fmt.allocPrint(gpa, "{s}/work-{s}", .{ root, name });
        defer gpa.free(work);
        try cwd.createDirPath(io, work);
        const src_name = try std.fmt.allocPrint(gpa, "prog_{s}_{x}.bit", .{ name, std.testing.random_seed });
        defer gpa.free(src_name);
        const src_path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ work, src_name });
        defer gpa.free(src_path);
        try cwd.writeFile(io, .{ .sub_path = src_path, .data = program });

        try expectRunsFrom(gpa, io, link, work, src_name);
    }
}
