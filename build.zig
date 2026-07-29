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

/// One `tests/bit/*.bit` gate: run the SHIPPED compiler on a harness written in
/// Bit. Every retired `tests/*.zig` harness collapses to a call of this (#1591),
/// so the wiring is stated once instead of twelve near-identical blocks.
///
/// `has_side_effects` is not optional here. Each harness reads its real inputs
/// (sources, fixtures, docs) at RUN time, so Zig's build cache cannot see an
/// edit to them; without it a regression is cache-skipped into a false pass,
/// which is the exact failure the old fmt_check harness was marked against.
/// `archive_installs` is every `libbitrt.a` install step. A gate that names a
/// `zig-out/lib/<triple>/` path in an env var reads it off disk at run time, so
/// the edge has to land on this RUN — putting it on `test_step` would let the
/// runner install and read concurrently (#1229). Passing them all is deliberate:
/// an over-wired gate costs one ordering edge, an under-wired one reads a
/// half-written archive.
fn addBitGate(
    b: *std.Build,
    bit_exe: std.Build.LazyPath,
    test_step: *std.Build.Step,
    archive_installs: []const *std.Build.Step,
    name: []const u8,
    src: []const u8,
    env: []const [2][]const u8,
    desc: []const u8,
) *std.Build.Step.Run {
    const run = std.Build.Step.Run.create(b, b.fmt("bit run {s}", .{src}));
    run.addFileArg(bit_exe);
    run.addArg("run");
    run.addFileArg(b.path(src));
    for (archive_installs) |st| run.step.dependOn(st);
    for (env) |kv| run.setEnvironmentVariable(kv[0], kv[1]);
    run.has_side_effects = true;
    run.expectExitCode(0);
    test_step.dependOn(&run.step);
    addNamedRun(b, run, b.fmt("test-{s}", .{name}), desc);
    return run;
}

/// Rebuild-cache gate (#1796): `libbitrt.a` and the self-hosted `bit` are each
/// produced by a step that reads its true sources at runtime (`root.zig`'s
/// `runtime/**/*.zig` today, `compiler/**/*.bit` always) — invisible to Zig's
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

/// Extracts the toolchain version from `compiler/version.bit`, the single
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
        "compiler/version.bit",
        b.allocator,
        .limited(64 << 10),
    ) catch @panic("build: cannot read compiler/version.bit");
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
            @panic("build: compiler/version.bit has an unterminated version literal");
        if (end == 0) @panic("build: compiler/version.bit declares an empty version");
        return b.allocator.dupe(u8, rest[0..end]) catch @panic("OOM");
    }
    @panic("build: compiler/version.bit lost its `const bitVersion: string = \"...\"` declaration");
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});

    // `-Dversion=X.Y.Z` is the ONLY difference between a local build and a
    // release build: it overrides the checked-in default for both compilers at
    // once (the seed via `seed_opts` below, the self-hosted `bit` via the staged
    // `version.bit` at the tail of this function). Never patch the source file
    // in CI — that makes the tree dirty and the two paths diverge.
    const version_default = readVersionBit(b);
    const version = b.option([]const u8, "version", "Toolchain version to stamp into both compilers (default: compiler/version.bit)") orelse version_default;
    // Default to ReleaseSafe, not Debug. In Debug, std's DebugAllocator captures
    // a DWARF stack trace on every allocation for leak detection; the compiler
    // allocates heavily, so a plain `zig build` compiler spent ~38s on the crypto
    // tree almost entirely in stack unwinding. ReleaseSafe keeps every safety
    // check (bounds, overflow, unreachable) but drops the per-alloc capture,
    // cutting that same compile to <1s. Pass `-Doptimize=Debug` for leak checks.
    // (standardOptimizeOption's preferred_optimize_mode only rebinds -Drelease and
    // still defaults to Debug, so bind -Doptimize directly with a ReleaseSafe default.)
    // `-Doptimize` is still ACCEPTED but no longer applies to anything: it set the
    // optimize mode of the Zig artifacts, and after #1593 the build compiles no
    // Zig at all. Kept rather than removed so an existing invocation that passes
    // it keeps working instead of dying on an unknown option; discarded rather
    // than silently honoured so nobody reads this as still tuning a build.
    _ = b.option(
        std.builtin.OptimizeMode,
        "optimize",
        "Accepted for compatibility; no longer applies (the build compiles no Zig)",
    );

    // The seed compiler, now retired to `seed/` and installed as `bit-seed`: a
    // bootstrap-only artifact that compiles the self-hosted `bit` (below) and
    // serves as the differential oracle. The canonical `bit` is the self-hosted
    // compiler under `compiler/`.
    const test_step = b.step("test", "Run unit tests");

    // Run steps that read a runtime archive straight out of `zig-out/lib/<triple>/`
    // instead of taking it as a build option (#1486). They name the path as a
    // plain string, so no `addOptionPath` edge exists to keep what they read fresh.
    // Every `libbitrt` install lands in this list as it is declared, and
    // `addBitGate` hangs each gate's RUN step off all of them.
    //
    // THE EDGE HAS TO LAND ON THE RUN STEP, NOT ON `test_step`. `test_step`
    // depending on an install only puts both in the same graph, and the build
    // runner is free to run them concurrently — the harness then reads the archive
    // mid-install. That is the #1229 shape, and it is why the old
    // `test_step.dependOn(host_libbitrt_install)` was not enough. The list used to
    // hold the seed's own Zig test roots; it now holds the Bit gates, which read
    // the same files for the same reason (#1593).
    var libbitrt_readers: std.ArrayList(*std.Build.Step) = .empty;
    // The seed-coupled Zig harnesses are GONE (#1593), all nine of them: they
    // formed one connected component rooted in the seed and nothing survives it.
    //
    //   ast_tags/imports/diffimports/version  linked the seed as a library
    //   selfbin, proc                          helpers for exactly those four
    //   testroots, list_test_runner            swept seed/ and runtime/ for
    //                                          orphaned Zig tests; runtime/ lost
    //                                          its last .zig in #1854, so after
    //                                          seed/ there is nothing to sweep
    //   stdstream_check                        gated how Zig SOURCE used Zig's
    //                                          std; there is no Zig source left
    //
    // What each asserted that still needs asserting is covered on the Bit side:
    // `test-imports-bit` runs the same 96 projects (96/96 OK) and
    // `test-version-cli` (tests/bit/version.bit) holds the CLI contract. What is
    // NOT replaced is the seed-vs-bit half of ast_tags and diffimports — those
    // compared two independent implementations, and after #1593 there is only
    // one. docs/release/bootstrap.md §5 records that as the accepted loss.

    // The Bit port of the above, tests/bit/importsrun.bit, is wired at the tail
    // as `test-imports-bit` and is deliberately NOT on `test_step`: it covers
    // the SELFHOST half only, while tests/imports.zig drives both compilers
    // over the same 96 projects. Running both would double the largest chunk of
    // `zig build test` to re-prove what the Zig harness already proves. It gets
    // promoted, and imports.zig deleted, when the seed goes (#1593).

    // Fuzz harness (#334) is now tests/bit/fuzz.bit — wired at the tail,
    // where `selfhosted` (the compiler under test) is in scope.

    // `zig build libbitrt`: the runtime archive the static linker (task #345)
    // consumes. #1584 (G3): built from Bit-compiled objects via
    // `scripts/g2archive.sh` (#1694's proven, mutation-tested recipe: per-module
    // `--emit-obj --freestanding` + `bit ar`), not `runtime/root.zig` — this is
    // the moment the Bit runtime stops being a parallel implementation and
    // becomes the runtime that ships. One `libbitrt.a` per target Bit itself
    // can build for. `x86_64-macos` is deliberately ABSENT (it was a 4th entry
    // before this task): once the archive is compiled FROM Bit, only a target
    // `seed/main.zig`'s `BuildTarget.parse` accepts can emit its member
    // objects, and that enum has exactly three members. Keeping the entry
    // would mean keeping a Zig build input for an archive nothing consumes —
    // see dist/README.md and dist/package.sh's `RUNTIME_TRIPLES`, which
    // already excluded it. Windows and other architectures are absent for the
    // pre-existing reason: the runtime `@compileError`s outside POSIX
    // x86-64/ARM64 today.
    const libbitrt_step = b.step("libbitrt", "Build libbitrt.a for every target this runtime supports");

    // THE PINNED STAGE0 (#1593), declared here because it is needed twice and the
    // earlier of the two uses is the runtime archive immediately below.
    //
    // `scripts/stage0.sh` downloads the release named by dist/stage0/SHA256SUMS,
    // verifies it against that COMMITTED digest, unpacks it under zig-out/stage0/
    // and writes a wrapper pinning BIT_STDLIB to this tree. First run fetches;
    // every later run is silent and offline. It REFUSES on any failure, so a
    // build can never quietly fall back to something unverified.
    //
    // The wrapper path is fixed rather than read from the script's stdout because
    // build.zig composes the graph before anything runs and cannot capture output
    // at configure time. stage0.sh writes exactly this path; the runs fail loudly
    // if it is absent.
    //
    // A CONSTRAINT THIS CREATES, worth knowing before it bites: stage0 compiles
    // both `compiler/` and `runtime/`, so NEITHER may use a language feature or
    // builtin the pinned release lacks. When they need one, the pin moves first —
    // cut a release, repin dist/stage0/SHA256SUMS, then use the feature. That is
    // the same discipline that made 0.1.2 unable to build today's compiler/
    // (`osRunTestBounded`), which is what forced the 0.1.3 pin.
    //
    // stdout is the script's return value for shell callers; build.zig already
    // knows the path, so it is dropped rather than printing a stray line on every
    // `zig build`. Diagnostics go to stderr and are kept.
    const stage0_ensure = b.addSystemCommand(&.{ "sh", "-c", "sh scripts/stage0.sh >/dev/null" });
    // Downloads and unpacks; the result is invisible to the build cache.
    stage0_ensure.has_side_effects = true;
    const stage0_bit = b.pathFromRoot("zig-out/stage0/bit-oracle");
    // Kept as target QUERIES rather than triple strings so the rebuild-cache
    // gate below (#1796) keeps working unchanged: it needs `zigTriple` for the
    // install path and a query comparison to pick the host's archive. The
    // `g2archive.sh` triple is that same `zigTriple` string.
    const libbitrt_targets = [_]std.Target.Query{
        .{ .cpu_arch = .x86_64, .os_tag = .linux },
        .{ .cpu_arch = .aarch64, .os_tag = .linux },
        .{ .cpu_arch = .aarch64, .os_tag = .macos },
    };

    // `g2archive.sh` compiles every runtime module and assembles the archive.
    // It used to be driven by a HOST-NATIVE copy of the seed, built separately
    // from `exe` because `exe` follows `-Dtarget=` and a cross-built seed cannot
    // exec on this host. The pinned stage0 has no such problem: it is a native
    // binary for THIS machine by construction, so archive assembly keeps working
    // under `-Dtarget=` without a second compiler being built to do it (#1593).
    const rt_builder_path = stage0_bit;

    // The one archive of the three every test harness reuses to link and
    // execute real binaries under `zig build test`. Captured as the archive's
    // `LazyPath` (into the build cache), not the install-path string — see
    // `wireLibbitrt`. Stays null (harnesses skip) if the host is not a supported
    // runtime target. `host_libbitrt_install` is kept so `zig build test` still
    // populates `zig-out/lib/<triple>/` for the CLI-path end-to-end tests
    // (link.zig, main.zig) that read it there.
    var host_libbitrt_bin: ?std.Build.LazyPath = null;
    // The host archive's INSTALL PATH, captured in the loop below from the same
    // QUERY triple the install uses. Recomputing it from `target.result` does
    // not work: a resolved target's `zigTriple` carries the OS version range
    // (`aarch64-macos.26.5.2...26.5.2-none`), which is not the directory name.
    var host_libbitrt_path: ?[]const u8 = null;
    var host_libbitrt_install: ?*std.Build.Step = null;
    // Set only when the gate below actually rebuilds (non-null), so a caller
    // that reaches libbitrt only as a `selfhost` dependency (rather than via
    // `zig build libbitrt`/`test` directly) can still make sure the stamp gets
    // recorded once that rebuild succeeds.
    var libbitrt_record_step: ?*std.Build.Step = null;

    // Rebuild-cache gate (#1796): the archive's inputs are `runtime/**/*.bit`
    // (the module set `g2archive.sh` compiles) and THE COMPILER THAT READS THEM.
    // Gating on source freshness rather than on how the archive is assembled is
    // what let this survive G3's rewrite unchanged — it was written against
    // `runtime/**/*.zig` and needed no edit when the assembly changed.
    // `build.zig` and `.zigversion` are folded in because a flag or toolchain
    // bump can change the output without touching a single source file.
    //
    // The compiler input used to be `seed/**`, which #1593 deleted. Its
    // replacement is NOT nothing: `rt_builder_path` is the pinned stage0, so the
    // thing that decides which compiler emits this archive is
    // `dist/stage0/SHA256SUMS`. Leaving it out would mean repinning stage0 does
    // not rebuild `libbitrt.a`, and the stale archive would keep whatever the
    // OLD compiler emitted — which is precisely #1857, where stage0 0.1.3's
    // `parseFloat` zeroed `bit_rt_log`'s polynomial. A pin bump must invalidate.
    const libbitrt_fp = fingerprintTree(b, &.{"runtime"}, &.{ "build.zig", ".zigversion", "dist/stage0/SHA256SUMS" }, null);
    var libbitrt_artifact_paths: [libbitrt_targets.len][]const u8 = undefined;
    for (libbitrt_targets, 0..) |q, i| {
        const t = q.zigTriple(b.allocator) catch @panic("OOM");
        libbitrt_artifact_paths[i] = b.getInstallPath(.{ .custom = b.fmt("lib/{s}", .{t}) }, "libbitrt.a");
    }
    const libbitrt_skip = fingerprintMatchesStamp(b, "fp-libbitrt.stamp", libbitrt_fp, &libbitrt_artifact_paths);

    if (libbitrt_skip) {
        // Fingerprint unchanged since the last successful build and every
        // archive it produced is still on disk: reuse them untouched instead
        // of re-running `g2archive.sh` + install for all three targets.
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
            const triple = query.zigTriple(b.allocator) catch @panic("OOM");
            // `scripts/g2archive.sh` (#1694) is the ONE recipe for this archive,
            // and it is a script rather than inline steps here on purpose: four
            // agents in one session each reconstructed the procedure by hand,
            // every reconstruction a fresh chance to diverge. It compiles each of
            // the 21 runtime module DIRECTORIES with `--emit-obj --freestanding`
            // and assembles them with `bit ar` (not `zig ar`, whose GNU
            // long-name members the Bit linker rejects). No `bundle_compiler_rt`
            // and no `.red_zone`/`.pic` knobs appear here because there is no
            // Zig compilation left to configure: `rtSymbol` emits `bit_rt_*` and
            // nothing else, so the archive has no compiler-rt surface to supply.
            const run = b.addSystemCommand(&.{ "bash", "scripts/g2archive.sh", triple });
            run.setEnvironmentVariable("BIT", rt_builder_path);
            run.step.dependOn(&stage0_ensure.step);
            run.expectExitCode(0);
            // The compiler reads `runtime/**/*.bit` at run time, which is
            // invisible to the build cache — the same reason `selfhost_run`
            // carries this. Without it a runtime edit links a stale archive, and
            // that failure reads as a compiler regression (#1486).
            run.has_side_effects = true;
            const archive = run.addOutputFileArg("libbitrt.a");
            const install = b.addInstallFile(archive, b.fmt("lib/{s}/libbitrt.a", .{triple}));
            libbitrt_step.dependOn(&install.step);
            // Make `zig build test` produce every archive its harnesses read out of
            // `zig-out/lib/`, not just the host's (#1486). Before this only the host
            // archive was installed under `test`, so cross-target tests read
            // whatever an earlier `zig build libbitrt` happened to leave on disk:
            // absent on a clean checkout (they self-skip, asserting nothing) or
            // stale after a runtime edit (they fail, and the failure reads as a
            // compiler regression).
            //
            // The list used to hold the seed's Zig test roots; those died with the
            // seed (#1593) and the Bit gates took their place, reading the same
            // files the same way. Still per-RUN, never on `test_step` — see the
            // declaration of `libbitrt_readers` for why that distinction is load
            // bearing (#1229).
            libbitrt_readers.append(b.allocator, &install.step) catch @panic("OOM");

            libbitrt_installs[install_idx] = &install.step;
            if (query.cpu_arch == target.result.cpu.arch and query.os_tag == target.result.os.tag) {
                host_libbitrt_bin = archive;
                host_libbitrt_path = b.pathFromRoot(b.fmt("zig-out/lib/{s}/libbitrt.a", .{triple}));
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

    // The CLI-path end-to-end tests (link.zig, main.zig, link/elf_reader.zig,
    // link/macho*.zig) that read `zig-out/lib/<triple>/` are now ordered after
    // EVERY archive install via `libbitrt_readers`, which both
    // keeps them from self-skipping and keeps them from reading a stale archive
    // (#1486). It replaces a bare `test_step.dependOn(host_libbitrt_install)`,
    // which named only the host archive and left the install unordered against
    // the harness runs.

    // The canonical `bit`: the self-hosted bit-in-Bit compiler under `compiler/`,
    // compiled by the bootstrap seed (`bit-seed`) and installed as `bit`. This is
    // the compiler that retires the seed (epic #363-#365). Building it means
    // RUNNING the seed to compile compiler/, so it only works when the seed
    // targets the build host — a cross-compile (`-Dtarget=` for another machine)
    // cannot exec it. So a NATIVE `zig build` produces `bit` in the default
    // install; a cross build produces only `bit-seed` (use `bit-seed build
    // selfhost --target <t>` to cross-produce a self-hosted bit). The seed is
    // always kept alongside as `bit-seed` for bootstrap + the differentials.
    // Runs from the build root so the seed resolves both `compiler/` and the host
    // `zig-out/lib/<triple>/libbitrt.a`. Depends on the seed's install
    // specifically (not the whole install step) to stay cycle-free.
    const native = target.result.cpu.arch == b.graph.host.result.cpu.arch and
        target.result.os.tag == b.graph.host.result.os.tag;

    // Rebuild-cache gate (#1796): compiler/**/*.bit are the compiler's real
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
        fingerprintTree(b, &.{"compiler"}, &.{ "build.zig", ".zigversion" }, libbitrt_fp)
    else
        [_]u8{0} ** 64;
    const selfhost_skip = selfhost_gate_applies and
        fingerprintMatchesStamp(b, "fp-selfhost.stamp", selfhost_fp, &.{selfhost_artifact_path});

    const selfhost_step = b.step("selfhost", "Build the self-hosted compiler (compiler/) with the pinned stage0 → bit");

    var selfhosted: std.Build.LazyPath = undefined;
    // Exposed so a gate that READS `zig-out/bin/bit` off disk (rather than
    // taking it as a LazyPath arg) can depend on the install and stop racing
    // it. tests/bit/stress.bit is the case: it copies the compiler out of
    // zig-out to get a private one, and a copy taken mid-publish yields a
    // truncated binary — #1644's hazard, one step earlier than #1644 found it.
    var selfhost_install_step: ?*std.Build.Step = null;

    if (selfhost_skip) {
        // Fingerprint unchanged and the previously-built `bit` is still on
        // disk: skip re-running the seed over compiler/ entirely. No step
        // dependency on `.cwd_relative` on purpose — nothing writes this file
        // this invocation.
        selfhosted = .{ .cwd_relative = selfhost_artifact_path };
    } else {
        const selfhost_run = b.addSystemCommand(&.{stage0_bit});
        selfhost_run.step.dependOn(&stage0_ensure.step);
        // LINK THE TREE'S RUNTIME, NOT THE RELEASE'S (#1857). stage0 is an
        // installed toolchain and resolves `libbitrt.a` relative to itself, so
        // without this the compiler `zig build` produces is linked against the
        // PREVIOUS RELEASE's runtime — every runtime/ change invisible to the
        // compiler binary until the next release. The seed did the right thing
        // by accident (it defaulted to `zig-out/lib/<triple>/`); switching the
        // bootstrap to stage0 in 3cb1f85 silently changed it, and the symptom
        // was a fixed `bit_rt_parse_float` that had no effect on `bit`.
        //
        // Set here rather than in scripts/stage0.sh's wrapper for the reason
        // that file records: BIT_LIBBITRT names ONE archive for ONE triple, and
        // the wrapper cannot know the target. This build is host-native, so the
        // host archive is the right one, and the run already depends on its
        // install below.
        // Named as the INSTALL PATH string, not the archive's LazyPath: a
        // LazyPath cannot be resolved while the graph is still being built
        // (`getPath2` panics at configure time), and an env var takes a string.
        // Ordering is carried by the explicit dependency on the install below,
        // which is the same shape every `addBitGate` env path uses.
        if (host_libbitrt_path) |rt| selfhost_run.setEnvironmentVariable("BIT_LIBBITRT", rt);
        selfhost_run.addArg("build");
        if (b.user_input_options.contains("version")) {
            // `-Dversion=` given: compile a COPY of compiler/ whose `version.bit`
            // carries the override, so the self-hosted `bit` reports exactly what
            // the seed reports (#1451). Only on the override path — an ordinary
            // build compiles the real source tree, unstaged, so the common case
            // gains no copy step and no new way to go stale.
            const staged = b.addWriteFiles();
            // The real `version.bit` MUST be excluded, not merely overwritten:
            // WriteFile emits its added files first and its copied directories
            // second, so an unexcluded copy silently clobbers the stamped file and
            // the release binary reports the development version (it did).
            _ = staged.addCopyDirectory(b.path("compiler"), "", .{ .exclude_extensions = &.{"version.bit"} });
            _ = staged.add("version.bit", b.fmt(
                "// Generated by build.zig from -Dversion=. Source of truth: compiler/version.bit.\nconst bitVersion: string = \"{s}\"\n",
                .{version},
            ));
            selfhost_run.addDirectoryArg(staged.getDirectory());
        } else {
            selfhost_run.addArg("compiler");
        }
        selfhost_run.addArg("-o");
        selfhosted = selfhost_run.addOutputFileArg("bit");
        if (host_libbitrt_install) |inst| selfhost_run.step.dependOn(inst);
        // `zig build selfhost` alone reaches libbitrt only as this dependency —
        // never through `libbitrt_step`/`test_step` — so without this its
        // rebuild would go unrecorded and the next libbitrt-only invocation
        // would needlessly redo it (safe, just not free).
        if (libbitrt_record_step) |s| selfhost_step.dependOn(s);
        // The seed reads compiler/*.bit at runtime, invisible to the build cache, so
        // an edit to a ported module wouldn't re-trigger the build — force it.
        selfhost_run.has_side_effects = true;
        const install_bit = b.addInstallBinFile(selfhosted, "bit");
        // Only pull `bit` into the default install on a native build (see above).
        if (native) b.getInstallStep().dependOn(&install_bit.step);
        selfhost_step.dependOn(&install_bit.step);
        selfhost_install_step = &install_bit.step;

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

    // The `selfhost_bit` wiring that stood here fed tests/{imports,diffimports,
    // version}.zig, all three of which died with the seed (#1593). Their
    // surviving coverage is `test-imports-bit` (the same 96 projects) and
    // `test-version-cli`, both of which take the compiler as a LazyPath through
    // `addBitGate` and so need no separate plumbing.

    // Gate the self-host: `zig build test` (and the x86_64 gate) builds the
    // self-hosted `bit` from the current compiler/ sources and runs
    // `bit selfcheck` — the in-Bit self-checks (compiler/selfcheck.bit). A failed
    // assert panics (exit 2) and fails the build, so a regression in a ported
    // module is caught on both arm64 and x86_64. `bit` targets the host, so it
    // always execs here. `has_side_effects` keeps it from being cache-skipped.
    //
    // The SUBCOMMAND IS REQUIRED (#1827). This used to run the binary bare,
    // because no-args meant selfcheck; that shipped a compiler which ran its own
    // test suite when a user typed `bit`, so no-args is now a usage error (exit 2)
    // and this gate would fail without the explicit argument.
    const selfhost_selfcheck = std.Build.Step.Run.create(b, "run self-hosted bit self-checks");
    selfhost_selfcheck.addFileArg(selfhosted);
    selfhost_selfcheck.addArg("selfcheck");
    selfhost_selfcheck.has_side_effects = true;
    selfhost_selfcheck.expectExitCode(0);
    test_step.dependOn(&selfhost_selfcheck.step);

    // Format gate (#1266, re-homed by #1848): every `.bit` source under stdlib/
    // and examples/ must already be canonical. This used to be tests/fmt_check.zig,
    // 71 lines of Zig re-walking both trees and calling the formatter in-process;
    // `bit fmt --check <dir>...` is the same question asked of the shipped CLI, so
    // the harness was deleted rather than ported.
    //
    // NOTE THE CHANGE OF AUTHORITY: the old harness imported the SEED's formatter
    // (`fmt_check_mod.addImport("bit", exe.root_module)`), so it asked "is this
    // canonical to bit-seed". This asks "is this canonical to the compiler that
    // actually ships" — the correct question once seed/ is gone, and the one that
    // keeps meaning afterwards. Seed-vs-selfhost formatter agreement is a separate
    // property, already gated by scripts/selfhost-difffmt.sh.
    //
    // tests/cases/ stays excluded on purpose: its `// fmt` cases are deliberately
    // UNformatted input to the formatter and its `// error` cases do not parse, so
    // gating either would be self-contradictory.
    //
    // Non-vacuity is enforced in the CLI, not here: `bit fmt` treats a directory
    // holding no `.bit` source as an error (compiler/main.bit's `fmtPaths`), so a
    // mistyped path fails loudly instead of passing over an empty input set.
    // Directories, never file paths — a source added later must not escape it.
    const fmt_gate = std.Build.Step.Run.create(b, "bit fmt --check stdlib examples");
    fmt_gate.addFileArg(selfhosted);
    fmt_gate.addArgs(&.{ "fmt", "--check" });
    fmt_gate.addDirectoryArg(b.path("stdlib"));
    fmt_gate.addDirectoryArg(b.path("examples"));
    // Sources are read at run time, invisible to the build cache; without this a
    // drifted file is cache-skipped into a false pass.
    fmt_gate.has_side_effects = true;
    fmt_gate.expectExitCode(0);
    test_step.dependOn(&fmt_gate.step);
    addNamedRun(b, fmt_gate, "test-fmt", "run the Bit-source fmt-canonical gate (`bit fmt --check`) only");

    // ---- Bit-native harnesses (#1591) -------------------------------------
    // Each of these replaced a tests/*.zig harness that was deleted with it.
    // They live here because `selfhosted` is the compiler under test AND the
    // interpreter running the check, so both sides need it in scope.
    const stdlib_root = b.pathFromRoot("stdlib");

    const osenv_gate = addBitGate(b, selfhosted, test_step, libbitrt_readers.items, "osenv", "tests/bit/osenv.bit", &.{
        .{ "BIT_STDLIB", stdlib_root },
    }, "run the std/os args+environment round-trip (tests/bit/osenv.bit) only");
    // It compiles and execs a fixture, so it needs a host libbitrt on disk;
    // without the dependency a stale archive gets linked (#1229).
    if (host_libbitrt_install) |inst| osenv_gate.step.dependOn(inst);

    _ = addBitGate(b, selfhosted, test_step, libbitrt_readers.items, "stdlib-docs", "tests/bit/stdlibdocs.bit", &.{
        .{ "BIT_DOCS_ROOT", b.pathFromRoot(".") },
        .{ "BIT_STDLIB", stdlib_root },
    }, "run the stdlib doc-coverage gate (tests/bit/stdlibdocs.bit) only");

    // "version-cli", not "version": tests/version.zig still owns `test-version`
    // for its seed-vs-selfhost parity half, which dies with seed/ (#1593) rather
    // than being ported. The two names coexist until then.
    _ = addBitGate(b, selfhosted, test_step, libbitrt_readers.items, "version-cli", "tests/bit/version.bit", &.{
        .{ "BIT_REPO", b.build_root.path.? },
    }, "run the `bit version` CLI contract (tests/bit/version.bit) only");

    // `bit lint` is selfhost-only, so the harness drives the same binary that
    // interprets it — BIT_SELF_EXE is that path, not argv[0].
    const lint_gate = addBitGate(b, selfhosted, test_step, libbitrt_readers.items, "lint", "tests/bit/lintcmd.bit", &.{
        .{ "BIT_SELF_EXE", selfhost_artifact_path },
        .{ "BIT_STDLIB", stdlib_root },
    }, "run the `bit lint` CLI contract (tests/bit/lintcmd.bit) only");
    // BIT_SELF_EXE names zig-out/bin/bit by PATH, so this must not run while
    // that file is still being installed — a partially-written binary execs and
    // SIGSEGVs with empty stderr (#1644). Same reason as the stress gate.
    if (selfhost_install_step) |inst| lint_gate.step.dependOn(inst);

    const pathresolve_gate = addBitGate(b, selfhosted, test_step, libbitrt_readers.items, "pathresolve", "tests/bit/pathresolve.bit", &.{
        .{ "BIT_STDLIB", stdlib_root },
    }, "run the install-prefix path-resolution gate (tests/bit/pathresolve.bit) only");
    if (host_libbitrt_install) |inst| pathresolve_gate.step.dependOn(inst);

    const pmimports_gate = addBitGate(b, selfhosted, test_step, libbitrt_readers.items, "pmimports", "tests/bit/pmimports.bit", &.{
        .{ "BIT_STDLIB_UNDER_TEST", stdlib_root },
    }, "run the package-manager import-resolution CLI contract (tests/bit/pmimports.bit) only");
    if (host_libbitrt_install) |inst| pmimports_gate.step.dependOn(inst);

    // Compiles and runs every examples/*.bit, so it needs the host archive.
    const examples_gate = addBitGate(b, selfhosted, test_step, libbitrt_readers.items, "examples", "tests/bit/examplesgate.bit", &.{
        .{ "BIT_STDLIB", stdlib_root },
        .{ "BIT_EXAMPLES_DIR", b.pathFromRoot("examples") },
    }, "run the examples/*.bit build+run guard (tests/bit/examplesgate.bit) only");
    if (host_libbitrt_install) |inst| examples_gate.step.dependOn(inst);

    // Fuzz harness (#334): the lexer+parser must never crash or hang on
    // arbitrary bytes. Now tests/bit/fuzz.bit, driving `bit check` OUT of
    // process — the kernel reports a fault as an exit status and `osRunBounded`
    // reports a hang as -2, so the 174-line signal-handler-plus-watchdog
    // apparatus in the old tests/fuzz/guard.zig has no counterpart and needed
    // none. Zig's `-ffuzz` workarounds (ziglang/zig#26040: one `test` per
    // instrumented binary, a separate always-plain replay binary) were Zig's
    // problem and are gone with it.
    //
    // In `zig build test` the budget is short AND THE SEED IS FIXED. A random
    // seed here would make the main suite nondeterministically red, which is
    // how a suite gets ignored; the open-ended search belongs in `zig build
    // fuzz`. The saved-crash replay under tests/fuzz/crashes/ runs first
    // either way, and that part IS deterministic.
    const fuzz_smoke = std.Build.Step.Run.create(b, "bit run tests/bit/fuzz.bit");
    fuzz_smoke.addFileArg(selfhosted);
    fuzz_smoke.addArg("run");
    fuzz_smoke.addFileArg(b.path("tests/bit/fuzz.bit"));
    fuzz_smoke.setEnvironmentVariable("BIT_FUZZ_BIN", selfhost_artifact_path);
    fuzz_smoke.setEnvironmentVariable("BIT_FUZZ_CASES", b.pathFromRoot("tests/cases"));
    fuzz_smoke.setEnvironmentVariable("BIT_FUZZ_CRASHES", b.pathFromRoot("tests/fuzz/crashes"));
    fuzz_smoke.setEnvironmentVariable("BIT_FUZZ_SECONDS", "5");
    fuzz_smoke.setEnvironmentVariable("BIT_FUZZ_SEED", "1");
    fuzz_smoke.setEnvironmentVariable("BIT_STDLIB", b.pathFromRoot("stdlib"));
    if (selfhost_install_step) |inst| fuzz_smoke.step.dependOn(inst);
    fuzz_smoke.has_side_effects = true;
    fuzz_smoke.expectExitCode(0);
    test_step.dependOn(&fuzz_smoke.step);
    addNamedRun(b, fuzz_smoke, "test-fuzz", "run the saved-crash replay + a 5s fixed-seed fuzz only");

    // `zig build fuzz [-- <seconds> [seed]]`: the open-ended run.
    const run_fuzz = std.Build.Step.Run.create(b, "scripts/fuzz.sh");
    run_fuzz.addFileArg(b.path("scripts/fuzz.sh"));
    if (b.args) |args| run_fuzz.addArgs(args);
    run_fuzz.setEnvironmentVariable("BIT_FUZZ_BIN", selfhost_artifact_path);
    run_fuzz.has_side_effects = true;
    b.step("fuzz", "Mutation-fuzz the lexer+parser (default 60s; pass -- <seconds> [seed])").dependOn(&run_fuzz.step);

    // Doc-snippet typecheck (#351), replacing tests/docs.zig. Was held off
    // test_step at 303s; batching brought it to 45s on an idle host (measured,
    // load 2.3), which is affordable in a ~15 minute suite. The verdict is
    // unchanged: 271 blocks over 31 pages, and a failing block is still named by
    // file and page rather than lost in a batch.
    const docs_bit = std.Build.Step.Run.create(b, "bit run tests/bit/docs.bit");
    docs_bit.addFileArg(selfhosted);
    docs_bit.addArg("run");
    docs_bit.addFileArg(b.path("tests/bit/docs.bit"));
    docs_bit.setEnvironmentVariable("BIT_STDLIB", stdlib_root);
    // docs/ is read at run time, invisible to the build cache.
    docs_bit.has_side_effects = true;
    docs_bit.expectExitCode(0);
    if (selfhost_install_step) |inst| docs_bit.step.dependOn(inst);
    test_step.dependOn(&docs_bit.step);
    addNamedRun(b, docs_bit, "test-docs", "run the doc-snippet typecheck gate (tests/bit/docs.bit) only");

    // Selfhost-half import resolution. Named-only for now — see the note beside
    // tests/imports.zig for why running both would just double the suite.
    const imports_bit = std.Build.Step.Run.create(b, "bit run tests/bit/importsrun.bit");
    imports_bit.addFileArg(selfhosted);
    imports_bit.addArg("run");
    imports_bit.addFileArg(b.path("tests/bit/importsrun.bit"));
    imports_bit.setEnvironmentVariable("BIT_IMPORTS_BIT", selfhost_artifact_path);
    imports_bit.setEnvironmentVariable("BIT_IMPORTS_DIR", b.pathFromRoot("tests/imports"));
    imports_bit.setEnvironmentVariable("BIT_STDLIB", stdlib_root);
    if (selfhost_install_step) |inst| imports_bit.step.dependOn(inst);
    imports_bit.has_side_effects = true;
    imports_bit.expectExitCode(0);
    addNamedRun(b, imports_bit, "test-imports-bit", "run the Bit import-resolution gate (selfhost half only)");

    // Concurrency + GC stress corpus (#350), replacing tests/stress.zig.
    //
    // ONE THING IS DELIBERATELY LOST: the Zig harness built every program with
    // BOTH compilers, 78 programs x 2 compilers x 2 GC policies = 312 runs. This
    // drives only the shipped `bit`, so 156. The seed pass is dropped, not
    // ported — the seed is the retiring bootstrap oracle and `bit` is what ships,
    // so a stress corpus proving the seed's runtime is proving a thing that is
    // being deleted. Recorded here because it is a coverage reduction, not a
    // refactor, and #1593 is where the argument for it finally lands.
    //
    // Halving the run also matters right now: at #1849's regressed runtimes the
    // 312-run version was tipping past its deadline under ordinary parallelism.
    const stress_gate = addBitGate(b, selfhosted, test_step, libbitrt_readers.items, "stress", "tests/bit/stress.bit", &.{
        .{ "BIT_STDLIB", stdlib_root },
    }, "run the tests/stress/* corpus (tests/bit/stress.bit) only");
    if (host_libbitrt_install) |inst| stress_gate.step.dependOn(inst);
    // stress.bit reads `zig-out/bin/bit` off disk to make its private copy, so
    // it must not run while that file is still being installed. Without this the
    // gate fails with NO harness output at all — the copy catches a partial
    // binary — which reads exactly like the harness being broken. It is not; the
    // same command passes standalone. This is tests/selfbin.zig's property
    // reappearing in the Bit toolchain, which is why the class-(a) audit called
    // that harness misclassified.
    if (selfhost_install_step) |inst| stress_gate.step.dependOn(inst);

    // Poll-free runtime audit (#1656/#1658), replacing tests/rootabi_pollfree.zig.
    // Every top-level function under runtime/{root,rand,net} must be @nosplit or
    // @naked, or be one of 95 reviewed exceptions — carried across verbatim and
    // machine-verified byte-identical to the Zig table.
    _ = addBitGate(b, selfhosted, test_step, libbitrt_readers.items, "pollfree", "tests/bit/pollfree.bit", &.{
        .{ "BIT_STDLIB", stdlib_root },
    }, "run the poll-free runtime audit (tests/bit/pollfree.bit) only");

    // Stop-the-world wiring (#1639), replacing tests/stwwiring.zig: the collector
    // and netpoller must actually be REACHABLE from a booted program. Checked on
    // the emitted objects, so it needs the compiler settled on disk.
    const stw_gate = addBitGate(b, selfhosted, test_step, libbitrt_readers.items, "stwwiring", "tests/bit/stwwiring.bit", &.{
        .{ "BIT_STDLIB", stdlib_root },
    }, "run the stop-the-world wiring gate (tests/bit/stwwiring.bit) only");
    if (selfhost_install_step) |inst| stw_gate.step.dependOn(inst);
    if (host_libbitrt_install) |inst| stw_gate.step.dependOn(inst);

    // Runtime-ABI register class (#1655), replacing tests/rootabi.zig. The
    // oracle MOVED: the Zig gate compared the `@symbol(...)` pin against
    // runtime/root.zig's `export fn`, and one of those is being deleted. This
    // compares the pin against the compiler's own emission — it runs `bit
    // --dump-ir` on a probe and reads the register class each rt_call actually
    // reads its result from. Neither side is Zig, and it cannot degenerate into
    // a table agreeing with itself.
    const rootabi_gate = addBitGate(b, selfhosted, test_step, libbitrt_readers.items, "rootabi", "tests/bit/rootabi.bit", &.{
        .{ "BIT_STDLIB", stdlib_root },
    }, "run the runtime-ABI register-class gate (tests/bit/rootabi.bit) only");
    if (selfhost_install_step) |inst| rootabi_gate.step.dependOn(inst);

    // ABI membership (#1674), replacing tests/rootabi_membership.zig: every
    // bit_rt_* name the compiler can emit must have a pin providing it.
    const abimembers_gate = addBitGate(b, selfhosted, test_step, libbitrt_readers.items, "abimembers", "tests/bit/abimembers.bit", &.{
        .{ "BIT_STDLIB", stdlib_root },
    }, "run the ABI-membership gate (tests/bit/abimembers.bit) only");
    if (selfhost_install_step) |inst| abimembers_gate.step.dependOn(inst);

    // Runtime-pin cycle gate (#1367), replacing tests/rootpins.zig: no bit_rt_*
    // definition may relocate to itself. Now that libbitrt.a is all-Bit, such a
    // definition is unbounded recursion in every shipped binary. Spawns 28
    // compiler children, ~51s.
    const rootpins_gate = addBitGate(b, selfhosted, test_step, libbitrt_readers.items, "rootpins", "tests/bit/rootpins.bit", &.{
        .{ "BIT_STDLIB", stdlib_root },
    }, "run the runtime-pin cycle gate (tests/bit/rootpins.bit) only");
    if (selfhost_install_step) |inst| rootpins_gate.step.dependOn(inst);

    // getauxval (#1591): runtime/auxv had NO test in any language. The Zig one
    // that covered it lives in runtime/shims.zig, which dies with the runtime.
    _ = addBitGate(b, selfhosted, test_step, libbitrt_readers.items, "auxv", "tests/bit/auxv.bit", &.{
        .{ "BIT_STDLIB", stdlib_root },
    }, "run the getauxval gate (tests/bit/auxv.bit) only");

    // Context-switch throughput (#1849). runtime/sched.zig's "<1us/switch" test
    // is the ONLY throughput assertion in the repo — a grep across tests/ for
    // any such gate returns nothing — and it dies with the runtime. #1849 is a
    // 4-9x performance regression that nothing caught, which is what a repo with
    // no perf gate looks like.
    const schedbench_gate = addBitGate(b, selfhosted, test_step, libbitrt_readers.items, "schedbench", "tests/bit/schedbench.bit", &.{
        .{ "BIT_STDLIB", stdlib_root },
    }, "run the context-switch throughput gate (tests/bit/schedbench.bit) only");
    if (host_libbitrt_install) |inst| schedbench_gate.step.dependOn(inst);

    // Golden corpus (#1591), replacing tests/harness.zig — all 336 cases against
    // the SHIPPED compiler. tests/golden-gaps.txt holds the documented
    // divergences, gated on the SET like tests/selfhost-imports-gaps.txt: a
    // listed case that starts PASSING fails as a stale gap, and a listed name
    // absent from the corpus fails as dangling, so the list cannot rot into
    // permanent excuses.
    const golden_gate = addBitGate(b, selfhosted, test_step, libbitrt_readers.items, "golden", "tests/bit/golden.bit", &.{
        .{ "BIT_STDLIB", stdlib_root },
        .{ "BIT_CASES_DIR", b.pathFromRoot("tests/cases") },
        .{ "BIT_BIN", selfhost_artifact_path },
        .{ "BIT_LIBBITRT", b.pathFromRoot("zig-out/lib/aarch64-macos/libbitrt.a") },
    }, "run the golden tests/cases/*.bit corpus (tests/bit/golden.bit) only");
    if (selfhost_install_step) |inst| golden_gate.step.dependOn(inst);
    if (host_libbitrt_install) |inst| golden_gate.step.dependOn(inst);

    // Private-copy discipline (#1644), replacing tests/selfbin.zig. The hazard is
    // NOT Zig's: compiler/build.bit:400 publishes with a truncating writeFile and
    // no temp-then-rename, and it bit twice in this session (stress.bit copied a
    // partial file; lintcmd.bit exec'd one and got SIGSEGV with empty stderr).
    const selfbin_gate = addBitGate(b, selfhosted, test_step, libbitrt_readers.items, "selfbin", "tests/bit/selfbin.bit", &.{
        .{ "BIT_STDLIB", stdlib_root },
    }, "run the private-copy discipline gate (tests/bit/selfbin.bit) only");
    if (selfhost_install_step) |inst| selfbin_gate.step.dependOn(inst);
    addNamedRun(b, selfhost_selfcheck, "test-selfcheck", "run the self-hosted bit self-checks (compiler/selfcheck.bit) only");

    // The self-hosted compiler must be able to CHECK ITS OWN SOURCE (#1829).
    //
    // This gate did not exist, and its absence hid a real break: the checker
    // rejected `compiler/pmcli.bit` with three E0057s, so `selfhost-fixpoint.sh`
    // could not produce a stageB at all — while `zig build test` stayed fully green,
    // because not one of the 28 harnesses ran `bit` over `compiler/`. A red fixpoint
    // and a green suite must never coexist again: the fixpoint is the proof that
    // permits retiring seed/, so silence there is expensive.
    //
    // `check`, not `build`: this needs the front end's verdict, not an artifact, and
    // it keeps the step to a few seconds. A golden case cannot cover this — the same
    // construct in a single file checks clean; it took the real module to fail.
    const selfhost_checks_self = std.Build.Step.Run.create(b, "self-hosted bit checks compiler/");
    selfhost_checks_self.addFileArg(selfhosted);
    selfhost_checks_self.addArg("check");
    selfhost_checks_self.addArg("compiler");
    selfhost_checks_self.has_side_effects = true;
    selfhost_checks_self.expectExitCode(0);
    test_step.dependOn(&selfhost_checks_self.step);
    addNamedRun(b, selfhost_checks_self, "test-selfhostcheck", "the self-hosted bit must check compiler/ clean (#1829)");
}
