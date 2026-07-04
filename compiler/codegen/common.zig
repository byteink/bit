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
        .void, .untyped_int, .untyped_float, .untyped_rune, .untyped_bool, .untyped_string, .untyped_nil, .invalid, .type_param, .fallible => false,
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
