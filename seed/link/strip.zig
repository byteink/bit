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

// ---------------------------------------------------------------------------
// GC stack-map merge (ABI.md §4)
// ---------------------------------------------------------------------------

/// The linker-defined bounds of the merged GC stack-map table. No object
/// defines either: the table spans every archive member that carries entries,
/// so a per-object definition would be a duplicate symbol, and a per-object
/// terminator would stop the runtime's walk at the first member's last entry.
/// The runtime `extern`s both and walks the half-open extent between them.
pub const stackmaps_start_symbol = "bit_stack_maps";
pub const stackmaps_end_symbol = "bit_stack_maps_end";

/// Builds the synthetic module holding the two boundary atoms. Both are
/// zero-size and 1-aligned so they contribute no bytes and force no padding —
/// they exist only to be given addresses at the ends of the merged group.
///
/// `sym_prefix` is the container's C symbol mangling ("" on ELF, "_" on
/// Mach-O). It is a parameter rather than a constant because these names must
/// match the runtime's `extern` spelling exactly, and an unprefixed name on
/// Mach-O does not fail at link — it falls through to a libSystem import and
/// aborts at dyld load, far from its cause.
///
/// Always present, even when nothing carries stack maps: the runtime's `extern`
/// references must resolve, and an empty extent (start == end) is the correct
/// answer for a program with no Bit frames to walk.
pub fn markerModule(gpa: Allocator, sym_prefix: []const u8) Allocator.Error!Module {
    const atoms = try gpa.alloc(object.Atom, 2);
    const start = try std.fmt.allocPrint(gpa, "{s}{s}", .{ sym_prefix, stackmaps_start_symbol });
    const end = try std.fmt.allocPrint(gpa, "{s}{s}", .{ sym_prefix, stackmaps_end_symbol });
    atoms[0] = .{ .name = start, .kind = .gc_meta, .binding = .global, .data = &.{}, .size = 0, .alignment = 1, .relocs = &.{} };
    atoms[1] = .{ .name = end, .kind = .gc_meta, .binding = .global, .data = &.{}, .size = 0, .alignment = 1, .relocs = &.{} };
    return .{ .name = "<gc stack maps>", .atoms = atoms };
}

/// Index of the boundary atoms within `markerModule`'s atom slice.
pub const marker_start_atom: u32 = 0;
pub const marker_end_atom: u32 = 1;

/// The reverse-dependency rule for stack-map entries: an entry is retained
/// exactly when the function it describes is retained.
///
/// It cannot be a dead-strip ROOT — an entry relocates to its function, so
/// rooting the entries would retain every function of every runtime module in
/// every image, defeating dead-strip entirely. Nor can it be left to ordinary
/// reachability: nothing ever references an entry, so every entry would be
/// dropped and the collector would see no frames at all. Hence a pass AFTER
/// `deadStrip`, keyed on the target the entry already names.
///
/// One pass suffices with no fixpoint: an entry's only relocation targets its
/// own function, which this rule has just established is already kept, so
/// keeping an entry can never make a further atom reachable.
pub fn keepLiveStackMaps(gpa: Allocator, modules: []const Module, globals: *const GlobalTable, kept: *KeptSet) Error!void {
    for (modules, 0..) |mod, mi| {
        for (mod.atoms, 0..) |atom, ai| {
            if (atom.kind != .gc_meta) continue;
            if (atom.binding == .global) continue; // the boundary markers, kept unconditionally
            for (atom.relocs) |r| {
                const target = try resolveRef(globals, @intCast(mi), r.target);
                if (!kept.contains(target)) continue;
                try kept.set.put(gpa, (AtomId{ .module = @intCast(mi), .atom = @intCast(ai) }).key(), {});
                break;
            }
        }
    }
}

/// Orders the merged group: the start marker, then every retained entry, then
/// the end marker. The driver appends this run to one output group **without
/// interruption**, which is what makes the runtime's linear walk valid — the
/// entries carry no count and no terminator, only these two bounds.
pub fn mergedStackMapAtoms(gpa: Allocator, modules: []const Module, kept: *const KeptSet, marker_module: u32) Allocator.Error![]AtomId {
    var out: std.ArrayList(AtomId) = .empty;
    try out.append(gpa, .{ .module = marker_module, .atom = marker_start_atom });
    for (modules, 0..) |mod, mi| {
        if (mi == marker_module) continue;
        for (mod.atoms, 0..) |atom, ai| {
            if (atom.kind != .gc_meta) continue;
            const id = AtomId{ .module = @intCast(mi), .atom = @intCast(ai) };
            if (!kept.contains(id)) continue;
            try out.append(gpa, id);
        }
    }
    try out.append(gpa, .{ .module = marker_module, .atom = marker_end_atom });
    return out.toOwnedSlice(gpa);
}

/// The values a single relocation's arithmetic can need — the driver fills in
/// whichever apply to the kind. `s` is the target atom's final address plus
/// the reloc addend already (`S + A`); `p` is the field's own final address;
/// `got_slot` is the address of the target's GOT entry (GOT kinds only);
/// `tp_offset` is the target's offset from the thread pointer (TLS kinds only,
/// negative under the x86-64 variant-II local-exec model).
pub const Values = struct {
    s: u64 = 0,
    p: u64 = 0,
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

        // ---- AArch64 instruction-field kinds (Mach-O arm64 executable) -----
        // Each patches a 4-byte little-endian instruction word in place. `s`
        // already folds the addend; GOT/TLVP kinds address their indirection
        // slot via `got_slot`.
        .aarch64_call26, .aarch64_jump26 => try writeBranch26(field, v.s, v.p),
        .aarch64_adr_prel_pg_hi21 => try writeAdrp(field, v.s, v.p),
        .aarch64_adr_got_page, .aarch64_tlvp_adr_page21 => try writeAdrp(field, v.got_slot, v.p),
        .aarch64_add_abs_lo12_nc => writeLo12(field, v.s, 0),
        .aarch64_ldst8_abs_lo12_nc => writeLo12(field, v.s, 0),
        .aarch64_ldst16_abs_lo12_nc => writeLo12(field, v.s, 1),
        .aarch64_ldst32_abs_lo12_nc => writeLo12(field, v.s, 2),
        .aarch64_ldst64_abs_lo12_nc => writeLo12(field, v.s, 3),
        .aarch64_ldst128_abs_lo12_nc => writeLo12(field, v.s, 4),
        .aarch64_ld64_got_lo12_nc, .aarch64_tlvp_ld64_lo12 => writeLo12(field, v.got_slot, 3),

        .tlsle_add_tprel_hi12, .tlsle_add_tprel_lo12_nc => {
            // AArch64 local-exec TLS (Variant I): X = TPREL(S) + A, already
            // folded into `tp_offset` by the driver. The pair sets an `ADD`
            // immediate to bits [23:12] (HI12) and [11:0] (LO12) of X, together
            // covering a 24-bit thread-pointer offset.
            const x: u64 = @bitCast(v.tp_offset);
            if (x >= (1 << 24)) return error.RelocationOutOfRange;
            const bits12: u64 = if (kind == .tlsle_add_tprel_hi12) x >> 12 else x;
            writeLo12(field, bits12, 0);
        },
    }
}

fn readInsn(field: []const u8) u32 {
    return std.mem.readInt(u32, field[0..4], .little);
}
fn writeInsn(field: []u8, insn: u32) void {
    std.mem.writeInt(u32, field[0..4], insn, .little);
}

/// `BL`/`B` imm26 = (target - P) >> 2, signed 26-bit, at instruction bits [25:0].
fn writeBranch26(field: []u8, target: u64, p: u64) Error!void {
    const disp: i64 = @as(i64, @bitCast(target)) - @as(i64, @bitCast(p));
    if (disp & 3 != 0) return error.UnsupportedRelocation; // branch targets are 4-aligned
    const imm: i64 = disp >> 2;
    if (imm < -(1 << 25) or imm >= (1 << 25)) return error.RelocationOutOfRange;
    const bits: u64 = @bitCast(imm);
    const insn = (readInsn(field) & 0xFC000000) | @as(u32, @intCast(bits & 0x03FFFFFF));
    writeInsn(field, insn);
}

/// `ADRP` imm21 = (page(target) - page(P)) >> 12, split into immlo (bits
/// [30:29]) and immhi (bits [23:5]). `page(x) = x & ~0xfff`.
fn writeAdrp(field: []u8, target: u64, p: u64) Error!void {
    const page_mask = ~@as(u64, 0xFFF);
    const delta: i64 = @as(i64, @bitCast(target & page_mask)) - @as(i64, @bitCast(p & page_mask));
    const imm: i64 = delta >> 12;
    if (imm < -(1 << 20) or imm >= (1 << 20)) return error.RelocationOutOfRange;
    const uimm: u32 = @intCast(@as(u64, @bitCast(imm)) & 0x1FFFFF);
    const immlo = uimm & 0x3;
    const immhi = (uimm >> 2) & 0x7FFFF;
    var insn = readInsn(field);
    insn &= ~((@as(u32, 0x3) << 29) | (@as(u32, 0x7FFFF) << 5));
    insn |= (immlo << 29) | (immhi << 5);
    writeInsn(field, insn);
}

/// `ADD`/`LDR`/`STR` imm12 = (value & 0xfff) >> scale, at bits [21:10]. `scale`
/// is the access-size log2 (0 for `ADD` and byte access, 3 for a 64-bit load).
fn writeLo12(field: []u8, value: u64, scale: u5) void {
    const imm12: u32 = @intCast((value & 0xFFF) >> scale);
    var insn = readInsn(field);
    insn &= ~(@as(u32, 0xFFF) << 10);
    insn |= imm12 << 10;
    writeInsn(field, insn);
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

/// True for a macOS thread-local kind that must materialize a `__thread_ptr`
/// slot for its target `tlv_descriptor` (the driver sizes that table the same
/// way it sizes the GOT).
pub fn needsTlvp(kind: RelocKind) bool {
    return switch (kind) {
        .aarch64_tlvp_adr_page21, .aarch64_tlvp_ld64_lo12 => true,
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

test "apply encodes AArch64 instruction-field relocations" {
    var insn: [4]u8 = undefined;

    // BL forward: target = P + 0x1000 -> imm26 = 0x400.
    std.mem.writeInt(u32, &insn, 0x94000000, .little); // bl #0
    try apply(.aarch64_call26, &insn, .{ .s = 0x1000, .p = 0 });
    try testing.expectEqual(@as(u32, 0x94000400), std.mem.readInt(u32, &insn, .little));

    // BL backward: target = P - 8 -> the canonical `bl .-8` == 0x97FFFFFE.
    std.mem.writeInt(u32, &insn, 0x94000000, .little);
    try apply(.aarch64_call26, &insn, .{ .s = 0, .p = 8 });
    try testing.expectEqual(@as(u32, 0x97FFFFFE), std.mem.readInt(u32, &insn, .little));

    // ADRP x0: page(target) - page(P) = 0x4000 -> imm=4 (immlo=0, immhi=1).
    std.mem.writeInt(u32, &insn, 0x90000000, .little);
    try apply(.aarch64_adr_prel_pg_hi21, &insn, .{ .s = 0x100004ABC, .p = 0x100000000 });
    try testing.expectEqual(@as(u32, 0x90000020), std.mem.readInt(u32, &insn, .little));

    // ADD x0,x0,#imm: lo12 of 0x...4ABC = 0xABC, unscaled.
    std.mem.writeInt(u32, &insn, 0x91000000, .little);
    try apply(.aarch64_add_abs_lo12_nc, &insn, .{ .s = 0x100004ABC, .p = 0 });
    try testing.expectEqual(@as(u32, 0x912AF000), std.mem.readInt(u32, &insn, .little));

    // LDR x0,[x0,#imm]: lo12 of 0x...4AC0 scaled by 8 = 0x158.
    std.mem.writeInt(u32, &insn, 0xF9400000, .little);
    try apply(.aarch64_ldst64_abs_lo12_nc, &insn, .{ .s = 0x100004AC0, .p = 0 });
    try testing.expectEqual(@as(u32, 0xF9456000), std.mem.readInt(u32, &insn, .little));

    // GOT/TLVP page kinds address `got_slot`, not `s`: page delta 0x8000 -> imm=8.
    std.mem.writeInt(u32, &insn, 0x90000000, .little);
    try apply(.aarch64_adr_got_page, &insn, .{ .s = 0, .p = 0x100000000, .got_slot = 0x100008000 });
    try testing.expectEqual(@as(u32, 0x90000040), std.mem.readInt(u32, &insn, .little));

    // TLS local-exec ADD pair for X = tp_offset = 0x12345 (a 24-bit value):
    // HI12 = bits [23:12] = 0x12 -> imm12; LO12 = bits [11:0] = 0x345 -> imm12.
    std.mem.writeInt(u32, &insn, 0x91000000, .little);
    try apply(.tlsle_add_tprel_hi12, &insn, .{ .s = 0, .p = 0, .tp_offset = 0x12345 });
    try testing.expectEqual(@as(u32, 0x91004800), std.mem.readInt(u32, &insn, .little));
    std.mem.writeInt(u32, &insn, 0x91000000, .little);
    try apply(.tlsle_add_tprel_lo12_nc, &insn, .{ .s = 0, .p = 0, .tp_offset = 0x12345 });
    try testing.expectEqual(@as(u32, 0x910D1400), std.mem.readInt(u32, &insn, .little));

    // A branch past ±128 MB is rejected, not truncated.
    try testing.expectError(error.RelocationOutOfRange, apply(.aarch64_call26, &insn, .{ .s = 0x10000000, .p = 0 }));
}
