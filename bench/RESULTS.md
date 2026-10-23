# Benchmark results: full numbers and method

The README carries the short version. This page keeps every table and the method behind it.

### Runtime: CPU cycles, lower is better

| Benchmark | Bit | Go | C | Bit / Go | Bit / C |
|---|--:|--:|--:|--:|--:|
| fib | 1038.4 M | 959.9 M | 638.8 M | 1.08x | 1.63x |
| mandelbrot | 2142.5 M | 1645.1 M | 1610.7 M | 1.30x | 1.33x |
| collatz | 900.2 M | 619.6 M | 412.7 M | 1.45x | 2.18x |
| alloc | 626.2 M | 390.5 M | 561.8 M | 1.60x | 1.11x |
| allocflat | 164.2 M | 117.7 M | 54.1 M | 1.40x | 3.03x |
| allocpar | 1549.6 M | 1259.6 M | 2477.1 M | 1.23x | 0.63x |
| strings | 215.4 M | 384.5 M | 110.6 M | 0.56x | 1.95x |
| map | 348.8 M | 470.1 M | 189.8 M | 0.74x | 1.84x |
| strmap | 1193.9 M | 683.5 M | 264.0 M | 1.75x | 4.52x |
| sort | 285.5 M | 361.4 M | 276.3 M | 0.79x | 1.03x |
| matrix | 1394.8 M | 967.0 M | 402.4 M | 1.44x | 3.47x |
| json | 722.5 M | 351.7 M | 229.6 M | 2.05x | 3.15x |

### Instructions retired: work emitted, not time taken

| Benchmark | Bit | Go | C |
|---|--:|--:|--:|
| fib | 5300.7 M | 5137.3 M | 3146.9 M |
| mandelbrot | 4788.3 M | 2507.6 M | 2699.7 M |
| collatz | 2581.6 M | 935.8 M | 930.8 M |
| alloc | 4970.4 M | 2152.7 M | 3829.6 M |
| allocflat | 1259.1 M | 405.5 M | 139.4 M |
| allocpar | 6688.6 M | 4597.7 M | 3757.8 M |
| strings | 1703.5 M | 1728.0 M | 646.2 M |
| map | 759.6 M | 694.1 M | 248.3 M |
| strmap | 5503.5 M | 2212.9 M | 534.5 M |
| sort | 1612.2 M | 943.8 M | 505.8 M |
| matrix | 12279.0 M | 7325.6 M | 1657.5 M |
| json | 4660.2 M | 2149.4 M | 1341.1 M |

### Wall clock: median of 15 runs, milliseconds

| Benchmark | Bit | Go | C |
|---|--:|--:|--:|
| fib | 239.1 ms | 224.5 ms | 149.4 ms |
| mandelbrot | 498.7 ms | 384.3 ms | 374.4 ms |
| collatz | 204.0 ms | 139.4 ms | 93.3 ms |
| alloc | 147.3 ms | 82.4 ms | 137.1 ms |
| allocflat | 41.0 ms | 19.7 ms | 14.8 ms |
| allocpar | 62.1 ms | 61.7 ms | 76.9 ms |
| strings | 53.2 ms | 61.0 ms | 28.1 ms |
| map | 80.4 ms | 117.3 ms | 47.5 ms |
| strmap | 279.9 ms | 159.7 ms | 64.1 ms |
| sort | 66.4 ms | 87.7 ms | 68.6 ms |
| matrix | 334.0 ms | 232.0 ms | 97.3 ms |
| json | 145.3 ms | 79.3 ms | 57.7 ms |
| allocpar W1 | 171.8 ms | 105.6 ms | 76.9 ms |
| allocpar W8 | 57.2 ms | 61.3 ms | 76.9 ms |

### GC pauses: one untimed run per case, share of that run's own wall clock

| Benchmark | Bit pauses | Bit pausens ms (share) | Bit pausemax ms | Go GCs | Go STW ms (share) | Go STW max ms | C |
|---|--:|--:|--:|--:|--:|--:|--:|
| fib | 0 | 0.0 ms (0.0%) | 0.0 ms | 0 | 0.0 ms (0.0%) | 0.0 ms | n/a |
| mandelbrot | 0 | 0.0 ms (0.0%) | 0.0 ms | 0 | 0.0 ms (0.0%) | 0.0 ms | n/a |
| collatz | 0 | 0.0 ms (0.0%) | 0.0 ms | 0 | 0.0 ms (0.0%) | 0.0 ms | n/a |
| alloc | 133 | 17.4 ms (11.7%) | 0.1 ms | 69 | 1.9 ms (2.3%) | 0.0 ms | n/a |
| allocflat | 66 | 0.2 ms (0.4%) | 0.0 ms | 77 | 2.3 ms (11.8%) | 0.0 ms | n/a |
| allocpar | 166 | 36.3 ms (57.2%) | 0.6 ms | 72 | 8.6 ms (12.0%) | 0.2 ms | n/a |
| strings | 3 | 0.5 ms (1.0%) | 0.3 ms | 14 | 0.5 ms (0.8%) | 0.1 ms | n/a |
| map | 1 | 0.0 ms (0.0%) | 0.0 ms | 4 | 0.1 ms (0.1%) | 0.0 ms | n/a |
| strmap | 4 | 3.3 ms (1.2%) | 2.7 ms | 3 | 0.1 ms (0.1%) | 0.0 ms | n/a |
| sort | 7 | 5.6 ms (8.5%) | 1.6 ms | 1 | 0.0 ms (0.0%) | 0.0 ms | n/a |
| matrix | 1 | 0.0 ms (0.0%) | 0.0 ms | 1 | 0.0 ms (0.0%) | 0.0 ms | n/a |
| json | 19 | 10.8 ms (7.6%) | 6.9 ms | 10 | 0.3 ms (0.4%) | 0.0 ms | n/a |
| allocpar W1 | 154 | 39.8 ms (23.0%) | 0.5 ms | 79 | 0.1 ms (0.1%) | 0.0 ms | n/a |
| allocpar W8 | 177 | 34.9 ms (48.0%) | 0.5 ms | 80 | 7.4 ms (11.8%) | 0.1 ms | n/a |

### Peak memory: max RSS, lower is better

| Benchmark | Bit | Go | C |
|---|--:|--:|--:|
| fib | 2.1 MB | 4.4 MB | 1.6 MB |
| mandelbrot | 2.1 MB | 4.4 MB | 1.6 MB |
| collatz | 2.1 MB | 4.4 MB | 1.6 MB |
| alloc | 6.6 MB | 10.7 MB | 1.8 MB |
| allocflat | 6.1 MB | 11.8 MB | 1.7 MB |
| allocpar | 10.2 MB | 17.9 MB | 3.2 MB |
| strings | 62.8 MB | 69.2 MB | 30.8 MB |
| map | 37.0 MB | 41.7 MB | 193.6 MB |
| strmap | 35.8 MB | 31.0 MB | 41.0 MB |
| sort | 18.0 MB | 15.0 MB | 11.2 MB |
| matrix | 8.5 MB | 11.2 MB | 7.6 MB |
| json | 129.3 MB | 60.4 MB | 125.2 MB |

### Heap allocations per run: the equivalence check, not a score

| Benchmark | Bit | Go | C |
|---|--:|--:|--:|
| fib | 2 | 192 | 0 |
| mandelbrot | 2 | 192 | 0 |
| collatz | 2 | 192 | 0 |
| alloc | 10006002 | 10002319 | 10004000 |
| allocflat | 4002 | 2300 | 2000 |
| allocpar | 10006015 | 10002402 | 10004000 |
| strings | 33 | 334 | 11 |
| map | 10 | 4375 | 1 |
| strmap | 400037 | 400800 | 400003 |
| sort | 600018 | 150277 | 150002 |
| matrix | 12 | 275 | 3 |
| json | 3750060 | 1050003 | 2250021 |

### Binary size: static, as emitted

| Benchmark | Bit | Go | C |
|---|--:|--:|--:|
| fib | 409 KB | 2373 KB | 33 KB |
| mandelbrot | 409 KB | 2373 KB | 33 KB |
| collatz | 409 KB | 2373 KB | 33 KB |
| alloc | 410 KB | 2390 KB | 33 KB |
| allocflat | 409 KB | 2373 KB | 33 KB |
| allocpar | 445 KB | 2390 KB | 33 KB |
| strings | 410 KB | 2389 KB | 33 KB |
| map | 449 KB | 2390 KB | 33 KB |
| strmap | 467 KB | 2390 KB | 33 KB |
| sort | 428 KB | 2407 KB | 33 KB |
| matrix | 409 KB | 2373 KB | 33 KB |
| json | 502 KB | 3696 KB | 33 KB |

### Startup & compile

| Metric | Bit | Go | C |
|---|--:|--:|--:|
| Process startup (per exec) | 4.586 ms | 5.790 ms | 4.536 ms |

Bit compile speed: **660 lines/sec** (769 lines across 12 cases, warm).

> Machine: Apple M5 Max, macOS 27.0.1. Bit @ `25c4f4985`, Go go1.27.3, Apple clang version 21.0.0 (clang-2100.3.34.2).
> Method: 15 runs per case per language. Cycles and instructions are a trimmed mean of those runs, meaning the mean after dropping the slowest fifth, which was the most reproducible of four estimators measured over 40 samples per series; wall clock and RSS are the median. C built `cc -O2 -ffp-contract=off`, Go `go build`, Bit `bit build`, each language's standard optimized build.
> Mandelbrot: Bit and C agree to the last bit; Go differs by ~0.0002% because it contracts `a*b+c` to a hardware FMA. Not a bug: cross-compiler float bit-identity is not guaranteed.
> alloc measures the ALLOCATOR: 10M short-lived nodes, each its own heap object in all three languages (Bit's element class has a reference field, Go holds `[]*Node`, C mallocs per node). allocflat measures DATA LAYOUT: the same 10M nodes and the same printed total, stored by value in one buffer per batch (Bit packs `[]Node` inline, Go holds `[]Node`, C mallocs the batch once). The gap between the two rows is what per-node heap allocation costs a language.
> allocpar measures the allocator under CONTENTION: the identical 10M nodes and the identical printed total as alloc, partitioned across 8 concurrent workers (Bit `spawn`, Go goroutines, C pthreads), worker count fixed in all three sources and never read from the host core count. The gap between the alloc and allocpar rows is what a language's allocator costs when more than one thread is in it; every other case in this table is single-mutator, so that cost appears nowhere else.
> The allocation table above is how those two claims are checked rather than asserted: same order of magnitude across a row means the three sources still express the same data structure, which is exactly what `alloc` silently lost for a day. Bit's count is `swept+live` from `BIT_GC_STATS=1`; Go's is `runtime.MemStats.Mallocs` and C's a `malloc` counter, both opt-in (`BENCH_ALLOC_STATS`, `-DBENCH_ALLOC_STATS`) and both absent from every timed binary.
> The ratios are built from CYCLES, not from wall clock. `/usr/bin/time` reports `real` in hundredths of a second and most of the C sides here finish in under 0.10s, so a wall-clock ratio for those rows would be quantisation: `map` published 7.50x C off 0.300s/0.040s where the counters say ~4.5x. Adding runs does not fix that, because it narrows the spread around a quantised value instead of removing the quantisation, so the unit changed. Cycles and instructions come from the same `/usr/bin/time -l` invocation that also produced the RSS; nothing extra is run and nothing extra is installed for those three. Wall clock is a separate one-decimal-millisecond measurement (`wall_run()`, one `fork`+`exec`+`waitpid` perl process per run, not `/usr/bin/time`'s own field) so it stays usable below `/usr/bin/time`'s 10ms floor; it still carries no ratio column and is kept as context.
> GC pauses: one untimed run per case, separate from the timed runs above (BIT_GC_STATS/GODEBUG both add real overhead). Bit's fields are `pausens=`/`pausemaxns=`/`pauses=` from `BIT_GC_STATS=1`. Go's are parsed from one `GODEBUG=gctrace=1` run: each `gc N @Ts P%: A+B+C ms clock` line's A (sweep termination) and C (mark termination) are its two STW segments (`go doc runtime`, go1.27.1), summed for the STW total, maxed individually for the longest single pause; B (concurrent mark) is not a stop and is excluded. C has no collector (n/a). Share is that probe run's own `wall_run()` wall time, not the timed loop's median. `allocpar W1`/`W8` reruns the same probe with `BIT_WORKERS`/`GOMAXPROCS` set; C is unchanged (its worker count is a compile-time `#define`, never read from env) so its wall-table cell reuses the baseline `allocpar` row rather than a redundant rerun.
> Cycles and instructions are startup-corrected: each figure has that language's own empty-program cost (`bench/cases/startup`, bit 5.5M, c 4.6M, go 6.8M) subtracted, because dyld and runtime init differ per language and are a fifth of C's `allocflat` row. Every other table is raw.

> On `matrix`, read the Go column as the target and not the C one. The C side vectorises: it retires 2.06 instructions per inner-loop iteration against Go's 9.09, so the Bit:C ratio on this row compares a scalar loop against a vectorised one and is not a statement about codegen quality. A scalar `cc -O2 -fno-vectorize` control build of the same case retires 8.07, which is the like-for-like figure. Denominator for all three: `trials * n^3 = 6 * 512^3 = 805,306,368` inner iterations.
> Reproducibility was measured rather than assumed: four independent regenerations of this table on this box held every ratio to 2.5% between adjacent runs and 8.5% at worst across all four. The loose rows are `alloc`, `map`, `allocflat` and `strings`, whose Go or C side is short enough that that language's own allocator and collector scheduling moves it by several percent from run to run; `matrix`, `mandelbrot`, `fib` and `sort` reproduce to about 1%. On those four loose rows, read a change under ~3% as noise.
> Peak RSS above is a within-run median like every other figure in that table, but it can still swing further ACROSS separate regenerations than one run shows. From every regeneration recorded in `bench/history.csv`, restricted to the same four loose rows above and to the Go/C columns (the Bit column reflects real compiler/runtime changes over that history, not noise): `alloc` c: 1.5-2.2 MB (median 2.0 MB, N=70); `allocflat` go: 10.6-12.8 MB (median 11.4 MB, N=61); `allocflat` c: 1.5-1.9 MB (median 1.9 MB, N=61); `strings` go: 61.0-100.0 MB (median 70.3 MB, N=67). Read that cell's published number as representative of the stated range, not a fixed constant.
> Instructions are published beside cycles because a cycle gap alone does not say whether it is work emitted or work stalled, and the two ratios differ a lot here: Bit retires roughly 4-7 instructions per cycle against C's 1.4-1.8, so its instruction ratio always overstates its cycle ratio. Cycles are the time; instructions are the reason.
> Generated by `bench/run.sh` on 2026-10-23T01:40:37Z. Do not edit by hand.
