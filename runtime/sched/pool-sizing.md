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
