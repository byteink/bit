# Benchmark results: full numbers and method

The README carries the short version. This page keeps every table and the method behind it.

### Runtime: CPU cycles, lower is better

| Benchmark | Bit | Go | C | Bit / Go | Bit / C |
|---|--:|--:|--:|--:|--:|
| fib | 985.6 M | 943.0 M | 639.5 M | 1.05x | 1.54x |
| mandelbrot | 2134.0 M | 1638.1 M | 1605.4 M | 1.30x | 1.33x |
| collatz | 921.4 M | 626.6 M | 411.4 M | 1.47x | 2.24x |
| alloc | 712.2 M | 392.3 M | 461.0 M | 1.82x | 1.54x |
| allocflat | 230.5 M | 112.6 M | 17.9 M | 2.05x | 12.86x |
| allocpar | 1899.7 M | 1246.9 M | 2155.2 M | 1.52x | 0.88x |
| strings | 215.2 M | 369.7 M | 109.2 M | 0.58x | 1.97x |
| map | 324.9 M | 397.5 M | 176.7 M | 0.82x | 1.84x |
| strmap | 1326.9 M | 677.8 M | 252.3 M | 1.96x | 5.26x |
| sort | 292.8 M | 357.6 M | 279.2 M | 0.82x | 1.05x |
| matrix | 1380.0 M | 951.8 M | 398.0 M | 1.45x | 3.47x |
| json | 808.3 M | 338.9 M | 226.6 M | 2.38x | 3.57x |

### Instructions retired: work emitted, not time taken

| Benchmark | Bit | Go | C |
|---|--:|--:|--:|
| fib | 5465.7 M | 5136.7 M | 3146.6 M |
| mandelbrot | 4788.6 M | 2506.3 M | 2698.7 M |
| collatz | 2578.8 M | 935.3 M | 930.5 M |
| alloc | 5375.4 M | 2160.1 M | 3606.8 M |
| allocflat | 1465.7 M | 401.7 M | 59.3 M |
| allocpar | 7331.5 M | 4598.2 M | 3620.9 M |
| strings | 1701.1 M | 1709.9 M | 643.3 M |
| map | 752.8 M | 693.7 M | 229.3 M |
| strmap | 6164.9 M | 2219.1 M | 534.2 M |
| sort | 1731.4 M | 943.1 M | 503.7 M |
| matrix | 12271.8 M | 7323.8 M | 1656.2 M |
| json | 5343.2 M | 2136.3 M | 1339.8 M |

### Wall clock: median of 15 runs, milliseconds

| Benchmark | Bit | Go | C |
|---|--:|--:|--:|
| fib | 234.4 ms | 220.4 ms | 148.7 ms |
| mandelbrot | 492.6 ms | 378.5 ms | 370.8 ms |
| collatz | 215.5 ms | 148.1 ms | 97.7 ms |
| alloc | 166.4 ms | 81.4 ms | 121.1 ms |
| allocflat | 55.1 ms | 19.5 ms | 6.2 ms |
| allocpar | 69.1 ms | 60.0 ms | 68.9 ms |
| strings | 52.8 ms | 59.9 ms | 27.7 ms |
| map | 78.7 ms | 93.2 ms | 45.3 ms |
| strmap | 298.7 ms | 157.1 ms | 59.6 ms |
| sort | 66.7 ms | 84.5 ms | 65.1 ms |
| matrix | 321.3 ms | 222.4 ms | 94.2 ms |
| json | 162.4 ms | 74.7 ms | 56.5 ms |
| allocpar W1 | 197.6 ms | 104.8 ms | 68.9 ms |
| allocpar W8 | 65.7 ms | 60.0 ms | 68.9 ms |

### GC pauses: one untimed run per case, share of that run's own wall clock

| Benchmark | Bit pauses | Bit pausens ms (share) | Bit pausemax ms | Go GCs | Go STW ms (share) | Go STW max ms | C |
|---|--:|--:|--:|--:|--:|--:|--:|
| fib | 0 | 0.0 ms (0.0%) | 0.0 ms | 0 | 0.0 ms (0.0%) | 0.0 ms | n/a |
| mandelbrot | 0 | 0.0 ms (0.0%) | 0.0 ms | 0 | 0.0 ms (0.0%) | 0.0 ms | n/a |
| collatz | 0 | 0.0 ms (0.0%) | 0.0 ms | 0 | 0.0 ms (0.0%) | 0.0 ms | n/a |
| alloc | 133 | 19.4 ms (12.0%) | 0.2 ms | 69 | 2.0 ms (2.5%) | 0.0 ms | n/a |
| allocflat | 66 | 3.1 ms (4.6%) | 0.2 ms | 75 | 2.2 ms (11.5%) | 0.0 ms | n/a |
| allocpar | 164 | 36.2 ms (53.6%) | 0.7 ms | 69 | 7.1 ms (11.9%) | 0.1 ms | n/a |
| strings | 3 | 0.2 ms (0.4%) | 0.1 ms | 13 | 0.4 ms (0.7%) | 0.0 ms | n/a |
| map | 1 | 0.0 ms (0.0%) | 0.0 ms | 4 | 0.1 ms (0.1%) | 0.0 ms | n/a |
| strmap | 4 | 6.6 ms (2.2%) | 4.7 ms | 2 | 0.1 ms (0.1%) | 0.0 ms | n/a |
| sort | 7 | 6.0 ms (9.1%) | 1.8 ms | 1 | 0.1 ms (0.1%) | 0.1 ms | n/a |
| matrix | 1 | 0.0 ms (0.0%) | 0.0 ms | 1 | 0.0 ms (0.0%) | 0.0 ms | n/a |
| json | 17 | 10.2 ms (6.5%) | 6.6 ms | 10 | 0.2 ms (0.3%) | 0.0 ms | n/a |
| allocpar W1 | 158 | 50.3 ms (25.4%) | 0.5 ms | 77 | 0.0 ms (0.0%) | 0.0 ms | n/a |
| allocpar W8 | 179 | 40.3 ms (62.9%) | 0.4 ms | 82 | 7.2 ms (11.9%) | 0.1 ms | n/a |

### Peak memory: max RSS, lower is better

| Benchmark | Bit | Go | C |
|---|--:|--:|--:|
| fib | 2.2 MB | 4.6 MB | 1.8 MB |
| mandelbrot | 2.2 MB | 4.6 MB | 1.8 MB |
| collatz | 2.2 MB | 4.6 MB | 1.8 MB |
| alloc | 6.6 MB | 10.9 MB | 2.0 MB |
| allocflat | 6.1 MB | 11.3 MB | 1.9 MB |
| allocpar | 11.5 MB | 18.1 MB | 3.7 MB |
| strings | 78.9 MB | 84.2 MB | 31.0 MB |
| map | 36.9 MB | 41.9 MB | 193.8 MB |
| strmap | 35.8 MB | 31.2 MB | 41.2 MB |
| sort | 18.0 MB | 15.2 MB | 11.4 MB |
| matrix | 8.5 MB | 11.4 MB | 7.8 MB |
| json | 128.9 MB | 56.2 MB | 125.5 MB |

### Heap allocations per run: the equivalence check, not a score

| Benchmark | Bit | Go | C |
|---|--:|--:|--:|
| fib | 2 | 199 | 0 |
| mandelbrot | 2 | 199 | 0 |
| collatz | 2 | 199 | 0 |
| alloc | 10006002 | 10002311 | 10004000 |
| allocflat | 4002 | 2305 | 2000 |
| allocpar | 10006015 | 10002430 | 10004000 |
| strings | 33 | 342 | 11 |
| map | 10 | 4383 | 1 |
| strmap | 400037 | 400826 | 400003 |
| sort | 600018 | 150289 | 150002 |
| matrix | 12 | 288 | 3 |
| json | 3750060 | 1049997 | 2250021 |

### Binary size: static, as emitted

| Benchmark | Bit | Go | C |
|---|--:|--:|--:|
| fib | 350 KB | 2373 KB | 33 KB |
| mandelbrot | 350 KB | 2373 KB | 33 KB |
| collatz | 350 KB | 2373 KB | 33 KB |
| alloc | 351 KB | 2390 KB | 33 KB |
| allocflat | 351 KB | 2373 KB | 33 KB |
| allocpar | 370 KB | 2390 KB | 33 KB |
| strings | 368 KB | 2389 KB | 33 KB |
| map | 389 KB | 2390 KB | 33 KB |
| strmap | 407 KB | 2390 KB | 33 KB |
| sort | 369 KB | 2407 KB | 33 KB |
| matrix | 351 KB | 2373 KB | 33 KB |
| json | 444 KB | 3679 KB | 33 KB |

### Startup & compile

| Metric | Bit | Go | C |
|---|--:|--:|--:|
| Process startup (per exec) | 3.639 ms | 4.144 ms | 2.848 ms |

Bit compile speed: **547 lines/sec** (769 lines across 12 cases, warm).

> Machine: Apple M5 Max, macOS 27.0.1. Bit @ `dc643bf8a`, Go go1.27.1, Apple clang version 21.0.0 (clang-2100.3.34.2).
> Method: 15 runs per case per language. Cycles and instructions are a trimmed mean of those runs, meaning the mean after dropping the slowest fifth, which was the most reproducible of four estimators measured over 40 samples per series; wall clock and RSS are the median. C built `cc -O2 -ffp-contract=off`, Go `go build`, Bit `bit build`, each language's standard optimized build.
> Mandelbrot: Bit and C agree to the last bit; Go differs by ~0.0002% because it contracts `a*b+c` to a hardware FMA. Not a bug: cross-compiler float bit-identity is not guaranteed.
> alloc measures the ALLOCATOR: 10M short-lived nodes, each its own heap object in all three languages (Bit's element class has a reference field, Go holds `[]*Node`, C mallocs per node). allocflat measures DATA LAYOUT: the same 10M nodes and the same printed total, stored by value in one buffer per batch (Bit packs `[]Node` inline, Go holds `[]Node`, C mallocs the batch once). The gap between the two rows is what per-node heap allocation costs a language.
> allocpar measures the allocator under CONTENTION: the identical 10M nodes and the identical printed total as alloc, partitioned across 8 concurrent workers (Bit `spawn`, Go goroutines, C pthreads), worker count fixed in all three sources and never read from the host core count. The gap between the alloc and allocpar rows is what a language's allocator costs when more than one thread is in it; every other case in this table is single-mutator, so that cost appears nowhere else.
> The allocation table above is how those two claims are checked rather than asserted: same order of magnitude across a row means the three sources still express the same data structure, which is exactly what `alloc` silently lost for a day. Bit's count is `swept+live` from `BIT_GC_STATS=1`; Go's is `runtime.MemStats.Mallocs` and C's a `malloc` counter, both opt-in (`BENCH_ALLOC_STATS`, `-DBENCH_ALLOC_STATS`) and both absent from every timed binary.
> The ratios are built from CYCLES, not from wall clock. `/usr/bin/time` reports `real` in hundredths of a second and most of the C sides here finish in under 0.10s, so a wall-clock ratio for those rows would be quantisation: `map` published 7.50x C off 0.300s/0.040s where the counters say ~4.5x. Adding runs does not fix that, because it narrows the spread around a quantised value instead of removing the quantisation, so the unit changed. Cycles and instructions come from the same `/usr/bin/time -l` invocation that also produced the RSS; nothing extra is run and nothing extra is installed for those three. Wall clock is a separate one-decimal-millisecond measurement (`wall_run()`, one `fork`+`exec`+`waitpid` perl process per run, not `/usr/bin/time`'s own field) so it stays usable below `/usr/bin/time`'s 10ms floor; it still carries no ratio column and is kept as context.
> GC pauses: one untimed run per case, separate from the timed runs above (BIT_GC_STATS/GODEBUG both add real overhead). Bit's fields are `pausens=`/`pausemaxns=`/`pauses=` from `BIT_GC_STATS=1`. Go's are parsed from one `GODEBUG=gctrace=1` run: each `gc N @Ts P%: A+B+C ms clock` line's A (sweep termination) and C (mark termination) are its two STW segments (`go doc runtime`, go1.27.1), summed for the STW total, maxed individually for the longest single pause; B (concurrent mark) is not a stop and is excluded. C has no collector (n/a). Share is that probe run's own `wall_run()` wall time, not the timed loop's median. `allocpar W1`/`W8` reruns the same probe with `BIT_WORKERS`/`GOMAXPROCS` set; C is unchanged (its worker count is a compile-time `#define`, never read from env) so its wall-table cell reuses the baseline `allocpar` row rather than a redundant rerun.
> Cycles and instructions are startup-corrected: each figure has that language's own empty-program cost (`bench/cases/startup`, bit 4.8M, c 4.0M, go 6.0M) subtracted, because dyld and runtime init differ per language and are a fifth of C's `allocflat` row. Every other table is raw.

> On `matrix`, read the Go column as the target and not the C one. The C side vectorises: it retires 2.06 instructions per inner-loop iteration against Go's 9.09, so the Bit:C ratio on this row compares a scalar loop against a vectorised one and is not a statement about codegen quality. A scalar `cc -O2 -fno-vectorize` control build of the same case retires 8.07, which is the like-for-like figure. Denominator for all three: `trials * n^3 = 6 * 512^3 = 805,306,368` inner iterations.
> Reproducibility was measured rather than assumed: four independent regenerations of this table on this box held every ratio to 2.5% between adjacent runs and 8.5% at worst across all four. The loose rows are `alloc`, `map`, `allocflat` and `strings`, whose Go or C side is short enough that that language's own allocator and collector scheduling moves it by several percent from run to run; `matrix`, `mandelbrot`, `fib` and `sort` reproduce to about 1%. On those four loose rows, read a change under ~3% as noise.
> Peak RSS above is a within-run median like every other figure in that table, but it can still swing further ACROSS separate regenerations than one run shows. From every regeneration recorded in `bench/history.csv`, restricted to the same four loose rows above and to the Go/C columns (the Bit column reflects real compiler/runtime changes over that history, not noise): `alloc` c: 1.5-2.0 MB (median 1.9 MB, N=48); `allocflat` go: 10.6-12.0 MB (median 11.4 MB, N=39); `allocflat` c: 1.5-1.9 MB (median 1.9 MB, N=39); `strings` go: 64.3-90.9 MB (median 75.8 MB, N=45). Read that cell's published number as representative of the stated range, not a fixed constant.
> Instructions are published beside cycles because a cycle gap alone does not say whether it is work emitted or work stalled, and the two ratios differ a lot here: Bit retires roughly 4-7 instructions per cycle against C's 1.4-1.8, so its instruction ratio always overstates its cycle ratio. Cycles are the time; instructions are the reason.
> Generated by `bench/run.sh` on 2026-10-03T17:27:13Z. Do not edit by hand.
