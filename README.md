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
| fib | 1012.2 M | 944.6 M | 636.5 M | 1.07x | 1.59x |
| mandelbrot | 2137.8 M | 1642.9 M | 1609.4 M | 1.30x | 1.33x |
| collatz | 917.9 M | 627.8 M | 412.1 M | 1.46x | 2.23x |
| alloc | 984.0 M | 394.3 M | 616.8 M | 2.50x | 1.60x |
| allocflat | 256.6 M | 122.1 M | 18.1 M | 2.10x | 14.17x |
| strings | 958.9 M | 362.3 M | 110.1 M | 2.65x | 8.71x |
| map | 327.0 M | 427.9 M | 174.9 M | 0.76x | 1.87x |
| strmap | 1372.3 M | 691.2 M | 265.9 M | 1.99x | 5.16x |
| sort | 330.9 M | 363.5 M | 287.9 M | 0.91x | 1.15x |
| matrix | 1384.2 M | 955.7 M | 400.1 M | 1.45x | 3.46x |
| json | 1379.6 M | 339.8 M | 234.4 M | 4.06x | 5.89x |

### Instructions retired: work emitted, not time taken

| Benchmark | Bit | Go | C |
|---|--:|--:|--:|
| fib | 5962.7 M | 5136.9 M | 3146.8 M |
| mandelbrot | 4789.7 M | 2507.2 M | 2699.5 M |
| collatz | 2579.1 M | 935.5 M | 930.6 M |
| alloc | 7549.7 M | 2158.9 M | 4287.8 M |
| allocflat | 1603.5 M | 405.1 M | 59.4 M |
| strings | 7066.8 M | 1682.8 M | 643.4 M |
| map | 748.6 M | 693.4 M | 229.8 M |
| strmap | 6428.6 M | 2238.6 M | 540.4 M |
| sort | 1882.9 M | 943.9 M | 509.5 M |
| matrix | 12280.4 M | 7324.2 M | 1656.6 M |
| json | 9283.9 M | 2134.1 M | 1372.6 M |

### Wall clock: median of 15 runs, context only

| Benchmark | Bit | Go | C |
|---|--:|--:|--:|
| fib | 0.230s | 0.220s | 0.150s |
| mandelbrot | 0.480s | 0.370s | 0.360s |
| collatz | 0.210s | 0.140s | 0.090s |
| alloc | 0.230s | 0.080s | 0.140s |
| allocflat | 0.060s | 0.020s | 0.000s |
| strings | 0.220s | 0.060s | 0.020s |
| map | 0.070s | 0.100s | 0.040s |
| strmap | 0.310s | 0.150s | 0.060s |
| sort | 0.070s | 0.080s | 0.060s |
| matrix | 0.320s | 0.220s | 0.090s |
| json | 0.320s | 0.070s | 0.050s |

### Peak memory: max RSS, lower is better

| Benchmark | Bit | Go | C |
|---|--:|--:|--:|
| fib | 1.8 MB | 4.2 MB | 1.4 MB |
| mandelbrot | 1.8 MB | 4.2 MB | 1.4 MB |
| collatz | 2.0 MB | 4.2 MB | 1.4 MB |
| alloc | 6.1 MB | 10.4 MB | 1.6 MB |
| allocflat | 5.7 MB | 10.8 MB | 1.5 MB |
| strings | 134.2 MB | 83.8 MB | 30.7 MB |
| map | 36.3 MB | 41.5 MB | 193.5 MB |
| strmap | 35.6 MB | 30.8 MB | 40.8 MB |
| sort | 25.1 MB | 14.8 MB | 11.0 MB |
| matrix | 8.2 MB | 10.9 MB | 7.5 MB |
| json | 179.0 MB | 55.5 MB | 125.2 MB |

### Heap allocations per run: the equivalence check, not a score

| Benchmark | Bit | Go | C |
|---|--:|--:|--:|
| fib | 6 | 194 | 0 |
| mandelbrot | 6 | 194 | 0 |
| collatz | 6 | 194 | 0 |
| alloc | 10006006 | 10002303 | 10004000 |
| allocflat | 4006 | 2305 | 2000 |
| strings | 7125035 | 338 | 11 |
| map | 14 | 4371 | 1 |
| strmap | 400041 | 400802 | 400003 |
| sort | 600022 | 150284 | 150002 |
| matrix | 16 | 277 | 3 |
| json | 5400061 | 1049993 | 2250021 |

### Binary size: static, as emitted

| Benchmark | Bit | Go | C |
|---|--:|--:|--:|
| fib | 235 KB | 2373 KB | 33 KB |
| mandelbrot | 235 KB | 2373 KB | 33 KB |
| collatz | 235 KB | 2373 KB | 33 KB |
| alloc | 235 KB | 2390 KB | 33 KB |
| allocflat | 235 KB | 2373 KB | 33 KB |
| strings | 269 KB | 2389 KB | 33 KB |
| map | 273 KB | 2390 KB | 33 KB |
| strmap | 291 KB | 2390 KB | 33 KB |
| sort | 270 KB | 2407 KB | 33 KB |
| matrix | 235 KB | 2373 KB | 33 KB |
| json | 344 KB | 3679 KB | 33 KB |

### Startup & compile

| Metric | Bit | Go | C |
|---|--:|--:|--:|
| Process startup (per exec) | 4.376 ms | 4.653 ms | 4.330 ms |

Bit compile speed: **587 lines/sec** (669 lines across 11 cases, warm).

> Machine: Apple M5 Max, macOS 26.6.2. Bit @ `52be55dc`, Go go1.27.1, Apple clang version 21.0.0 (clang-2100.1.1.101).
> Method: 15 runs per case per language. Cycles and instructions are a trimmed mean of those runs, meaning the mean after dropping the slowest fifth, which was the most reproducible of four estimators measured over 40 samples per series; wall clock and RSS are the median. C built `cc -O2 -ffp-contract=off`, Go `go build`, Bit `bit build`, each language's standard optimized build.
> Mandelbrot: Bit and C agree to the last bit; Go differs by ~0.0002% because it contracts `a*b+c` to a hardware FMA. Not a bug: cross-compiler float bit-identity is not guaranteed.
> alloc measures the ALLOCATOR: 10M short-lived nodes, each its own heap object in all three languages (Bit's element class has a reference field, Go holds `[]*Node`, C mallocs per node). allocflat measures DATA LAYOUT: the same 10M nodes and the same printed total, stored by value in one buffer per batch (Bit packs `[]Node` inline since #3862, Go holds `[]Node`, C mallocs the batch once). The gap between the two rows is what per-node heap allocation costs a language.
> The allocation table above is how those two claims are checked rather than asserted: same order of magnitude across a row means the three sources still express the same data structure, which is exactly what `alloc` silently lost for a day (#3934). Bit's count is `swept+live` from `BIT_GC_STATS=1`; Go's is `runtime.MemStats.Mallocs` and C's a `malloc` counter, both opt-in (`BENCH_ALLOC_STATS`, `-DBENCH_ALLOC_STATS`) and both absent from every timed binary.
> The ratios are built from CYCLES, not from wall clock. `/usr/bin/time` reports `real` in hundredths of a second and most of the C sides here finish in under 0.10s, so a wall-clock ratio for those rows is quantisation: `map` published 7.50x C off 0.300s/0.040s where the counters say ~4.5x. Adding runs does not fix that, because it narrows the spread around a quantised value instead of removing the quantisation, so the unit changed (#4040). Both counters come from the same `/usr/bin/time -l` invocation that already produced the wall clock and the RSS; nothing extra is run and nothing extra is installed. The wall-clock table is kept as context and carries no ratio column.
> Cycles and instructions are startup-corrected: each figure has that language's own empty-program cost (`bench/cases/startup`, bit 4.4M, c 3.7M, go 5.6M) subtracted, because dyld and runtime init differ per language and are a fifth of C's `allocflat` row. Every other table is raw.

> On `matrix`, read the Go column as the target and not the C one. The C side vectorises: it retires 2.06 instructions per inner-loop iteration against Go's 9.09, so the Bit:C ratio on this row compares a scalar loop against a vectorised one and is not a statement about codegen quality. A scalar `cc -O2 -fno-vectorize` control build of the same case retires 8.07, which is the like-for-like figure. Denominator for all three: `trials * n^3 = 6 * 512^3 = 805,306,368` inner iterations.
> Reproducibility was measured rather than assumed (#4040): four independent regenerations of this table on this box held every ratio to 2.5% between adjacent runs and 8.5% at worst across all four. The loose rows are `alloc`, `map`, `allocflat` and `strings`, whose Go or C side is short enough that that language's own allocator and collector scheduling moves it by several percent from run to run; `matrix`, `mandelbrot`, `fib` and `sort` reproduce to about 1%. On those four loose rows, read a change under ~3% as noise.
> Peak RSS above is a within-run median like every other figure in that table, but it can still swing further ACROSS separate regenerations than one run shows (#4199). From every regeneration recorded in `bench/history.csv`, restricted to the same four loose rows above and to the Go/C columns (the Bit column reflects real compiler/runtime changes over that history, not noise): `alloc` c: 1.5-1.7 MB (median 1.6 MB, N=20); `strings` go: 64.3-90.9 MB (median 69.0 MB, N=17). Read that cell's published number as representative of the stated range, not a fixed constant.
> Instructions are published beside cycles because a cycle gap alone does not say whether it is work emitted or work stalled, and the two ratios differ a lot here: Bit retires roughly 4-7 instructions per cycle against C's 1.4-1.8, so its instruction ratio always overstates its cycle ratio. Cycles are the time; instructions are the reason.
> Generated by `bench/run.sh` on 2026-09-13T03:37:50Z. Do not edit by hand.
<!-- BENCH:END -->

## License

Bit is licensed under the [Apache License 2.0](LICENSE).

See [CONTRIBUTING.md](CONTRIBUTING.md) for contribution guidelines,
[SECURITY.md](SECURITY.md) for reporting vulnerabilities, and
[TRADEMARK.md](TRADEMARK.md) for trademark guidelines.
