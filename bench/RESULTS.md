_Full method and caveats below the tables._

### Runtime: CPU cycles, lower is better

| Benchmark | Bit | Go | C | Bit / Go | Bit / C |
|---|--:|--:|--:|--:|--:|
| fib | 1006.0 M | 946.9 M | 635.3 M | 1.06x | 1.58x |
| mandelbrot | 2133.2 M | 1637.7 M | 1605.1 M | 1.30x | 1.33x |
| collatz | 921.3 M | 626.3 M | 411.1 M | 1.47x | 2.24x |
| alloc | 990.8 M | 389.5 M | 470.7 M | 2.54x | 2.10x |
| allocflat | 255.2 M | 115.5 M | 17.9 M | 2.21x | 14.23x |
| allocpar | 15318.2 M | 1259.8 M | 2140.3 M | 12.16x | 7.16x |
| strings | 211.5 M | 380.5 M | 109.5 M | 0.56x | 1.93x |
| map | 297.1 M | 373.2 M | 179.3 M | 0.80x | 1.66x |
| strmap | 1268.7 M | 677.9 M | 249.6 M | 1.87x | 5.08x |
| sort | 298.4 M | 356.2 M | 276.2 M | 0.84x | 1.08x |
| matrix | 1381.4 M | 951.7 M | 398.6 M | 1.45x | 3.47x |
| json | 888.2 M | 338.8 M | 225.7 M | 2.62x | 3.94x |

### Instructions retired: work emitted, not time taken

| Benchmark | Bit | Go | C |
|---|--:|--:|--:|
| fib | 5962.3 M | 5136.8 M | 3146.5 M |
| mandelbrot | 4788.4 M | 2506.2 M | 2698.6 M |
| collatz | 2578.9 M | 935.4 M | 930.5 M |
| alloc | 7612.1 M | 2159.3 M | 3606.8 M |
| allocflat | 1604.8 M | 404.8 M | 59.3 M |
| allocpar | 13709.7 M | 4585.3 M | 3620.9 M |
| strings | 1689.5 M | 1734.5 M | 643.4 M |
| map | 748.5 M | 693.4 M | 229.6 M |
| strmap | 6215.6 M | 2212.9 M | 534.2 M |
| sort | 1795.7 M | 942.9 M | 503.6 M |
| matrix | 12279.7 M | 7323.8 M | 1656.2 M |
| json | 5920.8 M | 2137.5 M | 1340.0 M |

### Wall clock: median of 15 runs, context only

| Benchmark | Bit | Go | C |
|---|--:|--:|--:|
| fib | 0.230s | 0.220s | 0.140s |
| mandelbrot | 0.470s | 0.360s | 0.360s |
| collatz | 0.200s | 0.130s | 0.090s |
| alloc | 0.220s | 0.070s | 0.100s |
| allocflat | 0.060s | 0.020s | 0.000s |
| allocpar | 0.670s | 0.060s | 0.060s |
| strings | 0.050s | 0.050s | 0.020s |
| map | 0.060s | 0.080s | 0.040s |
| strmap | 0.290s | 0.150s | 0.050s |
| sort | 0.070s | 0.080s | 0.060s |
| matrix | 0.310s | 0.220s | 0.090s |
| json | 0.200s | 0.070s | 0.050s |

### Peak memory: max RSS, lower is better

| Benchmark | Bit | Go | C |
|---|--:|--:|--:|
| fib | 2.2 MB | 4.6 MB | 1.8 MB |
| mandelbrot | 2.2 MB | 4.6 MB | 1.8 MB |
| collatz | 2.3 MB | 4.6 MB | 1.8 MB |
| alloc | 6.5 MB | 10.8 MB | 2.0 MB |
| allocflat | 6.1 MB | 12.0 MB | 1.9 MB |
| allocpar | 12.3 MB | 18.4 MB | 3.8 MB |
| strings | 78.6 MB | 69.2 MB | 31.0 MB |
| map | 36.7 MB | 41.9 MB | 193.8 MB |
| strmap | 39.3 MB | 31.1 MB | 41.2 MB |
| sort | 25.8 MB | 15.2 MB | 11.4 MB |
| matrix | 8.5 MB | 11.4 MB | 7.8 MB |
| json | 128.8 MB | 56.5 MB | 125.5 MB |

### Heap allocations per run: the equivalence check, not a score

| Benchmark | Bit | Go | C |
|---|--:|--:|--:|
| fib | 6 | 196 | 0 |
| mandelbrot | 6 | 196 | 0 |
| collatz | 6 | 196 | 0 |
| alloc | 10006006 | 10002303 | 10004000 |
| allocflat | 4006 | 2301 | 2000 |
| allocpar | 10006053 | 10002412 | 10004000 |
| strings | 37 | 341 | 11 |
| map | 14 | 4379 | 1 |
| strmap | 400041 | 400798 | 400003 |
| sort | 600022 | 150286 | 150002 |
| matrix | 16 | 285 | 3 |
| json | 3750066 | 1049993 | 2250021 |

### Binary size: static, as emitted

| Benchmark | Bit | Go | C |
|---|--:|--:|--:|
| fib | 271 KB | 2373 KB | 33 KB |
| mandelbrot | 271 KB | 2373 KB | 33 KB |
| collatz | 271 KB | 2373 KB | 33 KB |
| alloc | 272 KB | 2390 KB | 33 KB |
| allocflat | 272 KB | 2373 KB | 33 KB |
| allocpar | 291 KB | 2390 KB | 33 KB |
| strings | 273 KB | 2389 KB | 33 KB |
| map | 310 KB | 2390 KB | 33 KB |
| strmap | 328 KB | 2390 KB | 33 KB |
| sort | 291 KB | 2407 KB | 33 KB |
| matrix | 272 KB | 2373 KB | 33 KB |
| json | 381 KB | 3679 KB | 33 KB |

### Startup & compile

| Metric | Bit | Go | C |
|---|--:|--:|--:|
| Process startup (per exec) | 4.291 ms | 4.835 ms | 4.121 ms |

Bit compile speed: **601 lines/sec** (769 lines across 12 cases, warm).

> Machine: Apple M5 Max, macOS 27.0. Bit @ `5b65f1755`, Go go1.27.1, Apple clang version 21.0.0 (clang-2100.3.34.2).
> Method: 15 runs per case per language. Cycles and instructions are a trimmed mean of those runs, meaning the mean after dropping the slowest fifth, which was the most reproducible of four estimators measured over 40 samples per series; wall clock and RSS are the median. C built `cc -O2 -ffp-contract=off`, Go `go build`, Bit `bit build`, each language's standard optimized build.
> Mandelbrot: Bit and C agree to the last bit; Go differs by ~0.0002% because it contracts `a*b+c` to a hardware FMA. Not a bug: cross-compiler float bit-identity is not guaranteed.
> alloc measures the ALLOCATOR: 10M short-lived nodes, each its own heap object in all three languages (Bit's element class has a reference field, Go holds `[]*Node`, C mallocs per node). allocflat measures DATA LAYOUT: the same 10M nodes and the same printed total, stored by value in one buffer per batch (Bit packs `[]Node` inline, Go holds `[]Node`, C mallocs the batch once). The gap between the two rows is what per-node heap allocation costs a language.
> allocpar measures the allocator under CONTENTION: the identical 10M nodes and the identical printed total as alloc, partitioned across 8 concurrent workers (Bit `spawn`, Go goroutines, C pthreads), worker count fixed in all three sources and never read from the host core count. The gap between the alloc and allocpar rows is what a language's allocator costs when more than one thread is in it; every other case in this table is single-mutator, so that cost appears nowhere else.
> The allocation table above is how those two claims are checked rather than asserted: same order of magnitude across a row means the three sources still express the same data structure, which is exactly what `alloc` silently lost for a day. Bit's count is `swept+live` from `BIT_GC_STATS=1`; Go's is `runtime.MemStats.Mallocs` and C's a `malloc` counter, both opt-in (`BENCH_ALLOC_STATS`, `-DBENCH_ALLOC_STATS`) and both absent from every timed binary.
> The ratios are built from CYCLES, not from wall clock. `/usr/bin/time` reports `real` in hundredths of a second and most of the C sides here finish in under 0.10s, so a wall-clock ratio for those rows is quantisation: `map` published 7.50x C off 0.300s/0.040s where the counters say ~4.5x. Adding runs does not fix that, because it narrows the spread around a quantised value instead of removing the quantisation, so the unit changed. Both counters come from the same `/usr/bin/time -l` invocation that already produced the wall clock and the RSS; nothing extra is run and nothing extra is installed. The wall-clock table is kept as context and carries no ratio column.
> Cycles and instructions are startup-corrected: each figure has that language's own empty-program cost (`bench/cases/startup`, bit 4.9M, c 4.0M, go 6.0M) subtracted, because dyld and runtime init differ per language and are a fifth of C's `allocflat` row. Every other table is raw.

> On `matrix`, read the Go column as the target and not the C one. The C side vectorises: it retires 2.06 instructions per inner-loop iteration against Go's 9.09, so the Bit:C ratio on this row compares a scalar loop against a vectorised one and is not a statement about codegen quality. A scalar `cc -O2 -fno-vectorize` control build of the same case retires 8.07, which is the like-for-like figure. Denominator for all three: `trials * n^3 = 6 * 512^3 = 805,306,368` inner iterations.
> Reproducibility was measured rather than assumed: four independent regenerations of this table on this box held every ratio to 2.5% between adjacent runs and 8.5% at worst across all four. The loose rows are `alloc`, `map`, `allocflat` and `strings`, whose Go or C side is short enough that that language's own allocator and collector scheduling moves it by several percent from run to run; `matrix`, `mandelbrot`, `fib` and `sort` reproduce to about 1%. On those four loose rows, read a change under ~3% as noise.
> Peak RSS above is a within-run median like every other figure in that table, but it can still swing further ACROSS separate regenerations than one run shows. From every regeneration recorded in `bench/history.csv`, restricted to the same four loose rows above and to the Go/C columns (the Bit column reflects real compiler/runtime changes over that history, not noise): `alloc` c: 1.5-2.0 MB (median 1.6 MB, N=36); `allocflat` go: 10.6-12.0 MB (median 11.3 MB, N=27); `allocflat` c: 1.5-1.9 MB (median 1.5 MB, N=27); `strings` go: 64.3-90.9 MB (median 70.4 MB, N=33). Read that cell's published number as representative of the stated range, not a fixed constant.
> Instructions are published beside cycles because a cycle gap alone does not say whether it is work emitted or work stalled, and the two ratios differ a lot here: Bit retires roughly 4-7 instructions per cycle against C's 1.4-1.8, so its instruction ratio always overstates its cycle ratio. Cycles are the time; instructions are the reason.
> Generated by `bench/run.sh` on 2026-09-23T21:35:29Z. Do not edit by hand.
