# Benchmark results: full numbers and method

The README carries the short version. This page keeps every table and the method behind it.

### Runtime: CPU cycles, lower is better

| Benchmark | Bit | Go | C | Bit / Go | Bit / C |
|---|--:|--:|--:|--:|--:|
| fib | 1034.5 M | 947.8 M | 636.3 M | 1.09x | 1.63x |
| mandelbrot | 2138.8 M | 1642.9 M | 1608.3 M | 1.30x | 1.33x |
| collatz | 902.1 M | 619.0 M | 412.7 M | 1.46x | 2.19x |
| alloc | 653.1 M | 380.6 M | 467.6 M | 1.72x | 1.40x |
| allocflat | 166.3 M | 84.2 M | 18.1 M | 1.97x | 9.19x |
| allocpar | 807.3 M | 709.4 M | 2096.9 M | 1.14x | 0.38x |
| strings | 224.4 M | 401.5 M | 110.7 M | 0.56x | 2.03x |
| map | 370.5 M | 524.5 M | 190.5 M | 0.71x | 1.95x |
| strmap | 1230.5 M | 690.4 M | 268.9 M | 1.78x | 4.58x |
| sort | 320.3 M | 357.4 M | 279.2 M | 0.90x | 1.15x |
| matrix | 1384.4 M | 953.5 M | 399.4 M | 1.45x | 3.47x |
| json | 739.8 M | 344.8 M | 233.9 M | 2.15x | 3.16x |

### Instructions retired: work emitted, not time taken

| Benchmark | Bit | Go | C |
|---|--:|--:|--:|
| fib | 5300.9 M | 5137.3 M | 3146.9 M |
| mandelbrot | 4788.1 M | 2507.0 M | 2699.4 M |
| collatz | 2581.6 M | 935.6 M | 930.8 M |
| alloc | 5015.3 M | 2238.2 M | 3607.0 M |
| allocflat | 1262.0 M | 368.0 M | 59.3 M |
| allocpar | 5760.8 M | 3230.5 M | 3621.2 M |
| strings | 1713.8 M | 1778.1 M | 645.1 M |
| map | 760.2 M | 692.2 M | 243.7 M |
| strmap | 5514.8 M | 2272.0 M | 536.6 M |
| sort | 1731.5 M | 942.1 M | 503.8 M |
| matrix | 12277.5 M | 7323.1 M | 1656.3 M |
| json | 4664.6 M | 2155.0 M | 1349.1 M |

### Wall clock: median of 15 runs, milliseconds

| Benchmark | Bit | Go | C |
|---|--:|--:|--:|
| fib | 234.5 ms | 223.0 ms | 145.6 ms |
| mandelbrot | 494.2 ms | 375.9 ms | 371.5 ms |
| collatz | 204.4 ms | 139.0 ms | 93.1 ms |
| alloc | 141.0 ms | 84.3 ms | 112.9 ms |
| allocflat | 40.9 ms | 18.3 ms | 6.6 ms |
| allocpar | 53.2 ms | 56.2 ms | 67.1 ms |
| strings | 54.3 ms | 60.9 ms | 28.1 ms |
| map | 89.4 ms | 120.6 ms | 49.7 ms |
| strmap | 282.2 ms | 159.6 ms | 65.3 ms |
| sort | 66.3 ms | 85.9 ms | 66.4 ms |
| matrix | 324.7 ms | 225.8 ms | 95.3 ms |
| json | 141.8 ms | 76.8 ms | 58.1 ms |
| allocpar W1 | 172.2 ms | 107.5 ms | 67.1 ms |
| allocpar W8 | 55.5 ms | 61.6 ms | 67.1 ms |

### GC pauses: one untimed run per case, share of that run's own wall clock

| Benchmark | Bit pauses | Bit pausens ms (share) | Bit pausemax ms | Go GCs | Go STW ms (share) | Go STW max ms | C |
|---|--:|--:|--:|--:|--:|--:|--:|
| fib | 0 | 0.0 ms (0.0%) | 0.0 ms | 0 | 0.0 ms (0.0%) | 0.0 ms | n/a |
| mandelbrot | 0 | 0.0 ms (0.0%) | 0.0 ms | 0 | 0.0 ms (0.0%) | 0.0 ms | n/a |
| collatz | 0 | 0.0 ms (0.0%) | 0.0 ms | 0 | 0.0 ms (0.0%) | 0.0 ms | n/a |
| alloc | 133 | 9.1 ms (6.5%) | 0.1 ms | 68 | 1.5 ms (1.8%) | 0.0 ms | n/a |
| allocflat | 66 | 0.4 ms (1.0%) | 0.0 ms | 62 | 0.9 ms (5.2%) | 0.0 ms | n/a |
| allocpar | 157 | 18.3 ms (25.7%) | 0.2 ms | 85 | 5.3 ms (9.0%) | 0.2 ms | n/a |
| strings | 3 | 0.6 ms (1.1%) | 0.4 ms | 11 | 0.2 ms (0.3%) | 0.0 ms | n/a |
| map | 1 | 0.0 ms (0.0%) | 0.0 ms | 4 | 0.0 ms (0.0%) | 0.0 ms | n/a |
| strmap | 4 | 3.7 ms (1.3%) | 2.9 ms | 3 | 0.0 ms (0.0%) | 0.0 ms | n/a |
| sort | 8 | 6.5 ms (10.2%) | 2.1 ms | 1 | 0.0 ms (0.0%) | 0.0 ms | n/a |
| matrix | 1 | 0.0 ms (0.0%) | 0.0 ms | 1 | 0.0 ms (0.0%) | 0.0 ms | n/a |
| json | 19 | 7.7 ms (5.5%) | 5.0 ms | 10 | 0.3 ms (0.4%) | 0.0 ms | n/a |
| allocpar W1 | 150 | 35.4 ms (20.6%) | 0.4 ms | 69 | 0.0 ms (0.0%) | 0.0 ms | n/a |
| allocpar W8 | 178 | 34.0 ms (47.7%) | 0.3 ms | 80 | 7.3 ms (12.0%) | 0.2 ms | n/a |

### Peak memory: max RSS, lower is better

| Benchmark | Bit | Go | C |
|---|--:|--:|--:|
| fib | 2.3 MB | 4.4 MB | 1.7 MB |
| mandelbrot | 2.3 MB | 4.3 MB | 1.7 MB |
| collatz | 2.3 MB | 4.3 MB | 1.7 MB |
| alloc | 6.8 MB | 11.0 MB | 2.0 MB |
| allocflat | 6.3 MB | 11.2 MB | 1.9 MB |
| allocpar | 8.8 MB | 10.8 MB | 3.7 MB |
| strings | 63.0 MB | 61.0 MB | 31.0 MB |
| map | 37.2 MB | 41.2 MB | 193.8 MB |
| strmap | 35.9 MB | 30.4 MB | 41.1 MB |
| sort | 17.8 MB | 14.6 MB | 11.3 MB |
| matrix | 8.8 MB | 10.8 MB | 7.8 MB |
| json | 129.2 MB | 57.6 MB | 125.5 MB |

### Heap allocations per run: the equivalence check, not a score

| Benchmark | Bit | Go | C |
|---|--:|--:|--:|
| fib | 2 | 183 | 0 |
| mandelbrot | 2 | 183 | 0 |
| collatz | 2 | 183 | 0 |
| alloc | 10006002 | 10002216 | 10004000 |
| allocflat | 4002 | 2246 | 2000 |
| allocpar | 10006015 | 10002257 | 10004000 |
| strings | 33 | 256 | 11 |
| map | 10 | 4299 | 1 |
| strmap | 400037 | 400718 | 400003 |
| sort | 600018 | 150206 | 150002 |
| matrix | 12 | 205 | 3 |
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
| Process startup (per exec) | 4.620 ms | 4.807 ms | 4.504 ms |

Bit compile speed: **671 lines/sec** (769 lines across 12 cases, warm).

> Machine: Apple M5 Max, macOS 27.0.1. Bit @ `bb7b88457`, Go go1.27.2, Apple clang version 21.0.0 (clang-2100.3.34.2).
> Method: 15 runs per case per language. Cycles and instructions are a trimmed mean of those runs, meaning the mean after dropping the slowest fifth, which was the most reproducible of four estimators measured over 40 samples per series; wall clock and RSS are the median. C built `cc -O2 -ffp-contract=off`, Go `go build`, Bit `bit build`, each language's standard optimized build.
> Mandelbrot: Bit and C agree to the last bit; Go differs by ~0.0002% because it contracts `a*b+c` to a hardware FMA. Not a bug: cross-compiler float bit-identity is not guaranteed.
> alloc measures the ALLOCATOR: 10M short-lived nodes, each its own heap object in all three languages (Bit's element class has a reference field, Go holds `[]*Node`, C mallocs per node). allocflat measures DATA LAYOUT: the same 10M nodes and the same printed total, stored by value in one buffer per batch (Bit packs `[]Node` inline, Go holds `[]Node`, C mallocs the batch once). The gap between the two rows is what per-node heap allocation costs a language.
> allocpar measures the allocator under CONTENTION: the identical 10M nodes and the identical printed total as alloc, partitioned across 8 concurrent workers (Bit `spawn`, Go goroutines, C pthreads), worker count fixed in all three sources and never read from the host core count. The gap between the alloc and allocpar rows is what a language's allocator costs when more than one thread is in it; every other case in this table is single-mutator, so that cost appears nowhere else.
> The allocation table above is how those two claims are checked rather than asserted: same order of magnitude across a row means the three sources still express the same data structure, which is exactly what `alloc` silently lost for a day. Bit's count is `swept+live` from `BIT_GC_STATS=1`; Go's is `runtime.MemStats.Mallocs` and C's a `malloc` counter, both opt-in (`BENCH_ALLOC_STATS`, `-DBENCH_ALLOC_STATS`) and both absent from every timed binary.
> The ratios are built from CYCLES, not from wall clock. `/usr/bin/time` reports `real` in hundredths of a second and most of the C sides here finish in under 0.10s, so a wall-clock ratio for those rows would be quantisation: `map` published 7.50x C off 0.300s/0.040s where the counters say ~4.5x. Adding runs does not fix that, because it narrows the spread around a quantised value instead of removing the quantisation, so the unit changed. Cycles and instructions come from the same `/usr/bin/time -l` invocation that also produced the RSS; nothing extra is run and nothing extra is installed for those three. Wall clock is a separate one-decimal-millisecond measurement (`wall_run()`, one `fork`+`exec`+`waitpid` perl process per run, not `/usr/bin/time`'s own field) so it stays usable below `/usr/bin/time`'s 10ms floor; it still carries no ratio column and is kept as context.
> GC pauses: one untimed run per case, separate from the timed runs above (BIT_GC_STATS/GODEBUG both add real overhead). Bit's fields are `pausens=`/`pausemaxns=`/`pauses=` from `BIT_GC_STATS=1`. Go's are parsed from one `GODEBUG=gctrace=1` run: each `gc N @Ts P%: A+B+C ms clock` line's A (sweep termination) and C (mark termination) are its two STW segments (`go doc runtime`, go1.27.1), summed for the STW total, maxed individually for the longest single pause; B (concurrent mark) is not a stop and is excluded. C has no collector (n/a). Share is that probe run's own `wall_run()` wall time, not the timed loop's median. `allocpar W1`/`W8` reruns the same probe with `BIT_WORKERS`/`GOMAXPROCS` set; C is unchanged (its worker count is a compile-time `#define`, never read from env) so its wall-table cell reuses the baseline `allocpar` row rather than a redundant rerun.
> Cycles and instructions are startup-corrected: each figure has that language's own empty-program cost (`bench/cases/startup`, bit 5.6M, c 4.4M, go 6.6M) subtracted, because dyld and runtime init differ per language and are a fifth of C's `allocflat` row. Every other table is raw.

> On `matrix`, read the Go column as the target and not the C one. The C side vectorises: it retires 2.06 instructions per inner-loop iteration against Go's 9.09, so the Bit:C ratio on this row compares a scalar loop against a vectorised one and is not a statement about codegen quality. A scalar `cc -O2 -fno-vectorize` control build of the same case retires 8.07, which is the like-for-like figure. Denominator for all three: `trials * n^3 = 6 * 512^3 = 805,306,368` inner iterations.
> Reproducibility was measured rather than assumed: four independent regenerations of this table on this box held every ratio to 2.5% between adjacent runs and 8.5% at worst across all four. The loose rows are `alloc`, `map`, `allocflat` and `strings`, whose Go or C side is short enough that that language's own allocator and collector scheduling moves it by several percent from run to run; `matrix`, `mandelbrot`, `fib` and `sort` reproduce to about 1%. On those four loose rows, read a change under ~3% as noise.
> Peak RSS above is a within-run median like every other figure in that table, but it can still swing further ACROSS separate regenerations than one run shows. From every regeneration recorded in `bench/history.csv`, restricted to the same four loose rows above and to the Go/C columns (the Bit column reflects real compiler/runtime changes over that history, not noise): `alloc` c: 1.5-2.2 MB (median 2.0 MB, N=68); `allocflat` go: 10.6-12.8 MB (median 11.4 MB, N=59); `allocflat` c: 1.5-1.9 MB (median 1.9 MB, N=59); `strings` go: 61.0-100.0 MB (median 70.4 MB, N=65). Read that cell's published number as representative of the stated range, not a fixed constant.
> Instructions are published beside cycles because a cycle gap alone does not say whether it is work emitted or work stalled, and the two ratios differ a lot here: Bit retires roughly 4-7 instructions per cycle against C's 1.4-1.8, so its instruction ratio always overstates its cycle ratio. Cycles are the time; instructions are the reason.
> Generated by `bench/run.sh` on 2026-10-20T09:26:34Z. Do not edit by hand.
