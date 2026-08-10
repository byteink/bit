#!/usr/bin/env bash
# x86_64-linux behavioural differential (#1346): build every example with BOTH
# compilers for x86_64-linux, run both on a real x86-64 box, and diff the
# printed output. This is the only end-to-end guard the x64 backend has — the
# dump differentials compare check/lower, which are shared, so a codegen bug is
# invisible to them (see selfhost-diffexamples.sh for the arm64/macOS twin).
#
# Needs an x86-64 Linux host reachable over ssh. No hostname is baked into the
# repo: set BITX64_HOST, or configure candidates for scripts/x64host.sh.
# Usage: ./make selfhost && bash scripts/selfhost-diffexamples-x64.sh
set -u
# Oracle: the pinned stage0 -- the same compiler one release back, an EARLIER
# VERSION OF THIS SAME COMPILER, which is exactly what limits the claim below.
# scripts/stage0.sh downloads and DIGEST-VERIFIES it, and refuses rather
# than skipping. A green run proves no behaviour change versus the last
# release; it cannot catch a bug present in both — docs/release/bootstrap.md §4/§5.
ORACLE="$(sh scripts/stage0.sh)" || exit 2
BIT2=${BIT2:-bit-out/bin/bit}
HOST=${BITX64_HOST:-$(bash "$(dirname "$0")/x64host.sh")}
[ -n "$HOST" ] || exit 127
echo "diffexamples-x64: host=$HOST"
# Both sides link the WORKING TREE's x86_64-linux runtime, not the stage0
# tarball's — see scripts/selfhost-diffexamples.sh for why, and why this cannot
# live in the stage0 wrapper (BIT_LIBBITRT names one archive for one triple, and
# this script cross-compiles).
X64_RT=bit-out/lib/x86_64-linux/libbitrt.a
[ -f "$X64_RT" ] || { echo "diffexamples-x64: missing $X64_RT — run: ./make libbitrt" >&2; exit 2; }
export BIT_LIBBITRT="$PWD/$X64_RT"

REMOTE=/tmp/bitdiff-x64
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"; ssh "$HOST" "rm -rf $REMOTE" >/dev/null 2>&1' EXIT

ssh "$HOST" "rm -rf $REMOTE && mkdir -p $REMOTE" || { echo "cannot reach $HOST"; exit 1; }

# The same list selfhost-diffexamples.sh skips: these need constructs bit2
# cannot lower yet (closures/spawn), so they refuse on EVERY target — they are
# not an x64 gap, and counting them here would just mask a real one appearing.
SKIP="h3fetch httpserver httpsserver http2server tlsclient"

pass=0 diff=0 refused=0 oraclefail=0 skipped=0 scpfail=0
for d in examples/*/; do
  n=$(basename "$d")
  case " $SKIP " in *" $n "*) skipped=$((skipped + 1)); continue;; esac
  if ! "$ORACLE" build "$d" -o "$TMP/oracle_$n" --target x86_64-linux >"$TMP/oerr_$n" 2>&1; then
    oraclefail=$((oraclefail + 1)); echo "ORACLE-FAIL $n"; continue
  fi
  if ! "$BIT2" build "$d" -o "$TMP/b2_$n" --target x86_64-linux >"$TMP/berr_$n" 2>&1; then
    refused=$((refused + 1)); echo "REFUSED $n: $(head -1 "$TMP/berr_$n")"; continue
  fi
  # A failed transfer is a failure, not a silent skip: it printed SCP-FAIL and
  # then fell through to a verdict that never looked at it, so a run where EVERY
  # example failed to reach the host still exited 0 (#1513). Nothing was compared;
  # that cannot read as agreement.
  scp -q "$TMP/oracle_$n" "$TMP/b2_$n" "$HOST:$REMOTE/" || { echo "SCP-FAIL $n"; scpfail=$((scpfail + 1)); continue; }
  so=$(ssh "$HOST" "cd $REMOTE && chmod +x oracle_$n b2_$n && timeout 30 ./oracle_$n 2>&1; echo EXIT=\$?")
  bo=$(ssh "$HOST" "cd $REMOTE && timeout 30 ./b2_$n 2>&1; echo EXIT=\$?")
  if [ "$so" = "$bo" ]; then
    pass=$((pass + 1))
  else
    diff=$((diff + 1))
    echo "DIFF $n"
    echo "--- oracle: $so" | head -5
    echo "--- bit2: $bo" | head -5
  fi
done
echo "x86_64-linux example differential: PASS=$pass DIFF=$diff REFUSED=$refused ORACLE-FAIL=$oraclefail SCP-FAIL=$scpfail SKIP(unported)=$skipped"

# A phase that measured nothing must not pass (#1514). On an empty corpus the
# loop runs zero comparisons and every counter below is 0 for the wrong reason.
if [ "$pass" -lt 1 ]; then
  echo "FATAL: the x86_64 example differential compared nothing (PASS=$pass)." >&2
  exit 2
fi

[ "$diff" -eq 0 ] && [ "$oraclefail" -eq 0 ] && [ "$refused" -eq 0 ] && [ "$scpfail" -eq 0 ]
