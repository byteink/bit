//! Poll-free gate (#1658), split out of `rootabi.zig` under #1674 — see that
//! file's header for how this relates to the other two runtime-ABI gates.
//! Anchored into the `rootabi.zig` test binary via `_ = @import(...)` there,
//! following this repo's existing anchor idiom (see `tests/testroots.zig`).

const std = @import("std");
const bit = @import("bit");
const build_options = @import("build_options");
const testing = std.testing;
const Io = std.Io;
const Dir = std.Io.Dir;

const shared = @import("rootabi_shared.zig");
const max_source_bytes = shared.max_source_bytes;
const max_bit_files = shared.max_bit_files;
const nodeText = shared.nodeText;

// ---------------------------------------------------------------------------
// 2. THE POLL-FREE GATE (#1658)
// ---------------------------------------------------------------------------
//
// THE DEFECT (#1656, an s0 that survived four G3 attempts; read that ticket for
// the full mechanism). A `bit_rt_*` function written in Bit and NOT marked
// `@nosplit` gets a compiler-synthesized `bl bit_rt_safepoint` at every loop
// back edge (`seed/codegen/arm64.zig`'s `needsNoSafepoints`), so a collection
// can run INSIDE the runtime — where the Zig runtime never collects, carrying no
// back-edge polls. There the runtime holds its GC objects only as raw `int`
// addresses and interior pointers, because the ABI boundary FORCES that (E0079:
// a pinned symbol may not name a managed type), and no stack map names them —
// ABI.md §5 walks the RUNNING task's stack PRECISELY and scans only every
// *other* registered task's conservatively. So the object is swept, recycled and
// re-zeroed under a live reference.
//
// WHY A GATE AND NOT JUST THE FIX. The whole golden corpus returns OK / NUL 0 /
// HANG 0 on a tree that still has the defect; only `BIT_GC=stress` against a
// relinked compiler discriminates, and that configuration does not exist on
// `main`. Nothing in the tree fails when a NEW runtime function joins the class.
//
// WHAT IS ASSERTED. Every top-level function declared under `runtime/root/**`
// carries `@nosplit` or `@naked`, unless it is on the reviewed exception list
// below. `@nosplit` is the right primitive because E0075 makes the guarantee
// TRANSITIVE over the callee subtree and forbids allocation outright: one
// annotation on an ABI wrapper proves the whole reachable body is poll-free, so
// the checker does the closure and this gate only proves the roots were marked.
//
// SCOPE. `runtime/root/**` (#1658), `runtime/rand/**` (#1667) and
// `runtime/net/**` (#1668) — the three subtrees whose Bit functions are reached
// from an ABI pin. The remaining runtime subtrees (`gc`, `stw`, `alloc`, `chan`,
// `park`, `sched`, `thread`, `auxv`) are NOT asserted here, and this sentence is
// the honest statement of that rather than an implied clean bill.
//
// WHAT `runtime/net` ADDED TO THE PICTURE (#1668), because it is the shape
// `@nosplit` cannot express. `netReadSock` and its siblings must be able to PARK
// the calling green thread, and E0075 is transitive into the scheduler, so the
// annotation is unavailable to them by construction. What #1658 requires is not
// the annotation but THE PROPERTY BEHIND IT — no raw GC address held across a
// poll — and there are two ways to have it:
//
//   (a) `@nosplit`: no poll can occur, so a raw address is safe. Mechanically
//       checked, which is why it is preferred and why this gate demands it.
//   (b) Hold no raw GC address in the first place. `runtime/net`'s port layer
//       takes every buffer as a `*u8` PARAMETER into memory its CALLER owns, and
//       `netabi.bit`'s wrappers now hold their receive buffers as MANAGED `[]i64`
//       locals — real stack-map slots the precise walk names, whose backing the
//       non-moving collector never relocates. A `string` arriving as a raw `int`
//       parameter is likewise rooted by the compiled Bit caller's own frame,
//       which is what makes it different from #1656's `rtFsReadAll`, where the
//       object was allocated INSIDE the runtime and so named by no frame at all.
//
// (b) is a REVIEWED claim, not a checked one, so every function resting on it is
// an entry below carrying its argument. That is why the exception list is spelled
// out per function rather than per directory.

/// A subtree this gate covers, relative to `runtime/`, with a lower bound on the
/// declarations it must yield.
///
/// THE FLOOR IS PER-SUBTREE, AND THAT IS THE POINT. A single total floor lets one
/// subtree fall to zero — a moved directory, a renamed provider, a parser change
/// — while another's growth keeps the sum above the line, which is exactly the
/// vacuous pass this gate exists to prevent. #1658's first cut silently examined
/// 223 of 265 declarations and only a floor surfaced it.
const PollFreeRoot = struct { sub: []const u8, min_scanned: usize };

/// Today's populations are root 265, rand 17, net 189. Each floor sits under its
/// own subtree, and is a floor rather than a target.
const poll_free_roots = [_]PollFreeRoot{
    .{ .sub = "root", .min_scanned = 240 },
    .{ .sub = "rand", .min_scanned = 15 },
    .{ .sub = "net", .min_scanned = 170 },
};

/// Functions under `runtime/root/**` that are deliberately NOT poll-free.
///
/// EVERY ENTRY IS A CLAIM THAT THE FUNCTION HOLDS NO GC OBJECT AS A RAW
/// ADDRESS, not merely that annotating it was inconvenient. Adding a line here
/// is a review decision; the four groups and their reasons:
///
/// (a) `float{big,fmt,parse}.bit` and the two `floats.bit` wrappers — genuinely
///     MANAGED Bit code, allocating bignum limb arrays, digit buffers and
///     `string`s, so `@nosplit` (which forbids allocation) is not available to
///     them. #1658 gave them the property instead of the annotation: every raw
///     address now lives inside `packLowBytes`/`unpackToWords`, which ARE
///     `@nosplit`, and the outer bodies hold only managed values.
/// (b) `rootconfig.bit`/`testindex.bit` — they read the kernel-supplied `envp`
///     block, so every address they carry is outside the heap. They could not be
///     annotated anyway: `len(<literal>)` is not `@nosplit`-callable.
/// (c) `{darwin,linux}/boot.bit`'s boot machinery — must reach the scheduler,
///     thread and park layers and run user `main`, which E0075 would forbid. It
///     carries only raw kernel addresses (argv/envp/auxv, `mapPages` stacks).
/// (d) `{darwin,linux}/time.bit`'s three ABI pins — every parameter and result
///     is a scalar `int`; no object crosses them in either direction.
const poll_free_exceptions = [_][]const u8{
    // (a) managed float text — see `runtime/root/floats.bit`'s SEAM 5a block.
    "root/floatbig.bit:bigLimbs",
    "root/floatbig.bit:bigNew",
    "root/floatbig.bit:bigSetU64",
    "root/floatbig.bit:bigNorm",
    "root/floatbig.bit:bigCopy",
    "root/floatbig.bit:bigCmp",
    "root/floatbig.bit:bigAdd",
    "root/floatbig.bit:bigSub",
    "root/floatbig.bit:bigMulSmall",
    "root/floatbig.bit:bigMulAddSmall",
    "root/floatbig.bit:bigShl",
    "root/floatbig.bit:bigShr1",
    "root/floatbig.bit:bigBitLen",
    "root/floatbig.bit:bigIsZero",
    "root/floatbig.bit:bigMulPow10",
    "root/floatfmt.bit:fmtMaxDigits",
    "root/floatfmt.bit:fmtBits",
    "root/floatfmt.bit:dragon4",
    "root/floatfmt.bit:highTest",
    "root/floatfmt.bit:render",
    "root/floatfmt.bit:zeros",
    "root/floatfmt.bit:u64BitLen",
    "root/floatfmt.bit:floorDiv",
    "root/floatparse.bit:parseMaxDigits",
    "root/floatparse.bit:parseBits",
    "root/floatparse.bit:roundShiftRight",
    "root/floatparse.bit:infBits",
    "root/floats.bit:rtStringFromFloat",
    "root/floats.bit:rtParseFloat",
    // (b) envp readers — no heap object in play.
    "root/rootconfig.bit:gcEnvValuePtr",
    "root/rootconfig.bit:gcEnvKeyMatch",
    "root/rootconfig.bit:gcCstrEq",
    "root/rootconfig.bit:gcCstrUsize",
    "root/rootconfig.bit:gcEnvEnabled",
    "root/rootconfig.bit:gcEnvStress",
    "root/rootconfig.bit:gcEnvMinTrigger",
    "root/rootconfig.bit:gcEnvGrowthPct",
    "root/rootconfig.bit:gcEnvMarkStack",
    "root/rootconfig.bit:gcEnvVerbose",
    "root/rootconfig.bit:rootConfigureFromEnv",
    "root/rootconfig.bit:rootEnvVerbose",
    "root/rootconfig.bit:rootEnvMarkStack",
    "root/testindex.bit:testIndexParse",
    "root/testindex.bit:rtTestIndex",
    // (c) boot machinery — reaches the scheduler/thread/park layers and `main`.
    "root/darwin/boot.bit:workerBody",
    "root/darwin/boot.bit:joinWorker",
    "root/darwin/boot.bit:mainTrampoline",
    "root/darwin/boot.bit:boot",
    "root/darwin/boot.bit:machoMain",
    "root/linux/boot.bit:workerBody",
    "root/linux/boot.bit:joinWorker",
    "root/linux/boot.bit:mainTrampoline",
    "root/linux/boot.bit:boot",
    "root/linux/boot.bit:initLinuxTls",
    "root/linux/boot.bit:rtStartMain",
    // (d) clocks and sleep — scalars only, and `sleep_ns` parks.
    "root/darwin/time.bit:rtTimeMonoNs",
    "root/darwin/time.bit:rtTimeUnixNs",
    "root/darwin/time.bit:rtTimeSleepNs",
    "root/linux/time.bit:rtTimeMonoNs",
    "root/linux/time.bit:rtTimeUnixNs",
    "root/linux/time.bit:rtTimeSleepNs",
    // -----------------------------------------------------------------------
    // (e) `runtime/rand` (#1667) — one per platform, and only because `panic`
    //     is not `@nosplit`-callable. The allocate-and-fill half IS `@nosplit`
    //     (`randomBytesFill`); what is left here is straight-line with NO LOOP,
    //     and the one call it makes while `s` is set — `panic` — is on the
    //     branch where `s` is the `randEntropyFailed` sentinel rather than an
    //     object, and never returns. See `rand/*/random.bit`.
    "rand/darwin/random.bit:rtRandomBytes",
    "rand/linux/random.bit:rtRandomBytes",
    // -----------------------------------------------------------------------
    // (f) `runtime/net` (#1668) — THE PARK LAYER. Every entry from here down
    //     rests on claim (b) in this section's header: it holds no raw GC
    //     address, so a poll or a park inside it is harmless. `@nosplit` is not
    //     merely inconvenient for these, it is unavailable — E0075 is transitive
    //     and the subtree reaches `schedPark`. Each was confirmed refused by the
    //     compiler rather than assumed: marking them yields
    //     "calls 'netAwaitReady', which is not marked nosplit" (the engine),
    //     "calls 'fsOpen'" (`readResolvConf`) or "may not allocate" (the four
    //     wrappers that own a managed scratch).
    //
    //     (f1) The socket engine. Buffers arrive as `*u8` PARAMETERS pointing
    //     into memory the caller owns and keeps alive; these frames hold no
    //     object address of their own. `netAwaitReady` is the parker itself.
    "net/darwin/sock.bit:netAwaitReady",
    "net/linux/sock.bit:netAwaitReady",
    "net/darwin/tcp.bit:netAcceptTcp",
    "net/darwin/tcp.bit:netDialTcp",
    "net/darwin/tcp.bit:netReadSock",
    "net/darwin/tcp.bit:netWriteSock",
    "net/linux/tcp.bit:netAcceptTcp",
    "net/linux/tcp.bit:netDialTcp",
    "net/linux/tcp.bit:netReadSock",
    "net/linux/tcp.bit:netWriteSock",
    "net/darwin/udp.bit:netRecvFrom",
    "net/darwin/udp.bit:netSendTo",
    "net/linux/udp.bit:netRecvFrom",
    "net/linux/udp.bit:netSendTo",
    //     (f2) `readResolvConf` — reads into the caller's managed `[]i64`
    //     scratch through a `*u8`; owns no object. Refused `@nosplit` because
    //     `fsOpen`/`fsClose` are RtFn builtins.
    "net/darwin/netabi.bit:readResolvConf",
    "net/linux/netabi.bit:readResolvConf",
    //     (f3) The ABI wrappers that pass a caller's `string` STRAIGHT THROUGH
    //     to the parking engine as `strData(s)`. `s` is a raw `int` here, but
    //     the object is rooted by the compiled Bit caller's own stack-map slot —
    //     the runtime never allocated it, so unlike #1656's `rtFsReadAll` there
    //     IS a frame that names it, and the precise walk covers every frame of
    //     the running task.
    "net/darwin/netabi.bit:netAbiAccept",
    "net/darwin/netabi.bit:netAbiDial",
    "net/darwin/netabi.bit:netAbiUdpSend",
    "net/darwin/netabi.bit:netAbiWrite",
    "net/linux/netabi.bit:netAbiAccept",
    "net/linux/netabi.bit:netAbiDial",
    "net/linux/netabi.bit:netAbiUdpSend",
    "net/linux/netabi.bit:netAbiWrite",
    //     (f4) The four wrappers that ALLOCATE a receive buffer — this ticket's
    //     actual defect, and now the reason they cannot be `@nosplit`: their
    //     buffers are MANAGED `[]i64` locals and `@nosplit` forbids allocation
    //     outright. That is the fix, not a workaround; a managed local is a
    //     stack-map slot, which is precisely what the raw `rtStrAlloc` address
    //     they used to hold was not.
    "net/darwin/netabi.bit:netAbiRead",
    "net/darwin/netabi.bit:netAbiUdpRecv",
    "net/darwin/netabi.bit:netAbiUdpSenderHost",
    "net/darwin/netabi.bit:netAbiResolve",
    "net/linux/netabi.bit:netAbiRead",
    "net/linux/netabi.bit:netAbiUdpRecv",
    "net/linux/netabi.bit:netAbiUdpSenderHost",
    "net/linux/netabi.bit:netAbiResolve",
};

test "every function in the covered runtime subtrees is poll-free, or a reviewed exception" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const gpa = arena_state.allocator();

    var allowed = std.StringHashMap(void).init(gpa);
    for (poll_free_exceptions) |e| try allowed.put(e, {});

    const io = Io.Threaded.global_single_threaded.io();
    var failures: usize = 0;
    var vacuous: usize = 0;

    for (poll_free_roots) |root| {
        const sub = root.sub;
        var scanned: usize = 0;
        const abs = try std.fs.path.join(gpa, &.{ build_options.repo_root, "runtime", sub });
        var dir = try Dir.cwd().openDir(io, abs, .{ .iterate = true });
        defer dir.close(io);

        var walker = try dir.walk(gpa);
        defer walker.deinit();

        var files: usize = 0;
        while (try walker.next(io)) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.basename, ".bit")) continue;
            files += 1;
            if (files > max_bit_files) return error.TooManyRuntimeFiles;

            const source = try entry.dir.readFileAlloc(io, entry.basename, gpa, .limited(max_source_bytes));
            // The exception-list key: the path under `runtime/`, so an entry
            // names one function in one file and cannot be satisfied by a
            // same-named function elsewhere.
            const key_dir = try std.fs.path.join(gpa, &.{ sub, entry.path });
            const rel = try std.fs.path.join(gpa, &.{ "runtime", key_dir });
            try checkPollFreeInFile(gpa, &allowed, key_dir, rel, source, &scanned, &failures);
        }

        // PER-SUBTREE, inside the loop: a total checked afterwards would let one
        // subtree read zero while another's growth covers for it.
        if (scanned < root.min_scanned) {
            std.debug.print(
                "rootabi: the poll-free gate examined only {d} function declarations " ++
                    "under runtime/{s} (expected at least {d}). It is reading nothing " ++
                    "useful there — a directory moved, or the Bit parser rejected the " ++
                    "sources.\n",
                .{ scanned, sub, root.min_scanned },
            );
            vacuous += 1;
        }
    }

    if (vacuous != 0) {
        return error.VacuousPollFreeScan;
    }

    if (failures != 0) {
        std.debug.print(
            "rootabi: {d} function(s) under the covered runtime subtrees are neither " ++
                "`@nosplit`/`@naked` " ++
                "nor on the reviewed exception list. See this file's #1658 header: such a " ++
                "function takes a back-edge safepoint while holding GC objects as raw " ++
                "`int` addresses no stack map names, and the collector sweeps them under " ++
                "a live reference (#1656).\n",
            .{failures},
        );
        return error.RuntimeFunctionNotPollFree;
    }
}

fn checkPollFreeInFile(
    gpa: std.mem.Allocator,
    allowed: *const std.StringHashMap(void),
    key_dir: []const u8,
    rel: []const u8,
    source: []const u8,
    scanned: *usize,
    failures: *usize,
) !void {
    const d = bit.diagnostics;
    var sm = d.SourceManager.init(gpa);
    defer sm.deinit();
    const file = try sm.addFile(rel, source);

    var diags = d.Diagnostics.init(gpa, &sm);
    defer diags.deinit();

    var tree = try bit.ast.Tree.init(gpa);
    defer tree.deinit();
    try bit.parser.parse(gpa, &tree, &diags, file, source);
    if (diags.hasErrors()) {
        std.debug.print("rootabi: '{s}' does not parse as Bit.\n", .{rel});
        return error.BitParseFailed;
    }

    // `func_decl` kids: [recv, name, generics, params, result, body, attrs].
    const kid_name = 1;
    const kid_attrs = 6;

    for (tree.kids(tree.root)) |top| {
        const decl = if (tree.get(top).tag == .@"export") blk: {
            const wrapped = tree.kids(top);
            if (wrapped.len != 1) continue;
            break :blk wrapped[0];
        } else top;
        if (tree.get(decl).tag != .func_decl) continue;
        const kids = tree.kids(decl);
        if (kids.len <= kid_name) continue;

        scanned.* += 1;
        // A declaration with NO attributes at all has no `attrs` kid, and those
        // are exactly the ones this gate exists to catch — so a short kid list
        // means "not poll-free", never "skip". Treating it as `continue` (which
        // is what `collectBitPins` above may do, harmlessly, since every pin
        // carries `@symbol`) made the first cut of this gate examine 223 of 265
        // declarations and miss all 42 unannotated ones.
        const attrs = if (kids.len > kid_attrs) kids[kid_attrs] else bit.ast.none;
        if (hasBareAttr(&tree, source, attrs, "nosplit")) continue;
        if (hasBareAttr(&tree, source, attrs, "naked")) continue;

        const name = nodeText(&tree, source, kids[kid_name]);
        const key = try std.mem.concat(gpa, u8, &.{ key_dir, ":", name });
        if (allowed.contains(key)) continue;

        std.debug.print(
            "rootabi: {s}: '{s}' is not `@nosplit` and is not a reviewed exception. " ++
                "Add `@nosplit` (E0075 will report any callee that also needs it), " ++
                "restructure so no raw GC address spans a poll, or justify an entry " ++
                "`\"{s}\"` in `poll_free_exceptions`.\n",
            .{ rel, name, key },
        );
        failures.* += 1;
    }
}

/// True when `attrs` carries the argument-less attribute `@<want>`. `@symbol`
/// takes a string argument and so has two kids; `@nosplit`/`@naked` have one.
fn hasBareAttr(
    tree: *const bit.ast.Tree,
    source: []const u8,
    attrs: bit.ast.Index,
    want: []const u8,
) bool {
    if (attrs == bit.ast.none) return false;
    for (tree.kids(attrs)) |a| {
        if (tree.get(a).tag != .attr) continue;
        const ak = tree.kids(a);
        if (ak.len < 1) continue;
        if (std.mem.eql(u8, nodeText(tree, source, ak[0]), want)) return true;
    }
    return false;
}
