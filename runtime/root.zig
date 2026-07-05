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

/// Raw `argc`/`argv`, captured by `rtStartMain` and kept for a future
/// `os.args()` (stdlib `os` package, task #354) to read. Unused by this
/// ticket; captured now because extracting `envp` below already requires
/// walking past them, so keeping them costs nothing extra.
var g_argc: usize = 0;
var g_argv: [*]const ?[*:0]const u8 = undefined;

/// Compiled `main`'s normalized ABI shape (ABI.md §10): codegen wraps
/// whichever of the three surface `main` signatures (SPEC.md §17.4) the
/// program declares into this one form, returning the process exit code.
/// The compiled program provides the symbol `bit_main` with this signature;
/// `rtStartMain` below references it by that fixed name.
pub const MainFn = *const fn () callconv(.c) i32;

extern fn bit_main() callconv(.c) i32;

// ---------------------------------------------------------------------------
// Root scanning (ABI.md §11): channel-buffered references
// ---------------------------------------------------------------------------

/// Scans everything this runtime *can* precisely root today: buffered,
/// `is_ref` channel elements (ABI.md §11). Deliberately does NOT walk any
/// task's stack — the per-callsite stack-map wire format is the codegen
/// ticket's deliverable (ABI.md §4), and scanning every other, currently
/// parked task's stack additionally needs a live-task registry that does not
/// exist yet (ABI.md §5). Nothing calls `bit_rt_safepoint` yet (no codegen
/// emits it), so this partial root set is inert-safe today; it becomes a real
/// (documented) gap the moment codegen starts inserting safepoint polls, and
/// closing it is that ticket's job, not a silent hazard introduced here.
fn scanRoots(_: *anyopaque, g: *gc_mod.Gc) void {
    chan.WordChan.scanRegistryRoots(markChanWord);
    _ = g;
}

fn markChanWord(word: u64) void {
    if (word != 0) g_gc.markRoot(@ptrFromInt(word));
}

/// `ctx` is unused by `scanRoots` — any live, non-null pointer satisfies the
/// `RootScanner` contract without reading through it.
var scan_ctx: u8 = 0;

fn scanner() gc_mod.RootScanner {
    return .{ .ctx = @ptrCast(&scan_ctx), .scan = scanRoots };
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
/// committed to (`compiler/codegen/x64.zig`'s scratch-register scheme makes
/// no such promise), and there is no debug-info format yet for symbolizing
/// one if it did. A trace is future work once the object writers emit debug
/// sections; today's message is deliberately just the message.
fn fatal(msg: []const u8) noreturn {
    panicWrite(msg);
    rawExit(2);
}

/// `bit_rt_panic` (ABI.md §12): backs the `panic` builtin and every panic
/// source in SPEC.md §18.4 (index/slice range, divide-by-zero, nil-channel
/// misuse, failed `assert`, ...) — codegen routes all of them through this
/// one symbol with a message describing the specific failure.
///
/// Takes a raw `RtBytes` view, not a `string` value: the heap-object layout
/// for Bit's `string` type is undecided (`compiler/codegen/x64.zig` defers
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
export fn bit_rt_print(s: *const RtBytes) callconv(.c) void {
    writeAllFd(stdout_fd, s.ptr[0..s.len]);
}

// ---------------------------------------------------------------------------
// GC entry points (ABI.md §1-§2, §6)
// ---------------------------------------------------------------------------

/// `bit_rt_gc_alloc` (ABI.md §2/§6): allocates a zeroed body of type `info`.
/// Never returns null — v1 has no user-visible out-of-memory story (SPEC.md
/// defines no fallible object-construction form), so exhaustion is fatal here
/// rather than a null codegen would have to check at every allocation site.
export fn bit_rt_gc_alloc(info: *const gc_mod.TypeInfo) callconv(.c) [*]u8 {
    return g_gc.alloc(info) orelse fatal("out of memory");
}

/// `bit_rt_safepoint` (ABI.md §4/§5): zero-arg poll, inserted by codegen at
/// loop back-edges (and implicitly covered by allocation sites). See
/// `scanRoots`'s doc comment for what root set this collects against today.
export fn bit_rt_safepoint() callconv(.c) void {
    g_gc.safepoint(scanner());
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

/// Two-word return `(value, ok)` — the same tuple-return shape `ir.zig`
/// already uses for `make_closure` (`(fn_ptr, env_ref)`), so codegen's
/// existing 2-register-return handling covers this without inventing a
/// second convention. `ok=false` means the channel was closed and drained
/// (SPEC.md §16.2); `value` is then the zero word.
pub const ChanRecvResult = extern struct { value: u64, ok: bool };

export fn bit_rt_chan_recv(ch: ?*anyopaque) callconv(.c) ChanRecvResult {
    const c: ?*chan.WordChan = @ptrCast(@alignCast(ch));
    const r = chan.WordChan.recvNilable(c, &g_sched);
    return .{ .value = r.value, .ok = r.ok };
}

export fn bit_rt_chan_close(ch: ?*anyopaque) callconv(.c) void {
    const c: ?*chan.WordChan = @ptrCast(@alignCast(ch));
    chan.WordChan.closeNilable(c, &g_sched);
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
pub fn boot(main_fn: MainFn, environ: std.process.Environ) !i32 {
    std.debug.assert(!g_booted);
    g_booted = true;

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
    try g_sched.spawn(mainTrampoline, @ptrCast(&run));

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
/// see `compiler/link.zig`'s doc comment on the `PT_TLS` segment it emits)
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

    const at_phdr = shims.getauxval(std.elf.AT_PHDR);
    const at_phnum = shims.getauxval(std.elf.AT_PHNUM);
    const at_phent = shims.getauxval(std.elf.AT_PHENT);
    // Our own linker (`compiler/link.zig`) always emits standard
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
