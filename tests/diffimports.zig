//! Import-set differential (#1436): the two compilers must emit the same set of
//! UNDEFINED symbols for the same source.
//!
//! ---------------------------------------------------------------------------
//! THE DEFECT THIS EXISTS TO CATCH, AND WHY NOTHING ELSE COULD SEE IT
//! ---------------------------------------------------------------------------
//!
//! `extern function close(fd: i32): i32` built clean under both compilers and
//! then SIGSEGV'd under self-hosted `bit` only. The cause was not the linker:
//! `close` is *also* a predeclared builtin (`close(chan)`, SPEC §16.2), and
//! self-hosted `lowerCall` dispatched on the callee's **source text** rather
//! than on its resolved symbol. So the call lowered to `bit_rt_chan_close` and
//! the `_close` import simply ceased to exist — the emitted object referenced a
//! completely different symbol from the one the program named.
//!
//! Every existing gate is blind to that by construction:
//!
//!   - `selfhost-diffcheck.sh` compares DIAGNOSTICS. Both compilers accept the
//!     program, so there is nothing to differ.
//!   - `selfhost-difftypes.sh` / `diffast` compare DUMPS. The AST and the types
//!     are identical; only the lowering diverges.
//!   - `selfhost-diffir.sh` would see it, but only for sources in the IR corpus.
//!   - `zig build test` builds and runs every golden under BOTH compilers
//!     (#1413, #1424), so the crash WOULD be caught — if any corpus program used
//!     `extern` in this shape. None did.
//!
//! That is the recurring structural theme of #1409/#1413/#1415/#1418/#1419/
//! #1424: **a construct outside the corpus is outside every guard.** This gate
//! closes one dimension nothing else watches, and it closes it cheaply — the
//! undefined-symbol set is exactly what `nm -u` prints, and it is the same set
//! the linker resolves against.
//!
//! ---------------------------------------------------------------------------
//! WHY IT READS OBJECTS RATHER THAN COMPARING DUMPS OR RUNNING BINARIES
//! ---------------------------------------------------------------------------
//!
//! The undefined set is a property of the emitted image, not of any dump, so no
//! textual differential can reach it. It is also strictly *stronger* than
//! running the program: a dropped import is a defect whether or not the
//! particular call happens to crash on the host that day. `close(-1)` faulted;
//! a dropped import that lowered to a *plausible* runtime call would have
//! returned a wrong value in silence, which is the same class as #1407 and far
//! harder to notice.
//!
//! Reading objects also makes the gate target-independent in the sense #1421
//! established: it emits for a FIXED target and inspects symbolically, so it
//! fails identically on every host instead of only on the host whose ABI
//! happens to expose the bug.
//!
//! ---------------------------------------------------------------------------
//! WHY THE TARGET IS PINNED TO DARWIN
//! ---------------------------------------------------------------------------
//!
//! `extern function` is refused outright when targeting Linux (E0078: a fully
//! static ELF has nothing to resolve an import against), and the checker refuses
//! it even on an uncalled declaration. So an extern fixture can only be emitted
//! for a Darwin target. Nothing is linked or executed, so this runs on any host.
//!
//! ---------------------------------------------------------------------------
//! VACUITY
//! ---------------------------------------------------------------------------
//!
//! Set equality is trivially satisfiable — two empty sets are equal, and a
//! fixture that stopped importing anything would pass forever while checking
//! nothing. Eleven vacuous guards have been found in this codebase. So each
//! fixture names the symbol it exists to prove, and the gate asserts the SEED
//! actually emits it before comparing. If the fixture rots, the gate fails
//! loudly rather than degrading to a green no-op. The comptime length assert
//! covers the outer level (an empty `fixtures` makes the loop a no-op), the
//! lesson `rootpins` paid for.

const std = @import("std");
const bit = @import("bit");
const build_options = @import("build_options");

const testing = std.testing;
const Io = std.Io;
const Dir = std.Io.Dir;

/// One import-set fixture: a module directory, plus the symbol it exists to
/// prove is imported. `probe` is the anti-vacuity anchor described above — it
/// must appear in the SEED's undefined set or the fixture has stopped testing
/// what it claims.
const Fixture = struct {
    path: []const u8,
    probe: []const u8,
};

/// Mach-O spells C symbols with a leading underscore and both readers pass names
/// through verbatim, so probes are written in the object's own spelling. This is
/// the exact detail that made `rootpins`' entire Darwin half examine nothing.
const fixtures = [_]Fixture{
    // #1436 itself: an extern whose name collides with a predeclared builtin.
    .{ .path = "tests/importsets/externbuiltin", .probe = "_close" },
    // The control: an extern colliding with nothing. Distinguishes "builtin
    // shadowing broke" from "the extern path broke".
    .{ .path = "tests/importsets/externplain", .probe = "_getpid" },
};

/// Every fixture is emitted for this target: `extern function` cannot be
/// emitted for Linux at all (E0078).
const target: bit.BuildTarget = .aarch64_macos;

/// The `--target` spelling self-hosted `bit` accepts on the command line.
/// Written out rather than derived from `@tagName`, which yields the Zig enum
/// spelling (`aarch64_macos`) and not the CLI's (`aarch64-macos`).
fn targetFlag(t: bit.BuildTarget) []const u8 {
    return switch (t) {
        .x86_64_linux => "x86_64-linux",
        .aarch64_linux => "aarch64-linux",
        .aarch64_macos => "aarch64-macos",
    };
}

/// Upper bound on symbols in one object — keeps every walk provably bounded
/// (Power of 10 rule 2). Two orders of magnitude above today's counts.
const max_symbols = 16384;

test "seed and selfhost emit the same undefined-symbol set" {
    // An empty fixture list makes the loop below a no-op and the whole gate a
    // green no-op with it — a per-fixture vacuity check cannot fire for a
    // fixture that is never visited.
    comptime std.debug.assert(fixtures.len != 0);

    // A native build always produces the self-hosted `bit`; a cross build
    // produces only the seed and there is nothing to compare against. Assert
    // rather than silently skipping: a green suite must not be able to mean
    // "the half this gate exists for was not wired up" (#1419).
    try testing.expect(build_options.selfhost_bit.len > 0);

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const gpa = arena_state.allocator();

    // A dedicated `Io.Threaded` over `gpa`: `std.process.run`'s spawn arena is
    // backed by the io's allocator, and mixing the global io's allocator with
    // the per-test allocator trips its leak detector (tests/harness.zig).
    var threaded = Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var failures: usize = 0;

    for (fixtures) |f| {
        const abs = try std.fs.path.join(gpa, &.{ build_options.repo_root, f.path });

        // Self-hosted `bit` is driven first, before this process opens anything
        // for writing: driving it means `fork`, and `fork` copies the whole fd
        // table, so a write fd held here to a file about to be exec'd elsewhere
        // is an ETXTBSY waiting to happen (74811a3, kept by tests/harness.zig).
        const self_obj = try emitWithSelfhost(gpa, io, abs, f);
        const seed_obj = try emitWithSeed(gpa, io, abs, f);

        const seed_undef = try undefinedSet(gpa, f.path, seed_obj);
        const self_undef = try undefinedSet(gpa, f.path, self_obj);

        // ANTI-VACUITY, before any comparison: if the seed does not import the
        // probe, the fixture no longer exercises the extern path and set
        // equality below would be meaningless.
        if (!seed_undef.contains(f.probe)) {
            std.debug.print(
                "diffimports: '{s}' does not import its probe '{s}' under the SEED — " ++
                    "the fixture has stopped exercising the extern path, so comparing " ++
                    "import sets proves nothing. Fix the fixture or update `probe`.\n",
                .{ f.path, f.probe },
            );
            return error.VacuousFixture;
        }

        failures += try report(f.path, "selfhost", seed_undef, self_undef);
        failures += try report(f.path, "seed", self_undef, seed_undef);
    }

    if (failures != 0) return error.ImportSetDivergence;
}

/// Symbols referenced by this object's relocations that the object does not
/// itself define — precisely what `nm -u` prints, and precisely what the linker
/// must resolve.
fn undefinedSet(
    gpa: std.mem.Allocator,
    name: []const u8,
    obj: []const u8,
) !std.StringHashMapUnmanaged(void) {
    const module = bit.macho_reader.read(gpa, name, obj) catch |e| {
        std.debug.print("diffimports: cannot read emitted object for '{s}': {s}\n", .{ name, @errorName(e) });
        return e;
    };

    // Defined first: a reference to a name this object also defines is not an
    // import. Both passes walk the same bounded atom list.
    var defined: std.StringHashMapUnmanaged(void) = .{};
    var scanned: usize = 0;
    for (module.atoms) |atom| {
        scanned += 1;
        if (scanned > max_symbols) return error.TooManySymbols;
        if (atom.binding != .global) continue;
        try defined.put(gpa, atom.name, {});
    }

    var undef: std.StringHashMapUnmanaged(void) = .{};
    for (module.atoms) |atom| {
        for (atom.relocs) |r| {
            scanned += 1;
            if (scanned > max_symbols * 64) return error.TooManyRelocs;
            // `SymbolRef.global` is the linker's own view of the call target —
            // the name codegen actually EMITTED, not the name the source
            // spelled. That is what lets this gate see a call redirected to a
            // different symbol entirely, which is the whole of #1436.
            const t = switch (r.target) {
                .global => |g| g,
                .local => continue,
            };
            if (defined.contains(t)) continue;
            try undef.put(gpa, t, {});
        }
    }
    return undef;
}

/// Prints every symbol in `expected` that `actual` lacks. Called both ways round
/// by the caller, so a symbol invented by one compiler is reported as loudly as
/// one dropped by it.
fn report(
    path: []const u8,
    missing_side: []const u8,
    expected: std.StringHashMapUnmanaged(void),
    actual: std.StringHashMapUnmanaged(void),
) !usize {
    var n: usize = 0;
    var it = expected.iterator();
    while (it.next()) |e| {
        const sym = e.key_ptr.*;
        if (actual.contains(sym)) continue;
        std.debug.print(
            \\diffimports: {s}: '{s}' is imported by the other compiler but NOT by {s}.
            \\  The two compilers disagree about what this object must link against.
            \\  A dropped import means a call was lowered to a DIFFERENT symbol than
            \\  the source named (#1436: a user `extern function close` lost to the
            \\  `close(chan)` builtin because lowering dispatched on source text
            \\  instead of the resolved symbol). Check `lowerCall`'s builtin
            \\  dispatch in both compilers.
            \\
        , .{ path, sym, missing_side });
        n += 1;
    }
    return n;
}

/// Emits `dir_abs` as a relocatable object using the in-process seed.
fn emitWithSeed(gpa: std.mem.Allocator, io: Io, dir_abs: []const u8, f: Fixture) ![]u8 {
    var diags: Io.Writer.Allocating = .init(gpa);
    defer diags.deinit();

    return (try bit.buildProject(
        gpa,
        io,
        dir_abs,
        null,
        build_options.stdlib_dir,
        f.path,
        "", // no archive: emit_obj never links
        target,
        &diags.writer,
        null,
        true, // emit_obj
        false, // freestanding
    )) orelse {
        std.debug.print("diffimports: seed failed to compile '{s}':\n{s}\n", .{ f.path, diags.written() });
        return error.SeedCompileFailed;
    };
}

/// Emits `dir_abs` as a relocatable object by driving the self-hosted `bit`.
fn emitWithSelfhost(gpa: std.mem.Allocator, io: Io, dir_abs: []const u8, f: Fixture) ![]u8 {
    const out = try std.fmt.allocPrint(
        gpa,
        "/tmp/bit-diffimports-{s}-{x}.o",
        .{ std.fs.path.basename(dir_abs), testing.random_seed },
    );
    defer Dir.cwd().deleteFile(io, out) catch {};

    const result = try std.process.run(gpa, io, .{
        .argv = &.{
            build_options.selfhost_bit,
            "build",
            dir_abs,
            "--emit-obj",
            "-o",
            out,
            "--target",
            targetFlag(target),
        },
    });
    if (result.term != .exited or result.term.exited != 0) {
        std.debug.print(
            "diffimports: selfhost failed to compile '{s}':\n{s}{s}\n",
            .{ f.path, result.stdout, result.stderr },
        );
        return error.SelfhostCompileFailed;
    }
    return Dir.cwd().readFileAlloc(io, out, gpa, .limited(64 << 20));
}
