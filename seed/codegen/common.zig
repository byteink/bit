//! Backend-agnostic pieces shared by every codegen backend (x86-64 `x64.zig`
//! #340, ARM64 `arm64.zig` #341, and any future target). Kept deliberately
//! tiny: only logic that has zero dependency on a physical register file or
//! instruction encoding belongs here — everything else (register lists,
//! calling-convention argument mapping, the instruction encoder, frame
//! layout) is inherently per-ISA and stays in its own backend file.
//! Divergence between backends in code that COULD live here is a design
//! smell (see `arm64.zig`'s module comment); extract more here only once a
//! second concrete user demonstrates the logic is truly identical, not
//! merely similar.

const std = @import("std");
const check = @import("../check.zig");

const Allocator = std.mem.Allocator;
const TypeId = check.TypeId;
const TypeContext = check.TypeContext;
const Class = @import("../regalloc.zig").Class;

// ============================================================================
// Type classification (mirrors `lower.zig`'s object-layout scheme: every
// scalar prim is stored at its natural width; every other shape is one
// boxed 8-byte handle) — identical for every backend, since it depends only
// on the checker's `TypeContext`, never on a physical register.
// ============================================================================

pub const Width = struct { bytes: u8, class: Class, signed: bool };

pub fn widthOf(tctx: *const TypeContext, ty: TypeId) Width {
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

pub fn classOf(tctx: *const TypeContext, ty: TypeId) Class {
    return widthOf(tctx, ty).class;
}

/// True iff a value of type `ty` is a GC reference (`lower.zig`'s
/// `fieldLayout(...).is_ptr`, re-derived here for codegen's own use).
pub fn isRefType(tctx: *const TypeContext, ty: TypeId) bool {
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

/// A call-site relocation: `offset` names the byte, within a `FuncCode.code`,
/// of the field an object writer must patch to point at `symbol` (a Bit
/// function's own name, or a runtime symbol). The *width and meaning* of
/// that field is architecture-specific (x86-64: a 4-byte `E8 rel32`; ARM64:
/// a `BL`'s 26-bit immediate) — the object writer (#342/#343) already has to
/// be relocation-type-aware per target, so only the offset/symbol pairing
/// needs to be common.
pub const Reloc = struct {
    offset: u32,
    symbol: []const u8,
};

pub const CodegenError = error{
    UnsupportedConstruct,
    TooManyArguments,
} || Allocator.Error;

// ============================================================================
// GC stack-map table (`runtime/ABI.md` §4)
//
// The precise collector walks each Bit frame at a safepoint and needs, per
// return address, which stack slots and callee-saved registers hold a live GC
// reference — plus, to unwind past a frame, where that frame stashed the
// caller's callee-saved registers. Each backend computes this per function
// (`SafepointEntry` + the frame's saved-register list); `writeStackMaps`
// serializes the whole module into one blob the runtime reads at collection
// time via the `bit_stack_maps` symbol.
//
// All offsets are **frame-pointer-relative** (`rbp` on x86-64, `x29` on
// AArch64), normalized by each backend so the runtime walker is arch-neutral.
// Both arches chain frames identically: `*(fp)` is the caller's fp and
// `*(fp+8)` is the return address.
// ============================================================================

/// One callee-saved register a function preserves in its prologue, and the
/// frame-relative slot where it stashed the CALLER's value. Unwinding past
/// this frame, the walker restores the register from `*(fp + fp_off)`.
pub const SavedReg = struct { reg: u16, fp_off: i32 };

/// The live-reference set at one safepoint (a call/back-edge return address).
pub const SafepointView = struct {
    /// Return address = the function's code address + this offset.
    ret_offset: u32,
    /// Frame-pointer-relative offsets of stack slots holding a live reference.
    slots: []const i32,
    /// Physical register numbers holding a live reference at this point.
    regs: []const u16,
};

/// One function's contribution to the module stack-map table.
pub const FuncStackMap = struct {
    code_size: u32,
    saved: []const SavedReg,
    safepoints: []const SafepointView,
};

fn appendU16(out: *std.ArrayList(u8), gpa: Allocator, v: u16) !void {
    var b: [2]u8 = undefined;
    std.mem.writeInt(u16, &b, v, .little);
    try out.appendSlice(gpa, &b);
}

fn appendU32(out: *std.ArrayList(u8), gpa: Allocator, v: u32) !void {
    var b: [4]u8 = undefined;
    std.mem.writeInt(u32, &b, v, .little);
    try out.appendSlice(gpa, &b);
}

/// Serializes the module stack-map table (`runtime/ABI.md` §4) by appending
/// its blob to `out`. Returns, for each function in order, the byte offset
/// within `out` of that function's 8-byte code-address field — the object
/// writer relocates each to the function's own symbol so the runtime reads a
/// real code address. Offsets are section-relative because `out` already holds
/// everything emitted before the table.
///
/// Layout (little-endian, tightly packed — the runtime reads it with unaligned
/// `readInt`s): `u32 num_funcs`, then per function `u64 code_addr`, `u32
/// code_size`, `u16 num_saved` × `{u16 reg, i32 fp_off}`, `u16 num_safepoints`
/// × `{u32 ret_offset, u16 num_slots × i32, u16 num_regs × u16}`.
pub fn writeStackMaps(gpa: Allocator, out: *std.ArrayList(u8), funcs: []const FuncStackMap) Allocator.Error![]u32 {
    const reloc_offsets = try gpa.alloc(u32, funcs.len);
    errdefer gpa.free(reloc_offsets);

    try appendU32(out, gpa, @intCast(funcs.len));
    for (funcs, 0..) |fsm, fi| {
        reloc_offsets[fi] = @intCast(out.items.len);
        try out.appendSlice(gpa, &(.{0} ** 8)); // code_addr — filled by the reloc
        try appendU32(out, gpa, fsm.code_size);
        try appendU16(out, gpa, @intCast(fsm.saved.len));
        for (fsm.saved) |s| {
            try appendU16(out, gpa, s.reg);
            var b: [4]u8 = undefined;
            std.mem.writeInt(i32, &b, s.fp_off, .little);
            try out.appendSlice(gpa, &b);
        }
        try appendU16(out, gpa, @intCast(fsm.safepoints.len));
        for (fsm.safepoints) |sp| {
            try appendU32(out, gpa, sp.ret_offset);
            try appendU16(out, gpa, @intCast(sp.slots.len));
            for (sp.slots) |slot| {
                var b: [4]u8 = undefined;
                std.mem.writeInt(i32, &b, slot, .little);
                try out.appendSlice(gpa, &b);
            }
            try appendU16(out, gpa, @intCast(sp.regs.len));
            for (sp.regs) |r| try appendU16(out, gpa, r);
        }
    }
    return reloc_offsets;
}

test "widthOf classifies every primitive" {
    const gpa = std.testing.allocator;
    var ctx = try TypeContext.init(gpa);
    defer ctx.deinit();

    try std.testing.expectEqual(Width{ .bytes = 1, .class = .int, .signed = true }, widthOf(&ctx, ctx.prim_ids.get(.i8)));
    try std.testing.expectEqual(Width{ .bytes = 8, .class = .float, .signed = false }, widthOf(&ctx, ctx.prim_ids.get(.f64)));
    try std.testing.expectEqual(Width{ .bytes = 8, .class = .int, .signed = false }, widthOf(&ctx, ctx.prim_ids.get(.string)));
    try std.testing.expect(isRefType(&ctx, ctx.prim_ids.get(.string)));
    try std.testing.expect(!isRefType(&ctx, ctx.prim_ids.get(.i64)));
}
