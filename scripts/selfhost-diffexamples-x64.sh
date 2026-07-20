#!/usr/bin/env bash
# x86_64-linux behavioural differential (#1346): build every example with BOTH
# compilers for x86_64-linux, run both on a real x86-64 box, and diff the
# printed output. This is the only end-to-end guard the x64 backend has — the
# dump differentials compare check/lower, which are shared, so a codegen bug is
# invisible to them (see selfhost-diffexamples.sh for the arm64/macOS twin).
#
# Needs an x86-64 Linux host reachable over ssh (BITX64_HOST, default hl-master).
# Usage: zig build && zig build selfhost && bash scripts/selfhost-diffexamples-x64.sh
set -u
SEED=zig-out/bin/bit-seed
BIT2=${BIT2:-zig-out/bin/bit}
HOST=${BITX64_HOST:-hl-master}
REMOTE=/tmp/bitdiff-x64
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"; ssh "$HOST" "rm -rf $REMOTE" >/dev/null 2>&1' EXIT

ssh "$HOST" "rm -rf $REMOTE && mkdir -p $REMOTE" || { echo "cannot reach $HOST"; exit 1; }

# The same list selfhost-diffexamples.sh skips: these need constructs bit2
# cannot lower yet (closures/spawn), so they refuse on EVERY target — they are
# not an x64 gap, and counting them here would just mask a real one appearing.
SKIP="h3fetch httpserver httpsserver http2server tlsclient"

pass=0 diff=0 refused=0 seedfail=0 skipped=0 scpfail=0
for d in examples/*/; do
  n=$(basename "$d")
  case " $SKIP " in *" $n "*) skipped=$((skipped + 1)); continue;; esac
  if ! "$SEED" build "$d" -o "$TMP/seed_$n" --target x86_64-linux >"$TMP/serr_$n" 2>&1; then
    seedfail=$((seedfail + 1)); echo "SEED-FAIL $n"; continue
  fi
  if ! "$BIT2" build "$d" -o "$TMP/b2_$n" --target x86_64-linux >"$TMP/berr_$n" 2>&1; then
    refused=$((refused + 1)); echo "REFUSED $n: $(head -1 "$TMP/berr_$n")"; continue
  fi
  # A failed transfer is a failure, not a silent skip: it printed SCP-FAIL and
  # then fell through to a verdict that never looked at it, so a run where EVERY
  # example failed to reach the host still exited 0 (#1513). Nothing was compared;
  # that cannot read as agreement.
  scp -q "$TMP/seed_$n" "$TMP/b2_$n" "$HOST:$REMOTE/" || { echo "SCP-FAIL $n"; scpfail=$((scpfail + 1)); continue; }
  so=$(ssh "$HOST" "cd $REMOTE && chmod +x seed_$n b2_$n && timeout 30 ./seed_$n 2>&1; echo EXIT=\$?")
  bo=$(ssh "$HOST" "cd $REMOTE && timeout 30 ./b2_$n 2>&1; echo EXIT=\$?")
  if [ "$so" = "$bo" ]; then
    pass=$((pass + 1))
  else
    diff=$((diff + 1))
    echo "DIFF $n"
    echo "--- seed: $so" | head -5
    echo "--- bit2: $bo" | head -5
  fi
done
echo "x86_64-linux example differential: PASS=$pass DIFF=$diff REFUSED=$refused SEED-FAIL=$seedfail SCP-FAIL=$scpfail SKIP(unported)=$skipped"
[ "$diff" -eq 0 ] && [ "$seedfail" -eq 0 ] && [ "$refused" -eq 0 ] && [ "$scpfail" -eq 0 ]
