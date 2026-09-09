_Full method and caveats below the tables._

### Runtime: CPU cycles, lower is better

| Benchmark | Bit | Go | C | Bit / Go | Bit / C |
|---|--:|--:|--:|--:|--:|
| fib | 1012.0 M | 945.3 M | 635.8 M | 1.07x | 1.59x |
| mandelbrot | 2133.6 M | 1639.1 M | 1606.1 M | 1.30x | 1.33x |
| collatz | 917.2 M | 626.2 M | 411.4 M | 1.46x | 2.23x |
| alloc | 1149.6 M | 392.7 M | 641.1 M | 2.93x | 1.79x |
| allocflat | 248.5 M | 119.9 M | 17.7 M | 2.07x | 14.05x |
| strings | 1066.9 M | 373.7 M | 109.2 M | 2.86x | 9.77x |
| map | 323.7 M | 389.2 M | 172.7 M | 0.83x | 1.87x |
| strmap | 1343.5 M | 676.4 M | 255.2 M | 1.99x | 5.26x |
| sort | 315.5 M | 356.9 M | 285.4 M | 0.88x | 1.11x |
| matrix | 1382.3 M | 951.7 M | 397.5 M | 1.45x | 3.48x |
| json | 1565.2 M | 340.1 M | 230.5 M | 4.60x | 6.79x |

### Instructions retired: work emitted, not time taken

| Benchmark | Bit | Go | C |
|---|--:|--:|--:|
| fib | 5962.3 M | 5136.6 M | 3146.6 M |
| mandelbrot | 4793.0 M | 2506.1 M | 2698.8 M |
| collatz | 2578.8 M | 935.1 M | 930.5 M |
| alloc | 7997.8 M | 2154.2 M | 4289.7 M |
| allocflat | 1645.5 M | 401.9 M | 59.3 M |
| strings | 7455.2 M | 1714.6 M | 643.3 M |
| map | 793.6 M | 693.0 M | 229.0 M |
| strmap | 6649.6 M | 2218.0 M | 539.8 M |
| sort | 1928.7 M | 942.6 M | 508.7 M |
| matrix | 12279.7 M | 7323.5 M | 1656.2 M |
| json | 10576.4 M | 2139.3 M | 1371.6 M |

### Wall clock: median of 15 runs, context only

| Benchmark | Bit | Go | C |
|---|--:|--:|--:|
| fib | 0.240s | 0.220s | 0.140s |
| mandelbrot | 0.480s | 0.370s | 0.360s |
| collatz | 0.200s | 0.140s | 0.090s |
| alloc | 0.260s | 0.070s | 0.150s |
| allocflat | 0.050s | 0.010s | 0.000s |
| strings | 0.240s | 0.050s | 0.020s |
| map | 0.070s | 0.080s | 0.040s |
| strmap | 0.310s | 0.150s | 0.060s |
| sort | 0.070s | 0.080s | 0.060s |
| matrix | 0.310s | 0.210s | 0.090s |
| json | 0.360s | 0.070s | 0.050s |

### Peak memory: max RSS, lower is better

| Benchmark | Bit | Go | C |
|---|--:|--:|--:|
| fib | 1.9 MB | 4.2 MB | 1.4 MB |
| mandelbrot | 1.9 MB | 4.2 MB | 1.4 MB |
| collatz | 2.0 MB | 4.2 MB | 1.4 MB |
| alloc | 6.1 MB | 10.5 MB | 1.6 MB |
| allocflat | 5.7 MB | 11.3 MB | 1.5 MB |
| strings | 134.2 MB | 69.5 MB | 30.7 MB |
| map | 36.3 MB | 41.5 MB | 193.5 MB |
| strmap | 35.6 MB | 30.8 MB | 40.8 MB |
| sort | 25.1 MB | 14.8 MB | 11.0 MB |
| matrix | 8.2 MB | 11.0 MB | 7.5 MB |
| json | 179.0 MB | 57.6 MB | 125.2 MB |

### Heap allocations per run: the equivalence check, not a score

| Benchmark | Bit | Go | C |
|---|--:|--:|--:|
| fib | 6 | 195 | 0 |
| mandelbrot | 6 | 195 | 0 |
| collatz | 6 | 195 | 0 |
| alloc | 10006006 | 10002306 | 10004000 |
| allocflat | 4006 | 2303 | 2000 |
| strings | 7125035 | 338 | 11 |
| map | 14 | 4378 | 1 |
| strmap | 400041 | 400797 | 400003 |
| sort | 600022 | 150285 | 150002 |
| matrix | 16 | 284 | 3 |
| json | 5400061 | 1049989 | 2250021 |

### Binary size: static, as emitted

| Benchmark | Bit | Go | C |
|---|--:|--:|--:|
| fib | 234 KB | 2373 KB | 33 KB |
| mandelbrot | 234 KB | 2373 KB | 33 KB |
| collatz | 234 KB | 2373 KB | 33 KB |
| alloc | 234 KB | 2390 KB | 33 KB |
| allocflat | 234 KB | 2373 KB | 33 KB |
| strings | 252 KB | 2389 KB | 33 KB |
| map | 272 KB | 2390 KB | 33 KB |
| strmap | 291 KB | 2390 KB | 33 KB |
| sort | 269 KB | 2407 KB | 33 KB |
| matrix | 234 KB | 2373 KB | 33 KB |
| json | 343 KB | 3679 KB | 33 KB |

### Startup & compile

| Metric | Bit | Go | C |
|---|--:|--:|--:|
| Process startup (per exec) | 4.143 ms | 4.278 ms | 3.682 ms |

Bit compile speed: **605 lines/sec** (669 lines across 11 cases, warm).

> Machine: Apple M5 Max, macOS 26.6.2. Bit @ `7531627a`, Go go1.27.1, Apple clang version 21.0.0 (clang-2100.1.1.101).
> Method: 15 runs per case per language. Cycles and instructions are a trimmed mean of those runs, meaning the mean after dropping the slowest fifth, which was the most reproducible of four estimators measured over 40 samples per series; wall clock and RSS are the median. C built `cc -O2 -ffp-contract=off`, Go `go build`, Bit `bit build`, each language's standard optimized build.
> Mandelbrot: Bit and C agree to the last bit; Go differs by ~0.0002% because it contracts `a*b+c` to a hardware FMA. Not a bug: cross-compiler float bit-identity is not guaranteed.
> alloc measures the ALLOCATOR: 10M short-lived nodes, each its own heap object in all three languages (Bit's element class has a reference field, Go holds `[]*Node`, C mallocs per node). allocflat measures DATA LAYOUT: the same 10M nodes and the same printed total, stored by value in one buffer per batch (Bit packs `[]Node` inline since #3862, Go holds `[]Node`, C mallocs the batch once). The gap between the two rows is what per-node heap allocation costs a language.
> The allocation table above is how those two claims are checked rather than asserted: same order of magnitude across a row means the three sources still express the same data structure, which is exactly what `alloc` silently lost for a day (#3934). Bit's count is `swept+live` from `BIT_GC_STATS=1`; Go's is `runtime.MemStats.Mallocs` and C's a `malloc` counter, both opt-in (`BENCH_ALLOC_STATS`, `-DBENCH_ALLOC_STATS`) and both absent from every timed binary.
> The ratios are built from CYCLES, not from wall clock. `/usr/bin/time` reports `real` in hundredths of a second and most of the C sides here finish in under 0.10s, so a wall-clock ratio for those rows is quantisation: `map` published 7.50x C off 0.300s/0.040s where the counters say ~4.5x. Adding runs does not fix that, because it narrows the spread around a quantised value instead of removing the quantisation, so the unit changed (#4040). Both counters come from the same `/usr/bin/time -l` invocation that already produced the wall clock and the RSS; nothing extra is run and nothing extra is installed. The wall-clock table is kept as context and carries no ratio column.
> Cycles and instructions are startup-corrected: each figure has that language's own empty-program cost (`bench/cases/startup`, bit 4.5M, c 3.8M, go 5.6M) subtracted, because dyld and runtime init differ per language and are a fifth of C's `allocflat` row. Every other table is raw.

> On `matrix`, read the Go column as the target and not the C one. The C side vectorises: it retires 2.06 instructions per inner-loop iteration against Go's 9.09, so the Bit:C ratio on this row compares a scalar loop against a vectorised one and is not a statement about codegen quality. A scalar `cc -O2 -fno-vectorize` control build of the same case retires 8.07, which is the like-for-like figure. Denominator for all three: `trials * n^3 = 6 * 512^3 = 805,306,368` inner iterations.
> Reproducibility was measured rather than assumed (#4040): four independent regenerations of this table on this box held every ratio to 2.5% between adjacent runs and 8.5% at worst across all four. The loose rows are `alloc`, `map`, `allocflat` and `strings`, whose Go or C side is short enough that that language's own allocator and collector scheduling moves it by several percent from run to run; `matrix`, `mandelbrot`, `fib` and `sort` reproduce to about 1%. On those four loose rows, read a change under ~3% as noise.
> Peak RSS above is a within-run median like every other figure in that table, but it can still swing further ACROSS separate regenerations than one run shows (#4199). From every regeneration recorded in `bench/history.csv`, restricted to the same four loose rows above and to the Go/C columns (the Bit column reflects real compiler/runtime changes over that history, not noise): `alloc` c: 1.5-1.7 MB (median 1.6 MB, N=18); `strings` go: 64.3-90.9 MB (median 69.0 MB, N=15). Read that cell's published number as representative of the stated range, not a fixed constant.
> Instructions are published beside cycles because a cycle gap alone does not say whether it is work emitted or work stalled, and the two ratios differ a lot here: Bit retires roughly 4-7 instructions per cycle against C's 1.4-1.8, so its instruction ratio always overstates its cycle ratio. Cycles are the time; instructions are the reason.
> Generated by `bench/run.sh` on 2026-09-09T10:00:52Z. Do not edit by hand.
