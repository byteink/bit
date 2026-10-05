# Benchmark results: full numbers and method

The README carries the short version. This page keeps every table and the method behind it.

### Runtime: CPU cycles, lower is better

| Benchmark | Bit | Go | C | Bit / Go | Bit / C |
|---|--:|--:|--:|--:|--:|
| fib | 1019.6 M | 939.0 M | 638.8 M | 1.09x | 1.60x |
| mandelbrot | 2134.8 M | 1639.3 M | 1607.3 M | 1.30x | 1.33x |
| collatz | 918.9 M | 626.7 M | 411.8 M | 1.47x | 2.23x |
| alloc | 703.8 M | 397.9 M | 466.5 M | 1.77x | 1.51x |
| allocflat | 213.5 M | 128.4 M | 18.4 M | 1.66x | 11.61x |
| allocpar | 2302.7 M | 1304.4 M | 2028.2 M | 1.77x | 1.14x |
| strings | 215.2 M | 366.9 M | 110.1 M | 0.59x | 1.95x |
| map | 334.9 M | 408.3 M | 180.7 M | 0.82x | 1.85x |
| strmap | 1286.8 M | 683.4 M | 261.2 M | 1.88x | 4.93x |
| sort | 301.0 M | 359.4 M | 278.8 M | 0.84x | 1.08x |
| matrix | 1387.1 M | 953.9 M | 399.4 M | 1.45x | 3.47x |
| json | 762.0 M | 342.4 M | 230.8 M | 2.23x | 3.30x |

### Instructions retired: work emitted, not time taken

| Benchmark | Bit | Go | C |
|---|--:|--:|--:|
| fib | 5300.7 M | 5137.3 M | 3146.8 M |
| mandelbrot | 4789.5 M | 2506.9 M | 2699.1 M |
| collatz | 2579.2 M | 935.6 M | 930.6 M |
| alloc | 5405.0 M | 2161.8 M | 3606.9 M |
| allocflat | 1486.1 M | 410.9 M | 59.3 M |
| allocpar | 7602.8 M | 4592.0 M | 3615.5 M |
| strings | 1693.8 M | 1695.7 M | 643.5 M |
| map | 763.7 M | 693.9 M | 229.7 M |
| strmap | 6249.8 M | 2218.3 M | 534.3 M |
| sort | 1729.7 M | 943.4 M | 503.8 M |
| matrix | 12288.3 M | 7324.3 M | 1656.4 M |
| json | 4966.3 M | 2138.1 M | 1340.0 M |

### Wall clock: median of 15 runs, milliseconds

| Benchmark | Bit | Go | C |
|---|--:|--:|--:|
| fib | 236.7 ms | 221.6 ms | 148.0 ms |
| mandelbrot | 495.5 ms | 374.2 ms | 371.1 ms |
| collatz | 210.2 ms | 140.4 ms | 92.7 ms |
| alloc | 164.8 ms | 81.5 ms | 112.7 ms |
| allocflat | 52.1 ms | 20.0 ms | 6.4 ms |
| allocpar | 80.2 ms | 62.0 ms | 65.1 ms |
| strings | 52.9 ms | 61.2 ms | 28.2 ms |
| map | 79.0 ms | 92.6 ms | 47.0 ms |
| strmap | 291.8 ms | 159.8 ms | 63.7 ms |
| sort | 70.3 ms | 86.2 ms | 67.4 ms |
| matrix | 325.9 ms | 225.3 ms | 95.3 ms |
| json | 151.8 ms | 75.7 ms | 57.7 ms |
| allocpar W1 | 192.9 ms | 106.5 ms | 65.1 ms |
| allocpar W8 | 66.6 ms | 60.9 ms | 65.1 ms |

### GC pauses: one untimed run per case, share of that run's own wall clock

| Benchmark | Bit pauses | Bit pausens ms (share) | Bit pausemax ms | Go GCs | Go STW ms (share) | Go STW max ms | C |
|---|--:|--:|--:|--:|--:|--:|--:|
| fib | 0 | 0.0 ms (0.0%) | 0.0 ms | 0 | 0.0 ms (0.0%) | 0.0 ms | n/a |
| mandelbrot | 0 | 0.0 ms (0.0%) | 0.0 ms | 0 | 0.0 ms (0.0%) | 0.0 ms | n/a |
| collatz | 0 | 0.0 ms (0.0%) | 0.0 ms | 0 | 0.0 ms (0.0%) | 0.0 ms | n/a |
| alloc | 133 | 19.4 ms (11.8%) | 0.2 ms | 69 | 2.1 ms (2.5%) | 0.0 ms | n/a |
| allocflat | 66 | 2.8 ms (4.5%) | 0.1 ms | 77 | 2.3 ms (12.0%) | 0.0 ms | n/a |
| allocpar | 165 | 44.8 ms (59.4%) | 0.5 ms | 76 | 9.8 ms (12.9%) | 0.2 ms | n/a |
| strings | 3 | 0.3 ms (0.6%) | 0.2 ms | 11 | 0.3 ms (0.5%) | 0.0 ms | n/a |
| map | 1 | 0.0 ms (0.0%) | 0.0 ms | 4 | 0.1 ms (0.1%) | 0.0 ms | n/a |
| strmap | 4 | 6.5 ms (2.3%) | 4.9 ms | 2 | 0.1 ms (0.1%) | 0.0 ms | n/a |
| sort | 7 | 5.6 ms (8.2%) | 1.7 ms | 1 | 0.0 ms (0.0%) | 0.0 ms | n/a |
| matrix | 1 | 0.0 ms (0.0%) | 0.0 ms | 1 | 0.0 ms (0.0%) | 0.0 ms | n/a |
| json | 17 | 10.9 ms (7.0%) | 7.0 ms | 10 | 0.3 ms (0.4%) | 0.1 ms | n/a |
| allocpar W1 | 154 | 44.8 ms (23.4%) | 0.4 ms | 78 | 0.0 ms (0.0%) | 0.0 ms | n/a |
| allocpar W8 | 176 | 40.0 ms (61.4%) | 0.4 ms | 80 | 7.3 ms (12.0%) | 0.1 ms | n/a |

### Peak memory: max RSS, lower is better

| Benchmark | Bit | Go | C |
|---|--:|--:|--:|
| fib | 2.2 MB | 4.6 MB | 1.8 MB |
| mandelbrot | 2.2 MB | 4.7 MB | 1.8 MB |
| collatz | 2.2 MB | 4.6 MB | 1.8 MB |
| alloc | 6.6 MB | 11.0 MB | 2.0 MB |
| allocflat | 6.1 MB | 11.5 MB | 1.9 MB |
| allocpar | 11.0 MB | 17.4 MB | 3.9 MB |
| strings | 78.9 MB | 84.4 MB | 31.0 MB |
| map | 36.9 MB | 41.9 MB | 193.8 MB |
| strmap | 35.8 MB | 31.2 MB | 41.2 MB |
| sort | 18.0 MB | 15.2 MB | 11.4 MB |
| matrix | 8.6 MB | 11.4 MB | 7.8 MB |
| json | 128.9 MB | 55.0 MB | 125.5 MB |

### Heap allocations per run: the equivalence check, not a score

| Benchmark | Bit | Go | C |
|---|--:|--:|--:|
| fib | 2 | 199 | 0 |
| mandelbrot | 2 | 199 | 0 |
| collatz | 2 | 199 | 0 |
| alloc | 10006002 | 10002341 | 10004000 |
| allocflat | 4002 | 2299 | 2000 |
| allocpar | 10006015 | 10002434 | 10004000 |
| strings | 33 | 343 | 11 |
| map | 10 | 4389 | 1 |
| strmap | 400037 | 400813 | 400003 |
| sort | 600018 | 150289 | 150002 |
| matrix | 12 | 282 | 3 |
| json | 3750060 | 1050003 | 2250021 |

### Binary size: static, as emitted

| Benchmark | Bit | Go | C |
|---|--:|--:|--:|
| fib | 352 KB | 2373 KB | 33 KB |
| mandelbrot | 352 KB | 2373 KB | 33 KB |
| collatz | 352 KB | 2373 KB | 33 KB |
| alloc | 369 KB | 2390 KB | 33 KB |
| allocflat | 369 KB | 2373 KB | 33 KB |
| allocpar | 373 KB | 2390 KB | 33 KB |
| strings | 370 KB | 2389 KB | 33 KB |
| map | 407 KB | 2390 KB | 33 KB |
| strmap | 409 KB | 2390 KB | 33 KB |
| sort | 371 KB | 2407 KB | 33 KB |
| matrix | 369 KB | 2373 KB | 33 KB |
| json | 462 KB | 3679 KB | 33 KB |

### Startup & compile

| Metric | Bit | Go | C |
|---|--:|--:|--:|
| Process startup (per exec) | 3.820 ms | 3.920 ms | 3.623 ms |

Bit compile speed: **591 lines/sec** (769 lines across 12 cases, warm).

> Machine: Apple M5 Max, macOS 27.0.1. Bit @ `a0cd513a9`, Go go1.27.1, Apple clang version 21.0.0 (clang-2100.3.34.2).
> Method: 15 runs per case per language. Cycles and instructions are a trimmed mean of those runs, meaning the mean after dropping the slowest fifth, which was the most reproducible of four estimators measured over 40 samples per series; wall clock and RSS are the median. C built `cc -O2 -ffp-contract=off`, Go `go build`, Bit `bit build`, each language's standard optimized build.
> Mandelbrot: Bit and C agree to the last bit; Go differs by ~0.0002% because it contracts `a*b+c` to a hardware FMA. Not a bug: cross-compiler float bit-identity is not guaranteed.
> alloc measures the ALLOCATOR: 10M short-lived nodes, each its own heap object in all three languages (Bit's element class has a reference field, Go holds `[]*Node`, C mallocs per node). allocflat measures DATA LAYOUT: the same 10M nodes and the same printed total, stored by value in one buffer per batch (Bit packs `[]Node` inline, Go holds `[]Node`, C mallocs the batch once). The gap between the two rows is what per-node heap allocation costs a language.
> allocpar measures the allocator under CONTENTION: the identical 10M nodes and the identical printed total as alloc, partitioned across 8 concurrent workers (Bit `spawn`, Go goroutines, C pthreads), worker count fixed in all three sources and never read from the host core count. The gap between the alloc and allocpar rows is what a language's allocator costs when more than one thread is in it; every other case in this table is single-mutator, so that cost appears nowhere else.
> The allocation table above is how those two claims are checked rather than asserted: same order of magnitude across a row means the three sources still express the same data structure, which is exactly what `alloc` silently lost for a day. Bit's count is `swept+live` from `BIT_GC_STATS=1`; Go's is `runtime.MemStats.Mallocs` and C's a `malloc` counter, both opt-in (`BENCH_ALLOC_STATS`, `-DBENCH_ALLOC_STATS`) and both absent from every timed binary.
> The ratios are built from CYCLES, not from wall clock. `/usr/bin/time` reports `real` in hundredths of a second and most of the C sides here finish in under 0.10s, so a wall-clock ratio for those rows would be quantisation: `map` published 7.50x C off 0.300s/0.040s where the counters say ~4.5x. Adding runs does not fix that, because it narrows the spread around a quantised value instead of removing the quantisation, so the unit changed. Cycles and instructions come from the same `/usr/bin/time -l` invocation that also produced the RSS; nothing extra is run and nothing extra is installed for those three. Wall clock is a separate one-decimal-millisecond measurement (`wall_run()`, one `fork`+`exec`+`waitpid` perl process per run, not `/usr/bin/time`'s own field) so it stays usable below `/usr/bin/time`'s 10ms floor; it still carries no ratio column and is kept as context.
> GC pauses: one untimed run per case, separate from the timed runs above (BIT_GC_STATS/GODEBUG both add real overhead). Bit's fields are `pausens=`/`pausemaxns=`/`pauses=` from `BIT_GC_STATS=1`. Go's are parsed from one `GODEBUG=gctrace=1` run: each `gc N @Ts P%: A+B+C ms clock` line's A (sweep termination) and C (mark termination) are its two STW segments (`go doc runtime`, go1.27.1), summed for the STW total, maxed individually for the longest single pause; B (concurrent mark) is not a stop and is excluded. C has no collector (n/a). Share is that probe run's own `wall_run()` wall time, not the timed loop's median. `allocpar W1`/`W8` reruns the same probe with `BIT_WORKERS`/`GOMAXPROCS` set; C is unchanged (its worker count is a compile-time `#define`, never read from env) so its wall-table cell reuses the baseline `allocpar` row rather than a redundant rerun.
> Cycles and instructions are startup-corrected: each figure has that language's own empty-program cost (`bench/cases/startup`, bit 4.8M, c 3.9M, go 6.0M) subtracted, because dyld and runtime init differ per language and are a fifth of C's `allocflat` row. Every other table is raw.

> On `matrix`, read the Go column as the target and not the C one. The C side vectorises: it retires 2.06 instructions per inner-loop iteration against Go's 9.09, so the Bit:C ratio on this row compares a scalar loop against a vectorised one and is not a statement about codegen quality. A scalar `cc -O2 -fno-vectorize` control build of the same case retires 8.07, which is the like-for-like figure. Denominator for all three: `trials * n^3 = 6 * 512^3 = 805,306,368` inner iterations.
> Reproducibility was measured rather than assumed: four independent regenerations of this table on this box held every ratio to 2.5% between adjacent runs and 8.5% at worst across all four. The loose rows are `alloc`, `map`, `allocflat` and `strings`, whose Go or C side is short enough that that language's own allocator and collector scheduling moves it by several percent from run to run; `matrix`, `mandelbrot`, `fib` and `sort` reproduce to about 1%. On those four loose rows, read a change under ~3% as noise.
> Peak RSS above is a within-run median like every other figure in that table, but it can still swing further ACROSS separate regenerations than one run shows. From every regeneration recorded in `bench/history.csv`, restricted to the same four loose rows above and to the Go/C columns (the Bit column reflects real compiler/runtime changes over that history, not noise): `alloc` c: 1.5-2.0 MB (median 2.0 MB, N=49); `allocflat` go: 10.6-12.0 MB (median 11.4 MB, N=40); `allocflat` c: 1.5-1.9 MB (median 1.9 MB, N=40); `strings` go: 64.3-90.9 MB (median 78.4 MB, N=46). Read that cell's published number as representative of the stated range, not a fixed constant.
> Instructions are published beside cycles because a cycle gap alone does not say whether it is work emitted or work stalled, and the two ratios differ a lot here: Bit retires roughly 4-7 instructions per cycle against C's 1.4-1.8, so its instruction ratio always overstates its cycle ratio. Cycles are the time; instructions are the reason.
> Generated by `bench/run.sh` on 2026-10-05T03:09:47Z. Do not edit by hand.
