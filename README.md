# Bit

[![CI](https://github.com/byteink/bit/actions/workflows/ci.yml/badge.svg)](https://github.com/byteink/bit/actions/workflows/ci.yml)

Bit is a systems programming language with TypeScript-flavored syntax and
Go-like semantics. You write `let`/`const`, `function`, arrows, `interface`,
and `<>` generics; you get garbage collection, green threads (`spawn`), typed
channels, and structural interfaces. Programs compile to a single static native
binary with zero runtime and zero external toolchain — the compiler owns every
stage from lexer to linker, so there is no LLVM, no system assembler, and no
libc dependency.

## Status

Pre-alpha. The design is settled; the seed compiler (`bitc`, written in Zig) is
being scaffolded and bootstrapped. Nothing is production-ready yet.

## Requirements

- [Zig](https://ziglang.org/) `0.16.0` (pinned in [`.zigversion`](.zigversion))

## Build

```
zig build          # build the seed compiler (bitc) into zig-out/bin
zig build run      # build and run bitc (prints its version)
zig build test     # run unit tests
```

## Layout

| Path        | Purpose                                             |
|-------------|-----------------------------------------------------|
| `compiler/` | Zig seed compiler (`bitc`)                           |
| `runtime/`  | Zig runtime linked into user binaries               |
| `stdlib/`   | Standard library, written in Bit                    |
| `spec/`     | Language specification (source of truth)            |
| `docs/`     | Reference and tutorial documentation                |
| `editors/`  | Editor support (VS Code extension, LSP client)      |
| `dist/`     | Packaging (brew formula, installers)                |
| `tests/`    | Golden-file and stress tests                        |

## License

[MIT](LICENSE)
