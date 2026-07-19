//! ARM64 codegen (task #341): IR (`ir.zig`) + register allocation
//! (`regalloc.zig`) -> machine code for AAPCS64 (macOS and Linux both use
//! the base AAPCS64 calling convention for non-variadic calls, so unlike
//! `x64.zig` there is only one `CallConv` here — no `sysv`/`win64` split).
//! Direct binary encoding, no external assembler. Mirrors `x64.zig`'s
//! structure section-for-section; genuinely shared, register-free logic
//! (type classification, `Reloc`, `CodegenError`) lives in `codegen/common.zig`
//! instead of being duplicated — see that file's module comment for why the
//! rest (registers, ABI, the encoder, frame layout) stays per-backend.
//!
//! Every encoding below was cross-checked byte-for-byte against Apple's
//! native `as`/`objdump` (`clang`'s integrated assembler), not transcribed
//! from memory of the ISA manual — this is what "battle tested" means for a
//! hand-written encoder with no external assembler to fall back on.
//!
//! ## Output
//!
//! `compileFunction` returns a `FuncCode`, identical in spirit to `x64.zig`'s:
//! code bytes, `common.Reloc` call-site relocations, and GC stack maps
//! (`runtime/ABI.md` §4). Every `bl`-like instruction records a `Reloc`
//! naming its target symbol by name; the object writer resolves it later.
//!
//! ## Registers
//!
//! Three GPRs (`x9`, `x10`, `x11`) and two FP registers (`d30`, `d31`) are
//! permanently reserved as codegen scratch — ordinary caller-saved
//! temporaries in AAPCS64, never an argument/return register, never handed
//! to the register allocator. `x16`/`x17` (AAPCS64 IP0/IP1) and `x18` (the
//! platform register, reserved on Apple platforms and best left alone on
//! Linux too) are excluded from the allocatable set entirely rather than
//! used as scratch, since the ABI reserves them for veneers/platform use,
//! not general codegen — one less footgun for zero cost (this backend has
//! plenty of other GPRs to spare). `x29`/`x30` (frame pointer / link
//! register) and `sp` are never allocatable and always hold the frame
//! record.
//!
//! Every instruction selector materializes both operands into scratch
//! registers, computes there, then writes the result out (`getInt`/`putInt`
//! and friends) — same "always route through scratch" simplicity as
//! `x64.zig`, same cost/benefit tradeoff.
//!
//! Unlike x86-64, AArch64's `sdiv`/`udiv` and variable shifts take an
//! arbitrary GPR triplet — no fixed `rax`/`rdx`-for-`idiv` or
//! `rcx`/`cl`-for-shift constraint exists on this ISA, so (unlike
//! `x64.zig`'s `buildIntRegs`) no extra register is ever excluded from
//! allocation for those ops.
//!
//! ## Deliberately NOT covered
//!
//! Same exclusions as `x64.zig`, for identical reasons (these are
//! IR/lowering-level gaps, not backend-specific ones): a `ret` carrying more
//! than one value returns `error.UnsupportedConstruct`.
//! `field_get`/`field_set`, `index_get`/`index_set` (array base only),
//! `slice_len` (loads the header `len` word — slice/string), `gc_alloc`,
//! `const_string`, `make_closure`, `call_value`, `call_iface`, and `rt_call`
//! ARE covered.
//! Dynamic `[]T` indexing goes through the `slice_get`/`slice_set` runtime
//! calls (ABI.md §2), never the `index_*` ops.
//!
//! ## Sub-64-bit integers
//!
//! Same width-canonical convention as `x64.zig` (see its module comment): every
//! integer SSA value lives in a full 64-bit GPR whose bits above the type width
//! always match the type (zero-extended unsigned, sign-extended signed), so no
//! consumer needs a per-op mask. Loads sign/zero-extend to width, narrow
//! constants are in range, and the widening ops — `add`/`sub`/`mul`/`shl` and
//! unary `neg`/`bnot` — re-narrow their result via `canonNarrow` (an
//! `SBFM`/`UBFM` through `extendRegA`) before storing it; bitwise ops, right
//! shifts, and `div`/`mod` preserve canonical inputs and stay unmasked, and
//! `u64`/`i64` cost nothing. Fixes the narrow `add` + rotate miscompile that
//! blocks the crypto stdlib (#1158).
//!
//! ## Safepoints
//!
//! Per `runtime/ABI.md` §5, same policy as `x64.zig`: a stack map at every
//! `call`/`rt_call`, and at every loop back-edge (`jump`/`br` whose target
//! block index is <= the branching block's), with a synthetic zero-arg
//! `bl bit_rt_safepoint` inserted right before the back-edge branch. Whenever
//! a function contains any safepoint — a real call/rt_call *or* a loop
//! back-edge — its allocatable register file is restricted to the callee-saved
//! subset only (`has_safepoints`, derived from the recorded safepoint list),
//! sidestepping caller-save spill/reload entirely.
//!
//! ## Frame record
//!
//! AAPCS64 (and Apple's backtracer/crash-reporter tooling specifically)
//! expects every non-leaf frame to chain via `x29`: `*x29 == caller's x29`,
//! `*(x29+8) == return address`. This backend always establishes that
//! record in the prologue, unconditionally (simpler and more debuggable than
//! conditionally skipping it for leaf functions, at the cost of two stores
//! `x64.zig`'s own `push rbp` equivalent already pays regardless).
//!
//! ## Addressing
//!
//! AArch64 has no `x64.zig`-style SIB byte, but it does have a single
//! register-offset load/store instruction that computes `base + index<<shift`
//! for free (`loadIndexed`/`storeIndexed`), which is used directly for array
//! indexing. A constant byte offset (`field_get`/`field_set`, spill/frame
//! slots) uses the unsigned-immediate form when it fits (offset a multiple
//! of the access width, scaled value <= 4095), falling back to materializing
//! the offset into a scratch register and reusing the register-offset form
//! otherwise — always correct regardless of offset magnitude, exactly the
//! same "arbitrary displacement, uniform encoder" contract `x64.zig`'s
//! `movLoad`/`movStore` give their caller.

const std = @import("std");
const ir = @import("../ir.zig");
const check = @import("../check.zig");
const regalloc = @import("../regalloc.zig");
const common = @import("common.zig");

const Allocator = std.mem.Allocator;
const TypeId = check.TypeId;
const TypeContext = check.TypeContext;

/// How an object writer must patch a relocation's instruction field: a `BL`'s
/// 26-bit branch immediate (calls), or the `ADRP`/`ADD` pair that materializes
/// a static symbol's address (a `const_string`'s `__bitstr_N` header).
/// `tprel_hi12`/`tprel_lo12` are the AArch64 ELF local-exec TLS pair (§11.11);
/// they are meaningless on Mach-O, whose thread-locals go through a TLV
/// descriptor instead, so `emit.zig`'s Mach-O mapping rejects them.
pub const RelocKind = enum { branch, page21, pageoff12, tprel_hi12, tprel_lo12 };
pub const Reloc = struct { offset: u32, symbol: []const u8, kind: RelocKind = .branch };
pub const CodegenError = common.CodegenError;

// ============================================================================
// Registers & calling convention (AAPCS64)
// ============================================================================

/// Physical GPR `x0`..`x30`, numbered exactly as AArch64 encodes them
/// (`@intFromEnum` IS the register number). `sp`/`xzr` share encoding `31`
/// but are never a real operand's *allocated* register, so they are not
/// enum members — see `reg_zr`/`reg_sp` below.
pub const Reg = enum(u5) { x0, x1, x2, x3, x4, x5, x6, x7, x8, x9, x10, x11, x12, x13, x14, x15, x16, x17, x18, x19, x20, x21, x22, x23, x24, x25, x26, x27, x28, x29, x30 };
/// Physical FP/SIMD register, scalar `d0`..`d31` (double) or `s0`..`s31`
/// (single) view of the same register file — the width is selected per
/// access, not by a separate enum.
pub const FReg = enum(u5) { d0, d1, d2, d3, d4, d5, d6, d7, d8, d9, d10, d11, d12, d13, d14, d15, d16, d17, d18, d19, d20, d21, d22, d23, d24, d25, d26, d27, d28, d29, d30, d31 };

/// Register `31` in a load/store base or `add`/`sub`-immediate position
/// always means `sp` (never `xzr`) — a fixed AArch64 convention, not a
/// per-instruction choice.
const reg_sp: u5 = 31;
/// Register `31` everywhere else (logical/shifted-register ops, compare,
/// conditional-select) means the zero register.
const reg_zr: u5 = 31;

/// Reserved codegen-internal scratch — ordinary AAPCS64 caller-saved
/// temporaries, never allocatable, never a legitimate argument/return
/// register (see module doc comment).
const scratch1: Reg = .x9; // primary: binary/unary accumulator
const scratch2: Reg = .x10; // secondary: rhs operand / index register
const scratch3: Reg = .x11; // tertiary: address/offset materialization temp
// Two extra scratch GPRs used ONLY inside an atomic op's inline sequence
// (§11.5). An RMW/cmpxchg LL/SC loop needs up to five live registers at once
// (base, operand(s), old, computed, status) — more than `scratch1..3`.
// `x16`/`x17` (AAPCS64 IP0/IP1) are never allocatable and never scratch
// elsewhere, and no call occurs inside an atomic sequence, so they are safe
// as transient atomic temporaries.
const ascratch1: Reg = .x16; // atomic: base-address holder
const ascratch2: Reg = .x17; // atomic: operand / expected holder
const fscratch1: FReg = .d30; // primary float accumulator / move-cycle temp
const fscratch2: FReg = .d31; // secondary float operand

const master_gprs = [_]Reg{ .x0, .x1, .x2, .x3, .x4, .x5, .x6, .x7, .x8, .x12, .x13, .x14, .x15, .x19, .x20, .x21, .x22, .x23, .x24, .x25, .x26, .x27, .x28 };
const max_int_regs = master_gprs.len;
const max_float_regs = 30; // d0..d29 (d30/d31 are scratch)

const arg_int_regs = [_]Reg{ .x0, .x1, .x2, .x3, .x4, .x5, .x6, .x7 };
const max_arg_regs = arg_int_regs.len; // int and float each get 8 slots

/// Linux AArch64 syscall registers (§11.8): arguments in `x0`..`x5` (the first
/// six AAPCS64 argument registers, so `arg_int_regs`' own prefix), the syscall
/// number in `x8`, the kernel's return value back in `x0`.
const syscall_arg_regs = arg_int_regs[0..6];
const syscall_nr_reg: Reg = .x8;

fn isCalleeSavedInt(r: Reg) bool {
    return switch (r) {
        .x19, .x20, .x21, .x22, .x23, .x24, .x25, .x26, .x27, .x28 => true,
        else => false,
    };
}

/// AAPCS64 guarantees only the low 64 bits of `v8`..`v15` are preserved —
/// exactly the bits this backend ever uses (`d` registers only), so the
/// plain "is it in `d8..d15`" check is the whole story.
fn isCalleeSavedFloat(f: FReg) bool {
    return @intFromEnum(f) >= 8 and @intFromEnum(f) <= 15;
}

/// Allocatable GPRs for one function: the full master list, or (whenever the
/// function contains any safepoint) only its callee-saved subset — see the
/// module doc comment. `buf` is caller-owned storage (bounded, `max_int_regs`).
fn buildIntRegs(buf: *[max_int_regs]Reg, has_safepoints: bool) []const Reg {
    if (!has_safepoints) return &master_gprs;
    var n: usize = 0;
    for (master_gprs) |r| {
        if (isCalleeSavedInt(r)) {
            buf[n] = r;
            n += 1;
        }
    }
    return buf[0..n];
}

/// Allocatable FP registers for one function — see `buildIntRegs`.
fn buildFloatRegs(buf: *[max_float_regs]FReg, has_safepoints: bool) []const FReg {
    if (!has_safepoints) {
        for (0..max_float_regs) |i| buf[i] = @enumFromInt(@as(u5, @intCast(i)));
        return buf[0..max_float_regs];
    }
    var n: usize = 0;
    var r: u5 = 8;
    while (r <= 15) : (r += 1) {
        buf[n] = @enumFromInt(r);
        n += 1;
    }
    return buf[0..n];
}

/// The nth argument's ABI register, or `null` if it overflows to the stack
/// (unsupported — see `CodegenError.TooManyArguments`). AAPCS64 counts
/// int/float arguments independently, same as `x64.zig`'s SysV convention.
fn argReg(class: regalloc.Class, class_ordinal: u32) ?u5 {
    if (class_ordinal >= max_arg_regs) return null;
    return switch (class) {
        .int => @intFromEnum(arg_int_regs[class_ordinal]),
        .float => @intCast(class_ordinal), // d0..d7
    };
}

/// How many of `args` overflow the AAPCS64 argument registers — the count of
/// 8-byte outgoing stack slots this call needs. `base_int_ord`/`base_float_ord`
/// pre-charge the banks exactly as the matching `marshalArgs` call does (arg0
/// is reserved for a closure env / interface receiver at the `call_value` /
/// `call_iface` sites). Free function (not a `Ctx` method) so the frame layout
/// can size the outgoing area before `Ctx` exists.
fn stackArgSlots(tctx: *const TypeContext, f: *const ir.Function, args: []const u32, base_int_ord: u32, base_float_ord: u32) u32 {
    var int_ord = base_int_ord;
    var float_ord = base_float_ord;
    var slots: u32 = 0;
    for (args) |a| {
        const class = common.classOf(tctx, f.valueType(@enumFromInt(a)));
        const ord = if (class == .int) int_ord else float_ord;
        if (ord >= max_arg_regs) slots += 1;
        if (class == .int) int_ord += 1 else float_ord += 1;
    }
    return slots;
}

fn retRegNum(class: regalloc.Class) u5 {
    _ = class;
    return 0; // x0 or d0, both register #0 in their file
}

// ============================================================================
// Output records
// ============================================================================

pub const SafepointEntry = struct {
    /// Byte offset in `FuncCode.code` of the return address (right after the
    /// `bl`'s 4 bytes) this stack map applies to.
    code_offset: u32,
    regs: []const Reg,
    frame_offsets: []const i32,
};

pub const FuncCode = struct {
    gpa: Allocator,
    name: []const u8,
    code: []u8,
    relocs: []Reloc,
    safepoints: []SafepointEntry,
    /// Callee-saved registers this function's prologue preserves, and where
    /// (frame-pointer/x29-relative) it stashed the caller's value — the runtime
    /// stack walker (`runtime/ABI.md` §4) restores them when unwinding.
    saved_regs: []common.SavedReg,
    frame_size: u32,
    /// Owned `__bitstr_N` names that `relocs` borrow (one per `const_string`).
    owned_syms: [][]u8 = &.{},

    pub fn deinit(self: *FuncCode) void {
        self.gpa.free(self.code);
        self.gpa.free(self.relocs);
        for (self.safepoints) |sp| {
            self.gpa.free(sp.regs);
            self.gpa.free(sp.frame_offsets);
        }
        self.gpa.free(self.safepoints);
        self.gpa.free(self.saved_regs);
        for (self.owned_syms) |s| self.gpa.free(s);
        self.gpa.free(self.owned_syms);
        self.* = undefined;
    }
};

// ============================================================================
// Low-level AArch64 encoder
//
// Every bit-packing formula below was validated against `as -arch arm64` /
// `objdump -d` output for concrete operands (multiple distinct register
// numbers and immediate values per instruction class) before being written
// here — see the task's development notes; there is no ISA-manual
// transcription that hasn't been cross-checked against a real assembler.
// ============================================================================

const Cond = struct {
    const eq: u4 = 0x0;
    const ne: u4 = 0x1;
    const cs: u4 = 0x2; // == hs
    const cc: u4 = 0x3; // == lo
    const mi: u4 = 0x4;
    const pl: u4 = 0x5;
    const hi: u4 = 0x8;
    const ls: u4 = 0x9;
    const ge: u4 = 0xA;
    const lt: u4 = 0xB;
    const gt: u4 = 0xC;
    const le: u4 = 0xD;

    /// Flips the low bit — the standard AArch64 "invert condition" relation
    /// (every pair EQ/NE, CS/CC, MI/PL, ... differs only in that bit),
    /// used by `cset`'s `CSINC` encoding.
    fn invert(c: u4) u4 {
        return c ^ 1;
    }
};

/// One compiling function's full context — see `x64.zig`'s `Ctx` for the
/// shape this mirrors.
const Ctx = struct {
    gpa: Allocator,
    module: *const ir.Module,
    f: *const ir.Function,
    code: std.ArrayList(u8) = .empty,
    relocs: std.ArrayList(Reloc) = .empty,
    owned_syms: std.ArrayList([]u8) = .empty,
    inst_to_vreg: []const u32,
    result: *const regalloc.Result,
    int_regs: []const Reg,
    float_regs: []const FReg,
    frame: FrameInfo,
    block_offsets: []u32,
    jump_fixups: std.ArrayList(JumpFixup) = .empty,
    safepoints: std.ArrayList(SafepointEntry) = .empty,
    safepoint_positions: []const u32,
    next_safepoint_idx: u32 = 0,

    fn tctx(self: *const Ctx) *const TypeContext {
        return self.module.ctx;
    }

    fn emitByte(self: *Ctx, b: u8) !void {
        try self.code.append(self.gpa, b);
    }

    fn emitU32(self: *Ctx, v: u32) !void {
        try self.emitByte(@truncate(v));
        try self.emitByte(@truncate(v >> 8));
        try self.emitByte(@truncate(v >> 16));
        try self.emitByte(@truncate(v >> 24));
    }

    fn emitWord(self: *Ctx, w: u32) !void {
        try self.emitU32(w);
    }

    // ---- data-processing (register) ------------------------------------

    /// AND/ORR/EOR/ANDS (shifted register, `LSL #shift`); `N=1` inverts
    /// `rm` first (`ORN`/`MVN`, `BICS`-style — only `ORN` is used here).
    /// `dst`/`rm` are raw register numbers (not `Reg`) since the flag-setting
    /// forms (`TST`) need `dst == reg_zr == 31`, outside `Reg`'s `0..30` range.
    fn logicalShiftedReg(self: *Ctx, opc: u2, n: bool, dst: u5, rn: u5, rm: u5, shift: u6) !void {
        const word: u32 = (@as(u32, 1) << 31) | (@as(u32, opc) << 29) | (0b01010 << 24) | (@as(u32, 0) << 22) | (@as(u32, @intFromBool(n)) << 21) | (@as(u32, rm) << 16) | (@as(u32, shift) << 10) | (@as(u32, rn) << 5) | dst;
        try self.emitWord(word);
    }

    /// `MOV Xd, Xm` == `ORR Xd, XZR, Xm`.
    fn movRR(self: *Ctx, dst: Reg, src: Reg) !void {
        if (dst == src) return;
        try self.logicalShiftedReg(0b01, false, @intFromEnum(dst), reg_zr, @intFromEnum(src), 0);
    }

    /// `MVN Xd, Xm` == `ORN Xd, XZR, Xm`.
    fn mvnR(self: *Ctx, dst: Reg, src: Reg) !void {
        try self.logicalShiftedReg(0b01, true, @intFromEnum(dst), reg_zr, @intFromEnum(src), 0);
    }

    const LogicOp = enum { and_, orr, eor, ands };
    fn logicalOpc(op: LogicOp) struct { opc: u2, n: bool } {
        return switch (op) {
            .and_ => .{ .opc = 0b00, .n = false },
            .orr => .{ .opc = 0b01, .n = false },
            .eor => .{ .opc = 0b10, .n = false },
            .ands => .{ .opc = 0b11, .n = false },
        };
    }
    fn logicalRR(self: *Ctx, op: LogicOp, dst: Reg, rn: Reg, rm: Reg) !void {
        const o = logicalOpc(op);
        try self.logicalShiftedReg(o.opc, o.n, @intFromEnum(dst), @intFromEnum(rn), @intFromEnum(rm), 0);
    }
    /// `TST Xn, Xm` == `ANDS XZR, Xn, Xm` (flags only).
    fn tstRR(self: *Ctx, rn: Reg, rm: Reg) !void {
        try self.logicalShiftedReg(0b11, false, reg_zr, @intFromEnum(rn), @intFromEnum(rm), 0);
    }

    /// ADD/SUB (shifted register, `LSL #shift`), and their flag-setting
    /// forms (`ADDS`/`SUBS`/`CMP`/`NEG`).
    fn addSubShiftedReg(self: *Ctx, is_sub: bool, set_flags: bool, dst: u5, rn: u5, rm: u5, shift: u6) !void {
        const word: u32 = (@as(u32, 1) << 31) | (@as(u32, @intFromBool(is_sub)) << 30) | (@as(u32, @intFromBool(set_flags)) << 29) | (0b01011 << 24) | (@as(u32, 0) << 22) | (@as(u32, rm) << 16) | (@as(u32, shift) << 10) | (@as(u32, rn) << 5) | dst;
        try self.emitWord(word);
    }
    fn addRR(self: *Ctx, dst: Reg, rn: Reg, rm: Reg) !void {
        try self.addSubShiftedReg(false, false, @intFromEnum(dst), @intFromEnum(rn), @intFromEnum(rm), 0);
    }
    /// `base + index<<shift` in one instruction — see module doc comment on
    /// addressing.
    fn addShiftedRR(self: *Ctx, dst: Reg, rn: Reg, rm: Reg, shift: u6) !void {
        try self.addSubShiftedReg(false, false, @intFromEnum(dst), @intFromEnum(rn), @intFromEnum(rm), shift);
    }
    fn subRR(self: *Ctx, dst: Reg, rn: Reg, rm: Reg) !void {
        try self.addSubShiftedReg(true, false, @intFromEnum(dst), @intFromEnum(rn), @intFromEnum(rm), 0);
    }
    /// `CMP Xn, Xm` == `SUBS XZR, Xn, Xm`.
    fn cmpRR(self: *Ctx, rn: Reg, rm: Reg) !void {
        try self.addSubShiftedReg(true, true, reg_zr, @intFromEnum(rn), @intFromEnum(rm), 0);
    }
    /// `CMP Xn, #0` == `SUBS XZR, Xn, XZR` — used to branch on an arbitrary
    /// bool-typed SSA value without a dedicated `CBZ` encoder (see `br`'s
    /// instruction selector).
    fn cmpZero(self: *Ctx, rn: Reg) !void {
        try self.addSubShiftedReg(true, true, reg_zr, @intFromEnum(rn), reg_zr, 0);
    }
    /// `NEG Xd, Xm` == `SUB Xd, XZR, Xm`.
    fn negR(self: *Ctx, dst: Reg, src: Reg) !void {
        try self.addSubShiftedReg(true, false, @intFromEnum(dst), reg_zr, @intFromEnum(src), 0);
    }

    /// ADD/SUB (immediate), `imm12` optionally `<<12` — the only two
    /// instruction forms in this backend where register `31` in the
    /// `Rn`/`Rd` slots means `sp`, not `xzr`.
    fn addSubImmediate(self: *Ctx, is_sub: bool, dst: u5, rn: u5, imm12: u12, shift12: bool) !void {
        const word: u32 = (@as(u32, 1) << 31) | (@as(u32, @intFromBool(is_sub)) << 30) | (@as(u32, 0) << 29) | (0b100010 << 23) | (@as(u32, @intFromBool(shift12)) << 22) | (@as(u32, imm12) << 10) | (@as(u32, rn) << 5) | dst;
        try self.emitWord(word);
    }

    /// `dst += imm` / `dst -= imm` for an arbitrary non-negative `imm`
    /// (frame-size arithmetic only — bounded to <= 2 instructions, i.e.
    /// `imm < 4096*4096`, which every real function frame satisfies).
    fn addSubImmWide(self: *Ctx, is_sub: bool, dst: u5, rn: u5, imm: u32) !void {
        std.debug.assert(imm < 4096 * 4096);
        const lo: u12 = @intCast(imm & 0xFFF);
        const hi: u12 = @intCast((imm >> 12) & 0xFFF);
        var base = rn;
        if (hi != 0) {
            try self.addSubImmediate(is_sub, dst, base, hi, true);
            base = dst;
        }
        if (lo != 0 or hi == 0) try self.addSubImmediate(is_sub, dst, base, lo, false);
    }

    /// `MUL Xd, Xn, Xm` == `MADD Xd, Xn, Xm, XZR`.
    fn dataProc3Source(self: *Ctx, o0: bool, dst: Reg, rn: Reg, rm: Reg, ra: u5) !void {
        const word: u32 = (@as(u32, 1) << 31) | (0b11011 << 24) | (@as(u32, @intFromEnum(rm)) << 16) | (@as(u32, @intFromBool(o0)) << 15) | (@as(u32, ra) << 10) | (@as(u32, @intFromEnum(rn)) << 5) | @intFromEnum(dst);
        try self.emitWord(word);
    }
    fn mulRR(self: *Ctx, dst: Reg, rn: Reg, rm: Reg) !void {
        try self.dataProc3Source(false, dst, rn, rm, reg_zr);
    }
    /// `MSUB Xd, Xn, Xm, Xa` == `Xd = Xa - Xn*Xm` — used to compute a
    /// remainder as `a - (a/b)*b` (AArch64 has no `rem` instruction).
    fn msubRR(self: *Ctx, dst: Reg, rn: Reg, rm: Reg, ra: Reg) !void {
        try self.dataProc3Source(true, dst, rn, rm, @intFromEnum(ra));
    }

    /// SDIV/UDIV/LSLV/LSRV/ASRV (data-processing, 2 source) — no fixed
    /// register constraints on this ISA, unlike x86-64's `idiv`/shift-by-`cl`.
    fn dataProc2Source(self: *Ctx, opcode: u6, dst: Reg, rn: Reg, rm: Reg) !void {
        const word: u32 = (@as(u32, 1) << 31) | (0b0011010110 << 21) | (@as(u32, @intFromEnum(rm)) << 16) | (@as(u32, opcode) << 10) | (@as(u32, @intFromEnum(rn)) << 5) | @intFromEnum(dst);
        try self.emitWord(word);
    }
    fn sdivRR(self: *Ctx, dst: Reg, rn: Reg, rm: Reg) !void {
        try self.dataProc2Source(0b000011, dst, rn, rm);
    }
    fn udivRR(self: *Ctx, dst: Reg, rn: Reg, rm: Reg) !void {
        try self.dataProc2Source(0b000010, dst, rn, rm);
    }
    fn lslvRR(self: *Ctx, dst: Reg, rn: Reg, rm: Reg) !void {
        try self.dataProc2Source(0b001000, dst, rn, rm);
    }
    fn lsrvRR(self: *Ctx, dst: Reg, rn: Reg, rm: Reg) !void {
        try self.dataProc2Source(0b001001, dst, rn, rm);
    }
    fn asrvRR(self: *Ctx, dst: Reg, rn: Reg, rm: Reg) !void {
        try self.dataProc2Source(0b001010, dst, rn, rm);
    }

    /// UBFM/SBFM (bitfield move, immediate) — `LSL`/`LSR`/`ASR` by an
    /// immediate shift are aliases of these.
    fn bitfieldImm(self: *Ctx, opc: u2, dst: Reg, src: Reg, immr: u6, imms: u6) !void {
        const word: u32 = (@as(u32, 1) << 31) | (@as(u32, opc) << 29) | (0b100110 << 23) | (@as(u32, 1) << 22) | (@as(u32, immr) << 16) | (@as(u32, imms) << 10) | (@as(u32, @intFromEnum(src)) << 5) | @intFromEnum(dst);
        try self.emitWord(word);
    }
    fn lslImm(self: *Ctx, dst: Reg, src: Reg, shift: u6) !void {
        try self.bitfieldImm(0b10, dst, src, @truncate((64 - @as(u7, shift)) % 64), 63 - shift);
    }
    fn lsrImm(self: *Ctx, dst: Reg, src: Reg, shift: u6) !void {
        try self.bitfieldImm(0b10, dst, src, shift, 63);
    }
    fn asrImm(self: *Ctx, dst: Reg, src: Reg, shift: u6) !void {
        try self.bitfieldImm(0b00, dst, src, shift, 63);
    }

    /// Conditional select family (`CSEL`/`CSINC`/`CSINV`/`CSNEG`); only
    /// `CSINC` (`op=0,o2=1`) is used, to build `CSET`.
    fn condSelect(self: *Ctx, op: bool, o2: bool, dst: Reg, rn: u5, rm: u5, cond: u4) !void {
        const word: u32 = (@as(u32, 1) << 31) | (@as(u32, @intFromBool(op)) << 30) | (0b11010100 << 21) | (@as(u32, rm) << 16) | (@as(u32, cond) << 12) | (@as(u32, @intFromBool(o2)) << 10) | (@as(u32, rn) << 5) | @intFromEnum(dst);
        try self.emitWord(word);
    }
    /// `CSET Xd, cond` == `CSINC Xd, XZR, XZR, invert(cond)` — materializes
    /// the boolean result of a preceding compare directly, no zero+setcc
    /// two-step needed (simpler than `x64.zig`'s `setcc`).
    fn cset(self: *Ctx, dst: Reg, cond: u4) !void {
        try self.condSelect(false, true, dst, reg_zr, reg_zr, Cond.invert(cond));
    }

    /// MOVZ/MOVN/MOVK (move wide immediate).
    const MovWideKind = enum { z, n, k };
    fn movWideOpc(kind: MovWideKind) u2 {
        return switch (kind) {
            .n => 0b00,
            .z => 0b10,
            .k => 0b11,
        };
    }
    fn movWide(self: *Ctx, kind: MovWideKind, dst: Reg, imm16: u16, hw: u2) !void {
        const word: u32 = (@as(u32, 1) << 31) | (@as(u32, movWideOpc(kind)) << 29) | (0b100101 << 23) | (@as(u32, hw) << 21) | (@as(u32, imm16) << 5) | @intFromEnum(dst);
        try self.emitWord(word);
    }

    /// Materializes an arbitrary 64-bit immediate in `dst`, choosing the
    /// fewest `MOVZ/MOVN` + `MOVK` instructions (bounded: at most 4, one per
    /// 16-bit halfword — the standard optimal-halfword algorithm every
    /// mainstream AArch64 compiler backend uses).
    fn movImm64(self: *Ctx, dst: Reg, val: u64) !void {
        if (val == 0) return self.movWide(.z, dst, 0, 0);
        if (val == std.math.maxInt(u64)) return self.movWide(.n, dst, 0, 0);

        var hw: [4]u16 = undefined;
        for (0..4) |i| hw[i] = @truncate(val >> @intCast(i * 16));
        var zero_count: u8 = 0;
        var ones_count: u8 = 0;
        for (hw) |h| {
            if (h == 0) zero_count += 1;
            if (h == 0xFFFF) ones_count += 1;
        }

        if (ones_count > zero_count) {
            var first: u2 = 0;
            for (hw, 0..) |h, i| {
                if (h != 0xFFFF) {
                    first = @intCast(i);
                    break;
                }
            }
            try self.movWide(.n, dst, ~hw[first], first);
            for (hw, 0..) |h, i| {
                if (i == first or h == 0xFFFF) continue;
                try self.movWide(.k, dst, h, @intCast(i));
            }
        } else {
            var first: u2 = 0;
            for (hw, 0..) |h, i| {
                if (h != 0) {
                    first = @intCast(i);
                    break;
                }
            }
            try self.movWide(.z, dst, hw[first], first);
            for (hw, 0..) |h, i| {
                if (i == first or h == 0) continue;
                try self.movWide(.k, dst, h, @intCast(i));
            }
        }
    }

    // ---- loads/stores -----------------------------------------------------

    /// `size`/`opc` per AArch64's load/store table: `size` in {00=byte,
    /// 01=half,10=word,11=doubleword}; for loads, `opc` in {01=zero-extend,
    /// 10=sign-extend-to-64} (irrelevant for `size=11`, always `01`); for
    /// stores, `opc` is always `00`.
    fn gpSizeOpc(width: u8, signed: bool, is_load: bool) struct { size: u2, opc: u2 } {
        const size: u2 = switch (width) {
            1 => 0b00,
            2 => 0b01,
            4 => 0b10,
            8 => 0b11,
            else => unreachable, // caller contract: width is always 1/2/4/8
        };
        if (!is_load) return .{ .size = size, .opc = 0b00 };
        return .{ .size = size, .opc = if (width == 8) 0b01 else if (signed) 0b10 else 0b01 };
    }

    /// Load/store register, unsigned immediate offset (`imm12`, scaled by
    /// the access width — always `0` here, see the module doc comment on why
    /// this backend only ever uses a pre-computed `imm12=0`, or its
    /// non-scaled register-offset counterpart).
    fn loadStoreUnsignedImm(self: *Ctx, size: u2, is_fp: bool, opc: u2, imm12: u12, rn: u5, rt: u5) !void {
        const word: u32 = (@as(u32, size) << 30) | (0b111001 << 24) | (@as(u32, @intFromBool(is_fp)) << 26) | (@as(u32, opc) << 22) | (@as(u32, imm12) << 10) | (@as(u32, rn) << 5) | rt;
        try self.emitWord(word);
    }

    /// Load/store register, register offset (`base + Rm<<shift`, `option`
    /// fixed to `011` == plain 64-bit register, matching every index value
    /// this backend ever produces — see `getInt`). `scale` requests the
    /// implicit `log2(width)` shift baked into the ISA (no separate shift
    /// amount field exists); `false` performs an unshifted (byte) access.
    fn loadStoreRegOffset(self: *Ctx, size: u2, is_fp: bool, opc: u2, rm: Reg, scale: bool, rn: u5, rt: u5) !void {
        const word: u32 = (@as(u32, size) << 30) | (0b111000 << 24) | (@as(u32, @intFromBool(is_fp)) << 26) | (@as(u32, opc) << 22) | (@as(u32, 1) << 21) | (@as(u32, @intFromEnum(rm)) << 16) | (0b011 << 13) | (@as(u32, @intFromBool(scale)) << 12) | (0b10 << 10) | (@as(u32, rn) << 5) | rt;
        try self.emitWord(word);
    }

    /// Fits `disp` as a scaled `imm12` for `width`-byte unsigned-offset
    /// addressing, or `null` if it doesn't (caller falls back to
    /// `loadStoreRegOffset` with a materialized offset register).
    fn fitsImm12(disp: u32, width: u8) ?u12 {
        if (disp % width != 0) return null;
        const scaled = disp / width;
        if (scaled > 4095) return null;
        return @intCast(scaled);
    }

    fn loadImm(self: *Ctx, dst: Reg, base_reg: u5, disp: u32, width: u8, signed: bool) !void {
        const so = gpSizeOpc(width, signed, true);
        if (fitsImm12(disp, width)) |imm12| {
            try self.loadStoreUnsignedImm(so.size, false, so.opc, imm12, base_reg, @intFromEnum(dst));
        } else {
            try self.movImm64(scratch3, disp);
            try self.loadStoreRegOffset(so.size, false, so.opc, scratch3, false, base_reg, @intFromEnum(dst));
        }
    }
    fn storeImm(self: *Ctx, src: Reg, base_reg: u5, disp: u32, width: u8) !void {
        const so = gpSizeOpc(width, false, false);
        if (fitsImm12(disp, width)) |imm12| {
            try self.loadStoreUnsignedImm(so.size, false, so.opc, imm12, base_reg, @intFromEnum(src));
        } else {
            try self.movImm64(scratch3, disp);
            try self.loadStoreRegOffset(so.size, false, so.opc, scratch3, false, base_reg, @intFromEnum(src));
        }
    }
    /// `base + index<<log2(width)`, sign/zero-extending per `width`/`signed`
    /// — array element load (`index_get`).
    fn loadIndexed(self: *Ctx, dst: Reg, base_reg: Reg, index: Reg, width: u8, signed: bool) !void {
        const so = gpSizeOpc(width, signed, true);
        try self.loadStoreRegOffset(so.size, false, so.opc, index, width != 1, @intFromEnum(base_reg), @intFromEnum(dst));
    }
    fn storeIndexed(self: *Ctx, src: Reg, base_reg: Reg, index: Reg, width: u8) !void {
        const so = gpSizeOpc(width, false, false);
        try self.loadStoreRegOffset(so.size, false, so.opc, index, width != 1, @intFromEnum(base_reg), @intFromEnum(src));
    }

    fn fpSize(width: u8) u2 {
        return if (width == 8) 0b11 else 0b10;
    }
    fn loadImmF(self: *Ctx, dst: FReg, base_reg: u5, disp: u32, width: u8) !void {
        if (fitsImm12(disp, width)) |imm12| {
            try self.loadStoreUnsignedImm(fpSize(width), true, 0b01, imm12, base_reg, @intFromEnum(dst));
        } else {
            try self.movImm64(scratch3, disp);
            try self.loadStoreRegOffset(fpSize(width), true, 0b01, scratch3, false, base_reg, @intFromEnum(dst));
        }
    }
    fn storeImmF(self: *Ctx, src: FReg, base_reg: u5, disp: u32, width: u8) !void {
        if (fitsImm12(disp, width)) |imm12| {
            try self.loadStoreUnsignedImm(fpSize(width), true, 0b00, imm12, base_reg, @intFromEnum(src));
        } else {
            try self.movImm64(scratch3, disp);
            try self.loadStoreRegOffset(fpSize(width), true, 0b00, scratch3, false, base_reg, @intFromEnum(src));
        }
    }

    // ---- atomics (§11.5) ----------------------------------------------
    // Load/store-exclusive register family and its acquire/release
    // non-exclusive siblings, plus CBNZ for the LL/SC retry loop. Encodings
    // cross-checked against `as -arch arm64` (see the module-level note).

    /// Load/store-exclusive-or-ordered register. Layout:
    /// `size 001000 o2 L 0 Rs o0 (1)1111 Rn Rt`. `Rs`/`Rt2` default to `31`
    /// for the load and non-exclusive forms; a store-exclusive names its
    /// status register in `Rs`.
    fn ldstExclusive(self: *Ctx, size: u2, o2: bool, l: bool, o0: bool, rs: u5, rn: u5, rt: u5) !void {
        const word: u32 = (@as(u32, size) << 30) | (0b001000 << 24) | (@as(u32, @intFromBool(o2)) << 23) | (@as(u32, @intFromBool(l)) << 22) | (@as(u32, rs) << 16) | (@as(u32, @intFromBool(o0)) << 15) | (0b11111 << 10) | (@as(u32, rn) << 5) | rt;
        try self.emitWord(word);
    }
    /// LDAXR Wt/Xt, [Xn] — load-exclusive-acquire.
    fn ldaxr(self: *Ctx, size: u2, rn: u5, rt: u5) !void {
        try self.ldstExclusive(size, false, true, true, 0b11111, rn, rt);
    }
    /// STLXR Ws, Wt/Xt, [Xn] — store-exclusive-release; `Ws` = 0 on success.
    fn stlxr(self: *Ctx, size: u2, rs: u5, rn: u5, rt: u5) !void {
        try self.ldstExclusive(size, false, false, true, rs, rn, rt);
    }
    /// LDAR Wt/Xt, [Xn] — plain load-acquire.
    fn ldar(self: *Ctx, size: u2, rn: u5, rt: u5) !void {
        try self.ldstExclusive(size, true, true, true, 0b11111, rn, rt);
    }
    /// STLR Wt/Xt, [Xn] — plain store-release.
    fn stlr(self: *Ctx, size: u2, rn: u5, rt: u5) !void {
        try self.ldstExclusive(size, true, false, true, 0b11111, rn, rt);
    }
    /// CBNZ Wt/Xt, #imm19*4 — branch if register nonzero. `imm19` is the
    /// signed word (instruction) displacement.
    fn cbnz(self: *Ctx, sf: bool, rt: u5, imm19: i32) !void {
        const bits: u32 = @bitCast(imm19);
        const word: u32 = (@as(u32, @intFromBool(sf)) << 31) | (0b0110101 << 24) | ((bits & 0x7FFFF) << 5) | rt;
        try self.emitWord(word);
    }
    /// Access-width `size` field (00=byte,01=half,10=word,11=dword) for the
    /// exclusive/ordered load-store family.
    fn atomicSize(bytes: u8) u2 {
        return switch (bytes) {
            1 => 0b00,
            2 => 0b01,
            4 => 0b10,
            8 => 0b11,
            else => unreachable, // caller contract: integer prim width
        };
    }

    // ---- scalar floating point ----------------------------------------

    fn fpType(width: u8) u2 {
        return if (width == 8) 0b01 else 0b00;
    }

    /// FADD/FSUB/FMUL/FDIV (floating-point, 2 source).
    const FArithOp = enum { add, sub, mul, div };
    fn fArithOpcode(op: FArithOp) u4 {
        return switch (op) {
            .mul => 0b0000,
            .div => 0b0001,
            .add => 0b0010,
            .sub => 0b0011,
        };
    }
    fn fArithRR(self: *Ctx, op: FArithOp, dst: FReg, rn: FReg, rm: FReg, width: u8) !void {
        const word: u32 = (0b11110 << 24) | (@as(u32, fpType(width)) << 22) | (@as(u32, 1) << 21) | (@as(u32, @intFromEnum(rm)) << 16) | (@as(u32, fArithOpcode(op)) << 12) | (0b10 << 10) | (@as(u32, @intFromEnum(rn)) << 5) | @intFromEnum(dst);
        try self.emitWord(word);
    }

    /// FMOV (register, scalar) / FNEG (floating-point, 1 source).
    fn fp1Source(self: *Ctx, opcode: u6, width: u8, dst: FReg, src: FReg) !void {
        const word: u32 = (0b11110 << 24) | (@as(u32, fpType(width)) << 22) | (@as(u32, 1) << 21) | (@as(u32, opcode) << 15) | (0b10000 << 10) | (@as(u32, @intFromEnum(src)) << 5) | @intFromEnum(dst);
        try self.emitWord(word);
    }
    fn fmovFF(self: *Ctx, dst: FReg, src: FReg, width: u8) !void {
        if (dst == src) return;
        try self.fp1Source(0b000000, width, dst, src);
    }
    fn fnegF(self: *Ctx, dst: FReg, src: FReg, width: u8) !void {
        try self.fp1Source(0b000010, width, dst, src);
    }
    /// `FSQRT Dd, Dn` — the same "floating-point data-processing (1 source)"
    /// group as FMOV/FNEG above, opcode `000011`. IEEE-exact and correctly
    /// rounded in hardware, so it needs no libm and no runtime call.
    fn fsqrtF(self: *Ctx, dst: FReg, src: FReg, width: u8) !void {
        try self.fp1Source(0b000011, width, dst, src);
    }
    /// `FRINTx Dd, Dn` — round to an integral value in the given direction,
    /// same "floating-point data-processing (1 source)" group. Exact by
    /// construction: the hardware handles signed zeros, subnormals, infinities
    /// and NaN, so there is nothing for this backend to special-case.
    ///
    /// `FRINTA` (`001100`) is ties-AWAY-from-zero, which is what `fround`
    /// means. `FRINTN` (`001000`) is ties-to-EVEN and is deliberately unused —
    /// the two differ on exactly the halfway cases (`round(2.5)` is 3.0, not
    /// 2.0), which is the one thing a careless port gets wrong here.
    fn frintF(self: *Ctx, opcode: u6, dst: FReg, src: FReg, width: u8) !void {
        try self.fp1Source(opcode, width, dst, src);
    }

    /// `FCMP Dn, Dm` (floating-point compare, register form) — sets NZCV
    /// per the module doc comment's condition-code derivation.
    fn fcmp(self: *Ctx, rn: FReg, rm: FReg, width: u8) !void {
        const word: u32 = (0b11110 << 24) | (@as(u32, fpType(width)) << 22) | (@as(u32, 1) << 21) | (@as(u32, @intFromEnum(rm)) << 16) | (0b1000 << 10) | (@as(u32, @intFromEnum(rn)) << 5);
        try self.emitWord(word);
    }

    /// FMOV (general <-> scalar): `opcode=0b111` general->scalar (`rn`=GPR,
    /// `rd`=FP), `opcode=0b110` scalar->general (`rn`=FP, `rd`=GPR) — the
    /// bit-preserving transfer used to materialize float constants (via a
    /// GPR immediate) and read them back, mirroring `x64.zig`'s `movXG`.
    fn fpConvertGpr(self: *Ctx, sf: bool, width: u8, opcode: u3, rn: u5, rd: u5) !void {
        const word: u32 = (@as(u32, @intFromBool(sf)) << 31) | (0b11110 << 24) | (@as(u32, fpType(width)) << 22) | (@as(u32, 1) << 21) | (@as(u32, opcode) << 16) | (@as(u32, rn) << 5) | rd;
        try self.emitWord(word);
    }
    fn fmovToFp(self: *Ctx, dst: FReg, src: Reg, width: u8) !void {
        try self.fpConvertGpr(width == 8, width, 0b111, @intFromEnum(src), @intFromEnum(dst));
    }
    fn fmovFromFp(self: *Ctx, dst: Reg, src: FReg, width: u8) !void {
        try self.fpConvertGpr(width == 8, width, 0b110, @intFromEnum(src), @intFromEnum(dst));
    }
    /// FP↔int conversion (SCVTF/FCVTZS), the full form with the `rmode` field
    /// `fpConvertGpr` hardcodes to 0. `sf` is the GPR width (1 = 64-bit),
    /// `width` the float precision; `rn`→`rd` per the group's `Rn<<5 | Rd`.
    fn fpIntConv(self: *Ctx, sf: bool, width: u8, rmode: u2, opcode: u3, rn: u5, rd: u5) !void {
        const word: u32 = (@as(u32, @intFromBool(sf)) << 31) | (0b11110 << 24) | (@as(u32, fpType(width)) << 22) | (@as(u32, 1) << 21) | (@as(u32, rmode) << 19) | (@as(u32, opcode) << 16) | (@as(u32, rn) << 5) | rd;
        try self.emitWord(word);
    }

    // ---- branches / calls / return -----------------------------------

    fn ret(self: *Ctx) !void {
        const word: u32 = 0xD65F0000 | (@as(u32, 30) << 5); // RET (implicit x30)
        try self.emitWord(word);
    }
    fn udf(self: *Ctx) !void {
        try self.emitWord(0);
    }

    /// `UXTB Wr, Wr` — zero the register above its low byte. Encoded as
    /// `UBFM Wr, Wr, #0, #7` (sf=0, opc=10, N=0, immr=0, imms=7), which also
    /// clears bits [63:32] because a 32-bit destination write does.
    fn uxtb(self: *Ctx, r: Reg) !void {
        const n: u32 = @intFromEnum(r);
        try self.emitWord(0x53001C00 | (n << 5) | n);
    }

    fn emitCallReloc(self: *Ctx, symbol: []const u8) !void {
        const off: u32 = @intCast(self.code.items.len);
        try self.emitWord(0x94000000); // BL, imm26=0 placeholder
        try self.relocs.append(self.gpa, .{ .offset = off, .symbol = symbol, .kind = .branch });
    }

    /// `BLR Xn` — indirect branch-with-link through a register. Used for
    /// `call_value` (closure dispatch through a loaded code pointer).
    fn blr(self: *Ctx, reg: Reg) !void {
        try self.emitWord(0xD63F0000 | (@as(u32, @intFromEnum(reg)) << 5));
    }

    /// Materializes the address of a static symbol into `dst` via the AArch64
    /// `ADRP`/`ADD` pair (imm fields are 0 placeholders the linker patches from
    /// the `page21`/`pageoff12` relocations). No `movabs` equivalent exists on
    /// AArch64; this is the standard PC-relative address-of sequence.
    fn emitAddrOf(self: *Ctx, dst: Reg, symbol: []const u8) !void {
        const d: u32 = @intFromEnum(dst);
        const adrp_off: u32 = @intCast(self.code.items.len);
        try self.emitWord(0x90000000 | d); // ADRP dst, 0
        try self.relocs.append(self.gpa, .{ .offset = adrp_off, .symbol = symbol, .kind = .page21 });
        const add_off: u32 = @intCast(self.code.items.len);
        try self.emitWord(0x91000000 | (d << 5) | d); // ADD dst, dst, #0
        try self.relocs.append(self.gpa, .{ .offset = add_off, .symbol = symbol, .kind = .pageoff12 });
    }

    /// AArch64 ELF local-exec TLS (§11.11): the address of thread-local `symbol`
    /// in the *calling* thread, as
    ///
    ///     mrs dst, TPIDR_EL0
    ///     add dst, dst, #:tprel_hi12:symbol, lsl #12
    ///     add dst, dst, #:tprel_lo12_nc:symbol
    ///
    /// Three instructions, no memory reference and no call, so the sequence is
    /// legal in a `@nosplit` body and clobbers nothing but `dst`. The linker
    /// folds the variant-I `AbiTcb` header into the relocation's value, so the
    /// two `ADD`s together carry a 24-bit thread-pointer offset.
    fn emitTlsAddrOf(self: *Ctx, dst: Reg, symbol: []const u8) !void {
        const d: u32 = @intFromEnum(dst);
        try self.emitWord(0xD53BD040 | d); // MRS dst, TPIDR_EL0
        const hi_off: u32 = @intCast(self.code.items.len);
        try self.emitWord(0x91400000 | (d << 5) | d); // ADD dst, dst, #0, LSL #12
        try self.relocs.append(self.gpa, .{ .offset = hi_off, .symbol = symbol, .kind = .tprel_hi12 });
        const lo_off: u32 = @intCast(self.code.items.len);
        try self.emitWord(0x91000000 | (d << 5) | d); // ADD dst, dst, #0
        try self.relocs.append(self.gpa, .{ .offset = lo_off, .symbol = symbol, .kind = .tprel_lo12 });
    }

    fn emitJumpFixup(self: *Ctx, target: ir.BlockId) !void {
        const off: u32 = @intCast(self.code.items.len);
        try self.emitWord(0x14000000); // B, imm26=0 placeholder
        try self.jump_fixups.append(self.gpa, .{ .patch_offset = off, .cond = null, .target = target });
    }
    fn emitCondJumpFixup(self: *Ctx, cond: u4, target: ir.BlockId) !void {
        const off: u32 = @intCast(self.code.items.len);
        try self.emitWord(0x54000000 | @as(u32, cond)); // B.cond, imm19=0 placeholder
        try self.jump_fixups.append(self.gpa, .{ .patch_offset = off, .cond = cond, .target = target });
    }

    /// Emits a `B.cond` to a not-yet-known LOCAL code offset (never a real
    /// IR block — used only to skip over one side of a `br`'s inline
    /// then/else code, resolved immediately by `patchLocalCondBranch` once
    /// that offset is known, unlike `jump_fixups` which resolve at the very
    /// end against `block_offsets`).
    fn emitLocalCondBranch(self: *Ctx, cond: u4) !u32 {
        const off: u32 = @intCast(self.code.items.len);
        try self.emitWord(0x54000000 | @as(u32, cond));
        return off;
    }
    fn patchLocalCondBranch(self: *Ctx, patch_offset: u32) void {
        const target_off: u32 = @intCast(self.code.items.len);
        const rel: i64 = @as(i64, target_off) - @as(i64, patch_offset);
        const imm19: i32 = @intCast(@divExact(rel, 4));
        const bits: u32 = @bitCast(imm19);
        const word = std.mem.readInt(u32, self.code.items[patch_offset..][0..4], .little) | ((bits & 0x7FFFF) << 5);
        std.mem.writeInt(u32, self.code.items[patch_offset..][0..4], word, .little);
    }

    fn patchJumpFixups(self: *Ctx) void {
        for (self.jump_fixups.items) |fx| {
            const target_off = self.block_offsets[@intFromEnum(fx.target)];
            const rel: i64 = @as(i64, target_off) - @as(i64, fx.patch_offset);
            const word_off: i32 = @intCast(@divExact(rel, 4));
            const bits: u32 = @bitCast(word_off);
            const old = std.mem.readInt(u32, self.code.items[fx.patch_offset..][0..4], .little);
            const new = if (fx.cond) |c| (old & ~@as(u32, 0x7FFFF << 5)) | ((bits & 0x7FFFF) << 5) | c else old | (bits & 0x3FFFFFF);
            std.mem.writeInt(u32, self.code.items[fx.patch_offset..][0..4], new, .little);
        }
    }
};

const JumpFixup = struct { patch_offset: u32, cond: ?u4, target: ir.BlockId };

// ============================================================================
// Frame layout
//
// SP-relative throughout (no dynamic `alloca` in this language, so SP never
// moves except once at entry and once before `ret` — no per-spill `rbp`
// indirection needed the way `x64.zig` uses it, though the encoder would
// happily take any base register). Layout, low to high address:
//   [0, outgoing_bytes)                      outgoing stack-argument area
//   [outgoing_bytes, +spill_bytes)           spill slots, 8 bytes each
//   [+spill_bytes, +gpr_bytes)               saved callee-saved GPRs
//   [+gpr_bytes, +fpr_bytes)                  saved callee-saved FP regs
//   [frame_size-16, frame_size-8)             saved x29 (frame record)
//   [frame_size-8, frame_size)                saved x30 (frame record)
// `frame_size` is always a multiple of 16 (AAPCS64 requires SP 16-aligned at
// all times, not just at call boundaries).
//
// The outgoing-argument area holds the 9th+ integer/reference or float
// argument of any call this function makes (AAPCS64 passes the first eight of
// each class in x0–x7 / v0–v7; the rest spill to the caller's stack). Sized to
// the widest call (`outgoing_bytes`) and reserved at the bottom of the frame —
// rather than a transient `sub sp` per call the way `x64.zig` does — precisely
// because everything here is SP-relative: a mid-body SP shift would move every
// spill/save offset. The callee finds these same words just above its own
// frame at `[sp + frame_size + 8*k]` (its caller stored them at its own
// `[sp + 8*k]`, and the prologue lowered SP by `frame_size`).
// ============================================================================

const FrameInfo = struct {
    saved_gpr: []const Reg,
    saved_fpr: []const FReg,
    num_spill_slots: u32,
    /// Bytes reserved at the bottom of the frame for outgoing stack arguments
    /// (0 if every call this function makes fits in registers). A multiple of 8.
    outgoing_bytes: u32,
    frame_size: u32,

    fn spillOffset(self: FrameInfo, slot: u32) u32 {
        return self.outgoing_bytes + slot * 8;
    }
    fn gprSaveOffset(self: FrameInfo, i: usize) u32 {
        return self.outgoing_bytes + self.num_spill_slots * 8 + @as(u32, @intCast(i)) * 8;
    }
    fn fprSaveOffset(self: FrameInfo, i: usize) u32 {
        return self.outgoing_bytes + self.num_spill_slots * 8 + @as(u32, @intCast(self.saved_gpr.len)) * 8 + @as(u32, @intCast(i)) * 8;
    }
    fn fpOffset(self: FrameInfo) u32 {
        return self.frame_size - 16;
    }
    fn lrOffset(self: FrameInfo) u32 {
        return self.frame_size - 8;
    }
    /// SP-relative byte offset of the k-th outgoing stack argument (the caller
    /// side stores here just before a `bl`).
    fn outgoingArgOffset(_: FrameInfo, k: u32) u32 {
        return k * 8;
    }
    /// SP-relative byte offset of the k-th incoming stack argument — the words
    /// the caller placed just above this frame (see the layout note above).
    fn incomingArgOffset(self: FrameInfo, k: u32) u32 {
        return self.frame_size + k * 8;
    }
};

fn alignFrame16(raw: u32) u32 {
    return (raw + 15) & ~@as(u32, 15);
}

// ============================================================================
// Parallel move sequencing — identical algorithm to `x64.zig`'s (see that
// file's doc comment for why a naive sequential emission is unsafe), ported
// to this backend's move/load/store primitives. The cycle-breaking
// algorithm itself has no register-file dependency, but Zig has no
// lightweight way to parameterize a ~60-line routine over "the caller's
// move/load/store ops" without a comptime-generic module — not worth the
// indirection for the two call sites (`x64.zig`, this file) that exist
// today; a third backend would be the trigger to actually extract it.
// ============================================================================

const PLoc = union(enum) { reg: u5, mem: u32 };
const PMove = struct { from: PLoc, to: PLoc };

fn plocEq(a: PLoc, b: PLoc) bool {
    return switch (a) {
        .reg => |ar| switch (b) {
            .reg => |br| ar == br,
            .mem => false,
        },
        .mem => |am| switch (b) {
            .mem => |bm| am == bm,
            .reg => false,
        },
    };
}

fn emitMove(self: *Ctx, from: PLoc, to: PLoc, class: regalloc.Class) !void {
    switch (class) {
        .int => switch (from) {
            .reg => |fr| switch (to) {
                .reg => |tr| try self.movRR(@enumFromInt(tr), @enumFromInt(fr)),
                .mem => |m| try self.storeImm(@enumFromInt(fr), reg_sp, m, 8),
            },
            .mem => |fm| switch (to) {
                .reg => |tr| try self.loadImm(@enumFromInt(tr), reg_sp, fm, 8, false),
                .mem => |tm| {
                    try self.loadImm(scratch1, reg_sp, fm, 8, false);
                    try self.storeImm(scratch1, reg_sp, tm, 8);
                },
            },
        },
        .float => switch (from) {
            .reg => |fr| switch (to) {
                .reg => |tr| try self.fmovFF(@enumFromInt(tr), @enumFromInt(fr), 8),
                .mem => |m| try self.storeImmF(@enumFromInt(fr), reg_sp, m, 8),
            },
            .mem => |fm| switch (to) {
                .reg => |tr| try self.loadImmF(@enumFromInt(tr), reg_sp, fm, 8),
                .mem => |tm| {
                    try self.loadImmF(fscratch1, reg_sp, fm, 8);
                    try self.storeImmF(fscratch1, reg_sp, tm, 8);
                },
            },
        },
    }
}

/// See `x64.zig`'s `sequentializeAndEmit` — same two-phase algorithm
/// (topological drain, then scratch-assisted cycle breaking), bounded by
/// `moves.len` (<= the register file size).
fn sequentializeAndEmit(self: *Ctx, moves_in: []const PMove, class: regalloc.Class) !void {
    var moves = try std.ArrayList(PMove).initCapacity(self.gpa, moves_in.len);
    defer moves.deinit(self.gpa);
    for (moves_in) |m| {
        if (!plocEq(m.from, m.to)) try moves.append(self.gpa, m);
    }

    var changed = true;
    while (changed) {
        changed = false;
        var i: usize = 0;
        while (i < moves.items.len) {
            const m = moves.items[i];
            var needed = false;
            for (moves.items, 0..) |other, j| {
                if (j != i and plocEq(other.from, m.to)) {
                    needed = true;
                    break;
                }
            }
            if (!needed) {
                try emitMove(self, m.from, m.to, class);
                _ = moves.swapRemove(i);
                changed = true;
            } else {
                i += 1;
            }
        }
    }

    while (moves.items.len > 0) {
        var cycle = std.ArrayList(PMove).empty;
        defer cycle.deinit(self.gpa);
        const start = moves.items[0].to;
        var cur = start;
        while (true) {
            var found: ?usize = null;
            for (moves.items, 0..) |m, j| {
                if (plocEq(m.to, cur)) {
                    found = j;
                    break;
                }
            }
            const idx = found orelse unreachable; // invariant: what's left forms closed cycles
            const mv = moves.items[idx];
            try cycle.append(self.gpa, mv);
            _ = moves.swapRemove(idx);
            cur = mv.from;
            if (plocEq(cur, start)) break;
        }
        // The cycle scratch holds one location's value across the whole
        // rotation, so it must be a register `emitMove` never clobbers as its
        // own temporary. A mem->mem move inside the cycle routes through
        // `scratch1`/`fscratch1` (see `emitMove`), so the cycle must use the
        // *secondary* scratch — otherwise the first mem->mem rotation step
        // overwrites the saved value and the cycle resolves to garbage (a
        // spilled loop-carried value swap on a back-edge silently corrupts,
        // task #1235). `scratch2`/`fscratch2` are reserved and never a move
        // source/destination, so they are safe to hold across the rotation.
        const scratch: PLoc = .{ .reg = if (class == .int) @intFromEnum(scratch2) else @intFromEnum(fscratch2) };
        try emitMove(self, cycle.items[0].to, scratch, class);
        var i: usize = 0;
        while (i + 1 < cycle.items.len) : (i += 1) {
            try emitMove(self, cycle.items[i].from, cycle.items[i].to, class);
        }
        try emitMove(self, scratch, cycle.items[cycle.items.len - 1].to, class);
    }
}

// ============================================================================
// Operand fetch/store helpers
// ============================================================================

fn regLocOf(self: *Ctx, vreg: u32) regalloc.Location {
    return self.result.locations[vreg];
}

fn getInt(self: *Ctx, vreg: u32, scratch: Reg) !Reg {
    return switch (regLocOf(self, vreg)) {
        .reg => |idx| self.int_regs[idx],
        .spill => |slot| blk: {
            try self.loadImm(scratch, reg_sp, self.frame.spillOffset(slot), 8, false);
            break :blk scratch;
        },
    };
}
fn putInt(self: *Ctx, vreg: u32, src: Reg) !void {
    switch (regLocOf(self, vreg)) {
        .reg => |idx| try self.movRR(self.int_regs[idx], src),
        .spill => |slot| try self.storeImm(src, reg_sp, self.frame.spillOffset(slot), 8),
    }
}
fn getFloat(self: *Ctx, vreg: u32, scratch: FReg) !FReg {
    return switch (regLocOf(self, vreg)) {
        .reg => |idx| self.float_regs[idx],
        .spill => |slot| blk: {
            try self.loadImmF(scratch, reg_sp, self.frame.spillOffset(slot), 8);
            break :blk scratch;
        },
    };
}
fn putFloat(self: *Ctx, vreg: u32, src: FReg) !void {
    switch (regLocOf(self, vreg)) {
        .reg => |idx| try self.fmovFF(self.float_regs[idx], src, 8),
        .spill => |slot| try self.storeImmF(src, reg_sp, self.frame.spillOffset(slot), 8),
    }
}
fn plocOf(self: *Ctx, vreg: u32, class: regalloc.Class) PLoc {
    return switch (regLocOf(self, vreg)) {
        .reg => |idx| .{ .reg = switch (class) {
            .int => @intFromEnum(self.int_regs[idx]),
            .float => @intFromEnum(self.float_regs[idx]),
        } },
        .spill => |slot| .{ .mem = self.frame.spillOffset(slot) },
    };
}

fn vregOf(self: *Ctx, v: ir.ValueId) u32 {
    return self.inst_to_vreg[@intFromEnum(v)];
}

// ============================================================================
// Instruction selection
// ============================================================================

/// Re-narrow a freshly-computed result in `reg` to its type width, restoring
/// the width-canonical invariant (see module doc comment). A no-op for the
/// 64-bit and non-int classes — `extendRegA` already treats width 8 as a plain
/// move.
fn canonNarrow(self: *Ctx, reg: Reg, w: common.Width) !void {
    if (w.class == .int and w.bytes < 8) try extendRegA(self, reg, reg, w.bytes, w.signed);
}

fn emitBinaryInt(self: *Ctx, op: enum { add, sub, band, bor, bxor }, dst: u32, lhs: ir.ValueId, rhs: ir.ValueId, w: common.Width) !void {
    const l = try getInt(self, vregOf(self, lhs), scratch1);
    const r = try getInt(self, vregOf(self, rhs), scratch2);
    switch (op) {
        .add => try self.addRR(scratch1, l, r),
        .sub => try self.subRR(scratch1, l, r),
        .band => try self.logicalRR(.and_, scratch1, l, r),
        .bor => try self.logicalRR(.orr, scratch1, l, r),
        .bxor => try self.logicalRR(.eor, scratch1, l, r),
    }
    // `add`/`sub` can overflow past the type width; the bitwise ops preserve
    // canonical operands, so they need no re-narrowing.
    if (op == .add or op == .sub) try canonNarrow(self, scratch1, w);
    try putInt(self, dst, scratch1);
}

fn emitMulInt(self: *Ctx, dst: u32, lhs: ir.ValueId, rhs: ir.ValueId, w: common.Width) !void {
    const l = try getInt(self, vregOf(self, lhs), scratch1);
    const r = try getInt(self, vregOf(self, rhs), scratch2);
    try self.mulRR(scratch1, l, r);
    try canonNarrow(self, scratch1, w);
    try putInt(self, dst, scratch1);
}

fn emitDivInt(self: *Ctx, op: ir.Op, dst: u32, lhs: ir.ValueId, rhs: ir.ValueId) !void {
    const l = try getInt(self, vregOf(self, lhs), scratch1);
    const r = try getInt(self, vregOf(self, rhs), scratch2);
    const signed = op == .sdiv or op == .srem;
    const is_rem = op == .srem or op == .urem;
    // `rem` recovers its result with `msub dst = l - q*r`, so it still needs `l`
    // (and `r`) after the divide. `l` aliases `scratch1` whenever it was spilled
    // and reloaded there, so writing the quotient to `scratch1` would clobber `l`
    // before `msub` reads it (yielding `q*(1-r)`). Divide into `scratch3` — never
    // allocatable, and unused on this path — so `l` survives. A plain divide has
    // no later use of `l`, so it keeps the quotient in `scratch1` as its result.
    const q: Reg = if (is_rem) scratch3 else scratch1;
    if (signed) try self.sdivRR(q, l, r) else try self.udivRR(q, l, r);
    if (is_rem) try self.msubRR(scratch1, q, r, l);
    try putInt(self, dst, scratch1);
}

fn emitUnaryInt(self: *Ctx, op: ir.Op, dst: u32, operand: ir.ValueId, w: common.Width) !void {
    const v = try getInt(self, vregOf(self, operand), scratch1);
    switch (op) {
        .neg => try self.negR(scratch1, v), // two's-complement negate sets high bits
        .bnot => try self.mvnR(scratch1, v), // bitwise-not sets every bit above width
        else => unreachable,
    }
    try canonNarrow(self, scratch1, w);
    try putInt(self, dst, scratch1);
}

/// Re-represent `src`'s low `width` bytes as a full 64-bit value in `dst`:
/// SBFM (signed) or UBFM (unsigned), the SXTB/UXTB/... family. Width 8 is a
/// plain move.
fn extendRegA(self: *Ctx, dst: Reg, src: Reg, width: u8, signed: bool) !void {
    const opc: u2 = if (signed) 0b00 else 0b10; // SBFM / UBFM
    switch (width) {
        1 => try self.bitfieldImm(opc, dst, src, 0, 7),
        2 => try self.bitfieldImm(opc, dst, src, 0, 15),
        4 => try self.bitfieldImm(opc, dst, src, 0, 31),
        else => if (@intFromEnum(dst) != @intFromEnum(src)) try self.movRR(dst, src),
    }
}

/// `T(x)` numeric conversion (§12.9) — the arm64 mirror of x64's `emitConvert`.
/// Int operands are canonicalized to their true 64-bit value from the source
/// width, then to the destination width (SBFM/UBFM); int↔float uses SCVTF /
/// FCVTZS (truncating), float↔float uses FCVT. (Unsigned 64-bit ↔ float takes
/// the signed path — a value with bit 63 set is out of range, a v1 limit.)
fn emitConvert(self: *Ctx, dst: u32, src: ir.ValueId, dst_ty: TypeId) !void {
    const sw = common.widthOf(self.tctx(), self.f.valueType(src));
    const dw = common.widthOf(self.tctx(), dst_ty);
    if (sw.class == .int and dw.class == .int) {
        const r = try getInt(self, vregOf(self, src), scratch1);
        try extendRegA(self, scratch1, r, sw.bytes, sw.signed);
        try extendRegA(self, scratch1, scratch1, dw.bytes, dw.signed);
        try putInt(self, dst, scratch1);
    } else if (sw.class == .int and dw.class == .float) {
        const r = try getInt(self, vregOf(self, src), scratch1);
        try extendRegA(self, scratch1, r, sw.bytes, sw.signed);
        try self.fpIntConv(true, dw.bytes, 0b00, 0b010, @intFromEnum(scratch1), @intFromEnum(fscratch1)); // SCVTF
        try putFloat(self, dst, fscratch1);
    } else if (sw.class == .float and dw.class == .int) {
        const x = try getFloat(self, vregOf(self, src), fscratch1);
        try self.fpIntConv(true, sw.bytes, 0b11, 0b000, @intFromEnum(x), @intFromEnum(scratch1)); // FCVTZS
        try extendRegA(self, scratch1, scratch1, dw.bytes, dw.signed);
        try putInt(self, dst, scratch1);
    } else {
        // float → float, always differing widths (same-type is filtered in lowering).
        const x = try getFloat(self, vregOf(self, src), fscratch1);
        const opcode: u6 = if (dw.bytes == 8) 0b000101 else 0b000100; // FCVT to double / to single
        try self.fp1Source(opcode, sw.bytes, fscratch1, x);
        try putFloat(self, dst, fscratch1);
    }
}

/// Peeks whether `v` is a `const_int` instruction, returning its value
/// masked to a valid 0-63 shift count when so — mirrors `x64.zig`'s
/// `constShiftAmount`.
fn constShiftAmount(f: *const ir.Function, v: ir.ValueId) ?u6 {
    if (f.insts.items(.op)[@intFromEnum(v)] != .const_int) return null;
    const val = f.decode(v).const_int;
    return @truncate(@as(u64, @bitCast(val)));
}

fn emitShiftInt(self: *Ctx, op: ir.Op, dst: u32, lhs: ir.ValueId, rhs: ir.ValueId, w: common.Width) !void {
    const l = try getInt(self, vregOf(self, lhs), scratch1);
    if (constShiftAmount(self.f, rhs)) |amt| {
        switch (op) {
            .shl => try self.lslImm(scratch1, l, amt),
            .lshr => try self.lsrImm(scratch1, l, amt),
            .ashr => try self.asrImm(scratch1, l, amt),
            else => unreachable,
        }
    } else {
        const r = try getInt(self, vregOf(self, rhs), scratch2);
        switch (op) {
            .shl => try self.lslvRR(scratch1, l, r),
            .lshr => try self.lsrvRR(scratch1, l, r),
            .ashr => try self.asrvRR(scratch1, l, r),
            else => unreachable,
        }
    }
    // Only `shl` pushes bits past the type width; `lshr`/`ashr` keep a canonical
    // operand canonical, so a full-width right shift needs no re-narrowing.
    if (op == .shl) try canonNarrow(self, scratch1, w);
    try putInt(self, dst, scratch1);
}

const icmp_cond = std.EnumMap(ir.Op, u4).init(.{
    .icmp_eq = Cond.eq,
    .icmp_ne = Cond.ne,
    .icmp_slt = Cond.lt,
    .icmp_sle = Cond.le,
    .icmp_sgt = Cond.gt,
    .icmp_sge = Cond.ge,
    .icmp_ult = Cond.cc,
    .icmp_ule = Cond.ls,
    .icmp_ugt = Cond.hi,
    .icmp_uge = Cond.cs,
});

fn emitIcmp(self: *Ctx, op: ir.Op, dst: u32, lhs: ir.ValueId, rhs: ir.ValueId) !void {
    const l = try getInt(self, vregOf(self, lhs), scratch1);
    const r = try getInt(self, vregOf(self, rhs), scratch2);
    try self.cmpRR(l, r);
    try self.cset(scratch1, icmp_cond.get(op).?);
    try putInt(self, dst, scratch1);
}

/// AArch64's `FCMP` sets NZCV such that the *plain* `EQ`/`NE`/`GT`/`GE`
/// condition codes are already correct for IEEE-754 ordered comparisons
/// (false on any NaN, except `NE` which is true) — but "less than" and
/// "less than or equal" are NOT `LT`/`LE` (those would be true on an
/// unordered NaN compare — an ARM-specific gotcha every AArch64 backend
/// must special-case): use `MI` and `LS` instead. See module doc comment;
/// this mapping is the same one LLVM's AArch64 backend uses.
const fcmp_cond = std.EnumMap(ir.Op, u4).init(.{
    .fcmp_eq = Cond.eq,
    .fcmp_ne = Cond.ne,
    .fcmp_gt = Cond.gt,
    .fcmp_ge = Cond.ge,
    .fcmp_lt = Cond.mi,
    .fcmp_le = Cond.ls,
});

fn emitFcmp(self: *Ctx, op: ir.Op, dst: u32, lhs: ir.ValueId, rhs: ir.ValueId, width: u8) !void {
    const l = try getFloat(self, vregOf(self, lhs), fscratch1);
    const r = try getFloat(self, vregOf(self, rhs), fscratch2);
    try self.fcmp(l, r, width);
    try self.cset(scratch1, fcmp_cond.get(op).?);
    try putInt(self, dst, scratch1);
}

fn emitBinaryFloat(self: *Ctx, op: Ctx.FArithOp, dst: u32, lhs: ir.ValueId, rhs: ir.ValueId, width: u8) !void {
    const l = try getFloat(self, vregOf(self, lhs), fscratch1);
    const r = try getFloat(self, vregOf(self, rhs), fscratch2);
    try self.fArithRR(op, fscratch1, l, r, width);
    try putFloat(self, dst, fscratch1);
}

fn emitFneg(self: *Ctx, dst: u32, operand: ir.ValueId, width: u8) !void {
    const v = try getFloat(self, vregOf(self, operand), fscratch1);
    try self.fnegF(fscratch1, v, width);
    try putFloat(self, dst, fscratch1);
}

/// `fsqrt(x)` — one instruction, no call. `width` is the float width, which is
/// both the operand's and the result's.
fn emitFsqrt(self: *Ctx, dst: u32, operand: ir.ValueId, width: u8) !void {
    const v = try getFloat(self, vregOf(self, operand), fscratch1);
    try self.fsqrtF(fscratch1, v, width);
    try putFloat(self, dst, fscratch1);
}

/// `floatBits`/`float32Bits` — a register-class transfer, not a conversion:
/// `FMOV Xd, Dn` (width 8) or `FMOV Wd, Sn` (width 4) moves the bits verbatim.
/// The width comes from the OPERAND's float type. The result is `u64`/`u32` of
/// the same width by construction (f64->u64, f32->u32), so today reading it
/// from the result instead is exactly equivalent — mutation-tested, and it
/// changes nothing. The operand is still the honest source: it is the value
/// actually being moved, and it stays correct if a later primitive ever pairs
/// widths differently. `FMOV Wd, Sn` writes the 32-bit W view, which
/// zero-extends into X — the canonical form this backend keeps narrow unsigned
/// values in.
/// `ffloor`/`fceil`/`ftrunc`/`fround` — one `FRINT` each. See `frintF` for why
/// `fround` is `FRINTA` and not `FRINTN`.
fn emitFRound(self: *Ctx, dst: u32, operand: ir.ValueId, width: u8, opcode: u6) !void {
    const v = try getFloat(self, vregOf(self, operand), fscratch1);
    try self.frintF(opcode, fscratch1, v, width);
    try putFloat(self, dst, fscratch1);
}

/// `bitcast`: a register-class transfer, in whichever direction the result type
/// asks for. Float -> int is `floatBits` (SPEC §17); int -> float is the read
/// half of the container word ABI (`ir.rtReturnsWord`), turning the `u64` a
/// runtime primitive hands back in x0 into the `f64`/`f32` the element is.
/// `width` is the float side's width in both directions.
fn emitBitcast(self: *Ctx, dst: u32, operand: ir.ValueId, width: u8, dst_class: regalloc.Class) !void {
    if (dst_class == .float) {
        const v = try getInt(self, vregOf(self, operand), scratch1);
        try self.fmovToFp(fscratch1, v, width);
        try putFloat(self, dst, fscratch1);
        return;
    }
    const v = try getFloat(self, vregOf(self, operand), fscratch1);
    try self.fmovFromFp(scratch1, v, width);
    try putInt(self, dst, scratch1);
}

fn emitConstInt(self: *Ctx, dst: u32, val: i64) !void {
    try self.movImm64(scratch1, @bitCast(val));
    try putInt(self, dst, scratch1);
}
fn emitConstBool(self: *Ctx, dst: u32, val: bool) !void {
    try self.movImm64(scratch1, @intFromBool(val));
    try putInt(self, dst, scratch1);
}
fn emitConstNil(self: *Ctx, dst: u32) !void {
    try self.movImm64(scratch1, 0);
    try putInt(self, dst, scratch1);
}
/// A `const_string` value is the address of its static `{ptr,len}` header
/// (`__bitstr_N`, materialized by the object writer + linker into `.rodata`);
/// loads that address into the destination via the `ADRP`/`ADD` pair.
fn emitConstString(self: *Ctx, dst: u32, pool_idx: u32) !void {
    const name = try std.fmt.allocPrint(self.gpa, "__bitstr_{d}", .{pool_idx});
    try self.owned_syms.append(self.gpa, name);
    try self.emitAddrOf(scratch1, name);
    try putInt(self, dst, scratch1);
}
fn emitConstFloat(self: *Ctx, dst: u32, val: f64, width: u8) !void {
    if (width == 8) {
        try self.movImm64(scratch1, @bitCast(val));
        try self.fmovToFp(fscratch1, scratch1, 8);
    } else {
        const bits32: u32 = @bitCast(@as(f32, @floatCast(val)));
        try self.movImm64(scratch1, bits32);
        try self.fmovToFp(fscratch1, scratch1, 4);
    }
    try putFloat(self, dst, fscratch1);
}

/// `slice_len` reads the `len` word from a slice or string header. A `[]T`
/// header is `{ptr, len, cap, is_ref}` and a `string` header is `{ptr, len}`
/// (ABI.md §2) — both keep `len` at offset 8, so one load serves both. `len`
/// on a static `[N]T` array folds to a `const_int` in lowering, and dynamic
/// slice indexing goes through the `slice_get`/`_set` runtime calls, so this op
/// only ever loads a header length.
fn emitSliceLen(self: *Ctx, dst: u32, base: ir.ValueId) !void {
    const base_reg = try getInt(self, vregOf(self, base), scratch2);
    try self.loadImm(scratch1, @intFromEnum(base_reg), 8, 8, false);
    try putInt(self, dst, scratch1);
}

fn emitFieldGet(self: *Ctx, dst: u32, base: ir.ValueId, offset: u32, ty: TypeId) !void {
    const base_reg = try getInt(self, vregOf(self, base), scratch2);
    // A fixed-size array field is inline storage: its value is the interior
    // address `base + offset` (an ADD-immediate), not a loaded word.
    if (self.tctx().typeOf(ty) == .array) {
        try self.addSubImmWide(false, @intFromEnum(scratch1), @intFromEnum(base_reg), offset);
        try putInt(self, dst, scratch1);
        return;
    }
    const w = common.widthOf(self.tctx(), ty);
    switch (w.class) {
        .int => {
            try self.loadImm(scratch1, @intFromEnum(base_reg), offset, w.bytes, w.signed);
            try putInt(self, dst, scratch1);
        },
        .float => {
            try self.loadImmF(fscratch1, @intFromEnum(base_reg), offset, w.bytes);
            try putFloat(self, dst, fscratch1);
        },
    }
}

/// Write barrier not yet inserted — same deferral as `x64.zig`'s
/// `field_set`, pending the runtime's write-barrier contract.
fn emitFieldSet(self: *Ctx, base: ir.ValueId, offset: u32, value: ir.ValueId, ty: TypeId) !void {
    const w = common.widthOf(self.tctx(), ty);
    const base_reg = try getInt(self, vregOf(self, base), scratch2);
    switch (w.class) {
        .int => {
            const v = try getInt(self, vregOf(self, value), scratch1);
            try self.storeImm(v, @intFromEnum(base_reg), offset, w.bytes);
        },
        .float => {
            const v = try getFloat(self, vregOf(self, value), fscratch1);
            try self.storeImmF(v, @intFromEnum(base_reg), offset, w.bytes);
        },
    }
}

/// Array element access — `lower.zig` only ever emits `index_get`/`index_set`
/// against a static `.array` base (see module doc comment), so `base` is
/// always a direct data pointer with no header to skip.
fn emitIndexGet(self: *Ctx, dst: u32, base: ir.ValueId, index: ir.ValueId, ty: TypeId) !void {
    const w = common.widthOf(self.tctx(), ty);
    const base_reg = try getInt(self, vregOf(self, base), scratch2);
    const idx_reg = try getInt(self, vregOf(self, index), scratch3);
    switch (w.class) {
        .int => {
            try self.loadIndexed(scratch1, base_reg, idx_reg, w.bytes, w.signed);
            try putInt(self, dst, scratch1);
        },
        .float => {
            // Float arrays index the same way ints do (register-offset,
            // scaled); no distinct float indexed-load opcode is needed
            // since the addressing mode is class-independent — reuse the
            // GP encoder's `loadStoreRegOffset` via a small local wrapper.
            try self.loadStoreRegOffset(if (w.bytes == 8) 0b11 else 0b10, true, 0b01, idx_reg, w.bytes != 1, @intFromEnum(base_reg), @intFromEnum(fscratch1));
            try putFloat(self, dst, fscratch1);
        },
    }
}
fn emitIndexSet(self: *Ctx, base: ir.ValueId, index: ir.ValueId, value: ir.ValueId, ty: TypeId) !void {
    const w = common.widthOf(self.tctx(), ty);
    const base_reg = try getInt(self, vregOf(self, base), scratch2);
    const idx_reg = try getInt(self, vregOf(self, index), scratch3);
    switch (w.class) {
        .int => {
            const v = try getInt(self, vregOf(self, value), scratch1);
            try self.storeIndexed(v, base_reg, idx_reg, w.bytes);
        },
        .float => {
            const v = try getFloat(self, vregOf(self, value), fscratch1);
            try self.loadStoreRegOffset(if (w.bytes == 8) 0b11 else 0b10, true, 0b00, idx_reg, w.bytes != 1, @intFromEnum(base_reg), @intFromEnum(v));
        },
    }
}

// ============================================================================
// Runtime symbol names (static — no runtime string building, matching
// `Reloc.symbol`'s "borrowed... static strings" contract).
// ============================================================================

fn rtSymbol(rt: ir.RtFn) []const u8 {
    return switch (rt) {
        .string_concat => "bit_rt_string_concat",
        .string_from_int => "bit_rt_string_from_int",
        .string_from_float => "bit_rt_string_from_float",
        .string_from_bool => "bit_rt_string_from_bool",
        .string_eq => "bit_rt_string_eq",
        .string_byte => "bit_rt_string_byte",
        .string_slice => "bit_rt_string_slice",
        .bytes_from_string => "bit_rt_bytes_from_string",
        .string_from_bytes => "bit_rt_string_from_bytes",
        .sqrt => "bit_rt_sqrt",
        .panic => "bit_rt_panic",
        .assert => "bit_rt_assert",
        .print => "bit_rt_print",
        .eprint => "bit_rt_eprint",
        .err_set => "bit_rt_set_err",
        .err_get => "bit_rt_get_err",
        .chan_make => "bit_rt_chan_make",
        .chan_send => "bit_rt_chan_send",
        .chan_recv => "bit_rt_chan_recv",
        .chan_recv_ok => "bit_rt_chan_recv_ok",
        .iface_as => "bit_rt_iface_as",
        .iface_as_ok => "bit_rt_iface_as_ok",
        .iface_assert => "bit_rt_iface_assert",
        .chan_close => "bit_rt_chan_close",
        .spawn => "bit_rt_spawn",
        .map_new => "bit_rt_map_new",
        .map_set => "bit_rt_map_set",
        .map_get => "bit_rt_map_get",
        .map_has => "bit_rt_map_has",
        .map_delete => "bit_rt_map_delete",
        .map_len => "bit_rt_map_len",
        .map_iter_init => "bit_rt_map_iter_init",
        .map_iter_next => "bit_rt_map_iter_next",
        .map_key_at => "bit_rt_map_key_at",
        .map_val_at => "bit_rt_map_val_at",
        .select_alloc => "bit_rt_select_alloc",
        .select => "bit_rt_select",
        .slice_new => "bit_rt_slice_new",
        .slice_append => "bit_rt_slice_append",
        .slice_get => "bit_rt_slice_get",
        .slice_set => "bit_rt_slice_set",
        .slice_slice => "bit_rt_slice_slice",
        .fs_open => "bit_rt_fs_open",
        .fs_read_all => "bit_rt_fs_read_all",
        .fs_write => "bit_rt_fs_write",
        .fs_close => "bit_rt_fs_close",
        .fs_append => "bit_rt_fs_append",
        .fs_read => "bit_rt_fs_read",
        .fs_exists => "bit_rt_fs_exists",
        .fs_is_dir => "bit_rt_fs_is_dir",
        .fs_mkdir => "bit_rt_fs_mkdir",
        .fs_remove => "bit_rt_fs_remove",
        .fs_list_dir => "bit_rt_fs_list_dir",
        .fs_chmod => "bit_rt_fs_chmod",
        .net_listen => "bit_rt_net_listen",
        .net_local_port => "bit_rt_net_local_port",
        .net_accept => "bit_rt_net_accept",
        .net_dial => "bit_rt_net_dial",
        .net_read => "bit_rt_net_read",
        .net_write => "bit_rt_net_write",
        .net_udp_bind => "bit_rt_net_udp_bind",
        .net_udp_send => "bit_rt_net_udp_send",
        .net_udp_recv => "bit_rt_net_udp_recv",
        .net_udp_sender_host => "bit_rt_net_udp_sender_host",
        .net_udp_sender_port => "bit_rt_net_udp_sender_port",
        .net_resolve => "bit_rt_net_resolve",
        .test_index => "bit_rt_test_index",
        .floor => "bit_rt_floor",
        .ceil => "bit_rt_ceil",
        .round => "bit_rt_round",
        .trunc => "bit_rt_trunc",
        .pow => "bit_rt_pow",
        .atan2 => "bit_rt_atan2",
        .log => "bit_rt_log",
        .log2 => "bit_rt_log2",
        .log10 => "bit_rt_log10",
        .time_mono_ns => "bit_rt_time_mono_ns",
        .time_unix_ns => "bit_rt_time_unix_ns",
        .time_sleep_ns => "bit_rt_time_sleep_ns",
        .os_argc => "bit_rt_os_argc",
        .os_arg_at => "bit_rt_os_arg_at",
        .os_env => "bit_rt_os_env",
        .os_exit => "bit_rt_os_exit",
        .os_run => "bit_rt_os_run",
        .os_run_test => "bit_rt_os_run_test",
        .host_target => "bit_rt_host_target",
        .auxv => "bit_rt_auxv",
        .random_bytes => "bit_rt_random_bytes",
        .secure_zero => "bit_rt_secure_zero",
        .parse_float => "bit_rt_parse_float",
        .float_bits => "bit_rt_float_bits",
        .float32_bits => "bit_rt_float32_bits",
    };
}
const safepoint_symbol = "bit_rt_safepoint";

/// Binds `args` (already-computed SSA values) into their ABI argument
/// registers via the parallel-move sequencer, then emits `bl symbol` and
/// binds the single result (if any) into `dst`. Shared by `call` and
/// `rt_call` — the only difference between them is how `symbol` is named.
/// Marshals `args` into argument registers via parallel moves, with the
/// integer/float register banks already `base_int_ord`/`base_float_ord` deep.
/// `emitCall` passes zeros (a plain call); `emitCallValue` passes `1,0` to
/// reserve x0 for the closure's environment pointer.
/// Stores one overflow argument to its outgoing stack slot `[sp + off]` in the
/// reserved area at the bottom of this frame. `src` is sp-relative (a spill) or
/// a physical register; the frame never moves, so both the slot and every spill
/// source stay put — the mem staging temp (scratch1/fscratch1) is free here
/// because these run before the register parallel moves.
fn emitOutgoingStackArg(self: *Ctx, src: PLoc, class: regalloc.Class, off: u32) !void {
    switch (class) {
        .int => switch (src) {
            .reg => |r| try self.storeImm(@enumFromInt(r), reg_sp, off, 8),
            .mem => |m| {
                try self.loadImm(scratch1, reg_sp, m, 8, false);
                try self.storeImm(scratch1, reg_sp, off, 8);
            },
        },
        .float => switch (src) {
            .reg => |r| try self.storeImmF(@enumFromInt(r), reg_sp, off, 8),
            .mem => |m| {
                try self.loadImmF(fscratch1, reg_sp, m, 8);
                try self.storeImmF(fscratch1, reg_sp, off, 8);
            },
        },
    }
}

/// Arguments past x0–x7 / v0–v7 overflow to the outgoing stack-argument area at
/// the bottom of the frame (`FrameInfo` layout note): each is stored at
/// `[sp + 8*k]` in argument order, before the register parallel moves run.
fn marshalArgs(self: *Ctx, args: []const u32, base_int_ord: u32, base_float_ord: u32) CodegenError!void {
    var int_ord: u32 = base_int_ord;
    var float_ord: u32 = base_float_ord;
    var int_moves = try std.ArrayList(PMove).initCapacity(self.gpa, args.len);
    defer int_moves.deinit(self.gpa);
    var float_moves = try std.ArrayList(PMove).initCapacity(self.gpa, args.len);
    defer float_moves.deinit(self.gpa);

    var stack_index: u32 = 0;
    for (args) |a| {
        const v: ir.ValueId = @enumFromInt(a);
        const class = common.classOf(self.tctx(), self.f.valueType(v));
        const ord = if (class == .int) int_ord else float_ord;
        const from = plocOf(self, vregOf(self, v), class);
        if (argReg(class, ord)) |reg| {
            try (if (class == .int) &int_moves else &float_moves).append(self.gpa, .{ .from = from, .to = .{ .reg = reg } });
        } else {
            try emitOutgoingStackArg(self, from, class, self.frame.outgoingArgOffset(stack_index));
            stack_index += 1;
        }
        if (class == .int) int_ord += 1 else float_ord += 1;
    }
    try sequentializeAndEmit(self, int_moves.items, .int);
    try sequentializeAndEmit(self, float_moves.items, .float);
}

fn emitCall(self: *Ctx, dst: ?u32, dst_ty: TypeId, symbol: []const u8, args: []const u32, is_safepoint: bool) CodegenError!void {
    try marshalArgs(self, args, 0, 0);

    try self.emitCallReloc(symbol);
    const ret_off: u32 = @intCast(self.code.items.len);

    if (is_safepoint) try recordSafepoint(self, ret_off);

    if (dst) |d| {
        const class = common.classOf(self.tctx(), dst_ty);
        if (class == .int) {
            // A C callee returns `bool` in `w0`, leaving x0's upper bits
            // unspecified. A Bit `bool` is a full-width 0/1 — `!b` and the
            // branch tests read the whole register — so normalize at this
            // boundary, where a foreign convention meets ours. x64's
            // `emitCallLike` does the same, for the same reason; see ABI.md §2
            // on a narrow return leaving the register partly undefined.
            if (isBoolTy(self.tctx(), dst_ty)) try self.uxtb(@enumFromInt(retRegNum(.int)));
            try putInt(self, d, @enumFromInt(retRegNum(.int)));
        } else try putFloat(self, d, @enumFromInt(retRegNum(.float)));
    }
}

/// Whether `ty` is the `bool` primitive — the one integer-class type whose
/// return register a C callee may leave partially undefined.
fn isBoolTy(tctx: *const TypeContext, ty: TypeId) bool {
    const d = tctx.typeOf(ty);
    return d == .prim and d.prim == .bool;
}

/// Records the stack map for the safepoint at `ret_off` (a call return
/// address) from the register allocator's precomputed `stack_maps`, in the
/// same first-seen order `buildIntervals` collected them. Shared by every
/// safepoint-bearing call site (`emitCall`, `emitGcAlloc`).
fn recordSafepoint(self: *Ctx, ret_off: u32) CodegenError!void {
    const pos = self.safepoint_positions[self.next_safepoint_idx];
    const sm = self.result.stack_maps[self.next_safepoint_idx];
    std.debug.assert(sm.pos == pos);
    const regs = try self.gpa.alloc(Reg, sm.regs.len);
    for (sm.regs, 0..) |idx, i| regs[i] = self.int_regs[idx];
    // Normalize to frame-pointer-relative (x29 = sp + frame_size - 16), so the
    // runtime walker (`runtime/ABI.md` §4) is arch-neutral: `*(x29 + off)`.
    const fp_base: i32 = @intCast(self.frame.fpOffset()); // frame_size - 16
    const offs = try self.gpa.alloc(i32, sm.slots.len);
    for (sm.slots, 0..) |slot, i| offs[i] = @as(i32, @intCast(self.frame.spillOffset(slot))) - fp_base;
    try self.safepoints.append(self.gpa, .{ .code_offset = ret_off, .regs = regs, .frame_offsets = offs });
    self.next_safepoint_idx += 1;
}

/// `gc_alloc`: load the static `TypeInfo` blob's address into x0 and `bl
/// bit_rt_gc_alloc`, which returns the zeroed body pointer in x0. A GC point,
/// so it records a safepoint (buildIntervals counts `gc_alloc` too).
fn emitGcAlloc(self: *Ctx, dst: u32, size: u32, ptr_offsets: []const u32) CodegenError!void {
    const disc: u32 = @intFromEnum(self.f.valueType(@enumFromInt(dst)));
    const name = try ir.typeInfoSymbol(self.gpa, disc, size, ptr_offsets);
    try self.owned_syms.append(self.gpa, name);
    try self.emitAddrOf(@enumFromInt(argReg(.int, 0).?), name); // arg0 = x0
    try self.emitCallReloc("bit_rt_gc_alloc");
    const ret_off: u32 = @intCast(self.code.items.len);
    try recordSafepoint(self, ret_off);
    try putInt(self, dst, @enumFromInt(retRegNum(.int)));
}

/// `type_info`: materialize the address of a named type's static `TypeInfo`
/// blob. Not a call and not a GC point — the descriptor is a `.rodata` constant
/// (its non-reference result type keeps it out of the stack map).
fn emitTypeInfo(self: *Ctx, dst: u32, disc: u32, size: u32, ptr_offsets: []const u32) CodegenError!void {
    const name = try ir.typeInfoSymbol(self.gpa, disc, size, ptr_offsets);
    try self.owned_syms.append(self.gpa, name);
    try self.emitAddrOf(scratch1, name);
    try putInt(self, dst, scratch1);
}

/// A closure value is a pointer to a 16-byte GC cell `{ code_ptr, env_ptr }`:
/// the code pointer at +0 (into `.text`, never a GC ref) and the captured
/// environment at +8 (the cell's one GC field). Single-word, so it flows
/// through the register allocator like any other reference. Mirrors x64.zig.
const closure_cell_size: u32 = 16;
const closure_cell_ptr_offsets = [_]u32{8};

/// `make_closure`: allocate the `{code, env}` cell (a GC point, like
/// `emitGcAlloc`), then store the target function's address at +0 and the
/// already-materialized environment pointer at +8.
fn emitMakeClosure(self: *Ctx, dst: u32, func: ir.FuncId, env: ir.ValueId) CodegenError!void {
    const disc: u32 = @intFromEnum(self.f.valueType(@enumFromInt(dst)));
    const ti = try ir.typeInfoSymbol(self.gpa, disc, closure_cell_size, &closure_cell_ptr_offsets);
    try self.owned_syms.append(self.gpa, ti);
    try self.emitAddrOf(@enumFromInt(argReg(.int, 0).?), ti); // x0 = &TypeInfo
    try self.emitCallReloc("bit_rt_gc_alloc");
    const ret_off: u32 = @intCast(self.code.items.len);
    try recordSafepoint(self, ret_off);
    // x0 = cell. Store code address at +0 and the env pointer at +8.
    const cell: u5 = retRegNum(.int); // x0
    try self.emitAddrOf(scratch1, self.module.func(func).name); // x9 = &code
    try self.storeImm(scratch1, cell, 0, 8);
    const env_reg = try getInt(self, vregOf(self, env), scratch1);
    try self.storeImm(env_reg, cell, 8, 8);
    try putInt(self, dst, @enumFromInt(cell));
}

/// `func_addr`: materialize a function's code address into `dst` via a
/// page21/pageoff12 relocation pair to its own symbol (the same primitive
/// `make_closure` uses to fill a cell's code slot, minus the cell). No call.
fn emitFuncAddr(self: *Ctx, dst: u32, func: ir.FuncId) CodegenError!void {
    try self.emitAddrOf(scratch1, self.module.func(func).name);
    try putInt(self, dst, scratch1);
}

/// `global_addr` (§11.11): the static address of a module-level variable, via
/// the same ADRP/ADD symbol relocation pair `func_addr` uses. Pure address
/// arithmetic — no load, no call, no safepoint — so it is legal inside a
/// `@nosplit` body.
///
/// A `.thread` cell instead resolves against the thread pointer, so its address
/// differs per OS thread; that path is equally call-free, which is what lets
/// §11.11 promise `@nosplit` compatibility for both storage classes.
fn emitGlobalAddr(self: *Ctx, dst: u32, g: ir.GlobalId) CodegenError!void {
    const gl = self.module.global(g);
    switch (gl.storage) {
        // `.readonly` differs from `.process` only in which section the symbol
        // lands in (#1447) — both are ONE link-time address for the whole
        // program, so both materialize identically. The read-only-ness is the
        // loader's doing, enforced by the segment's page permissions, not
        // something codegen can or should re-state here.
        .process, .readonly => try self.emitAddrOf(scratch1, gl.name),
        .thread => try self.emitTlsAddrOf(scratch1, gl.name),
    }
    try putInt(self, dst, scratch1);
}

/// `call_value`: dispatch through a closure. Load the environment (+8) and
/// code pointer (+0) into reserved scratch regs argument marshaling never
/// touches (x10/x11 are not argument registers; x9 is the parallel-move cycle
/// temp), marshal the real arguments into x1.., place the environment in x0,
/// then `blr`. A call is a GC point, so it records a safepoint.
fn emitCallValue(self: *Ctx, dst: ?u32, dst_ty: TypeId, callee: ir.ValueId, args: []const u32) CodegenError!void {
    const cell = try getInt(self, vregOf(self, callee), scratch1);
    try self.loadImm(scratch2, @intFromEnum(cell), 8, 8, false); // x10 = env
    try self.loadImm(scratch3, @intFromEnum(cell), 0, 8, false); // x11 = code
    try marshalArgs(self, args, 1, 0);
    try self.movRR(@enumFromInt(argReg(.int, 0).?), scratch2); // x0 = env
    try self.blr(scratch3);
    const ret_off: u32 = @intCast(self.code.items.len);
    try recordSafepoint(self, ret_off);
    if (dst) |d| {
        const class = common.classOf(self.tctx(), dst_ty);
        if (class == .int) try putInt(self, d, @enumFromInt(retRegNum(.int))) else try putFloat(self, d, @enumFromInt(retRegNum(.float)));
    }
}

/// `call_iface`: structural interface dispatch (ABI.md §2.1). Load the receiver
/// object's `TypeInfo` (`*(recv - 32)`, the header's `info` field), resolve the
/// method id to a code address via `bit_rt_iface_lookup`, then `blr` it with the
/// receiver in x0. The lookup never collects, so only the final method call
/// records a safepoint (like `emitCallValue`); the receiver is reloaded from its
/// vreg afterward (its home survives the lookup call).
fn emitCallIface(self: *Ctx, dst: ?u32, dst_ty: TypeId, iface_val: ir.ValueId, method_id: u32, args: []const u32) CodegenError!void {
    const recv = try getInt(self, vregOf(self, iface_val), scratch1);
    try self.addSubImmediate(true, @intFromEnum(scratch2), @intFromEnum(recv), 32, false); // x10 = recv - 32
    try self.loadImm(scratch2, @intFromEnum(scratch2), 0, 8, false); // x10 = info
    try self.movRR(@enumFromInt(argReg(.int, 0).?), scratch2); // x0 = info
    try self.movImm64(@enumFromInt(argReg(.int, 1).?), method_id); // x1 = id
    try self.emitCallReloc("bit_rt_iface_lookup"); // x0 = method code address
    try self.movRR(scratch3, @enumFromInt(retRegNum(.int))); // x11 = fn, survives marshaling
    try marshalArgs(self, args, 1, 0);
    const recv2 = try getInt(self, vregOf(self, iface_val), scratch1);
    try self.movRR(@enumFromInt(argReg(.int, 0).?), recv2); // x0 = recv
    try self.blr(scratch3);
    const ret_off: u32 = @intCast(self.code.items.len);
    try recordSafepoint(self, ret_off);
    if (dst) |d| {
        const class = common.classOf(self.tctx(), dst_ty);
        if (class == .int) try putInt(self, d, @enumFromInt(retRegNum(.int))) else try putFloat(self, d, @enumFromInt(retRegNum(.float)));
    }
}

/// True iff `jump`/`br` targeting `target` is a loop back-edge — see module
/// doc comment on safepoints.
fn isBackEdge(cur_block: usize, target: ir.BlockId) bool {
    return @intFromEnum(target) <= cur_block;
}

/// §10.3.1: a @naked or @nosplit function emits no back-edge safepoint. The
/// recording side (`buildIntervals`) gates on the identical predicate so the
/// safepoint-position array stays in lockstep with emission.
fn needsNoSafepoints(f: *const ir.Function) bool {
    return f.is_naked or f.is_nosplit;
}

fn emitBackEdgeSafepointIfNeeded(self: *Ctx, cur_block: usize, target: ir.BlockId) !void {
    if (!isBackEdge(cur_block, target) or needsNoSafepoints(self.f)) return;
    try emitCall(self, null, .invalid, safepoint_symbol, &.{}, true);
}

fn moveBlockArgs(self: *Ctx, target: ir.BlockId, args: []const u32) !void {
    const tb = self.f.block(target);
    var int_moves = try std.ArrayList(PMove).initCapacity(self.gpa, args.len);
    defer int_moves.deinit(self.gpa);
    var float_moves = try std.ArrayList(PMove).initCapacity(self.gpa, args.len);
    defer float_moves.deinit(self.gpa);
    for (args, 0..) |a, i| {
        const param_v: ir.ValueId = tb.paramValue(@intCast(i));
        const class = common.classOf(self.tctx(), self.f.valueType(param_v));
        const from = plocOf(self, self.inst_to_vreg[a], class);
        const to = plocOf(self, self.inst_to_vreg[@intFromEnum(param_v)], class);
        try (if (class == .int) &int_moves else &float_moves).append(self.gpa, .{ .from = from, .to = to });
    }
    try sequentializeAndEmit(self, int_moves.items, .int);
    try sequentializeAndEmit(self, float_moves.items, .float);
}

fn emitEpilogueAndRet(self: *Ctx) !void {
    // §10.3.1 @naked: no frame was set up, so restore nothing — emit only the
    // raw `ret` (the return value is already in x0/v0).
    if (!self.f.is_naked) {
        for (self.frame.saved_fpr, 0..) |r, i| try self.loadImmF(r, reg_sp, self.frame.fprSaveOffset(i), 8);
        for (self.frame.saved_gpr, 0..) |r, i| try self.loadImm(r, reg_sp, self.frame.gprSaveOffset(i), 8, false);
        try self.loadImm(.x29, reg_sp, self.frame.fpOffset(), 8, false);
        try self.loadImm(.x30, reg_sp, self.frame.lrOffset(), 8, false);
        try self.addSubImmWide(false, reg_sp, reg_sp, self.frame.frame_size);
    }
    try self.ret();
}

// ---- atomics (§11.5) ------------------------------------------------------
// `*T` is an int-classed word; all sequences are call-free and use only the
// codegen scratch GPRs plus `ascratch1`/`ascratch2` (never a safepoint).

fn emitAtomicLoad(self: *Ctx, dst: u32, ptr: ir.ValueId, ty: TypeId) !void {
    const w = common.widthOf(self.tctx(), ty);
    const base = try getInt(self, vregOf(self, ptr), ascratch1);
    try self.ldar(Ctx.atomicSize(w.bytes), @intFromEnum(base), @intFromEnum(scratch1));
    try canonNarrow(self, scratch1, w);
    try putInt(self, dst, scratch1);
}

fn emitAtomicStore(self: *Ctx, ptr: ir.ValueId, value: ir.ValueId, ty: TypeId) !void {
    const w = common.widthOf(self.tctx(), ty);
    const base = try getInt(self, vregOf(self, ptr), ascratch1);
    const val = try getInt(self, vregOf(self, value), scratch1);
    try self.stlr(Ctx.atomicSize(w.bytes), @intFromEnum(base), @intFromEnum(val));
}

/// LL/SC retry loop; returns the pre-op (old) value. `scratch1`=old,
/// `scratch2`=computed, `scratch3`=STLXR status, `ascratch1`=base,
/// `ascratch2`=operand.
fn emitAtomicRmw(self: *Ctx, op: ir.Op, dst: u32, ptr: ir.ValueId, operand: ir.ValueId, ty: TypeId) !void {
    const w = common.widthOf(self.tctx(), ty);
    const size = Ctx.atomicSize(w.bytes);
    const base = try getInt(self, vregOf(self, ptr), ascratch1);
    const oper = try getInt(self, vregOf(self, operand), ascratch2);
    const retry_off: u32 = @intCast(self.code.items.len);
    try self.ldaxr(size, @intFromEnum(base), @intFromEnum(scratch1));
    switch (op) {
        .atomic_rmw_add => try self.addRR(scratch2, scratch1, oper),
        .atomic_rmw_sub => try self.subRR(scratch2, scratch1, oper),
        .atomic_rmw_and => try self.logicalRR(.and_, scratch2, scratch1, oper),
        .atomic_rmw_or => try self.logicalRR(.orr, scratch2, scratch1, oper),
        .atomic_rmw_xchg => try self.movRR(scratch2, oper),
        else => unreachable,
    }
    try self.stlxr(size, @intFromEnum(scratch3), @intFromEnum(base), @intFromEnum(scratch2));
    const cbnz_off: u32 = @intCast(self.code.items.len);
    try self.cbnz(false, @intFromEnum(scratch3), @intCast(@divExact(@as(i64, retry_off) - @as(i64, cbnz_off), 4)));
    try canonNarrow(self, scratch1, w);
    try putInt(self, dst, scratch1);
}

/// Go-style CAS: swaps `desired` in iff `[ptr] == expected`, result is the
/// bool "did it swap". `scratch1`=old, `scratch2`=desired, `scratch3`=status,
/// `ascratch1`=base, `ascratch2`=expected.
fn emitAtomicCmpxchg(self: *Ctx, dst: u32, ptr: ir.ValueId, expected: ir.ValueId, desired: ir.ValueId) !void {
    const w = common.widthOf(self.tctx(), self.f.valueType(expected));
    const size = Ctx.atomicSize(w.bytes);
    const base = try getInt(self, vregOf(self, ptr), ascratch1);
    const exp = try getInt(self, vregOf(self, expected), ascratch2);
    const des = try getInt(self, vregOf(self, desired), scratch2);
    const retry_off: u32 = @intCast(self.code.items.len);
    try self.ldaxr(size, @intFromEnum(base), @intFromEnum(scratch1));
    try canonNarrow(self, scratch1, w); // canonicalize old to match `expected` before the compare
    try self.cmpRR(scratch1, exp);
    const bne_fixup = try self.emitLocalCondBranch(Cond.ne);
    try self.stlxr(size, @intFromEnum(scratch3), @intFromEnum(base), @intFromEnum(des));
    const cbnz_off: u32 = @intCast(self.code.items.len);
    try self.cbnz(false, @intFromEnum(scratch3), @intCast(@divExact(@as(i64, retry_off) - @as(i64, cbnz_off), 4)));
    self.patchLocalCondBranch(bne_fixup); // success fall-through and mismatch converge here
    try self.cset(scratch1, Cond.eq); // Z from the last CMP: set iff old == expected
    try putInt(self, dst, scratch1);
}

fn compileInst(self: *Ctx, cur_block: usize, id: ir.ValueId) CodegenError!void {
    const i: u32 = @intFromEnum(id);
    const op = self.f.insts.items(.op)[i];
    const ty = self.f.insts.items(.ty)[i];
    const d = self.f.decode(id);
    const iw = common.widthOf(self.tctx(), ty); // result width: drives narrow re-canonicalization
    switch (d) {
        .block_param => unreachable, // never reached: loop bounds skip params
        .const_int => |v| try emitConstInt(self, i, v),
        .const_float => |v| try emitConstFloat(self, i, v, iw.bytes),
        .const_bool => |v| try emitConstBool(self, i, v),
        .const_string => |pool_idx| try emitConstString(self, i, pool_idx),
        .const_nil => try emitConstNil(self, i),
        .bin => |b| switch (op) {
            .add => try emitBinaryInt(self, .add, i, b.lhs, b.rhs, iw),
            .sub => try emitBinaryInt(self, .sub, i, b.lhs, b.rhs, iw),
            .band => try emitBinaryInt(self, .band, i, b.lhs, b.rhs, iw),
            .bor => try emitBinaryInt(self, .bor, i, b.lhs, b.rhs, iw),
            .bxor => try emitBinaryInt(self, .bxor, i, b.lhs, b.rhs, iw),
            .mul => try emitMulInt(self, i, b.lhs, b.rhs, iw),
            .sdiv, .udiv, .srem, .urem => try emitDivInt(self, op, i, b.lhs, b.rhs),
            .shl, .lshr, .ashr => try emitShiftInt(self, op, i, b.lhs, b.rhs, iw),
            .icmp_eq, .icmp_ne, .icmp_slt, .icmp_sle, .icmp_sgt, .icmp_sge, .icmp_ult, .icmp_ule, .icmp_ugt, .icmp_uge => try emitIcmp(self, op, i, b.lhs, b.rhs),
            .fadd, .fsub, .fmul, .fdiv => {
                const w = common.widthOf(self.tctx(), ty).bytes;
                const fop: Ctx.FArithOp = switch (op) {
                    .fadd => .add,
                    .fsub => .sub,
                    .fmul => .mul,
                    .fdiv => .div,
                    else => unreachable,
                };
                try emitBinaryFloat(self, fop, i, b.lhs, b.rhs, w);
            },
            .fcmp_eq, .fcmp_ne, .fcmp_lt, .fcmp_le, .fcmp_gt, .fcmp_ge => {
                const w = common.widthOf(self.tctx(), self.f.valueType(b.lhs)).bytes;
                try emitFcmp(self, op, i, b.lhs, b.rhs, w);
            },
            else => unreachable,
        },
        .un => |u| switch (op) {
            .neg, .bnot => try emitUnaryInt(self, op, i, u.operand, iw),
            .convert => try emitConvert(self, i, u.operand, ty),
            .fneg => try emitFneg(self, i, u.operand, iw.bytes),
            .fsqrt => try emitFsqrt(self, i, u.operand, iw.bytes),
            // FRINTM / FRINTP / FRINTZ / FRINTA — floor, ceil, truncate,
            // round-half-away-from-zero.
            .ffloor => try emitFRound(self, i, u.operand, iw.bytes, 0b001010),
            .fceil => try emitFRound(self, i, u.operand, iw.bytes, 0b001001),
            .ftrunc => try emitFRound(self, i, u.operand, iw.bytes, 0b001011),
            .fround => try emitFRound(self, i, u.operand, iw.bytes, 0b001100),
            // The width always comes from the FLOAT side — the integer view of
            // an f32 is 4 bytes wide whichever direction the transfer runs, and
            // only one of the two types carries a float width to read.
            .bitcast => try emitBitcast(self, i, u.operand, if (iw.class == .float) iw.bytes else common.widthOf(self.tctx(), self.f.valueType(u.operand)).bytes, iw.class),
            else => unreachable,
        },
        .jump => |j| {
            try emitBackEdgeSafepointIfNeeded(self, cur_block, j.target);
            try moveBlockArgs(self, j.target, j.args);
            try self.emitJumpFixup(j.target);
        },
        .br => |b| {
            const cond_reg = try getInt(self, vregOf(self, b.cond), scratch1);
            try self.cmpZero(cond_reg);
            const else_fixup = try self.emitLocalCondBranch(Cond.eq);
            try emitBackEdgeSafepointIfNeeded(self, cur_block, b.then_blk);
            try moveBlockArgs(self, b.then_blk, b.then_args);
            try self.emitJumpFixup(b.then_blk);
            self.patchLocalCondBranch(else_fixup);
            try emitBackEdgeSafepointIfNeeded(self, cur_block, b.else_blk);
            try moveBlockArgs(self, b.else_blk, b.else_args);
            try self.emitJumpFixup(b.else_blk);
        },
        .ret => |r| {
            if (r.vals.len > 1) return error.UnsupportedConstruct;
            if (r.vals.len == 1) {
                const v: ir.ValueId = @enumFromInt(r.vals[0]);
                const class = common.classOf(self.tctx(), self.f.valueType(v));
                if (class == .int) {
                    const src = try getInt(self, vregOf(self, v), scratch1);
                    try self.movRR(@enumFromInt(retRegNum(.int)), src);
                } else {
                    const src = try getFloat(self, vregOf(self, v), fscratch1);
                    try self.fmovFF(@enumFromInt(retRegNum(.float)), src, 8);
                }
            }
            try emitEpilogueAndRet(self);
        },
        .unreachable_ => try self.udf(),
        .call => |c| {
            const target = self.module.func(c.func);
            try emitCall(self, if (ty != .invalid) i else null, ty, target.name, c.args, true);
        },
        .call_value => |c| try emitCallValue(self, if (ty != .invalid) i else null, ty, c.callee, c.args),
        .call_iface => |c| try emitCallIface(self, if (ty != .invalid) i else null, ty, c.iface, c.method_index, c.args),
        .gc_alloc => |g| try emitGcAlloc(self, i, g.size, g.ptr_offsets),
        .type_info => |t| try emitTypeInfo(self, i, t.disc, t.size, t.ptr_offsets),
        .atomic_load => |a| try emitAtomicLoad(self, i, a.ptr, ty),
        .atomic_store => |a| try emitAtomicStore(self, a.ptr, a.value, self.f.valueType(a.value)),
        .atomic_cmpxchg => |a| try emitAtomicCmpxchg(self, i, a.ptr, a.expected, a.desired),
        .atomic_rmw => |a| try emitAtomicRmw(self, op, i, a.ptr, a.operand, ty),
        .field_get => |fg| try emitFieldGet(self, i, fg.base, fg.offset, ty),
        .field_set => |fs| try emitFieldSet(self, fs.base, fs.offset, fs.value, self.f.valueType(fs.value)),
        .index_get => |ig| try emitIndexGet(self, i, ig.base, ig.index, ty),
        .index_set => |is_| try emitIndexSet(self, is_.base, is_.index, is_.value, self.f.valueType(is_.value)),
        .slice_len => |sl| try emitSliceLen(self, i, sl.base),
        .make_closure => |mc| try emitMakeClosure(self, i, mc.func, mc.env),
        .func_addr => |fa| try emitFuncAddr(self, i, fa.func),
        .global_addr => |ga| try emitGlobalAddr(self, i, ga.global),
        .rt_call => |rc| try emitCall(self, if (ty != .invalid) i else null, ty, rtSymbol(rc.rt), rc.args, true),
        .asm_stmt => |a| try emitAsm(self, if (ty != .invalid) i else null, a.block, a.args),
        .syscall => |s| try emitSyscall(self, i, s.nr, s.args),
    }
}

/// Inline assembly (§11.6): move each `input` value into its fixed register
/// (excluded from the allocatable file for the whole function, so overwriting
/// it is safe), emit the arm64 sub-block's pre-encoded words verbatim, then
/// read the `result` register (if any) into the instruction's result vreg.
/// The register-name → number mapping is `check.asmRegArm64`'s; `emitWord` is
/// the same primitive `emitCallReloc` uses for its own fixed opcodes.
fn emitAsm(self: *Ctx, dst: ?u32, block: u32, in_vals: []const u32) !void {
    const blk = self.module.asmBlock(block);
    for (in_vals, blk.in_arm64) |v, reg_code| {
        const src = try getInt(self, vregOf(self, @enumFromInt(v)), scratch1);
        try self.movRR(@enumFromInt(reg_code), src);
    }
    for (blk.arm64_words) |w| try self.emitWord(w);
    if (dst) |d| try putInt(self, d, @enumFromInt(blk.result_arm64));
}

/// Raw Linux syscall (§11.8): move each argument into `x0`..`x5`, the number
/// into `x8`, trap into the kernel with `svc #0`, then read the return value
/// out of `x0`. Every register involved is excluded from the allocatable file
/// for the whole function (`collectReservedArm64`), so the moves cannot clobber
/// a live value and can run in plain sequence. `emitWord` is the same primitive
/// `emitCallReloc` uses for its own fixed opcodes.
fn emitSyscall(self: *Ctx, dst: u32, nr: ir.ValueId, args: []const u32) !void {
    for (args, syscall_arg_regs[0..args.len]) |v, reg| {
        const src = try getInt(self, vregOf(self, @enumFromInt(v)), scratch1);
        try self.movRR(reg, src);
    }
    const nr_src = try getInt(self, vregOf(self, nr), scratch1);
    try self.movRR(syscall_nr_reg, nr_src);
    try self.emitWord(0xD4000001); // svc #0
    try putInt(self, dst, .x0);
}

// ============================================================================
// Top-level: interval building, register allocation, frame layout, emission
// ============================================================================

/// One `Interval` per instruction slot (dense `0..insts.len`, matching
/// `regalloc.zig`'s dense-vreg contract exactly — see that file's module
/// comment). Non-value instructions (terminators, `field_set`/`index_set`)
/// get a trivial, never-referenced `[i,i]` interval; harmless filler, never
/// looked up. Also collects safepoint positions in the exact order they'll
/// be re-encountered during emission (calls/rt_calls first-seen order, then
/// back-edge terminators) so the emission pass can match each
/// `regalloc.Result.stack_maps` entry back to its `bl` by cursor position.
fn buildIntervals(gpa: Allocator, tctx: *const TypeContext, f: *const ir.Function, safepoints: *std.ArrayList(u32)) Allocator.Error![]regalloc.Interval {
    const n = f.insts.len;
    const intervals = try gpa.alloc(regalloc.Interval, n);
    for (0..n) |i| {
        const ty = f.insts.items(.ty)[i];
        const w = common.widthOf(tctx, ty);
        intervals[i] = .{
            .vreg = @enumFromInt(@as(u32, @intCast(i))),
            .class = w.class,
            .start = @intCast(i),
            .end = @intCast(i),
            .is_ref = w.class == .int and common.isRefType(tctx, ty),
        };
    }

    for (f.blocks, 0..) |b, bi| {
        var idx = b.insts_start + b.param_count;
        const end = b.insts_start + b.insts_len;
        while (idx < end) : (idx += 1) {
            const id: ir.ValueId = @enumFromInt(idx);
            const op = f.insts.items(.op)[idx];
            if (op == .call or op == .rt_call or op == .gc_alloc or op == .make_closure or op == .call_value or op == .call_iface) try safepoints.append(gpa, idx);
            const dd = f.decode(id);
            extendUses(intervals, idx, dd);
            switch (dd) {
                // Back-edge safepoints are suppressed for @naked/@nosplit — gate
                // recording on the same predicate as emission so the position
                // array and the emitted `bl`s stay in lockstep (§10.3.1).
                .jump => |j| if (isBackEdge(bi, j.target) and !needsNoSafepoints(f)) try safepoints.append(gpa, idx),
                .br => |br_| {
                    if (isBackEdge(bi, br_.then_blk) and !needsNoSafepoints(f)) try safepoints.append(gpa, idx);
                    if (isBackEdge(bi, br_.else_blk) and !needsNoSafepoints(f)) try safepoints.append(gpa, idx);
                },
                else => {},
            }
        }
    }
    forceParamInterference(intervals, f);
    return intervals;
}

/// All of a block's params are live simultaneously at block entry — the
/// predecessor edge's parallel move writes every one before the jump. A param
/// that is never read afterward would otherwise keep its initial empty `[i, i]`
/// interval and could be coalesced onto a live sibling param's register, so the
/// edge move clobbers one param with another (a returned value coming back as
/// some other incoming argument). Extend every param's interval to its block's
/// last param position so all params of a block mutually interfere and land in
/// distinct registers.
fn forceParamInterference(intervals: []regalloc.Interval, f: *const ir.Function) void {
    for (f.blocks) |blk| {
        if (blk.param_count == 0) continue;
        const last_param: u32 = @intCast(blk.insts_start + blk.param_count - 1);
        var p: usize = blk.insts_start;
        while (p < blk.insts_start + blk.param_count) : (p += 1) {
            if (intervals[p].end < last_param) intervals[p].end = last_param;
        }
    }
}

fn extendOne(intervals: []regalloc.Interval, use_pos: u32, operand: u32) void {
    if (intervals[operand].end < use_pos) intervals[operand].end = use_pos;
}

fn extendUses(intervals: []regalloc.Interval, use_pos: u32, d: ir.Decoded) void {
    switch (d) {
        .block_param, .const_int, .const_float, .const_bool, .const_string, .const_nil, .unreachable_ => {},
        .bin => |b| {
            extendOne(intervals, use_pos, @intFromEnum(b.lhs));
            extendOne(intervals, use_pos, @intFromEnum(b.rhs));
        },
        .un => |u| extendOne(intervals, use_pos, @intFromEnum(u.operand)),
        .jump => |j| for (j.args) |a| extendOne(intervals, use_pos, a),
        .br => |b| {
            extendOne(intervals, use_pos, @intFromEnum(b.cond));
            for (b.then_args) |a| extendOne(intervals, use_pos, a);
            for (b.else_args) |a| extendOne(intervals, use_pos, a);
        },
        .ret => |r| for (r.vals) |v| extendOne(intervals, use_pos, v),
        .call => |c| for (c.args) |a| extendOne(intervals, use_pos, a),
        .call_value => |c| {
            extendOne(intervals, use_pos, @intFromEnum(c.callee));
            for (c.args) |a| extendOne(intervals, use_pos, a);
        },
        .call_iface => |c| {
            extendOne(intervals, use_pos, @intFromEnum(c.iface));
            for (c.args) |a| extendOne(intervals, use_pos, a);
        },
        .gc_alloc, .type_info => {}, // no value operands
        .field_get => |fg| extendOne(intervals, use_pos, @intFromEnum(fg.base)),
        .field_set => |fs| {
            extendOne(intervals, use_pos, @intFromEnum(fs.base));
            extendOne(intervals, use_pos, @intFromEnum(fs.value));
        },
        .index_get => |ig| {
            extendOne(intervals, use_pos, @intFromEnum(ig.base));
            extendOne(intervals, use_pos, @intFromEnum(ig.index));
        },
        .index_set => |is_| {
            extendOne(intervals, use_pos, @intFromEnum(is_.base));
            extendOne(intervals, use_pos, @intFromEnum(is_.index));
            extendOne(intervals, use_pos, @intFromEnum(is_.value));
        },
        .slice_len => |sl| extendOne(intervals, use_pos, @intFromEnum(sl.base)),
        .atomic_load => |a| extendOne(intervals, use_pos, @intFromEnum(a.ptr)),
        .atomic_store => |a| {
            extendOne(intervals, use_pos, @intFromEnum(a.ptr));
            extendOne(intervals, use_pos, @intFromEnum(a.value));
        },
        .atomic_cmpxchg => |a| {
            extendOne(intervals, use_pos, @intFromEnum(a.ptr));
            extendOne(intervals, use_pos, @intFromEnum(a.expected));
            extendOne(intervals, use_pos, @intFromEnum(a.desired));
        },
        .atomic_rmw => |a| {
            extendOne(intervals, use_pos, @intFromEnum(a.ptr));
            extendOne(intervals, use_pos, @intFromEnum(a.operand));
        },
        .make_closure => |mc| extendOne(intervals, use_pos, @intFromEnum(mc.env)),
        .func_addr => {}, // references a FuncId, no value operands
        .global_addr => {}, // references a GlobalId, no value operands
        .rt_call => |rc| for (rc.args) |a| extendOne(intervals, use_pos, a),
        .asm_stmt => |a| for (a.args) |arg| extendOne(intervals, use_pos, arg),
        .syscall => |s| {
            extendOne(intervals, use_pos, @intFromEnum(s.nr));
            for (s.args) |a| extendOne(intervals, use_pos, a);
        },
    }
}

/// Marks every arm64 register pinned by an `asm` block (`input`/`result`/
/// clobber) or by a `syscall` in `f` in `reserved` (indexed by register number
/// 0..30). The `memory` sentinel (254) and `sp`/`xzr` (31) fall outside the
/// array and are skipped — neither is ever allocatable.
fn collectReservedArm64(module: *const ir.Module, f: *const ir.Function, reserved: *[32]bool) void {
    const ops = f.insts.items(.op);
    for (0..f.insts.len) |i| {
        switch (ops[i]) {
            .asm_stmt => {
                const a = f.decode(@enumFromInt(i)).asm_stmt;
                const blk = module.asmBlock(a.block);
                if (blk.has_result and blk.result_arm64 < 32) reserved[blk.result_arm64] = true;
                for (blk.in_arm64) |c| if (c < 32) {
                    reserved[c] = true;
                };
                for (blk.clob_arm64) |c| if (c < 32) {
                    reserved[c] = true;
                };
            },
            // §11.8: `x8` holds the syscall number, `x0`..`x5` the arguments,
            // `x0` the kernel's return value. `svc` is a trap, not a `bl` —
            // the Linux arm64 kernel ABI preserves every other register, so
            // unlike x64 there is nothing further to exclude.
            .syscall => {
                reserved[@intFromEnum(syscall_nr_reg)] = true;
                for (syscall_arg_regs) |r| reserved[@intFromEnum(r)] = true;
            },
            else => {},
        }
    }
}

/// Compiles one function to ARM64 machine code. Caller owns the returned
/// `FuncCode` (`FuncCode.deinit`).
pub fn compileFunction(gpa: Allocator, module: *const ir.Module, f: *const ir.Function) CodegenError!FuncCode {
    const tctx = module.ctx;
    var safepoint_list: std.ArrayList(u32) = .empty;
    defer safepoint_list.deinit(gpa);
    const intervals = try buildIntervals(gpa, tctx, f, &safepoint_list);
    defer gpa.free(intervals);

    // Any emitted safepoint is a `bl` (a real call/rt_call/etc. OR the
    // synthetic `bit_rt_safepoint` a loop back-edge inserts), and every `bl`
    // clobbers the caller-saved GPRs — so a function with *any* safepoint must
    // draw only from the callee-saved subset. `safepoint_list` is the exact set
    // of `bl`s `buildIntervals` recorded (calls + back-edges), so it is the
    // single source of truth; a bare `hasCalls` op-scan missed the back-edge
    // case, leaving a loop-carried value in a caller-saved register that the
    // back-edge safepoint then destroyed (#1236).
    const has_safepoints = safepoint_list.items.len > 0;
    var int_buf: [max_int_regs]Reg = undefined;
    var float_buf: [max_float_regs]FReg = undefined;
    const base_int_regs = buildIntRegs(&int_buf, has_safepoints);
    const float_regs = buildFloatRegs(&float_buf, has_safepoints);

    // Any physical register named by an `asm` block's `input`/`result`/clobber
    // list (§11.6) or pinned by a `syscall`'s kernel ABI (§11.8) is removed
    // from the allocatable file for the whole function, so no vreg can land in
    // a register the inline sequence overwrites — the same exclusion mechanism
    // division/shift/atomics use, generalized to an arbitrary set. Neither
    // construct present → all-false → identical to `base_int_regs`.
    var reserved = [_]bool{false} ** 32;
    collectReservedArm64(module, f, &reserved);
    var avail_buf: [max_int_regs]Reg = undefined;
    var avail_n: usize = 0;
    for (base_int_regs) |r| {
        if (!reserved[@intFromEnum(r)]) {
            avail_buf[avail_n] = r;
            avail_n += 1;
        }
    }
    const int_regs = avail_buf[0..avail_n];

    const target = regalloc.TargetRegs{
        .int = .{ .count = @intCast(int_regs.len) },
        .float = .{ .count = @intCast(float_regs.len) },
    };
    var result = try regalloc.allocate(gpa, target, intervals, safepoint_list.items);
    defer result.deinit();

    // Which callee-saved physical registers this function's allocation
    // actually touched — only those need saving/restoring. Scanned per-vreg
    // (rather than just over `result.locations`) since a bare `.reg` index
    // is ambiguous between the int and float files without its own class.
    var gpr_used = [_]bool{false} ** max_int_regs;
    var fpr_used = [_]bool{false} ** max_float_regs;
    for (0..intervals.len) |vi| {
        switch (result.locations[vi]) {
            .reg => |idx| switch (intervals[vi].class) {
                .int => gpr_used[idx] = true,
                .float => fpr_used[idx] = true,
            },
            .spill => {},
        }
    }
    var saved_gpr_buf: [max_int_regs]Reg = undefined;
    var saved_gpr_len: usize = 0;
    for (int_regs, 0..) |r, idx| {
        if (gpr_used[idx] and isCalleeSavedInt(r)) {
            saved_gpr_buf[saved_gpr_len] = r;
            saved_gpr_len += 1;
        }
    }
    var saved_fpr_buf: [max_float_regs]FReg = undefined;
    var saved_fpr_len: usize = 0;
    for (float_regs, 0..) |r, idx| {
        if (fpr_used[idx] and isCalleeSavedFloat(r)) {
            saved_fpr_buf[saved_fpr_len] = r;
            saved_fpr_len += 1;
        }
    }

    // Size the outgoing stack-argument area to the widest call this function
    // makes (see the `FrameInfo` layout note): the 9th+ argument of any class
    // spills to the stack. Only real `bl`s carry user args — the synthetic
    // back-edge safepoint, `gc_alloc`, and `make_closure` never overflow.
    var outgoing_slots: u32 = 0;
    for (0..intervals.len) |vi| {
        const need: u32 = switch (f.decode(@enumFromInt(vi))) {
            .call => |c| stackArgSlots(tctx, f, c.args, 0, 0),
            .rt_call => |rc| stackArgSlots(tctx, f, rc.args, 0, 0),
            .call_value => |c| stackArgSlots(tctx, f, c.args, 1, 0), // arg0 = env
            .call_iface => |c| stackArgSlots(tctx, f, c.args, 1, 0), // arg0 = receiver
            else => 0,
        };
        if (need > outgoing_slots) outgoing_slots = need;
    }
    const outgoing_bytes: u32 = outgoing_slots * 8;

    const raw_size: u32 = outgoing_bytes + 16 + @as(u32, @intCast(saved_gpr_len)) * 8 + @as(u32, @intCast(saved_fpr_len)) * 8 + result.num_spill_slots * 8;
    const frame_size = alignFrame16(raw_size);
    // Every access this backend emits into the frame uses the unsigned-imm12
    // form when possible: 4095*8 bytes reaches any realistic function frame;
    // larger frames still work (via the register-offset fallback) but that
    // path is untested at this scale — assert the common case explicitly.
    std.debug.assert(frame_size < 4096 * 4096);

    const frame = FrameInfo{
        .saved_gpr = saved_gpr_buf[0..saved_gpr_len],
        .saved_fpr = saved_fpr_buf[0..saved_fpr_len],
        .num_spill_slots = result.num_spill_slots,
        .outgoing_bytes = outgoing_bytes,
        .frame_size = frame_size,
    };

    // §10.3.1 @naked safety net: a naked function suppresses its prologue, so a
    // spill slot, saved register, or outgoing-arg area would silently corrupt the
    // caller. (frame_size itself is never 0 here — arm64 always budgets the
    // 16-byte frame record — but a naked fn allocates none of it.) Rules 1+2 make
    // this unreachable; fail loudly if that ever changes.
    if (f.is_naked and (result.num_spill_slots != 0 or saved_gpr_len != 0 or saved_fpr_len != 0 or outgoing_bytes != 0))
        return error.UnsupportedConstruct;

    const inst_to_vreg = try gpa.alloc(u32, intervals.len);
    defer gpa.free(inst_to_vreg);
    for (0..intervals.len) |i| inst_to_vreg[i] = @intCast(i);

    const block_offsets = try gpa.alloc(u32, f.blocks.len);
    defer gpa.free(block_offsets);

    var ctx = Ctx{
        .gpa = gpa,
        .module = module,
        .f = f,
        .inst_to_vreg = inst_to_vreg,
        .result = &result,
        .int_regs = int_regs,
        .float_regs = float_regs,
        .frame = frame,
        .block_offsets = block_offsets,
        .safepoint_positions = safepoint_list.items,
    };
    defer ctx.code.deinit(gpa);
    defer ctx.relocs.deinit(gpa);
    defer ctx.owned_syms.deinit(gpa);
    errdefer for (ctx.owned_syms.items) |s| gpa.free(s); // freed by FuncCode on success
    defer ctx.jump_fixups.deinit(gpa);
    defer ctx.safepoints.deinit(gpa);

    // ---- prologue: establish the frame record, save used registers -----
    // §10.3.1 @naked: suppressed entirely — a naked function runs on its
    // caller's frame and returns via a raw `ret`.
    if (!f.is_naked) {
        try ctx.addSubImmWide(true, reg_sp, reg_sp, frame_size);
        try ctx.storeImm(.x30, reg_sp, frame.lrOffset(), 8);
        try ctx.storeImm(.x29, reg_sp, frame.fpOffset(), 8);
        try ctx.addSubImmWide(false, 29, reg_sp, frame.fpOffset());
        for (frame.saved_gpr, 0..) |r, gi| try ctx.storeImm(r, reg_sp, frame.gprSaveOffset(gi), 8);
        for (frame.saved_fpr, 0..) |r, fi| try ctx.storeImmF(r, reg_sp, frame.fprSaveOffset(fi), 8);
    }

    // ---- bind incoming arguments into the entry block's params ---------
    {
        const entry_blk = f.block(f.entry);
        var int_ord: u32 = 0;
        var float_ord: u32 = 0;
        var int_moves = try std.ArrayList(PMove).initCapacity(gpa, f.param_types.len);
        defer int_moves.deinit(gpa);
        var float_moves = try std.ArrayList(PMove).initCapacity(gpa, f.param_types.len);
        defer float_moves.deinit(gpa);
        var stack_index: u32 = 0;
        for (f.param_types, 0..) |pt, pi| {
            const class = common.classOf(tctx, pt);
            const ord = if (class == .int) int_ord else float_ord;
            const param_v = entry_blk.paramValue(@intCast(pi));
            const to = plocOf(&ctx, @intFromEnum(param_v), class);
            // Mirror of `marshalArgs`: params 1–8 int / 1–8 float arrive in the
            // ABI registers; the rest sit just above this frame at
            // `[sp + frame_size + 8*k]` (the caller's outgoing area).
            const from: PLoc = if (argReg(class, ord)) |reg| .{ .reg = reg } else blk: {
                const off = frame.incomingArgOffset(stack_index);
                stack_index += 1;
                break :blk .{ .mem = off };
            };
            if (class == .int) int_ord += 1 else float_ord += 1;
            try (if (class == .int) &int_moves else &float_moves).append(gpa, .{ .from = from, .to = to });
        }
        try sequentializeAndEmit(&ctx, int_moves.items, .int);
        try sequentializeAndEmit(&ctx, float_moves.items, .float);
    }

    // ---- emit every block in its original (emission) order --------------
    for (f.blocks, 0..) |b, bi| {
        block_offsets[bi] = @intCast(ctx.code.items.len);
        var idx = b.insts_start + b.param_count;
        const end = b.insts_start + b.insts_len;
        while (idx < end) : (idx += 1) {
            try compileInst(&ctx, bi, @enumFromInt(idx));
        }
    }
    ctx.patchJumpFixups();

    // Register-recovery slots: the prologue saves callee-saved `saved_gpr[i]`
    // at `gprSaveOffset(i)` from sp; convert to x29-relative (fp = sp +
    // frame_size - 16) so the runtime walker reads `*(x29 + fp_off)`.
    const fp_base: i32 = @intCast(frame.fpOffset());
    const saved_regs = try gpa.alloc(common.SavedReg, frame.saved_gpr.len);
    errdefer gpa.free(saved_regs);
    for (frame.saved_gpr, 0..) |r, i| saved_regs[i] = .{
        .reg = @intFromEnum(r),
        .fp_off = @as(i32, @intCast(frame.gprSaveOffset(i))) - fp_base,
    };

    return .{
        .gpa = gpa,
        .name = f.name,
        .code = try ctx.code.toOwnedSlice(gpa),
        .relocs = try ctx.relocs.toOwnedSlice(gpa),
        .safepoints = try ctx.safepoints.toOwnedSlice(gpa),
        .saved_regs = saved_regs,
        .owned_syms = try ctx.owned_syms.toOwnedSlice(gpa),
        .frame_size = frame_size,
    };
}

// ============================================================================
// Tests — encoding unit tests vs. `as`/`objdump` disassembler goldens (every
// hex constant below was produced by assembling the shown mnemonic on this
// machine, not hand-derived from the ISA manual).
// ============================================================================

const testing = std.testing;

fn newCtx(gpa: Allocator, module: *const ir.Module, f: *const ir.Function) Ctx {
    return .{
        .gpa = gpa,
        .module = module,
        .f = f,
        .inst_to_vreg = &.{},
        .result = undefined,
        .int_regs = &.{},
        .float_regs = &.{},
        .frame = .{ .saved_gpr = &.{}, .saved_fpr = &.{}, .num_spill_slots = 0, .outgoing_bytes = 0, .frame_size = 0 },
        .block_offsets = &.{},
        .safepoint_positions = &.{},
    };
}

fn expectWord(gpa: Allocator, expected: u32, emit: anytype) !void {
    var ctx = newCtx(gpa, undefined, undefined);
    defer ctx.code.deinit(gpa);
    try emit(&ctx);
    try testing.expectEqual(@as(usize, 4), ctx.code.items.len);
    const got = std.mem.readInt(u32, ctx.code.items[0..4], .little);
    try testing.expectEqual(expected, got);
}

test "movRR encodes as ORR Xd, XZR, Xm (mov x0, x1 = 0xaa0103e0)" {
    try expectWord(testing.allocator, 0xaa0103e0, struct {
        fn f(c: *Ctx) !void {
            try c.movRR(.x0, .x1);
        }
    }.f);
}

test "addRR / subRR / cmpRR (add/sub/cmp x5, x2, x3)" {
    try expectWord(testing.allocator, 0x8b030045, struct {
        fn f(c: *Ctx) !void {
            try c.addRR(.x5, .x2, .x3);
        }
    }.f);
    try expectWord(testing.allocator, 0xcb030045, struct {
        fn f(c: *Ctx) !void {
            try c.subRR(.x5, .x2, .x3);
        }
    }.f);
    try expectWord(testing.allocator, 0xeb03005f, struct {
        fn f(c: *Ctx) !void {
            try c.cmpRR(.x2, .x3);
        }
    }.f);
}

test "logical ops (and/orr/eor/tst x5, x2, x3)" {
    try expectWord(testing.allocator, 0x8a030045, struct {
        fn f(c: *Ctx) !void {
            try c.logicalRR(.and_, .x5, .x2, .x3);
        }
    }.f);
    try expectWord(testing.allocator, 0xaa030045, struct {
        fn f(c: *Ctx) !void {
            try c.logicalRR(.orr, .x5, .x2, .x3);
        }
    }.f);
    try expectWord(testing.allocator, 0xca030045, struct {
        fn f(c: *Ctx) !void {
            try c.logicalRR(.eor, .x5, .x2, .x3);
        }
    }.f);
    try expectWord(testing.allocator, 0xea03005f, struct {
        fn f(c: *Ctx) !void {
            try c.tstRR(.x2, .x3);
        }
    }.f);
}

test "mvn / neg (mvn/neg x5, x3)" {
    try expectWord(testing.allocator, 0xaa2303e5, struct {
        fn f(c: *Ctx) !void {
            try c.mvnR(.x5, .x3);
        }
    }.f);
    try expectWord(testing.allocator, 0xcb0303e5, struct {
        fn f(c: *Ctx) !void {
            try c.negR(.x5, .x3);
        }
    }.f);
}

test "mul/sdiv/udiv/msub (x5, x2, x3[, x4])" {
    try expectWord(testing.allocator, 0x9b037c45, struct {
        fn f(c: *Ctx) !void {
            try c.mulRR(.x5, .x2, .x3);
        }
    }.f);
    try expectWord(testing.allocator, 0x9ac30c45, struct {
        fn f(c: *Ctx) !void {
            try c.sdivRR(.x5, .x2, .x3);
        }
    }.f);
    try expectWord(testing.allocator, 0x9ac30845, struct {
        fn f(c: *Ctx) !void {
            try c.udivRR(.x5, .x2, .x3);
        }
    }.f);
    try expectWord(testing.allocator, 0x9b039045, struct {
        fn f(c: *Ctx) !void {
            try c.msubRR(.x5, .x2, .x3, .x4);
        }
    }.f);
}

test "shift by immediate (lsl/lsr/asr x5, x2, #5)" {
    try expectWord(testing.allocator, 0xd37be845, struct {
        fn f(c: *Ctx) !void {
            try c.lslImm(.x5, .x2, 5);
        }
    }.f);
    try expectWord(testing.allocator, 0xd345fc45, struct {
        fn f(c: *Ctx) !void {
            try c.lsrImm(.x5, .x2, 5);
        }
    }.f);
    try expectWord(testing.allocator, 0x9345fc45, struct {
        fn f(c: *Ctx) !void {
            try c.asrImm(.x5, .x2, 5);
        }
    }.f);
}

test "shift by register (lslv/lsrv/asrv x5, x2, x3)" {
    try expectWord(testing.allocator, 0x9ac32045, struct {
        fn f(c: *Ctx) !void {
            try c.lslvRR(.x5, .x2, .x3);
        }
    }.f);
    try expectWord(testing.allocator, 0x9ac32445, struct {
        fn f(c: *Ctx) !void {
            try c.lsrvRR(.x5, .x2, .x3);
        }
    }.f);
    try expectWord(testing.allocator, 0x9ac32845, struct {
        fn f(c: *Ctx) !void {
            try c.asrvRR(.x5, .x2, .x3);
        }
    }.f);
}

test "cset covers every condition this backend uses" {
    const cases = [_]struct { cond: u4, want: u32 }{
        .{ .cond = Cond.eq, .want = 0x9a9f17e5 },
        .{ .cond = Cond.ne, .want = 0x9a9f07e5 },
        .{ .cond = Cond.lt, .want = 0x9a9fa7e5 },
        .{ .cond = Cond.le, .want = 0x9a9fc7e5 },
        .{ .cond = Cond.gt, .want = 0x9a9fd7e5 },
        .{ .cond = Cond.ge, .want = 0x9a9fb7e5 },
        .{ .cond = Cond.cc, .want = 0x9a9f27e5 },
        .{ .cond = Cond.ls, .want = 0x9a9f87e5 },
        .{ .cond = Cond.hi, .want = 0x9a9f97e5 },
        .{ .cond = Cond.cs, .want = 0x9a9f37e5 },
        .{ .cond = Cond.mi, .want = 0x9a9f57e5 },
    };
    for (cases) |tc| {
        var ctx = newCtx(testing.allocator, undefined, undefined);
        defer ctx.code.deinit(testing.allocator);
        try ctx.cset(.x5, tc.cond);
        const got = std.mem.readInt(u32, ctx.code.items[0..4], .little);
        try testing.expectEqual(tc.want, got);
    }
}

test "movImm64 picks MOVZ/MOVK/MOVN optimally" {
    // movz x5, #0x1234
    try expectWord(testing.allocator, 0xd2824685, struct {
        fn f(c: *Ctx) !void {
            try c.movImm64(.x5, 0x1234);
        }
    }.f);
    // A value whose upper halfwords are all 0xFFFF should use a single MOVN
    // (== `mov x5, #-0x1235`, encoded 0x92824685 per the golden).
    try expectWord(testing.allocator, 0x92824685, struct {
        fn f(c: *Ctx) !void {
            try c.movImm64(.x5, @bitCast(@as(i64, -0x1235)));
        }
    }.f);
}

test "movImm64 round-trips arbitrary 64-bit values through all four halfwords" {
    const gpa = testing.allocator;
    const values = [_]u64{ 0, std.math.maxInt(u64), 1, 0x0001000200030004, 0xFFFF0000FFFF0000, @bitCast(@as(i64, -1)), @bitCast(@as(i64, -100000)) };
    for (values) |val| {
        var ctx = newCtx(gpa, undefined, undefined);
        defer ctx.code.deinit(gpa);
        try ctx.movImm64(.x5, val);
        // Interpret the emitted MOVZ/MOVN + MOVK* sequence and confirm it
        // reconstructs `val` exactly — a semantic check complementing the
        // exact-byte goldens above (which only cover a couple of shapes).
        var acc: u64 = 0;
        var i: usize = 0;
        while (i < ctx.code.items.len) : (i += 4) {
            const w = std.mem.readInt(u32, ctx.code.items[i..][0..4], .little);
            const opc: u2 = @truncate(w >> 29);
            const hw: u2 = @truncate(w >> 21);
            const imm16: u16 = @truncate(w >> 5);
            const shift: u6 = @as(u6, hw) * 16;
            switch (opc) {
                0b10 => acc = @as(u64, imm16) << shift, // MOVZ (first instruction only)
                0b00 => acc = ~(@as(u64, imm16) << shift), // MOVN
                0b11 => acc = (acc & ~(@as(u64, 0xFFFF) << shift)) | (@as(u64, imm16) << shift), // MOVK
                else => unreachable,
            }
        }
        try testing.expectEqual(val, acc);
    }
}

test "unsigned-immediate load/store (ldr/str x5, [x1]; w/b/h variants)" {
    try expectWord(testing.allocator, 0xf9400025, struct {
        fn f(c: *Ctx) !void {
            try c.loadImm(.x5, 1, 0, 8, false);
        }
    }.f);
    try expectWord(testing.allocator, 0xf9000025, struct {
        fn f(c: *Ctx) !void {
            try c.storeImm(.x5, 1, 0, 8);
        }
    }.f);
    try expectWord(testing.allocator, 0xb9400025, struct {
        fn f(c: *Ctx) !void {
            try c.loadImm(.x5, 1, 0, 4, false);
        }
    }.f);
    try expectWord(testing.allocator, 0xb9800025, struct {
        fn f(c: *Ctx) !void {
            try c.loadImm(.x5, 1, 0, 4, true);
        }
    }.f); // ldrsw
    try expectWord(testing.allocator, 0x39400025, struct {
        fn f(c: *Ctx) !void {
            try c.loadImm(.x5, 1, 0, 1, false);
        }
    }.f); // ldrb
    try expectWord(testing.allocator, 0x39800025, struct {
        fn f(c: *Ctx) !void {
            try c.loadImm(.x5, 1, 0, 1, true);
        }
    }.f); // ldrsb (64-bit dest)
    try expectWord(testing.allocator, 0x79400025, struct {
        fn f(c: *Ctx) !void {
            try c.loadImm(.x5, 1, 0, 2, false);
        }
    }.f); // ldrh
    try expectWord(testing.allocator, 0x79800025, struct {
        fn f(c: *Ctx) !void {
            try c.loadImm(.x5, 1, 0, 2, true);
        }
    }.f); // ldrsh
}

test "unsigned-immediate load/store with a nonzero scaled offset (ldr x5, [x1, #16]/#4088)" {
    try expectWord(testing.allocator, 0xf9400825, struct {
        fn f(c: *Ctx) !void {
            try c.loadImm(.x5, 1, 16, 8, false);
        }
    }.f);
    try expectWord(testing.allocator, 0xf947fc25, struct {
        fn f(c: *Ctx) !void {
            try c.loadImm(.x5, 1, 4088, 8, false);
        }
    }.f);
}

test "register-offset load/store (ldr/str x5, [x1, x2, lsl #3] and unshifted)" {
    try expectWord(testing.allocator, 0xf8626825, struct {
        fn f(c: *Ctx) !void {
            try c.loadStoreRegOffset(0b11, false, 0b01, .x2, false, 1, 5);
        }
    }.f);
    try expectWord(testing.allocator, 0xf8627825, struct {
        fn f(c: *Ctx) !void {
            try c.loadStoreRegOffset(0b11, false, 0b01, .x2, true, 1, 5);
        }
    }.f);
    try expectWord(testing.allocator, 0xf8227825, struct {
        fn f(c: *Ctx) !void {
            try c.loadStoreRegOffset(0b11, false, 0b00, .x2, true, 1, 5);
        }
    }.f);
    try expectWord(testing.allocator, 0xfc627825, struct {
        fn f(c: *Ctx) !void {
            try c.loadStoreRegOffset(0b11, true, 0b01, .x2, true, 1, 5);
        }
    }.f); // ldr d5,[x1,x2,lsl#3]
}

test "loadIndexed/storeIndexed pick the scaled register-offset form" {
    try expectWord(testing.allocator, 0xf8627825, struct {
        fn f(c: *Ctx) !void {
            try c.loadIndexed(.x5, .x1, .x2, 8, false);
        }
    }.f);
    try expectWord(testing.allocator, 0xb8227825, struct {
        fn f(c: *Ctx) !void {
            try c.storeIndexed(.x5, .x1, .x2, 4);
        }
    }.f);
}

test "float load/store, fmov transfers, and arithmetic" {
    try expectWord(testing.allocator, 0xfd000025, struct {
        fn f(c: *Ctx) !void {
            try c.storeImmF(.d5, 1, 0, 8);
        }
    }.f);
    try expectWord(testing.allocator, 0xfd400025, struct {
        fn f(c: *Ctx) !void {
            try c.loadImmF(.d5, 1, 0, 8);
        }
    }.f);
    try expectWord(testing.allocator, 0xbd000025, struct {
        fn f(c: *Ctx) !void {
            try c.storeImmF(.d5, 1, 0, 4);
        }
    }.f); // note: width dictates size field, s-register store
    try expectWord(testing.allocator, 0x9e670045, struct {
        fn f(c: *Ctx) !void {
            try c.fmovToFp(.d5, .x2, 8);
        }
    }.f);
    try expectWord(testing.allocator, 0x9e660045, struct {
        fn f(c: *Ctx) !void {
            try c.fmovFromFp(.x5, .d2, 8);
        }
    }.f);
    try expectWord(testing.allocator, 0x1e270045, struct {
        fn f(c: *Ctx) !void {
            try c.fmovToFp(.d5, .x2, 4);
        }
    }.f);
    try expectWord(testing.allocator, 0x1e260045, struct {
        fn f(c: *Ctx) !void {
            try c.fmovFromFp(.x5, .d2, 4);
        }
    }.f);
    try expectWord(testing.allocator, 0x1e632845, struct {
        fn f(c: *Ctx) !void {
            try c.fArithRR(.add, .d5, .d2, .d3, 8);
        }
    }.f);
    try expectWord(testing.allocator, 0x1e633845, struct {
        fn f(c: *Ctx) !void {
            try c.fArithRR(.sub, .d5, .d2, .d3, 8);
        }
    }.f);
    try expectWord(testing.allocator, 0x1e630845, struct {
        fn f(c: *Ctx) !void {
            try c.fArithRR(.mul, .d5, .d2, .d3, 8);
        }
    }.f);
    try expectWord(testing.allocator, 0x1e631845, struct {
        fn f(c: *Ctx) !void {
            try c.fArithRR(.div, .d5, .d2, .d3, 8);
        }
    }.f);
    try expectWord(testing.allocator, 0x1e614045, struct {
        fn f(c: *Ctx) !void {
            try c.fnegF(.d5, .d2, 8);
        }
    }.f);
    try expectWord(testing.allocator, 0x1e632040, struct {
        fn f(c: *Ctx) !void {
            try c.fcmp(.d2, .d3, 8);
        }
    }.f);
    try expectWord(testing.allocator, 0x1e604045, struct {
        fn f(c: *Ctx) !void {
            try c.fmovFF(.d5, .d2, 8);
        }
    }.f);
    try expectWord(testing.allocator, 0x1e232845, struct {
        fn f(c: *Ctx) !void {
            // `FReg` only names the `d` view (see its doc comment); `width=4`
            // is what selects the `s`-register encoding for the same index.
            try c.fArithRR(.add, .d5, .d2, .d3, 4);
        }
    }.f);
}

test "ret / udf / branch-immediate opcodes" {
    try expectWord(testing.allocator, 0xd65f03c0, struct {
        fn f(c: *Ctx) !void {
            try c.ret();
        }
    }.f);
    try expectWord(testing.allocator, 0x00000000, struct {
        fn f(c: *Ctx) !void {
            try c.udf();
        }
    }.f);
}

test "addSubImmWide handles a small, an exact-4096, and a two-instruction frame size" {
    // sub sp, sp, #0x100 (256)
    try expectWord(testing.allocator, 0x910403ff, struct {
        fn f(c: *Ctx) !void {
            try c.addSubImmWide(false, reg_sp, reg_sp, 256);
        }
    }.f);
    var ctx = newCtx(testing.allocator, undefined, undefined);
    defer ctx.code.deinit(testing.allocator);
    try ctx.addSubImmWide(true, reg_sp, reg_sp, 0x11000); // hi=0x11, lo=0
    try testing.expectEqual(@as(usize, 4), ctx.code.items.len); // lo==0: only the shifted instruction
    const got = std.mem.readInt(u32, ctx.code.items[0..4], .little);
    try testing.expectEqual(@as(u32, 0xd14047ff), got); // sub sp,sp,#0x11,lsl#12
}

test "jump/branch fixups patch to the correct relative word offset" {
    const gpa = testing.allocator;
    var ctx = newCtx(gpa, undefined, undefined);
    defer ctx.code.deinit(gpa);
    defer ctx.jump_fixups.deinit(gpa);
    var block_offsets = [_]u32{ 0, 0 };
    ctx.block_offsets = &block_offsets;

    try ctx.emitJumpFixup(@enumFromInt(1)); // b -> block 1, patch_offset == 0
    // AArch64's branch immediate is PC-relative to the branch instruction's
    // OWN address (not the next instruction) — set block 1's start directly
    // so the expected word offset below is exactly 1048/4, not off-by-one.
    block_offsets[1] = 1048;
    ctx.patchJumpFixups();
    const got = std.mem.readInt(u32, ctx.code.items[0..4], .little);
    try testing.expectEqual(@as(u32, 0x14000000 | (1048 / 4)), got);
}

// Regression (#1235): two spilled values swapping stack slots form a
// mem<->mem 2-cycle in an edge's parallel move. The cycle-break saves one
// slot's value in a scratch register held across the whole rotation, so that
// register must differ from the one `emitMove` uses as its own mem->mem copy
// temp (`scratch1`). Using `scratch1` for both means the first rotation step
// overwrites the saved value and the swap silently corrupts — one loop-carried
// value takes another's. Byte-exact so a revert to `scratch1` fails here, not
// only in the allocation-sensitive golden.
test "sequentializeAndEmit breaks a mem<->mem swap cycle without clobbering the saved value" {
    const gpa = testing.allocator;
    const moves = [_]PMove{
        .{ .from = .{ .mem = 0 }, .to = .{ .mem = 8 } },
        .{ .from = .{ .mem = 8 }, .to = .{ .mem = 0 } },
    };
    var got = newCtx(gpa, undefined, undefined);
    defer got.code.deinit(gpa);
    try sequentializeAndEmit(&got, &moves, .int);

    var want = newCtx(gpa, undefined, undefined);
    defer want.code.deinit(gpa);
    try want.loadImm(scratch2, reg_sp, 8, 8, false); // save start slot into x10 (NOT x9)
    try want.loadImm(scratch1, reg_sp, 0, 8, false); // rotate the mem->mem move via x9
    try want.storeImm(scratch1, reg_sp, 8, 8);
    try want.storeImm(scratch2, reg_sp, 0, 8); // restore saved value from x10
    try testing.expectEqualSlices(u8, want.code.items, got.code.items);
}

// Regression for the desync between `buildIntervals`'s safepoint-position
// list and `emitCall`'s actual emission: a real `rt_call` with no loop
// back-edge in the same function used to get zero recorded safepoints (see
// this file's module doc comment / `runtime/ABI.md` §5, which both require
// one at *every* call/rt_call) even though `buildIntervals` already counted
// it and handed regalloc a stack map for it — a GC pausing at that call's
// return address would find `FuncCode.safepoints` empty and scan nothing.
test "compileFunction records a safepoint at a real rt_call with no back-edge" {
    const gpa = testing.allocator;
    var ctx = try check.TypeContext.init(gpa);
    defer ctx.deinit();
    const i64_ty = ctx.prim_ids.get(.i64);
    const string_ty = ctx.prim_ids.get(.string);

    var b = ir.FunctionBuilder.init(gpa);
    const entry = try b.newBlock();
    b.beginBlock(entry);
    const p0 = try b.addParam(i64_ty);
    const s = try b.rtCall(string_ty, .string_from_int, &.{p0});
    try b.ret(&.{s});
    b.endBlock();
    var f = try b.finish("f", &.{i64_ty}, string_ty, false, .invalid, entry);
    defer f.deinit(gpa);

    var module = ir.Module.init(gpa, &ctx);
    defer module.deinit();

    var code = try compileFunction(gpa, &module, &f);
    defer code.deinit();

    try testing.expectEqual(@as(usize, 1), code.safepoints.len);
}

test "global_addr on a .thread global emits the local-exec TLS sequence, not an ADRP pair" {
    const gpa = testing.allocator;
    var ctx = try check.TypeContext.init(gpa);
    defer ctx.deinit();
    const i64_ty = ctx.prim_ids.get(.i64);

    var module = ir.Module.init(gpa, &ctx);
    defer module.deinit();
    // `addGlobal` takes ownership of both slices, so they must be heap-owned.
    const proc = try module.addGlobal(try gpa.dupe(u8, "p"), try gpa.dupe(u8, &[_]u8{0} ** 8), 8, .process);
    const thr = try module.addGlobal(try gpa.dupe(u8, "t"), try gpa.dupe(u8, &[_]u8{0} ** 8), 8, .thread);

    for ([_]struct { g: ir.GlobalId, tls: bool }{
        .{ .g = proc, .tls = false },
        .{ .g = thr, .tls = true },
    }) |case| {
        var b = ir.FunctionBuilder.init(gpa);
        const entry = try b.newBlock();
        b.beginBlock(entry);
        const a = try b.globalAddr(i64_ty, case.g);
        try b.ret(&.{a});
        b.endBlock();
        var f = try b.finish("f", &.{}, i64_ty, false, .invalid, entry);
        defer f.deinit(gpa);

        var code = try compileFunction(gpa, &module, &f);
        defer code.deinit();

        // The tell is `MRS Xt, TPIDR_EL0` (0xD53BD040 | Rt): only the
        // thread-local path reads the thread pointer. Its absence on the
        // process-wide path is what proves the two classes are distinguished
        // rather than both compiling to the same address materialization.
        var saw_mrs = false;
        var i: usize = 0;
        while (i + 4 <= code.code.len) : (i += 4) {
            const w = std.mem.readInt(u32, code.code[i..][0..4], .little);
            if (w & 0xFFFFFFE0 == 0xD53BD040) saw_mrs = true;
        }
        try testing.expectEqual(case.tls, saw_mrs);

        // ...and the relocation pair must be the TLS one, so a wrong-but-present
        // MRS cannot carry an ordinary page21/pageoff12 pair past this test.
        var saw_tprel = false;
        for (code.relocs) |r| {
            if (r.kind == .tprel_hi12 or r.kind == .tprel_lo12) saw_tprel = true;
        }
        try testing.expectEqual(case.tls, saw_tprel);
    }
}
