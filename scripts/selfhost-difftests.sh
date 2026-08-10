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
# BOTH the ORACLE and BIT2 runs are alarm-guarded (#2866): neither had a bound
# before, so a hung `bit test` on either side wedged this script indefinitely —
# the same shape selfhost-diffcheck.sh's header warns about ("the seed side had
# no bound at all, so a hung ORACLE wedged the whole gate indefinitely").
# ALARMRUN_KEEP_STDERR=1 because this differential depends on the child's
# stderr landing in the SAME captured file as its stdout (the panic note
# above); alarmrun's own default discards stderr, which would silently drop a
# panic and turn a real divergence into a false MATCH.
#
# Usage: ./make selfhost && bash scripts/selfhost-difftests.sh
set -u
# shellcheck source=scripts/alarmrun.sh
. "$(dirname -- "$0")/alarmrun.sh"
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

# 20s matches this family's single-call convention (diffdump.sh/diffcheck.sh/
# diffverdict.sh/diffdoc.sh); DIFFTESTS_TIMEOUT overrides for a slower host or
# a bigger $PROJ. Do not go below ~12s on a shared box: #2863's mutation run at
# a 3s bound produced 11 false timeouts from ordinary machine load, redone at
# 12-20s.
TIMEOUT=${DIFFTESTS_TIMEOUT:-20}

ALARMRUN_KEEP_STDERR=1 alarmrun "$ORACLE" test "$PROJ" >"$TMP/seed" 2>&1
se=$?
if [ "$se" -eq 142 ]; then
  echo "ORACLE timed out after ${TIMEOUT}s running: $ORACLE test $PROJ"
  exit 1
fi

ALARMRUN_KEEP_STDERR=1 alarmrun "$BIT2" test "$PROJ" >"$TMP/b2" 2>&1
b2=$?
if [ "$b2" -eq 142 ]; then
  echo "BIT2 timed out after ${TIMEOUT}s running: $BIT2 test $PROJ"
  exit 1
fi

if [ "$se" != "$b2" ] || ! cmp -s "$TMP/seed" "$TMP/b2"; then
  echo "DIFF $PROJ (exit seed=$se bit2=$b2)"
  command diff "$TMP/seed" "$TMP/b2" | head -20
  exit 1
fi
echo "test-runner differential: MATCH $PROJ (exit=$se)"
exit 0
