_Full method and caveats below the tables._

### Runtime: CPU cycles, lower is better

| Benchmark | Bit | Go | C | Bit / Go | Bit / C |
|---|--:|--:|--:|--:|--:|
| fib | 1012.4 M | 946.4 M | 634.7 M | 1.07x | 1.60x |
| mandelbrot | 2139.6 M | 1644.2 M | 1609.8 M | 1.30x | 1.33x |
| collatz | 919.3 M | 625.0 M | 410.7 M | 1.47x | 2.24x |
| alloc | 1000.9 M | 417.7 M | 623.1 M | 2.40x | 1.61x |
| allocflat | 253.5 M | 135.9 M | 17.3 M | 1.86x | 14.62x |
| strings | 964.7 M | 373.7 M | 108.8 M | 2.58x | 8.87x |
| map | 333.4 M | 417.2 M | 156.1 M | 0.80x | 2.14x |
| strmap | 1341.8 M | 686.1 M | 258.9 M | 1.96x | 5.18x |
| sort | 309.6 M | 356.6 M | 284.1 M | 0.87x | 1.09x |
| matrix | 1383.4 M | 956.2 M | 398.2 M | 1.45x | 3.47x |
| json | 1527.2 M | 348.7 M | 235.2 M | 4.38x | 6.49x |

### Instructions retired: work emitted, not time taken

| Benchmark | Bit | Go | C |
|---|--:|--:|--:|
| fib | 5963.1 M | 5137.4 M | 3146.8 M |
| mandelbrot | 4790.9 M | 2508.2 M | 2700.4 M |
| collatz | 2579.1 M | 935.4 M | 930.6 M |
| alloc | 7651.5 M | 2164.8 M | 4291.1 M |
| allocflat | 1593.7 M | 410.4 M | 59.3 M |
| strings | 7140.8 M | 1703.9 M | 643.4 M |
| map | 757.3 M | 695.7 M | 234.1 M |
| strmap | 6396.2 M | 2212.7 M | 540.7 M |
| sort | 1878.6 M | 942.7 M | 508.7 M |
| matrix | 12279.9 M | 7324.0 M | 1656.2 M |
| json | 10254.3 M | 2142.7 M | 1372.1 M |

### Wall clock: median of 15 runs, context only

| Benchmark | Bit | Go | C |
|---|--:|--:|--:|
| fib | 0.280s | 0.260s | 0.170s |
| mandelbrot | 0.520s | 0.390s | 0.380s |
| collatz | 0.230s | 0.150s | 0.100s |
| alloc | 0.250s | 0.090s | 0.150s |
| allocflat | 0.060s | 0.020s | 0.000s |
| strings | 0.250s | 0.060s | 0.030s |
| map | 0.110s | 0.140s | 0.050s |
| strmap | 0.320s | 0.160s | 0.060s |
| sort | 0.070s | 0.080s | 0.060s |
| matrix | 0.320s | 0.220s | 0.090s |
| json | 0.360s | 0.070s | 0.050s |

### Peak memory: max RSS, lower is better

| Benchmark | Bit | Go | C |
|---|--:|--:|--:|
| fib | 1.8 MB | 4.2 MB | 1.4 MB |
| mandelbrot | 1.8 MB | 4.2 MB | 1.4 MB |
| collatz | 2.0 MB | 4.2 MB | 1.4 MB |
| alloc | 6.1 MB | 10.9 MB | 1.7 MB |
| allocflat | 5.7 MB | 11.3 MB | 1.5 MB |
| strings | 134.2 MB | 64.3 MB | 30.7 MB |
| map | 36.3 MB | 41.5 MB | 193.5 MB |
| strmap | 35.6 MB | 30.8 MB | 40.8 MB |
| sort | 25.1 MB | 14.8 MB | 11.0 MB |
| matrix | 8.2 MB | 11.0 MB | 7.5 MB |
| json | 179.0 MB | 60.0 MB | 125.2 MB |

### Heap allocations per run: the equivalence check, not a score

| Benchmark | Bit | Go | C |
|---|--:|--:|--:|
| fib | 6 | 195 | 0 |
| mandelbrot | 6 | 201 | 0 |
| collatz | 6 | 195 | 0 |
| alloc | 10006006 | 10002334 | 10004000 |
| allocflat | 4006 | 2341 | 2000 |
| strings | 7125035 | 341 | 11 |
| map | 14 | 4374 | 1 |
| strmap | 400041 | 400799 | 400003 |
| sort | 600022 | 150285 | 150002 |
| matrix | 16 | 314 | 3 |
| json | 5400061 | 1049995 | 2250021 |

### Binary size: static, as emitted

| Benchmark | Bit | Go | C |
|---|--:|--:|--:|
| fib | 235 KB | 2373 KB | 33 KB |
| mandelbrot | 235 KB | 2373 KB | 33 KB |
| collatz | 235 KB | 2373 KB | 33 KB |
| alloc | 235 KB | 2390 KB | 33 KB |
| allocflat | 235 KB | 2373 KB | 33 KB |
| strings | 269 KB | 2389 KB | 33 KB |
| map | 273 KB | 2390 KB | 33 KB |
| strmap | 291 KB | 2390 KB | 33 KB |
| sort | 270 KB | 2407 KB | 33 KB |
| matrix | 235 KB | 2373 KB | 33 KB |
| json | 344 KB | 3679 KB | 33 KB |

### Startup & compile

| Metric | Bit | Go | C |
|---|--:|--:|--:|
| Process startup (per exec) | 4.364 ms | 5.358 ms | 4.116 ms |

Bit compile speed: **521 lines/sec** (669 lines across 11 cases, warm).

> Machine: Apple M5 Max, macOS 26.6.2. Bit @ `69ac415e`, Go go1.27.1, Apple clang version 21.0.0 (clang-2100.1.1.101).
> Method: 15 runs per case per language. Cycles and instructions are a trimmed mean of those runs, meaning the mean after dropping the slowest fifth, which was the most reproducible of four estimators measured over 40 samples per series; wall clock and RSS are the median. C built `cc -O2 -ffp-contract=off`, Go `go build`, Bit `bit build`, each language's standard optimized build.
> Mandelbrot: Bit and C agree to the last bit; Go differs by ~0.0002% because it contracts `a*b+c` to a hardware FMA. Not a bug: cross-compiler float bit-identity is not guaranteed.
> alloc measures the ALLOCATOR: 10M short-lived nodes, each its own heap object in all three languages (Bit's element class has a reference field, Go holds `[]*Node`, C mallocs per node). allocflat measures DATA LAYOUT: the same 10M nodes and the same printed total, stored by value in one buffer per batch (Bit packs `[]Node` inline since #3862, Go holds `[]Node`, C mallocs the batch once). The gap between the two rows is what per-node heap allocation costs a language.
> The allocation table above is how those two claims are checked rather than asserted: same order of magnitude across a row means the three sources still express the same data structure, which is exactly what `alloc` silently lost for a day (#3934). Bit's count is `swept+live` from `BIT_GC_STATS=1`; Go's is `runtime.MemStats.Mallocs` and C's a `malloc` counter, both opt-in (`BENCH_ALLOC_STATS`, `-DBENCH_ALLOC_STATS`) and both absent from every timed binary.
> The ratios are built from CYCLES, not from wall clock. `/usr/bin/time` reports `real` in hundredths of a second and most of the C sides here finish in under 0.10s, so a wall-clock ratio for those rows is quantisation: `map` published 7.50x C off 0.300s/0.040s where the counters say ~4.5x. Adding runs does not fix that, because it narrows the spread around a quantised value instead of removing the quantisation, so the unit changed (#4040). Both counters come from the same `/usr/bin/time -l` invocation that already produced the wall clock and the RSS; nothing extra is run and nothing extra is installed. The wall-clock table is kept as context and carries no ratio column.
> Cycles and instructions are startup-corrected: each figure has that language's own empty-program cost (`bench/cases/startup`, bit 5.6M, c 4.5M, go 6.7M) subtracted, because dyld and runtime init differ per language and are a fifth of C's `allocflat` row. Every other table is raw.

> On `matrix`, read the Go column as the target and not the C one. The C side vectorises: it retires 2.06 instructions per inner-loop iteration against Go's 9.09, so the Bit:C ratio on this row compares a scalar loop against a vectorised one and is not a statement about codegen quality. A scalar `cc -O2 -fno-vectorize` control build of the same case retires 8.07, which is the like-for-like figure. Denominator for all three: `trials * n^3 = 6 * 512^3 = 805,306,368` inner iterations.
> Reproducibility was measured rather than assumed (#4040): four independent regenerations of this table on this box held every ratio to 2.5% between adjacent runs and 8.5% at worst across all four. The loose rows are `alloc`, `map`, `allocflat` and `strings`, whose Go or C side is short enough that that language's own allocator and collector scheduling moves it by several percent from run to run; `matrix`, `mandelbrot`, `fib` and `sort` reproduce to about 1%. On those four loose rows, read a change under ~3% as noise.
> Peak RSS above is a within-run median like every other figure in that table, but it can still swing further ACROSS separate regenerations than one run shows (#4199). From every regeneration recorded in `bench/history.csv`, restricted to the same four loose rows above and to the Go/C columns (the Bit column reflects real compiler/runtime changes over that history, not noise): `alloc` c: 1.5-1.7 MB (median 1.6 MB, N=19); `strings` go: 64.3-90.9 MB (median 68.9 MB, N=16). Read that cell's published number as representative of the stated range, not a fixed constant.
> Instructions are published beside cycles because a cycle gap alone does not say whether it is work emitted or work stalled, and the two ratios differ a lot here: Bit retires roughly 4-7 instructions per cycle against C's 1.4-1.8, so its instruction ratio always overstates its cycle ratio. Cycles are the time; instructions are the reason.
> Generated by `bench/run.sh` on 2026-09-11T02:54:37Z. Do not edit by hand.
