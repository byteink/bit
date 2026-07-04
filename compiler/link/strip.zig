//! Symbol resolution, dead-strip, and relocation arithmetic over the generic
//! object model (`object.zig`), shared by every executable writer. Split from
//! the format-specific driver (`link.zig`) because none of this depends on the
//! output container: given a set of `Module`s it builds the whole-link global
//! symbol table, walks the relocation graph from the entry roots to decide
//! which atoms survive (so `libbitrt.a` + compiler-rt do not drag their whole
//! std-lib closure into every image), and applies one relocation to its field
//! bytes given the resolved addresses.
//!
//! Weak vs. strong binding is not modeled yet: the real inputs here (one Bit
//! module + `libbitrt.a`) define each global name exactly once, so resolution
//! takes the first definition and a second is a hard error. // ponytail:
//! first-def-wins; add weak-override (strong beats weak) when stdlib objects
//! start providing overridable defaults.

const std = @import("std");
const object = @import("object.zig");
const Allocator = std.mem.Allocator;

const Module = object.Module;
const RelocKind = object.RelocKind;

/// Identifies one atom across the whole link: which module, and its index in
/// that module's `atoms`. Packed into a `u64` for hash-set keys.
pub const AtomId = struct {
    module: u32,
    atom: u32,

    pub fn key(self: AtomId) u64 {
        return (@as(u64, self.module) << 32) | self.atom;
    }
    pub fn fromKey(k: u64) AtomId {
        return .{ .module = @intCast(k >> 32), .atom = @truncate(k) };
    }
};

pub const GlobalTable = std.StringHashMapUnmanaged(AtomId);

pub const Error = error{
    OutOfMemory,
    DuplicateSymbol,
    UndefinedSymbol,
    UnsupportedRelocation,
    RelocationOutOfRange,
};

/// Builds `name -> AtomId` over every global-binding atom in every module. A
/// name defined twice is `error.DuplicateSymbol` (see the module doc comment
/// on the missing weak model).
pub fn resolveGlobals(gpa: Allocator, modules: []const Module) Error!GlobalTable {
    var table: GlobalTable = .{};
    errdefer table.deinit(gpa);
    for (modules, 0..) |mod, mi| {
        for (mod.atoms, 0..) |atom, ai| {
            if (atom.binding != .global) continue;
            const gop = try table.getOrPut(gpa, atom.name);
            if (gop.found_existing) {
                // Strong overrides weak; two weak defs keep the first; two
                // strong defs are a real conflict (e.g. a runtime symbol a Bit
                // program also defined). compiler-rt supplies many weak
                // defaults (memcpy, strlen, ...) that shims/the runtime may
                // strong-override.
                const existing = modules[gop.value_ptr.module].atoms[gop.value_ptr.atom];
                if (existing.weak and !atom.weak) {
                    gop.value_ptr.* = .{ .module = @intCast(mi), .atom = @intCast(ai) };
                } else if (!existing.weak and !atom.weak) {
                    return error.DuplicateSymbol;
                }
                continue;
            }
            gop.value_ptr.* = .{ .module = @intCast(mi), .atom = @intCast(ai) };
        }
    }
    return table;
}

/// Resolves one relocation target to the atom it names: a `.local` target is
/// an index into `module_idx`'s own atoms; a `.global` target goes through the
/// whole-link table (`error.UndefinedSymbol` if nothing defines it).
pub fn resolveRef(globals: *const GlobalTable, module_idx: u32, ref: object.SymbolRef) Error!AtomId {
    return switch (ref) {
        .local => |idx| .{ .module = module_idx, .atom = idx },
        .global => |name| globals.get(name) orelse error.UndefinedSymbol,
    };
}

pub const KeptSet = struct {
    set: std.AutoHashMapUnmanaged(u64, void) = .{},

    pub fn contains(self: *const KeptSet, id: AtomId) bool {
        return self.set.contains(id.key());
    }
    pub fn count(self: *const KeptSet) usize {
        return self.set.count();
    }
    pub fn deinit(self: *KeptSet, gpa: Allocator) void {
        self.set.deinit(gpa);
    }
};

/// Marks every atom reachable from `roots` (global symbol names — the entry
/// `_start`, plus anything the container must keep regardless) by walking each
/// kept atom's relocations transitively. Everything unmarked is dead and the
/// driver drops it. An explicit work stack (not recursion) keeps the traversal
/// bounded and stack-safe over `libbitrt`'s large call graph.
pub fn deadStrip(gpa: Allocator, modules: []const Module, globals: *const GlobalTable, roots: []const []const u8) Error!KeptSet {
    var kept: KeptSet = .{};
    errdefer kept.deinit(gpa);
    var stack: std.ArrayList(AtomId) = .empty;
    defer stack.deinit(gpa);

    for (roots) |name| {
        const id = globals.get(name) orelse return error.UndefinedSymbol;
        if ((try kept.set.getOrPut(gpa, id.key())).found_existing) continue;
        try stack.append(gpa, id);
    }

    while (stack.pop()) |id| {
        const cur = modules[id.module].atoms[id.atom];
        for (cur.relocs) |r| {
            const target = try resolveRef(globals, id.module, r.target);
            if ((try kept.set.getOrPut(gpa, target.key())).found_existing) continue;
            try stack.append(gpa, target);
        }
    }
    return kept;
}

/// The values a single relocation's arithmetic can need — the driver fills in
/// whichever apply to the kind. `s` is the target atom's final address plus
/// the reloc addend already (`S + A`); `p` is the field's own final address;
/// `got_slot` is the address of the target's GOT entry (GOT kinds only);
/// `tp_offset` is the target's offset from the thread pointer (TLS kinds only,
/// negative under the x86-64 variant-II local-exec model).
pub const Values = struct {
    s: u64,
    p: u64,
    got_slot: u64 = 0,
    tp_offset: i64 = 0,
};

/// Applies one relocation into `field` (the reloc's bytes within its atom's
/// data, already sliced to the kind's width). x86-64 kinds only for now; the
/// AArch64 instruction-field kinds land with the ARM64 executable writer.
pub fn apply(kind: RelocKind, field: []u8, v: Values) Error!void {
    switch (kind) {
        .abs64 => std.mem.writeInt(u64, field[0..8], v.s, .little),
        .abs32 => std.mem.writeInt(u32, field[0..4], @truncate(v.s), .little),
        .abs32_signed => {
            const sv: i64 = @bitCast(v.s);
            if (sv < std.math.minInt(i32) or sv > std.math.maxInt(i32)) return error.RelocationOutOfRange;
            std.mem.writeInt(i32, field[0..4], @intCast(sv), .little);
        },
        .pc32 => try writePcRel32(field, v.s, v.p),
        .got32 => try writePcRel32(field, v.got_slot, v.p),
        .tpoff32 => {
            // Variant II local-exec: value = S's thread-pointer offset + A.
            // `tp_offset` already folds the addend (the driver adds it), so
            // this writes it straight as a signed 32-bit displacement.
            if (v.tp_offset < std.math.minInt(i32) or v.tp_offset > std.math.maxInt(i32)) return error.RelocationOutOfRange;
            std.mem.writeInt(i32, field[0..4], @intCast(v.tp_offset), .little);
        },
        else => return error.UnsupportedRelocation,
    }
}

fn writePcRel32(field: []u8, target: u64, p: u64) Error!void {
    const disp: i64 = @as(i64, @bitCast(target)) - @as(i64, @bitCast(p));
    if (disp < std.math.minInt(i32) or disp > std.math.maxInt(i32)) return error.RelocationOutOfRange;
    std.mem.writeInt(i32, field[0..4], @intCast(disp), .little);
}

/// True for a relocation kind that must materialize a GOT slot for its target
/// (the driver pre-scans kept atoms for these to size the GOT).
pub fn needsGot(kind: RelocKind) bool {
    return switch (kind) {
        .got32, .aarch64_adr_got_page, .aarch64_ld64_got_lo12_nc => true,
        else => false,
    };
}

/// True for a TLS-relative kind (its target lives in the TLS segment and
/// resolves to a thread-pointer offset, not a virtual address).
pub fn isTls(kind: RelocKind) bool {
    return switch (kind) {
        .tpoff32, .tlsle_add_tprel_hi12, .tlsle_add_tprel_lo12_nc => true,
        else => false,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn mkAtom(name: []const u8, binding: object.Binding, relocs: []const object.Reloc) object.Atom {
    return .{ .name = name, .kind = .text, .binding = binding, .data = &.{}, .size = 0, .alignment = 1, .relocs = relocs };
}

test "resolveGlobals maps every global, rejects a duplicate" {
    const gpa = testing.allocator;
    const a0 = [_]object.Atom{ mkAtom("_start", .global, &.{}), mkAtom("helper", .local, &.{}) };
    const a1 = [_]object.Atom{mkAtom("bit_main", .global, &.{})};
    const mods = [_]Module{ .{ .name = "rt", .atoms = @constCast(&a0) }, .{ .name = "user", .atoms = @constCast(&a1) } };

    var t = try resolveGlobals(gpa, &mods);
    defer t.deinit(gpa);
    try testing.expectEqual(@as(u32, 0), t.get("_start").?.atom);
    try testing.expectEqual(@as(u32, 1), t.get("bit_main").?.module);
    try testing.expect(t.get("helper") == null); // locals are not global

    const dup = [_]object.Atom{mkAtom("_start", .global, &.{})};
    const mods2 = [_]Module{ .{ .name = "rt", .atoms = @constCast(&a0) }, .{ .name = "d", .atoms = @constCast(&dup) } };
    try testing.expectError(error.DuplicateSymbol, resolveGlobals(gpa, &mods2));
}

test "deadStrip keeps only what the entry root reaches" {
    const gpa = testing.allocator;
    // _start -> bit_main (global); bit_main -> local helper (atom 2 of user);
    // an unreferenced global `dead` is dropped.
    const rt = [_]object.Atom{mkAtom("_start", .global, &.{
        .{ .offset = 0, .kind = .pc32, .target = .{ .global = "bit_main" } },
    })};
    const user = [_]object.Atom{
        mkAtom("bit_main", .global, &.{.{ .offset = 0, .kind = .pc32, .target = .{ .local = 1 } }}),
        mkAtom("helper", .local, &.{}),
        mkAtom("dead", .global, &.{}),
    };
    const mods = [_]Module{ .{ .name = "rt", .atoms = @constCast(&rt) }, .{ .name = "user", .atoms = @constCast(&user) } };

    var globals = try resolveGlobals(gpa, &mods);
    defer globals.deinit(gpa);
    var kept = try deadStrip(gpa, &mods, &globals, &.{"_start"});
    defer kept.deinit(gpa);

    try testing.expect(kept.contains(.{ .module = 0, .atom = 0 })); // _start
    try testing.expect(kept.contains(.{ .module = 1, .atom = 0 })); // bit_main
    try testing.expect(kept.contains(.{ .module = 1, .atom = 1 })); // helper
    try testing.expect(!kept.contains(.{ .module = 1, .atom = 2 })); // dead dropped
    try testing.expectEqual(@as(usize, 3), kept.count());
}

test "apply computes each x86-64 relocation kind" {
    var buf: [8]u8 = undefined;

    try apply(.abs64, &buf, .{ .s = 0x1122334455667788, .p = 0 });
    try testing.expectEqual(@as(u64, 0x1122334455667788), std.mem.readInt(u64, &buf, .little));

    // pc32: disp = S - P = 0x2000 - 0x1005 = 0xFFB.
    try apply(.pc32, buf[0..4], .{ .s = 0x2000, .p = 0x1005 });
    try testing.expectEqual(@as(i32, 0xFFB), std.mem.readInt(i32, buf[0..4], .little));

    // got32: disp to the GOT slot, not the symbol.
    try apply(.got32, buf[0..4], .{ .s = 0, .p = 0x1000, .got_slot = 0x3000 });
    try testing.expectEqual(@as(i32, 0x2000), std.mem.readInt(i32, buf[0..4], .little));

    // tpoff32: the pre-computed negative thread-pointer offset, written raw.
    try apply(.tpoff32, buf[0..4], .{ .s = 0, .p = 0, .tp_offset = -16 });
    try testing.expectEqual(@as(i32, -16), std.mem.readInt(i32, buf[0..4], .little));

    // abs32_signed out of range is rejected, not truncated.
    try testing.expectError(error.RelocationOutOfRange, apply(.abs32_signed, buf[0..4], .{ .s = 0x8000_0000, .p = 0 }));
}
