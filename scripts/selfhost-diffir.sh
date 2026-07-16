#!/usr/bin/env bash
# Self-host IR differential (#1337/#364): run every corpus `.bit` through both
# compilers' `--dump-ir` (the lowered SSA text) and diff. Files the seed cannot
# lower/check are skipped (bitc2's lowering is still partial). This tracks
# Stage-2 lowering coverage: MATCH grows as more constructs lower; a byte diff
# pins the exact function whose IR differs.
#
# Usage: zig build && zig build selfhost && bash scripts/selfhost-diffir.sh
set -u
SEED=zig-out/bin/bitc
BITC2=zig-out/bin/bitc2
match=0 mismatch=0 skip=0 firstbad=""
for f in $(find stdlib examples tests/cases tests/imports -name '*.bit' | sort); do
  seed=$("$SEED" --dump-ir "$f" 2>/dev/null) || { skip=$((skip + 1)); continue; }
  [ -z "$seed" ] && { skip=$((skip + 1)); continue; }
  b2=$(perl -e 'alarm 10; exec @ARGV' "$BITC2" --dump-ir "$f" 2>/dev/null)
  if [ "$seed" = "$b2" ]; then
    match=$((match + 1))
  else
    mismatch=$((mismatch + 1))
    [ -z "$firstbad" ] && firstbad="$f"
  fi
done
echo "IR differential: MATCH=$match MISMATCH=$mismatch SKIP(lower/check-err)=$skip"
if [ -n "$firstbad" ]; then
  echo "first divergence: $firstbad"
  diff <("$SEED" --dump-ir "$firstbad" 2>/dev/null) <(perl -e 'alarm 10; exec @ARGV' "$BITC2" --dump-ir "$firstbad" 2>/dev/null) | head -20
fi
