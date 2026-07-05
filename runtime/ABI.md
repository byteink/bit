# Runtime ABI

The binary contract between the **compiler** (codegen) and the **runtime** (GC,
scheduler, channels). Change this document first; codegen and runtime both
implement what it says. Anything not written here is not guaranteed.

Status: v1 covers the garbage collector (`runtime/gc.zig`, §1-8), green-thread
spawn and program entry (`runtime/root.zig`, §9-10), channels (`runtime/chan.zig`
+ `runtime/root.zig`, §11), and panics (§12). The per-callsite stack-map wire
format and the multi-worker stop-the-world barrier are explicitly **not**
frozen here — §4/§5 say why and who owns them next.

All layouts below are for 64-bit targets (x86-64, ARM64). Pointers and `usize`
are 8 bytes; the null reference is the all-zero bit pattern.

---

## 1. Managed object layout

Every GC-managed allocation is `header ++ body`:

```
offset  size  field
0       8     info    *const TypeInfo   type descriptor (§2)
8       8     next    ?*GcHeader        runtime-private all-objects list
16      8     size    usize             runtime-private total alloc size
24      1     marked  bool              runtime-private mark bit
        7     (padding)
32      ...   body                      the object's fields
```

- Header size is **32 bytes**, 8-aligned. The body begins at `base + 32`.
- **The reference the compiler works with is the body pointer** (`base + 32`),
  i.e. the value returned by the allocator. Codegen never sees the header; the
  runtime reaches it by subtracting 32.
- `next`, `size`, `marked` are owned by the runtime. Codegen must not read or
  write them, and must not assume their meaning — only `info` and the 32-byte
  offset are stable ABI for codegen. The rest may change with the collector.

### Alignment

- Object base is 8-aligned; body is therefore 8-aligned.
- v1 supports body fields needing **at most 8-byte alignment** (pointers,
  `i64`/`u64`, `f64`). Over-aligned fields (SIMD, 16-byte) are out of scope; add
  an over-aligned allocation path when a type needs it.

### Initialization

- The allocator returns a **zeroed body**. Every pointer field therefore reads as
  null until codegen stores into it. This is required: a collection may occur at
  any safepoint between allocation and field initialization, and tracing must
  never follow an uninitialized slot.

---

## 2. Per-type pointer maps (`TypeInfo`)

The compiler emits one static `TypeInfo` per distinct (monomorphized) type and
passes a pointer to it at each allocation site (`bit_rt_gc_alloc`, §6).

```
TypeInfo {                       // extern struct, 40 bytes, 8-aligned
    size            : usize      // body size in bytes, excluding the header
    ptr_offsets_ptr : [*]const usize  // -\ byte offsets of GC-ref fields
    ptr_offsets_len : usize           // -/ (ptr_offsets_ptr[0..ptr_offsets_len])
    name_ptr        : [*]const u8     // -\ static type name; debug/stats only
    name_len        : usize           // -/ (may be empty: name_len == 0)
}
```

`extern`, and split into raw `ptr`/`len` pairs rather than Zig `[]const T`
slices: codegen (a different compiler than the one building the runtime)
writes this struct directly into an object file's `.rodata`, so its layout
must be a frozen, language-neutral contract, not whichever in-memory shape
happens to match Zig slices today. `runtime/gc.zig`'s `TypeInfo.of(size,
ptr_offsets, name)` is the Zig-side convenience constructor tests use;
codegen instead writes the four raw fields directly.

- `ptr_offsets` lists the byte offset, **within the body**, of every field that
  holds a GC reference. Non-reference fields (integers, floats, inline structs of
  non-pointers, packed data) are absent.
- Each offset must be **8-aligned** and satisfy `offset + 8 <= size`.
- For nested value types, flatten: emit the offsets of the pointer fields the
  value contributes, at their absolute body offsets. Pointers reachable only
  through *other* objects belong to *those* objects' maps, not this one.
- `TypeInfo` instances are static, read-only, and live for the whole program.

The runtime traces an object by reading a reference at `body + offset` for each
entry and marking it. That is the entire precision contract for the heap.

A **closure value** is one such object: `gc_alloc`'d, a fixed 16-byte
`{ code_ptr, env_ptr }` cell (`TypeInfo{ size = 16, ptr_offsets = [8] }`). The
code pointer at +0 targets `.text` and is never a GC reference; the environment
pointer at +8 is the cell's one ref field. Codegen calls a closure by loading
both and calling `code_ptr(env_ptr, args...)` — the environment is threaded in
as the callee's leading argument. Nothing new is required of the runtime: a
closure cell is scanned by the same `ptr_offsets` mechanism as any struct.

---

## 3. Reference contract

- A GC reference is **either null (all-zero) or the body base pointer** of a live
  managed object — the exact value the allocator returned.
- **Interior pointers are not references.** A pointer into the middle of an
  object must never be stored in a slot named by a pointer map (§2) or a stack
  map (§4). The collector assumes every traced/root reference is a base pointer;
  an interior pointer would resolve to a bogus header.
- The runtime exposes `Gc.owns(ptr)` which is true only for a live object's base
  pointer — interior and foreign pointers return false. It backs the debug/test
  check for this contract.

---

## 4. Root scanning and stack maps

The collector is **precise**: at a safepoint it must learn exactly which
registers and stack slots hold live references, from compiler-emitted per-callsite
stack maps.

Runtime interface (`runtime/gc.zig`):

```
RootScanner {
    ctx  : *anyopaque
    scan : fn(ctx, *Gc) void   // calls gc.markRoot(ref) for every live root
}
```

- Codegen's obligation: emit, per safepoint call-site, a stack map describing the
  live reference slots (frame offsets and live registers). The stack-map walker
  implements `RootScanner.scan` by decoding those maps up the call stack and
  calling `gc.markRoot` for each live reference.
- Roots passed to `markRoot` obey §3 (base pointers or null).
- The exact stack-map encoding (per-callsite table format, how safepoints are
  keyed by return address) is defined by the codegen ticket that produces it; the
  runtime only requires that `scan` surfaces a precise, complete root set.

---

## 5. Safepoints and stop-the-world

- v1 is **stop-the-world**: no mutator observes the heap mid-collection.
- A **safepoint** is a program point where the stack maps are valid and the
  mutator may yield to the collector. Codegen inserts safepoint polls (at least at
  loop back-edges and function entry/allocation) so collection cannot be starved.
- v1 has a single mutator **OS thread**, so "stop the world" is "run the
  collector synchronously at the safepoint". Green threads exist and run
  concurrently with each other (`runtime/sched.zig`'s M:N scheduler), but
  `rt_boot` (§9) pins the worker pool to exactly one OS thread — see §9's note
  — specifically so this remains true: only one green thread is ever actually
  executing at a time, and a safepoint reached by that thread really does see
  a quiescent heap. `Gc.safepoint(scanner)` is that poll. Running the worker
  pool at `nthreads > 1` is a real correctness hazard today: nothing pauses
  the other OS threads before `collect` marks, so a second mutator can mutate
  the heap mid-trace. Lifting the pin requires a real pause-all-workers
  barrier (each worker parks itself at its own next safepoint poll before the
  collecting thread proceeds) — future ticket, not built here.
- The collector never moves objects (non-moving mark-sweep), so references are
  stable across a collection and no pointer fix-up is required.

---

## 6. Allocation and collection entry points

v1 exposes the runtime API in Zig (`runtime/gc.zig`); the runtime-init/codegen
ticket wires the process-wide collector instance and any C-callable export
symbols.

```
Gc.init(heap, cfg) !Gc          // create over a size-class Heap
Gc.alloc(info) ?[*]u8           // allocate a zeroed body of type `info`
Gc.markRoot(ref)                // mark one root reference (used by scanners)
Gc.safepoint(scanner)           // poll: collect if the trigger was crossed
Gc.collect(scanner)             // force a full stop-the-world collection
Gc.owns(ptr) bool               // §3 base-pointer membership check
Gc.deinit()                     // free all objects and the mark worklist
```

`alloc` never collects on its own — collection happens only at safepoints, where
the stack maps make the roots precise.

Codegen never calls the Zig API above directly — it calls the two exported C
symbols `runtime/root.zig` wires to it:

```
bit_rt_gc_alloc(info: *const TypeInfo) -> *u8   // Gc.alloc, fatal (not null) on OOM
bit_rt_safepoint()                    -> void   // Gc.safepoint, with root.zig's scanner
```

Both are plain `callconv(.c)` functions with C linkage names — ordinary
external symbols to the linker (§9's export table lists every `bit_rt_*`
symbol together).

---

## 7. GC tuning (environment)

Read once at startup by `configFromEnv`. Knobs tune policy, never correctness.

| Variable            | Default | Effect                                             |
|---------------------|---------|----------------------------------------------------|
| `BIT_GC`            | on      | `off` or `0` disables automatic collection         |
| `BIT_GC_MIN_KB`     | 4096    | Min live KiB before the first/next collection      |
| `BIT_GC_GROWTH_PCT` | 200     | Heap growth percent between collections (>= 100)   |
| `BIT_GC_MARKSTACK`  | 8192    | Mark worklist capacity in entries (> 0)            |
| `BIT_GC_STATS`      | off     | `1`/`on` prints one line per collection to stderr  |

POSIX only in v1; Windows keeps the compiled defaults until the runtime adds
`GetEnvironmentVariableW`.

---

## 8. Collector algorithm (informative)

Not ABI — may change without touching §1–§7. v1 is a precise, non-moving,
stop-the-world **mark-and-sweep**: objects are threaded on an all-objects list;
mark traces from roots via the pointer maps using a fixed-capacity worklist
(worklist overflow falls back to bounded rescan passes, so mark-phase memory is
constant); sweep frees unmarked objects back to the size-class heap. Upgrade path
is incremental/generational collection when pause times matter.

---

## 9. Program entry, boot, and spawn (`runtime/root.zig`)

### Process entry

The linker (task #345) designates `_start` as the object's entry point (the
standard convention on every target this runtime supports — ELF `e_entry`,
Mach-O `LC_MAIN`/`LC_UNIXTHREAD`, PE `AddressOfEntryPoint`; wiring the header
field is the linker's concern, not this one). `_start` is hand-written asm per
arch: it reads the OS-provided `argc`/`argv`/`envp` block directly off the
initial stack pointer (the standard libc-free `_start` shape, matching
glibc/musl `crt1`) and calls `rtStartMain(sp: usize)`, which extracts `envp`,
calls `boot`, and exits the process with `boot`'s returned code.

### Boot sequence (`boot(main_fn, environ) !i32`)

1. Init the heap (`alloc.zig`) and collector (`gc.zig`, config from
   `configFromEnv(environ)` — §7).
2. Init and start the scheduler (`sched.zig`) with **exactly one** worker OS
   thread. Fixed at `nthreads = 1` — see §5's note on why v1's collector
   requires this and what lifting it needs.
3. Spawn `main_fn` (§10) as the first green thread.
4. Poll (bounded exponential backoff) until that task reports done, then shut
   the scheduler down, tear down the collector, and return the task's exit
   code.

`boot` never runs twice in one process (single-boot guard) — there is no
"reboot this runtime" operation.

### Spawn

```
bit_rt_spawn(fn_ptr: TaskFn, arg: ?*anyopaque) -> void
TaskFn = *const fn (arg: ?*anyopaque) callconv(.c) void
```

Fixed 2-arg native shape, matching `sched.TaskFn` exactly — spawn's arity does
**not** grow with the spawned call's own argument count. For `spawn f(a, b, c)`
codegen must pack `(a, b, c)` (and `f`'s captured environment, if any) into one
`bit_rt_gc_alloc`'d struct and generate a small trampoline that unpacks it and
calls `f` with the real arguments; `fn_ptr`/`arg` here are that trampoline and
its one packed-argument pointer, never `f` and its raw arguments directly.
Never fails visibly: OOM is fatal here (SPEC.md §16.1's `spawn` has no
fallible surface form), so codegen never checks a return value.

### Exported C symbols (all `bit_rt_*`, one process-wide runtime instance)

| Symbol               | Signature                                              |
|-----------------------|--------------------------------------------------------|
| `bit_rt_gc_alloc`     | `(info: *const TypeInfo) -> *u8` (§6)                  |
| `bit_rt_safepoint`    | `() -> void` (§6)                                      |
| `bit_rt_spawn`        | `(fn_ptr: TaskFn, arg: ?*anyopaque) -> void`            |
| `bit_rt_chan_make`    | `(capacity: usize, is_ref: bool) -> *anyopaque` (§11)  |
| `bit_rt_chan_send`    | `(ch: ?*anyopaque, value: u64) -> void` (§11)          |
| `bit_rt_chan_recv`    | `(ch: ?*anyopaque) -> ChanRecvResult` (§11)             |
| `bit_rt_chan_close`   | `(ch: ?*anyopaque) -> void` (§11)                       |
| `bit_rt_panic`        | `(msg: *const RtBytes) -> noreturn` (§12)               |
| `bit_rt_assert`       | `(cond: bool, msg: *const RtBytes) -> void` (§12)       |

Every symbol above is `callconv(.c)` with plain C linkage — the entire
compiler-facing surface of `libbitrt.a`. Nothing else in `runtime/` is a stable
call target for codegen; reach the collector, scheduler, and channels only
through this table.

---

## 10. Main entry normalization

SPEC.md §17.4 permits three surface `main` signatures. Codegen normalizes
whichever one a program declares into one fixed native shape and emits it
under the fixed symbol name `bit_main`:

```
bit_main() -> i32     // callconv(.c); the process exit code
```

Normalization (all three collapse to this one shape):

| Surface form                     | `bit_main` body                                  |
|-----------------------------------|---------------------------------------------------|
| `function main() { ... }`         | run the body, return `0`                          |
| `function main(): int { ... }`    | return the declared `int` directly                |
| `function main(): ()! { ... }`    | on ok, return `0`; on err, print it to stderr, return `1` |

`boot` (§9) spawns `bit_main` as the first green thread and returns its `i32`
as the process exit code, truncated to a byte for the OS `exit` syscall (a
negative or out-of-`u8`-range value truncates, matching every POSIX shell's own
exit-code truncation — Bit does not special-case it).

---

## 11. Channels (`runtime/chan.zig` + `runtime/root.zig`)

### The ABI's one channel type

Every `chan<T>` a Bit program declares is realized at the runtime boundary as
a channel of one 8-byte word (`WordChan = Chan(u64)` in `chan.zig`) — never a
per-`T` instantiation. A `T` that fits in 8 bytes (every integer width, `bool`,
`f64`, and every reference type) is carried by value, bit-reinterpreted into a
`u64`. A `T` that does not fit is out of scope for v1: box it in a
`bit_rt_gc_alloc`'d object and send the (8-byte) reference instead. This is
what lets one prebuilt `libbitrt.a` serve `chan<T>` for every monomorphized `T`
a program declares, with no per-`T` archive content.

```
bit_rt_chan_make(capacity: usize, is_ref: bool) -> *anyopaque
bit_rt_chan_send(ch: ?*anyopaque, value: u64)    -> void
bit_rt_chan_recv(ch: ?*anyopaque)                -> ChanRecvResult
bit_rt_chan_close(ch: ?*anyopaque)                -> void

ChanRecvResult { value: u64, ok: bool }   // extern struct, 2-word return
```

- `capacity == 0` is unbuffered (synchronous rendezvous); `capacity > 0` is a
  bounded ring buffer (SPEC.md §16.2).
- `is_ref` marks whether a buffered word is itself a GC reference. Codegen
  passes `true` for `chan<T>` where `T` is a reference type (or is boxed, per
  above), `false` otherwise. This is what makes root scanning (below) precise
  without inspecting the channel's element type at GC time.
- `ch == null` is a nil channel: send and receive block forever, matching
  Go-like nil-channel semantics (SPEC.md §16.2). `close` on a nil channel
  panics (§12), routed the same as every other panic source.
- `ChanRecvResult.ok == false` means the channel was closed and drained; `value`
  is then the zero word (SPEC.md §16.2).
- v1 has **no explicit channel-free primitive** — `bit_rt_chan_make` allocates
  from the process allocator directly (not GC-managed), and a channel handle
  is process-lifetime. It is therefore never dangling, but also never
  reclaimed; a program that churns through many short-lived channels leaks
  their handles (not their buffered elements, which the GC still reclaims
  once unreachable). Acceptable for v1 — see `chan.zig`'s registry note for
  the rationale — revisit if a real program's channel count matters.

### Root scanning integration

A buffered word is reachable only through the channel's ring buffer while it
sits unreceived — no stack or register holds it. `bit_rt_chan_make(_, true)`
registers the channel into a process-wide registry (`chan.zig`); root.zig's
`scanRoots` walks that registry once per collection and marks every
registered, `is_ref` channel's currently-buffered words as extra roots.

This is a **known, documented gap, not a silent hazard**: v1's root scanner
covers channel-buffered references only — it does not walk any parked green
thread's stack, because the per-callsite stack-map wire format (§4) and a
live-task registry are both future work. This is safe today only because
nothing yet emits `bit_rt_safepoint` calls (no codegen exists that does), so
there is no live stack-held reference for the gap to lose. The gap becomes
real the moment codegen starts inserting safepoint polls, and closing it
(stack maps + task registry) is that ticket's job, not this one's.

---

## 12. Panics

```
bit_rt_panic(msg: *const RtBytes)          -> noreturn
bit_rt_assert(cond: bool, msg: *const RtBytes) -> void

RtBytes { ptr: *const u8, len: usize }   // extern struct — a transient,
                                          // non-owning byte view, never
                                          // GC-managed; not the (undecided)
                                          // `string` heap-object layout
```

- `bit_rt_panic` backs the `panic(msg)` builtin and every other panic source in
  SPEC.md §18.4 (index/slice out of range, integer divide-by-zero, send/close
  on a nil or closed channel, nil function call, type-assertion mismatch,
  failed `assert`). Codegen routes all of them through this one symbol with a
  message describing the specific failure.
- `bit_rt_assert` backs `assert(cond)` / `assert(cond, msg)`. Fixed 2-arg:
  lowering must always supply a message — the 1-arg source form gets a
  compiler-supplied default (e.g. `"assertion failed"`) — since this symbol
  has one frozen native signature regardless of which surface form the
  program used.
- Both terminate the process the same way on failure: write `panic: <msg>\n`
  to fd 2, then exit immediately with code 2 (SPEC.md §18.4: "a non-zero exit
  code"). There is no `recover` (SPEC.md §18.4) and v1 emits no stack trace —
  codegen has made no frame-pointer-chain promise this runtime could walk, and
  there is no debug-info format yet to symbolize one if it did.
- `defer` unwinding (SPEC.md §18.5: deferred calls run while a panic unwinds
  to the program's top) is codegen's obligation, not the runtime's: by the
  time a panic reaches `bit_rt_panic`, every `defer` between the panic site
  and the abort must already have run. The runtime only terminates the
  process; it does not itself walk or run deferred calls.
