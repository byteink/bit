#!/usr/bin/env bash
# Self-host AST differential (#1332/#1335): parse every corpus `.bit` file with
# both the Zig seed (`bit`) and the Bit compiler (`bit2`) and diff their
# `--dump-ast` output. They must be byte-identical. Files the seed rejects with
# a parse/lex error are skipped — the Bit parser has no diagnostic renderer yet
# (deferred with the renderer port), so it parses past errors where the seed
# prints a diagnostic instead.
#
# Usage: zig build && zig build selfhost && bash scripts/selfhost-diffast.sh
# Exits non-zero (printing the first divergence) on any mismatch.
set -u
SEED=zig-out/bin/bit-seed
BIT2=zig-out/bin/bit
match=0 mismatch=0 skip=0 firstbad=""
for f in $(find stdlib examples tests/cases tests/imports -name '*.bit' | sort); do
  seed=$("$SEED" --dump-ast "$f" 2>/dev/null) || { skip=$((skip + 1)); continue; }
  b2=$("$BIT2" --dump-ast "$f" 2>/dev/null)
  if [ "$seed" = "$b2" ]; then
    match=$((match + 1))
  else
    mismatch=$((mismatch + 1))
    [ -z "$firstbad" ] && firstbad="$f"
  fi
done
echo "AST differential: MATCH=$match MISMATCH=$mismatch SKIP(parse-err)=$skip"
if [ -n "$firstbad" ]; then
  echo "first divergence: $firstbad"
  diff <("$SEED" --dump-ast "$firstbad" 2>/dev/null) <("$BIT2" --dump-ast "$firstbad" 2>/dev/null) | head -20
  exit 1
fi
