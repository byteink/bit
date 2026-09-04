# Request-scoped context propagation: decision

**Status:** decided (#3968). Task-local storage in the runtime (candidate B),
copy-on-spawn. No public API lands from this decision — it is scoped to the
`spawn` runtime contract that any future `Context` type must be built on.
Cancellation/deadlines are explicitly out of scope (see below for whether B can
carry them later).

## The gap

Bit has no way to carry a value that belongs to *this request* through the code
the request runs — distributed tracing (#3969), request-scoped logging,
per-request deadlines, and an authenticated identity all need this and none of
them exist today. `stdlib/http/server.bit` already spawns one green task per
accepted connection to read the request (`Server`'s own comment), so a real
server handling concurrent connections is exactly the case this has to work
under: many tasks live at once, each must see only its own request's data.

## The three candidates

### A. An explicit parameter (Go's `context.Context`)

Every participating function takes a context value and passes it on to
whatever it calls.

- **Signature cost.** `db.query(...)` becomes `db.query(ctx, ...)`, and that
  is not a one-time cost — every stdlib entry point that can be called from
  request-handling code needs it, permanently, including code that has nothing
  to do with tracing or deadlines and is forced to thread a parameter it never
  reads itself, purely to pass it further down.
- **Spawn.** Trivial and safe by construction: `ctx` is just a value, and
  whatever gets passed to `spawn worker(ctx, ...)` is exactly what the child
  gets. No runtime support of any kind — ordinary parameter-passing semantics
  already give the right answer, including the isolation property (each
  spawned task gets its own copy of the reference/handle, nothing is shared
  by accident).
- **Cost when forgotten.** Loud, at compile time. If a function two calls deep
  needs `ctx` and its caller's signature does not have one to pass, that is a
  type error, not a silent gap. This is A's one real strength.
- **Compiler/runtime support needed.** None — it is pure library/language
  feature, buildable today with existing struct-and-parameter syntax.

This is also the single most criticised part of Go's standard library API,
specifically because of the first bullet, and Bit would be adopting the design
after two decades of that criticism rather than before it.

### B. Task-local storage in the runtime, copy-on-spawn

A slot owned by the scheduler, one per task, read and written through
`Context.get()`/`Context.set()`-shaped calls that take no caller-supplied
value; `spawn` copies the parent task's slot into the new child's slot at the
moment of spawn.

- **Signature cost.** Zero. `db.query(...)` stays exactly as written; nothing
  in stdlib changes.
- **Spawn.** This is the hard case, and it was built and run, not reasoned
  about — see "The prototype" below. Copy-on-spawn was implemented as a
  bounded, per-task table (not a single shared word), and proven both to
  propagate correctly and to isolate correctly across 16 concurrently running
  tasks under `BIT_GC=stress`.
- **Cost when forgotten.** Implicit and silent at the read site. Code that
  forgets to call `Context.get()` where it should does not fail — it just
  never attaches the trace id/identity/whatever, and nothing reports that.
  This is the real, permanent cost of B, and it is the reason implicit context
  propagation is controversial in every language that has it (Node's
  `AsyncLocalStorage`, in particular, has a long history of context loss bugs
  across `.then()`/`setTimeout()`/event emitters — each of those is a
  *different* continuation-creating API that async_hooks has to instrument
  separately). **Bit does not have that problem's full shape**: `spawn` is
  currently the *only* task-creation primitive in the language — the compiler
  lowers the `spawn` keyword through exactly one path
  (`compiler/lowerfunc.bit`/`compiler/irrtfns.bit` → `bit_rt_spawn`) and there
  is no separate timer-callback, promise-then, or event-emitter continuation
  that runs arbitrary user code outside a task. Blocking on a channel, a
  mutex, or a `WaitGroup` parks and resumes the *same* task (same task
  address), so it needs no special handling — the slot survives a park/resume
  automatically because the key never changes. So B's implicit-propagation
  blind spot in Bit today is narrower than in a callback-heavy runtime: the
  one place it can be lost is a task genuinely not reached through `spawn` at
  all (a raw OS thread started outside the scheduler, which is not something
  ordinary Bit code can do).
- **Compiler/runtime support needed.** Real, but scoped to the scheduler:
  `bit_rt_spawn` (`runtime/root/<os>/boot.bit`) is the one place that must
  copy the slot, once per platform. No compiler codegen change, no stdlib
  signature change.

### C. B with an explicit override

Same as B, plus an opt-in explicit form (e.g. `spawnWith(ctx, fn, ...)`) for
the cases where the implicit inheritance is wrong — a worker pool that must
*not* inherit its spawner's identity, for instance.

C is strictly more expressive than B and costs a second API surface to get
there. It is the right shape for a *later* ticket once real call sites show
which specific cases need the override — building it now would be guessing at
an API from a hypothetical need. Recommendation is **B now, C available as a
non-breaking addition later** if a concrete case shows up (adding an explicit
override does not require revisiting the copy-on-spawn contract; it composes).

## The decision: B

**A wins on visibility, B wins on cost, and B's cost is the one Bit can afford
to pay once.** A's signature cost is not a one-time migration expense — it is
a permanent tax on every future stdlib function, applied whether or not the
caller cares about tracing, logging, deadlines, or identity. B's cost is paid
once, in the scheduler, and is exactly as large on day 1000 as it is today.
Given Bit's `spawn`-only concurrency model narrows B's classic failure mode
(the Node.js continuation-loss problem) to a case that does not arise in
ordinary Bit code, B's remaining downside — silent loss at a forgotten read
site — is a real but bounded cost, not an open-ended one.

**C loses to B only in that it is not needed yet**, not on the merits: it is
B's natural superset that we build when a real caller needs it.

**Reject the false alternative of designing nothing.** The four consumers
named in this ticket (#3969 tracing, request-scoped logging, deadlines,
identity) all need this exact primitive; deferring the decision defers all
four.

## The prototype

Built and run in a worktree, against a locally patched runtime that is **not
part of this commit** — nothing here ships. Two files were added/edited only
for the duration of the test:

- `runtime/sched/protoctx.bit` (new, throwaway): a bounded, fixed-size,
  open-addressed table keyed by task address — the same shape as
  `runtime/sched/preempt.bit`'s `requested[]`/`startNs[]` arrays (Power-of-10
  bounded probe, no allocation, `@nosplit` throughout). Two accessors,
  `bit_rt_proto_ctx_set`/`bit_rt_proto_ctx_get`, and one copy function,
  `protoCtxCopyOnSpawn(parentTask, childTask)`.
- `runtime/root/darwin/boot.bit`'s `rtSpawn`: one call,
  `protoCtxCopyOnSpawn(schedCurrentTask(), taskAddr)`, inserted after the
  child's task block is initialised but **before** `schedSpawn` publishes it
  to a worker queue — so the copy always runs synchronously on the parent's
  own stack, with no concurrent reader of the child's slot yet. This one call
  site is the entire copy-vs-reference decision: it reads out of the parent's
  slot and writes into a slot keyed by the *child's own* task address, never
  a slot shared between them.

A production implementation would want the slot living directly in the task
control block (`runtime/sched/task.bit`'s `taskWords`-sized block) for O(1)
access instead of a bounded hash probe, which needs growing that block across
three platforms' boot files — real work, deliberately out of scope for a
decision-proving prototype. The sidecar table proves the *semantics*
(copy-on-spawn, isolation, no shared mutable slot) without that surgery.

Test program (`ctxproto.bit`, kept under `$TMPDIR`, never committed): main
sets its context to 100, then spawns `nTasks = 16` tasks. Each child (a)
reads its context *before* writing anything — must equal the parent's 100 —
then (b) overwrites it with an id unique to that task (`1000 + id`), spins for
`spinCount` iterations to give the other 15 tasks real concurrent runtime to
interfere in, and (c) reads back — must still equal its own id, not a
sibling's. After every child finishes, main confirms its own slot is still
100 — a child's write must not leak backward either.

**Results, correct implementation** (`spinCount = 300000`, `BIT_GC=stress`
variant at `spinCount = 20000` to keep the run tractable):

```
8 plain runs:            PROTO OK n=16 inherited+isolated+parent-untouched   (all 8)
3 runs, BIT_GC=stress:    PROTO OK n=16 inherited+isolated+parent-untouched   (all 3)
```

**Mutation test — the check proven load-bearing, not just green.** `protoCtxSlot`
was mutated to `return 0` unconditionally: one shared slot for every task,
exactly the "shared mutable slot across tasks" the ticket names as the failure
this decision must avoid. Same test binary, rebuilt against the mutant
runtime, 3 runs:

```
child 0 FAIL inherited=100  want=100 after=1009 want=1000
child 1 FAIL inherited=1000 want=100 after=1009 want=1001
...
child 15 FAIL inherited=1014 want=100 after=1015 want=1015
PROTO FAIL allOk=0 parentAfter=1015 want=100
```

3 of 3 runs failed, 15 of 16 children wrong each time (task 0 happens to read
its own inherited value correctly because it is the first writer, everything
after it sees whichever task last wrote — the "last spawn wins" signature).
**`parentAfter=1015`** is the concrete version of the ticket's warning:
task 15's write reached the *parent's* value too — one task's data attached
itself to every other task's work, including the one that started the whole
request.

## Can B carry a cancellation signal later?

**Yes, and the reason is the same one that makes B cheap now**: because the
value B carries is opaque to the runtime (a plain word — in a real
implementation, a pointer to a Bit value), nothing about copy-on-spawn depends
on what is stored. A future `Context` value can carry a cancellation flag or a
deadline the same way Go's `context.Context` bundles `Done()`/`Deadline()`
into the same value it uses for request-scoped data — the copy-on-spawn
mechanism this ticket tested does not need to change at all; only the
*content* of the slot grows a field. What is genuinely new work for
cancellation (not decided here, per the ticket's scope) is the reverse
direction: a parent needs a way to reach into a *live* child's slot to signal
cancellation, which the copy-on-spawn design does not provide — copying is
one-shot, parent-to-child, at spawn time. That reachability (or a
subscribe/notify channel instead of a polled flag) is #3968's explicit
out-of-scope item and is real design work for whichever ticket takes it on.
