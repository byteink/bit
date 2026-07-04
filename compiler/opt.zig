//! Optimizer passes (task #338): constant folding + propagation, dead code
//! elimination, and simple size-budgeted inlining over the SSA IR built by
//! `lower.zig`, run immediately before codegen.
//!
//! ponytail: three classic passes only, add escape analysis/stack-alloc when
//! GC pressure shows in benchmarks.
//!
//! ## Rebuild, don't mutate
//!
//! `ir.Function`'s core invariant — instruction index == `ValueId`, and each
//! block's instructions are contiguous in emission order — makes deleting an
//! instruction in place illegal: it would shift every later index, silently
//! corrupting every operand reference that follows. Every pass here instead
//! *rebuilds* the function through `ir.FunctionBuilder`, walking the old
//! function once in (already def-before-use) order and translating each
//! surviving value through an old-index -> new-`ValueId` remap table. That's
//! exactly the construction `lower.zig` itself uses, so every rebuilt
//! function inherits the builder's own contiguity/terminator asserts for
//! free, and `ir.verifyFunction` re-checks the result after each pass in
//! debug builds (this module's own correctness net, per the task's Scope).
//!
//! ## Passes
//!
//! - `foldConstantsAndPrune`: a single forward sweep computes, per value,
//!   whether it is a compile-time constant (propagating through folded
//!   arithmetic/compares); a second sweep (bounded BFS over blocks) uses
//!   constant branch conditions to find which blocks are actually
//!   reachable, then the rebuild only reserves reachable blocks and turns
//!   any now-resolved `br` into a plain `jump` — constant folding, constant
//!   propagation, and dead-branch/dead-block pruning all fall out of the one
//!   rebuild pass.
//! - `deadCodeElim`: one backward liveness sweep (roots = side-effecting
//!   instructions, terminators, and block params) marks every operand of a
//!   live instruction live in turn; safe as a single O(n) backward pass
//!   because this IR's flat instruction order already satisfies
//!   def-index < use-index globally, not just per block. The rebuild then
//!   drops every pure instruction that stayed unmarked.
//! - `inlineCalls`: splices a callee's body at its call site when the callee
//!   is a single straight-line block (no branches) under a small
//!   instruction budget and not directly self-recursive — no CFG surgery
//!   needed, since a single-block, single-`ret` callee's body is just more
//!   straight-line code for the caller's already-open block.
//!
//! Every pass is one bounded, non-recursive walk over already-known-size
//! arrays (function instruction/block counts) — no pass loops to a
//! fixpoint. `-O1` chains a fixed 5-step pipeline (fold, DCE, inline, fold,
//! DCE) so a constant-argument call collapses after inlining exposes it,
//! without ever looping until nothing changes.

const std = @import("std");
const builtin = @import("builtin");
const ir = @import("ir.zig");
const check = @import("check.zig");

const Allocator = std.mem.Allocator;
const TypeId = check.TypeId;

// ============================================================================
// Compile-time constant values and folding
// ============================================================================

/// A value known at compile time. `int` holds the raw 64-bit pattern exactly
/// as `ir.Decoded.const_int` stores it — width and signedness come from the
/// value's own `TypeId`, not from this union, matching the IR's own
/// "store bits, reinterpret per type" convention.
const ConstVal = union(enum) {
    int: u64,
    float: f64,
    boolean: bool,
};

fn primOf(ctx: *const check.TypeContext, ty: TypeId) ?check.Prim {
    return switch (ctx.typeOf(ty)) {
        .prim => |p| p,
        else => null,
    };
}

fn widthOf(p: check.Prim) u8 {
    return switch (p) {
        .i8, .u8 => 8,
        .i16, .u16 => 16,
        .i32, .u32 => 32,
        .i64, .u64 => 64,
        else => unreachable, // callers only reach here after isIntPrim
    };
}

fn isSignedPrim(p: check.Prim) bool {
    return switch (p) {
        .i8, .i16, .i32, .i64 => true,
        else => false,
    };
}

fn isIntPrim(p: check.Prim) bool {
    return switch (p) {
        .i8, .i16, .i32, .i64, .u8, .u16, .u32, .u64 => true,
        else => false,
    };
}

fn isFloatPrim(p: check.Prim) bool {
    return p == .f32 or p == .f64;
}

/// Keeps only the low `bits` bits of `raw`, zeroing the rest — the IR's
/// canonical unsigned storage form for a `bits`-wide value.
fn maskTo(raw: u64, bits: u8) u64 {
    if (bits >= 64) return raw;
    const m: u64 = (@as(u64, 1) << @intCast(bits)) - 1;
    return raw & m;
}

/// Reinterprets `raw`'s low `bits` bits as a signed, sign-extended `i64`.
fn signExtend(raw: u64, bits: u8) i64 {
    if (bits >= 64) return @bitCast(raw);
    const shift: u6 = @intCast(64 - bits);
    return @as(i64, @bitCast(raw << shift)) >> shift;
}

/// Folds `add`/`sub`/`mul`. Unsigned always wraps modularly (§13.5: no trap
/// possible). Signed only folds when the exact result fits the type's
/// range — an out-of-range result is left as a runtime op so it keeps
/// trapping in debug / wrapping in release exactly as before, per §13.5's
/// build-mode-dependent overflow semantics (constant folding never changes
/// observable behavior).
fn foldAddSubMul(op: ir.Op, bits: u8, signed: bool, a_raw: u64, b_raw: u64) ?ConstVal {
    const a: i128 = if (signed) signExtend(a_raw, bits) else maskTo(a_raw, bits);
    const b: i128 = if (signed) signExtend(b_raw, bits) else maskTo(b_raw, bits);
    const wide: i128 = switch (op) {
        .add => a + b,
        .sub => a - b,
        .mul => a * b,
        else => unreachable,
    };
    if (signed) {
        const min: i128 = -(@as(i128, 1) << @intCast(bits - 1));
        const max: i128 = (@as(i128, 1) << @intCast(bits - 1)) - 1;
        if (wide < min or wide > max) return null;
        return .{ .int = maskTo(@bitCast(@as(i64, @intCast(wide))), bits) };
    }
    const modulus: i128 = @as(i128, 1) << @intCast(bits);
    var m = @mod(wide, modulus);
    if (m < 0) m += modulus;
    return .{ .int = @intCast(m) };
}

/// Folds `sdiv`/`srem`. Divide-by-zero and `MIN / -1` (the one signed
/// division that overflows) both always panic (§13.5) — left unfolded so
/// the trap still happens at runtime.
fn foldSignedDivRem(op: ir.Op, bits: u8, a_raw: u64, b_raw: u64) ?ConstVal {
    const a = signExtend(a_raw, bits);
    const b = signExtend(b_raw, bits);
    if (b == 0) return null;
    const min_val: i64 = -(@as(i64, 1) << @intCast(bits - 1));
    if (op == .sdiv and a == min_val and b == -1) return null;
    const result = switch (op) {
        .sdiv => @divTrunc(a, b),
        .srem => @rem(a, b),
        else => unreachable,
    };
    return .{ .int = maskTo(@bitCast(result), bits) };
}

/// Folds `udiv`/`urem`. Divide-by-zero always panics (§13.5) — left
/// unfolded; every other unsigned division is total, no trap possible.
fn foldUnsignedDivRem(op: ir.Op, bits: u8, a_raw: u64, b_raw: u64) ?ConstVal {
    const a = maskTo(a_raw, bits);
    const b = maskTo(b_raw, bits);
    if (b == 0) return null;
    return .{ .int = switch (op) {
        .udiv => a / b,
        .urem => a % b,
        else => unreachable,
    } };
}

/// Folds `shl`/`lshr`/`ashr`. Always total: §13.5 defines the shift count as
/// taken modulo the operand bit width, so no trap is ever possible here.
fn foldShift(op: ir.Op, bits: u8, a_raw: u64, b_raw: u64) ?ConstVal {
    const shift: u6 = @intCast(@mod(b_raw, bits));
    const a = maskTo(a_raw, bits);
    return .{ .int = switch (op) {
        .shl => maskTo(a << shift, bits),
        .lshr => a >> shift,
        .ashr => maskTo(@bitCast(signExtend(a_raw, bits) >> shift), bits),
        else => unreachable,
    } };
}

fn foldBinaryArith(ctx: *const check.TypeContext, op: ir.Op, ty: TypeId, lhs: ConstVal, rhs: ConstVal) ?ConstVal {
    const p = primOf(ctx, ty) orelse return null;
    if (isFloatPrim(p)) {
        return .{ .float = switch (op) {
            .fadd => lhs.float + rhs.float,
            .fsub => lhs.float - rhs.float,
            .fmul => lhs.float * rhs.float,
            .fdiv => lhs.float / rhs.float,
            else => return null,
        } };
    }
    if (!isIntPrim(p)) return null;
    const bits = widthOf(p);
    const signed = isSignedPrim(p);
    return switch (op) {
        .add, .sub, .mul => foldAddSubMul(op, bits, signed, lhs.int, rhs.int),
        .sdiv, .srem => if (signed) foldSignedDivRem(op, bits, lhs.int, rhs.int) else null,
        .udiv, .urem => if (!signed) foldUnsignedDivRem(op, bits, lhs.int, rhs.int) else null,
        .band, .bor, .bxor => blk: {
            const a = maskTo(lhs.int, bits);
            const b = maskTo(rhs.int, bits);
            break :blk .{ .int = maskTo(switch (op) {
                .band => a & b,
                .bor => a | b,
                .bxor => a ^ b,
                else => unreachable,
            }, bits) };
        },
        .shl, .lshr, .ashr => foldShift(op, bits, lhs.int, rhs.int),
        else => null,
    };
}

fn foldCompare(ctx: *const check.TypeContext, op: ir.Op, operand_ty: TypeId, lhs: ConstVal, rhs: ConstVal) ?ConstVal {
    const p = primOf(ctx, operand_ty) orelse return null;
    if (p == .bool) {
        return .{ .boolean = switch (op) {
            .icmp_eq => lhs.boolean == rhs.boolean,
            .icmp_ne => lhs.boolean != rhs.boolean,
            else => return null,
        } };
    }
    if (isFloatPrim(p)) {
        return .{ .boolean = switch (op) {
            .fcmp_eq => lhs.float == rhs.float,
            .fcmp_ne => lhs.float != rhs.float,
            .fcmp_lt => lhs.float < rhs.float,
            .fcmp_le => lhs.float <= rhs.float,
            .fcmp_gt => lhs.float > rhs.float,
            .fcmp_ge => lhs.float >= rhs.float,
            else => return null,
        } };
    }
    if (!isIntPrim(p)) return null;
    const bits = widthOf(p);
    if (isSignedPrim(p)) {
        const a = signExtend(lhs.int, bits);
        const b = signExtend(rhs.int, bits);
        return .{ .boolean = switch (op) {
            .icmp_eq => a == b,
            .icmp_ne => a != b,
            .icmp_slt => a < b,
            .icmp_sle => a <= b,
            .icmp_sgt => a > b,
            .icmp_sge => a >= b,
            else => return null,
        } };
    }
    const a = maskTo(lhs.int, bits);
    const b = maskTo(rhs.int, bits);
    return .{ .boolean = switch (op) {
        .icmp_eq => a == b,
        .icmp_ne => a != b,
        .icmp_ult => a < b,
        .icmp_ule => a <= b,
        .icmp_ugt => a > b,
        .icmp_uge => a >= b,
        else => return null,
    } };
}

fn foldUnary(ctx: *const check.TypeContext, op: ir.Op, ty: TypeId, v: ConstVal) ?ConstVal {
    const p = primOf(ctx, ty) orelse return null;
    return switch (op) {
        .fneg => .{ .float = -v.float },
        .bnot => blk: {
            if (!isIntPrim(p)) break :blk null;
            const bits = widthOf(p);
            break :blk .{ .int = maskTo(~maskTo(v.int, bits), bits) };
        },
        .neg => blk: {
            if (!isIntPrim(p)) break :blk null;
            const bits = widthOf(p);
            if (isSignedPrim(p)) {
                const a = signExtend(v.int, bits);
                const min_val: i64 = -(@as(i64, 1) << @intCast(bits - 1));
                if (a == min_val) break :blk null; // negating MIN overflows: preserve the trap
                break :blk .{ .int = maskTo(@bitCast(-a), bits) };
            }
            break :blk .{ .int = maskTo(0 -% maskTo(v.int, bits), bits) };
        },
        else => null,
    };
}

/// Single forward sweep over every instruction: records the compile-time
/// value of every constant literal, then folds each binary/unary op whose
/// operands are both already known — cascading propagation for free, since
/// this IR's flat order already guarantees an operand's def index is always
/// less than its use's (see module doc comment).
fn analyzeConsts(gpa: Allocator, ctx: *const check.TypeContext, f: *const ir.Function) Allocator.Error![]?ConstVal {
    const known = try gpa.alloc(?ConstVal, f.insts.len);
    @memset(known, null);
    var i: u32 = 0;
    while (i < f.insts.len) : (i += 1) {
        const op = f.insts.items(.op)[i];
        const ty = f.insts.items(.ty)[i];
        const d = f.decode(@enumFromInt(i));
        known[i] = switch (d) {
            .const_int => |v| ConstVal{ .int = @bitCast(v) },
            .const_float => |v| ConstVal{ .float = v },
            .const_bool => |v| ConstVal{ .boolean = v },
            .bin => |b| blk: {
                const lv = known[@intFromEnum(b.lhs)] orelse break :blk null;
                const rv = known[@intFromEnum(b.rhs)] orelse break :blk null;
                break :blk if (op.isCompare())
                    foldCompare(ctx, op, f.valueType(b.lhs), lv, rv)
                else
                    foldBinaryArith(ctx, op, ty, lv, rv);
            },
            .un => |u| blk: {
                const v = known[@intFromEnum(u.operand)] orelse break :blk null;
                break :blk foldUnary(ctx, op, ty, v);
            },
            else => null,
        };
    }
    return known;
}

// ============================================================================
// Block reachability (dead-branch / dead-block pruning)
// ============================================================================

fn enqueue(reachable: []bool, queue: []u32, tail: *usize, bi: u32) void {
    if (reachable[bi]) return;
    reachable[bi] = true;
    queue[tail.*] = bi;
    tail.* += 1;
}

/// Bounded BFS from the entry block (Power of 10: the worklist is sized to
/// `blocks.len` and each block is enqueued at most once). A `br` whose
/// condition folded to a known constant only follows the taken edge — this
/// is what prunes an unreachable branch's whole block, not just its
/// instructions.
fn computeReachable(gpa: Allocator, f: *const ir.Function, known: []const ?ConstVal) Allocator.Error![]bool {
    const n = f.blocks.len;
    const reachable = try gpa.alloc(bool, n);
    @memset(reachable, false);
    const queue = try gpa.alloc(u32, n);
    defer gpa.free(queue);

    var head: usize = 0;
    var tail: usize = 0;
    const entry_bi: u32 = @intFromEnum(f.entry);
    reachable[entry_bi] = true;
    queue[tail] = entry_bi;
    tail += 1;

    while (head < tail) : (head += 1) {
        const bi = queue[head];
        const b = f.blocks[bi];
        const term_idx = b.insts_start + b.insts_len - 1;
        switch (f.decode(@enumFromInt(term_idx))) {
            .jump => |j| enqueue(reachable, queue, &tail, @intFromEnum(j.target)),
            .br => |br_| {
                if (known[@intFromEnum(br_.cond)]) |kv| {
                    const target = if (kv.boolean) br_.then_blk else br_.else_blk;
                    enqueue(reachable, queue, &tail, @intFromEnum(target));
                } else {
                    enqueue(reachable, queue, &tail, @intFromEnum(br_.then_blk));
                    enqueue(reachable, queue, &tail, @intFromEnum(br_.else_blk));
                }
            },
            else => {},
        }
    }
    return reachable;
}

// ============================================================================
// Shared rebuild core
// ============================================================================

fn tr(remap: []const ir.ValueId, old: u32) ir.ValueId {
    return remap[old];
}

fn trList(gpa: Allocator, remap: []const ir.ValueId, olds: []const u32) Allocator.Error![]ir.ValueId {
    const out = try gpa.alloc(ir.ValueId, olds.len);
    for (olds, 0..) |o, i| out[i] = remap[o];
    return out;
}

/// Emits instruction `idx` of `f` into `bldr`, translating operands through
/// `remap` (old `ValueId` -> new) and block targets through `block_map` (old
/// `BlockId` -> new). If `known[idx]` holds a compile-time value, emits the
/// equivalent constant instead of the original op (constant folding); a
/// `br` whose condition is known collapses to a `jump` on the taken edge
/// (dead-branch pruning). Shared by every pass below — DCE and inlining
/// simply pass an all-`null` `known` so this always falls through to a
/// faithful translate-and-copy.
fn emitTranslated(
    gpa: Allocator,
    bldr: *ir.FunctionBuilder,
    f: *const ir.Function,
    known: []const ?ConstVal,
    remap: []ir.ValueId,
    block_map: []const ir.BlockId,
    idx: u32,
) !void {
    const id: ir.ValueId = @enumFromInt(idx);
    const op = f.insts.items(.op)[idx];
    const ty = f.insts.items(.ty)[idx];
    const d = f.decode(id);

    if (known[idx]) |kv| {
        remap[idx] = switch (kv) {
            .int => |v| try bldr.constInt(ty, @bitCast(v)),
            .float => |v| try bldr.constFloat(ty, v),
            .boolean => |v| try bldr.constBool(ty, v),
        };
        return;
    }

    switch (d) {
        .block_param => unreachable, // callers emit params via addParam directly
        // Only reachable when `known` is the all-null array DCE/inlining pass
        // in (the fold pass always resolves these through the fast path
        // above instead, since its own `known` array records every literal).
        .const_int => |v| remap[idx] = try bldr.constInt(ty, v),
        .const_float => |v| remap[idx] = try bldr.constFloat(ty, v),
        .const_bool => |v| remap[idx] = try bldr.constBool(ty, v),
        .const_string => |pool_idx| remap[idx] = try bldr.constString(ty, pool_idx),
        .const_nil => remap[idx] = try bldr.constNil(ty),
        .bin => |b| remap[idx] = try bldr.binary(op, ty, tr(remap, @intFromEnum(b.lhs)), tr(remap, @intFromEnum(b.rhs))),
        .un => |u| remap[idx] = try bldr.unary(op, ty, tr(remap, @intFromEnum(u.operand))),
        .jump => |j| {
            const args = try trList(gpa, remap, j.args);
            defer gpa.free(args);
            try bldr.jump(block_map[@intFromEnum(j.target)], args);
        },
        .br => |b| {
            if (known[@intFromEnum(b.cond)]) |kv| {
                const taken_target = if (kv.boolean) b.then_blk else b.else_blk;
                const taken_args = if (kv.boolean) b.then_args else b.else_args;
                const args = try trList(gpa, remap, taken_args);
                defer gpa.free(args);
                try bldr.jump(block_map[@intFromEnum(taken_target)], args);
            } else {
                const then_args = try trList(gpa, remap, b.then_args);
                defer gpa.free(then_args);
                const else_args = try trList(gpa, remap, b.else_args);
                defer gpa.free(else_args);
                try bldr.br(tr(remap, @intFromEnum(b.cond)), block_map[@intFromEnum(b.then_blk)], then_args, block_map[@intFromEnum(b.else_blk)], else_args);
            }
        },
        .ret => |r| {
            const vals = try trList(gpa, remap, r.vals);
            defer gpa.free(vals);
            try bldr.ret(vals);
        },
        .unreachable_ => try bldr.unreachableInst(),
        .call => |c| {
            const args = try trList(gpa, remap, c.args);
            defer gpa.free(args);
            remap[idx] = try bldr.call(ty, c.func, args);
        },
        .call_value => |c| {
            const args = try trList(gpa, remap, c.args);
            defer gpa.free(args);
            remap[idx] = try bldr.callValue(ty, tr(remap, @intFromEnum(c.callee)), args);
        },
        .call_iface => |c| {
            const args = try trList(gpa, remap, c.args);
            defer gpa.free(args);
            remap[idx] = try bldr.callIface(ty, tr(remap, @intFromEnum(c.iface)), c.method_index, args);
        },
        .gc_alloc => |g| remap[idx] = try bldr.gcAlloc(ty, g.size, g.ptr_offsets),
        .field_get => |fg| remap[idx] = try bldr.fieldGet(ty, tr(remap, @intFromEnum(fg.base)), fg.offset),
        .field_set => |fs| try bldr.fieldSet(tr(remap, @intFromEnum(fs.base)), fs.offset, tr(remap, @intFromEnum(fs.value))),
        .index_get => |ig| remap[idx] = try bldr.indexGet(ty, tr(remap, @intFromEnum(ig.base)), tr(remap, @intFromEnum(ig.index))),
        .index_set => |is_| try bldr.indexSet(tr(remap, @intFromEnum(is_.base)), tr(remap, @intFromEnum(is_.index)), tr(remap, @intFromEnum(is_.value))),
        .slice_len => |sl| remap[idx] = try bldr.sliceLen(ty, tr(remap, @intFromEnum(sl.base))),
        .make_closure => |mc| remap[idx] = try bldr.makeClosure(ty, mc.func, tr(remap, @intFromEnum(mc.env))),
        .rt_call => |rc| {
            const args = try trList(gpa, remap, rc.args);
            defer gpa.free(args);
            remap[idx] = try bldr.rtCall(ty, rc.rt, args);
        },
    }
}

/// Rebuilds `f`, keeping only blocks marked in `block_reachable` and, within
/// each kept block, only instructions marked in `inst_keep` (block params
/// and terminators are always emitted regardless — see the per-pass
/// wrappers below for how each flag array is derived).
fn rebuild(gpa: Allocator, f: *const ir.Function, known: []const ?ConstVal, block_reachable: []const bool, inst_keep: []const bool) !ir.Function {
    const block_map = try gpa.alloc(ir.BlockId, f.blocks.len);
    defer gpa.free(block_map);
    const remap = try gpa.alloc(ir.ValueId, f.insts.len);
    defer gpa.free(remap);

    var bldr = ir.FunctionBuilder.init(gpa);
    for (block_reachable, 0..) |ok, bi| {
        if (ok) block_map[bi] = try bldr.newBlock();
    }

    for (f.blocks, 0..) |b, bi| {
        if (!block_reachable[bi]) continue;
        bldr.beginBlock(block_map[bi]);
        var idx = b.insts_start;
        const params_end = b.insts_start + b.param_count;
        while (idx < params_end) : (idx += 1) {
            remap[idx] = try bldr.addParam(f.valueType(@enumFromInt(idx)));
        }
        const end = b.insts_start + b.insts_len;
        while (idx < end) : (idx += 1) {
            if (!inst_keep[idx]) continue;
            try emitTranslated(gpa, &bldr, f, known, remap, block_map, idx);
        }
        bldr.endBlock();
    }
    return bldr.finish(f.name, f.param_types, f.result, f.is_fallible, f.err_ty, block_map[@intFromEnum(f.entry)]);
}

// ============================================================================
// Pass 1: constant folding + propagation, dead-branch/dead-block pruning
// ============================================================================

fn foldConstantsAndPrune(gpa: Allocator, ctx: *const check.TypeContext, f: *const ir.Function) !ir.Function {
    const known = try analyzeConsts(gpa, ctx, f);
    defer gpa.free(known);
    const reachable = try computeReachable(gpa, f, known);
    defer gpa.free(reachable);
    const keep_all = try gpa.alloc(bool, f.insts.len);
    defer gpa.free(keep_all);
    @memset(keep_all, true);
    return rebuild(gpa, f, known, reachable, keep_all);
}

// ============================================================================
// Pass 2: dead code elimination
// ============================================================================

/// Instructions whose effect is more than "produce this value" — always
/// kept regardless of use count. Allocation and closure creation are kept
/// conservatively (no escape analysis yet, see module doc comment).
fn isSideEffecting(op: ir.Op) bool {
    return switch (op) {
        .call, .call_value, .call_iface, .rt_call, .field_set, .index_set, .gc_alloc, .make_closure => true,
        else => op.isTerminator(),
    };
}

fn markOperandsLive(f: *const ir.Function, live: []bool, id: ir.ValueId) void {
    switch (f.decode(id)) {
        .block_param, .const_int, .const_float, .const_bool, .const_string, .const_nil, .unreachable_, .gc_alloc => {},
        .bin => |b| {
            live[@intFromEnum(b.lhs)] = true;
            live[@intFromEnum(b.rhs)] = true;
        },
        .un => |u| live[@intFromEnum(u.operand)] = true,
        .jump => |j| for (j.args) |a| {
            live[a] = true;
        },
        .br => |b| {
            live[@intFromEnum(b.cond)] = true;
            for (b.then_args) |a| live[a] = true;
            for (b.else_args) |a| live[a] = true;
        },
        .ret => |r| for (r.vals) |v| {
            live[v] = true;
        },
        .call => |c| for (c.args) |a| {
            live[a] = true;
        },
        .call_value => |c| {
            live[@intFromEnum(c.callee)] = true;
            for (c.args) |a| live[a] = true;
        },
        .call_iface => |c| {
            live[@intFromEnum(c.iface)] = true;
            for (c.args) |a| live[a] = true;
        },
        .field_get => |fg| live[@intFromEnum(fg.base)] = true,
        .field_set => |fs| {
            live[@intFromEnum(fs.base)] = true;
            live[@intFromEnum(fs.value)] = true;
        },
        .index_get => |ig| {
            live[@intFromEnum(ig.base)] = true;
            live[@intFromEnum(ig.index)] = true;
        },
        .index_set => |is_| {
            live[@intFromEnum(is_.base)] = true;
            live[@intFromEnum(is_.index)] = true;
            live[@intFromEnum(is_.value)] = true;
        },
        .slice_len => |sl| live[@intFromEnum(sl.base)] = true,
        .make_closure => |mc| live[@intFromEnum(mc.env)] = true,
        .rt_call => |rc| for (rc.args) |a| {
            live[a] = true;
        },
    }
}

/// One backward sweep marks every value transitively reachable from a root
/// (side-effecting instruction, terminator, or block param) live. Correct in
/// a single O(n) pass, descending order, because every operand's def index
/// is always less than the current index (see module doc comment) — by the
/// time the sweep reaches a definition, every later instruction that could
/// mark it live has already run.
fn computeLive(gpa: Allocator, f: *const ir.Function) Allocator.Error![]bool {
    const n = f.insts.len;
    const live = try gpa.alloc(bool, n);
    @memset(live, false);
    var i: u32 = @intCast(n);
    while (i > 0) {
        i -= 1;
        const op = f.insts.items(.op)[i];
        if (op == .block_param) {
            live[i] = true;
            continue;
        }
        if (!live[i] and !isSideEffecting(op)) continue;
        live[i] = true;
        markOperandsLive(f, live, @enumFromInt(i));
    }
    return live;
}

fn deadCodeElim(gpa: Allocator, f: *const ir.Function) !ir.Function {
    const live = try computeLive(gpa, f);
    defer gpa.free(live);
    const no_fold = try gpa.alloc(?ConstVal, f.insts.len);
    defer gpa.free(no_fold);
    @memset(no_fold, null);
    const reach_all = try gpa.alloc(bool, f.blocks.len);
    defer gpa.free(reach_all);
    @memset(reach_all, true);
    return rebuild(gpa, f, no_fold, reach_all, live);
}

// ============================================================================
// Pass 3: simple size-budgeted inlining
// ============================================================================

/// ponytail: size-budget heuristic — small leaf helpers only; retune once a
/// real corpus shows the right number.
const max_inline_insts = 8;

/// A callee is inlinable when it is straight-line code under budget: exactly
/// one block (no branches to re-target, so splicing needs no CFG surgery),
/// terminated by a plain `ret` (not `unreachable`, so there is always a
/// value to substitute at the call site), not fallible (keeps error
/// propagation out of this pass's scope), and not the caller itself (no
/// self-recursion — this pass never re-inlines its own splice output, so an
/// unguarded self-call would still just be one level, but excluding it keeps
/// "small function inlining" from ever touching recursive functions at all).
fn inlineEligible(module: *const ir.Module, caller_id: ir.FuncId, callee_id: ir.FuncId) ?*const ir.Function {
    if (@intFromEnum(caller_id) == @intFromEnum(callee_id)) return null;
    const g = module.func(callee_id);
    if (g.blocks.len != 1) return null;
    if (g.is_fallible) return null;
    const b = g.blocks[0];
    const term_idx = b.insts_start + b.insts_len - 1;
    if (g.insts.items(.op)[term_idx] != .ret) return null;
    const body_len = b.insts_len - b.param_count - 1;
    if (body_len > max_inline_insts) return null;
    return g;
}

/// Splices `g`'s single block into `bldr`'s currently open block: `g`'s
/// params bind directly to the (already-translated) call `args`, its body
/// is emitted in place via the shared `emitTranslated` (no folding, no
/// block retargeting — `g` has exactly one block and its only terminator is
/// the `ret` this function excludes from the splice and reads separately).
fn spliceCallee(gpa: Allocator, bldr: *ir.FunctionBuilder, g: *const ir.Function, args: []const ir.ValueId) !ir.ValueId {
    const b = g.blocks[0];
    const remap = try gpa.alloc(ir.ValueId, g.insts.len);
    defer gpa.free(remap);
    const no_fold = try gpa.alloc(?ConstVal, g.insts.len);
    defer gpa.free(no_fold);
    @memset(no_fold, null);
    // Never dereferenced: `inlineEligible` guarantees `g`'s only terminator
    // (excluded below) is a `ret`, so no jump/br inside the spliced range
    // can index this.
    const dummy_block_map = [_]ir.BlockId{g.entry};

    var idx = b.insts_start;
    const params_end = b.insts_start + b.param_count;
    var p: usize = 0;
    while (idx < params_end) : (idx += 1) {
        remap[idx] = args[p];
        p += 1;
    }
    const last = b.insts_start + b.insts_len - 1;
    while (idx < last) : (idx += 1) {
        try emitTranslated(gpa, bldr, g, no_fold, remap, &dummy_block_map, idx);
    }
    const ret = g.decode(@enumFromInt(last)).ret;
    if (ret.vals.len == 0) return @enumFromInt(0); // void callee: result is never a usable value, never read
    return remap[ret.vals[0]];
}

fn inlineCalls(gpa: Allocator, module: *const ir.Module, fid: ir.FuncId) !ir.Function {
    const f = module.func(fid);
    const block_map = try gpa.alloc(ir.BlockId, f.blocks.len);
    defer gpa.free(block_map);
    const remap = try gpa.alloc(ir.ValueId, f.insts.len);
    defer gpa.free(remap);
    const no_fold = try gpa.alloc(?ConstVal, f.insts.len);
    defer gpa.free(no_fold);
    @memset(no_fold, null);

    var bldr = ir.FunctionBuilder.init(gpa);
    for (0..f.blocks.len) |bi| block_map[bi] = try bldr.newBlock();

    for (f.blocks, 0..) |b, bi| {
        bldr.beginBlock(block_map[bi]);
        var idx = b.insts_start;
        const params_end = b.insts_start + b.param_count;
        while (idx < params_end) : (idx += 1) {
            remap[idx] = try bldr.addParam(f.valueType(@enumFromInt(idx)));
        }
        const end = b.insts_start + b.insts_len;
        while (idx < end) : (idx += 1) {
            var handled = false;
            if (f.insts.items(.op)[idx] == .call) {
                const c = f.decode(@enumFromInt(idx)).call;
                if (inlineEligible(module, fid, c.func)) |g| {
                    const args = try trList(gpa, remap, c.args);
                    defer gpa.free(args);
                    remap[idx] = try spliceCallee(gpa, &bldr, g, args);
                    handled = true;
                }
            }
            if (!handled) try emitTranslated(gpa, &bldr, f, no_fold, remap, block_map, idx);
        }
        bldr.endBlock();
    }
    return bldr.finish(f.name, f.param_types, f.result, f.is_fallible, f.err_ty, block_map[@intFromEnum(f.entry)]);
}

// ============================================================================
// Pass manager
// ============================================================================

pub const Level = enum { o0, o1 };

fn applyPass(gpa: Allocator, module: *ir.Module, fid: ir.FuncId, new_f: ir.Function) !void {
    var nf = new_f;
    if (builtin.mode == .Debug) try ir.verifyFunction(gpa, &nf);
    const slot = &module.funcs.items[@intFromEnum(fid)];
    slot.deinit(gpa);
    slot.* = nf;
}

fn runPipeline(gpa: Allocator, module: *ir.Module, fid: ir.FuncId) !void {
    try applyPass(gpa, module, fid, try foldConstantsAndPrune(gpa, module.ctx, module.func(fid)));
    try applyPass(gpa, module, fid, try deadCodeElim(gpa, module.func(fid)));
    try applyPass(gpa, module, fid, try inlineCalls(gpa, module, fid));
    try applyPass(gpa, module, fid, try foldConstantsAndPrune(gpa, module.ctx, module.func(fid)));
    try applyPass(gpa, module, fid, try deadCodeElim(gpa, module.func(fid)));
}

/// Runs the optimizer over every function in `module`, in place. `-O0` is a
/// no-op — codegen sees exactly what `lower.zig` produced. `-O1` runs the
/// fixed, statically-bounded pipeline described in the module doc comment.
pub fn optimizeModule(gpa: Allocator, module: *ir.Module, level: Level) !void {
    if (level == .o0) return;
    var i: usize = 0;
    while (i < module.funcs.items.len) : (i += 1) {
        try runPipeline(gpa, module, @enumFromInt(i));
    }
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "fold + DCE collapses a constant expression to one instruction" {
    const gpa = testing.allocator;
    var ctx = try check.TypeContext.init(gpa);
    defer ctx.deinit();
    const i64_ty = ctx.prim_ids.get(.i64);

    var b = ir.FunctionBuilder.init(gpa);
    const entry = try b.newBlock();
    b.beginBlock(entry);
    const c2 = try b.constInt(i64_ty, 2);
    const c3 = try b.constInt(i64_ty, 3);
    const sum = try b.binary(.add, i64_ty, c2, c3);
    try b.ret(&.{sum});
    b.endBlock();
    var f = try b.finish("f", &.{}, i64_ty, false, .invalid, entry);
    defer f.deinit(gpa);

    var folded = try foldConstantsAndPrune(gpa, &ctx, &f);
    defer folded.deinit(gpa);
    var cleaned = try deadCodeElim(gpa, &folded);
    defer cleaned.deinit(gpa);
    try ir.verifyFunction(gpa, &cleaned);

    try testing.expectEqual(@as(usize, 2), cleaned.insts.len);
    try testing.expectEqual(ir.Op.const_int, cleaned.insts.items(.op)[0]);
    try testing.expectEqual(@as(i64, 5), cleaned.decode(@enumFromInt(0)).const_int);
}

test "foldConstantsAndPrune prunes the unreached branch" {
    const gpa = testing.allocator;
    var ctx = try check.TypeContext.init(gpa);
    defer ctx.deinit();
    const i64_ty = ctx.prim_ids.get(.i64);
    const bool_ty = ctx.prim_ids.get(.bool);

    var b = ir.FunctionBuilder.init(gpa);
    const entry = try b.newBlock();
    const then_blk = try b.newBlock();
    const else_blk = try b.newBlock();

    b.beginBlock(entry);
    const cond = try b.constBool(bool_ty, true);
    try b.br(cond, then_blk, &.{}, else_blk, &.{});
    b.endBlock();

    b.beginBlock(then_blk);
    const one = try b.constInt(i64_ty, 1);
    try b.ret(&.{one});
    b.endBlock();

    b.beginBlock(else_blk);
    const two = try b.constInt(i64_ty, 2);
    try b.ret(&.{two});
    b.endBlock();

    var f = try b.finish("f", &.{}, i64_ty, false, .invalid, entry);
    defer f.deinit(gpa);

    var folded = try foldConstantsAndPrune(gpa, &ctx, &f);
    defer folded.deinit(gpa);
    try ir.verifyFunction(gpa, &folded);

    try testing.expectEqual(@as(usize, 2), folded.blocks.len);
    const entry_term = folded.blocks[0].insts_start + folded.blocks[0].insts_len - 1;
    try testing.expectEqual(ir.Op.jump, folded.insts.items(.op)[entry_term]);
}

test "deadCodeElim drops an unused pure value" {
    const gpa = testing.allocator;
    var ctx = try check.TypeContext.init(gpa);
    defer ctx.deinit();
    const i64_ty = ctx.prim_ids.get(.i64);

    var b = ir.FunctionBuilder.init(gpa);
    const entry = try b.newBlock();
    b.beginBlock(entry);
    const p0 = try b.addParam(i64_ty);
    const one = try b.constInt(i64_ty, 1);
    _ = try b.binary(.add, i64_ty, p0, one); // dead: never used
    try b.ret(&.{p0});
    b.endBlock();
    var f = try b.finish("f", &.{i64_ty}, i64_ty, false, .invalid, entry);
    defer f.deinit(gpa);

    var cleaned = try deadCodeElim(gpa, &f);
    defer cleaned.deinit(gpa);
    try ir.verifyFunction(gpa, &cleaned);

    try testing.expectEqual(@as(usize, 2), cleaned.insts.len); // param + ret only
}

test "deadCodeElim keeps a side-effecting call even when its result is unused" {
    const gpa = testing.allocator;
    var ctx = try check.TypeContext.init(gpa);
    defer ctx.deinit();
    const i64_ty = ctx.prim_ids.get(.i64);
    const void_ty = ctx.void_id;

    var module = ir.Module.init(gpa, &ctx);
    defer module.deinit();

    var gb = ir.FunctionBuilder.init(gpa);
    const g_entry = try gb.newBlock();
    gb.beginBlock(g_entry);
    try gb.ret(&.{});
    gb.endBlock();
    try module.funcs.append(gpa, try gb.finish("sideeffect", &.{}, void_ty, false, .invalid, g_entry));
    const g_id: ir.FuncId = @enumFromInt(0);

    var fb = ir.FunctionBuilder.init(gpa);
    const f_entry = try fb.newBlock();
    fb.beginBlock(f_entry);
    _ = try fb.call(void_ty, g_id, &.{});
    const zero = try fb.constInt(i64_ty, 0);
    try fb.ret(&.{zero});
    fb.endBlock();
    try module.funcs.append(gpa, try fb.finish("main", &.{}, i64_ty, false, .invalid, f_entry));

    var cleaned = try deadCodeElim(gpa, module.func(@enumFromInt(1)));
    defer cleaned.deinit(gpa);
    try ir.verifyFunction(gpa, &cleaned);

    var saw_call = false;
    for (cleaned.insts.items(.op)) |op| {
        if (op == .call) saw_call = true;
    }
    try testing.expect(saw_call);
}

test "inlineCalls splices a small single-block callee" {
    const gpa = testing.allocator;
    var ctx = try check.TypeContext.init(gpa);
    defer ctx.deinit();
    const i64_ty = ctx.prim_ids.get(.i64);

    var module = ir.Module.init(gpa, &ctx);
    defer module.deinit();

    var gb = ir.FunctionBuilder.init(gpa);
    const g_entry = try gb.newBlock();
    gb.beginBlock(g_entry);
    const ga = try gb.addParam(i64_ty);
    const gbp = try gb.addParam(i64_ty);
    const gsum = try gb.binary(.add, i64_ty, ga, gbp);
    try gb.ret(&.{gsum});
    gb.endBlock();
    try module.funcs.append(gpa, try gb.finish("add", &.{ i64_ty, i64_ty }, i64_ty, false, .invalid, g_entry));
    const add_id: ir.FuncId = @enumFromInt(0);

    var fb = ir.FunctionBuilder.init(gpa);
    const f_entry = try fb.newBlock();
    fb.beginBlock(f_entry);
    const one = try fb.constInt(i64_ty, 1);
    const two = try fb.constInt(i64_ty, 2);
    const call_res = try fb.call(i64_ty, add_id, &.{ one, two });
    try fb.ret(&.{call_res});
    fb.endBlock();
    try module.funcs.append(gpa, try fb.finish("main", &.{}, i64_ty, false, .invalid, f_entry));
    const main_id: ir.FuncId = @enumFromInt(1);

    var inlined = try inlineCalls(gpa, &module, main_id);
    defer inlined.deinit(gpa);
    try ir.verifyFunction(gpa, &inlined);

    for (inlined.insts.items(.op)) |op| try testing.expect(op != .call);
}

test "inlineCalls leaves an oversized callee as a real call" {
    const gpa = testing.allocator;
    var ctx = try check.TypeContext.init(gpa);
    defer ctx.deinit();
    const i64_ty = ctx.prim_ids.get(.i64);

    var module = ir.Module.init(gpa, &ctx);
    defer module.deinit();

    var gb = ir.FunctionBuilder.init(gpa);
    const g_entry = try gb.newBlock();
    gb.beginBlock(g_entry);
    var acc = try gb.addParam(i64_ty);
    var n: usize = 0;
    while (n < max_inline_insts + 1) : (n += 1) {
        const one = try gb.constInt(i64_ty, 1);
        acc = try gb.binary(.add, i64_ty, acc, one);
    }
    try gb.ret(&.{acc});
    gb.endBlock();
    try module.funcs.append(gpa, try gb.finish("big", &.{i64_ty}, i64_ty, false, .invalid, g_entry));
    const big_id: ir.FuncId = @enumFromInt(0);

    var fb = ir.FunctionBuilder.init(gpa);
    const f_entry = try fb.newBlock();
    fb.beginBlock(f_entry);
    const zero = try fb.constInt(i64_ty, 0);
    const call_res = try fb.call(i64_ty, big_id, &.{zero});
    try fb.ret(&.{call_res});
    fb.endBlock();
    try module.funcs.append(gpa, try fb.finish("main", &.{}, i64_ty, false, .invalid, f_entry));
    const main_id: ir.FuncId = @enumFromInt(1);

    var out = try inlineCalls(gpa, &module, main_id);
    defer out.deinit(gpa);
    try ir.verifyFunction(gpa, &out);

    var saw_call = false;
    for (out.insts.items(.op)) |op| {
        if (op == .call) saw_call = true;
    }
    try testing.expect(saw_call);
}

test "optimizeModule is a no-op at O0" {
    const gpa = testing.allocator;
    var ctx = try check.TypeContext.init(gpa);
    defer ctx.deinit();
    const i64_ty = ctx.prim_ids.get(.i64);

    var module = ir.Module.init(gpa, &ctx);
    defer module.deinit();
    var b = ir.FunctionBuilder.init(gpa);
    const entry = try b.newBlock();
    b.beginBlock(entry);
    const c2 = try b.constInt(i64_ty, 2);
    const c3 = try b.constInt(i64_ty, 3);
    const sum = try b.binary(.add, i64_ty, c2, c3);
    try b.ret(&.{sum});
    b.endBlock();
    try module.funcs.append(gpa, try b.finish("f", &.{}, i64_ty, false, .invalid, entry));

    try optimizeModule(gpa, &module, .o0);
    try testing.expectEqual(@as(usize, 4), module.funcs.items[0].insts.len);
}

test "optimizeModule at O1 folds a constant expression end to end" {
    const gpa = testing.allocator;
    var ctx = try check.TypeContext.init(gpa);
    defer ctx.deinit();
    const i64_ty = ctx.prim_ids.get(.i64);

    var module = ir.Module.init(gpa, &ctx);
    defer module.deinit();
    var b = ir.FunctionBuilder.init(gpa);
    const entry = try b.newBlock();
    b.beginBlock(entry);
    const c2 = try b.constInt(i64_ty, 2);
    const c3 = try b.constInt(i64_ty, 3);
    const sum = try b.binary(.add, i64_ty, c2, c3);
    try b.ret(&.{sum});
    b.endBlock();
    try module.funcs.append(gpa, try b.finish("f", &.{}, i64_ty, false, .invalid, entry));

    try optimizeModule(gpa, &module, .o1);
    try ir.verify(gpa, &module);
    try testing.expectEqual(@as(usize, 2), module.funcs.items[0].insts.len);
}

test "optimizeModule at O1 inlines a call across the full pipeline" {
    const gpa = testing.allocator;
    var ctx = try check.TypeContext.init(gpa);
    defer ctx.deinit();
    const i64_ty = ctx.prim_ids.get(.i64);

    var module = ir.Module.init(gpa, &ctx);
    defer module.deinit();

    var gb = ir.FunctionBuilder.init(gpa);
    const g_entry = try gb.newBlock();
    gb.beginBlock(g_entry);
    const ga = try gb.addParam(i64_ty);
    const gbp = try gb.addParam(i64_ty);
    const gsum = try gb.binary(.add, i64_ty, ga, gbp);
    try gb.ret(&.{gsum});
    gb.endBlock();
    try module.funcs.append(gpa, try gb.finish("add", &.{ i64_ty, i64_ty }, i64_ty, false, .invalid, g_entry));

    var fb = ir.FunctionBuilder.init(gpa);
    const f_entry = try fb.newBlock();
    fb.beginBlock(f_entry);
    const one = try fb.constInt(i64_ty, 1);
    const two = try fb.constInt(i64_ty, 2);
    const call_res = try fb.call(i64_ty, @enumFromInt(0), &.{ one, two });
    try fb.ret(&.{call_res});
    fb.endBlock();
    try module.funcs.append(gpa, try fb.finish("main", &.{}, i64_ty, false, .invalid, f_entry));

    try optimizeModule(gpa, &module, .o1);
    try ir.verify(gpa, &module);

    // add(1, 2) inlines then collapses straight to the constant 3.
    const main_f = module.func(@enumFromInt(1));
    try testing.expectEqual(@as(usize, 2), main_f.insts.len);
    try testing.expectEqual(@as(i64, 3), main_f.decode(@enumFromInt(0)).const_int);
}

test "signed overflow is not folded (preserves the runtime trap)" {
    const gpa = testing.allocator;
    var ctx = try check.TypeContext.init(gpa);
    defer ctx.deinit();
    const i8_ty = ctx.prim_ids.get(.i8);

    var b = ir.FunctionBuilder.init(gpa);
    const entry = try b.newBlock();
    b.beginBlock(entry);
    const a = try b.constInt(i8_ty, 100);
    const c = try b.constInt(i8_ty, 100);
    const sum = try b.binary(.add, i8_ty, a, c); // 200 overflows i8
    try b.ret(&.{sum});
    b.endBlock();
    var f = try b.finish("f", &.{}, i8_ty, false, .invalid, entry);
    defer f.deinit(gpa);

    var folded = try foldConstantsAndPrune(gpa, &ctx, &f);
    defer folded.deinit(gpa);
    try ir.verifyFunction(gpa, &folded);

    var saw_add = false;
    for (folded.insts.items(.op)) |op| {
        if (op == .add) saw_add = true;
    }
    try testing.expect(saw_add);
}

test "unsigned overflow folds as modular wraparound" {
    const gpa = testing.allocator;
    var ctx = try check.TypeContext.init(gpa);
    defer ctx.deinit();
    const u8_ty = ctx.prim_ids.get(.u8);

    var b = ir.FunctionBuilder.init(gpa);
    const entry = try b.newBlock();
    b.beginBlock(entry);
    const a = try b.constInt(u8_ty, 250);
    const c = try b.constInt(u8_ty, 10);
    const sum = try b.binary(.add, u8_ty, a, c); // 260 wraps to 4 mod 256
    try b.ret(&.{sum});
    b.endBlock();
    var f = try b.finish("f", &.{}, u8_ty, false, .invalid, entry);
    defer f.deinit(gpa);

    var folded = try foldConstantsAndPrune(gpa, &ctx, &f);
    defer folded.deinit(gpa);
    var cleaned = try deadCodeElim(gpa, &folded);
    defer cleaned.deinit(gpa);
    try ir.verifyFunction(gpa, &cleaned);

    try testing.expectEqual(@as(usize, 2), cleaned.insts.len);
    try testing.expectEqual(@as(i64, 4), cleaned.decode(@enumFromInt(0)).const_int);
}

test "division by zero is not folded (preserves the runtime panic)" {
    const gpa = testing.allocator;
    var ctx = try check.TypeContext.init(gpa);
    defer ctx.deinit();
    const i64_ty = ctx.prim_ids.get(.i64);

    var b = ir.FunctionBuilder.init(gpa);
    const entry = try b.newBlock();
    b.beginBlock(entry);
    const a = try b.constInt(i64_ty, 10);
    const zero = try b.constInt(i64_ty, 0);
    const q = try b.binary(.sdiv, i64_ty, a, zero);
    try b.ret(&.{q});
    b.endBlock();
    var f = try b.finish("f", &.{}, i64_ty, false, .invalid, entry);
    defer f.deinit(gpa);

    var folded = try foldConstantsAndPrune(gpa, &ctx, &f);
    defer folded.deinit(gpa);
    try ir.verifyFunction(gpa, &folded);

    var saw_div = false;
    for (folded.insts.items(.op)) |op| {
        if (op == .sdiv) saw_div = true;
    }
    try testing.expect(saw_div);
}
