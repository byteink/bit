#!/usr/bin/env bash
# Self-host POST-opt IR differential (#1339): diff `bit --dump-ir` (optimized)
# against the pinned stage0's optimized `--dump-ir` over the corpus. Tracks optimizer
# coverage — MATCH grows as fold/DCE/inline passes land. Mirror of
# selfhost-diffir.sh but for the post-optimizer surface.
#
# ## Why this gates on the SET, not the count (#1478)
#
# It used to print `MISMATCH=3`, name only the first offender, and exit 0 — so
# it could not fail under any circumstance, and its output was quoted as
# verification anyway. Two separate defects: no verdict, and a count where a set
# was needed. A count is not a set: MATCH could grow while MISMATCH held steady
# because a known gap closed and a fresh regression opened in its place, and the
# two runs would read identically.
#
# So every mismatching path is NAMED, and any mismatch at all fails the gate.
# There was an expected-mismatch list for a while, so a known difference could be
# written down instead of fixed; its last entry closed and it was deleted with its
# reader (#1883). Nothing is permitted to differ now.
#
# A timeout is likewise not evidence. A file whose run is killed by the alarm is
# reported separately and fails the gate, rather than being scored as a mismatch
# that happens to sit in the expected set.
#
# ## The bound, and why BOTH sides carry it (#2070)
#
# The alarm is a HANG guard, not a performance budget, so it must sit well above
# the slowest legitimate file rather than near it. It was 20s while the corpus's
# worst case — tests/imports/cryptomldsa/main.bit — needed 25.20s wall and ~14s
# CPU on THIS tree and 21.86s on the oracle. That is not a margin; the gate went
# red with MISMATCH=0 whenever the box was busy, which is the shape CLAUDE.md
# warns about ("do not read a TIMED OUT as a hang until you have timed the
# program standalone"). 300s is ~12x the slowest observed file, in the spirit of
# the suite's own 900s-against-158s choice from #1637/#1652.
#
# The oracle used to run UNBOUNDED, so a hung stage0 wedged this script forever
# with no message — and merging that into SKIP would have been worse, since a
# skip means "the oracle legitimately could not lower this" and silently
# shrinking the corpus is how a gate stops asserting anything. Both sides are
# bounded, and an oracle timeout is its own reported outcome.
#
# Usage: ./make selfhost && bash scripts/selfhost-diffiropt.sh
set -uo pipefail

# The oracle is the PINNED STAGE0: the previous release, i.e. an EARLIER VERSION
# OF THIS SAME COMPILER — which is exactly what limits the claim below.
# scripts/stage0.sh downloads and DIGEST-VERIFIES it, and refuses rather
# than skipping, so a failure here is loud. What a green run asserts changed with
# it: "unchanged versus the last release", not "two implementations agree" —
# docs/release/bootstrap.md §4/§5.
ORACLE="$(sh scripts/stage0.sh)" || exit 2
BIT2=bit-out/bin/bit
TIMEOUT=${DIFFIROPT_TIMEOUT:-300}

# Why a child died, for the report. 128+N is death by signal N; 14 is the alarm
# this script set, so that alone is a timeout and every other signal is a crash.
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

# shellcheck source=scripts/selfhost-ir-canon.sh
. "$(dirname "$0")/selfhost-ir-canon.sh"

for bin in "$ORACLE" "$BIT2"; do
  [ -x "$bin" ] || { echo "diffiropt: missing $bin — run: ./make selfhost" >&2; exit 2; }
done

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

match=0 skip=0
: >"$work/mismatch"
: >"$work/timeout"
: >"$work/oracletimeout"
: >"$work/oraclecrash"

for f in $(find stdlib examples tests/cases tests/imports -name '*.bit' | sort); do
  # The oracle is bounded too, and its timeout is NOT a skip: a skip means the
  # oracle could not lower or check the file, which is a real and expected
  # outcome, while a hang is a broken stage0 that must be named (#2070).
  want=$(perl -e 'alarm shift; exec @ARGV' "$TIMEOUT" "$ORACLE" --dump-ir "$f" 2>/dev/null)
  rc=$?
  if [ "$rc" -eq 142 ]; then
    echo "$f${sep}$(whydied "$rc")" >>"$work/oracletimeout"
    continue
  fi
  if [ "$rc" -ge 128 ]; then
    echo "$f${sep}$(whydied "$rc")" >>"$work/oraclecrash"
    continue
  fi
  [ "$rc" -ne 0 ] && { skip=$((skip + 1)); continue; }
  [ -z "$want" ] && { skip=$((skip + 1)); continue; }

  b2=$(perl -e 'alarm shift; exec @ARGV' "$TIMEOUT" "$BIT2" --dump-ir "$f" 2>/dev/null)
  rc=$?
  # >=128 is death by signal, and WHICH signal is not a detail. 142 is our own
  # SIGALRM — a timeout. Anything else is the compiler dying, and reporting a
  # SIGSEGV as "timed out after ${TIMEOUT}s" sends the reader after a performance
  # problem that does not exist. Either way there is no verdict (#2070).
  if [ "$rc" -ge 128 ]; then
    echo "$f${sep}$(whydied "$rc")" >>"$work/timeout"
    continue
  fi

  # $t<id> suffixes are interning-order artifacts, not structural — canonicalize
  # before comparing (see selfhost-ir-canon.sh). Raw compare first: the
  # overwhelming majority of files already match byte-for-byte, so skip the
  # two awk forks unless the raw strings actually differ.
  if [ "$want" = "$b2" ] || [ "$(canon_ir_ids "$want")" = "$(canon_ir_ids "$b2")" ]; then
    match=$((match + 1))
  else
    echo "$f" >>"$work/mismatch"
  fi
done

sort -o "$work/mismatch" "$work/mismatch"

mismatch=$(wc -l <"$work/mismatch" | tr -d ' ')
timeouts=$(wc -l <"$work/timeout" | tr -d ' ')
oracletimeouts=$(wc -l <"$work/oracletimeout" | tr -d ' ')
oraclecrashes=$(wc -l <"$work/oraclecrash" | tr -d ' ')

echo "IR (post-opt) differential: MATCH=$match MISMATCH=$mismatch NO-VERDICT=$timeouts ORACLE-TIMEOUT=$oracletimeouts ORACLE-CRASH=$oraclecrashes SKIP(lower/check-err)=$skip"

# A RUN THAT COMPARED NOTHING IS NOT A PASS (#1881). Two ways to get here having
# verified nothing, and both leave `mismatch` and `timeout` empty, so every check
# below passes and the success line claims that every file's IR is identical:
#
#   - the corpus enumerated no files at all — a renamed or moved directory in the
#     `find` list above, which `find` reports on stderr and then carries on past;
#   - every file was skipped, because the oracle could not lower or check a single
#     one. A stage0 that is broken for the whole corpus scores as agreement.
#
# The distinction from the count-vs-set argument in the header is that this is not
# a threshold on how much matched. Zero is the one count that means the gate did
# not run, so it is the one count worth asserting.
if [ "$match" -eq 0 ]; then
  echo
  echo "INVALID: compared 0 files (skipped $skip) — the corpus or the oracle is broken. Nothing was verified." >&2
  exit 1
fi

status=0

# NO DIVERGENCE IS PERMITTED. There is no expected-mismatch list and no way to
# add one (#1883): a file whose IR differs from the pinned stage0's fails the
# run. The list existed so a known difference could be written down instead of
# fixed; its last entry closed with #1882.
if [ -s "$work/mismatch" ]; then
  echo
  echo "REGRESSION: $mismatch file(s) diverge from the pinned stage0:"
  while read -r f; do echo "  mismatch: $f"; done <"$work/mismatch"
  # Bounded evidence for the first few, so the failure is actionable in one read.
  head -3 "$work/mismatch" | while read -r f; do
    echo
    echo "--- diff (stage0 vs bit, \$t<id> canonicalized): $f"
    # Bounded on BOTH sides, exactly as the compare loop runs them — an unbounded
    # oracle here would hang the failure report of a run that already failed.
    diff <(canon_ir_ids "$(perl -e 'alarm shift; exec @ARGV' "$TIMEOUT" "$ORACLE" --dump-ir "$f" 2>/dev/null)") \
         <(canon_ir_ids "$(perl -e 'alarm shift; exec @ARGV' "$TIMEOUT" "$BIT2" --dump-ir "$f" 2>/dev/null)") | head -20
  done
  status=1
fi

if [ -s "$work/timeout" ]; then
  echo
  echo "INVALID: $timeouts file(s) produced no verdict — not a match:"
  while read -r f; do echo "  $f"; done <"$work/timeout"
  status=1
fi

# Reported apart from ours because it means something different: the PINNED
# oracle hung, so the corpus shrank rather than this tree misbehaving. Merging
# it into SKIP would have hidden that behind a number that is supposed to mean
# "the oracle declined this file", which is how a gate quietly stops asserting.
if [ -s "$work/oracletimeout" ]; then
  echo
  echo "INVALID: the pinned stage0 HUNG on $oracletimeouts file(s) — corpus reduced, not verified:"
  while read -r f; do echo "  $f"; done <"$work/oracletimeout"
  status=1
fi

# AN ORACLE CRASH IS REPORTED BUT DOES NOT FAIL, and the asymmetry with the hang
# above is deliberate. The oracle is a PUBLISHED, IMMUTABLE binary: no change to
# this tree can stop it faulting, so failing here would leave the gate red until
# the next pin move — the "known-and-ignored red gets routed around" hazard
# #1895 is about. A hang is different: it means the run could not complete in
# bounded time and may be masking anything, so it still fails.
#
# What this is NOT is the expected-mismatch list #1883 deleted. That recorded
# DIVERGENCES between the two compilers and let them be written down instead of
# fixed. This records a defect in the oracle itself, names the file on EVERY run
# rather than hiding it, and asserts nothing about agreement. Before #2070 the
# same crash was an anonymous +1 to SKIP and went unnoticed for months (#2084).
if [ -s "$work/oraclecrash" ]; then
  echo
  echo "NOTE: the pinned stage0 crashed on $oraclecrashes file(s) — no verdict available, tracked as #2084:"
  while read -r f; do echo "  $f"; done <"$work/oraclecrash"
fi

[ "$status" -eq 0 ] && { echo; echo "diffiropt: every file's post-opt IR is identical to the pinned stage0's."; }
exit "$status"
