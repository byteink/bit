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
- **A hang is a failure, not a stall (#1637).** Every subprocess the golden (`tests/harness.zig`) and stress (`tests/stress.zig`) harnesses spawn — both compilers' builds and every executed binary — carries a wall-clock deadline from `tests/proc.zig`. Exceeding it kills that child (its own PID, never a name pattern), reports `TIMED OUT` naming the case, and reddens the suite. Default 300s, ~6x the corpus's measured worst case (`tests/stress/quicwire` under `BIT_GC=stress`, 48.6s at load 14); override with `BIT_TEST_TIMEOUT_S=<seconds>` on a slower host, or `0` to disable and block forever as before. A timeout is a distinct outcome from a crash: a child killed by SIGSEGV/SIGBUS/SIGABRT is still reported as a crash naming the signal.

## File Size

Hard limit 800 lines per file, target ~500. 800 is the default of the repo's own lint rule E0200 max-file-lines (#1382) — the two must stay in step; changing one means changing the other. Split by moving top-level blocks into SIBLING `.bit` files in the same directory: siblings are the same module, so a split needs no imports, no namespace changes, and no call-site edits. Do not split into subdirectories — a new directory is a new module, which is a design change, not a cleanup.

Two things a split can break that a green build will not catch (#1503):

- **Silent line loss.** A split that swallows blank lines still compiles, passes selfcheck, and passes `zig build test`. Gate it with a line-multiset comparison of the directory before vs after — zero deletions, additions only for new file headers. Derive the "before" side from `git show HEAD:<path>`; a baseline written to a shared path can be clobbered by a concurrent agent, and a locale mismatch between the two sorts fabricates thousands of phantom deletions. Stronger still, and preferred: reassembling the new files in the original order must reproduce the original byte-for-byte.
- **Changed codegen (#1511).** Module files concatenate in bytewise sorted filename order, and the inliner only inlines a callee it has already lowered. A new sibling that sorts *before* the file holding its helpers silently loses inlining — perfect text diff, different machine code. Name new files so they sort after their helpers (for `sock.bit` the working order was `sock < tcp < udp`), and confirm with `bit build <src> --emit-obj` byte-identical before vs after.

Splitting a file can also make a test vacuous rather than failing it: any gate that names a single source path (`build.zig`'s `ast_tags` options did) will keep scanning the remnant. Point such gates at a directory.

## Deployment Context

Website deploys to the byteink k3s cluster (`kubectx byteink`, namespace `byteink`, Traefik IngressRoutes — see workspace-root CLAUDE.md). Releases ship from GitHub Actions on version tags: 6 target artifacts (linux/macos/windows × x64/arm64) + brew tap `byteink/homebrew-bit` + curl|sh installer + winget.
