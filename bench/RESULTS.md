# Benchmark results: full numbers and method

The README carries the short version. This page keeps every table and the method behind it.

### Runtime: CPU cycles, lower is better

| Benchmark | Bit | Go | C | Bit / Go | Bit / C |
|---|--:|--:|--:|--:|--:|
| fib | 1024.5 M | 949.3 M | 633.9 M | 1.08x | 1.62x |
| mandelbrot | 2132.8 M | 1639.6 M | 1604.6 M | 1.30x | 1.33x |
| collatz | 895.2 M | 617.9 M | 410.7 M | 1.45x | 2.18x |
| alloc | 649.5 M | 415.6 M | 465.0 M | 1.56x | 1.40x |
| allocflat | 156.3 M | 115.5 M | 17.4 M | 1.35x | 8.99x |
| allocpar | 1845.3 M | 1232.3 M | 2024.4 M | 1.50x | 0.91x |
| strings | 223.6 M | 372.4 M | 109.8 M | 0.60x | 2.04x |
| map | 371.1 M | 479.5 M | 203.6 M | 0.77x | 1.82x |
| strmap | 1286.0 M | 705.5 M | 278.9 M | 1.82x | 4.61x |
| sort | 290.9 M | 360.8 M | 275.8 M | 0.81x | 1.05x |
| matrix | 1386.0 M | 960.7 M | 401.2 M | 1.44x | 3.45x |
| json | 761.2 M | 362.6 M | 244.5 M | 2.10x | 3.11x |

### Instructions retired: work emitted, not time taken

| Benchmark | Bit | Go | C |
|---|--:|--:|--:|
| fib | 5300.5 M | 5137.0 M | 3146.3 M |
| mandelbrot | 4787.6 M | 2507.1 M | 2698.9 M |
| collatz | 2581.4 M | 935.7 M | 930.2 M |
| alloc | 5093.7 M | 2165.9 M | 3606.8 M |
| allocflat | 1279.5 M | 405.7 M | 59.0 M |
| allocpar | 7216.3 M | 4602.3 M | 3618.7 M |
| strings | 1714.6 M | 1705.3 M | 644.8 M |
| map | 782.2 M | 696.3 M | 255.0 M |
| strmap | 5749.8 M | 2222.4 M | 538.7 M |
| sort | 1632.7 M | 944.3 M | 503.9 M |
| matrix | 12277.5 M | 7324.3 M | 1656.2 M |
| json | 4765.1 M | 2145.4 M | 1350.3 M |

### Wall clock: median of 15 runs, milliseconds

| Benchmark | Bit | Go | C |
|---|--:|--:|--:|
| fib | 241.0 ms | 222.8 ms | 149.5 ms |
| mandelbrot | 499.1 ms | 383.8 ms | 375.6 ms |
| collatz | 208.0 ms | 140.5 ms | 95.7 ms |
| alloc | 157.7 ms | 86.6 ms | 116.8 ms |
| allocflat | 38.7 ms | 19.5 ms | 6.4 ms |
| allocpar | 69.9 ms | 61.2 ms | 65.1 ms |
| strings | 55.0 ms | 63.0 ms | 28.3 ms |
| map | 91.3 ms | 110.9 ms | 53.5 ms |
| strmap | 306.2 ms | 169.6 ms | 68.5 ms |
| sort | 68.3 ms | 88.3 ms | 68.5 ms |
| matrix | 336.7 ms | 237.3 ms | 99.9 ms |
| json | 150.8 ms | 80.9 ms | 62.9 ms |
| allocpar W1 | 182.1 ms | 105.6 ms | 65.1 ms |
| allocpar W8 | 60.7 ms | 60.9 ms | 65.1 ms |

### GC pauses: one untimed run per case, share of that run's own wall clock

| Benchmark | Bit pauses | Bit pausens ms (share) | Bit pausemax ms | Go GCs | Go STW ms (share) | Go STW max ms | C |
|---|--:|--:|--:|--:|--:|--:|--:|
| fib | 0 | 0.0 ms (0.0%) | 0.0 ms | 0 | 0.0 ms (0.0%) | 0.0 ms | n/a |
| mandelbrot | 0 | 0.0 ms (0.0%) | 0.0 ms | 0 | 0.0 ms (0.0%) | 0.0 ms | n/a |
| collatz | 0 | 0.0 ms (0.0%) | 0.0 ms | 0 | 0.0 ms (0.0%) | 0.0 ms | n/a |
| alloc | 133 | 17.7 ms (11.6%) | 0.4 ms | 69 | 2.0 ms (2.4%) | 0.1 ms | n/a |
| allocflat | 66 | 0.2 ms (0.4%) | 0.0 ms | 78 | 2.6 ms (12.4%) | 0.1 ms | n/a |
| allocpar | 169 | 35.3 ms (55.9%) | 0.5 ms | 70 | 7.1 ms (12.0%) | 0.2 ms | n/a |
| strings | 3 | 0.6 ms (1.0%) | 0.4 ms | 12 | 0.3 ms (0.5%) | 0.0 ms | n/a |
| map | 1 | 0.1 ms (0.1%) | 0.1 ms | 4 | 0.1 ms (0.1%) | 0.0 ms | n/a |
| strmap | 4 | 4.4 ms (1.4%) | 3.7 ms | 2 | 0.1 ms (0.1%) | 0.0 ms | n/a |
| sort | 7 | 6.1 ms (9.0%) | 1.9 ms | 1 | 0.0 ms (0.0%) | 0.0 ms | n/a |
| matrix | 1 | 0.0 ms (0.0%) | 0.0 ms | 1 | 0.0 ms (0.0%) | 0.0 ms | n/a |
| json | 19 | 12.8 ms (8.0%) | 8.1 ms | 10 | 0.4 ms (0.5%) | 0.0 ms | n/a |
| allocpar W1 | 161 | 50.0 ms (27.1%) | 0.5 ms | 78 | 0.0 ms (0.0%) | 0.0 ms | n/a |
| allocpar W8 | 176 | 35.1 ms (60.9%) | 0.4 ms | 82 | 7.7 ms (12.4%) | 0.2 ms | n/a |

### Peak memory: max RSS, lower is better

| Benchmark | Bit | Go | C |
|---|--:|--:|--:|
| fib | 2.3 MB | 4.6 MB | 1.8 MB |
| mandelbrot | 2.2 MB | 4.6 MB | 1.8 MB |
| collatz | 2.2 MB | 4.6 MB | 1.8 MB |
| alloc | 6.7 MB | 11.3 MB | 2.0 MB |
| allocflat | 6.2 MB | 11.4 MB | 1.9 MB |
| allocpar | 10.5 MB | 17.4 MB | 4.0 MB |
| strings | 62.9 MB | 69.2 MB | 31.0 MB |
| map | 37.2 MB | 41.9 MB | 193.8 MB |
| strmap | 35.8 MB | 31.2 MB | 41.2 MB |
| sort | 18.1 MB | 15.2 MB | 11.4 MB |
| matrix | 8.6 MB | 11.4 MB | 7.8 MB |
| json | 129.4 MB | 58.1 MB | 125.5 MB |

### Heap allocations per run: the equivalence check, not a score

| Benchmark | Bit | Go | C |
|---|--:|--:|--:|
| fib | 2 | 189 | 0 |
| mandelbrot | 2 | 189 | 0 |
| collatz | 2 | 189 | 0 |
| alloc | 10006002 | 10002307 | 10004000 |
| allocflat | 4002 | 2294 | 2000 |
| allocpar | 10006015 | 10002394 | 10004000 |
| strings | 33 | 330 | 11 |
| map | 10 | 4366 | 1 |
| strmap | 400037 | 400797 | 400003 |
| sort | 600018 | 150280 | 150002 |
| matrix | 12 | 272 | 3 |
| json | 3750060 | 1049988 | 2250021 |

### Binary size: static, as emitted

| Benchmark | Bit | Go | C |
|---|--:|--:|--:|
| fib | 408 KB | 2373 KB | 33 KB |
| mandelbrot | 408 KB | 2373 KB | 33 KB |
| collatz | 408 KB | 2373 KB | 33 KB |
| alloc | 409 KB | 2390 KB | 33 KB |
| allocflat | 409 KB | 2373 KB | 33 KB |
| allocpar | 429 KB | 2390 KB | 33 KB |
| strings | 410 KB | 2389 KB | 33 KB |
| map | 449 KB | 2390 KB | 33 KB |
| strmap | 466 KB | 2390 KB | 33 KB |
| sort | 411 KB | 2407 KB | 33 KB |
| matrix | 409 KB | 2373 KB | 33 KB |
| json | 502 KB | 3696 KB | 33 KB |

### Startup & compile

| Metric | Bit | Go | C |
|---|--:|--:|--:|
| Process startup (per exec) | 5.136 ms | 5.654 ms | 5.409 ms |

Bit compile speed: **727 lines/sec** (769 lines across 12 cases, warm).

> Machine: Apple M5 Max, macOS 27.0.1. Bit @ `93f13d1b4`, Go go1.27.2, Apple clang version 21.0.0 (clang-2100.3.34.2).
> Method: 15 runs per case per language. Cycles and instructions are a trimmed mean of those runs, meaning the mean after dropping the slowest fifth, which was the most reproducible of four estimators measured over 40 samples per series; wall clock and RSS are the median. C built `cc -O2 -ffp-contract=off`, Go `go build`, Bit `bit build`, each language's standard optimized build.
> Mandelbrot: Bit and C agree to the last bit; Go differs by ~0.0002% because it contracts `a*b+c` to a hardware FMA. Not a bug: cross-compiler float bit-identity is not guaranteed.
> alloc measures the ALLOCATOR: 10M short-lived nodes, each its own heap object in all three languages (Bit's element class has a reference field, Go holds `[]*Node`, C mallocs per node). allocflat measures DATA LAYOUT: the same 10M nodes and the same printed total, stored by value in one buffer per batch (Bit packs `[]Node` inline, Go holds `[]Node`, C mallocs the batch once). The gap between the two rows is what per-node heap allocation costs a language.
> allocpar measures the allocator under CONTENTION: the identical 10M nodes and the identical printed total as alloc, partitioned across 8 concurrent workers (Bit `spawn`, Go goroutines, C pthreads), worker count fixed in all three sources and never read from the host core count. The gap between the alloc and allocpar rows is what a language's allocator costs when more than one thread is in it; every other case in this table is single-mutator, so that cost appears nowhere else.
> The allocation table above is how those two claims are checked rather than asserted: same order of magnitude across a row means the three sources still express the same data structure, which is exactly what `alloc` silently lost for a day. Bit's count is `swept+live` from `BIT_GC_STATS=1`; Go's is `runtime.MemStats.Mallocs` and C's a `malloc` counter, both opt-in (`BENCH_ALLOC_STATS`, `-DBENCH_ALLOC_STATS`) and both absent from every timed binary.
> The ratios are built from CYCLES, not from wall clock. `/usr/bin/time` reports `real` in hundredths of a second and most of the C sides here finish in under 0.10s, so a wall-clock ratio for those rows would be quantisation: `map` published 7.50x C off 0.300s/0.040s where the counters say ~4.5x. Adding runs does not fix that, because it narrows the spread around a quantised value instead of removing the quantisation, so the unit changed. Cycles and instructions come from the same `/usr/bin/time -l` invocation that also produced the RSS; nothing extra is run and nothing extra is installed for those three. Wall clock is a separate one-decimal-millisecond measurement (`wall_run()`, one `fork`+`exec`+`waitpid` perl process per run, not `/usr/bin/time`'s own field) so it stays usable below `/usr/bin/time`'s 10ms floor; it still carries no ratio column and is kept as context.
> GC pauses: one untimed run per case, separate from the timed runs above (BIT_GC_STATS/GODEBUG both add real overhead). Bit's fields are `pausens=`/`pausemaxns=`/`pauses=` from `BIT_GC_STATS=1`. Go's are parsed from one `GODEBUG=gctrace=1` run: each `gc N @Ts P%: A+B+C ms clock` line's A (sweep termination) and C (mark termination) are its two STW segments (`go doc runtime`, go1.27.1), summed for the STW total, maxed individually for the longest single pause; B (concurrent mark) is not a stop and is excluded. C has no collector (n/a). Share is that probe run's own `wall_run()` wall time, not the timed loop's median. `allocpar W1`/`W8` reruns the same probe with `BIT_WORKERS`/`GOMAXPROCS` set; C is unchanged (its worker count is a compile-time `#define`, never read from env) so its wall-table cell reuses the baseline `allocpar` row rather than a redundant rerun.
> Cycles and instructions are startup-corrected: each figure has that language's own empty-program cost (`bench/cases/startup`, bit 5.1M, c 4.9M, go 6.3M) subtracted, because dyld and runtime init differ per language and are a fifth of C's `allocflat` row. Every other table is raw.

> On `matrix`, read the Go column as the target and not the C one. The C side vectorises: it retires 2.06 instructions per inner-loop iteration against Go's 9.09, so the Bit:C ratio on this row compares a scalar loop against a vectorised one and is not a statement about codegen quality. A scalar `cc -O2 -fno-vectorize` control build of the same case retires 8.07, which is the like-for-like figure. Denominator for all three: `trials * n^3 = 6 * 512^3 = 805,306,368` inner iterations.
> Reproducibility was measured rather than assumed: four independent regenerations of this table on this box held every ratio to 2.5% between adjacent runs and 8.5% at worst across all four. The loose rows are `alloc`, `map`, `allocflat` and `strings`, whose Go or C side is short enough that that language's own allocator and collector scheduling moves it by several percent from run to run; `matrix`, `mandelbrot`, `fib` and `sort` reproduce to about 1%. On those four loose rows, read a change under ~3% as noise.
> Peak RSS above is a within-run median like every other figure in that table, but it can still swing further ACROSS separate regenerations than one run shows. From every regeneration recorded in `bench/history.csv`, restricted to the same four loose rows above and to the Go/C columns (the Bit column reflects real compiler/runtime changes over that history, not noise): `alloc` c: 1.5-2.2 MB (median 2.0 MB, N=55); `allocflat` go: 10.6-12.8 MB (median 11.4 MB, N=46); `allocflat` c: 1.5-1.9 MB (median 1.9 MB, N=46); `strings` go: 64.3-100.0 MB (median 73.1 MB, N=52). Read that cell's published number as representative of the stated range, not a fixed constant.
> Instructions are published beside cycles because a cycle gap alone does not say whether it is work emitted or work stalled, and the two ratios differ a lot here: Bit retires roughly 4-7 instructions per cycle against C's 1.4-1.8, so its instruction ratio always overstates its cycle ratio. Cycles are the time; instructions are the reason.
> Generated by `bench/run.sh` on 2026-10-15T06:26:54Z. Do not edit by hand.
