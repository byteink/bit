//! Precise stop-the-world mark-and-sweep garbage collector.
//!
//! V1 goal is correctness, not throughput: a single-threaded, non-moving
//! collector layered on the size-class heap in `alloc.zig`. Every object carries
//! a fixed header (type-info pointer + mark bit) and is threaded onto an
//! all-objects list so sweep can walk the whole heap in one pass.
//!
//! Precision comes from two compiler-emitted tables, defined in `runtime/ABI.md`:
//!   * per-type pointer maps (`TypeInfo.ptrOffsets()`) — which fields of an object
//!     are GC references, so tracing follows only real pointers;
//!   * per-callsite stack maps — which stack/register slots hold live references
//!     at a safepoint, surfaced to the collector through `RootScanner`.
//!
//! ponytail: STW mark-sweep. Upgrade path is incremental/generational when pause
//! times matter. The header, the pointer-map contract, and the root-scan
//! interface are the stable parts; the algorithm behind them can change freely.
//!
//! ponytail: single mutator thread. Real STW (park every green thread at a
//! safepoint before marking) lands with the scheduler; today "stop the world" is
//! just "run synchronously on the one thread". `safepoint()` is the poll point
//! that grows into that barrier.

const std = @import("std");
const builtin = @import("builtin");
const heap_mod = @import("alloc.zig");
const Heap = heap_mod.Heap;

/// Per-type layout descriptor emitted by the compiler, one static instance per
/// distinct (monomorphized) type. See `runtime/ABI.md` §2 for the binary
/// contract.
///
/// `extern` and split into raw `ptr`/`len` pairs (not Zig `[]const T` slices):
/// this struct is written directly into an object file's `.rodata` by
/// codegen — a different compiler than the one building this runtime — so
/// its layout must be a frozen, language-neutral contract, not whatever
/// in-memory shape Zig slices happen to have today.
///
/// `ptr_offsets` (via `ptrOffsets()`) lists the byte offset, within the object
/// body, of every field that holds a GC reference. Offsets must be
/// pointer-aligned and lie fully inside the body. Fields that are not GC
/// references are absent; the collector never inspects them.
pub const TypeInfo = extern struct {
    /// Object body size in bytes, excluding the GC header.
    size: usize,
    ptr_offsets_ptr: [*]const usize,
    ptr_offsets_len: usize,
    /// Static type name, for stats/debugging only. May be empty (`name_len == 0`).
    name_ptr: [*]const u8,
    name_len: usize,

    /// Zig-side convenience constructor from ordinary slices. Codegen instead
    /// writes the four raw fields directly into static data.
    pub fn of(size: usize, ptr_offsets: []const usize, name: []const u8) TypeInfo {
        return .{
            .size = size,
            .ptr_offsets_ptr = ptr_offsets.ptr,
            .ptr_offsets_len = ptr_offsets.len,
            .name_ptr = name.ptr,
            .name_len = name.len,
        };
    }

    pub fn ptrOffsets(self: *const TypeInfo) []const usize {
        return self.ptr_offsets_ptr[0..self.ptr_offsets_len];
    }

    pub fn typeName(self: *const TypeInfo) []const u8 {
        return self.name_ptr[0..self.name_len];
    }
};

/// Root-scanning interface — the runtime side of the stack-map contract.
///
/// At a safepoint the collector calls `scan(ctx, gc)`; the implementation must
/// invoke `gc.markRoot(ref)` for every live GC reference currently held in
/// registers or on the stack, as described by the active call-site stack maps.
/// It must be precise: pass real object base pointers only, never interior or
/// stale values. The eventual stack-map walker implements this; tests supply a
/// scanner backed by an explicit root array.
pub const RootScanner = struct {
    ctx: *anyopaque,
    scan: *const fn (ctx: *anyopaque, gc: *Gc) void,
};

/// Tunable collector policy. Defaults are used unless overridden, e.g. via
/// `configFromEnv`.
pub const Config = struct {
    /// When false, `safepoint` never auto-collects; explicit `collect` still runs.
    enabled: bool = true,
    /// Torture mode: every safepoint collects, ignoring the byte trigger. Turns
    /// the stress suite into a precise-rooting oracle — any root the compiler
    /// fails to report is swept on the very next poll and surfaces immediately.
    stress: bool = false,
    /// Live-heap bytes that must accumulate before a collection is triggered.
    min_trigger: usize = 4 * 1024 * 1024,
    /// After each collection the next trigger is `max(min_trigger, live * pct/100)`.
    /// Must be >= 100 so the heap is allowed to grow between collections.
    growth_pct: usize = 200,
    /// Mark worklist capacity, in entries. Fixed at init — the collector never
    /// grows it; overflow is handled by bounded rescan passes instead, keeping
    /// mark-phase memory constant regardless of heap shape.
    mark_stack_len: usize = 8192,
    /// Print one line per collection to stderr.
    verbose: bool = false,
};

/// Cumulative collector counters, for observability and tests.
pub const Stats = struct {
    collections: usize = 0,
    total_allocated: usize = 0,
    total_swept: usize = 0,
    /// Objects that survived the most recent collection.
    survivors_last: usize = 0,
};

/// Object header prepended to every managed allocation. Implementation detail;
/// its layout is documented in `runtime/ABI.md` for codegen but not exposed as a
/// public type.
const GcHeader = struct {
    /// Type descriptor — drives tracing and records the body size.
    info: *const TypeInfo,
    /// Intrusive all-objects list, so sweep can enumerate the whole heap.
    next: ?*GcHeader,
    /// Total bytes handed to `Heap.alloc` (header + body); needed to free.
    size: usize,
    /// Reachability flag: set in mark, cleared in sweep.
    marked: bool,
};

const gc_align = @alignOf(GcHeader);
const header_size = @sizeOf(GcHeader);

comptime {
    // Body must be pointer-aligned: base is `gc_align`-aligned and the body sits
    // exactly `header_size` past it, so `header_size` must be a multiple of the
    // alignment. `@sizeOf` already rounds up to `@alignOf`, so this holds — assert
    // it anyway to catch any future field-layout change.
    std.debug.assert(header_size % gc_align == 0);
    // The mark bit and null-pointer encoding both assume 8-byte references.
    std.debug.assert(@sizeOf(?[*]u8) == @sizeOf(usize));
}

pub const Gc = struct {
    heap: *Heap,
    /// Head of the intrusive all-objects list.
    all: ?*GcHeader = null,
    /// Number of live (allocated, not yet swept) objects.
    num_objects: usize = 0,

    /// Fixed-capacity mark worklist and its top-of-stack index.
    stack: []*GcHeader,
    stack_top: usize = 0,
    /// Set when a mark could not be queued (worklist full); drives rescan.
    overflow: bool = false,

    cfg: Config,
    /// Live-byte threshold that triggers the next auto-collection.
    next_gc_bytes: usize,
    stats: Stats = .{},

    /// Inclusive-lower / exclusive-upper bounds of every object body pointer
    /// ever handed out, so a conservative stack scan (`markConservative`) can
    /// reject the vast majority of non-pointer words in O(1) before the O(n)
    /// `owns` membership check. Monotonic — never shrinks on sweep, which only
    /// widens the reject window slightly and costs nothing in correctness.
    lo_addr: usize = std.math.maxInt(usize),
    hi_addr: usize = 0,

    /// Create a collector over `heap`. Allocates the fixed mark worklist up front
    /// (startup allocation — never grows afterwards).
    pub fn init(heap: *Heap, cfg: Config) error{OutOfMemory}!Gc {
        const cap = if (cfg.mark_stack_len == 0) 1 else cfg.mark_stack_len;
        const bytes = cap * @sizeOf(*GcHeader);
        const raw = heap.alloc(bytes, @alignOf(*GcHeader)) orelse return error.OutOfMemory;
        const items: [*]*GcHeader = @ptrCast(@alignCast(raw));
        return .{
            .heap = heap,
            .stack = items[0..cap],
            .cfg = cfg,
            .next_gc_bytes = cfg.min_trigger,
        };
    }

    /// Free every remaining object and the mark worklist. The collector is
    /// unusable afterwards.
    pub fn deinit(self: *Gc) void {
        var o = self.all;
        while (o) |h| { // bounded: at most `num_objects` links
            const next = h.next;
            self.freeObject(h);
            o = next;
        }
        self.all = null;
        self.num_objects = 0;
        const bytes = self.stack.len * @sizeOf(*GcHeader);
        self.heap.free(@ptrCast(self.stack.ptr), bytes, @alignOf(*GcHeader));
    }

    /// Allocate a managed object of type `info`. Returns a pointer to the zeroed
    /// object body, or null if the heap is exhausted. Never auto-collects:
    /// collection happens only at safepoints where the roots are known.
    ///
    /// The body is zeroed so pointer fields read as null until assigned — a
    /// collection between allocation and initialization must never trace garbage.
    pub fn alloc(self: *Gc, info: *const TypeInfo) ?[*]u8 {
        const total = header_size + info.size;
        const raw = self.heap.alloc(total, gc_align) orelse return null;
        const h: *GcHeader = @ptrCast(@alignCast(raw));
        h.* = .{ .info = info, .next = self.all, .size = total, .marked = false };
        self.all = h;
        self.num_objects += 1;
        self.stats.total_allocated += 1;
        const body = raw + header_size;
        self.noteBody(@intFromPtr(body));
        @memset(body[0..info.size], 0);
        return body;
    }

    /// Like `alloc`, but for objects whose body size is not fixed by their
    /// `TypeInfo` (strings, byte buffers). `body_size` is the real body length;
    /// `info` must have empty `ptr_offsets` (a leaf object — `scanObject` never
    /// reads `info.size` then, so the descriptor can be shared across lengths).
    pub fn allocRaw(self: *Gc, body_size: usize, info: *const TypeInfo) ?[*]u8 {
        std.debug.assert(info.ptr_offsets_len == 0);
        const total = header_size + body_size;
        const raw = self.heap.alloc(total, gc_align) orelse return null;
        const h: *GcHeader = @ptrCast(@alignCast(raw));
        h.* = .{ .info = info, .next = self.all, .size = total, .marked = false };
        self.all = h;
        self.num_objects += 1;
        self.stats.total_allocated += 1;
        const body = raw + header_size;
        self.noteBody(@intFromPtr(body));
        @memset(body[0..body_size], 0);
        return body;
    }

    fn noteBody(self: *Gc, addr: usize) void {
        if (addr < self.lo_addr) self.lo_addr = addr;
        if (addr + 1 > self.hi_addr) self.hi_addr = addr + 1;
    }

    /// Mark one raw machine word from a conservative root source (a parked
    /// task's stack scan, `runtime/ABI.md` §5). A `usize`-taking front door for
    /// `markRoot`, which does the actual validation — sound because the
    /// collector is non-moving, so a false positive only retains garbage.
    pub fn markConservative(self: *Gc, word: usize) void {
        if (word != 0) self.markRoot(@ptrFromInt(word));
    }

    /// Poll point for automatic collection. A mutator calls this where the stack
    /// maps make the roots precise; if the live heap has crossed the trigger the
    /// world stops and a collection runs.
    pub fn safepoint(self: *Gc, scanner: RootScanner) void {
        if (!self.cfg.enabled) return;
        if (!self.cfg.stress and self.heap.liveBytes() < self.next_gc_bytes) return;
        self.collect(scanner);
    }

    /// Run a full stop-the-world mark-sweep against `scanner`'s roots.
    pub fn collect(self: *Gc, scanner: RootScanner) void {
        self.stack_top = 0;
        self.overflow = false;

        // Mark: seed from roots, then trace transitively.
        scanner.scan(scanner.ctx, self);
        self.drain();
        self.recoverOverflow();
        std.debug.assert(!self.overflow);

        const swept = self.sweep();

        // Reschedule the next collection relative to the surviving live set.
        const live = self.heap.liveBytes();
        const grown = (std.math.mul(usize, live, self.cfg.growth_pct) catch std.math.maxInt(usize)) / 100;
        self.next_gc_bytes = @max(self.cfg.min_trigger, grown);

        self.stats.collections += 1;
        self.stats.total_swept += swept;
        self.stats.survivors_last = self.num_objects;
        if (self.cfg.verbose) {
            std.debug.print(
                "[bit-gc] collection {d}: swept={d} survivors={d} live={d}B next={d}B\n",
                .{ self.stats.collections, swept, self.num_objects, live, self.next_gc_bytes },
            );
        }
    }

    /// Mark a single reference, marking it *only if* it is exactly the body
    /// base of a live managed object. Null, interior pointers, and foreign
    /// pointers are ignored.
    ///
    /// The validation is not defensive nicety: the type system calls several
    /// single-word pointers "references" that are not GC objects — a `chan`
    /// handle is page-allocated and process-lifetime, a bare function value is
    /// a code address — and both the stack maps (§4) and object pointer maps
    /// (§2) legitimately list them. Feeding one to a blind mark would decode
    /// `ptr - header` as a bogus `GcHeader` and corrupt or crash. The O(1)
    /// address-bounds gate rejects the common foreign pointer; `owns` is the
    /// exact backstop.
    ///
    /// ponytail: `owns` is an O(objects) list scan, so tracing a large *live*
    /// graph is O(n^2). Fine for v1's small heaps and the correctness goldens;
    /// the upgrade when it bites (a stress workload, #350) is an address->object
    /// index (hash set of live body pointers) making this O(1).
    pub fn markRoot(self: *Gc, ref: ?[*]u8) void {
        const p = ref orelse return;
        const word = @intFromPtr(p);
        if (word < self.lo_addr or word >= self.hi_addr) return;
        if (self.owns(p)) self.markObject(headerFromBody(p));
    }

    /// True iff `ptr` is the body base of a live managed object. Interior and
    /// foreign pointers return false — the contract requires references to point
    /// at an object base, and this is how that is checked.
    ///
    /// ponytail: linear scan of the all-objects list, O(n). A debug/validation
    /// aid, not on the mark hot path (precise roots already give base pointers).
    /// Add an address->object index if this ever needs to run hot.
    pub fn owns(self: *const Gc, ptr: [*]u8) bool {
        const target = @intFromPtr(ptr);
        var o = self.all;
        while (o) |h| : (o = h.next) { // bounded: at most `num_objects` links
            if (@intFromPtr(bodyFromHeader(h)) == target) return true;
        }
        return false;
    }

    // -- internals ----------------------------------------------------------

    fn markObject(self: *Gc, h: *GcHeader) void {
        if (h.marked) return;
        h.marked = true;
        if (self.stack_top < self.stack.len) {
            self.stack[self.stack_top] = h;
            self.stack_top += 1;
        } else {
            // Worklist full: the object is marked (so it survives) but its
            // children are not yet traced. A rescan pass will scan it.
            self.overflow = true;
        }
    }

    /// Trace every queued object's reference fields until the worklist drains.
    fn drain(self: *Gc) void {
        // Bounded: each object is queued at most once (guarded by `marked`), so
        // total pops across the whole mark phase is <= num_objects.
        while (self.stack_top > 0) {
            self.stack_top -= 1;
            self.scanObject(self.stack[self.stack_top]);
        }
    }

    /// After a worklist overflow, some marked objects were never traced. Rescan
    /// all marked objects, re-queueing their children, until no overflow remains.
    /// Terminates because every overflow pass marks at least one new object and
    /// the mark count is bounded by `num_objects`.
    fn recoverOverflow(self: *Gc) void {
        var passes: usize = 0;
        const max_passes = self.num_objects + 1; // provable upper bound
        while (self.overflow and passes < max_passes) : (passes += 1) {
            self.overflow = false;
            var o = self.all;
            while (o) |h| : (o = h.next) { // bounded: num_objects links
                if (h.marked) self.scanObject(h);
            }
            self.drain();
        }
    }

    fn scanObject(self: *Gc, h: *GcHeader) void {
        const body = bodyFromHeader(h);
        const offs = h.info.ptrOffsets();
        var i: usize = 0;
        while (i < offs.len) : (i += 1) { // bounded: num_ptrs for this type
            const off = offs[i];
            std.debug.assert(off % @alignOf(usize) == 0);
            std.debug.assert(off + @sizeOf(usize) <= h.info.size);
            const slot: *const ?[*]u8 = @ptrCast(@alignCast(body + off));
            self.markRoot(slot.*);
        }
    }

    /// Free every unmarked object and clear the mark on survivors. Returns the
    /// number of objects reclaimed.
    fn sweep(self: *Gc) usize {
        var swept: usize = 0;
        var link: *?*GcHeader = &self.all;
        while (link.*) |h| { // bounded: num_objects links
            if (h.marked) {
                h.marked = false;
                link = &h.next;
            } else {
                link.* = h.next; // unlink before freeing
                self.num_objects -= 1;
                swept += 1;
                self.freeObject(h);
            }
        }
        return swept;
    }

    fn freeObject(self: *Gc, h: *GcHeader) void {
        const raw: [*]u8 = @ptrCast(h);
        self.heap.free(raw, h.size, gc_align);
    }
};

fn headerFromBody(body: [*]u8) *GcHeader {
    return @ptrCast(@alignCast(body - header_size));
}

fn bodyFromHeader(h: *GcHeader) [*]u8 {
    const raw: [*]u8 = @ptrCast(h);
    return raw + header_size;
}

/// Build a `Config` from `BIT_GC*` environment variables, over the defaults.
///
///   BIT_GC=off|0            disable automatic collection
///   BIT_GC=stress           collect at every safepoint (torture the root scan)
///   BIT_GC_MIN_KB=<n>       min live KiB before the first/next collection
///   BIT_GC_GROWTH_PCT=<n>   heap growth percent between collections (>= 100)
///   BIT_GC_MARKSTACK=<n>    mark worklist capacity in entries (> 0)
///   BIT_GC_STATS=1|on       print a line per collection to stderr
///
/// The environment block is passed in (Zig 0.16 injects it into `main`), so the
/// runtime-init ticket forwards the block it received. No allocator needed:
/// `getPosix` returns a slice into the block.
///
/// ponytail: POSIX env only. Windows keeps the compiled defaults until the
/// runtime needs the WTF-16 lookup; these are tuning knobs, not correctness.
pub fn configFromEnv(environ: std.process.Environ) Config {
    var c = Config{};
    if (lookupEnv(environ, "BIT_GC")) |v| {
        if (std.mem.eql(u8, v, "off") or std.mem.eql(u8, v, "0")) c.enabled = false;
        if (std.mem.eql(u8, v, "stress")) c.stress = true;
    }
    if (envUsize(environ, "BIT_GC_MIN_KB")) |kb| c.min_trigger = kb *| 1024;
    if (envUsize(environ, "BIT_GC_GROWTH_PCT")) |g| {
        if (g >= 100) c.growth_pct = g;
    }
    if (envUsize(environ, "BIT_GC_MARKSTACK")) |n| {
        if (n > 0) c.mark_stack_len = n;
    }
    if (lookupEnv(environ, "BIT_GC_STATS")) |v| {
        if (std.mem.eql(u8, v, "1") or std.mem.eql(u8, v, "on")) c.verbose = true;
    }
    return c;
}

fn lookupEnv(environ: std.process.Environ, key: []const u8) ?[]const u8 {
    if (comptime builtin.os.tag == .windows) return null;
    if (environ.getPosix(key)) |v| return v;
    return null;
}

fn envUsize(environ: std.process.Environ, key: []const u8) ?usize {
    const v = lookupEnv(environ, key) orelse return null;
    return std.fmt.parseInt(usize, v, 10) catch null;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

/// Two-pointer node body: children at offsets 0 and 8.
const node_offsets = [_]usize{ 0, 8 };
const node_info = TypeInfo.of(16, &node_offsets, "Node");

/// Eight-pointer node body: fans out wide enough to overflow a small worklist.
const wide_offsets = [_]usize{ 0, 8, 16, 24, 32, 40, 48, 56 };
const wide_info = TypeInfo.of(64, &wide_offsets, "Wide");

fn setPtr(body: [*]u8, off: usize, target: ?[*]u8) void {
    const slot: *?[*]u8 = @ptrCast(@alignCast(body + off));
    slot.* = target;
}

/// Root scanner backed by an explicit slice of body pointers.
const RootArray = struct {
    roots: []const [*]u8,
    fn scan(ctx: *anyopaque, gc: *Gc) void {
        const self: *const RootArray = @ptrCast(@alignCast(ctx));
        for (self.roots) |r| gc.markRoot(r);
    }
    fn scanner(self: *RootArray) RootScanner {
        return .{ .ctx = @ptrCast(self), .scan = RootArray.scan };
    }
};

test "reachable data survives and an unreachable cycle is collected" {
    var heap = Heap.init();
    var gc = try Gc.init(&heap, .{ .enabled = false });
    defer gc.deinit();

    const a = gc.alloc(&node_info).?;
    const b = gc.alloc(&node_info).?;
    setPtr(a, 0, b); // a -> b

    // c <-> d: an unreachable cycle. Reference counting would leak it; tracing
    // must not.
    const c = gc.alloc(&node_info).?;
    const d = gc.alloc(&node_info).?;
    setPtr(c, 0, d);
    setPtr(d, 0, c);

    try testing.expectEqual(@as(usize, 4), gc.num_objects);

    var roots = RootArray{ .roots = &[_][*]u8{a} };
    gc.collect(roots.scanner());

    try testing.expectEqual(@as(usize, 2), gc.num_objects);
    try testing.expect(gc.owns(a));
    try testing.expect(gc.owns(b));
    try testing.expect(!gc.owns(c));
    try testing.expect(!gc.owns(d));
}

test "contract: interior and foreign pointers are not owned" {
    var heap = Heap.init();
    var gc = try Gc.init(&heap, .{ .enabled = false });
    defer gc.deinit();

    const a = gc.alloc(&node_info).?;
    try testing.expect(gc.owns(a)); // base pointer is valid

    const interior = a + 8; // into the middle of the 16-byte body
    try testing.expect(!gc.owns(interior)); // interior rejected per contract

    const foreign: [*]u8 = @ptrFromInt(0x1000);
    try testing.expect(!gc.owns(foreign));
}

test "mark overflow recovery: wide graph fully retained with a tiny worklist" {
    var heap = Heap.init();
    // Worklist of 4 cannot hold the root's 8 children at once, forcing overflow.
    var gc = try Gc.init(&heap, .{ .enabled = false, .mark_stack_len = 4 });
    defer gc.deinit();

    const root = gc.alloc(&wide_info).?;
    var mids: [8][*]u8 = undefined;
    var leaves: [8][*]u8 = undefined;
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        mids[i] = gc.alloc(&node_info).?;
        leaves[i] = gc.alloc(&node_info).?;
        setPtr(mids[i], 0, leaves[i]); // mid -> leaf
        setPtr(root, i * 8, mids[i]); // root -> mid
    }

    // Garbage that must be reclaimed even while overflow recovery runs.
    i = 0;
    while (i < 5) : (i += 1) _ = gc.alloc(&node_info).?;

    try testing.expectEqual(@as(usize, 1 + 8 + 8 + 5), gc.num_objects);

    var roots = RootArray{ .roots = &[_][*]u8{root} };
    gc.collect(roots.scanner());

    // Leaves survive only if the overflowed (marked-but-untraced) mids were
    // rescanned — this is the property under test.
    try testing.expectEqual(@as(usize, 1 + 8 + 8), gc.num_objects);
    try testing.expect(gc.owns(root));
    i = 0;
    while (i < 8) : (i += 1) {
        try testing.expect(gc.owns(mids[i]));
        try testing.expect(gc.owns(leaves[i]));
    }
}

test "configFromEnv: empty env gives defaults, set vars override" {
    const def = configFromEnv(std.process.Environ.empty);
    try testing.expect(def.enabled);
    try testing.expectEqual(@as(usize, 200), def.growth_pct);
    try testing.expect(def.mark_stack_len > 0);

    if (comptime builtin.os.tag == .windows) return; // POSIX-only env tuning in v1

    const entries = [_:null]?[*:0]const u8{
        "BIT_GC=off",
        "BIT_GC_MIN_KB=64",
        "BIT_GC_GROWTH_PCT=150",
        "BIT_GC_MARKSTACK=32",
        "BIT_GC_STATS=on",
    };
    const stress_entries = [_:null]?[*:0]const u8{"BIT_GC=stress"};
    const stress_env = std.process.Environ{ .block = .{ .slice = &stress_entries } };
    const sc = configFromEnv(stress_env);
    try testing.expect(sc.enabled and sc.stress);

    const env = std.process.Environ{ .block = .{ .slice = &entries } };
    const c = configFromEnv(env);
    try testing.expect(!c.enabled);
    try testing.expectEqual(@as(usize, 64 * 1024), c.min_trigger);
    try testing.expectEqual(@as(usize, 150), c.growth_pct);
    try testing.expectEqual(@as(usize, 32), c.mark_stack_len);
    try testing.expect(c.verbose);
}

test "stress: 10M short-lived allocations keep the heap bounded" {
    var heap = Heap.init();
    var gc = try Gc.init(&heap, .{
        .min_trigger = 256 * 1024,
        .growth_pct = 200,
        .mark_stack_len = 1024,
    });
    defer gc.deinit();

    const ring_len = 256;
    var ring = [_]?[*]u8{null} ** ring_len;

    const Ring = struct {
        r: *[ring_len]?[*]u8,
        fn scan(ctx: *anyopaque, g: *Gc) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            for (self.r.*) |p| if (p) |q| g.markRoot(q);
        }
    };
    var rr = Ring{ .r = &ring };
    const scanner = RootScanner{ .ctx = @ptrCast(&rr), .scan = Ring.scan };

    const iterations: usize = 10_000_000;
    var peak: usize = 0;
    var i: usize = 0;
    while (i < iterations) : (i += 1) { // statically bounded
        gc.safepoint(scanner); // collect if the trigger was crossed
        const p = gc.alloc(&node_info) orelse return error.OutOfMemory;
        ring[i % ring_len] = p; // only the last `ring_len` stay reachable
        const live = heap.liveBytes();
        if (live > peak) peak = live;
    }

    // Final unconditional collection: everything but the live ring must go.
    gc.collect(scanner);

    // Bounded: ~480 MB churned, but concurrent live bytes never approached it.
    try testing.expect(peak < 32 * 1024 * 1024);
    try testing.expect(gc.num_objects <= ring_len);
}
