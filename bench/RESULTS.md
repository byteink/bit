_Full method and caveats below the tables._

### Runtime: CPU cycles, lower is better

| Benchmark | Bit | Go | C | Bit / Go | Bit / C |
|---|--:|--:|--:|--:|--:|
| fib | 1029.6 M | 941.9 M | 636.1 M | 1.09x | 1.62x |
| mandelbrot | 2130.9 M | 1640.3 M | 1606.2 M | 1.30x | 1.33x |
| collatz | 896.8 M | 626.3 M | 411.1 M | 1.43x | 2.18x |
| alloc | 1549.6 M | 394.6 M | 641.1 M | 3.93x | 2.42x |
| allocflat | 299.6 M | 121.2 M | 17.9 M | 2.47x | 16.75x |
| strings | 1386.2 M | 366.2 M | 110.0 M | 3.79x | 12.61x |
| map | 425.5 M | 399.4 M | 171.8 M | 1.07x | 2.48x |
| strmap | 1705.1 M | 682.0 M | 254.8 M | 2.50x | 6.69x |
| sort | 511.8 M | 356.5 M | 282.9 M | 1.44x | 1.81x |
| matrix | 3368.7 M | 951.3 M | 398.3 M | 3.54x | 8.46x |
| json | 1897.7 M | 341.2 M | 230.6 M | 5.56x | 8.23x |

### Instructions retired: work emitted, not time taken

| Benchmark | Bit | Go | C |
|---|--:|--:|--:|
| fib | 5963.0 M | 5137.1 M | 3146.8 M |
| mandelbrot | 5005.4 M | 2506.4 M | 2698.9 M |
| collatz | 2715.4 M | 935.2 M | 930.5 M |
| alloc | 11491.4 M | 2161.3 M | 4287.5 M |
| allocflat | 2104.5 M | 403.1 M | 59.3 M |
| strings | 10283.9 M | 1687.3 M | 643.4 M |
| map | 1181.2 M | 693.4 M | 229.3 M |
| strmap | 9099.8 M | 2225.1 M | 539.9 M |
| sort | 2872.5 M | 942.6 M | 508.6 M |
| matrix | 22755.7 M | 7323.6 M | 1656.2 M |
| json | 12800.3 M | 2138.6 M | 1371.5 M |

### Wall clock: median of 15 runs, context only

| Benchmark | Bit | Go | C |
|---|--:|--:|--:|
| fib | 0.240s | 0.220s | 0.140s |
| mandelbrot | 0.490s | 0.380s | 0.370s |
| collatz | 0.200s | 0.130s | 0.090s |
| alloc | 0.360s | 0.080s | 0.150s |
| allocflat | 0.070s | 0.010s | 0.000s |
| strings | 0.320s | 0.060s | 0.020s |
| map | 0.100s | 0.090s | 0.040s |
| strmap | 0.390s | 0.150s | 0.060s |
| sort | 0.120s | 0.080s | 0.060s |
| matrix | 0.790s | 0.220s | 0.090s |
| json | 0.440s | 0.070s | 0.050s |

### Peak memory: max RSS, lower is better

| Benchmark | Bit | Go | C |
|---|--:|--:|--:|
| fib | 1.9 MB | 4.1 MB | 1.4 MB |
| mandelbrot | 1.9 MB | 4.1 MB | 1.4 MB |
| collatz | 2.0 MB | 4.1 MB | 1.4 MB |
| alloc | 5.9 MB | 10.4 MB | 1.7 MB |
| allocflat | 5.8 MB | 11.0 MB | 1.5 MB |
| strings | 130.9 MB | 69.0 MB | 30.7 MB |
| map | 36.4 MB | 41.5 MB | 193.5 MB |
| strmap | 41.6 MB | 30.8 MB | 40.8 MB |
| sort | 31.2 MB | 14.8 MB | 11.0 MB |
| matrix | 8.2 MB | 11.0 MB | 7.5 MB |
| json | 246.7 MB | 60.2 MB | 125.2 MB |

### Heap allocations per run: the equivalence check, not a score

| Benchmark | Bit | Go | C |
|---|--:|--:|--:|
| fib | 6 | n/a | n/a |
| mandelbrot | 6 | n/a | n/a |
| collatz | 6 | n/a | n/a |
| alloc | 10006006 | 10002307 | 10004000 |
| allocflat | 4006 | 2298 | 2000 |
| strings | 7125035 | n/a | n/a |
| map | 14 | n/a | n/a |
| strmap | 400041 | 400805 | 400003 |
| sort | 600022 | n/a | n/a |
| matrix | 16 | 285 | 3 |
| json | 5400062 | n/a | n/a |

### Binary size: static, as emitted

| Benchmark | Bit | Go | C |
|---|--:|--:|--:|
| fib | 251 KB | 2373 KB | 33 KB |
| mandelbrot | 251 KB | 2373 KB | 33 KB |
| collatz | 251 KB | 2373 KB | 33 KB |
| alloc | 252 KB | 2390 KB | 33 KB |
| allocflat | 252 KB | 2373 KB | 33 KB |
| strings | 285 KB | 2373 KB | 33 KB |
| map | 289 KB | 2373 KB | 33 KB |
| strmap | 323 KB | 2390 KB | 33 KB |
| sort | 286 KB | 2391 KB | 33 KB |
| matrix | 251 KB | 2373 KB | 33 KB |
| json | 360 KB | 3678 KB | 33 KB |

### Startup & compile

| Metric | Bit | Go | C |
|---|--:|--:|--:|
| Process startup (per exec) | 3.524 ms | 4.296 ms | 3.281 ms |

Bit compile speed: **387 lines/sec** (669 lines across 11 cases, warm).

> Machine: Apple M5 Max, macOS 26.6.2. Bit @ `411f04ee`, Go go1.27.1, Apple clang version 21.0.0 (clang-2100.1.1.101).
> Method: 15 runs per case per language. Cycles and instructions are a trimmed mean of those runs, meaning the mean after dropping the slowest fifth, which was the most reproducible of four estimators measured over 40 samples per series; wall clock and RSS are the median. C built `cc -O2 -ffp-contract=off`, Go `go build`, Bit `bit build`, each language's standard optimized build.
> Mandelbrot: Bit and C agree to the last bit; Go differs by ~0.0002% because it contracts `a*b+c` to a hardware FMA. Not a bug: cross-compiler float bit-identity is not guaranteed.
> alloc measures the ALLOCATOR: 10M short-lived nodes, each its own heap object in all three languages (Bit's element class has a reference field, Go holds `[]*Node`, C mallocs per node). allocflat measures DATA LAYOUT: the same 10M nodes and the same printed total, stored by value in one buffer per batch (Bit packs `[]Node` inline since #3862, Go holds `[]Node`, C mallocs the batch once). The gap between the two rows is what per-node heap allocation costs a language.
> The allocation table above is how those two claims are checked rather than asserted: same order of magnitude across a row means the three sources still express the same data structure, which is exactly what `alloc` silently lost for a day (#3934). Bit's count is `swept+live` from `BIT_GC_STATS=1`; Go's is `runtime.MemStats.Mallocs` and C's a `malloc` counter, both opt-in (`BENCH_ALLOC_STATS`, `-DBENCH_ALLOC_STATS`) and both absent from every timed binary.
> The ratios are built from CYCLES, not from wall clock. `/usr/bin/time` reports `real` in hundredths of a second and most of the C sides here finish in under 0.10s, so a wall-clock ratio for those rows is quantisation: `map` published 7.50x C off 0.300s/0.040s where the counters say ~4.5x. Adding runs does not fix that, because it narrows the spread around a quantised value instead of removing the quantisation, so the unit changed (#4040). Both counters come from the same `/usr/bin/time -l` invocation that already produced the wall clock and the RSS; nothing extra is run and nothing extra is installed. The wall-clock table is kept as context and carries no ratio column.
> Cycles and instructions are startup-corrected: each figure has that language's own empty-program cost (`bench/cases/startup`, bit 4.4M, c 3.8M, go 5.7M) subtracted, because dyld and runtime init differ per language and are a fifth of C's `allocflat` row. Every other table is raw.
> Reproducibility was measured rather than assumed (#4040): four independent regenerations of this table on this box held every ratio to 2.5% between adjacent runs and 8.5% at worst across all four. The loose rows are `alloc`, `map`, `allocflat` and `strings`, whose Go or C side is short enough that that language's own allocator and collector scheduling moves it by several percent from run to run; `matrix`, `mandelbrot`, `fib` and `sort` reproduce to about 1%. On those four loose rows, read a change under ~3% as noise.
> Peak RSS above is a within-run median like every other figure in that table, but it can still swing further ACROSS separate regenerations than one run shows (#4199). From every regeneration recorded in `bench/history.csv`, restricted to the same four loose rows above and to the Go/C columns (the Bit column reflects real compiler/runtime changes over that history, not noise): `alloc` c: 1.5-1.7 MB (median 1.6 MB, N=15); `strings` go: 64.3-90.9 MB (median 68.9 MB, N=12). Read that cell's published number as representative of the stated range, not a fixed constant.
> Instructions are published beside cycles because a cycle gap alone does not say whether it is work emitted or work stalled, and the two ratios differ a lot here: Bit retires roughly 4-7 instructions per cycle against C's 1.4-1.8, so its instruction ratio always overstates its cycle ratio. Cycles are the time; instructions are the reason.
> Generated by `bench/run.sh` on 2026-09-06T14:00:21Z. Do not edit by hand.
