# Channels, errors, and filesystem primitives

[Runtime ABI](../ABI.md)

## 11. Channels (`runtime/chan` + `runtime/root`)

### The ABI's one channel type

Every `chan<T>` a Bit program declares is realized at the runtime boundary as
a channel of one 8-byte word (`WordChan = Chan(u64)` in `runtime/chan/chan.bit`) — never a
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
bit_rt_chan_recv_ok()                            -> bool
bit_rt_chan_close(ch: ?*anyopaque)                -> void

ChanRecvResult { value: u64, ok: bool }   // extern class, 2-word return
```

- `bit_rt_chan_recv_ok` returns the `ok` of the receive *just* performed by this
  goroutine. `rt_call` threads only a single value word back through the IR, so
  the two-result form `let (v, ok) = <- c` (SPEC.md §16.2) lowers as
  `bit_rt_chan_recv` immediately followed by `bit_rt_chan_recv_ok`, with no
  yield between them. The outcome lives in the same per-task scratch mechanism
  the error slot uses (§13), not a threadlocal: word `scrRecvOk`, offset 264
  of the per-task scratch block (`runtime/sched/scratch.bit:77`), read by
  `bit_rt_chan_recv_ok` (`runtime/root/slots.bit:78`). The adjacency is what
  keeps that word from being clobbered by another scratch-writing operation
  before the ABI wrapper reads it back. This matters because a *reference*
  element's zero word on a closed channel is a null pointer: a receiver must
  be able to distinguish "closed" from "a real value" before dereferencing
  it.

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
  once unreachable). Acceptable for v1 — see `runtime/chan/chanreg.bit`'s note for
  the rationale — revisit if a real program's channel count matters.

### Select (§16.3)

```
SelectCaseDesc { dir: u64, chan: *WordChan, word: u64, ok: u64 }   // 32 bytes
bit_rt_select_alloc(n)                     -> *SelectCaseDesc[n]  (zeroed)
bit_rt_select(descs, n, has_default: bool) -> usize
```

Codegen evaluates each comm clause's channel (and a send case's value) once,
`bit_rt_select_alloc`s a zeroed `n`-descriptor buffer, and fills `dir` (0 recv /
1 send), `chan`, and — for a send — `word` (the value to send). `word` is
**in/out**: for a recv case the runtime writes the received value there, so
codegen reads it back from `descs[fired].word` after the call. `bit_rt_select`
returns the fired case index, or `n` to signal the `default` clause ran. The
descriptor buffer is a **traced** GC object (allocated with `ref_array_info`, so
every word is scanned): for a `chan<T>` where `T` is a reference type, a `word`
slot holds a live reference — a send case's value, or the value a recv case just
received — and that reference lives *only* in this buffer across `bit_rt_select`
(which may park while a collection runs) and until codegen loads it into a rooted
slot, so a leaf buffer would let the collector sweep a still-live received value.
Tracing every word is exact: `dir`/`ok` are 0/1 and each `chan` is a
process-lifetime page allocation, so the collector's base-pointer check skips
all three and marks only a real `word` reference. Nil-channel cases are the
caller's responsibility to omit (a nil case is never ready).

### Root scanning integration

A buffered word is reachable only through the channel's ring buffer while it
sits unreceived — no stack or register holds it. `bit_rt_chan_make(_, true)`
registers the channel into a process-wide registry (`runtime/chan/chanreg.bit`); `runtime/root/root.bit`'s
`scanRoots` walks that registry once per collection and marks every
registered, `is_ref` channel's currently-buffered words as extra roots.

This is a **known, documented gap, not a silent hazard**: v1's root scanner
covers channel-buffered references only — it does not walk any parked green
thread's stack, because the per-callsite stack-map wire format (§4) and a
live-task registry are both future work. This is safe today only because
nothing yet emits `bit_rt_safepoint` calls (no codegen exists that does), so
there is no live stack-held reference for the gap to lose. The gap becomes
real the moment codegen starts inserting safepoint polls, and closing it
(stack maps + task registry) is separate future work, not part of what this
section defines.

---

## 12. Panics

```
bit_rt_panic(msg: *const RtBytes)          -> noreturn
bit_rt_assert(cond: bool, msg: *const RtBytes) -> void
bit_rt_print(s: *const RtBytes)            -> void   // fd 1
bit_rt_eprint(s: *const RtBytes)           -> void   // fd 2

RtBytes { ptr: *const u8, len: usize }   // extern class — a transient,
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
- `bit_rt_print` / `bit_rt_eprint` back the `print` / `eprint` builtins: a
  string's bytes verbatim, no trailing newline, to fd 1 and fd 2 respectively.
  They are the only output primitives; `std/io`'s `println`/`printf` layer on
  top. The pair exists because the two streams are not interchangeable —
  diagnostics on stdout would mix into a program's real output the moment it is
  piped, so anything a caller is not asking *for* goes to fd 2.
- Both terminate the process the same way on failure: write `panic: <msg>\n`
  to fd 2, then, if `BIT_BACKTRACE=1` is set in the environment, a symbolized
  stack trace — one `  at <name> (<file>:<line>)` line per resolved frame,
  walked from `bit_rt_panic`'s own frame pointer (§4, "Frame chain") and
  symbolized against the `.bit_dbg` debug-info table (§4.2) — then exit
  immediately with code 2 (SPEC.md §18.4: "a non-zero exit code"). There is
  no `recover` keyword (SPEC.md §18.4); a task that wants to survive a panic
  installs a panic boundary (below), which is consulted *before* any of this
  runs. The trace is opt-in, not default: the `//
  panic` golden mode (`_tests_/cases/*.bit`) compares stderr byte-for-byte, so
  an always-on trace would need every `.expected` file updated in the same
  change. See `runtime/root/backtrace.bit` for the walker and
  its degrade rules — an unresolvable frame prints a raw `0x<hex>` address, a
  `format_version` mismatch untrusts the whole table for that process, and a
  missing or corrupt `name_hdr_ptr` omits just the name and keeps
  `file:line` — none of which ever calls `bit_rt_panic` recursively.
- `defer` and a panic never meet: SPEC.md §18.5 says deferred calls do **not**
  run on a panic path, "with no unwinding of any kind, deferred or
  otherwise". Nothing walks or runs a deferred call between the panic site
  and the abort — not codegen, and not the runtime, which only terminates
  the process. The panic boundary below does not change this: it discards
  the intervening frames without running anything in them.

**The panic boundary.** Six further symbols, specified here and
provided by `runtime/sched/boundary.bit` and the three `runtime/root/<os>/io.bit`
providers (not yet in the tree — this section is the contract they are written
against):

```
bit_rt_panic_boundary_arm(rec: int)             -> int
bit_rt_panic_boundary_disarm()                  -> void
bit_rt_panic_boundary_take(code: int, msg: int) -> int
bit_rt_panic_boundary_code()                    -> int
bit_rt_panic_boundary_msg()                     -> int
bit_rt_fatal(msg: *const RtBytes)               -> noreturn
```

- `bit_rt_panic_boundary_arm` saves `sp`, a resume address, `fp`/`lr` and BOTH
  callee-saved register files — the integer file and the FP file (`d8`..`d15`
  on arm64, `xmm6`..`xmm15` on x64) — into the caller-provided record `rec`,
  pushes `rec` on the current task's boundary head, and returns 0. The same
  call site returns **1** when it is reached by a resume rather than by the
  call, which is how the caller tells the two arrivals apart. The record lives
  on the arming function's own frame, which sits above every frame a later
  panic can be raised in. Saving the FP file is the difference from
  `gcSaveCalleeRegs` (`runtime/gc/gcworldsync.bit`), which only saves: this one
  restores.
- `bit_rt_panic_boundary_disarm` pops the head on the normal path — the arming
  function returning without a panic.
- `bit_rt_panic_boundary_take` is consulted by every recoverable panic door
  **before it writes anything**. It returns 0 when the current task has no
  boundary, and the caller then runs today's write-`panic:`-line, optional
  backtrace, exit-2 path unchanged, byte for byte. Otherwise it pops the head
  first (so a panic raised inside the boundary's own handler reaches the next
  outer boundary, or is fatal), records the `{code, msg}` pair in the record,
  and resumes in the armed frame — it does not return to its caller on that
  path. `msg` is the `*const RtBytes` the door was given, as an integer, or 0
  for an argument-free door; `code` is the reason code of §12.1.
- `bit_rt_panic_boundary_code` / `bit_rt_panic_boundary_msg` read the pair the
  last `take` recorded. They are meaningful only in the armed frame after a
  resume, and the message bytes must be copied out immediately: the record is
  reused by the next `take` and dies with the arming frame.
- **The message bytes live in the record, copied at `take` time.**
  `take` does not keep the caller's `*const RtBytes`: it copies the bytes it
  points at into the record and `bit_rt_panic_boundary_msg` answers a
  `{ptr, len}` header inside that same record. It must, because a
  `panic("... ${x}")` message is a heap string rooted only by the frames the
  resume discards — they are below `sp` afterwards and no longer scanned, and
  the record is a scalar buffer the collector does not scan for references. The
  recovering side cannot copy it safely instead: turning a raw header into a
  `string` allocates first (§11.7 forbids an `extern fn` returning a managed
  type) and that allocation is a collection point between the read of the
  header and the copy of the bytes. **The inline capacity is 256 bytes and a
  longer message is TRUNCATED to it** — the copy runs inside a panic door and
  may not allocate a bigger destination. That capacity is why a record is
  `bndWords` = 69 words (`runtime/sched/boundary.bit`): 22 context words,
  `prev`/`code`/`msg`, the two-word header, the 32 words of bytes, then 10 words
  holding the high 64 bits of `xmm6`..`xmm15` (x64 only; §9.1). A
  message-free door (§12.1) passes `msg` as 0, nothing is copied, and
  `bit_rt_panic_boundary_msg` answers 0.
- `bit_rt_fatal` is the always-fatal door — today's `rootPanic` body verbatim
  (the `panic: <msg>\n` line, the opt-in backtrace, exit 2) with **no boundary
  consult**, for a failure no program may catch: a runtime-internal invariant
  breaking. `bit_rt_oom` (§6) and `bit_rt_gc_mark_stack_overflow` are already
  separate always-fatal doors and are unaffected.

None of the six is emitted by a backend. They are called from inside the
runtime (`bit_rt_panic` and the §12.1 doors call `take`; the boundary itself
calls `arm`/`disarm`), never from generated code, so they are not part of the
directly-emitted class of §12.1 and `directEmissionSymbols`
(`tools/build/abiarity.bit`) does not grow for them. What does grow is the
`@symbol` pin population `_tests_/bit/abimembers/` counts, which reads the
providing half from the pins under `runtime/**` and the demanding half from the
compiler's own tables — it never reads this document, so a symbol specified
here and not yet provided cannot redden `test-abimembers`.

Consulting `take` is a per-door edit, and the doors are not the same set on
every OS: **windows has three argument-free panic siblings, not four** — there
is no `bit_rt_panic_overflow` in `runtime/root/windows/io.bit`, where darwin
and linux have one. That is existing state, recorded here so the per-OS work
is not read as three-quarters finished; adding a fourth windows door is a
separate decision, not part of wiring the boundary.

### 12.1 Backend-injected, argument-free panics

```
bit_rt_panic_div_zero()  -> noreturn
bit_rt_panic_overflow()  -> noreturn
bit_rt_panic_nil_call()  -> noreturn
bit_rt_panic_nil_iface() -> noreturn
```

Checks a backend inserts directly at the operation that would otherwise
fault, rather than through an `Op.RtCall`/lowering-built `RtBytes` message —
the same "emitted directly, not through the `RtFn` table" class as
`bit_rt_iface_lookup` (§2.1), and the same alloc-free-panic-path shape as
`bit_rt_oom`: each message is a **fixed, compile-time string baked into the
runtime provider itself**, packed into immediate words the way `bit_rt_oom`'s
"out of memory" is, so the report never allocates on the path that is
reporting a broken invariant.

- `bit_rt_panic_div_zero` — a zero divisor to `/` or `%` on any integer width
  (SPEC.md §13.5, §18.4). The backend compares the divisor to zero immediately
  before the hardware divide and branches to this call only on that cold path;
  a non-zero divisor never reaches it. The compile-time-power-of-two fast path
  (`xEmitPow2DivInt`/`xEmitPow2RemInt`) needs no check — its divisor is proven
  non-zero at compile time by construction.
- `bit_rt_panic_overflow` — a signed add, subtract, multiply or negate that
  overflows its result width (SPEC.md §13.5: trap in debug builds, wrap in
  release builds). One symbol covers all four operations, the same way
  `bit_rt_panic_div_zero` covers both `/` and `%` — the message does not name
  which operation trapped. Unlike the other panics in this section, the
  backend's check here is gated on debug-mode codegen, not unconditional: in a
  release build the operation wraps and this symbol is never called. Not yet
  called from any codegen path (a later change adds the checked codegen; this
  one only adds the callable symbol).
- `bit_rt_panic_nil_call` — an indirect call through a nil function value
  (SPEC.md §13.4, §18.4: "call of a `nil` function"). The backend tests the
  closure cell for null immediately before loading its `{code, env}` fields
  and branches to this call only when it is null.
- `bit_rt_panic_nil_iface` — a method call dispatched through a nil interface
  value. Not itself named in SPEC.md §18.4's enumerated list (which predates
  this fix), but the same class of broken invariant as a nil function call: an
  interface value *is* its receiver pointer (§2), so a nil receiver has no
  `TypeInfo` to dispatch through. The backend tests the receiver for null
  immediately before loading `*(recv - 16)` and branches to this call only
  when it is null.

All four are `@nosplit`, callable from anywhere a division or an indirect
call can appear (including inside another `@nosplit` function, exactly as
`bit_rt_panic` itself must be), and never return — control does not resume in
the caller on the branch that reaches them, so nothing after the call site
needs to treat their argument-free signature as clobbering anything live.

**The reason code.** These four doors cannot build a string and must
not allocate, so what they hand `bit_rt_panic_boundary_take` (§12) is a small
integer naming the reason instead of a message:

| `code` | Reason                                                     |
|--------|------------------------------------------------------------|
| `0`    | message-carrying — `msg` is a `*const RtBytes` (`bit_rt_panic`) |
| `1`    | `bit_rt_panic_div_zero`                                     |
| `2`    | `bit_rt_panic_overflow`                                     |
| `3`    | `bit_rt_panic_nil_call`                                     |
| `4`    | `bit_rt_panic_nil_iface`                                    |

A door passing a non-zero code passes `msg` as 0; the recovering side maps the
code to a fixed literal of its own, which is the only place a string for one of
these panics may be built. Codes are append-only — a new argument-free door
takes the next integer and never reuses one, because a recovering program may
have the mapping compiled into it.

## 13. Fallible results — the error channel (SPEC.md §18)

A fallible function (`T!`) returns its **ok value** exactly like a non-fallible
one — in `rax` / `x0` (or `xmm0` / `d0` for a float ok), or in the return words
of §1.2.2 for a tuple ok type — and its **error as one more return word**: the
next integer return register after the ok's integer words (#6562, on by default
since #6693).

| target             | ok words (int)        | error word, one-word ok | error word, `()!` or `f64!` |
|--------------------|-----------------------|-------------------------|-----------------------------|
| `aarch64-macos`    | `x0`, `x1`, `x2`, ... | `x1`                    | `x0`                        |
| `aarch64-linux`    | `x0`, `x1`, `x2`, ... | `x1`                    | `x0`                        |
| `x86_64-linux`     | `rax`, `rdx`, `rcx`, `rsi`, `rdi`, ... | `rdx`  | `rax`                       |
| `x86_64-windows`   | `rax`, `rdx`, `rcx`, `r8`, `r9` | `rdx` | `rax` |

The word is typed `error` (a GC object pointer), `nil` meaning ok, and the ok
words plus the error word must fit the return registers (§1.2.2: at most 4 int
ok words). It is decided from the declaration alone, like every return-word
rule, so a callee's `ret` and every call site agree without seeing each other.

The convention (a fallible callee's postcondition):

- **ok return** — runs defers, then returns the ok words and a `nil` error word.
- **`fail e`** — runs defers, then returns a zero word per ok word and `e` as the
  error word (after defers, so a deferred call cannot clobber the error).
- **`expr?`** — binds the call's words, then tests the error word; if non-nil,
  propagate: run defers and return zero ok words and that same error word. If
  nil, use the call's ok result.
- **`catch`** — binds the call's words, then tests the error word; if non-nil
  the error is handled, so evaluate the default / run the binding block; if nil,
  use the ok result.

**GC.** The error word is a pointer into the heap and has no root of its own. It
lives in a register only between the callee's `ret` and the call's single
binding move (`Op.CallWord`), and no safepoint sits in that window; from the
binding on it is an SSA value, which the safepoint root maps already cover like
any other. This is the same window argument the slot made, with nothing stored
anywhere in between.

### The slot (`BIT_ERR_REG=0`)

Code built by a pinned compiler predating register errors keeps the per-task
slot; the compiler's `BIT_ERR_REG=0` selects it too. Nothing else
reads or writes it. The slot is accessed through two symbols:

```
bit_rt_set_err(e: ?*anyopaque)  -> void   // publish (or, with nil, clear)
bit_rt_get_err()                -> ?*anyopaque   // read; non-null ⇒ failed
```

`bit_rt_set_err`/`bit_rt_get_err` (`runtime/root/slots.bit:49`/`:57`) read and
write `scrErr`, word 7 of the per-task scratch block at the base of the
running task's own stack (`runtime/sched/scratch.bit:57`) — never a
threadlocal: Mach-O refuses `@threadlocal` in the freestanding emit, and even
where a threadlocal were available, a per-OS-thread slot would not survive the
M:N scheduler migrating a goroutine to a different worker between the write
and the read. Per-task scratch does, because it travels with the task rather
than being pinned to the worker (§22).

Under the slot the convention is: an ok return leaves it **null** (cleared after
defers, so a deferred call can't leave a stale error); `fail e` runs defers,
then `bit_rt_set_err(e)`, then returns a zero ok value; `expr?` calls
`bit_rt_get_err()` after the call and, if non-null, runs defers, re-`set_err`s
the saved error (defers may have overwritten the slot) and returns a zero ok
value; `catch` calls `bit_rt_get_err()`, and if non-null `set_err(nil)`s (the
error is handled) and takes the default / binding block.

The slot is **read immediately after the call, before any yield or GC
safepoint**: codegen emits `set_err`/`get_err` back to back and both are
`@nosplit`, so no scheduling point sits between a fallible call's return and
its `?`/`catch` check. That adjacency is not what makes the slot
migration-safe — per-task scratch already is, independent of it (above) —
it is what makes the *unrooted* error pointer safe from a collection while it
sits there.

**Measured (#6691, main 2784502ef, A = `BIT_ERR_REG=0`, B = `=1`, one compiler,
Apple M5 Max).** Per `!` call on the ok path, the probe went 134.3 -> 53.2
instructions and 19.2 -> 7.8 cycles per iteration on arm64, and 152 -> 66 static
on x86-64. pkg/toml `bitbench loop`: fixture -10.9% and config -10.1% wall.
bench json: Bit/C 3.53 -> 3.28. pkg/web plaintext at c=64: +1.7% req/s. The
error-slot helpers (`set_err`, `get_err`, `port_sched_current_scratch`) went from
7.47% of pkg/toml samples to 0. One cost: x86-64 `readScalar` spill/reload sites
rose from 29 to 36 (arm64 unchanged), because the error word is one more value
live across calls in a large function.

## 14. Filesystem primitives

`bit_rt_fs_open_read_nonblocking_w` (#8128) takes packed path bytes and
returns a read-only descriptor, or -1. Symlinks are followed. POSIX opens
with `O_NONBLOCK|O_CLOEXEC`; Windows uses `CreateFileW(OPEN_EXISTING)` without
`WaitNamedPipe`, refuses non-disk handles and closes refused handles.
`std/fs/secure.openRegular` then checks the same descriptor with `statOpen`,
closes any inspection failure or nonregular descriptor, and transfers
ownership only for a regular file. No data is read before this check.

```
bit_rt_fs_open(path, write: bool) -> i64        // fd, or -1
bit_rt_fs_append(path)            -> i64        // fd opened O_APPEND, or -1
bit_rt_fs_read_all(fd)            -> string     // whole file (regular files only)
bit_rt_fs_read_all_failed()       -> bool       // see below
bit_rt_fs_read(fd, max: i64)      -> string     // up to max bytes; "" at EOF
bit_rt_fs_write(fd, s)            -> i64        // bytes written, or -1
bit_rt_fs_pread_w(fd, buf, max, off) -> i64     // positional read; count, or negative
bit_rt_fs_pwrite_w(fd, buf, n, off)  -> i64     // positional write; count, or negative
bit_rt_fs_open_rw_w(words, n)     -> i64        // O_RDWR|O_CREAT, no O_TRUNC; fd, or -1
bit_rt_fs_open_nofollow_w(words, n) -> i64      // read-only, refuses a symlinked final component; fd, or -1
bit_rt_fs_open_read_nonblocking_w(words, n) -> i64 // read-only, follows symlinks; fd, or -1
bit_rt_fs_sync(fd)                -> i64        // 0, or -1
bit_rt_fs_truncate(fd, size: i64) -> i64        // set fd's length; 0, or -1
bit_rt_fs_size(fd)                -> i64        // fd's length in bytes, or -1
bit_rt_fs_lock(fd, exclusive: bool, blocking: bool) -> i64  // whole-file advisory lock; 0/-1/-2
bit_rt_fs_unlock(fd)              -> i64        // release; 0, or -2
bit_rt_fs_sync_dir_w(words, n)    -> i64        // fsync the directory itself; 0, or -1; windows always 0
bit_rt_fs_cwd()                   -> string     // cwd, or "" on failure
bit_rt_fs_close(fd)               -> i64        // always 0
bit_rt_fs_exists(path)            -> bool
bit_rt_fs_is_dir(path)            -> bool
bit_rt_fs_mkdir(path)             -> i64        // 0, or -1
bit_rt_fs_remove(path)            -> i64        // file or empty dir; 0, or -1
bit_rt_fs_rename(oldPath, newPath) -> i64       // 0, or -1
bit_rt_fs_chmod(path, mode: i64)  -> i64        // permission bits; 0, or -1; windows maps only owner-write
bit_rt_fs_list_dir(path)          -> string     // NUL-terminated entry names
bit_rt_fs_is_symlink_w(words, n)  -> bool        // path is a symlink itself (readlink-based)
bit_rt_fs_stat_w(words, n, out)   -> i64        // fills `out`, follows a trailing symlink; 0 or -errno
bit_rt_fs_lstat_w(words, n, out)  -> i64        // fills `out`, does not follow;             0 or -errno
```

The low-level layer under `std/fs`. Deliberately plain (not fallible): failures
surface as a `-1` fd/byte-count that the Bit `std/fs` wrappers turn into real
errors (`fail newError(...)`), so all error *ergonomics* live in Bit, not the
runtime. Backed by the per-platform `rtFs*` primitives in `runtime/root/linux/fs.bit`
and `runtime/root/darwin/fs.bit`: Linux issues raw syscall numbers directly (no
libc), Darwin calls the bare libc externs declared at the top of that file and
goes through libSystem — Apple publishes no stable syscall numbers, so this side
is NOT libc-free. Neither platform has a separate `fileSize` helper;
`lseek(SEEK_END)` inline in `rtFsReadAll` computes it.

- `fs_open` copies the (non-NUL-terminated) Bit path into a bounded
  module-level scratch buffer (sound only under the single-worker contract,
  §5) before the syscall; `write=false` opens read-only, `write=true`
  creates+truncates write-only (mode `0644`).
- `fs_read_all` sizes the result with `lseek(SEEK_END)` then reads, so it
  targets regular files. An `lseek` failure and an allocation failure for a
  file already known non-empty both report through the out-of-band companion
  symbol `bit_rt_fs_read_all_failed()` (below); a genuine empty file (`lseek`
  reports 0) never does — `string` has no nil sentinel to carry the
  distinction in-band, which is why the flag exists at all. The one earlier
  attempt to add this signal was reverted because the pinned stage0's
  `libbitrt.a` predated the symbol: `std/fs` referencing it made the
  clean-tree driver build fail `E0078` against the OLD pinned archive, and
  repinning to a release that predates the symbol cannot make it appear
  — a cycle, not a wait. **The two-pass landing pattern broke the cycle in two
  passes.** Pass 1 re-added `bit_rt_fs_read_all_failed` and its setter
  (`runtime/root/slots.bit`) with no caller anywhere on the driver's import
  path, so the clean-tree build kept linking the OLD pinned archive without
  complaint; that landed in `v0.1.17`. Once the stage0 pin moved to `v0.1.17`,
  pass 2 wired `rtFsReadAll`'s `end < 0` and `s == 0` branches to the
  setter and `stdlib/fs/fs.bit`'s `File.readAll` to the getter — `fail
  newError(...)` on a read failure, same as `open`/`create`/`write`. The read
  loop's own I/O-error paths (an interrupted-but-failed read, or the retry
  budget exhausted before EOF) are NOT wired to the flag; those still trim
  silently to the bytes actually read. A short read — EOF before `end`, or an
  I/O error partway through — is NEVER zero-padded: the result is the
  string TRIMMED to the bytes actually verified read, retrying on `EINTR` up
  to `maxReadAllRetries` (1000) times.
- `fs_close` reports success unconditionally (the raw wrapper swallows
  `EINTR`/`EBADF`).
- `fs_pread_w`/`fs_pwrite_w` transfer bytes at an EXPLICIT offset
  instead of a shared file cursor, so several green threads may issue
  positional calls on the same `fd` concurrently without racing over
  position — the reason this pair exists rather than a stateful `seek`, which
  a shared fd cannot safely carry across concurrent callers. `buf` is a
  `[]byte`'s packed backing store (§2), the same convention
  `bit_rt_fs_is_symlink_w` uses, not a Bit `string`. Darwin and Linux use
  `pread(2)`/`pwrite(2)` — Linux issues the raw `pread64`/`pwrite64` syscall
  numbers directly, no libc; Darwin calls the bare libc externs. Windows uses
  `ReadFile`/`WriteFile` with a synchronous-mode `OVERLAPPED` carrying the
  offset — MSDN documents that a handle opened WITHOUT
  `FILE_FLAG_OVERLAPPED` still honors a non-NULL `lpOverlapped`'s byte
  offset, performing the transfer synchronously without moving the handle's
  own file position, which is the standard Win32 substitute for POSIX
  `pread`/`pwrite`. All three return the byte count transferred, or a
  negative value on any I/O error; a SHORT count — including 0 at end of
  file — is never an error, exactly as `fs_read` above. **No `stdlib/`
  caller exists yet** — the same `tools/build/` bootstrap cycle the
  `stat_w`/`lstat_w` bullet and the `fs_sync` bullet both describe:
  `tools/build/artifacts.bit` imports `std/fs`, which the PINNED stage0
  compiles against its own frozen `libbitrt.a`, so a `stdlib/fs/fs.bit`
  reference to either symbol breaks the driver bootstrap with E0078 on every
  fresh clone until a release ships this commit and the pin moves. This
  landing is pass 1 of a deliberate two-pass sequence: the runtime
  primitives only, no consumer. Pass 2 (`File.readAt`/`File.writeAt` methods
  in `stdlib/fs/fs.bit`) is a follow-up, gated on a release containing
  this commit and a stage0 repin to it.
- `fs_sync` flushes `fd`'s already-written bytes to stable storage,
  0 on success, -1 on any failure — a successful `fs_write` only reaches the
  OS page cache, and pulling power before `fs_sync` returns can still lose
  it. **Bare `fsync(2)` is not durable on Darwin**: it stops at the drive's
  write cache. Apple documents `fcntl(fd, F_FULLFSYNC, 0)` (`man 2 fsync`'s
  CAVEATS section) as the call that actually forces the platter, so Darwin's
  provider calls that first and falls back to bare `fsync` only when it
  returns `ENOTSUP` (some older exFAT/SMB mounts reject `F_FULLFSYNC`
  outright); any other failure is reported as-is, never silently downgraded
  to the weaker call. Linux's raw `fsync` syscall is already the durable
  call, no fallback needed. Windows' provider calls `FlushFileBuffers`,
  which per MSDN forces the OS cache and any intermediate hardware cache to
  the physical device. **No `stdlib/` caller exists yet** — the same
  `tools/build/` bootstrap cycle the `stat_w`/`lstat_w` bullet describes
  below applies here too: `tools/build/artifacts.bit` imports `std/fs`, which
  the PINNED stage0 compiles against its own frozen `libbitrt.a`, so a
  `stdlib/fs/fs.bit` reference to this symbol breaks the driver bootstrap
  with E0078 on every fresh clone until a release ships this commit and the
  pin moves. This landing is pass 1 of a deliberate two-pass sequence: the runtime
  primitives only, no consumer. Pass 2 (a `File.sync()` method in
  `stdlib/fs/fs.bit`) is a follow-up, gated on a release containing
  this commit and a stage0 repin to it.
- `fs_truncate`/`fs_size` set and read `fd`'s length. Darwin and
  Linux call `ftruncate(2)`/`fstat(2)` — Darwin via the bare libc externs,
  Linux via the raw `ftruncate`/`fstat` syscall numbers, no libc. Windows'
  `fs_truncate` saves the handle's current position with
  `SetFilePointerEx(FILE_CURRENT)`, moves it to `size` with
  `SetFilePointerEx(FILE_BEGIN)`, calls `SetEndOfFile`, then restores the
  saved position — so on all three platforms `fs_truncate` never moves the
  fd's own read/write cursor, matching `fs_pread_w`/`fs_pwrite_w`'s
  cursor-free contract above. `fs_size` uses `GetFileSizeEx` on Windows.
  Growing does not allocate blocks: the new region reads as zeros and the
  space is not reserved, so a later write can still fail with `ENOSPC` — a
  hole, not `fallocate`. Neither call itself flushes; the new length needs
  `fs_sync` like any other metadata change before it is durable. Both return
  a negative value on any failure — the OS itself rejects a negative `size`
  before `fs_truncate`'s own body runs, verified on Darwin and Linux (`-1`,
  no crash). **No `stdlib/` caller exists yet** — the same `tools/build/`
  bootstrap cycle the `stat_w`/`lstat_w` bullet below describes:
  `tools/build/artifacts.bit` imports `std/fs`, which the PINNED stage0
  compiles against its own frozen `libbitrt.a`, so a `stdlib/fs/fs.bit`
  reference to either symbol breaks the driver bootstrap with E0078 on every
  fresh clone until a release ships this commit and the pin moves. This
  landing is pass 1 of a deliberate two-pass sequence: the runtime primitives only,
  no consumer. Pass 2 (`File.truncate()`/`File.size()` methods in
  `stdlib/fs/fs.bit`) is a follow-up, gated on a release
  containing this commit and a stage0 repin to it.
- `fs_lock`/`fs_unlock` take/release a WHOLE-FILE advisory lock on
  `fd`, exclusive or shared, blocking or non-blocking. Darwin and Linux both
  call `flock(2)` — Darwin via the bare libc extern, Linux via the raw
  syscall number (73 on x86-64, 32 on aarch64) — deliberately NOT
  `fcntl(F_SETLK/F_SETLKW)`: an `fcntl` lock is released the instant ANY fd
  for the file closes anywhere in the process, even an unrelated one in
  library code, and `fcntl` locks are keyed on (process, inode) rather than
  fd, so a second `open()` of the same file by the SAME process would never
  conflict with the first under `fcntl` — `flock`'s lock is keyed on the
  OPEN FILE DESCRIPTION instead, so two fds from two separate opens
  correctly contend even within one process, which the stdlib-level
  acceptance test (once it lands) exercises directly. This also means
  Unix needs no explicit unlock-on-close: `flock` releases automatically
  when the last fd referring to that open file description closes, so
  `fs_close` needs no change. Windows has no such guarantee (undocumented
  behaviour on close per Win32 convention) and calls `LockFileEx`/
  `UnlockFileEx` instead, locking the `MAXDWORD`/`MAXDWORD` byte range at
  offset 0 — Microsoft's own documented whole-file convention, since Win32
  has no separate whole-file lock call — so the STDLIB `close()` wrapper
  MUST call `fs_unlock` before `fs_close` on that platform once it lands.
  `fs_lock` blocks indefinitely when `blocking` is true (bracketed with
  `gcSyscallBegin`/`gcSyscallEnd`, plus a bounded `EINTR` retry on
  Darwin/Linux, the same shape `fs_read_all`'s loop uses); non-blocking is a
  single unbracketed attempt. Both return a normalized THREE-WAY result,
  deliberately not the raw `-errno` convention `stat_w`/`lstat_w` use:
  `0` on success; `-1` only when `blocking` is false and
  the lock is held elsewhere (`EWOULDBLOCK` on Darwin/Linux,
  `ERROR_LOCK_VIOLATION` on Windows) — the expected outcome for
  `tryLock`/`tryLockShared`, not a failure; `-2` for any other error. Each
  provider normalizes its own platform-specific busy signal to this fixed
  sentinel internally, so the eventual `std/fs` caller needs no
  per-platform errno/`GetLastError` knowledge at all. `fs_unlock` is a
  no-op success on an fd/handle that holds no lock, on every platform
  (Windows folds `ERROR_NOT_LOCKED` into success specifically to match
  `flock(LOCK_UN)`'s native no-op behaviour), so a caller never needs to
  track whether it currently holds a lock before releasing it. Verified with
  a standalone probe on real aarch64-macos and real x86_64-linux hardware
  (14/14 assertions each: exclusive excludes exclusive and shared, shared
  coexists with shared, unlock releases, a fresh open after `File.close()`
  observes the lock gone, unlock-when-never-locked is a no-op) and
  mutation-tested on both (a wrong `EWOULDBLOCK` constant on Darwin and a
  wrong syscall number on Linux each turned every affected assertion red;
  reverting restored all-pass). Windows verified compile+link only — no
  hardware available this session — via a freestanding cross-build of
  `runtime/root/windows` confirming `bit_rt_fs_lock`/`bit_rt_fs_unlock` are
  defined and `LockFileEx`/`UnlockFileEx`/`GetLastError` resolve as PE
  imports. **No `stdlib/` caller exists yet**, the same `tools/build/`
  bootstrap cycle the `fs_truncate`/`fs_size` bullet above describes: this
  landing is pass 1 of a deliberate two-pass sequence, the runtime primitives only,
  no consumer. Pass 2 (`File.lock()`/`tryLock()`/`lockShared()`/
  `tryLockShared()`/`unlock()` in `stdlib/fs/fs.bit`) is a follow-up,
  gated on a release containing this commit and a stage0 repin to it.
- `fs_open_nofollow_w` opens the `n` path bytes at `words` read-only
  and REFUSES the open when the FINAL path component is a symlink, instead of
  following it. It exists because no composition of the existing primitives
  can do this: `fs_is_symlink_w` answers about a PATH, so a caller that probes
  first and calls `fs_open` second loses to whoever can replace that name in
  between, which is exactly the window this primitive closes by using
  O_NOFOLLOW on the final open plus fstat. Packed-bytes `(words, n)`, like
  `fs_open_rw_w`/`fs_is_symlink_w`/`fs_stat_w`/`fs_lstat_w` above, for the
  same §11.7 reason. Only the FINAL component is protected: an intermediate
  directory component that is a symlink is still traversed, exactly as
  `open(2)`'s own `O_NOFOLLOW` specifies. A DIRECTORY is refused on all three
  platforms, matching `fs_open`'s directory-refusal guard — `O_RDONLY` on a directory
  succeeds on darwin and linux and would hand back a `File` no read can fill.
  Darwin and Linux pass `O_NOFOLLOW` on the read-only open and let the kernel
  fail it with `ELOOP` — Darwin's value is `0x100`; Linux's is PER-ARCH
  (`runtime/root/linux/fs.bit`): `0o400000` on x86_64, but aarch64 does
  NOT use `asm-generic/fcntl.h` for this bit — `arch/arm64/include/uapi/asm/
  fcntl.h` overrides it to `0o100000`, and `0o400000` is `O_LARGEFILE` there
  instead, a harmless no-op that silently let the open follow the symlink.
  **Windows inverts
  the shape and REFUSES a reparse point rather than following it**: it has no
  `O_NOFOLLOW`, so `CreateFileW` is given `FILE_FLAG_OPEN_REPARSE_POINT`,
  which SUCCEEDS on the link itself, and the provider then reads
  `GetFileInformationByHandle`'s `dwFileAttributes` on the handle it just
  opened and returns -1 when `FILE_ATTRIBUTE_REPARSE_POINT` is set, closing
  the handle. Asking the HANDLE rather than the path is what makes that a
  refusal rather than a second check-then-open race. A successful open of a
  reparse point is not this primitive's contract on any platform. The return
  is a flat fd/handle or -1 — a malformed path, a directory, a symlink and an
  ordinary open failure are indistinguishable to the caller. **No `stdlib/`
  caller exists yet**: this landing is pass 1 of a deliberate two-pass sequence, the
  runtime primitive only, for the same `tools/build` bootstrap cycle the
  `fs_sync_dir_w` bullet below describes — pass 2 is the `std/fs` half,
  gated on a stage0 repin past this commit.
- `fs_sync_dir_w` fsyncs the DIRECTORY named by the `n` path bytes at
  `words`, not a file inside it — durability for the directory ENTRY a
  newly created file needs, not for that file's contents. `fs_sync`ing a
  freshly written file only guarantees its own blocks reach disk; on ext4
  and several other filesystems the directory entry that gives the file its
  name is separate metadata and is not guaranteed durable until the
  containing directory is itself fsynced — SQLite fsyncs its database's
  containing directory after creating the journal file for exactly this
  reason. Packed-bytes `(words, n)`, like `fs_open_rw_w`/`fs_is_symlink_w`/
  `fs_stat_w`/`fs_lstat_w` above — the `_w` shape every path-taking primitive
  with no compiler-builtin call form uses, since §11.7 admits no `string`
  across a plain `extern fn` boundary and this one has no reason to earn a
  new compiler builtin the way `fs_open`/`fs_read`/… have. Darwin and Linux
  both open the directory read-only (`open(O_RDONLY)` succeeds on a
  directory on both platforms, the same fact `fs_is_dir`'s probe already
  relies on) and reuse `fs_sync`'s own provider on the resulting fd —
  Darwin's `F_FULLFSYNC`/`ENOTSUP`-fallback `fcntl`, Linux's raw `fsync(2)`
  syscall — since a directory fd answers the identical call as a regular
  file's. **Windows is a documented successful no-op — no path validation,
  no handle opened, no syscall at all** — NTFS journals directory-entry
  creation as part of its own metadata transaction log (`$LogFile`), so an
  entry NTFS has already reported as created is already durably ordered with
  respect to the file; there is no Win32 call to make here and none is
  needed. A caller must not read the no-op as this call being a silent
  failure on Windows: it is a genuine, documented success. `fs_sync_dir_w`
  does not validate that the path names a directory rather than a regular
  file — a regular-file path opens and fsyncs successfully like any other
  fd, which is why that check belongs to the `stdlib/` caller (mirroring
  `readDir`'s own `is_dir` guard before it lists), not to this primitive.
  The caller is `std/fs`'s `syncDir` (pass 2 of the same two-pass sequence),
  which landed once the 0.13.0 pin carried this symbol in its own
  `libbitrt.a` — until then declaring the `extern` in `stdlib/fs/fs.bit`
  broke `tools/build`'s cold bootstrap with E0078, the same cycle the
  `fs_truncate`/`fs_size` bullet above describes.
- `fs_cwd` takes NO argument — nothing to encode through
  `fsPathZ`/`checkedPathW`. It shares that with `fs_read_all_failed` above,
  the family's only other zero-argument entry point. Darwin and Linux both
  call `getcwd` (libc on Darwin, the raw syscall on Linux — kernel
  `fs/d_path.c`'s `SYSCALL_DEFINE2(getcwd, ...)` returns the byte count
  INCLUDING the trailing NUL on success, unlike a `read`, so the wrapper trims
  one byte off), sized to `max_path` (4096) and rejected — never truncated —
  if the result would not fit. Windows calls `GetCurrentDirectoryW` into a
  `MAX_PATH` (260-unit) UTF-16LE scratch buffer, then decodes through the same
  `winUtf16ToUtf8` boundary every other Windows path-taking primitive uses.
  Empty string on any failure (`getcwd` returning NULL/negative-errno,
  `GetCurrentDirectoryW` returning 0, or either result not fitting its
  platform's ceiling) — the same flat-failure shape `fs_open`/`fs_mkdir`
  already use, no companion out-of-band flag. **No `stdlib/` caller exists
  yet** — the identical `tools/build/` bootstrap cycle the `stat_w`/`lstat_w`
  and `fs_sync` bullets describe: `tools/build/artifacts.bit` imports `std/fs`, which the
  PINNED stage0 compiles against its own frozen `libbitrt.a`, so a
  `stdlib/fs/fs.bit` reference to `bit_rt_fs_cwd` breaks the driver bootstrap
  with E0078 on every fresh clone until a release ships this commit and the
  pin moves. This landing is pass 1 of a deliberate two-pass sequence: the runtime
  primitive only, no consumer. Pass 2 (a `std/fs` function surfacing it) is a
  follow-up, gated on a release containing this commit and a stage0
  repin to it.
- `fs_read` reads once and returns what it got, so it is the primitive for
  pipes, sockets, and stdin — none of which have a size to seek to.
- `fs_list_dir` separates entries with a **NUL** byte, the one byte a POSIX
  filename cannot contain (a newline can). `.` and `..` are omitted. An empty
  result means either an empty directory or an unreadable one; `std/fs` calls
  `is_dir` first to tell them apart.
- `fs_list_dir_bounded_w(words, n, out, cap)` lists into a caller-owned
  packed-byte buffer in one pass. The path uses the existing `_w` convention.
  It returns the complete NUL-separated byte count, `-1` for invalid inputs,
  enumeration or close failures, and `-2` when the next name exceeds `cap`.
  A partial buffer is never a successful result. `cap` must be positive and
  at most `9223372036854775804`, so the `cap + 3` iteration bound cannot overflow.
  Each non-dot entry consumes at least two bytes. Linux uses the existing
  fixed-size getdents buffer; Darwin and Windows inspect one entry at a time.
  Every outcome closes the directory handle. `std/fs/secure` owns the wrapper,
  keeping this new extern outside the pinned compiler's bootstrap import graph.
- `exists` opens `path` rather than probing directory-ness — Darwin via
  `access(F_OK)`, Linux via an `open` immediately closed again on success — so
  a mode-000 file, or a directory hit by an fd-exhausted process, still
  reports present; only `ENOENT`/`ENOTDIR` mean genuinely absent.
  `is_dir` is the one that actually distinguishes a directory: Darwin's
  `opendir` succeeding, Linux's `getdents64` succeeding on the opened fd.
- `is_symlink_w` was the FIRST path-taking `bit_rt_fs_*` entry point to drop
  the Bit `string` argument; `open_rw_w`, `stat_w`, `lstat_w` and
  `sync_dir_w` have since followed it. Its caller is `std/fs`, which can reach
  a runtime symbol only through an `extern function` (SPEC §11.7), and §11.7
  admits no `string` across that boundary — so `words` is the raw backing
  store of a Bit `[]byte` instead, `n` **packed** bytes (§2), not
  NUL-terminated and not an `RtBytes`. The provider copies those bytes into
  its own NUL-terminated buffer before probing it, applying the same
  `max_path` and embedded-NUL rejections every other path-taking entry point
  applies. It answers with `readlink`, not `lstat` + `S_IFLNK`:
  `readlink` succeeds only on a symbolic link and needs no POSIX `stat`
  structure layout, so a dangling link still answers `true` — the link exists
  whether its target does or not.
- `stat_w`/`lstat_w` share `is_symlink_w`'s `words`/`n` path
  encoding, for the identical reason — a `std/fs` caller can reach them only
  through `extern fn`, which admits no `string` (SPEC §11.7). `out` is a
  caller-owned 5-word buffer the provider fills in fixed order: `size`,
  `mtime` (seconds since the Unix epoch), `mode` (the low 12 permission
  bits), `isDir` (0/1), `isSymlink` (0/1). `stat_w` follows a trailing
  symlink (`isSymlink` is therefore always 0 in its result); `lstat_w` does
  not, and reports whether `words` itself is a link. Unlike every other
  `bit_rt_fs_*` primitive above, a failure is **not** a flat `-1`: the return
  is 0 on success or `-errno` on failure, the same convention the net
  primitives use. Darwin's `stat`/`lstat` set a *positive* errno reachable
  through `__error()`; the provider negates it. Linux's raw `syscall`
  already returns `-errno` directly on failure, passed through unchanged.
  **No `stdlib/` caller exists yet.** This landed once before (`03cbbd41`)
  wiring both the runtime and a `stdlib/fs` consumer in one commit, and was
  reverted (`0dd25c35`): the pinned stage0 that compiles `tools/build/` links
  its own frozen release runtime, which had never shipped these symbols, so
  the `stdlib/` reference broke `./make`'s driver bootstrap with E0078 on
  every fresh clone. This landing is pass 1 of a deliberate two-pass sequence: the
  runtime primitives only, no consumer, so nothing on the driver's import
  path references them. Pass 2 (the `FileInfo` class and `stat`/`lstat`
  wrappers in `stdlib/fs/fs.bit`) is a follow-up, gated on a release
  containing this commit and a stage0 repin to it.
- `fs_rename` is the only `bit_rt_fs_*` entry point that needs two encoded
  paths live at the same time, and that is why it is backed by two separate
  scratch buffers instead of the one every other path-taking entry point
  shares. `oldPath` still goes through `fsPathZ`/`checkedPathZ` into the usual
  module-level `fsPathBuf`; `newPath` goes through a second, distinct pair —
  `fsPathZ2`/`checkedPathZ2` into `fsPathBuf2` (`runtime/root/fs.bit`)
  — so `rename(2)`/`sysRename` receives two pointers that can never alias.
  Encoding `newPath` through the shared `fsPathBuf` a second time, the way
  every single-path entry point does, would overwrite `oldPath`'s bytes
  before the syscall ever reads them, handing it the same pointer twice.
  Darwin dispatches to the libc `rename` extern; Linux has no libc and issues
  the raw syscall itself — `rename` (nr 82) on x86_64, `renameat(AT_FDCWD,
  old, AT_FDCWD, new)` (nr 38) on aarch64, which dropped the bare `rename`
  syscall. 0 on success, -1 on failure — the same shape `fs_remove` returns.

**These calls block their worker's OS thread for the syscall's duration, and
that is not a netpoller gap.** POSIX has no non-blocking read of a regular file:
`epoll`/`kqueue` always report one as ready. The netpoller (§11) exists for
sockets and pipes. A file read therefore stalls one worker: other green threads on other
workers keep running, and the tasks queued behind it on its own worker are
retaken within a few milliseconds by a new worker started from the monitor
thread (§9, "Retaking a blocked worker", #7128). Windows uses the same
blocked-worker replacement for a bracketed file read.

---


[Previous: Program boot, workers, and task entry](boot-and-spawn.md) | [Next: Collections, time, and operating-system services](collections-time-and-io.md)
