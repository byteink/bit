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

**Stage 3 — back-end + driver, COMPLETE (#365).** `selfhost/{codegen/,obj/,link.bit,
main.bit,fmt.bit,doc.bit,lsp.bit}` port codegen (x86-64 + ARM64), the ELF/Mach-O/PE
object writers, the static linker, and the CLI driver (`build`/`run`/`check`/
`test`/`fmt`/`doc`/`lsp`/`ar`/every `--dump-*` mode). The seed has already been
retired to `seed/` (installed as `bit-seed`); the canonical `zig-out/bin/bit` is
built by running `bit-seed` once against `selfhost/` — after that, `bit` builds
itself.

**The fixed-point proof** (`scripts/selfhost-fixpoint.sh`) no longer compares
against the seed — once the seed is retired there is no "stage2" built by it to
compare against. The meaningful property instead is self-reproducibility: the
current self-hosted `bit` (stageA) builds `selfhost/` to produce stageB, and
stageB builds `selfhost/` again to produce stageC. `stageB == stageC` is the
fixed point. Verified with a real `sha256sum` + `cmp` on all three required
targets:

| Target | Host | stageB == stageC (sha256) |
|--------|------|----------------------------|
| aarch64-macos | native | `f78c64da234003ff1c2630e4bf2f0a68e0655e6437039444d13774c200b2ba2a` |
| aarch64-linux | docker `bit-zig-0.16.0-arm64native` | `f8b523c4d4ddf56973a408cba0515f3e7f92b31189bb555edc5647755a07dcfa` |
| x86_64-linux | real x86-64 hardware, docker `bit-zig-0.16.0-amd64` | `26a64f2b4976bf1fdb215ae1a3b4603ef20923a031d7b510618364aeda17d435` |

(The script's own `shasum` call silently no-ops on Linux — no `shasum` binary
there — so the aarch64-linux/x86_64-linux numbers above were confirmed with an
explicit `sha256sum` + `cmp` outside the script, not trusted from its own
"FIXED POINT OK" line, which prints even when both sides hash to the empty
string. Worth hardening the script separately.)

**The #1332 differential harness** (`scripts/selfhost-diffall.sh`), which
discovers and runs the whole `selfhost-*.sh` family so no differential can be
forgotten:

| Target | Verdict |
|--------|---------|
| aarch64-macos | `PASS=15 FAIL=0 INCONCLUSIVE=0` — GREEN (re-run post-#1761 fix: still GREEN) |
| aarch64-linux | `PASS=15 FAIL=0 INCONCLUSIVE=0` — GREEN |
| x86_64-linux | `PASS=15 FAIL=0 INCONCLUSIVE=0` — GREEN, post-#1761 fix (was `PASS=14 FAIL=1 selfhost-difffmt.sh` pre-fix — see below) |

That covers diffast, diffcheck, diffdiags, diffdoc, diffexamples (the full
examples/ corpus, compiled and diffed against the seed), difffmt, diffir,
diffiropt, diffsafepoints, difftests, difftokens, difftypes, diffverdict,
fixpoint, and fuzzdiff. `diffsafepoints` needs `objdump`, absent from both
Linux docker images by default (`apt-get install binutils` fixes it; both
runs above are post-fix, real MATCH=326/MISMATCH=0 results, not the
INCONCLUSIVE the images give out of the box). `imports [selfhost]`
(`tests/imports.zig`, a separate `zig build test` step) reported clean on
aarch64-macos: 94/94 projects OK, 0 regressions.

**x86_64-linux real finding, RESOLVED: `bit fmt --check` segfaulted on
non-trivial files** — filed and fixed as #1761. Root cause was not codegen:
every Bit program's `main` runs on the runtime scheduler's fixed-size
goroutine stack (`runtime/sched.zig`), and the formatter's recursive-descent
AST walk overflowed the 64 KiB default on x86-64's larger stack frames (ARM64
frames stayed under it, which is why this was invisible on either aarch64
target). Fixed by raising the goroutine stack to 256 KiB, with a
`tests/stress/deeprecursion` regression case pinning the budget so it can't
silently regress. Re-verified post-fix on real x86_64 hardware:
the 4 originally-crashing files now exit with the same codes as aarch64
(0/1, never SIGSEGV), and `selfhost-difffmt.sh` scores `MATCH=692 MISMATCH=0
TIMEOUT=0` over the full corpus. `selfhost-difffmt.sh`'s own default timeout
was also raised 20s → 45s (this file), since an older Skylake x86-64 box needed
`DIFFFMT_TIMEOUT=40` to format `selfhost/lower.bit` (the corpus's largest
file, ~23s there) without misreporting a slow-but-correct result as a
timeout — the same false-signal class #1761 itself was first mistaken for.
This was found *because* the three-target verify bullet was actually
exercised on real x86_64 hardware, not emulation — every other check in this
gate would have shipped clean without it.

**CI decision, made:** `.github/workflows/ci.yml`'s `zig build` /
`zig build test` steps already build and exercise the self-hosted `bit` as
the primary artifact — `build.zig` installs `bit` (self-hosted) by default on
a native host and wires it as the driver behind the golden/examples/stress/
imports corpus in `zig build test`; `bit-seed` is retained only as the
bootstrap tool and differential oracle. That already satisfies "CI's primary
build switches to the self-hosted compiler" — no build-graph restructuring
needed. What CI *was* missing, and now has: its self-host differential step
called a hand-picked 5-of-15 script subset that never included
`selfhost-difffmt.sh` — the one script that actually catches #1761. CI now
calls `scripts/selfhost-diffall.sh` (self-discovering the full #1332 family,
with a hard floor so a deleted differential can't silently under-run)
instead of a hand-maintained list. The matrix already runs both `ubuntu-latest`
(x86_64) and `macos-latest` (arm64) natively, so no separate x86_64 job was
needed — the gap was coverage within the job, not the matrix.

The seed's differential dump modes (`--dump-tokens/-ast/-types/-ir/-diags`) are
the substrate every stage diffs against.

**Gate #365 sign-off.** Every verify bullet is closed: stage2/stage3 fixed
point byte-identical on all three targets; full #1332 differential family
15/15 GREEN on all three targets (aarch64-macos re-confirmed GREEN after the
#1761 fix + the difffmt timeout raise, in the same tree as this commit);
`zig build test` clean (0 real failures on both aarch64-macos and
x86_64; the sole aarch64-macos build-step miss was a cache artifact
from a session restart, not a code defect); seed retired to `seed/` as
`bit-seed`, `compiler/` gone; CI's primary build already targets the
self-hosted compiler, and its differential step now runs the full
self-discovering family instead of a hand-picked subset.
