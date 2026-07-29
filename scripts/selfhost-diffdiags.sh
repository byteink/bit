#!/usr/bin/env bash
# Self-host front-end diagnostic differential (#1335/#363): run every corpus
# `.bit` file through both compilers' `--dump-diags` (lexer + parser diagnostics
# only — resolve/check is Stage 2 and not yet ported) and diff. They must be
# byte-identical: empty for a clean file, and the same rendered diagnostic for a
# lex/parse error. Unlike difftokens/diffast this skips nothing — a valid file
# produces empty output from both, and the seed's --dump-diags is frontend-only
# so checker `// error` cases are empty on both sides too.
#
# Usage: ./make selfhost && bash scripts/selfhost-diffdiags.sh
# Exits non-zero (printing the first divergence) on any mismatch.
set -u
# The oracle is the PINNED STAGE0 (previous release), not the retired Zig seed
# (#1593). scripts/stage0.sh downloads and DIGEST-VERIFIES it, and refuses rather
# than skipping, so a failure here is loud. What a green run asserts changed with
# it: "unchanged versus the last release", not "two implementations agree" —
# docs/release/bootstrap.md §4/§5.
ORACLE="$(sh scripts/stage0.sh)" || exit 2
BIT2=bit-out/bin/bit

# A missing compiler must ABORT, never score a vacuous green (#1514). This gate
# is the worst of the family without it: both sides render empty, and since it
# skips nothing every file scores MATCH — a full green board from no compiler.
# Exit 2 to keep this distinct from a real divergence (exit 1).
for bin in "$ORACLE" "$BIT2"; do
  [ -x "$bin" ] || { echo "diffdiags: missing $bin — run: ./make selfhost" >&2; exit 2; }
done

match=0 mismatch=0 firstbad=""
for f in $(find stdlib examples tests/cases tests/imports -name '*.bit' | sort); do
  seed=$("$ORACLE" --dump-diags "$f" 2>/dev/null)
  b2=$("$BIT2" --dump-diags "$f" 2>/dev/null)
  if [ "$seed" = "$b2" ]; then
    match=$((match + 1))
  else
    mismatch=$((mismatch + 1))
    [ -z "$firstbad" ] && firstbad="$f"
  fi
done
echo "diag differential: MATCH=$match MISMATCH=$mismatch"

# A phase that measured nothing must not pass (#1516). On an empty or unfindable
# corpus the loop runs zero comparisons and MISMATCH is 0 for the wrong reason.
if [ "$match" -lt 1 ]; then
  echo "FATAL: the diag differential compared nothing (MATCH=$match) — corpus walk found no .bit file." >&2
  exit 2
fi

if [ -n "$firstbad" ]; then
  echo "first divergence: $firstbad"
  diff <("$ORACLE" --dump-diags "$firstbad" 2>/dev/null) <("$BIT2" --dump-diags "$firstbad" 2>/dev/null) | head -20
  exit 1
fi
