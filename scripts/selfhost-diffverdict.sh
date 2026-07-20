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
#
# A TIMEOUT IS NOT A VERDICT (#1538). `verdict()` used to fold an alarm kill into
# "R", because it only read the truth of the `if` and never distinguished
# "rejected" from "never finished". That fabricates the exact signal this script
# exists to find: a timed-out SEED reads as seed=R bit=A, i.e. a MISSING — the
# #1470 shape — from a cell that was never actually decided. So a timeout is now
# its own verdict "T", counted separately and `continue`d before classification.
#
# Exit codes (matching x64gate.sh / selfhost-diffsafepoints.sh / 3977211):
#   0  every cell decided and the two checkers agree
#   1  real divergence: a MISSING or a FALSEPOS
#   2  could not decide: a cell timed out and was never compared. Not a pass.
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

match=0 missing=0 falsepos=0 timeout=0 n=0
missing_list="" falsepos_list="" timeout_list=""

# The alarm is a HANG guard, not a performance budget. These cells are tiny
# synthesized programs — measured worst legitimate case over the real corpus is
# 1.23s for a full multi-module file, and a cell here is far smaller — so 20s is
# never crossed by real work and a trip is a DESCHEDULED process, not a slow one.
# Rather than trade one arbitrary constant for another, a trip is RETRIED ONCE: a
# genuine hang trips twice, a load artifact does not. TIMEOUT_S overrides.
TIMEOUT_S=${TIMEOUT_S:-20}

# Verdict of one compiler on one program: prints "A" (accepted), "R" (rejected)
# or "T" (timed out — NOT a verdict; see the header). `check` is used rather than
# `build`: this asks a question about the CHECKER, and it keeps the sweep fast
# enough to gate on.
verdict() {
  local rc
  perl -e 'alarm shift; exec @ARGV' "$TIMEOUT_S" "$1" check "$2" >/dev/null 2>&1
  rc=$?
  if [ "$rc" -eq 142 ]; then
    perl -e 'alarm shift; exec @ARGV' "$TIMEOUT_S" "$1" check "$2" >/dev/null 2>&1
    rc=$?
  fi
  if [ "$rc" -eq 142 ]; then
    printf 'T'
  elif [ "$rc" -eq 0 ]; then
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
  # Undecided cells leave BEFORE classification, so a cell that never ran can
  # never meet another one and score MATCH, nor be read as a MISSING/FALSEPOS.
  if [ "$sv" = "T" ] || [ "$bv" = "T" ]; then
    timeout=$((timeout + 1))
    timeout_list="${timeout_list}    seed=$sv bit=$bv  ${label}
"
    return
  fi
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
# The other contexts that carry a DECLARED slot type. Each of these was a
# separate instance of the same hole — a slot whose declared type nothing ever
# compared the initializer against — and each was found by widening this matrix
# rather than by reading any code.
# ---------------------------------------------------------------------------
for e in $EXPRS; do
  # Struct-literal FIELD types. Held out until #1476: validating them needs a
  # checkExprType recompute on the field value, which panicked ("index out of
  # range") on every multi-module file reaching stdlib/http. That was a real
  # compiler bug (a cross-module decl node read against the wrong module's tree),
  # it is fixed, and these cells are live again — this was the last unchecked
  # declared-type slot in the language.
  cell "struct field S{ v: f32 } = $e" \
"struct S {
  v: f32,
}
function main() {
  let s = S{ v: $e }
  print(\"ok\")
}"
  cell "map value map<string,f32> = $e" \
"function main() {
  let m = map<string, f32>{\"k\": $e}
  print(\"ok\")
}"
  cell "map key map<i32,i32> = $e" \
"function main() {
  let m = map<i32, i32>{$e: 1}
  print(\"ok\")
}"
  cell "typed slice []f32{$e}" \
"function main() {
  let s = []f32{$e}
  print(\"ok\")
}"
  cell "module const c: f32 = $e" \
"const c: f32 = $e
function main() {
  print(\"ok\")
}"
  cell "module let g: f32 = $e" \
"let g: f32 = $e
function main() {
  print(\"ok\")
}"
  cell "chan send chan<f32> <- $e" \
"function main() {
  let c = chan<f32>(1)
  c <- $e
  print(\"ok\")
}"
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
# CONVERSIONS (§12.9). Added for #1490: `string(x)` on an i64 was accepted by the
# selfhost and SIGSEGV'd at runtime while the seed rejected it with E0053. This
# whole family was absent from the matrix above — every cell there carries a
# DECLARED slot type, and a conversion has none, so widening the type/expr
# product could never have reached it. That is the same lesson the header
# records: the corpus only holds what someone thought to write down.
#
# Both operands vary: the TARGET prim, and the SOURCE as a typed local (so the
# source is concrete, not untyped). The well-typed diagonal is included, so a
# checker that rejects every conversion scores FALSEPOS instead of passing.
# ---------------------------------------------------------------------------
CONV_TARGETS='i32 i64 u8 u64 f32 f64 bool string'
CONV_SOURCES='i32 i64 f64 bool string'

conv_init() {
  case "$1" in
    bool)   echo 'true' ;;
    string) echo '"s"' ;;
    f32|f64) echo '1.5' ;;
    *)      echo '1' ;;
  esac
}

for tgt in $CONV_TARGETS; do
  for src in $CONV_SOURCES; do
    init=$(conv_init "$src")
    cell "$tgt(x) where x: $src" \
"function main() {
  let x: $src = $init
  let y = $tgt(x)
  print(\"ok\")
}"
  done
  # `string([]u8)` is a conversion; every other target must reject a slice.
  cell "$tgt(x) where x: []u8" \
"function main() {
  let x: []u8 = []byte(\"s\")
  let y = $tgt(x)
  print(\"ok\")
}"
  # Untyped-literal sources take a different path in both checkers (§15.4) than
  # the concrete locals above, so they are their own row rather than a repeat.
  for lit in '1' '4.5' 'true' '"s"'; do
    cell "$tgt($lit)  (untyped literal)" \
"function main() {
  let y = $tgt($lit)
  print(\"ok\")
}"
  done
done

# ---------------------------------------------------------------------------
echo "verdict differential over $n generated constructs"
echo "  MATCH    $match"
echo "  MISSING  $missing   (seed rejects, selfhost accepts)"
echo "  FALSEPOS $falsepos   (selfhost rejects, seed accepts)"
echo "  TIMEOUT  $timeout   (never decided, NOT compared)"

rc=0
if [ "$missing" -ne 0 ]; then
  printf '\nMISSING — selfhost admits what the seed refuses:\n%s' "$missing_list"
  rc=1
fi
if [ "$falsepos" -ne 0 ]; then
  printf '\nFALSEPOS — selfhost refuses what the seed admits:\n%s' "$falsepos_list"
  rc=1
fi
# A timeout decided nothing — it is neither an agreement nor a divergence. It
# gates at 2 (could-not-decide), below a real divergence but never a pass.
if [ "$rc" -eq 0 ] && [ "$timeout" -ne 0 ]; then
  printf '\nUNDECIDED — %d cell(s) timed out after %ss x2 and were NOT compared:\n%s' \
    "$timeout" "$TIMEOUT_S" "$timeout_list"
  echo "Not a pass. Re-run on a quieter host, or raise TIMEOUT_S."
  exit 2
fi
[ "$rc" -eq 0 ] && echo "OK: the two checkers agree on every generated construct."
exit $rc
