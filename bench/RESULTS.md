_Full method and caveats below the tables._

### Runtime: CPU cycles, lower is better

| Benchmark | Bit | Go | C | Bit / Go | Bit / C |
|---|--:|--:|--:|--:|--:|
| fib | 1024.4 M | 953.8 M | 635.5 M | 1.07x | 1.61x |
| mandelbrot | 2135.2 M | 1640.2 M | 1607.2 M | 1.30x | 1.33x |
| collatz | 921.9 M | 628.0 M | 412.3 M | 1.47x | 2.24x |
| alloc | 991.1 M | 393.9 M | 467.3 M | 2.52x | 2.12x |
| allocflat | 257.8 M | 123.9 M | 18.6 M | 2.08x | 13.86x |
| allocpar | 21552.0 M | 1260.2 M | 2097.8 M | 17.10x | 10.27x |
| strings | 948.8 M | 372.8 M | 109.5 M | 2.55x | 8.67x |
| map | 303.1 M | 382.2 M | 170.5 M | 0.79x | 1.78x |
| strmap | 1279.1 M | 679.2 M | 249.8 M | 1.88x | 5.12x |
| sort | 296.9 M | 357.6 M | 280.3 M | 0.83x | 1.06x |
| matrix | 1381.7 M | 952.1 M | 398.2 M | 1.45x | 3.47x |
| json | 892.2 M | 341.3 M | 230.4 M | 2.61x | 3.87x |

### Instructions retired: work emitted, not time taken

| Benchmark | Bit | Go | C |
|---|--:|--:|--:|
| fib | 5962.7 M | 5137.2 M | 3146.7 M |
| mandelbrot | 4789.0 M | 2506.7 M | 2699.2 M |
| collatz | 2579.2 M | 935.7 M | 930.6 M |
| alloc | 7611.9 M | 2158.6 M | 3607.0 M |
| allocflat | 1603.9 M | 406.8 M | 59.3 M |
| allocpar | 43589.6 M | 4582.9 M | 3619.7 M |
| strings | 7107.4 M | 1720.7 M | 643.3 M |
| map | 748.4 M | 693.3 M | 228.2 M |
| strmap | 6212.9 M | 2231.3 M | 534.2 M |
| sort | 1792.0 M | 943.1 M | 503.7 M |
| matrix | 12279.9 M | 7324.0 M | 1656.2 M |
| json | 5881.5 M | 2137.4 M | 1339.7 M |

### Wall clock: median of 15 runs, context only

| Benchmark | Bit | Go | C |
|---|--:|--:|--:|
| fib | 0.230s | 0.220s | 0.140s |
| mandelbrot | 0.490s | 0.370s | 0.360s |
| collatz | 0.200s | 0.140s | 0.090s |
| alloc | 0.230s | 0.080s | 0.110s |
| allocflat | 0.060s | 0.010s | 0.000s |
| allocpar | 1.040s | 0.060s | 0.060s |
| strings | 0.220s | 0.050s | 0.020s |
| map | 0.070s | 0.090s | 0.040s |
| strmap | 0.290s | 0.150s | 0.060s |
| sort | 0.070s | 0.080s | 0.060s |
| matrix | 0.310s | 0.220s | 0.090s |
| json | 0.210s | 0.070s | 0.050s |

### Peak memory: max RSS, lower is better

| Benchmark | Bit | Go | C |
|---|--:|--:|--:|
| fib | 2.2 MB | 4.6 MB | 1.8 MB |
| mandelbrot | 2.2 MB | 4.6 MB | 1.8 MB |
| collatz | 2.3 MB | 4.6 MB | 1.8 MB |
| alloc | 6.5 MB | 11.0 MB | 2.0 MB |
| allocflat | 6.1 MB | 11.1 MB | 1.9 MB |
| allocpar | 13.1 MB | 17.9 MB | 3.8 MB |
| strings | 134.6 MB | 70.4 MB | 31.0 MB |
| map | 36.7 MB | 41.9 MB | 193.8 MB |
| strmap | 39.3 MB | 31.2 MB | 41.2 MB |
| sort | 25.8 MB | 15.2 MB | 11.4 MB |
| matrix | 8.5 MB | 11.4 MB | 7.8 MB |
| json | 128.8 MB | 58.3 MB | 125.5 MB |

### Heap allocations per run: the equivalence check, not a score

| Benchmark | Bit | Go | C |
|---|--:|--:|--:|
| fib | 6 | 196 | 0 |
| mandelbrot | 6 | 196 | 0 |
| collatz | 6 | 196 | 0 |
| alloc | 10006006 | 10002304 | 10004000 |
| allocflat | 4006 | 2301 | 2000 |
| allocpar | 10006053 | 10002417 | 10004000 |
| strings | 7125035 | 341 | 11 |
| map | 14 | 4379 | 1 |
| strmap | 400041 | 400823 | 400003 |
| sort | 600022 | 150286 | 150002 |
| matrix | 16 | 279 | 3 |
| json | 3750060 | 1050007 | 2250021 |

### Binary size: static, as emitted

| Benchmark | Bit | Go | C |
|---|--:|--:|--:|
| fib | 270 KB | 2373 KB | 33 KB |
| mandelbrot | 270 KB | 2373 KB | 33 KB |
| collatz | 270 KB | 2373 KB | 33 KB |
| alloc | 271 KB | 2390 KB | 33 KB |
| allocflat | 271 KB | 2373 KB | 33 KB |
| allocpar | 274 KB | 2390 KB | 33 KB |
| strings | 272 KB | 2389 KB | 33 KB |
| map | 293 KB | 2390 KB | 33 KB |
| strmap | 311 KB | 2390 KB | 33 KB |
| sort | 273 KB | 2407 KB | 33 KB |
| matrix | 271 KB | 2373 KB | 33 KB |
| json | 348 KB | 3679 KB | 33 KB |

### Startup & compile

| Metric | Bit | Go | C |
|---|--:|--:|--:|
| Process startup (per exec) | 4.428 ms | 4.659 ms | 4.043 ms |

Bit compile speed: **686 lines/sec** (769 lines across 12 cases, warm).

> Machine: Apple M5 Max, macOS 27.0. Bit @ `2ff3f17d2`, Go go1.27.1, Apple clang version 21.0.0 (clang-2100.3.34.2).
> Method: 15 runs per case per language. Cycles and instructions are a trimmed mean of those runs, meaning the mean after dropping the slowest fifth, which was the most reproducible of four estimators measured over 40 samples per series; wall clock and RSS are the median. C built `cc -O2 -ffp-contract=off`, Go `go build`, Bit `bit build`, each language's standard optimized build.
> Mandelbrot: Bit and C agree to the last bit; Go differs by ~0.0002% because it contracts `a*b+c` to a hardware FMA. Not a bug: cross-compiler float bit-identity is not guaranteed.
> alloc measures the ALLOCATOR: 10M short-lived nodes, each its own heap object in all three languages (Bit's element class has a reference field, Go holds `[]*Node`, C mallocs per node). allocflat measures DATA LAYOUT: the same 10M nodes and the same printed total, stored by value in one buffer per batch (Bit packs `[]Node` inline, Go holds `[]Node`, C mallocs the batch once). The gap between the two rows is what per-node heap allocation costs a language.
> allocpar measures the allocator under CONTENTION: the identical 10M nodes and the identical printed total as alloc, partitioned across 8 concurrent workers (Bit `spawn`, Go goroutines, C pthreads), worker count fixed in all three sources and never read from the host core count. The gap between the alloc and allocpar rows is what a language's allocator costs when more than one thread is in it; every other case in this table is single-mutator, so that cost appears nowhere else.
> The allocation table above is how those two claims are checked rather than asserted: same order of magnitude across a row means the three sources still express the same data structure, which is exactly what `alloc` silently lost for a day. Bit's count is `swept+live` from `BIT_GC_STATS=1`; Go's is `runtime.MemStats.Mallocs` and C's a `malloc` counter, both opt-in (`BENCH_ALLOC_STATS`, `-DBENCH_ALLOC_STATS`) and both absent from every timed binary.
> The ratios are built from CYCLES, not from wall clock. `/usr/bin/time` reports `real` in hundredths of a second and most of the C sides here finish in under 0.10s, so a wall-clock ratio for those rows is quantisation: `map` published 7.50x C off 0.300s/0.040s where the counters say ~4.5x. Adding runs does not fix that, because it narrows the spread around a quantised value instead of removing the quantisation, so the unit changed. Both counters come from the same `/usr/bin/time -l` invocation that already produced the wall clock and the RSS; nothing extra is run and nothing extra is installed. The wall-clock table is kept as context and carries no ratio column.
> Cycles and instructions are startup-corrected: each figure has that language's own empty-program cost (`bench/cases/startup`, bit 4.8M, c 3.9M, go 5.9M) subtracted, because dyld and runtime init differ per language and are a fifth of C's `allocflat` row. Every other table is raw.

> On `matrix`, read the Go column as the target and not the C one. The C side vectorises: it retires 2.06 instructions per inner-loop iteration against Go's 9.09, so the Bit:C ratio on this row compares a scalar loop against a vectorised one and is not a statement about codegen quality. A scalar `cc -O2 -fno-vectorize` control build of the same case retires 8.07, which is the like-for-like figure. Denominator for all three: `trials * n^3 = 6 * 512^3 = 805,306,368` inner iterations.
> Reproducibility was measured rather than assumed: four independent regenerations of this table on this box held every ratio to 2.5% between adjacent runs and 8.5% at worst across all four. The loose rows are `alloc`, `map`, `allocflat` and `strings`, whose Go or C side is short enough that that language's own allocator and collector scheduling moves it by several percent from run to run; `matrix`, `mandelbrot`, `fib` and `sort` reproduce to about 1%. On those four loose rows, read a change under ~3% as noise.
> Peak RSS above is a within-run median like every other figure in that table, but it can still swing further ACROSS separate regenerations than one run shows. From every regeneration recorded in `bench/history.csv`, restricted to the same four loose rows above and to the Go/C columns (the Bit column reflects real compiler/runtime changes over that history, not noise): `alloc` c: 1.5-2.0 MB (median 1.6 MB, N=32); `allocflat` go: 10.6-11.7 MB (median 11.3 MB, N=23); `allocflat` c: 1.5-1.9 MB (median 1.5 MB, N=23); `strings` go: 64.3-90.9 MB (median 70.4 MB, N=29). Read that cell's published number as representative of the stated range, not a fixed constant.
> Instructions are published beside cycles because a cycle gap alone does not say whether it is work emitted or work stalled, and the two ratios differ a lot here: Bit retires roughly 4-7 instructions per cycle against C's 1.4-1.8, so its instruction ratio always overstates its cycle ratio. Cycles are the time; instructions are the reason.
> Generated by `bench/run.sh` on 2026-09-22T06:27:35Z. Do not edit by hand.
