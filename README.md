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

**Platforms.** Linux and macOS on x86-64 and ARM64. Windows is not supported yet:
the self-hosted compiler has no PE/COFF object writer, no Windows CLI target and
no Windows runtime port, so no Windows artifact is built. A PE/COFF writer and
linker existed in the retired Zig seed (`seed/obj/pe.zig`, `seed/link/pe.zig`,
recoverable at `4ffb5523^`) and are the port reference, not code still in the
tree.

## Install

```
brew install byteink/tap/bit             # macOS
curl -fsSL bitlang.org/install.sh | sh   # Linux
```

Either way you get a single static binary with nothing else to install - no
runtime, no VM, no libc dependency. Check it:

```
bit --version
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

### Runtime — CPU cycles, lower is better

| Benchmark | Bit | Go | C | Bit / Go | Bit / C |
|---|--:|--:|--:|--:|--:|
| fib | 1057.5 M | 953.5 M | 632.9 M | 1.11x | 1.67x |
| mandelbrot | 2157.2 M | 1637.2 M | 1604.8 M | 1.32x | 1.34x |
| collatz | 1204.3 M | 625.8 M | 410.9 M | 1.92x | 2.93x |
| alloc | 3495.3 M | 391.6 M | 683.8 M | 8.93x | 5.11x |
| allocflat | 345.8 M | 115.8 M | 17.4 M | 2.99x | 19.83x |
| strings | 3679.5 M | 382.0 M | 108.6 M | 9.63x | 33.87x |
| map | 758.7 M | 371.1 M | 170.3 M | 2.04x | 4.45x |
| sort | 1030.3 M | 357.2 M | 285.7 M | 2.88x | 3.61x |
| matrix | 8971.8 M | 950.3 M | 398.2 M | 9.44x | 22.53x |
| json | 5900.1 M | 337.0 M | 230.8 M | 17.51x | 25.57x |

### Instructions retired — work emitted, not time taken

| Benchmark | Bit | Go | C |
|---|--:|--:|--:|
| fib | 6790.6 M | 5136.6 M | 3146.6 M |
| mandelbrot | 8527.2 M | 2505.9 M | 2698.7 M |
| collatz | 5400.4 M | 935.1 M | 930.5 M |
| alloc | 24974.1 M | 2154.9 M | 4289.4 M |
| allocflat | 2901.2 M | 400.5 M | 59.3 M |
| strings | 24356.3 M | 1730.5 M | 643.3 M |
| map | 2712.3 M | 693.0 M | 228.9 M |
| sort | 7151.7 M | 942.7 M | 508.6 M |
| matrix | 75278.4 M | 7323.4 M | 1656.1 M |
| json | 35891.0 M | 2124.4 M | 1371.6 M |

### Wall clock — median of 15 runs, context only

| Benchmark | Bit | Go | C |
|---|--:|--:|--:|
| fib | 0.240s | 0.220s | 0.140s |
| mandelbrot | 0.500s | 0.370s | 0.360s |
| collatz | 0.270s | 0.140s | 0.090s |
| alloc | 0.810s | 0.080s | 0.160s |
| allocflat | 0.080s | 0.010s | 0.000s |
| strings | 0.850s | 0.050s | 0.020s |
| map | 0.170s | 0.080s | 0.040s |
| sort | 0.240s | 0.080s | 0.060s |
| matrix | 2.080s | 0.220s | 0.090s |
| json | 1.370s | 0.070s | 0.050s |

### Peak memory — max RSS, lower is better

| Benchmark | Bit | Go | C |
|---|--:|--:|--:|
| fib | 1.9 MB | 4.1 MB | 1.4 MB |
| mandelbrot | 1.8 MB | 4.1 MB | 1.4 MB |
| collatz | 2.0 MB | 4.1 MB | 1.4 MB |
| alloc | 5.9 MB | 10.4 MB | 1.6 MB |
| allocflat | 5.7 MB | 11.0 MB | 1.5 MB |
| strings | 131.0 MB | 68.9 MB | 30.7 MB |
| map | 62.6 MB | 41.5 MB | 193.5 MB |
| sort | 33.8 MB | 14.8 MB | 11.0 MB |
| matrix | 20.0 MB | 10.9 MB | 7.5 MB |
| json | 324.1 MB | 56.2 MB | 125.2 MB |

### Heap allocations per run — the equivalence check, not a score

| Benchmark | Bit | Go | C |
|---|--:|--:|--:|
| fib | 7 | — | — |
| mandelbrot | 7 | — | — |
| collatz | 7 | — | — |
| alloc | 10006007 | 10002310 | 10004000 |
| allocflat | 4007 | 2291 | 2000 |
| strings | 7125044 | — | — |
| map | 74 | — | — |
| sort | 1250035 | — | — |
| matrix | 52 | — | — |
| json | 7350067 | — | — |

### Binary size — static, as emitted

| Benchmark | Bit | Go | C |
|---|--:|--:|--:|
| fib | 247 KB | 2373 KB | 33 KB |
| mandelbrot | 247 KB | 2373 KB | 33 KB |
| collatz | 247 KB | 2373 KB | 33 KB |
| alloc | 248 KB | 2390 KB | 33 KB |
| allocflat | 247 KB | 2373 KB | 33 KB |
| strings | 248 KB | 2373 KB | 33 KB |
| map | 267 KB | 2373 KB | 33 KB |
| sort | 265 KB | 2391 KB | 33 KB |
| matrix | 247 KB | 2373 KB | 33 KB |
| json | 339 KB | 3678 KB | 33 KB |

### Startup & compile

| Metric | Bit | Go | C |
|---|--:|--:|--:|
| Process startup (per exec) | 3.755 ms | 4.048 ms | 3.484 ms |

Bit compile speed: **292 lines/sec** (499 lines across 10 cases, warm).

> Machine: Apple M5 Max, macOS 26.6.2. Bit @ `6f6a730e`, Go go1.27.0, Apple clang version 21.0.0 (clang-2100.1.1.101).
> Method: 15 runs per case per language. Cycles and instructions are a trimmed mean of those runs — the mean after dropping the slowest fifth, which was the most reproducible of four estimators measured over 40 samples per series; wall clock and RSS are the median. C built `cc -O2 -ffp-contract=off`, Go `go build`, Bit `bit build` — each language's standard optimized build.
> Mandelbrot: Bit and C agree to the last bit; Go differs by ~0.0002% because it contracts `a*b+c` to a hardware FMA. Not a bug — cross-compiler float bit-identity is not guaranteed.
> alloc measures the ALLOCATOR: 10M short-lived nodes, each its own heap object in all three languages (Bit's element class has a reference field, Go holds `[]*Node`, C mallocs per node). allocflat measures DATA LAYOUT: the same 10M nodes and the same printed total, stored by value in one buffer per batch (Bit packs `[]Node` inline since #3862, Go holds `[]Node`, C mallocs the batch once). The gap between the two rows is what per-node heap allocation costs a language.
> The allocation table above is how those two claims are checked rather than asserted — same order of magnitude across a row means the three sources still express the same data structure, which is exactly what `alloc` silently lost for a day (#3934). Bit's count is `swept+live` from `BIT_GC_STATS=1`; Go's is `runtime.MemStats.Mallocs` and C's a `malloc` counter, both opt-in (`BENCH_ALLOC_STATS`, `-DBENCH_ALLOC_STATS`) and both absent from every timed binary.
> The ratios are built from CYCLES, not from wall clock. `/usr/bin/time` reports `real` in hundredths of a second and most of the C sides here finish in under 0.10s, so a wall-clock ratio for those rows is quantisation: `map` published 7.50x C off 0.300s/0.040s where the counters say ~4.5x. Adding runs does not fix that — it narrows the spread around a quantised value instead of removing the quantisation — so the unit changed (#4040). Both counters come from the same `/usr/bin/time -l` invocation that already produced the wall clock and the RSS; nothing extra is run and nothing extra is installed. The wall-clock table is kept as context and carries no ratio column.
> Cycles and instructions are startup-corrected: each figure has that language's own empty-program cost (`bench/cases/startup`, bit 4.4M, c 3.7M, go 5.6M) subtracted, because dyld and runtime init differ per language and are a fifth of C's `allocflat` row. Every other table is raw.
> Reproducibility was measured rather than assumed (#4040): four independent regenerations of this table on this box held every ratio to 2.5% between adjacent runs and 8.5% at worst across all four. The loose rows are `alloc`, `map`, `allocflat` and `strings`, whose Go or C side is short enough that that language's own allocator and collector scheduling moves it by several percent from run to run; `matrix`, `mandelbrot`, `fib` and `sort` reproduce to about 1%. On those four loose rows, read a change under ~3% as noise.
> Instructions are published beside cycles because a cycle gap alone does not say whether it is work emitted or work stalled, and the two ratios differ a lot here: Bit retires roughly 4-7 instructions per cycle against C's 1.4-1.8, so its instruction ratio always overstates its cycle ratio. Cycles are the time; instructions are the reason.
> Generated by `bench/run.sh` on 2026-08-31T14:16:28Z — do not edit by hand.
<!-- BENCH:END -->

## License

[Apache-2.0](LICENSE). Apache-2.0 grants no trademark rights, so a modified
compiler gets a different name - see [TRADEMARK.md](TRADEMARK.md) for the naming
policy, and [CONTRIBUTING.md](CONTRIBUTING.md) before sending a change.

Security reports go through [SECURITY.md](SECURITY.md), never a public issue.
