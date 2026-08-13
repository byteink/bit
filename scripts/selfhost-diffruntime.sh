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
# ## Why object bytes were rejected once, and why that no longer holds
#
# #1859 first proposed object bytes here. The measurement then was
# seed-vs-selfhost: every module differed and the self-hosted output was
# consistently larger (root 147941 vs 171069, gc 50661 vs 57173, sched 29813
# vs 32309, chan 30736 vs 33856) — #1851's backend optimiser gap, not a
# correctness difference — and the conclusion was "object bytes only mean
# something between two builds of the SAME implementation."
#
# That sentence is the argument FOR doing it now: since #1593 the oracle IS
# the same implementation one release back, not `bit-seed`. Measured on `main`
# at `948ec5fd` against the pinned 0.1.11, host target, over the 23 modules
# `scripts/g2archive.sh` builds into `libbitrt.a` (16 platform-free entries
# including the bare `runtime/` dir, + 7 platform pairs — read from there
# below, never copied, so the two lists cannot drift; note #2741's own filing
# miscounted this population as 22):
#
#     23/23 modules byte-identical, 0 diverging (post-#2569)
#
# and it can fail: mutation-tested with `BIT_STAGE0_BIN` pointed at the
# PREVIOUS pin, v0.1.10 — the exact release #2569 repinned away from because
# it emitted a 64-bit atomic through a 32-bit pointer at 38 machine-code sites
# in 6 modules. That run named all 6 by object bytes (runtime, chan, gc, root,
# sched, stw) and exited non-zero; the per-file IR walk above, run in the same
# pass, still named only the 2 files (spinlock.bit, root/maps.bit) it named
# before this ticket — strictly less coverage of a divergence known to be
# real, not "no coverage". Restoring the pinned 0.1.11 oracle returned both
# surfaces to green. See the commit message for both full outputs.
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
# ## Reading a STAGE0-PINLAG verdict (#2937)
#
# A named accept list, defined just above the object-byte comparison below,
# lets a KNOWN and EXPECTED divergence exit 0 without exiting silently: a run
# that hits it prints one `STAGE0-PINLAG: <module> ...` line per accepted
# module and a `diffruntime: STAGE0-PINLAG —` (not `PASS —`) summary line, so
# it cannot be mistaken for a clean run. Any module NOT on that list still
# fails on any divergence, same as before this ticket. See the list itself
# for what it covers and why, and delete it at the next stage0 repin.
#
# Usage: ./make selfhost && bash scripts/selfhost-diffruntime.sh
set -uo pipefail
# shellcheck source=scripts/alarmrun.sh
. "$(dirname -- "$0")/alarmrun.sh"

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
    echo "$f" >>"$work/mismatch"
  fi
done

# --- Whole-module object-byte comparison (#2741) ---
#
# Same taxonomy as the per-file walk above (oracle hang is a FAIL, oracle
# crash is a NOTE, dev hang/crash is a FAIL, dev build failure where the
# oracle succeeded is a mismatch), applied at module instead of file
# granularity. `-c --freestanding -o` with no `--target` compiles for the
# host, matching `PLAT` resolved above.

# --- Stage0 pin-lag accept list (#2937) ---
#
# Relative to stage0 pin 0.1.15. #2929 (arm64 leaf-frame elision,
# compiler/arm64compile.bit, landed c750df13), #2925 (inlined back-edge
# safepoint guard) and #2934 (CFG-aware interval construction for
# mutually-exclusive early-return branches, compiler/codegen.bit) are real
# backend codegen changes in THIS tree; the pinned stage0 predates all three,
# so the OBJECT BYTES these modules compile to now legitimately diverge even
# though nothing here is wrong — the fix being present is exactly what the
# divergence is. It clears itself at the next stage0 repin and is not
# something a code change here can close (#2382's "outpaced oracle" case,
# same shape as the diffir/diffiropt/difftypes family's STAGE0-PINLAG pattern
# proposed in #2718/#2719/#2720).
#
# It is deliberately object-bytes-only, not per-file: the IR walk above
# (`--dump-ir-pre`, pre-optimizer) still agrees byte for byte with the
# oracle on every runtime file. Only the post-optimizer machine code that
# #2929/#2925/#2934 change diverges, which is exactly what this module-level
# comparison and not the file-level one is for.
#
# Named exactly, not by wildcard: an entry here is a specific module this
# divergence is already known to touch. A module NOT listed below still
# fails the run on any divergence, including one of these gaining a sibling
# for a new, unexamined reason.
#
# runtime/rand/darwin (#2934): randomBytesFill (runtime/rand/darwin/random.bit)
# is a chain of "if (cond) { return X }" checks over values it derives from
# each other — exactly the mutually-exclusive-early-return shape #2934 fixes.
# Examined directly: oracle vs dev object bytes for this module differ ONLY in
# which callee-saved GPRs get used (dev: x19-x25, 7 registers; oracle:
# x19-x28, 10) and the control flow is identical instruction for instruction —
# confirmed by disassembling both `_randomBytesFill` bodies side by side.
#
# DELETE THIS LIST AT THE NEXT STAGE0 REPIN (0.1.15 -> whatever pin next
# contains c750df13/#2929 and #2934). A module that still diverges after that
# repin is a real regression, not pin lag, and must be investigated rather
# than re-added here.
PINLAG_MODULES="runtime runtime/alloc runtime/alloc/darwin runtime/auxv runtime/chan runtime/cryptohw runtime/gc runtime/net runtime/net/darwin runtime/park runtime/park/darwin runtime/rand runtime/rand/darwin runtime/root runtime/root/darwin runtime/sched runtime/sched/darwin runtime/shims/scan runtime/stw runtime/syscalls runtime/thread runtime/thread/darwin"

is_pinlag_module() {
  m="$1"
  for p in $PINLAG_MODULES; do
    [ "$p" = "$m" ] && return 0
  done
  return 1
}

objdev="$work/obj_dev"
objor="$work/obj_or"
mkdir -p "$objdev" "$objor"

modmatch=0 modskip=0 modpinlag=0
: >"$work/mod_mismatch"
: >"$work/mod_timeout"
: >"$work/mod_oracletimeout"
: >"$work/mod_oraclecrash"
: >"$work/mod_compared"
: >"$work/mod_pinlag"

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
  if cmp -s "$devobj" "$orobj"; then
    modmatch=$((modmatch + 1))
  elif is_pinlag_module "$dir"; then
    modpinlag=$((modpinlag + 1))
    echo "$dir" >>"$work/mod_pinlag"
    echo "STAGE0-PINLAG: $dir (accepted until stage0 repin past #2929/c750df13, see #2937)"
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

# NO DIVERGENCE IS PERMITTED. Any runtime file whose IR differs from the pinned
# stage0's fails the run. There was an expected-mismatch list so a known
# difference could be written down instead of fixed; its last entry closed and it
# was deleted with its reader (#1883).
#
# The MIN_FILES floor and the REQUIRED list above are a SEPARATE property and
# stay: they prove the run was not vacuous, which an exit code cannot (#1881).
sort -u "$work/mismatch" >"$work/mismatch.sorted"

if [ -s "$work/mismatch.sorted" ]; then
  echo "diffruntime: FAIL — $(wc -l <"$work/mismatch.sorted" | tr -d ' ') file(s) diverge from the pinned stage0:" >&2
  sed 's/^/  /' "$work/mismatch.sorted" >&2
  echo "  Diff one with:  diff <(\"$ORACLE\" --dump-ir-pre FILE) <($BIT2 --dump-ir-pre FILE)" >&2
  bad=1
fi

# --- Object-byte checks (#2741), mirroring the IR-walk checks above ---

if [ "$NMOD" -lt "$MIN_MODULES" ]; then
  echo "diffruntime: FAIL — extracted $NMOD archive module(s) from $GARCHIVE, floor is $MIN_MODULES." >&2
  echo "  An emptied or badly-split module list passes everything; check" >&2
  echo "  PLATFORM_FREE_RELS/PLATFORM_PAIRS there." >&2
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
  echo "diffruntime: FAIL — $(wc -l <"$work/mod_mismatch.sorted" | tr -d ' ') runtime module(s) diverge from the pinned stage0 (object bytes):" >&2
  sed 's/^/  /' "$work/mod_mismatch.sorted" >&2
  echo "  Rebuild one with:  \"$ORACLE\" build MODULE -c --freestanding -o /tmp/or.o && $BIT2 build MODULE -c --freestanding -o /tmp/dev.o && cmp /tmp/or.o /tmp/dev.o" >&2
  bad=1
fi

[ "$bad" -ne 0 ] && exit 1

if [ "$modpinlag" -gt 0 ]; then
  echo "diffruntime: STAGE0-PINLAG — $match/$total runtime file(s) lower identically ($skip skipped); $modmatch/$NMOD runtime module(s) byte-identical, $modpinlag accepted as pin-lag ($modskip skipped, object)"
else
  echo "diffruntime: PASS — $match/$total runtime file(s) lower identically ($skip skipped); $modmatch/$NMOD runtime module(s) byte-identical ($modskip skipped, object)"
fi
