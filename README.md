# Bit

Bit is a systems programming language with TypeScript-flavored syntax and
Go-like semantics. You write `let`/`const`, `function`, arrows, `interface`,
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

- [Zig](https://ziglang.org/) `0.16.0` (pinned in [`.zigversion`](.zigversion))

Zig builds the bootstrap seed, which builds the Bit-written compiler - the usual
chicken-and-egg every self-hosted language has. It is not needed to use Bit.

```
zig build          # build the compiler into zig-out/bin
zig build test     # run the full suite (28 harnesses)
scripts/gate.sh    # run only what your diff can affect
```

## Layout

| Path        | Purpose                                             |
|-------------|-----------------------------------------------------|
| `compiler/` | Zig seed compiler (`bit`)                           |
| `runtime/`  | Zig runtime linked into user binaries               |
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

### Runtime - median wall-clock, lower is better

| Benchmark | Bit | Go | C | Bit / C |
|---|--:|--:|--:|--:|
| fib | 0.280s | 0.210s | 0.140s | 2.00x |
| mandelbrot | 0.780s | 0.360s | 0.350s | 2.23x |
| collatz | 0.430s | 0.130s | 0.090s | 4.78x |
| alloc | 0.420s | 0.070s | 0.120s | 3.50x |

### Peak memory - max RSS, lower is better

| Benchmark | Bit | Go | C |
|---|--:|--:|--:|
| fib | 1.6 MB | 4.0 MB | 1.4 MB |
| mandelbrot | 1.6 MB | 4.1 MB | 1.4 MB |
| collatz | 1.6 MB | 4.1 MB | 1.4 MB |
| alloc | 8.6 MB | 10.6 MB | 1.6 MB |

### Binary size - static, as emitted

| Benchmark | Bit | Go | C |
|---|--:|--:|--:|
| fib | 118 KB | 2450 KB | 33 KB |
| mandelbrot | 119 KB | 2450 KB | 33 KB |
| collatz | 119 KB | 2450 KB | 33 KB |
| alloc | 119 KB | 2450 KB | 33 KB |

### Startup & compile

| Metric | Bit | Go | C |
|---|--:|--:|--:|
| Process startup (per exec) | 4.443 ms | 4.638 ms | 3.935 ms |

Bit compile speed: **1844 lines/sec** (96 lines across 4 cases, warm).

> Machine: Apple M5 Max, macOS 26.5.2. Bit @ `182f9c9`, Go go1.26.5, Apple clang version 21.0.0 (clang-2100.1.1.101).
> Method: median of 7 runs. C built `cc -O2 -ffp-contract=off`, Go `go build`, Bit `bit build` - each language's standard optimized build.
> Mandelbrot: Bit and C agree to the last bit; Go differs by ~0.0002% because it contracts `a*b+c` to a hardware FMA. Not a bug - cross-compiler float bit-identity is not guaranteed.
> Generated by `bench/run.sh` on 2026-07-16T04:19:50Z - do not edit by hand.
<!-- BENCH:END -->

## License

[Apache-2.0](LICENSE). The code is open; the **name** is not - Apache-2.0
grants no trademark rights, so a modified compiler needs a different name. See
[TRADEMARK.md](TRADEMARK.md), and [CONTRIBUTING.md](CONTRIBUTING.md) before
sending a change.

Security reports go through [SECURITY.md](SECURITY.md), never a public issue.
