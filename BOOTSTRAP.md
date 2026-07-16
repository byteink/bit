# Bootstrap

How Bit becomes self-hosted: the compiler is written in Zig (the *seed*), then
re-written in Bit under [`selfhost/`](selfhost/) and proven correct by compiling
itself to a fixed point. This document is the map; the work is tracked as the
self-host epic (#363–#365).

## The chain

```
  zig build            (Zig toolchain)
      │  builds
      ▼
  bitc                 seed compiler — compiler/*.zig, ~34k lines of Zig
      │  builds  selfhost/*.bit
      ▼
  bitc2 = stage1       the Bit compiler, built by the seed
      │  builds  selfhost/*.bit  (itself)
      ▼
  stage2               the Bit compiler, built by the Bit compiler
      │  builds  selfhost/*.bit  (itself again)
      ▼
  stage3
```

**The proof:** `stage2 == stage3`, byte-for-byte (after stripping timestamps).
A compiler that reproduces itself exactly when it compiles its own source is a
fixed point — it has no dependency on the seed's code generation, only on the
language. That is what "self-hosted" means.

The seed (`compiler/`) is then retired to `seed/`, kept only so the chain can be
rebuilt from nothing. The **runtime** (`runtime/*.zig`) stays Zig — it is linked
into every user binary via the ABI ([`runtime/ABI.md`](runtime/ABI.md)); only
the *compiler* is ported.

## Stages and their gates

Each stage ports one third of the pipeline and is signed off by a differential
gate: the Zig and Bit compilers must produce **byte-identical** dumps over the
whole test corpus. The dumps are the canonical `bitc --dump-*` surfaces, diffed
by the harness (#1332).

| Stage | Ports | Gate (#) | Differential surface |
|-------|-------|----------|----------------------|
| 1 | lexer + parser + AST + diagnostics | #363 | `--dump-tokens`, `--dump-ast`, `// error` diagnostics |
| 2 | resolve + check + lower + optimize | #364 | `--dump-types`, `--dump-ir` (pre- and post-opt) |
| 3 | codegen + object writers + linker + driver | #365 | linked-binary bytes; then `stage2 == stage3` |

No stage starts until the previous gate is green. Stage 3 ends with the
fixed-point proof, the seed's retirement, and CI switching its primary build to
the self-hosted compiler.

## Building

```
zig build libbitrt     # the runtime archive the linker consumes (once)
zig build selfhost     # seed bitc builds selfhost/ → zig-out/bin/bitc2
./zig-out/bin/bitc2     # run it
```

## Current state

**Stage 1 — front-end, in progress.** The lexer, AST arena, parser, and the
diagnostic renderer are ported (`selfhost/{lexer,ast,parser,diagnostics}.bit`)
and `bitc2` drives them via `--dump-tokens`, `--dump-ast`, and `--dump-diags`.
Against the seed over the whole corpus:

| Surface | Script | Result |
|---------|--------|--------|
| tokens | `scripts/selfhost-difftokens.sh` | 326/0 byte-identical (1 lex-error skip) |
| AST | `scripts/selfhost-diffast.sh` | 325/0 byte-identical (2 front-end-error skips) |
| diagnostics | `scripts/selfhost-diffdiags.sh` | 327/0 byte-identical (incl. the 2 `// error` cases) |

Front-end `// error` parity holds for the corpus: E0001 (stray byte) and E0021
(expected token) render byte-for-byte. **Remaining for the #363 gate:** fuzz
accept/reject + codes/spans parity, which needs the formal differential harness
(#1332) as its verification surface, and with it the lexer's E0002–E0006 and the
parser's general `expect`-site diagnostics (with a speculation guard). Those are
emitted against that harness rather than blind.

The seed's differential dump modes (`--dump-tokens/-ast/-types/-ir/-diags`) are
the substrate every stage diffs against. Stage 2 (resolve/check/lower/opt) and
Stage 3 (codegen/link) land per the epic, each filling in a `selfhost/` module
and turning its gate green.
