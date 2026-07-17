#!/usr/bin/env bash
# Self-host type differential (#1337/#364): run every corpus `.bit` through both
# compilers' `--dump-types` (the binding/param/call type dump) and diff. Files
# the seed rejects at check time are skipped (bit2's checker is still partial).
# This tracks Stage-2 inference coverage: MATCH grows as more constructs are
# ported; a byte diff pins the exact expression whose inferred type differs.
#
# Usage: zig build && zig build selfhost && bash scripts/selfhost-difftypes.sh
set -u
SEED=zig-out/bin/bit-seed
BIT2=zig-out/bin/bit
match=0 mismatch=0 skip=0 firstbad=""
for f in $(find stdlib examples tests/cases tests/imports -name '*.bit' | sort); do
  seed=$("$SEED" --dump-types "$f" 2>/dev/null) || { skip=$((skip + 1)); continue; }
  b2=$(perl -e 'alarm 10; exec @ARGV' "$BIT2" --dump-types "$f" 2>/dev/null)
  if [ "$seed" = "$b2" ]; then
    match=$((match + 1))
  else
    mismatch=$((mismatch + 1))
    [ -z "$firstbad" ] && firstbad="$f"
  fi
done
echo "type differential: MATCH=$match MISMATCH=$mismatch SKIP(check-err)=$skip"
if [ -n "$firstbad" ]; then
  echo "first divergence: $firstbad"
  diff <("$SEED" --dump-types "$firstbad" 2>/dev/null) <(perl -e 'alarm 10; exec @ARGV' "$BIT2" --dump-types "$firstbad" 2>/dev/null) | head -12
fi
