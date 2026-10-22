# Safepoints, allocation, and GC tuning

[Runtime ABI](../ABI.md)

## 5. Safepoints and stop-the-world

- v1 is **stop-the-world**: no mutator observes the heap mid-collection.
- A **safepoint** is a program point where the stack maps are valid and the
  mutator may yield to the collector. Codegen inserts safepoint polls **at loop
  back-edges, and nowhere else**, so collection cannot be starved.
- The collector never moves objects (non-moving mark-sweep), so references are
  stable across a collection and no pointer fix-up is required.

**WHERE THE POLLS ACTUALLY ARE, AND WHY THAT SENTENCE WAS CORRECTED.** The bullet
above once read "at least at loop back-edges and function entry/allocation."
The second half never existed. Each backend has **exactly one** poll
emission site — `emitBackEdgeSafepointIfNeeded` (`compiler/arm64call.bit`) and
`xEmitBackEdgeSafepointIfNeeded` (`compiler/x64controlflow.bit`) — and both are
gated on `isBackEdge`. Nothing is emitted at a function entry, and nothing is
emitted at an allocation: `grep -rn 'safepointSymbol()' compiler/` returns those
two sites plus the two checks that pin them, and nothing in `runtime/alloc/**`
calls `gcShouldCollect` at all.

**So the back-edge poll is the ONLY automatic collection trigger in this
runtime.** `gcShouldCollect` is reached from exactly two places, both of them
under the poll: `gcSafepointRoots` (`runtime/gc/gccollect.bit`), and the
under-the-lock re-test in `runtime/stw/stwpoll.bit`, whose own fast path mirrors
the same predicate inline. Measured by ablating the
back-edge poll: `bench/cases/alloc`'s collection count goes 181 → **1**
and its peak RSS 6.2 MB → **745.2 MB**; `allocflat` 66 → 1 and 6.0 → 264.3 MB;
`strings` 10 → 1 and 137.2 → 558.2 MB. Removing the poll does not remove a
latency mechanism, it removes the collector. Anything that proposes to replace
the poll — signal-based preemption is the recurring one — has to supply a
trigger as well as a yield, and the corrected sentence above is what makes that
cost visible.

**THE BACK-EDGE POLL IS A LOAD, A COMPARE AND A BRANCH.** A polling
function fetches ONE address at entry — `bit_rt_port_sched_poll_attention_addr`,
the address of `runtime/sched/pollreq.bit`'s `pollAttention` word — into one slot
of its own frame. Every back edge then emits, on arm64:

```
ldr  x9, [sp, #<pollCacheOffset 0>]
ldar x9, [x9]
cbz  x9, <past the call>
bl   bit_rt_safepoint
```

and the same four steps on x86-64, where the compare cannot fold into the branch
(`mov`, `mov`, `test`, `je`). It replaces an eighteen-instruction inlined ladder
that re-derived `stwPollNeeded`'s whole predicate — ten loads, three of them
`ldar`, seven branches — plus the poll-thinning countdown's four-instruction
sequence that existed only to make evaluating it rarer. Measured on `_spin`, a bare counting loop:
84 emitted instructions to 34, entry prefetch 11 instructions and 3 calls to 2
and 1, frame 0x60 to 0x50 bytes.

**THE WORD HAS A SECOND, RELAXED READER, AND IT IS NOT A POLL.**
`Op.PollAttention` reads the same word through the same cached frame slot —
`ldr`/`ldr` on arm64, `movq`/`movq` on x86-64, no call and no relocation — and
exists so a compiler pass can ask "is anything already asking?" from inside a
loop without a `bl`, whose caller-saved clobber costs an allocated register for
the whole function. It is a **relaxed** read on purpose, where the poll's own
load is `ldar`: nothing acts on its answer. Its only consumer (the strip-mining
pass) uses it to choose how many iterations to run before the next poll, so a
stale answer costs at most one wide strip, and the poll on the outer back edge
then re-reads the word with the acquire that decides whether to act. **Do not
read the acquire below as a property of every read of this word — it is a
property of the READER THAT ACTS**, which is still exactly the two back-edge
emission sites named above.

**The word is a SUMMARY, and it is safe because the slow path is
self-checking.** `stwPollOn` already re-derives every clause and returns without
acting when none holds, so a spurious nonzero costs one wasted call. A missed
nonzero is the only real failure, which is why the publish/consume ordering below
is the load-bearing part rather than the instruction count.

- **Every writer publishes AFTER the state it summarises.** `worldRendezvous`
  (`runtime/gc/gcworldstop.bit`) calls `pollRequest()` after storing the stop
  flag; `sysmonTick` (`runtime/sched/preempt.bit`) after flagging a worker;
  `allocObject` (`runtime/gc/gcalloc.bit`) after an allocation that crosses
  `gcShouldCollect`; `gcConfigure` (`runtime/gc/gc.bit`) after installing the
  collector's configuration.
- **The one consumer clears BEFORE RE-DERIVING, and AFTER the poll's work.**
  `stwSafepoint` does the poll, then `pollConsume()`, then re-sets the word if a
  reason still holds. Both halves of that placement are load-bearing and they
  answer different failures.

  *Clear before the re-derivation*, or a request published between the
  re-derivation's last load and its store is lost: if a writer's state store
  lands before the re-derivation's reads, the re-derivation sees it and re-sets;
  if it lands after them, the writer's own `pollRequest` — which follows its
  state store — lands after the clear. The proof is on `pollConsume`'s
  declaration.

  *Clear after the work*, or the word being GLOBAL while the clear is
  PER-THREAD erases a live request for every other mutator: A consumes on entry,
  parks inside `stwPoll`, and B's next back edge reads 0, never polls, never
  parks, and `worldRendezvous` spins out `stwSpinBound` and abandons the
  collection. Placed after, A is still inside `stwPoll` while the stop is
  pending, so the word stays set for B.
- **The mutator's read is an ACQUIRE, and that is required rather than
  decorative.** It is the acquire half of a message-passing pair. Without it,
  the slow path's own loads of the summarised state may be satisfied before the
  summary read — control dependencies do not order loads on AArch64 — so a
  mutator could observe a request, read the state stale, and clear a live stop.
  x86-64 needs no instruction for it: an ordinary `mov` load is already an
  acquire load under TSO.
- **NO ACQUIRE WAS DOWNGRADED.** The ladder's three (`worldStopWord`, the
  preempt summary, `heapLive`) all still execute with the ordering they had, in
  `stwPollOn` / `preemptRequested` / `heapLiveBytes`, on the slow path where the
  values are consumed. Three per back edge became one; none became a plain load.

**The GC trigger moved to the allocation door, and that is where it belongs.**
`heapLive` and `gcNumObjectsIdx` rise in `allocObject` and nowhere else; a free
only lowers them and a collection only raises the trigger they are compared
against. (A thread with an allocation-cache entry charges both privately and
settles them into the shared words from its own allocation path, or, for the
object count, at the start of a collection, which recomputes the trigger anyway:
#5709, #5821, `runtime/gc/gcalloccache.bit`.) So the allocation door is the only place `gcShouldCollect` can turn from
false to true, and it is the only place that publishes for it. This does NOT make
the allocation door a collection point — collection still happens only at a
safepoint, where the roots are precise. It records the fact so the back edge can
act on it in three instructions instead of re-deriving it in eighteen.

**The latency bound is back to what it was before the poll-thinning countdown
existed: one back edge.** A stop
request is acknowledged at the requesting thread's slowest peer's very next back
edge, not within `N` of it. The countdown, its `stress ? 1 : pollThinN()`
reset and its bounded-latency argument are all deleted, and `pollThinN` with
them.

**STRIP MINING WIDENS THAT BOUND FOR ONE LOOP SHAPE, TO AT MOST 256 INNER
ITERATIONS OF BOUNDED STRAIGHT-LINE WORK.** `stripMine` (`compiler/optstrip.bit`)
wraps a qualifying counted loop in an outer loop and moves the poll to the outer
back edge; the inner back edge emits none. `stripSize()` is therefore a LATENCY
KNOB, not a tuning constant, and raising it raises this bound directly. Four
things make the widened bound sound, and the first two are what bound it at all:

- **At most `stripSize()` = 256 inner iterations pass between two polls**, by
  construction: the inner limit is `min(o + 256, n)`, the inner loop exits at
  `i >= lim`, and the outer back edge polls immediately.
- **One inner iteration is bounded straight-line work.** The predicate refuses
  any loop whose body holds a call, an allocation, a closure, inline assembly, a
  syscall or a nested back edge, so the bound is 256 x (a fixed instruction
  count) rather than 256 x (something unbounded). A block ending in `unreachable`
  is exempt — that is the `panic` arm every bounds check lowers to, and a path
  that does not return cannot delay a poll.
- **THE INNER LOOP CANNOT ALLOCATE, so it cannot overshoot the heap.** That is
  the reason the allocation refusal is in the predicate rather than a note here:
  with no allocation in the body, `heapLive` does not move while a strip runs, so
  the allocation door cannot cross `gcShouldCollect` and have the crossing sit
  unnoticed. The collection schedule is unchanged for a thread's own
  allocations; only a stop requested by ANOTHER thread can be delayed, and only
  by the first bullet.
- **THE STRIP COLLAPSES TO ONE ITERATION WHENEVER ANYTHING IS ALREADY ASKING.**
  The outer loop reads `pollAttention` — the same word the poll reads — once per
  strip, and takes a strip of one when it is non-zero. So the 256-iteration bound
  applies only to a request that ARRIVES mid-strip; a request already pending
  when the strip is chosen is honoured on the very next back edge, exactly as
  before this pass existed. That read is a plain load, not the poll's `ldar`: it
  only chooses a strip size, and a stale answer costs at most one wide strip,
  never a missed stop.

**`BIT_GC=stress` KEEPS ITS EXACT SCHEDULE, by that same read.** Under stress
`gcShouldCollect` is unconditionally true, so the attention word is set at boot
and re-set after every poll: every strip is one iteration, every original back
edge still polls, and every poll still collects. Measured base against branch on
three probes — a 2000-iteration counted loop, a two-deep nest, and a program
whose loops the predicate refuses — collections are **4104 = 4104, 521 = 521 and
634 = 634** on arm64 and **4050 = 4050, 464 = 464, 577/578 = 577/578** on
x86-64, where that last +/-1 is run-to-run jitter present on the base side too
(base over five runs: 578 577 577 577 577). Mutation-proven rather than asserted:
ignoring the attention read and always taking the wide strip drops the
2000-iteration probe from **4104 to 531**, which is the un-thinned-poll shape
this paragraph exists to prevent.

**Thinning the cheap poll was BUILT AND MEASURED before it was deleted, not
argued away.** Three configurations, arm64, 21 interleaved rounds under `boxlock
solo` with the label order rotated per round and a byte-identical copy of the
base binary as the control (noise floor 0.43% mean / 1.41% max):

| configuration | geomean cycles vs `main` |
|---|--:|
| control (base vs itself) | +0.30% |
| cheap poll, every lap | **−1.93%** |
| cheap poll, thinned 1-in-8 | −0.45% |

Cheap-every-lap beats cheap-thinned on 7 of 10 benchmarks, by 7.6pp on
`allocflat` and 4.4pp on `sort`; thinning wins on `matrix` (+2.0pp) and `map`
(+0.9pp) and is a wash on `fib`, which has no back edge at all. The countdown is
four instructions carrying a loop-carried store-to-load dependency through a
frame slot, on the path that skips a three-instruction poll, so it costs more
than it saves — and the thinned variant measured here did NOT yet carry the
stress arm it would need to be landable, so the comparison is generous to it.
Cutting the eighteen-instruction ladder was worth a countdown (measured
−5.95%); cutting a three-instruction one is not.

**`BIT_GC=stress` IS NOT THINNED — now by construction rather than by a special
case.** Under stress `gcShouldCollect` is unconditionally true, so `gcConfigure`
publishes at boot and `stwSafepoint`'s republish keeps the word set for the whole
run: every back edge takes the poll and every poll collects, which is what makes
the stress suite this runtime's precise-rooting oracle ("any root the caller
fails to report is swept on the very next poll", `gcSafepointRoots`). The
poll-thinning countdown needed a four-instruction stress arm on its reset path
to preserve this, and measured what its omission cost — collections under
stress 303 → 128 on a 200-iteration if/else loop, with every behavioural gate
still green. The current load-compare-branch poll has no reset path to
protect: the same probe reads 302 = 302 against `main`.

**The stop-the-world handshake.** "Stop the world" is a real rendezvous, not an
assumption about there being one thread. Any number of OS threads may execute Bit
code concurrently and reach safepoints concurrently.

Every OS thread that runs Bit code is a **mutator**, holding one slot in a fixed,
statically sized registry (no allocation after startup; a slot is claimed by
`bit_rt_gc_thread_enter` and released by `bit_rt_gc_thread_exit`). A slot is in
one of three states:

**THE REGISTRY BLOCK IS `runtime/gc`'s OWN MODULE STATE, AND THERE IS NO WAY TO
SUPPLY ONE.** `runtime/gc/gcworldsync.bit` declares `worldBlock`
and `syscallRegBlock`; `bit_rt_gc_world_ready` tells it boot has finished, and
carries no address. `bit_rt_gc_world_addr` reads the block's address back out and
answers 0 until readiness — which is what every door tests before reading a
thread token, because the x86-64 token is a `%fs:0` load that faults on a thread
whose FS base is not installed yet.

There used to be a `bit_rt_gc_world_bind(addr)` taking the block's address as a
plain integer — the old, unsafe binding API. A bound address is invisible to the
collector — not a root, never traced, never rewritten — and there was no unbind,
so handing it managed memory type-checked, linked and ran until a collection
swept the block, after which every safepoint poll in the process read freed
memory. `_tests_/stress/gcworld` did exactly that: bound a `[]i64` slice, printed
all 29 of its assertions correctly, then took a SIGSEGV at teardown once `main`
returned. Keeping the slice live through `main` does not help; the faulting reads
happen after `main` returns.

The block is module state now, so the lifetime invariant holds by construction
and there is nothing left to check. The door that remains cannot be misused
because it carries no address.

A program that wants a **private** registry passes its own block to the
parameterised doors (`bit_rt_port_stw_poll_on`,
`bit_rt_port_gc_current_mutator_on`), which never touch the process-wide
**registry block** — a rule `_tests_/stress/stwcollect`
follows. The defect this rule fixes was a private caller REPLACING the live
runtime's own address binding, so its own worker registered into the wrong
registry entirely; "never touch" is about that block/binding, not about every
word this file's module state holds. The per-thread poll hint (`mutHintSlot`) IS one
process-wide word shared by both the global and the parameterised doors, and
that is deliberate, not a hole in this rule: it never identifies which registry
to consult (the `world` parameter always does that) and it is re-validated
against THIS call's own registry before being trusted, so a hint left by a poll
against the other registry can only miss and fall back to the exact search,
never answer wrongly.

```
running   executing Bit code; may reach a safepoint at any moment
parked    stopped at a safepoint, its snapshot published for the collector
blocked   inside a call that holds NO live Bit references (see below)
syscall   stopped in the kernel, holding live references; scanned in place (below)
```

**REGISTRATION IS LAZY, BUT "A THREAD IS NEVER INVISIBLE" IS FALSE AS A BLANKET
CLAIM — IT IS FALSIFIED, NOT MERELY UNCONFIRMED.** A thread claims its
slot on its **first touch of the collector by either door** — any allocation, or
its first safepoint poll. Before that first touch the thread holds NO slot:
`rendezvous` does not wait for it, no snapshot exists for it (root classes 2/3,
§4, do not apply), and — if the thread is not itself a scheduler-registered
green task — the conservative task-stack scan below does not apply to it
either. A thread that becomes the **sole holder of a live reference** during
this window — reading it out of shared/module state whose other copy is then
cleared, with no allocation and no loop back-edge crossed since the thread
started — is invisible to every root class this file documents, and a
concurrent collection running on an already-registered mutator elsewhere WILL
sweep it.

This is not hypothetical. A reproducer was built: a raw OS thread (started via
`runtime/thread`'s `threadStart`, the same primitive `runtime/root/<os>/boot.bit`
uses to start the scheduler's own worker) whose first statements read a live
object's sole address out of an otherwise-cleared mailbox and hold it in a local
while another, already-registered mutator forces real collections under
`BIT_GC=stress`. The object was swept and its memory reused every one of 20/20
runs. A mutation-test control — adding one allocation to the thread before the
hand-off, so it registers first — flips the result to "survives" every time,
confirming the window is exactly the pre-registration gap and nothing else.

The window is narrow (a thread must hold a reference nowhere a root class
covers, before its first door-touch, while a collection completes) but it is
real, and it is exactly what `runtime/sched/worker.bit`'s `Worker.run` closes by calling
`gc_hooks.threadEnter()` **eagerly** at OS-thread entry rather than relying on
lazy registration alone. The Bit port dropped that eager call on the
reasoning that lazy registration was sufficient on its own; that reasoning was
wrong — the eager call is being restored at OS-thread entry points, measured for
`abandoned`-count regression on all three targets. Calling
`bit_rt_gc_thread_enter` explicitly at a thread's start is not merely
"preferred", it is what closes this gap; a thread that skips it is exposed for
as long as its first door-touch is delayed.

**The allocation door does NOT register, and
`bit_rt_gc_thread_enter` at OS-thread entry is the only claim a thread gets.**
It used to be the fallback that mattered, and it had to cover *every*
allocation entry point rather than just `bit_rt_gc_alloc` — strings, slice
headers, slice buffers, slice growth, map control blocks, map headers and
select-case buffers all allocate, and a thread can reach any of them long
before its first loop back edge, so a runtime that registered at only some of
them had threads whose live objects were swept underneath them. The
property that fallback maintained is unchanged; what changed is where it is
paid. Re-establishing "this thread is in the registry" once per OBJECT cost 79
instructions and 11-15 cycles per allocation on `bench/cases/alloc`, to
maintain a fact that changes exactly once in a thread's life — a slot is
claimed at entry and released only by `bit_rt_gc_thread_exit` on that same
thread's own exit path.

So the obligation above is now load-bearing with nothing behind it, and the
in-tree thread primitives discharge it themselves rather than asking a caller
to remember: `runtime/root/<os>`'s `workerBody` calls it as its first
statement, and every `runtime/thread/<os>` provider now calls it at the child's
entry, symmetrically with the `bit_rt_gc_thread_exit` it already makes at the
child's exit. A thread this runtime did **not** create must call it itself; it
has no other way into the registry.

**A parked slot counts as stopped only for the stop it acknowledged.** Each stop
carries a monotonically increasing **epoch**, and a mutator records the epoch it
parked *for*. `rendezvous` treats a `parked` slot as stopped only when its
acknowledgement matches the epoch being collected for. Without this, a thread on
its way out of a *previous* stop still reads as `parked`, so the next collector
passes it and begins marking while it resumes and mutates — with its snapshot
already cleared, so nothing is scanned for it. `blocked` slots are passed without
acknowledging, which is exactly what the `blocked` contract below buys, so a
thread leaving `blocked` must instead re-check the stop flag before it runs.

At a safepoint poll each mutator does exactly one of:

1. **A stop is already requested** — publish the snapshot, go `parked`, and wait
   until the stop clears. This is how a thread yields to someone else's
   collection.
2. **No stop is requested and the allocation trigger is not crossed** — return.
   This is the overwhelmingly common path and costs one atomic load.
3. **The trigger is crossed** — try to become the collector: take the
   world lock, request the stop, wait for every *other* `running` mutator to
   reach `parked`, collect, then clear the stop and release. A thread that
   fails to take the lock parks instead of spinning, so it can never hold the
   lock's winner hostage.

**A collection that cannot achieve a full stop is retried, then abandoned —
never forced.** The rendezvous wait is bounded (Power-of-10: every loop is); on
an individual expiry the collector retries it — *without* clearing the stop
request or releasing any parked thread — reusing the same epoch, so an
acknowledgement a prior round already collected stays valid and a round only
has to gather whatever mutator has not yet reached `parked`. Only once
`stwRendezvousRetryBound` (`runtime/stw/stwretry.bit`) rounds have all expired,
or the wall-clock ceiling on the whole retry (`stwRendezvousCeilingNs`, same
file, 250 ms) has passed, whichever comes first, does the collector clear the
stop request, release every parked thread, and return *without* collecting. (Clearing the stop on every individual
expiry used to release the whole parked herd into a race for the collector
lock, whose winner bumped the epoch again and discarded every acknowledgement
the previous round had banked — a self-sustaining livelock under CPU
oversubscription, epoch climbing while `collections` stayed frozen.) The stop is
deliberately NOT released between rounds to spare the unrelated threads: that
is the same herd release, and the ceiling bounds what holding it costs instead.
An abandoned attempt holds the next one off for four times the time it waited
(`stwShouldCollect`, `runtime/stw/stwstats.bit`), so a mutator that never
answers costs at most a fifth of the world's time rather than all of it. The
hold-off ends early once the slot the abandon named is no longer `running` or
has a new owner (`worldStuckResponded`, `runtime/gc/gcworldstuck.bit`, #6464): a
thread that left its unbracketed call and exited, or went into a bracketed
wait, no longer justifies it. Skipping a
collection is always safe — the heap simply grows to the next trigger — so
correctness never depends on the rendezvous succeeding, and no blocking mutator
can deadlock the collector. Abandonments (a full exhaustion of the retry
rounds, not an individual round's expiry) are counted and reported by
`BIT_GC_STATS=1`.

**Roots under the handshake.** The collecting thread walks its own stack
precisely from its own snapshot (§4); every *other* `parked` mutator is walked
precisely from the snapshot it published; parked green tasks are scanned
conservatively from the registry as described below. `blocked` mutators are
neither waited for nor scanned.

**The `blocked` contract, and its one precondition.** `bit_rt_gc_blocking_begin`
/ `_end` bracket a region in which the calling thread **holds no live Bit
references in any of its frames**. The collector then neither waits for that
thread nor scans it. This exists for one shape: a scheduler worker that has no
task on it and is about to sleep on an idle backoff. Without it, an idle sleeping
worker would hold up every collection for the length of its sleep. Calling it
around a region that *does* hold references is a collector bug — the references
are invisible and will be swept.

**The boot thread (its ABI names are confirmed elsewhere, not duplicated here).**
The OS thread that runs `boot` is itself a registered mutator, not exempt from
the rendezvous. Its wait for `main` to finish — an exponential-backoff
`parkSleepNs` loop — must bracket the sleep, and only the sleep, with
`bit_rt_gc_blocking_begin` immediately before it and `bit_rt_gc_blocking_end`
immediately after: the same pair the `blocked` contract above already names, no
separate boot-specific primitive exists or is needed. Across that bracket it
must hold no live Bit reference in any frame, because the collector does not
scan a blocked thread's stack — the precondition holds because `boot` allocates
nothing on the managed heap before `main` starts, so everything live across the
wait is a scalar or a raw pointer into module state, never a heap reference. The
two call sites are `runtime/root/darwin/boot.bit`'s step-7 loop and, on Linux,
`runtime/root/linux/boottail.bit`'s (the same loop, split out of
`runtime/root/linux/boot.bit`).

**The `syscall` contract.** `bit_rt_gc_syscall_begin` / `_end` bracket a
region in which the calling thread blocks in the kernel **while still holding
live Bit references**. It is the state `blocked` cannot express and `running`
cannot afford: the collector neither waits for the thread (like `blocked`) nor
skips it (unlike `blocked`) — it scans the thread where it stands.

`_begin` publishes the two things a conservative scan needs and a `@nosplit`
frame cannot supply precisely, since such code carries no stack map:

- the calling thread's **stack pointer**, which lowers the scan's bound from the
  task's `ctxSp` (where it last *parked*, arbitrarily far above where it now is)
  to where it actually stands;
- its **callee-saved integer registers**, because a live reference the allocator
  parked in one of those is on no stack at all — exactly the defect this
  precondition exists to prevent.

The two overlap deliberately. If an intervening frame clobbered a callee-saved
register, the ABI required it to spill the original above the published `sp`
first, so the stack walk covers what the register snapshot missed.

PRECONDITION: the thread really does block, and runs no Bit code and pushes
nothing below the published `sp` until `_end`. A thread that kept running under
this state would be scanned from a stale bound — the same class of bug as
claiming `blocked` while holding references. `_end` re-checks the stop flag
before running, like `blocking_end`, because a `syscall` slot is passed without
acknowledging.

**Known limitation, narrowed by the `syscall` contract but not closed.** Blocking runtime calls
made *from* Bit code (`bit_rt_print` on a full pipe, `bit_rt_fs_read` on stdin,
`bit_rt_net_resolve_w`'s DNS timeout) mostly do **not** use either contract: their
frames legitimately hold live references, so `blocked` is wrong, and they have
not been converted to `syscall`. Such a thread stays `running`, so a concurrent
collection waits for it and abandons if it exceeds the rendezvous bound. That is
safe but wastes a collection.

`bit_rt_os_run`'s `waitpid` and the bounded variants' poll sleep WERE converted,
and they were the expensive ones: a subprocess wait holds the whole world for the
child's lifetime. Measured before, under `./make test`, at 21 abandoned
rendezvous per completed collection; 0 after. The remaining call sites are the
same refinement applied to the same pattern.

The same limitation covers a thread asleep in `parkSleepNs`, and there the cost
is proportional to the sleep: every concurrent collection waits out whatever is
left of it. The Linux provider therefore drops the calling thread's timer slack,
because the kernel's 50us default rounded a 1us sleep to ~75us and made
that wait two orders of magnitude larger than the sleep actually asked for. That
narrows the tax; it does not remove it, and a caller that genuinely sleeps for
milliseconds still holds up every collection for its whole sleep.

**Live-task registry and parked stacks.** The scheduler keeps every task on an
all-tasks registry (`Scheduler.registerTask`, from `spawn` until the task's
`.done` teardown). At a collection the running task's stack is walked precisely
(§4); every *other* registered task's stack is scanned **conservatively** —
every 8-byte word in `[ctx.sp, stack_top)` that is exactly a live object base
(`Gc.markConservative`) is treated as a root. This is sound because a parked
task's live callee-saved references are all spilled to its own stack by the
runtime call chain that parked it (a channel op → `park` → context switch), so
they lie within that range; the non-moving collector makes a false positive
merely retain garbage, never corrupt. Precise per-frame maps for parked tasks
(instead of the conservative scan) are a later refinement.

**This soundness argument is scoped to a task that has actually parked at least
once.** A task that has been scheduled but never yet switched into and out of —
`ctx.sp` still holds the value set at task creation, not a genuine snapshot of
where its frames currently are — is on the registry but the conservative scan
of `[ctx.sp, stack_top)` covers essentially none of its real stack while it
runs. The Bit port's `runtime/sched/worker.bit` can dispatch straight into an
already-queued task on a fresh OS thread before that thread's own run-loop
back edge is ever reached (the same finding above — stated there for the
OS-thread registry rather than this one — applies identically here): the same
"holds no live Bit references before its first door-touch" gap. The same
eager-registration fix is what closes both.

### 5.1 The adjacency contract: what it guarantees, and what it never did

Several ABI entry points split what is logically a two-result operation into a
pair of calls — `bit_rt_iface_as`/`bit_rt_iface_as_ok` (§2.2),
`bit_rt_chan_recv`/`bit_rt_chan_recv_ok` (§11), and the fallible-call error
slot's set/get pair (§13) — and rely on codegen emitting the pair back to
back, with no safepoint poll and no yield between them. That property is the
**adjacency contract**: the second call always observes exactly the outcome
the first call just produced, because nothing can run on that same task in
between.

**What it guarantees.** Ordering of a call pair *on one task*, against an
intervening park *of that same task*. A safepoint poll is the only place a
task can be preempted (above); if codegen never emits one between the two
calls, that task cannot park between them, so nothing else running on that
task can observe or disturb the intermediate state. This remains true and
useful at any worker count — it is not what the rest of this note corrects.

**What it never guaranteed.** Anything about a *second task, on a second OS
thread, running at the same real time*. Adjacency is a property of one task's
own instruction stream; it says nothing about a different mutator
concurrently reading or writing the same storage. A value read back purely by
adjacency is safe from a **second caller** only when the runtime boots exactly
one worker. **That guarantee ended with multi-worker support.** Once `BIT_WORKERS>1`, a second worker's
identical call pair is not interleaved with the first — it runs simultaneously
on another core — and if both write the same process-wide or module-level
word, one worker's result is whatever the other happened to leave there. This
was read into the adjacency contract by every site that cited it as a safety
argument for a *shared* buffer; adjacency was never that.

**Two fixes** proved the distinction above the hard way: one to the UDP
last-sender slot (a per-worker `udpSenderBuf`/`udpSenderValid`, since deleted
altogether by #7746 in favour of a caller-owned buffer — see §20's UDP
paragraph) — the root cause of a shared-buffer race open six months across
three wrong hypotheses before this was found — and one to `saBuf`/`saBuf2`/`optBuf`/
`lenBuf`/`ipBuf` (`runtime/net/{darwin,linux}/sock.bit`, mutation-tested both
directions), whose pre-fix fingerprint was `gotport == the other socket's
port` — an outright swap. A
comment reading "sound only under the single-worker contract" and a live
cross-worker race were the same code, before and after `BIT_WORKERS>1` was
actually exercised. §22 audits every remaining module-level cell in
`runtime/**` against this distinction by name.

**The replacement shape**, established by those two fixes:

- If the value is naturally scoped to the calling **task** rather than the
  calling worker — as §11's `scrRecvOk` and §13's error slot are, both being
  the ABI's own outcome of a call the task itself just made — use **per-task
  scratch**: a fixed word offset in the task's own scratch block
  (`runtime/sched/scratch.bit`), read via `scratchOf(schedCurrentTask())`.
  This is strictly *stronger* than a per-worker slot, because it survives the
  M:N scheduler migrating the task to a different worker between the two
  calls.
- If the value is scoped to the calling **worker** instead — a buffer built
  once per OS thread rather than per task, as the sockaddr scratch buffers
  are — use **per-worker slots** indexed by `wkId`,
  double-bounded against both `schedMaxWorkers` and the array's own literal
  capacity (`let a: [N]i64` needs a literal `N`), plus one fallback slot for a
  caller with no current task.
- If the span can **park**, decide the slot **after** the park returns, not
  before it starts — the task can resume on a different worker mid-call. A
  value the CALLER needs back after the call is not a slot at all: pass the
  caller's own buffer in (`bit_rt_net_udp_recv_from_w`, #7746).
- Filling a buffer once outside a retry loop that can park is unsound under
  per-worker slots even though it was harmless under one shared buffer — a
  migrated task's next read lands on a different, unfilled slot (the sockaddr
  scratch-buffer fix had to move `netSendTo`'s fill inside its loop for
  exactly this reason).
- **`@nosplit` does NOT mean "cannot park."** `schedPark`
  (`runtime/sched/task.bit`) and `schedSwitch` (`runtime/sched/switch.bit`) are
  themselves `@nosplit`, so E0075 permits calling them from a `@nosplit` body.
  Prove a span cannot park by what it actually calls, never by inferring it
  from the attribute alone.

**A closed gap.** §2.2's `bit_rt_iface_as_ok` flag used to be the process-wide
shape this note describes as unsound at `BIT_WORKERS>1`. It was converted to
per-task scratch (`scrIfaceOk`, `runtime/sched/scratch.bit`) alongside its
§11/§13 siblings; `rtIfaceAs`/`rtIfaceAsOk` (`runtime/root/iface.bit`) now read
and write that slot, and the module-level `ifaceOk` global is gone from
`runtime/root/root.bit`. The adjacency contract now holds for this flag the
same way it does for the rest of §5.1.

---

## 6. Allocation and collection entry points

v1 exposes the runtime API in Bit (`runtime/gc/gc.bit`); the runtime-init/codegen
path wires the process-wide collector instance and any C-callable export
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

Codegen never calls the API above directly — it calls the two exported C
symbols `runtime/root` wires to it:

```
bit_rt_gc_alloc(info: *const TypeInfo) -> *u8   // Gc.alloc, fatal (not null) on OOM
bit_rt_safepoint()                    -> void   // poll + §5 stop-the-world handshake
```

`bit_rt_safepoint` takes no arguments and returns nothing **as seen by its
caller**; the on-stack snapshot of §4 is built and passed on entirely inside the
shim, so codegen is unaffected by it. The shim reserves ~300 bytes below the
caller's stack pointer, which is why a function containing a safepoint may not
rely on the x86-64 red zone (it is non-leaf by construction, so it already may
not).

Threads that run Bit code participate in the §5 handshake through four more
exports, none of which codegen emits — they are called by whatever creates the
thread (`runtime/sched`'s worker pool, `runtime/sched/`'s Bit port, or user
code that starts a raw OS thread via `runtime/thread`):

```
bit_rt_gc_thread_enter()   -> void   // claim a mutator slot for this OS thread
bit_rt_gc_thread_exit()    -> void   // release it; the platform does this at thread exit
bit_rt_gc_blocking_begin() -> void   // enter a no-live-references blocking region
bit_rt_gc_blocking_end()   -> void   // leave it
bit_rt_gc_syscall_begin()  -> void   // enter a kernel block that DOES hold references
bit_rt_gc_syscall_end()    -> void   // leave it
```

`_enter` is idempotent per thread and is also performed lazily by the first
safepoint poll, so a thread can never be invisible to the collector.

**`_exit` IS NO LONGER THE THREAD BODY'S RESPONSIBILITY.** A leaked slot
stays `running` forever, which does not corrupt anything but does make every
later rendezvous time out, i.e. collection stops — and that is silent, so a rule
each new caller had to remember was the wrong place for it (measured: 247 of
`_tests_/stress/gcthreadslinux`'s 292 abandoned collections were blocked on an
exited child's slot). The release now happens without the body's cooperation, by
whichever hook the platform actually offers:

| Platform | Where the slot is released | Why there |
|----------|----------------------------|-----------|
| Linux    | `runtime/thread/linux`'s child exit path calls `_exit` once the body returns | the provider owns the whole `clone(2)` child exit path, and a static binary has no libc hook |
| Darwin   | a pthread TSD destructor, armed when the slot is CLAIMED (`exit_hook`, `runtime/root`) | `pthread_create` owns the child's entry and stack, so there is nothing to wrap — but every pthread runs its destructors, including threads this runtime never started |

Three consequences worth stating. The Linux ordering is deliberate: the slot is
released while the child is still in user space, so a joiner that sees the `done`
word cleared also sees a released slot. Darwin's hook fires during
`_pthread_tsd_cleanup`, the same pass that tears the thread's TLVs down, so it
carries the slot pointer as the key's VALUE — a destructor reading the runtime's
`threadlocal` sees null (measured) and releases nothing. And the Linux provider's
`threadRelease` no longer treats `done` as proof that the child has left its
stack, because a body may clear that word itself; it waits on a flag only the
child's exit path clears, as that path's last memory access.

`_exit` remains exported, and remains what a thread calls to give its slot back
*earlier* than its own death — a worker that finishes its Bit loop and then keeps
running is the case (`runtime/sched`'s pool). Calling it disarms the platform
hook, so the two can never release one slot twice.

All are plain `callconv(.c)` functions with C linkage names — ordinary
external symbols to the linker (§9's export table lists every `bit_rt_*`
symbol together).

---

## 7. GC tuning (environment)

Read once at startup by `configFromEnv`. Knobs tune policy, never correctness.

| Variable            | Default | Valid values                                       | Effect                                             |
|---------------------|---------|----------------------------------------------------|----------------------------------------------------|
| `BIT_GC`            | on      | `on`, `1`, `off`, `0`, `stress`                    | `off`/`0` disables collection; `stress` collects at every safepoint |
| `BIT_GC_MIN_KB`     | 4096    | integer 0 to 1073741824                            | Min live KiB before the first/next collection      |
| `BIT_GC_GROWTH_PCT` | 200     | integer 101 to 1000000 (`> 100`)                   | Heap growth percent between collections            |
| `BIT_GC_MARKSTACK`  | 65536   | integer 1 to 16777216                              | Mark worklist capacity in entries                  |
| `BIT_GC_STATS`      | off     | `1`, `on`, `0`, `off`                              | `1`/`on` prints one summary line to stderr at exit |
| `BIT_GC_ALLOCCACHE` | off     | `1`, `on`, `0`, `off`                              | `1`/`on` arms the per-OS-thread slot cache at boot instead of on first lock contention |
| `BIT_WORKERS`       | 1       | integer 1 to 32                                    | Boot worker thread count (§9 step 2)               |
| `BIT_VDSO`          | on      | `1`, `on`, `0`, `off`                              | `0`/`off` keeps the Linux clock on the raw syscall |
| `BIT_HASH_SEED`     | drawn   | integer 0 to 1099511627776                         | Fixes the map hash seed, to reproduce a run whose behaviour followed map slot order |
| `BIT_STUCK_MS`      | 1000    | integer 0 to 86400000                              | Budget for the monitor's "worker held a task outside any bracket" warning (§8.5); `0` turns it off |

**A set value outside its valid values is fatal, never clamped and never
ignored** (#6060). At startup, before the first allocation-bearing boot step,
the runtime writes one line to stderr and exits with status 64 (`EX_USAGE`):

```text
bit: invalid BIT_GC_GROWTH_PCT="100", valid: an integer from 101 to 1000000
```

An empty value (`BIT_GC_GROWTH_PCT=`) reads as unset. The growth percent must be
strictly above 100: at exactly 100 the next collection trigger equals the live
size, so the heap is never allowed to grow and every allocation would collect
(a 1.2 MB `pkg/yaml` parse ran 3.3T instructions at `100` against 2.2G at the
default). Validation lives in `gcEnvCheckAll` (`runtime/root/rootconfig.bit`),
reached from the first environment read of every platform's `boot`.

`BIT_HASH_SEED` is not `configFromEnv`'s either (#7379). Unset, every platform's
`boot` draws the map hash seed from the OS CSPRNG (§21's source) before
`bit_main`, so map slot order, and with it `for k in m` order, differs between
processes and a peer cannot precompute colliding keys. A failed draw with the
variable unset is fatal: `bit: cannot seed the map hash: the OS CSPRNG failed`,
status 64. `0` is the fixed seed every process used before #7379.

`BIT_GC_ALLOCCACHE` is the one row that is NOT `configFromEnv`'s: it names this
port's own allocator (`runtime/gc/gcheap.bit`), it selects which of two paths a
run takes rather than any policy, and `BIT_GC=stress` arms the same cache on its
own — so every stress run already exercises it and the variable exists to reach
the default policy too.

POSIX only in v1; Windows keeps the compiled defaults until the runtime adds
`GetEnvironmentVariableW`.

**`bit` itself is a Bit program**, so every row above also configures `bit`'s
own process, not only the program it is building or running. `bit
build`/`check` compile in-process and simply run slower under `BIT_GC=stress`
(the compiler's own heap, not the input program, pays the per-safepoint
collection) — no exec follows, so a slow compile is the whole story.

`bit run` and `bit test` both compile in-process and then exec a built binary
as a separate child that inherits the environment fresh — `run` the program
it just built, `test` a synthetic `BIT_TEST_INDEX`-dispatch binary
(`compiler/testgen.bit`'s `injectTestMain`) — so under `BIT_GC=stress` neither
would ever reach that exec: the compile alone does not finish in useful time
(measured: a six-line input still compiling after 60s, zero collections
even logged). Both therefore **refuse** `BIT_GC=stress` outright
(`compiler/buildrun.bit`'s `refuseRunUnderStressGc`/`refuseTestUnderStressGc`,
the latter called from `compiler/testrun.bit`'s `testCmd`) rather than
appearing to hang.

| Subcommand   | In-process compile? | Under `BIT_GC=stress` | Supported route to stress the subject |
|--------------|----------------------|------------------------|----------------------------------------|
| `bit build`/`check` | yes, no exec after | slow compile, honestly reported (`warnCompilerUnderStressGc`) | run the output binary directly under `BIT_GC=stress` |
| `bit run`    | yes, execs the built binary | **refuses immediately** | `bit build` the source, then run the output binary directly under `BIT_GC=stress` |
| `bit test`   | yes, execs a synthetic test binary per `test_*` | **refuses immediately** | no build-only step is exposed for the synthetic test binary; move the logic into a normal `fn main()`, `bit build` it, and run that directly under `BIT_GC=stress` |

---


[Previous: Root scanning and stack maps](stack-roots.md) | [Next: Collector behavior and diagnostics](collector.md)
