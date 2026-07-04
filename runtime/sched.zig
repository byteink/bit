//! M:N green-thread scheduler: goroutine-equivalent `rt_spawn`, a fixed pool of
//! OS worker threads (GOMAXPROCS-style), per-worker work-stealing run queues,
//! and a netpoller integration point so a green thread blocked on I/O never
//! blocks the OS thread underneath it.
//!
//! Model (matches Go's M:N scheduler, simplified):
//!   - `Task` is one green thread: a fixed-size stack plus a saved CPU context.
//!   - `Worker` is one OS thread running a scheduling loop; it owns a local
//!     work-stealing run queue and, when idle, steals from other workers,
//!     drains the global overflow queue, then polls the netpoller.
//!   - `Scheduler` owns the fixed worker pool and the queues/poller shared
//!     across them.
//!
//! Context switch is hand-written asm per arch (x86-64, ARM64): it threads a
//! `*const Switch` message through a callee-clobbering inline-asm block rather
//! than manually saving callee-saved registers, so the compiler's own register
//! allocator does the spilling. Only `sp`/`fp`/`pc` are explicitly saved. This
//! technique is proven in this exact toolchain — it is the same shape as Zig
//! 0.16's own `std.Io.fiber` implementation — adapted here so the runtime has
//! no dependency on that internal, non-public API.
//!
//! ponytail: fixed 64KB stacks with a guard page, v1. Segmented/growable
//! stacks land when a real program overflows one; the guard page turns that
//! into a clean crash today instead of silent corruption.
//!
//! ponytail: idle workers poll with bounded exponential backoff instead of a
//! futex/condvar wake. Zig 0.16 moved Mutex/Condition behind the new `Io`
//! interface (needs an `Io` instance injected everywhere), and a from-scratch
//! futex wrapper would need private syscalls on Darwin — not worth the risk
//! for v1. Backoff is correct (pure polling, no missed-wakeup window) and
//! bounded; upgrade path is a futex-based wake if idle latency ever matters.
//!
//! ponytail: v1 is POSIX only (Linux + Darwin), matching the precedent already
//! set by `gc.zig`'s environment config. Windows lands when a target needs it.
//!
//! Scope boundary: the scheduler allocates its own bookkeeping (workers, task
//! control blocks, stacks) directly from the OS, never through the GC heap in
//! `alloc.zig`/`gc.zig`. Those remain single-threaded (see their own ponytail
//! notes) until a separate ticket makes them thread-safe; user code allocating
//! GC objects concurrently from multiple green threads is out of scope here.

const std = @import("std");
const builtin = @import("builtin");

comptime {
    switch (builtin.os.tag) {
        .linux, .macos, .ios, .tvos, .watchos, .visionos => {},
        else => @compileError("runtime/sched.zig v1 targets Linux and Darwin only; see runtime/ABI.md §9"),
    }
    switch (builtin.cpu.arch) {
        .x86_64, .aarch64 => {},
        else => @compileError("runtime/sched.zig v1 has context-switch asm for x86-64 and ARM64 only"),
    }
}

// ---------------------------------------------------------------------------
// Context switch (hand-written asm, x86-64 + ARM64)
// ---------------------------------------------------------------------------

/// Saved CPU state of an inactive fiber (task or worker scheduling loop).
/// Only the registers needed to resume execution are threaded explicitly;
/// everything else is clobbered and left to the compiler to spill/reload
/// around the switch (see module doc comment).
const Context = switch (builtin.cpu.arch) {
    .x86_64 => extern struct { sp: u64 = 0, fp: u64 = 0, pc: u64 = 0 },
    // AArch64 additionally saves `x30` (the link register): unlike x86-64,
    // where the return address lives on the stack, on AArch64 the compiler can
    // and does keep a live value in `x30` across the switch, and an inline-asm
    // *clobber* of `x30` is not reliably honored by LLVM — so the switch must
    // preserve it explicitly (like `fp`), not merely declare it clobbered.
    .aarch64 => extern struct { sp: u64 = 0, fp: u64 = 0, pc: u64 = 0, lr: u64 = 0 },
    else => unreachable, // gated by the comptime check above
};

const Switch = extern struct { old: *Context, new: *Context };

/// Save the caller's CPU state into `s.old`, restore `s.new`, and jump there.
/// Returns when some other switch later resumes `s.old` — the return value is
/// the `Switch` that resumer passed, so the resumed side learns who resumed it
/// and with what message, entirely via register passing (no shared memory).
///
/// `fp`/`rbp` is written directly by register name in the asm body below, not
/// through a declared operand, so it must also appear in the clobber list —
/// otherwise the register allocator has no way to know this block touches it
/// and may keep a live value there across the call, which the asm then
/// silently stomps.
inline fn contextSwitch(s: *const Switch) *const Switch {
    return switch (builtin.cpu.arch) {
        .aarch64 => asm volatile (
            \\ ldp x0, x2, [x1]
            \\ ldr x3, [x2, #16]
            \\ mov x4, sp
            \\ stp x4, fp, [x0]
            \\ str x30, [x0, #24]
            \\ adr x5, 0f
            \\ ldp x4, fp, [x2]
            \\ ldr x30, [x2, #24]
            \\ str x5, [x0, #16]
            \\ mov sp, x4
            \\ br x3
            \\0:
            : [received_message] "={x1}" (-> *const Switch),
            : [message_to_send] "{x1}" (s),
            // `x30` is deliberately NOT clobbered: the switch saves and restores
            // it (offset 24 in `Context`), so it is genuinely preserved across
            // the switch — declaring it clobbered instead is what previously
            // let LLVM stash a live `Worker*` there and lose it on resume.
            : .{
                .x0 = true,  .x2 = true,  .x3 = true,  .x4 = true,  .x5 = true,
                .x6 = true,  .x7 = true,  .x8 = true,  .x9 = true,  .x10 = true,
                .x11 = true, .x12 = true, .x13 = true, .x14 = true, .x15 = true,
                .x16 = true, .x17 = true, .x19 = true, .x20 = true, .x21 = true,
                .x22 = true, .x23 = true, .x24 = true, .x25 = true, .x26 = true,
                .x27 = true, .x28 = true, .x29 = true, .memory = true,
            }),
        .x86_64 => asm volatile (
            \\ movq 0(%%rsi), %%rax
            \\ movq 8(%%rsi), %%rcx
            \\ leaq 0f(%%rip), %%rdx
            \\ movq %%rsp, 0(%%rax)
            \\ movq %%rbp, 8(%%rax)
            \\ movq %%rdx, 16(%%rax)
            \\ movq 0(%%rcx), %%rsp
            \\ movq 8(%%rcx), %%rbp
            \\ jmpq *16(%%rcx)
            \\0:
            : [received_message] "={rsi}" (-> *const Switch),
            : [message_to_send] "{rsi}" (s),
            : .{
                .rax = true, .rcx = true, .rdx = true, .rbx = true, .rdi = true,
                .r8 = true,  .r9 = true,  .r10 = true, .r11 = true, .r12 = true,
                .r13 = true, .r14 = true, .r15 = true, .rbp = true, .memory = true,
            }),
        else => unreachable,
    };
}

// ---------------------------------------------------------------------------
// Task: one green thread
// ---------------------------------------------------------------------------

/// `callconv(.c)`: a spawned task's body eventually runs codegen-emitted
/// (non-Zig) machine code, and `root.zig`'s `bit_rt_spawn` takes this exact
/// type as one of its two ABI-facing parameters (`runtime/ABI.md` §9) — a
/// plain-Zig-callconv function pointer has no cross-language-stable ABI to
/// promise there.
pub const TaskFn = *const fn (arg: ?*anyopaque) callconv(.c) void;

pub const TaskState = enum(u8) { runnable, running, parked, done };

/// Runs on a worker's own thread, after a parked task's context is safely
/// saved, to make the task visible to whatever will wake it (register it with
/// the netpoller, link it onto a channel wait queue, ...). See `park`'s doc
/// comment for why this must not run on the task's own side of the switch.
pub const ParkFn = *const fn (t: *Task, arg: ?*anyopaque) void;

/// v1 fixed stack size. See the module doc comment's ponytail note.
const stack_size: usize = 64 * 1024;

pub const Task = struct {
    fn_ptr: TaskFn,
    arg: ?*anyopaque,
    /// Full mapping including the guard page, kept only to unmap on destroy.
    mapping: []align(std.heap.page_size_min) u8,
    ctx: Context = .{},
    /// Cross-thread-visible only at the `.parked` transition (see `park`'s
    /// doc comment); `.runnable`/`.done` are decided and acted on entirely by
    /// the owning worker's own thread and need no atomicity for that.
    state: std.atomic.Value(TaskState) = .init(.runnable),
    /// Intrusive link; owned by whichever queue currently holds the task.
    next: ?*Task = null,

    fn create(f: TaskFn, arg: ?*anyopaque) !*Task {
        const t = try std.heap.page_allocator.create(Task);
        errdefer std.heap.page_allocator.destroy(t);
        const mapping = try mapGuardedStack(stack_size);
        errdefer unmapGuardedStack(mapping);
        const top = @intFromPtr(mapping.ptr) + mapping.len;
        t.* = .{
            .fn_ptr = f,
            .arg = arg,
            .mapping = mapping,
            .ctx = initialContext(top),
        };
        return t;
    }

    fn destroy(t: *Task) void {
        unmapGuardedStack(t.mapping);
        std.heap.page_allocator.destroy(t);
    }
};

fn initialContext(stack_top: usize) Context {
    // The switch asm jumps straight to `pc` as if it were a fresh call entry.
    // x86-64 assumes a return address was just pushed (rsp % 16 == 8); AAPCS64
    // has no such assumption and just requires sp 16-aligned, which the raw
    // mapping top already is (page-aligned, stack_size a multiple of 16).
    return switch (builtin.cpu.arch) {
        .x86_64 => .{ .sp = stack_top - 8, .fp = 0, .pc = @intFromPtr(&trampoline) },
        // A fresh task enters `trampoline` by a plain jump; it never returns via
        // `x30`, so the initial link register is just 0.
        .aarch64 => .{ .sp = stack_top, .fp = 0, .pc = @intFromPtr(&trampoline), .lr = 0 },
        else => unreachable,
    };
}

/// Entry point for every fresh task. Reached by jumping directly to its
/// address (never `call`ed), so it takes no arguments — it recovers the task
/// to run from the resuming worker's thread-local, set right before switch.
fn trampoline() callconv(.c) noreturn {
    const t = Worker.current().running.?;
    t.fn_ptr(t.arg);
    // Re-fetch the worker instead of reusing one captured before `fn_ptr` ran:
    // the task body may have parked (e.g. on the netpoller) and been resumed
    // by a *different* worker OS thread. Using a pre-park worker here would
    // flip that other worker's `next_disposition` and switch this OS thread
    // into its abandoned `sched_ctx` — a wild jump once that worker has since
    // exited and its stack is gone.
    const w = Worker.current();
    w.next_disposition = .done;
    _ = contextSwitch(&.{ .old = &t.ctx, .new = &w.sched_ctx });
    unreachable; // a done task is never resumed
}

/// Voluntarily yield the CPU: the calling task becomes runnable again and is
/// requeued, and the worker picks its next task. Must be called from task code
/// running on a worker.
pub fn yield() void {
    const w = Worker.current();
    const t = w.running.?;
    w.next_disposition = .runnable;
    _ = contextSwitch(&.{ .old = &t.ctx, .new = &w.sched_ctx });
}

/// Park the calling task: it stops running and is NOT requeued automatically.
///
/// `setup`, if given, runs on the *worker's* thread immediately after this
/// call returns control to `Worker.run` — i.e. strictly after `contextSwitch`
/// has finished saving this task's context. That ordering is required, not
/// just tidy: `contextSwitch` writes `t.ctx` on this task's own core, and only
/// after `Worker.run` resumes (same core, same thread, so the write is
/// trivially ordered before anything it does next) is it safe to let another
/// thread learn about `t` at all. `setup` is that safe place to register `t`
/// with a netpoller or a channel's wait queue — doing that registration here,
/// before the switch, would let another thread try to resume `t.ctx` before
/// it was actually saved, a live-instructions-vs-stale-context race.
///
/// A park with no matching `unpark` (called directly, or triggered by `setup`
/// registering a wake source) leaks the task forever. Must be called from
/// task code running on a worker.
pub fn park(setup: ?ParkFn, arg: ?*anyopaque) void {
    const w = Worker.current();
    const t = w.running.?;
    w.next_disposition = .parked;
    w.park_setup = setup;
    w.park_setup_arg = arg;
    _ = contextSwitch(&.{ .old = &t.ctx, .new = &w.sched_ctx });
}

/// Make a parked task runnable again, from any thread. Routes through the
/// global queue since the caller may not be a worker at all. The CAS both
/// checks the precondition and performs the visible transition atomically —
/// a plain check-then-store would leave a window for a double-unpark to race
/// itself onto the queue twice.
///
/// Success order is `.acq_rel`, not `.release`: this CAS must *acquire* the
/// parking thread's release (step 2 in `park`'s doc comment) to actually see
/// its `t.ctx` writes — a release-only success order publishes this thread's
/// own writes but does not synchronize-with the other side, which is the
/// half that matters here.
pub fn unpark(sched: *Scheduler, t: *Task) void {
    if (t.state.cmpxchgStrong(.parked, .runnable, .acq_rel, .monotonic) != null) {
        std.debug.panic("unpark: task was not parked", .{});
    }
    sched.global.push(t);
}

// ---------------------------------------------------------------------------
// Guarded stack mapping
// ---------------------------------------------------------------------------

fn mapGuardedStack(size: usize) ![]align(std.heap.page_size_min) u8 {
    const ps = std.heap.pageSize();
    const usable = std.mem.alignForward(usize, size, ps);
    const total = ps + usable; // one leading guard page + usable stack
    const mem = try std.posix.mmap(
        null,
        total,
        std.posix.PROT{}, // PROT_NONE: nothing is accessible until mprotect below
        std.posix.MAP{ .TYPE = .PRIVATE, .ANONYMOUS = true },
        -1,
        0,
    );
    errdefer std.posix.munmap(mem);
    // `ps` is the runtime page size, always a multiple of `page_size_min`, so
    // the slice past the guard page keeps at least `page_size_min` alignment.
    try protect(@alignCast(mem[ps..]), std.posix.PROT{ .READ = true, .WRITE = true });
    return mem;
}

fn unmapGuardedStack(mem: []align(std.heap.page_size_min) u8) void {
    std.posix.munmap(mem);
}

fn protect(mem: []align(std.heap.page_size_min) u8, prot: std.posix.PROT) !void {
    switch (builtin.os.tag) {
        .linux => {
            const rc = std.os.linux.mprotect(mem.ptr, mem.len, prot);
            switch (std.posix.errno(rc)) {
                .SUCCESS => {},
                else => return error.PermissionDenied,
            }
        },
        else => { // Darwin family, per the comptime os gate above
            const rc = std.c.mprotect(@ptrCast(mem.ptr), mem.len, prot);
            if (rc != 0) return error.PermissionDenied;
        },
    }
}

// `posix.zig` in this Zig version does not wrap `close`/`write` (mid-move to
// the new `Io` interface, which this freestanding runtime does not depend on
// — see the module doc comment); call the raw syscalls directly instead.

fn closeFd(fd: std.posix.fd_t) void {
    switch (builtin.os.tag) {
        .linux => _ = std.os.linux.close(fd),
        else => _ = std.c.close(fd),
    }
}

/// `pub`: also used by `root.zig`'s panic protocol to write to stderr without
/// a libc dependency (same rationale as this file's own use below).
pub fn writeFd(fd: std.posix.fd_t, buf: []const u8) !usize {
    switch (builtin.os.tag) {
        .linux => {
            const rc = std.os.linux.write(fd, buf.ptr, buf.len);
            switch (std.posix.errno(rc)) {
                .SUCCESS => return rc,
                else => return error.WriteFailed,
            }
        },
        else => {
            const rc = std.c.write(fd, buf.ptr, buf.len);
            if (rc < 0) return error.WriteFailed;
            return @intCast(rc);
        },
    }
}

/// Monotonic clock in nanoseconds. `std.time.Timer` moved behind the new `Io`
/// interface in this Zig version (see the module doc comment on why this
/// runtime doesn't depend on `Io`); read `CLOCK_MONOTONIC` directly instead.
/// `pub` so other runtime modules (e.g. `chan.zig`'s `select` fairness seed)
/// don't need their own copy of this platform-branching syscall wrapper.
pub fn monoNs() u64 {
    var ts: std.posix.timespec = undefined;
    switch (builtin.os.tag) {
        .linux => _ = std.os.linux.clock_gettime(.MONOTONIC, &ts),
        else => _ = std.c.clock_gettime(.MONOTONIC, &ts),
    }
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

/// `pub`: also used by `root.zig`'s boot sequence to poll for the main task's
/// completion (same raw-syscall rationale as this file's own use below).
pub fn sleepNs(ns: u64) void {
    const req: std.posix.timespec = .{
        .sec = @intCast(ns / std.time.ns_per_s),
        .nsec = @intCast(ns % std.time.ns_per_s),
    };
    switch (builtin.os.tag) {
        .linux => _ = std.os.linux.nanosleep(&req, null),
        else => _ = std.c.nanosleep(&req, null),
    }
}

// ---------------------------------------------------------------------------
// Per-worker local run queue (fixed-capacity, work-stealing)
// ---------------------------------------------------------------------------

/// Bounded array deque, Go-runtime style: the owner exclusively appends at
/// `tail`; both the owner's own pop and other workers' steals contend for
/// `head` via CAS. Simpler to prove correct than a full Chase-Lev deque (the
/// owner's pop is not lock-free in the uncontended case) at negligible cost —
/// an uncontended CAS is a single instruction. Overflow spills to the
/// scheduler's global queue, so capacity need not be provably sufficient.
const Deque = struct {
    const capacity = 256; // power of two
    const mask = capacity - 1;

    buf: [capacity]?*Task = [_]?*Task{null} ** capacity,
    head: std.atomic.Value(usize) = .init(0),
    tail: std.atomic.Value(usize) = .init(0),

    /// Owner-only. False if full; caller must fall back to the global queue.
    fn pushBottom(self: *Deque, t: *Task) bool {
        const h = self.head.load(.acquire);
        const tl = self.tail.load(.monotonic); // only the owner writes tail
        if (tl - h >= capacity) return false;
        self.buf[tl & mask] = t;
        self.tail.store(tl + 1, .release);
        return true;
    }

    /// Owner-only pop; contends with `steal` on `head`.
    fn popBottom(self: *Deque) ?*Task {
        while (true) {
            const h = self.head.load(.acquire);
            const tl = self.tail.load(.monotonic);
            if (h == tl) return null;
            const t = self.buf[h & mask].?;
            if (self.head.cmpxchgStrong(h, h + 1, .acq_rel, .monotonic) == null) return t;
        }
    }

    /// Callable from any other worker.
    fn steal(self: *Deque) ?*Task {
        while (true) {
            const h = self.head.load(.acquire);
            const tl = self.tail.load(.acquire);
            if (h == tl) return null;
            const t = self.buf[h & mask].?;
            if (self.head.cmpxchgStrong(h, h + 1, .acq_rel, .monotonic) == null) return t;
        }
    }
};

/// Minimal spinlock for rare, O(1)-ish critical sections (the global run queue
/// here; channel send/recv/close in `chan.zig`). Never held across a blocking
/// call or a context switch, so spinning (rather than a futex/condvar) is both
/// simple and correct. `pub` so other runtime modules share one implementation
/// instead of hand-rolling their own.
pub const SpinLock = struct {
    locked: std.atomic.Value(bool) = .init(false),

    pub fn acquire(self: *SpinLock) void {
        while (self.locked.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
            std.atomic.spinLoopHint();
        }
    }

    pub fn release(self: *SpinLock) void {
        self.locked.store(false, .release);
    }
};

/// Overflow queue shared by all workers: spilled local-queue pushes, tasks
/// unparked from another thread, and tasks woken by the netpoller all land
/// here since the target worker isn't known (or isn't a worker at all).
const GlobalQueue = struct {
    lock: SpinLock = .{},
    head: ?*Task = null,
    tail: ?*Task = null,

    fn push(self: *GlobalQueue, t: *Task) void {
        t.next = null;
        self.lock.acquire();
        defer self.lock.release();
        if (self.tail) |tl| tl.next = t else self.head = t;
        self.tail = t;
    }

    fn pop(self: *GlobalQueue) ?*Task {
        self.lock.acquire();
        defer self.lock.release();
        const t = self.head orelse return null;
        self.head = t.next;
        if (self.head == null) self.tail = null;
        t.next = null;
        return t;
    }
};

// ---------------------------------------------------------------------------
// Netpoller integration point
// ---------------------------------------------------------------------------

pub const Interest = enum { read, write };

/// Non-blocking I/O readiness source: kqueue on Darwin, epoll on Linux. A
/// blocking-syscall wrapper (future stdlib `io` package) registers its fd and
/// interest here, then calls `park()`; when the fd becomes ready the poller
/// unparks the waiting task back onto the global queue. This is the
/// integration *point* — v1 does not implement non-blocking read/write
/// wrappers themselves, only the registration/wake mechanism they need.
///
/// Registration is one-shot (matches `EV_ONESHOT`/`EPOLLONESHOT`): a woken
/// task must re-register before parking on the same fd again.
pub const NetPoller = struct {
    fd: std.posix.fd_t,
    /// Non-blocking mutual exclusion around the actual poll syscall. Every
    /// idle worker calls `pollReady` from its own findWork loop; without this,
    /// two workers can both be inside epoll_wait/kevent on the same shared,
    /// level-triggered oneshot fd right as it becomes ready, and the kernel
    /// can report the same ready event to both before oneshot disarms it.
    /// That double-unparks one task: the second delivery lands on a `Task`
    /// the first delivery's worker has already run to completion and freed,
    /// a use-after-free. Losing this race costs nothing — the loser has
    /// other work to look for this round — so a try-lock (not a blocking
    /// one) is the right shape here.
    polling: std.atomic.Value(bool) = .init(false),

    fn init() !NetPoller {
        return .{ .fd = try createPollFd() };
    }

    fn deinit(self: *NetPoller) void {
        closeFd(self.fd);
    }

    /// Register `task` to be woken when `fd` is ready for `interest`.
    pub fn register(self: *NetPoller, fd: std.posix.fd_t, interest: Interest, task: *Task) !void {
        switch (builtin.os.tag) {
            .linux => {
                const io_bit: u32 = if (interest == .read) std.os.linux.EPOLL.IN else std.os.linux.EPOLL.OUT;
                var ev: std.os.linux.epoll_event = .{
                    .events = io_bit | std.os.linux.EPOLL.ONESHOT,
                    .data = .{ .ptr = @intFromPtr(task) },
                };
                const rc = std.os.linux.epoll_ctl(self.fd, std.os.linux.EPOLL.CTL_ADD, fd, &ev);
                switch (std.posix.errno(rc)) {
                    .SUCCESS => {},
                    else => return error.RegisterFailed,
                }
            },
            else => {
                var ev: std.c.Kevent = .{
                    .ident = @intCast(fd),
                    .filter = if (interest == .read) std.c.EVFILT.READ else std.c.EVFILT.WRITE,
                    .flags = std.c.EV.ADD | std.c.EV.ONESHOT,
                    .fflags = 0,
                    .data = 0,
                    .udata = @intFromPtr(task),
                };
                const empty: [0]std.c.Kevent = .{};
                const rc = std.c.kevent(self.fd, (&ev)[0..1].ptr, 1, &empty, 0, null);
                if (rc < 0) return error.RegisterFailed;
            },
        }
    }

    /// Non-blocking (or `timeout_ms`-bounded) drain of ready events; each
    /// ready task is unparked onto `sched`'s global queue. Returns the count
    /// woken. Safe to call from any worker's idle loop — at most one caller
    /// actually polls at a time (see `polling`'s doc comment); the rest
    /// return 0 immediately rather than wait.
    pub fn pollReady(self: *NetPoller, sched: *Scheduler, timeout_ms: i32) usize {
        if (self.polling.cmpxchgStrong(false, true, .acquire, .monotonic) != null) return 0;
        defer self.polling.store(false, .release);
        const max_batch = 64; // bounded per call; more ready events wait for the next poll
        switch (builtin.os.tag) {
            .linux => {
                var events: [max_batch]std.os.linux.epoll_event = undefined;
                const rc = std.os.linux.epoll_wait(self.fd, &events, max_batch, timeout_ms);
                switch (std.posix.errno(rc)) {
                    .SUCCESS => {},
                    else => return 0,
                }
                for (events[0..rc]) |ev| {
                    const t: *Task = @ptrFromInt(ev.data.ptr);
                    unpark(sched, t);
                }
                return rc;
            },
            else => {
                var events: [max_batch]std.c.Kevent = undefined;
                const ts: std.posix.timespec = .{
                    .sec = @intCast(@divTrunc(timeout_ms, std.time.ms_per_s)),
                    .nsec = @intCast(@mod(timeout_ms, std.time.ms_per_s) * std.time.ns_per_ms),
                };
                const empty: [0]std.c.Kevent = .{};
                const rc = std.c.kevent(self.fd, &empty, 0, &events, max_batch, &ts);
                if (rc < 0) return 0;
                const n: usize = @intCast(rc);
                for (events[0..n]) |ev| {
                    const t: *Task = @ptrFromInt(ev.udata);
                    unpark(sched, t);
                }
                return n;
            },
        }
    }
};

fn createPollFd() !std.posix.fd_t {
    switch (builtin.os.tag) {
        .linux => {
            const rc = std.os.linux.epoll_create1(0);
            switch (std.posix.errno(rc)) {
                .SUCCESS => return @intCast(rc),
                else => return error.PollerInitFailed,
            }
        },
        else => {
            const rc = std.c.kqueue();
            if (rc < 0) return error.PollerInitFailed;
            return rc;
        },
    }
}

// ---------------------------------------------------------------------------
// Worker: one OS thread running the scheduling loop
// ---------------------------------------------------------------------------

const min_backoff_ns: u64 = 1_000; // 1us
const max_backoff_ns: u64 = 1_000_000; // 1ms

const Worker = struct {
    /// Set by `Scheduler.start` after the array has its final, stable address
    /// — never at a point where `&scheduler_value` could later move.
    sched: *Scheduler = undefined,
    id: usize,
    deque: Deque = .{},
    /// This worker OS thread's own saved context while a task runs.
    sched_ctx: Context = .{},
    running: ?*Task = null,
    thread: ?std.Thread = null,
    /// Set by yield/park/trampoline, on this same thread, just before
    /// switching away; read by `run` right after the switch returns. Plain
    /// (non-atomic) is correct here — it is written and read by the same
    /// thread only, never observed cross-thread.
    next_disposition: TaskState = .running,
    park_setup: ?ParkFn = null,
    park_setup_arg: ?*anyopaque = null,

    threadlocal var tls: ?*Worker = null;

    fn current() *Worker {
        return tls.?; // task code only ever runs on a worker OS thread
    }

    fn run(self: *Worker) void {
        tls = self;
        var backoff: u64 = min_backoff_ns;
        while (true) {
            const t = self.findWork() orelse {
                if (self.sched.stopping.load(.acquire)) return;
                sleepNs(backoff);
                backoff = @min(backoff * 2, max_backoff_ns);
                continue;
            };
            backoff = min_backoff_ns;
            self.running = t;
            self.next_disposition = .running; // must be overwritten before the switch back
            _ = contextSwitch(&.{ .old = &self.sched_ctx, .new = &t.ctx });
            self.running = null;
            switch (self.next_disposition) {
                .runnable => if (!self.deque.pushBottom(t)) self.sched.global.push(t),
                .parked => {
                    // Safe only now: `t.ctx` was just saved by this same
                    // thread, in program order, above. The release store is
                    // what lets another thread's later acquire (unpark's CAS,
                    // or a test polling `state`) see that write.
                    t.state.store(.parked, .release);
                    if (self.park_setup) |setup| {
                        self.park_setup = null;
                        setup(t, self.park_setup_arg);
                        self.park_setup_arg = null;
                    }
                },
                .done => Task.destroy(t),
                .running => unreachable, // yield/park/trampoline must set this before switching back
            }
        }
    }

    fn findWork(self: *Worker) ?*Task {
        if (self.deque.popBottom()) |t| return t;
        if (self.sched.global.pop()) |t| return t;
        for (self.sched.workers) |*other| { // bounded: one pass over all workers
            if (other == self) continue;
            if (other.deque.steal()) |t| return t;
        }
        if (self.sched.poller.pollReady(self.sched, 0) > 0) {
            if (self.sched.global.pop()) |t| return t;
        }
        return null;
    }
};

// ---------------------------------------------------------------------------
// Scheduler
// ---------------------------------------------------------------------------

pub const Scheduler = struct {
    workers: []Worker,
    global: GlobalQueue = .{},
    poller: NetPoller,
    stopping: std.atomic.Value(bool) = .init(false),

    /// `nthreads == 0` auto-detects the CPU count (GOMAXPROCS default).
    /// Bookkeeping (worker array, task control blocks, stacks) is allocated
    /// directly from the OS — never through the GC heap (see module doc).
    pub fn init(nthreads: usize) !Scheduler {
        const n = if (nthreads == 0) (std.Thread.getCpuCount() catch 1) else nthreads;
        std.debug.assert(n > 0 and n <= 1024);
        const workers = try std.heap.page_allocator.alloc(Worker, n);
        errdefer std.heap.page_allocator.free(workers);
        for (workers, 0..) |*w, i| w.* = .{ .id = i };
        const poller = try NetPoller.init();
        return .{ .workers = workers, .poller = poller };
    }

    /// Spawns the OS thread pool. Must be called on a `*Scheduler` that will
    /// not move again (workers keep a back-pointer to it).
    pub fn start(self: *Scheduler) !void {
        for (self.workers) |*w| w.sched = self;
        for (self.workers) |*w| {
            w.thread = std.Thread.spawn(.{}, Worker.run, .{w}) catch |err| {
                self.stopping.store(true, .release);
                for (self.workers) |*started| if (started.thread) |th| th.join();
                return err;
            };
        }
    }

    /// Spawn a green thread. Callable from any thread; if called from within
    /// a running task it prefers that worker's local queue (fast path),
    /// falling back to the global queue when the local queue is full or the
    /// caller isn't a worker at all.
    pub fn spawn(self: *Scheduler, f: TaskFn, arg: ?*anyopaque) !void {
        const t = try Task.create(f, arg);
        if (Worker.tls) |w| {
            if (!w.deque.pushBottom(t)) self.global.push(t);
        } else {
            self.global.push(t);
        }
    }

    /// Signal every worker to stop once it next finds no work.
    pub fn shutdown(self: *Scheduler) void {
        self.stopping.store(true, .release);
    }

    /// Join every worker OS thread. Call after `shutdown`.
    pub fn join(self: *Scheduler) void {
        for (self.workers) |*w| if (w.thread) |th| th.join();
    }

    /// Free scheduler bookkeeping. Call after `join`.
    pub fn deinit(self: *Scheduler) void {
        self.poller.deinit();
        std.heap.page_allocator.free(self.workers);
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

/// Bounded-wait helper for tests: turns an open-ended spin into a loop with a
/// provable upper bound (Power-of-10: every loop must be statically bounded).
const Deadline = struct {
    end_ns: u64,

    fn after(ns: u64) Deadline {
        return .{ .end_ns = monoNs() + ns };
    }

    fn expired(self: Deadline) bool {
        return monoNs() > self.end_ns;
    }
};

test "context switch: round trip and microbench sanity (<1us/switch)" {
    const Harness = struct {
        var task_ctx: Context = .{};
        var caller_ctx: Context = .{};
        var iterations: usize = 0;

        fn body() callconv(.c) noreturn {
            while (true) {
                iterations += 1;
                _ = contextSwitch(&.{ .old = &task_ctx, .new = &caller_ctx });
            }
        }
    };

    const mapping = try mapGuardedStack(stack_size);
    defer unmapGuardedStack(mapping);
    const top = @intFromPtr(mapping.ptr) + mapping.len;
    Harness.task_ctx = switch (builtin.cpu.arch) {
        .x86_64 => .{ .sp = top - 8, .fp = 0, .pc = @intFromPtr(&Harness.body) },
        .aarch64 => .{ .sp = top, .fp = 0, .pc = @intFromPtr(&Harness.body) },
        else => unreachable,
    };

    const round_trips = 100_000;
    const start_ns = monoNs();
    var i: usize = 0;
    while (i < round_trips) : (i += 1) {
        _ = contextSwitch(&.{ .old = &Harness.caller_ctx, .new = &Harness.task_ctx });
    }
    const elapsed_ns = monoNs() - start_ns;

    try testing.expectEqual(round_trips, Harness.iterations);
    const ns_per_switch = elapsed_ns / (round_trips * 2); // two switches per round trip
    try testing.expect(ns_per_switch < 1000);
}

test "Deque: push/pop/steal ordering and full/empty edges" {
    var dq = Deque{};
    var tasks: [Deque.capacity + 1]Task = undefined;
    for (&tasks, 0..) |*t, i| t.* = .{ .fn_ptr = undefined, .arg = null, .mapping = &.{}, .ctx = .{ .sp = i, .fp = 0, .pc = 0 } };

    try testing.expect(dq.popBottom() == null);
    try testing.expect(dq.steal() == null);

    var i: usize = 0;
    while (i < Deque.capacity) : (i += 1) try testing.expect(dq.pushBottom(&tasks[i]));
    try testing.expect(!dq.pushBottom(&tasks[Deque.capacity])); // full

    // Owner pop takes from head (oldest first), matching steal order.
    try testing.expectEqual(&tasks[0], dq.popBottom().?);
    try testing.expect(dq.pushBottom(&tasks[Deque.capacity])); // room again
    try testing.expectEqual(&tasks[1], dq.steal().?);

    var drained: usize = 0;
    while (dq.popBottom()) |_| drained += 1;
    try testing.expectEqual(@as(usize, Deque.capacity - 1), drained);
    try testing.expect(dq.popBottom() == null);
}

test "GlobalQueue: FIFO order" {
    var gq = GlobalQueue{};
    var tasks: [3]Task = undefined;
    for (&tasks, 0..) |*t, i| t.* = .{ .fn_ptr = undefined, .arg = null, .mapping = &.{}, .ctx = .{ .sp = i, .fp = 0, .pc = 0 } };

    try testing.expect(gq.pop() == null);
    for (&tasks) |*t| gq.push(t);
    for (&tasks) |*t| try testing.expectEqual(t, gq.pop().?);
    try testing.expect(gq.pop() == null);
}

fn incTask(arg: ?*anyopaque) callconv(.c) void {
    const counter: *std.atomic.Value(usize) = @ptrCast(@alignCast(arg));
    _ = counter.fetchAdd(1, .monotonic);
}

test "stress: 100k green threads increment a shared atomic, no OS thread explosion" {
    const nworkers = 4;
    var sched = try Scheduler.init(nworkers);
    try sched.start();
    defer {
        sched.shutdown();
        sched.join();
        sched.deinit();
    }

    var counter = std.atomic.Value(usize).init(0);
    const total = 100_000;
    var i: usize = 0;
    while (i < total) : (i += 1) { // bounded: exactly `total` spawns
        try sched.spawn(incTask, @ptrCast(&counter));
    }

    const deadline = Deadline.after(30 * std.time.ns_per_s);
    while (counter.load(.acquire) < total) {
        if (deadline.expired()) return error.Timeout;
        sleepNs(100_000); // 100us poll
    }
    try testing.expectEqual(@as(usize, total), counter.load(.monotonic));
    try testing.expectEqual(@as(usize, nworkers), sched.workers.len); // fixed pool, never grew
}

test "park/unpark: a parked task does not block others on the same worker" {
    var sched = try Scheduler.init(1); // single worker: proves parking doesn't stall the OS thread
    try sched.start();
    defer {
        sched.shutdown();
        sched.join();
        sched.deinit();
    }

    const Harness = struct {
        var parked_task: ?*Task = null;
        var done_count: std.atomic.Value(usize) = .init(0);

        fn parkSelf(_: ?*anyopaque) callconv(.c) void {
            parked_task = Worker.current().running.?;
            park(null, null);
            _ = done_count.fetchAdd(1, .monotonic); // resumes only after unpark()
        }

        fn finishQuick(_: ?*anyopaque) callconv(.c) void {
            _ = done_count.fetchAdd(1, .monotonic);
        }
    };

    try sched.spawn(Harness.parkSelf, null);

    var deadline = Deadline.after(5 * std.time.ns_per_s);
    while (Harness.parked_task == null or Harness.parked_task.?.state.load(.acquire) != .parked) {
        if (deadline.expired()) return error.Timeout;
        sleepNs(10_000);
    }

    const others = 9;
    var i: usize = 0;
    while (i < others) : (i += 1) try sched.spawn(Harness.finishQuick, null);

    deadline = Deadline.after(5 * std.time.ns_per_s);
    while (Harness.done_count.load(.acquire) < others) {
        if (deadline.expired()) return error.Timeout;
        sleepNs(10_000);
    }
    try testing.expectEqual(@as(usize, others), Harness.done_count.load(.monotonic));

    unpark(&sched, Harness.parked_task.?);
    deadline = Deadline.after(5 * std.time.ns_per_s);
    while (Harness.done_count.load(.acquire) < others + 1) {
        if (deadline.expired()) return error.Timeout;
        sleepNs(10_000);
    }
    try testing.expectEqual(@as(usize, others + 1), Harness.done_count.load(.monotonic));
}

test "netpoller: register on a pipe wakes the parked task" {
    var sched = try Scheduler.init(2);
    try sched.start();
    defer {
        sched.shutdown();
        sched.join();
        sched.deinit();
    }

    var fds: [2]i32 = undefined;
    switch (builtin.os.tag) {
        .linux => {
            const rc = std.os.linux.pipe(&fds);
            try testing.expectEqual(std.os.linux.E.SUCCESS, std.posix.errno(rc));
        },
        else => try testing.expect(std.c.pipe(&fds) == 0),
    }
    defer closeFd(fds[0]);
    defer closeFd(fds[1]);

    const Harness = struct {
        var woke: std.atomic.Value(bool) = .init(false);
        var read_fd: i32 = undefined;
        var sched_ptr: *Scheduler = undefined;

        fn registerSetup(t: *Task, _: ?*anyopaque) void {
            // Runs on the worker's thread after `t.ctx` is safely saved (see
            // `park`'s doc comment) — only now is it safe to hand `t` to the
            // poller, which may hand it to another worker at any moment.
            sched_ptr.poller.register(read_fd, .read, t) catch unreachable;
        }

        fn waitOnPipe(_: ?*anyopaque) callconv(.c) void {
            park(registerSetup, null);
            var byte: [1]u8 = undefined;
            _ = std.posix.read(read_fd, &byte) catch unreachable;
            woke.store(true, .release);
        }
    };
    Harness.read_fd = fds[0];
    Harness.sched_ptr = &sched;

    try sched.spawn(Harness.waitOnPipe, null);
    sleepNs(50 * std.time.ns_per_ms); // let the task register and park

    _ = try writeFd(fds[1], "x");

    const deadline = Deadline.after(5 * std.time.ns_per_s);
    while (!Harness.woke.load(.acquire)) {
        if (deadline.expired()) return error.Timeout;
        sleepNs(10_000);
    }
}
