#!/usr/bin/env bash
# Self-host front-end fuzz differential (#1332/#363): mutate every corpus `.bit`
# by truncating it at each line boundary, then diff `--dump-diags` between the
# oracle and this tree's `bit`. Truncation is the cheapest high-value fuzz — it strands
# strings, block comments, and declarations mid-construct, exercising the
# unterminated/expected-token diagnostics that valid files never reach.
#
# Two invariants:
#   1. bit2 must not hang or crash on any input (each run is alarm-guarded).
#   2. bit2's rendered front-end diagnostics must be byte-identical to the seed.
#
# Usage: ./make selfhost && bash scripts/selfhost-fuzzdiff.sh
# Prints MATCH/MISMATCH/CRASH/TIMEOUT totals and the first divergence.
#
# Exit codes (matching x64gate.sh / selfhost-diffsafepoints.sh):
#   0  every truncation compared and agreed
#   1  real failure: a MISMATCH, or bit2 CRASHED (invariant 1)
#   2  could not decide: a missing compiler, a run timed out and was never
#      compared, or a divergence did not reproduce on an immediate re-run
#      (UNSTABLE, #6355). Not a pass — see #1524/#1525.
set -u
# shellcheck source=scripts/alarmrun.sh
. "$(dirname -- "$0")/alarmrun.sh"
# shellcheck source=scripts/diffexit.sh
. "$(dirname -- "$0")/diffexit.sh"
# shellcheck source=scripts/selfhost-ir-signatures.sh
. "$(dirname -- "$0")/selfhost-ir-signatures.sh"

# The oracle is the PINNED STAGE0: the previous release, i.e. an EARLIER VERSION
# OF THIS SAME COMPILER — which is exactly what limits the claim below.
# scripts/stage0.sh downloads and DIGEST-VERIFIES it, and refuses rather
# than skipping, so a failure here is loud. What a green run asserts changed with
# it: "unchanged versus the last release", not "two implementations agree" —
# docs/release/bootstrap.md §4/§5.
ORACLE="$(sh scripts/stage0.sh)" || exit 2
BIT2=bit-out/bin/bit

# A missing compiler must ABORT, never score a vacuous green (#1514). `run` execs
# through perl, and a FAILED exec still exits 0 — so an absent compiler yields
# rc=0 with seed == b2 == "", and every truncation scores MATCH. Measured: 6642
# MATCH, exit 0, no compiler on disk. Exit 2 to stay distinct from a divergence.
diffrequire fuzzdiff "$ORACLE" "$BIT2"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# The alarm is a HANG guard, not a performance budget (#1525). The old fixed 5s
# fired on healthy runs under parallel load — measured worst legitimate case
# (stdlib/crypto/bcryptboxes.bit) is 0.45s, so nothing real was ever near it;
# the kills were descheduled processes, not hangs. Raising the number alone just
# moves the drift, so a trip is RETRIED ONCE: a hang is deterministic and trips
# twice, a load artifact does not. TIMEOUT_S overrides for a slower host.
TIMEOUT_S=${TIMEOUT_S:-60}

# Alarm-guarded run. The exit status is LOAD-BEARING — any harness copied from
# this script that drops `$?` scores a timed-out run as a MISMATCH instead, which
# produced two false "still broken" readings during #1515. Returns 142
# (128+SIGALRM) iff the run timed out twice. Retry-once-on-stall is
# scripts/alarmrun.sh's alarmrun_retry_cap (#3490); no persistent build
# artifact to clean between attempts here, so its outfile arg is "".
#
# The compared payload never leaves its capture FILE. It used to be read back
# into a variable and `printf`ed into the caller's `$(...)`; a signal landing on
# that write (the alarmrun SIGALRM machinery, under fleet load) truncated one
# side's payload and scored a false MISMATCH (#6355: "printf: write error:
# Interrupted system call", byte-identical on re-run). Now the caller compares
# the two files with `cmp`, and only this function's exit status is returned.
#
# <capture> used to be the `$(...)` command substitution wrapped around BOTH
# attempts — one sink opened once for the whole retry, so a stalled first
# attempt's partial bytes survived as a prefix inside the retried attempt's
# compared payload (#3478/#4208, same shape as #4196/#4205). alarmrun_retry_cap
# truncates a per-call file before EACH attempt instead, so the file holds
# exactly one attempt's bytes.
#   run <capfile> <cmd...>   -> rc of <cmd>, or 142 iff it stalled twice
run() {
  local cap=$1 side
  local TIMEOUT="$TIMEOUT_S"
  shift
  [ "$1" = "$ORACLE" ] && side=ORACLE || side=BIT2
  alarmrun_retry_cap "$side" "" "$cap" "$@"
}

# Both sides of one truncation into $TMP/seed.out and $TMP/b2.out; the exit
# statuses land in $src and $brc (BOTH are captured, see the loop below).
runboth() {
  run "$TMP/seed.out" "$ORACLE" --dump-diags "$TMP/m.bit"; src=$?
  run "$TMP/b2.out" "$BIT2" --dump-diags "$TMP/m.bit"; brc=$?
}

# sameout -> 0 identical, 1 differ, 2 a capture could not be read. `cmp` is the
# only judge of the payload; status 2 is a harness fault, never a divergence.
sameout() {
  cmp -s "$TMP/seed.out" "$TMP/b2.out"
}

match=0 mismatch=0 explained=0 timeout=0 crash=0 unstable=0 firstbad="" firsthang="" firstunstable=""
for f in $(find stdlib examples _tests_/cases _tests_/imports -name '*.bit' | sort); do
  lines=$(wc -l < "$f")
  # Cap truncation points per file (Power-of-10: bounded work per input).
  step=$(( lines / 20 + 1 ))
  n=1
  while [ "$n" -le "$lines" ]; do
    head -n "$n" "$f" > "$TMP/m.bit"
    # BOTH statuses are captured. The seed's used not to be, so a timed-out
    # ORACLE scored a MISMATCH against a healthy bit2 (false red) — or, when the
    # truncation legitimately yields no diagnostics, "" = "" scored a MATCH
    # (false green). A comparison is only meaningful once both sides completed.
    runboth
    if [ "$src" -eq 142 ] || [ "$brc" -eq 142 ]; then
      # Undecided: this truncation was never compared. Counted, never a MATCH.
      timeout=$((timeout + 1))
      [ -z "$firsthang" ] && firsthang="$f@$n(SIGALRM after ${TIMEOUT_S}s x2, seed=$src bit2=$brc)"
    elif [ "$src" -ne 0 ] && [ "$brc" -eq 0 ] && [ -n "$(explainMismatch "$(cat "$TMP/seed.out")" "$(cat "$TMP/b2.out")" diags "$TMP/m.bit")" ]; then
      # The ORACLE crashed and bit2 did not, and the pair matches a declared
      # `diags` signature (scripts/selfhost-ir-signatures.sh): a panic in the
      # pinned release that this tree already fixed. Invariant 1 is about
      # bit2, so it is untouched; a bit2 crash never reaches this arm.
      explained=$((explained + 1))
    elif [ "$brc" -ne 0 ] || [ "$src" -ne 0 ]; then
      # A non-alarm non-zero exit is a CRASH: invariant 1 says bit2 must not
      # crash on any input. A real failure, distinct from an undecided timeout.
      crash=$((crash + 1))
      [ -z "$firstbad" ] && firstbad="$f@$n(crash seed=$src bit2=$brc)"
    else
      sameout; same=$?
      if [ "$same" -ne 0 ]; then
        # A divergence is only real if it REPRODUCES: a second pair of fresh
        # captures that agrees (or cannot be read) decided nothing (#6355).
        runboth
        if [ "$src" -eq 0 ] && [ "$brc" -eq 0 ]; then sameout; same=$?; else same=2; fi
        [ "$same" -eq 0 ] && same=2
      fi
      case "$same" in
        0) match=$((match + 1)) ;;
        1) if [ -n "$(explainMismatch "$(cat "$TMP/seed.out")" "$(cat "$TMP/b2.out")" diags "$TMP/m.bit")" ]; then
             # A declared `diags` signature (scripts/selfhost-ir-signatures.sh):
             # the oracle predates syntax this truncation still contains.
             explained=$((explained + 1))
           else
             mismatch=$((mismatch + 1))
             [ -z "$firstbad" ] && firstbad="$f@$n"
           fi ;;
        *) unstable=$((unstable + 1))
           [ -z "$firstunstable" ] && firstunstable="$f@$n" ;;
      esac
    fi
    n=$((n + step))
  done
done
echo "fuzz differential: MATCH=$match MISMATCH=$mismatch EXPLAINED=$explained CRASH=$crash TIMEOUT=$timeout UNSTABLE=$unstable"
if [ -n "$firstbad" ]; then
  file=${firstbad%@*}; rest=${firstbad#*@}; nn=${rest%%(*}
  echo "first divergence: $firstbad"
  head -n "$nn" "$file" > "$TMP/m.bit"
  runboth
  diff "$TMP/seed.out" "$TMP/b2.out" | head -20
  exit 1
fi
# A timeout decided nothing — it is neither a match nor a divergence. Exit 2
# (could-not-decide) keeps it visible without claiming a divergence that was
# never observed, matching the convention in x64gate.sh / diffsafepoints.sh.
if [ "$unstable" -gt 0 ]; then
  echo "first unstable: $firstunstable"
  echo "UNDECIDED: $unstable truncation(s) diverged once, then agreed (or could not be read) on an immediate re-run."
  echo "           Not a pass, and not a divergence: the capture or the host was interrupted (#6355)."
  exit 2
fi
if [ "$timeout" -gt 0 ]; then
  echo "first timeout: $firsthang"
  echo "UNDECIDED: $timeout truncation(s) timed out after ${TIMEOUT_S}s x2 and were NOT compared."
  echo "           Not a pass. Re-run on a quieter host, or raise TIMEOUT_S."
  echo "           If it reproduces on an idle host, that is a real hang — invariant 1 is broken."
  exit 2
fi
exit 0
