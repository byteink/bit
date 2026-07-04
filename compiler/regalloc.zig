//! Linear-scan register allocator (task #339) over SSA live intervals —
//! shared by both arch backends (#340 x86-64, #341 ARM64). Classic Poletto &
//! Sarkar (1999) linear scan, chosen over graph coloring for its linear-time
//! bound and simplicity:
//!
//! `// ponytail: linear scan, graph coloring if generated code quality
//! becomes the bottleneck`
//!
//! The allocator itself is fully abstract: it knows nothing about x86-64 or
//! ARM64, SysV or AAPCS64, or `ir.zig`'s instruction encoding. It consumes a
//! target-supplied register file description (`TargetRegs`) and a flat array
//! of live intervals, and produces a register/spill-slot assignment plus,
//! for every safepoint the caller names, the set of live GC references at
//! that exact program point (`runtime/ABI.md` §4's stack maps).
//!
//! ## Program points
//!
//! Callers number positions themselves — any monotonically increasing `u32`
//! per instruction works (codegen will typically reuse `ir.zig`'s own
//! instruction index). An interval `[start, end]` is inclusive on both
//! ends: `start` is the defining position, `end` the last position the
//! value is read at. A safepoint is just a position in that same numbering
//! (call sites, loop back-edges per `runtime/ABI.md` §5); a value is live at
//! a safepoint iff its interval contains it.
//!
//! ## One interval per vreg, dense numbering
//!
//! `Interval.vreg` values must be exactly `0..intervals.len`, each appearing
//! once — one live range per SSA value, mirroring `ir.zig`'s own
//! "instruction index == ValueId" house style. This lets the result array
//! be indexed directly by vreg, no lookup table. Violating this is a caller
//! bug (asserted, not a recoverable error — same contract style as
//! `ir.FunctionBuilder`'s asserts).
//!
//! ## GC stack maps
//!
//! Only `.int`-class values can be references (`runtime/ABI.md` §3: a
//! reference is one pointer-sized value; floats never hold one) —
//! `Interval.is_ref` set on a `.float` interval is a caller bug, asserted
//! against. For each requested safepoint, `allocate` records which physical
//! registers and which spill slots hold a live reference at that position;
//! codegen turns that into the per-callsite table the GC's root scanner
//! walks.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Class = enum { int, float };

/// One physical register file (e.g. the target's GPRs or FPRs), fully
/// abstract — the allocator never hardcodes a real machine register name.
pub const RegFile = struct {
    /// Number of allocatable registers in this class, indices `0..count`.
    /// Backends map indices to real registers and simply exclude any
    /// reserved register (stack/frame pointer, etc.) by leaving it out of
    /// `count` entirely.
    count: u32,
    /// Bit `i` set means register `i` is callee-saved. Informative only —
    /// this allocator runs no call-crossing preference pass; it's exposed
    /// so codegen can decide caller-save spill/reload policy around call
    /// sites independent of which vreg landed where.
    callee_saved: u32 = 0,
};

pub const TargetRegs = struct {
    int: RegFile,
    float: RegFile,

    fn file(self: TargetRegs, class: Class) RegFile {
        return switch (class) {
            .int => self.int,
            .float => self.float,
        };
    }
};

pub const VReg = enum(u32) { _ };

pub const Interval = struct {
    vreg: VReg,
    class: Class,
    start: u32,
    end: u32,
    /// True if this vreg holds a live GC reference — see the module doc
    /// comment on GC stack maps. Only valid on `.class == .int`.
    is_ref: bool = false,
};

pub const Location = union(enum) {
    reg: u32,
    spill: u32,
};

pub const StackMapEntry = struct {
    pos: u32,
    /// Physical (int-class) register indices holding a live reference at `pos`.
    regs: []const u32,
    /// Spill slot indices holding a live reference at `pos`.
    slots: []const u32,
};

pub const Result = struct {
    gpa: Allocator,
    /// Indexed by vreg (`locations[@intFromEnum(vreg)]`) — see the module
    /// doc comment on dense numbering.
    locations: []Location,
    /// Total distinct stack slots the allocator used; codegen sizes the
    /// spill area to `num_spill_slots * slot_width` (slots are a single
    /// flat, class-agnostic space — see `SpillPool`'s doc comment).
    num_spill_slots: u32,
    /// One entry per input safepoint, same order as given to `allocate`.
    stack_maps: []StackMapEntry,

    pub fn deinit(self: *Result) void {
        for (self.stack_maps) |sm| {
            self.gpa.free(sm.regs);
            self.gpa.free(sm.slots);
        }
        self.gpa.free(self.stack_maps);
        self.gpa.free(self.locations);
        self.* = undefined;
    }
};

fn orderByStart(intervals: []const Interval, a: u32, b: u32) bool {
    const ia = intervals[a];
    const ib = intervals[b];
    if (ia.start != ib.start) return ia.start < ib.start;
    return @intFromEnum(ia.vreg) < @intFromEnum(ib.vreg); // deterministic tiebreak
}

const ActiveEntry = struct { idx: u32, reg: u32 };

/// Per-class linear-scan state: which registers are free, and the active
/// set (intervals currently holding a register), kept sorted ascending by
/// end point exactly as Poletto & Sarkar's algorithm requires. `active`'s
/// backing buffer is fixed at `file.count` slots — the active set can never
/// exceed the register count, since reaching `count` forces a spill instead
/// of a new admission (Power of 10: no unbounded growth after startup).
const ClassState = struct {
    reg_file: RegFile,
    active: []ActiveEntry,
    len: u32 = 0,
    used: []bool,

    fn init(gpa: Allocator, reg_file: RegFile) Allocator.Error!ClassState {
        const active = try gpa.alloc(ActiveEntry, reg_file.count);
        errdefer gpa.free(active);
        const used = try gpa.alloc(bool, reg_file.count);
        @memset(used, false);
        return .{ .reg_file = reg_file, .active = active, .used = used };
    }

    fn deinit(self: *ClassState, gpa: Allocator) void {
        gpa.free(self.active);
        gpa.free(self.used);
        self.* = undefined;
    }

    /// ExpireOldIntervals: frees the register of every active interval
    /// whose end precedes `start`. `active[0..len]` is sorted ascending by
    /// end, so expired entries are always a prefix — bounded by `len`.
    fn expire(self: *ClassState, intervals: []const Interval, start: u32) void {
        var keep_from: u32 = 0;
        while (keep_from < self.len and intervals[self.active[keep_from].idx].end < start) : (keep_from += 1) {
            self.used[self.active[keep_from].reg] = false;
        }
        if (keep_from == 0) return;
        const remaining = self.len - keep_from;
        std.mem.copyForwards(ActiveEntry, self.active[0..remaining], self.active[keep_from..self.len]);
        self.len = remaining;
    }

    /// Inserts `entry` keeping `active[0..len]` sorted ascending by end
    /// point (bounded: at most `reg_file.count` shifts).
    fn insertActive(self: *ClassState, intervals: []const Interval, entry: ActiveEntry) void {
        std.debug.assert(self.len < self.active.len);
        const end = intervals[entry.idx].end;
        var pos = self.len;
        while (pos > 0 and intervals[self.active[pos - 1].idx].end > end) : (pos -= 1) {
            self.active[pos] = self.active[pos - 1];
        }
        self.active[pos] = entry;
        self.len += 1;
    }

    /// Only called when `len < reg_file.count`, so a free register always
    /// exists — the scan is bounded by `reg_file.count`.
    fn firstFreeReg(self: *const ClassState) u32 {
        for (self.used, 0..) |taken, r| {
            if (!taken) return @intCast(r);
        }
        unreachable;
    }
};

const SpillEntry = struct { idx: u32, slot: u32 };

/// Spill slots are one flat, class-agnostic stack space (both `.int` and
/// `.float` spills draw from the same numbering) — codegen already sizes
/// every slot uniformly (8 bytes covers `i64`/`u64`/`f64`/pointers per
/// `runtime/ABI.md` §1's alignment rules), so splitting the space per class
/// would only fragment the frame for no benefit. Mirrors `ClassState`'s
/// expire/insert shape, but slots are reused via a free list rather than a
/// fixed-capacity buffer — the frame has no fixed size to allocate against
/// up front.
const SpillPool = struct {
    active: std.ArrayList(SpillEntry) = .empty,
    free: std.ArrayList(u32) = .empty,
    next: u32 = 0,

    fn deinit(self: *SpillPool, gpa: Allocator) void {
        self.active.deinit(gpa);
        self.free.deinit(gpa);
        self.* = undefined;
    }

    fn expire(self: *SpillPool, gpa: Allocator, intervals: []const Interval, start: u32) Allocator.Error!void {
        var keep_from: usize = 0;
        while (keep_from < self.active.items.len and intervals[self.active.items[keep_from].idx].end < start) : (keep_from += 1) {
            try self.free.append(gpa, self.active.items[keep_from].slot);
        }
        if (keep_from == 0) return;
        const remaining = self.active.items.len - keep_from;
        std.mem.copyForwards(SpillEntry, self.active.items[0..remaining], self.active.items[keep_from..]);
        self.active.items.len = remaining;
    }

    fn assign(self: *SpillPool, gpa: Allocator, intervals: []const Interval, idx: u32) Allocator.Error!u32 {
        const slot = self.free.pop() orelse blk: {
            const s = self.next;
            self.next += 1;
            break :blk s;
        };
        const end = intervals[idx].end;
        var pos: usize = 0;
        while (pos < self.active.items.len and intervals[self.active.items[pos].idx].end <= end) : (pos += 1) {}
        try self.active.insert(gpa, pos, .{ .idx = idx, .slot = slot });
        return slot;
    }
};

/// Runs linear-scan register allocation over `intervals` for `target`, then
/// derives a GC stack map for each position in `safepoints`. Caller owns
/// `intervals`/`safepoints` and must free the returned `Result` via
/// `Result.deinit`.
pub fn allocate(gpa: Allocator, target: TargetRegs, intervals: []const Interval, safepoints: []const u32) Allocator.Error!Result {
    const n: u32 = @intCast(intervals.len);

    // Validate the caller's dense-vreg contract (see module doc comment) —
    // an internal-caller invariant, asserted rather than surfaced as an
    // `error`, matching `ir.FunctionBuilder`'s own contract-assertion style.
    {
        const seen = try gpa.alloc(bool, n);
        defer gpa.free(seen);
        @memset(seen, false);
        for (intervals) |iv| {
            const vi = @intFromEnum(iv.vreg);
            std.debug.assert(vi < n);
            std.debug.assert(!seen[vi]);
            seen[vi] = true;
            std.debug.assert(iv.start <= iv.end);
            std.debug.assert(iv.class == .int or !iv.is_ref);
        }
    }

    const order = try gpa.alloc(u32, n);
    defer gpa.free(order);
    for (order, 0..) |*o, i| o.* = @intCast(i);
    std.mem.sort(u32, order, intervals, orderByStart);

    const locations = try gpa.alloc(Location, n);
    errdefer gpa.free(locations);

    var int_state = try ClassState.init(gpa, target.int);
    defer int_state.deinit(gpa);
    var float_state = try ClassState.init(gpa, target.float);
    defer float_state.deinit(gpa);
    var spills: SpillPool = .{};
    defer spills.deinit(gpa);

    for (order) |idx| {
        const iv = intervals[idx];
        const state = if (iv.class == .int) &int_state else &float_state;
        state.expire(intervals, iv.start);
        try spills.expire(gpa, intervals, iv.start);

        if (state.len < state.reg_file.count) {
            const reg = state.firstFreeReg();
            state.used[reg] = true;
            locations[@intFromEnum(iv.vreg)] = .{ .reg = reg };
            state.insertActive(intervals, .{ .idx = idx, .reg = reg });
        } else if (state.len == 0 or intervals[state.active[state.len - 1].idx].end <= iv.end) {
            // Nothing active is worth evicting (either the class has no
            // registers at all, or `iv` itself has the furthest end) —
            // Poletto & Sarkar's `SpillAtInterval` "else" branch.
            const slot = try spills.assign(gpa, intervals, idx);
            locations[@intFromEnum(iv.vreg)] = .{ .spill = slot };
        } else {
            // Evict the active interval with the furthest end and hand its
            // register to `iv` — `SpillAtInterval`'s "if" branch.
            const evicted = state.active[state.len - 1];
            state.len -= 1;
            const slot = try spills.assign(gpa, intervals, evicted.idx);
            locations[@intFromEnum(intervals[evicted.idx].vreg)] = .{ .spill = slot };
            locations[@intFromEnum(iv.vreg)] = .{ .reg = evicted.reg };
            state.insertActive(intervals, .{ .idx = idx, .reg = evicted.reg });
        }
    }

    const stack_maps = try gpa.alloc(StackMapEntry, safepoints.len);
    var built: u32 = 0;
    errdefer {
        for (stack_maps[0..built]) |sm| {
            gpa.free(sm.regs);
            gpa.free(sm.slots);
        }
        gpa.free(stack_maps);
    }
    // Bounded by `safepoints.len * intervals.len` — both function-local,
    // finite sizes (mirrors `ir.computeDominators`'s own documented O(n^2)
    // bound for the same reason: no recursive or unbounded walk).
    for (safepoints, 0..) |pos, i| {
        var regs: std.ArrayList(u32) = .empty;
        errdefer regs.deinit(gpa);
        var slots: std.ArrayList(u32) = .empty;
        errdefer slots.deinit(gpa);
        for (intervals) |iv| {
            if (!iv.is_ref or iv.start > pos or iv.end < pos) continue;
            switch (locations[@intFromEnum(iv.vreg)]) {
                .reg => |r| try regs.append(gpa, r),
                .spill => |s| try slots.append(gpa, s),
            }
        }
        const regs_slice = try regs.toOwnedSlice(gpa);
        errdefer gpa.free(regs_slice);
        const slots_slice = try slots.toOwnedSlice(gpa);
        stack_maps[i] = .{ .pos = pos, .regs = regs_slice, .slots = slots_slice };
        built += 1;
    }

    return .{
        .gpa = gpa,
        .locations = locations,
        .num_spill_slots = spills.next,
        .stack_maps = stack_maps,
    };
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

fn vr(i: u32) VReg {
    return @enumFromInt(i);
}

/// Shared correctness check: no two intervals whose ranges overlap were
/// assigned the same physical register within the same class.
fn assertNoOverlappingRegs(intervals: []const Interval, locations: []const Location) !void {
    for (intervals, 0..) |a, i| {
        const loc_a = locations[@intFromEnum(a.vreg)];
        const reg_a = switch (loc_a) {
            .reg => |r| r,
            .spill => continue,
        };
        for (intervals[i + 1 ..]) |b| {
            if (a.class != b.class) continue;
            const reg_b = switch (locations[@intFromEnum(b.vreg)]) {
                .reg => |r| r,
                .spill => continue,
            };
            if (reg_a != reg_b) continue;
            const overlaps = a.start <= b.end and b.start <= a.end;
            try testing.expect(!overlaps);
        }
    }
}

test "allocate assigns disjoint registers to non-overlapping intervals" {
    const gpa = testing.allocator;
    const target = TargetRegs{ .int = .{ .count = 2 }, .float = .{ .count = 0 } };
    const intervals = [_]Interval{
        .{ .vreg = vr(0), .class = .int, .start = 0, .end = 2 },
        .{ .vreg = vr(1), .class = .int, .start = 3, .end = 5 },
    };
    var result = try allocate(gpa, target, &intervals, &.{});
    defer result.deinit();

    try testing.expectEqual(Location{ .reg = 0 }, result.locations[0]);
    try testing.expectEqual(Location{ .reg = 0 }, result.locations[1]); // reused after expiry
    try testing.expectEqual(@as(u32, 0), result.num_spill_slots);
    try assertNoOverlappingRegs(&intervals, result.locations);
}

test "allocate spills the interval with the furthest end when out of registers" {
    const gpa = testing.allocator;
    const target = TargetRegs{ .int = .{ .count = 1 }, .float = .{ .count = 0 } };
    // v0 and v1 overlap; only one register exists, so one of them must spill.
    // v1 has the furthest end, so it should be the one evicted.
    const intervals = [_]Interval{
        .{ .vreg = vr(0), .class = .int, .start = 0, .end = 4 },
        .{ .vreg = vr(1), .class = .int, .start = 1, .end = 10 },
    };
    var result = try allocate(gpa, target, &intervals, &.{});
    defer result.deinit();

    try testing.expectEqual(Location{ .reg = 0 }, result.locations[0]);
    try testing.expectEqual(Location{ .spill = 0 }, result.locations[1]);
    try testing.expectEqual(@as(u32, 1), result.num_spill_slots);
    try assertNoOverlappingRegs(&intervals, result.locations);
}

test "allocate reuses freed spill slots" {
    const gpa = testing.allocator;
    const target = TargetRegs{ .int = .{ .count = 1 }, .float = .{ .count = 0 } };
    // v0 and v2 each hold the register for a while; v1 and v3 each overlap
    // whichever one is active and outlive it, so both take the "spill
    // itself" branch (Poletto & Sarkar: the active occupant's end is
    // already <= the newcomer's, so evicting it would buy nothing). v1's
    // spill slot is freed once v1's own range ends (6) — well before v3
    // needs a slot (9) — so v3 should reuse it instead of growing the frame.
    const intervals = [_]Interval{
        .{ .vreg = vr(0), .class = .int, .start = 0, .end = 5 },
        .{ .vreg = vr(1), .class = .int, .start = 1, .end = 6 },
        .{ .vreg = vr(2), .class = .int, .start = 7, .end = 12 },
        .{ .vreg = vr(3), .class = .int, .start = 9, .end = 15 },
    };
    var result = try allocate(gpa, target, &intervals, &.{});
    defer result.deinit();

    try testing.expectEqual(Location{ .reg = 0 }, result.locations[0]);
    try testing.expectEqual(Location{ .spill = 0 }, result.locations[1]);
    try testing.expectEqual(Location{ .reg = 0 }, result.locations[2]);
    try testing.expectEqual(Location{ .spill = 0 }, result.locations[3]);
    try testing.expectEqual(@as(u32, 1), result.num_spill_slots);
    try assertNoOverlappingRegs(&intervals, result.locations);
}

test "allocate keeps int and float classes independent" {
    const gpa = testing.allocator;
    const target = TargetRegs{ .int = .{ .count = 1 }, .float = .{ .count = 1 } };
    const intervals = [_]Interval{
        .{ .vreg = vr(0), .class = .int, .start = 0, .end = 10 },
        .{ .vreg = vr(1), .class = .float, .start = 0, .end = 10 },
    };
    var result = try allocate(gpa, target, &intervals, &.{});
    defer result.deinit();

    try testing.expectEqual(Location{ .reg = 0 }, result.locations[0]);
    try testing.expectEqual(Location{ .reg = 0 }, result.locations[1]);
    try testing.expectEqual(@as(u32, 0), result.num_spill_slots);
}

test "allocate emits a precise GC stack map at a safepoint" {
    const gpa = testing.allocator;
    const target = TargetRegs{ .int = .{ .count = 2 }, .float = .{ .count = 0 } };
    // v0 is a live reference spanning the safepoint; v1 is a non-reference
    // int also live there; v2 is a reference whose range ends before it.
    const intervals = [_]Interval{
        .{ .vreg = vr(0), .class = .int, .start = 0, .end = 10, .is_ref = true },
        .{ .vreg = vr(1), .class = .int, .start = 0, .end = 10 },
        .{ .vreg = vr(2), .class = .int, .start = 0, .end = 3, .is_ref = true },
    };
    var result = try allocate(gpa, target, &intervals, &.{5});
    defer result.deinit();

    try testing.expectEqual(@as(usize, 1), result.stack_maps.len);
    const sm = result.stack_maps[0];
    try testing.expectEqual(@as(u32, 5), sm.pos);
    try testing.expectEqual(@as(usize, 0), sm.slots.len);
    try testing.expectEqual(@as(usize, 1), sm.regs.len);
    // v0's register, not v1's (not a ref) or v2's (already dead by pos 5).
    try testing.expectEqual(result.locations[0].reg, sm.regs[0]);
}

test "allocate reports a spilled reference in the stack map by slot" {
    const gpa = testing.allocator;
    const target = TargetRegs{ .int = .{ .count = 1 }, .float = .{ .count = 0 } };
    // v0 grabs the only register first and outlives v1, so v1 (the longer,
    // overlapping newcomer) is the one that spills — see the module doc
    // comment: the allocator evicts/self-spills whichever interval has the
    // furthest end, never the one already holding the register when a
    // shorter one arrives.
    const intervals = [_]Interval{
        .{ .vreg = vr(0), .class = .int, .start = 0, .end = 5 },
        .{ .vreg = vr(1), .class = .int, .start = 1, .end = 20, .is_ref = true },
    };
    var result = try allocate(gpa, target, &intervals, &.{10});
    defer result.deinit();

    try testing.expect(result.locations[1] == .spill);
    const sm = result.stack_maps[0];
    try testing.expectEqual(@as(usize, 0), sm.regs.len);
    try testing.expectEqual(@as(usize, 1), sm.slots.len);
    try testing.expectEqual(result.locations[1].spill, sm.slots[0]);
}

test "allocate under forced register pressure (cap of 4) never overlaps" {
    const gpa = testing.allocator;
    const target = TargetRegs{ .int = .{ .count = 4 }, .float = .{ .count = 0 } };

    // A synthetic stress pattern standing in for a corpus program run
    // through codegen: more concurrently live values than physical
    // registers, some long-lived (loop-carried), some short-lived
    // (temporaries), forcing repeated spill/evict decisions. Full
    // corpus-program integration lands once #340/#341 feed real IR-derived
    // intervals through this allocator.
    var intervals = std.ArrayList(Interval).empty;
    defer intervals.deinit(gpa);
    var v: u32 = 0;
    // Four long-lived "loop-carried" values, live across the whole range —
    // already saturating all 4 registers on their own.
    var carried: u32 = 0;
    while (carried < 4) : (carried += 1) {
        try intervals.append(gpa, .{ .vreg = vr(v), .class = .int, .start = 0, .end = 200, .is_ref = carried == 0 });
        v += 1;
    }
    // Overlapping temporaries layered on top (wide windows, small step) so
    // several are concurrently live alongside all 4 carried values —
    // register demand exceeds supply throughout, forcing spills.
    var t: u32 = 0;
    while (t < 20) : (t += 1) {
        const start = t * 5;
        try intervals.append(gpa, .{ .vreg = vr(v), .class = .int, .start = start, .end = start + 40 });
        v += 1;
    }

    var result = try allocate(gpa, target, intervals.items, &.{ 100, 150 });
    defer result.deinit();

    try assertNoOverlappingRegs(intervals.items, result.locations);
    try testing.expect(result.num_spill_slots > 0); // register pressure forced at least one spill
    for (result.stack_maps) |sm| {
        try testing.expect(sm.regs.len + sm.slots.len <= 1); // only vreg 0 is ever a reference
    }
}
