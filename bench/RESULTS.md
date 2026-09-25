_Full method and caveats below the tables._

### Runtime: CPU cycles, lower is better

| Benchmark | Bit | Go | C | Bit / Go | Bit / C |
|---|--:|--:|--:|--:|--:|
| fib | 1002.8 M | 949.9 M | 640.2 M | 1.06x | 1.57x |
| mandelbrot | 2132.8 M | 1638.1 M | 1605.1 M | 1.30x | 1.33x |
| collatz | 920.8 M | 626.2 M | 411.3 M | 1.47x | 2.24x |
| alloc | 796.6 M | 389.3 M | 457.4 M | 2.05x | 1.74x |
| allocflat | 250.5 M | 112.7 M | 17.7 M | 2.22x | 14.13x |
| allocpar | 1575.0 M | 1251.1 M | 2134.5 M | 1.26x | 0.74x |
| strings | 211.5 M | 369.5 M | 109.2 M | 0.57x | 1.94x |
| map | 304.8 M | 368.8 M | 173.8 M | 0.83x | 1.75x |
| strmap | 1280.5 M | 676.2 M | 254.1 M | 1.89x | 5.04x |
| sort | 282.5 M | 357.6 M | 277.8 M | 0.79x | 1.02x |
| matrix | 1381.0 M | 951.6 M | 398.2 M | 1.45x | 3.47x |
| json | 839.9 M | 339.7 M | 230.5 M | 2.47x | 3.64x |

### Instructions retired: work emitted, not time taken

| Benchmark | Bit | Go | C |
|---|--:|--:|--:|
| fib | 5962.4 M | 5136.9 M | 3146.6 M |
| mandelbrot | 4788.4 M | 2506.3 M | 2698.7 M |
| collatz | 2579.0 M | 935.5 M | 930.5 M |
| alloc | 5899.1 M | 2155.4 M | 3606.8 M |
| allocflat | 1596.3 M | 401.9 M | 59.3 M |
| allocpar | 8589.4 M | 4579.6 M | 3620.7 M |
| strings | 1689.0 M | 1706.5 M | 643.3 M |
| map | 751.5 M | 693.1 M | 229.2 M |
| strmap | 6299.9 M | 2199.2 M | 534.2 M |
| sort | 1717.4 M | 943.1 M | 503.6 M |
| matrix | 12279.6 M | 7323.8 M | 1656.2 M |
| json | 5577.1 M | 2133.1 M | 1339.8 M |

### Wall clock: median of 15 runs, milliseconds

| Benchmark | Bit | Go | C |
|---|--:|--:|--:|
| fib | 235.4 ms | 220.3 ms | 145.0 ms |
| mandelbrot | 482.2 ms | 367.5 ms | 361.0 ms |
| collatz | 211.0 ms | 148.0 ms | 94.5 ms |
| alloc | 185.3 ms | 81.3 ms | 119.8 ms |
| allocflat | 59.8 ms | 19.9 ms | 6.2 ms |
| allocpar | 65.4 ms | 60.4 ms | 68.5 ms |
| strings | 52.1 ms | 60.2 ms | 27.8 ms |
| map | 72.3 ms | 84.8 ms | 44.0 ms |
| strmap | 300.4 ms | 157.7 ms | 61.1 ms |
| sort | 67.5 ms | 84.6 ms | 64.5 ms |
| matrix | 322.6 ms | 224.0 ms | 94.6 ms |
| json | 198.3 ms | 74.6 ms | 56.8 ms |
| allocpar W1 | 219.6 ms | 105.3 ms | 68.5 ms |
| allocpar W8 | 63.5 ms | 60.1 ms | 68.5 ms |

### GC pauses: one untimed run per case, share of that run's own wall clock

| Benchmark | Bit pauses | Bit pausens ms (share) | Bit pausemax ms | Go GCs | Go STW ms (share) | Go STW max ms | C |
|---|--:|--:|--:|--:|--:|--:|--:|
| fib | 0 | 0.0 ms (0.0%) | 0.0 ms | 0 | 0.0 ms (0.0%) | 0.0 ms | n/a |
| mandelbrot | 0 | 0.0 ms (0.0%) | 0.0 ms | 0 | 0.0 ms (0.0%) | 0.0 ms | n/a |
| collatz | 0 | 0.0 ms (0.0%) | 0.0 ms | 0 | 0.0 ms (0.0%) | 0.0 ms | n/a |
| alloc | 133 | 34.9 ms (18.5%) | 0.5 ms | 69 | 2.1 ms (2.5%) | 0.1 ms | n/a |
| allocflat | 68 | 2.7 ms (3.8%) | 0.1 ms | 78 | 2.5 ms (12.6%) | 0.2 ms | n/a |
| allocpar | 172 | 31.8 ms (48.8%) | 0.3 ms | 68 | 7.4 ms (12.0%) | 0.1 ms | n/a |
| strings | 3 | 0.2 ms (0.4%) | 0.1 ms | 14 | 0.3 ms (0.5%) | 0.0 ms | n/a |
| map | 1 | 0.0 ms (0.0%) | 0.0 ms | 4 | 0.1 ms (0.1%) | 0.0 ms | n/a |
| strmap | 4 | 11.2 ms (3.7%) | 8.8 ms | 3 | 0.1 ms (0.1%) | 0.0 ms | n/a |
| sort | 4 | 4.8 ms (7.1%) | 2.9 ms | 1 | 0.1 ms (0.1%) | 0.0 ms | n/a |
| matrix | 1 | 0.0 ms (0.0%) | 0.0 ms | 1 | 0.0 ms (0.0%) | 0.0 ms | n/a |
| json | 17 | 40.3 ms (20.9%) | 27.3 ms | 10 | 0.3 ms (0.4%) | 0.0 ms | n/a |
| allocpar W1 | 161 | 71.1 ms (31.8%) | 0.7 ms | 77 | 0.0 ms (0.0%) | 0.0 ms | n/a |
| allocpar W8 | 179 | 39.6 ms (39.8%) | 0.4 ms | 81 | 7.8 ms (11.8%) | 0.1 ms | n/a |

### Peak memory: max RSS, lower is better

| Benchmark | Bit | Go | C |
|---|--:|--:|--:|
| fib | 2.3 MB | 4.6 MB | 1.8 MB |
| mandelbrot | 2.3 MB | 4.6 MB | 1.8 MB |
| collatz | 2.4 MB | 4.6 MB | 1.8 MB |
| alloc | 6.6 MB | 10.7 MB | 2.0 MB |
| allocflat | 6.2 MB | 11.8 MB | 1.9 MB |
| allocpar | 14.4 MB | 17.9 MB | 3.7 MB |
| strings | 78.7 MB | 69.4 MB | 31.0 MB |
| map | 36.8 MB | 41.8 MB | 193.8 MB |
| strmap | 39.4 MB | 31.0 MB | 41.2 MB |
| sort | 25.9 MB | 15.2 MB | 11.4 MB |
| matrix | 8.7 MB | 11.3 MB | 7.8 MB |
| json | 128.9 MB | 55.9 MB | 125.5 MB |

### Heap allocations per run: the equivalence check, not a score

| Benchmark | Bit | Go | C |
|---|--:|--:|--:|
| fib | 6 | 195 | 0 |
| mandelbrot | 6 | 195 | 0 |
| collatz | 6 | 195 | 0 |
| alloc | 10006006 | 10002309 | 10004000 |
| allocflat | 4006 | 2304 | 2000 |
| allocpar | 10006053 | 10002417 | 10004000 |
| strings | 37 | 340 | 11 |
| map | 14 | 4380 | 1 |
| strmap | 400041 | 400799 | 400003 |
| sort | 600022 | 150286 | 150002 |
| matrix | 16 | 279 | 3 |
| json | 3750066 | 1049990 | 2250021 |

### Binary size: static, as emitted

| Benchmark | Bit | Go | C |
|---|--:|--:|--:|
| fib | 329 KB | 2373 KB | 33 KB |
| mandelbrot | 329 KB | 2373 KB | 33 KB |
| collatz | 329 KB | 2373 KB | 33 KB |
| alloc | 330 KB | 2390 KB | 33 KB |
| allocflat | 330 KB | 2373 KB | 33 KB |
| allocpar | 349 KB | 2390 KB | 33 KB |
| strings | 331 KB | 2389 KB | 33 KB |
| map | 368 KB | 2390 KB | 33 KB |
| strmap | 370 KB | 2390 KB | 33 KB |
| sort | 349 KB | 2407 KB | 33 KB |
| matrix | 330 KB | 2373 KB | 33 KB |
| json | 423 KB | 3679 KB | 33 KB |

### Startup & compile

| Metric | Bit | Go | C |
|---|--:|--:|--:|
| Process startup (per exec) | 4.326 ms | 4.864 ms | 4.465 ms |

Bit compile speed: **943 lines/sec** (769 lines across 12 cases, warm).

> Machine: Apple M5 Max, macOS 27.0. Bit @ `f038626bf`, Go go1.27.1, Apple clang version 21.0.0 (clang-2100.3.34.2).
> Method: 15 runs per case per language. Cycles and instructions are a trimmed mean of those runs, meaning the mean after dropping the slowest fifth, which was the most reproducible of four estimators measured over 40 samples per series; wall clock and RSS are the median. C built `cc -O2 -ffp-contract=off`, Go `go build`, Bit `bit build`, each language's standard optimized build.
> Mandelbrot: Bit and C agree to the last bit; Go differs by ~0.0002% because it contracts `a*b+c` to a hardware FMA. Not a bug: cross-compiler float bit-identity is not guaranteed.
> alloc measures the ALLOCATOR: 10M short-lived nodes, each its own heap object in all three languages (Bit's element class has a reference field, Go holds `[]*Node`, C mallocs per node). allocflat measures DATA LAYOUT: the same 10M nodes and the same printed total, stored by value in one buffer per batch (Bit packs `[]Node` inline, Go holds `[]Node`, C mallocs the batch once). The gap between the two rows is what per-node heap allocation costs a language.
> allocpar measures the allocator under CONTENTION: the identical 10M nodes and the identical printed total as alloc, partitioned across 8 concurrent workers (Bit `spawn`, Go goroutines, C pthreads), worker count fixed in all three sources and never read from the host core count. The gap between the alloc and allocpar rows is what a language's allocator costs when more than one thread is in it; every other case in this table is single-mutator, so that cost appears nowhere else.
> The allocation table above is how those two claims are checked rather than asserted: same order of magnitude across a row means the three sources still express the same data structure, which is exactly what `alloc` silently lost for a day. Bit's count is `swept+live` from `BIT_GC_STATS=1`; Go's is `runtime.MemStats.Mallocs` and C's a `malloc` counter, both opt-in (`BENCH_ALLOC_STATS`, `-DBENCH_ALLOC_STATS`) and both absent from every timed binary.
> The ratios are built from CYCLES, not from wall clock. `/usr/bin/time` reports `real` in hundredths of a second and most of the C sides here finish in under 0.10s, so a wall-clock ratio for those rows would be quantisation: `map` published 7.50x C off 0.300s/0.040s where the counters say ~4.5x. Adding runs does not fix that, because it narrows the spread around a quantised value instead of removing the quantisation, so the unit changed. Cycles and instructions come from the same `/usr/bin/time -l` invocation that also produced the RSS; nothing extra is run and nothing extra is installed for those three. Wall clock is a separate one-decimal-millisecond measurement (`wall_run()`, one `fork`+`exec`+`waitpid` perl process per run, not `/usr/bin/time`'s own field) so it stays usable below `/usr/bin/time`'s 10ms floor; it still carries no ratio column and is kept as context.
> GC pauses: one untimed run per case, separate from the timed runs above (BIT_GC_STATS/GODEBUG both add real overhead). Bit's fields are `pausens=`/`pausemaxns=`/`pauses=` from `BIT_GC_STATS=1`. Go's are parsed from one `GODEBUG=gctrace=1` run: each `gc N @Ts P%: A+B+C ms clock` line's A (sweep termination) and C (mark termination) are its two STW segments (`go doc runtime`, go1.27.1), summed for the STW total, maxed individually for the longest single pause; B (concurrent mark) is not a stop and is excluded. C has no collector (n/a). Share is that probe run's own `wall_run()` wall time, not the timed loop's median. `allocpar W1`/`W8` reruns the same probe with `BIT_WORKERS`/`GOMAXPROCS` set; C is unchanged (its worker count is a compile-time `#define`, never read from env) so its wall-table cell reuses the baseline `allocpar` row rather than a redundant rerun.
> Cycles and instructions are startup-corrected: each figure has that language's own empty-program cost (`bench/cases/startup`, bit 5.1M, c 4.0M, go 6.0M) subtracted, because dyld and runtime init differ per language and are a fifth of C's `allocflat` row. Every other table is raw.

> On `matrix`, read the Go column as the target and not the C one. The C side vectorises: it retires 2.06 instructions per inner-loop iteration against Go's 9.09, so the Bit:C ratio on this row compares a scalar loop against a vectorised one and is not a statement about codegen quality. A scalar `cc -O2 -fno-vectorize` control build of the same case retires 8.07, which is the like-for-like figure. Denominator for all three: `trials * n^3 = 6 * 512^3 = 805,306,368` inner iterations.
> Reproducibility was measured rather than assumed: four independent regenerations of this table on this box held every ratio to 2.5% between adjacent runs and 8.5% at worst across all four. The loose rows are `alloc`, `map`, `allocflat` and `strings`, whose Go or C side is short enough that that language's own allocator and collector scheduling moves it by several percent from run to run; `matrix`, `mandelbrot`, `fib` and `sort` reproduce to about 1%. On those four loose rows, read a change under ~3% as noise.
> Peak RSS above is a within-run median like every other figure in that table, but it can still swing further ACROSS separate regenerations than one run shows. From every regeneration recorded in `bench/history.csv`, restricted to the same four loose rows above and to the Go/C columns (the Bit column reflects real compiler/runtime changes over that history, not noise): `alloc` c: 1.5-2.0 MB (median 1.6 MB, N=39); `allocflat` go: 10.6-12.0 MB (median 11.4 MB, N=30); `allocflat` c: 1.5-1.9 MB (median 1.7 MB, N=30); `strings` go: 64.3-90.9 MB (median 70.0 MB, N=36). Read that cell's published number as representative of the stated range, not a fixed constant.
> Instructions are published beside cycles because a cycle gap alone does not say whether it is work emitted or work stalled, and the two ratios differ a lot here: Bit retires roughly 4-7 instructions per cycle against C's 1.4-1.8, so its instruction ratio always overstates its cycle ratio. Cycles are the time; instructions are the reason.
> Generated by `bench/run.sh` on 2026-09-25T19:22:56Z. Do not edit by hand.
