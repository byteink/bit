# Benchmark results: full numbers and method

The README carries the short version. This page keeps every table and the method behind it.

### Runtime: CPU cycles, lower is better

| Benchmark | Bit | Go | C | Bit / Go | Bit / C |
|---|--:|--:|--:|--:|--:|
| fib | 1057.5 M | 954.7 M | 646.0 M | 1.11x | 1.64x |
| mandelbrot | 2143.2 M | 1647.5 M | 1616.6 M | 1.30x | 1.33x |
| collatz | 924.3 M | 628.0 M | 415.3 M | 1.47x | 2.23x |
| alloc | 650.5 M | 474.0 M | 475.5 M | 1.37x | 1.37x |
| allocflat | 158.7 M | 172.0 M | 18.1 M | 0.92x | 8.79x |
| allocpar | 2741.7 M | 1646.4 M | 1920.5 M | 1.67x | 1.43x |
| strings | 215.8 M | 377.4 M | 108.4 M | 0.57x | 1.99x |
| map | 361.8 M | 446.2 M | 179.5 M | 0.81x | 2.02x |
| strmap | 1232.5 M | 689.4 M | 280.4 M | 1.79x | 4.40x |
| sort | 296.3 M | 357.9 M | 270.9 M | 0.83x | 1.09x |
| matrix | 1402.5 M | 961.4 M | 401.2 M | 1.46x | 3.50x |
| json | 771.0 M | 384.5 M | 229.7 M | 2.01x | 3.36x |

### Instructions retired: work emitted, not time taken

| Benchmark | Bit | Go | C |
|---|--:|--:|--:|
| fib | 5302.4 M | 5139.9 M | 3147.8 M |
| mandelbrot | 4789.5 M | 2507.9 M | 2700.5 M |
| collatz | 2579.9 M | 935.9 M | 930.9 M |
| alloc | 5154.1 M | 2178.9 M | 3607.0 M |
| allocflat | 1299.2 M | 423.6 M | 59.3 M |
| allocpar | 8459.9 M | 4582.9 M | 3608.7 M |
| strings | 1695.2 M | 1702.8 M | 643.4 M |
| map | 753.0 M | 694.8 M | 231.3 M |
| strmap | 5594.9 M | 2214.9 M | 534.5 M |
| sort | 1658.7 M | 943.0 M | 503.6 M |
| matrix | 12278.5 M | 7324.1 M | 1656.2 M |
| json | 4891.3 M | 2166.7 M | 1340.1 M |

### Wall clock: median of 15 runs, milliseconds

| Benchmark | Bit | Go | C |
|---|--:|--:|--:|
| fib | 257.9 ms | 232.8 ms | 158.9 ms |
| mandelbrot | 514.8 ms | 394.9 ms | 389.1 ms |
| collatz | 223.2 ms | 153.6 ms | 103.3 ms |
| alloc | 162.6 ms | 91.4 ms | 122.5 ms |
| allocflat | 42.2 ms | 25.6 ms | 6.5 ms |
| allocpar | 84.7 ms | 92.3 ms | 62.0 ms |
| strings | 55.8 ms | 64.8 ms | 28.6 ms |
| map | 90.0 ms | 111.9 ms | 47.3 ms |
| strmap | 293.2 ms | 171.6 ms | 72.8 ms |
| sort | 71.4 ms | 88.4 ms | 66.4 ms |
| matrix | 357.6 ms | 249.7 ms | 104.6 ms |
| json | 152.8 ms | 84.1 ms | 59.8 ms |
| allocpar W1 | 203.1 ms | 118.7 ms | 62.0 ms |
| allocpar W8 | 66.5 ms | 90.6 ms | 62.0 ms |

### GC pauses: one untimed run per case, share of that run's own wall clock

| Benchmark | Bit pauses | Bit pausens ms (share) | Bit pausemax ms | Go GCs | Go STW ms (share) | Go STW max ms | C |
|---|--:|--:|--:|--:|--:|--:|--:|
| fib | 0 | 0.0 ms (0.0%) | 0.0 ms | 0 | 0.0 ms (0.0%) | 0.0 ms | n/a |
| mandelbrot | 0 | 0.0 ms (0.0%) | 0.0 ms | 0 | 0.0 ms (0.0%) | 0.0 ms | n/a |
| collatz | 0 | 0.0 ms (0.0%) | 0.0 ms | 0 | 0.0 ms (0.0%) | 0.0 ms | n/a |
| alloc | 133 | 19.7 ms (11.5%) | 0.3 ms | 69 | 3.6 ms (3.6%) | 0.2 ms | n/a |
| allocflat | 66 | 0.2 ms (0.5%) | 0.0 ms | 80 | 4.3 ms (13.2%) | 0.1 ms | n/a |
| allocpar | 173 | 72.3 ms (67.8%) | 10.2 ms | 78 | 10.7 ms (11.7%) | 0.2 ms | n/a |
| strings | 3 | 0.4 ms (0.7%) | 0.2 ms | 14 | 0.4 ms (0.6%) | 0.0 ms | n/a |
| map | 1 | 0.0 ms (0.0%) | 0.0 ms | 4 | 0.2 ms (0.2%) | 0.0 ms | n/a |
| strmap | 4 | 5.3 ms (1.8%) | 4.6 ms | 2 | 0.1 ms (0.1%) | 0.1 ms | n/a |
| sort | 7 | 7.6 ms (11.4%) | 3.4 ms | 1 | 0.1 ms (0.1%) | 0.1 ms | n/a |
| matrix | 1 | 0.0 ms (0.0%) | 0.0 ms | 1 | 0.1 ms (0.0%) | 0.1 ms | n/a |
| json | 19 | 13.5 ms (8.6%) | 8.5 ms | 10 | 0.5 ms (0.6%) | 0.1 ms | n/a |
| allocpar W1 | 158 | 52.5 ms (25.8%) | 0.5 ms | 77 | 0.1 ms (0.1%) | 0.0 ms | n/a |
| allocpar W8 | 177 | 41.1 ms (62.5%) | 0.4 ms | 83 | 10.9 ms (11.8%) | 0.2 ms | n/a |

### Peak memory: max RSS, lower is better

| Benchmark | Bit | Go | C |
|---|--:|--:|--:|
| fib | 2.2 MB | 4.6 MB | 1.8 MB |
| mandelbrot | 2.2 MB | 4.5 MB | 1.8 MB |
| collatz | 2.2 MB | 4.5 MB | 1.8 MB |
| alloc | 6.6 MB | 11.2 MB | 2.0 MB |
| allocflat | 6.1 MB | 12.8 MB | 1.9 MB |
| allocpar | 10.5 MB | 17.6 MB | 4.0 MB |
| strings | 62.9 MB | 69.5 MB | 31.0 MB |
| map | 36.8 MB | 42.0 MB | 193.8 MB |
| strmap | 35.8 MB | 31.2 MB | 41.2 MB |
| sort | 18.0 MB | 15.2 MB | 11.4 MB |
| matrix | 8.5 MB | 11.4 MB | 7.8 MB |
| json | 129.6 MB | 60.9 MB | 125.5 MB |

### Heap allocations per run: the equivalence check, not a score

| Benchmark | Bit | Go | C |
|---|--:|--:|--:|
| fib | 2 | 198 | 0 |
| mandelbrot | 2 | 198 | 0 |
| collatz | 2 | 198 | 0 |
| alloc | 10006002 | 10002322 | 10004000 |
| allocflat | 4002 | 2360 | 2000 |
| allocpar | 10006015 | 10002439 | 10004000 |
| strings | 33 | 348 | 11 |
| map | 10 | 4383 | 1 |
| strmap | 400037 | 400812 | 400003 |
| sort | 600018 | 150288 | 150002 |
| matrix | 12 | 281 | 3 |
| json | 3750060 | 1050019 | 2250021 |

### Binary size: static, as emitted

| Benchmark | Bit | Go | C |
|---|--:|--:|--:|
| fib | 372 KB | 2373 KB | 33 KB |
| mandelbrot | 372 KB | 2373 KB | 33 KB |
| collatz | 372 KB | 2373 KB | 33 KB |
| alloc | 373 KB | 2390 KB | 33 KB |
| allocflat | 373 KB | 2373 KB | 33 KB |
| allocpar | 409 KB | 2390 KB | 33 KB |
| strings | 390 KB | 2389 KB | 33 KB |
| map | 411 KB | 2390 KB | 33 KB |
| strmap | 429 KB | 2390 KB | 33 KB |
| sort | 407 KB | 2407 KB | 33 KB |
| matrix | 373 KB | 2373 KB | 33 KB |
| json | 482 KB | 3679 KB | 33 KB |

### Startup & compile

| Metric | Bit | Go | C |
|---|--:|--:|--:|
| Process startup (per exec) | 3.579 ms | 4.125 ms | 3.223 ms |

Bit compile speed: **749 lines/sec** (769 lines across 12 cases, warm).

> Machine: Apple M5 Max, macOS 27.0.1. Bit @ `8015c4e2f`, Go go1.27.1, Apple clang version 21.0.0 (clang-2100.3.34.2).
> Method: 15 runs per case per language. Cycles and instructions are a trimmed mean of those runs, meaning the mean after dropping the slowest fifth, which was the most reproducible of four estimators measured over 40 samples per series; wall clock and RSS are the median. C built `cc -O2 -ffp-contract=off`, Go `go build`, Bit `bit build`, each language's standard optimized build.
> Mandelbrot: Bit and C agree to the last bit; Go differs by ~0.0002% because it contracts `a*b+c` to a hardware FMA. Not a bug: cross-compiler float bit-identity is not guaranteed.
> alloc measures the ALLOCATOR: 10M short-lived nodes, each its own heap object in all three languages (Bit's element class has a reference field, Go holds `[]*Node`, C mallocs per node). allocflat measures DATA LAYOUT: the same 10M nodes and the same printed total, stored by value in one buffer per batch (Bit packs `[]Node` inline, Go holds `[]Node`, C mallocs the batch once). The gap between the two rows is what per-node heap allocation costs a language.
> allocpar measures the allocator under CONTENTION: the identical 10M nodes and the identical printed total as alloc, partitioned across 8 concurrent workers (Bit `spawn`, Go goroutines, C pthreads), worker count fixed in all three sources and never read from the host core count. The gap between the alloc and allocpar rows is what a language's allocator costs when more than one thread is in it; every other case in this table is single-mutator, so that cost appears nowhere else.
> The allocation table above is how those two claims are checked rather than asserted: same order of magnitude across a row means the three sources still express the same data structure, which is exactly what `alloc` silently lost for a day. Bit's count is `swept+live` from `BIT_GC_STATS=1`; Go's is `runtime.MemStats.Mallocs` and C's a `malloc` counter, both opt-in (`BENCH_ALLOC_STATS`, `-DBENCH_ALLOC_STATS`) and both absent from every timed binary.
> The ratios are built from CYCLES, not from wall clock. `/usr/bin/time` reports `real` in hundredths of a second and most of the C sides here finish in under 0.10s, so a wall-clock ratio for those rows would be quantisation: `map` published 7.50x C off 0.300s/0.040s where the counters say ~4.5x. Adding runs does not fix that, because it narrows the spread around a quantised value instead of removing the quantisation, so the unit changed. Cycles and instructions come from the same `/usr/bin/time -l` invocation that also produced the RSS; nothing extra is run and nothing extra is installed for those three. Wall clock is a separate one-decimal-millisecond measurement (`wall_run()`, one `fork`+`exec`+`waitpid` perl process per run, not `/usr/bin/time`'s own field) so it stays usable below `/usr/bin/time`'s 10ms floor; it still carries no ratio column and is kept as context.
> GC pauses: one untimed run per case, separate from the timed runs above (BIT_GC_STATS/GODEBUG both add real overhead). Bit's fields are `pausens=`/`pausemaxns=`/`pauses=` from `BIT_GC_STATS=1`. Go's are parsed from one `GODEBUG=gctrace=1` run: each `gc N @Ts P%: A+B+C ms clock` line's A (sweep termination) and C (mark termination) are its two STW segments (`go doc runtime`, go1.27.1), summed for the STW total, maxed individually for the longest single pause; B (concurrent mark) is not a stop and is excluded. C has no collector (n/a). Share is that probe run's own `wall_run()` wall time, not the timed loop's median. `allocpar W1`/`W8` reruns the same probe with `BIT_WORKERS`/`GOMAXPROCS` set; C is unchanged (its worker count is a compile-time `#define`, never read from env) so its wall-table cell reuses the baseline `allocpar` row rather than a redundant rerun.
> Cycles and instructions are startup-corrected: each figure has that language's own empty-program cost (`bench/cases/startup`, bit 5.4M, c 4.3M, go 6.7M) subtracted, because dyld and runtime init differ per language and are a fifth of C's `allocflat` row. Every other table is raw.

> On `matrix`, read the Go column as the target and not the C one. The C side vectorises: it retires 2.06 instructions per inner-loop iteration against Go's 9.09, so the Bit:C ratio on this row compares a scalar loop against a vectorised one and is not a statement about codegen quality. A scalar `cc -O2 -fno-vectorize` control build of the same case retires 8.07, which is the like-for-like figure. Denominator for all three: `trials * n^3 = 6 * 512^3 = 805,306,368` inner iterations.
> Reproducibility was measured rather than assumed: four independent regenerations of this table on this box held every ratio to 2.5% between adjacent runs and 8.5% at worst across all four. The loose rows are `alloc`, `map`, `allocflat` and `strings`, whose Go or C side is short enough that that language's own allocator and collector scheduling moves it by several percent from run to run; `matrix`, `mandelbrot`, `fib` and `sort` reproduce to about 1%. On those four loose rows, read a change under ~3% as noise.
> Peak RSS above is a within-run median like every other figure in that table, but it can still swing further ACROSS separate regenerations than one run shows. From every regeneration recorded in `bench/history.csv`, restricted to the same four loose rows above and to the Go/C columns (the Bit column reflects real compiler/runtime changes over that history, not noise): `alloc` c: 1.5-2.2 MB (median 2.0 MB, N=52); `allocflat` go: 10.6-12.8 MB (median 11.4 MB, N=43); `allocflat` c: 1.5-1.9 MB (median 1.9 MB, N=43); `strings` go: 64.3-100.0 MB (median 75.8 MB, N=49). Read that cell's published number as representative of the stated range, not a fixed constant.
> Instructions are published beside cycles because a cycle gap alone does not say whether it is work emitted or work stalled, and the two ratios differ a lot here: Bit retires roughly 4-7 instructions per cycle against C's 1.4-1.8, so its instruction ratio always overstates its cycle ratio. Cycles are the time; instructions are the reason.
> Generated by `bench/run.sh` on 2026-10-06T23:54:15Z. Do not edit by hand.
