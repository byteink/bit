# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

**Bit** — a systems programming language under the byteink brand. TypeScript-flavored syntax, Go-like semantics, compiled to static native binaries with zero runtime dependency. Greenfield: the plan is complete, implementation has not started. All work is tracked as smash tasks (#320–#366); `smash.json` in this directory is the project config.

## Non-Negotiable Design Decisions

Settled in planning — do not relitigate:

- **Syntax**: TypeScript-flavored (`let`/`const`, `function`, arrows, `interface`, `<>` generics, optional semicolons). "Easy to write" is the #1 design goal.
- **Semantics**: Go-like — garbage collected, green threads (`spawn`), typed channels, structural interfaces.
- **Output**: single static native binary, like Go/Zig. No interpreter, no VM, no libc dependency.
- **Zero external toolchain**: own lexer→parser→checker→SSA IR→codegen (x86-64 + ARM64)→object writers (ELF/Mach-O/PE)→own static linker. No LLVM, no system assembler/linker.
- **Seed compiler in Zig**, then self-host in three staged ports (differential-tested, stage2 == stage3 byte-identical). Zig seed retires to `seed/` after bootstrap.
- **Naming**: language "Bit", binary `bit`, extension `.bit`, LSP `bit lsp`, site bit-lang.byteink.com. Working name — renamable by find-replace, don't bikeshed it.

## Workflow

Task management via the smash MCP (`smash_whois` → `smash_list` → claim work). Tasks are ordered by hard dependencies; #320 (spec) and #321 (Zig scaffold) are the roots. Every task's details include verification criteria — a task isn't done until its verify section passes.

The spec (`spec/SPEC.md`, task #320) is the single source of truth for syntax/semantics. Compiler, docs, TextMate grammar, and tests all derive from it. Spec changes discovered during implementation flow back into SPEC.md in the same change.

The compiler↔runtime contract lives in `runtime/ABI.md` (object headers, stack maps, safepoints, spawn/chan signatures). Codegen and runtime both implement it; change it only by updating the doc first.

## Commands

Nothing is scaffolded yet. Once #321 lands, the intended commands are:

```
zig build              # build seed compiler bit
zig build test         # unit + golden tests
zig build fuzz         # fuzzing harness (after #334)
```

Zig version is pinned in `.zigversion` — verify current stable before scaffolding, don't trust memory.

## Planned Layout

```
compiler/   Zig seed compiler (lexer, parser, check, ir, codegen/, obj/, link)
runtime/    Zig runtime linked into user binaries (alloc, gc, sched, chan) + ABI.md
stdlib/     written in Bit (core, io, fs, net, time, math, os, testing)
spec/       SPEC.md — the authority
tests/      golden cases (tests/cases/*.bit + .expected), stress/, fuzz/
editors/    vscode extension (grammar + LSP client)
docs/       reference/, tutorial.md, stdlib/
website/    static site → k3s byteink namespace
selfhost/   Bit-in-Bit compiler (stages 1–3)
dist/       packaging (brew formula, install scripts)
```

## Testing Conventions

- Golden-file tests: `tests/cases/*.bit` with sibling `.expected`; line-1 directive selects the mode — `// run` (execute, compare stdout), `// panic` (must exit 2, compare stderr), `// error` (expect diagnostics), `// fmt` (canonicalization), `// types` (inferred-type dump). Every compiler stage adds cases as it lands.
- Differential testing is the self-hosting gate: Zig and Bit implementations must produce byte-identical AST/type/IR dumps over the full corpus.
- Doc snippets are CI-verified — tutorial and stdlib docs compile as part of the build; docs that don't compile fail CI.

## Deployment Context

Website deploys to the byteink k3s cluster (`kubectx byteink`, namespace `byteink`, Traefik IngressRoutes — see workspace-root CLAUDE.md). Releases ship from GitHub Actions on version tags: 6 target artifacts (linux/macos/windows × x64/arm64) + brew tap `byteink/homebrew-bit` + curl|sh installer + winget.
