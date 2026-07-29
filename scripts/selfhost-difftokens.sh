#!/usr/bin/env bash
# Token differential (#1332/#1334): lex every corpus `.bit` file with both the
# PINNED STAGE0 (the previous release) and the working tree's compiler, and diff
# their `--dump-tokens` output. They must be byte-identical. Files the oracle
# rejects with a lex error are skipped — the two lexers disagree about how far
# to lex past an error, so those files measure the diagnostic renderer rather
# than the lexer.
#
# THE ORACLE CHANGED IN #1593, AND SO DID WHAT A GREEN RUN MEANS. It used to be
# `zig-out/bin/bit-seed`, a compiler written in a different language, so green
# meant "two independent implementations agree". It is now the last release of
# this same compiler, so green means "this version did not change behaviour
# versus the last release". See docs/release/bootstrap.md §4/§5 — the loss is
# recorded there, not papered over.
#
# Usage: zig build selfhost && bash scripts/selfhost-difftokens.sh
# Exits non-zero (printing the first divergence) on any mismatch.
set -u
# Resolves, downloads and DIGEST-VERIFIES the pinned stage0; see scripts/stage0.sh.
# It refuses rather than skipping, so a `set -u` failure here is loud.
ORACLE="$(sh scripts/stage0.sh)" || exit 2
BIT2=zig-out/bin/bit

# A missing compiler must ABORT, never score a vacuous green (#1514): both sides
# of the differential would produce empty output, and equal-empty compares as
# agreement. Exit 2 to keep this distinct from a real divergence (exit 1).
for bin in "$ORACLE" "$BIT2"; do
  [ -x "$bin" ] || { echo "difftokens: missing $bin — run: zig build selfhost" >&2; exit 2; }
done

match=0 mismatch=0 skip=0 firstbad=""
for f in $(find stdlib examples tests/cases tests/imports -name '*.bit' | sort); do
  oracle_out=$("$ORACLE" --dump-tokens "$f" 2>/dev/null) || { skip=$((skip + 1)); continue; }
  b2=$("$BIT2" --dump-tokens "$f" 2>/dev/null)
  if [ "$oracle_out" = "$b2" ]; then
    match=$((match + 1))
  else
    mismatch=$((mismatch + 1))
    [ -z "$firstbad" ] && firstbad="$f"
  fi
done
echo "token differential: MATCH=$match MISMATCH=$mismatch SKIP(lex-err)=$skip"

# A phase that measured nothing must not pass (#1516). On an empty or unfindable
# corpus the loop runs zero comparisons and MISMATCH is 0 for the wrong reason.
if [ "$match" -lt 1 ]; then
  echo "FATAL: the token differential compared nothing (MATCH=$match) — corpus walk found no .bit file." >&2
  exit 2
fi

if [ -n "$firstbad" ]; then
  echo "first divergence: $firstbad"
  diff <("$ORACLE" --dump-tokens "$firstbad" 2>/dev/null) <("$BIT2" --dump-tokens "$firstbad" 2>/dev/null) | head -20
  exit 1
fi
