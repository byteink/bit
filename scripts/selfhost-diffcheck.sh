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
# A TIMEOUT IS NOT AN OUTCOME (#1538). The alarm-guarded run's exit status used
# to be discarded, so a killed `bit` yielded an empty output that was then
# classified by CONTENT — the classic shape of #1512/#1513/#1514/#1524/#1525.
# Both directions were wrong, and both landed in numbers this workstream steers
# by: a non-empty seed side scored MISSING (false red straight into the tracked
# MISSING 24 -> 7 -> 4 metric), and the common case of a file with no
# diagnostics scored `"" = ""` -> MATCH (silent false green: never compared).
# Now a timeout gets its own counter and `continue`s BEFORE any comparison, so
# the classification is structurally unreachable unless both sides produced a
# result. Two empty outputs can no longer meet each other.
#
# Exit codes (matching x64gate.sh / selfhost-diffsafepoints.sh / 3977211):
#   0  every file compared, no false positive
#   1  real failure: a FALSEPOS (bit rejects code the seed accepts)
#   2  could not decide: a file timed out and was never compared. Not a pass.
#
# Usage: zig build selfhost && bash scripts/selfhost-diffcheck.sh
set -u
# The oracle is the PINNED STAGE0 (previous release), not the retired Zig seed
# (#1593). scripts/stage0.sh downloads and DIGEST-VERIFIES it, and refuses rather
# than skipping, so a failure here is loud. What a green run asserts changed with
# it: "unchanged versus the last release", not "two implementations agree" —
# docs/release/bootstrap.md §4/§5.
ORACLE="$(sh scripts/stage0.sh)" || exit 2
BIT2=zig-out/bin/bit
ROOT="$(pwd)/"

# The alarm is a HANG guard, not a performance budget. Measured worst legitimate
# case over this exact corpus is 1.23s (`bit check tests/imports/nethttp/main.bit`,
# on a host running 9 parallel agents) against a 20s budget — 16x headroom, so no
# real work was ever near it and every trip was a DESCHEDULED process, not a slow
# one. Raising the constant would fix a cause that does not exist, so instead a
# trip is RETRIED ONCE: a genuine hang is deterministic and trips twice, a load
# artifact does not. TIMEOUT_S overrides for a slower host.
TIMEOUT_S=${TIMEOUT_S:-20}

# Alarm-guarded run; captures diagnostics (stderr) and discards stdout.
# The exit status is LOAD-BEARING and must be read by every caller: it returns
# 142 (128+SIGALRM) iff the run timed out TWICE.
run() {
  local out rc
  out=$(perl -e 'alarm shift; exec @ARGV' "$TIMEOUT_S" "$@" 2>&1 >/dev/null)
  rc=$?
  if [ "$rc" -eq 142 ]; then
    out=$(perl -e 'alarm shift; exec @ARGV' "$TIMEOUT_S" "$@" 2>&1 >/dev/null)
    rc=$?
  fi
  printf '%s' "$out"
  return "$rc"
}

match=0 missing=0 falsepos=0 diff=0 timeout=0 firstfp="" firstdiff="" firsthang=""
for f in $(find stdlib examples tests/cases tests/imports -name '*.bit' | sort); do
  # BOTH sides are alarm-guarded and BOTH statuses are captured. The seed side
  # had no bound at all, so a hung ORACLE wedged the whole gate indefinitely.
  seed=$(run "$ORACLE" check "$f"); src=$?
  b2=$(run "$BIT2" check "$f"); brc=$?
  if [ "$src" -eq 142 ] || [ "$brc" -eq 142 ]; then
    # Undecided: this file was never compared. Counted on its own, and
    # deliberately NOT folded into MISSING or FALSEPOS — those are tracked,
    # pinned counts, and an undecided file sitting inside them corrupts the pin.
    timeout=$((timeout + 1))
    [ -z "$firsthang" ] && firsthang="$f (SIGALRM after ${TIMEOUT_S}s x2, seed=$src bit=$brc)"
    continue
  fi
  # The seed appends its own `error: CheckFailed` trace line; that is the Zig
  # runtime reporting main's error return, not a diagnostic. Drop it, and strip
  # the absolute repo-root prefix so the two rendered streams are comparable.
  seed=$(printf '%s\n' "$seed" | grep -v '^error: CheckFailed$' | sed "s#--> ${ROOT}#--> #")
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
echo "check differential: MATCH=$match MISSING=$missing FALSEPOS=$falsepos DIFF=$diff TIMEOUT=$timeout"
if [ -n "$firstfp" ]; then
  echo "=== FIRST FALSE POSITIVE (bit2 rejects code the seed accepts): $firstfp"
  run "$BIT2" check "$firstfp" | head -8
fi
if [ -n "$firstdiff" ]; then
  echo "=== first differing text: $firstdiff"
  diff <(run "$ORACLE" check "$firstdiff" | grep -v '^error: CheckFailed$' | sed "s#--> ${ROOT}#--> #") \
       <(run "$BIT2" check "$firstdiff") | head -14
fi
# Only a false positive is a build-breaking regression; MISSING shrinks as emit
# sites land, and DIFF is dominated by cascades from unported root sites.
if [ "$falsepos" -ne 0 ]; then
  exit 1
fi
# A timeout decided nothing — neither a match nor a divergence. Exit 2
# (could-not-decide) keeps it visible without claiming a result that was never
# observed, and keeps it out of the pinned MISSING/FALSEPOS counts.
if [ "$timeout" -gt 0 ]; then
  echo "first timeout: $firsthang"
  echo "UNDECIDED: $timeout file(s) timed out after ${TIMEOUT_S}s x2 and were NOT compared."
  echo "           Not a pass. Re-run on a quieter host, or raise TIMEOUT_S."
  echo "           If it reproduces on an idle host, that is a real hang in a compiler."
  exit 2
fi
exit 0
