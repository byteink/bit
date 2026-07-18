//! x86-64 codegen (task #340): IR (`ir.zig`) + register allocation
//! (`regalloc.zig`) -> machine code, for the SysV and Win64 calling
//! conventions. Direct binary encoding, no external assembler.
//!
//! ## Output
//!
//! `compileFunction` returns a `FuncCode`: raw code bytes, call-site
//! relocations (by symbol name), and GC stack maps (`runtime/ABI.md` §4) —
//! format-agnostic, consumed by a not-yet-built object writer/linker. Every
//! `call`-like instruction emits a plain `0xE8 rel32` with a `Reloc` naming
//! its target symbol; nothing needs to *exist* at codegen time (the linker's
//! job), exactly like `ir.Op.call`'s `FuncId` is only resolved to a name
//! here (`module.func(id).name`), never an address.
//!
//! ## Registers
//!
//! Three GPRs (`r10`, `r11`, `r12`) and two XMMs (`xmm14`, `xmm15`) are
//! permanently reserved as codegen scratch — never handed to the register
//! allocator, never a legitimate SysV/Win64 argument or return register.
//! Every instruction selector materializes both operands into scratch
//! registers, computes there, then writes the result out (`getInt`/`putInt`
//! and friends) — simpler and more uniform than trying to reuse an operand's
//! own register as the destination, at the cost of a handful of extra `mov`s
//! `// ponytail: always route through scratch, tighten later if code size
//! on hot paths matters`.
//!
//! ## Deliberately NOT covered (returns `error.UnsupportedConstruct`, never a
//! silently-wrong codegen — mirrors `lower.zig`'s own scope-exclusion style)
//!
//! - `index_get`/`index_set` on anything but a static `.array` base: array
//!   element addressing is fully determined by `lower.zig`'s "arrays have no
//!   header, a static length" scheme, so `base + index*width` is unambiguous.
//!   A dynamic `[]T` instead carries a `{ptr, len, cap, is_ref}` header
//!   (ABI.md §2) and indexes through the bounds-checked `slice_get`/`slice_set`
//!   runtime calls, so `lower.zig` never emits the `index_*` ops against a
//!   slice. `slice_len` IS covered here: it loads the `len` word (offset 8),
//!   shared by the slice and `string` headers.
//! - A `ret` carrying more than one value: `ir.zig` itself notes "codegen
//!   decides ABI packing for a multi-value tuple return" — undecided, so an
//!   explicit error rather than a guessed packing.
//!
//! `field_get`/`field_set` (struct fields) and `rt_call` (any `ir.RtFn`,
//! generically dispatched to a `bit_rt_<tag>` symbol) ARE covered: both need
//! only a byte offset/width or an arg count already present in the IR, no
//! new layout invention.
//!
//! ## Sub-64-bit integers
//!
//! Every integer SSA value lives in a full 64-bit GPR held **width-canonical**:
//! its bits above the type width always match the type — zero for an unsigned
//! type, a copy of the sign bit for a signed one — so every consumer (logical
//! right shift, signed/unsigned compare, unsigned div/mod, rotate) reads a
//! correct value with no per-op masking. The invariant is upheld at every
//! definition site: loads sign/zero-extend to width (`movLoad`/`emitFieldGet`),
//! narrow constants are in-range by construction, and the ops that CAN push
//! bits past the type width — `add`/`sub`/`mul`/`shl` and unary `neg`/`bnot` —
//! re-narrow their result through `canonNarrow` (`movzx`/`movsx`/`movsxd`)
//! before it is stored. Bitwise `and`/`or`/`xor`, the right shifts, and
//! `div`/`mod` already carry canonical inputs to canonical outputs, so they add
//! no mask; `u64`/`i64` (register width == type width) stay on the zero-cost
//! fast path. This is what makes narrow `add` + `>>`/rotate round-trips exact —
//! the SHA-256/ChaCha20/BLAKE prerequisite (#1158) — instead of leaking the
//! overflow bits a full-width add left behind.
//!
//! ## Safepoints
//!
//! Per `runtime/ABI.md` §5, a stack map is recorded at every `call`/`rt_call`
//! and at every loop back-edge (a `jump`/`br` whose target block's index is
//! <= the branching block's — the natural back-edge shape for blocks built
//! in emission/RPO order, same heuristic implied by `regalloc.zig`'s own doc
//! comment). A back-edge additionally gets a synthetic zero-arg call to
//! `bit_rt_safepoint` inserted right before it, so an allocation-free loop
//! still gives the collector a chance to run. No poll is inserted at plain
//! function entry — a function that never loops and never calls returns
//! promptly, so it cannot itself starve the collector; only its *caller's*
//! own loop/call safepoints bound total mutator time between collections.
//!
//! Register pressure: whenever a function contains any safepoint, its
//! allocatable register file is restricted to the callee-saved subset only
//! (`scanFuncFlags`' `has_safepoints`, which counts both real calls and
//! back-edges) — this sidesteps caller-save
//! spill/reload entirely (no vreg can ever land in a call-clobbered
//! register) at the cost of using fewer registers in such functions.
//! `// ponytail: callee-saved-only register file across calls, add
//! caller-save spill/reload around call sites if this measurably hurts
//! codegen quality`. Similarly, a function containing `sdiv`/`udiv`/`srem`/
//! `urem` excludes `rax`/`rdx` from allocation (both are fixed operands of
//! `idiv`/`div`), and a function containing a shift by a non-constant amount
//! excludes `rcx` (its low byte, `cl`, is the only valid variable shift
//! count).

const std = @import("std");
const ir = @import("../ir.zig");
const check = @import("../check.zig");
const regalloc = @import("../regalloc.zig");
const common = @import("common.zig");

const Allocator = std.mem.Allocator;
const TypeId = check.TypeId;
const TypeContext = check.TypeContext;

// ============================================================================
// Registers & calling convention
// ============================================================================

/// Physical GPR, numbered exactly as the x86-64 ModRM/REX encoding expects
/// (`@intFromEnum` IS the register number).
pub const Reg = enum(u4) { rax, rcx, rdx, rbx, rsp, rbp, rsi, rdi, r8, r9, r10, r11, r12, r13, r14, r15 };
/// Physical XMM register, numbered the same way.
pub const XReg = enum(u4) { xmm0, xmm1, xmm2, xmm3, xmm4, xmm5, xmm6, xmm7, xmm8, xmm9, xmm10, xmm11, xmm12, xmm13, xmm14, xmm15 };

pub const CallConv = enum { sysv, win64 };

/// Reserved codegen-internal scratch — never allocatable, never a legitimate
/// SysV/Win64 argument or return register in either convention (see module
/// doc comment).
const scratch1: Reg = .r11; // primary: binary/unary accumulator, setcc/and8/or8 target, move-cycle temp
const scratch2: Reg = .r10; // secondary: rhs operand / base pointer
const scratch3: Reg = .r12; // tertiary: index register (array indexing only)
const fscratch1: XReg = .xmm14; // primary float accumulator / move-cycle temp
const fscratch2: XReg = .xmm15; // secondary float operand

const master_gprs = [_]Reg{ .rax, .rcx, .rdx, .rbx, .rsi, .rdi, .r8, .r9, .r13, .r14, .r15 };
const max_int_regs = master_gprs.len;
const max_float_regs = 14; // xmm0..xmm13

const sysv_int_args = [_]Reg{ .rdi, .rsi, .rdx, .rcx, .r8, .r9 };
const win64_int_args = [_]Reg{ .rcx, .rdx, .r8, .r9 };

fn isCalleeSavedInt(cc: CallConv, r: Reg) bool {
    return switch (cc) {
        .sysv => switch (r) {
            .rbx, .r13, .r14, .r15 => true,
            else => false,
        },
        .win64 => switch (r) {
            .rbx, .rsi, .rdi, .r13, .r14, .r15 => true,
            else => false,
        },
    };
}

fn isCalleeSavedFloat(cc: CallConv, x: XReg) bool {
    return switch (cc) {
        .sysv => false,
        .win64 => @intFromEnum(x) >= 6, // xmm6..xmm13 (xmm14/15 are scratch, never allocatable)
    };
}

/// Allocatable GPRs for one function: the full master list, or (whenever the
/// function contains any safepoint) only its callee-saved subset — see the
/// module doc comment. `buf` is caller-owned storage (bounded, `max_int_regs`).
fn buildIntRegs(buf: *[max_int_regs]Reg, cc: CallConv, has_calls: bool, needs_rax_rdx: bool, needs_rcx: bool) []const Reg {
    var n: usize = 0;
    for (master_gprs) |r| {
        if (has_calls) {
            if (!isCalleeSavedInt(cc, r)) continue;
        } else {
            if (needs_rax_rdx and (r == .rax or r == .rdx)) continue;
            if (needs_rcx and r == .rcx) continue;
        }
        buf[n] = r;
        n += 1;
    }
    return buf[0..n];
}

/// Allocatable XMMs for one function — see `buildIntRegs`.
fn buildFloatRegs(buf: *[max_float_regs]XReg, cc: CallConv, has_calls: bool) []const XReg {
    if (!has_calls) {
        for (0..max_float_regs) |i| buf[i] = @enumFromInt(@as(u4, @intCast(i)));
        return buf[0..max_float_regs];
    }
    if (cc == .sysv) return buf[0..0];
    var n: usize = 0;
    var r: u4 = 6;
    while (r < max_float_regs) : (r += 1) {
        buf[n] = @enumFromInt(r);
        n += 1;
    }
    return buf[0..n];
}

fn calleeSavedIntMask(cc: CallConv, regs: []const Reg) u32 {
    var mask: u32 = 0;
    for (regs, 0..) |r, i| if (isCalleeSavedInt(cc, r)) {
        mask |= @as(u32, 1) << @intCast(i);
    };
    return mask;
}

fn calleeSavedFloatMask(cc: CallConv, regs: []const XReg) u32 {
    var mask: u32 = 0;
    for (regs, 0..) |r, i| if (isCalleeSavedFloat(cc, r)) {
        mask |= @as(u32, 1) << @intCast(i);
    };
    return mask;
}

/// The nth argument's ABI register, or `null` if it overflows to the stack.
/// SysV counts int/float arguments independently (`class_ordinal`); Win64
/// shares one positional slot counter across both classes (`position`).
fn argReg(cc: CallConv, class: regalloc.Class, position: u32, class_ordinal: u32) ?u4 {
    const ord = if (cc == .sysv) class_ordinal else position;
    return switch (cc) {
        .sysv => switch (class) {
            .int => if (ord < sysv_int_args.len) @intFromEnum(sysv_int_args[ord]) else null,
            .float => if (ord < 8) @intCast(ord) else null,
        },
        .win64 => switch (class) {
            .int => if (ord < win64_int_args.len) @intFromEnum(win64_int_args[ord]) else null,
            .float => if (ord < 4) @intCast(ord) else null,
        },
    };
}

// ============================================================================
// Type classification (mirrors `lower.zig`'s object-layout scheme exactly —
// see that file's module doc comment: every scalar prim is stored at its
// natural width; every other shape is one boxed 8-byte handle)
// ============================================================================

const Width = struct { bytes: u8, class: regalloc.Class, signed: bool };

fn widthOf(tctx: *const TypeContext, ty: TypeId) Width {
    return switch (tctx.typeOf(ty)) {
        .prim => |p| switch (p) {
            .i8 => .{ .bytes = 1, .class = .int, .signed = true },
            .u8 => .{ .bytes = 1, .class = .int, .signed = false },
            .i16 => .{ .bytes = 2, .class = .int, .signed = true },
            .u16 => .{ .bytes = 2, .class = .int, .signed = false },
            .i32 => .{ .bytes = 4, .class = .int, .signed = true },
            .u32 => .{ .bytes = 4, .class = .int, .signed = false },
            .i64 => .{ .bytes = 8, .class = .int, .signed = true },
            .u64 => .{ .bytes = 8, .class = .int, .signed = false },
            .f32 => .{ .bytes = 4, .class = .float, .signed = false },
            .f64 => .{ .bytes = 8, .class = .float, .signed = false },
            .bool => .{ .bytes = 1, .class = .int, .signed = false },
            .string => .{ .bytes = 8, .class = .int, .signed = false },
        },
        else => .{ .bytes = 8, .class = .int, .signed = false }, // uniform boxed handle
    };
}

fn classOf(tctx: *const TypeContext, ty: TypeId) regalloc.Class {
    return widthOf(tctx, ty).class;
}

/// True iff a value of type `ty` is a GC reference (`lower.zig`'s
/// `fieldLayout(...).is_ptr`, re-derived here for codegen's own use).
fn isRefType(tctx: *const TypeContext, ty: TypeId) bool {
    return switch (tctx.typeOf(ty)) {
        .prim => |p| p == .string,
        // A raw pointer `*T` (§11.4) is a word the GC must never follow.
        .void, .untyped_int, .untyped_float, .untyped_rune, .untyped_bool, .untyped_string, .untyped_nil, .invalid, .type_param, .fallible, .ptr => false,
        .@"enum" => |e| check.enumBoxed(e), // bare tag word, or boxed {tag,payloadPtr} if it has payloads
        else => true, // slice/array/map/tuple/chan/struct/interface/func
    };
}

// ============================================================================
// Output records
// ============================================================================

/// How the object writer patches a relocation's field. `.call` is the 4-byte
/// PC-relative branch immediate (`E8 rel32`); `.abs64` is a full 64-bit
/// absolute pointer, how a `const_string` loads its static header's address.
pub const RelocKind = enum { call, abs64 };

pub const Reloc = struct {
    /// Byte offset in `FuncCode.code` of the field to patch.
    offset: u32,
    /// Target symbol name: a Bit function's own name, a runtime symbol
    /// (`bit_rt_<RtFn tag>`, `bit_rt_safepoint`), or a `const_string` header
    /// (`__bitstr_N`) — see module doc comment.
    symbol: []const u8,
    kind: RelocKind = .call,
};

pub const SafepointEntry = struct {
    /// Byte offset in `FuncCode.code` of the return address (i.e. right
    /// after the `call`'s 5 bytes) this stack map applies to.
    code_offset: u32,
    /// Physical registers holding a live GC reference at this point.
    regs: []const Reg,
    /// rbp-relative byte offsets of stack slots holding a live GC reference.
    frame_offsets: []const i32,
};

pub const FuncCode = struct {
    gpa: Allocator,
    name: []const u8, // borrowed from the `ir.Function`
    code: []u8,
    relocs: []Reloc, // `symbol` slices borrowed (module func names / static strings)
    safepoints: []SafepointEntry,
    /// Callee-saved registers this function's prologue preserves, and where
    /// (rbp-relative, i.e. fp-relative) it stashed the caller's value — the
    /// runtime stack walker (`runtime/ABI.md` §4) restores them when unwinding.
    saved_regs: []common.SavedReg,
    frame_size: u32,
    /// Owned `__bitstr_N` names some `relocs` borrow (see `Ctx.owned_syms`).
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

pub const CodegenError = error{
    UnsupportedConstruct,
    TooManyArguments,
} || Allocator.Error;

// ============================================================================
// Low-level x86-64 encoder
// ============================================================================

fn rex(w: bool, r: bool, x: bool, b: bool) u8 {
    return 0x40 | (@as(u8, @intFromBool(w)) << 3) | (@as(u8, @intFromBool(r)) << 2) | (@as(u8, @intFromBool(x)) << 1) | @intFromBool(b);
}

fn modrmRegByte(reg_field: u4, rm: u4) u8 {
    return 0xC0 | (@as(u8, reg_field & 7) << 3) | (rm & 7);
}

fn scaleBits(scale: u8) u2 {
    return switch (scale) {
        1 => 0,
        2 => 1,
        4 => 2,
        8 => 3,
        else => unreachable, // caller contract: scale is always an element width in {1,2,4,8}
    };
}

/// One compiling function's full context: encoder state, register
/// allocation results, frame layout, and fixup/relocation bookkeeping.
const Ctx = struct {
    gpa: Allocator,
    cc: CallConv,
    module: *const ir.Module,
    f: *const ir.Function,
    code: std.ArrayList(u8) = .empty,
    relocs: std.ArrayList(Reloc) = .empty,
    /// Symbol names this function synthesized (per-`const_string` `__bitstr_N`)
    /// and that its relocations borrow — owned here, moved into `FuncCode`.
    owned_syms: std.ArrayList([]u8) = .empty,
    inst_to_vreg: []const u32,
    result: *const regalloc.Result,
    int_regs: []const Reg,
    float_regs: []const XReg,
    frame: FrameInfo,
    block_offsets: []u32,
    jump_fixups: std.ArrayList(JumpFixup) = .empty,
    safepoint_code_offsets: []u32,
    next_safepoint_idx: u32 = 0,
    /// Array index (== `BlockId`) of the block currently being emitted —
    /// used to classify a `jump`/`br` target as a back-edge (`runtime/ABI.md`
    /// §5 / module doc comment on safepoints).
    cur_block_idx: u32 = 0,

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

    fn emitI32(self: *Ctx, v: i32) !void {
        try self.emitU32(@bitCast(v));
    }

    fn emitU64(self: *Ctx, v: u64) !void {
        try self.emitU32(@truncate(v));
        try self.emitU32(@truncate(v >> 32));
    }

    fn maybeRex(self: *Ctx, w: bool, r: bool, x: bool, b: bool) !void {
        if (w or r or x or b) try self.emitByte(rex(w, r, x, b));
    }

    // ---- register-direct ops --------------------------------------------

    fn movRR(self: *Ctx, dst: Reg, src: Reg) !void {
        if (dst == src) return;
        try self.maybeRex(true, @intFromEnum(src) >= 8, false, @intFromEnum(dst) >= 8);
        try self.emitByte(0x89);
        try self.emitByte(modrmRegByte(@intFromEnum(src), @intFromEnum(dst)));
    }

    fn movRI(self: *Ctx, dst: Reg, imm: i64) !void {
        if (imm >= std.math.minInt(i32) and imm <= std.math.maxInt(i32)) {
            try self.maybeRex(true, false, false, @intFromEnum(dst) >= 8);
            try self.emitByte(0xC7);
            try self.emitByte(modrmRegByte(0, @intFromEnum(dst)));
            try self.emitI32(@intCast(imm));
        } else {
            try self.maybeRex(true, false, false, @intFromEnum(dst) >= 8);
            try self.emitByte(0xB8 | @as(u8, @intFromEnum(dst) & 7));
            try self.emitU64(@bitCast(imm));
        }
    }

    /// `movabs dst, <address of symbol>` — a `REX.W B8+r` with an 8-byte
    /// immediate the linker fills via an `abs64` relocation. Loads the address
    /// of a static symbol (a `const_string`'s `__bitstr_N` header) into `dst`.
    fn movAbsReloc(self: *Ctx, dst: Reg, symbol: []const u8) !void {
        try self.maybeRex(true, false, false, @intFromEnum(dst) >= 8);
        try self.emitByte(0xB8 | @as(u8, @intFromEnum(dst) & 7));
        const off: u32 = @intCast(self.code.items.len);
        try self.emitU64(0);
        try self.relocs.append(self.gpa, .{ .offset = off, .symbol = symbol, .kind = .abs64 });
    }

    const ArithOp = enum { add, or_, and_, sub, xor, cmp };
    fn arithOpcode(op: ArithOp) u8 {
        return switch (op) {
            .add => 0x01,
            .or_ => 0x09,
            .and_ => 0x21,
            .sub => 0x29,
            .xor => 0x31,
            .cmp => 0x39,
        };
    }

    /// `dst (rm) <op>= src (reg)`; for `.cmp`, `dst` is unmodified (flags only).
    fn arithRR(self: *Ctx, op: ArithOp, dst: Reg, src: Reg) !void {
        try self.maybeRex(true, @intFromEnum(src) >= 8, false, @intFromEnum(dst) >= 8);
        try self.emitByte(arithOpcode(op));
        try self.emitByte(modrmRegByte(@intFromEnum(src), @intFromEnum(dst)));
    }

    fn testRR(self: *Ctx, a: Reg, b: Reg) !void {
        try self.maybeRex(true, @intFromEnum(b) >= 8, false, @intFromEnum(a) >= 8);
        try self.emitByte(0x85);
        try self.emitByte(modrmRegByte(@intFromEnum(b), @intFromEnum(a)));
    }

    /// `dst *= src` (two-operand IMUL, `0F AF /r`).
    fn imulRR(self: *Ctx, dst: Reg, src: Reg) !void {
        try self.maybeRex(true, @intFromEnum(dst) >= 8, false, @intFromEnum(src) >= 8);
        try self.emitByte(0x0F);
        try self.emitByte(0xAF);
        try self.emitByte(modrmRegByte(@intFromEnum(dst), @intFromEnum(src)));
    }

    fn group3R(self: *Ctx, digit: u3, r: Reg) !void {
        try self.maybeRex(true, false, false, @intFromEnum(r) >= 8);
        try self.emitByte(0xF7);
        try self.emitByte(modrmRegByte(digit, @intFromEnum(r)));
    }
    fn negR(self: *Ctx, r: Reg) !void {
        try self.group3R(3, r);
    }
    fn notR(self: *Ctx, r: Reg) !void {
        try self.group3R(2, r);
    }
    fn idivR(self: *Ctx, r: Reg) !void {
        try self.group3R(7, r);
    }
    fn divR(self: *Ctx, r: Reg) !void {
        try self.group3R(6, r);
    }

    fn cqo(self: *Ctx) !void {
        try self.emitByte(rex(true, false, false, false));
        try self.emitByte(0x99);
    }

    /// `edx := 0` (also zero-extends the full 64-bit `rdx`) — the standard
    /// idiom to prime unsigned division.
    fn zero32(self: *Ctx, r: Reg) !void {
        try self.maybeRex(false, @intFromEnum(r) >= 8, false, @intFromEnum(r) >= 8);
        try self.emitByte(0x31);
        try self.emitByte(modrmRegByte(@intFromEnum(r), @intFromEnum(r)));
    }

    const ShiftOp = enum { shl, shr, sar };
    fn shiftDigit(op: ShiftOp) u3 {
        return switch (op) {
            .shl => 4,
            .shr => 5,
            .sar => 7,
        };
    }
    fn shiftImm(self: *Ctx, op: ShiftOp, r: Reg, amount: u6) !void {
        try self.maybeRex(true, false, false, @intFromEnum(r) >= 8);
        try self.emitByte(0xC1);
        try self.emitByte(modrmRegByte(shiftDigit(op), @intFromEnum(r)));
        try self.emitByte(@intCast(amount));
    }
    /// Shift `r` by `cl` — `cl` (`rcx`'s low byte) is the only valid
    /// variable shift-count operand on x86-64.
    fn shiftCl(self: *Ctx, op: ShiftOp, r: Reg) !void {
        try self.maybeRex(true, false, false, @intFromEnum(r) >= 8);
        try self.emitByte(0xD3);
        try self.emitByte(modrmRegByte(shiftDigit(op), @intFromEnum(r)));
    }

    /// `setcc r_low8` — always forces a REX prefix (even when otherwise
    /// unneeded) so the destination is read as the "new" low byte (never
    /// the legacy AH/BH/CH/DH high-byte encoding — see module doc comment).
    fn setcc(self: *Ctx, cc: u4, r: Reg) !void {
        try self.emitByte(rex(false, false, false, @intFromEnum(r) >= 8));
        try self.emitByte(0x0F);
        try self.emitByte(0x90 | @as(u8, cc));
        try self.emitByte(modrmRegByte(0, @intFromEnum(r)));
    }
    /// `movzx dst64, src8` (REX.W 0F B6 /r) — zero-extends the low byte of
    /// `src` into the full 64-bit `dst`. Used to widen a `setcc` result to a
    /// clean 0/1 *without* the flag-clobbering `xor` that zeroing-before-setcc
    /// would need (setcc must read the flags left by the preceding compare).
    fn movzxb(self: *Ctx, dst: Reg, src: Reg) !void {
        try self.maybeRex(true, @intFromEnum(dst) >= 8, false, @intFromEnum(src) >= 8);
        try self.emitByte(0x0F);
        try self.emitByte(0xB6);
        try self.emitByte(modrmRegByte(@intFromEnum(dst), @intFromEnum(src)));
    }
    fn and8(self: *Ctx, dst: Reg, src: Reg) !void {
        try self.emitByte(rex(false, @intFromEnum(src) >= 8, false, @intFromEnum(dst) >= 8));
        try self.emitByte(0x20);
        try self.emitByte(modrmRegByte(@intFromEnum(src), @intFromEnum(dst)));
    }
    fn or8(self: *Ctx, dst: Reg, src: Reg) !void {
        try self.emitByte(rex(false, @intFromEnum(src) >= 8, false, @intFromEnum(dst) >= 8));
        try self.emitByte(0x08);
        try self.emitByte(modrmRegByte(@intFromEnum(src), @intFromEnum(dst)));
    }

    fn push(self: *Ctx, r: Reg) !void {
        if (@intFromEnum(r) >= 8) try self.emitByte(rex(false, false, false, true));
        try self.emitByte(0x50 | @as(u8, @intFromEnum(r) & 7));
    }
    fn pop(self: *Ctx, r: Reg) !void {
        if (@intFromEnum(r) >= 8) try self.emitByte(rex(false, false, false, true));
        try self.emitByte(0x58 | @as(u8, @intFromEnum(r) & 7));
    }
    /// `call r/m64` (indirect through a register) — `FF /2`. Used for
    /// `call_value` (closure dispatch through a loaded code pointer).
    fn callReg(self: *Ctx, r: Reg) !void {
        if (@intFromEnum(r) >= 8) try self.emitByte(rex(false, false, false, true));
        try self.emitByte(0xFF);
        try self.emitByte(modrmRegByte(2, @intFromEnum(r)));
    }
    fn ret(self: *Ctx) !void {
        try self.emitByte(0xC3);
    }
    fn ud2(self: *Ctx) !void {
        try self.emitByte(0x0F);
        try self.emitByte(0x0B);
    }
    /// `rsp <op>= imm32` (`.add`/`.sub` only — group-1 `/0` and `/5`).
    fn rspAddSub(self: *Ctx, is_sub: bool, imm: u32) !void {
        try self.emitByte(rex(true, false, false, false));
        try self.emitByte(0x81);
        try self.emitByte(modrmRegByte(if (is_sub) 5 else 0, @intFromEnum(Reg.rsp)));
        try self.emitI32(@bitCast(imm));
    }

    // ---- memory operands ---------------------------------------------------
    // Always `mod=10` (disp32), even for disp=0 — avoids the rbp/r13
    // "no-base" and rsp/r12 SIB special cases entirely at the cost of a few
    // extra bytes (`// ponytail: always disp32, shrink to disp8/disp0 later
    // if code size matters`). A SIB byte is emitted whenever an index
    // register is given, or the base is rsp/r12 (mandatory per the ISA).

    fn memModRM(self: *Ctx, reg_field: u4, base: Reg, index: ?Reg, scale: u8, disp: i32) !void {
        const base_low3: u3 = @truncate(@intFromEnum(base));
        const need_sib = index != null or base_low3 == 0b100;
        try self.emitByte(0x80 | (@as(u8, reg_field & 7) << 3) | (if (need_sib) @as(u8, 0b100) else base_low3));
        if (need_sib) {
            const idx_low3: u3 = if (index) |ix| @truncate(@intFromEnum(ix)) else 0b100;
            try self.emitByte((@as(u8, scaleBits(scale)) << 6) | (@as(u8, idx_low3) << 3) | base_low3);
        }
        try self.emitI32(disp);
    }

    fn regBits(reg_field: u4, base: Reg, index: ?Reg) struct { r: bool, x: bool, b: bool } {
        return .{
            .r = reg_field >= 8,
            .x = if (index) |ix| @intFromEnum(ix) >= 8 else false,
            .b = @intFromEnum(base) >= 8,
        };
    }

    /// Loads `[base + index*scale + disp]` into `dst` (full 64-bit GPR),
    /// sign/zero-extending from `width` bytes per `signed`.
    fn movLoad(self: *Ctx, dst: Reg, base: Reg, index: ?Reg, scale: u8, disp: i32, width: u8, signed: bool) !void {
        const bits = regBits(@intFromEnum(dst), base, index);
        switch (width) {
            8 => {
                try self.maybeRex(true, bits.r, bits.x, bits.b);
                try self.emitByte(0x8B);
            },
            4 => {
                if (signed) {
                    try self.maybeRex(true, bits.r, bits.x, bits.b); // MOVSXD
                    try self.emitByte(0x63);
                } else {
                    try self.maybeRex(false, bits.r, bits.x, bits.b);
                    try self.emitByte(0x8B);
                }
            },
            2 => {
                try self.maybeRex(true, bits.r, bits.x, bits.b);
                try self.emitByte(0x0F);
                try self.emitByte(if (signed) 0xBF else 0xB7);
            },
            1 => {
                try self.maybeRex(true, bits.r, bits.x, bits.b);
                try self.emitByte(0x0F);
                try self.emitByte(if (signed) 0xBE else 0xB6);
            },
            else => unreachable,
        }
        try self.memModRM(@intFromEnum(dst), base, index, scale, disp);
    }

    /// `lea dst, [base + disp]` (`REX.W 8D /r`) — computes an address without
    /// dereferencing. Used to form the interior pointer of an inline aggregate
    /// field (a fixed-size array `[N]T` field lives inline in its struct body).
    fn lea(self: *Ctx, dst: Reg, base: Reg, disp: i32) !void {
        const bits = regBits(@intFromEnum(dst), base, null);
        try self.maybeRex(true, bits.r, bits.x, bits.b);
        try self.emitByte(0x8D);
        try self.memModRM(@intFromEnum(dst), base, null, 1, disp);
    }

    /// Stores the low `width` bytes of `src` to `[base + index*scale + disp]`.
    fn movStore(self: *Ctx, base: Reg, index: ?Reg, scale: u8, disp: i32, src: Reg, width: u8) !void {
        const bits = regBits(@intFromEnum(src), base, index);
        switch (width) {
            8 => {
                try self.maybeRex(true, bits.r, bits.x, bits.b);
                try self.emitByte(0x89);
            },
            4 => {
                try self.maybeRex(false, bits.r, bits.x, bits.b);
                try self.emitByte(0x89);
            },
            2 => {
                try self.emitByte(0x66);
                try self.maybeRex(false, bits.r, bits.x, bits.b);
                try self.emitByte(0x89);
            },
            1 => {
                // Always force REX (even a bare 0x40) so a src in {rsi,rdi,
                // rbp,rsp}'s low nibble reads as the new SIL/DIL/BPL/SPL
                // encoding, never the legacy AH/CH/DH/BH one.
                try self.emitByte(rex(false, bits.r, bits.x, bits.b));
                try self.emitByte(0x88);
            },
            else => unreachable,
        }
        try self.memModRM(@intFromEnum(src), base, index, scale, disp);
    }

    // ---- atomics (§11.5) ---------------------------------------------------
    // Memory-destination RMW forms with the operand register in `reg` and the
    // target at `[base]` (disp=0). `lock` prepends the `F0` prefix; width picks
    // the operand size (0x66 for 2, REX.W for 8). XCHG-with-memory is
    // implicitly locked, so it never needs the prefix.

    /// `[lock] 0F <op8|op> [base], reg` — CMPXCHG (op8=B0, op=B1) and
    /// XADD (op8=C0, op=C1); both are `0F`-prefixed at every width.
    fn atomic0F(self: *Ctx, lock: bool, op8: u8, op: u8, reg: Reg, base: Reg, width: u8) !void {
        if (lock) try self.emitByte(0xF0);
        if (width == 2) try self.emitByte(0x66);
        const bits = regBits(@intFromEnum(reg), base, null);
        // width 1 forces a REX even when otherwise unneeded, so a src in
        // {rsi,rdi,rbp,rsp} reads as the new low-byte encoding (as `movStore`).
        if (width == 1) try self.emitByte(rex(false, bits.r, bits.x, bits.b)) else try self.maybeRex(width == 8, bits.r, bits.x, bits.b);
        try self.emitByte(0x0F);
        try self.emitByte(if (width == 1) op8 else op);
        try self.memModRM(@intFromEnum(reg), base, null, 1, 0);
    }
    fn lockCmpxchgMem(self: *Ctx, reg: Reg, base: Reg, width: u8) !void {
        try self.atomic0F(true, 0xB0, 0xB1, reg, base, width);
    }
    fn lockXaddMem(self: *Ctx, reg: Reg, base: Reg, width: u8) !void {
        try self.atomic0F(true, 0xC0, 0xC1, reg, base, width);
    }
    /// `XCHG [base], reg` (`86`/`87`) — a memory operand makes it implicitly
    /// locked, so no `F0` prefix is emitted.
    fn xchgMem(self: *Ctx, reg: Reg, base: Reg, width: u8) !void {
        if (width == 2) try self.emitByte(0x66);
        const bits = regBits(@intFromEnum(reg), base, null);
        if (width == 1) try self.emitByte(rex(false, bits.r, bits.x, bits.b)) else try self.maybeRex(width == 8, bits.r, bits.x, bits.b);
        try self.emitByte(if (width == 1) 0x86 else 0x87);
        try self.memModRM(@intFromEnum(reg), base, null, 1, 0);
    }
    /// `MFENCE` (`0F AE F0`) — full barrier after a seq-cst store.
    fn mfence(self: *Ctx) !void {
        try self.emitByte(0x0F);
        try self.emitByte(0xAE);
        try self.emitByte(0xF0);
    }
    /// `Jcc rel32` to an already-emitted local byte offset (the CAS retry
    /// label) — a backward branch inside one instruction's own codegen.
    fn jccToOffset(self: *Ctx, cc: u4, target_off: u32) !void {
        try self.emitByte(0x0F);
        try self.emitByte(0x80 | @as(u8, cc));
        const next: i64 = @as(i64, @intCast(self.code.items.len)) + 4;
        try self.emitI32(@intCast(@as(i64, target_off) - next));
    }

    // ---- SSE2 scalar float --------------------------------------------------

    fn fPrefix(width: u8) u8 {
        return if (width == 8) 0xF2 else 0xF3; // movsd family vs movss family
    }

    fn movFRR(self: *Ctx, dst: XReg, src: XReg, width: u8) !void {
        if (dst == src) return;
        try self.emitByte(fPrefix(width));
        try self.maybeRex(false, @intFromEnum(dst) >= 8, false, @intFromEnum(src) >= 8);
        try self.emitByte(0x0F);
        try self.emitByte(0x10);
        try self.emitByte(modrmRegByte(@intFromEnum(dst), @intFromEnum(src)));
    }

    /// `index`/`scale` follow `movLoad`'s convention (array element addressing);
    /// pass `null, 1` for a plain `[base + disp]` operand (field access).
    fn movFLoad(self: *Ctx, dst: XReg, base: Reg, index: ?Reg, scale: u8, disp: i32, width: u8) !void {
        try self.emitByte(fPrefix(width));
        const bits = regBits(@intFromEnum(dst), base, index);
        try self.maybeRex(false, bits.r, bits.x, bits.b);
        try self.emitByte(0x0F);
        try self.emitByte(0x10);
        try self.memModRM(@intFromEnum(dst), base, index, scale, disp);
    }

    fn movFStore(self: *Ctx, base: Reg, index: ?Reg, scale: u8, disp: i32, src: XReg, width: u8) !void {
        try self.emitByte(fPrefix(width));
        const bits = regBits(@intFromEnum(src), base, index);
        try self.maybeRex(false, bits.r, bits.x, bits.b);
        try self.emitByte(0x0F);
        try self.emitByte(0x11);
        try self.memModRM(@intFromEnum(src), base, index, scale, disp);
    }

    const FArithOp = enum { add, sub, mul, div };
    fn fArithOpcode(op: FArithOp) u8 {
        return switch (op) {
            .add => 0x58,
            .sub => 0x5C,
            .mul => 0x59,
            .div => 0x5E,
        };
    }
    /// `dst <op>= src` (scalar double/single per `width`).
    fn fArithRR(self: *Ctx, op: FArithOp, dst: XReg, src: XReg, width: u8) !void {
        try self.emitByte(fPrefix(width));
        try self.maybeRex(false, @intFromEnum(dst) >= 8, false, @intFromEnum(src) >= 8);
        try self.emitByte(0x0F);
        try self.emitByte(fArithOpcode(op));
        try self.emitByte(modrmRegByte(@intFromEnum(dst), @intFromEnum(src)));
    }

    /// Ordered compare setting ZF/PF/CF (`ucomisd`/`ucomiss`); flags per
    /// module doc comment's `fcmp_*` derivation.
    fn ucomis(self: *Ctx, a: XReg, b: XReg, width: u8) !void {
        if (width == 8) try self.emitByte(0x66);
        try self.maybeRex(false, @intFromEnum(a) >= 8, false, @intFromEnum(b) >= 8);
        try self.emitByte(0x0F);
        try self.emitByte(0x2E);
        try self.emitByte(modrmRegByte(@intFromEnum(a), @intFromEnum(b)));
    }

    fn xorpX(self: *Ctx, dst: XReg, src: XReg, width: u8) !void {
        if (width == 8) try self.emitByte(0x66);
        try self.maybeRex(false, @intFromEnum(dst) >= 8, false, @intFromEnum(src) >= 8);
        try self.emitByte(0x0F);
        try self.emitByte(0x57);
        try self.emitByte(modrmRegByte(@intFromEnum(dst), @intFromEnum(src)));
    }

    /// `movq xmm, r64` (width 8) or `movd xmm, r32` (width 4) — materializes
    /// a float constant's raw bit pattern out of a GPR.
    fn movXG(self: *Ctx, dst: XReg, src: Reg, width: u8) !void {
        try self.emitByte(0x66);
        try self.maybeRex(width == 8, @intFromEnum(dst) >= 8, false, @intFromEnum(src) >= 8);
        try self.emitByte(0x0F);
        try self.emitByte(0x6E);
        try self.emitByte(modrmRegByte(@intFromEnum(dst), @intFromEnum(src)));
    }

    // ---- integer width conversion (movsx/movzx/movsxd) ----------------------
    // Each re-represents `reg`'s low `width` bytes as a full 64-bit value: sign-
    // extend (signed) or zero-extend (unsigned). Used by `emitConvert` (§12.9).
    fn ext0F(self: *Ctx, opcode: u8, dst: Reg, src: Reg) !void {
        try self.maybeRex(true, @intFromEnum(dst) >= 8, false, @intFromEnum(src) >= 8);
        try self.emitByte(0x0F);
        try self.emitByte(opcode);
        try self.emitByte(modrmRegByte(@intFromEnum(dst), @intFromEnum(src)));
    }
    /// Canonicalize `reg` from a `width`-byte value to a full 64-bit register.
    fn extendReg(self: *Ctx, reg: Reg, width: u8, signed: bool) !void {
        switch (width) {
            1 => try self.ext0F(if (signed) 0xBE else 0xB6, reg, reg), // movsx/movzx r64, r/m8
            2 => try self.ext0F(if (signed) 0xBF else 0xB7, reg, reg), // movsx/movzx r64, r/m16
            4 => if (signed) {
                try self.maybeRex(true, @intFromEnum(reg) >= 8, false, @intFromEnum(reg) >= 8);
                try self.emitByte(0x63); // movsxd r64, r/m32
                try self.emitByte(modrmRegByte(@intFromEnum(reg), @intFromEnum(reg)));
            } else {
                // mov r32, r/m32 zero-extends the low 32 bits into the full 64.
                try self.maybeRex(false, @intFromEnum(reg) >= 8, false, @intFromEnum(reg) >= 8);
                try self.emitByte(0x8B);
                try self.emitByte(modrmRegByte(@intFromEnum(reg), @intFromEnum(reg)));
            },
            else => {}, // 8 bytes: already the full register
        }
    }

    // ---- int↔float / float↔float conversion (SSE) ---------------------------
    /// `cvtsi2sd/ss xmm, r64` — a signed 64-bit int to `fwidth`-byte float.
    fn cvtI2F(self: *Ctx, dst: XReg, src: Reg, fwidth: u8) !void {
        try self.emitByte(if (fwidth == 8) 0xF2 else 0xF3);
        try self.maybeRex(true, @intFromEnum(dst) >= 8, false, @intFromEnum(src) >= 8);
        try self.emitByte(0x0F);
        try self.emitByte(0x2A);
        try self.emitByte(modrmRegByte(@intFromEnum(dst), @intFromEnum(src)));
    }
    /// `cvttsd2si/cvttss2si r64, xmm` — a `fwidth`-byte float to a signed 64-bit
    /// int, truncating toward zero (SPEC §12.9).
    fn cvtF2I(self: *Ctx, dst: Reg, src: XReg, fwidth: u8) !void {
        try self.emitByte(if (fwidth == 8) 0xF2 else 0xF3);
        try self.maybeRex(true, @intFromEnum(dst) >= 8, false, @intFromEnum(src) >= 8);
        try self.emitByte(0x0F);
        try self.emitByte(0x2C);
        try self.emitByte(modrmRegByte(@intFromEnum(dst), @intFromEnum(src)));
    }
    /// `cvtsd2ss` (from_width 8) / `cvtss2sd` (from_width 4) — float to float.
    fn cvtF2F(self: *Ctx, dst: XReg, src: XReg, from_width: u8) !void {
        try self.emitByte(if (from_width == 8) 0xF2 else 0xF3);
        try self.maybeRex(false, @intFromEnum(dst) >= 8, false, @intFromEnum(src) >= 8);
        try self.emitByte(0x0F);
        try self.emitByte(0x5A);
        try self.emitByte(modrmRegByte(@intFromEnum(dst), @intFromEnum(src)));
    }

    // ---- calls / jumps (relocations & intra-function fixups) ---------------

    fn emitCallReloc(self: *Ctx, symbol: []const u8) !void {
        try self.emitByte(0xE8);
        const off: u32 = @intCast(self.code.items.len);
        try self.emitU32(0);
        try self.relocs.append(self.gpa, .{ .offset = off, .symbol = symbol });
    }

    fn emitJumpFixup(self: *Ctx, opcode_bytes: []const u8, target: ir.BlockId) !void {
        try self.code.appendSlice(self.gpa, opcode_bytes);
        const off: u32 = @intCast(self.code.items.len);
        try self.emitU32(0);
        try self.jump_fixups.append(self.gpa, .{ .patch_offset = off, .target = target });
    }
    fn jmpRel32(self: *Ctx, target: ir.BlockId) !void {
        try self.emitJumpFixup(&.{0xE9}, target);
    }
    fn jccRel32(self: *Ctx, cc: u4, target: ir.BlockId) !void {
        try self.emitJumpFixup(&.{ 0x0F, 0x80 | cc }, target);
    }

    /// Emits `Jcc rel32` with a placeholder displacement, returning the byte
    /// offset of the 4-byte field so the caller can resolve it immediately
    /// (via `patchRel32Here`) once the "not taken" path's code is known —
    /// used for `br`'s in-function skip-over, distinct from
    /// `jccRel32`/`jump_fixups` which target a real `BlockId` resolved only
    /// after every block's offset is known.
    fn emitCondJumpPlaceholder(self: *Ctx, cc: u4) !u32 {
        try self.emitByte(0x0F);
        try self.emitByte(0x80 | @as(u8, cc));
        const off: u32 = @intCast(self.code.items.len);
        try self.emitU32(0);
        return off;
    }

    /// Patches the rel32 field at `patch_offset` (from `emitCondJumpPlaceholder`)
    /// to land exactly at the current end of `code` — i.e. "jump to here".
    fn patchRel32Here(self: *Ctx, patch_offset: u32) void {
        const rel: i64 = @as(i64, @intCast(self.code.items.len)) - @as(i64, patch_offset + 4);
        const rel32: i32 = @intCast(rel);
        const bits: u32 = @bitCast(rel32);
        self.code.items[patch_offset] = @truncate(bits);
        self.code.items[patch_offset + 1] = @truncate(bits >> 8);
        self.code.items[patch_offset + 2] = @truncate(bits >> 16);
        self.code.items[patch_offset + 3] = @truncate(bits >> 24);
    }

    fn patchJumpFixups(self: *Ctx) void {
        for (self.jump_fixups.items) |fx| {
            const target_off = self.block_offsets[@intFromEnum(fx.target)];
            const rel: i64 = @as(i64, target_off) - @as(i64, fx.patch_offset + 4);
            const rel32: i32 = @intCast(rel);
            const bits: u32 = @bitCast(rel32);
            self.code.items[fx.patch_offset] = @truncate(bits);
            self.code.items[fx.patch_offset + 1] = @truncate(bits >> 8);
            self.code.items[fx.patch_offset + 2] = @truncate(bits >> 16);
            self.code.items[fx.patch_offset + 3] = @truncate(bits >> 24);
        }
    }
};

const JumpFixup = struct { patch_offset: u32, target: ir.BlockId };

/// Condition-code nibbles for `Jcc`/`SETcc` (Intel encoding).
const CC = struct {
    const e: u4 = 0x4;
    const ne: u4 = 0x5;
    const b: u4 = 0x2;
    const ae: u4 = 0x3;
    const be: u4 = 0x6;
    const a: u4 = 0x7;
    const l: u4 = 0xC;
    const ge: u4 = 0xD;
    const le: u4 = 0xE;
    const g: u4 = 0xF;
    const p: u4 = 0xA;
    const np: u4 = 0xB;
};

// ============================================================================
// Frame layout
// ============================================================================

const FrameInfo = struct {
    saved_gpr: []const Reg,
    saved_xmm: []const XReg,
    num_spill_slots: u32,
    frame_size: u32,

    fn spillOffset(self: FrameInfo, slot: u32) i32 {
        return -(@as(i32, @intCast(8 * self.saved_gpr.len)) + @as(i32, @intCast(8 * (slot + 1))));
    }
    fn xmmSaveOffset(self: FrameInfo, i: usize) i32 {
        return -(@as(i32, @intCast(8 * self.saved_gpr.len)) + @as(i32, @intCast(8 * self.num_spill_slots)) + @as(i32, @intCast(8 * (i + 1))));
    }
};

/// Rounds `raw` up so that, after `saved_count` 8-byte pushes following
/// `push rbp` (which itself lands `rsp` 16-aligned), `sub rsp, <result>`
/// leaves `rsp` 16-aligned for any `call` inside the body.
fn alignFrame(raw: u32, saved_count: u32) u32 {
    const needed_mod: u32 = if (saved_count % 2 == 0) 0 else 8;
    const rem = raw % 16;
    if (rem == needed_mod) return raw;
    const diff = if (rem < needed_mod) needed_mod - rem else 16 - (rem - needed_mod);
    return raw + diff;
}

// ============================================================================
// Parallel move sequencing (SSA block-param resolution, argument binding —
// see module doc comment / this file's design notes on why a naive
// sequential emission of "independent" moves can silently clobber a value
// still needed by another move in the same batch)
// ============================================================================

const PLoc = union(enum) { reg: u4, mem: i32 };
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
                .mem => |m| try self.movStore(.rbp, null, 1, m, @enumFromInt(fr), 8),
            },
            .mem => |fm| switch (to) {
                .reg => |tr| try self.movLoad(@enumFromInt(tr), .rbp, null, 1, fm, 8, false),
                .mem => |tm| {
                    try self.movLoad(scratch1, .rbp, null, 1, fm, 8, false);
                    try self.movStore(.rbp, null, 1, tm, scratch1, 8);
                },
            },
        },
        .float => switch (from) {
            .reg => |fr| switch (to) {
                .reg => |tr| try self.movFRR(@enumFromInt(tr), @enumFromInt(fr), 8),
                .mem => |m| try self.movFStore(.rbp, null, 1, m, @enumFromInt(fr), 8),
            },
            .mem => |fm| switch (to) {
                .reg => |tr| try self.movFLoad(@enumFromInt(tr), .rbp, null, 1, fm, 8),
                .mem => |tm| {
                    try self.movFLoad(fscratch1, .rbp, null, 1, fm, 8);
                    try self.movFStore(.rbp, null, 1, tm, fscratch1, 8);
                },
            },
        },
    }
}

/// Emits `moves` such that every destination receives exactly the source
/// value it would under true-parallel semantics, even when sources and
/// destinations alias (register swaps/rotations). Two-phase: drain every
/// move whose destination is not needed as another pending move's source
/// (a plain topological order), then break any remaining cycles one at a
/// time via a scratch register. Bounded by `moves.len` (<= the register
/// file size, a small compile-time-ish constant).
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
        try emitMove(self, cycle.items[0].to, scratch, class); // save the value about to be overwritten
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
            try self.movLoad(scratch, .rbp, null, 1, self.frame.spillOffset(slot), 8, false);
            break :blk scratch;
        },
    };
}

fn putInt(self: *Ctx, vreg: u32, src: Reg) !void {
    switch (regLocOf(self, vreg)) {
        .reg => |idx| try self.movRR(self.int_regs[idx], src),
        .spill => |slot| try self.movStore(.rbp, null, 1, self.frame.spillOffset(slot), src, 8),
    }
}

fn getFloat(self: *Ctx, vreg: u32, scratch: XReg) !XReg {
    return switch (regLocOf(self, vreg)) {
        .reg => |idx| self.float_regs[idx],
        .spill => |slot| blk: {
            try self.movFLoad(scratch, .rbp, null, 1, self.frame.spillOffset(slot), 8);
            break :blk scratch;
        },
    };
}

fn putFloat(self: *Ctx, vreg: u32, src: XReg) !void {
    switch (regLocOf(self, vreg)) {
        .reg => |idx| try self.movFRR(self.float_regs[idx], src, 8),
        .spill => |slot| try self.movFStore(.rbp, null, 1, self.frame.spillOffset(slot), src, 8),
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

// ============================================================================
// Instruction selection
// ============================================================================

fn vregOf(self: *Ctx, v: ir.ValueId) u32 {
    return self.inst_to_vreg[@intFromEnum(v)];
}

/// Re-narrow a freshly-computed result in `reg` to its type width, restoring
/// the width-canonical invariant (see module doc comment). A no-op for the
/// 64-bit and non-int classes, where the register width already equals the
/// type width.
fn canonNarrow(self: *Ctx, reg: Reg, w: Width) !void {
    if (w.class == .int and w.bytes < 8) try self.extendReg(reg, w.bytes, w.signed);
}

fn emitBinaryInt(self: *Ctx, op: Ctx.ArithOp, dst: u32, lhs: ir.ValueId, rhs: ir.ValueId, w: Width) !void {
    const l = try getInt(self, vregOf(self, lhs), scratch1);
    const r = try getInt(self, vregOf(self, rhs), scratch2);
    try self.movRR(scratch1, l);
    try self.arithRR(op, scratch1, r);
    // `add`/`sub` can overflow past the type width; bitwise `and`/`or`/`xor`
    // (the other `arithRR` ops) preserve canonical operands, so skip them.
    if (op == .add or op == .sub) try canonNarrow(self, scratch1, w);
    try putInt(self, dst, scratch1);
}

fn emitMulInt(self: *Ctx, dst: u32, lhs: ir.ValueId, rhs: ir.ValueId, w: Width) !void {
    const l = try getInt(self, vregOf(self, lhs), scratch1);
    const r = try getInt(self, vregOf(self, rhs), scratch2);
    try self.movRR(scratch1, l);
    try self.imulRR(scratch1, r);
    try canonNarrow(self, scratch1, w);
    try putInt(self, dst, scratch1);
}

/// `sdiv`/`udiv`/`srem`/`urem` — the function containing this was already
/// forced (by `buildIntervals`'s prescan) to exclude `rax`/`rdx` from
/// allocation, so neither operand's real register can ever alias them.
fn emitDivInt(self: *Ctx, op: ir.Op, dst: u32, lhs: ir.ValueId, rhs: ir.ValueId) !void {
    const l = try getInt(self, vregOf(self, lhs), scratch1);
    const r = try getInt(self, vregOf(self, rhs), scratch2);
    try self.movRR(.rax, l);
    const signed = op == .sdiv or op == .srem;
    if (signed) try self.cqo() else try self.zero32(.rdx);
    if (signed) try self.idivR(r) else try self.divR(r);
    const result_reg: Reg = if (op == .sdiv or op == .udiv) .rax else .rdx;
    try putInt(self, dst, result_reg);
}

fn emitUnaryInt(self: *Ctx, op: ir.Op, dst: u32, operand: ir.ValueId, w: Width) !void {
    const v = try getInt(self, vregOf(self, operand), scratch1);
    try self.movRR(scratch1, v);
    switch (op) {
        .neg => try self.negR(scratch1), // two's-complement negate sets high bits
        .bnot => try self.notR(scratch1), // bitwise-not sets every bit above width
        else => unreachable,
    }
    try canonNarrow(self, scratch1, w);
    try putInt(self, dst, scratch1);
}

/// `T(x)` numeric conversion (§12.9). The four class combinations: int↔int
/// (extend/truncate to the destination width), int→float (`cvtsi2*`), float→int
/// (`cvtt*2si`, truncating), float→float (`cvt*2*`). Int operands are first
/// canonicalized to their true 64-bit value from the *source* width, then
/// re-canonicalized to the destination width — correct whether widening,
/// narrowing, or same-size. (Unsigned 64-bit ↔ float uses the signed path; a
/// value with bit 63 set is out of range — a documented v1 limit.)
fn emitConvert(self: *Ctx, dst: u32, src: ir.ValueId, dst_ty: TypeId) !void {
    const sw = widthOf(self.tctx(), self.f.valueType(src));
    const dw = widthOf(self.tctx(), dst_ty);
    if (sw.class == .int and dw.class == .int) {
        const r = try getInt(self, vregOf(self, src), scratch1);
        try self.movRR(scratch1, r);
        try self.extendReg(scratch1, sw.bytes, sw.signed);
        try self.extendReg(scratch1, dw.bytes, dw.signed);
        try putInt(self, dst, scratch1);
    } else if (sw.class == .int and dw.class == .float) {
        const r = try getInt(self, vregOf(self, src), scratch1);
        try self.movRR(scratch1, r);
        try self.extendReg(scratch1, sw.bytes, sw.signed);
        try self.cvtI2F(fscratch1, scratch1, dw.bytes);
        try putFloat(self, dst, fscratch1);
    } else if (sw.class == .float and dw.class == .int) {
        const x = try getFloat(self, vregOf(self, src), fscratch1);
        try self.cvtF2I(scratch1, x, sw.bytes);
        try self.extendReg(scratch1, dw.bytes, dw.signed);
        try putInt(self, dst, scratch1);
    } else {
        const x = try getFloat(self, vregOf(self, src), fscratch1);
        if (sw.bytes == dw.bytes) {
            try self.movFRR(fscratch1, x, sw.bytes);
        } else {
            try self.cvtF2F(fscratch1, x, sw.bytes);
        }
        try putFloat(self, dst, fscratch1);
    }
}

/// Peeks whether `v` is a `const_int` instruction, returning its value
/// masked to a valid 0-63 shift count when so — used to pick the immediate
/// shift-count encoding over the `cl`-register form.
fn constShiftAmount(f: *const ir.Function, v: ir.ValueId) ?u6 {
    if (f.insts.items(.op)[@intFromEnum(v)] != .const_int) return null;
    const val = f.decode(v).const_int;
    return @truncate(@as(u64, @bitCast(val)));
}

fn emitShiftInt(self: *Ctx, op: Ctx.ShiftOp, dst: u32, lhs: ir.ValueId, rhs: ir.ValueId, w: Width) !void {
    const l = try getInt(self, vregOf(self, lhs), scratch1);
    try self.movRR(scratch1, l);
    if (constShiftAmount(self.f, rhs)) |amt| {
        try self.shiftImm(op, scratch1, amt);
    } else {
        const r = try getInt(self, vregOf(self, rhs), scratch2);
        try self.movRR(.rcx, r);
        try self.shiftCl(op, scratch1);
    }
    // Only `shl` (`.shl`) pushes bits past the type width; `shr`/`sar` keep a
    // canonical operand canonical, so a full-width right shift needs no mask.
    if (op == .shl) try canonNarrow(self, scratch1, w);
    try putInt(self, dst, scratch1);
}

const icmp_cc = std.EnumMap(ir.Op, u4).init(.{
    .icmp_eq = CC.e,
    .icmp_ne = CC.ne,
    .icmp_slt = CC.l,
    .icmp_sle = CC.le,
    .icmp_sgt = CC.g,
    .icmp_sge = CC.ge,
    .icmp_ult = CC.b,
    .icmp_ule = CC.be,
    .icmp_ugt = CC.a,
    .icmp_uge = CC.ae,
});

fn emitIcmp(self: *Ctx, op: ir.Op, dst: u32, lhs: ir.ValueId, rhs: ir.ValueId) !void {
    const l = try getInt(self, vregOf(self, lhs), scratch1);
    const r = try getInt(self, vregOf(self, rhs), scratch2);
    try self.arithRR(.cmp, l, r);
    // `setcc` must read the flags `cmp` just set — capture the byte first,
    // then zero-extend it. Zeroing `scratch1` beforehand would clobber those
    // flags (its `xor` forces ZF=1), making every comparison read as false.
    try self.setcc(icmp_cc.get(op).?, scratch1);
    try self.movzxb(scratch1, scratch1);
    try putInt(self, dst, scratch1);
}

fn emitFcmp(self: *Ctx, op: ir.Op, dst: u32, lhs: ir.ValueId, rhs: ir.ValueId, width: u8) !void {
    const l = try getFloat(self, vregOf(self, lhs), fscratch1);
    const r = try getFloat(self, vregOf(self, rhs), fscratch2);
    // As in `emitIcmp`, `setcc` must read the flags the `ucomis` just set, so
    // the destination is widened with a trailing `movzxb` rather than zeroed
    // up front — a `zero32` between the compare and the `setcc` would clobber
    // those flags. The eq/ne paths combine two `setcc` bytes (both reading the
    // same `ucomis` result; `setcc`/`and8`/`or8` on the low byte are enough,
    // and the final `movzxb` produces a clean 0/1).
    switch (op) {
        .fcmp_gt, .fcmp_ge => {
            try self.ucomis(l, r, width);
            try self.setcc(if (op == .fcmp_gt) CC.a else CC.ae, scratch1);
        },
        .fcmp_lt, .fcmp_le => {
            try self.ucomis(r, l, width); // swapped: lhs<rhs === rhs>lhs
            try self.setcc(if (op == .fcmp_lt) CC.a else CC.ae, scratch1);
        },
        .fcmp_eq => {
            try self.ucomis(l, r, width);
            try self.setcc(CC.np, scratch2); // ordered
            try self.setcc(CC.e, scratch1); // equal
            try self.and8(scratch1, scratch2);
        },
        .fcmp_ne => {
            try self.ucomis(l, r, width);
            try self.setcc(CC.p, scratch2); // unordered
            try self.setcc(CC.ne, scratch1); // not equal
            try self.or8(scratch1, scratch2);
        },
        else => unreachable,
    }
    try self.movzxb(scratch1, scratch1);
    try putInt(self, dst, scratch1);
}

fn emitBinaryFloat(self: *Ctx, op: Ctx.FArithOp, dst: u32, lhs: ir.ValueId, rhs: ir.ValueId, width: u8) !void {
    const l = try getFloat(self, vregOf(self, lhs), fscratch1);
    const r = try getFloat(self, vregOf(self, rhs), fscratch2);
    try self.movFRR(fscratch1, l, width);
    try self.fArithRR(op, fscratch1, r, width);
    try putFloat(self, dst, fscratch1);
}

/// `-x` via `0.0 - x` (no sign-mask constant needed — see module doc comment).
fn emitFneg(self: *Ctx, dst: u32, operand: ir.ValueId, width: u8) !void {
    const v = try getFloat(self, vregOf(self, operand), fscratch2);
    try self.xorpX(fscratch1, fscratch1, width);
    try self.fArithRR(.sub, fscratch1, v, width);
    try putFloat(self, dst, fscratch1);
}

/// `const_string` loads the address of its static string header (`__bitstr_N`,
/// where `N` is the string-pool index) — the compiler driver emits that header
/// (`{ptr,len}` + the bytes) into the object's `.rodata` under this same name.
/// v1 string literals are static, so the value is a plain pointer, no GC.
fn emitConstString(self: *Ctx, dst: u32, pool_idx: u32) !void {
    const name = try std.fmt.allocPrint(self.gpa, "__bitstr_{d}", .{pool_idx});
    try self.owned_syms.append(self.gpa, name);
    try self.movAbsReloc(scratch1, name);
    try putInt(self, dst, scratch1);
}

/// `gc_alloc`: load the static `TypeInfo` blob's address into arg0 and call
/// `bit_rt_gc_alloc`, which returns the zeroed body pointer. This is a real
/// call and a GC point, so — like `emitCallLike` — it records a safepoint at
/// the return address so a collection triggered by the allocation finds the
/// caller's live pointers in the stack map (`collectSafepoints`/`scanFuncFlags`
/// count `gc_alloc` as a safepoint site so the slot exists).
fn emitGcAlloc(self: *Ctx, dst: u32, size: u32, ptr_offsets: []const u32) !void {
    const disc: u32 = @intFromEnum(self.f.valueType(@enumFromInt(dst)));
    const name = try ir.typeInfoSymbol(self.gpa, disc, size, ptr_offsets);
    try self.owned_syms.append(self.gpa, name);
    const arg0: Reg = if (self.cc == .win64) .rcx else .rdi; // SysV rdi / Win64 rcx
    try self.movAbsReloc(arg0, name);
    if (self.cc == .win64) try self.rspAddSub(true, 32);
    try self.emitCallReloc("bit_rt_gc_alloc");
    self.safepoint_code_offsets[self.next_safepoint_idx] = @intCast(self.code.items.len);
    self.next_safepoint_idx += 1;
    if (self.cc == .win64) try self.rspAddSub(false, 32);
    try putInt(self, dst, .rax);
}

/// `type_info`: materialize the address of a named type's static `TypeInfo`
/// blob. Not a call and not a GC point — the descriptor is a `.rodata` constant
/// (its non-reference result type keeps it out of the stack map).
fn emitTypeInfo(self: *Ctx, dst: u32, disc: u32, size: u32, ptr_offsets: []const u32) !void {
    const name = try ir.typeInfoSymbol(self.gpa, disc, size, ptr_offsets);
    try self.owned_syms.append(self.gpa, name);
    try self.movAbsReloc(.rax, name);
    try putInt(self, dst, .rax);
}

/// A closure value is a pointer to a 16-byte GC cell `{ code_ptr, env_ptr }`:
/// the code pointer at +0 (into `.text`, never a GC ref) and the captured
/// environment at +8 (the cell's one GC field). This keeps a closure a single
/// word, so it flows through the register allocator like any other reference.
const closure_cell_size: u32 = 16;
const closure_cell_ptr_offsets = [_]u32{8};

/// `make_closure`: allocate the `{code, env}` cell (a GC point, like
/// `emitGcAlloc`), then store the target function's address at +0 and the
/// already-materialized environment pointer at +8.
fn emitMakeClosure(self: *Ctx, dst: u32, func: ir.FuncId, env: ir.ValueId) !void {
    const disc: u32 = @intFromEnum(self.f.valueType(@enumFromInt(dst)));
    const ti = try ir.typeInfoSymbol(self.gpa, disc, closure_cell_size, &closure_cell_ptr_offsets);
    try self.owned_syms.append(self.gpa, ti);
    const arg0: Reg = if (self.cc == .win64) .rcx else .rdi;
    try self.movAbsReloc(arg0, ti);
    if (self.cc == .win64) try self.rspAddSub(true, 32);
    try self.emitCallReloc("bit_rt_gc_alloc");
    self.safepoint_code_offsets[self.next_safepoint_idx] = @intCast(self.code.items.len);
    self.next_safepoint_idx += 1;
    if (self.cc == .win64) try self.rspAddSub(false, 32);
    // rax = cell. The function name is module-owned (outlives this reloc list).
    try self.movAbsReloc(scratch1, self.module.func(func).name);
    try self.movStore(.rax, null, 1, 0, scratch1, 8);
    const env_reg = try getInt(self, vregOf(self, env), scratch1);
    try self.movStore(.rax, null, 1, 8, env_reg, 8);
    try putInt(self, dst, .rax);
}

/// `func_addr`: materialize a function's code address into `dst` via an
/// absolute relocation to its own symbol (the same primitive `make_closure`
/// uses to fill a cell's code slot, minus the cell). No call, no safepoint.
fn emitFuncAddr(self: *Ctx, dst: u32, func: ir.FuncId) !void {
    try self.movAbsReloc(scratch1, self.module.func(func).name);
    try putInt(self, dst, scratch1);
}

/// `call_value`: dispatch through a closure. Load the environment (+8) and
/// code pointer (+0) into reserved scratch regs that argument marshaling never
/// disturbs (r10/r12 are not argument registers; r11 is the parallel-move
/// cycle temp), marshal the real arguments into arg1.., place the environment
/// in arg0, then call indirectly. A call is a GC point, so it records a
/// safepoint at the return address like `emitCallLike`.
fn emitCallValue(self: *Ctx, dst: u32, ty: TypeId, callee: ir.ValueId, args: []const u32) CodegenError!void {
    const cell = try getInt(self, vregOf(self, callee), scratch1);
    try self.movLoad(scratch2, cell, null, 1, 8, 8, false); // r10 = env
    try self.movLoad(scratch3, cell, null, 1, 0, 8, false); // r12 = code
    const arg_reserve = try marshalArgs(self, args, 1, 1, 0);
    const arg0: Reg = if (self.cc == .win64) .rcx else .rdi;
    try self.movRR(arg0, scratch2);
    if (self.cc == .win64) try self.rspAddSub(true, 32);
    try self.callReg(scratch3);
    self.safepoint_code_offsets[self.next_safepoint_idx] = @intCast(self.code.items.len);
    self.next_safepoint_idx += 1;
    if (self.cc == .win64) try self.rspAddSub(false, 32);
    if (arg_reserve > 0) try self.rspAddSub(false, arg_reserve); // reclaim SysV stack args
    if (self.tctx().typeOf(ty) != .void) switch (classOf(self.tctx(), ty)) {
        .int => try putInt(self, dst, .rax),
        .float => try putFloat(self, dst, .xmm0),
    };
}

/// `call_iface`: structural interface dispatch (ABI.md §2.1). Load the receiver
/// object's `TypeInfo` (`*(recv - 32)`, the header's `info` field), resolve the
/// method id to a code address via `bit_rt_iface_lookup`, then call it with the
/// receiver as arg0. The lookup itself never collects, so only the final
/// (indirect) method call records a safepoint — like `emitCallValue`. The
/// receiver is reloaded from its vreg after the lookup call (its home is a
/// callee-saved reg or spill slot, both surviving the call).
fn emitCallIface(self: *Ctx, dst: u32, ty: TypeId, iface_val: ir.ValueId, method_id: u32, args: []const u32) CodegenError!void {
    const recv = try getInt(self, vregOf(self, iface_val), scratch1);
    try self.movLoad(scratch2, recv, null, 1, -32, 8, false); // r10 = info = *(recv - 32)
    const arg0: Reg = if (self.cc == .win64) .rcx else .rdi;
    const arg1: Reg = if (self.cc == .win64) .rdx else .rsi;
    try self.movRR(arg0, scratch2);
    try self.movRI(arg1, @intCast(method_id));
    if (self.cc == .win64) try self.rspAddSub(true, 32);
    try self.emitCallReloc("bit_rt_iface_lookup"); // rax = method code address
    if (self.cc == .win64) try self.rspAddSub(false, 32);
    try self.movRR(scratch3, .rax); // r12 = fn, survives arg marshaling (like emitCallValue)
    const arg_reserve = try marshalArgs(self, args, 1, 1, 0);
    const recv2 = try getInt(self, vregOf(self, iface_val), scratch1);
    try self.movRR(arg0, recv2);
    if (self.cc == .win64) try self.rspAddSub(true, 32);
    try self.callReg(scratch3);
    self.safepoint_code_offsets[self.next_safepoint_idx] = @intCast(self.code.items.len);
    self.next_safepoint_idx += 1;
    if (self.cc == .win64) try self.rspAddSub(false, 32);
    if (arg_reserve > 0) try self.rspAddSub(false, arg_reserve); // reclaim SysV stack args
    if (self.tctx().typeOf(ty) != .void) switch (classOf(self.tctx(), ty)) {
        .int => try putInt(self, dst, .rax),
        .float => try putFloat(self, dst, .xmm0),
    };
}

fn emitConstInt(self: *Ctx, dst: u32, val: i64) !void {
    try self.movRI(scratch1, val);
    try putInt(self, dst, scratch1);
}

fn emitConstBool(self: *Ctx, dst: u32, val: bool) !void {
    try self.movRI(scratch1, @intFromBool(val));
    try putInt(self, dst, scratch1);
}

fn emitConstNil(self: *Ctx, dst: u32) !void {
    try self.movRI(scratch1, 0);
    try putInt(self, dst, scratch1);
}

fn emitConstFloat(self: *Ctx, dst: u32, val: f64, width: u8) !void {
    if (width == 8) {
        try self.movRI(scratch1, @bitCast(val));
        try self.movXG(fscratch1, scratch1, 8);
    } else {
        const f32_val: f32 = @floatCast(val);
        const bits32: u32 = @bitCast(f32_val);
        try self.movRI(scratch1, @intCast(bits32));
        try self.movXG(fscratch1, scratch1, 4);
    }
    try putFloat(self, dst, fscratch1);
}

/// `base` is already the GC body pointer (`runtime/ABI.md` §1: codegen never
/// sees the header), so `offset` is a plain byte offset from it — no header
/// adjustment needed. `ty` is the field's own type (the `field_get`
/// instruction's result type), which picks load width/signedness/class.
fn emitFieldGet(self: *Ctx, dst: u32, base: ir.ValueId, offset: u32, ty: TypeId) !void {
    const base_reg = try getInt(self, vregOf(self, base), scratch2);
    // A fixed-size array field is inline storage: its value is the interior
    // address `base + offset`, formed with `lea`, not a loaded word.
    if (self.tctx().typeOf(ty) == .array) {
        try self.lea(scratch1, base_reg, @intCast(offset));
        try putInt(self, dst, scratch1);
        return;
    }
    const w = widthOf(self.tctx(), ty);
    switch (w.class) {
        .int => {
            try self.movLoad(scratch1, base_reg, null, 1, @intCast(offset), w.bytes, w.signed);
            try putInt(self, dst, scratch1);
        },
        .float => {
            try self.movFLoad(fscratch1, base_reg, null, 1, @intCast(offset), w.bytes);
            try putFloat(self, dst, fscratch1);
        },
    }
}

/// `ty` is `value`'s own type — the field's declared width/class, exactly
/// like `emitFieldGet`.
fn emitFieldSet(self: *Ctx, base: ir.ValueId, offset: u32, value: ir.ValueId, ty: TypeId) !void {
    const base_reg = try getInt(self, vregOf(self, base), scratch2);
    switch (widthOf(self.tctx(), ty).class) {
        .int => {
            const v = try getInt(self, vregOf(self, value), scratch1);
            try self.movStore(base_reg, null, 1, @intCast(offset), v, widthOf(self.tctx(), ty).bytes);
        },
        .float => {
            const v = try getFloat(self, vregOf(self, value), fscratch1);
            try self.movFStore(base_reg, null, 1, @intCast(offset), v, widthOf(self.tctx(), ty).bytes);
        },
    }
}

/// Only a static `.array` base is addressable today — see the module doc
/// comment's "Deliberately NOT covered" section (slice/string have no
/// defined runtime-length storage yet, and `lower.zig` never emits this op
/// against them). `ty` is the element type (`index_get`'s result type).
fn emitIndexGet(self: *Ctx, dst: u32, base: ir.ValueId, index: ir.ValueId, ty: TypeId) CodegenError!void {
    if (self.tctx().typeOf(self.f.valueType(base)) != .array) return error.UnsupportedConstruct;
    const base_reg = try getInt(self, vregOf(self, base), scratch2);
    const idx_reg = try getInt(self, vregOf(self, index), scratch3);
    const w = widthOf(self.tctx(), ty);
    switch (w.class) {
        .int => {
            try self.movLoad(scratch1, base_reg, idx_reg, w.bytes, 0, w.bytes, w.signed);
            try putInt(self, dst, scratch1);
        },
        .float => {
            try self.movFLoad(fscratch1, base_reg, idx_reg, w.bytes, 0, w.bytes);
            try putFloat(self, dst, fscratch1);
        },
    }
}

/// `slice_len` reads the `len` word from a slice or string header. A `[]T`
/// header is `{ptr, len, cap, is_ref}` and a `string` header is `{ptr, len}`
/// (ABI.md §2) — both keep `len` at offset 8, so one load serves both. `len`
/// on a static `[N]T` array never reaches here (lowering folds it to a
/// `const_int`), and dynamic slice indexing goes through the `slice_get`/`_set`
/// runtime calls, so this op only ever loads a header length.
fn emitSliceLen(self: *Ctx, dst: u32, base: ir.ValueId) !void {
    const base_reg = try getInt(self, vregOf(self, base), scratch2);
    try self.movLoad(scratch1, base_reg, null, 1, 8, 8, false);
    try putInt(self, dst, scratch1);
}

/// `ty` is `value`'s own type (the array's element type) — see `emitIndexGet`.
fn emitIndexSet(self: *Ctx, base: ir.ValueId, index: ir.ValueId, value: ir.ValueId, ty: TypeId) CodegenError!void {
    if (self.tctx().typeOf(self.f.valueType(base)) != .array) return error.UnsupportedConstruct;
    const base_reg = try getInt(self, vregOf(self, base), scratch2);
    const idx_reg = try getInt(self, vregOf(self, index), scratch3);
    const w = widthOf(self.tctx(), ty);
    switch (w.class) {
        .int => {
            const v = try getInt(self, vregOf(self, value), scratch1);
            try self.movStore(base_reg, idx_reg, w.bytes, 0, v, w.bytes);
        },
        .float => {
            const v = try getFloat(self, vregOf(self, value), fscratch1);
            try self.movFStore(base_reg, idx_reg, w.bytes, 0, v, w.bytes);
        },
    }
}

// ============================================================================
// Terminators
// ============================================================================

/// Binds `target`'s block-param values from `args` (raw value indices, per
/// `ir.Decoded.jump`/`.br`) as one parallel move per class — see the module
/// doc comment on why a naive sequential emission would be unsound here
/// (loop-carried register rotations).
fn emitParamMoves(self: *Ctx, target: ir.BlockId, args: []const u32) !void {
    const blk = self.f.block(target);
    var int_moves: std.ArrayList(PMove) = .empty;
    defer int_moves.deinit(self.gpa);
    var float_moves: std.ArrayList(PMove) = .empty;
    defer float_moves.deinit(self.gpa);

    var p: u32 = 0;
    while (p < blk.param_count) : (p += 1) {
        const param_val = blk.paramValue(p);
        const class = classOf(self.tctx(), self.f.valueType(param_val));
        const from = plocOf(self, self.inst_to_vreg[args[p]], class);
        const to = plocOf(self, vregOf(self, param_val), class);
        const list = if (class == .int) &int_moves else &float_moves;
        try list.append(self.gpa, .{ .from = from, .to = to });
    }
    try sequentializeAndEmit(self, int_moves.items, .int);
    try sequentializeAndEmit(self, float_moves.items, .float);
}

/// Binds the incoming argument registers (per `self.cc`) into the entry
/// block's param vregs, as one parallel move per class — the mirror image of
/// `emitParamMoves`, but the sources are the ABI argument registers rather
/// than another block's values (`arm64.zig` does the equivalent in its
/// prologue). Without this the entry params hold whatever the allocator left
/// in their registers, so every function that reads its own parameters
/// returns garbage. Emitted right after the prologue, whose only register
/// writes are to callee-saved GPRs and rbp/rsp — never an argument register —
/// so the incoming values are still live here.
fn bindIncomingArgs(self: *Ctx) !void {
    const entry = self.f.block(self.f.entry);
    var int_moves: std.ArrayList(PMove) = .empty;
    defer int_moves.deinit(self.gpa);
    var float_moves: std.ArrayList(PMove) = .empty;
    defer float_moves.deinit(self.gpa);

    var int_ordinal: u32 = 0;
    var float_ordinal: u32 = 0;
    var stack_index: u32 = 0;
    var p: u32 = 0;
    while (p < entry.param_count) : (p += 1) {
        const param_val = entry.paramValue(p);
        const class = classOf(self.tctx(), self.f.valueType(param_val));
        const ordinal = if (class == .int) int_ordinal else float_ordinal;
        const to = plocOf(self, vregOf(self, param_val), class);
        const list = if (class == .int) &int_moves else &float_moves;
        // The mirror of `marshalArgs`: params 1–6 int / 1–8 float arrive in the
        // ABI registers; the rest were pushed by the caller and now sit just
        // above the saved rbp/return address at `[rbp+16]`, `[rbp+24]`, … in
        // argument order (a `.mem` source `emitMove` reads rbp-relative).
        const from: PLoc = if (argReg(self.cc, class, p, ordinal)) |reg|
            .{ .reg = reg }
        else blk: {
            if (self.cc != .sysv) return error.TooManyArguments; // Win64 overflow unimplemented
            const off: i32 = 16 + 8 * @as(i32, @intCast(stack_index));
            stack_index += 1;
            break :blk .{ .mem = off };
        };
        if (class == .int) int_ordinal += 1 else float_ordinal += 1;
        try list.append(self.gpa, .{ .from = from, .to = to });
    }
    try sequentializeAndEmit(self, int_moves.items, .int);
    try sequentializeAndEmit(self, float_moves.items, .float);
}

/// True iff `target` is a loop back-edge from the block currently being
/// emitted (`ir.zig`/`regalloc.zig`'s shared heuristic: a jump/br whose
/// target's index is <= the branching block's own — see the module doc
/// comment on safepoints).
fn isBackEdge(self: *const Ctx, target: ir.BlockId) bool {
    return @intFromEnum(target) <= self.cur_block_idx;
}

fn emitJump(self: *Ctx, target: ir.BlockId, args: []const u32) !void {
    if (isBackEdge(self, target)) try emitCallLike(self, "bit_rt_safepoint", &.{}, null);
    try emitParamMoves(self, target, args);
    try self.jmpRel32(target);
}

fn emitBr(self: *Ctx, cond: ir.ValueId, then_blk: ir.BlockId, then_args: []const u32, else_blk: ir.BlockId, else_args: []const u32) !void {
    const c = try getInt(self, vregOf(self, cond), scratch1);
    try self.testRR(c, c);
    const skip_off = try self.emitCondJumpPlaceholder(CC.e);
    if (isBackEdge(self, then_blk)) try emitCallLike(self, "bit_rt_safepoint", &.{}, null);
    try emitParamMoves(self, then_blk, then_args);
    try self.jmpRel32(then_blk);
    self.patchRel32Here(skip_off);
    if (isBackEdge(self, else_blk)) try emitCallLike(self, "bit_rt_safepoint", &.{}, null);
    try emitParamMoves(self, else_blk, else_args);
    try self.jmpRel32(else_blk);
}

/// A multi-value `ret` is out of scope (module doc comment: codegen hasn't
/// decided a packing yet).
fn emitRet(self: *Ctx, vals: []const u32) !void {
    if (vals.len > 1) return error.UnsupportedConstruct;
    if (vals.len == 1) {
        const v: ir.ValueId = @enumFromInt(vals[0]);
        const ty = self.f.valueType(v);
        switch (classOf(self.tctx(), ty)) {
            .int => {
                const r = try getInt(self, vregOf(self, v), scratch1);
                try self.movRR(.rax, r);
            },
            .float => {
                const r = try getFloat(self, vregOf(self, v), fscratch1);
                try self.movFRR(.xmm0, r, widthOf(self.tctx(), ty).bytes);
            },
        }
    }
    try emitEpilogue(self);
    try self.ret();
}

// ============================================================================
// Calls (direct `call`, opaque `rt_call`, closure `call_value`, and interface
// `call_iface` — all real x86-64 calls; see `emitCallIface` for dispatch)
// ============================================================================

/// Per-`RtFn` runtime symbol name (module doc comment: "generically
/// dispatched to a `bit_rt_<tag>` symbol").
const rt_symbol = std.EnumArray(ir.RtFn, []const u8).init(.{
    .string_concat = "bit_rt_string_concat",
    .string_from_int = "bit_rt_string_from_int",
    .string_from_float = "bit_rt_string_from_float",
    .string_from_bool = "bit_rt_string_from_bool",
    .string_eq = "bit_rt_string_eq",
    .string_byte = "bit_rt_string_byte",
    .string_slice = "bit_rt_string_slice",
    .bytes_from_string = "bit_rt_bytes_from_string",
    .string_from_bytes = "bit_rt_string_from_bytes",
    .sqrt = "bit_rt_sqrt",
    .panic = "bit_rt_panic",
    .assert = "bit_rt_assert",
    .print = "bit_rt_print",
    .eprint = "bit_rt_eprint",
    .err_set = "bit_rt_set_err",
    .err_get = "bit_rt_get_err",
    .chan_make = "bit_rt_chan_make",
    .chan_send = "bit_rt_chan_send",
    .chan_recv = "bit_rt_chan_recv",
    .chan_recv_ok = "bit_rt_chan_recv_ok",
    .iface_as = "bit_rt_iface_as",
    .iface_as_ok = "bit_rt_iface_as_ok",
    .iface_assert = "bit_rt_iface_assert",
    .chan_close = "bit_rt_chan_close",
    .spawn = "bit_rt_spawn",
    .map_new = "bit_rt_map_new",
    .map_set = "bit_rt_map_set",
    .map_get = "bit_rt_map_get",
    .map_has = "bit_rt_map_has",
    .map_delete = "bit_rt_map_delete",
    .map_len = "bit_rt_map_len",
    .map_iter_init = "bit_rt_map_iter_init",
    .map_iter_next = "bit_rt_map_iter_next",
    .map_key_at = "bit_rt_map_key_at",
    .map_val_at = "bit_rt_map_val_at",
    .select_alloc = "bit_rt_select_alloc",
    .select = "bit_rt_select",
    .slice_new = "bit_rt_slice_new",
    .slice_append = "bit_rt_slice_append",
    .slice_get = "bit_rt_slice_get",
    .slice_set = "bit_rt_slice_set",
    .slice_slice = "bit_rt_slice_slice",
    .fs_open = "bit_rt_fs_open",
    .fs_read_all = "bit_rt_fs_read_all",
    .fs_write = "bit_rt_fs_write",
    .fs_close = "bit_rt_fs_close",
    .fs_append = "bit_rt_fs_append",
    .fs_read = "bit_rt_fs_read",
    .fs_exists = "bit_rt_fs_exists",
    .fs_is_dir = "bit_rt_fs_is_dir",
    .fs_mkdir = "bit_rt_fs_mkdir",
    .fs_remove = "bit_rt_fs_remove",
    .fs_list_dir = "bit_rt_fs_list_dir",
    .fs_chmod = "bit_rt_fs_chmod",
    .net_listen = "bit_rt_net_listen",
    .net_local_port = "bit_rt_net_local_port",
    .net_accept = "bit_rt_net_accept",
    .net_dial = "bit_rt_net_dial",
    .net_read = "bit_rt_net_read",
    .net_write = "bit_rt_net_write",
    .net_udp_bind = "bit_rt_net_udp_bind",
    .net_udp_send = "bit_rt_net_udp_send",
    .net_udp_recv = "bit_rt_net_udp_recv",
    .net_udp_sender_host = "bit_rt_net_udp_sender_host",
    .net_udp_sender_port = "bit_rt_net_udp_sender_port",
    .net_resolve = "bit_rt_net_resolve",
    .test_index = "bit_rt_test_index",
    .floor = "bit_rt_floor",
    .ceil = "bit_rt_ceil",
    .round = "bit_rt_round",
    .trunc = "bit_rt_trunc",
    .pow = "bit_rt_pow",
    .atan2 = "bit_rt_atan2",
    .log = "bit_rt_log",
    .log2 = "bit_rt_log2",
    .log10 = "bit_rt_log10",
    .time_mono_ns = "bit_rt_time_mono_ns",
    .time_unix_ns = "bit_rt_time_unix_ns",
    .time_sleep_ns = "bit_rt_time_sleep_ns",
    .os_argc = "bit_rt_os_argc",
    .os_arg_at = "bit_rt_os_arg_at",
    .os_env = "bit_rt_os_env",
    .os_exit = "bit_rt_os_exit",
    .os_run = "bit_rt_os_run",
    .os_run_test = "bit_rt_os_run_test",
    .host_target = "bit_rt_host_target",
    .random_bytes = "bit_rt_random_bytes",
    .secure_zero = "bit_rt_secure_zero",
    .parse_float = "bit_rt_parse_float",
    .float_bits = "bit_rt_float_bits",
    .float32_bits = "bit_rt_float32_bits",
});

const CallReturn = struct { dst: u32, ty: TypeId };

/// Marshals `args` (raw value indices) into `symbol`'s argument registers per
/// `self.cc`, emits the call + its safepoint record (module doc comment:
/// every `call`/`rt_call`, and every synthetic back-edge poll, is a
/// safepoint), then moves the return value (if any) out of `rax`/`xmm0`.
/// Every source location here is guaranteed callee-saved-or-spill (see the
/// module doc comment: a function containing any safepoint restricts its
/// whole allocatable file to the callee-saved subset), so these parallel
/// moves can never collide with the argument registers they target.
/// One argument that overflowed its ABI registers and must be passed on the
/// stack: its source location and the byte offset (from the post-`sub` `rsp`)
/// of its outgoing slot.
const StackArg = struct { src: PLoc, class: regalloc.Class, offset: i32 };

/// Stores one overflow argument to its outgoing stack slot `[rsp + offset]`.
/// `src` is rbp-relative (a spill) or a physical register — both survive the
/// `sub rsp` that precedes this (rbp is never the argument stack base), so the
/// value is fetched from wherever the allocator left it and written straight
/// down to the outgoing area.
fn emitStackArgStore(self: *Ctx, sa: StackArg) !void {
    switch (sa.class) {
        .int => switch (sa.src) {
            .reg => |r| try self.movStore(.rsp, null, 1, sa.offset, @enumFromInt(r), 8),
            .mem => |m| {
                try self.movLoad(scratch1, .rbp, null, 1, m, 8, false);
                try self.movStore(.rsp, null, 1, sa.offset, scratch1, 8);
            },
        },
        .float => switch (sa.src) {
            .reg => |r| try self.movFStore(.rsp, null, 1, sa.offset, @enumFromInt(r), 8),
            .mem => |m| {
                try self.movFLoad(fscratch1, .rbp, null, 1, m, 8);
                try self.movFStore(.rsp, null, 1, sa.offset, fscratch1, 8);
            },
        },
    }
}

/// Marshals `args` into argument registers via parallel moves, starting at
/// positional slot `base_position` with the integer/float register banks
/// already `base_int_ord`/`base_float_ord` deep. `emitCallLike` passes all
/// zeros (a plain call); `emitCallValue` passes `1,1,0` to reserve arg0 for
/// the closure's environment pointer (which it moves in after marshaling).
///
/// Arguments past the ABI register banks (SysV: the 7th+ integer/reference or
/// 9th+ float) overflow to the stack. This lowers them per SysV: reserve a
/// 16-byte-aligned outgoing area with `sub rsp`, store each overflow arg at
/// `[rsp + 8*k]` in argument order (so the callee reads them contiguously just
/// above its return address), then the register moves as usual. Returns the
/// reserved byte count so the caller reclaims it with `add rsp` right after the
/// call — rsp is 16-aligned in the body (`alignFrame`) and the reserve is a
/// multiple of 16, so the call boundary stays 16-aligned. (Win64 stack args are
/// unimplemented — the only x64 target wired up is SysV; the Win64 overflow
/// path still errors cleanly.)
fn marshalArgs(self: *Ctx, args: []const u32, base_position: u32, base_int_ord: u32, base_float_ord: u32) CodegenError!u32 {
    var int_moves: std.ArrayList(PMove) = .empty;
    defer int_moves.deinit(self.gpa);
    var float_moves: std.ArrayList(PMove) = .empty;
    defer float_moves.deinit(self.gpa);
    var stack_args: std.ArrayList(StackArg) = .empty;
    defer stack_args.deinit(self.gpa);

    var int_ordinal: u32 = base_int_ord;
    var float_ordinal: u32 = base_float_ord;
    var stack_index: u32 = 0;
    for (args, 0..) |raw, position| {
        const class = classOf(self.tctx(), self.f.valueType(@enumFromInt(raw)));
        const ordinal = if (class == .int) int_ordinal else float_ordinal;
        const from = plocOf(self, self.inst_to_vreg[raw], class);
        if (argReg(self.cc, class, @intCast(base_position + position), ordinal)) |reg| {
            const list = if (class == .int) &int_moves else &float_moves;
            try list.append(self.gpa, .{ .from = from, .to = .{ .reg = reg } });
        } else {
            if (self.cc != .sysv) return error.TooManyArguments; // Win64 overflow unimplemented
            try stack_args.append(self.gpa, .{ .src = from, .class = class, .offset = 8 * @as(i32, @intCast(stack_index)) });
            stack_index += 1;
        }
        if (class == .int) int_ordinal += 1 else float_ordinal += 1;
    }

    var reserve: u32 = 0;
    if (stack_index > 0) {
        reserve = @intCast(std.mem.alignForward(usize, 8 * @as(usize, stack_index), 16));
        try self.rspAddSub(true, reserve);
        // Ordered before the register moves: those may recycle scratch1/scratch2
        // (the parallel-move temps), whereas each stack store only reads a
        // source and writes the outgoing area, so doing them first can never
        // clobber a pending register-move source.
        for (stack_args.items) |sa| try emitStackArgStore(self, sa);
    }
    try sequentializeAndEmit(self, int_moves.items, .int);
    try sequentializeAndEmit(self, float_moves.items, .float);
    return reserve;
}

fn emitCallLike(self: *Ctx, symbol: []const u8, args: []const u32, ret: ?CallReturn) CodegenError!void {
    const arg_reserve = try marshalArgs(self, args, 0, 0, 0);

    // Win64 requires the caller to reserve 32 bytes of "home space" right
    // below the call; done dynamically around just this call site (not
    // baked into the frame) because every stack slot codegen otherwise
    // touches is rbp-relative, so this transient rsp shift never disturbs
    // spill/local addressing. 32 is 16-aligned, so it preserves whatever
    // alignment the frame prologue already established.
    if (self.cc == .win64) try self.rspAddSub(true, 32);
    try self.emitCallReloc(symbol);
    // The safepoint's code offset is the return address — the byte right
    // after the call, before any home-space or outgoing-arg teardown. Recording
    // it after an `add rsp` would push it past the real return address and
    // corrupt stack-map lookups during a GC triggered by the callee.
    self.safepoint_code_offsets[self.next_safepoint_idx] = @intCast(self.code.items.len);
    self.next_safepoint_idx += 1;
    if (self.cc == .win64) try self.rspAddSub(false, 32);
    if (arg_reserve > 0) try self.rspAddSub(false, arg_reserve); // reclaim SysV stack args

    if (ret) |r| {
        switch (classOf(self.tctx(), r.ty)) {
            .int => {
                // The C ABI returns a `bool` in `al` and leaves rax's upper bits
                // **unspecified** — the same hazard ABI.md §2 records for a `u8`
                // return. A Bit `bool` is a full-width 0/1, because `!b` and the
                // branch tests read the whole register. Normalize here, at the
                // one boundary where a foreign callee's convention meets ours.
                //
                // Whether a particular callee happens to zero `eax` is not
                // something to rely on: `bit_rt_string_eq` did, `bit_rt_fs_exists`
                // did not, and `!fsExists(missing)` silently evaluated to false.
                if (isBoolTy(self.tctx(), r.ty)) try self.movzxb(.rax, .rax);
                try putInt(self, r.dst, .rax);
            },
            .float => try putFloat(self, r.dst, .xmm0),
        }
    }
}

/// Whether `ty` is the `bool` primitive — the one integer-class type whose
/// return register a C callee may leave partially undefined.
fn isBoolTy(tctx: *const TypeContext, ty: TypeId) bool {
    const d = tctx.typeOf(ty);
    return d == .prim and d.prim == .bool;
}

// ============================================================================
// Prologue / epilogue
// ============================================================================

/// Filters `regs` (a function's allocatable GPR file) down to the subset
/// that must be saved/restored by this function's own prologue/epilogue —
/// every callee-saved register in that file, regardless of whether a
/// safepoint further restricted the file to callee-saved-only (see
/// `buildIntRegs`). `buf` is caller-owned, bounded storage (mirrors
/// `buildIntRegs`'s own pattern).
fn buildSavedGpr(buf: *[max_int_regs]Reg, cc: CallConv, regs: []const Reg) []const Reg {
    var n: usize = 0;
    for (regs) |r| {
        if (isCalleeSavedInt(cc, r)) {
            buf[n] = r;
            n += 1;
        }
    }
    return buf[0..n];
}

fn buildSavedXmm(buf: *[max_float_regs]XReg, cc: CallConv, regs: []const XReg) []const XReg {
    var n: usize = 0;
    for (regs) |r| {
        if (isCalleeSavedFloat(cc, r)) {
            buf[n] = r;
            n += 1;
        }
    }
    return buf[0..n];
}

fn emitPrologue(self: *Ctx) !void {
    try self.push(.rbp);
    try self.movRR(.rbp, .rsp);
    for (self.frame.saved_gpr) |r| try self.push(r);
    if (self.frame.frame_size > 0) try self.rspAddSub(true, self.frame.frame_size);
    for (self.frame.saved_xmm, 0..) |x, i| {
        try self.movFStore(.rbp, null, 1, self.frame.xmmSaveOffset(i), x, 8);
    }
}

fn emitEpilogue(self: *Ctx) !void {
    for (self.frame.saved_xmm, 0..) |x, i| {
        try self.movFLoad(x, .rbp, null, 1, self.frame.xmmSaveOffset(i), 8);
    }
    if (self.frame.frame_size > 0) try self.rspAddSub(false, self.frame.frame_size);
    var i: usize = self.frame.saved_gpr.len;
    while (i > 0) {
        i -= 1;
        try self.pop(self.frame.saved_gpr[i]);
    }
    try self.pop(.rbp);
}

// ============================================================================
// Live-interval construction (feeds `regalloc.allocate`)
// ============================================================================

fn markUse(intervals: []regalloc.Interval, v: u32, pos: u32) void {
    if (intervals[v].end < pos) intervals[v].end = pos;
}

/// Extends every operand's interval to cover `pos` (the instruction doing the
/// using) — mirrors `ir.zig`'s own `checkAllOperands` operand enumeration
/// (that one checks dominance, this one accumulates liveness), duplicated
/// here rather than shared because the two files serve different tickets and
/// `ir.zig`/`regalloc.zig` are locked shared surface during #340/#341's
/// concurrent development (see this file's own doc comment on scratch
/// register ownership for the same "don't reach across a ticket boundary"
/// posture).
fn markUses(intervals: []regalloc.Interval, d: ir.Decoded, pos: u32) void {
    switch (d) {
        .block_param, .const_int, .const_float, .const_bool, .const_string, .const_nil, .unreachable_, .gc_alloc, .type_info => {},
        .bin => |b| {
            markUse(intervals, @intFromEnum(b.lhs), pos);
            markUse(intervals, @intFromEnum(b.rhs), pos);
        },
        .un => |u| markUse(intervals, @intFromEnum(u.operand), pos),
        .jump => |j| for (j.args) |a| markUse(intervals, a, pos),
        .br => |b| {
            markUse(intervals, @intFromEnum(b.cond), pos);
            for (b.then_args) |a| markUse(intervals, a, pos);
            for (b.else_args) |a| markUse(intervals, a, pos);
        },
        .ret => |r| for (r.vals) |v| markUse(intervals, v, pos),
        .call => |c| for (c.args) |a| markUse(intervals, a, pos),
        .call_value => |c| {
            markUse(intervals, @intFromEnum(c.callee), pos);
            for (c.args) |a| markUse(intervals, a, pos);
        },
        .call_iface => |c| {
            markUse(intervals, @intFromEnum(c.iface), pos);
            for (c.args) |a| markUse(intervals, a, pos);
        },
        .atomic_load => |a| markUse(intervals, @intFromEnum(a.ptr), pos),
        .atomic_store => |a| {
            markUse(intervals, @intFromEnum(a.ptr), pos);
            markUse(intervals, @intFromEnum(a.value), pos);
        },
        .atomic_cmpxchg => |a| {
            markUse(intervals, @intFromEnum(a.ptr), pos);
            markUse(intervals, @intFromEnum(a.expected), pos);
            markUse(intervals, @intFromEnum(a.desired), pos);
        },
        .atomic_rmw => |a| {
            markUse(intervals, @intFromEnum(a.ptr), pos);
            markUse(intervals, @intFromEnum(a.operand), pos);
        },
        .field_get => |fg| markUse(intervals, @intFromEnum(fg.base), pos),
        .field_set => |fs| {
            markUse(intervals, @intFromEnum(fs.base), pos);
            markUse(intervals, @intFromEnum(fs.value), pos);
        },
        .index_get => |ig| {
            markUse(intervals, @intFromEnum(ig.base), pos);
            markUse(intervals, @intFromEnum(ig.index), pos);
        },
        .index_set => |is_| {
            markUse(intervals, @intFromEnum(is_.base), pos);
            markUse(intervals, @intFromEnum(is_.index), pos);
            markUse(intervals, @intFromEnum(is_.value), pos);
        },
        .slice_len => |sl| markUse(intervals, @intFromEnum(sl.base), pos),
        .make_closure => |mc| markUse(intervals, @intFromEnum(mc.env), pos),
        .func_addr => {}, // references a FuncId, no value operands
        .rt_call => |rc| for (rc.args) |a| markUse(intervals, a, pos),
    }
}

/// One interval per instruction (dense identity vreg numbering — `vreg i`
/// IS instruction index `i`, matching `ir.zig`'s own "instruction index ==
/// ValueId" house style; terminators and other void-typed instructions get a
/// throwaway `[i,i]` `.int` interval that's built for uniformity but never
/// read back, since nothing ever calls `getInt`/`getFloat` on their index).
fn buildIntervals(gpa: Allocator, tctx: *const TypeContext, f: *const ir.Function) Allocator.Error![]regalloc.Interval {
    const n = f.insts.len;
    const intervals = try gpa.alloc(regalloc.Interval, n);
    errdefer gpa.free(intervals);
    for (0..n) |i| {
        const ty = f.insts.items(.ty)[i];
        const is_value = ty != .invalid;
        const class = if (is_value) classOf(tctx, ty) else .int;
        intervals[i] = .{
            .vreg = @enumFromInt(i),
            .class = class,
            .start = @intCast(i),
            .end = @intCast(i),
            .is_ref = is_value and class == .int and isRefType(tctx, ty),
        };
    }
    for (f.blocks) |blk| {
        var i = blk.insts_start + blk.param_count;
        const end = blk.insts_start + blk.insts_len;
        while (i < end) : (i += 1) {
            markUses(intervals, f.decode(@enumFromInt(i)), i);
        }
    }
    extendParamsToPreds(intervals, f);
    forceParamInterference(intervals, f);
    return intervals;
}

/// A block param's storage is written by each predecessor's edge move, which
/// runs at the predecessor's terminator. Under the RPO block order a forward
/// branch can target a block emitted *later*, so the write happens well before
/// the param's own instruction index. Extend every param's interval start back
/// to its earliest predecessor terminator, so the param is live across that gap
/// and interferes with any value live there; without this, a value that dies in
/// the gap can be handed the same register/spill slot and then be clobbered by
/// the edge move — the caller reads the wrong value (e.g. an early `return` from
/// inside a loop reading a spilled loop-carried local). A back-edge predecessor
/// sits at a higher position than the param, so it never lowers the start.
fn extendParamsToPreds(intervals: []regalloc.Interval, f: *const ir.Function) void {
    for (f.blocks) |pblk| {
        const term_pos: u32 = @intCast(pblk.insts_start + pblk.insts_len - 1);
        switch (f.decode(@enumFromInt(term_pos))) {
            .jump => |j| extendBlockParams(intervals, f, j.target, term_pos),
            .br => |b| {
                extendBlockParams(intervals, f, b.then_blk, term_pos);
                extendBlockParams(intervals, f, b.else_blk, term_pos);
            },
            else => {},
        }
    }
}

fn extendBlockParams(intervals: []regalloc.Interval, f: *const ir.Function, target: ir.BlockId, edge_pos: u32) void {
    const blk = f.blocks[@intFromEnum(target)];
    var p: u32 = blk.insts_start;
    const end = blk.insts_start + blk.param_count;
    while (p < end) : (p += 1) {
        if (intervals[p].start > edge_pos) intervals[p].start = edge_pos;
    }
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

/// Positions (raw instruction indices) `regalloc.allocate` should build a GC
/// stack map for: every `call`/`rt_call`, and every back-edge `jump`/`br`
/// (once per back-edge successor — see `emitJump`/`emitBr`, which emit one
/// synthetic `bit_rt_safepoint` call per back-edge target, in this exact
/// order, so `result.stack_maps[i]` lines up with the i-th call site actually
/// emitted).
fn collectSafepoints(gpa: Allocator, f: *const ir.Function) Allocator.Error![]u32 {
    var out: std.ArrayList(u32) = .empty;
    errdefer out.deinit(gpa);
    for (f.blocks, 0..) |blk, bi| {
        var i = blk.insts_start + blk.param_count;
        const end = blk.insts_start + blk.insts_len;
        while (i < end) : (i += 1) {
            switch (f.insts.items(.op)[i]) {
                .call, .rt_call, .gc_alloc, .make_closure, .call_value, .call_iface => try out.append(gpa, @intCast(i)),
                .jump => {
                    const j = f.decode(@enumFromInt(i)).jump;
                    if (@intFromEnum(j.target) <= bi) try out.append(gpa, @intCast(i));
                },
                .br => {
                    const b = f.decode(@enumFromInt(i)).br;
                    if (@intFromEnum(b.then_blk) <= bi) try out.append(gpa, @intCast(i));
                    if (@intFromEnum(b.else_blk) <= bi) try out.append(gpa, @intCast(i));
                },
                else => {},
            }
        }
    }
    return out.toOwnedSlice(gpa);
}

/// True iff `f` contains anything that forces the callee-saved-only register
/// file restriction (module doc comment): a real call/rt_call, a back-edge
/// (which gets a synthetic call inserted), integer division/remainder (fixed
/// `rax`/`rdx` operands), or a variable-count shift (fixed `rcx`/`cl`).
const FuncFlags = struct { has_safepoints: bool, needs_rax_rdx: bool, needs_rcx: bool };

fn scanFuncFlags(f: *const ir.Function) FuncFlags {
    var flags = FuncFlags{ .has_safepoints = false, .needs_rax_rdx = false, .needs_rcx = false };
    for (f.blocks, 0..) |blk, bi| {
        var i = blk.insts_start + blk.param_count;
        const end = blk.insts_start + blk.insts_len;
        while (i < end) : (i += 1) {
            switch (f.insts.items(.op)[i]) {
                .call, .rt_call, .gc_alloc, .make_closure, .call_value, .call_iface => flags.has_safepoints = true,
                .sdiv, .udiv, .srem, .urem => flags.needs_rax_rdx = true,
                // CMPXCHG (and the AND/OR CAS-retry loops) commandeer `rax` as
                // the implicit accumulator — reserve it (via the same rax/rdx
                // exclusion) for the whole function, exactly like `idiv`.
                .atomic_cmpxchg, .atomic_rmw_and, .atomic_rmw_or => flags.needs_rax_rdx = true,
                .shl, .ashr, .lshr => {
                    const b = f.decode(@enumFromInt(i)).bin;
                    if (constShiftAmount(f, b.rhs) == null) flags.needs_rcx = true;
                },
                .jump => {
                    const j = f.decode(@enumFromInt(i)).jump;
                    if (@intFromEnum(j.target) <= bi) flags.has_safepoints = true;
                },
                .br => {
                    const b = f.decode(@enumFromInt(i)).br;
                    if (@intFromEnum(b.then_blk) <= bi or @intFromEnum(b.else_blk) <= bi) flags.has_safepoints = true;
                },
                else => {},
            }
        }
    }
    return flags;
}

// ============================================================================
// Instruction dispatch
// ============================================================================

// ---- atomics (§11.5) ------------------------------------------------------
// `*T` is an int-classed word; every sequence is call-free (never a safepoint).
// `lock`-prefixed forms are seq-cst regardless of the requested ordering.

fn emitAtomicLoad(self: *Ctx, dst: u32, ptr: ir.ValueId, ty: TypeId) !void {
    const w = widthOf(self.tctx(), ty);
    const base = try getInt(self, vregOf(self, ptr), scratch2);
    try self.movLoad(scratch1, base, null, 1, 0, w.bytes, w.signed); // plain load is acquire on x86-TSO
    try putInt(self, dst, scratch1);
}

fn emitAtomicStore(self: *Ctx, ptr: ir.ValueId, value: ir.ValueId, ty: TypeId) !void {
    const w = widthOf(self.tctx(), ty);
    const base = try getInt(self, vregOf(self, ptr), scratch2);
    const val = try getInt(self, vregOf(self, value), scratch1);
    try self.movStore(base, null, 1, 0, val, w.bytes);
    try self.mfence(); // a seq-cst store needs a trailing full barrier on x86
}

/// `rax` is pinned in this function (`scanFuncFlags` sets `needs_rax_rdx`), so
/// CMPXCHG's implicit accumulator is free to clobber. Result is the Go-style
/// bool "did it swap".
fn emitAtomicCmpxchg(self: *Ctx, dst: u32, ptr: ir.ValueId, expected: ir.ValueId, desired: ir.ValueId) !void {
    const w = widthOf(self.tctx(), self.f.valueType(expected));
    const base = try getInt(self, vregOf(self, ptr), scratch2);
    const des = try getInt(self, vregOf(self, desired), scratch3);
    const exp = try getInt(self, vregOf(self, expected), scratch1);
    try self.movRR(.rax, exp);
    try self.lockCmpxchgMem(des, base, w.bytes);
    try self.setcc(CC.e, scratch1); // ZF=1 => swapped
    try self.movzxb(scratch1, scratch1);
    try putInt(self, dst, scratch1);
}

/// Fetch-and-op; returns the pre-op value. add/sub/xchg map to single
/// `lock`-implicit instructions; and/or have no native fetch form on x86 and
/// use the standard CMPXCHG retry loop (`rax` pinned).
fn emitAtomicRmw(self: *Ctx, op: ir.Op, dst: u32, ptr: ir.ValueId, operand: ir.ValueId, ty: TypeId) !void {
    const w = widthOf(self.tctx(), ty);
    const base = try getInt(self, vregOf(self, ptr), scratch2);
    switch (op) {
        .atomic_rmw_add, .atomic_rmw_sub, .atomic_rmw_xchg => {
            const oper = try getInt(self, vregOf(self, operand), scratch1);
            try self.movRR(scratch1, oper); // reg holds the source and receives the old value
            switch (op) {
                .atomic_rmw_add => try self.lockXaddMem(scratch1, base, w.bytes),
                .atomic_rmw_sub => {
                    try self.negR(scratch1); // fetch-and-sub == fetch-and-add(-v)
                    try self.lockXaddMem(scratch1, base, w.bytes);
                },
                .atomic_rmw_xchg => try self.xchgMem(scratch1, base, w.bytes),
                else => unreachable,
            }
        },
        .atomic_rmw_and, .atomic_rmw_or => {
            const oper = try getInt(self, vregOf(self, operand), scratch3);
            try self.movLoad(.rax, base, null, 1, 0, w.bytes, w.signed);
            const retry_off: u32 = @intCast(self.code.items.len);
            try canonNarrow(self, .rax, w); // keep the comparand canonical each iteration
            try self.movRR(scratch1, .rax);
            if (op == .atomic_rmw_and) try self.arithRR(.and_, scratch1, oper) else try self.arithRR(.or_, scratch1, oper);
            try self.lockCmpxchgMem(scratch1, base, w.bytes);
            try self.jccToOffset(CC.ne, retry_off); // JNZ retry: reservation lost, rax reloaded
            try self.movRR(scratch1, .rax); // rax holds the old (pre-op) value
        },
        else => unreachable,
    }
    try canonNarrow(self, scratch1, w);
    try putInt(self, dst, scratch1);
}

fn emitInst(self: *Ctx, id: ir.ValueId) CodegenError!void {
    const i: u32 = @intFromEnum(id);
    const op = self.f.insts.items(.op)[i];
    const ty = self.f.insts.items(.ty)[i];
    const dst = self.inst_to_vreg[i];
    const d = self.f.decode(id);
    const iw = widthOf(self.tctx(), ty); // result width: drives narrow re-canonicalization
    switch (op) {
        .const_int => try emitConstInt(self, dst, d.const_int),
        .const_string => try emitConstString(self, dst, d.const_string),
        .const_bool => try emitConstBool(self, dst, d.const_bool),
        .const_nil => try emitConstNil(self, dst),
        .const_float => try emitConstFloat(self, dst, d.const_float, iw.bytes),
        .add => try emitBinaryInt(self, .add, dst, d.bin.lhs, d.bin.rhs, iw),
        .sub => try emitBinaryInt(self, .sub, dst, d.bin.lhs, d.bin.rhs, iw),
        .band => try emitBinaryInt(self, .and_, dst, d.bin.lhs, d.bin.rhs, iw),
        .bor => try emitBinaryInt(self, .or_, dst, d.bin.lhs, d.bin.rhs, iw),
        .bxor => try emitBinaryInt(self, .xor, dst, d.bin.lhs, d.bin.rhs, iw),
        .fadd => try emitBinaryFloat(self, .add, dst, d.bin.lhs, d.bin.rhs, iw.bytes),
        .fsub => try emitBinaryFloat(self, .sub, dst, d.bin.lhs, d.bin.rhs, iw.bytes),
        .fmul => try emitBinaryFloat(self, .mul, dst, d.bin.lhs, d.bin.rhs, iw.bytes),
        .fdiv => try emitBinaryFloat(self, .div, dst, d.bin.lhs, d.bin.rhs, iw.bytes),
        .mul => try emitMulInt(self, dst, d.bin.lhs, d.bin.rhs, iw),
        .sdiv, .udiv, .srem, .urem => try emitDivInt(self, op, dst, d.bin.lhs, d.bin.rhs),
        .shl => try emitShiftInt(self, .shl, dst, d.bin.lhs, d.bin.rhs, iw),
        .ashr => try emitShiftInt(self, .sar, dst, d.bin.lhs, d.bin.rhs, iw),
        .lshr => try emitShiftInt(self, .shr, dst, d.bin.lhs, d.bin.rhs, iw),
        .neg, .bnot => try emitUnaryInt(self, op, dst, d.un.operand, iw),
        .convert => try emitConvert(self, dst, d.un.operand, ty),
        .fneg => try emitFneg(self, dst, d.un.operand, widthOf(self.tctx(), self.f.valueType(d.un.operand)).bytes),
        .icmp_eq, .icmp_ne, .icmp_slt, .icmp_sle, .icmp_sgt, .icmp_sge, .icmp_ult, .icmp_ule, .icmp_ugt, .icmp_uge => try emitIcmp(self, op, dst, d.bin.lhs, d.bin.rhs),
        .fcmp_eq, .fcmp_ne, .fcmp_lt, .fcmp_le, .fcmp_gt, .fcmp_ge => try emitFcmp(self, op, dst, d.bin.lhs, d.bin.rhs, widthOf(self.tctx(), self.f.valueType(d.bin.lhs)).bytes),
        .jump => try emitJump(self, d.jump.target, d.jump.args),
        .br => try emitBr(self, d.br.cond, d.br.then_blk, d.br.then_args, d.br.else_blk, d.br.else_args),
        .ret => try emitRet(self, d.ret.vals),
        .unreachable_ => try self.ud2(),
        .call => {
            const ret: ?CallReturn = if (self.tctx().typeOf(ty) == .void) null else .{ .dst = dst, .ty = ty };
            try emitCallLike(self, self.module.func(d.call.func).name, d.call.args, ret);
        },
        .rt_call => {
            const ret: ?CallReturn = if (self.tctx().typeOf(ty) == .void) null else .{ .dst = dst, .ty = ty };
            try emitCallLike(self, rt_symbol.get(d.rt_call.rt), d.rt_call.args, ret);
        },
        .atomic_load => try emitAtomicLoad(self, dst, d.atomic_load.ptr, ty),
        .atomic_store => try emitAtomicStore(self, d.atomic_store.ptr, d.atomic_store.value, self.f.valueType(d.atomic_store.value)),
        .atomic_cmpxchg => try emitAtomicCmpxchg(self, dst, d.atomic_cmpxchg.ptr, d.atomic_cmpxchg.expected, d.atomic_cmpxchg.desired),
        .atomic_rmw_add, .atomic_rmw_sub, .atomic_rmw_and, .atomic_rmw_or, .atomic_rmw_xchg => try emitAtomicRmw(self, op, dst, d.atomic_rmw.ptr, d.atomic_rmw.operand, ty),
        .field_get => try emitFieldGet(self, dst, d.field_get.base, d.field_get.offset, ty),
        .field_set => try emitFieldSet(self, d.field_set.base, d.field_set.offset, d.field_set.value, self.f.valueType(d.field_set.value)),
        .index_get => try emitIndexGet(self, dst, d.index_get.base, d.index_get.index, ty),
        .index_set => try emitIndexSet(self, d.index_set.base, d.index_set.index, d.index_set.value, self.f.valueType(d.index_set.value)),
        .gc_alloc => try emitGcAlloc(self, dst, d.gc_alloc.size, d.gc_alloc.ptr_offsets),
        .type_info => try emitTypeInfo(self, dst, d.type_info.disc, d.type_info.size, d.type_info.ptr_offsets),
        .make_closure => try emitMakeClosure(self, dst, d.make_closure.func, d.make_closure.env),
        .func_addr => try emitFuncAddr(self, dst, d.func_addr.func),
        .call_value => try emitCallValue(self, dst, ty, d.call_value.callee, d.call_value.args),
        .slice_len => try emitSliceLen(self, dst, d.slice_len.base),
        .call_iface => try emitCallIface(self, dst, ty, d.call_iface.iface, d.call_iface.method_index, d.call_iface.args),
        .block_param => unreachable, // dispatch loop skips a block's leading param_count instructions
    }
}

// ============================================================================
// Top-level driver
// ============================================================================

/// Compiles one `ir.Function` to machine code for `cc`. Runs register
/// allocation itself (building intervals/safepoints from the IR), lays out
/// the stack frame, then emits the prologue, every block in `f.blocks`
/// order (which back-edge detection assumes is the original builder/RPO
/// order — see `isBackEdge`), and the fixed-up jump targets.
pub fn compileFunction(gpa: Allocator, module: *const ir.Module, f: *const ir.Function, cc: CallConv) CodegenError!FuncCode {
    const tctx = module.ctx;
    const flags = scanFuncFlags(f);

    var int_buf: [max_int_regs]Reg = undefined;
    var float_buf: [max_float_regs]XReg = undefined;
    const int_regs = buildIntRegs(&int_buf, cc, flags.has_safepoints, flags.needs_rax_rdx, flags.needs_rcx);
    const float_regs = buildFloatRegs(&float_buf, cc, flags.has_safepoints);

    const intervals = try buildIntervals(gpa, tctx, f);
    defer gpa.free(intervals);
    const safepoints = try collectSafepoints(gpa, f);
    defer gpa.free(safepoints);

    const target = regalloc.TargetRegs{
        .int = .{ .count = @intCast(int_regs.len), .callee_saved = calleeSavedIntMask(cc, int_regs) },
        .float = .{ .count = @intCast(float_regs.len), .callee_saved = calleeSavedFloatMask(cc, float_regs) },
    };
    var result = try regalloc.allocate(gpa, target, intervals, safepoints);
    defer result.deinit();

    var saved_gpr_buf: [max_int_regs]Reg = undefined;
    var saved_xmm_buf: [max_float_regs]XReg = undefined;
    const saved_gpr = buildSavedGpr(&saved_gpr_buf, cc, int_regs);
    const saved_xmm = buildSavedXmm(&saved_xmm_buf, cc, float_regs);
    const raw_frame = 8 * (result.num_spill_slots + @as(u32, @intCast(saved_xmm.len)));
    const frame = FrameInfo{
        .saved_gpr = saved_gpr,
        .saved_xmm = saved_xmm,
        .num_spill_slots = result.num_spill_slots,
        .frame_size = alignFrame(raw_frame, @intCast(saved_gpr.len)),
    };

    const inst_to_vreg = try gpa.alloc(u32, f.insts.len);
    errdefer gpa.free(inst_to_vreg);
    for (0..f.insts.len) |i| inst_to_vreg[i] = @intCast(i);

    const block_offsets = try gpa.alloc(u32, f.blocks.len);
    errdefer gpa.free(block_offsets);
    const safepoint_code_offsets = try gpa.alloc(u32, safepoints.len);
    errdefer gpa.free(safepoint_code_offsets);

    var ctx = Ctx{
        .gpa = gpa,
        .cc = cc,
        .module = module,
        .f = f,
        .inst_to_vreg = inst_to_vreg,
        .result = &result,
        .int_regs = int_regs,
        .float_regs = float_regs,
        .frame = frame,
        .block_offsets = block_offsets,
        .safepoint_code_offsets = safepoint_code_offsets,
    };
    errdefer ctx.code.deinit(gpa);
    errdefer ctx.relocs.deinit(gpa);
    errdefer ctx.jump_fixups.deinit(gpa);
    errdefer {
        for (ctx.owned_syms.items) |s| gpa.free(s);
        ctx.owned_syms.deinit(gpa);
    }

    try emitPrologue(&ctx);
    try bindIncomingArgs(&ctx);
    for (f.blocks, 0..) |blk, bi| {
        ctx.cur_block_idx = @intCast(bi);
        ctx.block_offsets[bi] = @intCast(ctx.code.items.len);
        var i = blk.insts_start + blk.param_count;
        const end = blk.insts_start + blk.insts_len;
        while (i < end) : (i += 1) {
            try emitInst(&ctx, @enumFromInt(i));
        }
    }
    ctx.patchJumpFixups();
    ctx.jump_fixups.deinit(gpa);

    const code = try ctx.code.toOwnedSlice(gpa);
    errdefer gpa.free(code);
    const relocs = try ctx.relocs.toOwnedSlice(gpa);
    errdefer gpa.free(relocs);
    const owned_syms = try ctx.owned_syms.toOwnedSlice(gpa);
    errdefer {
        for (owned_syms) |s| gpa.free(s);
        gpa.free(owned_syms);
    }

    const sp_entries = try gpa.alloc(SafepointEntry, safepoints.len);
    var built: usize = 0;
    errdefer {
        for (sp_entries[0..built]) |e| {
            gpa.free(e.regs);
            gpa.free(e.frame_offsets);
        }
        gpa.free(sp_entries);
    }
    for (result.stack_maps, 0..) |sm, idx| {
        const regs = try gpa.alloc(Reg, sm.regs.len);
        errdefer gpa.free(regs);
        for (sm.regs, 0..) |r, ri| regs[ri] = int_regs[r];
        const offs = try gpa.alloc(i32, sm.slots.len);
        for (sm.slots, 0..) |s, si| offs[si] = frame.spillOffset(s);
        sp_entries[idx] = .{ .code_offset = safepoint_code_offsets[idx], .regs = regs, .frame_offsets = offs };
        built += 1;
    }
    gpa.free(safepoint_code_offsets);
    gpa.free(inst_to_vreg);
    gpa.free(block_offsets);

    // Register-recovery slots: the prologue does `push rbp; mov rbp,rsp; push
    // saved_gpr[i]...`, so the caller's value of `saved_gpr[i]` lands at
    // rbp - 8*(i+1) — fp-relative, matching `SafepointEntry.frame_offsets`.
    const saved_regs = try gpa.alloc(common.SavedReg, frame.saved_gpr.len);
    for (frame.saved_gpr, 0..) |r, i| saved_regs[i] = .{
        .reg = @intFromEnum(r),
        .fp_off = -@as(i32, @intCast(8 * (i + 1))),
    };

    return .{
        .gpa = gpa,
        .name = f.name,
        .code = code,
        .relocs = relocs,
        .safepoints = sp_entries,
        .saved_regs = saved_regs,
        .frame_size = frame.frame_size,
        .owned_syms = owned_syms,
    };
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;
const builtin = @import("builtin");

/// Minimal `Ctx` for exercising a low-level encoder method directly.
/// `module`/`f`/`result` are `undefined` — safe here because every method
/// exercised this way (`movRR`, `arithRR`, `push`/`pop`, `setcc`, the SSE2
/// helpers, etc.) only ever touches `self.code`; nothing in this file calls
/// `self.tctx()`/`self.f`/`self.result` from those methods. Integration-level
/// tests further down go through `compileFunction` instead, which builds a
/// fully real `Ctx`.
fn testCtx(gpa: Allocator) Ctx {
    const S = struct {
        var block_offsets: [0]u32 = .{};
        var safepoint_offsets: [0]u32 = .{};
    };
    return .{
        .gpa = gpa,
        .cc = .sysv,
        .module = undefined,
        .f = undefined,
        .inst_to_vreg = &.{},
        .result = undefined,
        .int_regs = &.{},
        .float_regs = &.{},
        .frame = .{ .saved_gpr = &.{}, .saved_xmm = &.{}, .num_spill_slots = 0, .frame_size = 0 },
        .block_offsets = &S.block_offsets,
        .safepoint_code_offsets = &S.safepoint_offsets,
    };
}

test "rex encodes W/R/X/B bits" {
    try testing.expectEqual(@as(u8, 0x40), rex(false, false, false, false));
    try testing.expectEqual(@as(u8, 0x48), rex(true, false, false, false));
    try testing.expectEqual(@as(u8, 0x44), rex(false, true, false, false));
    try testing.expectEqual(@as(u8, 0x42), rex(false, false, true, false));
    try testing.expectEqual(@as(u8, 0x41), rex(false, false, false, true));
    try testing.expectEqual(@as(u8, 0x4F), rex(true, true, true, true));
}

test "modrmRegByte encodes mod=11 register-direct operands" {
    try testing.expectEqual(@as(u8, 0xC0), modrmRegByte(0, 0));
    try testing.expectEqual(@as(u8, 0xD3), modrmRegByte(10, 3)); // reg=r10 (masked to 2), rm=rbx(3)
    try testing.expectEqual(@as(u8, 0xFF), modrmRegByte(15, 15)); // reg=r15 (masked to 7), rm=r15(masked to 7)
}

test "scaleBits maps element widths to SIB scale encoding" {
    try testing.expectEqual(@as(u2, 0), scaleBits(1));
    try testing.expectEqual(@as(u2, 1), scaleBits(2));
    try testing.expectEqual(@as(u2, 2), scaleBits(4));
    try testing.expectEqual(@as(u2, 3), scaleBits(8));
}

// The following byte goldens were cross-checked against GNU `as`/`objdump -d
// -M intel` disassembly of the equivalent Intel-syntax instruction (task
// #340's verify criterion) — see the task's own PR notes for the assembled
// reference. `sete al` is the one deliberate divergence: this encoder always
// forces a REX prefix on `setcc` (see that method's doc comment), so its
// output is `40 0F 94 C0` rather than the minimal `0F 94 C0` an assembler
// would pick — both decode to the identical instruction.

test "movRR encodes REX.W + MOV r/m64,r64" {
    const gpa = testing.allocator;
    var ctx = testCtx(gpa);
    defer ctx.code.deinit(gpa);
    try ctx.movRR(.rbx, .r10);
    try testing.expectEqualSlices(u8, &.{ 0x4C, 0x89, 0xD3 }, ctx.code.items);
}

test "movRR is a no-op when src == dst" {
    const gpa = testing.allocator;
    var ctx = testCtx(gpa);
    defer ctx.code.deinit(gpa);
    try ctx.movRR(.rax, .rax);
    try testing.expectEqual(@as(usize, 0), ctx.code.items.len);
}

// Regression (#1235): two spilled values swapping stack slots form a
// mem<->mem 2-cycle in an edge's parallel move. The cycle-break saves one
// slot's value in a scratch register held across the whole rotation, so that
// register must differ from the one `emitMove` uses as its own mem->mem copy
// temp (`scratch1`). Using `scratch1` for both means the first rotation step
// overwrites the saved value and the swap silently corrupts. Byte-exact so a
// revert to `scratch1` fails here, not only in the allocation-sensitive golden.
test "sequentializeAndEmit breaks a mem<->mem swap cycle without clobbering the saved value" {
    const gpa = testing.allocator;
    const moves = [_]PMove{
        .{ .from = .{ .mem = 0 }, .to = .{ .mem = 8 } },
        .{ .from = .{ .mem = 8 }, .to = .{ .mem = 0 } },
    };
    var got = testCtx(gpa);
    defer got.code.deinit(gpa);
    try sequentializeAndEmit(&got, &moves, .int);

    var want = testCtx(gpa);
    defer want.code.deinit(gpa);
    try want.movLoad(scratch2, .rbp, null, 1, 8, 8, false); // save start slot into r10 (NOT r11)
    try want.movLoad(scratch1, .rbp, null, 1, 0, 8, false); // rotate the mem->mem move via r11
    try want.movStore(.rbp, null, 1, 8, scratch1, 8);
    try want.movStore(.rbp, null, 1, 0, scratch2, 8); // restore saved value from r10
    try testing.expectEqualSlices(u8, want.code.items, got.code.items);
}

test "movRI encodes a sign-extended imm32 for values that fit" {
    const gpa = testing.allocator;
    var ctx = testCtx(gpa);
    defer ctx.code.deinit(gpa);
    try ctx.movRI(.rax, 5);
    try testing.expectEqualSlices(u8, &.{ 0x48, 0xC7, 0xC0, 0x05, 0x00, 0x00, 0x00 }, ctx.code.items);
}

test "movRI encodes a full imm64 when the value overflows i32" {
    const gpa = testing.allocator;
    var ctx = testCtx(gpa);
    defer ctx.code.deinit(gpa);
    try ctx.movRI(.rax, 0x1_0000_0000);
    try testing.expectEqualSlices(u8, &.{ 0x48, 0xB8, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00 }, ctx.code.items);
}

test "arithRR add encodes REX.W + ADD r/m64,r64" {
    const gpa = testing.allocator;
    var ctx = testCtx(gpa);
    defer ctx.code.deinit(gpa);
    try ctx.arithRR(.add, .rax, .rcx);
    try testing.expectEqualSlices(u8, &.{ 0x48, 0x01, 0xC8 }, ctx.code.items);
}

test "arithRR cmp encodes REX.W + CMP r/m64,r64" {
    const gpa = testing.allocator;
    var ctx = testCtx(gpa);
    defer ctx.code.deinit(gpa);
    try ctx.arithRR(.cmp, .rdi, .rsi);
    try testing.expectEqualSlices(u8, &.{ 0x48, 0x39, 0xF7 }, ctx.code.items);
}

test "push/pop encode REX.B for r8-r15" {
    const gpa = testing.allocator;
    var ctx = testCtx(gpa);
    defer ctx.code.deinit(gpa);
    try ctx.push(.r12);
    try ctx.pop(.r12);
    try testing.expectEqualSlices(u8, &.{ 0x41, 0x54, 0x41, 0x5C }, ctx.code.items);
}

test "ret encodes a bare 0xC3" {
    const gpa = testing.allocator;
    var ctx = testCtx(gpa);
    defer ctx.code.deinit(gpa);
    try ctx.ret();
    try testing.expectEqualSlices(u8, &.{0xC3}, ctx.code.items);
}

test "setcc always forces a REX prefix" {
    const gpa = testing.allocator;
    var ctx = testCtx(gpa);
    defer ctx.code.deinit(gpa);
    try ctx.setcc(CC.e, .rax);
    try testing.expectEqualSlices(u8, &.{ 0x40, 0x0F, 0x94, 0xC0 }, ctx.code.items);
}

test "movzxb encodes REX.W + MOVZX r64,r/m8" {
    const gpa = testing.allocator;
    var ctx = testCtx(gpa);
    defer ctx.code.deinit(gpa);
    try ctx.movzxb(.rax, .rax); // movzx rax, al
    try testing.expectEqualSlices(u8, &.{ 0x48, 0x0F, 0xB6, 0xC0 }, ctx.code.items);
}

test "movFRR encodes movsd for width 8" {
    const gpa = testing.allocator;
    var ctx = testCtx(gpa);
    defer ctx.code.deinit(gpa);
    try ctx.movFRR(.xmm1, .xmm2, 8);
    try testing.expectEqualSlices(u8, &.{ 0xF2, 0x0F, 0x10, 0xCA }, ctx.code.items);
}

test "fArithRR encodes addsd" {
    const gpa = testing.allocator;
    var ctx = testCtx(gpa);
    defer ctx.code.deinit(gpa);
    try ctx.fArithRR(.add, .xmm0, .xmm1, 8);
    try testing.expectEqualSlices(u8, &.{ 0xF2, 0x0F, 0x58, 0xC1 }, ctx.code.items);
}

// ---- integration: compileFunction over a real IR function -----------------
//
// Executed only on x86-64 Linux (the CI runner this backend targets — module
// doc comment / task #340's verify criterion): generated machine code is
// mmap'd PROT_EXEC and called directly as a native function pointer, since
// no object writer/linker (#342-345) exists yet to produce a real
// executable. This is still a full, real proof that regalloc + the SysV
// calling convention + the encoder agree with each other — not a mock.

const can_exec_native = builtin.cpu.arch == .x86_64 and builtin.os.tag == .linux;

fn mmapExec(code: []const u8) ![]align(std.heap.page_size_min) u8 {
    const mem = try std.posix.mmap(
        null,
        code.len,
        .{ .READ = true, .WRITE = true, .EXEC = true },
        .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
        -1,
        0,
    );
    @memcpy(mem[0..code.len], code);
    return mem;
}

test "compileFunction: add(a, b) executes under the SysV convention" {
    if (!can_exec_native) return error.SkipZigTest;
    const gpa = testing.allocator;
    var tctx = try TypeContext.init(gpa);
    defer tctx.deinit();
    const i64_ty = tctx.prim_ids.get(.i64);

    var module = ir.Module.init(gpa, &tctx);
    defer module.deinit();

    var b = ir.FunctionBuilder.init(gpa);
    const entry = try b.newBlock();
    b.beginBlock(entry);
    const p0 = try b.addParam(i64_ty);
    const p1 = try b.addParam(i64_ty);
    const sum = try b.binary(.add, i64_ty, p0, p1);
    try b.ret(&.{sum});
    b.endBlock();
    var f = try b.finish("add", &.{ i64_ty, i64_ty }, i64_ty, false, .invalid, entry);
    defer f.deinit(gpa);

    var code = try compileFunction(gpa, &module, &f, .sysv);
    defer code.deinit();
    try testing.expectEqual(@as(usize, 0), code.relocs.len);
    try testing.expectEqual(@as(usize, 0), code.safepoints.len);

    const mem = try mmapExec(code.code);
    defer std.posix.munmap(mem);
    const fn_ptr: *const fn (i64, i64) callconv(.c) i64 = @ptrCast(mem.ptr);
    try testing.expectEqual(@as(i64, 7), fn_ptr(3, 4));
    try testing.expectEqual(@as(i64, -1), fn_ptr(-5, 4));
}

test "compileFunction: branch + block params select max(a, b)" {
    if (!can_exec_native) return error.SkipZigTest;
    const gpa = testing.allocator;
    var tctx = try TypeContext.init(gpa);
    defer tctx.deinit();
    const i64_ty = tctx.prim_ids.get(.i64);

    var module = ir.Module.init(gpa, &tctx);
    defer module.deinit();

    var b = ir.FunctionBuilder.init(gpa);
    const entry = try b.newBlock();
    const join = try b.newBlock();

    b.beginBlock(entry);
    const p0 = try b.addParam(i64_ty);
    const p1 = try b.addParam(i64_ty);
    const cond = try b.binary(.icmp_sgt, tctx.prim_ids.get(.bool), p0, p1);
    try b.br(cond, join, &.{p0}, join, &.{p1});
    b.endBlock();

    b.beginBlock(join);
    const result = try b.addParam(i64_ty);
    try b.ret(&.{result});
    b.endBlock();

    var f = try b.finish("max", &.{ i64_ty, i64_ty }, i64_ty, false, .invalid, entry);
    defer f.deinit(gpa);

    var code = try compileFunction(gpa, &module, &f, .sysv);
    defer code.deinit();

    const mem = try mmapExec(code.code);
    defer std.posix.munmap(mem);
    const fn_ptr: *const fn (i64, i64) callconv(.c) i64 = @ptrCast(mem.ptr);
    try testing.expectEqual(@as(i64, 9), fn_ptr(9, 4));
    try testing.expectEqual(@as(i64, 9), fn_ptr(4, 9));
    try testing.expectEqual(@as(i64, 5), fn_ptr(5, 5));
}

test "compileFunction: icmp_sgt yields a clean 0/1 without clobbering the compare flags" {
    // Regression guard: `setcc` reads the flags the `cmp` set, so the result
    // must be widened afterward — zeroing the destination first (an `xor`)
    // would force ZF=1 and make every comparison read false.
    if (!can_exec_native) return error.SkipZigTest;
    const gpa = testing.allocator;
    var tctx = try TypeContext.init(gpa);
    defer tctx.deinit();
    const i64_ty = tctx.prim_ids.get(.i64);
    const bool_ty = tctx.prim_ids.get(.bool);

    var module = ir.Module.init(gpa, &tctx);
    defer module.deinit();

    var b = ir.FunctionBuilder.init(gpa);
    const entry = try b.newBlock();
    b.beginBlock(entry);
    const p0 = try b.addParam(i64_ty);
    const p1 = try b.addParam(i64_ty);
    const gt = try b.binary(.icmp_sgt, bool_ty, p0, p1);
    try b.ret(&.{gt});
    b.endBlock();
    var f = try b.finish("gt", &.{ i64_ty, i64_ty }, bool_ty, false, .invalid, entry);
    defer f.deinit(gpa);

    var code = try compileFunction(gpa, &module, &f, .sysv);
    defer code.deinit();

    const mem = try mmapExec(code.code);
    defer std.posix.munmap(mem);
    const fn_ptr: *const fn (i64, i64) callconv(.c) i64 = @ptrCast(mem.ptr);
    try testing.expectEqual(@as(i64, 1), fn_ptr(9, 4));
    try testing.expectEqual(@as(i64, 0), fn_ptr(4, 9));
    try testing.expectEqual(@as(i64, 0), fn_ptr(5, 5));
}

test "compileFunction: a loop back-edge records one safepoint per iteration site" {
    // sum(n) { total = 0; i = 0; while (i < n) { total += i; i += 1 }; return total }
    // Exercises loop-carried block-param rotation and back-edge safepoint
    // insertion. Not executed: the synthetic `bit_rt_safepoint` call's
    // relocation is only resolvable once a linker (#345) exists, so running
    // this would call into whatever bytes happen to follow in the mmap'd
    // buffer. Verified structurally instead: it compiles, and records
    // exactly the relocations/safepoints the module doc comment promises.
    const gpa = testing.allocator;
    var tctx = try TypeContext.init(gpa);
    defer tctx.deinit();
    const i64_ty = tctx.prim_ids.get(.i64);
    const bool_ty = tctx.prim_ids.get(.bool);

    var module = ir.Module.init(gpa, &tctx);
    defer module.deinit();

    var b = ir.FunctionBuilder.init(gpa);
    const entry = try b.newBlock();
    const header = try b.newBlock();
    const body = try b.newBlock();
    const exit = try b.newBlock();

    b.beginBlock(entry);
    const n = try b.addParam(i64_ty);
    const zero = try b.constInt(i64_ty, 0);
    try b.jump(header, &.{ zero, zero });
    b.endBlock();

    b.beginBlock(header);
    const total_in = try b.addParam(i64_ty);
    const i_in = try b.addParam(i64_ty);
    const cond = try b.binary(.icmp_slt, bool_ty, i_in, n);
    try b.br(cond, body, &.{ total_in, i_in }, exit, &.{total_in});
    b.endBlock();

    b.beginBlock(body);
    const total_body = try b.addParam(i64_ty);
    const i_body = try b.addParam(i64_ty);
    const one = try b.constInt(i64_ty, 1);
    const total_next = try b.binary(.add, i64_ty, total_body, i_body);
    const i_next = try b.binary(.add, i64_ty, i_body, one);
    try b.jump(header, &.{ total_next, i_next }); // back-edge: header's index <= body's
    b.endBlock();

    b.beginBlock(exit);
    const total_out = try b.addParam(i64_ty);
    try b.ret(&.{total_out});
    b.endBlock();

    var f = try b.finish("sum", &.{i64_ty}, i64_ty, false, .invalid, entry);
    defer f.deinit(gpa);

    var code = try compileFunction(gpa, &module, &f, .sysv);
    defer code.deinit();

    try testing.expect(code.code.len > 0);
    try testing.expectEqual(@as(usize, 1), code.safepoints.len);
    try testing.expectEqual(@as(usize, 1), code.relocs.len);
    try testing.expectEqualStrings("bit_rt_safepoint", code.relocs[0].symbol);
}

test "compileFunction: field_get loads a typed value at a byte offset" {
    if (!can_exec_native) return error.SkipZigTest;
    const gpa = testing.allocator;
    var tctx = try TypeContext.init(gpa);
    defer tctx.deinit();
    const i64_ty = tctx.prim_ids.get(.i64);

    var module = ir.Module.init(gpa, &tctx);
    defer module.deinit();

    // `field_get` only needs a byte offset and its own result type — the
    // base's declared type is irrelevant to addressing (module doc comment),
    // so a plain `i64` parameter standing in for a pointer is enough here.
    var b = ir.FunctionBuilder.init(gpa);
    const entry = try b.newBlock();
    b.beginBlock(entry);
    const base = try b.addParam(i64_ty);
    const v = try b.fieldGet(i64_ty, base, 8);
    try b.ret(&.{v});
    b.endBlock();
    var f = try b.finish("readField", &.{i64_ty}, i64_ty, false, .invalid, entry);
    defer f.deinit(gpa);

    var code = try compileFunction(gpa, &module, &f, .sysv);
    defer code.deinit();

    const mem = try mmapExec(code.code);
    defer std.posix.munmap(mem);
    const fn_ptr: *const fn (i64) callconv(.c) i64 = @ptrCast(mem.ptr);

    var backing = [_]i64{ 111, 222, 333 };
    try testing.expectEqual(@as(i64, 222), fn_ptr(@intCast(@intFromPtr(&backing[0]))));
}

test "compileFunction: index_get on a static array base loads the element" {
    if (!can_exec_native) return error.SkipZigTest;
    const gpa = testing.allocator;
    var tctx = try TypeContext.init(gpa);
    defer tctx.deinit();
    const i64_ty = tctx.prim_ids.get(.i64);
    const arr_ty = try tctx.arrayType(3, i64_ty); // a real `.array` — the positive path

    var module = ir.Module.init(gpa, &tctx);
    defer module.deinit();

    var b = ir.FunctionBuilder.init(gpa);
    const entry = try b.newBlock();
    b.beginBlock(entry);
    const base = try b.addParam(arr_ty);
    const idx = try b.addParam(i64_ty);
    const v = try b.indexGet(i64_ty, base, idx);
    try b.ret(&.{v});
    b.endBlock();
    var f = try b.finish("at", &.{ arr_ty, i64_ty }, i64_ty, false, .invalid, entry);
    defer f.deinit(gpa);

    var code = try compileFunction(gpa, &module, &f, .sysv);
    defer code.deinit();

    const mem = try mmapExec(code.code);
    defer std.posix.munmap(mem);
    const fn_ptr: *const fn (*const i64, i64) callconv(.c) i64 = @ptrCast(mem.ptr);

    const backing = [_]i64{ 10, 20, 30 };
    try testing.expectEqual(@as(i64, 10), fn_ptr(&backing[0], 0));
    try testing.expectEqual(@as(i64, 20), fn_ptr(&backing[0], 1));
    try testing.expectEqual(@as(i64, 30), fn_ptr(&backing[0], 2));
}

test "compileFunction: index_get on a non-array base is unsupported" {
    const gpa = testing.allocator;
    var tctx = try TypeContext.init(gpa);
    defer tctx.deinit();
    const i64_ty = tctx.prim_ids.get(.i64);

    var module = ir.Module.init(gpa, &tctx);
    defer module.deinit();

    var b = ir.FunctionBuilder.init(gpa);
    const entry = try b.newBlock();
    b.beginBlock(entry);
    const base = try b.addParam(i64_ty); // not `.array` — index_get must reject it
    const idx = try b.addParam(i64_ty);
    const v = try b.indexGet(i64_ty, base, idx);
    try b.ret(&.{v});
    b.endBlock();
    var f = try b.finish("bad", &.{ i64_ty, i64_ty }, i64_ty, false, .invalid, entry);
    defer f.deinit(gpa);

    try testing.expectError(error.UnsupportedConstruct, compileFunction(gpa, &module, &f, .sysv));
}

test "compileFunction: a multi-value ret is unsupported" {
    const gpa = testing.allocator;
    var tctx = try TypeContext.init(gpa);
    defer tctx.deinit();
    const i64_ty = tctx.prim_ids.get(.i64);

    var module = ir.Module.init(gpa, &tctx);
    defer module.deinit();

    var b = ir.FunctionBuilder.init(gpa);
    const entry = try b.newBlock();
    b.beginBlock(entry);
    const p0 = try b.addParam(i64_ty);
    const p1 = try b.addParam(i64_ty);
    try b.ret(&.{ p0, p1 });
    b.endBlock();
    var f = try b.finish("bad", &.{ i64_ty, i64_ty }, i64_ty, false, .invalid, entry);
    defer f.deinit(gpa);

    try testing.expectError(error.UnsupportedConstruct, compileFunction(gpa, &module, &f, .sysv));
}

test "compileFunction: a Win64 call records its safepoint at the return address, before the home-space restore" {
    // Structural (not executed — the runtime symbol is unresolved until a
    // linker exists). A Win64 `call` is bracketed by `sub rsp,32` / `add
    // rsp,32` home-space adjustments; the safepoint's code offset must be the
    // return address (right after the 5-byte `E8 rel32`), NOT after the
    // trailing `add rsp,32`, or a GC stack-map lookup keyed on the return
    // address would miss by the 7 bytes of that restore.
    const gpa = testing.allocator;
    var tctx = try TypeContext.init(gpa);
    defer tctx.deinit();
    const i64_ty = tctx.prim_ids.get(.i64);
    const string_ty = tctx.prim_ids.get(.string);

    var module = ir.Module.init(gpa, &tctx);
    defer module.deinit();

    var b = ir.FunctionBuilder.init(gpa);
    const entry = try b.newBlock();
    b.beginBlock(entry);
    const n = try b.addParam(i64_ty);
    const s = try b.rtCall(string_ty, .string_from_int, &.{n}); // a real call → one safepoint
    try b.ret(&.{s});
    b.endBlock();
    var f = try b.finish("toStr", &.{i64_ty}, string_ty, false, .invalid, entry);
    defer f.deinit(gpa);

    var code = try compileFunction(gpa, &module, &f, .win64);
    defer code.deinit();

    try testing.expectEqual(@as(usize, 1), code.safepoints.len);
    const sp = code.safepoints[0].code_offset;
    // The 5 bytes ending at `sp` are the call; the bytes starting at `sp` are
    // the `add rsp,32` home-space restore (48 81 C4 ...).
    try testing.expectEqual(@as(u8, 0xE8), code.code[sp - 5]);
    try testing.expectEqualSlices(u8, &.{ 0x48, 0x81, 0xC4 }, code.code[sp .. sp + 3]);
}

test "compileFunction: gc_alloc calls bit_rt_gc_alloc with a TypeInfo reloc" {
    // A real aggregate `.array` type — the exact shape the front end emits
    // `gc_alloc` for. Codegen loads the deduped `__bittype_*` TypeInfo blob's
    // address and calls the runtime allocator; the object emitter defines the
    // blob (see emit.zig) and the linker resolves `bit_rt_gc_alloc`.
    const gpa = testing.allocator;
    var tctx = try TypeContext.init(gpa);
    defer tctx.deinit();
    const i64_ty = tctx.prim_ids.get(.i64);
    const arr_ty = try tctx.arrayType(4, i64_ty);

    var module = ir.Module.init(gpa, &tctx);
    defer module.deinit();

    var b = ir.FunctionBuilder.init(gpa);
    const entry = try b.newBlock();
    b.beginBlock(entry);
    const v = try b.gcAlloc(arr_ty, 32, &.{});
    try b.ret(&.{v});
    b.endBlock();
    var f = try b.finish("mkarr", &.{}, i64_ty, false, .invalid, entry);
    defer f.deinit(gpa);

    var fc = try compileFunction(gpa, &module, &f, .sysv);
    defer fc.deinit();

    var saw_call = false;
    var saw_type = false;
    for (fc.relocs) |r| {
        if (std.mem.eql(u8, r.symbol, "bit_rt_gc_alloc")) saw_call = true;
        if (std.mem.startsWith(u8, r.symbol, "__bittype_")) saw_type = true;
    }
    try testing.expect(saw_call);
    try testing.expect(saw_type);
}
