# Benchmark results: full numbers and method

The README carries the short version. This page keeps every table and the method behind it.

### Runtime: CPU cycles, lower is better

| Benchmark | Bit | Go | C | Bit / Go | Bit / C |
|---|--:|--:|--:|--:|--:|
| fib | 1012.4 M | 948.6 M | 633.6 M | 1.07x | 1.60x |
| mandelbrot | 2138.4 M | 1642.4 M | 1609.0 M | 1.30x | 1.33x |
| collatz | 918.8 M | 618.1 M | 410.8 M | 1.49x | 2.24x |
| alloc | 633.9 M | 405.2 M | 455.9 M | 1.56x | 1.39x |
| allocflat | 162.7 M | 122.0 M | 17.0 M | 1.33x | 9.54x |
| allocpar | 2420.0 M | 1397.6 M | 1963.7 M | 1.73x | 1.23x |
| strings | 216.1 M | 382.5 M | 107.3 M | 0.56x | 2.01x |
| map | 366.0 M | 473.1 M | 185.5 M | 0.77x | 1.97x |
| strmap | 1245.9 M | 705.3 M | 274.2 M | 1.77x | 4.54x |
| sort | 279.2 M | 356.6 M | 274.2 M | 0.78x | 1.02x |
| matrix | 1379.9 M | 953.3 M | 398.2 M | 1.45x | 3.47x |
| json | 735.6 M | 353.5 M | 225.8 M | 2.08x | 3.26x |

### Instructions retired: work emitted, not time taken

| Benchmark | Bit | Go | C |
|---|--:|--:|--:|
| fib | 5300.7 M | 5137.2 M | 3146.6 M |
| mandelbrot | 4787.4 M | 2506.7 M | 2698.6 M |
| collatz | 2579.2 M | 935.6 M | 930.5 M |
| alloc | 5112.8 M | 2167.8 M | 3606.8 M |
| allocflat | 1359.2 M | 414.2 M | 59.3 M |
| allocpar | 7321.4 M | 4589.5 M | 3606.9 M |
| strings | 1695.6 M | 1737.3 M | 643.4 M |
| map | 752.5 M | 694.7 M | 238.9 M |
| strmap | 5550.0 M | 2225.8 M | 535.1 M |
| sort | 1632.4 M | 943.4 M | 503.7 M |
| matrix | 12277.3 M | 7324.5 M | 1656.2 M |
| json | 4829.9 M | 2135.7 M | 1340.3 M |

### Wall clock: median of 15 runs, milliseconds

| Benchmark | Bit | Go | C |
|---|--:|--:|--:|
| fib | 266.1 ms | 245.7 ms | 165.0 ms |
| mandelbrot | 548.5 ms | 424.6 ms | 414.7 ms |
| collatz | 229.6 ms | 155.0 ms | 104.3 ms |
| alloc | 161.4 ms | 89.5 ms | 119.5 ms |
| allocflat | 45.9 ms | 22.6 ms | 7.0 ms |
| allocpar | 85.3 ms | 76.3 ms | 68.1 ms |
| strings | 58.4 ms | 66.0 ms | 30.5 ms |
| map | 98.0 ms | 121.9 ms | 54.0 ms |
| strmap | 297.3 ms | 176.1 ms | 68.7 ms |
| sort | 66.5 ms | 86.9 ms | 67.9 ms |
| matrix | 341.2 ms | 242.4 ms | 102.6 ms |
| json | 156.6 ms | 84.4 ms | 61.5 ms |
| allocpar W1 | 193.7 ms | 119.2 ms | 68.1 ms |
| allocpar W8 | 67.0 ms | 72.5 ms | 68.1 ms |

### GC pauses: one untimed run per case, share of that run's own wall clock

| Benchmark | Bit pauses | Bit pausens ms (share) | Bit pausemax ms | Go GCs | Go STW ms (share) | Go STW max ms | C |
|---|--:|--:|--:|--:|--:|--:|--:|
| fib | 0 | 0.0 ms (0.0%) | 0.0 ms | 0 | 0.0 ms (0.0%) | 0.0 ms | n/a |
| mandelbrot | 0 | 0.0 ms (0.0%) | 0.0 ms | 0 | 0.0 ms (0.0%) | 0.0 ms | n/a |
| collatz | 0 | 0.0 ms (0.0%) | 0.0 ms | 0 | 0.0 ms (0.0%) | 0.0 ms | n/a |
| alloc | 133 | 19.3 ms (11.8%) | 0.2 ms | 69 | 2.2 ms (2.4%) | 0.1 ms | n/a |
| allocflat | 66 | 0.2 ms (0.4%) | 0.0 ms | 78 | 2.6 ms (11.7%) | 0.1 ms | n/a |
| allocpar | 169 | 48.8 ms (63.1%) | 0.8 ms | 74 | 9.4 ms (12.7%) | 0.1 ms | n/a |
| strings | 3 | 0.7 ms (1.2%) | 0.5 ms | 12 | 0.3 ms (0.5%) | 0.0 ms | n/a |
| map | 1 | 0.1 ms (0.1%) | 0.1 ms | 4 | 0.1 ms (0.1%) | 0.0 ms | n/a |
| strmap | 4 | 3.9 ms (1.2%) | 3.2 ms | 3 | 0.1 ms (0.1%) | 0.0 ms | n/a |
| sort | 7 | 5.9 ms (9.3%) | 1.8 ms | 1 | 0.0 ms (0.0%) | 0.0 ms | n/a |
| matrix | 1 | 0.0 ms (0.0%) | 0.0 ms | 1 | 0.0 ms (0.0%) | 0.0 ms | n/a |
| json | 19 | 11.9 ms (7.7%) | 7.7 ms | 10 | 0.4 ms (0.5%) | 0.1 ms | n/a |
| allocpar W1 | 162 | 55.8 ms (27.0%) | 0.5 ms | 79 | 0.1 ms (0.1%) | 0.0 ms | n/a |
| allocpar W8 | 176 | 41.2 ms (61.5%) | 0.4 ms | 84 | 9.9 ms (12.3%) | 0.1 ms | n/a |

### Peak memory: max RSS, lower is better

| Benchmark | Bit | Go | C |
|---|--:|--:|--:|
| fib | 2.2 MB | 4.6 MB | 1.8 MB |
| mandelbrot | 2.2 MB | 4.6 MB | 1.8 MB |
| collatz | 2.2 MB | 4.6 MB | 1.8 MB |
| alloc | 6.6 MB | 11.2 MB | 2.0 MB |
| allocflat | 6.1 MB | 11.5 MB | 1.9 MB |
| allocpar | 10.5 MB | 17.4 MB | 3.9 MB |
| strings | 62.9 MB | 69.4 MB | 31.0 MB |
| map | 36.9 MB | 42.0 MB | 193.8 MB |
| strmap | 35.8 MB | 31.2 MB | 41.2 MB |
| sort | 18.0 MB | 15.2 MB | 11.4 MB |
| matrix | 8.5 MB | 11.4 MB | 7.8 MB |
| json | 129.5 MB | 55.8 MB | 125.5 MB |

### Heap allocations per run: the equivalence check, not a score

| Benchmark | Bit | Go | C |
|---|--:|--:|--:|
| fib | 2 | 199 | 0 |
| mandelbrot | 2 | 199 | 0 |
| collatz | 2 | 199 | 0 |
| alloc | 10006002 | 10002330 | 10004000 |
| allocflat | 4002 | 2315 | 2000 |
| allocpar | 10006015 | 10002423 | 10004000 |
| strings | 33 | 350 | 11 |
| map | 10 | 4389 | 1 |
| strmap | 400037 | 400801 | 400003 |
| sort | 600018 | 150283 | 150002 |
| matrix | 12 | 289 | 3 |
| json | 3750060 | 1049998 | 2250021 |

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
| json | 482 KB | 3696 KB | 33 KB |

### Startup & compile

| Metric | Bit | Go | C |
|---|--:|--:|--:|
| Process startup (per exec) | 4.297 ms | 5.231 ms | 3.487 ms |

Bit compile speed: **742 lines/sec** (769 lines across 12 cases, warm).

> Machine: Apple M5 Max, macOS 27.0.1. Bit @ `10ea16944`, Go go1.27.2, Apple clang version 21.0.0 (clang-2100.3.34.2).
> Method: 15 runs per case per language. Cycles and instructions are a trimmed mean of those runs, meaning the mean after dropping the slowest fifth, which was the most reproducible of four estimators measured over 40 samples per series; wall clock and RSS are the median. C built `cc -O2 -ffp-contract=off`, Go `go build`, Bit `bit build`, each language's standard optimized build.
> Mandelbrot: Bit and C agree to the last bit; Go differs by ~0.0002% because it contracts `a*b+c` to a hardware FMA. Not a bug: cross-compiler float bit-identity is not guaranteed.
> alloc measures the ALLOCATOR: 10M short-lived nodes, each its own heap object in all three languages (Bit's element class has a reference field, Go holds `[]*Node`, C mallocs per node). allocflat measures DATA LAYOUT: the same 10M nodes and the same printed total, stored by value in one buffer per batch (Bit packs `[]Node` inline, Go holds `[]Node`, C mallocs the batch once). The gap between the two rows is what per-node heap allocation costs a language.
> allocpar measures the allocator under CONTENTION: the identical 10M nodes and the identical printed total as alloc, partitioned across 8 concurrent workers (Bit `spawn`, Go goroutines, C pthreads), worker count fixed in all three sources and never read from the host core count. The gap between the alloc and allocpar rows is what a language's allocator costs when more than one thread is in it; every other case in this table is single-mutator, so that cost appears nowhere else.
> The allocation table above is how those two claims are checked rather than asserted: same order of magnitude across a row means the three sources still express the same data structure, which is exactly what `alloc` silently lost for a day. Bit's count is `swept+live` from `BIT_GC_STATS=1`; Go's is `runtime.MemStats.Mallocs` and C's a `malloc` counter, both opt-in (`BENCH_ALLOC_STATS`, `-DBENCH_ALLOC_STATS`) and both absent from every timed binary.
> The ratios are built from CYCLES, not from wall clock. `/usr/bin/time` reports `real` in hundredths of a second and most of the C sides here finish in under 0.10s, so a wall-clock ratio for those rows would be quantisation: `map` published 7.50x C off 0.300s/0.040s where the counters say ~4.5x. Adding runs does not fix that, because it narrows the spread around a quantised value instead of removing the quantisation, so the unit changed. Cycles and instructions come from the same `/usr/bin/time -l` invocation that also produced the RSS; nothing extra is run and nothing extra is installed for those three. Wall clock is a separate one-decimal-millisecond measurement (`wall_run()`, one `fork`+`exec`+`waitpid` perl process per run, not `/usr/bin/time`'s own field) so it stays usable below `/usr/bin/time`'s 10ms floor; it still carries no ratio column and is kept as context.
> GC pauses: one untimed run per case, separate from the timed runs above (BIT_GC_STATS/GODEBUG both add real overhead). Bit's fields are `pausens=`/`pausemaxns=`/`pauses=` from `BIT_GC_STATS=1`. Go's are parsed from one `GODEBUG=gctrace=1` run: each `gc N @Ts P%: A+B+C ms clock` line's A (sweep termination) and C (mark termination) are its two STW segments (`go doc runtime`, go1.27.1), summed for the STW total, maxed individually for the longest single pause; B (concurrent mark) is not a stop and is excluded. C has no collector (n/a). Share is that probe run's own `wall_run()` wall time, not the timed loop's median. `allocpar W1`/`W8` reruns the same probe with `BIT_WORKERS`/`GOMAXPROCS` set; C is unchanged (its worker count is a compile-time `#define`, never read from env) so its wall-table cell reuses the baseline `allocpar` row rather than a redundant rerun.
> Cycles and instructions are startup-corrected: each figure has that language's own empty-program cost (`bench/cases/startup`, bit 6.5M, c 5.7M, go 7.5M) subtracted, because dyld and runtime init differ per language and are a fifth of C's `allocflat` row. Every other table is raw.

> On `matrix`, read the Go column as the target and not the C one. The C side vectorises: it retires 2.06 instructions per inner-loop iteration against Go's 9.09, so the Bit:C ratio on this row compares a scalar loop against a vectorised one and is not a statement about codegen quality. A scalar `cc -O2 -fno-vectorize` control build of the same case retires 8.07, which is the like-for-like figure. Denominator for all three: `trials * n^3 = 6 * 512^3 = 805,306,368` inner iterations.
> Reproducibility was measured rather than assumed: four independent regenerations of this table on this box held every ratio to 2.5% between adjacent runs and 8.5% at worst across all four. The loose rows are `alloc`, `map`, `allocflat` and `strings`, whose Go or C side is short enough that that language's own allocator and collector scheduling moves it by several percent from run to run; `matrix`, `mandelbrot`, `fib` and `sort` reproduce to about 1%. On those four loose rows, read a change under ~3% as noise.
> Peak RSS above is a within-run median like every other figure in that table, but it can still swing further ACROSS separate regenerations than one run shows. From every regeneration recorded in `bench/history.csv`, restricted to the same four loose rows above and to the Go/C columns (the Bit column reflects real compiler/runtime changes over that history, not noise): `alloc` c: 1.5-2.2 MB (median 2.0 MB, N=53); `allocflat` go: 10.6-12.8 MB (median 11.4 MB, N=44); `allocflat` c: 1.5-1.9 MB (median 1.9 MB, N=44); `strings` go: 64.3-100.0 MB (median 73.1 MB, N=50). Read that cell's published number as representative of the stated range, not a fixed constant.
> Instructions are published beside cycles because a cycle gap alone does not say whether it is work emitted or work stalled, and the two ratios differ a lot here: Bit retires roughly 4-7 instructions per cycle against C's 1.4-1.8, so its instruction ratio always overstates its cycle ratio. Cycles are the time; instructions are the reason.
> Generated by `bench/run.sh` on 2026-10-09T09:09:30Z. Do not edit by hand.
