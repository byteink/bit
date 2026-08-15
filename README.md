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
the PE/COFF object writer exists, but the CLI target and the Windows runtime port
do not, so no Windows artifact is built.

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
| `tests/`    | Golden-file and stress tests                        |

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

### Runtime — median wall-clock, lower is better

| Benchmark | Bit | Go | C | Bit / C |
|---|--:|--:|--:|--:|
| fib | 0.290s | 0.220s | 0.140s | 2.07x |
| mandelbrot | 1.190s | 0.390s | 0.360s | 3.31x |
| collatz | 0.350s | 0.140s | 0.090s | 3.89x |
| alloc | 1.360s | 0.070s | 0.130s | 10.46x |
| strings | 2.340s | 0.050s | 0.020s | 117.00x |
| map | 0.450s | 0.080s | 0.040s | 11.25x |
| sort | 0.950s | 0.080s | 0.060s | 15.83x |
| matrix | 9.800s | 0.220s | 0.090s | 108.89x |
| json | 6.170s | 0.100s | 0.050s | 123.40x |

### Peak memory — max RSS, lower is better

| Benchmark | Bit | Go | C |
|---|--:|--:|--:|
| fib | 1.8 MB | 4.0 MB | 1.4 MB |
| mandelbrot | 1.8 MB | 4.1 MB | 1.4 MB |
| collatz | 1.8 MB | 4.1 MB | 1.4 MB |
| alloc | 10.2 MB | 10.3 MB | 1.5 MB |
| strings | 952.2 MB | 83.8 MB | 30.7 MB |
| map | 54.0 MB | 41.5 MB | 193.4 MB |
| sort | 46.0 MB | 14.6 MB | 11.0 MB |
| matrix | 32.0 MB | 10.9 MB | 7.5 MB |
| json | 1131.8 MB | 56.8 MB | 125.2 MB |

### Binary size — static, as emitted

| Benchmark | Bit | Go | C |
|---|--:|--:|--:|
| fib | 147 KB | 2450 KB | 33 KB |
| mandelbrot | 147 KB | 2450 KB | 33 KB |
| collatz | 147 KB | 2450 KB | 33 KB |
| alloc | 163 KB | 2450 KB | 33 KB |
| strings | 179 KB | 2450 KB | 33 KB |
| map | 196 KB | 2451 KB | 33 KB |
| sort | 180 KB | 2468 KB | 33 KB |
| matrix | 179 KB | 2450 KB | 33 KB |
| json | 277 KB | 3002 KB | 33 KB |

### Startup & compile

| Metric | Bit | Go | C |
|---|--:|--:|--:|
| Process startup (per exec) | 4.521 ms | 3.881 ms | 3.367 ms |

Bit compile speed: **400 lines/sec** (460 lines across 9 cases, warm).

> Machine: Apple M5 Max, macOS 26.6.1. Bit @ `686876ad`, Go go1.26.5, Apple clang version 21.0.0 (clang-2100.1.1.101).
> Method: median of 7 runs. C built `cc -O2 -ffp-contract=off`, Go `go build`, Bit `bit build` — each language's standard optimized build.
> Mandelbrot: Bit and C agree to the last bit; Go differs by ~0.0002% because it contracts `a*b+c` to a hardware FMA. Not a bug — cross-compiler float bit-identity is not guaranteed.
> Generated by `bench/run.sh` on 2026-08-15T07:58:15Z — do not edit by hand.
<!-- BENCH:END -->

## License

[Apache-2.0](LICENSE). Apache-2.0 grants no trademark rights, so a modified
compiler gets a different name - see [TRADEMARK.md](TRADEMARK.md) for the naming
policy, and [CONTRIBUTING.md](CONTRIBUTING.md) before sending a change.

Security reports go through [SECURITY.md](SECURITY.md), never a public issue.
