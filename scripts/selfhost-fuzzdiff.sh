#!/usr/bin/env bash
# Self-host front-end fuzz differential (#1332/#363): mutate every corpus `.bit`
# by truncating it at each line boundary, then diff `--dump-diags` between the
# Zig seed and `bit2`. Truncation is the cheapest high-value fuzz — it strands
# strings, block comments, and declarations mid-construct, exercising the
# unterminated/expected-token diagnostics that valid files never reach.
#
# Two invariants:
#   1. bit2 must not hang or crash on any input (each run is alarm-guarded).
#   2. bit2's rendered front-end diagnostics must be byte-identical to the seed.
#
# Usage: zig build selfhost && bash scripts/selfhost-fuzzdiff.sh
# Prints MATCH/MISMATCH/CRASH/TIMEOUT totals and the first divergence.
#
# Exit codes (matching x64gate.sh / selfhost-diffsafepoints.sh):
#   0  every truncation compared and agreed
#   1  real failure: a MISMATCH, or bit2 CRASHED (invariant 1)
#   2  could not decide: a missing compiler, or a run timed out and was never
#      compared. Not a pass — see #1524/#1525.
set -u
# The oracle is the PINNED STAGE0 (previous release), not the retired Zig seed
# (#1593). scripts/stage0.sh downloads and DIGEST-VERIFIES it, and refuses rather
# than skipping, so a failure here is loud. What a green run asserts changed with
# it: "unchanged versus the last release", not "two implementations agree" —
# docs/release/bootstrap.md §4/§5.
ORACLE="$(sh scripts/stage0.sh)" || exit 2
BIT2=zig-out/bin/bit

# A missing compiler must ABORT, never score a vacuous green (#1514). `run` execs
# through perl, and a FAILED exec still exits 0 — so an absent compiler yields
# rc=0 with seed == b2 == "", and every truncation scores MATCH. Measured: 6642
# MATCH, exit 0, no compiler on disk. Exit 2 to stay distinct from a divergence.
for bin in "$ORACLE" "$BIT2"; do
  [ -x "$bin" ] || { echo "fuzzdiff: missing $bin — run: zig build selfhost" >&2; exit 2; }
done

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
# (128+SIGALRM) iff the run timed out twice.
run() {
  local out rc
  out=$( ( perl -e 'alarm shift; exec @ARGV' "$TIMEOUT_S" "$@" 2>/dev/null ) 2>/dev/null )
  rc=$?
  if [ "$rc" -eq 142 ]; then
    out=$( ( perl -e 'alarm shift; exec @ARGV' "$TIMEOUT_S" "$@" 2>/dev/null ) 2>/dev/null )
    rc=$?
  fi
  printf '%s' "$out"
  return "$rc"
}

match=0 mismatch=0 timeout=0 crash=0 firstbad="" firsthang=""
for f in $(find stdlib examples tests/cases tests/imports -name '*.bit' | sort); do
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
    seed=$(run "$ORACLE" --dump-diags "$TMP/m.bit"); src=$?
    b2=$(run "$BIT2" --dump-diags "$TMP/m.bit"); brc=$?
    if [ "$src" -eq 142 ] || [ "$brc" -eq 142 ]; then
      # Undecided: this truncation was never compared. Counted, never a MATCH.
      timeout=$((timeout + 1))
      [ -z "$firsthang" ] && firsthang="$f@$n(SIGALRM after ${TIMEOUT_S}s x2, seed=$src bit2=$brc)"
    elif [ "$brc" -ne 0 ] || [ "$src" -ne 0 ]; then
      # A non-alarm non-zero exit is a CRASH: invariant 1 says bit2 must not
      # crash on any input. A real failure, distinct from an undecided timeout.
      crash=$((crash + 1))
      [ -z "$firstbad" ] && firstbad="$f@$n(crash seed=$src bit2=$brc)"
    elif [ "$seed" = "$b2" ]; then
      match=$((match + 1))
    else
      mismatch=$((mismatch + 1))
      [ -z "$firstbad" ] && firstbad="$f@$n"
    fi
    n=$((n + step))
  done
done
echo "fuzz differential: MATCH=$match MISMATCH=$mismatch CRASH=$crash TIMEOUT=$timeout"
if [ -n "$firstbad" ]; then
  file=${firstbad%@*}; rest=${firstbad#*@}; nn=${rest%%(*}
  echo "first divergence: $firstbad"
  head -n "$nn" "$file" > "$TMP/m.bit"
  diff <(run "$ORACLE" --dump-diags "$TMP/m.bit") <(run "$BIT2" --dump-diags "$TMP/m.bit") | head -20
  exit 1
fi
# A timeout decided nothing — it is neither a match nor a divergence. Exit 2
# (could-not-decide) keeps it visible without claiming a divergence that was
# never observed, matching the convention in x64gate.sh / diffsafepoints.sh.
if [ "$timeout" -gt 0 ]; then
  echo "first timeout: $firsthang"
  echo "UNDECIDED: $timeout truncation(s) timed out after ${TIMEOUT_S}s x2 and were NOT compared."
  echo "           Not a pass. Re-run on a quieter host, or raise TIMEOUT_S."
  echo "           If it reproduces on an idle host, that is a real hang — invariant 1 is broken."
  exit 2
fi
exit 0
