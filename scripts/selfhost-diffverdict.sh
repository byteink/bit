#!/usr/bin/env bash
# Self-host VERDICT differential over a GENERATED construct matrix.
#
# WHY THIS EXISTS, given selfhost-diffcheck.sh already diffs accept/reject:
# diffcheck runs the *existing corpus* through both compilers. A construct that
# no corpus file happens to contain is invisible to it — and by construction the
# corpus only contains constructs someone already thought to write down. #1470
# (`let arr: [2]f32 = [4.5, 4.5]`: seed rejects, selfhost accepts and yields a
# wrong value) escaped every differential for exactly that reason, and surfaced
# only when a human typed it by hand.
#
# The other differentials are structurally blind here, not merely unlucky:
# difftypes/diffir/diffexamples all compare DUMPS, so when the seed refuses to
# emit there is no pair to compare and the case scores SKIP, not MISMATCH.
# A green board across all of them is not evidence about acceptance.
#
# So this script does not read the corpus. It SYNTHESIZES a cross-product of
# small programs — declared type x initializer expression, across the contexts
# that share the assignability machinery (let binding, assignment, function
# return, call argument) — and diffs the two compilers' accept/reject VERDICT
# rather than their output. Most cells are expected to be rejected by both; the
# signal is any cell where they disagree.
#
# Four outcomes:
#   MATCH    both accept, or both reject
#   MISSING  seed rejects, selfhost accepts  — the #1470 shape. A hole in the
#            selfhost checker, and the dangerous one: it admits a program the
#            language does not define, which then miscompiles silently.
#   FALSEPOS selfhost rejects, seed accepts  — selfhost refusing valid code.
#   (Both are reported; either being non-zero fails the script.)
#
# This compares VERDICTS, not diagnostic text: diagnostic-text parity over the
# corpus is diffcheck's job, and demanding it here would drown the acceptance
# signal in wording differences. A cell where both reject with different codes
# is a MATCH here and diffcheck's problem there.
#
# Usage: zig build && bash scripts/selfhost-diffverdict.sh [-v]
set -u
SEED=zig-out/bin/bit-seed
BIT2=zig-out/bin/bit
VERBOSE=0
[ "${1:-}" = "-v" ] && VERBOSE=1

for b in "$SEED" "$BIT2"; do
  [ -x "$b" ] || { echo "missing $b — run: zig build" >&2; exit 1; }
done

TMP=$(mktemp -d "${TMPDIR:-/tmp}/bitverdict.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT

match=0 missing=0 falsepos=0 n=0
missing_list="" falsepos_list=""

# Verdict of one compiler on one program: prints "A" (accepted) or "R".
# `check` is used rather than `build`: this asks a question about the CHECKER,
# and it keeps the sweep fast enough to gate on. A 20s alarm bounds a hang so a
# stuck cell cannot wedge the run.
verdict() {
  if perl -e 'alarm 20; exec @ARGV' "$1" check "$2" >/dev/null 2>&1; then
    printf 'A'
  else
    printf 'R'
  fi
}

# One cell: a label and a complete program body.
cell() {
  local label="$1" prog="$2"
  n=$((n + 1))
  local f="$TMP/c$n.bit"
  printf '%s\n' "$prog" > "$f"
  local sv bv
  sv=$(verdict "$SEED" "$f")
  bv=$(verdict "$BIT2" "$f")
  if [ "$sv" = "$bv" ]; then
    match=$((match + 1))
    [ "$VERBOSE" = 1 ] && printf '  MATCH    (%s%s) %s\n' "$sv" "$bv" "$label"
  elif [ "$sv" = "R" ]; then
    missing=$((missing + 1))
    missing_list="${missing_list}    seed=R bit=A  ${label}
"
  else
    falsepos=$((falsepos + 1))
    falsepos_list="${falsepos_list}    seed=A bit=R  ${label}
"
  fi
}

# ---------------------------------------------------------------------------
# The matrix. TYPES x EXPRS is the core: every declared type against every
# initializer expression, in four contexts that all route through assignability.
# Deliberately includes the well-typed diagonal, so a checker that rejects
# EVERYTHING scores FALSEPOS rather than passing.
# ---------------------------------------------------------------------------
TYPES='i32 i64 f32 f64 bool string []i32 []f32 [2]i32 [2]f32'
EXPRS='1 4.5 true "s" [1,2] [4.5,4.5] [1,2,3]'

for t in $TYPES; do
  for e in $EXPRS; do
    cell "let x: $t = $e" \
"function main() {
  let x: $t = $e
  print(\"ok\")
}"
    cell "var x: $t; x = $e" \
"function main() {
  var x: $t
  x = $e
  print(\"ok\")
}"
    cell "function f(): $t { return $e }" \
"function f(): $t {
  return $e
}
function main() {
  print(\"ok\")
}"
    cell "f(p: $t) called with $e" \
"function f(p: $t) {
  print(\"ok\")
}
function main() {
  f($e)
}"
  done
done

# ---------------------------------------------------------------------------
# Array-specific shapes. #1470's worst cell is a LENGTH mismatch, which is a
# memory-safety hole rather than a wrong value: the selfhost accepted
# `let a: [4]i32 = [1,2]` and a[0] read uninitialized heap.
# ---------------------------------------------------------------------------
for decl in '[1]i32' '[2]i32' '[3]i32' '[4]i32'; do
  for lit in '[1]' '[1,2]' '[1,2,3]'; do
    cell "let a: $decl = $lit  (length)" \
"function main() {
  let a: $decl = $lit
  print(\"ok\")
}"
  done
done

# Typed composite-literal form: the ONLY array construction SPEC.md admits
# (§11.2, §12.3). Length agreement must be accepted, disagreement rejected.
for n_ in 1 2 3; do
  for lit in '4.5' '4.5, 4.5' '4.5, 4.5, 4.5'; do
    cell "let a: [$n_]f32 = [$n_]f32{$lit}" \
"function main() {
  let a: [$n_]f32 = [$n_]f32{$lit}
  print(\"ok\")
}"
  done
done

# ---------------------------------------------------------------------------
echo "verdict differential over $n generated constructs"
echo "  MATCH    $match"
echo "  MISSING  $missing   (seed rejects, selfhost accepts)"
echo "  FALSEPOS $falsepos   (selfhost rejects, seed accepts)"

rc=0
if [ "$missing" -ne 0 ]; then
  printf '\nMISSING — selfhost admits what the seed refuses:\n%s' "$missing_list"
  rc=1
fi
if [ "$falsepos" -ne 0 ]; then
  printf '\nFALSEPOS — selfhost refuses what the seed admits:\n%s' "$falsepos_list"
  rc=1
fi
[ "$rc" -eq 0 ] && echo "OK: the two checkers agree on every generated construct."
exit $rc
