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

# Self-check: run directly (not sourced) to assert explainMismatch explains each
# declared signature's divergence and nothing unrelated (see scripts/selfhost-ir-
# signatures.sh's Declared signatures), and that declaredSignatureNames() stays
# in sync with it.
# `bash scripts/selfhost-ir-signatures-selfcheck.sh`. Same pattern as
# scripts/selfhost-ir-canon.sh's self-check.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -u
  fail=0

  # Every signature this check once carried a fixture for is RETIRED; the
  # list, and the repin that retired each, is in scripts/selfhost-ir-
  # signatures.sh's Retirement history. An unrelated divergence of any shape
  # must stay unexplained on every kind.
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

  # --- the signatures declared against the 0.40.0 oracle (#7558, #7562) ---
  #
  # Each fixture is a reduced copy of the real divergence; each negative variant
  # breaks exactly one clause of the identity and must stay unexplained.
  expect() { # <want name or ""> <got> <label>
    if [ "$1" != "$2" ]; then
      echo "FAIL: $3: want '$1' got '$2'"
      fail=1
    fi
  }

  # 7558-synth-json-alias-column-shift: only a column moves, on a synthesized line.
  ty_o='30:135: __json_entries: []JsonEntry
30:199: __json_a4: []Json
30:300: cols: []string
31:5: x: i64'
  ty_b='30:154: __json_entries: []JsonEntry
30:218: __json_a4: []Json
30:319: cols: []string
31:5: x: i64'
  expect "7558-synth-json-alias-column-shift" "$(explainMismatch "$ty_o" "$ty_b" types)" "types: column shift"
  expect "" "$(explainMismatch "$ty_o" "${ty_b/a4: []Json/a4: []JsonEntry}" types)" "types: a type changed"
  expect "" "$(explainMismatch "$ty_o" "${ty_b/__json_a4/__json_a5}" types)" "types: a name changed"
  expect "" "$(explainMismatch "$ty_o" "${ty_b/31:5:/31:6:}" types)" "types: a column moved on a line that is not synthesized"
  expect "" "$(explainMismatch "$ty_o" "${ty_b/30:218:/30:150:}" types)" "types: a column moved left"
  expect "" "$(explainMismatch "$ty_o" "${ty_b/30:218:/31:218:}" types)" "types: a line number changed"
  expect "" "$(explainMismatch "$ty_o" "${ty_b/30:319:/30:300:}" types)" "types: a row after the shift did not move"
  expect "" "$(explainMismatch "$ty_o" "$(printf '%s\n' "$ty_b" | sed 1d)" types)" "types: a row is missing"

  # 7562-packed-halfword-slices: the word-strided halfword slice shapes become the packed ones.
  ir_head='func f(%0: []u16) void {
bb0(%0: []u16):
  %1 = const_int i64 0
  %2 = slice_len %0
  %3 = icmp_ult bool %1, %2
  br %3, bb2(), bb1()
bb1():
  %4 = const_string "index out of range"
  %5 = rt_call panic(%4) void
  unreachable
bb2():
  %6 = field_get %0[0] i64
  %7 = field_get %0[16] i64
  %8 = add i64 %7, %1'
  ir_o="$ir_head
  %9 = const_int i64 3
  %10 = shl i64 %8, %9
  %11 = add i64 %6, %10
  %12 = field_get %11[0] u16
  %13 = rt_call string_from_int(%12) string
  ret
}"
  ir_b="$ir_head
  %9 = index_get %6[%8] u16
  %10 = rt_call string_from_int(%9) string
  ret
}"
  expect "7562-packed-halfword-slices" "$(explainMismatch "$ir_o" "$ir_b" ir)" "ir: scaled read becomes index_get"
  expect "7562-packed-halfword-slices" "$(explainMismatch "$ir_o" "$ir_b" iropt)" "iropt: scaled read becomes index_get"
  expect "" "$(explainMismatch "$ir_o" "${ir_b/string_from_int/string_from_uint}" ir)" "ir: an unrelated call changed"
  expect "" "$(explainMismatch "${ir_o//u16/u64}" "${ir_b//u16/u64}" ir)" "ir: a u64 slice is a word and never packed"
  expect "" "$(explainMismatch "$ir_o" "$(printf '%s\n' "$ir_b" | sed 's/index_get %6\[%8\]/index_get %6[%1]/')" ir)" "ir: the packed read takes another index"
  expect "" "$(explainMismatch "$ir_o" "$ir_o" ir)" "ir: a tree that kept the word stride is not explained by the packing"
  ir_new_o='bb0():
  %0 = const_int i64 4
  %1 = const_int i64 0
  %2 = const_int i64 8
  %3 = rt_call slice_new(%0, %0, %1, %2) []i16
  %4 = const_int i16 7
  %5 = const_int i64 0
  %6 = convert i64 %4
  %7 = field_get %3[0] i64
  index_set %7[%5] = %6
  ret'
  ir_new_b='bb0():
  %0 = const_int i64 4
  %1 = const_int i64 0
  %2 = const_int i64 2
  %3 = rt_call slice_new(%0, %0, %1, %2) []i16
  %4 = const_int i16 7
  %5 = const_int i64 0
  %6 = field_get %3[0] i64
  index_set %6[%5] = %4
  ret'
  expect "7562-packed-halfword-slices" "$(explainMismatch "func g() void {
$ir_new_o
}" "func g() void {
$ir_new_b
}" ir)" "ir: elem_size 2, the narrow store"
  expect "" "$(explainMismatch "func g() void {
${ir_new_o//i16/i32}
}" "func g() void {
${ir_new_b//i16/i32}
}" ir)" "ir: an i32 slice packed at the halfword 2"
  ir_new_4=$(printf '%s\n' "$ir_new_b" | sed 's/%2 = const_int i64 2/%2 = const_int i64 4/')
  expect "" "$(explainMismatch "func g() void {
$ir_new_o
}" "func g() void {
$ir_new_4
}" ir)" "ir: elem_size is neither 8 nor the packed 2"

  # 7574-packed-narrow-slices: the same shapes for i8/bool (1 byte) and i32/u32/f32 (4 bytes).
  ir_o32="${ir_o//u16/u32}"
  ir_b32="${ir_b//u16/u32}"
  expect "7574-packed-narrow-slices" "$(explainMismatch "$ir_o32" "$ir_b32" ir)" "ir: a u32 scaled read becomes index_get"
  expect "7574-packed-narrow-slices" "$(explainMismatch "$ir_o32" "$ir_b32" iropt)" "iropt: a u32 scaled read becomes index_get"
  expect "7574-packed-narrow-slices" "$(explainMismatch "${ir_o//u16/f32}" "${ir_b//u16/f32}" ir)" "ir: an f32 scaled read becomes index_get"
  expect "7574-packed-narrow-slices" "$(explainMismatch "${ir_o//u16/bool}" "${ir_b//u16/bool}" ir)" "ir: a bool scaled read becomes index_get"
  expect "" "$(explainMismatch "$ir_o32" "$ir_o32" ir)" "ir: a u32 read that kept the word stride is not explained"
  expect "" "$(explainMismatch "$ir_o32" "$(printf '%s\n' "$ir_b32" | sed 's/index_get %6\[%8\]/index_get %6[%1]/')" ir)" "ir: a packed u32 read takes another index"
  ir_wrong_stride=$(printf '%s\n' "$ir_o32" | sed 's/{const_int i64 3}/{const_int i64 2}/; s/%9 = const_int i64 3/%9 = const_int i64 2/')
  expect "" "$(explainMismatch "$ir_o32" "$ir_wrong_stride" ir)" "ir: a read re-strided to a shift of 2 stays unexplained"
  ir_new_i32_4=$(printf '%s\n' "${ir_new_b//i16/i32}" | sed 's/%2 = const_int i64 2/%2 = const_int i64 4/')
  expect "7574-packed-narrow-slices" "$(explainMismatch "func g() void {
${ir_new_o//i16/i32}
}" "func g() void {
$ir_new_i32_4
}" ir)" "ir: an i32 slice at elem_size 4, the narrow store"
  expect "" "$(explainMismatch "func g() void {
${ir_new_o//i16/i32}
}" "func g() void {
${ir_new_b//i16/i32}
}" ir)" "ir: an i32 slice at elem_size 2 is a wrong stride"
  ir_new_i8=$(printf '%s\n' "${ir_new_b//i16/i8}" | sed 's/%2 = const_int i64 2/%2 = const_int i64 1/')
  expect "7574-packed-narrow-slices" "$(explainMismatch "func g() void {
${ir_new_o//i16/i8}
}" "func g() void {
$ir_new_i8
}" ir)" "ir: an i8 slice at elem_size 1"
  expect "" "$(explainMismatch "func g() void {
${ir_new_o//i16/i8}
}" "func g() void {
${ir_new_b//i16/i8}
}" ir)" "ir: an i8 slice at elem_size 2 is a wrong stride"

  # 7574, the f32 element store: slice_set through bitcast becomes the inline store.
  f32_o='bb0(%0: []f32, %1: f32):
  %2 = const_int i64 0
  %3 = bitcast u32 %1
  %4 = const_int i64 8
  %5 = rt_call slice_set(%0, %2, %3, %4) void
  ret'
  f32_fill='bb0(%0: []f32, %1: f32):
  %2 = const_int i64 0
  %3 = field_get %0[0] i64
  index_set %3[%2] = %1
  ret'
  f32_chk='bb0(%0: []f32, %1: f32):
  %2 = const_int i64 0
  %3 = slice_len %0
  %4 = icmp_ult bool %2, %3
  br %4, bb1(), bb2()
bb2():
  %5 = const_string "index out of range"
  %6 = rt_call panic(%5) void
  unreachable
bb1():
  %7 = field_get %0[0] i64
  %8 = field_get %0[16] i64
  %9 = add i64 %8, %2
  index_set %7[%9] = %1
  ret'
  f32_other=$(printf '%s\n' "$f32_fill" | sed 's/index_set %3\[%2\]/index_set %3[%1]/')
  expect "7574-packed-narrow-slices" "$(explainMismatch "func g() void {
$f32_o
}" "func g() void {
$f32_fill
}" ir)" "ir: an f32 literal store inline"
  expect "7574-packed-narrow-slices" "$(explainMismatch "func g() void {
$f32_o
}" "func g() void {
$f32_chk
}" ir)" "ir: an f32 checked store inline"
  expect "" "$(explainMismatch "func g() void {
$f32_o
}" "func g() void {
$f32_other
}" ir)" "ir: an f32 store at another index"
  expect "" "$(explainMismatch "func g() void {
$f32_o
}" "func g() void {
$f32_o
}" ir)" "ir: a tree that kept the f32 slice_set is not explained by the inline store"

  # 7574, the f32 element read: slice_get through bitcast, or the tree's guarded index_get. Both
  # sides are canonicalized, so a tree that still reads through slice_get (at elem_size 4) agrees too.
  f32_ld_o='bb0(%0: []f32):
  %1 = const_int i64 0
  %2 = const_int i64 8
  %3 = rt_call slice_get(%0, %1, %2) u32
  %4 = bitcast f32 %3
  %5 = rt_call string_from_float(%4) string
  ret'
  f32_ld_chk='bb0(%0: []f32):
  %1 = const_int i64 0
  %2 = slice_len %0
  %3 = icmp_ult bool %1, %2
  br %3, bb1(), bb2()
bb2():
  %4 = const_string "index out of range"
  %5 = rt_call panic(%4) void
  unreachable
bb1():
  %6 = field_get %0[0] i64
  %7 = field_get %0[16] i64
  %8 = add i64 %7, %1
  %9 = index_get %6[%8] f32
  %10 = rt_call string_from_float(%9) string
  ret'
  expect "7574-packed-narrow-slices" "$(explainMismatch "func g() void {
$f32_ld_o
}" "func g() void {
$f32_ld_chk
}" ir)" "ir: an f32 guarded read inline"
  expect "7574-packed-narrow-slices" "$(explainMismatch "func g() void {
$f32_ld_o
}" "func g() void {
${f32_ld_o/i64 8/i64 4}
}" ir)" "ir: an f32 read through slice_get at the packed elem_size 4"
  expect "" "$(explainMismatch "func g() void {
$f32_ld_o
}" "func g() void {
${f32_ld_o/i64 8/i64 2}
}" ir)" "ir: an f32 read at elem_size 2 is a wrong stride"
  expect "" "$(explainMismatch "func g() void {
$f32_ld_o
}" "func g() void {
${f32_ld_chk/icmp_ult bool %1, %2/icmp_ult bool %2, %2}
}" ir)" "ir: an f32 read whose guard tests another index"
  expect "" "$(explainMismatch "func g() void {
$f32_o
}" "func g() void {
${f32_chk/icmp_ult bool %2, %3/icmp_ult bool %3, %3}
}" ir)" "ir: an f32 store whose guard tests another index"


  # 7637-string-from-rune-range: string(rs[lo:hi]) on a []rune.
  rr_o='func f(%0: []i32, %1: i64, %2: i64) string {
bb0(%0: []i32, %1: i64, %2: i64):
  %3 = rt_call string_from_byte_range(%0, %1, %2) string
  ret %3
}'
  rr_b="${rr_o//string_from_byte_range/string_from_rune_range}"
  expect "7637-string-from-rune-range" "$(explainMismatch "$rr_o" "$rr_b" ir)" "ir: a []rune range call"
  expect "7637-string-from-rune-range" "$(explainMismatch "$rr_o" "$rr_b" iropt)" "iropt: a []rune range call"
  expect "" "$(explainMismatch "${rr_o//i32/u8}" "${rr_b//i32/u8}" ir)" "ir: a []u8 receiver keeps string_from_byte_range"
  expect "" "$(explainMismatch "$rr_o" "$rr_o" ir)" "ir: a []rune call that stayed a byte range is not explained"
  expect "" "$(explainMismatch "$rr_o" "${rr_b/\(%0, %1, %2\)/(%0, %2, %1)}" ir)" "ir: a range call with swapped bounds"

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
  want=$(grep -hoE 'print "[0-9]+-[a-z-]+"' "${ROOT}/scripts/selfhost-ir-signatures.sh" "${ROOT}/scripts/ir-signatures-walk.sh" |
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
