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
//! Each has its own test and its own header block; (2) lives in
//! `rootabi_pollfree.zig` and (3) in `rootabi_membership.zig` (#1674 split).
//! Shared parsing helpers used by more than one gate live in
//! `rootabi_shared.zig`.
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

const shared = @import("rootabi_shared.zig");
const max_source_bytes = shared.max_source_bytes;
const pin_prefix = shared.pin_prefix;
const abi_prefix = shared.abi_prefix;
const SigMap = shared.SigMap;
const collectBitPins = shared.collectBitPins;

/// Lower bounds on what each half of the gate must actually find. A gate that
/// examines nothing passes, and that is the failure this family keeps hitting
/// (rootpins shipped a Darwin half that matched zero symbols for months). These
/// are floors well under today's populations (99 / 112 / 86), not targets:
/// they exist so that a parser change, a moved file or a renamed prefix turns
/// this gate RED rather than silently vacuous.
const min_zig_exports = 90;
const min_bit_pins = 100;
const min_compared = 80;

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

// Anchors: the poll-free and ABI-membership gates live in sibling files
// (#1674 split) and must be pulled into THIS test binary to run, following
// this repo's existing anchor idiom, documented in tests/testroots.zig
// (seed/codegen_x64_test.zig and friends) — a file zig build rootabi never
// analyzes has its test blocks silently never executed.
test {
    _ = @import("rootabi_pollfree.zig");
    _ = @import("rootabi_membership.zig");
}
