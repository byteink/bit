#!/usr/bin/env bash
# Self-host AST differential (#1332/#1335): parse every corpus `.bit` file with
# both the Zig seed (`bit`) and the Bit compiler (`bit2`) and diff their
# `--dump-ast` output. They must be byte-identical. Files the seed rejects with
# a parse/lex error are skipped — the Bit parser has no diagnostic renderer yet
# (deferred with the renderer port), so it parses past errors where the seed
# prints a diagnostic instead.
#
# Usage: ./make selfhost && bash scripts/selfhost-diffast.sh
# Exits non-zero (printing the first divergence) on any mismatch.
set -u
# The oracle is the PINNED STAGE0 (previous release), not the retired Zig seed
# (#1593). scripts/stage0.sh downloads and DIGEST-VERIFIES it, and refuses rather
# than skipping, so a failure here is loud. What a green run asserts changed with
# it: "unchanged versus the last release", not "two implementations agree" —
# docs/release/bootstrap.md §4/§5.
ORACLE="$(sh scripts/stage0.sh)" || exit 2
BIT2=zig-out/bin/bit

# A missing compiler must ABORT, never score a vacuous green (#1514): both sides
# of the differential would produce empty output, and equal-empty compares as
# agreement. Exit 2 to keep this distinct from a real divergence (exit 1).
for bin in "$ORACLE" "$BIT2"; do
  [ -x "$bin" ] || { echo "diffast: missing $bin — run: ./make selfhost" >&2; exit 2; }
done

match=0 mismatch=0 skip=0 firstbad=""
for f in $(find stdlib examples tests/cases tests/imports -name '*.bit' | sort); do
  seed=$("$ORACLE" --dump-ast "$f" 2>/dev/null) || { skip=$((skip + 1)); continue; }
  b2=$("$BIT2" --dump-ast "$f" 2>/dev/null)
  if [ "$seed" = "$b2" ]; then
    match=$((match + 1))
  else
    mismatch=$((mismatch + 1))
    [ -z "$firstbad" ] && firstbad="$f"
  fi
done
echo "AST differential: MATCH=$match MISMATCH=$mismatch SKIP(parse-err)=$skip"

# A phase that measured nothing must not pass (#1516). On an empty or unfindable
# corpus the loop runs zero comparisons and MISMATCH is 0 for the wrong reason.
if [ "$match" -lt 1 ]; then
  echo "FATAL: the AST differential compared nothing (MATCH=$match) — corpus walk found no .bit file." >&2
  exit 2
fi

if [ -n "$firstbad" ]; then
  echo "first divergence: $firstbad"
  diff <("$ORACLE" --dump-ast "$firstbad" 2>/dev/null) <("$BIT2" --dump-ast "$firstbad" 2>/dev/null) | head -20
  exit 1
fi
