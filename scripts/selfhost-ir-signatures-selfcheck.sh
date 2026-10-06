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

# Self-check: run directly (not sourced) to assert explainMismatch explains
# each declared signature's real divergence and nothing unrelated (see
# scripts/selfhost-ir-signatures.sh's Retirement history), and that
# declaredSignatureNames() stays in sync with it.
# `bash scripts/selfhost-ir-signatures-selfcheck.sh`. Same pattern as
# scripts/selfhost-ir-canon.sh's self-check.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -u
  fail=0

  # Every signature this check once carried a fixture for is RETIRED; the
  # list, and the repin that retired each, is in scripts/selfhost-ir-
  # signatures.sh's Retirement history, and the fixtures are in git history at
  # this file's state before #6527. With nothing declared, an unrelated
  # divergence of any shape must stay unexplained on every kind.
  oracle_unrelated='%1 = sub %2, %3'
  bit2_unrelated='%1 = sub %2, %3
%4 = sub %5, %6'
  for kind in ir iropt ast fmt types diags tokens; do
    sig=$(explainMismatch "$oracle_unrelated" "$bit2_unrelated" "$kind" "_tests_/cases/run_bound_static_amp.bit")
    rc=$?
    if [ "$rc" -eq 0 ] || [ -n "$sig" ]; then
      echo "FAIL: an unrelated $kind delta was wrongly explained (rc=$rc sig='$sig')"
      fail=1
    fi
  done

  # --- the signatures declared against the 0.39.0 oracle (#7451) ---
  #
  # Each fixture is a reduced copy of the real divergence; the negative
  # variants break exactly one clause of the identity.
  expect() { # <want name or ""> <got> <label>
    if [ "$1" != "$2" ]; then
      echo "FAIL: $3: want '$1' got '$2'"
      fail=1
    fi
  }
  at='  --> m.bit:3:17
   |
3 |   export static count(): i64 {
   |                 ^^^^^'
  static_o="error[E0021]: expected '(', found an identifier
$at
error[E0021]: expected ':', found '('
  --> m.bit:3:22
   |
3 |   export static count(): i64 {
   |                      ^
error[E0021]: expected '}', found end of file
  --> m.bit:4:1"
  eof_t="error[E0021]: expected '}', found end of file
  --> m.bit:4:1"
  expect 6403-enum-static-method-presyntax "$(explainMismatch "$static_o" "$eof_t" diags)" "static head and cascade"
  expect "" "$(explainMismatch "$static_o" "" diags)" "static: the tree lost the truncation error too"
  expect "" "$(explainMismatch "${static_o}
error[E0001]: unrelated
  --> m.bit:9:1" "$eof_t" diags)" "static: an extra oracle record"
  kw_o="error[E0021]: 'as' is a reserved keyword
  --> m.bit:2:10
   |
2 |   export as(a: Actor): string {
   |          ^^ reserved words cannot be used as identifiers (SPEC §5.2)"
  expect 7035-keyword-member-name-presyntax "$(explainMismatch "$kw_o" "" diags)" "keyword method name"
  expect "" "$(explainMismatch "$(printf '%s' "$kw_o" | sed 's/as(a/as: a/')" "" diags)" "keyword field name stays rejected"
  mkdir -p "${TMPDIR:-/tmp}" && mf=$(mktemp "${TMPDIR:-/tmp}/ir-sig-selfcheck.XXXXXX")
  printf 'fn a(c: bool): string { return render(c ? <a>a#b</a> : <b>no</b>) }\n' >"$mf"
  panic_o='panic: slice bounds out of range'
  expect 6421-ternary-jsx-hash-oracle-panic "$(explainMismatch "$panic_o" "" diags "$mf")" "oracle panic on a ternary JSX then with #"
  expect "" "$(explainMismatch "$panic_o" "" diags)" "oracle panic without the input file"
  expect "" "$(explainMismatch "$panic_o" "$static_o" diags "$mf")" "oracle panic against a tree that errors"
  printf 'fn a(): int { return 1 }\n' >"$mf"
  expect "" "$(explainMismatch "$panic_o" "" diags "$mf")" "oracle panic on an input without the construct"
  rm -f "$mf"
  jo='  let p = <p>it'"'"'s</p>;'
  jt='  let p = <p>it'"'"'s</p>'
  expect 7380-jsx-text-apostrophe-stray-semicolon "$(explainMismatch "$jo" "$jt" fmt)" "stray ; after JSX text"
  expect "" "$(explainMismatch "  let p = <p>its</p>;" "  let p = <p>its</p>" fmt)" "stray ; with no apostrophe"
  expect "" "$(explainMismatch "$jo
let z = 1" "$jt" fmt)" "fmt: a longer oracle output"

  # --- the signatures declared against the 0.39.0 oracle (#7449) ---
  #
  # Reduced copies of the real divergences (the `ir` and `iropt` rows share one program); every
  # negative breaks exactly one clause of its identity.
  ok_o=$(cat <<'X'
func f(%0: Shape) void {
bb0(%0: Shape):
  %1 = type_info disc=59 size=8 ptrs=[] u64
  %2 = rt_call iface_as(%0, %1) Circle
  %3 = rt_call iface_as_ok() bool
  br %3, bb1(), bb2()
bb1():
  ret
bb2():
  ret
}
X
)
  ok_t=$(cat <<'X'
func f(%0: Shape) void {
bb0(%0: Shape):
  %1 = type_info disc=59 size=8 ptrs=[] u64
  %2 = rt_call iface_as(%0, %1) Circle
  %3 = const_nil
  %4 = icmp_ne bool %2, %3
  br %4, bb1(), bb2()
bb1():
  ret
bb2():
  ret
}
X
)
  for kind in ir iropt; do
    expect 7408-assert-ok-nil-compare "$(explainMismatch "$ok_o" "$ok_t" $kind)" "$kind: ok read as a nil compare"
    expect "" "$(explainMismatch "$ok_o" "${ok_t//icmp_ne/icmp_eq}" $kind)" "$kind: ok compared with the wrong predicate"
    expect "" "$(explainMismatch "$ok_o" "${ok_t//bool %2, %3/bool %0, %3}" $kind)" "$kind: ok compared on another value"
    expect "" "$(explainMismatch "$ok_o" "${ok_t//  %3 = const_nil/  %3 = const_nil
  %9 = sub %0, %0}" $kind)" "$kind: an unrelated extra line"
  done
  chain_o=$(cat <<'X'
func f(%0: Shape) E {
bb0(%0: Shape):
  %1 = const_int i64 0
  %2 = rt_call iface_has(%0, %1) E
  %3 = const_int i64 1
  %4 = rt_call iface_has(%2, %3) E
  ret %4
}
X
)
  chain_t=$(cat <<'X'
func f(%0: Shape) E {
bb0(%0: Shape):
  %1 = const_string "0,1"
  %2 = rt_call iface_implements(%0, %1) E
  ret %2
}
X
)
  expect 7406-iface-implements-call "$(explainMismatch "$chain_o" "$chain_t" ir)" "an iface_has chain became one iface_implements"
  expect "" "$(explainMismatch "$chain_o" "${chain_t//0,1/0,2}" ir)" "iface_implements with other ids"
  expect "" "$(explainMismatch "$chain_o" "${chain_t//iface_implements/iface_has}" iropt)" "iface_has kept by the tree"
  expect "" "$(explainMismatch "$chain_o" "$chain_t" types)" "an IR identity never explains a types dump"
  neg_o=$(cat <<'X'
func f(%0: i32) i32 {
bb0(%0: i32):
  %1 = const_int i32 5
  %2 = neg i32 %1
  %3 = add i32 %0, %2
  ret %3
}
X
)
  neg_t=$(cat <<'X'
func f(%0: i32) i32 {
bb0(%0: i32):
  %1 = const_int i32 -5
  %2 = add i32 %0, %1
  ret %2
}
X
)
  for kind in ir iropt; do
    expect 7069-neg-literal-const "$(explainMismatch "$neg_o" "$neg_t" $kind)" "$kind: neg of a literal became one negative const_int"
    expect "" "$(explainMismatch "$neg_o" "${neg_t//-5/-6}" $kind)" "$kind: a different constant"
    expect "" "$(explainMismatch "$neg_o" "${neg_t//add/sub}" $kind)" "$kind: a different operation"
  done
  range_o=$(cat <<'X'
func f(%0: i32) bool {
bb0(%0: i32):
  %1 = const_int i32 3
  %2 = neg i32 %1
  %3 = const_int i32 2
  %4 = neg i32 %3
  %5 = icmp_eq bool %0, %2
  %6 = icmp_eq bool %0, %4
  %7 = bor bool %5, %6
  br %7, bb1(), bb2()
bb1():
  ret %7
bb2():
  ret %7
}
X
)
  range_t=$(cat <<'X'
func f(%0: i32) bool {
bb0(%0: i32):
  %1 = const_int u32 4294967293
  %2 = sub u32 %0, %1
  %3 = const_int u32 1
  %4 = icmp_ule bool %2, %3
  br %4, bb1(), bb2()
bb1():
  ret %4
bb2():
  ret %4
}
X
)
  expect 7069-neg-literal-const "$(explainMismatch "$range_o" "$range_t" ir)" "negative labels became one range test"
  expect "" "$(explainMismatch "$range_o" "${range_t//u32 1/u32 2}" ir)" "range test with a wider width"
  expect "" "$(explainMismatch "$range_o" "${range_t//4294967293/4294967294}" ir)" "range test from another first label"
  loop_o=$(cat <<'X'
func f(%0: []i64, %1: []i64, %2: i64, %3: i64) []i64 {
bb0(%0: []i64, %1: []i64, %2: i64, %3: i64):
  %4 = const_int i64 0
  jump bb1(%0, %1, %2, %3, %4)
bb1(%5: []i64, %6: []i64, %7: i64, %8: i64, %9: i64):
  %10 = slice_len %6
  %11 = icmp_slt bool %9, %10
  br %11, bb2(), bb3(%5)
bb2():
  %13 = field_get %6[0] i64
  %14 = index_get %13[%9] i64
  %15 = rt_call slice_append(%5, %14, %7, %8) []i64
  %16 = const_int i64 1
  %17 = add i64 %9, %16
  jump bb1(%15, %6, %7, %8, %17)
bb3(%18: []i64):
  ret %18
}
X
)
  loop_t=$(cat <<'X'
func f(%0: []i64, %1: []i64, %2: i64, %3: i64) []i64 {
bb0(%0: []i64, %1: []i64, %2: i64, %3: i64):
  %4 = rt_call slice_append_slice(%0, %1, %2, %3) []i64
  ret %4
}
X
)
  expect 7377-append-spread-bulk-move "$(explainMismatch "$loop_o" "$loop_t" ir)" "an append spread loop became slice_append_slice"
  expect "" "$(explainMismatch "$loop_o" "${loop_t//(%0, %1, %2, %3)/(%1, %0, %2, %3)}" ir)" "slice_append_slice with swapped operands"
  expect "" "$(explainMismatch "${loop_o//  %4 = const_int i64 0/  %4 = const_int i64 1}" "$loop_t" ir)" "a loop that does not start at index 0"
  expect "" "$(explainMismatch "${loop_o//  %13 = field_get/  %12 = call @g() i64
  %13 = field_get}" "$loop_t" ir)" "a loop body holding another call"
  expect "" "$(explainMismatch "${loop_o//jump bb1(%15, %6, %7, %8, %17)/jump bb1(%15, %1, %7, %8, %17)}" "$loop_t" ir)" "a loop that replaces its source"
  omit_o=$(cat <<'X'
func g() void {
bb0():
  ret
}
X
)
  omit_t=$(cat <<'X'
func g() void {
bb0():
  ret
}

func h(%0: Cloner) Cloner {
bb0(%0: Cloner):
  %1 = call_iface %0.2() Cloner
  ret %1
}
X
)
  expect 7387-self-result-oracle-omits-function "$(explainMismatch "$omit_o" "$omit_t" ir)" "a function with a Self result the oracle never lowered"
  expect "" "$(explainMismatch "$omit_o" "${omit_t//%0.2() Cloner/%0.2() Other}" ir)" "a call whose result type is not its receiver type"
  expect "" "$(explainMismatch "$omit_t" "$omit_o" ir)" "a function only the oracle lowered"
  arrow_o=$(cat <<'X'
func g() void {
bb0():
  ret
}

func closure$1(%0: fn(<T>) <invalid>, %1: <T>) <invalid> {
bb0(%0: fn(<T>) <invalid>, %1: <T>):
  ret %0
}
X
)
  arrow_t=$(cat <<'X'
func g() void {
bb0():
  ret
}

func main() void {
bb0():
  ret
}

func closure$1(%0: fn(Row) bool, %1: Row) bool {
bb0(%0: fn(Row) bool, %1: Row):
  ret %0
}
X
)
  expect 7383-arrow-oracle-leaks-type-param "$(explainMismatch "$arrow_o" "$arrow_t" ir)" "an oracle closure with a leaked type"
  expect 7383-arrow-oracle-leaks-type-param "$(explainMismatch "$arrow_o" "$arrow_t" iropt)" "the same, post-opt (headers)"
  expect "" "$(explainMismatch "$arrow_o" "${arrow_t//main/other}" ir)" "a tree-only function that is not main or a closure"
  arrow_clean=${arrow_o//<T>/Row}
  expect "" "$(explainMismatch "${arrow_clean//<invalid>/bool}" "$arrow_t" ir)" "an oracle without the leak"
  ty_o="47:3: x.dup(): Self
48:3: d: Self
49:3: d.tag(): <error>"
  expect 7383-arrow-param-types "$(explainMismatch "45:28: r: T
46:40: r: <error>" "45:28: r: Row
46:40: r: Row" types)" "an arrow parameter typed T"
  expect 7387-self-result-types "$(explainMismatch "$ty_o" "47:3: x.dup(): T
48:3: d: Cloner
49:3: d.tag(): string" types)" "a Self result"
  expect "" "$(explainMismatch "45:28: r: T" "45:28: r: <error>" types)" "an arrow parameter the tree no longer types"
  expect "" "$(explainMismatch "45:28: r: T" "45:29: r: Row" types)" "an arrow parameter at another column"
  expect "" "$(explainMismatch "45:28: x.dup(): T" "45:28: x.dup(): Row" types)" "a call typed T is not a Self result"
  expect "" "$(explainMismatch "45:28: r: T
9:1: f: int" "45:28: r: Row
9:1: f: i64" types)" "a second, unrelated types difference"

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
  want=$(grep -hoE 'print "[0-9]+-[a-z-]+"|return "[0-9]+-[a-z-]+"' "${ROOT}/scripts/selfhost-ir-signatures.sh" "${ROOT}/scripts/ir-signatures-walk.sh" |
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
