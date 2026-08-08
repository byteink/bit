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
# ## Why IR text and not object bytes
#
# #1859 proposed object bytes as "the strongest available surface". They are not
# usable here. Measured seed-vs-selfhost, every module differs and the
# self-hosted output is consistently larger (root 147941 vs 171069, gc 50661 vs
# 57173, sched 29813 vs 32309, chan 30736 vs 33856). That is #1851, the backend
# optimiser gap, not a correctness difference. Object bytes only mean something
# between two builds of the SAME implementation.
#
# IR text is the right surface anyway for this bug class: a mis-parsed constant
# appears directly in it as `const_float f64 0.5`.
#
# ## Why per-file and not per-module
#
# Not a preference — there is no module-level IR dump. `--dump-ir-pre` reads
# exactly one file (`readDumpSource` in compiler/main.bit calls `readFile` on
# its argument) and lowers it standalone; a directory fails outright:
#
#     bit --dump-ir-pre runtime/gc   -> bit: cannot read runtime/gc   (rc=1)
#     bit --dump-ir-pre runtime/root -> bit: cannot read runtime/root (rc=1)
#
# Teaching it to resolve a directory as a module is a compiler feature, not a
# script; until then, per-file is the whole surface. It happens to cost
# nothing: the walk below skips zero files.
#
# Usage: ./make selfhost && bash scripts/selfhost-diffruntime.sh
set -uo pipefail

# The oracle is the PINNED STAGE0 (previous release), like every other
# differential since #1593. scripts/stage0.sh downloads and DIGEST-VERIFIES it
# and refuses rather than skipping, so a failure here is loud. It also pins
# BIT_STDLIB to the WORKING TREE for both sides — without that this would diff
# two stdlibs instead of two compilers.
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
  a=$(perl -e 'alarm shift; exec @ARGV' "$TIMEOUT" "$ORACLE" --dump-ir-pre "$f" 2>/dev/null)
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

  b=$(perl -e 'alarm shift; exec @ARGV' "$TIMEOUT" "$BIT2" --dump-ir-pre "$f" 2>/dev/null)
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

[ "$bad" -ne 0 ] && exit 1

echo "diffruntime: PASS — $match/$total runtime file(s) lower identically ($skip skipped)"
