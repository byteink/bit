#!/usr/bin/env bash
# Self-host front-end diagnostic differential (#1335/#363): run every corpus
# `.bit` file through both compilers' `--dump-diags` (lexer + parser diagnostics
# only — resolve/check is Stage 2 and not yet ported) and diff. They must be
# byte-identical: empty for a clean file, and the same rendered diagnostic for a
# lex/parse error. Unlike difftokens/diffast this skips nothing — a valid file
# produces empty output from both, and the seed's --dump-diags is frontend-only
# so checker `// error` cases are empty on both sides too.
#
# Usage: zig build && zig build selfhost && bash scripts/selfhost-diffdiags.sh
# Exits non-zero (printing the first divergence) on any mismatch.
set -u
SEED=zig-out/bin/bit
BIT2=zig-out/bin/bit2
match=0 mismatch=0 firstbad=""
for f in $(find stdlib examples tests/cases tests/imports -name '*.bit' | sort); do
  seed=$("$SEED" --dump-diags "$f" 2>/dev/null)
  b2=$("$BIT2" --dump-diags "$f" 2>/dev/null)
  if [ "$seed" = "$b2" ]; then
    match=$((match + 1))
  else
    mismatch=$((mismatch + 1))
    [ -z "$firstbad" ] && firstbad="$f"
  fi
done
echo "diag differential: MATCH=$match MISMATCH=$mismatch"
if [ -n "$firstbad" ]; then
  echo "first divergence: $firstbad"
  diff <("$SEED" --dump-diags "$firstbad" 2>/dev/null) <("$BIT2" --dump-diags "$firstbad" 2>/dev/null) | head -20
  exit 1
fi
