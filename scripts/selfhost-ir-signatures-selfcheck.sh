#!/usr/bin/env bash
# Self-check for scripts/selfhost-ir-signatures.sh's explainMismatch, split
# into its own file by #5442 so the main file (which both selfhost-diffdump.sh
# and selfhost-diffruntime.sh source) stays under the 800-line ceiling
# (spec/LINT.md) as new signatures are added. Discovered and run directly by
# scripts/selfhost-diffall.sh's `scripts/selfhost-*.sh` glob, same as the
# file it tests.
ROOT="$(cd -- "$(dirname -- "$0")/.." && pwd)"
# shellcheck source=scripts/selfhost-ir-signatures.sh
. "${ROOT}/scripts/selfhost-ir-signatures.sh"

# Self-check: run directly (not sourced) to assert each declared signature
# explains its own shape and nothing wider (see scripts/selfhost-ir-
# signatures.sh's header), and that declaredSignatureNames() stays in sync
# with it. `bash scripts/selfhost-ir-signatures-selfcheck.sh`. Same pattern as
# scripts/selfhost-ir-canon.sh's self-check.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -u
  fail=0

  # expect <label> <oracle> <tree> <kind> <want-name or empty>: the verdict of
  # explainMismatch must be exactly <want-name> (empty means unexplained).
  expect() {
    local sig rc
    sig=$(explainMismatch "$2" "$3" "$4" "_tests_/cases/selfcheck.bit")
    rc=$?
    if [ -n "$5" ] && { [ "$rc" -ne 0 ] || [ "$sig" != "$5" ]; }; then
      echo "FAIL: $1: expected '$5' (rc=$rc sig='$sig')"
      fail=1
    fi
    if [ -z "$5" ] && { [ "$rc" -eq 0 ] || [ -n "$sig" ]; }; then
      echo "FAIL: $1: wrongly explained (rc=$rc sig='$sig')"
      fail=1
    fi
  }

  # An unrelated divergence of any shape stays unexplained on every kind.
  oracle_unrelated='%1 = sub %2, %3'
  bit2_unrelated='%1 = sub %2, %3
%4 = sub %5, %6'
  for kind in ir iropt ast fmt types diags tokens; do
    expect "unrelated $kind delta" "$oracle_unrelated" "$bit2_unrelated" "$kind" ""
  done

  # --- 6679-generic-join-param-retype: only header param TYPES differ ---
  for kind in ir iropt; do
    expect "6679 positive ($kind)" 'bb3(%8: Node, %9: i64):' 'bb3(%8: Node, %9: Node):' "$kind" 6679-generic-join-param-retype
    expect "6679 header %id list differs ($kind)" 'bb3(%8: Node, %9: i64):' 'bb3(%8: Node, %10: Node):' "$kind" ""
    expect "6679 non-header line differs ($kind)" '  %1 = const_int i64 0' '  %1 = const_int i64 1' "$kind" ""
  done

  # --- 6570-fail-zero-decimal-box: decimal zero becomes a 16-byte box ---
  dec_oracle='func f() decimal! {
bb0():
  %0 = const_int i64 1
  %1 = const_int decimal 0
  ret %1
  %2 = add %0, %0
}'
  dec_tree='func f() decimal! {
bb0():
  %0 = const_int i64 1
  %1 = const_int i64 0
  %2 = const_int i64 0
  %3 = gc_alloc size=16 ptrs=[] (i64, i64)
  field_set %3[0] = %1
  field_set %3[8] = %2
  ret %3
  %4 = add %0, %0
}'
  for kind in ir iropt; do
    expect "6570 positive ($kind)" "$dec_oracle" "$dec_tree" "$kind" 6570-fail-zero-decimal-box
    expect "6570 size=24 ($kind)" "$dec_oracle" "${dec_tree/size=16/size=24}" "$kind" ""
    expect "6570 extra added line ($kind)" "$dec_oracle" "${dec_tree/  ret %3/  %9 = add %0, %0
  ret %3}" "$kind" ""
  done

  # --- 6564-arrow-ctor-seeded ---
  expect "6564 types positive" '60:19: x: <error>
61:18: y: int' '60:19: x: i64
61:18: y: int' types 6564-arrow-ctor-seeded
  expect "6564 types tree side is <error>" '60:19: x: i64' '60:19: x: <error>' types ""
  arrow_oracle='func closure$1(%0: fn(<invalid>) void, %1: <invalid>) void {
bb0(%0: fn(<invalid>) void, %1: <invalid>):
  %2 = call_closure %0(%1) void
}'
  arrow_tree='func closure$1(%0: fn([]u8) void!error, %1: []u8) void!error {
bb0(%0: fn([]u8) void!error, %1: []u8):
  %2 = call_closure %0(%1) void
  %3 = const_nil
  %4 = rt_call err_set(%3) void
}'
  for kind in ir iropt; do
    expect "6564 ir positive ($kind)" "$arrow_oracle" "$arrow_tree" "$kind" 6564-arrow-ctor-seeded
  done
  # The control proves the negative below fails only on the extra err_set
  # pair: the same closure with a filled `<invalid>` is explained without it.
  ok_oracle='func closure$1(%0: fn(i64) void!error) void!error {
bb0(%0: fn(i64) void!error):
  %1 = gc_alloc size=8 ptrs=[%0] fn(<invalid>) []u8
}'
  ok_tree='func closure$1(%0: fn(i64) void!error) void!error {
bb0(%0: fn(i64) void!error):
  %1 = gc_alloc size=8 ptrs=[%0] fn(i64) []u8
}'
  expect "6564 ir control, no err_set pair" "$ok_oracle" "$ok_tree" ir 6564-arrow-ctor-seeded
  expect "6564 ir extra err_set pair, oracle already void!error" "$ok_oracle" "${ok_tree/bb0(%0: fn(i64) void!error):/bb0(%0: fn(i64) void!error):
  %7 = const_nil
  %8 = rt_call err_set(%7) void}" ir ""

  # --- declaredSignatureNames() stays in sync with explainMismatch (#5509) ---
  #
  # The retirement check in scripts/selfhost-diffdump.sh's run_ir() only ever
  # asks declaredSignatureNames() what to look for; it never reads the awk
  # script. A name added to one list and not the other is silent everywhere
  # except here: extra-in-explainMismatch means a signature can fire but is
  # never checked for going dead; extra-in-declaredSignatureNames means a
  # live corpus run always reports it as explaining zero, because nothing
  # can ever print that name, which force-fails every future run with a
  # false "retired" verdict for a name that was never real.
  got=$(declaredSignatureNames | LC_ALL=C sort)
  # Unanchored on purpose (#5510 added `if (...) { print "…"; exit 0 }` on
  # one line, so `print "…"` no longer always starts the line) -- safe
  # against a false match inside `printf` because that is followed by `f`
  # then a SINGLE quote, never `print` immediately followed by a `"`.
  want=$(grep -oE 'print "[0-9]+-[a-z-]+"' "${ROOT}/scripts/selfhost-ir-signatures.sh" |
    grep -oE '"[0-9]+-[a-z-]+"' | tr -d '"' | LC_ALL=C sort -u)
  if [ "$got" != "$want" ]; then
    echo "FAIL: declaredSignatureNames() is out of sync with explainMismatch's print statements"
    echo "  declaredSignatureNames(): $(printf '%s' "$got" | tr '\n' ' ')"
    echo "  print \"…\" in the file:   $(printf '%s' "$want" | tr '\n' ' ')"
    fail=1
  fi

  if [ "$fail" -eq 0 ]; then
    echo "selfhost-ir-signatures-selfcheck.sh: self-check passed"
  fi
  exit "$fail"
fi
