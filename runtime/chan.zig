//! Typed channels: `Chan(T)` is a bounded (fixed-capacity ring buffer) or
//! unbuffered (capacity 0, synchronous rendezvous) queue between green
//! threads, plus `select` for waiting on several channels at once.
//!
//! Semantics match the spec (SPEC.md §16.2-16.3, mirroring Go): send on a
//! closed channel panics, receive on a closed-and-drained channel yields
//! `(zero, false)`, a nil channel blocks forever, `close` wakes every blocked
//! peer, and `select` picks uniformly at random among the cases ready at the
//! moment it runs.
//!
//! Blocking is implemented entirely on top of `sched.park`/`sched.unpark`: a
//! blocked send or receive parks the calling green thread and links a
//! stack-local `Waiter` onto the channel's wait queue, from `park`'s `setup`
//! callback — never before, and never after. `setup` runs strictly after the
//! task's context is saved and its state is visibly `.parked` (see `park`'s
//! doc comment in sched.zig); registering the waiter any earlier would let a
//! concurrent `unpark` race a task that isn't actually parked yet. `setup`
//! also rechecks whether the channel condition is now satisfiable (someone
//! else may have changed it in the gap since the caller last checked under
//! lock) and, if so, completes and self-unparks right there instead of
//! registering — the same "recheck under the park callback" trick single- and
//! multi-channel (select) waits both rely on.
//!
//! `select` needs one more piece: exactly one of several concurrently-racing
//! channel operations must be allowed to complete a given select's waiter.
//! Each registered `Waiter` optionally points at a `SelectShared`; claiming a
//! waiter is a compare-and-swap on `SelectShared.done`, so only the first
//! completer wins — every other channel's attempt on that same select finds
//! the CAS lost, treats the waiter as if it were never there, and moves on
//! (exactly Go's `sudog.isSelect` / `selectDone` design).
//!
//! ponytail: the spec (§16.2) defines exactly two channel shapes — unbuffered
//! (`chan<T>()`) and fixed-capacity buffered (`chan<T>(N)`) — no growable
//! "unbounded" queue channel. Capacity 0 *is* the unbuffered case; the ring
//! buffer's `count < cap` check is `0 < 0` there, so it naturally always takes
//! the direct-handoff or block path with no special-casing.
//!
//! ponytail: `select` is capped at `max_select_cases` parked cases, sized on
//! the stack (no heap allocation, per the resource-predictability rule). Bump
//! the constant if a real program ever needs more; nobody writes 32-way
//! selects.
//!
//! ponytail: fairness (`select`'s "uniformly at random") only needs an
//! unbiased shuffle, not an unpredictable one, so each call seeds its own
//! xoshiro256 from the clock, a stack address, and a call counter rather than
//! pulling in a CSPRNG dependency.

const std = @import("std");
const sched = @import("sched.zig");

// ---------------------------------------------------------------------------
// select: type-erased case list over heterogeneous Chan(T) instances
// ---------------------------------------------------------------------------

pub const SelectDir = enum { send, recv };

/// Dispatch table generated once per `Chan(T)` instantiation (see `Chan`'s
/// `vtable`). Every function takes the channel's own lock as already held by
/// the caller except `lock`/`unlock`/`addr` themselves, mirroring gc.zig's
/// `RootScanner` — a static vtable over an opaque pointer, the one indirection
/// this file needs to let `select` work across distinct `T`s.
pub const ChanVTable = struct {
    addr: *const fn (chan: *anyopaque) usize,
    lock: *const fn (chan: *anyopaque) void,
    unlock: *const fn (chan: *anyopaque) void,
    /// Non-blocking attempt, lock already held. Returns true if the
    /// communication happened (or, for `closed`, would panic) and sets `ok`.
    tryRecv: *const fn (chan: *anyopaque, elem: *anyopaque, ok: *bool, sp: *sched.Scheduler) bool,
    trySend: *const fn (chan: *anyopaque, elem: *anyopaque, ok: *bool, sp: *sched.Scheduler) bool,
    /// Register a waiter, lock already held. `node` is `max_select_cases`
    /// scratch storage owned by `select`'s stack frame (see `SelectNode`).
    enqueueRecv: *const fn (chan: *anyopaque, node: *anyopaque, task: *sched.Task, elem: *anyopaque, ok: *bool, sel: *SelectShared, case_idx: usize) void,
    enqueueSend: *const fn (chan: *anyopaque, node: *anyopaque, task: *sched.Task, elem: *anyopaque, ok: *bool, sel: *SelectShared, case_idx: usize) void,
    /// Unlink a losing case's waiter, lock already held. A no-op if the
    /// waiter already completed (and so was already unlinked) or was never
    /// registered (the winner resolved before any registration happened).
    removeRecv: *const fn (chan: *anyopaque, node: *anyopaque) void,
    removeSend: *const fn (chan: *anyopaque, node: *anyopaque) void,
};

pub const SelectCase = struct {
    dir: SelectDir,
    chan: *anyopaque,
    /// recv: destination slot for the received value. send: the
    /// already-evaluated value to send (spec: case operands are evaluated
    /// once, at entry to `select`, before this case is ever built).
    elem: *anyopaque,
    /// recv only: where to write whether the value is valid.
    ok_out: ?*bool = null,
    vtable: *const ChanVTable,
};

pub const SelectResult = union(enum) { fired: usize, default };

/// Winner-take-all flag shared by every case of one `select` call. Claiming a
/// waiter is the CAS on `done`; the winner also records which case fired so
/// `select` can read it back without threading a return value through
/// `sched.park`.
const SelectShared = struct {
    done: std.atomic.Value(u8) = .init(0),
    winner: usize = undefined,
};

/// Fixed-size, layout-compatible stand-in for `Chan(T).Waiter` used as
/// `select`'s per-case scratch storage — `select` itself never knows the
/// concrete `T` of any case. Every `Waiter` field is a pointer or `usize`
/// regardless of `T` (a `*T` is 8 bytes no matter what `T` is), so an `extern
/// struct` with the same field order/types has identical layout; the
/// `comptime` assert in `Chan(T)` proves it for every instantiation instead of
/// trusting that reasoning blindly.
const SelectNode = extern struct {
    task: *sched.Task = undefined,
    elem: *anyopaque = undefined,
    ok: *bool = undefined,
    select: ?*SelectShared = null,
    case_idx: usize = 0,
    next: ?*anyopaque = null,
};

/// No heap allocation for select's wait registrations (Power-of-10: bounded
/// resources) — plenty of headroom for any real `select` statement.
pub const max_select_cases = 32;

var select_seed_counter: std.atomic.Value(u64) = .init(0);

/// Fresh, unshared PRNG per call — see the module doc comment's ponytail note.
fn selectRandom() std.Random.Xoshiro256 {
    const counter = select_seed_counter.fetchAdd(1, .monotonic);
    var stack_marker: u8 = 0;
    const seed = sched.monoNs() ^ counter ^ @intFromPtr(&stack_marker);
    return std.Random.Xoshiro256.init(seed);
}

fn sortByAddr(cases: []const SelectCase, order: []usize) void {
    // Insertion sort: order.len <= max_select_cases, no need for anything
    // fancier. This is the global lock order that keeps two concurrent
    // `select`s sharing channels from deadlocking each other.
    var i: usize = 1;
    while (i < order.len) : (i += 1) {
        var j = i;
        while (j > 0 and addrOf(cases, order[j - 1]) > addrOf(cases, order[j])) : (j -= 1) {
            std.mem.swap(usize, &order[j - 1], &order[j]);
        }
    }
}

fn addrOf(cases: []const SelectCase, idx: usize) usize {
    return cases[idx].vtable.addr(cases[idx].chan);
}

/// Lock every distinct channel among `cases`, in `lock_order` (sorted by
/// address, so duplicates from the same channel appearing in two cases are
/// adjacent and locked exactly once).
fn lockAll(cases: []const SelectCase, lock_order: []const usize) void {
    var last_addr: ?usize = null;
    for (lock_order) |idx| {
        const a = addrOf(cases, idx);
        if (last_addr != null and last_addr.? == a) continue;
        cases[idx].vtable.lock(cases[idx].chan);
        last_addr = a;
    }
}

fn unlockAll(cases: []const SelectCase, lock_order: []const usize) void {
    var last_addr: ?usize = null;
    var i = lock_order.len;
    while (i > 0) {
        i -= 1;
        const idx = lock_order[i];
        const a = addrOf(cases, idx);
        if (last_addr != null and last_addr.? == a) continue;
        cases[idx].vtable.unlock(cases[idx].chan);
        last_addr = a;
    }
}

/// One non-blocking pass, all involved channels already locked: shuffle the
/// case order (so "first ready wins" is a uniform-random pick among the ready
/// set) and try each in turn. `send_oks[idx]` receives the send case's
/// outcome (false only means "channel closed, this will panic"); recv cases
/// write straight through their own `ok_out`.
fn pollOnce(cases: []const SelectCase, send_oks: []bool, sp: *sched.Scheduler) ?usize {
    var order: [max_select_cases]usize = undefined;
    for (0..cases.len) |i| order[i] = i;
    var prng = selectRandom();
    prng.random().shuffle(usize, order[0..cases.len]);

    for (order[0..cases.len]) |idx| {
        const c = cases[idx];
        switch (c.dir) {
            .recv => if (c.vtable.tryRecv(c.chan, c.elem, c.ok_out.?, sp)) return idx,
            .send => if (c.vtable.trySend(c.chan, c.elem, &send_oks[idx], sp)) return idx,
        }
    }
    return null;
}

fn finishSelect(cases: []const SelectCase, send_oks: []const bool, idx: usize) SelectResult {
    if (cases[idx].dir == .send and !send_oks[idx]) @panic("send on closed channel");
    return .{ .fired = idx };
}

const SelectSetupCtx = struct {
    cases: []const SelectCase,
    lock_order: []const usize,
    nodes: []SelectNode,
    send_oks: []bool,
    shared: *SelectShared,
    sched: *sched.Scheduler,
};

/// `sched.ParkFn` for a blocking select: runs after this task's state is
/// safely `.parked` (see the module doc comment). Rechecks every case once
/// more under lock — the gap between `select`'s own failed poll and this
/// callback running is exactly when another thread could have made a case
/// ready — and either self-completes (mirrors plain send/recv's setup) or
/// registers this task on every case's wait queue.
fn selectParkSetup(t: *sched.Task, arg: ?*anyopaque) void {
    const ctx: *SelectSetupCtx = @ptrCast(@alignCast(arg.?));
    lockAll(ctx.cases, ctx.lock_order);
    if (pollOnce(ctx.cases, ctx.send_oks, ctx.sched)) |idx| {
        unlockAll(ctx.cases, ctx.lock_order);
        ctx.shared.winner = idx;
        sched.unpark(ctx.sched, t);
        return;
    }
    for (ctx.cases, 0..) |c, i| {
        switch (c.dir) {
            .recv => c.vtable.enqueueRecv(c.chan, &ctx.nodes[i], t, c.elem, c.ok_out.?, ctx.shared, i),
            .send => c.vtable.enqueueSend(c.chan, &ctx.nodes[i], t, c.elem, &ctx.send_oks[i], ctx.shared, i),
        }
    }
    unlockAll(ctx.cases, ctx.lock_order);
}

/// Block until exactly one of `cases` can proceed, chosen uniformly at random
/// among those ready; `has_default` makes a non-blocking attempt instead
/// (spec §16.3). Panics if the winning case is a send on a closed channel,
/// matching a plain blocking `send`. `cases.len == 0` is `select {}`, which
/// blocks forever.
///
/// A nil channel in a case is the caller's responsibility to omit — like Go,
/// a nil-channel case is simply never ready and never wins.
pub fn select(sp: *sched.Scheduler, cases: []const SelectCase, has_default: bool) SelectResult {
    std.debug.assert(cases.len <= max_select_cases);
    if (cases.len == 0) {
        sched.park(null, null); // select {}: no cases, blocks forever.
        unreachable;
    }

    var lock_order: [max_select_cases]usize = undefined;
    for (0..cases.len) |i| lock_order[i] = i;
    sortByAddr(cases, lock_order[0..cases.len]);

    var send_oks: [max_select_cases]bool = undefined;

    lockAll(cases, lock_order[0..cases.len]);
    if (pollOnce(cases, send_oks[0..cases.len], sp)) |idx| {
        unlockAll(cases, lock_order[0..cases.len]);
        return finishSelect(cases, send_oks[0..cases.len], idx);
    }
    if (has_default) {
        unlockAll(cases, lock_order[0..cases.len]);
        return .default;
    }
    unlockAll(cases, lock_order[0..cases.len]); // never hold a spinlock across park's context switch

    var shared: SelectShared = .{};
    var nodes: [max_select_cases]SelectNode = undefined;
    var ctx: SelectSetupCtx = .{
        .cases = cases,
        .lock_order = lock_order[0..cases.len],
        .nodes = nodes[0..cases.len],
        .send_oks = send_oks[0..cases.len],
        .shared = &shared,
        .sched = sp,
    };
    sched.park(selectParkSetup, &ctx);

    // Unlink every losing case's registration before returning: `nodes` lives
    // on this stack frame, and a stale queue entry pointing into it would be
    // a dangling pointer the instant `select` returns. A case that was never
    // actually registered (the winner resolved inside `selectParkSetup`
    // before the registration loop ran) is a harmless no-op here.
    lockAll(cases, lock_order[0..cases.len]);
    for (0..cases.len) |i| {
        if (i == shared.winner) continue;
        switch (cases[i].dir) {
            .recv => cases[i].vtable.removeRecv(cases[i].chan, &nodes[i]),
            .send => cases[i].vtable.removeSend(cases[i].chan, &nodes[i]),
        }
    }
    unlockAll(cases, lock_order[0..cases.len]);

    return finishSelect(cases, send_oks[0..cases.len], shared.winner);
}

// ---------------------------------------------------------------------------
// WaitQueue: singly-linked FIFO of *W, protected by the owning Chan's lock
// ---------------------------------------------------------------------------

fn WaitQueue(comptime W: type) type {
    return struct {
        head: ?*W = null,
        tail: ?*W = null,

        fn push(self: *@This(), w: *W) void {
            w.next = null;
            if (self.tail) |t| t.next = w else self.head = w;
            self.tail = w;
        }

        fn pop(self: *@This()) ?*W {
            const w = self.head orelse return null;
            self.head = w.next;
            if (self.head == null) self.tail = null;
            w.next = null;
            return w;
        }

        fn isEmpty(self: *const @This()) bool {
            return self.head == null;
        }

        /// O(n) unlink of a specific node; only ever used to cancel a losing
        /// select registration. Bounded by the queue's own length. A no-op if
        /// `target` isn't present (already popped by a completer).
        fn remove(self: *@This(), target: *W) void {
            var prev: ?*W = null;
            var cur = self.head;
            while (cur) |c| : (cur = c.next) {
                if (c == target) {
                    if (prev) |p| p.next = c.next else self.head = c.next;
                    if (self.tail == c) self.tail = prev;
                    c.next = null;
                    return;
                }
                prev = c;
            }
        }
    };
}

// ---------------------------------------------------------------------------
// Chan(T)
// ---------------------------------------------------------------------------

pub fn Chan(comptime T: type) type {
    return struct {
        const Self = @This();

        /// See `SelectNode`'s doc comment for why this must stay layout
        /// (field order, field sizes) identical to it.
        const Waiter = extern struct {
            task: *sched.Task = undefined,
            elem: *T = undefined,
            ok: *bool = undefined,
            select: ?*SelectShared = null,
            case_idx: usize = 0,
            next: ?*Waiter = null,
        };

        comptime {
            std.debug.assert(@sizeOf(Waiter) == @sizeOf(SelectNode));
            std.debug.assert(@alignOf(Waiter) == @alignOf(SelectNode));
        }

        const SetupCtx = struct { self: *Self, waiter: *Waiter, sched: *sched.Scheduler };

        lock: sched.SpinLock = .{},
        closed: bool = false,
        buf: []T = &.{},
        cap: usize = 0,
        head: usize = 0,
        count: usize = 0,
        sendq: WaitQueue(Waiter) = .{},
        recvq: WaitQueue(Waiter) = .{},
        /// True when a buffered `T` may itself be a GC reference — set by the
        /// caller after `init` (root.zig's `bit_rt_chan_make`), never by
        /// `Chan(T)` itself. Gates whether `scanRegistryRoots` treats this
        /// channel's buffer as GC roots (ABI.md §11).
        is_ref: bool = false,
        /// Intrusive link for the per-`T` registry below. Unset (`null`) for
        /// channels that are never `register`ed — i.e. every plain
        /// stack-local test channel in this file.
        registry_next: ?*Self = null,

        /// `capacity == 0` is an unbuffered (synchronous) channel.
        pub fn init(capacity: usize) !Self {
            // `alloc` with `capacity == 0` (unbuffered channel) returns a
            // valid empty slice with no actual OS allocation.
            const buf = try std.heap.page_allocator.alloc(T, capacity);
            return .{ .buf = buf, .cap = capacity };
        }

        // -- GC root registry -------------------------------------------
        //
        // A buffered value is reachable only through this ring buffer while
        // it sits unreceived — no stack or register holds it. The registry
        // lets the GC's root scanner (root.zig, ABI.md §11) find every live
        // channel of this instantiation and treat `is_ref` ones' buffered
        // elements as extra roots. One registry per distinct `T` — the ABI
        // only ever registers `Chan(u64)` (see this file's `IntChan`); other
        // instantiations (this file's own tests) never call `register`, so
        // their registries stay empty.
        //
        // Channels are never removed from the registry: v1 has no explicit
        // channel-free primitive (§11), so a registered channel's backing
        // memory is process-lifetime — never freed, hence never dangling.

        var registry_lock: sched.SpinLock = .{};
        var registry_head: ?*Self = null;

        /// Register `self` (which must already be at its final, stable
        /// address — heap-allocated by the caller) so the GC's root scanner
        /// will visit it. Not called by `init`: only the ABI's channel
        /// constructor opts a channel into this bookkeeping.
        pub fn register(self: *Self) void {
            registry_lock.acquire();
            defer registry_lock.release();
            self.registry_next = registry_head;
            registry_head = self;
        }

        /// Visit every registered, `is_ref` channel's currently-buffered
        /// elements as GC roots via `mark`. Called once per collection from
        /// root.zig's root scanner.
        pub fn scanRegistryRoots(mark: *const fn (T) void) void {
            registry_lock.acquire();
            defer registry_lock.release();
            var node = registry_head;
            while (node) |c| : (node = c.registry_next) { // bounded: one registered channel per link
                if (c.is_ref) c.forEachBuffered(mark);
            }
        }

        pub fn deinit(self: *Self) void {
            std.heap.page_allocator.free(self.buf);
        }

        // -- claim/finish: shared by plain waiters and select registrations --

        /// True if this waiter may be completed by the caller. Plain
        /// (non-select) waiters always claim successfully — they sit on
        /// exactly one queue and nothing else contends for them. A select
        /// registration claims via CAS on its shared `done` flag; losing
        /// means a different case of the same select already won, and this
        /// popped entry must be treated as if it had never been queued.
        fn claim(w: *Waiter) bool {
            const s = w.select orelse return true;
            return s.done.cmpxchgStrong(0, 1, .acq_rel, .monotonic) == null;
        }

        fn finish(w: *Waiter, sp: *sched.Scheduler) void {
            if (w.select) |s| s.winner = w.case_idx;
            sched.unpark(sp, w.task);
        }

        // -- ring buffer, cap > 0 only (see Waiter/attempt* callers) --

        fn pushBuf(self: *Self, value: T) void {
            std.debug.assert(self.cap > 0 and self.count < self.cap);
            self.buf[(self.head + self.count) % self.cap] = value;
            self.count += 1;
        }

        fn popBuf(self: *Self) T {
            std.debug.assert(self.cap > 0 and self.count > 0);
            const value = self.buf[self.head];
            self.head = (self.head + 1) % self.cap;
            self.count -= 1;
            return value;
        }

        // -- direct handoffs (skip the buffer entirely; also how unbuffered
        //    channels, cap == 0, always move values) --

        fn tryHandoffToReceiver(self: *Self, value: T, sp: *sched.Scheduler) bool {
            while (self.recvq.pop()) |w| {
                if (!claim(w)) continue;
                w.elem.* = value;
                w.ok.* = true;
                finish(w, sp);
                return true;
            }
            return false;
        }

        fn tryHandoffFromSender(self: *Self, value_out: *T, sp: *sched.Scheduler) bool {
            while (self.sendq.pop()) |w| {
                if (!claim(w)) continue;
                value_out.* = w.elem.*;
                w.ok.* = true;
                finish(w, sp);
                return true;
            }
            return false;
        }

        /// After popping a value out of the buffer, pull one blocked sender
        /// (if any — only possible when the buffer had been full) back into
        /// the freed slot, preserving FIFO order across buffered sends.
        fn promoteQueuedSender(self: *Self, sp: *sched.Scheduler) void {
            while (self.sendq.pop()) |w| {
                if (!claim(w)) continue;
                self.pushBuf(w.elem.*);
                w.ok.* = true;
                finish(w, sp);
                return;
            }
        }

        // -- must be called with self.lock held --

        fn attemptSend(self: *Self, value: T, sp: *sched.Scheduler) bool {
            if (self.tryHandoffToReceiver(value, sp)) return true;
            if (self.count < self.cap) {
                self.pushBuf(value);
                return true;
            }
            return false;
        }

        fn attemptRecv(self: *Self, value_out: *T, ok_out: *bool, sp: *sched.Scheduler) bool {
            if (self.count > 0) {
                value_out.* = self.popBuf();
                self.promoteQueuedSender(sp);
                ok_out.* = true;
                return true;
            }
            if (self.tryHandoffFromSender(value_out, sp)) {
                ok_out.* = true;
                return true;
            }
            if (self.closed) {
                value_out.* = std.mem.zeroes(T);
                ok_out.* = false;
                return true;
            }
            return false;
        }

        // -- public blocking API --

        pub fn send(self: *Self, sp: *sched.Scheduler, value: T) void {
            self.lock.acquire();
            if (self.closed) {
                self.lock.release();
                @panic("send on closed channel");
            }
            if (self.attemptSend(value, sp)) {
                self.lock.release();
                return;
            }
            self.lock.release();

            var mutable_value = value;
            var ok = false;
            var w: Waiter = .{ .elem = &mutable_value, .ok = &ok };
            var ctx: SetupCtx = .{ .self = self, .waiter = &w, .sched = sp };
            sched.park(sendParkSetup, &ctx);
            if (!ok) @panic("send on closed channel");
        }

        fn sendParkSetup(t: *sched.Task, arg: ?*anyopaque) void {
            const ctx: *SetupCtx = @ptrCast(@alignCast(arg.?));
            ctx.waiter.task = t;
            ctx.self.lock.acquire();
            if (ctx.self.closed) {
                ctx.self.lock.release();
                ctx.waiter.ok.* = false;
                Self.finish(ctx.waiter, ctx.sched);
                return;
            }
            if (ctx.self.attemptSend(ctx.waiter.elem.*, ctx.sched)) {
                ctx.self.lock.release();
                ctx.waiter.ok.* = true;
                Self.finish(ctx.waiter, ctx.sched);
                return;
            }
            ctx.self.sendq.push(ctx.waiter);
            ctx.self.lock.release();
        }

        /// Named (not an inline anonymous struct literal) so `recvNilable`
        /// can declare the identical return type: two separately-written
        /// `struct { value: T, ok: bool }` literals are distinct nominal
        /// types to Zig even when structurally identical, which previously
        /// broke `recvNilable`'s direct `return self.recv(sp)`.
        pub const RecvResult = struct { value: T, ok: bool };

        pub fn recv(self: *Self, sp: *sched.Scheduler) RecvResult {
            self.lock.acquire();
            var value: T = undefined;
            var ok: bool = undefined;
            if (self.attemptRecv(&value, &ok, sp)) {
                self.lock.release();
                return .{ .value = value, .ok = ok };
            }
            self.lock.release();

            var w: Waiter = .{ .elem = &value, .ok = &ok };
            var ctx: SetupCtx = .{ .self = self, .waiter = &w, .sched = sp };
            sched.park(recvParkSetup, &ctx);
            return .{ .value = value, .ok = ok };
        }

        fn recvParkSetup(t: *sched.Task, arg: ?*anyopaque) void {
            const ctx: *SetupCtx = @ptrCast(@alignCast(arg.?));
            ctx.waiter.task = t;
            ctx.self.lock.acquire();
            if (ctx.self.attemptRecv(ctx.waiter.elem, ctx.waiter.ok, ctx.sched)) {
                ctx.self.lock.release();
                Self.finish(ctx.waiter, ctx.sched);
                return;
            }
            ctx.self.recvq.push(ctx.waiter);
            ctx.self.lock.release();
        }

        pub fn close(self: *Self, sp: *sched.Scheduler) void {
            self.lock.acquire();
            if (self.closed) {
                self.lock.release();
                @panic("close of closed channel");
            }
            self.closed = true;
            while (self.recvq.pop()) |w| {
                if (!claim(w)) continue;
                w.elem.* = std.mem.zeroes(T);
                w.ok.* = false;
                finish(w, sp);
            }
            while (self.sendq.pop()) |w| {
                if (!claim(w)) continue;
                w.ok.* = false;
                finish(w, sp);
            }
            self.lock.release();
        }

        // -- nil-safe entry points: a nil `chan<T>` blocks forever on
        //    send/recv and panics on close (spec §16.2). ------------------

        pub fn sendNilable(maybe_self: ?*Self, sp: *sched.Scheduler, value: T) void {
            const self = maybe_self orelse {
                sched.park(null, null); // no setup: nothing will ever unpark this task.
                unreachable;
            };
            self.send(sp, value);
        }

        pub fn recvNilable(maybe_self: ?*Self, sp: *sched.Scheduler) RecvResult {
            const self = maybe_self orelse {
                sched.park(null, null);
                unreachable;
            };
            return self.recv(sp);
        }

        pub fn closeNilable(maybe_self: ?*Self, sp: *sched.Scheduler) void {
            const self = maybe_self orelse @panic("close of nil channel");
            self.close(sp);
        }

        // -- select case construction --

        fn vAddr(chan: *anyopaque) usize {
            return @intFromPtr(chan);
        }
        fn vLock(chan: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(chan));
            self.lock.acquire();
        }
        fn vUnlock(chan: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(chan));
            self.lock.release();
        }
        fn vTryRecv(chan: *anyopaque, elem: *anyopaque, ok: *bool, sp: *sched.Scheduler) bool {
            const self: *Self = @ptrCast(@alignCast(chan));
            const dest: *T = @ptrCast(@alignCast(elem));
            return self.attemptRecv(dest, ok, sp);
        }
        fn vTrySend(chan: *anyopaque, elem: *anyopaque, ok: *bool, sp: *sched.Scheduler) bool {
            const self: *Self = @ptrCast(@alignCast(chan));
            const src: *T = @ptrCast(@alignCast(elem));
            if (self.closed) {
                ok.* = false; // ready: will panic, exactly like a plain send.
                return true;
            }
            if (self.attemptSend(src.*, sp)) {
                ok.* = true;
                return true;
            }
            return false;
        }
        fn vEnqueueRecv(chan: *anyopaque, node: *anyopaque, task: *sched.Task, elem: *anyopaque, ok: *bool, sel: *SelectShared, case_idx: usize) void {
            const self: *Self = @ptrCast(@alignCast(chan));
            const w: *Waiter = @ptrCast(@alignCast(node));
            w.* = .{ .task = task, .elem = @ptrCast(@alignCast(elem)), .ok = ok, .select = sel, .case_idx = case_idx };
            self.recvq.push(w);
        }
        fn vEnqueueSend(chan: *anyopaque, node: *anyopaque, task: *sched.Task, elem: *anyopaque, ok: *bool, sel: *SelectShared, case_idx: usize) void {
            const self: *Self = @ptrCast(@alignCast(chan));
            const w: *Waiter = @ptrCast(@alignCast(node));
            w.* = .{ .task = task, .elem = @ptrCast(@alignCast(elem)), .ok = ok, .select = sel, .case_idx = case_idx };
            self.sendq.push(w);
        }
        fn vRemoveRecv(chan: *anyopaque, node: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(chan));
            self.recvq.remove(@ptrCast(@alignCast(node)));
        }
        fn vRemoveSend(chan: *anyopaque, node: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(chan));
            self.sendq.remove(@ptrCast(@alignCast(node)));
        }

        const vtable = ChanVTable{
            .addr = vAddr,
            .lock = vLock,
            .unlock = vUnlock,
            .tryRecv = vTryRecv,
            .trySend = vTrySend,
            .enqueueRecv = vEnqueueRecv,
            .enqueueSend = vEnqueueSend,
            .removeRecv = vRemoveRecv,
            .removeSend = vRemoveSend,
        };

        /// Build a `select` recv-case reading into `dest`, with validity
        /// reported through `ok_out` once the case fires.
        pub fn recvCase(self: *Self, dest: *T, ok_out: *bool) SelectCase {
            return .{ .dir = .recv, .chan = @ptrCast(self), .elem = @ptrCast(dest), .ok_out = ok_out, .vtable = &vtable };
        }

        /// Build a `select` send-case for `value`, already evaluated by the
        /// caller (spec: case operands are evaluated once, at entry).
        pub fn sendCase(self: *Self, value: *const T) SelectCase {
            return .{ .dir = .send, .chan = @ptrCast(self), .elem = @ptrCast(@constCast(value)), .vtable = &vtable };
        }

        /// Visits every currently-buffered element, in queue order, under the
        /// channel's own lock. A buffered value that is itself a GC reference
        /// is reachable only through this buffer while it sits unreceived —
        /// not from any stack — so `runtime/ABI.md` §11 has the GC's root
        /// scanner call this to keep such values alive. Read-only: `visit`
        /// must not block or re-enter the channel.
        pub fn forEachBuffered(self: *Self, visit: *const fn (T) void) void {
            self.lock.acquire();
            defer self.lock.release();
            var i: usize = 0;
            while (i < self.count) : (i += 1) visit(self.buf[(self.head + i) % self.cap]);
        }
    };
}

/// The ABI's one channel element type (ABI.md §11): every `chan<T>` in a Bit
/// program is realized at the runtime boundary as a channel of this single
/// 8-byte word, whatever `T` actually is. A `T` that fits in 8 bytes (every
/// integer width, `bool`, `f64`, and every reference type) is carried by
/// value, bit-reinterpreted; a `T` that does not fit is out of scope for v1
/// channels — box it in a GC object and send the (8-byte) reference instead.
/// This is what makes a single prebuilt `libbitrt.a` able to serve `chan<T>`
/// for every monomorphized `T` a Bit program ever declares, without the
/// runtime archive needing per-`T` instantiations it cannot know ahead of
/// time. Named `WordChan` (not `IntChan`) to stay clear of this file's own
/// unrelated per-test `IntChan` locals below.
pub const WordChan = Chan(u64);

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const builtin = @import("builtin");

fn sleepNs(ns: u64) void {
    const req: std.posix.timespec = .{
        .sec = @intCast(ns / std.time.ns_per_s),
        .nsec = @intCast(ns % std.time.ns_per_s),
    };
    switch (builtin.os.tag) {
        .linux => _ = std.os.linux.nanosleep(&req, null),
        else => _ = std.c.nanosleep(&req, null),
    }
}

/// Bounded-wait helper: turns an open-ended spin into a loop with a provable
/// upper bound (Power-of-10: every loop must be statically bounded).
const Deadline = struct {
    end_ns: u64,

    fn after(ns: u64) Deadline {
        return .{ .end_ns = sched.monoNs() + ns };
    }

    fn expired(self: Deadline) bool {
        return sched.monoNs() > self.end_ns;
    }
};

/// `Scheduler.start` stores a back-pointer to `s` in every worker, so `s`
/// must never move again — initialize it in place, not through a
/// return-by-value helper (which would move it to the caller's frame).
fn testScheduler(s: *sched.Scheduler, nthreads: usize) !void {
    s.* = try sched.Scheduler.init(nthreads);
    try s.start();
}

fn teardown(s: *sched.Scheduler) void {
    s.shutdown();
    s.join();
    s.deinit();
}

test "buffered channel: FIFO order and ring-buffer wraparound" {
    var s: sched.Scheduler = undefined;
    try testScheduler(&s, 1);
    defer teardown(&s);

    const IntChan = Chan(i64);
    var ch = try IntChan.init(3);
    defer ch.deinit();

    const Harness = struct {
        var ch_ptr: *IntChan = undefined;
        var sp: *sched.Scheduler = undefined;
        var ok_count: std.atomic.Value(usize) = .init(0);
        var done: std.atomic.Value(bool) = .init(false);

        fn run(_: ?*anyopaque) callconv(.c) void {
            // Fill to capacity, drain, then wrap the ring buffer around at
            // least once — exercises `head`/`count` modulo arithmetic.
            var sent: i64 = 0;
            while (sent < 9) : (sent += 1) {
                ch_ptr.send(sp, sent);
                if (@mod(sent, 3) == 2) { // buffer is full every 3rd send: drain 3
                    var i: i64 = 0;
                    while (i < 3) : (i += 1) {
                        const r = ch_ptr.recv(sp);
                        if (r.ok and r.value == sent - 2 + i) _ = ok_count.fetchAdd(1, .monotonic);
                    }
                }
            }
            done.store(true, .release);
        }
    };
    Harness.ch_ptr = &ch;
    Harness.sp = &s;

    try s.spawn(Harness.run, null);

    const deadline = Deadline.after(5 * std.time.ns_per_s);
    while (!Harness.done.load(.acquire)) {
        if (deadline.expired()) return error.Timeout;
        sleepNs(10_000);
    }
    try testing.expectEqual(@as(usize, 9), Harness.ok_count.load(.monotonic));
}

test "unbuffered channel: producer/consumer, 1,000,000 messages, no loss or reorder" {
    var s: sched.Scheduler = undefined;
    try testScheduler(&s, 4);
    defer teardown(&s);

    const IntChan = Chan(u64);
    var ch = try IntChan.init(0);
    defer ch.deinit();

    const total: u64 = 1_000_000;
    const Harness = struct {
        var ch_ptr: *IntChan = undefined;
        var sp: *sched.Scheduler = undefined;
        var received: u64 = 0;
        var in_order: bool = true;
        var done: std.atomic.Value(bool) = .init(false);

        fn produce(_: ?*anyopaque) callconv(.c) void {
            var i: u64 = 0;
            while (i < total) : (i += 1) ch_ptr.send(sp, i);
        }

        fn consume(_: ?*anyopaque) callconv(.c) void {
            var i: u64 = 0;
            while (i < total) : (i += 1) {
                const r = ch_ptr.recv(sp);
                if (!r.ok or r.value != i) in_order = false;
                received += 1;
            }
            done.store(true, .release);
        }
    };
    Harness.ch_ptr = &ch;
    Harness.sp = &s;

    try s.spawn(Harness.produce, null);
    try s.spawn(Harness.consume, null);

    const deadline = Deadline.after(60 * std.time.ns_per_s);
    while (!Harness.done.load(.acquire)) {
        if (deadline.expired()) return error.Timeout;
        sleepNs(1_000_000);
    }
    try testing.expectEqual(total, Harness.received);
    try testing.expect(Harness.in_order);
}

test "select: one ready among three fires the correct arm" {
    var s: sched.Scheduler = undefined;
    try testScheduler(&s, 1);
    defer teardown(&s);

    const IntChan = Chan(i32);
    var a = try IntChan.init(1);
    defer a.deinit();
    var b = try IntChan.init(1);
    defer b.deinit();
    var c = try IntChan.init(1);
    defer c.deinit();

    const Harness = struct {
        var a_ptr: *IntChan = undefined;
        var b_ptr: *IntChan = undefined;
        var c_ptr: *IntChan = undefined;
        var sp: *sched.Scheduler = undefined;
        var fired: usize = undefined;
        var value: i32 = undefined;
        var ok: bool = undefined;
        var done: std.atomic.Value(bool) = .init(false);

        fn run(_: ?*anyopaque) callconv(.c) void {
            b_ptr.send(sp, 42); // only B has a value ready; A and C are empty.
            var dest_a: i32 = undefined;
            var dest_b: i32 = undefined;
            var dest_c: i32 = undefined;
            var ok_a: bool = undefined;
            var ok_c: bool = undefined;
            const cases = [_]SelectCase{
                a_ptr.recvCase(&dest_a, &ok_a),
                b_ptr.recvCase(&dest_b, &ok),
                c_ptr.recvCase(&dest_c, &ok_c),
            };
            const result = select(sp, &cases, false);
            fired = result.fired;
            value = dest_b;
            done.store(true, .release);
        }
    };
    Harness.a_ptr = &a;
    Harness.b_ptr = &b;
    Harness.c_ptr = &c;
    Harness.sp = &s;

    try s.spawn(Harness.run, null);

    const deadline = Deadline.after(5 * std.time.ns_per_s);
    while (!Harness.done.load(.acquire)) {
        if (deadline.expired()) return error.Timeout;
        sleepNs(10_000);
    }
    try testing.expectEqual(@as(usize, 1), Harness.fired); // B is case index 1
    try testing.expect(Harness.ok);
    try testing.expectEqual(@as(i32, 42), Harness.value);
}

test "close: wakes every blocked receiver with (zero, false)" {
    var s: sched.Scheduler = undefined;
    try testScheduler(&s, 4);
    defer teardown(&s);

    const IntChan = Chan(i32);
    var ch = try IntChan.init(0);
    defer ch.deinit();

    const nreceivers = 16;
    const Harness = struct {
        var ch_ptr: *IntChan = undefined;
        var sp: *sched.Scheduler = undefined;
        var started: std.atomic.Value(usize) = .init(0);
        var woke_correctly: std.atomic.Value(usize) = .init(0);

        fn receive(_: ?*anyopaque) callconv(.c) void {
            _ = started.fetchAdd(1, .monotonic);
            const r = ch_ptr.recv(sp);
            if (!r.ok and r.value == 0) _ = woke_correctly.fetchAdd(1, .monotonic);
        }
    };
    Harness.ch_ptr = &ch;
    Harness.sp = &s;

    var i: usize = 0;
    while (i < nreceivers) : (i += 1) try s.spawn(Harness.receive, null);

    var deadline = Deadline.after(5 * std.time.ns_per_s);
    while (Harness.started.load(.acquire) < nreceivers) {
        if (deadline.expired()) return error.Timeout;
        sleepNs(10_000);
    }
    sleepNs(50 * std.time.ns_per_ms); // let every receiver actually reach `park`

    ch.close(&s);

    deadline = Deadline.after(5 * std.time.ns_per_s);
    while (Harness.woke_correctly.load(.acquire) < nreceivers) {
        if (deadline.expired()) return error.Timeout;
        sleepNs(10_000);
    }
    try testing.expectEqual(@as(usize, nreceivers), Harness.woke_correctly.load(.monotonic));
}

test "stress: many senders and receivers, total count conserved" {
    var s: sched.Scheduler = undefined;
    try testScheduler(&s, 8);
    defer teardown(&s);

    const IntChan = Chan(u32);
    var ch = try IntChan.init(32);
    defer ch.deinit();

    const nsenders = 8;
    const nreceivers = 8;
    const per_sender = 20_000;
    const total = nsenders * per_sender;

    const Harness = struct {
        var ch_ptr: *IntChan = undefined;
        var sp: *sched.Scheduler = undefined;
        var sent: std.atomic.Value(usize) = .init(0);
        var received: std.atomic.Value(usize) = .init(0);
        var checksum: std.atomic.Value(u64) = .init(0);

        fn send(_: ?*anyopaque) callconv(.c) void {
            var i: u32 = 0;
            while (i < per_sender) : (i += 1) {
                ch_ptr.send(sp, i);
                _ = sent.fetchAdd(1, .monotonic);
            }
        }

        // Drains until `close` (called once every sender is done) marks the
        // channel closed and the buffer is drained — the standard fan-in
        // shutdown, and the only deadlock-free way to end a receiver whose
        // channel might otherwise still have more values coming.
        fn recv(_: ?*anyopaque) callconv(.c) void {
            while (true) {
                const r = ch_ptr.recv(sp);
                if (!r.ok) return;
                _ = checksum.fetchAdd(r.value, .monotonic);
                _ = received.fetchAdd(1, .monotonic);
            }
        }
    };
    Harness.ch_ptr = &ch;
    Harness.sp = &s;

    var i: usize = 0;
    while (i < nsenders) : (i += 1) try s.spawn(Harness.send, null);
    while (i < nsenders + nreceivers) : (i += 1) try s.spawn(Harness.recv, null);

    var deadline = Deadline.after(30 * std.time.ns_per_s);
    while (Harness.sent.load(.acquire) < total) {
        if (deadline.expired()) return error.Timeout;
        sleepNs(1_000_000);
    }
    ch.close(&s);

    deadline = Deadline.after(30 * std.time.ns_per_s);
    while (Harness.received.load(.acquire) < total) {
        if (deadline.expired()) return error.Timeout;
        sleepNs(1_000_000);
    }
    try testing.expectEqual(@as(usize, total), Harness.received.load(.monotonic));

    var expected_checksum: u64 = 0;
    var v: u32 = 0;
    while (v < per_sender) : (v += 1) expected_checksum += v;
    expected_checksum *= nsenders;
    try testing.expectEqual(expected_checksum, Harness.checksum.load(.monotonic));
}
