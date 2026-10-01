# Bit

Bit is a systems programming language with TypeScript-flavored syntax and
Go-like semantics. You write `let`/`const`, `fn`, arrows, `interface`,
and `<>` generics; you get garbage collection, green threads (`spawn`), typed
channels, and structural interfaces. Programs compile to a single static native
binary with zero runtime and zero external toolchain - the compiler owns every
stage from lexer to linker, so there is no LLVM, no system assembler, and no
libc dependency.

## Status

**Pre-1.0.** The compiler is self-hosted - written in Bit, compiling itself to a
fixed point (the binary stage 2 produces and the binary stage 3 produces are
byte-identical). The language, standard library and toolchain work: package
manager, language server, formatter, linter, test runner.

What that does *not* mean: the API is not frozen, and `0.x` releases carry no
support guarantee. Read [the support policy](docs/release/SUPPORT.md) before
depending on it.

**Platforms.** Linux and macOS on x86-64 and ARM64, and Windows on x86-64.
ARM64 Windows is out of scope for the Windows port; x86-64 is the only
Windows target.

## Install

```
brew install byteink/tap/bit           # macOS; see Get started for Linux, Windows and Docker
```

A single static binary with nothing else to install - no runtime, no VM, no
libc dependency. [Get started](docs/get-started.md) covers every platform,
verifies the install, and runs your first program.

## Build from source

You only need this to work *on* Bit. Users install the binary above.

No toolchain to install. `./make` downloads and digest-verifies the pinned
previous release and builds this tree with it - the usual chicken-and-egg every
self-hosted language has, resolved by a published binary rather than by a second
compiler. You need `sh`, `curl` and `tar`; none of it is needed to *use* Bit.

```
./make             # build the compiler into bit-out/bin
./make test        # run the full suite
./make --list      # every step and what it does
scripts/gate.sh    # run only what your diff can affect
```

[`docs/development.md`](docs/development.md) covers the bootstrap chain, the
testing conventions, the 800-line file-size rule and the traps a green build does
not catch. Read it before a large refactor.

## Layout

| Path        | Purpose                                             |
|-------------|-----------------------------------------------------|
| `compiler/` | The compiler (`bit`), written in Bit                |
| `runtime/`  | Runtime linked into user binaries, written in Bit   |
| `stdlib/`   | Standard library, written in Bit                    |
| `spec/`     | Language specification (source of truth)            |
| `docs/`     | Reference and tutorial documentation                |
| `editors/`  | Editor support (VS Code extension, LSP client)      |
| `dist/`     | Packaging (brew formula, installers)                |
| `_tests_/`    | Golden-file and stress tests                        |

See [`docs/release/VERSIONING.md`](docs/release/VERSIONING.md) for what
counts as a breaking, additive, or fix change across the language, CLI,
stdlib, and runtime ABI.

## Benchmarks

Bit compiles to a single static native binary with a garbage-collected runtime.
The tables below compare four CPU-bound micro-benchmarks against Go (also GC'd)
and C (`-O2`), covering call overhead, float math, integer/branch work, and
allocation churn. Reproduce with `bench/run.sh`; sources live in `bench/cases/`.

<!-- BENCH:START -->
_Full method and caveats below the tables._

### Runtime: CPU cycles, lower is better

| Benchmark | Bit | Go | C | Bit / Go | Bit / C |
|---|--:|--:|--:|--:|--:|
| fib | 1018.0 M | 939.5 M | 636.7 M | 1.08x | 1.60x |
| mandelbrot | 2134.0 M | 1640.1 M | 1606.5 M | 1.30x | 1.33x |
| collatz | 920.2 M | 627.6 M | 412.3 M | 1.47x | 2.23x |
| alloc | 781.4 M | 391.2 M | 470.6 M | 2.00x | 1.66x |
| allocflat | 222.3 M | 110.8 M | 18.0 M | 2.01x | 12.36x |
| allocpar | 2532.0 M | 1226.5 M | 2130.8 M | 2.06x | 1.19x |
| strings | 207.9 M | 374.9 M | 108.7 M | 0.55x | 1.91x |
| map | 313.7 M | 386.7 M | 177.0 M | 0.81x | 1.77x |
| strmap | 1301.4 M | 676.4 M | 253.6 M | 1.92x | 5.13x |
| sort | 285.6 M | 357.7 M | 279.6 M | 0.80x | 1.02x |
| matrix | 1380.6 M | 951.6 M | 398.8 M | 1.45x | 3.46x |
| json | 826.9 M | 336.5 M | 227.0 M | 2.46x | 3.64x |

### Instructions retired: work emitted, not time taken

| Benchmark | Bit | Go | C |
|---|--:|--:|--:|
| fib | 5962.8 M | 5137.2 M | 3146.8 M |
| mandelbrot | 4789.0 M | 2506.8 M | 2699.1 M |
| collatz | 2579.1 M | 935.7 M | 930.6 M |
| alloc | 5557.6 M | 2154.9 M | 3606.9 M |
| allocflat | 1456.0 M | 402.2 M | 59.3 M |
| allocpar | 8617.3 M | 4590.2 M | 3619.6 M |
| strings | 1699.6 M | 1722.7 M | 643.4 M |
| map | 749.3 M | 693.5 M | 229.3 M |
| strmap | 6156.7 M | 2225.1 M | 534.2 M |
| sort | 1723.9 M | 943.1 M | 503.7 M |
| matrix | 12272.0 M | 7324.0 M | 1656.2 M |
| json | 5402.4 M | 2133.2 M | 1340.0 M |

### Wall clock: median of 15 runs, milliseconds

| Benchmark | Bit | Go | C |
|---|--:|--:|--:|
| fib | 242.8 ms | 224.4 ms | 151.5 ms |
| mandelbrot | 502.2 ms | 386.9 ms | 379.0 ms |
| collatz | 217.7 ms | 149.9 ms | 98.8 ms |
| alloc | 183.2 ms | 81.5 ms | 117.3 ms |
| allocflat | 53.5 ms | 19.1 ms | 6.2 ms |
| allocpar | 71.1 ms | 59.3 ms | 67.2 ms |
| strings | 51.7 ms | 60.3 ms | 27.5 ms |
| map | 74.6 ms | 88.2 ms | 44.1 ms |
| strmap | 306.2 ms | 156.7 ms | 61.2 ms |
| sort | 67.6 ms | 84.5 ms | 64.8 ms |
| matrix | 320.9 ms | 223.9 ms | 94.9 ms |
| json | 193.4 ms | 74.6 ms | 56.6 ms |
| allocpar W1 | 219.9 ms | 105.3 ms | 67.2 ms |
| allocpar W8 | 61.8 ms | 59.7 ms | 67.2 ms |

### GC pauses: one untimed run per case, share of that run's own wall clock

| Benchmark | Bit pauses | Bit pausens ms (share) | Bit pausemax ms | Go GCs | Go STW ms (share) | Go STW max ms | C |
|---|--:|--:|--:|--:|--:|--:|--:|
| fib | 0 | 0.0 ms (0.0%) | 0.0 ms | 0 | 0.0 ms (0.0%) | 0.0 ms | n/a |
| mandelbrot | 0 | 0.0 ms (0.0%) | 0.0 ms | 0 | 0.0 ms (0.0%) | 0.0 ms | n/a |
| collatz | 0 | 0.0 ms (0.0%) | 0.0 ms | 0 | 0.0 ms (0.0%) | 0.0 ms | n/a |
| alloc | 133 | 37.1 ms (19.8%) | 0.3 ms | 69 | 2.0 ms (2.5%) | 0.1 ms | n/a |
| allocflat | 68 | 2.9 ms (4.5%) | 0.1 ms | 77 | 2.2 ms (11.6%) | 0.0 ms | n/a |
| allocpar | 168 | 42.2 ms (58.7%) | 0.9 ms | 67 | 7.3 ms (12.4%) | 0.2 ms | n/a |
| strings | 3 | 0.2 ms (0.4%) | 0.2 ms | 10 | 0.3 ms (0.5%) | 0.0 ms | n/a |
| map | 1 | 0.0 ms (0.0%) | 0.0 ms | 4 | 0.1 ms (0.1%) | 0.0 ms | n/a |
| strmap | 4 | 11.0 ms (3.7%) | 8.6 ms | 3 | 0.1 ms (0.1%) | 0.0 ms | n/a |
| sort | 7 | 7.4 ms (11.1%) | 2.4 ms | 1 | 0.0 ms (0.0%) | 0.0 ms | n/a |
| matrix | 1 | 0.0 ms (0.0%) | 0.0 ms | 1 | 0.0 ms (0.0%) | 0.0 ms | n/a |
| json | 17 | 42.8 ms (22.7%) | 29.0 ms | 10 | 0.3 ms (0.4%) | 0.0 ms | n/a |
| allocpar W1 | 156 | 68.9 ms (31.5%) | 0.6 ms | 77 | 0.0 ms (0.0%) | 0.0 ms | n/a |
| allocpar W8 | 175 | 37.3 ms (58.1%) | 0.3 ms | 80 | 7.0 ms (11.7%) | 0.2 ms | n/a |

### Peak memory: max RSS, lower is better

| Benchmark | Bit | Go | C |
|---|--:|--:|--:|
| fib | 2.3 MB | 4.6 MB | 1.8 MB |
| mandelbrot | 2.3 MB | 4.6 MB | 1.8 MB |
| collatz | 2.5 MB | 4.6 MB | 1.8 MB |
| alloc | 6.6 MB | 10.8 MB | 2.0 MB |
| allocflat | 6.2 MB | 11.9 MB | 1.9 MB |
| allocpar | 13.8 MB | 18.3 MB | 3.8 MB |
| strings | 78.7 MB | 84.2 MB | 31.0 MB |
| map | 36.8 MB | 41.9 MB | 193.8 MB |
| strmap | 39.4 MB | 31.3 MB | 41.2 MB |
| sort | 18.1 MB | 15.2 MB | 11.4 MB |
| matrix | 8.7 MB | 11.4 MB | 7.8 MB |
| json | 128.9 MB | 55.1 MB | 125.5 MB |

### Heap allocations per run: the equivalence check, not a score

| Benchmark | Bit | Go | C |
|---|--:|--:|--:|
| fib | 6 | 199 | 0 |
| mandelbrot | 6 | 199 | 0 |
| collatz | 6 | 199 | 0 |
| alloc | 10006006 | 10002315 | 10004000 |
| allocflat | 4006 | 2299 | 2000 |
| allocpar | 10006053 | 10002424 | 10004000 |
| strings | 37 | 344 | 11 |
| map | 14 | 4382 | 1 |
| strmap | 400041 | 400820 | 400003 |
| sort | 600022 | 150289 | 150002 |
| matrix | 16 | 282 | 3 |
| json | 3750064 | 1049993 | 2250021 |

### Binary size: static, as emitted

| Benchmark | Bit | Go | C |
|---|--:|--:|--:|
| fib | 331 KB | 2373 KB | 33 KB |
| mandelbrot | 331 KB | 2373 KB | 33 KB |
| collatz | 331 KB | 2373 KB | 33 KB |
| alloc | 331 KB | 2390 KB | 33 KB |
| allocflat | 331 KB | 2373 KB | 33 KB |
| allocpar | 351 KB | 2390 KB | 33 KB |
| strings | 332 KB | 2389 KB | 33 KB |
| map | 370 KB | 2390 KB | 33 KB |
| strmap | 371 KB | 2390 KB | 33 KB |
| sort | 349 KB | 2407 KB | 33 KB |
| matrix | 331 KB | 2373 KB | 33 KB |
| json | 424 KB | 3679 KB | 33 KB |

### Startup & compile

| Metric | Bit | Go | C |
|---|--:|--:|--:|
| Process startup (per exec) | 3.634 ms | 3.964 ms | 3.347 ms |

Bit compile speed: **518 lines/sec** (769 lines across 12 cases, warm).

> Machine: Apple M5 Max, macOS 27.0.1. Bit @ `0d23128a0`, Go go1.27.1, Apple clang version 21.0.0 (clang-2100.3.34.2).
> Method: 15 runs per case per language. Cycles and instructions are a trimmed mean of those runs, meaning the mean after dropping the slowest fifth, which was the most reproducible of four estimators measured over 40 samples per series; wall clock and RSS are the median. C built `cc -O2 -ffp-contract=off`, Go `go build`, Bit `bit build`, each language's standard optimized build.
> Mandelbrot: Bit and C agree to the last bit; Go differs by ~0.0002% because it contracts `a*b+c` to a hardware FMA. Not a bug: cross-compiler float bit-identity is not guaranteed.
> alloc measures the ALLOCATOR: 10M short-lived nodes, each its own heap object in all three languages (Bit's element class has a reference field, Go holds `[]*Node`, C mallocs per node). allocflat measures DATA LAYOUT: the same 10M nodes and the same printed total, stored by value in one buffer per batch (Bit packs `[]Node` inline, Go holds `[]Node`, C mallocs the batch once). The gap between the two rows is what per-node heap allocation costs a language.
> allocpar measures the allocator under CONTENTION: the identical 10M nodes and the identical printed total as alloc, partitioned across 8 concurrent workers (Bit `spawn`, Go goroutines, C pthreads), worker count fixed in all three sources and never read from the host core count. The gap between the alloc and allocpar rows is what a language's allocator costs when more than one thread is in it; every other case in this table is single-mutator, so that cost appears nowhere else.
> The allocation table above is how those two claims are checked rather than asserted: same order of magnitude across a row means the three sources still express the same data structure, which is exactly what `alloc` silently lost for a day. Bit's count is `swept+live` from `BIT_GC_STATS=1`; Go's is `runtime.MemStats.Mallocs` and C's a `malloc` counter, both opt-in (`BENCH_ALLOC_STATS`, `-DBENCH_ALLOC_STATS`) and both absent from every timed binary.
> The ratios are built from CYCLES, not from wall clock. `/usr/bin/time` reports `real` in hundredths of a second and most of the C sides here finish in under 0.10s, so a wall-clock ratio for those rows would be quantisation: `map` published 7.50x C off 0.300s/0.040s where the counters say ~4.5x. Adding runs does not fix that, because it narrows the spread around a quantised value instead of removing the quantisation, so the unit changed. Cycles and instructions come from the same `/usr/bin/time -l` invocation that also produced the RSS; nothing extra is run and nothing extra is installed for those three. Wall clock is a separate one-decimal-millisecond measurement (`wall_run()`, one `fork`+`exec`+`waitpid` perl process per run, not `/usr/bin/time`'s own field) so it stays usable below `/usr/bin/time`'s 10ms floor; it still carries no ratio column and is kept as context.
> GC pauses: one untimed run per case, separate from the timed runs above (BIT_GC_STATS/GODEBUG both add real overhead). Bit's fields are `pausens=`/`pausemaxns=`/`pauses=` from `BIT_GC_STATS=1`. Go's are parsed from one `GODEBUG=gctrace=1` run: each `gc N @Ts P%: A+B+C ms clock` line's A (sweep termination) and C (mark termination) are its two STW segments (`go doc runtime`, go1.27.1), summed for the STW total, maxed individually for the longest single pause; B (concurrent mark) is not a stop and is excluded. C has no collector (n/a). Share is that probe run's own `wall_run()` wall time, not the timed loop's median. `allocpar W1`/`W8` reruns the same probe with `BIT_WORKERS`/`GOMAXPROCS` set; C is unchanged (its worker count is a compile-time `#define`, never read from env) so its wall-table cell reuses the baseline `allocpar` row rather than a redundant rerun.
> Cycles and instructions are startup-corrected: each figure has that language's own empty-program cost (`bench/cases/startup`, bit 4.7M, c 3.8M, go 5.8M) subtracted, because dyld and runtime init differ per language and are a fifth of C's `allocflat` row. Every other table is raw.

> On `matrix`, read the Go column as the target and not the C one. The C side vectorises: it retires 2.06 instructions per inner-loop iteration against Go's 9.09, so the Bit:C ratio on this row compares a scalar loop against a vectorised one and is not a statement about codegen quality. A scalar `cc -O2 -fno-vectorize` control build of the same case retires 8.07, which is the like-for-like figure. Denominator for all three: `trials * n^3 = 6 * 512^3 = 805,306,368` inner iterations.
> Reproducibility was measured rather than assumed: four independent regenerations of this table on this box held every ratio to 2.5% between adjacent runs and 8.5% at worst across all four. The loose rows are `alloc`, `map`, `allocflat` and `strings`, whose Go or C side is short enough that that language's own allocator and collector scheduling moves it by several percent from run to run; `matrix`, `mandelbrot`, `fib` and `sort` reproduce to about 1%. On those four loose rows, read a change under ~3% as noise.
> Peak RSS above is a within-run median like every other figure in that table, but it can still swing further ACROSS separate regenerations than one run shows. From every regeneration recorded in `bench/history.csv`, restricted to the same four loose rows above and to the Go/C columns (the Bit column reflects real compiler/runtime changes over that history, not noise): `alloc` c: 1.5-2.0 MB (median 1.7 MB, N=46); `allocflat` go: 10.6-12.0 MB (median 11.4 MB, N=37); `allocflat` c: 1.5-1.9 MB (median 1.9 MB, N=37); `strings` go: 64.3-90.9 MB (median 75.8 MB, N=43). Read that cell's published number as representative of the stated range, not a fixed constant.
> Instructions are published beside cycles because a cycle gap alone does not say whether it is work emitted or work stalled, and the two ratios differ a lot here: Bit retires roughly 4-7 instructions per cycle against C's 1.4-1.8, so its instruction ratio always overstates its cycle ratio. Cycles are the time; instructions are the reason.
> Generated by `bench/run.sh` on 2026-10-01T01:41:35Z. Do not edit by hand.
<!-- BENCH:END -->

## License

Bit is licensed under the [Apache License 2.0](LICENSE).

See [CONTRIBUTING.md](CONTRIBUTING.md) for contribution guidelines,
[SECURITY.md](SECURITY.md) for reporting vulnerabilities, and
[TRADEMARK.md](TRADEMARK.md) for trademark guidelines.
