# RCA: runtime + compile performance regression, Zig seed → self-hosted compiler

**Status:** Finding 2 (allocator/RSS) root-caused to a commit and FIXED (#2920).
Finding 1 (codegen) remains open at subsystem level, bisect pending.
**Severity:** high. Generated code is now 4–5× slower on compute and the allocator
holds ~18× the memory on churn; the compiler itself is ~6× slower.
**Measured:** on `bench/run.sh`, single idle host (Apple M5 Max, macOS 26.6.x).
**Compared:** Zig seed compiler `bitc` @ `182f9c9` vs self-hosted `bit` @ `eaff3b94`
(1470 commits apart). Both runs are recorded in `bench/history.csv`.

## TL;DR

Three independent regressions, on two different timelines:

1. **Codegen** — non-allocating compute regressed **4–5×** (`collatz` 0.43s → 2.07s,
   `mandelbrot` 0.78s → 3.32s). Pure emitted-code quality; `fib` (call-bound) was
   unaffected, so the loss is in loop / arithmetic codegen, not calls. Still open;
   not dated more precisely than "somewhere in the seed→self-host bootstrap".
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

### Finding 1 — codegen regression (proven at subsystem level)

`collatz` and `mandelbrot` **allocate nothing** — by construction they use only
`i64`/`f64` locals, no `struct`, `slice`, or `append`. Their 4–5× slowdown
therefore cannot involve the allocator or GC; it is entirely the quality of the
machine code the compiler emits. `fib`, which is dominated by call overhead rather
than loop body work, did **not** regress (1.04×). The regression is thus localized
to **loop / arithmetic codegen** (instruction selection and register allocation),
not the calling convention.

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
built by the Bit compiler, so it is subject to Finding 1's weak codegen on its own
hot paths. This is expected to improve as Finding 1 is fixed and does not need
independent root-causing first.

## Scope and what is NOT yet known

- **Commit-level cause is unknown.** 1470 commits separate the two builds. Both
  root causes are almost certainly a small number of commits inside that range, but
  which ones is **not established** — this RCA localizes to subsystem, not commit.
- The two seed→self-host builds are one data point each (n=7 medians) on one host,
  one day apart in wall-clock terms but comparable hardware/OS. The regression
  magnitude (4–26×) is far outside measurement noise, but a bisect must re-measure
  rather than trust these two rows.

## Reproduction

```sh
# current numbers, both root causes:
./bench/run.sh                                   # writes README.md, RESULTS.md, history.csv

# Finding 2 discriminator — collector works, memory is not returned:
/usr/bin/time -l ./bit-out/bin/bit build bench/cases/alloc/alloc.bit -o /tmp/alloc
BIT_GC_STATS=1 /tmp/alloc >/dev/null            # collections=1205 swept=10M live=15K
/usr/bin/time -l /tmp/alloc >/dev/null          # RSS ~154 MB

# Finding 1 — non-allocating, so pure codegen:
/usr/bin/time -l /tmp/collatz >/dev/null        # 2.07s vs seed 0.43s
```

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
2. **Bisect the loop-codegen slowdown (Finding 1).** Use `collatz` wall-clock as
   the signal (largest, allocation-free multiplier). ~11 builds. Owner:
   `bit-triage`. May share a commit with (1) or be independent.
3. **Rebuild the seed at `182f9c9` for a true A/B** if the bisect is ambiguous:
   checkout pre-`afd448f1` (before `build.zig` was deleted) and `zig build` with the
   still-present `zig 0.16`. This is the only way to compare seed vs self-host
   codegen directly rather than by the recorded numbers.
4. File the two root causes as separate smash bugs (allocator; loop codegen) so they
   can be fixed independently. Finding 3 rides on Finding 1.

## Appendix — environment

- Host: Apple M5 Max, macOS 26.6.x.
- Self-host: `bit` @ `eaff3b94`, built via `./make` (stage0-pinned).
- References: Go `go1.26.5`, Apple clang 21.0.0, C built `cc -O2 -ffp-contract=off`.
- GC knobs (defaults, `runtime/ABI.md`): `BIT_GC_MIN_KB=4096`,
  `BIT_GC_GROWTH_PCT=200`, `BIT_GC=on`.
