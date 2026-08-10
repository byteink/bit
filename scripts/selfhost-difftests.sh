#!/usr/bin/env bash
# Self-host TEST-RUNNER differential: `bit test` vs `bit2 test` must agree on
# what they discover, how they dispatch, and every verdict — same printed lines,
# same exit code. This guards the second self-hosted CLI subcommand end to end:
# testgen discovery, the synthesized dispatch main, bit_rt_os_run_test's
# per-process BIT_TEST_INDEX plumbing, and the runner's pass/fail accounting.
#
# A panic line comes from the child test process on stderr, so the compared
# output deliberately folds stdout+stderr together (2>&1): a test that fails by
# panicking must print the same panic under both compilers.
#
# Usage: ./make selfhost && bash scripts/selfhost-difftests.sh
set -u
# Oracle: the pinned stage0 -- the same compiler one release back, an EARLIER
# VERSION OF THIS SAME COMPILER, which is exactly what limits the claim below.
# scripts/stage0.sh downloads and DIGEST-VERIFIES it, and refuses rather
# than skipping, so a failure here is loud. A green run proves no behaviour
# change versus the last release; it cannot catch a bug present in both —
# docs/release/bootstrap.md §4/§5.
ORACLE="$(sh scripts/stage0.sh)" || exit 2
BIT2=${BIT2:-bit-out/bin/bit}
PROJ=${1:-tests/testproj}
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

"$ORACLE" test "$PROJ" >"$TMP/seed" 2>&1
se=$?
"$BIT2" test "$PROJ" >"$TMP/b2" 2>&1
b2=$?

if [ "$se" != "$b2" ] || ! cmp -s "$TMP/seed" "$TMP/b2"; then
  echo "DIFF $PROJ (exit seed=$se bit2=$b2)"
  command diff "$TMP/seed" "$TMP/b2" | head -20
  exit 1
fi
echo "test-runner differential: MATCH $PROJ (exit=$se)"
exit 0
