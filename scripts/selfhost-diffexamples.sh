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
# emit a binary) and is reported but not fatal — the fatal ones are DIFF (bit2
# built something that behaves differently from the seed) and SEED-FAIL.
#
# Usage: zig build && zig build selfhost && bash scripts/selfhost-diffexamples.sh
set -u
SEED=zig-out/bin/bit
BIT2=${BIT2:-zig-out/bin/bit2}
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

echo "example differential: PASS=$pass DIFF=$diff REFUSED=$refused SEED-FAIL=$seedfail SKIP(network)=$skipped"
# A REFUSED example is an honest "not ported yet"; a DIFF is a miscompile.
if [ "$diff" -gt 0 ] || [ "$seedfail" -gt 0 ]; then
  exit 1
fi
exit 0
