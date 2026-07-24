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
    // -----------------------------------------------------------------------
    // THE NETPOLLER (#1673) — the same defect class as #1639, in a second place
    // -----------------------------------------------------------------------
    //
    // `runtime/sched/{linux,darwin}/poll.bit` was complete and correct: epoll
    // and kqueue providers, one-shot registration, the ADD/MOD re-arm split, the
    // try-lock around the drain. NOTHING CALLED EITHER END OF IT. `pollCreate`
    // had no caller in the tree, so `scPollFd` stayed 0 for the life of every
    // process; `pollDrain` had no caller on the live boot path, so nothing could
    // have delivered a wake even had the descriptor existed.
    //
    // The consequence is SILENT, which is why it needs an object-level gate
    // rather than a test that runs. `netAwaitReady` bails at its `pollFd == 0`
    // guard and reports "there was nobody to park on"; `netReadSock` falls
    // through to the unscheduled-caller spin, exhausts it and returns -1; and
    // `bit_rt_net_read` reports that as an EMPTY READ, which is the documented
    // "peer closed" answer. So `tests/imports/nettcp` printed BLANK LINES where
    // `HELLO`/`BIT` belong and still EXITED 0. No exit-code, example, golden or
    // differential gate could see it, and none did — for as long as the Bit net
    // port has existed, no packet had ever gone through it.
    //
    // It is unobservable on `main` for `tests/stwwiring.zig`'s own stated reason:
    // the linked `libbitrt.a` is Zig's, so `runtime/net`'s Bit code is dead and
    // the Zig netpoller answers instead. Only G2/G3 (#1583/#1584) make it live.
    // What IS observable today is the emitted object: `boot` either references
    // the create/bind pair or it does not, and the worker loop either references
    // the drain or it does not.
    //
    // BOTH HALVES ARE LISTED BECAUSE NEITHER IS SUFFICIENT. A descriptor nothing
    // drains parks the reader forever; a drain with no descriptor returns 0 on
    // its first line. Deleting either call reddens exactly one of these.
    .{
        .path = "runtime/root/darwin",
        .target = .aarch64_macos,
        .from = "",
        .to = "bit_rt_port_sched_poll_create",
        .why = "boot must create the netpoller descriptor, or scPollFd stays 0 and " ++
            "every socket read that must wait returns an empty string (#1673)",
    },
    .{
        .path = "runtime/root/darwin",
        .target = .aarch64_macos,
        .from = "",
        .to = "bit_rt_port_sched_set_poll_fd",
        .why = "boot must bind the descriptor into the scheduler block, or netAwaitReady " ++
            "cannot find it however it was created (#1673)",
    },
    .{
        .path = "runtime/root/darwin",
        .target = .aarch64_macos,
        .from = "",
        .to = "bit_rt_port_sched_poll_drain",
        .why = "the worker loop must drain the netpoller, or a task parked on an fd has " ++
            "no thread in the process that can ever wake it (#1673)",
    },
    .{
        .path = "runtime/root/linux",
        .target = .x86_64_linux,
        .from = "",
        .to = "bit_rt_port_sched_poll_create",
        .why = "boot must create the netpoller descriptor, or scPollFd stays 0 and " ++
            "every socket read that must wait returns an empty string (#1673)",
    },
    .{
        .path = "runtime/root/linux",
        .target = .x86_64_linux,
        .from = "",
        .to = "bit_rt_port_sched_set_poll_fd",
        .why = "boot must bind the descriptor into the scheduler block, or netAwaitReady " ++
            "cannot find it however it was created (#1673)",
    },
    .{
        .path = "runtime/root/linux",
        .target = .x86_64_linux,
        .from = "",
        .to = "bit_rt_port_sched_poll_drain",
        .why = "the worker loop must drain the netpoller, or a task parked on an fd has " ++
            "no thread in the process that can ever wake it (#1673)",
    },
    // -----------------------------------------------------------------------
    // THE `bad=` FIELD (#1682) — the one counter that says the trace was WRONG
    // -----------------------------------------------------------------------
    //
    // `gcStatBadOffsets` counts pointer-map offsets the tracer refused as
    // misaligned or out of body, and SKIPS the field rather than reading past
    // it (`runtime/gc` deviation 5, where Zig asserts). A skipped field is a
    // reference that never gets marked, so a non-zero count means the collector
    // was handed a map it could not trust and traced less than it should have —
    // and a degraded trace reads exactly like a healthy one everywhere else.
    //
    // It was WRITE-ONLY outside unit tests until #1682: `statsReport` printed
    // collections/swept/live/abandoned/oom and stopped, which is why #1679's
    // verification bar asked for `bad=0` from a real run and could not get it.
    //
    // An edge rather than a run, for this file's standing reason: pre-G2 the
    // linked archive is Zig's, so no `BIT_GC_STATS` line a binary prints today
    // comes from `boot.bit` at all. What is observable is that the emitted
    // freestanding object for each platform boot references the accessor.
    // Deleting the field from either `statsReport` reddens exactly its own
    // entry, and both are listed because the two copies are kept identical by
    // hand and nothing else forces them to agree.
    .{
        .path = "runtime/root/darwin",
        .target = .aarch64_macos,
        .from = "",
        .to = "bit_rt_port_stw_bad_offsets",
        .why = "the BIT_GC_STATS line must report refused pointer-map offsets, or a " ++
            "silently degraded trace is indistinguishable from a healthy one (#1682)",
    },
    .{
        .path = "runtime/root/linux",
        .target = .x86_64_linux,
        .from = "",
        .to = "bit_rt_port_stw_bad_offsets",
        .why = "the BIT_GC_STATS line must report refused pointer-map offsets, or a " ++
            "silently degraded trace is indistinguishable from a healthy one (#1682)",
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

// ---------------------------------------------------------------------------
// THE ROOT-CLASS POPULATION FLOOR (#1683)
// ---------------------------------------------------------------------------
//
// #1679 was a root class covered by NOTHING. The per-task scratch area held two
// live references — `scrElem`, a blocking channel send/receive's value slot, and
// `scrErr`, the pending-error object — and no enumerated class reached them, so
// a value in flight through a blocking channel was swept. Every gate in the tree
// was green the whole time: `zig build`, `libbitrt`, `rootpins`, `rootabi`, the
// edges above, `zig build test`, `test-stress` and the full differential sweep.
//
// None of them could have seen it. The differentials compare check/type/IR
// dumps, and a root set appears in no dump. The object-level edges here check
// that a call EXISTS; the missing class was not a missing symbol —
// `gcMarkConservative` was linked and called, just never with those words.
// `zig build test`'s imports corpus links the ZIG archive, whose `root.zig` has
// no scratch area at all, so the defect is unreachable there by construction.
//
// `tests/stress/stwcollect` does drive the Bit collector and IS the right
// vehicle, but on its own it can only check the classes its author thought of:
// it builds its own synthetic root sources, and a class nobody wrote is a class
// nobody constructs. That is the hole this test closes, and it is deliberately
// the cheap, static half of the answer — the expensive half is the per-class
// behavioural case over there, one payload reachable from exactly one class,
// each of which reddens on its own when its class is deleted.
//
// So: the collector enumerates its classes in ONE place, `stw.bit`'s ROOT SET
// header, and every one of them must carry a `ROOT CLASS <n>` case marker in
// `stwcollect.bit`. Adding a class to the collector without adding a case is a
// red build. Deleting a class from the header without deleting its case is a
// red build. Dropping below the floor — the six classes that exist today — is a
// red build even if the two sides still agree, which is what stops the whole
// gate from being quietly emptied one class at a time.
//
// The scratch area's own width is floored for the same reason one level down:
// the scan is bounded by `min(chanScratchWords, stackBytes/8)`, so a shrunken
// `chanScratchWords` would silently narrow the SCANNED SET while every class
// stayed present and every case stayed green.

/// The seven classes `stw.bit` enumerates today (#1742 added the seventh).
/// Raising this is part of adding a class; LOWERING it means a class was
/// deleted, which is exactly the change that must not pass silently.
const min_root_classes = 7;

/// The scratch area's width today. The scan walks the whole area, so this is
/// the population of words a missing-root check can possibly cover.
const min_scratch_words = 265;

const stw_source = "runtime/stw/stw.bit";
const stw_root_set_anchor = "THE ROOT SET, AND WHY IT IS ALL-OR-NOTHING";
const stwcollect_source = "tests/stress/stwcollect/stwcollect.bit";
const case_marker = "ROOT CLASS ";
const scratch_source = "runtime/sched/scratch.bit";
const scratch_words_decl = "export const chanScratchWords: int = ";

/// A set of class numbers 1..63, so the two sides can be compared and the
/// difference NAMED rather than reported as a count mismatch.
const ClassSet = u64;

fn has(set: ClassSet, n: u6) bool {
    return set & (@as(ClassSet, 1) << n) != 0;
}

fn readSource(gpa: std.mem.Allocator, io: Io, rel: []const u8) ![]u8 {
    const abs = try std.fs.path.join(gpa, &.{ build_options.repo_root, rel });
    return Io.Dir.cwd().readFileAlloc(io, abs, gpa, .limited(1 << 20));
}

/// Every class number enumerated in `stw.bit`'s ROOT SET header.
///
/// Bounded to that comment block by its own heading rather than matched over
/// the whole file: `stwPoll`'s body carries a second numbered list ("1. Someone
/// else is collecting"), and a file-wide scan would silently fold the two
/// together — a gate that examines the wrong set is the failure mode this
/// whole test exists to prevent.
fn rootClassesDeclared(src: []const u8) !ClassSet {
    const anchor = std.mem.indexOf(u8, src, stw_root_set_anchor) orelse {
        std.debug.print(
            "stwwiring: {s}: the ROOT SET header ('{s}') is gone. This test examined " ++
                "nothing, which is a failure and not a pass — the class enumeration it " ++
                "reads was renamed or deleted (#1683).\n",
            .{ stw_source, stw_root_set_anchor },
        );
        return error.RootSetHeaderMissing;
    };

    var set: ClassSet = 0;
    var it = std.mem.splitScalar(u8, src[anchor..], '\n');
    _ = it.next(); // the heading line itself
    var lines: usize = 0;
    while (it.next()) |line| {
        lines += 1;
        if (lines > max_scan) return error.TooMuchToScan;
        // The block ends at the first line that is not a comment.
        if (!std.mem.startsWith(u8, line, "//")) break;
        const body = std.mem.trimStart(u8, line[2..], " ");
        if (body.len < 3) continue;
        const dot = std.mem.indexOfScalar(u8, body, '.') orelse continue;
        if (dot == 0 or dot > 2) continue;
        const n = std.fmt.parseInt(u6, body[0..dot], 10) catch continue;
        if (n == 0) continue;
        set |= @as(ClassSet, 1) << n;
    }
    return set;
}

/// Every class number a `ROOT CLASS <n>` marker in `stwcollect.bit` claims a
/// case for. A marker not followed by digits (the rule stated in that file's
/// own header) contributes nothing.
fn rootClassesCovered(src: []const u8) !ClassSet {
    var set: ClassSet = 0;
    var at: usize = 0;
    var found: usize = 0;
    while (std.mem.indexOfPos(u8, src, at, case_marker)) |i| {
        found += 1;
        if (found > max_scan) return error.TooMuchToScan;
        at = i + case_marker.len;
        var end = at;
        while (end < src.len and std.ascii.isDigit(src[end])) end += 1;
        if (end == at) continue;
        const n = std.fmt.parseInt(u6, src[at..end], 10) catch continue;
        if (n == 0) continue;
        set |= @as(ClassSet, 1) << n;
    }
    return set;
}

test "every enumerated GC root class has a case in tests/stress/stwcollect" {
    const io = Io.Threaded.global_single_threaded.io();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const gpa = arena_state.allocator();

    const declared = try rootClassesDeclared(try readSource(gpa, io, stw_source));
    const covered = try rootClassesCovered(try readSource(gpa, io, stwcollect_source));

    if (@popCount(declared) < min_root_classes) {
        std.debug.print(
            "stwwiring: {s} enumerates {d} root classes, floor is {d}. A class was " ++
                "REMOVED from the collector's root set. That is not a cleanup: the " ++
                "symptom of a missing class is a live object swept and a wrong answer " ++
                "somewhere else entirely (#1679). If the removal is deliberate, delete " ++
                "its case in {s} and lower the floor in the same change.\n",
            .{ stw_source, @popCount(declared), min_root_classes, stwcollect_source },
        );
        return error.RootClassCountBelowFloor;
    }

    var n: u6 = 1;
    while (n < 63) : (n += 1) {
        if (has(declared, n) and !has(covered, n)) {
            std.debug.print(
                "stwwiring: root class {d} is enumerated in {s} and has NO case in {s}.\n" ++
                    "  Add a phase there that makes one payload reachable from THAT CLASS " ++
                    "ALONE, asserts it survives a collection with a non-zero count, and " ++
                    "marks itself 'ROOT CLASS {d}'.\n" ++
                    "  A class with no case is exactly #1679: every build, link, golden, " ++
                    "differential and stress gate stayed green while a live value was " ++
                    "being swept.\n",
                .{ n, stw_source, stwcollect_source, n },
            );
            return error.RootClassUncovered;
        }
        if (has(covered, n) and !has(declared, n)) {
            std.debug.print(
                "stwwiring: {s} claims a case for root class {d}, which {s} does not " ++
                    "enumerate. Either the class was deleted from the collector (see the " ++
                    "floor above) or the marker is stale — a case for a class that does " ++
                    "not exist tests nothing.\n",
                .{ stwcollect_source, n, stw_source },
            );
            return error.RootClassCaseStale;
        }
    }
}

test "the scanned scratch area has not shrunk" {
    const io = Io.Threaded.global_single_threaded.io();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const gpa = arena_state.allocator();

    const src = try readSource(gpa, io, scratch_source);
    const at = std.mem.indexOf(u8, src, scratch_words_decl) orelse {
        std.debug.print(
            "stwwiring: {s}: no '{s}' declaration. This check examined nothing.\n",
            .{ scratch_source, scratch_words_decl },
        );
        return error.ScratchWidthAnchorMissing;
    };
    const rest = src[at + scratch_words_decl.len ..];
    var end: usize = 0;
    while (end < rest.len and std.ascii.isDigit(rest[end])) end += 1;
    const words = try std.fmt.parseInt(usize, rest[0..end], 10);

    if (words < min_scratch_words) {
        std.debug.print(
            "stwwiring: chanScratchWords is {d}, floor is {d}. The stop-the-world scratch " ++
                "scan walks min(chanScratchWords, stackBytes/8) words, so shrinking this " ++
                "NARROWS THE SCANNED SET while root class 6 stays present and its case " ++
                "stays green — the live references at scrElem/scrErr/scrRecvOk fall out " ++
                "of the scan one word at a time (#1679, #1683).\n",
            .{ words, min_scratch_words },
        );
        return error.ScratchAreaShrunk;
    }
}
