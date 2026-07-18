//! Minimal spinlock for rare, O(1)-ish critical sections shared across the
//! freestanding runtime (the scheduler's global run queue and registry, channel
//! send/recv/close in `chan.zig`, the allocator's free lists in `alloc.zig`).
//! Never held across a blocking call or a green-thread context switch, so
//! spinning (rather than a futex/condvar) is both simple and correct — and keeps
//! the runtime free of libc threading primitives. One implementation so no module
//! hand-rolls its own; it lives in its own file so even the lowest layer
//! (`alloc.zig`) can use it without importing the scheduler.

const std = @import("std");

pub const SpinLock = struct {
    locked: std.atomic.Value(bool) = .init(false),

    pub fn acquire(self: *SpinLock) void {
        while (self.locked.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
            std.atomic.spinLoopHint();
        }
    }

    /// One attempt, no spinning: true if this call took the lock. For callers
    /// that have something better to do than wait — the GC's stop-the-world
    /// entry (ABI.md §5) parks itself instead of spinning here, because a
    /// thread spinning for the lock is a thread the lock's winner is waiting on.
    pub fn tryAcquire(self: *SpinLock) bool {
        return self.locked.cmpxchgStrong(false, true, .acquire, .monotonic) == null;
    }

    pub fn release(self: *SpinLock) void {
        self.locked.store(false, .release);
    }
};
