#!/usr/bin/env bash
# Self-host `bit doc` differential (#1590): run every corpus MODULE through both
# compilers' `doc` and compare the exported-surface bytes. `doc` derives a
# module's public API from the checker (not a text scrape), and `tests/bit/stdlibdocs.bit`
# fails the build on any undocumented export — so this surface is a live gate.
# This is the standing differential that keeps the
# two `doc` implementations in step.
#
# ## What is being compared
#
# `bit-seed doc <dir>` output vs `bit doc <dir>` output, in BOTH forms — the plain
# "<kind> <name> <type>" listing and the `--json` array. The unit is a module
# DIRECTORY, not a `.bit` file: `bit doc` documents a whole module (its files are
# concatenated), and a lone-file root has no doc form (SPEC §17.1). So the corpus
# is `stdlib/*/`, `examples/*/` and `tests/imports/*/`, not a `-name '*.bit'` glob.
#
# ## The seed is the oracle
#
# A directory the seed cannot `doc` (an internal helper dir that is not a module,
# or a module that does not compile) is out of scope and SKIPPED — exactly as
# difftypes skips files the seed's checker rejects. Only the two compilers
# disagreeing on a module the seed DID document is a finding.
#
# ## Preconditions are hard failures, never a vacuous green (#1514)
#
# Two gates: a missing binary aborts, and a compiler that does not IMPLEMENT `doc`
# aborts as ABSENT rather than scoring zero modules as agreement. A surface that
# does not exist has not been verified to match; it has not been tested at all,
# and those are opposite claims. And a corpus floor: comparing zero modules is
# never agreement (#1516).
#
# Read the exit code of the thing being tested, on its own line — never through a
# pipe (a `| tail` returns tail's status, which is how a red diffir read green,
# #1568). Nothing is inferred from output text.
#
# Usage: ./make selfhost && bash scripts/selfhost-diffdoc.sh
set -uo pipefail
# The oracle is the PINNED STAGE0: the previous release, i.e. an EARLIER VERSION
# OF THIS SAME COMPILER — which is exactly what limits the claim below.
# scripts/stage0.sh downloads and DIGEST-VERIFIES it, and refuses rather
# than skipping. What a green run asserts changed with it: "unchanged versus the
# last release", not "two implementations agree" — docs/release/bootstrap.md §4/§5.
ORACLE=${DIFFDOC_ORACLE:-$(sh scripts/stage0.sh)} || exit 2
# Overridable so the script can be mutation-tested against a known-agreeing and a
# known-disagreeing doc surface. The verdict line names what was actually compared.
BIT2=${DIFFDOC_BIT:-bit-out/bin/bit}

for bin in "$ORACLE" "$BIT2"; do
  [ -x "$bin" ] || { echo "diffdoc: missing $bin — run: ./make selfhost" >&2; exit 2; }
done

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# Capability probe, not a verdict: `doc` a throwaway module and see whether the
# subcommand exists at all. Exit status alone cannot tell "doc rejected this" from
# "there is no doc", so the usage text is what distinguishes them.
probe_doc() {
  local bin=$1 dir="$work/probe.$2"
  mkdir -p "$dir"
  printf 'export function inc(n: i64): i64 {\n  return n + 1\n}\n' >"$dir/m.bit"
  local out
  out=$("$bin" doc "$dir" 2>&1)
  if printf '%s' "$out" | grep -q 'unknown subcommand'; then
    return 1
  fi
  return 0
}

absent=""
probe_doc "$ORACLE" seed || absent="$absent $ORACLE"
probe_doc "$BIT2" bit2 || absent="$absent $BIT2"
if [ -n "$absent" ]; then
  echo "diffdoc: ABSENT — no \`doc\` subcommand in:$absent"
  echo "diffdoc: nothing was compared. This is NOT agreement — the surface is unimplemented."
  exit 2
fi

: >"$work/mismatch"
match=0 skip=0

for d in stdlib/*/ examples/*/ tests/imports/*/; do
  [ -d "$d" ] || continue

  "$ORACLE" doc "$d" >"$work/seed.plain" 2>/dev/null
  seed_rc=$?
  # The seed is the oracle: a directory it cannot document is out of scope.
  if [ "$seed_rc" -ne 0 ]; then
    skip=$((skip + 1))
    continue
  fi
  "$ORACLE" doc --json "$d" >"$work/seed.json" 2>/dev/null

  "$BIT2" doc "$d" >"$work/bit.plain" 2>/dev/null
  bit_rc=$?
  "$BIT2" doc --json "$d" >"$work/bit.json" 2>/dev/null
  bit_json_rc=$?

  if [ "$bit_rc" -ne 0 ] || [ "$bit_json_rc" -ne 0 ]; then
    echo "$d (bit doc exit $bit_rc / --json exit $bit_json_rc, seed exit 0)" >>"$work/mismatch"
    continue
  fi

  if cmp -s "$work/seed.plain" "$work/bit.plain" && cmp -s "$work/seed.json" "$work/bit.json"; then
    match=$((match + 1))
  else
    echo "$d" >>"$work/mismatch"
  fi
done

mismatch=$(wc -l <"$work/mismatch" | tr -d ' ')
compared=$((match + mismatch))
echo "doc differential ($ORACLE vs $BIT2): MATCH=$match MISMATCH=$mismatch SKIP(not a module)=$skip"

# Corpus floor (#1516): comparing nothing is not agreement.
if [ "$compared" -eq 0 ]; then
  echo
  echo "INVALID: zero modules were compared — no evidence of agreement."
  exit 2
fi

if [ -s "$work/mismatch" ]; then
  echo
  # EVERY divergence, named — a "first divergence" report leaves the rest invisible.
  echo "MISMATCH: $mismatch module(s) the two doc surfaces render differently:"
  while read -r d; do echo "  $d"; done <"$work/mismatch"
  head -3 "$work/mismatch" | while read -r d; do
    dir=${d%% *}
    echo
    echo "--- diff (seed vs bit): $dir"
    "$ORACLE" doc "$dir" >"$work/da" 2>/dev/null
    "$BIT2" doc "$dir" >"$work/db" 2>/dev/null
    diff "$work/da" "$work/db" | head -12
  done
  exit 1
fi

echo
echo "diffdoc: the two doc surfaces agree on every compared module."
exit 0
