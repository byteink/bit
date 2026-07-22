//! Stop-the-world WIRING gate (#1639): the collector is not merely present, it
//! is actually reachable from a real program.
//!
//! ---------------------------------------------------------------------------
//! THE DEFECT THIS EXISTS TO CATCH
//! ---------------------------------------------------------------------------
//!
//! #1633 landed `runtime/stw`: `stwBind`, `stwCanCollect`, the root enumeration
//! and the precise stack walk, every piece mutation-tested. It proved itself by
//! calling `stwPoll` BY NAME from a test program that owned its own collector
//! block. NO SUCH CALL EXISTED ON THE LIVE PATH. Nothing bound the World
//! registry, nothing bound the three root sources, and so a fully-Bit
//! `libbitrt.a` reported ZERO collections where the Zig runtime reported 65536.
//!
//! It is silent in every direction. A program that never collects is a program
//! that never frees: it exits 0, prints the right answer, and 27 examples ran
//! byte-identically against that archive with the collector entirely dormant.
//! No build, link, golden, differential or stress gate could see it.
//!
//! ---------------------------------------------------------------------------
//! WHY THIS IS AN OBJECT-LEVEL GATE AND NOT A PROGRAM THAT RUNS
//! ---------------------------------------------------------------------------
//!
//! Because on `main` the property is UNOBSERVABLE AT RUN TIME. `runtime/root.zig`
//! is still in `libbitrt.a` and still owns `bit_rt_safepoint`, so the poll both
//! backends synthesize at every loop back edge goes to ZIG. Any `BIT_GC_STATS`
//! collection count read out of a normally linked binary is Zig's collector's
//! and is identical with or without this wiring — the measurement trap #1632
//! hit and #1633 refused to claim. Only after G2/G3 (#1583/#1584) swap the
//! archive does behaviour diverge, and a gate that can only run after the thing
//! it protects has landed protects nothing.
//!
//! What IS observable today is the emitted object: `boot` either references the
//! bind symbols or it does not, and the safepoint shim either targets the gated
//! entry or it does not. Those are exactly the four facts whose absence produced
//! #1639, and they are checked here in the objects the archive is assembled
//! from. Same oracle the linker uses, same technique as `tests/rootpins.zig`.
//!
//! ---------------------------------------------------------------------------
//! WHAT EACH CHECK PROTECTS, AND THE MUTATION THAT REDDENS IT
//! ---------------------------------------------------------------------------
//!
//!   world_bind   `rootInit` must hand `runtime/gc` the World block. Without it
//!                `worldBlockAddr()` stays 0 and the poll returns before it ever
//!                looks at the registry.   Delete the call -> red.
//!   stw_bind     each platform `boot` must hand `runtime/stw` the collector,
//!                scheduler and channel-registry addresses. `stwCanCollect` is
//!                all-or-nothing, so a missing bind is a permanently dormant
//!                collector rather than a partial one. Delete the call -> red.
//!   shim target  the `@naked bit_rt_safepoint` shim must call `stwSafepoint`,
//!                the pinned live entry, not `stwPoll` directly. Point it back
//!                at `stwPoll` -> red.
//!   registration `stwPoll` must reach the mutator registration door
//!                (`currentMutator`) so that EVERY polling thread is registered
//!                before it can park or collect. Delete the call -> red.
//!   NO gate      `stwSafepoint` must NOT consult the sched task-stack probe.
//!                THIS ENTRY USED TO REQUIRE THE OPPOSITE, and it was pinning a
//!                bug: the #1639 gate was a workaround for one process-wide
//!                current-mutator cell, and it suppressed the poll on a worker's
//!                own OS-thread stack — where `schedWorkerRun`'s `nowFn`/`pollFn`
//!                function-value cells live. They were swept while live and
//!                `tests/stress/chanracelinux` faulted 20/20. #1650 keyed the
//!                registry on a real per-OS-thread token, so the gate has
//!                nothing left to protect. Re-add the gate -> red.
//!
//! The last one is a FORBID edge, and it is the only one here that has to be:
//! a re-added gate ADDS a call rather than removing one, and its consequence is
//! silent — the program prints the same answer while the collector reports
//! `collections=0 abandoned=217`, every rendezvous expiring because a registered
//! worker can never park. No positive edge can express that.
//!
//! Every check names the symbol it expects and fails loudly when it finds
//! nothing, so a rename that makes a check stop matching is a failure rather
//! than a vacuous pass — the specific way `tests/rootpins.zig`'s Darwin half
//! read green for months while examining nothing.

const std = @import("std");
const bit = @import("bit");
const build_options = @import("build_options");

const testing = std.testing;
const Io = std.Io;

/// One required edge: within module `path`, the definition `from` must carry a
/// relocation naming `to`. `from` empty means "any atom in the module", used
/// where the caller is a private function whose symbol name is a mangling
/// detail rather than a contract.
const Edge = struct {
    path: []const u8,
    target: bit.BuildTarget,
    from: []const u8,
    to: []const u8,
    why: []const u8,

    /// When set, the edge must NOT exist: `from` must still be present (so the
    /// check is never vacuous), but must carry no relocation naming `to`.
    ///
    /// Added by #1650 for the one property whose violation is SILENT. Every
    /// other entry here guards against a call going missing, which some run
    /// eventually notices. Re-adding the #1639 safepoint gate does the
    /// opposite — it adds a call — and nothing downstream changes: the program
    /// prints the same answer while `BIT_GC_STATS=1` reports `collections=0
    /// abandoned=217`, because a registered worker that can never park makes
    /// every rendezvous expire. A positive edge cannot express "this call must
    /// not come back", and that is exactly what has to be pinned.
    forbid: bool = false,

    /// Mach-O carries the C leading underscore verbatim and ELF does not;
    /// `macho_reader` passes names through unchanged. Normalising here is what
    /// keeps a Darwin entry from silently matching nothing — the exact vacuity
    /// `tests/rootpins.zig` documents at length.
    fn symPrefix(self: Edge) []const u8 {
        return switch (self.target) {
            .aarch64_macos => "_",
            else => "",
        };
    }
};

/// Both platform boots are listed, each on the target its seams are written for
/// (Linux `syscall`, Darwin `extern function`) — a `linux/` module cannot be
/// emitted for Darwin nor a `darwin/` one for Linux, even on an uncalled
/// declaration. Same per-module targeting as `tests/rootpins.zig`.
const edges = [_]Edge{
    .{
        .path = "runtime/root",
        .target = .aarch64_macos,
        .from = "bit_rt_root_init",
        .to = "bit_rt_port_gc_world_bind",
        .why = "rootInit must bind the World/Mutator registry, or the safepoint poll " ++
            "returns at `worldBlockAddr() == 0` and no thread ever registers",
    },
    .{
        .path = "runtime/root/darwin",
        .target = .aarch64_macos,
        .from = "",
        .to = "bit_rt_port_stw_bind",
        .why = "boot must bind the collector, scheduler and channel registry, or " ++
            "stwCanCollect refuses every collection for the life of the process",
    },
    .{
        .path = "runtime/root/linux",
        .target = .x86_64_linux,
        .from = "",
        .to = "bit_rt_port_stw_bind",
        .why = "boot must bind the collector, scheduler and channel registry, or " ++
            "stwCanCollect refuses every collection for the life of the process",
    },
    .{
        .path = "runtime/stw",
        .target = .aarch64_macos,
        .from = "bit_rt_root_safepoint",
        .to = "bit_rt_port_stw_safepoint",
        .why = "the naked shim must enter through the pinned live entry, not stwPoll directly",
    },
    // THIS EDGE REPLACES THE #1639 GATE ASSERTION, WHICH WAS PINNING A BUG.
    //
    // It used to require `bit_rt_port_stw_safepoint` -> `bit_rt_port_sched_task_on_stack`,
    // i.e. that the safepoint gate on "am I on a green-thread stack". That gate
    // was a workaround for `gcworld.bit` keeping ONE process-wide current-mutator
    // cell, and #1650 measured what it cost: `schedCurrentTask()` is 0 on a
    // worker's OWN OS-thread stack, so a worker's run loop never polled, and
    // `schedWorkerRun`'s `nowFn`/`pollFn` function-value cells — which live in
    // exactly those frames — were swept while live. `tests/stress/chanracelinux`
    // faulted 20 runs out of 20 against a Bit-built `libbitrt.a`.
    //
    // The registry is keyed on a real per-OS-thread token now (`gcthread.bit`),
    // so the gate is gone. What must be pinned instead is the property the gate
    // was standing in front of: EVERY thread that polls must go through
    // registration first. Re-adding the gate breaks this edge, and it must
    // break, because the failure a re-added gate produces is silent — the
    // program still prints the right answer while `BIT_GC_STATS=1` reports
    // `collections=0 abandoned=217`. A registered worker that never parks makes
    // every rendezvous expire, so the collector stops collecting altogether and
    // no test output changes. Measured, not predicted.
    .{
        .path = "runtime/stw",
        .target = .aarch64_macos,
        .from = "bit_rt_port_stw_safepoint",
        .to = "bit_rt_port_sched_task_on_stack",
        .forbid = true,
        .why = "stwSafepoint must NOT gate on 'am I on a green-thread stack' — that " ++
            "gate suppresses the poll on a worker's own OS-thread stack, where " ++
            "schedWorkerRun's nowFn/pollFn function-value cells live, and they are " ++
            "then swept while live (#1650)",
    },
    // The positive half of the same property, on `stwPoll` because that is the
    // atom that carries it: `stwSafepoint` is a pure forward and `stwPoll` is
    // separately pinned, so the registration edge survives there and not in the
    // caller. Deleting `worldEnsureSelf` from the poll reddens this.
    .{
        .path = "runtime/stw",
        .target = .aarch64_macos,
        .from = "bit_rt_port_stw_poll",
        // `worldEnsureSelf` inlines into the poll, so the edge that survives
        // into the object names the registration door it forwards to.
        .to = "bit_rt_port_gc_current_mutator",
        .why = "the poll must reach the mutator registration door on EVERY thread " ++
            "that polls, or a thread is invisible to both the rendezvous and the " ++
            "root scan and its live references are swept (#1650)",
    },
};

/// Upper bound on atoms/relocations walked in one object — every walk provably
/// bounded (Power of 10 rule 2), two orders of magnitude above today's counts.
const max_scan = 1 << 20;

test "the stop-the-world collector is wired into a real boot" {
    // An empty table makes the loop a no-op and the whole gate a green no-op
    // with it — the failure `tests/rootpins.zig` measured when `modules` was
    // emptied. A per-edge check cannot fire for an edge that is never visited.
    comptime std.debug.assert(edges.len != 0);

    const io = Io.Threaded.global_single_threaded.io();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const gpa = arena_state.allocator();

    for (edges) |e| {
        const abs = try std.fs.path.join(gpa, &.{ build_options.repo_root, e.path });
        const obj = try emitObject(gpa, io, abs, e);

        const module = switch (e.target) {
            .x86_64_linux => bit.elf_reader.read(gpa, .x86_64, e.path, obj),
            .aarch64_linux => bit.elf_reader.read(gpa, .aarch64, e.path, obj),
            .aarch64_macos => bit.macho_reader.read(gpa, e.path, obj),
        } catch |err| {
            std.debug.print("stwwiring: cannot read emitted object for '{s}': {s}\n", .{ e.path, @errorName(err) });
            return err;
        };

        try checkEdge(gpa, e, module);
    }
}

/// Emits `dir_abs` for the edge's target, `--freestanding` — WHICH IS LOAD-BEARING
/// AND NOT AN INHERITED DEFAULT. An ordinary object inlines the imported modules'
/// bodies into itself, so `runtime/root/darwin` DEFINES `bit_rt_port_stw_bind`
/// whether or not `boot` calls it, and a "does this object reference the symbol"
/// check matches the definition and passes vacuously. Measured: deleting the
/// `stwBind` call left this gate green until this flag flipped. `--freestanding`
/// is also how the archive G3 ships is actually assembled, so it is the mode
/// whose relocations are the ones that matter.
fn emitObject(gpa: std.mem.Allocator, io: Io, dir_abs: []const u8, e: Edge) ![]u8 {
    var diags: Io.Writer.Allocating = .init(gpa);
    defer diags.deinit();

    const obj = (try bit.buildProject(
        gpa,
        io,
        dir_abs,
        null,
        build_options.stdlib_dir,
        e.path,
        "", // no archive: emit_obj never links
        e.target,
        &diags.writer,
        null,
        true, // emit_obj
        true, // freestanding
    )) orelse {
        std.debug.print("stwwiring: '{s}' failed to compile:\n{s}\n", .{ e.path, diags.written() });
        return error.RuntimeModuleCompileFailed;
    };
    return obj;
}

/// Fails unless some definition in `module` (named `e.from`, or any when that is
/// empty) relocates against `e.to`.
///
/// Reads the LINKER's view of the call target rather than the source's, which is
/// what lets one entry cover an inlined forwarder: `schedCurrentTask` disappears
/// into its caller and the surviving edge names the probe underneath it. A
/// source scan would have had to re-derive that.
fn checkEdge(gpa: std.mem.Allocator, e: Edge, module: anytype) !void {
    const sp = e.symPrefix();
    const want_to = try std.fmt.allocPrint(gpa, "{s}{s}", .{ sp, e.to });
    const want_from = if (e.from.len == 0)
        ""
    else
        try std.fmt.allocPrint(gpa, "{s}{s}", .{ sp, e.from });

    var scanned: usize = 0;
    var from_seen = e.from.len == 0;
    for (module.atoms) |atom| {
        scanned += 1;
        if (scanned > max_scan) return error.TooMuchToScan;
        if (want_from.len != 0) {
            if (!std.mem.eql(u8, atom.name, want_from)) continue;
            from_seen = true;
        }
        for (atom.relocs) |r| {
            scanned += 1;
            if (scanned > max_scan) return error.TooMuchToScan;
            const target = switch (r.target) {
                .global => |g| g,
                .local => continue,
            };
            if (std.mem.eql(u8, target, want_to)) {
                if (!e.forbid) return;
                std.debug.print(
                    \\stwwiring: {s}: '{s}' MUST NOT reference '{s}', and does.
                    \\  {s}.
                    \\
                , .{ e.path, want_from, want_to, e.why });
                return error.StwWiringForbidden;
            }
        }
    }

    // A missing DEFINITION and a missing EDGE are different repairs, so they are
    // reported differently rather than as one "not found".
    if (from_seen and e.forbid) return;

    if (!from_seen) {
        std.debug.print(
            "stwwiring: {s}: no definition named '{s}'. The gate examined nothing " ++
                "for this edge — the symbol was renamed or the pin was dropped, " ++
                "which is a failure here and not a pass.\n",
            .{ e.path, want_from },
        );
        return error.WiringAnchorMissing;
    }

    std.debug.print(
        \\stwwiring: {s}: '{s}' does not reference '{s}'.
        \\  {s}.
        \\  This is invisible to every other gate: pre-G2 the safepoint still
        \\  resolves to runtime/root.zig, so a program linked today collects
        \\  exactly the same with or without the missing call (#1639).
        \\
    , .{ e.path, if (e.from.len == 0) "<any definition>" else want_from, want_to, e.why });
    return error.StwWiringMissing;
}
