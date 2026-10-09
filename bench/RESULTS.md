# Benchmark results: full numbers and method

The README carries the short version. This page keeps every table and the method behind it.

### Runtime: CPU cycles, lower is better

| Benchmark | Bit | Go | C | Bit / Go | Bit / C |
|---|--:|--:|--:|--:|--:|
| fib | 1027.9 M | 943.6 M | 635.0 M | 1.09x | 1.62x |
| mandelbrot | 2145.0 M | 1645.5 M | 1611.9 M | 1.30x | 1.33x |
| collatz | 919.7 M | 617.9 M | 410.4 M | 1.49x | 2.24x |
| alloc | 636.4 M | 406.8 M | 460.2 M | 1.56x | 1.38x |
| allocflat | 157.3 M | 115.5 M | 17.9 M | 1.36x | 8.79x |
| allocpar | 1946.0 M | 1353.2 M | 1911.4 M | 1.44x | 1.02x |
| strings | 214.6 M | 378.8 M | 109.8 M | 0.57x | 1.95x |
| map | 403.3 M | 563.6 M | 193.6 M | 0.72x | 2.08x |
| strmap | 1303.6 M | 707.2 M | 294.2 M | 1.84x | 4.43x |
| sort | 285.6 M | 357.8 M | 273.8 M | 0.80x | 1.04x |
| matrix | 1382.5 M | 954.1 M | 399.3 M | 1.45x | 3.46x |
| json | 731.1 M | 350.5 M | 227.5 M | 2.09x | 3.21x |

### Instructions retired: work emitted, not time taken

| Benchmark | Bit | Go | C |
|---|--:|--:|--:|
| fib | 5300.5 M | 5137.1 M | 3146.8 M |
| mandelbrot | 4786.8 M | 2506.3 M | 2698.5 M |
| collatz | 2578.9 M | 935.3 M | 930.4 M |
| alloc | 5112.6 M | 2168.6 M | 3606.8 M |
| allocflat | 1289.1 M | 406.4 M | 59.3 M |
| allocpar | 7147.0 M | 4602.4 M | 3609.3 M |
| strings | 1693.7 M | 1716.4 M | 643.4 M |
| map | 752.3 M | 694.1 M | 230.1 M |
| strmap | 5555.2 M | 2243.6 M | 534.4 M |
| sort | 1630.3 M | 943.3 M | 503.8 M |
| matrix | 12276.8 M | 7324.0 M | 1656.2 M |
| json | 4833.7 M | 2140.4 M | 1340.1 M |

### Wall clock: median of 15 runs, milliseconds

| Benchmark | Bit | Go | C |
|---|--:|--:|--:|
| fib | 262.6 ms | 244.1 ms | 162.2 ms |
| mandelbrot | 522.4 ms | 398.5 ms | 391.4 ms |
| collatz | 222.1 ms | 150.5 ms | 99.9 ms |
| alloc | 156.8 ms | 87.4 ms | 114.7 ms |
| allocflat | 40.5 ms | 20.7 ms | 7.3 ms |
| allocpar | 72.8 ms | 73.6 ms | 65.8 ms |
| strings | 57.5 ms | 66.4 ms | 31.2 ms |
| map | 100.2 ms | 146.8 ms | 52.4 ms |
| strmap | 318.6 ms | 169.0 ms | 76.1 ms |
| sort | 68.0 ms | 86.8 ms | 68.0 ms |
| matrix | 329.2 ms | 227.6 ms | 97.3 ms |
| json | 146.8 ms | 77.8 ms | 58.2 ms |
| allocpar W1 | 194.3 ms | 116.6 ms | 65.8 ms |
| allocpar W8 | 68.3 ms | 74.2 ms | 65.8 ms |

### GC pauses: one untimed run per case, share of that run's own wall clock

| Benchmark | Bit pauses | Bit pausens ms (share) | Bit pausemax ms | Go GCs | Go STW ms (share) | Go STW max ms | C |
|---|--:|--:|--:|--:|--:|--:|--:|
| fib | 0 | 0.0 ms (0.0%) | 0.0 ms | 0 | 0.0 ms (0.0%) | 0.0 ms | n/a |
| mandelbrot | 0 | 0.0 ms (0.0%) | 0.0 ms | 0 | 0.0 ms (0.0%) | 0.0 ms | n/a |
| collatz | 0 | 0.0 ms (0.0%) | 0.0 ms | 0 | 0.0 ms (0.0%) | 0.0 ms | n/a |
| alloc | 133 | 17.9 ms (11.4%) | 0.2 ms | 69 | 1.9 ms (2.2%) | 0.1 ms | n/a |
| allocflat | 66 | 0.2 ms (0.5%) | 0.0 ms | 77 | 2.2 ms (10.2%) | 0.0 ms | n/a |
| allocpar | 167 | 38.7 ms (55.1%) | 0.5 ms | 73 | 8.8 ms (12.3%) | 0.2 ms | n/a |
| strings | 3 | 0.7 ms (1.2%) | 0.5 ms | 12 | 0.3 ms (0.5%) | 0.1 ms | n/a |
| map | 1 | 0.0 ms (0.0%) | 0.0 ms | 4 | 0.1 ms (0.1%) | 0.0 ms | n/a |
| strmap | 4 | 3.9 ms (1.2%) | 3.2 ms | 2 | 0.1 ms (0.1%) | 0.0 ms | n/a |
| sort | 7 | 6.2 ms (9.0%) | 1.9 ms | 1 | 0.0 ms (0.0%) | 0.0 ms | n/a |
| matrix | 1 | 0.0 ms (0.0%) | 0.0 ms | 1 | 0.0 ms (0.0%) | 0.0 ms | n/a |
| json | 19 | 11.1 ms (7.4%) | 7.2 ms | 10 | 0.3 ms (0.4%) | 0.0 ms | n/a |
| allocpar W1 | 158 | 52.6 ms (25.5%) | 0.5 ms | 77 | 0.1 ms (0.1%) | 0.0 ms | n/a |
| allocpar W8 | 177 | 41.8 ms (61.7%) | 0.6 ms | 83 | 9.3 ms (12.1%) | 0.2 ms | n/a |

### Peak memory: max RSS, lower is better

| Benchmark | Bit | Go | C |
|---|--:|--:|--:|
| fib | 2.2 MB | 4.6 MB | 1.8 MB |
| mandelbrot | 2.2 MB | 4.6 MB | 1.8 MB |
| collatz | 2.2 MB | 4.6 MB | 1.8 MB |
| alloc | 6.6 MB | 11.3 MB | 2.0 MB |
| allocflat | 6.1 MB | 11.6 MB | 1.9 MB |
| allocpar | 10.4 MB | 17.5 MB | 4.0 MB |
| strings | 62.9 MB | 76.2 MB | 31.0 MB |
| map | 36.9 MB | 42.0 MB | 193.8 MB |
| strmap | 35.8 MB | 31.3 MB | 41.2 MB |
| sort | 18.0 MB | 15.2 MB | 11.4 MB |
| matrix | 8.5 MB | 11.4 MB | 7.8 MB |
| json | 129.4 MB | 56.8 MB | 125.5 MB |

### Heap allocations per run: the equivalence check, not a score

| Benchmark | Bit | Go | C |
|---|--:|--:|--:|
| fib | 2 | 199 | 0 |
| mandelbrot | 2 | 205 | 0 |
| collatz | 2 | 205 | 0 |
| alloc | 10006002 | 10002334 | 10004000 |
| allocflat | 4002 | 2348 | 2000 |
| allocpar | 10006015 | 10002424 | 10004000 |
| strings | 33 | 346 | 11 |
| map | 10 | 4383 | 1 |
| strmap | 400037 | 400803 | 400003 |
| sort | 600018 | 150283 | 150002 |
| matrix | 12 | 282 | 3 |
| json | 3750060 | 1050006 | 2250021 |

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
| Process startup (per exec) | 4.910 ms | 5.546 ms | 4.165 ms |

Bit compile speed: **774 lines/sec** (769 lines across 12 cases, warm).

> Machine: Apple M5 Max, macOS 27.0.1. Bit @ `4b25c1299`, Go go1.27.2, Apple clang version 21.0.0 (clang-2100.3.34.2).
> Method: 15 runs per case per language. Cycles and instructions are a trimmed mean of those runs, meaning the mean after dropping the slowest fifth, which was the most reproducible of four estimators measured over 40 samples per series; wall clock and RSS are the median. C built `cc -O2 -ffp-contract=off`, Go `go build`, Bit `bit build`, each language's standard optimized build.
> Mandelbrot: Bit and C agree to the last bit; Go differs by ~0.0002% because it contracts `a*b+c` to a hardware FMA. Not a bug: cross-compiler float bit-identity is not guaranteed.
> alloc measures the ALLOCATOR: 10M short-lived nodes, each its own heap object in all three languages (Bit's element class has a reference field, Go holds `[]*Node`, C mallocs per node). allocflat measures DATA LAYOUT: the same 10M nodes and the same printed total, stored by value in one buffer per batch (Bit packs `[]Node` inline, Go holds `[]Node`, C mallocs the batch once). The gap between the two rows is what per-node heap allocation costs a language.
> allocpar measures the allocator under CONTENTION: the identical 10M nodes and the identical printed total as alloc, partitioned across 8 concurrent workers (Bit `spawn`, Go goroutines, C pthreads), worker count fixed in all three sources and never read from the host core count. The gap between the alloc and allocpar rows is what a language's allocator costs when more than one thread is in it; every other case in this table is single-mutator, so that cost appears nowhere else.
> The allocation table above is how those two claims are checked rather than asserted: same order of magnitude across a row means the three sources still express the same data structure, which is exactly what `alloc` silently lost for a day. Bit's count is `swept+live` from `BIT_GC_STATS=1`; Go's is `runtime.MemStats.Mallocs` and C's a `malloc` counter, both opt-in (`BENCH_ALLOC_STATS`, `-DBENCH_ALLOC_STATS`) and both absent from every timed binary.
> The ratios are built from CYCLES, not from wall clock. `/usr/bin/time` reports `real` in hundredths of a second and most of the C sides here finish in under 0.10s, so a wall-clock ratio for those rows would be quantisation: `map` published 7.50x C off 0.300s/0.040s where the counters say ~4.5x. Adding runs does not fix that, because it narrows the spread around a quantised value instead of removing the quantisation, so the unit changed. Cycles and instructions come from the same `/usr/bin/time -l` invocation that also produced the RSS; nothing extra is run and nothing extra is installed for those three. Wall clock is a separate one-decimal-millisecond measurement (`wall_run()`, one `fork`+`exec`+`waitpid` perl process per run, not `/usr/bin/time`'s own field) so it stays usable below `/usr/bin/time`'s 10ms floor; it still carries no ratio column and is kept as context.
> GC pauses: one untimed run per case, separate from the timed runs above (BIT_GC_STATS/GODEBUG both add real overhead). Bit's fields are `pausens=`/`pausemaxns=`/`pauses=` from `BIT_GC_STATS=1`. Go's are parsed from one `GODEBUG=gctrace=1` run: each `gc N @Ts P%: A+B+C ms clock` line's A (sweep termination) and C (mark termination) are its two STW segments (`go doc runtime`, go1.27.1), summed for the STW total, maxed individually for the longest single pause; B (concurrent mark) is not a stop and is excluded. C has no collector (n/a). Share is that probe run's own `wall_run()` wall time, not the timed loop's median. `allocpar W1`/`W8` reruns the same probe with `BIT_WORKERS`/`GOMAXPROCS` set; C is unchanged (its worker count is a compile-time `#define`, never read from env) so its wall-table cell reuses the baseline `allocpar` row rather than a redundant rerun.
> Cycles and instructions are startup-corrected: each figure has that language's own empty-program cost (`bench/cases/startup`, bit 7.2M, c 5.7M, go 8.4M) subtracted, because dyld and runtime init differ per language and are a fifth of C's `allocflat` row. Every other table is raw.

> On `matrix`, read the Go column as the target and not the C one. The C side vectorises: it retires 2.06 instructions per inner-loop iteration against Go's 9.09, so the Bit:C ratio on this row compares a scalar loop against a vectorised one and is not a statement about codegen quality. A scalar `cc -O2 -fno-vectorize` control build of the same case retires 8.07, which is the like-for-like figure. Denominator for all three: `trials * n^3 = 6 * 512^3 = 805,306,368` inner iterations.
> Reproducibility was measured rather than assumed: four independent regenerations of this table on this box held every ratio to 2.5% between adjacent runs and 8.5% at worst across all four. The loose rows are `alloc`, `map`, `allocflat` and `strings`, whose Go or C side is short enough that that language's own allocator and collector scheduling moves it by several percent from run to run; `matrix`, `mandelbrot`, `fib` and `sort` reproduce to about 1%. On those four loose rows, read a change under ~3% as noise.
> Peak RSS above is a within-run median like every other figure in that table, but it can still swing further ACROSS separate regenerations than one run shows. From every regeneration recorded in `bench/history.csv`, restricted to the same four loose rows above and to the Go/C columns (the Bit column reflects real compiler/runtime changes over that history, not noise): `alloc` c: 1.5-2.2 MB (median 2.0 MB, N=54); `allocflat` go: 10.6-12.8 MB (median 11.5 MB, N=45); `allocflat` c: 1.5-1.9 MB (median 1.9 MB, N=45); `strings` go: 64.3-100.0 MB (median 75.8 MB, N=51). Read that cell's published number as representative of the stated range, not a fixed constant.
> Instructions are published beside cycles because a cycle gap alone does not say whether it is work emitted or work stalled, and the two ratios differ a lot here: Bit retires roughly 4-7 instructions per cycle against C's 1.4-1.8, so its instruction ratio always overstates its cycle ratio. Cycles are the time; instructions are the reason.
> Generated by `bench/run.sh` on 2026-10-09T19:23:12Z. Do not edit by hand.
