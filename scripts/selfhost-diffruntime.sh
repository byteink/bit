#!/usr/bin/env bash
# Runtime codegen differential (#1859): run every `runtime/**/*.bit` through both
# compilers' `--dump-ir-pre` and diff the lowered SSA text.
#
# ## Why this exists
#
# The other fifteen `selfhost-diff*.sh` all walk the same corpus:
#
#     find stdlib examples tests/cases tests/imports -name '*.bit'
#
# `runtime/` is in none of them. The compiler had therefore NEVER been
# differentially tested against the source it compiles into every user binary.
#
# That blind spot has a price tag. #1857: `parseFloat` had no hex-float branch,
# so every `0x…p…` literal became ±0.0. `runtime/root` is the only place in the
# repo that uses hex float literals, so no differential could ever have compared
# the construct. The bug survived the entire self-hosting effort and surfaced
# only when #1593 made the self-hosted compiler build `libbitrt.a` for the first
# time — where it silently zeroed `bit_rt_log`'s whole polynomial and made
# `log(x)` return 0 for every input. The differentials were green throughout.
# They were not wrong; they were asked about a corpus that excluded the code.
#
# ## Why IR text alone is not the whole picture (#2741)
#
# Measured on `main` at `948ec5fd`, over the same 87 files this walk compares:
# 966 function bodies dumped, 477 EMPTY (49.4%). A single `.bit` file cannot
# resolve its module siblings' imports, so lowering a body that references one
# does not error — it emits an EMPTY body and exits 0. `runtime/root/root.bit`'s
# `bit_rt_init`, the runtime's boot function, is one of the 477:
#
#     func bit_rt_init(%0: i64) bool {
#     bb0(%0: i64):
#       ret
#     }
#
# `--dump-ir-pre` is also PRE-optimisation, so a divergence inside a small
# `@nosplit` helper inlined by `compiler/opt.bit`'s `-O1` pass (`spinRelease`,
# `spinTryAcquire`) is invisible in every per-file dump — it exists only in the
# caller's post-inline body. #2569's divergence had 38 machine-code sites
# across 6 modules; this walk alone named 2 files and 3 sites.
#
# The whole-module object-byte comparison below (added by #2741) closes both
# gaps: a module build resolves its own siblings (no empty stubs) and emits
# the actual post-optimisation machine code (inlining and all). It does not
# replace this walk — IR text is still the right surface for a mis-parsed
# constant, which appears in it directly as `const_float f64 0.5`, and
# catches it (#1857) at the file granularity a module build cannot isolate.
#
# ## Why byte-for-byte identity against the pinned release stopped being a
# ## valid invariant, and what replaced it (#3103)
#
# #1859 first proposed object bytes here; the measurement then was
# seed-vs-selfhost, every module differed (root 147941 vs 171069, gc 50661 vs
# 57173, ...) — #1851's backend optimiser gap, not a correctness difference —
# and the conclusion was "object bytes only mean something between two builds
# of the SAME implementation." #2741 (measured on `main` at `948ec5fd`, 23/23
# modules byte-identical) argued that since #1593 the pinned stage0 IS that
# same implementation, one release back, so byte identity became meaningful.
#
# It held only because no intentional codegen improvement had landed in that
# window. #1852 closed #1851's own backend gap on aarch64 (`_scanObject` 120
# movs -> 60) and reopened exactly the seed-vs-selfhost condition #1859
# rejected: 22 of 23 modules diverge, every one SMALLER on this tree, none of
# them a bug (`gc` 63528 -> 55184 bytes, `chan` 37345 -> 31393, measured
# #3103). Byte identity cannot pass an optimisation that is doing its job, so
# it is no longer the invariant on **aarch64** hosts (macOS and Linux share
# the ISA). What must still hold, because it is what #2569 actually broke:
#
# > no atomic memory access changes WIDTH between its source type and the
# > instruction the backend emits.
#
# v0.1.10 emitted a 64-bit `stlr x`/`ldaxr x` through a `*i32` pointer at 38
# sites (34 stores + 4 RMW/CAS, zero loads — `assertAtomicOperandWidth` below
# only has a value operand to mis-widen on those three op kinds) across 6
# modules, corrupting the 4 adjacent bytes every time. Width is not a style
# choice the way instruction selection is — it is fixed by the pointee's
# declared type (§11.5) — so an optimisation pass has no reason to touch it.
# Verified rather than assumed (#3103), on all 23 modules, #1852's tree
# against the pinned 0.1.17: **0 atomic-signature mismatches where 22 of 23
# byte-compares diverge.**
#
# So on aarch64 the module check below disassembles both objects, keeps only
# the acquire/release-ordered mnemonics (`ldar*`/`ldax*`/`ldapr*`/`stlr*`/
# `stlx*`/`cas*`), strips the register NUMBER (allocation legitimately moves)
# but keeps the register CLASS — `w` (32-bit) vs `x` (64-bit) — sorts, dedupes
# to a SET, and requires the sets to match. A width flip changes SET
# membership (a `stlr w`/`stlr x` pair appears or disappears); an inlining
# change that duplicates an already-emitted atomic, or a scheduling change,
# does not (#3170 — an earlier `cmp` on the un-deduped, count-sensitive
# multiset reddened this exact way when #3164's algebraic folding let
# `trampRelease` inline into both its callers, doubling `_stlxr x`/`_ldaxr x`
# without touching a single width).
#
# Mutation-tested (#3103) against the real bug, not a synthetic stand-in:
# `BIT_STAGE0_BIN` cannot point directly at v0.1.10 against TODAY's runtime
# source any more — v0.1.10 predates the `function`->`fn` rename (#2760) and
# cannot parse it (`E0021` on every `@nosplit fn`), which is itself worth
# knowing and is filed separately (#3109). Rebuilt the actual v0.1.10 and
# v0.1.11 (the real #2569 fix) release binaries against the runtime/ source
# AS IT EXISTED the commit before the repin (32ce1ff3, still
# `function`-keyword era): raw bytes AND the atomic signature both diverge on
# all 6 named modules (runtime, chan, gc, root, sched, stw) — output below.
#
# What this deliberately no longer asserts, on aarch64: that instruction
# COUNT, SCHEDULE or SELECTION for anything but atomic width matches the
# pinned release. A backend bug that is not a width mismatch (wrong
# arithmetic, a dropped instruction, a wrong branch) is not guaranteed to be
# caught here — it never truly was, before #1852, except by the accident that
# any difference at all was suspicious; #1852 broke that accident on purpose,
# and un-breaking it would block every future codegen improvement, which
# #3103's own ticket weighs and rejects (gating on pin currency is silently
# vacuous between releases; informational-only is a check nobody fails; a
# release-and-repin per change serialises all performance work). The per-file
# IR walk above is unweakened by any of this — still exact-text.
#
# What was tried and rejected: comparing the tree's OWN runtime object output
# across two `selfhost-fixpoint.sh`-style self-build generations, instead of
# against the pinned release. Rejected on inspection, not on principle: `bit
# build compiler -o X` links a PRE-BUILT `libbitrt.a` rather than recompiling
# runtime/ from source (`compiler/build.bit`'s `libbitrtPath`), so a
# self-build fixed point never touches runtime codegen at all; a from-scratch
# two-generation runtime rebuild would only reconfirm what
# `selfhost-fixpoint.sh` already proves (this tree reproduces itself), a
# different property from "matches a known-good reference", and it would have
# scored #2569 a MATCH — v0.1.10's bug was baked identically into every
# self-build generation, so a same-tree comparison has nothing external to
# diverge from by construction. Confirmed empirically (#3103): reverting the
# exact #2569 fix commit on current HEAD does not even reach a silent byte
# divergence any more — it now trips `assertAtomicOperandWidth`'s compile-time
# panic (#2742, added after #2569), caught by the existing build-failure
# branch below independent of anything in this section.
#
# x86-64 gets the SAME narrowed invariant now (#3110), verified on real
# x86_64-linux hardware (hl-master), not guessed. x86-64's TSO model has no
# single per-instruction acquire/release mnemonic the way aarch64's
# `ldar`/`stlr` do, so the signal is structurally different, found by
# disassembling all 23 `runtime/**` archive modules built by the pinned
# oracle and grepping every `lock`-prefixed instruction plus every
# instruction immediately preceding an `mfence`:
#
# - RMW (add/sub/xchg) and CAS (`atomicCmpxchg`, and the and/or retry loop —
#   x86 has no native fetch-and-and/or) lower to `lock xadd`/`lock cmpxchg`
#   (`compiler/x64select.bit`'s `xEmitAtomicRmw`/`xEmitAtomicCmpxchg`), width
#   visible in the register operand's class — exactly the RMW mnemonic plus
#   register-width signal #3110's own hypothesis guessed.
# - STORE is not `lock`-prefixed at all — x86-TSO already orders a store
#   against earlier stores, so there is no dedicated release-store mnemonic.
#   It lowers to a plain `mov <reg>,MEM` immediately followed by `mfence`
#   (`xEmitAtomicStore`; `xMfence`'s only call site in the whole backend, and
#   the only thing that ever emits `mfence` at all). Confirmed on real
#   disassembly: all 87 `mfence` occurrences across the 23 modules were
#   immediately preceded by exactly that store's own `mov`, zero exceptions —
#   adjacency is a safe discriminator here, not a guess.
# - LOAD has no signal at all: a plain acquire load on x86-TSO is just `mov`,
#   indistinguishable from any other load by mnemonic. Not a gap worth
#   closing — `assertAtomicOperandWidth` (compiler/lowerprim.bit) never
#   checks `atomicLoad`'s width either (only store/RMW/CAS have a value
#   operand to mis-widen), so a load-width bug is not a case this invariant
#   needs to catch on any ISA; aarch64's mnemonic list includes `ldar*` only
#   because aarch64 happens to have a dedicated load mnemonic to grep, not
#   because loads are part of the invariant.
#
# Mutation-tested against a synthesized width-class miscompile — no
# historical x86-64 case exists, so one was built the same shape as the real
# #2569 bug, as #3103's own precedent and this ticket allow.
# `xEmitAtomicStore`'s `xMovStore(cx.buf, xMemB(base, 0), val, w.bytes)`
# mutated to hardcode `8` (always emit a 64-bit store regardless of the
# pointee's declared width), rebuilt, and compared against the pinned oracle
# on hl-master (real x86_64 hardware):
#
#   plain instruction COUNT:  0/23 modules differ  (bug NOT caught)
#   raw object bytes:         9/23 modules differ
#   this signature:           9/23 modules differ, the SAME 9 as raw bytes
#
# Site level: every 32-bit-pointee atomic store in the corpus flips from
# `store w` to `store x` — oracle totals `store w`=52 `store x`=35, mutated
# totals `store w`=0 `store x`=87 (cmpxchg/xadd counts unchanged, as
# expected: the mutation only touches `xEmitAtomicStore`). 0 false positives
# on the other 14 modules, which carry no atomics or no 32-bit atomic
# stores. So an instruction-count-only diff — the naive cheaper alternative
# — would have passed this exact bug; the signature and full byte identity
# both catch it, and unlike byte identity the signature does not also flag a
# legitimate codegen improvement that changes bytes without changing width
# (#3103's own reason for narrowing the aarch64 invariant in the first
# place).
#
# Verified on x86_64-linux ONLY: no x86_64-macOS host exists to check
# `otool -tV`'s x86 output against this same regex/adjacency logic (Apple
# has not shipped Intel hardware in years). The MIN_ATOMIC_SITES floor below
# still guards a silently-emptied extraction on any host, including a
# hypothetical x86_64-macOS one, exactly as it already does for aarch64.
#
# No Mach-O code-signature trap here (the family of bug where two
# byte-identical compilers differ if built to different `-o` names): `-c
# --freestanding` emits a relocatable object (Mach-O `MH_OBJECT`), which
# carries no `LC_CODE_SIGNATURE` load command and no embedded filename or
# path — confirmed by building the same module to two different basenames in
# two different directories and finding all four outputs byte-identical.
#
# ## Why the IR walk above is per-file and not per-module
#
# Not a preference — there is no module-level IR dump. `--dump-ir-pre` reads
# exactly one file (`readDumpSource` in compiler/main.bit calls `readFile` on
# its argument) and lowers it standalone; a directory fails outright:
#
#     bit --dump-ir-pre runtime/gc   -> bit: cannot read runtime/gc   (rc=1)
#     bit --dump-ir-pre runtime/root -> bit: cannot read runtime/root (rc=1)
#
# `bit build <dir>` has no such limit — it is what the object-byte comparison
# below uses to get module granularity. Teaching `--dump-ir-pre` to resolve a
# directory is a compiler feature, not a script; until then, per-file is the
# whole surface this walk can reach. It happens to cost nothing: the walk
# below skips zero files.
#
# ## Why a mismatch is checked against a declared-transform signature first (#3132)
#
# This IR walk has its OWN shell-out to `--dump-ir-pre` — it never routed
# through scripts/selfhost-diffdump.sh — so #3125's fix (score a mismatch
# against a table of declared lowering-transform signatures before calling it
# a regression) never reached it. #3107's inline slice-index lowering
# (compiler/loweraccess.bit) reddened this arm exactly the way it reddened
# diffdump's ir/iropt rows before #3125: `runtime/park/darwin/wait.bit`,
# `runtime/root/{floatbig,floatfmt,floatparse}.bit` and
# `runtime/thread/darwin/spawn.bit` all index buffers and lower differently
# by design. This sources `explainMismatch` from
# scripts/selfhost-ir-signatures.sh — the same function selfhost-diffdump.sh
# sources, not a second copy — and downgrades a mismatch to EXPLAINED only
# when it satisfies the registered #3107 identity; anything else still fails
# exactly as before.
#
# Usage: ./make selfhost && bash scripts/selfhost-diffruntime.sh
set -uo pipefail
# shellcheck source=scripts/alarmrun.sh
. "$(dirname -- "$0")/alarmrun.sh"
# shellcheck source=scripts/selfhost-ir-signatures.sh
. "$(dirname -- "$0")/selfhost-ir-signatures.sh"

# Oracle: the pinned stage0 (previous release), like every other differential
# since #1593. scripts/stage0.sh downloads and DIGEST-VERIFIES it and refuses
# rather than skipping, so a failure here is loud. It also pins BIT_STDLIB to
# the WORKING TREE for both sides — without that this would diff two stdlibs
# instead of two compilers.
ORACLE="$(sh scripts/stage0.sh)" || exit 2
BIT2=bit-out/bin/bit
# The alarm is a HANG guard, not a performance budget (#2070). 20s sat below the
# corpus's slowest file measured on the IR differentials (25.20s on this tree,
# 21.86s on the oracle), so a busy box turned a clean run red with no divergence
# at all. 300s is ~12x that, in the spirit of the suite's own 900s-against-158s.
TIMEOUT=${DIFFRUNTIME_TIMEOUT:-300}

# Why a child died, for the report. 128+N is death by signal N; 14 is the alarm
# this script set, so that alone is a timeout and every other signal is a crash.
# Calling a SIGSEGV "timed out" sends the reader after a problem that is not
# there — the same distinction the test harnesses make (#2070, docs/development.md).
sep="  -> "
whydied() {
  case "$1" in
    142) echo "timed out after ${TIMEOUT}s" ;;
    139) echo "CRASHED (SIGSEGV)" ;;
    138) echo "CRASHED (SIGBUS)" ;;
    134) echo "CRASHED (SIGABRT)" ;;
    *)   echo "CRASHED (signal $(( $1 - 128 )))" ;;
  esac
}

# A gate whose population can quietly go to zero passes everything. `runtime/`
# holds 85 `.bit` files today and the walk skips none of them, so a floor well
# under that catches a broken find, a moved directory or a compiler that starts
# refusing every file, while leaving room to delete a module.
MIN_FILES=${DIFFRUNTIME_MIN_FILES:-70}

# A count is not coverage. These are the files carrying hex float literals — the
# construct #1857 got wrong — and each MUST be compared, not merely counted. A
# refactor that makes one unparseable in single-file mode would drop it into the
# skip set, leave the totals looking healthy, and silently retire the only
# regression test this gate exists to provide.
REQUIRED="runtime/root/floatslog.bit runtime/root/floatsatan.bit"

# --- Object-byte module list (#2741): extracted, not hand-copied ---
#
# `PLATFORM_FREE_RELS` / `PLATFORM_PAIRS` come straight out of g2archive.sh —
# never restated here — so the two lists cannot drift the way g2archive.sh's
# own header (lines 106-112 there) warns a hand-maintained copy always does.
# Sourcing the whole file is not an option: it is an argv-driven CLI that
# calls `usage` and exits 2 when run with no arguments.
GARCHIVE="$(dirname "$0")/g2archive.sh"
eval "$(grep -E '^(PLATFORM_FREE_RELS|PLATFORM_PAIRS)=' "$GARCHIVE")"
if [ -z "${PLATFORM_FREE_RELS:-}" ] || [ -z "${PLATFORM_PAIRS:-}" ]; then
  echo "diffruntime: FAIL — could not extract the module list from $GARCHIVE." >&2
  exit 2
fi

# Same OS mapping g2archive.sh uses (aarch64-macos -> darwin; x86_64-linux and
# aarch64-linux both -> linux) restricted to the HOST — this check builds with
# no --target, so `bit build` targets the host by default and the platform
# pair must match it.
case "$(uname -s)" in
  Darwin) PLAT=darwin ;;
  Linux)  PLAT=linux ;;
  *) echo "diffruntime: FAIL — unsupported host $(uname -s) for the object-byte check." >&2; exit 2 ;;
esac

# The invariant that survives #1852-style optimisation is atomic INSTRUCTION
# WIDTH, not full bytes — see the header. Keyed off the CPU, not PLAT: an
# aarch64-linux host gets the same treatment as this aarch64-macos one,
# because it is the same ISA. x86-64 gets its own signature extraction now
# too (header, #3110), verified on real x86_64-linux hardware. Any other ISA
# still keeps the old, stricter, byte-identity check unconditionally.
case "$(uname -m)" in
  arm64|aarch64) ATOMIC_ISA=aarch64 ;;
  x86_64|amd64)  ATOMIC_ISA=x86_64 ;;
  *)             ATOMIC_ISA=other ;;
esac

# The disassembler differs by OS, not by ISA: `otool -tV` on Darwin,
# `objdump -d` on Linux (both understand aarch64 Mach-O/ELF relocatables and
# print the same standard ARM mnemonics — `ldar`, `stlr`, register operand
# `w9`/`x9` — so one extraction regex covers both). The x86-64 extraction
# below is verified against objdump's AT&T-syntax output only (header) but
# reuses this same OS dispatch, so an x86_64-macOS host would still get
# otool's text — untested, guarded by MIN_ATOMIC_SITES below.
disasmText() { # <objfile>
  case "$(uname -s)" in
    Darwin) otool -tV "$1" 2>/dev/null ;;
    Linux)  objdump -d "$1" 2>/dev/null ;;
  esac
}

# Every acquire/release-ordered mnemonic this backend can emit for §11.5's
# atomic builtins, AARCH64 ONLY — see x86AtomicSignature below for why x86-64
# needs a structurally different extraction, not just a different mnemonic
# list. CAS lowers to an ldaxr/stlxr load-linked/store-conditional loop on
# this backend rather than a dedicated `casal`, confirmed by grepping the
# corpus (#3103) — the cas* entries are kept anyway in case that changes; an
# unmatched alternative costs nothing.
ATOMIC_MNEMONICS='ldar|ldarb|ldarh|ldaxr|ldaxrb|ldaxrh|ldapr|ldaprb|ldaprh|ldaxp|stlr|stlrb|stlrh|stlxr|stlxrb|stlxrh|stlxp|cas|casa|casl|casal|casb|casab|caslb|casalb|cash|casah|caslh|casalh|casp|caspa|caspl|caspal'

# x86-64 atomic-instruction-width signature (#3110, header has the full
# derivation and the mutation-test result). Unlike aarch64 this needs two
# discriminators, not one mnemonic list:
#
#   RMW/CAS: `lock (xadd|cmpxchg) %REG,` — register class is the width.
#   STORE:   a `mov %REG,MEM` immediately followed by `mfence` — register
#            class of the mov's SOURCE operand is the width. Adjacency is
#            safe because `xMfence` (compiler/x64select.bit) has exactly one
#            call site, `xEmitAtomicStore`, and emits nothing between the
#            mov and the fence.
#
# Output format matches the aarch64 arm's ("<mnemonic-ish> <class>", sorted,
# one line per site) so both feed the same cmp-based multiset comparison
# below. Register CLASS here is x=64-bit, w=32-bit, h=16-bit, b=8-bit (ARM's
# own naming, reused for one consistent vocabulary across both ISAs) — full,
# not prefix-based, register-name classification, since x86 register names
# (`eax` vs `rax` vs `r13d` vs `r13`) don't share a common numeric suffix to
# strip the way aarch64's `w9`/`x9` do.
x86AtomicSignature() { # <objfile>
  disasmText "$1" | awk '
    function regClass(r) {
      if (r ~ /^r(8|9|1[0-5])$/)               return "x"
      if (r ~ /^r(ax|bx|cx|dx|si|di|bp|sp)$/)  return "x"
      if (r ~ /^r(8|9|1[0-5])d$/)              return "w"
      if (r ~ /^e(ax|bx|cx|dx|si|di|bp|sp)$/)  return "w"
      if (r ~ /^r(8|9|1[0-5])w$/)              return "h"
      if (r ~ /^(ax|bx|cx|dx|si|di|bp|sp)$/)   return "h"
      if (r ~ /^r(8|9|1[0-5])b$/)              return "b"
      if (r ~ /^[abcd]l$/)                     return "b"
      if (r ~ /^(sil|dil|bpl|spl)$/)           return "b"
      return ""
    }
    {
      if (match($0, /lock (cmpxchg|xadd) %[a-z0-9]+,/)) {
        seg = substr($0, RSTART, RLENGTH)
        split(seg, p, " ")
        reg = p[3]; sub(/^%/, "", reg); sub(/,$/, "", reg)
        cls = regClass(reg)
        if (cls != "") print p[2]" "cls
        prevcls = ""
        next
      }
      if (match($0, /mov[ \t]+%[a-z0-9]+,[^\t]*\(%[a-z0-9]+\)/)) {
        seg = substr($0, RSTART, RLENGTH)
        match(seg, /%[a-z0-9]+/)
        reg = substr(seg, RSTART + 1, RLENGTH - 1)
        prevcls = regClass(reg)
        next
      }
      if ($0 ~ /mfence/) {
        if (prevcls != "") print "store " prevcls
        prevcls = ""
        next
      }
      prevcls = ""
    }
  ' | sort
}

# Sorted, register-NUMBER-stripped, register-CLASS-preserved atomic mnemonic
# list for one object — the signature two builds must agree on. Register
# ALLOCATION (which number) legitimately varies with optimisation; register
# CLASS (w=32-bit vs x=64-bit) is fixed by the pointee's declared type
# (§11.5) and is exactly what #2569 got wrong.
atomicSignature() { # <objfile>
  if [ "$ATOMIC_ISA" = x86_64 ]; then
    x86AtomicSignature "$1"
    return
  fi
  disasmText "$1" | grep -oE "\\b(${ATOMIC_MNEMONICS})[[:space:]]+[wx][0-9]+" | sed -E 's/[0-9]+$//' | sort
}

# A count is not coverage (same principle as MIN_FILES/MIN_MODULES below): if
# extraction silently breaks — otool/objdump missing, a mnemonic spelling
# change, a moved tool — every module's signature would go empty on BOTH
# sides and pass vacuously. 362 sites were extracted from the pinned oracle's
# 23 modules on aarch64 when this floor was set (#3103); 300 is comfortably
# under that while still catching an emptied extraction. x86-64's corpus is
# structurally smaller — a store costs 2 instructions (mov+mfence) there
# against 1 (stlr) on aarch64, but there are fewer RMW/CAS sites overall — and
# measured independently on hl-master at 126 (#3110); 100 is the same margin
# in spirit.
MIN_ATOMIC_SITES_DEFAULT=300
[ "$ATOMIC_ISA" = x86_64 ] && MIN_ATOMIC_SITES_DEFAULT=100
MIN_ATOMIC_SITES=${DIFFRUNTIME_MIN_ATOMIC_SITES:-$MIN_ATOMIC_SITES_DEFAULT}
atomic_sites_seen=0

# Same (rel, label) expansion g2archive.sh applies to the same two variables —
# glue over the extracted data, not a second copy of the data itself.
MOD_RELS=()
MOD_LABELS=()
for rel in $PLATFORM_FREE_RELS; do
  if [ "$rel" = "-" ]; then
    MOD_RELS+=("")
    MOD_LABELS+=("runtime")
  else
    MOD_RELS+=("$rel")
    MOD_LABELS+=("runtime_$(printf '%s' "$rel" | tr '/' '_')")
  fi
done
for p in $PLATFORM_PAIRS; do
  MOD_RELS+=("$p/$PLAT")
  MOD_LABELS+=("runtime_${p}_${PLAT}")
done
NMOD=${#MOD_RELS[@]}

# A floor, not an exact match, for the same reason MIN_FILES above is a floor:
# the extracted list is 23 today (16 platform-free entries incl. the bare
# `runtime` dir, + 7 platform pairs) and legitimately grows as modules are
# added — g2archive.sh's own on-disk completeness check (lines 132-157 there)
# is what keeps it honest going forward. 20 is well under 23, so this still
# catches an emptied list or a broken extraction without going stale the next
# time a module is added, which is exactly how #2741's own filing ended up
# citing 22.
MIN_MODULES=${DIFFRUNTIME_MIN_MODULES:-20}

for bin in "$ORACLE" "$BIT2"; do
  [ -x "$bin" ] || { echo "diffruntime: missing $bin — run: ./make selfhost" >&2; exit 2; }
done

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

match=0 skip=0 total=0
: >"$work/mismatch"
: >"$work/explained"
: >"$work/timeout"
: >"$work/oracletimeout"
: >"$work/oraclecrash"
: >"$work/compared"

for f in $(find runtime -name '*.bit' | sort); do
  total=$((total + 1))

  # The oracle is bounded too (#2070). Its timeout is NOT a skip: a skip means
  # the oracle could not lower the file, an expected outcome, while a hang is a
  # broken stage0 — and an unbounded oracle wedged this gate with no message.
  a=$(alarmrun "$ORACLE" --dump-ir-pre "$f")
  arc=$?
  if [ "$arc" -eq 142 ]; then
    echo "$f${sep}$(whydied "$arc")" >>"$work/oracletimeout"
    continue
  fi
  if [ "$arc" -ge 128 ]; then
    echo "$f${sep}$(whydied "$arc")" >>"$work/oraclecrash"
    continue
  fi
  if [ "$arc" -ne 0 ] || [ -z "$a" ]; then
    # The oracle cannot lower it, so there is no verdict to be had. Counted and
    # reported, never scored as agreement (#1514/#1516).
    skip=$((skip + 1))
    continue
  fi

  b=$(alarmrun "$BIT2" --dump-ir-pre "$f")
  rc=$?
  # >=128 is death by signal, and WHICH signal is not a detail: 142 is our own
  # alarm, anything else is the compiler crashing. Either way no verdict (#2070).
  if [ "$rc" -ge 128 ]; then
    echo "$f${sep}$(whydied "$rc")" >>"$work/timeout"
    continue
  fi
  if [ "$rc" -ne 0 ]; then
    # The oracle lowered it and the working tree could not. That is a
    # regression, not a skip.
    echo "$f (bit failed where stage0 succeeded)" >>"$work/mismatch"
    echo "$f" >>"$work/compared"
    continue
  fi

  echo "$f" >>"$work/compared"
  if [ "$a" = "$b" ]; then
    match=$((match + 1))
  else
    # A raw mismatch is not automatically a regression (#3132, same fix as
    # #3125 one level up): check it against the declared-transform-signature
    # table before scoring it. Only an UNEXPLAINED divergence fails the gate.
    sig=$(explainMismatch "$a" "$b" ir)
    if [ -n "$sig" ]; then
      echo "$f${sep}explained by declared signature '$sig'" >>"$work/explained"
    else
      echo "$f" >>"$work/mismatch"
    fi
  fi
done

# --- Whole-module object comparison (#2741, invariant narrowed by #3103) ---
#
# Same taxonomy as the per-file walk above (oracle hang is a FAIL, oracle
# crash is a NOTE, dev hang/crash is a FAIL, dev build failure where the
# oracle succeeded is a mismatch), applied at module instead of file
# granularity. `-c --freestanding -o` with no `--target` compiles for the
# host, matching `PLAT` resolved above. On aarch64 hosts "compare" means the
# atomic-signature check (header); elsewhere it is still full byte identity.

objdev="$work/obj_dev"
objor="$work/obj_or"
mkdir -p "$objdev" "$objor"

modmatch=0 modskip=0
: >"$work/mod_mismatch"
: >"$work/mod_timeout"
: >"$work/mod_oracletimeout"
: >"$work/mod_oraclecrash"
: >"$work/mod_compared"

i=0
while [ "$i" -lt "$NMOD" ]; do
  rel=${MOD_RELS[$i]}
  label=${MOD_LABELS[$i]}
  i=$((i + 1))
  dir="runtime${rel:+/$rel}"
  devobj="$objdev/${label}.o"
  orobj="$objor/${label}.o"

  alarmrun "$ORACLE" build "$dir" -c --freestanding -o "$orobj" >/dev/null
  orc=$?
  if [ "$orc" -eq 142 ]; then
    echo "$dir${sep}$(whydied "$orc")" >>"$work/mod_oracletimeout"
    continue
  fi
  if [ "$orc" -ge 128 ]; then
    echo "$dir${sep}$(whydied "$orc")" >>"$work/mod_oraclecrash"
    continue
  fi
  if [ "$orc" -ne 0 ] || [ ! -s "$orobj" ]; then
    # The oracle cannot build this module, so there is no verdict to be had —
    # counted and reported, never scored as agreement (#1514/#1516).
    modskip=$((modskip + 1))
    continue
  fi

  alarmrun "$BIT2" build "$dir" -c --freestanding -o "$devobj" >/dev/null
  rc=$?
  if [ "$rc" -ge 128 ]; then
    echo "$dir${sep}$(whydied "$rc")" >>"$work/mod_timeout"
    continue
  fi
  if [ "$rc" -ne 0 ] || [ ! -s "$devobj" ]; then
    # The oracle built it and the working tree could not. That is a
    # regression, not a skip.
    echo "$dir (bit failed where stage0 succeeded)" >>"$work/mod_mismatch"
    echo "$dir" >>"$work/mod_compared"
    continue
  fi

  echo "$dir" >>"$work/mod_compared"
  if [ "$ATOMIC_ISA" = aarch64 ] || [ "$ATOMIC_ISA" = x86_64 ]; then
    devsig="$work/sig_dev"
    orsig="$work/sig_or"
    atomicSignature "$devobj" >"$devsig"
    atomicSignature "$orobj" >"$orsig"
    # The floor below counts raw (non-deduped) sites — it exists to catch a
    # broken extraction, not to weigh in on the equality check.
    atomic_sites_seen=$((atomic_sites_seen + $(wc -l <"$orsig")))
    # #3170: compare the SET of (mnemonic, register-class) pairs, not the
    # multiset. The header above says this check "no longer asserts ...
    # instruction COUNT" — the un-deduped `cmp` below it contradicted that:
    # inlining the same atomic into an extra call site (#3164, a legitimate
    # `wordsAt` fold that dropped `trampRelease` under the inline budget)
    # duplicates a line in the sorted list without touching any width, and
    # `cmp` on two differently-sized files always fails. `sort -u` collapses
    # duplicate (mnemonic, class) lines on both sides first; a width flip
    # still fails the comparison because it adds a class absent on the other
    # side or removes the last remaining instance of one — see the ticket
    # (#3170) for the mutation test that confirms the latter.
    if cmp -s <(sort -u "$devsig") <(sort -u "$orsig"); then
      modmatch=$((modmatch + 1))
    else
      echo "$dir" >>"$work/mod_mismatch"
    fi
  elif cmp -s "$devobj" "$orobj"; then
    modmatch=$((modmatch + 1))
  else
    echo "$dir" >>"$work/mod_mismatch"
  fi
done

bad=0

if [ "$total" -lt "$MIN_FILES" ]; then
  echo "diffruntime: FAIL — walked $total file(s), floor is $MIN_FILES." >&2
  echo "  An empty or shrunken walk passes everything; check the find expression." >&2
  bad=1
fi

for r in $REQUIRED; do
  if ! grep -qxF "$r" "$work/compared"; then
    echo "diffruntime: FAIL — required file '$r' was never compared." >&2
    echo "  It carries hex float literals, the construct #1857 got wrong. Losing" >&2
    echo "  coverage of it is a failure, not a smaller number." >&2
    bad=1
  fi
done

if [ -s "$work/oracletimeout" ]; then
  # Apart from ours because it means something different: the PINNED oracle hung,
  # so the corpus shrank rather than this tree misbehaving. Folding it into the
  # skip count would hide that behind a number meaning "the oracle declined it".
  echo "diffruntime: FAIL — the pinned stage0 HUNG (corpus reduced, not verified):" >&2
  sed 's/^/  /' "$work/oracletimeout" >&2
  bad=1
fi

# Reported, not failed — the oracle is a published immutable binary and no change
# here can stop it faulting, so failing would leave the gate red until the pin
# moves (#1895's routed-around-red hazard). A HANG still fails: that one means the
# run could not complete in bounded time. Naming the file every run is the point;
# before #2070 an oracle crash was an anonymous +1 to the skip count (#2084).
if [ -s "$work/oraclecrash" ]; then
  echo "diffruntime: NOTE — the pinned stage0 crashed, no verdict available (#2084):" >&2
  sed 's/^/  /' "$work/oraclecrash" >&2
fi

if [ -s "$work/timeout" ]; then
  echo "diffruntime: FAIL — no verdict (not a match):" >&2
  sed 's/^/  /' "$work/timeout" >&2
  bad=1
fi

# NO UNEXPLAINED DIVERGENCE IS PERMITTED. Any runtime file whose IR differs
# from the pinned stage0's, and whose delta does not satisfy a registered
# transform signature (explainMismatch, scripts/selfhost-ir-signatures.sh,
# #3132/#3125), fails the run. There was an expected-mismatch FILE list so a
# known difference could be written down instead of fixed; its last entry
# closed and it was deleted with its reader (#1883) — a signature is not that
# list reborn, see selfhost-ir-signatures.sh's header for why.
#
# The MIN_FILES floor and the REQUIRED list above are a SEPARATE property and
# stay: they prove the run was not vacuous, which an exit code cannot (#1881).
sort -u "$work/mismatch" >"$work/mismatch.sorted"
sort -u "$work/explained" >"$work/explained.sorted"

if [ -s "$work/mismatch.sorted" ]; then
  echo "diffruntime: FAIL — $(wc -l <"$work/mismatch.sorted" | tr -d ' ') file(s) diverge from the pinned stage0:" >&2
  sed 's/^/  /' "$work/mismatch.sorted" >&2
  echo "  Diff one with:  diff <(\"$ORACLE\" --dump-ir-pre FILE) <($BIT2 --dump-ir-pre FILE)" >&2
  bad=1
fi

# Informational, never fails the gate: each of these matched a declared
# transform signature's identity exactly (explainMismatch), a stronger claim
# than "this file is allowed to differ" — see selfhost-ir-signatures.sh's
# header for why that distinction is load-bearing.
if [ -s "$work/explained.sorted" ]; then
  echo "diffruntime: EXPLAINED — $(wc -l <"$work/explained.sorted" | tr -d ' ') file(s) diverge from the pinned stage0 but match a declared lowering-transform signature (not a regression):"
  sed 's/^/  /' "$work/explained.sorted"
fi

# --- Object-byte checks (#2741), mirroring the IR-walk checks above ---

if [ "$NMOD" -lt "$MIN_MODULES" ]; then
  echo "diffruntime: FAIL — extracted $NMOD archive module(s) from $GARCHIVE, floor is $MIN_MODULES." >&2
  echo "  An emptied or badly-split module list passes everything; check" >&2
  echo "  PLATFORM_FREE_RELS/PLATFORM_PAIRS there." >&2
  bad=1
fi

# A count is not coverage (#3103, same principle as MIN_FILES/MIN_MODULES): if
# disassembly extraction silently breaks, every module's atomic signature goes
# empty on BOTH sides and the comparison below passes vacuously.
if { [ "$ATOMIC_ISA" = aarch64 ] || [ "$ATOMIC_ISA" = x86_64 ]; } && [ "$atomic_sites_seen" -lt "$MIN_ATOMIC_SITES" ]; then
  echo "diffruntime: FAIL — extracted $atomic_sites_seen atomic-instruction site(s) from the oracle's objects, floor is $MIN_ATOMIC_SITES." >&2
  echo "  An emptied atomic-signature extraction passes everything; check ATOMIC_MNEMONICS" >&2
  echo "  (aarch64) or x86AtomicSignature (x86-64), and that otool/objdump are on PATH and" >&2
  echo "  can disassemble these objects." >&2
  bad=1
fi

if [ -s "$work/mod_oracletimeout" ]; then
  echo "diffruntime: FAIL — the pinned stage0 HUNG building a runtime module (corpus reduced, not verified):" >&2
  sed 's/^/  /' "$work/mod_oracletimeout" >&2
  bad=1
fi

if [ -s "$work/mod_oraclecrash" ]; then
  echo "diffruntime: NOTE — the pinned stage0 crashed building a runtime module, no verdict available (#2084):" >&2
  sed 's/^/  /' "$work/mod_oraclecrash" >&2
fi

if [ -s "$work/mod_timeout" ]; then
  echo "diffruntime: FAIL — no verdict building a runtime module (not a match):" >&2
  sed 's/^/  /' "$work/mod_timeout" >&2
  bad=1
fi

sort -u "$work/mod_mismatch" >"$work/mod_mismatch.sorted"

if [ -s "$work/mod_mismatch.sorted" ]; then
  what="object bytes"
  { [ "$ATOMIC_ISA" = aarch64 ] || [ "$ATOMIC_ISA" = x86_64 ]; } && what="atomic-instruction width signature — see the header before assuming this is a real bug"
  echo "diffruntime: FAIL — $(wc -l <"$work/mod_mismatch.sorted" | tr -d ' ') runtime module(s) diverge from the pinned stage0 ($what):" >&2
  sed 's/^/  /' "$work/mod_mismatch.sorted" >&2
  if [ "$ATOMIC_ISA" = aarch64 ] || [ "$ATOMIC_ISA" = x86_64 ]; then
    dtool="otool -tV"; [ "$(uname -s)" = Linux ] && dtool="objdump -d"
    echo "  Compare one with:  \"$ORACLE\" build MODULE -c --freestanding -o /tmp/or.o && $BIT2 build MODULE -c --freestanding -o /tmp/dev.o && diff <($dtool /tmp/or.o) <($dtool /tmp/dev.o)" >&2
  else
    echo "  Rebuild one with:  \"$ORACLE\" build MODULE -c --freestanding -o /tmp/or.o && $BIT2 build MODULE -c --freestanding -o /tmp/dev.o && cmp /tmp/or.o /tmp/dev.o" >&2
  fi
  bad=1
fi

[ "$bad" -ne 0 ] && exit 1

modwhat="byte-identical"
{ [ "$ATOMIC_ISA" = aarch64 ] || [ "$ATOMIC_ISA" = x86_64 ]; } && modwhat="atomic-width-signature-identical"
explained=$(wc -l <"$work/explained.sorted" | tr -d ' ')
echo "diffruntime: PASS — $match/$total runtime file(s) lower identically ($skip skipped, $explained explained); $modmatch/$NMOD runtime module(s) $modwhat ($modskip skipped, object)"
