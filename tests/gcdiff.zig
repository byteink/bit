//! Differential: the Zig collector (`runtime/gc.zig`) against the Bit port
//! (`runtime/gc/gc.bit`, #1363).
//!
//! Both collectors are driven through the byte-for-byte SAME scripted sequence
//! of allocations, edge writes, root drops and collections, and both must
//! produce the same table. The table is `tests/stress/gcbit/gcbit.expected`:
//! `tests/stress.zig` compares the Bit program's stdout against it, and this
//! test compares the Zig collector's table against it. Neither side is derived
//! from the other — the golden file is a shared oracle, and a behavioural
//! divergence between the two implementations fails one side or the other.
//!
//! What the recorded columns pin down, per step:
//!
//!   numObjects   the live object count — WHICH objects survive
//!   liveBytes    bytes handed out and not freed — the growth-trigger input
//!   collections  how many collections have run, i.e. the TRIGGER SCHEDULE;
//!                this only matches if the growth policy matches exactly
//!   totalSwept   cumulative objects reclaimed — the sweep decision, cumulative
//!   survivors    objects surviving the most recent collection
//!   indexEntries live entries in the address->object index
//!
//! No addresses appear anywhere: the two implementations allocate from
//! different allocators (see `runtime/gc/region.bit` for why the Bit port has
//! its own), so addresses legitimately differ while every behavioural quantity
//! above must not.
//!
//! The mark worklist is deliberately 4 entries against a live set reaching ~30
//! objects and a type that fans out 8 ways, so the worklist overflows and the
//! bounded-rescan recovery runs on nearly every collection in both.

const std = @import("std");
const gc = @import("gc");
const build_options = @import("build_options");

const Gc = gc.Gc;
/// `runtime/gc.zig` imports `alloc.zig` relatively, so both files belong to the
/// one module and `alloc.zig` cannot also be rooted as a second one. The heap
/// type is therefore taken from the collector's own public field rather than
/// re-imported — which also means this test can never disagree with the
/// collector about which heap it uses.
const Heap = @typeInfo(@FieldType(Gc, "heap")).pointer.child;
const TypeInfo = gc.TypeInfo;
const RootScanner = gc.RootScanner;
const testing = std.testing;

// ---- the script (must match tests/stress/gcbit/gcbit.bit exactly) ----------

const roots_len = 16;
const steps = 600;
const record_every = 8;
const mark_stack = 4;
const min_trigger = 4096;
const growth_pct = 200;
const seed = 88172645463325252;

/// Two-pointer node body: references at 0 and 8.
const node_offsets = [_]usize{ 0, 8 };
/// Eight-pointer body: fans out wide enough to overflow the 4-entry worklist.
const wide_offsets = [_]usize{ 0, 8, 16, 24, 32, 40, 48, 56 };

/// splitmix64, masked to 62 bits so the value is a non-negative `int` on the
/// Bit side too. The Bit port computes this in `u64` with the same constants.
const Rand = struct {
    state: u64,

    fn next(self: *Rand) i64 {
        self.state +%= 0x9E3779B97F4A7C15;
        var z = self.state;
        z = (z ^ (z >> 30)) *% 0xBF58476D1CE4E5B9;
        z = (z ^ (z >> 27)) *% 0x94D049BB133111EB;
        z = z ^ (z >> 31);
        return @intCast(z & 0x3FFF_FFFF_FFFF_FFFF);
    }
};

/// Root scanner over the fixed root array — the same shape the Bit side drives
/// through `gcCollectRoots`.
const Roots = struct {
    slots: *[roots_len]?[*]u8,

    fn scan(ctx: *anyopaque, g: *Gc) void {
        const self: *Roots = @ptrCast(@alignCast(ctx));
        for (self.slots.*) |p| if (p) |q| g.markRoot(q);
    }

    fn scanner(self: *Roots) RootScanner {
        return .{ .ctx = @ptrCast(self), .scan = Roots.scan };
    }
};

/// Emits only words that are inside the collector's address window but are NOT
/// object bases — the interior of each live object, and each live object's
/// header address. `markRoot`'s validation must reject every one, so a
/// collection seeded with nothing else reclaims the entire heap.
const Probe = struct {
    slots: *[roots_len]?[*]u8,

    fn scan(ctx: *anyopaque, g: *Gc) void {
        const self: *Probe = @ptrCast(@alignCast(ctx));
        for (self.slots.*) |p| {
            if (p) |q| {
                g.markConservative(@intFromPtr(q) + 8); // interior pointer
                g.markConservative(@intFromPtr(q) - 32); // the header, not the body
            }
        }
    }

    fn scanner(self: *Probe) RootScanner {
        return .{ .ctx = @ptrCast(self), .scan = Probe.scan };
    }
};

fn setPtr(body: [*]u8, off: usize, target: ?[*]u8) void {
    const slot: *?[*]u8 = @ptrCast(@alignCast(body + off));
    slot.* = target;
}

/// Run the script and render the table the Bit program prints.
fn runScript(out: *std.ArrayList(u8), gpa: std.mem.Allocator) !void {
    const node_info = TypeInfo.of(16, &node_offsets, "Node");
    const wide_info = TypeInfo.of(64, &wide_offsets, "Wide");

    var heap = Heap.init();
    var g = try Gc.init(&heap, .{
        .enabled = true,
        .stress = false,
        .min_trigger = min_trigger,
        .growth_pct = growth_pct,
        .mark_stack_len = mark_stack,
    });
    defer g.deinit();

    var slots = [_]?[*]u8{null} ** roots_len;
    var roots = Roots{ .slots = &slots };
    const scanner = roots.scanner();

    var rng = Rand{ .state = seed };
    var index_agree: u8 = 1;
    var owns_agree: u8 = 1;

    var step: usize = 0;
    while (step < steps) { // statically bounded
        g.safepoint(scanner);

        // Exactly four draws per step regardless of the operation taken: a
        // variable draw count would let the two streams diverge silently.
        const a = rng.next();
        const b = rng.next();
        const c = rng.next();
        const d = rng.next();
        const op = @mod(a, 16);
        const slot: usize = @intCast(@mod(b, roots_len));
        const slot2: usize = @intCast(@mod(c, roots_len));
        const field: usize = @intCast(@mod(d, 2) * 8);

        if (op < 8) {
            slots[slot] = g.alloc(&node_info) orelse return error.OutOfMemory;
        } else if (op < 10) {
            slots[slot] = g.alloc(&wide_info) orelse return error.OutOfMemory;
        } else if (op < 12) {
            // Offsets 0 and 8 are reference fields of both shapes.
            if (slots[slot]) |s| {
                if (slots[slot2]) |t| setPtr(s, field, t);
            }
        } else if (op == 12) {
            slots[slot] = null;
        } else if (op == 13) {
            g.collect(scanner);
        }

        step += 1;

        if (step % record_every == 0) {
            const entries = g.addr_index.count();
            if (entries != g.num_objects) index_agree = 0;
            try out.print(gpa, "{d} {d} {d} {d} {d} {d} {d}\n", .{
                step,
                g.num_objects,
                heap.liveBytes(),
                g.stats.collections,
                g.stats.total_swept,
                g.stats.survivors_last,
                entries,
            });
        }
    }

    // The index and the authoritative linear scan must agree for every root,
    // for an interior pointer, and for a foreign address (ABI.md §3).
    for (slots) |maybe| {
        if (maybe) |r| {
            if (g.owns(r) != g.ownsLinear(r)) owns_agree = 0;
            if (!g.owns(r)) owns_agree = 0;
            if (g.owns(r + 8) != g.ownsLinear(r + 8)) owns_agree = 0;
        }
    }
    const foreign: [*]u8 = @ptrFromInt(4096);
    if (g.owns(foreign) or g.ownsLinear(foreign)) owns_agree = 0;

    // CONSERVATIVE ROOT PROBING (ABI.md §5). This collection seeds no real
    // roots — only words inside the collector's address window that are not
    // object bases: the interior of every live object, and every live object's
    // header address. All must be rejected by `markRoot`'s validation, so the
    // outcome is a collection with an effectively empty root set and the whole
    // heap goes. This is what makes that validation load-bearing in the
    // differential rather than merely present.
    var probe = Probe{ .slots = &slots };
    g.collect(probe.scanner());

    // `badOffsets` is always 0 here: the Zig asserts the pointer-map invariant
    // in debug builds rather than counting it (the Bit port counts it, because
    // `@nosplit` cannot call `panic` — see runtime/gc/gc.bit deviation 5). Both
    // report 0 on this script, which is the point.
    try out.print(gpa, "done {d} {d} {d} {d} {d} {d} {d} {d}\n", .{
        g.num_objects,
        g.stats.total_allocated,
        g.stats.total_swept,
        0,
        index_agree,
        owns_agree,
        @intFromBool(g.index_ok),
        g.addr_index.count(),
    });
}

test "Zig and Bit collectors produce the same table for the same script" {
    const gpa = testing.allocator;

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try runScript(&out, gpa);

    const path = try std.fs.path.join(gpa, &.{ build_options.stress_dir, "gcbit", "gcbit.expected" });
    defer gpa.free(path);

    const io = std.Io.Threaded.global_single_threaded.io();
    const want = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 20));
    defer gpa.free(want);

    if (!std.mem.eql(u8, want, out.items)) {
        std.debug.print(
            "gc differential MISMATCH\n--- expected (Bit collector, {s}) ---\n{s}\n--- got (Zig collector) ---\n{s}\n",
            .{ path, want, out.items },
        );
        return error.GcDifferentialMismatch;
    }
}
