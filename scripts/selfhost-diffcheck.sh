#!/usr/bin/env bash
# Self-host CHECK differential: run every corpus `.bit` through both compilers'
# `check` and diff the rendered diagnostics.
#
# This is the guard the other differentials structurally cannot be. difftypes
# SKIPs every file the seed rejects (202 of them — the entire invalid-program
# corpus); diffdiags only covers lex+parse, because the seed's `--dump-diags` is
# front-end only; diffexamples only ever builds VALID programs. So a green board
# across all three said nothing about whether bit2 REJECTS what the seed
# rejects — and for a long time it rejected nothing at all, silently compiling
# `function f(): i32 { return "hi" }` into a binary that printed a raw pointer.
#
# Four outcomes, and the asymmetry between the last two is the point:
#   MATCH    both compilers produce byte-identical diagnostics (or both none)
#   MISSING  the seed rejects, bit2 accepts    — a gap: an emit site not ported
#            yet. Expected to shrink; harmless (the seed is still the gate).
#   FALSEPOS bit2 rejects, the seed accepts    — a BUG, and the dangerous one:
#            bit2 refusing valid code breaks builds. Must stay 0.
#   DIFF     both reject, different text        — usually a cascade: bit2 report
#            a downstream error because the root site is not ported.
#
# Diagnostics go to stderr (both compilers), so stdout is discarded.
#
# PATH NORMALIZATION: the seed's file-check CLI absolutizes the display path (it
# routes a lone file through `checkHostProject(absFromCwd(dirname), basename)`,
# introduced when a lone .bit file became a module in 83b511f), so it renders
# `--> /abs/repo/stdlib/x.bit`. bit2 renders the path AS GIVEN — `--> stdlib/x.bit`
# — which is what gcc/clang/rustc/zig do and what the `.expected` goldens encode,
# so bit2 is the correct one. Rather than do loader surgery on the about-to-retire
# seed, strip the repo-root prefix from the seed's output before comparing: the
# diff then reflects only REAL diagnostic differences, and this script retires
# with the seed. Verified exact (stripping the prefix collapsed all 44 path-diffs
# to MATCH, 0 real).
#
# Usage: zig build && zig build selfhost && bash scripts/selfhost-diffcheck.sh
set -u
SEED=zig-out/bin/bit
BIT2=zig-out/bin/bit2
ROOT="$(pwd)/"
match=0 missing=0 falsepos=0 diff=0 firstfp="" firstdiff=""
for f in $(find stdlib examples tests/cases tests/imports -name '*.bit' | sort); do
  seed=$("$SEED" check "$f" 2>&1 >/dev/null)
  # The seed appends its own `error: CheckFailed` trace line; that is the Zig
  # runtime reporting main's error return, not a diagnostic. Drop it, and strip
  # the absolute repo-root prefix so the two rendered streams are comparable.
  seed=$(printf '%s\n' "$seed" | grep -v '^error: CheckFailed$' | sed "s#--> ${ROOT}#--> #")
  b2=$(perl -e 'alarm 20; exec @ARGV' "$BIT2" check "$f" 2>&1 >/dev/null)
  if [ "$seed" = "$b2" ]; then
    match=$((match + 1))
  elif [ -n "$seed" ] && [ -z "$b2" ]; then
    missing=$((missing + 1))
  elif [ -z "$seed" ] && [ -n "$b2" ]; then
    falsepos=$((falsepos + 1))
    [ -z "$firstfp" ] && firstfp="$f"
  else
    diff=$((diff + 1))
    [ -z "$firstdiff" ] && firstdiff="$f"
  fi
done
echo "check differential: MATCH=$match MISSING=$missing FALSEPOS=$falsepos DIFF=$diff"
if [ -n "$firstfp" ]; then
  echo "=== FIRST FALSE POSITIVE (bit2 rejects code the seed accepts): $firstfp"
  perl -e 'alarm 20; exec @ARGV' "$BIT2" check "$firstfp" 2>&1 >/dev/null | head -8
fi
if [ -n "$firstdiff" ]; then
  echo "=== first differing text: $firstdiff"
  diff <("$SEED" check "$firstdiff" 2>&1 >/dev/null | grep -v '^error: CheckFailed$') \
       <(perl -e 'alarm 20; exec @ARGV' "$BIT2" check "$firstdiff" 2>&1 >/dev/null) | head -14
fi
# Only a false positive is a build-breaking regression; MISSING shrinks as emit
# sites land, and DIFF is dominated by cascades from unported root sites.
[ "$falsepos" -eq 0 ]
