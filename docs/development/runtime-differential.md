# Runtime codegen differential: design record

Moved out of `scripts/selfhost-diffruntime.sh`'s header (#4264) to keep the
script itself under the 800-line ceiling. Nothing below was reworded — only
moved and reflowed from `#`-comments into Markdown.

Runtime codegen differential (#1859): run every `runtime/**/*.bit` through both
compilers' `--dump-ir-pre` and diff the lowered SSA text.

## Why this exists

The other fifteen `selfhost-diff*.sh` all walk the same corpus:

```
    find stdlib examples _tests_/cases _tests_/imports -name '*.bit'
```

`runtime/` is in none of them. The compiler had therefore NEVER been
differentially tested against the source it compiles into every user binary.

That blind spot has a price tag. #1857: `parseFloat` had no hex-float branch,
so every `0x…p…` literal became ±0.0. `runtime/root` is the only place in the
repo that uses hex float literals, so no differential could ever have compared
the construct. The bug survived the entire self-hosting effort and surfaced
only when #1593 made the self-hosted compiler build `libbitrt.a` for the first
time — where it silently zeroed `bit_rt_log`'s whole polynomial and made
`log(x)` return 0 for every input. The differentials were green throughout.
They were not wrong; they were asked about a corpus that excluded the code.

## Why IR text alone is not the whole picture (#2741)

Measured on `main` at `948ec5fd`, over the same 87 files this walk compares:
966 function bodies dumped, 477 EMPTY (49.4%). A single `.bit` file cannot
resolve its module siblings' imports, so lowering a body that references one
does not error — it emits an EMPTY body and exits 0. `runtime/root/root.bit`'s
`bit_rt_init`, the runtime's boot function, is one of the 477:

```
    func bit_rt_init(%0: i64) bool {
    bb0(%0: i64):
      ret
    }
```

`--dump-ir-pre` is also PRE-optimisation, so a divergence inside a small
`@nosplit` helper inlined by `compiler/opt.bit`'s `-O1` pass (`spinRelease`,
`spinTryAcquire`) is invisible in every per-file dump — it exists only in the
caller's post-inline body. #2569's divergence had 38 machine-code sites
across 6 modules; this walk alone named 2 files and 3 sites.

The whole-module object-byte comparison below (added by #2741) closes both
gaps: a module build resolves its own siblings (no empty stubs) and emits
the actual post-optimisation machine code (inlining and all). It does not
replace this walk — IR text is still the right surface for a mis-parsed
constant, which appears in it directly as `const_float f64 0.5`, and
catches it (#1857) at the file granularity a module build cannot isolate.

## Why byte-for-byte identity against the pinned release stopped being a valid invariant, and what replaced it (#3103)

#1859 first proposed object bytes here; the measurement then was
seed-vs-selfhost, every module differed (root 147941 vs 171069, gc 50661 vs
57173, ...) — #1851's backend optimiser gap, not a correctness difference —
and the conclusion was "object bytes only mean something between two builds
of the SAME implementation." #2741 (measured on `main` at `948ec5fd`, 23/23
modules byte-identical) argued that since #1593 the pinned stage0 IS that
same implementation, one release back, so byte identity became meaningful.

It held only because no intentional codegen improvement had landed in that
window. #1852 closed #1851's own backend gap on aarch64 (`_scanObject` 120
movs -> 60) and reopened exactly the seed-vs-selfhost condition #1859
rejected: 22 of 23 modules diverge, every one SMALLER on this tree, none of
them a bug (`gc` 63528 -> 55184 bytes, `chan` 37345 -> 31393, measured
#3103). Byte identity cannot pass an optimisation that is doing its job, so
it is no longer the invariant on **aarch64** hosts (macOS and Linux share
the ISA). What must still hold, because it is what #2569 actually broke:

> no atomic memory access changes WIDTH between its source type and the
> instruction the backend emits.

v0.1.10 emitted a 64-bit `stlr x`/`ldaxr x` through a `*i32` pointer at 38
sites (34 stores + 4 RMW/CAS, zero loads — `assertAtomicOperandWidth` below
only has a value operand to mis-widen on those three op kinds) across 6
modules, corrupting the 4 adjacent bytes every time. Width is not a style
choice the way instruction selection is — it is fixed by the pointee's
declared type (§11.5) — so an optimisation pass has no reason to touch it.
Verified rather than assumed (#3103), on all 23 modules, #1852's tree
against the pinned 0.1.17: **0 atomic-signature mismatches where 22 of 23
byte-compares diverge.**

So on aarch64 the module check below disassembles both objects, keeps only
the acquire/release-ordered mnemonics (`ldar*`/`ldax*`/`ldapr*`/`stlr*`/
`stlx*`/`cas*`), strips the register NUMBER (allocation legitimately moves)
but keeps the register CLASS — `w` (32-bit) vs `x` (64-bit) — sorts, dedupes
to a SET, and requires the sets to match. A width flip changes SET
membership (a `stlr w`/`stlr x` pair appears or disappears); an inlining
change that duplicates an already-emitted atomic, or a scheduling change,
does not (#3170 — an earlier `cmp` on the un-deduped, count-sensitive
multiset reddened this exact way when #3164's algebraic folding let
`trampRelease` inline into both its callers, doubling `_stlxr x`/`_ldaxr x`
without touching a single width).

Mutation-tested (#3103) against the real bug, not a synthetic stand-in:
`BIT_STAGE0_BIN` cannot point directly at v0.1.10 against TODAY's runtime
source any more — v0.1.10 predates the `function`->`fn` rename (#2760) and
cannot parse it (`E0021` on every `@nosplit fn`). Filed separately as #3109,
which re-ran the ticket's own repro on 2026-08-16 (stage0 pinned to 0.1.19
by then) and reconfirmed it: `BIT_STDLIB="$PWD/stdlib"
<v0.1.10's bin/bit> build runtime/gc -c --freestanding -o /dev/null` still
fails, `error[E0021]: expected 'function' or 'let' after an attribute, found
an identifier` at `runtime/gc/gc.bit:177` (the first `@nosplit fn`). This is
not something a repin will ever fix — v0.1.10 is frozen at release time, so
the parse failure against current source is permanent.

The historical #2569 divergence itself still reproduces, on ERA-MATCHED
source — v0.1.10/v0.1.11 never need to parse today's tree, only the tree as
it stood the commit before the repin. No fixture is committed for this: the
source is one `git archive` away and both release binaries are one `curl`
away (same GitHub-releases path `scripts/stage0.sh` fetches from), and a
frozen copy would only be a second thing to go stale the same way this
recipe did. Re-run and reconfirmed by #3109 for the `gc` module (the other 5
named below follow the identical shape — swap the path):

```
  git archive 32ce1ff3 runtime | tar -x -C "$SCRATCH/era"
  for v in 0.1.10 0.1.11; do
    curl -fsSL -o "$SCRATCH/$v.tar.xz" \
      "https://github.com/byteink/bit/releases/download/v$v/bit-$v-<triple>.tar.xz"
    tar xf "$SCRATCH/$v.tar.xz" -C "$SCRATCH/$v"
  done
  cd "$SCRATCH/era"
  "$SCRATCH/0.1.10"/*/bin/bit build runtime/gc -c --freestanding -o gc10.o
  "$SCRATCH/0.1.11"/*/bin/bit build runtime/gc -c --freestanding -o gc11.o
  cmp gc10.o gc11.o
```

(<triple> is macos-aarch64 / linux-aarch64 / linux-x86_64 — the same host
mapping scripts/stage0.sh uses.) #3109 ran exactly this: both binaries build
the era-matched `gc` module cleanly (exit 0 each, 98826 bytes each), then
`cmp` exits 1 at byte 145 — the raw-byte divergence #2569 actually shipped,
reproduced without reasoning about it. #3109 also re-ran the atomic-width
signature this file actually gates on (aarch64's `atomicSignature()` below,
lifted into a scratch script rather than re-derived by hand):
`gc10.o` (v0.1.10, the bug) yields `{ldar x, ldaxr x, stlr x, stlxr w}` —
missing `ldaxr w` and `stlr w` entirely; `gc11.o` (v0.1.11, the fix) yields
both the `w` and `x` forms of each. That is #2569 exactly: v0.1.10 never
emits the 32-bit acquire/release form at all, because it always widens to
`x` regardless of the pointee's declared type.

This block demonstrates the invariant catches the real bug ONCE; it needs
re-running only if the invariant itself changes, not on every stage0 repin.
The routine, every-run oracle stays the CURRENT pin via `scripts/stage0.sh`
below — never a hardcoded version, which is what made the old recipe go
stale in the first place.

What this deliberately no longer asserts, on aarch64: that instruction
COUNT, SCHEDULE or SELECTION for anything but atomic width matches the
pinned release. A backend bug that is not a width mismatch (wrong
arithmetic, a dropped instruction, a wrong branch) is not guaranteed to be
caught here — it never truly was, before #1852, except by the accident that
any difference at all was suspicious; #1852 broke that accident on purpose,
and un-breaking it would block every future codegen improvement, which
#3103's own ticket weighs and rejects (gating on pin currency is silently
vacuous between releases; informational-only is a check nobody fails; a
release-and-repin per change serialises all performance work). The per-file
IR walk above is unweakened by any of this — still exact-text.

What was tried and rejected: comparing the tree's OWN runtime object output
across two `selfhost-fixpoint.sh`-style self-build generations, instead of
against the pinned release. Rejected on inspection, not on principle: `bit
build compiler -o X` links a PRE-BUILT `libbitrt.a` rather than recompiling
runtime/ from source (`compiler/build.bit`'s `libbitrtPath`), so a
self-build fixed point never touches runtime codegen at all; a from-scratch
two-generation runtime rebuild would only reconfirm what
`selfhost-fixpoint.sh` already proves (this tree reproduces itself), a
different property from "matches a known-good reference", and it would have
scored #2569 a MATCH — v0.1.10's bug was baked identically into every
self-build generation, so a same-tree comparison has nothing external to
diverge from by construction. Confirmed empirically (#3103): reverting the
exact #2569 fix commit on current HEAD does not even reach a silent byte
divergence any more — it now trips `assertAtomicOperandWidth`'s compile-time
panic (#2742, added after #2569), caught by the existing build-failure
branch below independent of anything in this section.

x86-64 gets the SAME narrowed invariant now (#3110), verified on real
x86_64-linux hardware (hl-master), not guessed. x86-64's TSO model has no
single per-instruction acquire/release mnemonic the way aarch64's
`ldar`/`stlr` do, so the signal is structurally different, found by
disassembling all 23 `runtime/**` archive modules built by the pinned
oracle and grepping every `lock`-prefixed instruction plus every
instruction immediately preceding an `mfence`:

- RMW (add/sub/xchg) and CAS (`atomicCmpxchg`, and the and/or retry loop —
  x86 has no native fetch-and-and/or) lower to `lock xadd`/`lock cmpxchg`
  (`compiler/x64select.bit`'s `xEmitAtomicRmw`/`xEmitAtomicCmpxchg`), width
  visible in the register operand's class — exactly the RMW mnemonic plus
  register-width signal #3110's own hypothesis guessed.
- STORE is not `lock`-prefixed at all — x86-TSO already orders a store
  against earlier stores, so there is no dedicated release-store mnemonic.
  It lowers to a plain `mov <reg>,MEM` immediately followed by `mfence`
  (`xEmitAtomicStore`; `xMfence`'s only call site in the whole backend, and
  the only thing that ever emits `mfence` at all). Confirmed on real
  disassembly: all 87 `mfence` occurrences across the 23 modules were
  immediately preceded by exactly that store's own `mov`, zero exceptions —
  adjacency is a safe discriminator here, not a guess.
- LOAD has no signal at all: a plain acquire load on x86-TSO is just `mov`,
  indistinguishable from any other load by mnemonic. Not a gap worth
  closing — `assertAtomicOperandWidth` (compiler/lowerprim.bit) never
  checks `atomicLoad`'s width either (only store/RMW/CAS have a value
  operand to mis-widen), so a load-width bug is not a case this invariant
  needs to catch on any ISA; aarch64's mnemonic list includes `ldar*` only
  because aarch64 happens to have a dedicated load mnemonic to grep, not
  because loads are part of the invariant.

Mutation-tested against a synthesized width-class miscompile — no
historical x86-64 case exists, so one was built the same shape as the real
#2569 bug, as #3103's own precedent and this ticket allow.
`xEmitAtomicStore`'s `xMovStore(cx.buf, xMemB(base, 0), val, w.bytes)`
mutated to hardcode `8` (always emit a 64-bit store regardless of the
pointee's declared width), rebuilt, and compared against the pinned oracle
on hl-master (real x86_64 hardware):

```
  plain instruction COUNT:  0/23 modules differ  (bug NOT caught)
  raw object bytes:         9/23 modules differ
  this signature:           9/23 modules differ, the SAME 9 as raw bytes
```

Site level: every 32-bit-pointee atomic store in the corpus flips from
`store w` to `store x` — oracle totals `store w`=52 `store x`=35, mutated
totals `store w`=0 `store x`=87 (cmpxchg/xadd counts unchanged, as
expected: the mutation only touches `xEmitAtomicStore`). 0 false positives
on the other 14 modules, which carry no atomics or no 32-bit atomic
stores. So an instruction-count-only diff — the naive cheaper alternative
— would have passed this exact bug; the signature and full byte identity
both catch it, and unlike byte identity the signature does not also flag a
legitimate codegen improvement that changes bytes without changing width
(#3103's own reason for narrowing the aarch64 invariant in the first
place).

Verified on x86_64-linux ONLY: no x86_64-macOS host exists to check
`otool -tV`'s x86 output against this same regex/adjacency logic (Apple
has not shipped Intel hardware in years). The MIN_ATOMIC_SITES floor below
still guards a silently-emptied extraction on any host, including a
hypothetical x86_64-macOS one, exactly as it already does for aarch64.

No Mach-O code-signature trap here (the family of bug where two
byte-identical compilers differ if built to different `-o` names): `-c
--freestanding` emits a relocatable object (Mach-O `MH_OBJECT`), which
carries no `LC_CODE_SIGNATURE` load command and no embedded filename or
path — confirmed by building the same module to two different basenames in
two different directories and finding all four outputs byte-identical.

## Why the IR walk above is per-file and not per-module

Not a preference — there is no module-level IR dump. `--dump-ir-pre` reads
exactly one file (`readDumpSource` in compiler/main.bit calls `readFile` on
its argument) and lowers it standalone; a directory fails outright:

```
    bit --dump-ir-pre runtime/gc   -> bit: cannot read runtime/gc   (rc=1)
    bit --dump-ir-pre runtime/root -> bit: cannot read runtime/root (rc=1)
```

`bit build <dir>` has no such limit — it is what the object-byte comparison
below uses to get module granularity. Teaching `--dump-ir-pre` to resolve a
directory is a compiler feature, not a script; until then, per-file is the
whole surface this walk can reach. It happens to cost nothing: the walk
below skips zero files.

## Why a mismatch is checked against a declared-transform signature first (#3132)

This IR walk has its OWN shell-out to `--dump-ir-pre` — it never routed
through scripts/selfhost-diffdump.sh — so #3125's fix (score a mismatch
against a table of declared lowering-transform signatures before calling it
a regression) never reached it. #3107's inline slice-index lowering
(compiler/loweraccess.bit) reddened this arm exactly the way it reddened
diffdump's ir/iropt rows before #3125: `runtime/park/darwin/wait.bit`,
`runtime/root/{floatbig,floatfmt,floatparse}.bit` and
`runtime/thread/darwin/spawn.bit` all index buffers and lower differently
by design. This sources `explainMismatch` from
scripts/selfhost-ir-signatures.sh — the same function selfhost-diffdump.sh
sources, not a second copy — and downgrades a mismatch to EXPLAINED only
when it satisfies the registered #3107 identity; anything else still fails
exactly as before.

