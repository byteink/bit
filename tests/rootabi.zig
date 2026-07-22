//! Runtime-ABI gates. Three properties of the Bit runtime port that are
//! observable in the DECLARATIONS today, and only detonate later — inside G2/G3,
//! where a Bit-sourced `libbitrt.a` is linked and no differential can see them:
//!
//!   1. register-class agreement between a pin and the `root.zig` export it
//!      replaces (#1655) — the original gate, documented below;
//!   2. `runtime/root` is POLL-FREE (#1658) — no runtime ABI function may take a
//!      safepoint while it holds a GC object as a raw `int`;
//!   3. ABI MEMBERSHIP (#1662) — every `bit_rt_*` symbol any `runtime/*.zig`
//!      exports has a Bit provider, so dropping the Zig half links.
//!
//! Each has its own test and its own header block; (2) and (3) are at the bottom
//! of the file.
//!
//! ---------------------------------------------------------------------------
//! 1. REGISTER CLASS (#1655) — THE DEFECT IT EXISTS TO CATCH
//! ---------------------------------------------------------------------------
//!
//! `runtime/root.zig` declares
//!
//!     export fn bit_rt_parse_float(s: *const RtBytes) callconv(.c) f64
//!
//! and `seed/ir.zig` types the `parse_float` RtFn the same way, so every backend
//! reads the result out of the FLOAT return register (`d0`/`xmm0`). The Bit port
//! of that symbol declared
//!
//!     export @symbol("bit_rt_root_parse_float") function rtParseFloat(s: int): u64
//!
//! which returns in the INTEGER register (`x0`/`rax`). Against a Bit-sourced
//! `libbitrt.a` the caller therefore read a register the callee never wrote, and
//! EVERY FLOAT LITERAL IN EVERY PROGRAM FOLDED TO 0.0 — `sqrt(2) = 0` — while
//! integers stayed correct and every other gate stayed green.
//!
//! Nothing else in the tree can see it:
//!
//!   - it compiles and links: the two names are still distinct pre-rename, and
//!     post-rename they are one symbol with no type carried in the object;
//!   - `tests/rootpins.zig` asks a different question (does a definition reach
//!     ITSELF after the rename) and is blind to signatures — an object records
//!     symbol names and relocations, not C types;
//!   - the differential family compares dumps produced by ONE compiler against
//!     ONE runtime, so a runtime-side ABI defect cancels out of the comparison;
//!   - the golden corpus links the Zig archive, where no mismatch exists.
//!
//! It detonates only when a Bit-built archive is linked into a program that
//! calls the symbol — a configuration that does not exist on `main` until G2
//! (#1583/#1584) lands. So the property has to be gated where it IS observable
//! today: in the two declarations.
//!
//! ---------------------------------------------------------------------------
//! WHY A SOURCE READ IS THE RIGHT ORACLE HERE, GIVEN ROOTPINS ARGUES OTHERWISE
//! ---------------------------------------------------------------------------
//!
//! `tests/rootpins.zig` refuses to scan source, correctly: the question it asks
//! ("what symbol does this call land on") has no answer in the source, because
//! the call target is invented by codegen out of an `RtFn` tag. This gate's
//! question is the opposite kind. A parameter's type is *written down*, on both
//! sides, and is the whole of the input the C ABI classifies. So the source is
//! not a proxy for the answer — it is the answer.
//!
//! What that still does not license is a text scan. Both sides are read with the
//! REAL parser for their language (`std.zig.Ast`, and the seed's own
//! `bit.parser`), so neither side can drift from its grammar. And every scan is
//! bounded below by an explicit population assertion, because the failure mode
//! of a gate like this is not a wrong answer but a vacuous one — see the
//! `min_*` constants.
//!
//! ---------------------------------------------------------------------------
//! WHY CLASS, NOT TYPE EQUALITY
//! ---------------------------------------------------------------------------
//!
//! The two declarations are deliberately not identical and never will be: a
//! pinned Bit function may not name a GC-managed type (E0079), so every
//! `*const RtBytes`/`*SliceHeader` on the Zig side is a raw `int` on the Bit
//! side. That difference is sound — a pointer and an `int` are both integer
//! class, one register, same slot. Only the float/integer split changes which
//! physical register is used, so only that split is asserted.

const std = @import("std");
const bit = @import("bit");
const build_options = @import("build_options");
const testing = std.testing;
const Io = std.Io;
const Dir = std.Io.Dir;

/// Upper bound on a single source file this gate will read. `runtime/root.zig`
/// is the largest at ~60 KiB.
const max_source_bytes = 1 << 22;

/// The ABI prefix a ported runtime symbol will claim when #1369/G2 drops the
/// `_root` infix. Mirrors `tests/rootpins.zig`'s rename.
const pin_prefix = "bit_rt_root_";
const abi_prefix = "bit_rt_";

/// Lower bounds on what each half of the gate must actually find. A gate that
/// examines nothing passes, and that is the failure this family keeps hitting
/// (rootpins shipped a Darwin half that matched zero symbols for months). These
/// are floors well under today's populations (99 / 112 / 86), not targets:
/// they exist so that a parser change, a moved file or a renamed prefix turns
/// this gate RED rather than silently vacuous.
const min_zig_exports = 90;
const min_bit_pins = 100;
const min_compared = 80;

/// Upper bound on the runtime source files walked — keeps the walk provably
/// bounded (Power of 10 rule 2). An order of magnitude above today's ~130.
const max_bit_files = 1024;

/// Every floating-point type Zig can spell. Only these travel in a float
/// register at the C ABI; everything else this tree uses (integers, pointers,
/// `bool`, single-word structs by value) travels in an integer one.
fn isFloatZig(t: []const u8) bool {
    const floats = [_][]const u8{ "f16", "f32", "f64", "f80", "f128" };
    for (floats) |f| if (std.mem.eql(u8, t, f)) return true;
    return false;
}

/// Bit's floating-point types (SPEC §8.1). `f64` is the only one an ABI pin
/// uses today; `f32` is included so a future one cannot slip past.
fn isFloatBit(t: []const u8) bool {
    return std.mem.eql(u8, t, "f64") or std.mem.eql(u8, t, "f32");
}

const Sig = struct {
    /// Type expressions, in declaration order. Owned by the caller's arena.
    params: []const []const u8,
    /// The result type expression; `"void"` when the declaration names none.
    ret: []const u8,
    /// Where the declaration lives, for the failure message.
    where: []const u8,
};

const SigMap = std.StringHashMap(Sig);

test "every ported runtime pin matches its root.zig export's register classes" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const gpa = arena_state.allocator();

    var zig_sigs = SigMap.init(gpa);
    try collectZigExports(gpa, &zig_sigs);
    if (zig_sigs.count() < min_zig_exports) {
        std.debug.print(
            "rootabi: found only {d} `export fn bit_rt_*` declarations in runtime/root.zig " ++
                "(expected at least {d}). The gate is reading nothing useful — the file moved, " ++
                "the export shape changed, or std.zig.Ast rejected it.\n",
            .{ zig_sigs.count(), min_zig_exports },
        );
        return error.VacuousZigScan;
    }

    var pins = SigMap.init(gpa);
    try collectBitPins(gpa, &pins, pin_prefix);
    if (pins.count() < min_bit_pins) {
        std.debug.print(
            "rootabi: found only {d} `@symbol(\"{s}...\")` pins under runtime/ " ++
                "(expected at least {d}). The gate is reading nothing useful.\n",
            .{ pins.count(), pin_prefix, min_bit_pins },
        );
        return error.VacuousBitScan;
    }

    var compared: usize = 0;
    var failures: usize = 0;
    var it = pins.iterator();
    while (it.next()) |e| {
        const pin_name = e.key_ptr.*;
        const pin = e.value_ptr.*;
        // The name this pin becomes after G2's rename.
        const abi = try std.mem.concat(gpa, u8, &.{ abi_prefix, pin_name[pin_prefix.len..] });
        // A pin with no `root.zig` counterpart never joins the ABI (the
        // allocator's own names were never in it, ABI.md names no allocator
        // symbol) — there is no second declaration to disagree with.
        const zig = zig_sigs.get(abi) orelse continue;
        compared += 1;

        if (zig.params.len != pin.params.len) {
            std.debug.print(
                "rootabi: {s}: arity differs — root.zig takes {d} parameter(s), " ++
                    "the pin takes {d} ({s}).\n",
                .{ abi, zig.params.len, pin.params.len, pin.where },
            );
            failures += 1;
            continue;
        }

        for (zig.params, pin.params, 0..) |zt, bt, i| {
            if (isFloatZig(zt) == isFloatBit(bt)) continue;
            std.debug.print(
                "rootabi: {s}: parameter {d} crosses the register class — " ++
                    "root.zig says `{s}` ({s} register), the pin says `{s}` ({s} register). " ++
                    "The value would be passed in one and read from the other ({s}).\n",
                .{
                    abi,       i,
                    zt,        if (isFloatZig(zt)) "float" else "integer",
                    bt,        if (isFloatBit(bt)) "float" else "integer",
                    pin.where,
                },
            );
            failures += 1;
        }

        if (isFloatZig(zig.ret) != isFloatBit(pin.ret)) {
            std.debug.print(
                "rootabi: {s}: RESULT crosses the register class — root.zig returns `{s}` " ++
                    "({s} register), the pin returns `{s}` ({s} register). Against a " ++
                    "Bit-built libbitrt.a the caller reads a register the callee never " ++
                    "wrote, and the call silently yields 0 ({s}).\n",
                .{
                    abi,                                             zig.ret,
                    if (isFloatZig(zig.ret)) "float" else "integer", pin.ret,
                    if (isFloatBit(pin.ret)) "float" else "integer", pin.where,
                },
            );
            failures += 1;
        }
    }

    // A pin set and an export set that never intersect would sail through the
    // loop above with zero failures. Assert the intersection itself.
    if (compared < min_compared) {
        std.debug.print(
            "rootabi: only {d} pin/export pairs were compared (expected at least {d}). " ++
                "The two halves are no longer matching up — check the `{s}` -> `{s}` rename.\n",
            .{ compared, min_compared, pin_prefix, abi_prefix },
        );
        return error.VacuousComparison;
    }

    if (failures != 0) {
        std.debug.print("rootabi: {d} register-class mismatch(es).\n", .{failures});
        return error.AbiRegisterClassMismatch;
    }
}

/// Reads every `export fn bit_rt_*(...) callconv(.c) R` out of `runtime/root.zig`
/// with Zig's own parser.
fn collectZigExports(gpa: std.mem.Allocator, out: *SigMap) !void {
    const io = Io.Threaded.global_single_threaded.io();
    const path = try std.fs.path.join(gpa, &.{ build_options.repo_root, "runtime/root.zig" });
    const raw = try Dir.cwd().readFileAlloc(io, path, gpa, .limited(max_source_bytes));
    // `std.zig.Ast.parse` wants a sentinel-terminated source.
    const source = try gpa.allocSentinel(u8, raw.len, 0);
    @memcpy(source, raw);

    var tree = try std.zig.Ast.parse(gpa, source, .zig);
    if (tree.errors.len != 0) {
        std.debug.print("rootabi: runtime/root.zig does not parse as Zig.\n", .{});
        return error.ZigParseFailed;
    }

    for (tree.rootDecls()) |decl| {
        var buf: [1]std.zig.Ast.Node.Index = undefined;
        const proto = tree.fullFnProto(&buf, decl) orelse continue;
        // `export` is the only qualifier that puts a symbol in the ABI.
        const tok = proto.extern_export_inline_token orelse continue;
        if (tree.tokenTag(tok) != .keyword_export) continue;
        const name_tok = proto.name_token orelse continue;
        const name = tree.tokenSlice(name_tok);
        if (!std.mem.startsWith(u8, name, abi_prefix)) continue;

        var params: std.ArrayList([]const u8) = .empty;
        for (proto.ast.params) |p| try params.append(gpa, tree.getNodeSource(p));

        const ret = if (proto.ast.return_type.unwrap()) |r|
            tree.getNodeSource(r)
        else
            "void";

        try out.put(name, .{
            .params = params.items,
            .ret = ret,
            .where = "runtime/root.zig",
        });
    }
}

/// Reads every `@symbol("<prefix>*")`-pinned function under `runtime/` with the
/// seed's own Bit parser. `prefix` is `pin_prefix` for the register-class gate
/// (which compares against `root.zig`'s post-rename names) and `abi_prefix` for
/// the membership gate (which wants every pin, port-internal ones included).
fn collectBitPins(gpa: std.mem.Allocator, out: *SigMap, prefix: []const u8) !void {
    const io = Io.Threaded.global_single_threaded.io();
    const root = try std.fs.path.join(gpa, &.{ build_options.repo_root, "runtime" });
    var dir = try Dir.cwd().openDir(io, root, .{ .iterate = true });
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
        const rel = try std.fs.path.join(gpa, &.{ "runtime", entry.path });
        try collectPinsInFile(gpa, out, rel, source, prefix);
    }
}

fn collectPinsInFile(
    gpa: std.mem.Allocator,
    out: *SigMap,
    rel: []const u8,
    source: []const u8,
    prefix: []const u8,
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
    const kid_params = 3;
    const kid_result = 4;
    const kid_attrs = 6;

    for (tree.kids(tree.root)) |top| {
        // Every pin is exported, and `export` is a wrapper node ([decl]) rather
        // than a flag on the declaration — so the `func_decl` is one level down.
        // Missing this is what made the first cut of this gate find 2 pins
        // instead of 112; the `min_bit_pins` floor is what surfaced it.
        const decl = if (tree.get(top).tag == .@"export") blk: {
            const wrapped = tree.kids(top);
            if (wrapped.len != 1) continue;
            break :blk wrapped[0];
        } else top;
        if (tree.get(decl).tag != .func_decl) continue;
        const kids = tree.kids(decl);
        if (kids.len <= kid_attrs) continue;

        const name = pinSymbol(&tree, source, kids[kid_attrs]) orelse continue;
        if (!std.mem.startsWith(u8, name, prefix)) continue;

        var params: std.ArrayList([]const u8) = .empty;
        if (kids[kid_params] != bit.ast.none) {
            for (tree.kids(kids[kid_params])) |p| {
                const pk = tree.kids(p);
                // `param` kids: [name_ident, type]. A parameter with no written
                // type cannot reach a pin (§11.9 requires full annotation), so
                // treat its absence as a gate failure rather than skipping it.
                if (pk.len < 2) return error.UnexpectedParamShape;
                try params.append(gpa, nodeText(&tree, source, pk[1]));
            }
        }

        const ret = if (kids[kid_result] != bit.ast.none)
            nodeText(&tree, source, kids[kid_result])
        else
            "void";

        try out.put(try gpa.dupe(u8, name), .{
            .params = params.items,
            .ret = ret,
            .where = try gpa.dupe(u8, rel),
        });
    }
}

/// The string literal of a `@symbol("...")` attribute in `attrs`, or null when
/// the declaration carries no such attribute.
fn pinSymbol(tree: *const bit.ast.Tree, source: []const u8, attrs: bit.ast.Index) ?[]const u8 {
    if (attrs == bit.ast.none) return null;
    for (tree.kids(attrs)) |a| {
        if (tree.get(a).tag != .attr) continue;
        const ak = tree.kids(a);
        // `attr` kids: [name_ident, arg_string_lit?]. `@naked`/`@nosplit` have
        // no argument.
        if (ak.len < 2) continue;
        if (!std.mem.eql(u8, nodeText(tree, source, ak[0]), "symbol")) continue;
        const lit = nodeText(tree, source, ak[1]);
        // The span covers the quotes; the symbol is what they enclose. Bit's
        // ABI symbols contain no escapes, so the slice is the name verbatim.
        if (lit.len < 2 or lit[0] != '"' or lit[lit.len - 1] != '"') return null;
        return lit[1 .. lit.len - 1];
    }
    return null;
}

fn nodeText(tree: *const bit.ast.Tree, source: []const u8, idx: bit.ast.Index) []const u8 {
    const span = tree.get(idx).span;
    return source[span.start..span.end];
}

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
// SCOPE, STATED HONESTLY. `runtime/root/**` ONLY. `runtime/rand` (#1667) and
// `runtime/net` (#1668) hold live members of this same class and are NOT covered
// here; both close by widening `poll_free_roots`. A gate that silently implied
// they were clean would be worse than no gate.

/// The subtrees this gate covers, relative to `runtime/`. Widened by #1667 and
/// #1668; see the scope note above before adding to it.
const poll_free_roots = [_][]const u8{"root"};

/// Lower bound on the declarations examined. The failure mode of a gate like
/// this is a vacuous pass, not a wrong answer: a moved directory or a parser
/// change would otherwise scan nothing and report success. Today's population
/// is 261; this floor sits under it, and is a floor rather than a target.
const min_poll_free_scanned = 240;

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
};

test "every function in runtime/root is poll-free, or a reviewed exception" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const gpa = arena_state.allocator();

    var allowed = std.StringHashMap(void).init(gpa);
    for (poll_free_exceptions) |e| try allowed.put(e, {});

    const io = Io.Threaded.global_single_threaded.io();
    var scanned: usize = 0;
    var failures: usize = 0;

    for (poll_free_roots) |sub| {
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
    }

    if (scanned < min_poll_free_scanned) {
        std.debug.print(
            "rootabi: the poll-free gate examined only {d} function declarations " ++
                "(expected at least {d}). It is reading nothing useful — a directory " ++
                "moved, or the Bit parser rejected the sources.\n",
            .{ scanned, min_poll_free_scanned },
        );
        return error.VacuousPollFreeScan;
    }

    if (failures != 0) {
        std.debug.print(
            "rootabi: {d} function(s) under runtime/root are neither `@nosplit`/`@naked` " ++
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

// ---------------------------------------------------------------------------
// 3. ABI MEMBERSHIP (#1662)
// ---------------------------------------------------------------------------
//
// G3 drops every `runtime/*.zig` from the build and assembles `libbitrt.a` from
// Bit objects alone, so any `bit_rt_*` symbol only the Zig half defines becomes
// an undefined symbol in EVERY link at that moment. #1641/#1642 added two such
// seams (`bit_rt_unmap_pages`, `bit_rt_oom`) and could only supply the Zig side;
// #1662 added the Bit providers.
//
// This check has now been got wrong TWICE BY HAND, GREEN both times with the
// hole open: the first audit read only `export fn` and missed `bit_rt_safepoint`
// (exported through `comptime { @export(...) }`), which cost a full G3 attempt;
// the second read only `runtime/root.zig` and missed `bit_rt_unmap_pages`
// (`runtime/alloc.zig`), reporting a 1-symbol gap where the real gap was 2. So
// it is gated rather than remembered, over BOTH export forms across EVERY
// `runtime/*.zig`. One-way on purpose: every Zig export needs a Bit provider,
// but a Bit pin with no Zig counterpart is fine — the port-internal
// `bit_rt_port_*` names were never in the ABI.
//
// Read with Zig's own TOKENIZER rather than by regex: `export fn NAME` and the
// `.name = "bit_rt_..."` an `@export` carries are both lexical facts, and the
// tokenizer is the thing that decides where a token ends.
//
// THE SECOND FORM IS MATCHED ON ITS `.name =` PREFIX, NOT ON THE LITERAL ALONE.
// "any `bit_rt_*` string literal is an export name" is the obvious rule and it
// is FALSE — `runtime/root.zig` also contains
// `fatal("bit_rt_string_from_float: float text exceeds buffer")` and a
// `test "bit_rt_gc_alloc: ..."` name. Both were reported as missing providers
// on the first run of this gate. A false positive here is not harmless noise:
// it is an unsatisfiable demand that would push someone to weaken the check.

/// Lower bound on the Zig exports found, against today's 103. Guards the
/// vacuous pass — a scan that finds nothing trivially satisfies a subset test.
const min_zig_abi_symbols = 90;

/// Lower bound on the Bit pins found, against today's 277.
const min_bit_abi_pins = 200;

test "every bit_rt_* symbol runtime/*.zig exports has a Bit provider" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const gpa = arena_state.allocator();
    const io = Io.Threaded.global_single_threaded.io();

    // The Bit side: every `@symbol("bit_rt_...")` under runtime/, with G2's
    // rename applied (`bit_rt_root_x` -> `bit_rt_x`), which is the name the Bit
    // definition claims once #1583 lands.
    var provided = std.StringHashMap(void).init(gpa);
    {
        var pins = SigMap.init(gpa);
        try collectBitPins(gpa, &pins, abi_prefix);
        var it = pins.keyIterator();
        while (it.next()) |k| {
            const n = k.*;
            const abi = if (std.mem.startsWith(u8, n, pin_prefix))
                try std.mem.concat(gpa, u8, &.{ abi_prefix, n[pin_prefix.len..] })
            else
                n;
            try provided.put(abi, {});
        }
    }
    if (provided.count() < min_bit_abi_pins) {
        std.debug.print(
            "rootabi: found only {d} `@symbol(\"bit_rt_*\")` pins under runtime/ " ++
                "(expected at least {d}). The membership check is reading nothing.\n",
            .{ provided.count(), min_bit_abi_pins },
        );
        return error.VacuousBitPinScan;
    }

    // The Zig side: every runtime/*.zig, both export forms.
    var exported = std.StringHashMap([]const u8).init(gpa);
    {
        const abs = try std.fs.path.join(gpa, &.{ build_options.repo_root, "runtime" });
        var dir = try Dir.cwd().openDir(io, abs, .{ .iterate = true });
        defer dir.close(io);
        var it = dir.iterate();
        while (try it.next(io)) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".zig")) continue;
            const source = try dir.readFileAlloc(io, entry.name, gpa, .limited(max_source_bytes));
            const where = try std.fmt.allocPrint(gpa, "runtime/{s}", .{entry.name});
            try collectZigAbiSymbols(gpa, source, where, &exported);
        }
    }
    if (exported.count() < min_zig_abi_symbols) {
        std.debug.print(
            "rootabi: found only {d} `bit_rt_*` exports across runtime/*.zig " ++
                "(expected at least {d}). The membership check is reading nothing — " ++
                "note it must cover BOTH `export fn` and `@export(.{{ .name = ... }})`.\n",
            .{ exported.count(), min_zig_abi_symbols },
        );
        return error.VacuousZigAbiScan;
    }

    var missing: usize = 0;
    var it = exported.iterator();
    while (it.next()) |e| {
        if (provided.contains(e.key_ptr.*)) continue;
        std.debug.print(
            "rootabi: '{s}' is exported by {s} but NO Bit pin provides it. " ++
                "G3 drops that file from the build, at which point this is an " ++
                "undefined symbol in every link. Add a provider pinned " ++
                "`bit_rt_root_{s}` (the `_root` placeholder, NOT the bare name — " ++
                "that is a DuplicateSymbol against the still-live Zig, #1624).\n",
            .{ e.key_ptr.*, e.value_ptr.*, e.key_ptr.*[abi_prefix.len..] },
        );
        missing += 1;
    }
    if (missing != 0) {
        std.debug.print("rootabi: {d} ABI symbol(s) have no Bit provider.\n", .{missing});
        return error.AbiSymbolHasNoBitProvider;
    }
}

/// Every `bit_rt_*` symbol `source` exports, by either form, into `out`
/// (symbol -> the file that exports it).
fn collectZigAbiSymbols(
    gpa: std.mem.Allocator,
    source: []const u8,
    where: []const u8,
    out: *std.StringHashMap([]const u8),
) !void {
    const src = try gpa.allocSentinel(u8, source.len, 0);
    @memcpy(src, source);

    // A three-token lookbehind, which is all either form needs: `export fn
    // NAME` and `. name = "NAME"`. `[0]` is the token immediately before the
    // current one.
    const Seen = struct { tag: std.zig.Token.Tag, text: []const u8 };
    var back = [_]Seen{.{ .tag = .invalid, .text = "" }} ** 3;

    var tz = std.zig.Tokenizer.init(src);
    var guard: usize = 0;
    while (true) {
        guard += 1;
        // Provably bounded (Power of 10 rule 2): a tokenizer emits at most one
        // token per byte plus the final `.eof`.
        if (guard > source.len + 2) return error.TokenizerDidNotTerminate;
        const tok = tz.next();
        if (tok.tag == .eof) break;

        const text = src[tok.loc.start..tok.loc.end];
        switch (tok.tag) {
            .identifier => if (back[0].tag == .keyword_fn and back[1].tag == .keyword_export) {
                if (std.mem.startsWith(u8, text, abi_prefix)) {
                    try out.put(try gpa.dupe(u8, text), where);
                }
            },
            .string_literal => {
                // `.name = "..."`: the literal's span covers the quotes, and an
                // ABI symbol name carries no escapes, so the enclosed slice is
                // the name verbatim.
                const named = back[0].tag == .equal and
                    back[1].tag == .identifier and
                    std.mem.eql(u8, back[1].text, "name") and
                    back[2].tag == .period;
                if (named and text.len >= 2 and text[0] == '"') {
                    const name = text[1 .. text.len - 1];
                    if (std.mem.startsWith(u8, name, abi_prefix)) {
                        try out.put(try gpa.dupe(u8, name), where);
                    }
                }
            },
            else => {},
        }
        back[2] = back[1];
        back[1] = back[0];
        back[0] = .{ .tag = tok.tag, .text = text };
    }
}
