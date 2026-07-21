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
//!                the GATED entry, not `stwPoll` directly. Point it back at
//!                `stwPoll` -> red.
//!   the gate     `stwSafepoint` must consult the sched task-stack probe. The
//!                gate is what keeps the boot thread out of the one shared
//!                current-mutator cache; without it the boot thread can become
//!                the collector, and both the rendezvous and the parked-frame
//!                walk SKIP the collector's own slot, so the worker's published
//!                frame — the only precise record of the running task's
//!                references — is never scanned and its references are swept.
//!                Delete the gate -> red.
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
        .why = "the naked shim must enter through the GATED poll, not stwPoll directly",
    },
    .{
        .path = "runtime/stw",
        .target = .aarch64_macos,
        .from = "bit_rt_port_stw_safepoint",
        // `schedCurrentTask` inlines (it reads `sp` and forwards), so the edge
        // that survives into the object is to the probe it forwards to.
        .to = "bit_rt_port_sched_task_on_stack",
        .why = "stwSafepoint must gate on 'am I on a green-thread stack', or the boot " ++
            "thread shares the one current-mutator slot with the worker and can " ++
            "collect while skipping the worker's published frame",
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
            if (std.mem.eql(u8, target, want_to)) return;
        }
    }

    // A missing DEFINITION and a missing EDGE are different repairs, so they are
    // reported differently rather than as one "not found".
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
