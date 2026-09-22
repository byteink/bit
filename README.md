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
brew install byteink/tap/bit           # macOS
curl -fsSL bitlang.org/install.sh | sh # Linux
irm bitlang.org/install.ps1 | iex      # Windows
```

Any of them gives you a single static binary with nothing else to install - no
runtime, no VM, no libc dependency. Check it:

```
bit --version
```

Later, move an `install.sh` install to the newest release in place - `--check`
reports what it would do and changes nothing. A Homebrew install is upgraded
with `brew upgrade byteink/tap/bit`, and `bit upgrade` says so rather than
overwriting what brew owns:

```
bit upgrade --check
bit upgrade
```

Or run the toolchain as a container, no install at all:

```
docker run --rm -v "$PWD:/work" ghcr.io/byteink/bit run hello.bit

# to BUILD into your project, pass your own uid so the output belongs to you:
docker run --rm --user "$(id -u):$(id -g)" -v "$PWD:/work" ghcr.io/byteink/bit build hello.bit
```

The image runs as an unprivileged user, so without `--user` it can read your
sources but not write a binary back into them.

New here? [Get started](docs/tutorial.md) takes about fifteen minutes and ends
with a real concurrent program.

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
| fib | 1021.1 M | 956.7 M | 639.7 M | 1.07x | 1.60x |
| mandelbrot | 2134.9 M | 1639.3 M | 1606.7 M | 1.30x | 1.33x |
| collatz | 921.1 M | 626.5 M | 411.7 M | 1.47x | 2.24x |
| alloc | 984.4 M | 389.5 M | 460.9 M | 2.53x | 2.14x |
| allocflat | 255.8 M | 113.5 M | 18.1 M | 2.25x | 14.12x |
| allocpar | 21679.7 M | 1277.4 M | 2096.6 M | 16.97x | 10.34x |
| strings | 958.0 M | 357.4 M | 109.8 M | 2.68x | 8.72x |
| map | 310.8 M | 408.5 M | 181.2 M | 0.76x | 1.72x |
| strmap | 1275.3 M | 680.7 M | 249.9 M | 1.87x | 5.10x |
| sort | 293.9 M | 356.8 M | 279.2 M | 0.82x | 1.05x |
| matrix | 1383.5 M | 956.5 M | 399.5 M | 1.45x | 3.46x |
| json | 885.7 M | 340.2 M | 227.8 M | 2.60x | 3.89x |

### Instructions retired: work emitted, not time taken

| Benchmark | Bit | Go | C |
|---|--:|--:|--:|
| fib | 5962.7 M | 5137.1 M | 3146.8 M |
| mandelbrot | 4788.7 M | 2506.3 M | 2698.9 M |
| collatz | 2579.0 M | 935.6 M | 930.5 M |
| alloc | 7611.5 M | 2147.6 M | 3606.7 M |
| allocflat | 1604.2 M | 403.0 M | 59.3 M |
| allocpar | 43719.9 M | 4590.3 M | 3618.3 M |
| strings | 7109.9 M | 1674.9 M | 643.3 M |
| map | 748.6 M | 693.9 M | 229.3 M |
| strmap | 6216.1 M | 2231.0 M | 534.1 M |
| sort | 1791.9 M | 943.1 M | 503.6 M |
| matrix | 12280.2 M | 7324.2 M | 1656.3 M |
| json | 5880.2 M | 2137.4 M | 1339.7 M |

### Wall clock: median of 15 runs, context only

| Benchmark | Bit | Go | C |
|---|--:|--:|--:|
| fib | 0.230s | 0.220s | 0.150s |
| mandelbrot | 0.490s | 0.380s | 0.370s |
| collatz | 0.200s | 0.140s | 0.090s |
| alloc | 0.230s | 0.080s | 0.100s |
| allocflat | 0.060s | 0.010s | 0.000s |
| allocpar | 0.650s | 0.060s | 0.060s |
| strings | 0.220s | 0.060s | 0.020s |
| map | 0.070s | 0.090s | 0.040s |
| strmap | 0.290s | 0.150s | 0.060s |
| sort | 0.070s | 0.080s | 0.060s |
| matrix | 0.320s | 0.220s | 0.090s |
| json | 0.200s | 0.070s | 0.050s |

### Peak memory: max RSS, lower is better

| Benchmark | Bit | Go | C |
|---|--:|--:|--:|
| fib | 2.2 MB | 4.6 MB | 1.8 MB |
| mandelbrot | 2.2 MB | 4.6 MB | 1.8 MB |
| collatz | 2.3 MB | 4.6 MB | 1.8 MB |
| alloc | 6.5 MB | 10.8 MB | 2.0 MB |
| allocflat | 6.1 MB | 11.6 MB | 1.9 MB |
| allocpar | 13.3 MB | 17.9 MB | 3.8 MB |
| strings | 134.6 MB | 84.1 MB | 31.0 MB |
| map | 36.7 MB | 41.9 MB | 193.8 MB |
| strmap | 39.3 MB | 31.2 MB | 41.2 MB |
| sort | 25.8 MB | 15.2 MB | 11.4 MB |
| matrix | 8.5 MB | 11.4 MB | 7.8 MB |
| json | 128.8 MB | 56.7 MB | 125.5 MB |

### Heap allocations per run: the equivalence check, not a score

| Benchmark | Bit | Go | C |
|---|--:|--:|--:|
| fib | 6 | 196 | 0 |
| mandelbrot | 6 | 196 | 0 |
| collatz | 6 | 202 | 0 |
| alloc | 10006006 | 10002316 | 10004000 |
| allocflat | 4006 | 2301 | 2000 |
| allocpar | 10006053 | 10002411 | 10004000 |
| strings | 7125035 | 340 | 11 |
| map | 14 | 4380 | 1 |
| strmap | 400041 | 400798 | 400003 |
| sort | 600022 | 150280 | 150002 |
| matrix | 16 | 279 | 3 |
| json | 3750060 | 1049996 | 2250021 |

### Binary size: static, as emitted

| Benchmark | Bit | Go | C |
|---|--:|--:|--:|
| fib | 270 KB | 2373 KB | 33 KB |
| mandelbrot | 270 KB | 2373 KB | 33 KB |
| collatz | 270 KB | 2373 KB | 33 KB |
| alloc | 271 KB | 2390 KB | 33 KB |
| allocflat | 271 KB | 2373 KB | 33 KB |
| allocpar | 274 KB | 2390 KB | 33 KB |
| strings | 272 KB | 2389 KB | 33 KB |
| map | 293 KB | 2390 KB | 33 KB |
| strmap | 311 KB | 2390 KB | 33 KB |
| sort | 273 KB | 2407 KB | 33 KB |
| matrix | 271 KB | 2373 KB | 33 KB |
| json | 348 KB | 3679 KB | 33 KB |

### Startup & compile

| Metric | Bit | Go | C |
|---|--:|--:|--:|
| Process startup (per exec) | 4.436 ms | 4.835 ms | 4.288 ms |

Bit compile speed: **689 lines/sec** (769 lines across 12 cases, warm).

> Machine: Apple M5 Max, macOS 27.0. Bit @ `caca2c042`, Go go1.27.1, Apple clang version 21.0.0 (clang-2100.3.34.2).
> Method: 15 runs per case per language. Cycles and instructions are a trimmed mean of those runs, meaning the mean after dropping the slowest fifth, which was the most reproducible of four estimators measured over 40 samples per series; wall clock and RSS are the median. C built `cc -O2 -ffp-contract=off`, Go `go build`, Bit `bit build`, each language's standard optimized build.
> Mandelbrot: Bit and C agree to the last bit; Go differs by ~0.0002% because it contracts `a*b+c` to a hardware FMA. Not a bug: cross-compiler float bit-identity is not guaranteed.
> alloc measures the ALLOCATOR: 10M short-lived nodes, each its own heap object in all three languages (Bit's element class has a reference field, Go holds `[]*Node`, C mallocs per node). allocflat measures DATA LAYOUT: the same 10M nodes and the same printed total, stored by value in one buffer per batch (Bit packs `[]Node` inline, Go holds `[]Node`, C mallocs the batch once). The gap between the two rows is what per-node heap allocation costs a language.
> allocpar measures the allocator under CONTENTION: the identical 10M nodes and the identical printed total as alloc, partitioned across 8 concurrent workers (Bit `spawn`, Go goroutines, C pthreads), worker count fixed in all three sources and never read from the host core count. The gap between the alloc and allocpar rows is what a language's allocator costs when more than one thread is in it; every other case in this table is single-mutator, so that cost appears nowhere else.
> The allocation table above is how those two claims are checked rather than asserted: same order of magnitude across a row means the three sources still express the same data structure, which is exactly what `alloc` silently lost for a day. Bit's count is `swept+live` from `BIT_GC_STATS=1`; Go's is `runtime.MemStats.Mallocs` and C's a `malloc` counter, both opt-in (`BENCH_ALLOC_STATS`, `-DBENCH_ALLOC_STATS`) and both absent from every timed binary.
> The ratios are built from CYCLES, not from wall clock. `/usr/bin/time` reports `real` in hundredths of a second and most of the C sides here finish in under 0.10s, so a wall-clock ratio for those rows is quantisation: `map` published 7.50x C off 0.300s/0.040s where the counters say ~4.5x. Adding runs does not fix that, because it narrows the spread around a quantised value instead of removing the quantisation, so the unit changed. Both counters come from the same `/usr/bin/time -l` invocation that already produced the wall clock and the RSS; nothing extra is run and nothing extra is installed. The wall-clock table is kept as context and carries no ratio column.
> Cycles and instructions are startup-corrected: each figure has that language's own empty-program cost (`bench/cases/startup`, bit 4.8M, c 3.8M, go 5.9M) subtracted, because dyld and runtime init differ per language and are a fifth of C's `allocflat` row. Every other table is raw.

> On `matrix`, read the Go column as the target and not the C one. The C side vectorises: it retires 2.06 instructions per inner-loop iteration against Go's 9.09, so the Bit:C ratio on this row compares a scalar loop against a vectorised one and is not a statement about codegen quality. A scalar `cc -O2 -fno-vectorize` control build of the same case retires 8.07, which is the like-for-like figure. Denominator for all three: `trials * n^3 = 6 * 512^3 = 805,306,368` inner iterations.
> Reproducibility was measured rather than assumed: four independent regenerations of this table on this box held every ratio to 2.5% between adjacent runs and 8.5% at worst across all four. The loose rows are `alloc`, `map`, `allocflat` and `strings`, whose Go or C side is short enough that that language's own allocator and collector scheduling moves it by several percent from run to run; `matrix`, `mandelbrot`, `fib` and `sort` reproduce to about 1%. On those four loose rows, read a change under ~3% as noise.
> Peak RSS above is a within-run median like every other figure in that table, but it can still swing further ACROSS separate regenerations than one run shows. From every regeneration recorded in `bench/history.csv`, restricted to the same four loose rows above and to the Go/C columns (the Bit column reflects real compiler/runtime changes over that history, not noise): `alloc` c: 1.5-2.0 MB (median 1.6 MB, N=31); `allocflat` go: 10.6-11.7 MB (median 11.3 MB, N=22); `allocflat` c: 1.5-1.9 MB (median 1.5 MB, N=22); `strings` go: 64.3-90.9 MB (median 70.0 MB, N=28). Read that cell's published number as representative of the stated range, not a fixed constant.
> Instructions are published beside cycles because a cycle gap alone does not say whether it is work emitted or work stalled, and the two ratios differ a lot here: Bit retires roughly 4-7 instructions per cycle against C's 1.4-1.8, so its instruction ratio always overstates its cycle ratio. Cycles are the time; instructions are the reason.
> Generated by `bench/run.sh` on 2026-09-22T01:56:31Z. Do not edit by hand.
<!-- BENCH:END -->

## License

Bit is licensed under the [Apache License 2.0](LICENSE).

See [CONTRIBUTING.md](CONTRIBUTING.md) for contribution guidelines,
[SECURITY.md](SECURITY.md) for reporting vulnerabilities, and
[TRADEMARK.md](TRADEMARK.md) for trademark guidelines.
