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
# Usage: zig build && zig build selfhost && bash scripts/selfhost-difftests.sh
set -u
SEED=zig-out/bin/bit
BIT2=${BIT2:-zig-out/bin/bit2}
PROJ=${1:-tests/testproj}
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

"$SEED" test "$PROJ" >"$TMP/seed" 2>&1
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
