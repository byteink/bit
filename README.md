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
The table below compares it with Go (also garbage-collected) and C (`-O2`) on
twelve small programs. Reproduce with `bench/run.sh`; sources live in
`bench/cases/`.

<!-- BENCH:START -->
Bit is faster than Go on 3 of 12 benchmarks, about the same on 0 and slower on 9 (up to 2.1x slower); against C it is faster on 0, about the same on 1 and slower on 11 (up to 9.5x slower).

| Benchmark | What it tests | vs Go | vs C |
|---|---|--:|--:|
| strings | building and slicing strings | 1.8x faster | 2.0x slower |
| map | hash map with number keys | 1.3x faster | 2.0x slower |
| sort | sorting numbers and strings | 1.3x faster | about the same |
| fib | function calls | 1.1x slower | 1.6x slower |
| mandelbrot | floating point math | 1.3x slower | 1.3x slower |
| allocflat | many objects in one buffer | 1.3x slower | 9.5x slower |
| matrix | matrix multiplication | 1.4x slower | 3.5x slower |
| collatz | integer loops and branches | 1.5x slower | 2.2x slower |
| alloc | many small heap objects | 1.6x slower | 1.4x slower |
| allocpar | heap objects on 8 threads | 1.7x slower | 1.2x slower |
| strmap | hash map with string keys | 1.8x slower | 4.5x slower |
| json | JSON parse and walk | 2.1x slower | 3.3x slower |

Memory: Bit uses less than Go on 9 of 12 benchmarks. A typical run takes 9.5 MB in Bit, 13.3 MB in Go and 5.8 MB in C.

Program size: about 381 KB in Bit, 2.3 MB in Go and 33 KB in C.

Measured on Apple M5 Max, macOS 27.0.1, on 2026-10-09.

Full numbers and method: [bench/RESULTS.md](bench/RESULTS.md)
<!-- BENCH:END -->

## License

Bit is licensed under the [Apache License 2.0](LICENSE).

See [CONTRIBUTING.md](CONTRIBUTING.md) for contribution guidelines,
[SECURITY.md](SECURITY.md) for reporting vulnerabilities, and
[TRADEMARK.md](TRADEMARK.md) for trademark guidelines.
