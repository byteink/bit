//! Runtime memory allocator: size-class segregated free lists over OS pages.
//!
//! Freestanding, zero libc: pages come straight from `mmap`/`VirtualAlloc`.
//! Small objects are carved from per-class spans and recycled through intrusive
//! free lists; objects larger than the last size class are mapped directly.
//! This is the foundation the GC heap is built on.
//!
//! Free contract: `free()` receives the same `size` and `alignment` that
//! `alloc()` returned for. That is how Zig's own allocator interface works and
//! how the GC will call it (object sizes live in GC headers), so we need no
//! per-object headers and no address→span lookup table.
//!
//! Thread safety: a single `SpinLock` guards the free lists and the byte
//! counters, so the scheduler's green-thread workers can allocate concurrently on
//! different OS threads. ponytail: one coarse lock — a span map (`mapPages`) runs
//! under it, so refills briefly serialize all allocators; the upgrade when
//! contention bites is a per-worker cache in front of the shared lists.

const std = @import("std");
const builtin = @import("builtin");
const SpinLock = @import("spinlock.zig").SpinLock;

/// Compile-time lower bound on the OS page size; used only for pointer types.
/// The real page size is read at runtime via `std.heap.pageSize()`.
const page_align = std.heap.page_size_min;

/// Small-object size classes in bytes. Every power of two up to the largest
/// class is present — that guarantees any supported alignment (a power of two
/// no larger than `max_small`) is itself a class, so a satisfying slot always
/// exists. Requests above the last class are direct-mapped from the OS.
const class_sizes = [_]usize{
    8,    16,    32,    48,    64,    80,   96,   112,
    128,  160,   192,   224,   256,   320,  384,  448,
    512,  640,   768,   896,   1024,  1280, 1536, 1792,
    2048, 2560,  3072,  3584,  4096,  5120, 6144, 7168,
    8192, 10240, 12288, 14336, 16384,
};
const num_classes = class_sizes.len;
const max_small = class_sizes[num_classes - 1];

/// Bytes pulled from the OS each time a size class runs dry. Kept >= max_small
/// so every span holds at least one slot of every class.
const span_bytes: usize = 128 * 1024;

comptime {
    std.debug.assert(span_bytes >= max_small);
    // Every free slot must hold the intrusive next-pointer.
    std.debug.assert(class_sizes[0] >= @sizeOf(Slot));
}

/// Intrusive free-list node, stored inside a free slot.
const Slot = struct { next: ?*Slot };

pub const Heap = struct {
    /// Guards the free lists and the byte counters against concurrent allocation
    /// from multiple OS worker threads. The critical section is a few list-pointer
    /// swaps (plus an occasional `mapPages` on refill), never a blocking wait.
    lock: SpinLock = .{},
    free_lists: [num_classes]?*Slot = [_]?*Slot{null} ** num_classes,
    /// Bytes handed out to callers and not yet freed. Returns to 0 when every
    /// allocation is freed — the leak metric the verify stress test checks.
    /// Atomic so the GC's off-lock `liveBytes` trigger read never tears; every
    /// write happens under `lock`.
    live_bytes: std.atomic.Value(usize) = .init(0),
    /// Total bytes currently mapped from the OS (spans + large allocations).
    mapped_bytes: std.atomic.Value(usize) = .init(0),

    pub fn init() Heap {
        return .{};
    }

    /// Allocate `size` bytes aligned to `alignment` (a power of two, no larger
    /// than the OS page size). Returns null only when the OS refuses more pages.
    pub fn alloc(self: *Heap, size: usize, alignment: usize) ?[*]u8 {
        std.debug.assert(alignment != 0 and std.math.isPowerOfTwo(alignment));
        self.lock.acquire();
        defer self.lock.release();
        if (classify(size, alignment)) |idx| return self.allocSmall(idx, size);
        return self.allocLarge(size, alignment);
    }

    /// Free a block previously returned by `alloc`. `size` and `alignment` must
    /// match the original request.
    pub fn free(self: *Heap, ptr: [*]u8, size: usize, alignment: usize) void {
        self.lock.acquire();
        defer self.lock.release();
        if (classify(size, alignment)) |idx| {
            self.freeSmall(ptr, idx, size);
        } else {
            self.freeLarge(ptr, size, alignment);
        }
    }

    pub fn liveBytes(self: *const Heap) usize {
        return self.live_bytes.load(.monotonic);
    }

    pub fn mappedBytes(self: *const Heap) usize {
        return self.mapped_bytes.load(.monotonic);
    }

    fn allocSmall(self: *Heap, idx: usize, size: usize) ?[*]u8 {
        if (self.free_lists[idx] == null and !self.refill(idx)) return null;
        const slot = self.free_lists[idx].?;
        self.free_lists[idx] = slot.next;
        _ = self.live_bytes.fetchAdd(size, .monotonic);
        return @ptrCast(slot);
    }

    fn freeSmall(self: *Heap, ptr: [*]u8, idx: usize, size: usize) void {
        const slot: *Slot = @ptrCast(@alignCast(ptr));
        slot.next = self.free_lists[idx];
        self.free_lists[idx] = slot;
        _ = self.live_bytes.fetchSub(size, .monotonic);
    }

    /// Carve one fresh span into slots and push them onto class `idx`.
    fn refill(self: *Heap, idx: usize) bool {
        const cs = class_sizes[idx];
        const span = mapPages(span_bytes) orelse return false;
        _ = self.mapped_bytes.fetchAdd(span_bytes, .monotonic);
        const count = span_bytes / cs; // >= 1 by the span_bytes >= max_small invariant
        std.debug.assert(count >= 1);
        var i: usize = 0;
        while (i < count) : (i += 1) { // bounded: count <= span_bytes / class_sizes[0]
            const slot: *Slot = @ptrCast(@alignCast(span + i * cs));
            slot.next = self.free_lists[idx];
            self.free_lists[idx] = slot;
        }
        return true;
    }

    fn allocLarge(self: *Heap, size: usize, alignment: usize) ?[*]u8 {
        const ps = std.heap.pageSize();
        // Direct-mapped pages are only page-aligned; larger alignment is out of
        // scope (language objects never need it). ponytail: over-map and trim if
        // that ever changes.
        std.debug.assert(alignment <= ps);
        const len = alignUp(nonZero(size), ps);
        const mem = mapPages(len) orelse return null;
        _ = self.mapped_bytes.fetchAdd(len, .monotonic);
        _ = self.live_bytes.fetchAdd(size, .monotonic);
        return mem;
    }

    fn freeLarge(self: *Heap, ptr: [*]u8, size: usize, alignment: usize) void {
        const ps = std.heap.pageSize();
        std.debug.assert(alignment <= ps);
        const len = alignUp(nonZero(size), ps);
        unmapPages(ptr, len);
        _ = self.mapped_bytes.fetchSub(len, .monotonic);
        _ = self.live_bytes.fetchSub(size, .monotonic);
    }
};

/// Map a request to a size-class index, or null if it must be direct-mapped.
fn classify(size: usize, alignment: usize) ?usize {
    const needed = alignUp(size, alignment);
    if (needed > max_small) return null;
    var i: usize = 0;
    while (i < num_classes) : (i += 1) { // bounded: <= num_classes iterations
        const cs = class_sizes[i];
        // cs % alignment == 0 plus a page-aligned span base means every slot in
        // the class is `alignment`-aligned.
        if (cs >= needed and cs % alignment == 0) return i;
    }
    return null; // unreachable for alignment <= max_small; falls back to large path
}

fn alignUp(n: usize, a: usize) usize {
    return (n + a - 1) & ~(a - 1);
}

fn nonZero(n: usize) usize {
    return if (n == 0) 1 else n;
}

fn mapPages(len: usize) ?[*]align(page_align) u8 {
    if (builtin.os.tag == .windows) {
        const w = std.os.windows;
        const p = w.VirtualAlloc(
            null,
            len,
            w.MEM_COMMIT | w.MEM_RESERVE,
            w.PAGE_READWRITE,
        ) catch return null;
        return @alignCast(@as([*]u8, @ptrCast(p)));
    }
    const prot = std.posix.PROT{ .READ = true, .WRITE = true };
    const flags = std.posix.MAP{ .TYPE = .PRIVATE, .ANONYMOUS = true };
    const mem = std.posix.mmap(null, len, prot, flags, -1, 0) catch return null;
    return mem.ptr;
}

/// The page seam `runtime/gc/mem.bit` reaches through (#1638).
///
/// The Bit collector must compile for all three targets, so it cannot contain a
/// `syscall` or a platform `extern function` itself; it names this symbol and
/// lets the link resolve it. This definition is the one that serves while the
/// ZIG archive is still the linked runtime, which is every program importing
/// `runtime/gc` from source today (`tests/stress/gcbit` and its neighbours).
/// In a Bit-sourced archive the definition is `runtime/root/{linux,darwin}`'s
/// `rtMapPages`, pinned `bit_rt_root_map_pages` — the `bit_rt_root_` prefix
/// every Bit port of a `root.zig` symbol carries so the two runtimes can be in
/// one link without colliding, which G2's rename (#1583) strips to exactly this
/// name. Spelling THIS one `bit_rt_port_alloc_map_pages` — the Bit page
/// provider's own pin — is what a first attempt did, and it fails
/// `tests/stress/roothostdarwin` with DuplicateSymbol: that program compiles
/// `runtime/alloc/darwin` from source AND links this archive.
///
/// Returns 0 when the OS refuses, matching the Bit providers' sentinel.
export fn bit_rt_map_pages(nbytes: i64) callconv(.c) i64 {
    if (nbytes <= 0) return 0;
    const mem = mapPages(@intCast(nbytes)) orelse return 0;
    return @intCast(@intFromPtr(mem));
}

/// The release half of the `bit_rt_map_pages` seam (#1641).
///
/// `runtime/gc/mem.bit`'s `memUnmapPages` names this symbol for exactly the
/// reasons the mapping half documents above, and the same two definitions
/// answer to it: this one while the Zig archive is the linked runtime, and
/// `runtime/root/{linux,darwin}`'s provider once G2's rename (#1583) strips the
/// `bit_rt_root_` prefix. Do not rename it to the Bit page provider's own pin —
/// see `bit_rt_map_pages` for the DuplicateSymbol that produces.
///
/// `addr`/`nbytes` must be a range this runtime mapped. Returns 1 on release
/// and 0 for a rejected argument; the Bit caller ignores the result, matching
/// `unmapPages` returning void.
export fn bit_rt_unmap_pages(addr: i64, nbytes: i64) callconv(.c) i64 {
    if (addr == 0 or nbytes <= 0) return 0;
    const ptr: [*]u8 = @ptrFromInt(@as(usize, @intCast(addr)));
    unmapPages(ptr, @intCast(nbytes));
    return 1;
}

fn unmapPages(ptr: [*]u8, len: usize) void {
    if (builtin.os.tag == .windows) {
        std.os.windows.VirtualFree(@ptrCast(ptr), 0, std.os.windows.MEM_RELEASE);
        return;
    }
    const aligned: [*]align(page_align) u8 = @alignCast(ptr);
    std.posix.munmap(aligned[0..len]);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "alloc/free every size class: alignment, writability, reuse" {
    var heap = Heap.init();
    for (class_sizes) |cs| {
        const p = heap.alloc(cs, 8) orelse return error.OutOfMemory;
        try testing.expect(@intFromPtr(p) % 8 == 0);
        // Touch the whole slot to prove it is mapped and non-overlapping.
        @memset(p[0..cs], 0xAB);
        try testing.expectEqual(cs, heap.liveBytes());
        heap.free(p, cs, 8);
        try testing.expectEqual(@as(usize, 0), heap.liveBytes());

        // Freed slot must be recycled, not re-mapped.
        const q = heap.alloc(cs, 8) orelse return error.OutOfMemory;
        try testing.expectEqual(@intFromPtr(p), @intFromPtr(q));
        heap.free(q, cs, 8);
    }
}

test "alignment guarantees across powers of two" {
    var heap = Heap.init();
    const aligns = [_]usize{ 8, 16, 32, 64, 128, 256, 512, 1024, 4096 };
    for (aligns) |a| {
        for ([_]usize{ 1, 7, 8, 17, 100, 1000 }) |size| {
            const p = heap.alloc(size, a) orelse return error.OutOfMemory;
            try testing.expect(@intFromPtr(p) % a == 0);
            @memset(p[0..size], 0xCD);
            heap.free(p, size, a);
        }
    }
    try testing.expectEqual(@as(usize, 0), heap.liveBytes());
}

test "large direct-mapped allocations are page aligned and unmapped on free" {
    var heap = Heap.init();
    const ps = std.heap.pageSize();
    for ([_]usize{ max_small + 1, 100 * 1024, 1024 * 1024 }) |size| {
        const p = heap.alloc(size, 16) orelse return error.OutOfMemory;
        try testing.expect(@intFromPtr(p) % ps == 0);
        @memset(p[0..size], 0xEF);
        try testing.expectEqual(size, heap.liveBytes());
        heap.free(p, size, 16);
        try testing.expectEqual(@as(usize, 0), heap.liveBytes());
    }
    // Every large mapping was returned to the OS.
    try testing.expectEqual(@as(usize, 0), heap.mappedBytes());
}

test "stress: 1M allocations churn without leaking live bytes" {
    var heap = Heap.init();
    const iterations: usize = 1_000_000;
    const ring_len: usize = 4096;

    const Entry = struct { ptr: ?[*]u8 = null, size: usize = 0, alignment: usize = 0 };
    var ring = [_]Entry{.{}} ** ring_len;

    var i: usize = 0;
    while (i < iterations) : (i += 1) { // statically bounded loop
        const slot = i % ring_len;
        const e = &ring[slot];
        if (e.ptr) |old| {
            // Verify the sentinel survived, i.e. no slot overlap.
            try testing.expectEqual(@as(u8, @truncate(e.size)), old[0]);
            heap.free(old, e.size, e.alignment);
            e.ptr = null;
        }
        // Deterministic size/alignment spanning both small and large paths.
        const size = 1 + (i *% 2654435761) % 20000;
        const alignment = @as(usize, 8) << @intCast(i % 4); // 8,16,32,64
        const p = heap.alloc(size, alignment) orelse return error.OutOfMemory;
        try testing.expect(@intFromPtr(p) % alignment == 0);
        p[0] = @truncate(size);
        e.* = .{ .ptr = p, .size = size, .alignment = alignment };
    }

    // Drain survivors.
    for (&ring) |*e| {
        if (e.ptr) |p| heap.free(p, e.size, e.alignment);
    }
    try testing.expectEqual(@as(usize, 0), heap.liveBytes());
}

test "concurrent stress: N threads share one heap without corruption or leak" {
    if (builtin.single_threaded) return;

    var heap = Heap.init();

    // Each worker churns its own ring of live allocations against the shared heap.
    // A per-thread sentinel byte written into every allocation must survive until
    // that thread frees it: if the lock ever handed the same slot to two threads,
    // one thread's write would clobber the other's sentinel and the assert fires.
    const Worker = struct {
        fn run(h: *Heap, seed: usize) void {
            const iterations: usize = 200_000;
            const ring_len: usize = 256;
            const Entry = struct { ptr: ?[*]u8 = null, size: usize = 0, alignment: usize = 0, tag: u8 = 0 };
            var ring = [_]Entry{.{}} ** ring_len;

            var i: usize = 0;
            while (i < iterations) : (i += 1) { // statically bounded
                const e = &ring[i % ring_len];
                if (e.ptr) |old| {
                    std.debug.assert(old[0] == e.tag); // sentinel intact -> no cross-thread overlap
                    h.free(old, e.size, e.alignment);
                    e.ptr = null;
                }
                const mix = (i +% seed) *% 2654435761;
                const size = 1 + mix % 20000; // spans the small and large paths
                const alignment = @as(usize, 8) << @as(u6, @intCast(mix % 4)); // 8,16,32,64
                const p = h.alloc(size, alignment) orelse @panic("heap exhausted in concurrent stress");
                std.debug.assert(@intFromPtr(p) % alignment == 0);
                const tag: u8 = @truncate(seed *% 131 +% i);
                p[0] = tag;
                e.* = .{ .ptr = p, .size = size, .alignment = alignment, .tag = tag };
            }
            for (&ring) |*e| {
                if (e.ptr) |p| {
                    std.debug.assert(p[0] == e.tag);
                    h.free(p, e.size, e.alignment);
                }
            }
        }
    };

    const nthreads = @min(@as(usize, 4), std.Thread.getCpuCount() catch 2);
    var threads: [4]std.Thread = undefined;
    var t: usize = 0;
    while (t < nthreads) : (t += 1) {
        threads[t] = try std.Thread.spawn(.{}, Worker.run, .{ &heap, t + 1 });
    }
    for (threads[0..nthreads]) |th| th.join();

    // Every allocation was freed by its owning thread: a clean liveBytes proves the
    // atomic counter neither lost nor double-counted an update across the threads.
    try testing.expectEqual(@as(usize, 0), heap.liveBytes());
}
