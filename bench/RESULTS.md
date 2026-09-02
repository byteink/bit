_Full method and caveats below the tables._

### Runtime: CPU cycles, lower is better

| Benchmark | Bit | Go | C | Bit / Go | Bit / C |
|---|--:|--:|--:|--:|--:|
| fib | 1065.1 M | 939.7 M | 631.5 M | 1.13x | 1.69x |
| mandelbrot | 2153.1 M | 1638.6 M | 1606.4 M | 1.31x | 1.34x |
| collatz | 1178.5 M | 627.1 M | 411.9 M | 1.88x | 2.86x |
| alloc | 2053.6 M | 394.0 M | 643.1 M | 5.21x | 3.19x |
| allocflat | 334.8 M | 117.9 M | 17.5 M | 2.84x | 19.17x |
| strings | 2419.2 M | 372.9 M | 108.5 M | 6.49x | 22.29x |
| map | 612.3 M | 365.5 M | 167.9 M | 1.68x | 3.65x |
| sort | 878.6 M | 357.3 M | 284.0 M | 2.46x | 3.09x |
| matrix | 6731.9 M | 952.1 M | 398.4 M | 7.07x | 16.90x |
| json | 3837.4 M | 339.2 M | 231.4 M | 11.31x | 16.59x |

### Instructions retired: work emitted, not time taken

| Benchmark | Bit | Go | C |
|---|--:|--:|--:|
| fib | 6790.3 M | 5136.5 M | 3146.6 M |
| mandelbrot | 8527.7 M | 2506.1 M | 2698.8 M |
| collatz | 5400.2 M | 935.3 M | 930.6 M |
| alloc | 13984.2 M | 2157.8 M | 4287.6 M |
| allocflat | 2750.3 M | 401.1 M | 59.3 M |
| strings | 15858.3 M | 1714.9 M | 643.2 M |
| map | 1953.7 M | 693.1 M | 228.9 M |
| sort | 5685.9 M | 942.7 M | 508.6 M |
| matrix | 51908.9 M | 7323.3 M | 1656.1 M |
| json | 25625.0 M | 2135.3 M | 1371.4 M |

### Wall clock: median of 15 runs, context only

| Benchmark | Bit | Go | C |
|---|--:|--:|--:|
| fib | 0.240s | 0.220s | 0.140s |
| mandelbrot | 0.500s | 0.370s | 0.370s |
| collatz | 0.270s | 0.140s | 0.090s |
| alloc | 0.480s | 0.080s | 0.150s |
| allocflat | 0.070s | 0.010s | 0.000s |
| strings | 0.560s | 0.050s | 0.020s |
| map | 0.140s | 0.080s | 0.040s |
| sort | 0.200s | 0.080s | 0.060s |
| matrix | 1.560s | 0.220s | 0.090s |
| json | 0.890s | 0.070s | 0.050s |

### Peak memory: max RSS, lower is better

| Benchmark | Bit | Go | C |
|---|--:|--:|--:|
| fib | 1.9 MB | 4.1 MB | 1.4 MB |
| mandelbrot | 1.9 MB | 4.1 MB | 1.4 MB |
| collatz | 2.0 MB | 4.1 MB | 1.4 MB |
| alloc | 5.9 MB | 10.6 MB | 1.6 MB |
| allocflat | 5.7 MB | 11.4 MB | 1.5 MB |
| strings | 130.8 MB | 68.9 MB | 30.7 MB |
| map | 36.3 MB | 41.5 MB | 193.5 MB |
| sort | 31.1 MB | 14.8 MB | 11.0 MB |
| matrix | 8.2 MB | 11.0 MB | 7.5 MB |
| json | 287.7 MB | 55.9 MB | 125.2 MB |

### Heap allocations per run: the equivalence check, not a score

| Benchmark | Bit | Go | C |
|---|--:|--:|--:|
| fib | 6 | n/a | n/a |
| mandelbrot | 6 | n/a | n/a |
| collatz | 6 | n/a | n/a |
| alloc | 10006006 | 10002302 | 10004000 |
| allocflat | 4006 | 2300 | 2000 |
| strings | 7125035 | n/a | n/a |
| map | 14 | n/a | n/a |
| sort | 600026 | n/a | n/a |
| matrix | 16 | 285 | 3 |
| json | 6000056 | n/a | n/a |

### Binary size: static, as emitted

| Benchmark | Bit | Go | C |
|---|--:|--:|--:|
| fib | 249 KB | 2373 KB | 33 KB |
| mandelbrot | 249 KB | 2373 KB | 33 KB |
| collatz | 249 KB | 2373 KB | 33 KB |
| alloc | 250 KB | 2390 KB | 33 KB |
| allocflat | 250 KB | 2373 KB | 33 KB |
| strings | 267 KB | 2373 KB | 33 KB |
| map | 285 KB | 2373 KB | 33 KB |
| sort | 284 KB | 2391 KB | 33 KB |
| matrix | 249 KB | 2373 KB | 33 KB |
| json | 373 KB | 3678 KB | 33 KB |

### Startup & compile

| Metric | Bit | Go | C |
|---|--:|--:|--:|
| Process startup (per exec) | 3.558 ms | 5.327 ms | 3.363 ms |

Bit compile speed: **336 lines/sec** (519 lines across 10 cases, warm).

> Machine: Apple M5 Max, macOS 26.6.2. Bit @ `0282a1c9`, Go go1.27.1, Apple clang version 21.0.0 (clang-2100.1.1.101).
> Method: 15 runs per case per language. Cycles and instructions are a trimmed mean of those runs, meaning the mean after dropping the slowest fifth, which was the most reproducible of four estimators measured over 40 samples per series; wall clock and RSS are the median. C built `cc -O2 -ffp-contract=off`, Go `go build`, Bit `bit build`, each language's standard optimized build.
> Mandelbrot: Bit and C agree to the last bit; Go differs by ~0.0002% because it contracts `a*b+c` to a hardware FMA. Not a bug: cross-compiler float bit-identity is not guaranteed.
> alloc measures the ALLOCATOR: 10M short-lived nodes, each its own heap object in all three languages (Bit's element class has a reference field, Go holds `[]*Node`, C mallocs per node). allocflat measures DATA LAYOUT: the same 10M nodes and the same printed total, stored by value in one buffer per batch (Bit packs `[]Node` inline since #3862, Go holds `[]Node`, C mallocs the batch once). The gap between the two rows is what per-node heap allocation costs a language.
> The allocation table above is how those two claims are checked rather than asserted: same order of magnitude across a row means the three sources still express the same data structure, which is exactly what `alloc` silently lost for a day (#3934). Bit's count is `swept+live` from `BIT_GC_STATS=1`; Go's is `runtime.MemStats.Mallocs` and C's a `malloc` counter, both opt-in (`BENCH_ALLOC_STATS`, `-DBENCH_ALLOC_STATS`) and both absent from every timed binary.
> The ratios are built from CYCLES, not from wall clock. `/usr/bin/time` reports `real` in hundredths of a second and most of the C sides here finish in under 0.10s, so a wall-clock ratio for those rows is quantisation: `map` published 7.50x C off 0.300s/0.040s where the counters say ~4.5x. Adding runs does not fix that, because it narrows the spread around a quantised value instead of removing the quantisation, so the unit changed (#4040). Both counters come from the same `/usr/bin/time -l` invocation that already produced the wall clock and the RSS; nothing extra is run and nothing extra is installed. The wall-clock table is kept as context and carries no ratio column.
> Cycles and instructions are startup-corrected: each figure has that language's own empty-program cost (`bench/cases/startup`, bit 4.3M, c 3.7M, go 5.5M) subtracted, because dyld and runtime init differ per language and are a fifth of C's `allocflat` row. Every other table is raw.
> Reproducibility was measured rather than assumed (#4040): four independent regenerations of this table on this box held every ratio to 2.5% between adjacent runs and 8.5% at worst across all four. The loose rows are `alloc`, `map`, `allocflat` and `strings`, whose Go or C side is short enough that that language's own allocator and collector scheduling moves it by several percent from run to run; `matrix`, `mandelbrot`, `fib` and `sort` reproduce to about 1%. On those four loose rows, read a change under ~3% as noise.
> Instructions are published beside cycles because a cycle gap alone does not say whether it is work emitted or work stalled, and the two ratios differ a lot here: Bit retires roughly 4-7 instructions per cycle against C's 1.4-1.8, so its instruction ratio always overstates its cycle ratio. Cycles are the time; instructions are the reason.
> Generated by `bench/run.sh` on 2026-09-02T23:14:20Z. Do not edit by hand.
