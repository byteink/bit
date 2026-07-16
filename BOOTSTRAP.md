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

**Stage 1 — front-end, valid-input parity complete.** The lexer, AST arena,
parser, and diagnostic renderer are ported (`selfhost/{lexer,ast,parser,
diagnostics}.bit`); `bitc2` drives them via `--dump-tokens`, `--dump-ast`, and
`--dump-diags`. Against the seed over the whole corpus:

| Surface | Script | Result |
|---------|--------|--------|
| tokens | `scripts/selfhost-difftokens.sh` | 326/0 byte-identical (1 lex-error skip) |
| AST | `scripts/selfhost-diffast.sh` | 325/0 byte-identical (2 front-end-error skips) |
| diagnostics | `scripts/selfhost-diffdiags.sh` | 327/0 byte-identical (incl. the 2 `// error` cases) |

Robustness + accept/reject parity are proven by `scripts/selfhost-fuzzdiff.sh`,
which truncates every corpus file at each line and diffs `--dump-diags`: over
5065 mutated inputs, **0 crashes/hangs** and **0 accept/reject disagreements**
(every malformed input is rejected by both compilers). The remaining ~236 are
byte-exact multi-error *cascade ordering* on truncated garbage — cosmetic
diagnostic ordering that valid compiler source never reaches. Closing those to
zero is bounded by the formal fuzz harness (#1332, not yet built; the fuzz crash
corpus is empty), so it is deferred with that task rather than ground out blind.

**Stage 2 — middle-end, type inference near-parity.** `selfhost/{resolve,types,
check}.bit` port the resolve substrate + the type checker; `bitc2 --dump-types`
diffs against the seed over the corpus:

| Surface | Script | Result |
|---------|--------|--------|
| types | `scripts/selfhost-difftypes.sh` | 124/125 (202 check-error skips) |

Inference covers literals + defaulting, idents/params/receivers, unary/binary
merge, calls (free + generic-param substitution + runtime-primitive builtins),
composites, index/slice/member, struct fields, enum variants (incl. turbofish),
interface + type-parameter method dispatch, arrow-fn and uncalled method values,
comma-ok (`<-ch` / `m[k]` / `x.(T)`), try/catch unwrap, the `error` interface,
for-of binders, and transparent type aliases. The **1** remaining mismatch
(`run_generic_nested`) needs generic type-*argument* tracking through instances
(`Pair<i64>` → substitute `T`=i64), which the checker currently discards
(instances render by bare name) — a substantive feature deferred to its own
change.

**Stage 2 — lowering, started.** `selfhost/{ir,lower}.bit` port the SSA IR
model + text dumper (`ir.zig`) and AST→IR lowering (`lower.zig`), behind
`bitc2 --dump-ir`, diffed by `scripts/selfhost-diffir.sh`:

| Surface | Script | Result |
|---------|--------|--------|
| IR | `scripts/selfhost-diffir.sh` | 1/122 (205 lower/check-err skips) |

Function signatures (params incl. method receiver, fallible-ok result) and
`return [expr]` bodies over literals / idents / `(+,-,*)` lower byte-for-byte; a
per-function fallback to a signature-only stub keeps partial IR from leaking as
the frontier grows (const folding, strings/interp, `print`/`rt_call`, bindings,
control flow, calls). Stage 3 (codegen/link, then `stage2 == stage3`) follows.

The seed's differential dump modes (`--dump-tokens/-ast/-types/-ir/-diags`) are
the substrate every stage diffs against.
