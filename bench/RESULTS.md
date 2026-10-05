# Benchmark results: full numbers and method

The README carries the short version. This page keeps every table and the method behind it.

### Runtime: CPU cycles, lower is better

| Benchmark | Bit | Go | C | Bit / Go | Bit / C |
|---|--:|--:|--:|--:|--:|
| fib | 1013.9 M | 931.5 M | 633.9 M | 1.09x | 1.60x |
| mandelbrot | 2139.4 M | 1642.2 M | 1608.6 M | 1.30x | 1.33x |
| collatz | 918.1 M | 627.4 M | 412.2 M | 1.46x | 2.23x |
| alloc | 699.9 M | 402.0 M | 462.3 M | 1.74x | 1.51x |
| allocflat | 215.3 M | 139.4 M | 18.4 M | 1.54x | 11.71x |
| allocpar | 2279.8 M | 1412.7 M | 1972.5 M | 1.61x | 1.16x |
| strings | 216.3 M | 390.9 M | 110.2 M | 0.55x | 1.96x |
| map | 345.0 M | 430.5 M | 181.2 M | 0.80x | 1.90x |
| strmap | 1281.7 M | 680.7 M | 257.5 M | 1.88x | 4.98x |
| sort | 283.0 M | 358.5 M | 277.1 M | 0.79x | 1.02x |
| matrix | 1393.0 M | 956.5 M | 400.2 M | 1.46x | 3.48x |
| json | 748.1 M | 346.8 M | 233.0 M | 2.16x | 3.21x |

### Instructions retired: work emitted, not time taken

| Benchmark | Bit | Go | C |
|---|--:|--:|--:|
| fib | 5300.6 M | 5137.1 M | 3146.8 M |
| mandelbrot | 4787.2 M | 2506.8 M | 2698.9 M |
| collatz | 2579.1 M | 935.6 M | 930.6 M |
| alloc | 5396.2 M | 2166.9 M | 3606.9 M |
| allocflat | 1456.2 M | 414.8 M | 59.3 M |
| allocpar | 7627.0 M | 4592.5 M | 3606.9 M |
| strings | 1693.8 M | 1741.8 M | 643.4 M |
| map | 763.1 M | 694.0 M | 229.3 M |
| strmap | 6181.8 M | 2225.1 M | 534.3 M |
| sort | 1664.7 M | 943.3 M | 503.7 M |
| matrix | 12278.5 M | 7324.1 M | 1656.3 M |
| json | 4991.5 M | 2141.7 M | 1340.1 M |

### Wall clock: median of 15 runs, milliseconds

| Benchmark | Bit | Go | C |
|---|--:|--:|--:|
| fib | 271.3 ms | 259.8 ms | 175.2 ms |
| mandelbrot | 505.4 ms | 392.3 ms | 380.2 ms |
| collatz | 218.7 ms | 149.8 ms | 98.5 ms |
| alloc | 168.8 ms | 84.8 ms | 115.4 ms |
| allocflat | 54.6 ms | 20.7 ms | 6.6 ms |
| allocpar | 95.8 ms | 75.0 ms | 66.4 ms |
| strings | 55.9 ms | 62.9 ms | 28.8 ms |
| map | 85.8 ms | 105.5 ms | 48.1 ms |
| strmap | 295.5 ms | 164.6 ms | 63.9 ms |
| sort | 66.2 ms | 87.4 ms | 67.4 ms |
| matrix | 332.5 ms | 231.7 ms | 96.7 ms |
| json | 150.7 ms | 76.4 ms | 57.8 ms |
| allocpar W1 | 201.7 ms | 111.7 ms | 66.4 ms |
| allocpar W8 | 74.9 ms | 69.4 ms | 66.4 ms |

### GC pauses: one untimed run per case, share of that run's own wall clock

| Benchmark | Bit pauses | Bit pausens ms (share) | Bit pausemax ms | Go GCs | Go STW ms (share) | Go STW max ms | C |
|---|--:|--:|--:|--:|--:|--:|--:|
| fib | 0 | 0.0 ms (0.0%) | 0.0 ms | 0 | 0.0 ms (0.0%) | 0.0 ms | n/a |
| mandelbrot | 0 | 0.0 ms (0.0%) | 0.0 ms | 0 | 0.0 ms (0.0%) | 0.0 ms | n/a |
| collatz | 0 | 0.0 ms (0.0%) | 0.0 ms | 0 | 0.0 ms (0.0%) | 0.0 ms | n/a |
| alloc | 133 | 20.0 ms (12.0%) | 0.3 ms | 69 | 2.0 ms (2.4%) | 0.0 ms | n/a |
| allocflat | 66 | 2.6 ms (4.9%) | 0.1 ms | 79 | 2.5 ms (12.4%) | 0.0 ms | n/a |
| allocpar | 168 | 47.2 ms (59.6%) | 0.7 ms | 71 | 8.2 ms (12.0%) | 0.2 ms | n/a |
| strings | 3 | 0.4 ms (0.7%) | 0.3 ms | 12 | 0.3 ms (0.5%) | 0.1 ms | n/a |
| map | 1 | 0.0 ms (0.0%) | 0.0 ms | 4 | 0.2 ms (0.2%) | 0.1 ms | n/a |
| strmap | 4 | 6.6 ms (2.3%) | 4.7 ms | 3 | 0.1 ms (0.1%) | 0.0 ms | n/a |
| sort | 7 | 6.1 ms (9.2%) | 1.7 ms | 1 | 0.1 ms (0.1%) | 0.0 ms | n/a |
| matrix | 1 | 0.0 ms (0.0%) | 0.0 ms | 1 | 0.0 ms (0.0%) | 0.0 ms | n/a |
| json | 19 | 10.9 ms (7.3%) | 7.2 ms | 10 | 0.3 ms (0.4%) | 0.0 ms | n/a |
| allocpar W1 | 155 | 47.6 ms (23.4%) | 0.5 ms | 77 | 0.0 ms (0.0%) | 0.0 ms | n/a |
| allocpar W8 | 174 | 43.5 ms (62.3%) | 0.4 ms | 81 | 7.6 ms (11.0%) | 0.1 ms | n/a |

### Peak memory: max RSS, lower is better

| Benchmark | Bit | Go | C |
|---|--:|--:|--:|
| fib | 2.2 MB | 4.6 MB | 1.8 MB |
| mandelbrot | 2.2 MB | 4.7 MB | 1.8 MB |
| collatz | 2.2 MB | 4.6 MB | 1.8 MB |
| alloc | 6.6 MB | 10.9 MB | 2.0 MB |
| allocflat | 6.1 MB | 11.5 MB | 1.9 MB |
| allocpar | 11.0 MB | 17.4 MB | 4.0 MB |
| strings | 78.9 MB | 68.6 MB | 31.0 MB |
| map | 36.9 MB | 41.9 MB | 193.8 MB |
| strmap | 35.8 MB | 31.2 MB | 41.2 MB |
| sort | 18.0 MB | 15.2 MB | 11.4 MB |
| matrix | 8.6 MB | 11.4 MB | 7.8 MB |
| json | 128.9 MB | 56.2 MB | 125.5 MB |

### Heap allocations per run: the equivalence check, not a score

| Benchmark | Bit | Go | C |
|---|--:|--:|--:|
| fib | 2 | 199 | 0 |
| mandelbrot | 2 | 199 | 0 |
| collatz | 2 | 199 | 0 |
| alloc | 10006002 | 10002332 | 10004000 |
| allocflat | 4002 | 2308 | 2000 |
| allocpar | 10006015 | 10002416 | 10004000 |
| strings | 33 | 347 | 11 |
| map | 10 | 4376 | 1 |
| strmap | 400037 | 400813 | 400003 |
| sort | 600018 | 150283 | 150002 |
| matrix | 12 | 282 | 3 |
| json | 3750060 | 1049999 | 2250021 |

### Binary size: static, as emitted

| Benchmark | Bit | Go | C |
|---|--:|--:|--:|
| fib | 352 KB | 2373 KB | 33 KB |
| mandelbrot | 352 KB | 2373 KB | 33 KB |
| collatz | 352 KB | 2373 KB | 33 KB |
| alloc | 369 KB | 2390 KB | 33 KB |
| allocflat | 369 KB | 2373 KB | 33 KB |
| allocpar | 373 KB | 2390 KB | 33 KB |
| strings | 370 KB | 2389 KB | 33 KB |
| map | 407 KB | 2390 KB | 33 KB |
| strmap | 409 KB | 2390 KB | 33 KB |
| sort | 371 KB | 2407 KB | 33 KB |
| matrix | 369 KB | 2373 KB | 33 KB |
| json | 462 KB | 3679 KB | 33 KB |

### Startup & compile

| Metric | Bit | Go | C |
|---|--:|--:|--:|
| Process startup (per exec) | 3.718 ms | 4.061 ms | 3.555 ms |

Bit compile speed: **567 lines/sec** (769 lines across 12 cases, warm).

> Machine: Apple M5 Max, macOS 27.0.1. Bit @ `12dba4297`, Go go1.27.1, Apple clang version 21.0.0 (clang-2100.3.34.2).
> Method: 15 runs per case per language. Cycles and instructions are a trimmed mean of those runs, meaning the mean after dropping the slowest fifth, which was the most reproducible of four estimators measured over 40 samples per series; wall clock and RSS are the median. C built `cc -O2 -ffp-contract=off`, Go `go build`, Bit `bit build`, each language's standard optimized build.
> Mandelbrot: Bit and C agree to the last bit; Go differs by ~0.0002% because it contracts `a*b+c` to a hardware FMA. Not a bug: cross-compiler float bit-identity is not guaranteed.
> alloc measures the ALLOCATOR: 10M short-lived nodes, each its own heap object in all three languages (Bit's element class has a reference field, Go holds `[]*Node`, C mallocs per node). allocflat measures DATA LAYOUT: the same 10M nodes and the same printed total, stored by value in one buffer per batch (Bit packs `[]Node` inline, Go holds `[]Node`, C mallocs the batch once). The gap between the two rows is what per-node heap allocation costs a language.
> allocpar measures the allocator under CONTENTION: the identical 10M nodes and the identical printed total as alloc, partitioned across 8 concurrent workers (Bit `spawn`, Go goroutines, C pthreads), worker count fixed in all three sources and never read from the host core count. The gap between the alloc and allocpar rows is what a language's allocator costs when more than one thread is in it; every other case in this table is single-mutator, so that cost appears nowhere else.
> The allocation table above is how those two claims are checked rather than asserted: same order of magnitude across a row means the three sources still express the same data structure, which is exactly what `alloc` silently lost for a day. Bit's count is `swept+live` from `BIT_GC_STATS=1`; Go's is `runtime.MemStats.Mallocs` and C's a `malloc` counter, both opt-in (`BENCH_ALLOC_STATS`, `-DBENCH_ALLOC_STATS`) and both absent from every timed binary.
> The ratios are built from CYCLES, not from wall clock. `/usr/bin/time` reports `real` in hundredths of a second and most of the C sides here finish in under 0.10s, so a wall-clock ratio for those rows would be quantisation: `map` published 7.50x C off 0.300s/0.040s where the counters say ~4.5x. Adding runs does not fix that, because it narrows the spread around a quantised value instead of removing the quantisation, so the unit changed. Cycles and instructions come from the same `/usr/bin/time -l` invocation that also produced the RSS; nothing extra is run and nothing extra is installed for those three. Wall clock is a separate one-decimal-millisecond measurement (`wall_run()`, one `fork`+`exec`+`waitpid` perl process per run, not `/usr/bin/time`'s own field) so it stays usable below `/usr/bin/time`'s 10ms floor; it still carries no ratio column and is kept as context.
> GC pauses: one untimed run per case, separate from the timed runs above (BIT_GC_STATS/GODEBUG both add real overhead). Bit's fields are `pausens=`/`pausemaxns=`/`pauses=` from `BIT_GC_STATS=1`. Go's are parsed from one `GODEBUG=gctrace=1` run: each `gc N @Ts P%: A+B+C ms clock` line's A (sweep termination) and C (mark termination) are its two STW segments (`go doc runtime`, go1.27.1), summed for the STW total, maxed individually for the longest single pause; B (concurrent mark) is not a stop and is excluded. C has no collector (n/a). Share is that probe run's own `wall_run()` wall time, not the timed loop's median. `allocpar W1`/`W8` reruns the same probe with `BIT_WORKERS`/`GOMAXPROCS` set; C is unchanged (its worker count is a compile-time `#define`, never read from env) so its wall-table cell reuses the baseline `allocpar` row rather than a redundant rerun.
> Cycles and instructions are startup-corrected: each figure has that language's own empty-program cost (`bench/cases/startup`, bit 4.9M, c 3.9M, go 5.9M) subtracted, because dyld and runtime init differ per language and are a fifth of C's `allocflat` row. Every other table is raw.

> On `matrix`, read the Go column as the target and not the C one. The C side vectorises: it retires 2.06 instructions per inner-loop iteration against Go's 9.09, so the Bit:C ratio on this row compares a scalar loop against a vectorised one and is not a statement about codegen quality. A scalar `cc -O2 -fno-vectorize` control build of the same case retires 8.07, which is the like-for-like figure. Denominator for all three: `trials * n^3 = 6 * 512^3 = 805,306,368` inner iterations.
> Reproducibility was measured rather than assumed: four independent regenerations of this table on this box held every ratio to 2.5% between adjacent runs and 8.5% at worst across all four. The loose rows are `alloc`, `map`, `allocflat` and `strings`, whose Go or C side is short enough that that language's own allocator and collector scheduling moves it by several percent from run to run; `matrix`, `mandelbrot`, `fib` and `sort` reproduce to about 1%. On those four loose rows, read a change under ~3% as noise.
> Peak RSS above is a within-run median like every other figure in that table, but it can still swing further ACROSS separate regenerations than one run shows. From every regeneration recorded in `bench/history.csv`, restricted to the same four loose rows above and to the Go/C columns (the Bit column reflects real compiler/runtime changes over that history, not noise): `alloc` c: 1.5-2.2 MB (median 2.0 MB, N=51); `allocflat` go: 10.6-12.0 MB (median 11.4 MB, N=42); `allocflat` c: 1.5-1.9 MB (median 1.9 MB, N=42); `strings` go: 64.3-100.0 MB (median 78.4 MB, N=48). Read that cell's published number as representative of the stated range, not a fixed constant.
> Instructions are published beside cycles because a cycle gap alone does not say whether it is work emitted or work stalled, and the two ratios differ a lot here: Bit retires roughly 4-7 instructions per cycle against C's 1.4-1.8, so its instruction ratio always overstates its cycle ratio. Cycles are the time; instructions are the reason.
> Generated by `bench/run.sh` on 2026-10-05T13:33:13Z. Do not edit by hand.
