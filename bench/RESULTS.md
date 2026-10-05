# Benchmark results: full numbers and method

The README carries the short version. This page keeps every table and the method behind it.

### Runtime: CPU cycles, lower is better

| Benchmark | Bit | Go | C | Bit / Go | Bit / C |
|---|--:|--:|--:|--:|--:|
| fib | 1085.4 M | 943.8 M | 656.6 M | 1.15x | 1.65x |
| mandelbrot | 2172.3 M | 1680.1 M | 1652.7 M | 1.29x | 1.31x |
| collatz | 928.1 M | 635.9 M | 439.2 M | 1.46x | 2.11x |
| alloc | 749.9 M | 453.9 M | 516.5 M | 1.65x | 1.45x |
| allocflat | 228.8 M | 150.2 M | 23.1 M | 1.52x | 9.90x |
| allocpar | 3409.1 M | 1548.7 M | 1809.7 M | 2.20x | 1.88x |
| strings | 219.4 M | 366.8 M | 114.7 M | 0.60x | 1.91x |
| map | 441.8 M | 603.2 M | 182.2 M | 0.73x | 2.42x |
| strmap | 1852.0 M | 1202.3 M | 434.9 M | 1.54x | 4.26x |
| sort | 400.7 M | 400.2 M | 310.3 M | 1.00x | 1.29x |
| matrix | 1415.4 M | 960.0 M | 400.8 M | 1.47x | 3.53x |
| json | 864.7 M | 410.9 M | 257.2 M | 2.10x | 3.36x |

### Instructions retired: work emitted, not time taken

| Benchmark | Bit | Go | C |
|---|--:|--:|--:|
| fib | 5304.4 M | 5140.6 M | 3150.5 M |
| mandelbrot | 4794.5 M | 2510.6 M | 2702.4 M |
| collatz | 2581.1 M | 936.8 M | 931.4 M |
| alloc | 5407.6 M | 2144.6 M | 3608.1 M |
| allocflat | 1456.8 M | 410.0 M | 59.5 M |
| allocpar | 8336.3 M | 4578.6 M | 3610.1 M |
| strings | 1695.3 M | 1612.5 M | 644.0 M |
| map | 766.1 M | 698.6 M | 242.1 M |
| strmap | 6190.0 M | 2207.6 M | 538.3 M |
| sort | 1683.0 M | 946.3 M | 505.9 M |
| matrix | 12282.2 M | 7325.7 M | 1657.1 M |
| json | 5028.6 M | 2166.1 M | 1343.5 M |

### Wall clock: median of 15 runs, milliseconds

| Benchmark | Bit | Go | C |
|---|--:|--:|--:|
| fib | 420.6 ms | 367.9 ms | 262.1 ms |
| mandelbrot | 801.1 ms | 622.3 ms | 612.2 ms |
| collatz | 337.8 ms | 233.2 ms | 163.5 ms |
| alloc | 308.2 ms | 142.2 ms | 212.0 ms |
| allocflat | 86.2 ms | 34.4 ms | 10.3 ms |
| allocpar | 178.3 ms | 128.8 ms | 98.5 ms |
| strings | 87.7 ms | 103.7 ms | 46.1 ms |
| map | 189.8 ms | 267.8 ms | 82.3 ms |
| strmap | 1232.3 ms | 681.3 ms | 200.9 ms |
| sort | 172.4 ms | 181.2 ms | 130.5 ms |
| matrix | 484.5 ms | 336.5 ms | 142.2 ms |
| json | 351.8 ms | 172.0 ms | 125.8 ms |
| allocpar W1 | 338.0 ms | 183.7 ms | 98.5 ms |
| allocpar W8 | 135.6 ms | 124.0 ms | 98.5 ms |

### GC pauses: one untimed run per case, share of that run's own wall clock

| Benchmark | Bit pauses | Bit pausens ms (share) | Bit pausemax ms | Go GCs | Go STW ms (share) | Go STW max ms | C |
|---|--:|--:|--:|--:|--:|--:|--:|
| fib | 0 | 0.0 ms (0.0%) | 0.0 ms | 0 | 0.0 ms (0.0%) | 0.0 ms | n/a |
| mandelbrot | 0 | 0.0 ms (0.0%) | 0.0 ms | 0 | 0.0 ms (0.0%) | 0.0 ms | n/a |
| collatz | 0 | 0.0 ms (0.0%) | 0.0 ms | 0 | 0.0 ms (0.0%) | 0.0 ms | n/a |
| alloc | 133 | 31.8 ms (11.9%) | 0.3 ms | 69 | 2.4 ms (2.1%) | 0.1 ms | n/a |
| allocflat | 66 | 4.7 ms (5.6%) | 0.2 ms | 71 | 2.4 ms (8.0%) | 0.1 ms | n/a |
| allocpar | 172 | 111.8 ms (69.5%) | 4.0 ms | 84 | 19.7 ms (17.6%) | 1.0 ms | n/a |
| strings | 3 | 0.4 ms (0.5%) | 0.2 ms | 9 | 0.4 ms (0.4%) | 0.1 ms | n/a |
| map | 1 | 0.1 ms (0.1%) | 0.1 ms | 4 | 0.5 ms (0.2%) | 0.2 ms | n/a |
| strmap | 4 | 15.6 ms (1.6%) | 11.9 ms | 2 | 0.1 ms (0.0%) | 0.1 ms | n/a |
| sort | 7 | 31.0 ms (15.8%) | 10.7 ms | 1 | 0.2 ms (0.1%) | 0.1 ms | n/a |
| matrix | 1 | 0.0 ms (0.0%) | 0.0 ms | 1 | 0.1 ms (0.0%) | 0.1 ms | n/a |
| json | 19 | 218.3 ms (25.3%) | 197.9 ms | 10 | 2.4 ms (1.2%) | 0.6 ms | n/a |
| allocpar W1 | 158 | 72.8 ms (24.2%) | 0.7 ms | 81 | 0.1 ms (0.1%) | 0.0 ms | n/a |
| allocpar W8 | 175 | 71.0 ms (52.2%) | 2.5 ms | 89 | 18.4 ms (14.6%) | 0.3 ms | n/a |

### Peak memory: max RSS, lower is better

| Benchmark | Bit | Go | C |
|---|--:|--:|--:|
| fib | 2.2 MB | 4.6 MB | 1.8 MB |
| mandelbrot | 2.2 MB | 4.6 MB | 1.8 MB |
| collatz | 2.2 MB | 4.6 MB | 1.8 MB |
| alloc | 6.6 MB | 11.3 MB | 2.2 MB |
| allocflat | 6.1 MB | 11.3 MB | 1.9 MB |
| allocpar | 11.1 MB | 16.5 MB | 4.0 MB |
| strings | 78.9 MB | 100.0 MB | 31.0 MB |
| map | 36.9 MB | 42.0 MB | 193.8 MB |
| strmap | 36.1 MB | 31.0 MB | 41.2 MB |
| sort | 18.1 MB | 15.2 MB | 11.4 MB |
| matrix | 8.6 MB | 11.4 MB | 7.8 MB |
| json | 129.0 MB | 60.8 MB | 125.6 MB |

### Heap allocations per run: the equivalence check, not a score

| Benchmark | Bit | Go | C |
|---|--:|--:|--:|
| fib | 2 | 205 | 0 |
| mandelbrot | 2 | 199 | 0 |
| collatz | 2 | 199 | 0 |
| alloc | 10006002 | 10002311 | 10004000 |
| allocflat | 4002 | 2312 | 2000 |
| allocpar | 10006015 | 10002436 | 10004000 |
| strings | 33 | 341 | 11 |
| map | 10 | 4382 | 1 |
| strmap | 400037 | 400801 | 400003 |
| sort | 600018 | 150290 | 150002 |
| matrix | 12 | 282 | 3 |
| json | 3750060 | 1049991 | 2250021 |

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
| Process startup (per exec) | 5.005 ms | 5.460 ms | 4.154 ms |

Bit compile speed: **308 lines/sec** (769 lines across 12 cases, warm).

> Machine: Apple M5 Max, macOS 27.0.1. Bit @ `b61b69170`, Go go1.27.1, Apple clang version 21.0.0 (clang-2100.3.34.2).
> Method: 15 runs per case per language. Cycles and instructions are a trimmed mean of those runs, meaning the mean after dropping the slowest fifth, which was the most reproducible of four estimators measured over 40 samples per series; wall clock and RSS are the median. C built `cc -O2 -ffp-contract=off`, Go `go build`, Bit `bit build`, each language's standard optimized build.
> Mandelbrot: Bit and C agree to the last bit; Go differs by ~0.0002% because it contracts `a*b+c` to a hardware FMA. Not a bug: cross-compiler float bit-identity is not guaranteed.
> alloc measures the ALLOCATOR: 10M short-lived nodes, each its own heap object in all three languages (Bit's element class has a reference field, Go holds `[]*Node`, C mallocs per node). allocflat measures DATA LAYOUT: the same 10M nodes and the same printed total, stored by value in one buffer per batch (Bit packs `[]Node` inline, Go holds `[]Node`, C mallocs the batch once). The gap between the two rows is what per-node heap allocation costs a language.
> allocpar measures the allocator under CONTENTION: the identical 10M nodes and the identical printed total as alloc, partitioned across 8 concurrent workers (Bit `spawn`, Go goroutines, C pthreads), worker count fixed in all three sources and never read from the host core count. The gap between the alloc and allocpar rows is what a language's allocator costs when more than one thread is in it; every other case in this table is single-mutator, so that cost appears nowhere else.
> The allocation table above is how those two claims are checked rather than asserted: same order of magnitude across a row means the three sources still express the same data structure, which is exactly what `alloc` silently lost for a day. Bit's count is `swept+live` from `BIT_GC_STATS=1`; Go's is `runtime.MemStats.Mallocs` and C's a `malloc` counter, both opt-in (`BENCH_ALLOC_STATS`, `-DBENCH_ALLOC_STATS`) and both absent from every timed binary.
> The ratios are built from CYCLES, not from wall clock. `/usr/bin/time` reports `real` in hundredths of a second and most of the C sides here finish in under 0.10s, so a wall-clock ratio for those rows would be quantisation: `map` published 7.50x C off 0.300s/0.040s where the counters say ~4.5x. Adding runs does not fix that, because it narrows the spread around a quantised value instead of removing the quantisation, so the unit changed. Cycles and instructions come from the same `/usr/bin/time -l` invocation that also produced the RSS; nothing extra is run and nothing extra is installed for those three. Wall clock is a separate one-decimal-millisecond measurement (`wall_run()`, one `fork`+`exec`+`waitpid` perl process per run, not `/usr/bin/time`'s own field) so it stays usable below `/usr/bin/time`'s 10ms floor; it still carries no ratio column and is kept as context.
> GC pauses: one untimed run per case, separate from the timed runs above (BIT_GC_STATS/GODEBUG both add real overhead). Bit's fields are `pausens=`/`pausemaxns=`/`pauses=` from `BIT_GC_STATS=1`. Go's are parsed from one `GODEBUG=gctrace=1` run: each `gc N @Ts P%: A+B+C ms clock` line's A (sweep termination) and C (mark termination) are its two STW segments (`go doc runtime`, go1.27.1), summed for the STW total, maxed individually for the longest single pause; B (concurrent mark) is not a stop and is excluded. C has no collector (n/a). Share is that probe run's own `wall_run()` wall time, not the timed loop's median. `allocpar W1`/`W8` reruns the same probe with `BIT_WORKERS`/`GOMAXPROCS` set; C is unchanged (its worker count is a compile-time `#define`, never read from env) so its wall-table cell reuses the baseline `allocpar` row rather than a redundant rerun.
> Cycles and instructions are startup-corrected: each figure has that language's own empty-program cost (`bench/cases/startup`, bit 5.1M, c 4.2M, go 7.0M) subtracted, because dyld and runtime init differ per language and are a fifth of C's `allocflat` row. Every other table is raw.

> On `matrix`, read the Go column as the target and not the C one. The C side vectorises: it retires 2.06 instructions per inner-loop iteration against Go's 9.09, so the Bit:C ratio on this row compares a scalar loop against a vectorised one and is not a statement about codegen quality. A scalar `cc -O2 -fno-vectorize` control build of the same case retires 8.07, which is the like-for-like figure. Denominator for all three: `trials * n^3 = 6 * 512^3 = 805,306,368` inner iterations.
> Reproducibility was measured rather than assumed: four independent regenerations of this table on this box held every ratio to 2.5% between adjacent runs and 8.5% at worst across all four. The loose rows are `alloc`, `map`, `allocflat` and `strings`, whose Go or C side is short enough that that language's own allocator and collector scheduling moves it by several percent from run to run; `matrix`, `mandelbrot`, `fib` and `sort` reproduce to about 1%. On those four loose rows, read a change under ~3% as noise.
> Peak RSS above is a within-run median like every other figure in that table, but it can still swing further ACROSS separate regenerations than one run shows. From every regeneration recorded in `bench/history.csv`, restricted to the same four loose rows above and to the Go/C columns (the Bit column reflects real compiler/runtime changes over that history, not noise): `alloc` c: 1.5-2.2 MB (median 2.0 MB, N=50); `allocflat` go: 10.6-12.0 MB (median 11.4 MB, N=41); `allocflat` c: 1.5-1.9 MB (median 1.9 MB, N=41); `strings` go: 64.3-100.0 MB (median 81.1 MB, N=47). Read that cell's published number as representative of the stated range, not a fixed constant.
> Instructions are published beside cycles because a cycle gap alone does not say whether it is work emitted or work stalled, and the two ratios differ a lot here: Bit retires roughly 4-7 instructions per cycle against C's 1.4-1.8, so its instruction ratio always overstates its cycle ratio. Cycles are the time; instructions are the reason.
> Generated by `bench/run.sh` on 2026-10-05T08:28:47Z. Do not edit by hand.
