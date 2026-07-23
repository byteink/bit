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
  bit                 seed compiler — compiler/*.zig, ~34k lines of Zig
      │  builds  selfhost/*.bit
      ▼
  bit2 = stage1       the Bit compiler, built by the seed
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
whole test corpus. The dumps are the canonical `bit --dump-*` surfaces, diffed
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
zig build               # native: builds the seed (bit-seed) AND the self-hosted bit
./zig-out/bin/bit       # the canonical self-hosted compiler
./zig-out/bin/bit-seed  # the bootstrap seed (differential oracle; retired to seed/)
```

The seed compiler now lives in `seed/` and installs as `bit-seed`; the canonical
`bit` is the self-hosted compiler built from `selfhost/`. A native `zig build`
produces both; a cross build (`-Dtarget=`) produces only `bit-seed` (execing the
seed to build the self-hosted bit needs a native host).

## Current state

**Stage 1 — front-end, COMPLETE (#363).** The lexer, AST arena, parser, and
diagnostic renderer are ported (`selfhost/{lexer,ast,parser,diagnostics}.bit`);
`bit2` drives them via `--dump-tokens`, `--dump-ast`, and `--dump-diags`.
Against the seed over the whole corpus:

| Surface | Script | Result |
|---------|--------|--------|
| tokens | `scripts/selfhost-difftokens.sh` | MATCH=515 MISMATCH=0 (14 lex-error skips) |
| AST | `scripts/selfhost-diffast.sh` | MATCH=506 MISMATCH=0 (23 parse-error skips) |
| diagnostics | `scripts/selfhost-diffdiags.sh` | MATCH=529 MISMATCH=0 (incl. every `// error` case) |

Robustness + accept/reject parity are proven by `scripts/selfhost-fuzzdiff.sh`
(the #1332 harness), which truncates every corpus file at each line boundary
and diffs `--dump-diags`: **MATCH=7526 MISMATCH=0 CRASH=0 TIMEOUT=0** — every
malformed input is rejected identically by both compilers, including the
multi-error cascade-ordering cases that used to diverge before #1332 landed.
Zero diffs across all four surfaces; gate #363 is signed off.

**Stage 2 — middle-end, COMPLETE.** `selfhost/{resolve,types,check,ir,lower,
opt}.bit` port the resolve substrate, type checker, SSA IR model + text dumper,
AST→IR lowering, and the optimizer. Against the seed over the whole corpus:

| Surface | Script | Result |
|---------|--------|--------|
| types | `scripts/selfhost-difftypes.sh` | **125/125** byte-identical (202 check-error skips) |
| IR (pre-opt) | `scripts/selfhost-diffir.sh` | **121/122** (205 lower/check-err skips) |
| IR (post-opt) | `scripts/selfhost-diffiropt.sh` | **121/122** |

Inference covers literals + defaulting, idents/params/receivers, unary/binary
merge, calls (free + generic substitution + runtime-primitive builtins),
composites, index/slice/member, struct fields, enum variants (incl. turbofish),
interface + type-parameter method dispatch, arrow-fn and uncalled method values,
comma-ok (`<-ch` / `m[k]` / `x.(T)`), try/catch unwrap, the `error` interface,
for-of binders, and transparent type aliases. Lowering covers every construct:
control flow (if/while/for-c/for-of/switch/match/select), enums (C-like, boxed
payload, generic), the fallible error channel, generics (monomorphized per
instantiation), closures (arrows + capture, spawn, first-class and interface
method values), comma-ok, arrays, maps, channels, floats/runes, and `show()`
interpolation. Type ids are assigned in the seed's lazy touch order (declTypeOf
first-touch + composite dedup), which method mangling `name$t{recvId}` depends on.
The optimizer mirrors `-O1` — fold, DCE, inline, fold, DCE — rebuilding each
function rather than mutating it.

The **1** remaining mismatch in both IR surfaces (`run_generic_nested`) is generic
type substitution reaching lowering: the seed prints `field_get %28[8] i64` where
the self-hosted compiler still prints `field_get %28[8] <T>`. Its function bodies,
result types, and every type already match.

That case used to carry a second, independent defect — instance *index numbering*
(`wrap$7` vs `wrap$0`) — fixed in #1530. The seed's `ctx.instantiations` is one
global ledger holding generic **type** instantiations alongside function ones, so
the printed suffix was sparse while the seed's own FuncIds for those instances were
already dense: the symbol text disagreed with the id it named. Naming from the
dense counter the seed already computes made both compilers converge without
building type monomorphization in the port.

Stage 3 (codegen + object writers + linker + driver, then `stage2 == stage3`)
follows.

The seed's differential dump modes (`--dump-tokens/-ast/-types/-ir/-diags`) are
the substrate every stage diffs against.
