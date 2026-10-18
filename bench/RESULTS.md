# Benchmark results: full numbers and method

The README carries the short version. This page keeps every table and the method behind it.

### Runtime: CPU cycles, lower is better

| Benchmark | Bit | Go | C | Bit / Go | Bit / C |
|---|--:|--:|--:|--:|--:|
| fib | 1037.7 M | 950.1 M | 637.3 M | 1.09x | 1.63x |
| mandelbrot | 2140.7 M | 1644.0 M | 1609.1 M | 1.30x | 1.33x |
| collatz | 901.2 M | 620.1 M | 412.5 M | 1.45x | 2.18x |
| alloc | 638.4 M | 390.9 M | 465.0 M | 1.63x | 1.37x |
| allocflat | 163.6 M | 119.0 M | 18.0 M | 1.37x | 9.10x |
| allocpar | 1705.8 M | 1283.1 M | 2067.3 M | 1.33x | 0.83x |
| strings | 215.6 M | 358.6 M | 110.0 M | 0.60x | 1.96x |
| map | 327.6 M | 420.5 M | 177.7 M | 0.78x | 1.84x |
| strmap | 1211.1 M | 686.4 M | 263.1 M | 1.76x | 4.60x |
| sort | 280.5 M | 358.1 M | 272.6 M | 0.78x | 1.03x |
| matrix | 1385.9 M | 955.7 M | 399.5 M | 1.45x | 3.47x |
| json | 714.1 M | 346.9 M | 228.5 M | 2.06x | 3.13x |

### Instructions retired: work emitted, not time taken

| Benchmark | Bit | Go | C |
|---|--:|--:|--:|
| fib | 5301.0 M | 5137.5 M | 3146.9 M |
| mandelbrot | 4788.7 M | 2507.5 M | 2699.6 M |
| collatz | 2581.6 M | 935.9 M | 930.7 M |
| alloc | 4970.8 M | 2157.1 M | 3607.0 M |
| allocflat | 1259.2 M | 406.6 M | 59.3 M |
| allocpar | 6798.3 M | 4594.7 M | 3620.7 M |
| strings | 1703.6 M | 1680.6 M | 643.4 M |
| map | 759.7 M | 694.1 M | 229.5 M |
| strmap | 5510.3 M | 2206.9 M | 534.3 M |
| sort | 1611.4 M | 943.2 M | 503.6 M |
| matrix | 12277.7 M | 7324.6 M | 1656.4 M |
| json | 4659.9 M | 2142.4 M | 1339.9 M |

### Wall clock: median of 15 runs, milliseconds

| Benchmark | Bit | Go | C |
|---|--:|--:|--:|
| fib | 239.8 ms | 223.7 ms | 150.0 ms |
| mandelbrot | 496.6 ms | 381.0 ms | 373.1 ms |
| collatz | 205.6 ms | 141.7 ms | 95.6 ms |
| alloc | 150.7 ms | 82.0 ms | 112.8 ms |
| allocflat | 40.8 ms | 20.0 ms | 6.2 ms |
| allocpar | 74.9 ms | 62.1 ms | 65.4 ms |
| strings | 53.0 ms | 61.0 ms | 28.2 ms |
| map | 79.1 ms | 97.8 ms | 45.4 ms |
| strmap | 280.7 ms | 159.4 ms | 64.4 ms |
| sort | 64.3 ms | 86.0 ms | 66.8 ms |
| matrix | 324.5 ms | 224.6 ms | 95.4 ms |
| json | 142.7 ms | 76.7 ms | 56.5 ms |
| allocpar W1 | 173.8 ms | 106.7 ms | 65.4 ms |
| allocpar W8 | 56.7 ms | 61.4 ms | 65.4 ms |

### GC pauses: one untimed run per case, share of that run's own wall clock

| Benchmark | Bit pauses | Bit pausens ms (share) | Bit pausemax ms | Go GCs | Go STW ms (share) | Go STW max ms | C |
|---|--:|--:|--:|--:|--:|--:|--:|
| fib | 0 | 0.0 ms (0.0%) | 0.0 ms | 0 | 0.0 ms (0.0%) | 0.0 ms | n/a |
| mandelbrot | 0 | 0.0 ms (0.0%) | 0.0 ms | 0 | 0.0 ms (0.0%) | 0.0 ms | n/a |
| collatz | 0 | 0.0 ms (0.0%) | 0.0 ms | 0 | 0.0 ms (0.0%) | 0.0 ms | n/a |
| alloc | 133 | 17.2 ms (11.6%) | 0.1 ms | 69 | 2.2 ms (2.7%) | 0.1 ms | n/a |
| allocflat | 66 | 0.2 ms (0.4%) | 0.0 ms | 78 | 2.5 ms (12.5%) | 0.1 ms | n/a |
| allocpar | 167 | 35.5 ms (46.8%) | 0.7 ms | 67 | 7.7 ms (12.5%) | 0.1 ms | n/a |
| strings | 3 | 0.5 ms (0.9%) | 0.3 ms | 12 | 0.3 ms (0.5%) | 0.0 ms | n/a |
| map | 1 | 0.0 ms (0.0%) | 0.0 ms | 4 | 0.1 ms (0.1%) | 0.0 ms | n/a |
| strmap | 4 | 3.5 ms (1.2%) | 2.9 ms | 2 | 0.1 ms (0.1%) | 0.0 ms | n/a |
| sort | 7 | 5.5 ms (8.7%) | 1.5 ms | 1 | 0.1 ms (0.1%) | 0.0 ms | n/a |
| matrix | 1 | 0.0 ms (0.0%) | 0.0 ms | 1 | 0.1 ms (0.0%) | 0.0 ms | n/a |
| json | 19 | 10.5 ms (7.4%) | 6.7 ms | 10 | 0.3 ms (0.4%) | 0.0 ms | n/a |
| allocpar W1 | 154 | 40.1 ms (23.2%) | 0.4 ms | 78 | 0.0 ms (0.0%) | 0.0 ms | n/a |
| allocpar W8 | 177 | 35.8 ms (51.5%) | 2.7 ms | 81 | 7.4 ms (12.1%) | 0.1 ms | n/a |

### Peak memory: max RSS, lower is better

| Benchmark | Bit | Go | C |
|---|--:|--:|--:|
| fib | 2.2 MB | 4.6 MB | 1.7 MB |
| mandelbrot | 2.2 MB | 4.5 MB | 1.7 MB |
| collatz | 2.2 MB | 4.5 MB | 1.7 MB |
| alloc | 6.7 MB | 10.7 MB | 2.0 MB |
| allocflat | 6.2 MB | 11.3 MB | 1.9 MB |
| allocpar | 10.3 MB | 17.5 MB | 3.8 MB |
| strings | 62.9 MB | 84.3 MB | 31.0 MB |
| map | 37.1 MB | 41.8 MB | 193.8 MB |
| strmap | 35.8 MB | 31.0 MB | 41.1 MB |
| sort | 18.0 MB | 15.1 MB | 11.3 MB |
| matrix | 8.5 MB | 11.3 MB | 7.8 MB |
| json | 129.4 MB | 58.4 MB | 125.5 MB |

### Heap allocations per run: the equivalence check, not a score

| Benchmark | Bit | Go | C |
|---|--:|--:|--:|
| fib | 2 | 191 | 0 |
| mandelbrot | 2 | 191 | 0 |
| collatz | 2 | 191 | 0 |
| alloc | 10006002 | 10002299 | 10004000 |
| allocflat | 4002 | 2298 | 2000 |
| allocpar | 10006015 | 10002420 | 10004000 |
| strings | 33 | 345 | 11 |
| map | 10 | 4374 | 1 |
| strmap | 400037 | 400800 | 400003 |
| sort | 600018 | 150275 | 150002 |
| matrix | 12 | 280 | 3 |
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
| Process startup (per exec) | 4.701 ms | 5.074 ms | 4.777 ms |

Bit compile speed: **669 lines/sec** (769 lines across 12 cases, warm).

> Machine: Apple M5 Max, macOS 27.0.1. Bit @ `3dc5f4bbe`, Go go1.27.2, Apple clang version 21.0.0 (clang-2100.3.34.2).
> Method: 15 runs per case per language. Cycles and instructions are a trimmed mean of those runs, meaning the mean after dropping the slowest fifth, which was the most reproducible of four estimators measured over 40 samples per series; wall clock and RSS are the median. C built `cc -O2 -ffp-contract=off`, Go `go build`, Bit `bit build`, each language's standard optimized build.
> Mandelbrot: Bit and C agree to the last bit; Go differs by ~0.0002% because it contracts `a*b+c` to a hardware FMA. Not a bug: cross-compiler float bit-identity is not guaranteed.
> alloc measures the ALLOCATOR: 10M short-lived nodes, each its own heap object in all three languages (Bit's element class has a reference field, Go holds `[]*Node`, C mallocs per node). allocflat measures DATA LAYOUT: the same 10M nodes and the same printed total, stored by value in one buffer per batch (Bit packs `[]Node` inline, Go holds `[]Node`, C mallocs the batch once). The gap between the two rows is what per-node heap allocation costs a language.
> allocpar measures the allocator under CONTENTION: the identical 10M nodes and the identical printed total as alloc, partitioned across 8 concurrent workers (Bit `spawn`, Go goroutines, C pthreads), worker count fixed in all three sources and never read from the host core count. The gap between the alloc and allocpar rows is what a language's allocator costs when more than one thread is in it; every other case in this table is single-mutator, so that cost appears nowhere else.
> The allocation table above is how those two claims are checked rather than asserted: same order of magnitude across a row means the three sources still express the same data structure, which is exactly what `alloc` silently lost for a day. Bit's count is `swept+live` from `BIT_GC_STATS=1`; Go's is `runtime.MemStats.Mallocs` and C's a `malloc` counter, both opt-in (`BENCH_ALLOC_STATS`, `-DBENCH_ALLOC_STATS`) and both absent from every timed binary.
> The ratios are built from CYCLES, not from wall clock. `/usr/bin/time` reports `real` in hundredths of a second and most of the C sides here finish in under 0.10s, so a wall-clock ratio for those rows would be quantisation: `map` published 7.50x C off 0.300s/0.040s where the counters say ~4.5x. Adding runs does not fix that, because it narrows the spread around a quantised value instead of removing the quantisation, so the unit changed. Cycles and instructions come from the same `/usr/bin/time -l` invocation that also produced the RSS; nothing extra is run and nothing extra is installed for those three. Wall clock is a separate one-decimal-millisecond measurement (`wall_run()`, one `fork`+`exec`+`waitpid` perl process per run, not `/usr/bin/time`'s own field) so it stays usable below `/usr/bin/time`'s 10ms floor; it still carries no ratio column and is kept as context.
> GC pauses: one untimed run per case, separate from the timed runs above (BIT_GC_STATS/GODEBUG both add real overhead). Bit's fields are `pausens=`/`pausemaxns=`/`pauses=` from `BIT_GC_STATS=1`. Go's are parsed from one `GODEBUG=gctrace=1` run: each `gc N @Ts P%: A+B+C ms clock` line's A (sweep termination) and C (mark termination) are its two STW segments (`go doc runtime`, go1.27.1), summed for the STW total, maxed individually for the longest single pause; B (concurrent mark) is not a stop and is excluded. C has no collector (n/a). Share is that probe run's own `wall_run()` wall time, not the timed loop's median. `allocpar W1`/`W8` reruns the same probe with `BIT_WORKERS`/`GOMAXPROCS` set; C is unchanged (its worker count is a compile-time `#define`, never read from env) so its wall-table cell reuses the baseline `allocpar` row rather than a redundant rerun.
> Cycles and instructions are startup-corrected: each figure has that language's own empty-program cost (`bench/cases/startup`, bit 5.0M, c 4.1M, go 6.3M) subtracted, because dyld and runtime init differ per language and are a fifth of C's `allocflat` row. Every other table is raw.

> On `matrix`, read the Go column as the target and not the C one. The C side vectorises: it retires 2.06 instructions per inner-loop iteration against Go's 9.09, so the Bit:C ratio on this row compares a scalar loop against a vectorised one and is not a statement about codegen quality. A scalar `cc -O2 -fno-vectorize` control build of the same case retires 8.07, which is the like-for-like figure. Denominator for all three: `trials * n^3 = 6 * 512^3 = 805,306,368` inner iterations.
> Reproducibility was measured rather than assumed: four independent regenerations of this table on this box held every ratio to 2.5% between adjacent runs and 8.5% at worst across all four. The loose rows are `alloc`, `map`, `allocflat` and `strings`, whose Go or C side is short enough that that language's own allocator and collector scheduling moves it by several percent from run to run; `matrix`, `mandelbrot`, `fib` and `sort` reproduce to about 1%. On those four loose rows, read a change under ~3% as noise.
> Peak RSS above is a within-run median like every other figure in that table, but it can still swing further ACROSS separate regenerations than one run shows. From every regeneration recorded in `bench/history.csv`, restricted to the same four loose rows above and to the Go/C columns (the Bit column reflects real compiler/runtime changes over that history, not noise): `alloc` c: 1.5-2.2 MB (median 2.0 MB, N=60); `allocflat` go: 10.6-12.8 MB (median 11.4 MB, N=51); `allocflat` c: 1.5-1.9 MB (median 1.9 MB, N=51); `strings` go: 64.3-100.0 MB (median 70.5 MB, N=57). Read that cell's published number as representative of the stated range, not a fixed constant.
> Instructions are published beside cycles because a cycle gap alone does not say whether it is work emitted or work stalled, and the two ratios differ a lot here: Bit retires roughly 4-7 instructions per cycle against C's 1.4-1.8, so its instruction ratio always overstates its cycle ratio. Cycles are the time; instructions are the reason.
> Generated by `bench/run.sh` on 2026-10-18T07:33:05Z. Do not edit by hand.
