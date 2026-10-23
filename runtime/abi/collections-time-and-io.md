# Collections, time, and operating-system services

[Runtime ABI](../ABI.md)

## 15. Maps (`runtime/root`)

`map<K,V>` (SPEC §11.2, §13.5) is a `MapHeader` GC object naming ONE slot
table — an open-addressing hash table with linear probing. Compiled code never
reads either layout; it calls the entry points below.

```
MapHeader {
  tbl:  *MapTable       // +0   the current table — traced; replaced whole by a grow
  len:  usize           // +8   live entries
  used: usize           // +16  FULL + TOMB (drives growth)
  key_desc: usize       // +24  0 scalar / 1 string / else a descriptor (§15.1)
  val_is_ref:    usize  // +32
}

MapTable {
  cap:  usize           // +0   slot count (power of two, >= 8)
  keys: [*]u64          // +8   slot keys   (ref-array iff key_desc != 0) — traced
  vals: [*]u64          // +16  slot values (ref-array iff val_is_ref)    — traced
  ctrl: [cap]u8         // +24  per-slot state, inline: 0 EMPTY / 1 TOMB / 128|tag FULL
}
```

A table's `cap`/`keys`/`vals` are written once, before a release store
publishes it into `tbl`, and never after; every operation loads `tbl` once and
indexes only that table (#5796, `runtime/root/maptable.bit`). That load is
plain: every later read takes its address from it, and both targets order an
address-dependent load after the load it depends on. `map_info`'s
pointer map is `{0}`; `map_tbl_info`'s is `{8, 16}` with a declared size of 24,
so the inline ctrl bytes past it are untraced. The two buffer bases are traced
as references. The `keys`/`vals` buffers use `ref_array_info` (every word traced)
exactly when their flag is set — for `keys` that is `key_desc != 0`, i.e. every
reference key type, `string` and composite alike. The `ctrl` buffer is always a
leaf; tracing its base only keeps it alive. Empty, tombstoned, and unused slots
hold a zero key/value word, which `markRoot` skips.

`key_desc` itself is NOT traced and must not be: it is either a small integer or
the handle of a string CONSTANT, which is static for the life of the process.

- **Word model.** A key or value is one word, same as slice elements (§2): a
  scalar by value, a `string` as its `*RtBytes` object base, a wider `V` boxed (a `decimal`: its tuple pointer, `val_is_ref` set, #6570).
- **Hash / equality.** `key_desc` picks the strategy: `0` hashes the word with a
  splitmix64 finalizer (so low-entropy integer keys avalanche) and compares by
  word; `1` Wyhashes a string key over its bytes and compares byte-wise; anything
  else is a composite key hashed and compared through its descriptor (§15.1).
- **Seed.** Every hash is keyed by one per-process seed (#7379, §7
  `BIT_HASH_SEED`), drawn at boot and never changed after, so slot order and
  iteration order differ between processes. `bit_rt_map_hash_seed() -> u64` returns
  it, for a hash computed outside this module to agree with these.
- **Growth.** At `(used+1)*8 >= cap*7` the table doubles and rehashes, dropping
  tombstones (`used` resets to `len`). This keeps an EMPTY slot present at all
  times, so every probe terminates in `<= cap` steps (a statically bounded loop).
- **Capacity hint** (`map<K,V>(n)`, SPEC §11.2/§12.9). `map_new`'s
  `cap_hint` picks the initial `cap` directly instead of starting at
  `mapInitCap` and growing there: the smallest power of two with
  `cap*7 > n*8`, so `n` entries can be inserted without an immediate grow.
  ADVISORY, never a correctness input — `n <= 0` or an `n*8` overflow both fall
  back to `mapInitCap` and the map still grows normally past whatever `n`
  under-promised (`mapCapForHint`, `runtime/root/maps.bit`).
- **Delete** leaves a `TOMB` and zeroes the slot's key word, and its value word
  when `val_is_ref` (dropping the refs so a removed entry becomes collectable);
  the tombstone is reclaimed at the next grow, which rehashes at the SAME `cap`
  while the live count is at most 5/8 of it and doubles otherwise, so a steady
  set under insert/delete churn keeps a fixed table and pays an amortized O(1)
  rehash per insert (#5813). An insert never claims a `TOMB`,
  only an `EMPTY` slot, so a slot belongs to one key until the table is replaced
  and a reader holding that slot (the `map_slot` token, or `map_get` between its
  key compare and its value load) cannot be handed another key's value by a
  racing `delete` + insert (#5813).
- **Nil.** Reads on a nil map (`?*MapHeader == null`) yield the zero word /
  `false` / `0`; `map_set` on a nil map is fatal (SPEC §11.2, Go semantics).
- **Two-result read** (`let (v, ok) = m[k]`, §12.6) is ONE probe: `map_slot`
  returns a non-negative TOKEN on a hit or `-1`, `ok` is `slot >= 0`, and
  `map_val_at` reads the value word (yielding `0` for the `-1`). It used to be
  `map_get` + `map_has` — two probes of the same key for one expression. The
  token is `2^62` plus the address of the value word in the table the probe
  used, not an index, so a grow between the two calls cannot hand back another
  key's value (#5796). It is valid only for the `map_val_at` codegen emits
  immediately after it, under the adjacency contract (§5.1): with no poll
  between the calls no collection can free that table.
- **String-key reads by words** (#5906). `map_get_str`/`map_slot_str` are
  `map_get`/`map_slot` for a `map<string, _>` key passed as `(ptr, len)`: the
  same hash over the same bytes, so a key stored through a header is found
  through its words. The compiler emits them when the key is a `string` box it
  just built (an exploded local or an `s[lo:hi]` view), which then needs no
  allocation; a key that already is a handle still goes to `map_get`/`map_slot`.
  The caller keeps `base` live across the call; both entries are `@nosplit`.
- **Iteration** (`for (k, v) of m`, §13.5) is by slot cursor: `map_iter_init`
  returns the first FULL slot or `-1`, `map_iter_next` the next after `prev`,
  then `map_key_at`/`map_val_at` read the pair. Slot order is unspecified and the
  protocol assumes no concurrent mutation (a resize would invalidate the cursor).
  An iteration slot is a plain index, below `2^62`, into the current table;
  `map_key_at`/`map_val_at` read an index that table does not have as `0`.

### 15.1 Composite values — descriptor programs

| symbol | signature |
|---|---|
| `bit_rt_value_eq` | `(a: usize, b: usize, desc: *const RtBytes) -> bool` |

SPEC §14.6 makes a class comparable **field-wise** and a tuple **element-wise**.
Both are one traced handle to a heap box (§1, §1.1), so comparing the word asks
"same allocation?" — which is what `==` did, and what the map hashed keys by.

**The runtime cannot recover the shape on its own.** A `TypeInfo` (§2) says which
body words hold references but not what kind: a `string` field and a nested
class field are both one traced word. Worse, a string LITERAL is a static
`{ptr,len}` pair in `.data` with no GC header at all, so there is no descriptor
to read off it. The compiler therefore emits a **descriptor program** — a string
constant, one byte per body word — and passes it at the comparison site and to
`map_new`.

```
'{' item* '}'    an aggregate; its items describe consecutive 8-byte body words
'w'              a raw word, compared and hashed BY VALUE
's'              a `string` handle, compared and hashed BY ITS BYTES
'r'              an opaque reference (slice, map, chan, func, interface),
                 compared and hashed BY IDENTITY
'e' block* ')'   a boxed payload enum: `block` is one `"{...}"`
                 payload program per variant, in declaration order, over the
                 words past the tag (§1.2). The tag is read directly and
                 compared/mixed by the dispatcher; which block applies is a
                 RUNTIME question, so this cannot flatten into a plain '{...}'
'{' ... '}'      a nested class or tuple: dereferenced and walked
```

`class P { x: int, name: string }` is `{ws}`; `class Q { p: P, n: int }` is
`{{ws}w}`; `enum Port { Default, Explicit(int) }` is `e{}{w})`. The producer is
`descProgram`/`descEnumProgram` in `compiler/lowerdesc.bit`; the consumers are
`descEqAgg`/`descHashAgg` in `runtime/root/maps.bit` and
`descEqEnumChild`/`descHashEnumChild` in `runtime/root/mapenumeq.bit`.

- **Equality and hashing are ONE walk.** The two interpreters read the same
  program and take the same cases in the same order, so `eq(a,b)` implies
  `hash(a) == hash(b)` case by case. A hash that disagreed with equality gives a
  map that silently loses entries, so this correspondence is a contract, not an
  optimisation: the two functions must be edited together.
- **Bounds.** The generator stops at 6 levels of nesting and a 96-word total
  budget, emitting `'r'` past either; the interpreters stop at 8 levels. Every
  loop in both is bounded by the program's length.
- **Floats compare by bit pattern inside a composite**, where a bare `f64 ==` is
  IEEE. This keeps composite equality reflexive — a key not equal to itself
  could never be found or deleted — and matches what a bare `map<f64,int>` key
  already does. `+0.0` and `-0.0` therefore differ in a field.
- **A field whose type is not comparable at all never reaches lowering:**
  the checker's `vComparable` (`compiler/validateattr.bit`) recurses into
  a class's fields and a boxed enum's variant payloads and rejects such a type
  at compile time, naming the offending field or variant. `'r'` remains the
  depth/budget backstop below for a field that IS comparable but too deep or
  wide to describe.

---

## 16. Test selection (`bit test`)

```
bit_rt_test_index() -> i64   // BIT_TEST_INDEX, or -1 when unset/unparsable
```

The one runtime hook `bit test` (SPEC §19) needs. `boot` captures the process
environment block; this reads `BIT_TEST_INDEX` out of it.

A failed `assert` panics, which aborts the process — so the runner cannot loop
over tests in one process without the first failure taking the rest down. It
instead compiles the module **once**, with `compiler/testgen.bit` appending a
synthetic `main` that calls this function and dispatches to that single test,
then execs the binary once per test with `BIT_TEST_INDEX` set. An unset or
out-of-range index matches no test and returns cleanly, so running a test binary
by hand is a harmless no-op.

---

## 17. Math (`runtime/root`)

The low-level layer under `std/math`. `floor`/`ceil`/`round`/`trunc`/`sqrt` are
single instructions on both targets; `pow`/`atan2`/`log`/`log2`/`log10` are the
toolchain's own libm-free implementations.

**`sin`, `cos`, `tan`, and `exp` are deliberately absent.** The toolchain exposes
them only as builtins that lower to libm calls (`sin`, `exp`, …), and a Bit
binary links no libc. They arrive with a freestanding implementation, not as a
silently-approximate stand-in.

> The `log` family is table-driven, which is what made it the first thing to
> notice the AArch64 mapping-symbol bug: a mis-atomized `.rodata` literal pool
> shifted the lookup tables and these returned garbage while table-free fast
> paths stayed exact. `_tests_/cases/run_math.bit` guards that.

**`bit_rt_float_bits`/`bit_rt_float32_bits` are not math functions — they
reinterpret an f64/f32's IEEE-754 bit pattern as a same-width unsigned integer
with no value conversion** (`FMOV`/`movq` on both targets). They are the only
way a Bit program can observe `-0.0` or distinguish two NaN payloads, since
`==` reports `-0.0 == +0.0` as true and `NaN == NaN` as false either way.
The compiler's own `floatBits`/`float32Bits` primitives lower to
an inline `Op.Bitcast`, not an `ir.RtFn` call (`compiler/lowerprim.bit`), so
neither pinned symbol is reached by generated code — `_tests_/bit/rootpins/`
proves that (§9). The exports (`runtime/root/floats.bit:121-129`) remain
because `_tests_/stress/rootfloat` links and calls them directly as ordinary
`bit_rt_*` C ABI entry points, and because they are `runtime/root`'s port of
the same-named symbols the pre-selfhost runtime shipped.

---

## 18. Time (`runtime/root` + `runtime/sched`)

```
bit_rt_time_mono_ns()      -> i64   // monotonic; the only clock that measures elapsed time
bit_rt_time_unix_ns()      -> i64   // wall clock, ns since the Unix epoch; may jump
bit_rt_time_sleep_ns(ns)   -> void  // park this green thread for >= ns
```

`bit_rt_time_sleep_ns` converts the relative `ns` to an absolute monotonic
deadline (`bit_rt_time_mono_ns() + ns`) and clamps that deadline to `i64max`
nanoseconds rather than let the addition overflow and wrap negative, so a
duration near `i64max` never wakes early.

`sleep` records a deadline on the `Task`, then `park`s with a `ParkFn` that
links it onto the scheduler's `TimerQueue` — the same "register only after the
context is safely saved" point the netpoller uses (§11), which is what
guarantees the task is observably `.parked` before another worker can wake it.

A worker expires due timers on its **idle** path, before polling the netpoller,
and its idle backoff is capped at 1ms — so once a worker has nothing else to
run, a timer fires within about a millisecond of its deadline. A deadline never
preempts a running task, consistent with the cooperative scheduler (a CPU-bound
task already starves its worker).

`TimerQueue` is an unsorted intrusive list: O(1) insert, and `expire` is one
bounded pass over the live sleepers. A thousand green threads sleeping 50ms
finish together, in ~50ms, on one OS thread.

### 18.1 Linux clocks read through the vDSO (#5959)

On Linux both clocks (`bit_rt_time_mono_ns`, `bit_rt_time_unix_ns`, and the
runtime's own `parkMonoNs`) call `parkClockRead`
(`runtime/park/linux/vdso.bit`): the kernel vDSO's `clock_gettime` when boot
resolved it, the raw syscall otherwise. Measured on an x86_64 host (kernel
7.0.14): 1015-1030 ns per `std/time` clock read through the syscall,
26-34 ns through the vDSO; the pkg/web bench server made 8087
`clock_gettime` syscalls over 2001 requests before, and none after.

**Resolution.** `boot` step 3b calls `parkVdsoInit` once, before any other
thread is cloned, so its one write to `vdsoClockFn` is ordered before every
reader by the clone itself. It reads `AT_SYSINFO_EHDR` (33) through
`getauxval` (§19) and looks up `__vdso_clock_gettime`@`LINUX_2.6` (x86_64) or
`__kernel_clock_gettime`@`LINUX_2.6.39` (aarch64) by walking the image's
program headers, `PT_DYNAMIC`, `DT_SYMTAB`/`DT_STRTAB`, the symbol count from
`DT_HASH` or `DT_GNU_HASH`, and `DT_VERSYM`/`DT_VERDEF` when both are present.
Every loop is bounded by the ELF's own count and by a fixed ceiling, and every
table address is checked against the image's extent (its first `PT_LOAD`) and
for alignment before it is read. Any failure answers 0 and keeps the syscall.
`BIT_VDSO=0` (or `off`) skips the lookup. `_tests_/stress/vdsolinux` prints the
lookup's reason code, so a lookup that stops resolving turns the test red
instead of making the clock quietly slower.

**The call.** `parkVdsoCall` is an `asm` `call rax` / `blr x9` with every C
caller-saved GPR declared clobbered, the `taskInvoke` shape, admitted in
`@nosplit` code by SPEC §10.3.1's `asm` rule: it neither allocates nor reaches a
safepoint. The vDSO's C ABI preserves a superset of the registers Bit's callers
rely on (x64 SysV keeps rbx, rbp, r12..r15, and so does Bit. AAPCS64
keeps x19..x28 and the low halves of v8..v15, which is exactly Bit's set), so the
call destroys only registers every Bit call already treats as dead. Every Bit
prologue leaves rsp 16-byte aligned at the `call` (read back from the
x86_64-linux archive), and the declared x30 clobber keeps the arm64 frame's
return address (#3915).

**Stack.** The vDSO runs on the caller's stack. Go switches to the system stack
for this call because a goroutine stack can be 2 KiB and a hardened kernel's
vDSO can probe about a page (golang/go#20427). Bit has no small stacks: a task
stack is 256 KiB (`schedStackBytes`) and worker, sysmon and `main` stacks are
larger. No Bit frame checks its depth either, so the vDSO frame is one more leaf
frame, and it is small: 6 pushes and two leaf calls, at most 72 bytes, on the
x86_64 kernel; none at all on the aarch64 linuxkit 7.0.12 kernel
(both read from the running kernels' images).

**Signals.** The Linux runtime has no preemption signal: preemption is a flag
polled at safepoints (§9), and the collector's stop-the-world waits for each
mutator to reach a safepoint too. A thread inside the vDSO is inside a
`@nosplit` function, so it is "running" to both and returns within
nanoseconds, exactly as it did from the syscall. The handlers that can land
there are SIGSEGV/SIGBUS/SIGILL/SIGTRAP, which run on the alternate stack and do
not return, and SIGTERM/SIGINT, which run below the interrupted frame and exit.
None of them reads the vDSO's state or calls it. The vDSO itself is
async-signal-safe: it reads the kernel's data page under a sequence count and
retries on a torn read, with no lock to hold across an interruption.

---

## 19. OS (`runtime/root`)

```
bit_rt_os_argc()           -> i64
bit_rt_os_arg_at(i)        -> *const RtBytes   // "" when out of range
bit_rt_os_env(name)        -> *const RtBytes   // "" when unset
bit_rt_os_env_present(name) -> bool           // true for a defined empty value too
bit_rt_os_self_exe()       -> *const RtBytes   // own path, symlinks resolved; "" if unknown
bit_rt_os_hostname(buf, room) -> i64       // local host name NUL-terminated into buf; its length (< room), or -1 (failure or does not fit)
bit_rt_os_exit(code)       -> noreturn         // deferred calls do not run
bit_rt_os_run(path, argv)  -> i64              // child exit code; argv ([]string) appended after path; -1 on failure, <= -100 signal-killed
bit_rt_os_run_test(path, i) -> i64             // like os_run + BIT_TEST_INDEX=i (no argv)
bit_rt_os_run_bounded(path, timeout_ms)      -> i64  // os_run, killed if it outlives timeout_ms
bit_rt_os_run_test_bounded(path, i, timeout_ms) -> i64  // os_run_test, same bound
bit_rt_host_target()       -> i64              // host BuildTarget ordinal (0/1/2)
bit_rt_auxv()              -> i64              // ELF auxv address; 0 when none
```

`argc`/`argv`/`envp` are captured by the process entry (§9) on both the raw-stack
Linux path and the Darwin `machoMain` path; `boot` captures the environment block.
Bit has no nil string, so an unset variable and one set to `""` both read empty.

`bit_rt_os_env_present` distinguishes those cases without allocating a string.
It and `bit_rt_os_env` share the bounded, first-match scan of the captured
startup environment. An exact `name=` entry is present even when no bytes
follow `=`; a longer key with the same prefix does not match. The captured
environment stays alive and has no supported mutation API, so presence and
value reads use the same snapshot. Linux and Darwin retain the startup array;
Windows retains its UTF-8 copy before releasing the system environment block.
The common `runtime/root/os.bit` provider serves all four supported targets.
The compiler's internal `osEnvPresent(name: string): bool` primitive maps to
this symbol. The released seed provides it; `std/os.lookupEnv` uses it to return
`None` for absence and `Some(osEnv(name))` for a present variable.

`bit_rt_os_run` runs the executable at `path` as a child process, with `argv` (a
`[]string`, or a null `SliceHeader` for the empty/default slice) appended to the
child's own argv after `path` — `arg(0)` is `path` itself, exactly as it is for a
binary the caller execs directly. The child inherits the captured `envp`. It is
`bit run`'s launcher (`bit test` uses the separate `bit_rt_os_run_test` below) —
`fork` + immediate `execve` (Linux: raw syscalls; Darwin: libSystem), the only
work between fork and exec, so it is safe with scheduler worker threads live.
Result encoding, the same one the bounded pair below uses minus the `-2` case it
has no deadline to produce:

```
 >= 0     child exited normally with this code (0-255)
 -1       spawn/exec/wait failure, or the child stopped rather than exited
 <= -100  child was killed by a signal; signal number is -(result) - 100
          (e.g. -111 = SIGSEGV)
```

The `<= -100` case used to collapse to `-1`, which made a program that ran and
then crashed indistinguishable from one that never started — `bit run` reported
every segfault as "could not run". A caller that only tests `code < 0` keeps its
old behaviour; one that wants the distinction subtracts.

**`bit_rt_os_run` gained `argv` in place (`bit run <src> [args...]`)
rather than through a new symbol beside it.** A new symbol was tried first and
reverted: `compiler/build.bit` — part of `compiler/`'s own self-hosting
source — is what needed to call it, and `compiler/`'s own build (`./make
selfhost`) is compiled by the PINNED stage0, a published release
(`dist/stage0/SHA256SUMS`). Stage0 has no idea a brand-new predeclared name
exists, so a call to one fails `E0040: undefined name` on every clean build
until the next stage0 repin — which itself needs a published release first,
a circular requirement a single commit cannot satisfy. Reusing the
ALREADY-recognized `osRun` identifier sidesteps that entirely: this compiler
validates no builtin call's arity (`compiler/validatecall.bit`'s `vCall`),
so stage0 accepts a 2-argument call to a name it has always known, with
nothing new required of its own predeclared-name table. Every caller was
updated in the same commit instead: `compiler/buildrun.bit`'s `runCmd`,
`compiler/pmfetchtail.bit`'s `runGit`, and the fixtures that call the
predeclared `osRun` builtin directly rather than through a `std/os` wrapper
(none exists) — `_tests_/cases/fs_walk_symlink.bit`,
`_tests_/imports/pmadd_e2e/main.bit`, `examples/staticserver/staticserver.bit`.

`argv` is a `[]string` SliceHeader (§2), or a null header for the empty/default
slice — the same content the old fixed `[path, NULL]` construction always
sent. The child sees `[path, argv[0], ..., argv[n-1], NULL]`; `path` is
`arg(0)` from the child's own `bit_rt_os_argc`/`bit_rt_os_arg_at`, exactly as
it was before and as it is for a binary the caller execs directly.

The runtime builds this argv vector into a FIXED buffer (Power of 10 rules
2/3: no unbounded allocation, no unbounded loop), so it is capped at
`osRunMaxArgv` (64) forwarded elements of at most `osRunMaxArgLen` (4096)
bytes each (`runtime/root/os.bit`'s consts). Above either bound the call is
REJECTED — `bit_rt_os_run` returns `-1`, the same sentinel a spawn failure
uses — never truncated: a silently shortened argument would be the same
class of bug as a silently dropped one. `compiler/build.bit`'s
`runMaxForwardedArgs` mirrors the count so `bit run` itself reports a
specific, named rejection before ever reaching the runtime's generic one.

`bit_rt_host_target` returns the ordinal of the `BuildTarget` this binary's own
host matches (0 `x86_64-linux`, 1 `aarch64-linux`, 2 `aarch64-macos` — the enum in
compiler/build.bit). The runtime archive is compiled once per target, so the answer
is fixed when the archive is built; the Bit provider takes the OS from its
own provider directory and the arch from an `asm` per-arch immediate, the code it
replaces read `builtin.target`. It is the default `bit build`/`bit run` target when
`--target` is absent, so a wrong ordinal silently mis-targets the compiler.

`bit_rt_auxv` returns the address of the ELF auxiliary vector the kernel placed
on this process's initial stack, or 0 where there is none (Darwin, which has no
auxv at all). The initial stack is unreachable once any Bit code is running, so
the pointer has to come from the process entry (§9) — but the SCAN over it is
Bit's own: `runtime/auxv` walks the `(a_type, a_un.a_val)` pairs to `AT_NULL`,
which is `getauxval`. `runtime/thread/linux` reads `AT_PHDR`/`AT_PHNUM`/`AT_PHENT`
through it to find `PT_TLS` and size a spawned thread's TLS block.

`bit_rt_os_run_test` is the same fork+exec launcher with `BIT_TEST_INDEX=<idx>`
prepended to the child's environment (first match wins, so it overrides any
inherited value). `bit test` calls it once per discovered test so the test
binary's synthetic `main` (compiler/testgen.bit) dispatches to test `idx`.

**`bit_rt_os_run_bounded`/`bit_rt_os_run_test_bounded` are `os_run`/`os_run_test`
with a wall-clock deadline.** `os_run`'s synchronous `waitpid` blocks the
calling green thread forever if the child never exits, exactly the hazard
the harnesses needed closed —
and one a Bit harness needs closed the same way, since nothing
else in this ABI lets Bit code bound a subprocess wait. `os_run`/`os_run_test`
themselves are unchanged: `bit run`/`bit test` still depend on their unbounded
semantics for real user programs, so the bound is a new, separate primitive
rather than an added argument to the existing two.

Same fork+exec as `os_run`, but the parent polls `waitpid(WNOHANG)` on a
`sched.sleepNs`-paced interval instead of blocking, checking the monotonic
clock (`sched.monoNs`, ABI.md §18's layer) against a deadline resolved from
`timeout_ms` once, before the first poll — the same "one absolute deadline,
not a per-iteration timeout" shape the harnesses use, so a chatty or
CPU-bound child cannot restart the clock. The child is placed in its own
process group (`setpgid`, both sides, immediately after fork — the standard
race-free idiom) with pgid equal to its own pid, so anything it or a wrapper
it execs (e.g. a harness's `/bin/sh` script) later forks inherits that same
group unless it detaches on its own. **If the deadline elapses before the
child exits, the parent `SIGKILL`s the whole group, not just the direct
child, and reaps the direct child before returning** (a single-pid
kill used to leave a grandchild — a compile the direct child's wrapper shell had
spawned — running indefinitely, reparented to pid 1, after the timeout had
already been reported). Result encoding (three outcomes in one `i64`, no
separate signal channel):

```
 >= 0     child exited normally with this code (0-255)
 -1       spawn failure (fork/exec/wait error) — same sentinel as os_run
 -2       timed out: the deadline elapsed, so the child was SIGKILLed and reaped
 <= -100  child was killed by a signal observed during a poll; signal number
          is -(result) - 100 (e.g. -109 = killed by SIGKILL from outside)
```

`-2` and `<= -100` stay distinct on purpose: `-2` means the *runtime* killed the
child on a budget, `<= -100` means something else killed it first. `timeout_ms`
is clamped to 100 minutes (`os_run_bounded_max_ms`), matching the harnesses'
own `max_timeout_s` clamp, so a caller typo cannot reinstate an unbounded wait; the
poll loop's iteration count is bounded by that clamp divided by the poll
interval (Power of 10 rule 2) rather than an open-ended `while (true)` — the
deadline check inside the loop is what actually ends every real call.

**`hostTarget()` and `auxv()` are compiler `prim_rt_fns` entries — the CALLER side
lowers to an `ir.RtFn` that codegen emits as a call to the symbol itself, and
that lowering stays permanent for both (SEAM 6).** A Bit *provider* whose
body called the primitive would therefore be a call to itself, now that the
`_root` infix has been dropped (the pin cycle `_tests_/bit/rootpins/` guards). Both are
PORTED regardless — each by finding the
answer somewhere other than the primitive:

- `host_target` is a **property of the emit**, not a runtime computation. The
  archive is compiled once per target, so its `builtin.target` *is* the build
  target — each per-target `libbitrt.a` returns its own ordinal (x86_64-linux → 0,
  aarch64-linux → 1, aarch64-macos → 2). Since the compiler selects the archive by
  `--target` (`libbitrtPath`), a cross-built binary reports the target it was
  built FOR, not the host it was built ON.

  **The provider is `runtime/root/linux/os.bit` or `runtime/root/darwin/os.bit`, selected by
  the OS axis below.** The old claim here, that a running Bit program has no
  compile-time `builtin` and so this could never be ported, mistook "no `builtin`"
  for "no compile-time knowledge". The emit carries both axes the ordinal needs:
  - the **OS** is *which provider directory the source sits in* —
    `runtime/root/linux/os.bit` vs `runtime/root/darwin/os.bit`. Mis-selection is a
    compile error, not a wrong answer: a Darwin `--emit-obj` refuses the Linux
    provider's `syscall` and a Linux one refuses the Darwin provider's
    `extern fn`, both even on an uncalled declaration.
  - the **arch** is an `asm` block's per-arch sub-blocks (SPEC §11.6), which the
    backend selects at codegen — `runtime/sched/switch.bit`'s `entryBias` shape.
    This is the axis the directory split does NOT draw, and x86_64-linux vs
    aarch64-linux is exactly where it is needed.

  x86_64 exists only on Linux among the three recognised targets and Darwin is
  aarch64-only, so (provider, arch) names all three exactly; Darwin therefore needs
  no `asm` at all and returns the literal 2. The provider must never call
  `hostTarget()` — that primitive lowers to a call to this very symbol, now that
  the `_root` infix has been dropped (the pin cycle `_tests_/bit/rootpins/`
  guards) — and an `asm` immediate is inline by construction, so there is no
  callee for the rename to redirect. Verified running on all three targets, not
  just by disassembly:
  `_tests_/stress/roothost{darwin,linux}`.
- `auxv` is a **process-entry fact owned by the boot layer (SEAM 3)**, and
  `bit_rt_auxv`'s provider is `runtime/root/os.bit`. The kernel places the
  auxiliary vector on the initial stack, unreachable once any Bit code runs, so only
  the entry (`rtStartMain`) can capture it — a single writer, Linux-only;
  `machoMain` captures none. The Bit Linux entry walks past `envp`'s NULL to the
  auxv array and stores its address, through `bit_rt_port_root_os_set_auxv`, into
  the cell `runtime/root/os.bit`'s `gAuxv` owns (beside `g_argc`/`g_argv`/`g_envp`);
  the reader `bit_rt_auxv` hands that cell back. This is the move promised
  above — ownership of the cell moved from `runtime/root/root.bit`'s `g_auxv`
  to the boot layer (the old `g_auxv`/`bit_rt_auxv` stayed live only until the
  archive swap made the Bit entry the real one, which it now is). The reader
  reads `gAuxv` DIRECTLY, never through the `auxv()` primitive, precisely to avoid
  the self-reference the pin-cycle gate forbids; `runtime/auxv` still does the scan
  (`getauxval`) over what the reader returns, and `runtime/thread/linux` reads
  `AT_PHDR`/`AT_PHNUM`/`AT_PHENT` through it to size a spawned thread's TLS block.
  Darwin's `gAuxv` stays 0 (the reader is platform-free so the portable
  `runtime/auxv` resolves the symbol there too), and the vector must never be
  captured a second time.

**`bit_rt_os_run_captured` is `os_run_bounded` with its child's stdout and
stderr captured into memory instead of left attached to the parent's own
file descriptors, plus three out-of-band companions to read the result:**

```
bit_rt_os_run_captured(path, argv, timeout_ms)  -> i64     // same encoding as os_run_bounded
bit_rt_os_run_captured_stdout()                 -> string  // must be called immediately after, no yield between
bit_rt_os_run_captured_stderr()                 -> string  // same
bit_rt_os_run_captured_truncated()              -> i64     // bit 0: stdout hit the cap; bit 1: stderr did; same contract
```

`path` and `argv` are the same `*const RtBytes` / SliceHeader pair `bit_rt_os_run`
takes (`argv` appended after `path`, above); `timeout_ms` is the same
wall-clock deadline `bit_rt_os_run_bounded` takes, clamped to the same
`os_run_bounded_max_ms`. `bit_rt_os_run_captured` reuses `os_run_bounded`'s
own result encoding exactly, unchanged by capture or by truncation of either
stream:

```
 >= 0     child exited normally with this code (0-255)
 -1       spawn failure (fork/exec/wait error), same sentinel as os_run
 -2       timed out: the deadline elapsed, so the child was SIGKILLed and reaped,
          or the child exited but a stream had not reached EOF by then
 <= -100  child was killed by a signal observed during a poll; signal number
          is -(result) - 100 (e.g. -109 = killed by SIGKILL from outside)
```

`timeout_ms` bounds the whole call, including the drain after the child has
exited. If the deadline passes while a stream is still open (a grandchild
inherited the pipe write end and outlives the child), the result is `-2` with
whatever was captured up to then, and the read ends are closed. This is
Python's `subprocess.run(timeout=)` (partial output kept), not Go's `WaitDelay`
(which keeps the child's exit status). A stream that reaches EOF inside the
deadline never turns a normal exit into `-2`. The Windows provider does not
wait for EOF after the child exits (it drains what is buffered), so it never
reaches this case.

Each stream is capped at `osRunCaptureMaxBytes` (4 MiB, `runtime/root/os.bit`).
Both pipes are drained to EOF regardless of the cap: bytes read past the cap
on either stream are discarded rather than appended, but the read loop on
that stream keeps consuming them instead of stopping. A pipe's kernel buffer
is small, so once it fills the child blocks on its next write to that pipe
until the parent reads more of it; stopping one stream's drain at the cap
while the other still has output to produce would leave the child blocked
writing to the stopped pipe forever, deadlocking the still-open sibling
stream along with it. Both drain loops therefore run to EOF independent of
the cap, matching `bit_rt_fs_read_all`'s "sized... then TRIMMED, never
zero-padded" allocate-once shape (`runtime/root/linux/fsrw.bit`).

`_stdout`, `_stderr` and `_truncated` are out-of-band companions reading
per-task state, the same shape `bit_rt_fs_read_all_failed` uses (§14): "per-task
state... must be read immediately after that call with no yield between" is
the identical contract here, all three cleared and repopulated together at
each `bit_rt_os_run_captured` entry. Calling any of the three on a task that
has not yet made a `bit_rt_os_run_captured` call reads that field's zero
value: `_stdout`/`_stderr` return `""`, `_truncated` returns `0`.

`_truncated`'s two bits are independent, not mutually exclusive: bit 0
(value 1) set means the child's stdout produced more than
`osRunCaptureMaxBytes` bytes and the excess was trimmed; bit 1 (value 2) set
means stderr did; both set together reads 3, neither set reads 0. Truncation
never changes the exit encoding above: a child that exceeds the cap on one
or both streams and then exits normally still reports `>= 0`, with the data
loss visible only through `_truncated`, never folded into the exit result.

The four symbols are reached only through `extern fn` declarations in
`stdlib/process/process.bit`, the same way `bit_rt_fs_stat_w` is declared
directly in `stdlib/fs/fs.bit:429`: no `compiler/checktype.bit`,
`compiler/symbols.bit`, `compiler/validatecall.bit` or
`compiler/lowerprim.bit` entry registers any of the four as a compiler
builtin.

---

## 20. Networking (`runtime/net` + `runtime/root`)

The low-level layer under `std/net`/`std/http`. Every socket is `O_NONBLOCK`; an
operation that would block registers its fd with the netpoller (§11) and parks
the calling green thread rather than blocking an OS thread. Addresses are
dotted-quad IPv4 literals — a socket is closed by `bit_rt_fs_close`.

```
bit_rt_net_listen(host, port)   -> fd    // TCP listener; port 0 = kernel picks. -1 on error
bit_rt_net_local_port(fd)       -> port  // the bound port (recovers a port-0 choice). -1 on error
bit_rt_net_accept(fd)           -> fd    // next connection; parks. -1 on error
bit_rt_net_dial(host, port)     -> fd    // connected socket; parks past the handshake. -1 on error
bit_rt_net_read(fd, max)        -> str   // up to max bytes; parks. "" at end of stream OR on error
bit_rt_net_read_bytes_w(fd, outWords, cap) -> n // up to cap bytes into outWords; parks. 0 = peer closed; -1 hard error
bit_rt_net_write(fd, s)         -> n     // all of s (retried internally). -1 on error
```

**THE PEER ADDRESS IS 16 RAW BYTES, NOT TEXT.**
`bit_rt_net_peer_addr_w(fd, outWords)` writes the connected peer's address into
the caller's 16-byte buffer in the IPv6 wire form and returns `0`, or `-1` for
every "there is no peer": an unconnected or listening socket (ENOTCONN), a
closed one (EBADF), and a peer whose family is neither AF_INET nor AF_INET6
(the bytes at `sin_addr` mean something else in every other family, so the
family is checked rather than assumed). An AF_INET peer is written
IPv4-mapped, `::ffff:a.b.c.d` (ten zero bytes, `ff ff`, the four octets), so a
`::` listener's mapped peer and an IPv4 socket's peer are the same 16 bytes and
the one rendering rule in `std/net` (`stdlib/net/ipaddr.bit`: mapped prints as
the dotted quad, anything else per RFC 5952) gives one client one string.

It is raw bytes rather than formatted so that all three wrappers stay
`@nosplit`: formatting means allocating a managed octet scratch and a string,
which costs entries in `_tests_/bit/pollfree`'s REVIEWED exception list (§5's
hazard of a raw GC address held across a poll). `std/net`'s `Conn.peerIp()` renders them instead,
where string work is free. `outWords` crosses as a packed `[]byte` backing the
caller holds live with `keepAlive`, and is written before the wrapper returns.

Two layers, both real symbols. `bit_rt_port_net_peer_addr(fd: i64, out: *u8) ->
i64` is the port-level primitive, bound as `getpeername(2)` into a
`sockaddr_in6`-sized scratch in all three providers
(`runtime/net/{darwin,linux,windows}/sock.bit`) rather than captured in the
accept loop, whose `sockaddr` out-parameter stays NULL — it is per fd, so
`bit_rt_net_accept` above is unchanged and a DIALED socket answers too.

```
bit_rt_net_peer_addr_w(fd, out) -> 0|-1  // the peer's address, 16 bytes IPv6 wire form (IPv4 mapped). -1 when there is no peer
```

`bit_rt_net_peer_addr_w` is the ABI wrapper over it, one per provider's
`netabi.bit`. **The `_w` suffix says `std/net` reaches it through a plain
`extern fn` — the same class as `bit_rt_net_dial_deadline_w` and
`bit_rt_net_shutdown_sock_w` below, not the class `bit_rt_net_local_port` above
belongs to, and like those two it is documented here rather than in §9's
emitted-symbol table.** A compiler-recognized builtin exists for the signatures
an `extern` cannot express (§11.7 admits no `string` across that boundary; the
chan-typed timer arm is the other case), and `(i64, *byte) -> i64` is not one. A
builtin could not have been used from `stdlib/**` before the next stage0 repin
in any case: `make selfhost` compiles the whole stdlib with the PINNED stage0,
and `compiler/pmfetch.bit` pulls `std/http` -> `std/net` into that build, so a
freshly added predeclared name is `E0040: undefined name` there.

**UDP** (connectionless). `bit_rt_net_udp_recv_from_w(fd, outWords, cap,
peerWords)` is recvfrom(2): ONE call returns the datagram and its sender, both
written into buffers the CALLER owns — the datagram into `outWords` (up to `cap`
bytes, a packed `[]byte` backing), the sender's raw `sockaddr_in` into
`peerWords` (16 bytes, the port big-endian at byte 2, the four octets at byte 4,
on Linux, Darwin and Windows alike; only the family byte differs). The runtime
keeps NO "last sender" state, and `std/net`'s `UdpSocket.recv` decodes the
address from its own buffer. A zero-length datagram returns `0` with a valid
sender; a failed receive returns `-1`, which is how it is told from one.

Windows retains immediate `recvfrom` and `sendto` results. A would-block
result posts a real `WSARecvFrom` or `WSASendTo` operation (#8023). The
bounded IOCP pool retains each OVERLAPPED until the caller reads its result.
The caller roots payload and peer; managed sender, flags and address-length
scratch stays live through terminal completion. Windows reports a truncated
message as a failed receive. A zero-byte readiness probe cannot serve UDP:
a receive consumes the datagram, and a send emits an empty datagram.

**This replaced a per-worker "last sender" slot (#7746).** `recv` used to record
the sender in `udpSenderBuf`/`udpSenderValid`, one `[4]i64` sockaddr and one
valid flag per worker indexed by the calling task's `wkId`, and `std/net` read
it back with two more calls, `bit_rt_net_udp_sender_port` then
`bit_rt_net_udp_sender_host`. A single shared slot (before #3272) was clobbered
by two tasks on two OS threads; the per-worker slot fixed that and argued the
read-backs were safe because "nothing parks between them". A park is not the
only scheduling point: every loop back edge polls, and a poll yields when the
worker's preempt flag is up (`schedMaybeYieldForPreempt`), after which the task
may resume on another worker. Under load a QUIC server saw a datagram from
`0.0.0.0:0` (a reply to it failed with `udp send to 0.0.0.0:0 failed` and ended
the connection). The window PROVEN is in the engine: `netRecvFromLoop`
(`runtime/net/{linux,darwin}/udp.bit`) had the kernel write the sender into the
per-worker `saBytes()` slot and a copy loop (a back edge is a poll site) re-derive
the slot to copy it out; a `schedYield()` inserted right after the
kernel write made `stdlib/net/udpsender.test.bit` report 2 to 10
wrong senders in 4 of 5 runs, and the same insertion into the fixed tree 0 in
10 of 10. Whether the field failure came through that loop or through the
slot read-back is not established; both are gone. Adjacency of two calls is a
property of one instruction stream, not a guarantee about the storage between
them; storage the caller passes in has no such window. The slots, their
accessors (`udpSenderSlot`, `udpValidAt`, `udpSenderWordAt`, `udpSenderAddr`,
`copySockAddrWords`), `formatQuad` and the three primitives are deleted on every
provider, and `netRecvFrom` on Linux and Darwin writes the sockaddr straight into
the caller's `peer` (its `salen` is a managed local).

```
bit_rt_net_udp_bind(host, port)         -> fd    // datagram socket; port 0 = kernel picks. -1 on error
bit_rt_net_udp_send(fd, host, port, s)  -> n     // one datagram (all-or-nothing). -1 on error
bit_rt_net_udp_recv_from_w(fd, out, cap, peer) -> n // next datagram into out, sender sockaddr into peer; parks. -1 on error
```

**DNS.** `resolve` returns the first A record for `host` as a dotted quad, or `""`
on failure; a dotted-quad `host` passes straight back. It queries every
nameserver in `/etc/resolv.conf` in order over a non-blocking UDP socket with
bounded retransmits (`attempts` passes over the list, one try of `timeoutMs`
per nameserver per pass, both passed in by `std/net`, which takes them from `options timeout:N attempts:N`
in `resolv.conf` and defaults to 2 tries of 5 s as glibc does). The calling task
parks on the netpoller with the attempt's deadline, so a lost packet neither
holds the OS thread nor delays a stop-the-world rendezvous.

```
bit_rt_net_resolve_w(host, hostLen, timeoutMs, attempts, out) -> n   // first A record, dotted quad, in out[0..n). -1 on failure
```

**Deadline-bounded dial/read/write.** A server that completes the
handshake (or accepts) and then never writes parks `bit_rt_net_read`/
`bit_rt_net_dial` above forever — nothing bounds their park on the netpoller.
These three give `std/net`'s `dialDeadline`/`readDeadline`/`writeDeadline` a
way to bound it instead, resolving ONE absolute monotonic deadline before the
first poll and never restarting it — the same "resolve once, never
per-iteration" shape §19's `osForkExecWaitBounded` uses. They are reached
through a plain `extern fn`, not the compiler-recognized builtins the four
entries above lower to, because §11.7 admits no `string` across an `extern`
boundary: `host`/the written body cross as a raw pointer into a packed Bit
`[]byte`'s backing (§2) plus a length, and a read result is
written into the caller's own such buffer rather than returned as a fresh
string, the same shape §14's `bit_rt_fs_is_symlink_w` uses. `deadlineNs` is an
absolute
monotonic nanosecond value on the same clock `bit_rt_time_mono_ns` reaches
(§18); `<= 0` (a `Conn`'s zero value) or further out than the wait ceiling
below both clamp to it — a caller typo must not reinstate an unbounded wait,
the same reasoning the §19 clamp documents.

```
bit_rt_net_dial_deadline_w(hostWords, hostLen, port, deadlineNs)  -> fd  // -1 hard failure, -2 timed out
bit_rt_net_read_deadline_w(fd, outWords, cap, deadlineNs)         -> n   // writes into outWords; 0 = peer closed; -1 hard error; -2 timed out
bit_rt_net_write_deadline_w(fd, words, n, deadlineNs)             -> n   // bytes written; -1 hard error; -2 timed out
```

Implemented as a poll-and-sleep loop (`runtime/net/{darwin,linux}/tcp.bit`'s
`net{Read,Write}SockDeadline`/`netDialTcpDeadline`), not by adding a
poll/timer race to the scheduler: on each `EAGAIN` the deadline is checked,
then the calling task sleeps a short, bounded slice (2ms, matching §19's
`osPollNs`) via `schedSleepUntil` before retrying the syscall itself, capped
at a one-hour wait ceiling (`netDeadlineMaxWaitNs`, `runtime/net/net.bit`) —
kept independent of §19's own clamp on purpose: that one governs
test/gate wall-clock capacity, this one bounds a caller's own deadline input
against a unit typo, a different reason with no tie to gate timing —
expressed as a worst-case poll count (`netDeadlineMaxPolls`) so the loop is
statically bounded either way. No
`gcSyscallBegin`/`gcSyscallEnd` bracket: every syscall this touches
(`read`/`write`/`connect`) runs on this provider's always-non-blocking
sockets, so each returns immediately rather than holding the OS thread in
the kernel — exactly as the unbounded `bit_rt_net_read`/`_dial` above do with
no bracket either.

Windows deadline operations wait for IOCP result publication (#8002).
`bit_rt_port_sched_poll_op_completed(slot: i64) -> bool` acquires the completion
marker for a slot in `[0, 512)`; an invalid slot returns false. Claiming a slot
clears its marker before issuing the operation. The completion drain copies
its byte count and status, decrements the pending count, then release-publishes
the marker before waking the cached task. It reads no slot state after
publication. The caller reads results before releasing the slot. A deadline
cancellation uses the same marker and drains for at most 500 polls. If completion
is still pending at that bound, `bit_rt_fatal` exits the process before caller
payload owners can unwind; a recovery boundary cannot catch this failure (#8012).
A completed cancellation releases the slot normally.

---


[Previous: Channels, errors, and filesystem primitives](channels-errors-and-files.md) | [Next: Crypto, shared state, and concurrency](crypto-and-concurrency.md)
