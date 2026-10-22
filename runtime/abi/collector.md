# Collector behavior and diagnostics

[Runtime ABI](../ABI.md)

## 8. Collector algorithm (informative)

Not ABI — may change without touching §1–§7. v1 is a precise, non-moving,
stop-the-world **mark-and-sweep**: objects are threaded on an all-objects list;
mark traces from roots via the pointer maps using a fixed-capacity worklist
(worklist overflow falls back to bounded rescan passes, so mark-phase memory is
constant); sweep frees unmarked objects back to the size-class heap. Upgrade path
is incremental/generational collection when pause times matter.

### 8.1 What goes back to the OS, and what does not (informative)

Three things are returned, and all three are live paths today:

- a **large block** (over `allocMaxSmall`, 16 KiB) is mapped individually, its
  length rounded up to one of four classes per doubling up to 512 pages. When
  freed it is kept for the next request of its class while the large cache
  holds under 16 MiB (#7445), and `munmap`ed otherwise. A cached block goes
  back to the OS at the first collection that finds it still unused, at
  `gcDeinit`, and whenever the OS refuses a fresh mapping;
- an **entirely-free owned span** is unlinked by `heapReclaimSpansLocked` and
  then either parked in the 64-slot cross-class span cache, or pushed onto the
  span free list, which resets it with `MAP_FIXED` at the same address — the OS
  drops the physical pages, the address stays valid;
- **every chunk the span reserve mapped** goes back at `gcDeinit`.

Four things are not, in decreasing order of measured cost:

1. **A span with even one live object.** Reclamation is whole-span and the
   collector is non-moving, so nothing can compact the survivors together.
2. **A span carved from memory the caller bound** (`boot`'s own arena, a stress
   fixture's `[]i64`). It is `spanOwned == 0` and may never be unmapped —
   unmapping it would punch a hole in memory the caller owns.
3. **Entirely-free owned spans below the reclaim trigger.** A pass is asked for
   only when at least half a class's spans are entirely free, because each
   `heapReclaimSpansLocked` pass walks the class's spans and has to pay for
   itself. A class therefore settles at holding up to half its spans
   free.
4. **Reserve address space.** `reserveGrow`'s bump never rewinds; the chunk list
   is walked only by `reserveRelease` (`gcDeinit`) and `reserveReclaimChunks`
   (the index reserve). Address space, not resident pages: a span parked on the
   free list is decommitted.

**Measured on `2e7aabff`, `bench/cases` at their own end state, span occupancy
read from the live heap through `bit_rt_gc_addr`.** (1) is small in practice —
spans at most 25% live are 3 of 2052 on `json` (0.15%), 5 of 164 on `sort`, 12
of 78 on `strings`. (3) is the larger of the two: 25.4 MB held in entirely-free
owned spans on `json` against a 302 MB peak, 2.2 MB on `sort`, 1.0 MB on
`strings`.

**Neither is a peak-RSS cost, and that is why the trigger has not been
tightened.** Replacing the half-the-spans test with the exact amortisation
question it approximates (are the doomed spans' slots at least half of the free
list, which is `spanSpans * allocSpanSlots(idx) - spanLive`) removes essentially
all of (3) — `json` 25.4 MB → 1.3 MB of retained free spans, 2052 → 1867 spans,
with `heapLive` byte-identical. Peak RSS moves 0.27% on `json` and 3.15% on
`sort`, and not at all on the other eight cases, because those spans empty
*after* the high-water mark. Cycles move the wrong way over the noise floor:
`strings` +7.8%, `json` +3.8%, `alloc` +1.9% (medians of 9, interleaved with a
second independent baseline series whose own spread was under 2%). The trade was
therefore rejected, not overlooked.

### 8.2 `BIT_GC_STATS` byte fields

Before these byte fields existed, every heap figure `BIT_GC_STATS=1` printed was a COUNT — of
objects (`collections=`/`swept=`/`live=`) or of reserve chunks
(`chunks=`/`chunkbytes=`/`idxchunks=`/`idxbytes=`) — so no memory claim could
be attributed without ablating the collector (`BIT_GC=off` for a total, a
tuned min/growth pair for a live high-water bound; both used independently,
more than once, before this landed). Four byte fields close that gap:

| field | source | rounding |
|---|---|---|
| `livebytes=` | `heapLiveBytes` | EXACT — the caller's `gcHeaderSize + bodySize` request |
| `mappedbytes=` | `heapMappedBytes` | CLASS-ROUNDED — spans plus large (page-rounded) allocations |
| `peakbytes=` | new: `heapPeakMappedBytes` | CLASS-ROUNDED — high-water mark of `mappedbytes=` |
| `allocbytes=` | new: `heapAllocBytes` | CLASS-ROUNDED — cumulative, never decremented |

**`livebytes=` is the odd one out on purpose.** It is the EXACT byte count a
caller asked for, not what class a 56-byte request actually lands in (64) —
that is what makes it return to exactly 0 when every allocation is freed, the
leak metric the stress tests already rely on. The other three are
CLASS-ROUNDED: `mappedbytes=`/`peakbytes=` can only ever be class/page-rounded
(that is what the allocator actually took from the OS), and `allocbytes=`
matches them deliberately, so `allocbytes=` divided by (`swept=` + `live=`)
answers "average bytes ACTUALLY SPENT per object" rather than a number no
external measurement (RSS, `/usr/bin/time -l`) could ever be checked against.
Requested-vs-rounded is not a rounding-error footnote here — it is the entire
subject of the base-offset discussion in §1.2 above, which this field now
lets a caller see directly instead of inferring from an RSS delta across two
size classes.

**`peakbytes=` exists because the value at exit is not the peak.** For a
program whose heap fell after its high point — spans reclaimed, `mappedbytes=`
dropped — `mappedbytes=` at exit understates the memory the run actually
needed. §8.1's "a scavenger cannot lower a peak" is the same fact read from
the other direction: nothing here can lower `peakbytes=` once set, by
construction (`heapNotePeakLocked`, `runtime/alloc/alloc.bit`).

**Both new counters are PLAIN loads/stores, not atomic**, unlike
`heapLiveBytes`/`heapMappedBytes` — deliberately, and the deviation is
measured rather than a shortcut. `heapLiveBytes`/`heapMappedBytes` are read
concurrently, off the heap lock, by the collector's own growth-trigger check
on every allocation, so a torn read there is a real hazard. `heapPeakMappedBytes`/
`heapAllocBytes` have exactly one caller anywhere in the runtime — `statsReport`,
called only after `main` has returned and the worker is reaped — so no
concurrent reader or writer can ever observe either word. Making them atomic
cost `bench/cases/alloc` (10M individual small allocations) +12.6% cycles with
`BIT_GC_STATS` UNSET; dropping the atomics brought that to +5.5%, the residue
being an unavoidable (not inlining-eligible, see `runtime/alloc/alloc.bit`'s
`heapTakeSmallLocked`) call to `allocClassSize`. `bench/cases/allocflat`, whose
elements are packed inline rather than individually heap-allocated, costs 0%
either way — the fixed per-small-allocation cost is real but narrow.

Both live in the HEAP BLOCK (`heapWords` 41 → 43), never the GC state block
(`gcWords`, unchanged at 39) — the GC state block is boot-pinned exactly full,
and a new counter belongs beside `heapLiveWord`/`heapMappedWord`, which the
same block already carries for the same reason.

### 8.3 `BIT_GC_STATS` pause-time fields

Before these fields existed, `BIT_GC_STATS=1` could show a wall-clock
regression with no collector-side counter that moved — #5828 found
`bench/cases/allocpar` running ~4x Go's wall time on identical cycle counts,
because seven of eight `BIT_WORKERS` sit idle through every collection while
the world is stopped, and nothing on the line said how long that was. Seven
fields close that gap, appended AFTER `allocbytes=` (§8.2) so `bench/run.sh`
and `bench/objprobe`, which parse `swept=`/`live=` by name, are unaffected:

```
pauses=<n> pausens=<n> pausemaxns=<n> rdvns=<n> rootsns=<n> drainns=<n> sweepns=<n>
```

| field | meaning |
|---|---|
| `pauses=` | rounds `stwPollOn` (`runtime/stw/stwpoll.bit`) stopped the world for — `gcShouldCollect` held under the world lock, success or ABANDON alike |
| `pausens=` | summed wall nanoseconds the world was stopped, across every pause `pauses=` counts |
| `pausemaxns=` | the single longest pause, in nanoseconds |
| `rdvns=` | summed nanoseconds in the rendezvous (`stwRetryRendezvous`, `runtime/stw/stwretry.bit`), success and ABANDON alike |
| `rootsns=` | summed nanoseconds scanning roots — `stwCollect`'s own span minus `drainns=`/`sweepns=` for the same collection |
| `drainns=` | summed nanoseconds in `drain` + `recoverOverflow` (`runtime/gc/gccollect.bit`'s `gcDrainAndSweep`) |
| `sweepns=` | summed nanoseconds in `sweep` (`gcDrainAndSweep`) |

**`pauses=` is not always `collections=`.** An ABANDONED round (every
`stwRendezvousRetryBound` retry or the wall-clock ceiling expired, `abandoned=` above) stops the world
and restarts it without collecting, so it advances `pauses=`/`pausens=`/
`pausemaxns=`/`rdvns=` but not `rootsns=`/`drainns=`/`sweepns=`, which stay at
that round's 0. This is the rare, contention-bound exception
`stwRetryRendezvous`'s own header describes; `pauses=` equals `collections=`
on every ordinary run.

**One clock, three targets, reused rather than reinvented.** The nanosecond
read is `runtime/gc/gcstopwait.bit`'s `bit_rt_port_gc_ticks`, whose three
provider bodies (`runtime/gc/{darwin,linux,windows}/gcstopwait.bit`) each
forward to the SAME monotonic clock `runtime/park`'s `bit_rt_port_park_mono_ns`
already provides for that OS — `mach_absolute_time` scaled by the cached
`mach_timebase_info` ratio on Darwin, `clock_gettime(CLOCK_MONOTONIC)` through
a raw `syscall` on Linux, `QueryPerformanceCounter`/`QueryPerformanceFrequency`
on Windows — rather than a second cache of the same ratio. Called only by the
thread holding the world lock (`worldLockTry`, `runtime/gc/gcworld.bit`), so
there is exactly one caller at a time and the Linux/Windows scratch words each
provider keeps for the underlying clock call are plain module state, not
`@threadlocal` — unlike `runtime/gc/linux/gcstopwait.bit`'s existing
`gcStopWaitTs`, which every parked mutator writes at once.

**Once per COLLECTION, never per allocation.** The four timestamps a pause
takes (`runtime/stw/stwpoll.bit`'s `stwPollOn`/`stwFinishPause`,
`runtime/gc/gccollect.bit`'s `gcDrainAndSweep`) are read only inside the
already-stopped-world section a collection pays for regardless; no allocation
or safepoint poll reads the clock. Measured (`BIT_LIBBITRT_TREE=1`, a null
copy, 15 interleaved runs): `allocpar`/`alloc`/`json` cycles with
`BIT_GC_STATS` UNSET are indistinguishable from the same runs before this
change, inside the null copy's own run-to-run spread.

The seven accumulators are plain words in `runtime/stw`'s own module state
(`runtime/stw/stwstats.bit`), not a new `gcWords` slot: that block is
boot-pinned exactly full (§8.2), and this change does not grow it or
`heapWords`. Written only by the thread holding the world lock, so no atomic
is needed — the same argument `gcAddr`/`stwAbandoned` (`runtime/stw/stw.bit`)
already rest on.

### 8.4 The helper gang (#5837)

§8.3 found that seven of eight `BIT_WORKERS` sit idle through every
`allocpar` collection while the world is stopped. This ticket opens the
mechanism a later one spends: a parked mutator can now JOIN the stopped
collection instead of only waiting it out, and leaves again before
`worldRestart`. No work moves through a join yet — #5838 (parallel sweep) and
#5839 (parallel mark) are what give a helper something to do — so this only
adds one field:

```
helpers=<n>
```

| field | meaning |
|---|---|
| `helpers=` | total joins into the helper gang across the whole run (`stwGangJoins`, `runtime/stw/stwstats.bit`, forwarding `gcGangHelp`'s counter, `runtime/gc/gccollect.bit`) |

**Two new World words, and that is the whole layout change.**
`worldGangWord` (0 = closed, otherwise the stop EPOCH the gang is open for)
and `worldGangIn` (helpers currently inside a join) sit immediately after
`worldWaiters` (`runtime/gc/gcworld.bit`), growing `worldWords` from 1801 to
1803. No existing World word moves. `runtime/gc/gcworldsync.bit`'s
`worldBlock` and `runtime/root/root.bit`'s boot-time width assertion both
carry the new 1803, the same pair that already asserted 1801 (see §8.2's
"boot-pinned exactly full" for why the GC state block, `gcState`, could never
have taken this instead — the World block is the caller-owned one, and it is
runtime-internal, appearing nowhere else in this document).

**The protocol, in the order it runs.** Once `stwRetryRendezvous`
(`runtime/stw/stwretry.bit`) wins a full stop, the coordinator calls
`worldGangOpen`: publish the collector block `g` a helper will read, store the
stop's own epoch into `worldGangWord`, store **2** — not 1 — into
`worldStopWord`, and wake every sleeper. Storing a value distinct from the
plain stop's 1 is what lets a thread mid-way into its own blocking wait
distinguish "the stop this thread already knows about" from a fresh signal,
closing the same restart-then-restop ambiguity §5's stop-word wait already
names; every reader of `worldStopWord` tests `!= 0`, never `== 1`, so nothing
elsewhere needed to change for the new value to be legal. A parked mutator
tries to join on every turn of its own wait loop (`worldGangTryHelp`,
`runtime/gc/gcworldstop.bit`): if the open epoch matches the one it itself
acknowledged, it increments `worldGangIn`, RE-CHECKS the gang is still open
(undoing the increment and backing off if a close landed in the gap — the
"helper that races the close" case), calls `gcGangHelp(g, slot)`, then decrements
`worldGangIn` unconditionally. Before `worldRestart`, the coordinator calls
`worldGangClose`: store 0 into `worldGangWord` (no new helper can start after
that store is visible) and wait for `worldGangIn` to read 0 — safe to call
even when the gang was never opened, since an unopened gang closes on its very
first check. The wait never gives up and proceeds: every helper region is
bounded work, so a drain the coordinator has watched for 10 s is
`bit_rt_fatal` (`worldDrainOrDie`), because restarting with a helper inside is
heap corruption once helpers sweep (#5838). Only time the coordinator itself
observed counts, each check capped at 50 ms, so a whole-process stop
(SIGSTOP, a debugger, a paused VM) is never charged to the helper.

**The gang kick (#5853).** Each phase that publishes work wakes the gang
through `worldGangKick`, which stores into `worldStopWord` a value it does not
hold: **3**, or **4** when it holds 3. The mark kick and the sweep kick
therefore always differ, so a helper that loaded one and sleeps on it wakes
for the next. Every reader of `worldStopWord` tests `!= 0`.

**The sweep phase (#5838).** Under `heapLock`, the coordinator fills a side
table with every small-class span, publishes it (`gcSwOpen = g`,
`runtime/gc/gcsweeppar.bit`), wakes the gang (`worldGangKick`), and claims spans by `atomicAdd` on one
cursor alongside every helper that joins. A helper sweeps only the span it
claimed and writes only that span and its table entry. The coordinator then
closes the table and drains its claim-loop count the same fatal-or-zero way,
and applies every entry's class and heap accounting serially, in the serial
walk's order, so the heap it leaves is the serial sweep's.

**The mark phase (#5839).** Only when a slot is parked for the open epoch or
an idle worker was woken into the gang (`worldGangHasHelpers`); otherwise the
serial mark runs unchanged. The roots
are still pushed serially. The coordinator cuts them into 256-entry segments
on one global list (`runtime/gc/gcmarkpar.bit`), publishes the phase
(`gcMkOpen = g`), kicks the gang, and marks alongside every helper that joins.
Only the thread whose `atomicOr` on the header size word finds the mark clear
(`hdrTryMark`) queues an object. The joined and idle counts, the global list
and the done flag change only under `gcMkLock`, and termination is decided
there, on every joined member idle with the list empty. The pool holds at most
`gcStackLen` entries. A push with no free segment sets `gcOverflow`, and the
serial `recoverOverflow` answers it after the phase closes. The coordinator
drains the phase's helper count the same fatal-or-zero way before the sweep.

**A helper never returns to mutator code while the world is stopped.** It is
still inside `worldResumeWhenClear`'s own wait loop for the whole of a join;
`gcGangHelp` returning is not a resumption, it is one more turn of that loop.
The coordinator waits for every JOINED helper to LEAVE before it restarts, and
a helper leaves unconditionally on every path through `worldGangTryHelp`
(including the raced-close case, which never called `gcGangHelp` at all), so
the collector stays correct with zero helpers exactly as it did before this
ticket — nothing about `stwCollect`'s own root scan changed.

**Idle workers are recruited (#5842).** Right after opening the gang, at the
top of `stwCollect` (`stwGangRecruit`, `runtime/stw/stwstats.bit`), the
coordinator claims and wakes
up to 7 parked scheduler workers, never more than `scIdleCount`
(`schedWakeIdleGang`, `runtime/sched/sleep.bit`). Each leaves its park through
`gcBlockingEnd` and joins from `worldResumeWhenClear` as a `blocked` slot. A
`blocked` slot needs no epoch ack to join, because the rendezvous counts it
stopped for every epoch. A `syscall` slot never joins. A recruit that leaves
its wait while the gang it joined is still open ends the process
(`worldGangCheckLeft`, "gc: a gang helper left an open stop"). At
`BIT_WORKERS=1` nobody is parked, so nothing is woken.

---

### 8.5 A stuck mutator names itself (#6423)

A thread that stops polling without saying so (a kernel wait or foreign call
with no `bit_rt_gc_blocking_begin`/`_end` around it, §5) leaves its slot
`running`, and every collection attempt waits for it. The wait is bounded by
the wall-clock ceiling in §5, not by a spin count, and the first time it gives
up the process says who, once, on stderr:

```text
[bit-gc] stop-the-world abandoned after 250 ms: slot 3 (thread token 6159986912) is still running (acked epoch 0, stop epoch 1) and never reached a safepoint; bracket kernel and foreign calls with gcBlockingBegin/gcBlockingEnd (ABI.md section 5)
```

| part | meaning |
|---|---|
| `after <n> ms` | how long the stop had been pending when the rendezvous gave up. A lower bound on how long the thread has been out of Bit code: the registry keeps no per-slot clock |
| `slot <n>` | the first registry slot, other than the collector's own, that was not stopped for this epoch |
| `thread token` | `gcThreadToken()` of the OS thread that owns the slot, the value the thread provider uses to find it |
| `is still <state>` | the slot's last published state (`running` when the contract was broken; `parked` with an `acked epoch` older than the `stop epoch` is a thread still on its way out of an earlier stop) |

**The same contract bounds the scheduler, not only the collector (#7836).** A task
that blocks its worker's OS thread in a kernel wait or foreign call with no
bracket leaves the worker's slot `running`, and the monitor thread's retake
(`runtime/sched/retake.bit`, #7128) keys on the slot being `syscall` or `blocked`:
an unbracketed block is indistinguishable from a CPU-bound task that has not
reached a safepoint yet. So at `BIT_WORKERS=1` such a task holds the only worker
and nothing queued behind it, `main` included, runs until the call returns. That
is the contract, not a gap to retake around: Go's `sysmon` hands a P off only from
`_Psyscall` (`retake` / `handoffp` in `runtime/proc.go`), a state its cgo and
syscall paths enter themselves (`cgocall` -> `entersyscall`), so a foreign call
Go does not bracket cannot occur there. Bit's compiler does the same for a user
`extern fn` (#7842, SPEC section 11.7): every call is emitted as
`bit_rt_gc_syscall_begin`, the call, `bit_rt_gc_syscall_end`, so the caller of an
extern writes no bracket. Three things are not bracketed and keep the contract
by hand: an extern declared in a module under `runtime/`, any `bit_rt_*` symbol
wherever it is declared (the primitive brackets itself where it blocks), and a
call to a declaration marked `@nonblocking`. The bracket costs +7.5 to +7.8 ns
per call on aarch64 (macOS and Linux, Apple M5 Max) and +27.6 ns on x86-64
(Core i7-14700KF); SPEC section 11.7 has the table. A callee under the bracket
must not run Bit code. Teardown does not depend on
it: a returned `main` joins the workers under ONE 100 ms deadline (`boot`, step 8)
and the process exits with a worker still blocked.

**The monitor names that worker too (#7841).** On every tick the monitor thread
(`rootRetakeScan`, `runtime/root/retake.bit`; Windows reaches it through
`sysmonRetake`, `runtime/root/windows/bootgrow.bit`) counts, per worker with a
registered slot, the consecutive scans in which the slot reads `running` and a
preempt request is outstanding (`preemptRequested`: set once a task has held the
worker past `preemptBudgetNs`, cleared at the task's next safepoint or exit). When
the count reaches `BIT_STUCK_MS` (default 1000 ms, which is 500 scans at
`sysmonPeriodNs`; `0` disables) it writes one line to stderr:

```text
[bit-rt] worker 0 has run one task for over 1000 ms without reaching a safepoint or a blocking bracket (registry state running); bracket kernel and foreign calls with gcBlockingBegin/gcBlockingEnd (ABI.md section 5; budget BIT_STUCK_MS)
```

One line per episode: the count restarts after a safepoint, a bracket or the
task's exit, so one worker prints at most one line per budget. The figure is the
budget, a lower bound, because the registry keeps no per-slot clock. The
registry cannot tell a blocking foreign call from a loop with no back-edge poll,
so the line says neither. The count is left alone while a stop-the-world is
pending (the collecting thread is `running` and poll-free for the whole
collection; a thread that never answers a stop has the `[bit-gc]` line above). A
task in a bracket reads `syscall` or `blocked` and a task that polls consumes its
request within microseconds, so neither counts; the consecutive-scan requirement
keeps a task that has just left a long bracket, still holding the request it
never consumed, from being caught in the instructions before its first poll.
The cost is on the monitor thread only: a load of the worker's slot word, its
registry state and its request flag per tick, and nothing on spawn, dispatch or
any safepoint. `_tests_/stress/stuckwarn` pins one line for an unbracketed
sleep and none for a polling loop or a bracketed one, at `BIT_WORKERS=1` and 4.

`BIT_GC_STATS=1` adds a field, `stuck=<n>`: how many abandoned
rendezvous named a slot, over the whole run. The line itself is printed once
per process, after the world is restarted (a blocked stderr must never hold the
parked threads), so `stuck=` is the count and the line is the first witness.
`runtime/gc/gcworldstuck.bit` composes both.

The last field is `latewakes=<n>` (#6474): idle parallel-mark members whose
sleep on `gcMkWake` ended by timeout although the termination notify had
completed at least 100 us before that timeout could fire (`gcMkWakeTick`, the
`gcTicks` reading stored when `gcMkNotify(true)` finishes), plus one for a
phase whose termination was decided but whose notify never completed, checked
once every member has left; both over the whole run
(`gcStatLateWakes`, `runtime/gc/gcmarkpar.bit`, forwarded by `stwLateWakes`,
`runtime/stw/stwstats.bit`). A sleeper is meant to be woken by termination, and
each sleep is capped at 1 ms, so a lost wake costs 1 ms and no run time shows
it; this counter is the witness and a correct build reads `latewakes=0`. A
notifier descheduled before it reaches the wake delays the wake without losing
it and is not counted. It is touched only when a sleep times out and once per
mark phase, never per marked object. The line is now
`... sweepns=<n> helpers=<n> stuck=<n> latewakes=<n>`; consumers read fields by
name (`_tests_/bit/stress/verify.bit`'s `statsField`).


[Previous: Safepoints, allocation, and GC tuning](safepoints-and-gc.md) | [Next: Program boot, workers, and task entry](boot-and-spawn.md)
