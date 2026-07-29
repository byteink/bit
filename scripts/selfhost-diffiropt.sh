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
# So the mismatching paths are compared against the checked-in expected set in
# `tests/selfhost-iropt-gaps.txt`, and the gate fails when a file ENTERS or
# LEAVES it. A swap at constant count is a failure, which is the whole point.
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
GAPS=tests/selfhost-iropt-gaps.txt
TIMEOUT=${DIFFIROPT_TIMEOUT:-20}

# shellcheck source=scripts/selfhost-ir-canon.sh
. "$(dirname "$0")/selfhost-ir-canon.sh"

for bin in "$ORACLE" "$BIT2"; do
  [ -x "$bin" ] || { echo "diffiropt: missing $bin — run: ./make selfhost" >&2; exit 2; }
done
[ -f "$GAPS" ] || { echo "diffiropt: missing expected-gap list $GAPS" >&2; exit 2; }

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
# Expected set: `path  # reason`, blank lines and full-line comments ignored.
sed -e 's/#.*//' -e 's/[[:space:]]*$//' "$GAPS" | grep -v '^$' | sort >"$work/expected"

mismatch=$(wc -l <"$work/mismatch" | tr -d ' ')
timeouts=$(wc -l <"$work/timeout" | tr -d ' ')
expected=$(wc -l <"$work/expected" | tr -d ' ')

echo "IR (post-opt) differential: MATCH=$match MISMATCH=$mismatch (expected $expected) TIMEOUT=$timeouts SKIP(lower/check-err)=$skip"

comm -23 "$work/mismatch" "$work/expected" >"$work/entered"
comm -13 "$work/mismatch" "$work/expected" >"$work/left"
comm -12 "$work/mismatch" "$work/expected" >"$work/held"

if [ -s "$work/held" ]; then
  echo
  echo "known gaps still diverging (expected):"
  while read -r f; do
    reason=$(grep -F "$f" "$GAPS" | sed -e 's/^[^#]*#[[:space:]]*//' | head -1)
    echo "  $f — ${reason:-no reason recorded}"
  done <"$work/held"
fi

status=0

if [ -s "$work/entered" ]; then
  echo
  echo "REGRESSION: $(wc -l <"$work/entered" | tr -d ' ') file(s) newly diverge and are NOT in $GAPS:"
  while read -r f; do echo "  entered: $f"; done <"$work/entered"
  # Bounded evidence for the first few, so the failure is actionable in one read.
  head -3 "$work/entered" | while read -r f; do
    echo
    echo "--- diff (stage0 vs bit, \$t<id> canonicalized): $f"
    diff <(canon_ir_ids "$("$ORACLE" --dump-ir "$f" 2>/dev/null)") \
         <(canon_ir_ids "$(perl -e 'alarm shift; exec @ARGV' "$TIMEOUT" "$BIT2" --dump-ir "$f" 2>/dev/null)") | head -20
  done
  status=1
fi

if [ -s "$work/left" ]; then
  echo
  echo "STALE: $(wc -l <"$work/left" | tr -d ' ') expected gap(s) no longer diverge — delete them from $GAPS:"
  while read -r f; do echo "  closed: $f"; done <"$work/left"
  # Failing on a closed gap is deliberate: it is what makes a swap at constant
  # count impossible to miss.
  status=1
fi

if [ -s "$work/timeout" ]; then
  echo
  echo "INVALID: $timeouts file(s) timed out after ${TIMEOUT}s — no verdict, not a match:"
  while read -r f; do echo "  timeout: $f"; done <"$work/timeout"
  status=1
fi

[ "$status" -eq 0 ] && { echo; echo "diffiropt: mismatch set matches $GAPS exactly."; }
exit "$status"
