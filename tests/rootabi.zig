//! Runtime-ABI register-class gate (#1655): a ported runtime pin and the
//! `root.zig` export it replaces must pass and return their values in the same
//! REGISTER CLASS.
//!
//! ---------------------------------------------------------------------------
//! THE DEFECT THIS EXISTS TO CATCH
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
    try collectBitPins(gpa, &pins);
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

/// Reads every `@symbol("bit_rt_root_*")`-pinned function under `runtime/` with
/// the seed's own Bit parser.
fn collectBitPins(gpa: std.mem.Allocator, out: *SigMap) !void {
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
        try collectPinsInFile(gpa, out, rel, source);
    }
}

fn collectPinsInFile(
    gpa: std.mem.Allocator,
    out: *SigMap,
    rel: []const u8,
    source: []const u8,
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
        if (!std.mem.startsWith(u8, name, pin_prefix)) continue;

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
