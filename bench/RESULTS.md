# Benchmark results: full numbers and method

The README carries the short version. This page keeps every table and the method behind it.

### Runtime: CPU cycles, lower is better

| Benchmark | Bit | Go | C | Bit / Go | Bit / C |
|---|--:|--:|--:|--:|--:|
| fib | 1029.8 M | 944.9 M | 637.0 M | 1.09x | 1.62x |
| mandelbrot | 2140.1 M | 1643.2 M | 1609.9 M | 1.30x | 1.33x |
| collatz | 903.6 M | 619.5 M | 412.6 M | 1.46x | 2.19x |
| alloc | 630.3 M | 392.5 M | 465.4 M | 1.61x | 1.35x |
| allocflat | 163.4 M | 115.9 M | 17.9 M | 1.41x | 9.10x |
| allocpar | 1589.1 M | 1256.3 M | 2115.3 M | 1.26x | 0.75x |
| strings | 214.9 M | 366.1 M | 109.4 M | 0.59x | 1.96x |
| map | 327.5 M | 413.3 M | 177.3 M | 0.79x | 1.85x |
| strmap | 1187.8 M | 682.0 M | 257.5 M | 1.74x | 4.61x |
| sort | 272.8 M | 357.9 M | 276.5 M | 0.76x | 0.99x |
| matrix | 1385.7 M | 954.6 M | 399.7 M | 1.45x | 3.47x |
| json | 712.6 M | 343.7 M | 228.3 M | 2.07x | 3.12x |

### Instructions retired: work emitted, not time taken

| Benchmark | Bit | Go | C |
|---|--:|--:|--:|
| fib | 5300.6 M | 5137.3 M | 3146.8 M |
| mandelbrot | 4787.7 M | 2507.0 M | 2699.3 M |
| collatz | 2581.4 M | 935.8 M | 930.7 M |
| alloc | 4970.4 M | 2152.2 M | 3606.9 M |
| allocflat | 1259.1 M | 404.4 M | 59.3 M |
| allocpar | 6706.7 M | 4600.3 M | 3621.2 M |
| strings | 1703.5 M | 1699.4 M | 643.3 M |
| map | 759.4 M | 693.6 M | 235.5 M |
| strmap | 5507.6 M | 2212.6 M | 534.7 M |
| sort | 1611.1 M | 943.2 M | 503.7 M |
| matrix | 12277.4 M | 7324.2 M | 1656.3 M |
| json | 4661.8 M | 2142.5 M | 1342.3 M |

### Wall clock: median of 15 runs, milliseconds

| Benchmark | Bit | Go | C |
|---|--:|--:|--:|
| fib | 240.5 ms | 224.1 ms | 150.1 ms |
| mandelbrot | 489.8 ms | 372.7 ms | 365.3 ms |
| collatz | 201.9 ms | 138.4 ms | 92.3 ms |
| alloc | 150.3 ms | 81.9 ms | 113.0 ms |
| allocflat | 40.9 ms | 19.8 ms | 6.1 ms |
| allocpar | 60.5 ms | 61.3 ms | 66.8 ms |
| strings | 52.2 ms | 60.9 ms | 27.8 ms |
| map | 79.1 ms | 97.6 ms | 45.6 ms |
| strmap | 272.6 ms | 158.4 ms | 61.7 ms |
| sort | 63.0 ms | 85.3 ms | 65.4 ms |
| matrix | 323.4 ms | 224.0 ms | 94.8 ms |
| json | 140.7 ms | 74.7 ms | 56.9 ms |
| allocpar W1 | 175.5 ms | 105.4 ms | 66.8 ms |
| allocpar W8 | 56.2 ms | 60.9 ms | 66.8 ms |

### GC pauses: one untimed run per case, share of that run's own wall clock

| Benchmark | Bit pauses | Bit pausens ms (share) | Bit pausemax ms | Go GCs | Go STW ms (share) | Go STW max ms | C |
|---|--:|--:|--:|--:|--:|--:|--:|
| fib | 0 | 0.0 ms (0.0%) | 0.0 ms | 0 | 0.0 ms (0.0%) | 0.0 ms | n/a |
| mandelbrot | 0 | 0.0 ms (0.0%) | 0.0 ms | 0 | 0.0 ms (0.0%) | 0.0 ms | n/a |
| collatz | 0 | 0.0 ms (0.0%) | 0.0 ms | 0 | 0.0 ms (0.0%) | 0.0 ms | n/a |
| alloc | 133 | 17.3 ms (11.8%) | 0.2 ms | 69 | 1.9 ms (2.3%) | 0.0 ms | n/a |
| allocflat | 66 | 0.2 ms (0.4%) | 0.0 ms | 76 | 2.4 ms (12.0%) | 0.2 ms | n/a |
| allocpar | 166 | 33.5 ms (54.6%) | 0.5 ms | 62 | 7.2 ms (12.1%) | 0.2 ms | n/a |
| strings | 3 | 0.4 ms (0.7%) | 0.2 ms | 12 | 0.3 ms (0.4%) | 0.0 ms | n/a |
| map | 1 | 0.0 ms (0.0%) | 0.0 ms | 4 | 0.1 ms (0.1%) | 0.1 ms | n/a |
| strmap | 4 | 3.5 ms (1.3%) | 3.0 ms | 2 | 0.1 ms (0.1%) | 0.0 ms | n/a |
| sort | 7 | 5.2 ms (8.2%) | 1.5 ms | 1 | 0.0 ms (0.0%) | 0.0 ms | n/a |
| matrix | 1 | 0.0 ms (0.0%) | 0.0 ms | 1 | 0.0 ms (0.0%) | 0.0 ms | n/a |
| json | 19 | 10.7 ms (7.6%) | 6.9 ms | 10 | 0.3 ms (0.4%) | 0.0 ms | n/a |
| allocpar W1 | 157 | 43.0 ms (24.5%) | 0.4 ms | 78 | 0.0 ms (0.0%) | 0.0 ms | n/a |
| allocpar W8 | 178 | 35.0 ms (62.8%) | 0.4 ms | 81 | 7.4 ms (12.1%) | 0.1 ms | n/a |

### Peak memory: max RSS, lower is better

| Benchmark | Bit | Go | C |
|---|--:|--:|--:|
| fib | 2.2 MB | 4.5 MB | 1.7 MB |
| mandelbrot | 2.2 MB | 4.5 MB | 1.7 MB |
| collatz | 2.2 MB | 4.5 MB | 1.7 MB |
| alloc | 6.7 MB | 10.7 MB | 2.0 MB |
| allocflat | 6.2 MB | 11.5 MB | 1.9 MB |
| allocpar | 10.2 MB | 18.2 MB | 3.8 MB |
| strings | 62.9 MB | 69.2 MB | 31.0 MB |
| map | 37.1 MB | 41.8 MB | 193.8 MB |
| strmap | 35.8 MB | 31.1 MB | 41.1 MB |
| sort | 18.0 MB | 15.1 MB | 11.3 MB |
| matrix | 8.5 MB | 11.3 MB | 7.8 MB |
| json | 129.4 MB | 58.0 MB | 125.5 MB |

### Heap allocations per run: the equivalence check, not a score

| Benchmark | Bit | Go | C |
|---|--:|--:|--:|
| fib | 2 | 196 | 0 |
| mandelbrot | 2 | 196 | 0 |
| collatz | 2 | 196 | 0 |
| alloc | 10006002 | 10002309 | 10004000 |
| allocflat | 4002 | 2301 | 2000 |
| allocpar | 10006015 | 10002428 | 10004000 |
| strings | 33 | 341 | 11 |
| map | 10 | 4379 | 1 |
| strmap | 400037 | 400798 | 400003 |
| sort | 600018 | 150286 | 150002 |
| matrix | 12 | 279 | 3 |
| json | 3750060 | 1049989 | 2250021 |

### Binary size: static, as emitted

| Benchmark | Bit | Go | C |
|---|--:|--:|--:|
| fib | 408 KB | 2373 KB | 33 KB |
| mandelbrot | 408 KB | 2373 KB | 33 KB |
| collatz | 408 KB | 2373 KB | 33 KB |
| alloc | 409 KB | 2390 KB | 33 KB |
| allocflat | 409 KB | 2373 KB | 33 KB |
| allocpar | 445 KB | 2390 KB | 33 KB |
| strings | 410 KB | 2389 KB | 33 KB |
| map | 449 KB | 2390 KB | 33 KB |
| strmap | 466 KB | 2390 KB | 33 KB |
| sort | 428 KB | 2407 KB | 33 KB |
| matrix | 409 KB | 2373 KB | 33 KB |
| json | 502 KB | 3696 KB | 33 KB |

### Startup & compile

| Metric | Bit | Go | C |
|---|--:|--:|--:|
| Process startup (per exec) | 4.488 ms | 4.768 ms | 4.137 ms |

Bit compile speed: **682 lines/sec** (769 lines across 12 cases, warm).

> Machine: Apple M5 Max, macOS 27.0.1. Bit @ `079c63121`, Go go1.27.2, Apple clang version 21.0.0 (clang-2100.3.34.2).
> Method: 15 runs per case per language. Cycles and instructions are a trimmed mean of those runs, meaning the mean after dropping the slowest fifth, which was the most reproducible of four estimators measured over 40 samples per series; wall clock and RSS are the median. C built `cc -O2 -ffp-contract=off`, Go `go build`, Bit `bit build`, each language's standard optimized build.
> Mandelbrot: Bit and C agree to the last bit; Go differs by ~0.0002% because it contracts `a*b+c` to a hardware FMA. Not a bug: cross-compiler float bit-identity is not guaranteed.
> alloc measures the ALLOCATOR: 10M short-lived nodes, each its own heap object in all three languages (Bit's element class has a reference field, Go holds `[]*Node`, C mallocs per node). allocflat measures DATA LAYOUT: the same 10M nodes and the same printed total, stored by value in one buffer per batch (Bit packs `[]Node` inline, Go holds `[]Node`, C mallocs the batch once). The gap between the two rows is what per-node heap allocation costs a language.
> allocpar measures the allocator under CONTENTION: the identical 10M nodes and the identical printed total as alloc, partitioned across 8 concurrent workers (Bit `spawn`, Go goroutines, C pthreads), worker count fixed in all three sources and never read from the host core count. The gap between the alloc and allocpar rows is what a language's allocator costs when more than one thread is in it; every other case in this table is single-mutator, so that cost appears nowhere else.
> The allocation table above is how those two claims are checked rather than asserted: same order of magnitude across a row means the three sources still express the same data structure, which is exactly what `alloc` silently lost for a day. Bit's count is `swept+live` from `BIT_GC_STATS=1`; Go's is `runtime.MemStats.Mallocs` and C's a `malloc` counter, both opt-in (`BENCH_ALLOC_STATS`, `-DBENCH_ALLOC_STATS`) and both absent from every timed binary.
> The ratios are built from CYCLES, not from wall clock. `/usr/bin/time` reports `real` in hundredths of a second and most of the C sides here finish in under 0.10s, so a wall-clock ratio for those rows would be quantisation: `map` published 7.50x C off 0.300s/0.040s where the counters say ~4.5x. Adding runs does not fix that, because it narrows the spread around a quantised value instead of removing the quantisation, so the unit changed. Cycles and instructions come from the same `/usr/bin/time -l` invocation that also produced the RSS; nothing extra is run and nothing extra is installed for those three. Wall clock is a separate one-decimal-millisecond measurement (`wall_run()`, one `fork`+`exec`+`waitpid` perl process per run, not `/usr/bin/time`'s own field) so it stays usable below `/usr/bin/time`'s 10ms floor; it still carries no ratio column and is kept as context.
> GC pauses: one untimed run per case, separate from the timed runs above (BIT_GC_STATS/GODEBUG both add real overhead). Bit's fields are `pausens=`/`pausemaxns=`/`pauses=` from `BIT_GC_STATS=1`. Go's are parsed from one `GODEBUG=gctrace=1` run: each `gc N @Ts P%: A+B+C ms clock` line's A (sweep termination) and C (mark termination) are its two STW segments (`go doc runtime`, go1.27.1), summed for the STW total, maxed individually for the longest single pause; B (concurrent mark) is not a stop and is excluded. C has no collector (n/a). Share is that probe run's own `wall_run()` wall time, not the timed loop's median. `allocpar W1`/`W8` reruns the same probe with `BIT_WORKERS`/`GOMAXPROCS` set; C is unchanged (its worker count is a compile-time `#define`, never read from env) so its wall-table cell reuses the baseline `allocpar` row rather than a redundant rerun.
> Cycles and instructions are startup-corrected: each figure has that language's own empty-program cost (`bench/cases/startup`, bit 5.0M, c 4.0M, go 6.2M) subtracted, because dyld and runtime init differ per language and are a fifth of C's `allocflat` row. Every other table is raw.

> On `matrix`, read the Go column as the target and not the C one. The C side vectorises: it retires 2.06 instructions per inner-loop iteration against Go's 9.09, so the Bit:C ratio on this row compares a scalar loop against a vectorised one and is not a statement about codegen quality. A scalar `cc -O2 -fno-vectorize` control build of the same case retires 8.07, which is the like-for-like figure. Denominator for all three: `trials * n^3 = 6 * 512^3 = 805,306,368` inner iterations.
> Reproducibility was measured rather than assumed: four independent regenerations of this table on this box held every ratio to 2.5% between adjacent runs and 8.5% at worst across all four. The loose rows are `alloc`, `map`, `allocflat` and `strings`, whose Go or C side is short enough that that language's own allocator and collector scheduling moves it by several percent from run to run; `matrix`, `mandelbrot`, `fib` and `sort` reproduce to about 1%. On those four loose rows, read a change under ~3% as noise.
> Peak RSS above is a within-run median like every other figure in that table, but it can still swing further ACROSS separate regenerations than one run shows. From every regeneration recorded in `bench/history.csv`, restricted to the same four loose rows above and to the Go/C columns (the Bit column reflects real compiler/runtime changes over that history, not noise): `alloc` c: 1.5-2.2 MB (median 2.0 MB, N=61); `allocflat` go: 10.6-12.8 MB (median 11.4 MB, N=52); `allocflat` c: 1.5-1.9 MB (median 1.9 MB, N=52); `strings` go: 64.3-100.0 MB (median 70.5 MB, N=58). Read that cell's published number as representative of the stated range, not a fixed constant.
> Instructions are published beside cycles because a cycle gap alone does not say whether it is work emitted or work stalled, and the two ratios differ a lot here: Bit retires roughly 4-7 instructions per cycle against C's 1.4-1.8, so its instruction ratio always overstates its cycle ratio. Cycles are the time; instructions are the reason.
> Generated by `bench/run.sh` on 2026-10-18T17:16:35Z. Do not edit by hand.
