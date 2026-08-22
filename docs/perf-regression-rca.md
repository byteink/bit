# RCA: runtime + compile performance regression, Zig seed → self-hosted compiler

**Status:** both findings root-caused and FIXED — Finding 1 by #2921, Finding 2 by
#2920, both merged to `main` 2026-08-12. **This document's original subsystem
attribution was WRONG for both**, and the corrected mechanisms are in each
Finding below. Residual work is tracked as #2925 (finish Finding 1: the guard is
still a leaf call, ~0.50s of collatz's remaining 0.86s), #2926 (x64 never got the
guard), #2922 (a genuine, separate allocator leak found underneath Finding 2).
**Severity:** was high — 4–5× on compute and ~18× peak RSS. After the fixes:
collatz 2.10s → 0.86s, mandelbrot 3.47s → 1.29s, `alloc` peak RSS 154.0 MB →
10.2 MB, all re-measured on `main`. Still 2.0× and 1.65× the seed respectively,
hence #2925.
**Measured:** on `bench/run.sh`, single idle host (Apple M5 Max, macOS 26.6.x).
**Compared:** Zig seed compiler `bitc` @ `182f9c9` vs self-hosted `bit` @ `eaff3b94`
(1470 commits apart). Both runs are recorded in `bench/history.csv`.

## TL;DR

Three independent regressions, on two different timelines:

1. **Runtime safepoint poll, NOT codegen** — non-allocating compute regressed
   **4–5×** (`collatz` 0.43s → 2.07s, `mandelbrot` 0.78s → 3.32s) while `fib`
   (call-bound) held at 1.04×. This document originally read that as loop /
   arithmetic codegen. **It is not.** Loop-body emission is unchanged in cost
   across the whole range; 83% of collatz's runtime was inside the poll emitted at
   every loop back edge, whose *callee* grew from one inlined Zig check into five
   Bit stack frames. Two steps: `09e862a2` (#1429, 1.64×) and `6eaaad83`
   (#1583/#1584, 2.10×). Fixed by #2921; see Finding 1.
2. **Boot-time GC min-trigger default** — `alloc` peak RSS **8.6 MB → 154 MB**
   (~18×). **Not a seed→self-host bootstrap cost**: v0.1.2, a released
   *self-hosted* compiler, reproduces the healthy 8.56 MB figure exactly. The
   regression is a single commit inside the self-hosted era (`6eaaad83`,
   07-29), which put a boot.bit constant 64x below the documented default on
   the shipping path. Root-caused and fixed by #2920; see Finding 2.
3. **Compiler self-speed** — **1844 → 287 lines/sec** (~6× slower). A consequence
   of (1): the compiler is now Bit compiled by Bit, so weak codegen compounds.

These are two distinct root causes (codegen, boot-time GC config) plus one
downstream consequence (compiler speed).

## Evidence

### Benchmark deltas (median of 7 runs)

| Benchmark | Seed `bitc` | Self-host `bit` | Regression | C (ref) | Bit/C then → now |
|---|--:|--:|--:|--:|---|
| fib (recursion / calls) | 0.28s | 0.29s | 1.04× | 0.14s | 2.0× → 2.1× |
| mandelbrot (f64 loops)  | 0.78s | 3.32s | **4.26×** | 0.35s | 2.2× → 9.5× |
| collatz (i64 div/mod)   | 0.43s | 2.07s | **4.81×** | 0.09s | 4.8× → 23× |
| alloc (GC churn)        | 0.42s | 3.08s | **7.33×** | 0.12s | 3.5× → 26× |

| Metric | Seed | Self-host |
|---|--:|--:|
| alloc peak RSS | 8.6 MB | **154.0 MB** |
| compile speed  | 1844 L/s | **287 L/s** |
| binary size    | 118 KB | 276 KB |

### Finding 1 — runtime safepoint poll regression (proven at subsystem level; CORRECTED, #2921)

**This finding originally attributed the regression to "loop / arithmetic
codegen (instruction selection and register allocation)". That attribution is
disproven — see #2921's engineer comment for the full measurement. Corrected
here rather than left standing, since this document is what escalated the
investigation.**

`collatz` and `mandelbrot` **allocate nothing** — by construction they use only
`i64`/`f64` locals, no `class`, `slice`, or `append`. Their 4–5× slowdown
therefore cannot involve the allocator or GC. It is also **not** instruction
selection or register allocation: `@nosplit` on the benchmark function (SPEC
§10.3.1) suppresses only the back-edge safepoint poll, leaving the same loop
body, and the emitted loop body's cost is flat — 0.35s / 0.35s / 0.33s
(`@nosplit collatz`) — across three commits spanning the whole 1470-commit
range. `fib`, which is dominated by call overhead rather than a loop back edge
(recursion has no back-edge poll), did **not** regress (1.04×), consistent with
the loop body itself being unaffected.

The actual regression is the **runtime safepoint poll's callee**. Every loop
back edge emits an unconditional `bl bit_rt_safepoint` (both then and now); at
the Zig seed (`182f9c9`) that call was one inlined check (`g_gc.safepoint`).
Two runtime-only commits grew it into a 5-stack-frame Bit call chain — the
naked snapshot shim, then `stwSafepoint` → `stwPoll` → `stwPollOn` →
`currentMutatorOn`/`mutatorSlot` (`runtime/stw/stwpoll.bit`,
`runtime/gc/gcworldsync.bit`) — three of which are pure argument forwarders
kept `@symbol`-pinned across a module boundary and so never inlined:
`09e862a2` (#1429, a real per-thread safepoint frame and STW handshake, 1.64×)
and `6eaaad83` (#1583/#1584, G2/G3 porting `libbitrt.a` from Zig to Bit,
2.10×), plus self-hosting adding two more forwarder frames (1.23×). Measured at
13.3 ns/iteration (~53 cycles) for a fast path whose entire semantic content is
"no stop pending, no collection due, return" — 83% of `collatz`'s runtime.

Fixed by #2921: an inlined fast-path guard, `bit_rt_safepoint_needed` (a true
leaf, no calls of its own), checked before the unconditional call — the common
case is now one leaf call plus a branch, skipping the five-frame chain
entirely, with the chain still reachable exactly when a stop is pending or a
collection is due.

Ruled out as the cause:
- **Missing optimization flag.** `bit build` exposes no `-O` level
  (`-o`, `-c`, `--freestanding`, `--target` only) — there is a single codegen path,
  so this is not a misconfigured build.
- **Benchmark drift.** The `.bit` sources were migrated `function` → `fn`
  (commit `d8368950`) but are otherwise identical; the Go/C references are
  untouched and still verify byte-for-byte (integer cases) against Bit.

### Finding 2 — boot-time GC min-trigger default, 64x too low (ROOT-CAUSED AND FIXED, #2920)

Running `alloc` with `BIT_GC_STATS=1` prints:

```
[bit-gc] collections=1205 swept=10014982 live=15023 abandoned=0 oom=0 bad=0
```

The collector runs 1205 times, sweeps all ~10M allocated objects, and ends with
only 15K live — so **marking and sweeping are correct**, and the allocator's
reuse/return path was never the defect: an earlier draft of this finding blamed
"allocator reuse/return" (`runtime/gc/gcalloc.bit` / `runtime/alloc/**`). That
theory is wrong. The actual subsystem is **boot-time GC configuration**:
`runtime/root/darwin/boot.bit:172` and `runtime/root/linux/boot.bit:251` each
carried a private `const minTrigger: int = 65536`, 64x below
`runtime/gc/gc.bit`'s exported `gcDefaultMinTrigger = 4194304` — the value
`runtime/ABI.md` documents as the default. `gcInit` seeds the collector
correctly with the real default; `boot`'s call to `rootConfigureFromEnv` then
overwrote it with the stale 64 KiB value on every program, on both platforms,
so the collector ran a cycle every ~64 KiB of churn instead of every 4 MiB.

Setting `BIT_GC_MIN_KB=4096` (the documented default) on the exact same binary
drops peak RSS **154 MB → 10.2 MB** and collections **1205 → 199** — the Zig
runtime's own collection count on this program — while `swept` stays ~10M and
`live` stays small in both runs: the fix does not work by collecting less, it
works by collecting at the intended cadence. Fixed in #2920: `boot` now
imports and passes `gcDefaultMinTrigger` directly instead of carrying a
duplicate constant, so there is exactly one definition of the default.

A genuinely separate, much smaller defect remains open: a per-allocation leak
of ~21 bytes in certain size classes when the live set is small, tracked as
#2922. It is unrelated to this finding (correcting the trigger makes it
slightly *worse* in isolation) and does not explain the 154 MB figure, which
#2920's fix resolves on its own.

Ruled out: a **retention / marking bug** — `live=15023` and `swept=10014982` show
the collector does identify the dropped batches as dead and reclaim them.

### Finding 3 — compiler self-speed (downstream consequence)

Compile throughput fell 1844 → 287 L/s. The self-hosted compiler is a Bit program
built by the Bit compiler, so it pays Finding 1 on its own hot paths — every loop
in the compiler was polling through five stack frames. Not independently
root-caused, and correctly so; it should improve with #2921 and further with
#2925. **Re-measure it before quoting either number again** — the 287 figure
predates both fixes.

## Scope: what this document got wrong, and why it matters

**Both subsystem attributions in the original draft were false, and both were
stated as "proven at subsystem level".** Finding 1 named instruction selection and
register allocation; the cause was the safepoint poll's callee. Finding 2 named
allocator reuse/return; the cause was a boot-time constant 64× too low. Each was
disproved by one command, and each wrong attribution propagated into a bug ticket
and an agent dispatch before it was caught.

The measurements in this document are sound and the benchmark tables are accurate.
**The localization was the hypothesis, not the finding** — and it read as a finding
because it was written with the same confidence. Two lessons worth keeping:

- **A negative result at subsystem level is much stronger than a positive one.**
  "`collatz` allocates nothing, so the allocator is not involved" was correct and
  load-bearing. "Therefore it is instruction selection" was a guess wearing the
  first claim's authority.
- **Say which premises you have not checked.** Two of this document's supporting
  claims were false — that every intermediate commit builds with the current pinned
  stage0 (each pins its own), and that comparing seed to self-host was necessary at
  all (a released *self-hosted* toolchain reproduces the healthy baseline). Both
  were written as facts and both went into dispatches as facts.

Also still true, and unchanged: the seed→self-host rows are one data point each
(n=7 medians) on one host. The magnitudes were far outside noise, but any future
claim here must re-measure rather than trust a recorded row.

## Reproduction

```sh
# current numbers, both root causes:
./bench/run.sh                                   # writes README.md, RESULTS.md, history.csv

# Finding 2 discriminator — collector works, memory is not returned:
/usr/bin/time -l ./bit-out/bin/bit build bench/cases/alloc/alloc.bit -o /tmp/alloc
BIT_GC_STATS=1 /tmp/alloc >/dev/null            # collections=1205 swept=10M live=15K
/usr/bin/time -l /tmp/alloc >/dev/null          # RSS ~154 MB

# Finding 1 discriminator — @nosplit suppresses ONLY the back-edge poll
# (SPEC §10.3.1), so this isolates the poll from the loop body with one build:
sed 's/^fn collatz/@nosplit fn collatz/' bench/cases/collatz/collatz.bit > /tmp/c_ns.bit
./bit-out/bin/bit build /tmp/c_ns.bit -o /tmp/c_ns
/usr/bin/time -p /tmp/c_ns >/dev/null           # 0.36s user, vs 2.09s unguarded
                                                # both print 524; the seed was 0.43s
```

**Both discriminators above answered the question that two ~11-build bisects were
commissioned for, and each is one command.** Neither subsystem attribution in the
original draft survived them. A discriminator that lands *below* the baseline you
are chasing — `@nosplit` at 0.36s against the seed's 0.43s — ends the
investigation; no bisect can add to that.

Historic seed numbers are in `bench/history.csv` under `git_sha=182f9c9`.

## Recommended next steps

1. **DONE — Finding 2 is root-caused and fixed (#2920).** A commit-level bisect
   was never run, and the plan to run one here was based on a false premise:
   "every intermediate commit is buildable with the current pinned stage0" is
   NOT true — each commit pins its OWN stage0 (`dist/stage0/SHA256SUMS` at
   `189c3d01^` pins 0.1.5, not the 0.1.13 actually cached in `bit-out/stage0/`),
   and crossing `09dbb53d`/#2773 (the lexer drops the `function` keyword) means
   no locally-available stage0 can build the older trees at all. What actually
   worked, and is the method to reuse for a future case like this: a
   single-variable A/B on two *released* toolchains — extract v0.1.2 and v0.1.3,
   swap `lib/<triple>/libbitrt.a` between them, rebuild the same benchmark with
   each combination. The compiler binary never changes across the four runs, so
   only the runtime archive can explain the result; no bisect and no Zig build
   were required.
2. **DONE — Finding 1 is root-caused and fixed (#2921).** The bisect this section
   originally asked for did run, and its most useful output was not the SHA: the
   `@nosplit` discriminator above settled the subsystem in one build, and the
   bisect's value was turning "a subsystem" into a mechanism at `file:line` with a
   cost model. **The step commits were found by timing two runtime-only commits,
   not by walking 11.** Rebuilding the seed at `182f9c9` (step 3 of the original
   plan) was never needed either — see Finding 2's note that a *released
   self-hosted* toolchain reproduces the healthy baseline, so the seed is not
   required to establish one.
3. **Remaining work, all filed.** #2925 finishes Finding 1 — the guard is still a
   leaf call and ~0.50s of collatz's remaining 0.86s is that call, against a
   measured 0.36s floor. #2926 ports the guard to x64, which never got it. #2922 is
   the genuine allocator leak found underneath Finding 2 (~21 B/allocation,
   unbounded, only when a class's live set is small) — that one is a real
   reuse/return defect, which is what this document originally *guessed* Finding 2
   was.
4. **The method to reuse, since both attributions here were wrong.** Before
   commissioning a bisect, look for a switch that turns the suspected mechanism off
   and leaves everything else identical — an attribute, an environment variable, an
   archive swap between two released toolchains. Both of this document's findings
   had one, and each cost a single command. Then bisect for the *mechanism*, not for
   the SHA.

## Appendix — environment

- Host: Apple M5 Max, macOS 26.6.x.
- Self-host: `bit` @ `eaff3b94`, built via `./make` (stage0-pinned).
- References: Go `go1.26.5`, Apple clang 21.0.0, C built `cc -O2 -ffp-contract=off`.
- GC knobs (defaults, `runtime/ABI.md`): `BIT_GC_MIN_KB=4096`,
  `BIT_GC_GROWTH_PCT=200`, `BIT_GC=on`.
