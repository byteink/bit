# Parallel stress coverage

`tests/bit/stressparallel.bit` (#2538, epic #1253) builds and runs the five
programs in `tests/stress/parallel/*.bit`. Together they prove three things
about the runtime under real concurrency, each independently checked by a
reconciling value (an exact count, a checksum, or an exactly-once tally) — not
by "it did not crash": **no data race** (`mutexcounter`'s final count must be
exactly `STRESS_WORKERS*50000`; a lost update from a race moves it), **no
lost or duplicated channel message** (`chanhammer`'s close races every
in-flight receiver on a bounded channel; `pipeline`'s consumer counts each
of `totalItems` originals exactly once through a two-stage, backpressured
pipeline), and **no heap corruption under parallel mutation**
(`gcalloc`'s workers each retain a ring of records reachable only through
that ring and their own stack, across concurrent `BIT_GC=stress`
collections, and verify each survives intact).

Reproduce the whole table with:

```sh
./make test-stress-parallel-programs
```

This is registered in `coreSteps()`, not `gateSteps()`
(`tools/build/defs.bit:104`, `tools/build/gates.bit:443`), so it is
deliberately **not** part of `./make test` — same shape as
`test-stress`/`test-differentials`.

Every build and every run is bounded to a **300-second base** deadline
(`perRunTimeoutMs`, `tests/bit/stressparallel.bit:99`). Since #3587, that base
is scaled by currently observed host load (up to `loadScaleCap=8`,
`tests/bit/stressparallel.bit:103`) and capped at `clampTimeoutMs=6000000`
(`tests/bit/stressparallel.bit:109`, matching the runtime's own
`osBoundedMaxMs` clamp in `runtime/root/{darwin,linux}/os.bit:450/458`) —
a fixed 300s wall was found to false-time-out under heavy fleet contention
(load 41-50) while the same binary finished in 30.85s wall run alone. A
genuinely hung program is still killed, just at a higher ceiling under load
rather than never. A probe failure (missing `uptime`/`getconf`, malformed
output) falls back to the flat pre-#3587 300s bound rather than scaling
open-ended.

`BIT_MAXPROCS` does not exist anywhere in the runtime and is a silent no-op;
the real knob for scheduler worker count is `BIT_WORKERS` (see #3400). Every
run below names it explicitly rather than relying on the runtime's default
(currently 1, `runtime/root/rootconfig.bit`'s `rootEnvWorkers(1)`).

## Coverage table

Each program is built once and executed twice — `BIT_WORKERS=8` then
`BIT_WORKERS=1` — both passes always with `STRESS_WORKERS=8`
(`tests/bit/stressparallel.bit:289-291`, hardcoded regardless of
`BIT_WORKERS`), so the `BIT_WORKERS` column below covers both runs for that
program: a target only reads `pass` once **both** passes reported `PASS` in
the same run.

| scenario | program | workers | BIT_WORKERS | aarch64-macos | aarch64-linux | x86_64-linux |
|---|---|---|---|---|---|---|
| bounded-channel close races every in-flight receiver; no send/receive may be lost | chanhammer | 8 | 8, 1 | pass | not run | not run |
| `STRESS_WORKERS` goroutines increment one shared counter through `std/sync`'s Mutex, no atomics; final count must equal exactly `W*50000` | mutexcounter | 8 | 8, 1 | pass | not run | not run |
| WaitGroup fan-out/fan-in over a 100000-element list; reconciling checksum, not a hang check | fanout | 8 | 8, 1 | pass | not run | not run |
| self-referential record graph + per-worker retention ring under `BIT_GC=stress`; each retained record must survive concurrent collection intact | gcalloc | 8 | 8, 1 | pass | not run | not run |
| 3-stage producer/mapper/consumer pipeline sized so stage 2 is the bottleneck, forcing real backpressure; consumer verifies exactly-once delivery | pipeline | 8 | 8, 1 | pass | not run | not run |

`not run` means exactly that — no Linux host was used for this ticket, not
"expected to pass". Running the two Linux targets is #2540, a separate
ticket; when it lands, replace these two columns with its recorded verdicts
rather than inferring a Linux result from the macOS one.

**aarch64-macos, measured 2026-08-24** — the reproduce command above, run via
`boxlock.sh run` on this dev Mac, at commit `d0ba4ef6` (the load-scaled
version described above; merged to `main` at `46f707cc`, confirmed with
`git merge-base --is-ancestor d0ba4ef6 main`), under real heavy fleet
contention (`uptime` load 38.79/64.60/70.83, 6/6 boxlock slots held by other
agents' builds): all 10 runs (5 programs x `BIT_WORKERS` 8 and 1) reported
`PASS`, `stress-parallel: all 10 runs passed`, exit 0, 7m55s wall — no
`TIMEOUT`, the exact contention class that produced a false timeout before
#3587's load-scaling. Recorded in #3587's engineer comment. A repeat attempt
in this ticket's own worktree queued behind a `solo`-held lock (another
agent's `rm -rf bit-out && ./make && ./make test-differentials`) for the
full 10-minute foreground window without acquiring a slot, so this table
cites that prior run rather than a fresh one from this session.
