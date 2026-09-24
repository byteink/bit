_Full method and caveats below the tables._

### Runtime: CPU cycles, lower is better

| Benchmark | Bit | Go | C | Bit / Go | Bit / C |
|---|--:|--:|--:|--:|--:|
| fib | 1005.4 M | 938.4 M | 636.0 M | 1.07x | 1.58x |
| mandelbrot | 2133.6 M | 1638.0 M | 1605.2 M | 1.30x | 1.33x |
| collatz | 920.9 M | 626.3 M | 411.2 M | 1.47x | 2.24x |
| alloc | 993.5 M | 388.5 M | 464.3 M | 2.56x | 2.14x |
| allocflat | 252.9 M | 114.7 M | 17.9 M | 2.21x | 14.11x |
| allocpar | 1755.5 M | 1263.2 M | 2112.2 M | 1.39x | 0.83x |
| strings | 211.5 M | 382.6 M | 109.2 M | 0.55x | 1.94x |
| map | 300.5 M | 373.8 M | 177.2 M | 0.80x | 1.70x |
| strmap | 1276.4 M | 678.0 M | 250.3 M | 1.88x | 5.10x |
| sort | 294.7 M | 357.2 M | 279.4 M | 0.83x | 1.05x |
| matrix | 1381.1 M | 950.9 M | 398.4 M | 1.45x | 3.47x |
| json | 890.9 M | 337.6 M | 227.7 M | 2.64x | 3.91x |

### Instructions retired: work emitted, not time taken

| Benchmark | Bit | Go | C |
|---|--:|--:|--:|
| fib | 5962.5 M | 5137.0 M | 3146.6 M |
| mandelbrot | 4788.3 M | 2506.2 M | 2698.7 M |
| collatz | 2578.8 M | 935.5 M | 930.5 M |
| alloc | 7632.5 M | 2161.0 M | 3606.8 M |
| allocflat | 1604.8 M | 404.3 M | 59.3 M |
| allocpar | 12151.0 M | 4585.5 M | 3620.9 M |
| strings | 1689.4 M | 1739.7 M | 643.4 M |
| map | 760.1 M | 693.4 M | 229.2 M |
| strmap | 6348.3 M | 2225.0 M | 534.2 M |
| sort | 1791.2 M | 943.0 M | 503.7 M |
| matrix | 12279.6 M | 7323.8 M | 1656.2 M |
| json | 5906.5 M | 2127.4 M | 1339.8 M |

### Wall clock: median of 15 runs, context only

| Benchmark | Bit | Go | C |
|---|--:|--:|--:|
| fib | 0.230s | 0.210s | 0.140s |
| mandelbrot | 0.470s | 0.360s | 0.350s |
| collatz | 0.200s | 0.130s | 0.090s |
| alloc | 0.230s | 0.070s | 0.100s |
| allocflat | 0.050s | 0.010s | 0.000s |
| allocpar | 0.230s | 0.060s | 0.060s |
| strings | 0.050s | 0.050s | 0.020s |
| map | 0.060s | 0.080s | 0.040s |
| strmap | 0.290s | 0.150s | 0.050s |
| sort | 0.060s | 0.080s | 0.060s |
| matrix | 0.310s | 0.210s | 0.090s |
| json | 0.200s | 0.070s | 0.050s |

### Peak memory: max RSS, lower is better

| Benchmark | Bit | Go | C |
|---|--:|--:|--:|
| fib | 2.2 MB | 4.6 MB | 1.8 MB |
| mandelbrot | 2.2 MB | 4.6 MB | 1.8 MB |
| collatz | 2.3 MB | 4.6 MB | 1.8 MB |
| alloc | 6.5 MB | 10.8 MB | 2.0 MB |
| allocflat | 6.1 MB | 11.5 MB | 1.9 MB |
| allocpar | 13.4 MB | 18.3 MB | 3.9 MB |
| strings | 78.6 MB | 69.4 MB | 31.0 MB |
| map | 36.7 MB | 41.9 MB | 193.8 MB |
| strmap | 39.3 MB | 31.2 MB | 41.2 MB |
| sort | 25.9 MB | 15.2 MB | 11.4 MB |
| matrix | 8.5 MB | 11.4 MB | 7.8 MB |
| json | 128.8 MB | 55.1 MB | 125.5 MB |

### Heap allocations per run: the equivalence check, not a score

| Benchmark | Bit | Go | C |
|---|--:|--:|--:|
| fib | 6 | 202 | 0 |
| mandelbrot | 6 | 196 | 0 |
| collatz | 6 | 196 | 0 |
| alloc | 10006006 | 10002301 | 10004000 |
| allocflat | 4006 | 2312 | 2000 |
| allocpar | 10005960 | 10002424 | 10004000 |
| strings | 37 | 340 | 11 |
| map | 14 | 4373 | 1 |
| strmap | 400041 | 400804 | 400003 |
| sort | 600022 | 150286 | 150002 |
| matrix | 16 | 279 | 3 |
| json | 3750066 | 1049989 | 2250021 |

### Binary size: static, as emitted

| Benchmark | Bit | Go | C |
|---|--:|--:|--:|
| fib | 272 KB | 2373 KB | 33 KB |
| mandelbrot | 272 KB | 2373 KB | 33 KB |
| collatz | 272 KB | 2373 KB | 33 KB |
| alloc | 273 KB | 2390 KB | 33 KB |
| allocflat | 272 KB | 2373 KB | 33 KB |
| allocpar | 292 KB | 2390 KB | 33 KB |
| strings | 274 KB | 2389 KB | 33 KB |
| map | 311 KB | 2390 KB | 33 KB |
| strmap | 329 KB | 2390 KB | 33 KB |
| sort | 291 KB | 2407 KB | 33 KB |
| matrix | 273 KB | 2373 KB | 33 KB |
| json | 382 KB | 3679 KB | 33 KB |

### Startup & compile

| Metric | Bit | Go | C |
|---|--:|--:|--:|
| Process startup (per exec) | 4.367 ms | 4.691 ms | 4.273 ms |

Bit compile speed: **596 lines/sec** (769 lines across 12 cases, warm).

> Machine: Apple M5 Max, macOS 27.0. Bit @ `b8de2e1a8`, Go go1.27.1, Apple clang version 21.0.0 (clang-2100.3.34.2).
> Method: 15 runs per case per language. Cycles and instructions are a trimmed mean of those runs, meaning the mean after dropping the slowest fifth, which was the most reproducible of four estimators measured over 40 samples per series; wall clock and RSS are the median. C built `cc -O2 -ffp-contract=off`, Go `go build`, Bit `bit build`, each language's standard optimized build.
> Mandelbrot: Bit and C agree to the last bit; Go differs by ~0.0002% because it contracts `a*b+c` to a hardware FMA. Not a bug: cross-compiler float bit-identity is not guaranteed.
> alloc measures the ALLOCATOR: 10M short-lived nodes, each its own heap object in all three languages (Bit's element class has a reference field, Go holds `[]*Node`, C mallocs per node). allocflat measures DATA LAYOUT: the same 10M nodes and the same printed total, stored by value in one buffer per batch (Bit packs `[]Node` inline, Go holds `[]Node`, C mallocs the batch once). The gap between the two rows is what per-node heap allocation costs a language.
> allocpar measures the allocator under CONTENTION: the identical 10M nodes and the identical printed total as alloc, partitioned across 8 concurrent workers (Bit `spawn`, Go goroutines, C pthreads), worker count fixed in all three sources and never read from the host core count. The gap between the alloc and allocpar rows is what a language's allocator costs when more than one thread is in it; every other case in this table is single-mutator, so that cost appears nowhere else.
> The allocation table above is how those two claims are checked rather than asserted: same order of magnitude across a row means the three sources still express the same data structure, which is exactly what `alloc` silently lost for a day. Bit's count is `swept+live` from `BIT_GC_STATS=1`; Go's is `runtime.MemStats.Mallocs` and C's a `malloc` counter, both opt-in (`BENCH_ALLOC_STATS`, `-DBENCH_ALLOC_STATS`) and both absent from every timed binary.
> The ratios are built from CYCLES, not from wall clock. `/usr/bin/time` reports `real` in hundredths of a second and most of the C sides here finish in under 0.10s, so a wall-clock ratio for those rows is quantisation: `map` published 7.50x C off 0.300s/0.040s where the counters say ~4.5x. Adding runs does not fix that, because it narrows the spread around a quantised value instead of removing the quantisation, so the unit changed. Both counters come from the same `/usr/bin/time -l` invocation that already produced the wall clock and the RSS; nothing extra is run and nothing extra is installed. The wall-clock table is kept as context and carries no ratio column.
> Cycles and instructions are startup-corrected: each figure has that language's own empty-program cost (`bench/cases/startup`, bit 4.8M, c 3.9M, go 6.0M) subtracted, because dyld and runtime init differ per language and are a fifth of C's `allocflat` row. Every other table is raw.

> On `matrix`, read the Go column as the target and not the C one. The C side vectorises: it retires 2.06 instructions per inner-loop iteration against Go's 9.09, so the Bit:C ratio on this row compares a scalar loop against a vectorised one and is not a statement about codegen quality. A scalar `cc -O2 -fno-vectorize` control build of the same case retires 8.07, which is the like-for-like figure. Denominator for all three: `trials * n^3 = 6 * 512^3 = 805,306,368` inner iterations.
> Reproducibility was measured rather than assumed: four independent regenerations of this table on this box held every ratio to 2.5% between adjacent runs and 8.5% at worst across all four. The loose rows are `alloc`, `map`, `allocflat` and `strings`, whose Go or C side is short enough that that language's own allocator and collector scheduling moves it by several percent from run to run; `matrix`, `mandelbrot`, `fib` and `sort` reproduce to about 1%. On those four loose rows, read a change under ~3% as noise.
> Peak RSS above is a within-run median like every other figure in that table, but it can still swing further ACROSS separate regenerations than one run shows. From every regeneration recorded in `bench/history.csv`, restricted to the same four loose rows above and to the Go/C columns (the Bit column reflects real compiler/runtime changes over that history, not noise): `alloc` c: 1.5-2.0 MB (median 1.6 MB, N=38); `allocflat` go: 10.6-12.0 MB (median 11.4 MB, N=29); `allocflat` c: 1.5-1.9 MB (median 1.5 MB, N=29); `strings` go: 64.3-90.9 MB (median 70.4 MB, N=35). Read that cell's published number as representative of the stated range, not a fixed constant.
> Instructions are published beside cycles because a cycle gap alone does not say whether it is work emitted or work stalled, and the two ratios differ a lot here: Bit retires roughly 4-7 instructions per cycle against C's 1.4-1.8, so its instruction ratio always overstates its cycle ratio. Cycles are the time; instructions are the reason.
> Generated by `bench/run.sh` on 2026-09-24T11:38:33Z. Do not edit by hand.
