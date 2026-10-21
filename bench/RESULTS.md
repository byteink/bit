# Benchmark results: full numbers and method

The README carries the short version. This page keeps every table and the method behind it.

### Runtime: CPU cycles, lower is better

| Benchmark | Bit | Go | C | Bit / Go | Bit / C |
|---|--:|--:|--:|--:|--:|
| fib | 1032.8 M | 958.4 M | 638.9 M | 1.08x | 1.62x |
| mandelbrot | 2141.8 M | 1645.9 M | 1611.1 M | 1.30x | 1.33x |
| collatz | 901.4 M | 620.8 M | 412.8 M | 1.45x | 2.18x |
| alloc | 651.3 M | 378.1 M | 465.0 M | 1.72x | 1.40x |
| allocflat | 167.0 M | 84.5 M | 18.1 M | 1.98x | 9.22x |
| allocpar | 811.2 M | 718.7 M | 2103.1 M | 1.13x | 0.39x |
| strings | 222.3 M | 399.1 M | 110.7 M | 0.56x | 2.01x |
| map | 332.5 M | 416.3 M | 182.0 M | 0.80x | 1.83x |
| strmap | 1234.8 M | 687.2 M | 260.1 M | 1.80x | 4.75x |
| sort | 312.3 M | 358.3 M | 279.7 M | 0.87x | 1.12x |
| matrix | 1388.0 M | 953.9 M | 399.7 M | 1.46x | 3.47x |
| json | 731.1 M | 338.6 M | 229.8 M | 2.16x | 3.18x |

### Instructions retired: work emitted, not time taken

| Benchmark | Bit | Go | C |
|---|--:|--:|--:|
| fib | 5301.2 M | 5137.5 M | 3147.0 M |
| mandelbrot | 4788.5 M | 2507.5 M | 2699.6 M |
| collatz | 2581.9 M | 935.9 M | 930.7 M |
| alloc | 5016.7 M | 2209.3 M | 3607.1 M |
| allocflat | 1262.0 M | 367.3 M | 59.3 M |
| allocpar | 5798.3 M | 3240.7 M | 3621.4 M |
| strings | 1704.4 M | 1762.7 M | 643.5 M |
| map | 759.8 M | 691.7 M | 229.3 M |
| strmap | 5509.8 M | 2268.1 M | 534.3 M |
| sort | 1730.8 M | 942.2 M | 503.8 M |
| matrix | 12278.2 M | 7323.6 M | 1656.4 M |
| json | 4654.0 M | 2139.0 M | 1339.9 M |

### Wall clock: median of 15 runs, milliseconds

| Benchmark | Bit | Go | C |
|---|--:|--:|--:|
| fib | 237.1 ms | 223.8 ms | 144.8 ms |
| mandelbrot | 480.6 ms | 366.7 ms | 360.3 ms |
| collatz | 202.2 ms | 139.3 ms | 93.0 ms |
| alloc | 138.1 ms | 81.3 ms | 111.6 ms |
| allocflat | 41.2 ms | 18.1 ms | 6.4 ms |
| allocpar | 52.8 ms | 55.7 ms | 67.3 ms |
| strings | 53.0 ms | 59.8 ms | 28.2 ms |
| map | 79.7 ms | 99.0 ms | 46.2 ms |
| strmap | 283.1 ms | 158.5 ms | 64.5 ms |
| sort | 63.8 ms | 85.1 ms | 65.5 ms |
| matrix | 323.5 ms | 223.5 ms | 94.6 ms |
| json | 138.9 ms | 76.0 ms | 56.6 ms |
| allocpar W1 | 175.7 ms | 106.1 ms | 67.3 ms |
| allocpar W8 | 56.1 ms | 62.2 ms | 67.3 ms |

### GC pauses: one untimed run per case, share of that run's own wall clock

| Benchmark | Bit pauses | Bit pausens ms (share) | Bit pausemax ms | Go GCs | Go STW ms (share) | Go STW max ms | C |
|---|--:|--:|--:|--:|--:|--:|--:|
| fib | 0 | 0.0 ms (0.0%) | 0.0 ms | 0 | 0.0 ms (0.0%) | 0.0 ms | n/a |
| mandelbrot | 0 | 0.0 ms (0.0%) | 0.0 ms | 0 | 0.0 ms (0.0%) | 0.0 ms | n/a |
| collatz | 0 | 0.0 ms (0.0%) | 0.0 ms | 0 | 0.0 ms (0.0%) | 0.0 ms | n/a |
| alloc | 133 | 9.1 ms (6.6%) | 0.1 ms | 65 | 1.8 ms (2.2%) | 0.1 ms | n/a |
| allocflat | 66 | 0.4 ms (1.0%) | 0.0 ms | 62 | 1.0 ms (5.7%) | 0.0 ms | n/a |
| allocpar | 159 | 18.8 ms (27.4%) | 0.2 ms | 85 | 5.1 ms (9.0%) | 0.1 ms | n/a |
| strings | 3 | 0.7 ms (1.2%) | 0.4 ms | 13 | 0.2 ms (0.3%) | 0.0 ms | n/a |
| map | 1 | 0.1 ms (0.1%) | 0.1 ms | 4 | 0.1 ms (0.1%) | 0.0 ms | n/a |
| strmap | 4 | 3.7 ms (1.3%) | 3.2 ms | 3 | 0.0 ms (0.0%) | 0.0 ms | n/a |
| sort | 8 | 6.5 ms (10.1%) | 2.0 ms | 1 | 0.0 ms (0.0%) | 0.0 ms | n/a |
| matrix | 1 | 0.0 ms (0.0%) | 0.0 ms | 1 | 0.0 ms (0.0%) | 0.0 ms | n/a |
| json | 19 | 7.1 ms (5.2%) | 4.6 ms | 10 | 0.3 ms (0.4%) | 0.0 ms | n/a |
| allocpar W1 | 162 | 48.4 ms (27.4%) | 0.5 ms | 78 | 0.1 ms (0.1%) | 0.0 ms | n/a |
| allocpar W8 | 176 | 37.1 ms (62.8%) | 0.3 ms | 82 | 7.7 ms (12.3%) | 0.1 ms | n/a |

### Peak memory: max RSS, lower is better

| Benchmark | Bit | Go | C |
|---|--:|--:|--:|
| fib | 2.3 MB | 4.3 MB | 1.7 MB |
| mandelbrot | 2.3 MB | 4.3 MB | 1.7 MB |
| collatz | 2.3 MB | 4.3 MB | 1.7 MB |
| alloc | 6.8 MB | 11.2 MB | 2.0 MB |
| allocflat | 6.3 MB | 10.8 MB | 1.9 MB |
| allocpar | 8.8 MB | 10.9 MB | 3.8 MB |
| strings | 63.0 MB | 61.0 MB | 31.0 MB |
| map | 37.2 MB | 41.2 MB | 193.8 MB |
| strmap | 35.9 MB | 30.4 MB | 41.1 MB |
| sort | 17.8 MB | 14.6 MB | 11.3 MB |
| matrix | 8.8 MB | 10.8 MB | 7.8 MB |
| json | 129.3 MB | 55.6 MB | 125.5 MB |

### Heap allocations per run: the equivalence check, not a score

| Benchmark | Bit | Go | C |
|---|--:|--:|--:|
| fib | 2 | 184 | 0 |
| mandelbrot | 2 | 184 | 0 |
| collatz | 2 | 184 | 0 |
| alloc | 10006002 | 10002217 | 10004000 |
| allocflat | 4002 | 2223 | 2000 |
| allocpar | 10006015 | 10002264 | 10004000 |
| strings | 33 | 259 | 11 |
| map | 10 | 4300 | 1 |
| strmap | 400037 | 400719 | 400003 |
| sort | 600018 | 150207 | 150002 |
| matrix | 12 | 206 | 3 |
| json | 3750060 | 1049905 | 2250021 |

### Binary size: static, as emitted

| Benchmark | Bit | Go | C |
|---|--:|--:|--:|
| fib | 409 KB | 2373 KB | 33 KB |
| mandelbrot | 409 KB | 2373 KB | 33 KB |
| collatz | 409 KB | 2373 KB | 33 KB |
| alloc | 410 KB | 2390 KB | 33 KB |
| allocflat | 409 KB | 2373 KB | 33 KB |
| allocpar | 445 KB | 2390 KB | 33 KB |
| strings | 410 KB | 2389 KB | 33 KB |
| map | 449 KB | 2390 KB | 33 KB |
| strmap | 467 KB | 2390 KB | 33 KB |
| sort | 428 KB | 2407 KB | 33 KB |
| matrix | 409 KB | 2373 KB | 33 KB |
| json | 502 KB | 3696 KB | 33 KB |

### Startup & compile

| Metric | Bit | Go | C |
|---|--:|--:|--:|
| Process startup (per exec) | 4.509 ms | 5.715 ms | 4.594 ms |

Bit compile speed: **675 lines/sec** (769 lines across 12 cases, warm).

> Machine: Apple M5 Max, macOS 27.0.1. Bit @ `7e8257380`, Go go1.27.3, Apple clang version 21.0.0 (clang-2100.3.34.2).
> Method: 15 runs per case per language. Cycles and instructions are a trimmed mean of those runs, meaning the mean after dropping the slowest fifth, which was the most reproducible of four estimators measured over 40 samples per series; wall clock and RSS are the median. C built `cc -O2 -ffp-contract=off`, Go `go build`, Bit `bit build`, each language's standard optimized build.
> Mandelbrot: Bit and C agree to the last bit; Go differs by ~0.0002% because it contracts `a*b+c` to a hardware FMA. Not a bug: cross-compiler float bit-identity is not guaranteed.
> alloc measures the ALLOCATOR: 10M short-lived nodes, each its own heap object in all three languages (Bit's element class has a reference field, Go holds `[]*Node`, C mallocs per node). allocflat measures DATA LAYOUT: the same 10M nodes and the same printed total, stored by value in one buffer per batch (Bit packs `[]Node` inline, Go holds `[]Node`, C mallocs the batch once). The gap between the two rows is what per-node heap allocation costs a language.
> allocpar measures the allocator under CONTENTION: the identical 10M nodes and the identical printed total as alloc, partitioned across 8 concurrent workers (Bit `spawn`, Go goroutines, C pthreads), worker count fixed in all three sources and never read from the host core count. The gap between the alloc and allocpar rows is what a language's allocator costs when more than one thread is in it; every other case in this table is single-mutator, so that cost appears nowhere else.
> The allocation table above is how those two claims are checked rather than asserted: same order of magnitude across a row means the three sources still express the same data structure, which is exactly what `alloc` silently lost for a day. Bit's count is `swept+live` from `BIT_GC_STATS=1`; Go's is `runtime.MemStats.Mallocs` and C's a `malloc` counter, both opt-in (`BENCH_ALLOC_STATS`, `-DBENCH_ALLOC_STATS`) and both absent from every timed binary.
> The ratios are built from CYCLES, not from wall clock. `/usr/bin/time` reports `real` in hundredths of a second and most of the C sides here finish in under 0.10s, so a wall-clock ratio for those rows would be quantisation: `map` published 7.50x C off 0.300s/0.040s where the counters say ~4.5x. Adding runs does not fix that, because it narrows the spread around a quantised value instead of removing the quantisation, so the unit changed. Cycles and instructions come from the same `/usr/bin/time -l` invocation that also produced the RSS; nothing extra is run and nothing extra is installed for those three. Wall clock is a separate one-decimal-millisecond measurement (`wall_run()`, one `fork`+`exec`+`waitpid` perl process per run, not `/usr/bin/time`'s own field) so it stays usable below `/usr/bin/time`'s 10ms floor; it still carries no ratio column and is kept as context.
> GC pauses: one untimed run per case, separate from the timed runs above (BIT_GC_STATS/GODEBUG both add real overhead). Bit's fields are `pausens=`/`pausemaxns=`/`pauses=` from `BIT_GC_STATS=1`. Go's are parsed from one `GODEBUG=gctrace=1` run: each `gc N @Ts P%: A+B+C ms clock` line's A (sweep termination) and C (mark termination) are its two STW segments (`go doc runtime`, go1.27.1), summed for the STW total, maxed individually for the longest single pause; B (concurrent mark) is not a stop and is excluded. C has no collector (n/a). Share is that probe run's own `wall_run()` wall time, not the timed loop's median. `allocpar W1`/`W8` reruns the same probe with `BIT_WORKERS`/`GOMAXPROCS` set; C is unchanged (its worker count is a compile-time `#define`, never read from env) so its wall-table cell reuses the baseline `allocpar` row rather than a redundant rerun.
> Cycles and instructions are startup-corrected: each figure has that language's own empty-program cost (`bench/cases/startup`, bit 5.2M, c 4.1M, go 6.3M) subtracted, because dyld and runtime init differ per language and are a fifth of C's `allocflat` row. Every other table is raw.

> On `matrix`, read the Go column as the target and not the C one. The C side vectorises: it retires 2.06 instructions per inner-loop iteration against Go's 9.09, so the Bit:C ratio on this row compares a scalar loop against a vectorised one and is not a statement about codegen quality. A scalar `cc -O2 -fno-vectorize` control build of the same case retires 8.07, which is the like-for-like figure. Denominator for all three: `trials * n^3 = 6 * 512^3 = 805,306,368` inner iterations.
> Reproducibility was measured rather than assumed: four independent regenerations of this table on this box held every ratio to 2.5% between adjacent runs and 8.5% at worst across all four. The loose rows are `alloc`, `map`, `allocflat` and `strings`, whose Go or C side is short enough that that language's own allocator and collector scheduling moves it by several percent from run to run; `matrix`, `mandelbrot`, `fib` and `sort` reproduce to about 1%. On those four loose rows, read a change under ~3% as noise.
> Peak RSS above is a within-run median like every other figure in that table, but it can still swing further ACROSS separate regenerations than one run shows. From every regeneration recorded in `bench/history.csv`, restricted to the same four loose rows above and to the Go/C columns (the Bit column reflects real compiler/runtime changes over that history, not noise): `alloc` c: 1.5-2.2 MB (median 2.0 MB, N=69); `allocflat` go: 10.6-12.8 MB (median 11.4 MB, N=60); `allocflat` c: 1.5-1.9 MB (median 1.9 MB, N=60); `strings` go: 61.0-100.0 MB (median 70.3 MB, N=66). Read that cell's published number as representative of the stated range, not a fixed constant.
> Instructions are published beside cycles because a cycle gap alone does not say whether it is work emitted or work stalled, and the two ratios differ a lot here: Bit retires roughly 4-7 instructions per cycle against C's 1.4-1.8, so its instruction ratio always overstates its cycle ratio. Cycles are the time; instructions are the reason.
> Generated by `bench/run.sh` on 2026-10-21T18:00:48Z. Do not edit by hand.
