# Program boot, workers, and task entry

[Runtime ABI](../ABI.md)

## 9. Program entry, boot, and spawn (`runtime/root`)

### Process entry

The linker designates `_start` as the object's entry point (the
standard convention on every target this runtime supports — ELF `e_entry`,
Mach-O `LC_MAIN`/`LC_UNIXTHREAD`, PE `AddressOfEntryPoint`; wiring the header
field is the linker's concern, not this one). `_start` is hand-written asm per
arch: it reads the OS-provided `argc`/`argv`/`envp` block directly off the
initial stack pointer (the standard libc-free `_start` shape, matching
glibc/musl `crt1`) and calls `rtStartMain(sp: usize)`, which extracts `envp`,
calls `boot`, and exits the process with `boot`'s returned code.

**Work discovery (#8004).** Each worker probes the global queue before local
work every 64 find-work calls. Other calls take the local ring, the worker's
next-run slot, the global queue, then a bounded pass stealing from peers. This
keeps globally woken tasks eligible while local work stays runnable, with the
ring still preceding the next-run slot on ordinary turns. The owner-only probe
counter ranges from 0 through 63 and is initialized for every worker slot. It
occupies word 292, making the worker stride 293 words; the deque still starts
at word 34. Each platform's boot storage holds 32 such blocks (9376 words).
This phase counter does not reset or extend the finite worker lifetime limit.

### Boot sequence (`boot(main_fn, environ) !i32`)

1. Init the heap (`runtime/alloc/alloc.bit`) and collector (`runtime/gc/gc.bit`, config from
   `configFromEnv(environ)` — §7).
2. Init and start the scheduler (`runtime/sched/sched.bit`) with `nthreads`
   worker OS threads: `BIT_WORKERS` if set and parseable, clamped to `[1, 32]`,
   **otherwise 1**. The ceiling is static so `boot` allocates nothing new for
   it. `BIT_WORKERS` always overrides the default that follows.

   **The boot-time default is 1, and it changes at run time, not at boot.**
   Defaulting *boot itself* to the CPU count was tried and reverted twice, for
   two independent, measured reasons (`runtime/sched/pool-sizing.md` records
   both verbatim). First: an idle worker ran its find-work/steal/backoff loop
   regardless of runnable work, so a pool wider than the work cost more than
   it saved — on an 18-core box, four CPU-bound tasks took 108% of one task's
   time with four workers and 215% with eighteen. This was fixed by making
   idle workers park on a futex instead of spinning; the same repro is flat
   at 0.04-0.05s for 1..18 idle workers. Second, even after idle cost was fixed,
   a core-count default still failed `./make test`: a boot-time snapshot of
   "cores available right now" is a claim on the *whole machine*, wrong for a
   process that is itself one of N run at once. `_tests_/bit/docs.bit` runs 12
   `bit` processes concurrently by design; at 18 workers each that is 200+
   parked worker threads on 18 cores, and a batch that runs in ~48s blew its
   300s deadline on oversubscription alone — the threads were genuinely
   parked (sampled at 0:00.00 CPU), not spinning.

   **The rule that changes the pool size at run time**
   (`runtime/sched/grow.bit` — grow-on-demand, the design
   chosen in `runtime/sched/pool-sizing.md`): every `spawn` tracks backlog two
   ways, one for each of the queues a task can land on. `schedGrowObserve`
   counts a streak of consecutive enqueues that find the scheduler's global
   run queue still non-empty; `schedGrowObserveLocal` reads a spawning
   worker's own local ring depth directly (its head/tail already give an
   exact count, so this needs no streak — a ring at or above threshold IS
   backlog the instant it's observed). Either one reaching
   `growStreakThreshold` (4), with the pool still below `schedMaxWorkers`
   (32 — the same static ceiling the clamp above uses), starts exactly one
   more OS thread and resets. Both paths matter: an ordinary CPU-bound
   program's spawns stay on the calling worker's own local ring, so without
   the local check the global one alone never sees them and the pool never
   grows past 1 regardless of backlog. A program that never has
   parallel work never pays for a pool it doesn't use; a program with
   sustained backlog grows toward the machine's actual, current free
   capacity instead of a boot-time guess at it — UNLESS `BIT_WORKERS` was
   explicitly set, in which case it is also a hard ceiling on that growth,
   not only the boot-time floor: `schedGrowArm`/`schedMaybeGrow`
   (`runtime/sched/grow.bit`) refuse to grow the pool past it. The implicit
   default (unset `BIT_WORKERS`) is unaffected and still grows to
   `schedMaxWorkers` exactly as described above.

   **The width the implicit default actually reaches is not 4, and a
   default-versus-pinned reading is therefore a WIDTH reading** (#5729,
   measured on 52703111c, darwin arm64, 18 usable cores, under the
   workspace build lock with the fleet drained). On a timer-only workload
   — eight green tasks, each sleeping 200us five thousand times — the
   unset default settles at **ten workers** (twelve OS threads: boot, ten
   workers, sysmon) inside the first second and does not move again. So an
   unset `BIT_WORKERS` against `BIT_WORKERS=4` compares ten workers with
   four; it does not compare grow-on-demand against a steady pool. Derive
   the width before attributing any such difference to the growth
   machinery.

   This was pinned to **exactly one** until multi-worker support landed. It was never a *collector*
   requirement — §5's handshake makes concurrent mutators safe, and each worker
   registers as a mutator for the life of its run loop — only a
   scheduler-maturity choice, because work stealing across several workers had
   no test that exercised it.

   **What that means for anyone reading a stack trace from before multi-worker support landed:** with
   one worker, a worker's steal path could never find a victim, so the stealing
   branch of `schedFindWorkAt` was unreachable in every binary this runtime ever
   produced. It runs for the first time with `nthreads > 1`. Treat a failure
   that appears only under multiple workers as a first execution, not a
   regression.

   `BIT_WORKERS=1` fixes the *boot-time* pool at the single-worker default that
   existed before multi-worker support landed, and exists so a suspected
   concurrency failure can be bisected against it without a rebuild. An
   explicit `BIT_WORKERS` is ALSO a hard ceiling on growth, so `BIT_WORKERS=1`
   now keeps the pool at exactly one RUNNING worker rather than merely
   starting it there — the earlier behaviour (growth ignoring
   which count started the pool) is no longer accurate for an explicit
   setting. The implicit default (no
   `BIT_WORKERS` set at all) is unchanged: it still starts at 1 and grows
   under sustained backlog exactly as before.

   **`BIT_WORKERS` bounds RUNNING workers, like Go's GOMAXPROCS (#7128).** A
   worker whose task is inside a `bit_rt_gc_syscall_begin` /
   `bit_rt_gc_blocking_begin` bracket (a file read, `waitpid`, a blocking
   DNS call) does not count against it: the monitor thread starts one more
   worker for the work queued behind it (see "Retaking a blocked worker"
   under Preemption below), so at `BIT_WORKERS=1` a 500 ms `waitpid` no longer
   stalls every other task. The pool never shrinks, so once the blocked
   worker returns its thread keeps running tasks beside the replacement:
   after a retake the pool is larger than the ceiling for the rest of the
   process, by at most the number of workers that were blocked at the same
   time. Linux, darwin, and Windows use this blocked-worker replacement.
   Windows publishes grown handles through the shared grow protocol and joins
   the locked final worker count at shutdown. Windows does not add CPU-backlog
   growth.
3. Spawn `main_fn` (§10) as the first green thread.
4. Poll (bounded exponential backoff) until that task reports done, then shut
   the scheduler down, tear down the collector, and return the task's exit
   code.

`boot` never runs twice in one process (single-boot guard) — there is no
"reboot this runtime" operation.

### Preemption: the sysmon monitor and the preempt request flag

**Preemption is fully landed: a state module plus four consumers.** Every
claim below was checked directly against the source with the greps shown,
not against a comment's stated intent.

**The state module (`runtime/sched/preempt.bit`, landed).** The only
OS call in this file is the monitor's idle park and its wake (#6008, below),
and none of its functions reads a clock at all anymore: the budget is
counted in SYSMON TICKS. `sysmonTick` bumps the
module's own `sysmonEpoch` counter once per call, `preemptTickNow()` reads it,
and both the dispatch stamp and the over-budget comparison use that one value.
It defines:

- `preemptBudgetNs: i64 = 10000000` (10 ms) — a task that has held its
  worker longer than this is eligible for a preempt request.
- `sysmonPeriodNs: i64 = 2000000` (2 ms) — the monitor thread's sleep between
  ticks. Both monitor threads import it rather than repeating the literal.
- `preemptBudgetTicks: i64 = preemptBudgetNs / sysmonPeriodNs + 1` (6) — the
  threshold actually tested. The `+ 1` is tick granularity: the first tick
  after a dispatch can land arbitrarily soon, so `k` observed ticks prove only
  `(k - 1) * sysmonPeriodNs` of elapsed time, and 6 preserves the promise
  that a worker is never flagged before a real 10 ms of holding its task.
- `preemptTickNow(): i64` — `sysmonEpoch + 1`, so never 0. The value a
  dispatch stamps and the value `sysmonTick` measures ages against; one epoch,
  one accessor, so the two sides cannot disagree about which clock they read.
- Two fixed-size, worker-indexed globals, `startTick` and `requested`, each
  `[32]i64` (`runtime/sched/preempt.bit:58-59`), whose scan bound is this
  file's own `preemptSlots: int = 32` (`runtime/sched/preempt.bit:51`) —
  deliberately a separate constant from the scheduler's own worker-count
  constant, which this file treats as advisory only, not as the real bound
  on these arrays.
- `preemptStamp(worker: i64, startedTick: i64)`, which sets
  `startTick[worker] = startedTick` and clears `requested[worker]`. The tick
  is a parameter rather than read inside, which is what lets
  `_tests_/bit/pollguardpreempt.bit` backdate one worker deterministically.
- `sysmonTick(): i64`, which advances `sysmonEpoch` by one and then scans
  every worker slot — bounded by both the scheduler's worker-count constant
  and `preemptSlots` — publishing the nonzero dispatch stamp as the request
  tag when `preemptTickNow() - startTick[w]` reaches `preemptBudgetTicks`.
  It counts retained current-dispatch requests. A stale publisher retracts
  only its own tag. Epoch increments are atomic across concurrent callers.
  It takes no argument and reads no clock.
- `preemptRequested(worker: i64): bool`, which reads the flag without
  clearing it (`runtime/sched/preempt.bit:109-111`).
- `maybePreempt(worker: i64): bool`, which reports a pending request and
  clears it in the same call. It only reports — the caller is responsible
  for the actual yield (`runtime/sched/preempt.bit:117-123`).
- `anyRequested`, a `[1]i64` SUMMARY of `requested`, with its pinned
  address accessor `bit_rt_port_sched_preempt_any_addr` (`preemptAnyAddr(): int`)
  and its pinned value accessor
  `bit_rt_port_sched_preempt_any` (`preemptAnyPending(): bool`). The word may
  read 1 with nothing pending; it can never read 0 with something pending.
  `sysmonTick` publishes it AFTER setting a flag, `maybePreempt`/`preemptStamp`
  write 0 and re-scan AFTER clearing one; that ordering is what makes the
  one-way error one-way, and the proof is on the declaration in
  `runtime/sched/preempt.bit`.

  **No backend reads this word any more.** Both inlined poll guards
  cached its address beside `bit_rt_world_addr` and `bit_rt_gc_addr` and read it
  at every back edge to decide whether to spend `schedCurrentWorker` +
  `preemptRequested`. The back edge now reads `pollAttention`
  (`runtime/sched/pollreq.bit`) instead, which `sysmonTick` publishes into on the
  same terms and in the same place; `stwPollNeeded` consumes `anyRequested`
  through `preemptAnyPending`, on the slow path, where the two scheduler calls it
  replaced used to run.

  NOTE: the `runtime/sched/preempt.bit:NN` line citations in this section
  may have drifted from later edits. Resolve by NAME.

**Wired: the stamp on dispatch (landed; later changed what it
stamps).** `schedWorkerStep` calls `preemptStamp(*(w + wkId),
preemptTickNow())` once per task dispatch, immediately before `schedSwitch`
hands control to the task (`runtime/sched/workerrun.bit`) — the only call site
for `preemptStamp` in the tree (`git grep -n preemptStamp -- '*.bit'`).

**THE DISPATCH PATH READS NO CLOCK.** It used to stamp `monoNs()` here.
On Linux that pinned `parkMonoNs` (`runtime/park/linux/wait.bit`), then a raw
`clock_gettime` `svc` (the vDSO read is §18.1, #5959), so every green-task dispatch —
once per context switch — took a kernel trap: +147 ns/switch, 285 -> 423
ns/switch on the arm64-linux `test-schedbench` gate. The stamp is now
`preemptTickNow()`, one atomic load of a word `preempt.bit` owns. The monitor
thread lost its clock read in the same change; its `nanosleep` period is the
only remaining tie between ticks and real time, which is why
`preemptBudgetTicks` is derived from `sysmonPeriodNs` and both monitor threads
import that constant.

**Wired: the monitor ticks the flag (darwin and linux, both
landed).** `sysmonRun` is a `nanosleep`-then-`sysmonTick` loop, sleeping
~2ms between ticks while any task is in flight. With none in flight it
blocks in `sysmonIdleWait` on the `sysmonPark` word until `preemptStamp`
wakes it (#6008): the stamp is stored before the word is read, the word
before `startTick` is re-scanned, so one side always sees the other. The
epoch stands still while parked, so a task stamped during the park is
flagged by the same `preemptBudgetTicks` real ticks as one stamped while
ticking. Windows also starts a monitor through `sysmonStart`
(`runtime/root/windows/sysmon.bit`, #6469). Each `sysmonRun` runs for the
process lifetime; process termination ends the thread. Each turn and its
resource use remain bounded. Linux and Darwin start their monitors beside
the `BIT_WORKERS` worker boot sequence in `boot`
(`runtime/root/linux/boottail.bit`, `runtime/root/darwin/boot.bit`).
The monitor stays GC-blocked through `gcBlockingBegin`: it holds no live
Bit references, as explained by `sysmonRun` in each provider. So `requested` is
set by a real, clock-driven tick on all three platforms, not only by the
dispatch-time stamp described above.

**Wired: the safepoint consumes the flag (landed).**
`schedMaybeYieldForPreempt` (`runtime/sched/task.bit:286-292`) calls
`maybePreempt(workerId)` at `runtime/sched/task.bit:290` and yields via the
existing `schedYield` path when it returns true. `stwSafepoint`
(`runtime/stw/stwpoll.bit:413`) calls `schedMaybeYieldForPreempt()` at
`runtime/stw/stwpoll.bit:415`, immediately after `stwPoll(snap)` returns —
the real, pinned safepoint entry point (`bit_rt_port_stw_safepoint`).

**Net effect today:** the flag is stamped at dispatch and set by a real
tick on both platforms (above), and it is consumed whenever a task reaches
the real safepoint poll (above). A task with no safepoint is still
not preemptible even when `sysmonTick` has set its flag: the flag is only
acted on where `maybePreempt` is called, and a task that never reaches that
call point keeps running regardless of `requested`'s value.

**No separate preemption knob.** `preemptBudgetNs` is a compile-time
constant, read from no environment variable. The only worker-related
environment knob is `BIT_WORKERS`, above; nothing else in the environment
controls worker count or preemption.

**Retaking a blocked worker (#7128; darwin and linux).** A task that blocks
its worker's OS thread inside a `bit_rt_gc_syscall_begin` /
`bit_rt_gc_blocking_begin` bracket leaves that worker's ring and next-run slot
with nobody to run them; at one worker that is the whole process. After each
`sysmonTick`, `sysmonRun` calls `rootRetakeScan` (`runtime/root/retake.bit`),
which reads each worker's registry state (the slot the worker recorded in
`wkSlot` at entry) and hands a mask to `schedRetakeScan`
(`runtime/sched/retake.bit`). A worker counts when the mask has its bit, it has
a task in flight (`startTick`; an idle worker parks under `gcBlockingBegin`
too), and it has been seen so on `retakeTicks` (3) consecutive ticks, i.e. 4 to
6 ms. If such a worker has a non-empty ring or next-run slot, or every started
worker is blocked and the global queue is non-empty, then a parked peer is
woken if there is one; otherwise `scGrowStreak` is latched and the monitor
thread runs the same `schedGrowArm` / `threadStart` / `schedGrowCommit`
recipe a worker uses (`tryGrowPoolAt`), with the explicit `BIT_WORKERS`
ceiling widened by the number of blocked workers. `schedMaxWorkers` and
`scStopping` refuse as ever, and no thread is created while a parked worker
exists. Before it creates the FIRST peer, the monitor fences and re-reads
worker 0's state (`rootRetakeConfirm`), and abandons the start unless worker 0
is still in its bracket: the other half of the plain-store map publish
(`mapCtrlPublish`, `runtime/root/maptable.bit`, #7784). Measured on darwin arm64 at 23af4e0ca: stranded tasks start 7.1-7.6 ms after spawn
at the default pool and at `BIT_WORKERS=1` (500 ms before). A syscall that
is not bracketed is not seen (the collector would already be waiting on that
thread), and the monitor prints a warning for it instead (§8.5, #7841). The spawn and dispatch paths are unchanged; the monitor's extra work is
one pass over the started workers per tick (at most 32), and the monitor still
parks when no task is in flight.

### Spawn

```
bit_rt_spawn(fn_ptr: TaskFn, arg: ?*anyopaque) -> void
TaskFn = *const fn (arg: ?*anyopaque) callconv(.c) void
```

Fixed 2-arg native shape, matching `sched.TaskFn` exactly — spawn's arity does
**not** grow with the spawned call's own argument count. For `spawn f(a, b, c)`
codegen must pack `(a, b, c)` (and `f`'s captured environment, if any) into one
`bit_rt_gc_alloc`'d class and generate a small trampoline that unpacks it and
calls `f` with the real arguments; `fn_ptr`/`arg` here are that trampoline and
its one packed-argument pointer, never `f` and its raw arguments directly.
Never fails visibly: OOM is fatal here (SPEC.md §16.1's `spawn` has no
fallible surface form), so codegen never checks a return value.

### Task-local storage slot (`docs/context-propagation.md` decision B)

One word, **offset 33, size 8 bytes**, inside every task control block
(`runtime/sched/task.bit`'s `taskLocal`, index `taskWords - 1` — `taskWords`
grew from 32 to 33 words to hold it, then to 34 for `taskTimerPrev` at 32,
#5887, which moved this slot from 32 to 33). Present on `main`'s task, every worker's
idle-loop task, and every spawned task alike, because it lives in the same
fixed-size block `schedTaskInit` zeroes for all of them, not in the one extra
word `taskSpawnEntry` reserves for a spawned task only.

**Semantics.** The slot is owned exclusively by the task it belongs to.
`bit_rt_task_local_get()` and `bit_rt_task_local_set(v: i64)` read and write
the CALLING task's own slot only — there is no cross-task accessor. At
`bit_rt_spawn`, the runtime copies the spawning task's word into the new
child's word once, synchronously, on the parent's own stack, after the
child's task control block is initialised (`schedTaskInit`, which zeroes the
word first) and before the child is published to any worker queue
(`runtime/root/<os>/boot.bit`'s `rtSpawn`, immediately before its call to
`schedSpawn`) — so no reader of the child's word can observe anything but
either that snapshot or the child's own later write, and the parent's word is
never written by anything but the parent itself. A task with no parent (there
is exactly one: `main`) starts at 0.

**The word is opaque to the runtime** — a plain `i64`, not a typed value. It
may hold a small integer or the address of a GC-managed object; the runtime
does not decode it either way. `runtime/stw/stwscan.bit`'s `stwScanTasks`
marks it conservatively for every registered task on every collection
(`runtime/stw/stw.bit` root class 5, alongside the pending-spawn `arg` word),
so a live reference stored here survives a collection for as long as the
owning task holds it — exactly the property a future typed `Context` value
needs before it can be built on top of this slot.

**Exported C symbols:**

| Symbol | Signature |
|--------|-----------|
| `bit_rt_task_local_get` | `() -> i64` — the calling task's own word, or `0` off a task stack |
| `bit_rt_task_local_set` | `(v: i64) -> void` — a no-op off a task stack |

`stdlib/runtime`'s `taskLocalGet`/`taskLocalSet` (`docs/stdlib/runtime.md`)
are the only sanctioned callers. **No public `Context` API lands with this
slot** — see `docs/context-propagation.md`'s decision: this is the primitive
`std/trace` and later request-scoped mechanisms build on, not a
finished feature.

### 9.1 x86_64-windows: xmm6..xmm15 across a foreign-to-Bit entry (#6434)

Win64 makes `xmm6`..`xmm15` nonvolatile: a function a foreign caller reaches must
return all **128 bits** of each unchanged. Bit's backend uses `xmm14`/`xmm15` as
its float scratch pair (`xFScratch1`/`xFScratch2`, `compiler/x64.bit`) on every
target and allocates `xmm0`..`xmm13`, so the rule is stated once, here.

**The rule.** On Win64 every Bit function preserves, in full, each nonvolatile
XMM it can write, and nothing else is the entry's job:

- `xBuildSavedXmm` (`compiler/x64compile.bit`) lists the registers a function
  owes: the `xmm6`..`xmm13` its allocation placed a float in, plus `xmm14` and
  `xmm15` whenever the function holds any float value (a spilled one included,
  since every float load, convert and move cycle goes through the scratch pair).
  A function with no float value saves nothing. SysV preserves no XMM and saves
  none; its code is unchanged.
- The save and the restore are `movups` into a 16-byte frame slot
  (`xXmmSaveOffset`, `xMovUpsStore`/`xMovUpsLoad` in `compiler/x64frame.bit`),
  never `movsd`: a `movsd` keeps 64 bits and its load ZEROES the upper 64.
- Bit-to-Bit calls follow the same rule, so a foreign caller of any Bit function
  gets its XMMs back whole without a trampoline. No entry below needs one.
- The panic boundary (`bit_rt_panic_boundary_arm`/`take`, §12) is a non-local
  return that skips epilogues, so it saves and restores the same registers in
  full: the low halves with `movsd` in context words 10..19 and the high halves
  with `movhpd` in `bndFpHi` (record words 59..68).
- `schedSwitch` (`runtime/sched/switch.bit`) still saves only the low 64 bits.
  That is sound because it switches between green tasks, whose stacks and entry
  points are all Bit's own (`schedTaskInit`); no foreign frame is ever resumed
  across it. A foreign thread calling a Bit `@symbol` export runs on its own
  stack, not in a task.

**Every foreign-to-Bit entry on x86_64-windows.** Found by listing every
`entryOf(...)` handed to the OS and every `@symbol` export; a task entry
(`mainTrampoline`, `winSpawnTrampoline`) and the `stwSafepoint` shim target are
reached from Bit code only and are not foreign entries.

| Entry | Called by | Preservation |
| --- | --- | --- |
| `winMain`, `@symbol("_start")` (`runtime/root/windows/boot.bit`) | the loader, as `AddressOfEntryPoint` | Never returns to its caller: it ends in `ExitProcess`. Preserved anyway by the rule above. |
| `workerBody` (`runtime/root/windows/boot.bit`, `CreateThread` in `boot`) | the OS thread start thunk | Returns only into `RtlExitUserThread`, which does not return. The rule above holds for every frame it runs. |
| `threadTrampoline` (`runtime/thread/windows/spawn.bit`, `CreateThread` in `threadStart`) | the OS thread start thunk | Same as `workerBody`. |
| `vehHandler` (`runtime/root/windows/signal.bit`, `AddVectoredExceptionHandler` in `installFatalSignalHandlers`) | `ntdll` exception dispatch, which resumes after it returns | Returns to ntdll: preserved by the rule above (`movups` save of whatever it and its callees write). Fixed here; before #6434 it came back with `xmm14`/`xmm15` and the upper halves of `xmm6`..`xmm13` altered. |
| `consoleCtrlHandler` (`runtime/root/windows/signal.bit`, `SetConsoleCtrlHandler` in `installConsoleCtrlHandler`) | the OS console-control thread | Same as `vehHandler`. |
| any user `export @symbol` function | a C caller | Same rule: it is an ordinary Bit function. |

`test-windows-smoke` runs `_tests_/stress/thread/winxmm/` on a real Win64 host: an asm stub
acting as a C caller loads a known 128-bit pattern into `xmm15` and into `xmm6`
with a distinct upper half, calls a Bit function doing float work, and checks
both patterns afterwards.

### Exported C symbols (all `bit_rt_*`, one process-wide runtime instance)

**This table is a selection, not a census.** Every row below is exported and
stable, but a name's ABSENCE here says nothing: on `e869af60` plus this
change, `git grep -ho '@symbol("bit_rt_[a-z0-9_]*")' -- runtime | sort -u`
reports 594 pinned names against the 137 rows below. Most of the gap is
`bit_rt_port_*` test pins and GC/scheduler/provider internals, but not all of
it — `bit_rt_chan_recv_ok`, an ordinary §11 entry point generated code calls
directly, has no row. Every `bit_rt_fs_*` symbol does have one now,
which is a fact about §14 today rather than a rule the table follows. **Each
section's own prose is the authority for its family**; use this table as an
index into them, never as the exported-symbol list.

**Standing rule for Bit-sourced runtime modules: every runtime function another
module calls MUST be pinned with `@symbol("...")` (SPEC §11.9).** This is a
structural requirement, not a style preference, and it is not optional for
anything in the table below.

The reason is `modulePrefix`: a non-root module's symbols are emitted as
`m<id>$name`, where `<id>` is an ordinal the **importing** build assigns. The
ordinal is therefore a property of the build that consumed the module, not of
the module itself, so the same source compiled into two separately emitted
objects gets two different names. `export` does not bypass this — it controls
Bit-level visibility (may another module import the name), not the link-level
symbol. Meanwhile code generation calls the runtime by fixed name (`bit_rt_alloc`,
`bit_rt_safepoint`, ...). Without a pin, a Bit-sourced runtime module can never
define the symbol the caller emits a reference to, and the archive members will
not link.

`@symbol` fixes the **name, not the retention**: a linker still dead-strips a
definition nothing references. `export` and `@symbol` are independent and
compose freely.

The rule is **enforced by `--freestanding` itself** (SPEC §17.6), so forgetting
a pin is a build failure naming the symbol rather than a link error, a
dead-stripped reference, or a dyld abort at load. Both compilers refuse to emit
a freestanding object that would reference a compiler-mangled name it does not
define.

Pins are validated by both compilers — E0079 `symbol_attr_invalid` (one
string-literal argument, a C identifier, free non-generic functions only, C-ABI
signature) and E0080 `duplicate_symbol` (project-wide: each pinned name must be
defined exactly once).

| Symbol               | Signature                                              |
|-----------------------|--------------------------------------------------------|
| `bit_rt_gc_alloc`     | `(info: *const TypeInfo) -> *u8` (§6)                  |
| `bit_rt_iface_lookup` | `(info: *const TypeInfo, id: u64) -> *const anyopaque` (§2.1) |
| `bit_rt_iface_lookup_ic` | `(info: *const TypeInfo, id: u64, cell: *[2]usize) -> *const anyopaque` (§2.1, a `call_iface` site's cache miss) |
| `bit_rt_safepoint`    | `() -> void` (§6)                                      |
| `bit_rt_module_roots_register` | `(table: usize) -> void` (§4.3, called first by the entry `main` when the program has a traced module cell) |
| `bit_rt_spawn`        | `(fn_ptr: TaskFn, arg: ?*anyopaque) -> void`            |
| `bit_rt_chan_make`    | `(capacity: usize, is_ref: bool) -> *anyopaque` (§11)  |
| `bit_rt_chan_send`    | `(ch: ?*anyopaque, value: u64) -> void` (§11)          |
| `bit_rt_chan_recv`    | `(ch: ?*anyopaque) -> ChanRecvResult` (§11)             |
| `bit_rt_chan_close`   | `(ch: ?*anyopaque) -> void` (§11)                       |
| `bit_rt_select_alloc` | `(n: usize) -> *SelectCaseDesc` (§11)                   |
| `bit_rt_select`       | `(descs: *SelectCaseDesc, n: usize, has_default: bool) -> usize` (§11) |
| `bit_rt_panic`        | `(msg: *const RtBytes) -> noreturn` (§12)               |
| `bit_rt_panic_div_zero` | `() -> noreturn` (§12.1)                              |
| `bit_rt_panic_overflow` | `() -> noreturn` (§12.1, §13.5)                       |
| `bit_rt_panic_nil_call` | `() -> noreturn` (§12.1)                              |
| `bit_rt_panic_nil_iface` | `() -> noreturn` (§12.1)                             |
| `bit_rt_assert`       | `(cond: bool, msg: *const RtBytes) -> void` (§12)       |
| `bit_rt_print`        | `(s: *const RtBytes) -> void` (§12, fd 1)               |
| `bit_rt_eprint`       | `(s: *const RtBytes) -> void` (§12, fd 2)               |
| `bit_rt_string_concat`| `(a: *const RtBytes, b: *const RtBytes) -> *const RtBytes` (§2) |
| `bit_rt_string_concat5`| `(a: *const RtBytes, ..., e: *const RtBytes) -> *const RtBytes` (§2, five operands joined in ONE sized allocation; an operand past the last real part is the empty string, which lowering materializes as a pooled `const_string ""` — a null header reads the same way through §2's string funnel. Interpolation joins four new parts per call instead of folding one per binary `string_concat`) |
| `bit_rt_string_eq`    | `(a: *const RtBytes, b: *const RtBytes) -> bool` (§2)   |
| `bit_rt_string_eq_words` | `(a_ptr: *const u8, a_len: usize, b_ptr: *const u8, b_len: usize) -> bool` (§2 — the same comparison over the two views' `ptr`/`len` words instead of two boxed headers, and the form lowering emits for `==`/`!=`. `bit_rt_string_eq` stays exported and delegates here, so the two cannot drift. The boxed form is what forced a 24-byte view to exist at every comparison: a one-handle call NAMES the box, which `optalloc.bit` treats as an escape, so the allocation could never be dropped. Keeping the backing rooted across the call is the CALLER's job — this side is `@nosplit` — and lowering does it with the keepalive edges `unboxStringWords` records.) |
| `bit_rt_string_cmp`   | `(a: *const RtBytes, b: *const RtBytes) -> i64` (§2, three-way lexicographic order; unsigned bytes, shorter-is-less on a common prefix) |
| `bit_rt_string_byte`  | `(s: *const RtBytes, index: usize) -> u64` (§2, `s[i]`; u64-widened) |
| `bit_rt_string_slice` | `(s: *const RtBytes, lo: usize, hi: usize) -> *const RtBytes` (§2, `s[lo:hi]`; a shared-backing view — header only, `base = s`, no byte copy) |
| `bit_rt_bytes_from_string` | `(s: *const RtBytes) -> *SliceHeader` (§2, `[]byte(s)`) |
| `bit_rt_string_from_bytes` | `(h: *const SliceHeader) -> *const RtBytes` (§2, `string(b)`) |
| `bit_rt_string_from_byte_range` | `(h: *const SliceHeader, lo: usize, hi: usize) -> *const RtBytes` (§2, `string(b[lo:hi])` in one call, #6558: a fresh string holding bytes `lo..hi` of `b`'s view, with no intermediate slice header. Bounds and panic are `bit_rt_slice_slice`'s exactly — a null `h` admits only `[0:0]`, otherwise `0 <= lo <= hi <= cap`, else "slice bounds out of range" — and the caller has already evaluated `b`, `lo`, `hi` in reslice order) |
| `bit_rt_string_from_rune` | `(r: i32) -> *const RtBytes` (§2, `string(r)`, #7101: the UTF-8 encoding of `r` in one exactly-sized string. Only the low 32 bits of the register are read, so the caller's sign- or zero-extension is immaterial; a negative value, a surrogate U+D800..U+DFFF or a value above U+10FFFF encodes U+FFFD) |
| `bit_rt_string_from_runes` | `(h: *const SliceHeader) -> *const RtBytes` (§2, `string(rs)` for a `[]rune`, #7101: each element encoded as `bit_rt_string_from_rune` does, in one exactly-sized string; a null `h` is `""`) |
| `bit_rt_string_from_rune_range` | `(h: *const SliceHeader, lo: usize, hi: usize) -> *const RtBytes` (§2, `string(rs[lo:hi])` for a `[]rune` in one call, #7637: `bit_rt_string_from_runes` over the elements `lo..hi` of `rs`'s view, with no intermediate slice header. Bounds and panic are `bit_rt_slice_slice`'s exactly — a null `h` admits only `[0:0]`, otherwise `0 <= lo <= hi <= cap`, else "slice bounds out of range" — and the caller has already evaluated `rs`, `lo`, `hi` in reslice order) |
| `bit_rt_runes_from_string` | `(s: *const RtBytes) -> *SliceHeader` (§2, `[]rune(s)`, #7101: a fresh `[]i32`, packed at 4 bytes per element (#7574), `len == cap ==` the code point count. An invalid byte sequence is U+FFFD and consumes one byte, `std/strings`' `decodeRune` rule) |
| `bit_rt_string_from_int`   | `(v: i64) -> *const RtBytes` (§2, the signed prims i8..i64) |
| `bit_rt_string_from_uint`  | `(v: u64) -> *const RtBytes` (§2, the unsigned prims u8..u64, zero-extended by the caller) |
| `bit_rt_string_from_float` | `(v: f64) -> *const RtBytes` (§2)                  |
| `bit_rt_parse_float`  | `(s: *const RtBytes) -> f64` (§2, correctly-rounded text->f64; the inverse of `bit_rt_string_from_float`) |
| `bit_rt_string_from_bool`  | `(v: bool) -> *const RtBytes` (§2)                 |
| `bit_rt_slice_new`    | `(len: usize, cap: usize, is_ref: usize, elem_size: usize) -> *SliceHeader` (§2, `elem_size` in **bytes** — `1` for a packed `[]u8`, a class's own body size for a packed all-scalar `T`, `16` for a `decimal`, `8` for every other element type) |
| `bit_rt_slice_append` | `(h: *SliceHeader, word: u64, is_ref: usize, elem_size: usize) -> *SliceHeader` (§2, `is_ref`/`elem_size` are the static element type's — a null `h` has no header to read them from; for `elem_size > 8` writes only the element's low word, since the payload is one `u64` — the caller fills the rest at its own computed offset) |
| `bit_rt_slice_append_str` | `(h: ?*SliceHeader, s: ?*const RtBytes) -> *SliceHeader` (§2 — appends the string's BYTES to a `[]u8` in one call, the shape `append(dst, s)` lowers to when `dst`'s element is `u8`. Stride and `is_ref` are fixed at `1`/`0` by that operand rule, so neither travels. A null `h` allocates a fresh header exactly as `bit_rt_slice_append` does; a null `s` is the empty string (§2's null-header contract) and appends nothing. Grows ONCE to `max(2 * cap, len + n)`, so a long string costs one allocation rather than one per doubling. Same aliasing contract as `bit_rt_slice_append`.) |
| `bit_rt_slice_append_slice` | `(h: ?*SliceHeader, src: ?*const SliceHeader, is_ref: usize, elem_size: usize) -> *SliceHeader` (§2 — `append(dst, ...src)` in one call, every element type (#7377). `is_ref`/`elem_size` are the static element type's, as for `bit_rt_slice_append`; a null `h` allocates a fresh header, a null `src` is empty and appends nothing. Grows ONCE to `max(2 * cap, len + n)`, then moves `n * stride` bytes overlap-safely, so the result holds `src` as it stood at the call even when `src` views `h`'s own buffer. Same aliasing contract as `bit_rt_slice_append`; `bit_rt_slice_append_slice_fresh` is the default compiler target and never writes a non-null `h` (the temporary explicit-zero escape and proven-owned calls use the mutating target).) |
| `bit_rt_slice_get`    | `(h: *const SliceHeader, index: usize, elem_size: usize) -> u64` (§2; FATAL for a packed, non-ref buffer with `elem_size` neither `1` nor `8` — one `u64` cannot represent a wider element without truncating) |
| `bit_rt_slice_set`    | `(h: *SliceHeader, index: usize, word: u64, elem_size: usize) -> void` (§2; FATAL under the identical condition `bit_rt_slice_get` is, and for the identical reason) |
| `bit_rt_slice_slice`  | `(h: *const SliceHeader, lo: usize, hi: usize) -> *SliceHeader` (§2, unchanged — reslicing works in element counts already, `runtime/root/slices.bit` `rtSliceSlice`) |
| `bit_rt_map_new`      | `(key_desc: usize, val_is_ref: usize, cap_hint: i64) -> *MapHeader` (§15, §15.1; `cap_hint <= 0` is no hint) |
| `bit_rt_map_set`      | `(m: ?*MapHeader, key: u64, val: u64) -> void` (§15)    |
| `bit_rt_map_get`      | `(m: ?*MapHeader, key: u64) -> u64` (§15)               |
| `bit_rt_map_has`      | `(m: ?*MapHeader, key: u64) -> bool` (§15)              |
| `bit_rt_map_slot`     | `(m: ?*MapHeader, key: u64) -> i64` (§15, a hit token `>= 0` for `map_val_at`, or `-1`) |
| `bit_rt_map_get_str`  | `(m: ?*MapHeader, ptr: *const u8, len: usize) -> u64` (§15; `bit_rt_map_get` for a `string` key passed as its bytes, not a header) |
| `bit_rt_map_slot_str` | `(m: ?*MapHeader, ptr: *const u8, len: usize) -> i64` (§15; `bit_rt_map_slot` for a `string` key passed as its bytes, not a header) |
| `bit_rt_map_delete`   | `(m: ?*MapHeader, key: u64) -> void` (§15)              |
| `bit_rt_map_len`      | `(m: ?*MapHeader) -> i64` (§15)                         |
| `bit_rt_map_hash_seed`| `() -> u64` (§15; the seed every map hash starts from, drawn per process at boot, #7379, §7 `BIT_HASH_SEED`. The compiler's synthesized `__valueHash` (SPEC §14.3) starts from the same value) |
| `bit_rt_map_iter_init`| `(m: ?*MapHeader) -> i64` (§15)                         |
| `bit_rt_map_iter_next`| `(m: ?*MapHeader, prev: i64) -> i64` (§15)              |
| `bit_rt_map_key_at`   | `(m: *MapHeader, slot: i64) -> u64` (§15)               |
| `bit_rt_map_val_at`   | `(m: *MapHeader, slot: i64) -> u64` (§15; a NEGATIVE slot reads as `0`, so `map_slot`'s miss marker needs no branch at the call site) |
| `bit_rt_fs_open`      | `(path: *const RtBytes, write: bool) -> i64` (§14, fd, or `-1`; `write=false` opens read-only, `write=true` creates+truncates write-only at mode `0644`. Rejects a DIRECTORY — `open(2)` on one succeeds `O_RDONLY`, handing out a `File` nothing can read) |
| `bit_rt_fs_append`    | `(path: *const RtBytes) -> i64` (§14)                   |
| `bit_rt_fs_read`      | `(fd: i64, max: i64) -> *const RtBytes` (§14)           |
| `bit_rt_fs_read_all`  | `(fd: i64) -> *const RtBytes` (§14, the whole file, regular files only — sized by `lseek(SEEK_END)`, then TRIMMED to the bytes actually read, never zero-padded. An empty result is ambiguous in-band, since `string` has no nil sentinel; `bit_rt_fs_read_all_failed` below carries the distinction) |
| `bit_rt_fs_read_all_failed` | `() -> bool` (§14, the out-of-band companion flag for the row above: true when `lseek` failed or the allocation for an already-known-non-empty file failed, and NEVER for a genuinely empty file. Per-task state cleared at each `bit_rt_fs_read_all` entry, so it must be read immediately after that call with no yield between) |
| `bit_rt_fs_write`     | `(fd: i64, s: *const RtBytes) -> i64` (§14, bytes written, or `-1`) |
| `bit_rt_fs_close`     | `(fd: i64) -> i64` (§14, always `0` — the raw wrapper swallows `EINTR`/`EBADF`, so a caller has no close error to handle) |
| `bit_rt_fs_exists`    | `(path: *const RtBytes) -> bool` (§14)                  |
| `bit_rt_fs_is_dir`    | `(path: *const RtBytes) -> bool` (§14)                  |
| `bit_rt_fs_mkdir`     | `(path: *const RtBytes) -> i64` (§14)                   |
| `bit_rt_fs_remove`    | `(path: *const RtBytes) -> i64` (§14)                   |
| `bit_rt_fs_rename`    | `(oldPath: *const RtBytes, newPath: *const RtBytes) -> i64` (§14) |
| `bit_rt_fs_chmod`     | `(path: *const RtBytes, mode: i64) -> i64` (§14, sets `path`'s permission bits to `mode`; `0`, or `-1` on any error. Darwin calls libc `chmod`, Linux the raw `chmod`/`fchmodat(AT_FDCWD, ...)` syscall. Windows maps ONLY the POSIX owner-write bit (`mode & 0o200`) to `FILE_ATTRIBUTE_READONLY` — see that provider's header scope note, `runtime/root/windows/fs.bit:85`) |
| `bit_rt_fs_list_dir`  | `(path: *const RtBytes) -> *const RtBytes` (§14)        |
| `bit_rt_fs_is_symlink_w` | `(words: usize, n: i64) -> bool` (§14, `words` is a `[]byte`'s backing, packed one byte per element (§2) — not NUL-terminated, not `RtBytes`; the FIRST entry point shaped this way and now the family's convention — eight `bit_rt_fs_*_w` symbols share it, six carrying a path (this, `bit_rt_fs_open_rw_w`, `bit_rt_fs_open_nofollow_w`, `bit_rt_fs_stat_w`, `bit_rt_fs_lstat_w`, `bit_rt_fs_sync_dir_w`) and two a data buffer (`bit_rt_fs_pread_w`/`bit_rt_fs_pwrite_w`)) |
| `bit_rt_fs_sync`      | `(fd: i64) -> i64` (§14, `0` on success, `-1` on failure; Darwin uses `F_FULLFSYNC`, falling back to bare `fsync` only on `ENOTSUP` — bare `fsync` alone does not flush the drive's write cache on that platform) |
| `bit_rt_fs_truncate`  | `(fd: i64, size: i64) -> i64` (§14, sets `fd`'s length; `0`, or negative on any failure. Never moves the fd's own cursor, matching `bit_rt_fs_pread_w`/`bit_rt_fs_pwrite_w`; growing leaves a HOLE rather than reserving blocks, so a later write can still fail `ENOSPC`, and the new length is not durable until `bit_rt_fs_sync`) |
| `bit_rt_fs_size`      | `(fd: i64) -> i64` (§14, `fd`'s length in bytes, or negative on any failure; `fstat` on Darwin/Linux, `GetFileSizeEx` on Windows) |
| `bit_rt_fs_lock`      | `(fd: i64, exclusive: bool, blocking: bool) -> i64` (§14, whole-file advisory lock — `flock(2)` on Darwin/Linux, `LockFileEx` over the `MAXDWORD`/`MAXDWORD` range on Windows. A normalized THREE-WAY result, deliberately not the `-errno` of `bit_rt_fs_stat_w`: `0` success; `-1` ONLY when `blocking` is false and the lock is held elsewhere, which is `tryLock`'s expected outcome rather than a failure; `-2` any other error) |
| `bit_rt_fs_unlock`    | `(fd: i64) -> i64` (§14, releases the lock above; `0`, or `-2` — `-1` has no meaning here, since releasing a lock has no "would block" outcome. A no-op success on an fd holding no lock, on every platform, so a caller never tracks whether it currently holds one) |
| `bit_rt_fs_pread_w`   | `(fd: i64, buf: usize, max: i64, off: i64) -> i64` (§14, positional read: `buf` is a `[]byte`'s backing, packed one byte per element (§2) — not `RtBytes`, not NUL-terminated, same convention `bit_rt_fs_is_symlink_w` uses; byte count transferred, or negative on any I/O error; a short count, including 0 at end of file, is NOT an error) |
| `bit_rt_fs_pwrite_w`  | `(fd: i64, buf: usize, n: i64, off: i64) -> i64` (§14, positional write: same `buf` convention as `bit_rt_fs_pread_w`; byte count transferred, or negative on any I/O error; extends the file or leaves a zero-filled hole as POSIX `pwrite(2)` does) |
| `bit_rt_fs_open_rw_w` | `(words: usize, n: i64) -> i64` (§14, read-write open: same packed-bytes `words`/`n` convention as `bit_rt_fs_is_symlink_w`; `O_RDWR\|O_CREAT`, deliberately WITHOUT `O_TRUNC` -- creates `path` if absent, never destroys existing content on open; fd, or -1. Darwin/Linux only -- windows deferred, see runtime/root/{darwin,linux}/fsopenrw.bit and fs.bit) |
| `bit_rt_fs_stat_w`    | `(words: usize, n: i64, out: usize) -> i64` (§14, same packed-bytes `words`/`n` path convention as `bit_rt_fs_is_symlink_w`; fills the caller-owned 5-word `out` buffer in fixed order — `size`, `mtime`, `mode`, `isDir`, `isSymlink` — FOLLOWING a trailing symlink, so `isSymlink` is always 0 here. Not the flat `-1` of the primitives above: 0 on success, `-errno` on failure) |
| `bit_rt_fs_lstat_w`   | `(words: usize, n: i64, out: usize) -> i64` (§14, identical to `bit_rt_fs_stat_w` except it does NOT follow a trailing symlink, so `out`'s `isSymlink` word reports whether `words` itself is a link; same 0/`-errno` return) |
| `bit_rt_fs_open_nofollow_w` | `(words: usize, n: i64) -> i64` (§14, read-only open that REFUSES a symlinked final path component instead of following it: same packed-bytes `words`/`n` convention as `bit_rt_fs_is_symlink_w`; `O_RDONLY|O_NOFOLLOW` on darwin/linux, `CreateFileW` with `FILE_FLAG_OPEN_REPARSE_POINT` plus a `GetFileInformationByHandle` reparse-point refusal on windows; a directory is refused too; fd/handle, or -1) |
| `bit_rt_fs_sync_dir_w` | `(words: usize, n: i64) -> i64` (§14, fsyncs the DIRECTORY named by the packed-bytes `words`/`n` path — the durability half `bit_rt_fs_sync` on a file does not cover; `0`, or `-1`; windows always reports 0) |
| `bit_rt_fs_cwd`       | `() -> *const RtBytes` (§14, the process's current working directory, or the empty string on any failure) |
| `bit_rt_test_index`   | `() -> i64` (§16)                                      |
| `bit_rt_floor`        | `(x: f64) -> f64` (§17)                                |
| `bit_rt_ceil`         | `(x: f64) -> f64` (§17)                                |
| `bit_rt_round`        | `(x: f64) -> f64` (§17)                                |
| `bit_rt_trunc`        | `(x: f64) -> f64` (§17)                                |
| `bit_rt_float_bits`   | `(v: f64) -> u64` (§17, IEEE-754 bit pattern, no conversion; unreached by generated code — `floatBits` lowers to an inline bitcast) |
| `bit_rt_float32_bits` | `(v: f32) -> u32` (§17, same, for f32/`float32Bits`)   |
| `bit_rt_pow`          | `(x: f64, y: f64) -> f64` (§17)                        |
| `bit_rt_atan2`        | `(y: f64, x: f64) -> f64` (§17)                        |
| `bit_rt_log`          | `(x: f64) -> f64` (§17)                                |
| `bit_rt_log2`         | `(x: f64) -> f64` (§17)                                |
| `bit_rt_log10`        | `(x: f64) -> f64` (§17)                                |
| `bit_rt_time_mono_ns` | `() -> i64` (§18)                                      |
| `bit_rt_time_unix_ns` | `() -> i64` (§18)                                      |
| `bit_rt_time_sleep_ns`| `(ns: i64) -> void` (§18)                              |
| `bit_rt_os_argc`      | `() -> i64` (§19)                                      |
| `bit_rt_os_arg_at`    | `(i: i64) -> *const RtBytes` (§19)                     |
| `bit_rt_os_env`       | `(name: *const RtBytes) -> *const RtBytes` (§19)       |
| `bit_rt_os_env_present` | `(name: *const RtBytes) -> bool` (§19)              |
| `bit_rt_os_self_exe`  | `() -> *const RtBytes` (§19)                           |
| `bit_rt_os_hostname`  | `(buf: *byte, room: i64) -> i64` (§19, #7192: writes the local host name NUL-terminated into the caller's `room`-byte buffer and returns its length, always `< room`; `-1` when the call fails or the name plus its NUL does not fit, never a truncated name (Darwin cannot tell a name of `room - 1` bytes from a truncated one, so it refuses that length too). Darwin `gethostname(2)`, Linux `uname(2)` `nodename`, Windows `GetComputerNameExW(ComputerNameDnsHostname)` re-encoded as UTF-8. A plain `extern fn` taking a caller buffer, not a compiler primitive: §11.7 admits no `string` return) |
| `bit_rt_os_exit`      | `(code: i64) -> noreturn` (§19)                        |
| `bit_rt_os_run`       | `(path: *const RtBytes, argv: *const SliceHeader) -> i64` (§19) |
| `bit_rt_os_run_test`  | `(path: *const RtBytes, idx: i64) -> i64` (§19)        |
| `bit_rt_os_run_bounded` | `(path: *const RtBytes, timeout_ms: i64) -> i64` (§19) |
| `bit_rt_os_run_test_bounded` | `(path: *const RtBytes, idx: i64, timeout_ms: i64) -> i64` (§19) |
| `bit_rt_host_target`  | `() -> i64` (§19)                                      |
| `bit_rt_os_wait_for_signal` | `() -> i64` (§19, #6087): blocks until the process receives SIGTERM or SIGINT (Linux/Darwin) or a Ctrl-C/Ctrl-Break/close console event (Windows), returns the raw POSIX signal number (2 = SIGINT, 15 = SIGTERM — the same two numbers on every platform this runtime supports). A plain `extern fn` in `stdlib/signal/signal.bit` (`std/signal`, deliberately NOT `std/os`), not a compiler primitive: `tools/build` imports `std/os`, so EITHER shape landing there would need the pinned stage0 compiler to already know it (#3538/#5901's bootstrap constraint) before `std/os` could typecheck at all — `std/signal` is its own module that neither `compiler/**` nor `tools/**` imports, so it carries no such ordering requirement. |
| `bit_rt_auxv`         | `() -> i64` (§19)                                      |
| `bit_rt_net_listen`   | `(host: *const RtBytes, port: i64) -> i64` (§20)       |
| `bit_rt_net_local_port` | `(fd: i64) -> i64` (§20)                             |
| `bit_rt_net_peer_addr_w` | `(fd: i64, outWords: usize) -> i64` (§20, #7410: the connected peer's address written into the caller's own 16-byte `outWords` buffer in the IPv6 wire form, an IPv4 peer as its IPv4-mapped `::ffff:a.b.c.d`; `0`, or `-1` when `fd` has no peer. Reached through a plain `extern fn`, the same class as the deadline entries below, not the compiler-recognized builtins the rows around it lower to) |
| `bit_rt_net_accept`   | `(fd: i64) -> i64` (§20)                               |
| `bit_rt_net_dial`     | `(host: *const RtBytes, port: i64) -> i64` (§20)       |
| `bit_rt_net_dial_deadline_w` | `(hostWords: usize, hostLen: i64, port: i64, deadlineNs: i64) -> i64` (§20, `bit_rt_net_dial` bounded by ONE absolute monotonic `deadlineNs` on `bit_rt_time_mono_ns`'s clock rather than parking forever; `host` crosses as a packed `[]byte`'s backing plus a length (§2) because §11.7 admits no `string` across an `extern fn`. fd, `-1` hard failure, `-2` timed out) |
| `bit_rt_net_read`     | `(fd: i64, max: i64) -> *const RtBytes` (§20)          |
| `bit_rt_net_read_deadline_w` | `(fd: i64, outWords: usize, cap: i64, deadlineNs: i64) -> i64` (§20, same deadline shape as `bit_rt_net_dial_deadline_w`; the kernel reads straight into the caller's own packed `outWords` buffer instead of a fresh string, with no runtime scratch or copy between, so the caller keeps that buffer live across the call with `keepAlive` (SPEC §11.5), as `std/net` does. Byte count, `0` peer closed, `-1` hard error, `-2` timed out) |
| `bit_rt_net_read_bytes_w` | `(fd: i64, outWords: usize, cap: i64) -> i64` (§20, #7389: `bit_rt_net_read`'s byte-taking sibling — the kernel reads straight into the caller's own packed `outWords` buffer through the SAME parking, never-give-up engine `bit_rt_net_read` uses, not the deadline-bounded one, so `std/net`'s `Conn.readInto` with no deadline armed waits exactly like `Conn.read` and allocates nothing; the caller keeps the buffer live across the call with `keepAlive`. Byte count, `0` peer closed, `-1` hard error) |
| `bit_rt_net_write`    | `(fd: i64, s: *const RtBytes) -> i64` (§20)            |
| `bit_rt_net_write_deadline_w` | `(fd: i64, words: usize, n: i64, deadlineNs: i64) -> i64` (§20, same deadline shape; the body crosses as packed `words`/`n` and the kernel reads it straight from the caller's buffer, with no runtime copy, so the caller keeps that buffer live across the call with `keepAlive`. Bytes written, `-1` hard error, `-2` timed out) |
| `bit_rt_net_write_bytes_w` | `(fd: i64, words: usize, n: i64) -> i64` (§20, #5928: `bit_rt_net_write`'s byte-taking sibling — same `words`/`n` packed-buffer shape `bit_rt_net_write_deadline_w` uses, but calls the SAME true-blocking, never-give-up engine `bit_rt_net_write` does, not the deadline-bounded one, so `std/net`'s `Conn.writeBytes` with no deadline armed behaves exactly like `Conn.write(s: string)`'s own no-deadline fast path. Bytes written, `-1` hard error) |
| `bit_rt_net_shutdown_sock_w` | `(fd: i64) -> bool` (§20, shuts BOTH directions of `fd` down without releasing it for reuse — see `netShutdownSock` in runtime/net/{darwin,linux,windows}/tcp.bit for why this exists alongside plain close. No buffer, so unlike its `_w` siblings it needs no packed-byte scratch; `true` on success) |
| `bit_rt_net_lookup_txt_w` | `(inWords: usize, hostLen: i64, nsLen: i64, port: i64, outWords: usize) -> i64` (§20, #6882: the TXT records of a host, written into the caller's own `outWords` buffer (65537 bytes) as entries of a two-byte big-endian length then that many bytes, one per TXT RR with its character-strings concatenated in order. `in` holds a 16-byte budget header (#6350: the per-attempt window in milliseconds, then the attempt count, each a little-endian 64-bit word; it rides in the buffer because the entry is at the five-parameter ceiling), then the host (`hostLen` bytes), then, when `nsLen > 0`, one nameserver's IPv4 or IPv6 text (at most 64 bytes) that is asked on `port`; `nsLen == 0` asks the configured nameservers on port 53: `/etc/resolv.conf` on POSIX, UP-adapter DNS addresses on Windows. A budget outside 1..1000000 for either word returns `-1`. Returns the bytes written (`0`: no TXT record, NXDOMAIN included), `-1` timeout or server failure, `-2` malformed reply, `-3` unsupported provider. A reply with TC set is repeated over TCP inside the same per-server budget: IPv4 nameservers on POSIX, IPv4 or IPv6 nameservers on Windows. Windows retains adapter-provided IPv6 scope IDs for both transports (#7153). Both buffers cross as packed `[]byte` backings the caller holds live with `keepAlive`) |
| `bit_rt_net_udp_bind` | `(host: *const RtBytes, port: i64) -> i64` (§20)       |
| `bit_rt_net_udp_send` | `(fd: i64, host: *const RtBytes, port: i64, data: *const RtBytes) -> i64` (§20) |
| `bit_rt_net_udp_recv_from_w` | `(fd: i64, outWords: usize, cap: i64, peerWords: usize) -> i64` (§20, #7746: the next datagram into the caller's own packed `outWords` buffer (up to `cap` bytes) and the sender's raw 16-byte `sockaddr_in` into the caller's own `peerWords` buffer, in ONE call, as recvfrom(2) does; the runtime keeps no last-sender state. The caller keeps both buffers live across the call with `keepAlive`. Byte count (`0` for a zero-length datagram, which has a valid sender), `-1` on error. A plain `extern fn` in `stdlib/net/net.bit`; it replaced the `netUdpRecv`, `netUdpSenderHost` and `netUdpSenderPort` compiler primitives and their three `bit_rt_net_udp_*` entries) |
| `bit_rt_net_resolve_w` | `(hostWords: usize, hostLen: i64, timeoutMs: i64, attempts: i64, outWords: usize) -> i64` (§20, #6350: the first A record of the host as a dotted quad written into the caller's own `outWords` buffer (at least 16 bytes), its byte count returned; `-1` once every nameserver has failed or an argument is refused (a host of 0 or over 255 bytes, a null buffer, `timeoutMs` or `attempts` outside 1..1000000). `timeoutMs` is the receive window of ONE try and `attempts` how many passes are made over the nameserver list (A, B, A, B: resolv.conf(5)'s meaning, so a dead first server costs one window before the second is asked; the window is fixed, no retrans back-off): `std/net` owns both (resolv.conf's `options timeout:N attempts:N`, defaults 5000 and 2) and the runtime keeps no default of its own. A plain `extern fn` in `stdlib/net/net.bit`, which replaced the `netResolve` compiler primitive and its `bit_rt_net_resolve` entry: a primitive's arity is baked into the compiler that emits the call, so widening it would have needed a stage0 repin (`tools/build/abiarity.bit`); an `extern` takes its arity from the source it is compiled against. Both buffers cross as packed `[]byte` backings the caller holds live with `keepAlive`) |
| `bit_rt_net_dns_servers_w` | `() -> i64` (§20, #7480: how many nameservers `bit_rt_net_resolve_w` walks that no `/etc/resolv.conf` line names, so `std/net`'s `resolveBudgetMs` budgets the servers the resolver asks. `0` on Linux and Darwin, whose list is that file, which `std/net` counts itself. On Windows the number of DNS servers, IPv4 and IPv6, that the adapters that are up carry (`GetAdaptersAddresses`, deduplicated, at most 16), from the SAME discovery the resolve walks, `0` when there is none. A plain `extern fn` in `stdlib/net/net.bit`) |
| `bit_rt_random_bytes` | `(len: i64) -> *const RtBytes` (§21)                   |
| `bit_rt_secure_zero`  | `(h: *SliceHeader) -> void` (§21)                      |
| `bit_rt_crypto_aes_hw_available` | `() -> bool` (§21b)                         |
| `bit_rt_crypto_ghash_hw_available` | `() -> bool` (§21b)                       |
| `bit_rt_crypto_sha256_hw_available` | `() -> bool` (§21b)                      |
| `bit_rt_crypto_aes_encrypt_hw` | `(rk: *byte, nr: i64, block: *byte, out: *byte) -> void` (§21b) |
| `bit_rt_crypto_aes_decrypt_hw` | `(drk: *byte, nr: i64, block: *byte, out: *byte) -> void` (§21b) |
| `bit_rt_crypto_aes_invert_schedule_hw` | `(erk: *byte, nr: i64, out: *byte) -> void` (§21b) |
| `bit_rt_crypto_aes_ctr32_hw` | `(rk: *byte, ctr: *byte, src: *byte, dst: *byte, blocks: i64) -> void` (§21b, counter mode: x86-64 AES-NI, arm64 ARMv8 AES) |
| `bit_rt_crypto_ghash_mul_hw` | `(acc0, acc1, b0, b1, h0, h1: u64, outHi: *u64) -> u64` (§21b) |
| `bit_rt_crypto_sha256_compress_hw` | `(state: *u32, block: *byte) -> void` (§21b) |
| `bit_rt_crypto_hwcaps` | `() -> u64` (§21c) |
| `bit_rt_crypto_x64_clmul_caps` | `() -> u64` (§21c, x86-64 CPUID: 2 when PCLMULQDQ and SSSE3, else 0) |
| `bit_rt_aes_hw_expand_key` | `(key: i64, keyBits: i64, roundKeys: i64) -> void` (§21d) |
| `bit_rt_aes_hw_encrypt_block` | `(roundKeys: i64, rounds: i64, blockIn: i64, out: i64) -> void` (§21d) |
| `bit_rt_aes_hw_decrypt_block` | `(roundKeys: i64, rounds: i64, blockIn: i64, out: i64) -> void` (§21d) |
| `bit_rt_ghash_hw_keys` | `(h: i64, keys: i64, keysLen: i64) -> void` (§21e, #7460: the key table for subkey H, built once per key into a caller buffer of at least 304 bytes) |
| `bit_rt_ghash_hw_blocks_keyed` | `(keys: i64, state: i64, data: i64, blocks: u64) -> void` (§21e, #7460: folds `blocks` 16-byte blocks into `state` under that table) |
| `bit_rt_sha256_hw_blocks` | `(state: i64, data: i64, blocks: u64) -> void` (§21f) |
| `bit_rt_bytes_copy`   | `(dst: *byte, src: *byte, n: i64) -> void` (§11.4/§11.7, `@nosplit`, bounded by `n` — copies `n` bytes; regions must be disjoint) |
| `bit_rt_bytes_equal`  | `(a: *byte, b: *byte, n: i64) -> bool` (§11.4/§11.7, `@nosplit`, bounded by `n`) |
| `bit_rt_bytes_indexbyte` | `(p: *byte, n: i64, b: u8) -> i64` (§11.4/§11.7, `@nosplit`, bounded by `n` — first index of `b` in `[0, n)`, or -1) |

**Narrow return values.** The C ABI returns a `bool` in `al`/`w0` and leaves the
rest of the return register **unspecified**; the same is true of any sub-word
integer. A Bit `bool` is a full-width 0/1, because `!b` and the branch tests read
the whole register. Codegen therefore zero-extends a `bool`-typed call result at
the call boundary, on both targets. Do not rely on a particular callee zeroing
it: `bit_rt_string_eq` happened to, `bit_rt_fs_exists` did not, and
`!fsExists(missing)` silently evaluated to `false` on x86-64. A primitive that
returns a wider integer (e.g. `bit_rt_string_byte` returning `u64` rather than
`u8`) sidesteps the question entirely, which is why it does.

Every symbol above is `callconv(.c)` with plain C linkage — the entire
compiler-facing surface of `libbitrt.a`. Nothing else in `runtime/` is a stable
call target for codegen; reach the collector, scheduler, and channels only
through this table.

---

## 10. Main entry normalization

SPEC.md §17.4 permits four surface `main` signatures. Codegen normalizes
whichever one a program declares into one fixed native shape and emits it
under the fixed symbol name `bit_main`:

```
bit_main() -> i32     // callconv(.c); the process exit code
```

Normalization (all four collapse to this one shape):

| Surface form               | `bit_main` body                                  |
|-----------------------------|---------------------------------------------------|
| `fn main() { ... }`         | run the body, return `0`                          |
| `fn main(): int { ... }`    | return the declared `int` directly                |
| `fn main(): ()! { ... }`    | on ok, return `0`; on err, print it to stderr, return `1` |
| `fn main(): int! { ... }`   | on ok, return the declared `int`; on err, print it to stderr, return `1` |

`boot` (§9) spawns `bit_main` as the first green thread and returns its `i32`
as the process exit code, truncated to a byte for the OS `exit` syscall (a
negative or out-of-`u8`-range value truncates, matching every POSIX shell's own
exit-code truncation — Bit does not special-case it).

### Where the fallible rows are realized

The trampoline that defines `bit_main` is hand-assembled (`emitmacho.bit`,
`emitelf.bit`); it can `bl main` and it can zero the return register, and that
covers the first two rows. It cannot dispatch `error.message()`, because the
interface method's dispatch id is assigned per program (§2.1). So the third and
fourth rows are emitted as ordinary lowered IR instead, by `compiler/lowerentry.bit`:

- the user's fallible `main` body is emitted under the private link name
  **`main$fallible`** (same shape it always had — a void or `T` result, with the
  error travelling as the last return word, §13);
- a synthesized `main`, result `i64`, calls it, tests that error word (or
  the slot with `BIT_ERR_REG=0`), and branches. The `i64` result is also what stops the
  trampoline zeroing the return register: its void-`main` test reads the IR
  function's result type.

The err arm writes **`error: <msg>\n`** to fd 2 through `bit_rt_eprint`, as one
concatenated write. SPEC §17.4 fixes fd 2 and exit 1 but not the wording; the
prefix matches the runtime's own `panic: <msg>\n` (§12), which is the only other
line a running Bit program puts on fd 2, and keeps a failed `main` from reading
as the program's own logging. No new runtime symbol: `bit_rt_string_concat` and `bit_rt_eprint` all already exist.

The ok arm returns the declared `int` as the exit code for `main(): int!`
(§17.4's fourth signature), widened to `i64` first, and `0` for `main(): ()!`.
Under checker rule E0085, these are the only two ok types that reach
this code — every other shape (`f64!`, `string!`, `bool!`, ...) is rejected at
`bit check` before lowering ever runs, rather than silently returning `0` with
a float ok value handed back in `d0`/`xmm0` and read out of `x0`/`eax` as
whatever was left there.

This row did not always exist in code: `fail` used to set the slot with
nothing reading it, and a failed `main` exited 0 with an empty stderr.

### Module startup initializers (#6480)

A module `let`/`const` whose initializer is not a compile-time constant is
initialized by the program, not by the object file. `compiler/lowerstartup.bit`
emits one `()!` function per such cell, `bit$init$<module id>$<name>`, and one
driver, **`bit$startup`**, that calls them in program order: modules in id order
(a module's id is greater than every id it imports, so dependencies run first),
then the cells of a module top to bottom. The root `main`'s first statement is a
call to `bit$startup`, and so is the first statement of the `bit test` dispatch
`main`; no per-target entry code is involved. The driver therefore runs on the
first green task, after `boot` has brought up the scheduler and the collector, so
an initializer may allocate, spawn and block.

The driver tests each init function's error word (§13; the §7 error slot with
`BIT_ERR_REG=0`) after the call. A pending error
writes one line to fd 2 through `bit_rt_eprint` and ends the process through
`bit_rt_os_exit`:

```
error: module <path> failed to start: <message> (<path>/<file>:<line>)
```

`<path>` is the module's import path as its first importer wrote it (`.` for the
root), `<message>` is `error.message()`, `<file>` is the base name of the file of
the declaration the initializer belongs to and `<line>` the line it starts on.
No host path is embedded, so a binary does not depend on the directory it was
built in. The exit code is
**3**: `0` is success, `1` a fallible `main`'s error, `2` a panic (§12), so a
failed start is distinguishable from both. Deferred calls do not run and `main`
is never entered. No new runtime symbol is involved.

---


[Previous: Collector behavior and diagnostics](collector.md) | [Next: Channels, errors, and filesystem primitives](channels-errors-and-files.md)
