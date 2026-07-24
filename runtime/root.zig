//! Program entry, green-thread spawn, and panic protocol — the ABI surface
//! (`runtime/ABI.md` §9-§12) that glues `gc.zig`, `sched.zig`, and `chan.zig`
//! into one bootable archive (`libbitrt.a`). Every symbol codegen calls by a
//! `bit_rt_*` name lives here; the other runtime modules stay pure Zig APIs
//! with no C-callable surface of their own — see ABI.md §6's note assigning
//! "wiring the process-wide collector instance and any C-callable export
//! symbols" to this file.
//!
//! POSIX only (Linux + Darwin) and x86-64 + ARM64 only, matching the
//! precedent already set in `sched.zig` and `gc.zig`.

const std = @import("std");
const builtin = @import("builtin");
const heap_mod = @import("alloc.zig");
const gc_mod = @import("gc.zig");
const sched = @import("sched.zig");
const chan = @import("chan.zig");
const net = @import("net.zig");
const rand = @import("rand.zig");

/// Linux-only C-runtime shims (`memcpy`/`__divti3`/`getauxval`/...) — see
/// that file's module doc comment for why this runtime needs them at all.
/// `struct {}` on Darwin: `shims.zig` itself `@compileError`s off non-Linux,
/// so this must stay an untaken comptime branch there, matching the
/// `if (builtin.os.tag == .windows) @import(...) else struct {}` idiom Zig's
/// own std lib uses for OS-specific modules.
const shims = if (builtin.os.tag == .linux) @import("shims.zig") else struct {};

comptime {
    switch (builtin.os.tag) {
        .linux, .macos => {},
        else => @compileError("runtime/root.zig v1 targets Linux and Darwin only; see runtime/ABI.md §9"),
    }
    switch (builtin.cpu.arch) {
        .x86_64, .aarch64 => {},
        else => @compileError("runtime/root.zig v1 has entry asm for x86-64 and ARM64 only"),
    }
}

// ---------------------------------------------------------------------------
// Global runtime singletons (ABI.md §9) — exactly one Bit program per process
// ---------------------------------------------------------------------------

var g_heap: heap_mod.Heap = undefined;
var g_gc: gc_mod.Gc = undefined;
var g_sched: sched.Scheduler = undefined;
var g_booted = false;
/// The process environment block, captured by `boot` so runtime entry points
/// reachable from Bit code (`bit_rt_test_index`) can read it. `boot` always
/// runs before `main`, so this is initialized before any Bit code observes it.
var g_environ: std.process.Environ = .empty;

/// Raw `argc`/`argv`, captured by `rtStartMain` and kept for a future
/// `os.args()` (stdlib `os` package, task #354) to read. Unused by this
/// ticket; captured now because extracting `envp` below already requires
/// walking past them, so keeping them costs nothing extra.
var g_argc: usize = 0;
var g_argv: [*]const ?[*:0]const u8 = undefined;

/// The process's own `envp`, NUL-terminated, captured by `rtStartMain` so
/// `bit_rt_os_run` can hand it to `execve` — a `bit run`/`bit test` child must
/// inherit the environment (config-from-env, `BIT_TEST_INDEX`, ...). Set on the
/// same line as `g_argv`, so it is live before any Bit code runs.
var g_envp: [*:null]const ?[*:0]const u8 = undefined;

/// This process's ELF auxiliary vector, captured by `rtStartMain` (Linux only —
/// there is no auxv on Darwin, so it stays 0 there and `bit_rt_auxv` reports
/// "none"). The kernel puts the table on the initial stack, past `envp`, so the
/// process entry is the ONLY place it can be found; everything downstream has to
/// be handed it. `shims.setTable` gets the same pointer for the Zig side, and
/// `bit_rt_auxv` below hands it to the Bit side.
var g_auxv: usize = 0;

/// Compiled `main`'s normalized ABI shape (ABI.md §10): codegen wraps
/// whichever of the three surface `main` signatures (SPEC.md §17.4) the
/// program declares into this one form, returning the process exit code.
/// The compiled program provides the symbol `bit_main` with this signature;
/// `rtStartMain` below references it by that fixed name.
pub const MainFn = *const fn () callconv(.c) i32;

extern fn bit_main() callconv(.c) i32;

// ---------------------------------------------------------------------------
// Root scanning (ABI.md §4/§5/§11)
//
// A collection roots from three sources, all funneled through `scanRoots`:
//   1. the running (collecting) task's own stack — walked *precisely* via the
//      compiler's stack-map table (`bit_stack_maps`, ABI.md §4), starting from
//      the register/frame snapshot `bit_rt_safepoint` captured at the poll;
//   2. every other live task's stack — scanned *conservatively* (ABI.md §5),
//      sound because a parked task's callee-saved references are all spilled to
//      its stack by the runtime call chain that parked it;
//   3. buffered `is_ref` channel elements (ABI.md §11).
// ---------------------------------------------------------------------------

/// The compiler-emitted stack-map table (ABI.md §4), as a half-open extent.
///
/// Both bounds are defined by the LINKER, not by any object: entries come from
/// every archive member that carries them, concatenated, so no single object
/// can know the total and no object may claim the symbol without colliding with
/// its siblings. That is also why there is no count and no terminator — a
/// per-object terminator would stop this walk at the first member's last entry.
/// `extern const` so the platform's C symbol mangling matches how the linker
/// defines them (plain on ELF, `_`-prefixed on Mach-O), as with `bit_main`.
/// Their addresses are only ever taken from non-test builds (a unit-test binary
/// links no user object); the reads below are gated on `!builtin.is_test`
/// exactly so those references never force resolution.
extern const bit_stack_maps: u8;
extern const bit_stack_maps_end: u8;

/// A thread's register+frame state at a safepoint poll, captured by
/// `bit_rt_safepoint` before any runtime code could clobber it (ABI.md §4).
/// `regs[n]` is physical register `n`'s live value; `ret`/`fp` locate the
/// innermost Bit frame.
///
/// **This lives on the polling thread's own stack**, built by the naked shim
/// below and passed to `safepointImpl` as an argument. That is what makes the
/// snapshot per-thread without thread-local storage, registration, or a shared
/// global — two workers polling at the same moment write two different frames.
/// It used to be one process-wide global, which raced (#1429).
///
/// `regs` is deliberately **not** zeroed: the shim runs at every loop back-edge
/// and clearing 32 words per poll is not free. Sound because §4 restricts the
/// registers a stack map may name at a safepoint to exactly the callee-saved
/// file the shim saves, and because every word the walk reads goes through
/// `markRoot`, which marks only exact live object bases. `ret == 0` means "not
/// captured" and roots nothing.
const SafepointFrame = extern struct {
    ret: usize,
    fp: usize,
    regs: [32]usize,
};

/// Byte size the shim reserves. Rounded up to a 16-byte multiple so the stack
/// stays ABI-aligned across the reservation on both targets.
const safepoint_frame_size = std.mem.alignForward(usize, @sizeOf(SafepointFrame), 16);

comptime {
    // The shim's hand-written offsets below are literals; if the struct ever
    // grows a field they must move with it.
    std.debug.assert(@offsetOf(SafepointFrame, "ret") == 0);
    std.debug.assert(@offsetOf(SafepointFrame, "fp") == 8);
    std.debug.assert(@offsetOf(SafepointFrame, "regs") == 16);
    std.debug.assert(@sizeOf(SafepointFrame) == 272);
    std.debug.assert(safepoint_frame_size == 272);
}

// ---------------------------------------------------------------------------
// Mutator registration (ABI.md §5)
//
// `World` holds the slots and the handshake; this is just the per-thread
// binding to one of them. Zig `threadlocal` is fine here — this is Zig code
// compiled by Zig, so Darwin's TLV thunk is the compiler's problem, not ours.
// It is *not* reachable from the naked shim (which must not call anything
// before it snapshots), which is exactly why the snapshot is on the stack
// instead of hanging off this record.
// ---------------------------------------------------------------------------

var g_world: gc_mod.World = .{};

threadlocal var g_mutator: ?*gc_mod.Mutator = null;

/// This thread's mutator slot, claiming one on first use.
///
/// CALLED FROM EVERY DOOR INTO THE COLLECTOR — the safepoint poll and all eight
/// allocation sites, via `gcAlloc`/`gcAllocRaw`. The allocation door is the one
/// that matters: a thread registering only at its first safepoint is invisible
/// for the whole window between starting and reaching a loop back edge, and it
/// can allocate in that window — `let keep = []i64(16)` before the first loop is
/// exactly that shape. Another thread collecting there finds no snapshot for
/// this one and sweeps a live object out from under it. Measured, not theorised:
/// it is what made `tests/stress/gcthreads*` panic with `index out of range`.
///
/// A thread that claims a slot while a stop is already pending parks at once
/// rather than running on into the mark phase. `frame` is the snapshot to
/// publish while parked, or 0 when the caller has none — which is the honest
/// value for the allocation door, whose caller is runtime Zig code with no stack
/// map. THE SAFEPOINT DOOR MUST PASS ITS REAL SNAPSHOT: a thread whose first
/// touch of the collector is a poll already holds live references named by that
/// poll's stack map, and parking it with 0 would hide exactly those.
fn currentMutator(frame: usize) ?*gc_mod.Mutator {
    if (g_mutator) |m| return m;
    const m = g_world.claim() orelse return null;
    g_mutator = m;
    if (g_world.stopRequested()) g_world.park(m, frame);
    return m;
}

/// THE ONLY TWO WAYS THIS FILE MAY REACH THE COLLECTOR'S ALLOCATOR.
///
/// Registration is a precondition of allocating, not a courtesy: an
/// *unregistered* thread is one `World.rendezvous` does not wait for and
/// `forEachParkedFrame` cannot scan, so a collection that runs while it
/// allocates sweeps its live objects out from under it — silent heap
/// corruption, not a crash. `bit_rt_gc_alloc` used to be the only site that
/// registered, and it is only one of eight allocation sites: strings, slice
/// headers, slice buffers, slice growth, map control blocks, map headers and
/// select-case buffers all reached `g_gc` directly. `let keep = []i64(16)` on a
/// fresh OS thread therefore allocated before that thread existed as far as the
/// collector was concerned, which is exactly what made `tests/stress/gcthreads*`
/// panic with `index out of range` (#1431).
///
/// Routing every site through one pair of wrappers is what makes the invariant
/// checkable by grep — `g_gc.alloc`/`g_gc.allocRaw` must appear nowhere else in
/// this file — rather than something each new allocation site has to remember.
fn gcAlloc(info: *const gc_mod.TypeInfo) [*]u8 {
    _ = currentMutator(0);
    return g_gc.alloc(info) orelse fatal("out of memory");
}

fn gcAllocRaw(size: usize, info: *const gc_mod.TypeInfo) [*]u8 {
    _ = currentMutator(0);
    return g_gc.allocRaw(size, info) orelse fatal("out of memory");
}

/// `bit_rt_gc_thread_enter` (ABI.md §5/§6): register the calling OS thread as a
/// mutator. Idempotent. Callers that create threads should call it explicitly so
/// registration is not left to whichever safepoint happens to fire first.
export fn bit_rt_gc_thread_enter() callconv(.c) void {
    _ = currentMutator(0);
}

/// `bit_rt_gc_thread_exit` (ABI.md §5/§6): release this thread's slot. **Not
/// optional** — a leaked slot stays `running` forever, which corrupts nothing
/// but makes every later rendezvous expire, i.e. collection quietly stops.
export fn bit_rt_gc_thread_exit() callconv(.c) void {
    const m = g_mutator orelse return;
    g_mutator = null;
    g_world.release(m);
}

/// `bit_rt_gc_blocking_begin` (ABI.md §5/§6). PRECONDITION: the calling thread
/// holds **no live Bit references in any frame** for the whole bracketed region.
/// The collector neither waits for nor scans a blocked thread, so a reference
/// held across this is invisible and will be swept.
export fn bit_rt_gc_blocking_begin() callconv(.c) void {
    const m = currentMutator(0) orelse return;
    g_world.beginBlocking(m);
}

/// `bit_rt_gc_blocking_end` (ABI.md §5/§6). Blocks while a stop is pending
/// rather than resuming behind the collector's back.
export fn bit_rt_gc_blocking_end() callconv(.c) void {
    const m = g_mutator orelse return;
    g_world.endBlocking(m);
}

/// Marks one root candidate from a stack slot or register named by a stack map
/// (§4). Routed through the validating `markRoot` (via `markConservative`'s
/// `usize` door) because the type system lists some non-GC single-word
/// pointers — notably `chan` handles — as references; `markRoot` skips any word
/// that is not a live object base. See `Gc.markRoot`.
fn markRootWord(word: usize) void {
    g_gc.markConservative(word);
}

fn markChanWord(word: u64) void {
    markRootWord(@intCast(word));
}

fn blobU16(base: [*]const u8, off: usize) u16 {
    return std.mem.readInt(u16, (base + off)[0..2], .little);
}
fn blobU32(base: [*]const u8, off: usize) u32 {
    return std.mem.readInt(u32, (base + off)[0..4], .little);
}
fn blobU64(base: [*]const u8, off: usize) u64 {
    return std.mem.readInt(u64, (base + off)[0..8], .little);
}
fn blobI32(base: [*]const u8, off: usize) i32 {
    return std.mem.readInt(i32, (base + off)[0..4], .little);
}

/// Reads one machine word from an address on the (currently running) mutator
/// stack. Only ever the live stack below this collecting frame, always mapped.
fn stackWord(addr: usize) usize {
    return @as(*const usize, @ptrFromInt(addr)).*;
}

fn fpSlot(fp: usize, off: i32) usize {
    return @intCast(@as(i64, @intCast(fp)) + off);
}

/// Statically bounded frame-walk depth (Power-of-10): a runaway backstop far
/// above any real Bit call depth on a 64KB task stack.
const max_walk_frames: usize = 1 << 16;

/// Statically bounded entry count for one merged stack-map scan (Power-of-10),
/// far above any real program's function count.
const max_stackmap_entries: usize = 1 << 22;

/// Finds the stack-map entry whose code range contains `pc` and, if found, (a)
/// marks every live reference the safepoint at `pc` names — stack slots via
/// `fp`, registers via `regs` — and (b) rewrites `regs` to the caller's
/// callee-saved values this frame saved, so the next (outer) frame reads them
/// correctly. Returns false when `pc` is not in any Bit function (the top of
/// the Bit portion of the stack), which stops the walk.
///
/// `len` bounds the merged table: entries are self-delimiting and carry no
/// count, so the loop advances by decoding each entry and stops at the extent's
/// end. `max_stackmap_entries` is a Power-of-10 backstop making the bound
/// static as well — a corrupt length can then cost at most a bounded scan.
fn scanFrame(base: [*]const u8, len: usize, pc: usize, fp: usize, regs: *[32]usize) bool {
    var off: usize = 0;
    var fi: usize = 0;
    while (off < len and fi < max_stackmap_entries) : (fi += 1) {
        const code_addr: usize = @intCast(blobU64(base, off));
        off += 8;
        const code_size = blobU32(base, off);
        off += 4;
        const num_saved = blobU16(base, off);
        off += 2;
        const saved_off = off;
        off += @as(usize, num_saved) * 6; // u16 reg + i32 fp_off
        const num_sps = blobU16(base, off);
        off += 2;
        const hit = pc >= code_addr and pc < code_addr + code_size;
        var si: usize = 0;
        while (si < num_sps) : (si += 1) {
            const ret_off = blobU32(base, off);
            off += 4;
            const num_slots = blobU16(base, off);
            off += 2;
            const slots_off = off;
            off += @as(usize, num_slots) * 4;
            const num_regs = blobU16(base, off);
            off += 2;
            const regs_off = off;
            off += @as(usize, num_regs) * 2;
            if (hit and code_addr + ret_off == pc) {
                var k: usize = 0;
                while (k < num_slots) : (k += 1) {
                    const slot = blobI32(base, slots_off + k * 4);
                    markRootWord(stackWord(fpSlot(fp, slot)));
                }
                k = 0;
                while (k < num_regs) : (k += 1) {
                    markRootWord(regs[blobU16(base, regs_off + k * 2)]);
                }
            }
        }
        if (hit) {
            var k: usize = 0;
            while (k < num_saved) : (k += 1) {
                const rn = blobU16(base, saved_off + k * 6);
                const foff = blobI32(base, saved_off + k * 6 + 2);
                regs[rn] = stackWord(fpSlot(fp, foff));
            }
            return true;
        }
    }
    return false;
}

/// Precisely walks one thread's Bit frames from its safepoint snapshot, marking
/// every live reference each frame's stack map names (ABI.md §4). Called once
/// for the collecting thread's own snapshot and once per *parked* mutator's
/// published snapshot — the walk is identical, only the starting frame differs.
fn scanSnapshot(snap: *const SafepointFrame) void {
    if (builtin.is_test) return; // no stack-map table is linked into unit-test binaries
    if (snap.ret == 0) return;
    const base: [*]const u8 = @ptrCast(&bit_stack_maps);
    // The linker guarantees `end >= start`; the subtraction is the extent.
    const len: usize = @intFromPtr(&bit_stack_maps_end) - @intFromPtr(&bit_stack_maps);
    var regs = snap.regs;
    var pc = snap.ret;
    var fp = snap.fp;
    var frame: usize = 0;
    while (frame < max_walk_frames) : (frame += 1) {
        if (!scanFrame(base, len, pc, fp, &regs)) break; // pc left the Bit call graph
        const ret = stackWord(fp + 8);
        const next_fp = stackWord(fp);
        if (next_fp <= fp) break; // frame pointers grow toward higher addresses; anything else is the boundary
        pc = ret;
        fp = next_fp;
    }
}

/// Conservatively marks any word in `[sp, top)` that is a live object base
/// (ABI.md §5). Bounded by the fixed task-stack size.
fn conservativeStack(_: *anyopaque, sp: usize, top: usize) void {
    var a = std.mem.alignForward(usize, sp, @alignOf(usize));
    while (a + @sizeOf(usize) <= top) : (a += @sizeOf(usize)) {
        g_gc.markConservative(stackWord(a));
    }
}

fn markTaskArg(_: *anyopaque, arg: usize) void {
    g_gc.markConservative(arg);
}

/// Walks one *other* stopped mutator's published snapshot. Its frame lives on
/// that thread's stack, which is valid for as long as it stays parked — which is
/// until this collection ends.
fn scanParkedFrame(_: *anyopaque, frame: usize) void {
    scanSnapshot(@ptrFromInt(frame));
}

/// What `scanRoots` needs that is not global: which snapshot is the collecting
/// thread's own, and which mutator slot to skip when visiting the others.
const ScanCtx = struct {
    snap: *const SafepointFrame,
    self_m: ?*gc_mod.Mutator,
};

fn scanRoots(ctx: *anyopaque, g: *gc_mod.Gc) void {
    _ = g;
    const sc: *const ScanCtx = @ptrCast(@alignCast(ctx));
    chan.WordChan.scanRegistryRoots(markChanWord);
    // This thread, precisely (ABI.md §4).
    scanSnapshot(sc.snap);
    // Every other OS thread stopped at its own safepoint, also precisely — the
    // world is stopped, so each has published a frame that is not moving.
    if (sc.self_m) |m| g_world.forEachParkedFrame(m, @ptrCast(&scan_ctx), scanParkedFrame);
    // Parked green tasks, conservatively (ABI.md §5).
    g_sched.forEachOtherStack(sched.currentTask(), @ptrCast(&scan_ctx), conservativeStack);
    g_sched.forEachTaskArg(@ptrCast(&scan_ctx), markTaskArg);
}

/// A live, non-null pointer for callbacks that ignore their `ctx`. The
/// `RootScanner` contract only requires it be valid, never that it be read.
var scan_ctx: u8 = 0;

fn scanner(sc: *const ScanCtx) gc_mod.RootScanner {
    return .{ .ctx = @ptrCast(@constCast(sc)), .scan = scanRoots };
}

// ---------------------------------------------------------------------------
// Fatal termination — shared by panic, assert, and unrecoverable runtime
// errors (OOM during spawn/chan/gc_alloc). ABI.md §12.
// ---------------------------------------------------------------------------

fn writeAllFd(fd: i32, bytes: []const u8) void {
    var off: usize = 0;
    while (off < bytes.len) { // bounded by bytes.len
        const n = sched.writeFd(fd, bytes[off..]) catch return; // best-effort: nowhere left to report a write failure
        if (n == 0) return;
        off += n;
    }
}

const stderr_fd = 2;

fn panicWrite(msg: []const u8) void {
    writeAllFd(stderr_fd, "panic: ");
    writeAllFd(stderr_fd, msg);
    writeAllFd(stderr_fd, "\n");
}

/// Terminates the process immediately with exit code 2 (SPEC.md §18.4: "a
/// non-zero exit code"), after printing `panic: <msg>`. Never returns.
///
/// v1 does not attempt a symbolized (or even raw-address) stack trace: this
/// runtime cannot assume codegen maintains a frame-pointer chain it hasn't
/// committed to (`seed/codegen/x64.zig`'s scratch-register scheme makes
/// no such promise), and there is no debug-info format yet for symbolizing
/// one if it did. A trace is future work once the object writers emit debug
/// sections; today's message is deliberately just the message.
fn fatal(msg: []const u8) noreturn {
    panicWrite(msg);
    rawExit(2);
}

/// The heap-exhaustion seam `runtime/gc/mem.bit` reaches through (#1642).
///
/// Every allocating door in this file already spells exhaustion `orelse
/// fatal("out of memory")`, so a null object has never reached compiled code
/// here. The Bit port could not say the same: `@nosplit` cannot call `panic`,
/// so `runtime/root/root.bit` deviation 3 returned 0 and bumped a counter
/// nothing reads, and exhaustion showed up as wrong output followed by a null
/// store instead of a diagnostic.
///
/// `runtime/gc` must compile for all three targets, so it can no more write the
/// stderr write and the exit itself than it can write an mmap — it names this
/// symbol and lets the link resolve it, exactly as it does for
/// `bit_rt_map_pages`. Routing it here rather than duplicating the sequence is
/// what makes the two runtimes agree by CONSTRUCTION: same message, same fd,
/// same exit code, because it is the same `fatal`.
///
/// Declared with an `i64` result only because Bit's unmanaged subset has no
/// `noreturn`. It does not return.
export fn bit_rt_oom() callconv(.c) i64 {
    fatal("out of memory");
}

/// `bit_rt_panic` (ABI.md §12): backs the `panic` builtin and every panic
/// source in SPEC.md §18.4 (index/slice range, divide-by-zero, nil-channel
/// misuse, failed `assert`, ...) — codegen routes all of them through this
/// one symbol with a message describing the specific failure.
///
/// Takes a raw `RtBytes` view, not a `string` value: the heap-object layout
/// for Bit's `string` type is undecided (`seed/codegen/x64.zig` defers
/// `const_string` for the same reason) and is this ticket's `RtBytes`-worth
/// of scope, not the full string ABI's — see ABI.md §12's note.
export fn bit_rt_panic(msg: *const RtBytes) callconv(.c) noreturn {
    fatal(msg.ptr[0..msg.len]);
}

/// `bit_rt_assert` (ABI.md §12): backs the `assert(cond)` / `assert(cond,
/// msg)` builtins. Fixed 2-arg: lowering must always supply a message
/// (defaulting to something like `"assertion failed"` for the 1-arg source
/// form), since this symbol has one frozen native signature regardless of
/// which surface form the program used.
export fn bit_rt_assert(cond: bool, msg: *const RtBytes) callconv(.c) void {
    if (!cond) fatal(msg.ptr[0..msg.len]);
}

/// A transient, non-owning byte view — `{ptr, len}` only, never GC-managed.
/// Exists solely so `bit_rt_panic`/`bit_rt_assert` have a stable wire shape
/// today without depending on the (separately owned, not-yet-decided) `string`
/// heap-object header. See `bit_rt_panic`'s doc comment.
pub const RtBytes = extern struct { ptr: [*]const u8, len: usize };

const stdout_fd = 1;

/// `bit_rt_print` (ABI.md §12): backs the `print` builtin — writes a string's
/// bytes to stdout, no trailing newline. v1's `string` heap object is a
/// `{ptr, len}` header (same shape as `RtBytes`); for a string literal it is
/// static `.rodata` the compiler emits, so this only ever reads it.
export fn bit_rt_print(s: ?*const RtBytes) callconv(.c) void {
    writeAllFd(stdout_fd, strBytes(s));
}

/// `bit_rt_eprint` (ABI.md §12): `print`'s sibling on fd 2. Diagnostics,
/// usage, and progress belong on stderr so a program's real output can be
/// piped or redirected without them mixing in — a compiler written in Bit
/// cannot report errors correctly without this.
export fn bit_rt_eprint(s: ?*const RtBytes) callconv(.c) void {
    writeAllFd(stderr_fd, strBytes(s));
}

// ---------------------------------------------------------------------------
// Fallible-result error channel (ABI.md §13, SPEC §18)
// ---------------------------------------------------------------------------

/// The pending error for the currently-executing goroutine. A fallible
/// function returns with this null on the ok path and set to the error value
/// (an `error`-interface object pointer) on the fail path; the caller reads it
/// immediately after the call (via `?`/`catch`) before any yield, so a plain
/// per-worker threadlocal is goroutine-correct: nothing between a fallible
/// call's return and its check migrates the goroutine to another worker.
threadlocal var pending_err: ?*anyopaque = null;

/// `bit_rt_set_err` (ABI.md §13): `fail e` / `?`-propagation store the error
/// here; a null argument clears it (an ok return, or `catch` consuming it).
export fn bit_rt_set_err(e: ?*anyopaque) callconv(.c) void {
    pending_err = e;
}

/// `bit_rt_get_err` (ABI.md §13): the caller reads the pending error right
/// after a fallible call. Non-null means the call failed.
export fn bit_rt_get_err() callconv(.c) ?*anyopaque {
    return pending_err;
}

// ---------------------------------------------------------------------------
// GC entry points (ABI.md §1-§2, §6)
// ---------------------------------------------------------------------------

/// `bit_rt_gc_alloc` (ABI.md §2/§6): allocates a zeroed body of type `info`.
/// Never returns null — v1 has no user-visible out-of-memory story (SPEC.md
/// defines no fallible object-construction form), so exhaustion is fatal here
/// rather than a null codegen would have to check at every allocation site.
export fn bit_rt_gc_alloc(info: *const gc_mod.TypeInfo) callconv(.c) [*]u8 {
    // Registers before allocating, via `gcAlloc` — see the invariant there.
    return gcAlloc(info);
}

/// `bit_rt_iface_lookup` (ABI.md §2.1): resolve an interface method call to a
/// concrete method's code address. Linearly scans the receiver type's method
/// table for `id` — types have few methods, so this is a short, allocation-free
/// walk. The checker guarantees the receiver satisfies the interface, so a miss
/// is a compiler bug (a call_iface id with no matching method), hence fatal.
export fn bit_rt_iface_lookup(info: *const gc_mod.TypeInfo, id: u64) callconv(.c) *const anyopaque {
    for (info.methods()) |m| {
        if (m.id == id) return m.fn_ptr;
    }
    fatal("interface method not found");
}

/// The dynamic type of an interface value, or null if it does not name a live
/// managed object. An interface value *is* its receiver pointer (ABI.md §2.1),
/// so its dynamic type is the `TypeInfo` in that object's GC header — but a nil
/// interface is a null word, and a reference-typed value need not be a GC object
/// at all (a `chan` is not), so the header is only safe to read once `owns()`
/// confirms this address is exactly a live object's body.
fn dynTypeOf(recv: ?*anyopaque) ?*const gc_mod.TypeInfo {
    const p = recv orelse return null;
    const body: [*]u8 = @ptrCast(p);
    if (!g_gc.owns(body)) return null;
    return gc_mod.infoOf(body);
}

/// `bit_rt_iface_as` (ABI.md §2.2): the two-result type assertion
/// `let (v, ok) = iface.(T)` (SPEC §14.4). `TypeInfo`s are per concrete type, so
/// descriptor identity *is* type identity. Returns the receiver narrowed to `T`
/// on a match, else null — the caller reads `ok` from `bit_rt_iface_as_ok`.
///
/// Null on a mismatch is load-bearing, not tidiness: the result is typed `T`, so
/// handing back the un-narrowed receiver would let a caller that ignores `ok`
/// read a `Square` as a `Circle`. Null is `T`'s zero value, and the same reason
/// `ok` exists for a reference-element channel receive.
export fn bit_rt_iface_as(recv: ?*anyopaque, want: usize) callconv(.c) ?*anyopaque {
    const info = dynTypeOf(recv) orelse {
        last_iface_ok = false;
        return null;
    };
    last_iface_ok = @intFromPtr(info) == want;
    return if (last_iface_ok) recv else null;
}

threadlocal var last_iface_ok: bool = false;

/// `bit_rt_iface_as_ok` (ABI.md §2.2): the `ok` of the `bit_rt_iface_as`
/// immediately preceding it. Same adjacency contract as `bit_rt_chan_recv_ok`
/// (§11) — lowering emits the two back to back, so no other assertion can land
/// in between.
export fn bit_rt_iface_as_ok() callconv(.c) bool {
    return last_iface_ok;
}

/// `bit_rt_iface_assert` (ABI.md §2.2): the one-result type assertion
/// `let v = iface.(T)` (SPEC §14.4), which panics on a mismatch (§18.4). Both
/// type names are already in the descriptors, so the message can name them.
export fn bit_rt_iface_assert(recv: ?*anyopaque, want: usize) callconv(.c) ?*anyopaque {
    const info = dynTypeOf(recv);
    if (info) |i| {
        if (@intFromPtr(i) == want) return recv;
    }
    const target: *const gc_mod.TypeInfo = @ptrFromInt(want);
    const got: []const u8 = if (info) |i| i.typeName() else "nil";
    var buf: [128]u8 = undefined;
    var n: usize = 0;
    for ([_][]const u8{ "type assertion failed: ", got, " is not ", target.typeName() }) |part| {
        const room = buf.len - n;
        const take = @min(part.len, room);
        @memcpy(buf[n..][0..take], part[0..take]);
        n += take;
    }
    fatal(buf[0..n]);
}

/// The real safepoint poll, called by the `bit_rt_safepoint` shim below after
/// the caller's registers are snapshotted into `snap` — which sits on *this
/// thread's* stack, just below the shim's frame. `noinline` so the shim's
/// `call`/`bl` is a real ABI boundary (the snapshot must reflect the caller's
/// state, not this function's).
///
/// This is the ABI.md §5 handshake. Exactly one of three things happens:
///
///  1. Someone else is collecting -> park here until they finish. A mutator
///     that ignored this would run behind the collector's back.
///  2. Nobody is collecting and the trigger is not crossed -> return. The hot
///     path, one atomic load plus the trigger test.
///  3. The trigger is crossed -> try to become the collector.
///
/// The `tryLock` loser parks rather than spinning on the lock. That is the
/// deadlock-freedom argument: a thread the collector is waiting for is never
/// itself waiting for the collector.
noinline fn safepointImpl(snap: *const SafepointFrame) callconv(.c) void {
    const m = currentMutator(@intFromPtr(snap));

    if (g_world.stopRequested()) {
        if (m) |mm| g_world.park(mm, @intFromPtr(snap));
        return;
    }
    if (!g_gc.shouldCollect()) return;

    // A thread with no slot (registry full) must not collect: it cannot be
    // skipped by `rendezvous`, so it would wait for itself forever.
    const self_m = m orelse return;

    if (!g_world.lock.tryAcquire()) {
        // Another thread is collecting, or is about to. Park speculatively —
        // a no-op if it turns out no stop is pending.
        g_world.park(self_m, @intFromPtr(snap));
        return;
    }
    defer g_world.lock.release();

    // Re-test under the lock: the thread that just released it may have
    // collected everything we were about to collect for.
    if (!g_gc.shouldCollect()) return;

    if (!g_world.rendezvous(self_m)) {
        // Could not stop the world within the bound. ABANDON — never force.
        // Skipping a collection only costs heap growth; collecting while a
        // mutator runs costs correctness.
        g_gc.noteAbandoned();
        g_world.restart();
        return;
    }
    defer g_world.restart();

    var sc = ScanCtx{ .snap = snap, .self_m = self_m };
    g_gc.collect(scanner(&sc));
}

/// `bit_rt_safepoint` (ABI.md §4/§5): the zero-arg poll codegen emits at loop
/// back-edges. Naked so it runs with *no* prologue — it captures the caller's
/// return address, frame pointer, and callee-saved registers (the ones that may
/// hold a live GC reference, per each backend's callee-saved-only register file)
/// before any Zig code could overwrite them, then hands the snapshot to
/// `safepointImpl` as its first C argument.
///
/// **The snapshot is built on this thread's own stack**, in the space the shim
/// reserves below the caller's stack pointer. That is the whole fix for #1429:
/// the frame used to be one process-wide global, so two workers polling at once
/// overwrote each other's registers and then both collected. Reserving it here
/// is per-thread by construction — no TLS (which the naked body could not reach
/// anyway without calling Darwin's TLV thunk), no registration, no ordering.
///
/// Layout matches `SafepointFrame`: `ret` at +0, `fp` at +8, `regs[n]` at
/// +16+8n. The reservation is 8 bytes larger than the 272-byte struct on x86-64
/// and 16 larger on AArch64, purely to keep the stack ABI-aligned at the call.
///
/// A function containing a safepoint is non-leaf by construction (it calls
/// this), so it may not rely on the x86-64 red zone, and the reservation
/// overlapping that zone costs nothing.
fn safepointEntry() callconv(.naked) void {
    switch (builtin.cpu.arch) {
        // rbx=3, r13=13, r14=14, r15=15 -> regs[n] at 16+8n = 40,120,128,136.
        // At entry rsp % 16 == 8 (the caller's `call` pushed the return
        // address); subtracting 280 restores rsp % 16 == 0 for the call while
        // leaving the return address at 280(%rsp). rbp is still the caller's
        // frame pointer — no prologue ran. rdi is the SysV first argument;
        // rcx/r8 are caller-saved scratch, so materializing them cannot destroy
        // a callee-saved value before it is saved.
        .x86_64 => asm volatile (
            \\ subq $280, %%rsp
            \\ movq 280(%%rsp), %%r8
            \\ movq %%r8, 0(%%rsp)
            \\ movq %%rbp, 8(%%rsp)
            \\ movq %%rbx, 40(%%rsp)
            \\ movq %%r13, 120(%%rsp)
            \\ movq %%r14, 128(%%rsp)
            \\ movq %%r15, 136(%%rsp)
            \\ movq %%rsp, %%rdi
            \\ call *%%rcx
            \\ addq $280, %%rsp
            \\ ret
            :
            : [impl] "{rcx}" (&safepointImpl),
            : .{ .rdi = true, .r8 = true, .memory = true }),
        // x19..x28 -> regs[n] at 16+8n = 168..240. x30 (link register) is the
        // caller's return address; x29 the caller's frame pointer. 288 keeps sp
        // 16-aligned (the hardware enforces it). x0 is the first argument and
        // x1 caller-saved scratch, so neither disturbs the saved file. x30 is
        // preserved across the call by its own push, not by the frame copy, so
        // the return path does not depend on the callee leaving the frame
        // untouched.
        .aarch64 => asm volatile (
            \\ sub sp, sp, #288
            \\ str x30, [sp, #0]
            \\ str x29, [sp, #8]
            \\ stp x19, x20, [sp, #168]
            \\ stp x21, x22, [sp, #184]
            \\ stp x23, x24, [sp, #200]
            \\ stp x25, x26, [sp, #216]
            \\ stp x27, x28, [sp, #232]
            \\ mov x0, sp
            \\ str x30, [sp, #-16]!
            \\ blr x1
            \\ ldr x30, [sp], #16
            \\ add sp, sp, #288
            \\ ret
            :
            : [impl] "{x1}" (&safepointImpl),
            : .{ .x0 = true, .memory = true }),
        else => unreachable, // gated by the comptime arch check at file top
    }
}

comptime {
    @export(&safepointEntry, .{ .name = "bit_rt_safepoint" });
}

// ---------------------------------------------------------------------------
// Strings (ABI.md §2): a `string` value is a pointer to a GC-allocated
// `{ptr, len}` header immediately followed by its bytes; `ptr` points at those
// inline bytes, so the object is a leaf (no traced refs, shared `string_info`).
// Dynamic strings (concat, from-number) allocate here; string literals are
// static `.rodata` the compiler emits. All share the `RtBytes` wire shape.
// ---------------------------------------------------------------------------

const string_info = gc_mod.TypeInfo.of(0, &[_]usize{}, "string");
const string_hdr_size = @sizeOf(RtBytes); // {ptr, len} = 16 bytes

/// Allocates a `len`-byte string body; returns the header and a writable view
/// of its bytes for the caller to fill. OOM is fatal (no fallible string form).
fn allocString(len: usize) struct { hdr: *RtBytes, bytes: []u8 } {
    const body = gcAllocRaw(string_hdr_size + len, &string_info);
    const hdr: *RtBytes = @ptrCast(@alignCast(body));
    const bytes = (body + string_hdr_size)[0..len];
    hdr.* = .{ .ptr = bytes.ptr, .len = len };
    return .{ .hdr = hdr, .bytes = bytes };
}

/// The bytes of a `string` value, tolerating a NULL header (#1564).
///
/// A struct zero-value is one `gc_alloc` of zeroed memory (SPEC §13.4), so a
/// `string` field of a zeroed struct is the null word, not `""`. `s == nil` is
/// not spellable for a string (E0053), so null and empty are indistinguishable
/// to a program — the only observable difference was the fault. Every string
/// reader therefore goes through here and sees a null as `""`.
///
/// Deliberately returns a byte view rather than a substitute header: no shared
/// header object is ever handed back to Bit code, so nothing can alias or
/// mutate a process-wide empty (the trap #1557 called out for slices).
fn strBytes(s: ?*const RtBytes) []const u8 {
    const h = s orelse return &.{};
    return h.ptr[0..h.len];
}

/// `bit_rt_string_concat` (ABI.md §2): a fresh string holding `a` then `b`.
/// Binary — lowering folds an N-part interpolation into a chain of these.
export fn bit_rt_string_concat(a: ?*const RtBytes, b: ?*const RtBytes) callconv(.c) *const RtBytes {
    const ab = strBytes(a);
    const bb = strBytes(b);
    const s = allocString(ab.len + bb.len);
    @memcpy(s.bytes[0..ab.len], ab);
    @memcpy(s.bytes[ab.len..][0..bb.len], bb);
    return s.hdr;
}

/// `bit_rt_string_eq` (ABI.md §2): byte-wise equality; backs string `==`/`!=`.
export fn bit_rt_string_eq(a: ?*const RtBytes, b: ?*const RtBytes) callconv(.c) bool {
    return std.mem.eql(u8, strBytes(a), strBytes(b));
}

/// `bit_rt_string_cmp` (ABI.md §2): three-way lexicographic order, backing
/// string `<`/`<=`/`>`/`>=` (SPEC §14.6). Negative when `a < b`, 0 when equal,
/// positive when `a > b`. Bytes compare UNSIGNED and a common prefix is broken
/// by length (shorter is less), which is also code-point order for UTF-8.
/// Length-driven, never NUL-terminated: an embedded NUL is an ordinary byte,
/// and a sliced string carries its own length.
export fn bit_rt_string_cmp(a: ?*const RtBytes, b: ?*const RtBytes) callconv(.c) i64 {
    const ab = strBytes(a);
    const bb = strBytes(b);
    const n = @min(ab.len, bb.len);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (ab[i] != bb[i]) return @as(i64, ab[i]) - @as(i64, bb[i]);
    }
    if (ab.len == bb.len) return 0;
    return if (ab.len < bb.len) -1 else 1;
}

/// `bit_rt_sqrt` (ABI.md §14): the square root, backing `std/math`'s `sqrt`.
/// `@sqrt` lowers to the hardware instruction (`sqrtsd`/`fsqrt`) — no libm.
export fn bit_rt_sqrt(x: f64) callconv(.c) f64 {
    return @sqrt(x);
}

/// `bit_rt_string_byte` (ABI.md §2): the byte at `index`, backing `s[i]` on a
/// string (SPEC §12.2 — result type `u8`). Out-of-range panics, mirroring
/// slice indexing (SPEC §18.4). Returns `u64` (zero-extended), like
/// `bit_rt_slice_get`, so the whole return register is defined — a `u8` return
/// leaves rax's upper bits undefined under the C ABI.
export fn bit_rt_string_byte(s: ?*const RtBytes, index: usize) callconv(.c) u64 {
    const bs = strBytes(s);
    if (index >= bs.len) fatal("index out of range");
    return bs[index];
}

/// `bit_rt_string_slice` (ABI.md §2): `s[lo:hi]` (SPEC §12.6) — a fresh string
/// holding bytes `[lo, hi)`. Copies rather than sharing `s`'s buffer: a string
/// header's `ptr` is an interior pointer into its own GC object, so a shared
/// view could not keep the backing alive (a slice can, because its header names
/// the buffer object base). Panics unless `0 <= lo <= hi <= len`.
export fn bit_rt_string_slice(s: ?*const RtBytes, lo: usize, hi: usize) callconv(.c) *const RtBytes {
    const bs = strBytes(s);
    if (!(lo <= hi and hi <= bs.len)) fatal("string bounds out of range");
    const out = allocString(hi - lo);
    @memcpy(out.bytes, bs[lo..hi]);
    return out.hdr;
}

/// `bit_rt_bytes_from_string` (ABI.md §2): `[]byte(s)` (SPEC §12.9) — a fresh
/// `[]u8` whose element `i` is `s[i]`. Slices are word-stored (ABI.md §2), so
/// each byte lands zero-extended in its own word; the buffer is a leaf (non-ref).
export fn bit_rt_bytes_from_string(s: ?*const RtBytes) callconv(.c) *SliceHeader {
    const bs = strBytes(s);
    const h = bit_rt_slice_new(bs.len, bs.len, 0);
    var i: usize = 0;
    while (i < bs.len) : (i += 1) h.buf[i] = bs[i];
    return h;
}

/// `bit_rt_string_from_bytes` (ABI.md §2): `string(b)` for a `[]u8` (SPEC §12.9)
/// — a fresh string whose byte `i` is the low byte of element word `i`.
export fn bit_rt_string_from_bytes(h: ?*const SliceHeader) callconv(.c) *const RtBytes {
    const s = h orelse return allocString(0).hdr; // null header (#1564) => ""
    const out = allocString(s.len);
    var i: usize = 0;
    while (i < s.len) : (i += 1) out.bytes[i] = @truncate(s.buf[s.off + i]);
    return out.hdr;
}

// ---------------------------------------------------------------------------
// Filesystem (ABI.md §14) — thin POSIX wrappers; the ergonomic File/open/
// readFile/writeFile layer lives in std/fs, built on these primitives.
// ---------------------------------------------------------------------------

const max_path = 4096;

/// `bit_rt_fs_open`: open `path` read-only (`write=false`), or create+truncate
/// write-only (`write=true`). Returns the fd, or -1 on any error. The Bit path
/// is a `{ptr,len}` view with no NUL terminator, so copy it into a bounded
/// stack buffer first (a path at/over `max_path` is rejected, not truncated).
export fn bit_rt_fs_open(path: *const RtBytes, write: bool) callconv(.c) i64 {
    return openWithMode(path, if (write) .write else .read);
}

/// `bit_rt_fs_append`: open `path` create+append write-only. Returns the fd, or
/// -1. Every write lands at the end of the file, atomically w.r.t. other
/// appenders (`O_APPEND`).
export fn bit_rt_fs_append(path: *const RtBytes) callconv(.c) i64 {
    return openWithMode(path, .append);
}

/// The Bit path is a `{ptr,len}` view with no NUL terminator, so copy it into a
/// bounded stack buffer first (a path at/over `max_path` is rejected, not
/// truncated). Shared by every path-taking primitive below.
fn openWithMode(path: *const RtBytes, mode: sched.OpenMode) i64 {
    var buf: [max_path]u8 = undefined;
    const p = pathZ(path, &buf) orelse return -1;
    return sched.openFd(p, mode) catch return -1;
}

fn pathZ(path: *const RtBytes, buf: *[max_path]u8) ?[*:0]const u8 {
    if (path.len >= max_path) return null;
    @memcpy(buf[0..path.len], path.ptr[0..path.len]);
    buf[path.len] = 0;
    return buf[0..path.len :0].ptr;
}

/// `bit_rt_fs_read`: read up to `max` bytes from `fd` into a fresh string; the
/// result is shorter than `max` at EOF (empty exactly at EOF). Unlike
/// `fs_read_all` this works on pipes, sockets, and stdin, which have no size.
export fn bit_rt_fs_read(fd: i64, max: i64) callconv(.c) *const RtBytes {
    if (max <= 0) return stringFromBytes("");
    const want: usize = @intCast(max);
    const tmp = std.heap.page_allocator.alloc(u8, want) catch return stringFromBytes("");
    defer std.heap.page_allocator.free(tmp);
    const n = sched.readFd(@intCast(fd), tmp) catch return stringFromBytes("");
    return stringFromBytes(tmp[0..n]);
}

/// `bit_rt_fs_exists` / `bit_rt_fs_is_dir`: both false for a missing path.
export fn bit_rt_fs_exists(path: *const RtBytes) callconv(.c) bool {
    var buf: [max_path]u8 = undefined;
    const p = pathZ(path, &buf) orelse return false;
    return sched.statPath(p).exists;
}

export fn bit_rt_fs_is_dir(path: *const RtBytes) callconv(.c) bool {
    var buf: [max_path]u8 = undefined;
    const p = pathZ(path, &buf) orelse return false;
    return sched.statPath(p).is_dir;
}

/// `bit_rt_fs_mkdir` / `bit_rt_fs_remove`: 0 on success, -1 on failure.
/// `remove` deletes a file or an *empty* directory.
export fn bit_rt_fs_mkdir(path: *const RtBytes) callconv(.c) i64 {
    var buf: [max_path]u8 = undefined;
    const p = pathZ(path, &buf) orelse return -1;
    return if (sched.mkdirAt(p)) 0 else -1;
}

export fn bit_rt_fs_remove(path: *const RtBytes) callconv(.c) i64 {
    var buf: [max_path]u8 = undefined;
    const p = pathZ(path, &buf) orelse return -1;
    return if (sched.removeAt(p)) 0 else -1;
}

/// `bit_rt_fs_list_dir`: `path`'s entries, each terminated by a NUL byte, with
/// `.`/`..` omitted. Empty string when the directory is empty or unreadable —
/// `std/fs` checks `isDir` first to tell those apart. NUL separates because it
/// is the one byte a POSIX filename cannot contain.
export fn bit_rt_fs_list_dir(path: *const RtBytes) callconv(.c) *const RtBytes {
    var buf: [max_path]u8 = undefined;
    const p = pathZ(path, &buf) orelse return stringFromBytes("");
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.heap.page_allocator);
    if (!sched.listDir(p, &out)) return stringFromBytes("");
    return stringFromBytes(out.items);
}

/// `bit_rt_fs_read_all`: the whole file as a fresh `string`. Sized from
/// `fstat`, so it targets regular files; a stat error or non-regular fd yields
/// the empty string. A short read leaves the tail zero-filled (GC memory is
/// zeroed) — acceptable for v1's regular-file use.
export fn bit_rt_fs_read_all(fd: i64) callconv(.c) *const RtBytes {
    const size: usize = @intCast(sched.fileSize(@intCast(fd)) catch return stringFromBytes(""));
    const s = allocString(size);
    var off: usize = 0;
    while (off < size) { // bounded by file size
        const n = sched.readFd(@intCast(fd), s.bytes[off..]) catch break;
        if (n == 0) break;
        off += n;
    }
    return s.hdr;
}

/// `bit_rt_fs_write`: write all of `s`'s bytes to `fd`. Returns the byte count
/// written, or -1 on any write error.
export fn bit_rt_fs_write(fd: i64, s: *const RtBytes) callconv(.c) i64 {
    var off: usize = 0;
    while (off < s.len) { // bounded by s.len
        const n = sched.writeFd(@intCast(fd), s.ptr[off..s.len]) catch return -1;
        if (n == 0) break;
        off += n;
    }
    return @intCast(off);
}

/// `bit_rt_fs_chmod`: set `path`'s permission bits to `mode`. Returns 0 on
/// success, -1 on any error. Needed because a compiler that writes an executable
/// must mark it executable — `writeFile` alone leaves a 0o644 file the kernel
/// refuses to exec.
export fn bit_rt_fs_chmod(path: *const RtBytes, mode: i64) callconv(.c) i64 {
    var buf: [max_path]u8 = undefined;
    const p = pathZ(path, &buf) orelse return -1;
    return if (sched.chmodAt(p, @intCast(mode))) 0 else -1;
}

/// `bit_rt_os_run`: run the executable at `path` as a child process — inheriting
/// this process's environment — and return its exit code (or -1 on any failure
/// or abnormal termination). `bit run`/`bit test`'s primitive: after writing the
/// compiled binary it must launch it and report the status.
///
/// fork + immediate exec is the ONLY work between fork and exec, so it is safe
/// even with scheduler worker threads live: the child touches only
/// async-signal-safe syscalls and stack data computed before the fork (`pathZ`
/// already copied the path). On failure to exec, the child `_exit`s 127 (the
/// shell's "command not found"), never returning into forked runtime state.
export fn bit_rt_os_run(path: *const RtBytes) callconv(.c) i64 {
    var buf: [max_path]u8 = undefined;
    const p = pathZ(path, &buf) orelse return -1;
    const child_argv = [_:null]?[*:0]const u8{p};
    // Linux is no-libc (raw syscalls); Darwin routes through libSystem — the same
    // split `rawExit` makes. `std.posix` has no fork/execve/waitpid wrappers.
    switch (builtin.os.tag) {
        .linux => {
            const forked: isize = @bitCast(std.os.linux.fork());
            if (forked < 0) return -1;
            if (forked == 0) {
                _ = std.os.linux.execve(p, &child_argv, g_envp);
                rawExit(127);
            }
            var status: u32 = 0;
            var tries: usize = 0;
            while (tries < 256) : (tries += 1) { // bounded EINTR retry (Power of 10)
                const w: isize = @bitCast(std.os.linux.waitpid(@intCast(forked), &status, 0));
                if (w >= 0) break;
                if (@as(usize, @intCast(-w)) != @intFromEnum(std.os.linux.E.INTR)) return -1;
            }
            if (std.os.linux.W.IFEXITED(status)) return @intCast(std.os.linux.W.EXITSTATUS(status));
            return -1;
        },
        else => {
            const pid = std.c.fork();
            if (pid < 0) return -1;
            if (pid == 0) {
                _ = std.c.execve(p, &child_argv, g_envp);
                rawExit(127);
            }
            var status: c_int = 0;
            if (std.c.waitpid(pid, &status, 0) < 0) return -1;
            const us: u32 = @bitCast(status);
            if (std.c.W.IFEXITED(us)) return @intCast(std.c.W.EXITSTATUS(us));
            return -1;
        },
    }
}

/// `bit_rt_os_run_test(path, idx)` (ABI.md §19): like `bit_rt_os_run`, but execs
/// the child with `BIT_TEST_INDEX=<idx>` in front of the inherited environment so
/// its synthetic `main` (see selfhost/testgen.bit) dispatches to test `idx`. The
/// `bit test` runner calls this once per discovered test. `getPosix` returns the
/// first match, so prepending the var makes it win over any inherited one.
export fn bit_rt_os_run_test(path: *const RtBytes, idx: i64) callconv(.c) i64 {
    var buf: [max_path]u8 = undefined;
    const p = pathZ(path, &buf) orelse return -1;
    const child_argv = [_:null]?[*:0]const u8{p};

    var idx_buf: [40]u8 = undefined;
    const idx_str = std.fmt.bufPrintZ(&idx_buf, "BIT_TEST_INDEX={d}", .{idx}) catch return -1;

    // child env = BIT_TEST_INDEX :: inherited. Bounded copy (Power of 10); a
    // process with more than max_env vars loses the overflow, never corrupts.
    const max_env = 1024;
    var envp: [max_env + 2]?[*:0]const u8 = undefined;
    envp[0] = idx_str.ptr;
    var n: usize = 0;
    while (g_envp[n]) |e| : (n += 1) {
        if (n + 1 >= max_env) break;
        envp[n + 1] = e;
    }
    envp[n + 1] = null;
    const child_envp: [*:null]?[*:0]const u8 = @ptrCast(&envp);

    switch (builtin.os.tag) {
        .linux => {
            const forked: isize = @bitCast(std.os.linux.fork());
            if (forked < 0) return -1;
            if (forked == 0) {
                _ = std.os.linux.execve(p, &child_argv, child_envp);
                rawExit(127);
            }
            var status: u32 = 0;
            var tries: usize = 0;
            while (tries < 256) : (tries += 1) {
                const w: isize = @bitCast(std.os.linux.waitpid(@intCast(forked), &status, 0));
                if (w >= 0) break;
                if (@as(usize, @intCast(-w)) != @intFromEnum(std.os.linux.E.INTR)) return -1;
            }
            if (std.os.linux.W.IFEXITED(status)) return @intCast(std.os.linux.W.EXITSTATUS(status));
            return -1;
        },
        else => {
            const pid = std.c.fork();
            if (pid < 0) return -1;
            if (pid == 0) {
                _ = std.c.execve(p, &child_argv, child_envp);
                rawExit(127);
            }
            var status: c_int = 0;
            if (std.c.waitpid(pid, &status, 0) < 0) return -1;
            const us: u32 = @bitCast(status);
            if (std.c.W.IFEXITED(us)) return @intCast(std.c.W.EXITSTATUS(us));
            return -1;
        },
    }
}

/// `bit_rt_host_target()` (ABI.md §19): the BuildTarget ordinal of the host this
/// binary runs on — 0 x86_64-linux, 1 aarch64-linux, 2 aarch64-macos, matching
/// selfhost/main.bit's BuildTarget enum. This archive is compiled once per
/// target, so `builtin.target` here IS the host: bit2 has no compile-time
/// `builtin`, so its `hostTarget()` default reads this instead of hard-coding.
/// `bit_rt_auxv()` (ABI.md §19): the address of this process's ELF auxiliary
/// vector, or 0 when there is none — Darwin never sets it, and `initLinuxTls`
/// is the only writer.
///
/// This is the Bit-side counterpart of `shims.setTable`: the auxv is initial-
/// stack knowledge that only the process entry can recover, so a Bit module
/// cannot find it for itself. It gets the POINTER from here and does the SCAN
/// itself (`runtime/auxv`, which is the `getauxval` port). When #1367 ports this
/// file, the capture moves to Bit and this accessor becomes module state.
export fn bit_rt_auxv() callconv(.c) i64 {
    return @bitCast(g_auxv);
}

export fn bit_rt_host_target() callconv(.c) i64 {
    return switch (builtin.target.os.tag) {
        .macos => 2,
        else => switch (builtin.target.cpu.arch) {
            .aarch64 => 1,
            else => 0,
        },
    };
}

/// `bit_rt_fs_close`: close `fd`. Always reports success (the raw close wrapper
/// swallows `EINTR`/`EBADF`); a caller that must know uses the fd's own errors.
///
/// Closes sockets too: `close(2)` does not care what kind of fd it is given, so
/// `std/net` reuses this rather than adding an identical `netClose` primitive.
export fn bit_rt_fs_close(fd: i64) callconv(.c) i64 {
    sched.closeFd(@intCast(fd));
    return 0;
}

// ---------------------------------------------------------------------------
// Network (ABI.md §20) — the low-level layer under `std/net`
// ---------------------------------------------------------------------------
// Any of these may park the calling green thread on the netpoller; none blocks
// an OS thread. Each reports failure as `-1` (or an empty string) and leaves the
// ergonomic, error-returning layer to `stdlib/net`.
//
// Addresses are dotted-quad IPv4 literals — no DNS at this level.
// `bit_rt_fs_close` closes a socket.

/// A host string's bytes. A socket takes an address, not a NUL-terminated path,
/// so unlike `pathZ` this needs no copy and cannot fail.
fn hostBytes(host: *const RtBytes) []const u8 {
    return host.ptr[0..host.len];
}

/// `bit_rt_net_listen`: a listening TCP socket on `host:port`, or `-1`.
/// `port == 0` asks the kernel to choose one; read it back with `net_local_port`.
export fn bit_rt_net_listen(host: *const RtBytes, port: i64) callconv(.c) i64 {
    if (port < 0 or port > 65535) return -1;
    const fd = net.listenTcp(hostBytes(host), @intCast(port), 512) catch return -1;
    return @intCast(fd);
}

/// `bit_rt_net_local_port`: the port `fd` is bound to, or `-1`.
export fn bit_rt_net_local_port(fd: i64) callconv(.c) i64 {
    const p = net.localPort(@intCast(fd)) catch return -1;
    return @intCast(p);
}

/// `bit_rt_net_accept`: the next connection on listener `fd`, or `-1`. Parks the
/// calling green thread until a peer arrives.
export fn bit_rt_net_accept(fd: i64) callconv(.c) i64 {
    const c = net.acceptTcp(@intCast(fd)) catch return -1;
    return @intCast(c);
}

/// `bit_rt_net_dial`: a connected TCP socket to `host:port`, or `-1`. Parks until
/// the handshake completes, and surfaces a refused connection here rather than at
/// some later write.
export fn bit_rt_net_dial(host: *const RtBytes, port: i64) callconv(.c) i64 {
    if (port < 0 or port > 65535) return -1;
    const fd = net.dialTcp(hostBytes(host), @intCast(port)) catch return -1;
    return @intCast(fd);
}

/// `bit_rt_net_read`: up to `max` bytes from `fd`, parking until some arrive.
/// Empty means the peer closed — an orderly end of stream. An I/O error reads as
/// empty too: `std/net` cannot distinguish them, and a read loop should stop
/// either way.
export fn bit_rt_net_read(fd: i64, max: i64) callconv(.c) *const RtBytes {
    if (max <= 0) return stringFromBytes("");
    const want: usize = @intCast(max);
    const tmp = std.heap.page_allocator.alloc(u8, want) catch return stringFromBytes("");
    defer std.heap.page_allocator.free(tmp);
    const n = net.readSock(@intCast(fd), tmp) catch return stringFromBytes("");
    return stringFromBytes(tmp[0..n]);
}

/// `bit_rt_net_write`: all of `s` to `fd`, parking whenever the send buffer is
/// full. Returns the byte count, or `-1`. A short write is retried internally,
/// never reported: a caller that asked to write 12 bytes gets 12, or an error.
export fn bit_rt_net_write(fd: i64, s: *const RtBytes) callconv(.c) i64 {
    const n = net.writeSock(@intCast(fd), s.ptr[0..s.len]) catch return -1;
    return @intCast(n);
}

/// The sender of the most recent `bit_rt_net_udp_recv` on this goroutine.
/// Read by `bit_rt_net_udp_sender_host`/`_port` immediately after the recv, with
/// no yield in between — a per-worker threadlocal is goroutine-correct here for
/// the same reason as `pending_err`. `port == -1` flags a failed recv, which is
/// how `net_udp_recv`'s empty return is told apart from a real zero-length
/// datagram (a valid sender's port is 0..65535).
const UdpSender = struct { addr: std.posix.sockaddr.in = undefined, port: i64 = -1 };
threadlocal var udp_last_sender: UdpSender = .{};

/// `bit_rt_net_udp_bind`: a datagram socket bound to `host:port`, or `-1`.
/// `port == 0` asks the kernel to choose one; read it back with `net_local_port`.
export fn bit_rt_net_udp_bind(host: *const RtBytes, port: i64) callconv(.c) i64 {
    if (port < 0 or port > 65535) return -1;
    const fd = net.bindUdp(hostBytes(host), @intCast(port)) catch return -1;
    return @intCast(fd);
}

/// `bit_rt_net_udp_send`: one datagram of `data` to `host:port` from `fd`.
/// Returns the byte count, or `-1`. Parks if the send buffer is momentarily full.
export fn bit_rt_net_udp_send(fd: i64, host: *const RtBytes, port: i64, data: *const RtBytes) callconv(.c) i64 {
    if (port < 0 or port > 65535) return -1;
    const n = net.sendTo(@intCast(fd), hostBytes(host), @intCast(port), data.ptr[0..data.len]) catch return -1;
    return @intCast(n);
}

/// `bit_rt_net_udp_recv`: up to `max` bytes of the next datagram on `fd`, parking
/// until one arrives. Records the sender for `net_udp_sender_host`/`_port`. On
/// error returns empty and sets the sender port to `-1` (a zero-length datagram,
/// by contrast, returns empty with a valid sender).
export fn bit_rt_net_udp_recv(fd: i64, max: i64) callconv(.c) *const RtBytes {
    udp_last_sender = .{};
    if (max <= 0) return stringFromBytes("");
    const want: usize = @intCast(max);
    const tmp = std.heap.page_allocator.alloc(u8, want) catch return stringFromBytes("");
    defer std.heap.page_allocator.free(tmp);
    var from: std.posix.sockaddr.in = undefined;
    const n = net.recvFrom(@intCast(fd), tmp, &from) catch return stringFromBytes("");
    udp_last_sender = .{ .addr = from, .port = net.addrPort(&from) };
    return stringFromBytes(tmp[0..n]);
}

/// `bit_rt_net_udp_sender_host`: dotted-quad of the last recv's sender, or `""`.
export fn bit_rt_net_udp_sender_host() callconv(.c) *const RtBytes {
    if (udp_last_sender.port < 0) return stringFromBytes("");
    var buf: [15]u8 = undefined;
    return stringFromBytes(net.formatIpv4(&udp_last_sender.addr, &buf));
}

/// `bit_rt_net_udp_sender_port`: the last recv's sender port, or `-1` on error.
export fn bit_rt_net_udp_sender_port() callconv(.c) i64 {
    return udp_last_sender.port;
}

/// `bit_rt_net_resolve`: the first IPv4 A-record for `host` as a dotted quad, or
/// `""` on failure. A dotted-quad `host` passes straight back. Uses the first
/// nameserver in /etc/resolv.conf (ABI.md §20).
export fn bit_rt_net_resolve(host: *const RtBytes) callconv(.c) *const RtBytes {
    const ip = net.resolve(hostBytes(host)) catch return stringFromBytes("");
    var buf: [15]u8 = undefined;
    return stringFromBytes(net.formatOctets(ip, &buf));
}

// ---------------------------------------------------------------------------
// Crypto (ABI.md §21) — the Zig↔Bit boundary primitives crypto needs but that
// cannot be written in pure Bit. Entropy comes only from the OS CSPRNG.
// ---------------------------------------------------------------------------

/// `bit_rt_random_bytes`: a fresh `string` of `len` cryptographically-secure
/// random bytes from the OS CSPRNG. A non-positive `len` yields the empty string
/// (mirroring `fs_read`); an OS entropy failure is **fatal** — this never hands
/// back weak or zero bytes.
export fn bit_rt_random_bytes(len: i64) callconv(.c) *const RtBytes {
    if (len <= 0) return stringFromBytes("");
    const s = allocString(@intCast(len));
    rand.fill(s.bytes) catch fatal("random_bytes: OS CSPRNG failed");
    return s.hdr;
}

/// `bit_rt_secure_zero`: wipe a `[]byte`'s element words to zero with a barrier
/// the optimizer cannot elide (`std/crypto` uses it to clear key material). The
/// slice's word model (ABI.md §2) stores one byte per 8-byte word, so wiping the
/// whole `[off, off+len)` word range zeroes every logical byte the slice views.
export fn bit_rt_secure_zero(h: ?*SliceHeader) callconv(.c) void {
    const s = h orelse return; // null header (#1564) views no bytes
    const words = s.buf[s.off .. s.off + s.len];
    rand.secureZero(std.mem.sliceAsBytes(words));
}

// ---------------------------------------------------------------------------
// Math (ABI.md §17) — the low-level layer under `std/math`
// ---------------------------------------------------------------------------
// `@floor`/`@ceil`/`@round`/`@trunc`/`@sqrt` lower to single instructions on
// both targets. `pow`/`atan2`/`log*` are Zig's own pure-Zig implementations.
//
// Deliberately absent: `sin`/`cos`/`tan`/`exp`. Zig exposes those only as
// builtins that LLVM lowers to libm calls (`sin`, `exp`, …), and Bit links no
// libc — a freestanding-correct implementation is its own task, and shipping an
// approximate one silently would be worse than not shipping it.

export fn bit_rt_floor(x: f64) callconv(.c) f64 {
    return @floor(x);
}
export fn bit_rt_ceil(x: f64) callconv(.c) f64 {
    return @ceil(x);
}
export fn bit_rt_round(x: f64) callconv(.c) f64 {
    return @round(x);
}
export fn bit_rt_trunc(x: f64) callconv(.c) f64 {
    return @trunc(x);
}
export fn bit_rt_pow(x: f64, y: f64) callconv(.c) f64 {
    return std.math.pow(f64, x, y);
}
export fn bit_rt_atan2(y: f64, x: f64) callconv(.c) f64 {
    return std.math.atan2(y, x);
}
export fn bit_rt_log(x: f64) callconv(.c) f64 {
    return std.math.log(f64, std.math.e, x);
}
export fn bit_rt_log2(x: f64) callconv(.c) f64 {
    return std.math.log2(x);
}
export fn bit_rt_log10(x: f64) callconv(.c) f64 {
    return std.math.log10(x);
}

// ---------------------------------------------------------------------------
// Time (ABI.md §18) — the low-level layer under `std/time`
// ---------------------------------------------------------------------------

/// `bit_rt_time_mono_ns`: monotonic nanoseconds. Never jumps; measures elapsed.
export fn bit_rt_time_mono_ns() callconv(.c) i64 {
    return @intCast(sched.monoNs());
}

/// `bit_rt_time_unix_ns`: wall-clock nanoseconds since the Unix epoch. Can jump
/// (NTP, clock set), so it dates events and never measures durations.
export fn bit_rt_time_unix_ns() callconv(.c) i64 {
    return sched.realtimeNs();
}

/// `bit_rt_time_sleep_ns`: parks the calling green thread for at least `ns`,
/// leaving its worker free to run other tasks (ABI.md §18). A non-positive
/// duration just yields. Never blocks the OS thread.
export fn bit_rt_time_sleep_ns(ns: i64) callconv(.c) void {
    if (ns <= 0) {
        sched.yield();
        return;
    }
    sched.sleepTask(@intCast(ns));
}

// ---------------------------------------------------------------------------
// OS (ABI.md §19) — the low-level layer under `std/os`
// ---------------------------------------------------------------------------

/// `bit_rt_os_argc`: the process argument count (`argv[0]` is the program).
export fn bit_rt_os_argc() callconv(.c) i64 {
    return @intCast(g_argc);
}

/// `bit_rt_os_arg_at`: argument `i`, or the empty string when out of range.
export fn bit_rt_os_arg_at(i: i64) callconv(.c) *const RtBytes {
    if (i < 0 or @as(usize, @intCast(i)) >= g_argc) return stringFromBytes("");
    const p = g_argv[@intCast(i)] orelse return stringFromBytes("");
    return stringFromBytes(std.mem.span(p));
}

/// `bit_rt_os_env`: the value of environment variable `name`, or the empty
/// string when unset (Bit has no nil string; `std/os` maps empty to absent).
export fn bit_rt_os_env(name: *const RtBytes) callconv(.c) *const RtBytes {
    const v = gc_mod.lookupEnv(g_environ, name.ptr[0..name.len]) orelse return stringFromBytes("");
    return stringFromBytes(v);
}

/// `bit_rt_os_self_exe`: the running executable's own absolute path with
/// symlinks resolved, or the empty string when the platform cannot report it
/// (Bit has no nil string; `std/os` maps empty to "unknown", same convention as
/// `os_env`). Callers must treat empty as "fall back", never as a valid path.
///
/// `argv[0]` is deliberately NOT a fallback: it is whatever the caller passed,
/// so it can be a bare name, a relative path against a cwd that has since
/// changed, or an outright lie. Resolving an install prefix from it would be
/// worse than admitting we do not know.
export fn bit_rt_os_self_exe() callconv(.c) *const RtBytes {
    var buf: [max_path]u8 = undefined;
    const p = sched.selfExePath(&buf) catch return stringFromBytes("");
    return stringFromBytes(p);
}

/// `bit_rt_os_exit`: terminate the process immediately with `code`. Deferred
/// calls do not run (SPEC §18.4's panic rules apply equally here).
export fn bit_rt_os_exit(code: i64) callconv(.c) noreturn {
    rawExit(@bitCast(@as(i8, @truncate(code))));
}

/// `bit_rt_test_index` (ABI.md §16): the 0-based index of the one test this
/// process should run, read from `BIT_TEST_INDEX`; `-1` when unset (so a test
/// binary run directly is a no-op rather than running an arbitrary test).
///
/// `bit test` execs the test binary once per test rather than looping in-process
/// because a failed `assert` panics the process — isolation is what lets the
/// runner attribute the failure and still run the remaining tests.
export fn bit_rt_test_index() callconv(.c) i64 {
    const v = gc_mod.lookupEnv(g_environ, "BIT_TEST_INDEX") orelse return -1;
    return std.fmt.parseInt(i64, v, 10) catch -1;
}

fn stringFromBytes(txt: []const u8) *const RtBytes {
    const s = allocString(txt.len);
    @memcpy(s.bytes, txt);
    return s.hdr;
}

export fn bit_rt_string_from_int(v: i64) callconv(.c) *const RtBytes {
    var buf: [24]u8 = undefined; // fits any i64 decimal + sign
    return stringFromBytes(std.fmt.bufPrint(&buf, "{d}", .{v}) catch unreachable);
}

/// The longest text `{d}` can produce for an f64. `{d}` is POSITIONAL decimal
/// always — it never falls back to an exponent form — so the extremes are long:
/// the negative smallest subnormal is `-0.` + 323 zeros + `5` = 327 bytes, and
/// negative DBL_MAX is 310. 327 is the true maximum; the buffer carries slack so
/// a formatting change upstream cannot silently reintroduce the overflow.
///
/// This bound is load-bearing, not decorative. It was 32, which truncated every
/// float wider than 32 characters — and because `libbitrt` is built ReleaseSmall
/// (build.zig), the `NoSpaceLeft` that `bufPrint` correctly returned met a
/// `catch unreachable` with safety checks OFF. That is undefined behaviour, not
/// a panic, and it surfaced as a silently truncated string: DBL_MAX printed as
/// `17976931348623157000000000000000` and 5e-324 as `0.000...000`. Silent, and
/// wrong in every Bit program that prints a float, not only in the IR dump.
const float_text_max = 512;

export fn bit_rt_string_from_float(v: f64) callconv(.c) *const RtBytes {
    var buf: [float_text_max]u8 = undefined;
    // Not `catch unreachable`: in a ReleaseSmall archive that is UB and degrades
    // to silent truncation. An explicit `fatal` fails loudly instead, so a bound
    // that ever stops holding is a stopped process rather than a wrong number.
    const txt = std.fmt.bufPrint(&buf, "{d}", .{v}) catch
        fatal("bit_rt_string_from_float: float text exceeds buffer");
    return stringFromBytes(txt);
}

/// `parseFloat(text) -> f64`: the value of a float literal, `_` separators
/// stripped (SPEC §5.4). Mirrors the seed checker's `parseFloatLiteral`, so the
/// self-hosted compiler parses a float to the identical bits — a prerequisite for
/// a byte-identical `const_float` IR dump (both format via `{d}`). Unparsable
/// text yields 0 (the checker has already validated the literal's shape).
export fn bit_rt_parse_float(s: *const RtBytes) callconv(.c) f64 {
    // Sized to match `float_text_max` so the two directions compose: the widest
    // text `bit_rt_string_from_float` can emit is 327 bytes, and at the old 80
    // any such literal fell straight into the `return 0` below — a round trip
    // that silently produced zero rather than the value it started from.
    var buf: [float_text_max]u8 = undefined;
    if (s.len > buf.len) return 0;
    var n: usize = 0;
    for (s.ptr[0..s.len]) |c| {
        if (c == '_') continue;
        buf[n] = c;
        n += 1;
    }
    return std.fmt.parseFloat(f64, buf[0..n]) catch 0;
}

/// `floatBits(v) -> u64` / `float32Bits(v) -> u32`: an IEEE-754 value's raw bit
/// pattern. Bit has no bitcast operator and its `u64(x)` conversion is numeric
/// (it truncates), so a compiler written in Bit cannot otherwise materialize a
/// float constant into a register — the backends need exactly these bits to emit
/// `movz`/`movk` + `fmov`. Added for the self-hosted compiler's `const_float`
/// selection, the same reason `parse_float` exists.
export fn bit_rt_float_bits(v: f64) callconv(.c) u64 {
    return @bitCast(v);
}

export fn bit_rt_float32_bits(v: f32) callconv(.c) u32 {
    return @bitCast(v);
}

export fn bit_rt_string_from_bool(v: bool) callconv(.c) *const RtBytes {
    return stringFromBytes(if (v) "true" else "false");
}

// ---------------------------------------------------------------------------
// Slices (ABI.md §2): a `[]T` value is a pointer to a GC-allocated
// `{buf, len, off, cap, is_ref}` header; `buf` points at a *separate* GC element
// buffer the header traces (`ptr_offsets = [0]`), and the slice views the `len`
// words at `buf[off .. off + len]` (capacity `cap` from `off`, so `buf` holds
// `off + cap` words). A reslice `s[lo:hi]` shares the same `buf` and only bumps
// `off`/`len`/`cap` — `buf` stays a base pointer, so no interior pointer is ever
// stored as a GC reference (ABI.md §3). Elements are one 8-byte word each — the
// same word model channels use (ABI.md §11): a `T` that fits in a word is stored
// by value, a wider `T` is boxed and its reference stored. This keeps `[]T` a
// single-word value and indexing a fixed stride, at the cost of one word per
// element (a packed `[]byte` is a later optimization). `is_ref` records whether
// each word is a GC reference: a ref buffer is allocated with `ref_array_info`
// so the collector traces its words as roots (elements reachable only through
// the slice survive), a non-ref buffer stays a leaf. `len` sits at offset 8, the
// same as the `string` header's, so `slice_len` serves both.
// ---------------------------------------------------------------------------

const SliceHeader = extern struct {
    buf: [*]u64, // +0  element buffer base (a GC object); the header's one traced ref
    len: usize, // +8   (shared offset with the string header's len)
    off: usize, // +16  view start index into buf (nonzero only after reslicing)
    cap: usize, // +24  capacity counted from off (buf holds off + cap words)
    is_ref: usize, // +32  0/1: are the buffered words GC references (for #1106)
};

const slice_info = gc_mod.TypeInfo.of(@sizeOf(SliceHeader), &[_]usize{0}, "slice");
const slicebuf_info = gc_mod.TypeInfo.of(0, &[_]usize{}, "slicebuf"); // leaf (non-ref elements)

/// Allocates a `cap`-word element buffer. When the elements are GC references
/// (`is_ref`) the buffer carries the `ref_array_info` descriptor so the
/// collector traces its words as roots (ABI.md §2); otherwise it is a leaf.
/// `cap == 0` yields a valid zero-length body — never indexed (bounds checks
/// reject it).
fn allocSliceBuf(cap: usize, is_ref: bool) [*]u64 {
    const info = if (is_ref) &gc_mod.ref_array_info else &slicebuf_info;
    const body = gcAllocRaw(cap * @sizeOf(u64), info);
    return @ptrCast(@alignCast(body));
}

/// `bit_rt_slice_new`: a fresh `[]T` of length `len`, capacity `max(len, cap)`,
/// elements zeroed. Backs slice literals (`len == cap == N`) and `[]T(n[, m])`.
export fn bit_rt_slice_new(len: usize, cap: usize, is_ref: usize) callconv(.c) *SliceHeader {
    const c = if (cap < len) len else cap;
    const h: *SliceHeader = @ptrCast(@alignCast(gcAlloc(&slice_info)));
    h.* = .{ .buf = allocSliceBuf(c, is_ref != 0), .len = len, .off = 0, .cap = c, .is_ref = is_ref };
    return h;
}

/// `bit_rt_slice_append`: appends one word, growing the buffer (doubling, from
/// 1) when full. A grow reallocates from the current view and resets `off` to 0.
/// Mutates the header in place and returns it, so `s = append(s, x)` observes
/// the new length/buffer through the same value.
/// A NULL header appends into a FRESH slice rather than mutating through null
/// (#1564): a zeroed struct's slice field is the null word (SPEC §13.4), and
/// `append` must treat it as the empty slice. It cannot reuse a shared empty —
/// `append` grows the header IN PLACE, so a process-wide empty would be
/// corrupted by the first append anywhere (#1557).
///
/// `is_ref` is unrecoverable from a NULL header — there is no header to read
/// it from, and the element type never made the wire — so lowering passes it
/// as a third argument (ABI.md §2, #1569): the call site is the only place
/// that still knows the static element type. A non-null header ignores it and
/// keeps its own `is_ref`, set once at `bit_rt_slice_new`.
fn appendTarget(h: ?*SliceHeader, is_ref: usize) *SliceHeader {
    return h orelse bit_rt_slice_new(0, 0, is_ref);
}

export fn bit_rt_slice_append(h_opt: ?*SliceHeader, word: u64, is_ref: usize) callconv(.c) *SliceHeader {
    const h = appendTarget(h_opt, is_ref);
    if (h.len == h.cap) {
        const newcap = if (h.cap == 0) 1 else h.cap * 2;
        const nb = allocSliceBuf(newcap, h.is_ref != 0);
        @memcpy(nb[0..h.len], (h.buf + h.off)[0..h.len]);
        h.buf = nb;
        h.off = 0;
        h.cap = newcap;
    }
    h.buf[h.off + h.len] = word;
    h.len += 1;
    return h;
}

/// `bit_rt_slice_get`: bounds-checked element read (SPEC §18.4 — out-of-range
/// panics). Returns the raw word; a sub-word `T` occupies its low bytes exactly
/// as the producer left it (already correctly extended in its register).
/// A null header (a zeroed struct's slice field, #1564) has length 0, so every
/// index is out of range — the same panic an empty slice gives.
export fn bit_rt_slice_get(h: ?*const SliceHeader, index: usize) callconv(.c) u64 {
    const s = h orelse fatal("index out of range");
    if (index >= s.len) fatal("index out of range");
    return s.buf[s.off + index];
}

/// `bit_rt_slice_set`: bounds-checked element write (SPEC §18.4).
export fn bit_rt_slice_set(h: ?*SliceHeader, index: usize, word: u64) callconv(.c) void {
    const s = h orelse fatal("index out of range");
    if (index >= s.len) fatal("index out of range");
    s.buf[s.off + index] = word;
}

/// `bit_rt_slice_slice`: `s[lo:hi]` (SPEC §12.6). Shares `s`'s buffer; the new
/// view is `buf[off+lo .. off+hi]` with capacity extending to the old end
/// (`cap - lo`, Go semantics). Panics unless `0 <= lo <= hi <= cap`.
export fn bit_rt_slice_slice(h: ?*const SliceHeader, lo: usize, hi: usize) callconv(.c) *SliceHeader {
    const s = h orelse {
        // A null header (#1564) is the empty slice: capacity 0, so `[0:0]` is
        // the only in-bounds reslice. The result is a fresh empty slice, never
        // a view onto a shared body.
        if (!(lo == 0 and hi == 0)) fatal("slice bounds out of range");
        return bit_rt_slice_new(0, 0, 0);
    };
    if (!(lo <= hi and hi <= s.cap)) fatal("slice bounds out of range");
    const nh: *SliceHeader = @ptrCast(@alignCast(gcAlloc(&slice_info)));
    nh.* = .{ .buf = s.buf, .len = hi - lo, .off = s.off + lo, .cap = s.cap - lo, .is_ref = s.is_ref };
    return nh;
}

// ---------------------------------------------------------------------------
// Maps (SPEC §11.2, §13.5; ABI.md §15) — open-addressing hash table
// ---------------------------------------------------------------------------
// A `map<K,V>` is a `MapHeader` GC object over three parallel `cap`-slot
// buffers: `keys`, `vals` (slice-style word buffers, ref-typed — hence traced
// element-wise — when the stored word is a GC reference), and `ctrl` (one
// state byte per slot). Linear probing. It grows (doubling `cap`, rehashing,
// dropping tombstones) once full+tombstone load reaches 7/8, so an EMPTY slot
// always exists and every probe loop terminates in <= `cap` steps.
//
// A key is one word: a scalar compared/hashed by value, or a `string`
// (`*RtBytes`) compared/hashed by its bytes — `key_is_string` selects which,
// and also whether the key buffer is a traced ref-array (`string` is the only
// comparable reference key type; §14.6). `val_is_ref` traces the value buffer.

const CtrlEmpty: u8 = 0;
const CtrlFull: u8 = 1;
const CtrlTomb: u8 = 2;

const MapHeader = extern struct {
    keys: [*]u64, // +0   slot keys (ref-array iff key_is_string) — traced
    vals: [*]u64, // +8   slot values (ref-array iff val_is_ref)   — traced
    ctrl: [*]u8, // +16   per-slot state (leaf buffer, kept alive) — traced base
    len: usize, // +24    live entries
    cap: usize, // +32    slot count (power of two, >= 8)
    used: usize, // +40   FULL + TOMB slots (drives growth)
    key_is_string: usize, // +48
    val_is_ref: usize, // +56
};

const map_info = gc_mod.TypeInfo.of(@sizeOf(MapHeader), &[_]usize{ 0, 8, 16 }, "map");
const mapctrl_info = gc_mod.TypeInfo.of(0, &[_]usize{}, "mapctrl"); // leaf

fn allocCtrl(cap: usize) [*]u8 {
    const body = gcAllocRaw(cap, &mapctrl_info);
    return @ptrCast(body); // zeroed by allocRaw => every slot CtrlEmpty
}

fn mapHash(m: *const MapHeader, key: u64) u64 {
    if (m.key_is_string != 0) {
        const s: *const RtBytes = @ptrFromInt(@as(usize, @intCast(key)));
        return std.hash.Wyhash.hash(0, s.ptr[0..s.len]);
    }
    // splitmix64 finalizer: cheap avalanche so low-entropy integer keys
    // (0,1,2,…) don't cluster in the low probe bins.
    var x = key;
    x = (x ^ (x >> 30)) *% 0xbf58476d1ce4e5b9;
    x = (x ^ (x >> 27)) *% 0x94d049bb133111eb;
    return x ^ (x >> 31);
}

fn mapKeyEq(m: *const MapHeader, a: u64, b: u64) bool {
    if (m.key_is_string != 0) {
        const sa: *const RtBytes = @ptrFromInt(@as(usize, @intCast(a)));
        const sb: *const RtBytes = @ptrFromInt(@as(usize, @intCast(b)));
        return std.mem.eql(u8, sa.ptr[0..sa.len], sb.ptr[0..sb.len]);
    }
    return a == b;
}

// Locates `key`'s slot. `found` => `slot` holds it; otherwise `slot` is where
// it belongs (the first tombstone seen, else the terminating EMPTY).
fn mapProbe(m: *const MapHeader, key: u64) struct { slot: usize, found: bool } {
    const mask = m.cap - 1;
    var i = mapHash(m, key) & mask;
    var first_tomb: usize = m.cap; // sentinel: "none seen"
    var steps: usize = 0;
    while (steps < m.cap) : ({
        i = (i + 1) & mask;
        steps += 1;
    }) {
        switch (m.ctrl[i]) {
            CtrlEmpty => return .{ .slot = if (first_tomb != m.cap) first_tomb else i, .found = false },
            CtrlTomb => if (first_tomb == m.cap) {
                first_tomb = i;
            },
            else => if (mapKeyEq(m, m.keys[i], key)) return .{ .slot = i, .found = true },
        }
    }
    fatal("map probe overflow"); // unreachable: load factor guarantees an EMPTY slot
}

fn mapGrow(m: *MapHeader) void {
    const newcap = m.cap * 2;
    const nkeys = allocSliceBuf(newcap, m.key_is_string != 0);
    const nvals = allocSliceBuf(newcap, m.val_is_ref != 0);
    const nctrl = allocCtrl(newcap);
    const mask = newcap - 1;
    var i: usize = 0;
    while (i < m.cap) : (i += 1) {
        if (m.ctrl[i] != CtrlFull) continue;
        const key = m.keys[i];
        var j = mapHash(m, key) & mask;
        while (nctrl[j] == CtrlFull) : (j = (j + 1) & mask) {}
        nkeys[j] = key;
        nvals[j] = m.vals[i];
        nctrl[j] = CtrlFull;
    }
    m.keys = nkeys;
    m.vals = nvals;
    m.ctrl = nctrl;
    m.cap = newcap;
    m.used = m.len; // tombstones reclaimed
}

/// `bit_rt_map_new`: an empty map. `key_is_string`/`val_is_ref` (0/1) are fixed
/// by K/V at the call site and decide hashing/equality and GC tracing.
export fn bit_rt_map_new(key_is_string: usize, val_is_ref: usize) callconv(.c) *MapHeader {
    const cap: usize = 8;
    const m: *MapHeader = @ptrCast(@alignCast(gcAlloc(&map_info)));
    m.* = .{
        .keys = allocSliceBuf(cap, key_is_string != 0),
        .vals = allocSliceBuf(cap, val_is_ref != 0),
        .ctrl = allocCtrl(cap),
        .len = 0,
        .cap = cap,
        .used = 0,
        .key_is_string = key_is_string,
        .val_is_ref = val_is_ref,
    };
    return m;
}

/// `bit_rt_map_set`: insert or overwrite `m[key] = val`. Panics on a nil map
/// (Go/SPEC §11.2 — writing a nil map is a fatal condition).
export fn bit_rt_map_set(m: ?*MapHeader, key: u64, val: u64) callconv(.c) void {
    const mm = m orelse fatal("assignment to entry in nil map");
    if ((mm.used + 1) * 8 >= mm.cap * 7) mapGrow(mm);
    const p = mapProbe(mm, key);
    if (!p.found) {
        if (mm.ctrl[p.slot] == CtrlEmpty) mm.used += 1; // reusing a TOMB keeps `used`
        mm.ctrl[p.slot] = CtrlFull;
        mm.len += 1;
    }
    mm.keys[p.slot] = key;
    mm.vals[p.slot] = val;
}

/// `bit_rt_map_get`: `m[key]`, or the zero word when absent (SPEC §11.2 — an
/// absent key reads as the zero value of V). Nil map reads as empty.
export fn bit_rt_map_get(m: ?*MapHeader, key: u64) callconv(.c) u64 {
    const mm = m orelse return 0;
    if (mm.len == 0) return 0;
    const p = mapProbe(mm, key);
    return if (p.found) mm.vals[p.slot] else 0;
}

/// `bit_rt_map_has`: presence test (backs the deferred two-result form + tests).
export fn bit_rt_map_has(m: ?*MapHeader, key: u64) callconv(.c) bool {
    const mm = m orelse return false;
    if (mm.len == 0) return false;
    return mapProbe(mm, key).found;
}

/// `bit_rt_map_delete`: `delete(m, key)` — a no-op if absent. Leaves a
/// tombstone (reclaimed on the next grow) and drops the slot's ref words so the
/// collector can reclaim a removed key/value.
export fn bit_rt_map_delete(m: ?*MapHeader, key: u64) callconv(.c) void {
    const mm = m orelse return;
    if (mm.len == 0) return;
    const p = mapProbe(mm, key);
    if (!p.found) return;
    mm.ctrl[p.slot] = CtrlTomb;
    mm.keys[p.slot] = 0;
    mm.vals[p.slot] = 0;
    mm.len -= 1;
}

/// `bit_rt_map_len`: `len(m)` — live entry count (nil map => 0).
export fn bit_rt_map_len(m: ?*MapHeader) callconv(.c) i64 {
    const mm = m orelse return 0;
    return @intCast(mm.len);
}

/// Iteration (`for k of m`, §13.5): `map_iter_init` returns the first FULL slot
/// index or -1; `map_iter_next` the next FULL slot after `prev` or -1;
/// `map_key_at`/`map_val_at` read that slot. Slot order is unspecified and a
/// concurrent insert may rehash — iteration assumes no mutation, per spec.
export fn bit_rt_map_iter_init(m: ?*MapHeader) callconv(.c) i64 {
    return bit_rt_map_iter_next(m, -1);
}

export fn bit_rt_map_iter_next(m: ?*MapHeader, prev: i64) callconv(.c) i64 {
    const mm = m orelse return -1;
    var i: usize = @intCast(prev + 1);
    while (i < mm.cap) : (i += 1) {
        if (mm.ctrl[i] == CtrlFull) return @intCast(i);
    }
    return -1;
}

export fn bit_rt_map_key_at(m: *MapHeader, slot: i64) callconv(.c) u64 {
    return m.keys[@intCast(slot)];
}

export fn bit_rt_map_val_at(m: *MapHeader, slot: i64) callconv(.c) u64 {
    return m.vals[@intCast(slot)];
}

// ---------------------------------------------------------------------------
// Channels (ABI.md §11)
// ---------------------------------------------------------------------------

/// `bit_rt_chan_make`: allocates a process-lifetime channel handle (v1 has no
/// explicit channel-free primitive — see `chan.zig`'s registry doc comment)
/// and, if `is_ref`, registers it so the GC treats its buffer as roots.
/// Never returns null: same out-of-memory policy as `bit_rt_gc_alloc`, for
/// the same reason — a null return here would be indistinguishable from a
/// deliberately-`nil` channel to codegen, silently turning an OOM into a
/// channel that blocks forever instead of a loud, immediate failure.
export fn bit_rt_chan_make(capacity: usize, is_ref: bool) callconv(.c) *anyopaque {
    const ch = std.heap.page_allocator.create(chan.WordChan) catch fatal("out of memory");
    ch.* = chan.WordChan.init(capacity) catch fatal("out of memory");
    ch.is_ref = is_ref;
    ch.register();
    return @ptrCast(ch);
}

export fn bit_rt_chan_send(ch: ?*anyopaque, value: u64) callconv(.c) void {
    const c: ?*chan.WordChan = @ptrCast(@alignCast(ch));
    chan.WordChan.sendNilable(c, &g_sched, value);
}

/// Two-word return `(value, ok)`. `ok=false` means the channel was closed and
/// drained (SPEC.md §16.2); `value` is then the zero word.
pub const ChanRecvResult = extern struct { value: u64, ok: bool };

/// The `ok` flag of the most recent `bit_rt_chan_recv` on this goroutine, for
/// the two-result form `let (v, ok) = <- c` (ABI.md §11).
///
/// Codegen lowers that form as `bit_rt_chan_recv` immediately followed by
/// `bit_rt_chan_recv_ok`, with no yield in between — exactly the discipline the
/// fallible-call error slot already relies on (§13): a green thread cannot
/// migrate between a call's return and the caller's immediate read of it, so a
/// per-worker threadlocal is goroutine-correct. This exists because the single
/// value word is all `rt_call` can thread back through the IR, and a reference
/// element's zero word on a closed channel is a null pointer — so a receiver
/// *must* be able to tell "closed" from "a real value" before dereferencing.
threadlocal var last_recv_ok: bool = false;

export fn bit_rt_chan_recv(ch: ?*anyopaque) callconv(.c) ChanRecvResult {
    const c: ?*chan.WordChan = @ptrCast(@alignCast(ch));
    const r = chan.WordChan.recvNilable(c, &g_sched);
    last_recv_ok = r.ok;
    return .{ .value = r.value, .ok = r.ok };
}

/// `bit_rt_chan_recv_ok` (ABI.md §11): the `ok` of the receive just performed.
export fn bit_rt_chan_recv_ok() callconv(.c) bool {
    return last_recv_ok;
}

export fn bit_rt_chan_close(ch: ?*anyopaque) callconv(.c) void {
    const c: ?*chan.WordChan = @ptrCast(@alignCast(ch));
    chan.WordChan.closeNilable(c, &g_sched);
}

/// One `select` case as codegen marshals it (ABI.md §11). `word` is in/out: for
/// a send case it holds the value to send; for a recv case the runtime writes
/// the received value into it. `ok` receives recv validity (low byte, 0 =
/// channel closed and drained). Codegen fills a zeroed array of these, one per
/// case, in an `bit_rt_select_alloc`'d buffer.
const SelectCaseDesc = extern struct {
    dir: u64, // 0 = recv, 1 = send
    chan: ?*anyopaque,
    word: u64,
    ok: u64,
};

/// `bit_rt_select_alloc`: a zeroed `n`-case descriptor buffer. Codegen populates
/// `dir`/`chan` (and, for a send, `word`) per case, then calls `bit_rt_select`.
///
/// The buffer is a **traced** (`ref_array_info`) object, not a leaf: a `word`
/// slot can hold a live GC reference — a send case's value, or the value a recv
/// case just received (`bit_rt_select` writes it there for codegen to read
/// back) — for a `chan<T>` whose `T` is a reference type. That reference lives
/// *only* in this buffer across `bit_rt_select` (which may park and let a
/// collection run) and in the window before codegen loads it into a rooted
/// slot, so leaving the buffer untraced would sweep a still-live received value.
/// Every-word conservative tracing is exact here: `dir`/`ok` are 0/1 and the
/// `chan` handle is a process-lifetime page allocation, so `markRoot` skips all
/// three (none is a live object base); only a real `word` reference is marked.
export fn bit_rt_select_alloc(n: usize) callconv(.c) [*]SelectCaseDesc {
    const body = gcAllocRaw(n * @sizeOf(SelectCaseDesc), &gc_mod.ref_array_info);
    return @ptrCast(@alignCast(body));
}

/// `bit_rt_select` (SPEC §16.3): blocks until one case can proceed, choosing
/// uniformly at random among those ready; `has_default` makes it non-blocking
/// (run the default clause when none is ready). Returns the fired case index,
/// or `n` to signal the default clause. The received value of a recv case is
/// left in that case's `word` for codegen to read back.
export fn bit_rt_select(descs: [*]SelectCaseDesc, n: usize, has_default: bool) callconv(.c) usize {
    std.debug.assert(n <= chan.max_select_cases);
    var cases: [chan.max_select_cases]chan.SelectCase = undefined;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const c: *chan.WordChan = @ptrCast(@alignCast(descs[i].chan.?));
        cases[i] = if (descs[i].dir == 0)
            c.recvCase(&descs[i].word, @ptrCast(&descs[i].ok))
        else
            c.sendCase(&descs[i].word);
    }
    return switch (chan.select(&g_sched, cases[0..n], has_default)) {
        .fired => |idx| idx,
        .default => n,
    };
}

// ---------------------------------------------------------------------------
// Spawn (ABI.md §9)
// ---------------------------------------------------------------------------

/// `bit_rt_spawn`: fixed 2-arg, matching `sched.TaskFn` exactly (one code
/// pointer, one opaque argument pointer) — spawn's native arity does NOT
/// grow with the spawned call's own argument count. A `spawn f(a, b, c)`
/// with real arguments must have codegen pack `(a, b, c)` (and the closure's
/// own captured environment, if any) into one `bit_rt_gc_alloc`'d struct and
/// generate a small trampoline function that unpacks it and calls `f` with
/// real arguments; `fn_ptr`/`arg` here are that trampoline and its one
/// packed-argument pointer, not `f` and its raw arguments directly.
///
/// Never returns null/fails visibly: same fatal-on-OOM policy as
/// `bit_rt_gc_alloc` (`spawn` has no fallible surface form in SPEC.md §16.1).
export fn bit_rt_spawn(fn_ptr: sched.TaskFn, arg: ?*anyopaque) callconv(.c) void {
    g_sched.spawn(fn_ptr, arg) catch fatal("out of memory");
}

// ---------------------------------------------------------------------------
// Boot sequence (ABI.md §9/§10)
// ---------------------------------------------------------------------------

const MainRun = struct {
    fn_ptr: MainFn,
    exit_code: i32 = 0,
    done: std.atomic.Value(bool) = .init(false),
};

fn mainTrampoline(arg: ?*anyopaque) callconv(.c) void {
    const run: *MainRun = @ptrCast(@alignCast(arg.?));
    run.exit_code = run.fn_ptr();
    run.done.store(true, .release);
}

/// Boots the collector and scheduler, runs `main_fn` as the first green
/// thread, waits for it to return, tears the runtime down, and reports the
/// process exit code. Testable in isolation (no process exit) — `rtStartMain`
/// below is the thin, untestable (no real process to launch it from outside
/// a linked binary) wrapper that turns this into an actual process.
///
/// Only ever called once per process; `g_booted` catches a second call
/// (there is no such thing as rebooting this runtime).
/// Ignore SIGPIPE process-wide. A `write` to a socket whose peer has closed its
/// read end otherwise raises SIGPIPE, whose default disposition terminates the
/// process with no output — so a single client that hangs up mid-response would
/// kill the whole server (observed as an exit-141, empty-stderr crash under a
/// port collision). Ignored, the `write` returns EPIPE instead and `net.zig`'s
/// normal `Error` path handles it. Every networked runtime does this at startup
/// (Go, libuv). `std.posix.sigaction` is the raw syscall on Linux (libc-free)
/// and libc on Darwin — the same split the rest of this file uses.
fn ignoreSigpipe() void {
    const act: std.posix.Sigaction = .{
        .handler = .{ .handler = std.posix.SIG.IGN },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(.PIPE, &act, null);
}

pub fn boot(main_fn: MainFn, environ: std.process.Environ) !i32 {
    std.debug.assert(!g_booted);
    g_booted = true;
    g_environ = environ;
    ignoreSigpipe();

    g_heap = heap_mod.Heap.init();
    g_gc = try gc_mod.Gc.init(&g_heap, gc_mod.configFromEnv(environ));

    // ABI.md §5: nthreads pinned to 1. Only one green thread is ever actually
    // executing at a time, which is what lets v1's single-scanner, no-barrier
    // collector remain correct despite not walking parked tasks' stacks
    // (nothing runs concurrently with a collection to mutate the heap under
    // it) — see §5's full rationale for why lifting this pin needs a real
    // pause-all-workers barrier first.
    g_sched = try sched.Scheduler.init(1);
    try g_sched.start();

    var run = MainRun{ .fn_ptr = main_fn };
    try g_sched.spawnMain(mainTrampoline, @ptrCast(&run));

    // This OS thread is not itself a scheduler worker (see sched.zig's module
    // doc comment), so it waits for `main` the same way any external caller
    // would: poll with bounded exponential backoff, same shape as
    // `sched.zig`'s own idle-worker loop. Unbounded by design — waiting for
    // the program itself to finish — same as that loop's own service life.
    var backoff_ns: u64 = 1_000;
    while (!run.done.load(.acquire)) {
        sched.sleepNs(backoff_ns);
        backoff_ns = @min(backoff_ns * 2, 1_000_000);
    }

    g_sched.shutdown();
    g_sched.join();
    g_sched.deinit();
    g_gc.deinit();
    return run.exit_code;
}

fn rawExit(code: u8) noreturn {
    switch (builtin.os.tag) {
        .linux => std.os.linux.exit_group(code),
        else => std.c._exit(code), // Darwin: see sched.zig's module doc comment on using std.c, not raw syscalls, here
    }
}

/// Extracts `envp` from the raw initial stack layout the OS hands `_start`:
/// `[argc][argv[0]]..[argv[argc-1]][NULL][envp[0]]..[NULL]`. `sp` points at
/// `argc`. Also stashes `argc`/`argv` in case a future `os.args()` needs them
/// (see `g_argc`/`g_argv`'s doc comment) — free, since finding `envp` already
/// requires walking past them.
///
/// On Linux, also locates and installs this process's static TLS area
/// (`initLinuxTls`'s doc comment) — before `boot` ever spawns a scheduler
/// worker thread, since `sched.zig`'s `Worker.tls` (and Zig std's own
/// panic-recursion guard / thread-id cache) are real `threadlocal`s that
/// need a correctly-installed thread pointer the moment any code runs on
/// a worker OS thread.
///
/// Not `export`ed: `_start` below reaches it by taking `&rtStartMain` as an
/// inline-asm input operand (a real Zig reference, unlike a bare symbol name
/// in the asm text), which is what ties this function's liveness — and
/// therefore `bit_main`'s extern reference below — to `_start`'s own,
/// comptime-gated liveness. A real linked program still gets a perfectly
/// ordinary, named `rtStartMain` symbol in its object file; this only
/// changes how *this compilation unit* discovers it needs one.
fn rtStartMain(sp: usize) callconv(.c) noreturn {
    const argc: usize = @as(*const usize, @ptrFromInt(sp)).*;
    const argv_base = sp + @sizeOf(usize);
    g_argc = argc;
    g_argv = @ptrFromInt(argv_base);

    const envp_base = argv_base + (argc + 1) * @sizeOf(usize); // past argv[0..argc) and its NULL
    const envp_multi: [*:null]const ?[*:0]const u8 = @ptrFromInt(envp_base);
    g_envp = envp_multi;
    const envp_slice = std.mem.span(envp_multi);
    const environ = std.process.Environ{ .block = .{ .slice = envp_slice } };

    if (builtin.os.tag == .linux) {
        // Standard Linux ABI: the auxv array follows envp's own terminating
        // NULL immediately — no padding, both are plain pointer-width arrays.
        const auxv_addr = @intFromPtr(envp_slice.ptr) + (envp_slice.len + 1) * @sizeOf(usize);
        initLinuxTls(auxv_addr);
    }

    const code = boot(bit_main, environ) catch fatal("runtime boot failed");
    rawExit(@bitCast(@as(i8, @truncate(code))));
}

/// Captures the real auxv (so `shims.getauxval` has real data to answer
/// from) and installs this thread's TLS: reads this process's own `PT_TLS`
/// program header (found via `AT_PHDR`/`AT_PHNUM`, standard ELF TLS ABI —
/// see `seed/link.zig`'s doc comment on the `PT_TLS` segment it emits)
/// and hands it to `std.os.linux.tls.initStatic`, the exact routine Zig's
/// own `std.start` uses for a normal Linux program's main thread. That one
/// call both sets this (the process's first) thread's thread pointer AND
/// populates `std.os.linux.tls.area_desc`, which `std.Thread.spawn`'s
/// `LinuxThreadImpl` reads to set up TLS for every worker OS thread the
/// scheduler spawns afterward — reusing std's own bootstrap, not
/// hand-rolling per-thread TLS setup here (see task #345's own guidance to
/// prefer this over raw `arch_prctl`/`set_tls` syscalls).
fn initLinuxTls(auxv_addr: usize) void {
    const auxv: [*]const std.elf.Auxv = @ptrFromInt(auxv_addr);
    shims.setTable(auxv);
    g_auxv = auxv_addr;

    const at_phdr = shims.getauxval(std.elf.AT_PHDR);
    const at_phnum = shims.getauxval(std.elf.AT_PHNUM);
    const at_phent = shims.getauxval(std.elf.AT_PHENT);
    // Our own linker (`seed/link.zig`) always emits standard
    // `Elf64_Phdr`-shaped entries; a mismatch here means the binary that's
    // running isn't one our linker produced, which this runtime cannot cope
    // with regardless (its whole TLS/entry contract assumes it).
    std.debug.assert(at_phent == @sizeOf(std.elf.Phdr));
    const phdrs: [*]std.elf.Phdr = @ptrFromInt(at_phdr);
    std.os.linux.tls.initStatic(phdrs[0..at_phnum]);
}

/// The process entry point: the linker (task #345) designates this exact
/// symbol name as the object's entry (standard convention on every target
/// this runtime supports; the per-platform object-header wiring — ELF
/// `e_entry`, Mach-O `LC_MAIN`/`LC_UNIXTHREAD`, PE `AddressOfEntryPoint` — is
/// the linker ticket's own concern, not this file's).
///
/// Naked: there is no caller and no return address, so this cannot be an
/// ordinary Zig function — it must hand off to `rtStartMain` (a normal
/// `callconv(.c)` function) before doing anything Zig's calling convention
/// would otherwise assume is already set up (a valid frame, an aligned
/// stack). Both arches read the OS-provided argc/argv/envp block directly
/// off the initial stack pointer and pass it as `rtStartMain`'s one integer
/// argument — the standard libc-free `_start` shape (matches glibc/musl
/// crt1, adapted here as this runtime's own, since Bit's own linker — not
/// `zig build-exe` — controls final linking and cannot pull in Zig's
/// `std.start`).
///
/// Exported only outside tests (`comptime` guard below): `zig build test`
/// links this file into a *test* executable, which brings in Zig's own
/// `std.start` and its own `_start` — exporting a second, conflicting
/// `_start` unconditionally would collide with it. A real `libbitrt.a` build
/// is never a test build, so production archives always get this symbol.
fn startEntry() callconv(.naked) noreturn {
    switch (builtin.cpu.arch) {
        .x86_64 => asm volatile (
            \\ xorl %%ebp, %%ebp
            \\ movq %%rsp, %%rdi
            \\ andq $-16, %%rsp
            \\ call *%[start]
            \\ hlt
            :
            : [start] "r" (&rtStartMain),
        ),
        .aarch64 => asm volatile (
            \\ mov x0, sp
            \\ blr %[start]
            \\ brk #0
            :
            : [start] "r" (&rtStartMain),
        ),
        else => unreachable, // gated by the comptime check above
    }
}

/// macOS entry point. dyld's `LC_MAIN` (task #345's Mach-O writer) calls this
/// with the C `main(argc, argv, envp, apple)` ABI — args in registers, a valid
/// aligned stack already set up — and calls `exit()` with the returned code.
/// That is a different contract from `startEntry` above (which reads the raw
/// initial stack the kernel hands a Linux `_start`), so macOS gets its own
/// entry rather than sharing the naked one. No TLS bootstrap here: libSystem's
/// initializer has already installed the main thread's TLV/pthread state before
/// dyld transfers control (the runtime reaches TLS through libSystem on macOS —
/// see this file's `std.c`/`threadlocal` use and ABI.md §9).
fn machoMain(argc: c_int, argv: [*]const ?[*:0]const u8, envp: [*:null]const ?[*:0]const u8) callconv(.c) c_int {
    g_argc = @intCast(argc);
    g_argv = argv;
    g_envp = envp;
    const environ = std.process.Environ{ .block = .{ .slice = std.mem.span(envp) } };
    return boot(bit_main, environ) catch fatal("runtime boot failed");
}

comptime {
    if (!builtin.is_test) {
        // Both export the fixed entry symbol `_start`; the linker points the
        // header's entry field (ELF `e_entry` / Mach-O `LC_MAIN`) at it.
        if (builtin.os.tag == .macos)
            @export(&machoMain, .{ .name = "_start" })
        else
            @export(&startEntry, .{ .name = "_start" });
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn testMainOk() callconv(.c) i32 {
    return 0;
}

fn testMainCode() callconv(.c) i32 {
    return 7;
}

test "boot: runs main as a green thread and reports its exit code" {
    g_booted = false; // tests run in one process; reset the single-boot guard
    defer g_booted = false;
    const code = try boot(testMainOk, std.process.Environ.empty);
    try testing.expectEqual(@as(i32, 0), code);
}

test "boot: propagates a non-zero exit code from main" {
    g_booted = false;
    defer g_booted = false;
    const code = try boot(testMainCode, std.process.Environ.empty);
    try testing.expectEqual(@as(i32, 7), code);
}

test "os_run: launches a child and returns its exit code" {
    // The process entry (`rtStartMain`/`machoMain`) that normally sets `g_envp`
    // does not run in a test build; an empty environment suffices for
    // `/usr/bin/true`|`/usr/bin/false` (POSIX-standard on Linux and Darwin).
    const empty = [_:null]?[*:0]const u8{};
    g_envp = &empty;
    const yes = RtBytes{ .ptr = "/usr/bin/true".ptr, .len = "/usr/bin/true".len };
    try testing.expectEqual(@as(i64, 0), bit_rt_os_run(&yes));
    const no = RtBytes{ .ptr = "/usr/bin/false".ptr, .len = "/usr/bin/false".len };
    try testing.expectEqual(@as(i64, 1), bit_rt_os_run(&no));
    // A path that cannot exec fails cleanly (the child `_exit`s 127, reaped as
    // the child's own "exit code"), never hanging or corrupting the parent.
    const missing = RtBytes{ .ptr = "/nonexistent/bit-os-run".ptr, .len = "/nonexistent/bit-os-run".len };
    try testing.expectEqual(@as(i64, 127), bit_rt_os_run(&missing));
}

test "boot: spawn and channel round-trip through the ABI's exported symbols" {
    g_booted = false;
    defer g_booted = false;

    const Harness = struct {
        var ch: ?*anyopaque = null;

        fn spawned(arg: ?*anyopaque) callconv(.c) void {
            const c: *anyopaque = arg.?;
            bit_rt_chan_send(c, 42);
        }

        fn main() callconv(.c) i32 {
            ch = bit_rt_chan_make(1, false);
            bit_rt_spawn(spawned, ch.?);
            const r = bit_rt_chan_recv(ch.?);
            return if (r.ok and r.value == 42) 0 else 1;
        }
    };

    const code = try boot(Harness.main, std.process.Environ.empty);
    try testing.expectEqual(@as(i32, 0), code);
}

test "bit_rt_gc_alloc: zeroed body allocated through the exported symbol" {
    g_booted = false;
    defer g_booted = false;

    const offsets = [_]usize{};
    const info = gc_mod.TypeInfo.of(8, &offsets, "Test");

    const Harness = struct {
        var info_ptr: *const gc_mod.TypeInfo = undefined;
        fn main() callconv(.c) i32 {
            const body = bit_rt_gc_alloc(info_ptr);
            const word: *u64 = @ptrCast(@alignCast(body));
            return if (word.* == 0) 0 else 1;
        }
    };
    Harness.info_ptr = &info;

    const code = try boot(Harness.main, std.process.Environ.empty);
    try testing.expectEqual(@as(i32, 0), code);
}

test "bit_rt_slice_append: is_ref on a null header matches the caller's element type (#1569)" {
    g_booted = false;
    defer g_booted = false;

    const Harness = struct {
        fn main() callconv(.c) i32 {
            // `[]i64` first appended through a null header (a zeroed struct
            // field, #1564) must come back scalar, not conservatively traced.
            const scalar = bit_rt_slice_append(null, 7, 0);
            if (scalar.is_ref != 0) return 1;

            // `[]string` through the same path must come back traced.
            const ref = bit_rt_slice_append(null, 0, 1);
            if (ref.is_ref != 1) return 2;

            return 0;
        }
    };

    const code = try boot(Harness.main, std.process.Environ.empty);
    try testing.expectEqual(@as(i32, 0), code);
}

test "panicWrite: formats panic: <msg>\\n to the given fd" {
    var fds: [2]i32 = undefined;
    switch (builtin.os.tag) {
        .linux => {
            const rc = std.os.linux.pipe(&fds);
            try testing.expectEqual(std.os.linux.E.SUCCESS, std.posix.errno(rc));
        },
        else => try testing.expect(std.c.pipe(&fds) == 0),
    }
    defer switch (builtin.os.tag) {
        .linux => {
            _ = std.os.linux.close(fds[0]);
        },
        else => _ = std.c.close(fds[0]),
    };

    writeAllFd(fds[1], "panic: ");
    writeAllFd(fds[1], "boom");
    writeAllFd(fds[1], "\n");
    switch (builtin.os.tag) {
        .linux => _ = std.os.linux.close(fds[1]),
        else => _ = std.c.close(fds[1]),
    }

    var buf: [64]u8 = undefined;
    const n = std.posix.read(fds[0], &buf) catch |err| return err;
    try testing.expectEqualStrings("panic: boom\n", buf[0..n]);
}

// #1248 (M:N shared-state audit): `pending_err` is `threadlocal`, not a
// process-global — this is the regression guard for that. Each OS thread
// hammers `bit_rt_set_err`/`bit_rt_get_err` with its own distinct value and
// must only ever read back its own writes, never another thread's. A
// `pending_err` accidentally demoted to a plain `var` would fail this
// immediately (whichever thread wrote last "wins" for everyone); §13's
// "goroutine-correct even under M:N" claim rests on it staying `threadlocal`.
test "bit_rt_set_err/get_err: threadlocal slot never crosses OS threads" {
    if (builtin.single_threaded) return;

    const Worker = struct {
        fn run(seed: usize) void {
            const iterations: usize = 20_000;
            var i: usize = 0;
            while (i < iterations) : (i += 1) { // statically bounded
                const tag = seed * 131 + i + 1; // never 0, so never confused with "cleared"
                const val: ?*anyopaque = @ptrFromInt(tag);
                bit_rt_set_err(val);
                const got = bit_rt_get_err();
                std.debug.assert(got == val); // never another thread's tag
                bit_rt_set_err(null);
                std.debug.assert(bit_rt_get_err() == null);
            }
        }
    };

    const nthreads = @min(@as(usize, 4), std.Thread.getCpuCount() catch 2);
    var threads: [4]std.Thread = undefined;
    var t: usize = 0;
    while (t < nthreads) : (t += 1) {
        threads[t] = try std.Thread.spawn(.{}, Worker.run, .{t + 1});
    }
    for (threads[0..nthreads]) |th| th.join();
}
