#!/usr/bin/env bash
# Self-host type differential (#1337/#364): run every corpus `.bit` through both
# compilers' `--dump-types` (the binding/param/call type dump) and diff. Files
# the seed rejects at check time are skipped (bit2's checker is still partial).
# This tracks Stage-2 inference coverage: MATCH grows as more constructs are
# ported; a byte diff pins the exact expression whose inferred type differs.
#
# ## It had no exit status either (#1478)
#
# Found by the #1478 audit, one script down from `selfhost-diffiropt.sh`: this
# printed `MISMATCH=n` and a first-divergence diff, then fell off the end at the
# `if`'s status — always 0. Quoting it as verification was never a true claim.
#
# No expected-gap set here, deliberately: unlike the IR differentials this one
# is at MISMATCH=0, so the expectation is simply "none", and a set file would be
# an empty ceremony. If a gap ever has to be tolerated, add one then — do not
# pin a count.
#
# A timeout is not evidence: a `bit` run killed by the alarm produced no verdict,
# so it is reported separately and fails, rather than being scored as a mismatch.
#
# Usage: ./make selfhost && bash scripts/selfhost-difftypes.sh
set -uo pipefail
# The oracle is the PINNED STAGE0 (previous release), not the retired Zig seed
# (#1593). scripts/stage0.sh downloads and DIGEST-VERIFIES it, and refuses rather
# than skipping, so a failure here is loud. What a green run asserts changed with
# it: "unchanged versus the last release", not "two implementations agree" —
# docs/release/bootstrap.md §4/§5.
ORACLE="$(sh scripts/stage0.sh)" || exit 2
BIT2=zig-out/bin/bit
TIMEOUT=${DIFFTYPES_TIMEOUT:-20}

for bin in "$ORACLE" "$BIT2"; do
  [ -x "$bin" ] || { echo "difftypes: missing $bin — run: ./make selfhost" >&2; exit 2; }
done

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
: >"$work/mismatch"
: >"$work/timeout"
match=0 skip=0

for f in $(find stdlib examples tests/cases tests/imports -name '*.bit' | sort); do
  seed=$("$ORACLE" --dump-types "$f" 2>/dev/null) || { skip=$((skip + 1)); continue; }
  b2=$(perl -e 'alarm shift; exec @ARGV' "$TIMEOUT" "$BIT2" --dump-types "$f" 2>/dev/null)
  rc=$?
  if [ "$rc" -ge 128 ]; then
    echo "$f" >>"$work/timeout"
    continue
  fi
  if [ "$seed" = "$b2" ]; then
    match=$((match + 1))
  else
    echo "$f" >>"$work/mismatch"
  fi
done

mismatch=$(wc -l <"$work/mismatch" | tr -d ' ')
timeouts=$(wc -l <"$work/timeout" | tr -d ' ')
echo "type differential: MATCH=$match MISMATCH=$mismatch TIMEOUT=$timeouts SKIP(check-err)=$skip"

status=0

if [ -s "$work/mismatch" ]; then
  echo
  # EVERY divergence, named. "first divergence" told you one file out of n and
  # left the rest unreported, which is how a set of gaps reads as a single bug.
  echo "MISMATCH: $mismatch file(s) whose inferred types differ:"
  while read -r f; do echo "  $f"; done <"$work/mismatch"
  head -3 "$work/mismatch" | while read -r f; do
    echo
    echo "--- diff (seed vs bit): $f"
    diff <("$ORACLE" --dump-types "$f" 2>/dev/null) \
         <(perl -e 'alarm shift; exec @ARGV' "$TIMEOUT" "$BIT2" --dump-types "$f" 2>/dev/null) | head -12
  done
  status=1
fi

if [ -s "$work/timeout" ]; then
  echo
  echo "INVALID: $timeouts file(s) timed out after ${TIMEOUT}s — no verdict, not a match:"
  while read -r f; do echo "  timeout: $f"; done <"$work/timeout"
  status=1
fi

[ "$status" -eq 0 ] && { echo; echo "difftypes: the two checkers agree on every compared file."; }
exit "$status"
