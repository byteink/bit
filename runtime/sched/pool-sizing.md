# Worker pool sizing: decision

Filed under epic #1911 (parent #1899). This is the decision record; it does not
flip the default. The flip is #2592 (worker start after boot) / #2593 (grow-on-demand
policy) / #2594 (Linux boot wiring) / #2595 (Darwin boot wiring).

## Chosen design: grow on demand (option 3)

Boot at 1 worker. Start additional workers only after the run queue has stayed
non-empty, up to the platform cap. A program that never has parallel work never
pays for a pool it doesn't use, and — critically — this needs no cooperation
between processes: it reacts to the work this process actually has in front of
it, not to a snapshot of the machine that may be shared with an unknown number
of siblings.

### Why the other two are rejected

**Option 1, inherited budget (MAKEFLAGS'-jobserver shape).** Rejected because it
only works when every process on the machine is a cooperating Bit process. A
`bit` program invoked from a shell, from `make`, from CI, or from any other
non-Bit parent has no budget to inherit and falls back to some other rule
anyway, so the mechanism doesn't remove the need for a real default — it only
covers the one case where a Bit parent fans out to Bit children. The exact
failure this project already hit (12 concurrent `bit` invocations from
`_tests_/bit/docs.bit`) is not a Bit-parent-fans-out-to-Bit-children scenario in
the general case; nothing forces every caller of the compiler to be Bit itself.

**Option 2, boot-time read of run-queue length or core count.** Rejected because
a boot-time snapshot is stale by the time the pool matters, and because it is
the design already tried and measured to fail: `rootEnvWorkers(parkCpuCount())`
was implemented and flipped in, and it broke `./make test` on nested
parallelism — see "measured facts" below. A single point-in-time read at boot
cannot see the other 11 sibling processes that start moments later, so sizing
against "cores available right now" is systematically wrong for exactly the
workload this repo runs on every push.

## Measured facts (recorded verbatim, not re-derived)

- `parkCpuCount()` reads `sched_getaffinity`, so a container cpuset is already
  respected.
- #1900 measured 18 idle workers burning 84x the CPU of one worker.
- #1902 fixed that with per-worker futex park words, and the idle repro is now
  flat at 0.04s for 1..18 workers.
- A `parkCpuCount()` default still failed `./make test` because
  `_tests_/bit/docs.bit` runs 12 `bit` processes at once, giving 204 parked
  worker threads on 18 cores and blowing the 300000ms batch deadline.
- A sample during that failing run showed every one of the 204 threads at
  0:00.00 CPU, so the cause is oversubscription, not a spin.

## The rule

The default pool size is 1, and it changes when the run queue has stayed
non-empty, growing the pool up to the platform's core count.

## #5622: `parkCpuCount()` is wired in, and it is not Option 2

The "measured facts" above record a `parkCpuCount()` default failing
`./make test`, and Option 2 above was rejected for exactly that reason. This
section exists because `rootWorkersCeiling` (`../root/rootconfig.bit`) now
calls `parkCpuCount()` anyway, and the two would read as a contradiction
without the distinction that makes it safe:

- **What failed (Option 2):** `rootEnvWorkers(parkCpuCount())` set the BOOT
  worker count to the core count. Twelve concurrent `bit` processes each
  booted ~18 workers before any of them had a task queued, giving 204 parked
  threads on 18 cores.
- **What #5622 does instead:** the boot count is still 1 (`nworkers` in
  `boot`'s step 4 is untouched). `parkCpuCount()` is read only as the input to
  `rootWorkersCeiling`'s non-explicit branch, which becomes the ceiling
  `schedMaybeGrow` (`../sched/grow.bit`) checks before starting worker N+1.
  Growth is already gated on the run queue staying non-empty across
  `growStreakThreshold` calls (the rule above); this only lowers the ceiling
  that gate grows toward from the fixed `schedMaxWorkers` (32) to the
  process's actual usable-core count. A process that never fills its run
  queue never grows past 1 worker regardless of what the ceiling is, so
  twelve idle-ish compilers stay near twelve threads rather than 204 — the
  boot-time snapshot problem Option 2 had does not apply, because nothing is
  sized against it at boot.

`parkCpuCount()` returning 0 on a failed query passes straight through:
`growCeiling(0)` already treats 0 as "no ceiling" and falls back to
`schedMaxWorkers`, so a failed read reproduces the pre-#5622 default rather
than wrongly pinning growth at 0.
