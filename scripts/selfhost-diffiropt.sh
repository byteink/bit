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
# A timeout is likewise not evidence. A file whose `bit` run is killed by the
# alarm is reported separately and fails the gate, rather than being scored as a
# mismatch that happens to sit in the expected set.
#
# Usage: ./make selfhost && bash scripts/selfhost-diffiropt.sh
set -uo pipefail

# The oracle is the PINNED STAGE0 (previous release), not the retired Zig seed
# (#1593). scripts/stage0.sh downloads and DIGEST-VERIFIES it, and refuses rather
# than skipping, so a failure here is loud. What a green run asserts changed with
# it: "unchanged versus the last release", not "two implementations agree" —
# docs/release/bootstrap.md §4/§5.
ORACLE="$(sh scripts/stage0.sh)" || exit 2
BIT2=bit-out/bin/bit
TIMEOUT=${DIFFIROPT_TIMEOUT:-20}

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

for f in $(find stdlib examples tests/cases tests/imports -name '*.bit' | sort); do
  want=$("$ORACLE" --dump-ir "$f" 2>/dev/null) || { skip=$((skip + 1)); continue; }
  [ -z "$want" ] && { skip=$((skip + 1)); continue; }

  b2=$(perl -e 'alarm shift; exec @ARGV' "$TIMEOUT" "$BIT2" --dump-ir "$f" 2>/dev/null)
  rc=$?
  # >=128 is death by signal, i.e. the alarm fired (or bit crashed outright).
  # Either way the run produced no verdict, so it must not be scored as one.
  if [ "$rc" -ge 128 ]; then
    echo "$f" >>"$work/timeout"
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

echo "IR (post-opt) differential: MATCH=$match MISMATCH=$mismatch TIMEOUT=$timeouts SKIP(lower/check-err)=$skip"

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
    diff <(canon_ir_ids "$("$ORACLE" --dump-ir "$f" 2>/dev/null)") \
         <(canon_ir_ids "$(perl -e 'alarm shift; exec @ARGV' "$TIMEOUT" "$BIT2" --dump-ir "$f" 2>/dev/null)") | head -20
  done
  status=1
fi

if [ -s "$work/timeout" ]; then
  echo
  echo "INVALID: $timeouts file(s) timed out after ${TIMEOUT}s — no verdict, not a match:"
  while read -r f; do echo "  timeout: $f"; done <"$work/timeout"
  status=1
fi

[ "$status" -eq 0 ] && { echo; echo "diffiropt: every file's post-opt IR is identical to the pinned stage0's."; }
exit "$status"
