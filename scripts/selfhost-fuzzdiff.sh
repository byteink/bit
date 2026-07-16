#!/usr/bin/env bash
# Self-host front-end fuzz differential (#1332/#363): mutate every corpus `.bit`
# by truncating it at each line boundary, then diff `--dump-diags` between the
# Zig seed and `bitc2`. Truncation is the cheapest high-value fuzz — it strands
# strings, block comments, and declarations mid-construct, exercising the
# unterminated/expected-token diagnostics that valid files never reach.
#
# Two invariants:
#   1. bitc2 must not hang or crash on any input (each run is alarm-guarded).
#   2. bitc2's rendered front-end diagnostics must be byte-identical to the seed.
#
# Usage: zig build && zig build selfhost && bash scripts/selfhost-fuzzdiff.sh
# Prints MATCH/MISMATCH/TIMEOUT totals and the first divergence.
set -u
SEED=zig-out/bin/bitc
BITC2=zig-out/bin/bitc2
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
# Alarm-guarded run: kills a hung child after 5s (macOS has no `timeout`).
run() { perl -e 'alarm 5; exec @ARGV' "$@" 2>/dev/null; }

match=0 mismatch=0 timeout=0 firstbad=""
for f in $(find stdlib examples tests/cases tests/imports -name '*.bit' | sort); do
  lines=$(wc -l < "$f")
  # Cap truncation points per file (Power-of-10: bounded work per input).
  step=$(( lines / 20 + 1 ))
  n=1
  while [ "$n" -le "$lines" ]; do
    head -n "$n" "$f" > "$TMP/m.bit"
    seed=$(run "$SEED" --dump-diags "$TMP/m.bit")
    b2=$(run "$BITC2" --dump-diags "$TMP/m.bit"); rc=$?
    if [ "$rc" -ne 0 ]; then
      timeout=$((timeout + 1))
      [ -z "$firstbad" ] && firstbad="$f@$n(hang/crash rc=$rc)"
    elif [ "$seed" = "$b2" ]; then
      match=$((match + 1))
    else
      mismatch=$((mismatch + 1))
      [ -z "$firstbad" ] && firstbad="$f@$n"
    fi
    n=$((n + step))
  done
done
echo "fuzz differential: MATCH=$match MISMATCH=$mismatch TIMEOUT/CRASH=$timeout"
if [ -n "$firstbad" ]; then
  file=${firstbad%@*}; rest=${firstbad#*@}; nn=${rest%%(*}
  echo "first divergence: $firstbad"
  head -n "$nn" "$file" > "$TMP/m.bit"
  diff <(run "$SEED" --dump-diags "$TMP/m.bit") <(run "$BITC2" --dump-diags "$TMP/m.bit") | head -20
  exit 1
fi
