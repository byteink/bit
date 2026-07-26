# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

**Bit** - a systems programming language under the byteink brand. TypeScript-flavored syntax, Go-like semantics, compiled to static native binaries with zero runtime dependency. Greenfield: the plan is complete, implementation has not started. All work is tracked as smash tasks (#320–#366); `smash.json` in this directory is the project config.

## Non-Negotiable Design Decisions

Settled in planning - do not relitigate:

- **Syntax**: TypeScript-flavored (`let`/`const`, `function`, arrows, `interface`, `<>` generics, optional semicolons). "Easy to write" is the #1 design goal.
- **Semantics**: Go-like - garbage collected, green threads (`spawn`), typed channels, structural interfaces.
- **Output**: single static native binary, like Go/Zig. No interpreter, no VM, no libc dependency.
- **Zero external toolchain**: own lexer→parser→checker→SSA IR→codegen (x86-64 + ARM64)→object writers (ELF/Mach-O/PE)→own static linker. No LLVM, no system assembler/linker.
- **Seed compiler in Zig**, then self-host in three staged ports (differential-tested, stage2 == stage3 byte-identical). Zig seed retires to `seed/` after bootstrap.
- **Naming**: language "Bit", binary `bit`, extension `.bit`, LSP `bit lsp`, site **bitlang.org** (settled 2026-07-26 - `.org` is the convention for open-source languages, and byteink.io stays the company site; bitlang.io/.net redirect to it). The language name itself is still renamable by find-replace - don't bikeshed it.

## Workflow

Task management via the smash MCP (`smash_whois` → `smash_list` → claim work). Tasks are ordered by hard dependencies; #320 (spec) and #321 (Zig scaffold) are the roots. Every task's details include verification criteria - a task isn't done until its verify section passes.

The spec (`spec/SPEC.md`, task #320) is the single source of truth for syntax/semantics. Compiler, docs, TextMate grammar, and tests all derive from it. Spec changes discovered during implementation flow back into SPEC.md in the same change.

The compiler↔runtime contract lives in `runtime/ABI.md` (object headers, stack maps, safepoints, spawn/chan signatures). Codegen and runtime both implement it; change it only by updating the doc first.

## Commands

Nothing is scaffolded yet. Once #321 lands, the intended commands are:

```
zig build              # build seed compiler bit
zig build test         # unit + golden tests
zig build fuzz         # fuzzing harness (after #334)
```

Zig version is pinned in `.zigversion` - verify current stable before scaffolding, don't trust memory.

## Planned Layout

```
compiler/   Zig seed compiler (lexer, parser, check, ir, codegen/, obj/, link)
runtime/    Zig runtime linked into user binaries (alloc, gc, sched, chan) + ABI.md
stdlib/     written in Bit (core, io, fs, net, time, math, os, testing)
spec/       SPEC.md - the authority
tests/      golden cases (tests/cases/*.bit + .expected), stress/, fuzz/
editors/    vscode extension (grammar + LSP client)
docs/       reference/, tutorial.md, stdlib/
website/    static site → k3s byteink namespace
selfhost/   Bit-in-Bit compiler (stages 1–3)
dist/       packaging (brew formula, install scripts)
```

## Testing Conventions

- **Verify scoped changes with `scripts/gate.sh`, not the full suite (#1770).** It reads your `git diff` and runs only the steps that change touches - a `selfhost/**` edit runs the selfhost diffs + `test-imports`, a `tests/cases/**` edit runs `zig build test-golden`, etc. Run the full `zig build test` (all 28 harnesses, ~7 min) only for a cross-cutting change (build.zig, seed/, spec/), a mixed change set, or the final pre-merge gate - and `gate.sh` already falls back to it automatically in those cases. Every harness also has its own named step (`zig build test-golden|test-examples|test-gcdiff|test-version|test-selfcheck|…`) for running one area directly. The `libbitrt.a`/selfhost `bit` rebuild is now source-fingerprint cache-gated, so an unchanged tree skips the ~23s recompile automatically on every `zig build`.
- Golden-file tests: `tests/cases/*.bit` with sibling `.expected`; line-1 directive selects the mode - `// run` (execute, compare stdout), `// panic` (must exit 2, compare stderr), `// error` (expect diagnostics), `// fmt` (canonicalization), `// types` (inferred-type dump). Every compiler stage adds cases as it lands.
- Differential testing is the self-hosting gate: Zig and Bit implementations must produce byte-identical AST/type/IR dumps over the full corpus.
- Doc snippets are CI-verified - tutorial and stdlib docs compile as part of the build; docs that don't compile fail CI.
- **A hang is a failure, not a stall (#1637, #1652).** Every subprocess a harness spawns carries a wall-clock deadline from `tests/proc.zig` - the golden (`tests/harness.zig`), stress (`tests/stress.zig`), examples (`tests/examples.zig`), imports (`tests/imports.zig`) and orphaned-test (`tests/testroots.zig`) harnesses, covering both compilers' builds and every executed binary. (`tests/gcdiff.zig` spawns nothing; it runs the Zig collector in-process.) Exceeding it kills that child (its own PID, never a name pattern), reports `TIMED OUT` naming the case, and reddens the suite. Default 300s, ~6x the corpus's measured worst case (`tests/stress/quicwire` under `BIT_GC=stress`, 48.6s at load 14); override with `BIT_TEST_TIMEOUT_S=<seconds>` on a slower host, or `0` to disable and block forever as before. A timeout is a distinct outcome from a crash: a child killed by SIGSEGV/SIGBUS/SIGABRT is still reported as a crash naming the signal.

## File Size

Hard limit 800 lines per file, target ~500. 800 is the default of the repo's own lint rule E0200 max-file-lines (#1382) - the two must stay in step; changing one means changing the other. Split by moving top-level blocks into SIBLING `.bit` files in the same directory: siblings are the same module, so a split needs no imports, no namespace changes, and no call-site edits. Do not split into subdirectories - a new directory is a new module, which is a design change, not a cleanup.

Two things a split can break that a green build will not catch (#1503):

- **Silent line loss.** A split that swallows blank lines still compiles, passes selfcheck, and passes `zig build test`. Gate it with a line-multiset comparison of the directory before vs after - zero deletions, additions only for new file headers. Derive the "before" side from `git show HEAD:<path>`; a baseline written to a shared path can be clobbered by a concurrent agent, and a locale mismatch between the two sorts fabricates thousands of phantom deletions. Stronger still, and preferred: reassembling the new files in the original order must reproduce the original byte-for-byte.
- **Changed codegen (#1511).** Module files concatenate in bytewise sorted filename order, and the inliner only inlines a callee it has already lowered. A new sibling that sorts *before* the file holding its helpers silently loses inlining - perfect text diff, different machine code. Name new files so they sort after their helpers (for `sock.bit` the working order was `sock < tcp < udp`), and confirm with `bit build <src> --emit-obj` byte-identical before vs after.

Splitting a file can also make a test vacuous rather than failing it: any gate that names a single source path (`build.zig`'s `ast_tags` options did) will keep scanning the remnant. Point such gates at a directory.

## Website (bitlang.org)

The site is generated by **`website/gen`** and served by **`website/server`**, both
Bit programs. `website/Dockerfile` is `FROM scratch`: one cross-compiled static
binary plus the generated HTML, no distro, no libc, no shell. nginx is gone.

**`website/server` is TEMPORARY and must not grow.** It is a few dozen lines that
answer GET for a directory. The real static server and the web framework are
separate, planned pieces of work, and both will replace it. Adding routing,
templating, compression, caching or middleware to `website/server` turns it into a
framework nobody designed - if you need any of that, that is the signal to build
the real thing, not to extend this.

**Two copies of the serving logic exist on purpose, and drift is the risk.**
`website/server/serve.bit` and `examples/staticserver/staticserver.bit` hold the
same `fileResponse`/`safePath`/`mimeFor`. The website deliberately does not build
out of `examples/` - an example is a showcase, not a production dependency - but
only the example is gated: the examples harness compiles and runs it, including a
mutation-tested path-traversal check. So a fix in `website/server` that is not
mirrored into the example is a fix with no test, and the traversal guard is where
that bites. **Change one, change both**, until the real server retires both.

The generator reads `docs/` and never writes it, so the doc gates
(`tests/docs.zig` typechecks every ```bit block, `tests/stdlib_docs.zig` fails on
an undocumented export) keep covering the content the site publishes. Get started
IS `docs/tutorial.md`, not a copy.

Deploys go through **ssd** like every other byteink app. `.ssd/` is gitignored
(machine-local); `website/ssd.yaml.example` is the committed reference.
`website/deploy.sh` fetches the advisory feed, regenerates the pages, then hands
over to `ssd deploy website`, which builds the image on the server from committed
source.

## No GitHub Actions

**This project does not use GitHub Actions, and is not planning to.** There is no
`.github/workflows/` directory; it was deleted deliberately, not lost. Do not add
one, and do not "fix" a missing CI badge by wiring a workflow back up.

Verification happens on the machines that can actually prove things:

- `scripts/gate.sh` reads your diff and runs only the steps it can affect,
  falling back to the full `zig build test` (28 harnesses) when the change is
  cross-cutting.
- `scripts/arm64gate.sh` and `scripts/x64gate.sh` run the suite on real
  aarch64-linux and real x86-64 Linux. The x86-64 host is resolved by
  `scripts/x64host.sh` from a machine-local list, never hardcoded — an emulated
  x86-64 pass is not a pass (a red-zone scheduler bug was only settled on real
  hardware).
- `dist/release.sh <version>` cuts a release: builds all three targets, smoke-
  tests each UNPACKED artifact by compiling and running a program on hardware
  that matches it, writes SHA256SUMS, renders notes from conventional commits,
  and creates a DRAFT release. `--dry-run` builds and verifies without
  publishing.

Why: Actions minutes are billed to the owner, and every check worth running needs
either the real x86-64 box or a container image that already exists here. A hosted
runner adds cost and a second, weaker definition of "green".

## Deployment Context

Releases are cut LOCALLY with `dist/release.sh <version>` (see "No GitHub Actions" above). **3** target artifacts - `x86_64-linux`, `aarch64-linux`, `aarch64-macos` - plus a Homebrew tap (`brew install byteink/tap/bit`, published by `dist/brew/publish.sh`) and a `curl | sh` installer served from the site. There is NO Windows build and no winget submission: the PE/COFF writer landed but the CLI target and the Windows runtime port did not. Website deployment specifics (cluster, namespace, ingress) are operational detail kept out of this public repo.
