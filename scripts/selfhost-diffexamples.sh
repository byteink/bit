#!/usr/bin/env bash
# Self-host BEHAVIOURAL differential (#1346): build every example with both
# compilers and compare what the programs actually PRINT, not what the compiler
# dumps.
#
# The --dump-types/--dump-ir differentials compare the compiler's own view of a
# program, so a bug that is consistent between check and lower is invisible to
# them: bit2 once typed `mapped<i64,i64>(...)`'s result as `[]T` with `T`
# unsubstituted, emitted a binary happily, and printed 0 instead of 56. Only
# running the output catches that class. This is the end-to-end guard.
#
# A REFUSED example is a known lowering gap (main.bit's stub guard declining to
# emit a binary): an honest "not ported yet", not a miscompile. It is therefore
# tolerated — but only up to a PINNED COUNT (#1424).
#
# Tolerating refusals unconditionally is what a mid-flight port relies on, and
# is also how a real regression hides: #1419 reverted the selfhost half of its
# own variadic fix and the only signal was PASS dropping 42->41 with the script
# still exiting 0. That conflates "not ported yet" with "regressed", for every
# example. So the count is pinned and compared EXACTLY:
#
#   - refusals ABOVE the pin  -> a construct that used to lower no longer does.
#   - refusals BELOW the pin  -> good news, but the pin must be tightened in the
#                                same commit, or it silently re-opens headroom
#                                for a future regression to hide in.
#
# Landing a port that refuses mid-flight (as #1364 does) means raising the pin
# deliberately, in the commit that causes it — which is the point: a refusal
# becomes a reviewed decision instead of an unasserted number scrolling past.
#
# Usage: zig build && zig build selfhost && bash scripts/selfhost-diffexamples.sh
set -u
SEED=zig-out/bin/bit-seed
BIT2=${BIT2:-zig-out/bin/bit}
# The pin. Override only to explore locally; the committed value is the gate.
EXPECTED_REFUSED=${EXPECTED_REFUSED:-0}
# Network-dependent examples: they talk to the outside world, so their output is
# not a function of the compiler alone.
SKIP="h3fetch httpserver httpsserver http2server tlsclient"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

pass=0 diff=0 refused=0 seedfail=0 skipped=0
for d in examples/*/; do
  n=$(basename "$d")
  case " $SKIP " in *" $n "*) skipped=$((skipped + 1)); continue;; esac

  if ! "$SEED" build "$d" -o "$TMP/seed_$n" >/dev/null 2>&1; then
    echo "SEED-FAIL $n"
    seedfail=$((seedfail + 1))
    continue
  fi
  if ! "$BIT2" build "$d" -o "$TMP/b2_$n" >"$TMP/err_$n" 2>&1; then
    echo "REFUSED   $n: $(tail -1 "$TMP/err_$n")"
    refused=$((refused + 1))
    continue
  fi

  # alarm: a miscompile can hang rather than print, and a hung example must not
  # hang the differential. `timeout` is not on macOS, perl is.
  perl -e 'alarm 30; exec @ARGV' "$TMP/seed_$n" >"$TMP/o_seed_$n" 2>&1
  se=$?
  perl -e 'alarm 30; exec @ARGV' "$TMP/b2_$n" >"$TMP/o_b2_$n" 2>&1
  b2=$?

  if [ "$se" != "$b2" ] || ! cmp -s "$TMP/o_seed_$n" "$TMP/o_b2_$n"; then
    echo "DIFF      $n (exit seed=$se bit2=$b2)"
    command diff "$TMP/o_seed_$n" "$TMP/o_b2_$n" | head -6
    diff=$((diff + 1))
    continue
  fi
  pass=$((pass + 1))
done

echo "example differential: PASS=$pass DIFF=$diff REFUSED=$refused (pinned $EXPECTED_REFUSED) SEED-FAIL=$seedfail SKIP(network)=$skipped"
# A DIFF is a miscompile; a SEED-FAIL means the oracle itself did not build.
if [ "$diff" -gt 0 ] || [ "$seedfail" -gt 0 ]; then
  exit 1
fi
# A REFUSED example is an honest "not ported yet" only while it matches the pin.
if [ "$refused" -gt "$EXPECTED_REFUSED" ]; then
  echo "FAIL: REFUSED rose $EXPECTED_REFUSED -> $refused. A construct that used to lower no longer does."
  echo "      Fix the regression, or raise EXPECTED_REFUSED in this script if the refusal is deliberate."
  exit 1
fi
if [ "$refused" -lt "$EXPECTED_REFUSED" ]; then
  echo "FAIL: REFUSED fell $EXPECTED_REFUSED -> $refused. Lower EXPECTED_REFUSED to $refused in this script,"
  echo "      otherwise the pin leaves $((EXPECTED_REFUSED - refused)) refusals of slack for a regression to hide in."
  exit 1
fi
exit 0
