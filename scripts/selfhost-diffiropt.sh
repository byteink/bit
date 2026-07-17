#!/usr/bin/env bash
# Self-host POST-opt IR differential (#1339): diff `bit2 --dump-ir` (optimized)
# against the seed's optimized `--dump-ir` over the corpus. Tracks optimizer
# coverage — MATCH grows as fold/DCE/inline passes land. Mirror of
# selfhost-diffir.sh but for the post-optimizer surface.
set -u
SEED=zig-out/bin/bit-seed
BIT2=zig-out/bin/bit
match=0 mismatch=0 skip=0 firstbad=""
for f in $(find stdlib examples tests/cases tests/imports -name '*.bit' | sort); do
  seed=$("$SEED" --dump-ir "$f" 2>/dev/null) || { skip=$((skip + 1)); continue; }
  [ -z "$seed" ] && { skip=$((skip + 1)); continue; }
  b2=$(perl -e 'alarm 10; exec @ARGV' "$BIT2" --dump-ir "$f" 2>/dev/null)
  if [ "$seed" = "$b2" ]; then
    match=$((match + 1))
  else
    mismatch=$((mismatch + 1))
    [ -z "$firstbad" ] && firstbad="$f"
  fi
done
echo "IR (post-opt) differential: MATCH=$match MISMATCH=$mismatch SKIP(lower/check-err)=$skip"
if [ -n "$firstbad" ]; then
  echo "first divergence: $firstbad"
  diff <("$SEED" --dump-ir "$firstbad" 2>/dev/null) <(perl -e 'alarm 10; exec @ARGV' "$BIT2" --dump-ir "$firstbad" 2>/dev/null) | head -20
fi
