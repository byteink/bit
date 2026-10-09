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
  # 7564-synth-table-alias-column-shift: the same rule on an @table synthesized line.
  tt_o='214:284: cols: []string
214:307: __row: Author
215:3: y: i64'
  tt_b='214:321: cols: []string
214:344: __row: Author
215:3: y: i64'
  expect "7564-synth-table-alias-column-shift" "$(explainMismatch "$tt_o" "$tt_b" types)" "types: table column shift"
  expect "" "$(explainMismatch "$tt_o" "${tt_b/__row: Author/__row: Post}" types)" "types: table row type changed"
  expect "" "$(explainMismatch "$tt_o" "${tt_b/215:3:/215:4:}" types)" "types: table column moved on a line that is not synthesized"
  # A row past the source file's end is synthesized text: its column may move either way.
  eoff=$(mktemp "${TMPDIR:-/tmp}/sigeof.XXXXXX"); printf '1\n2\n3\n' > "$eoff"
  pe_o='2:5: x: i64
5:11: cols: []string'
  pe_b='2:5: x: i64
5:6: cols: []string'
  expect "7564-synth-table-alias-column-shift" "$(explainMismatch "$pe_o" "$pe_b" types "$eoff")" "types: column moved left past EOF"
  expect "" "$(explainMismatch "$pe_o" "$pe_b" types)" "types: past-EOF move without the file"
  expect "" "$(explainMismatch "$pe_o" "${pe_b/cols: []string/cols: []int}" types "$eoff")" "types: past-EOF type changed"
  expect "" "$(explainMismatch "$pe_o" "${pe_b/2:5:/2:4:}" types "$eoff")" "types: in-file column moved left"
  rm -f "$eoff"
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


  # 7574-f32-store-schedule-lag: a per-file pin (irLagPins) for the optimizer moving the inline f32
  # store past the next call. Accepted only for a pinned file on the iropt arm, and only when what is
  # left after deleting every line tied to an []f32 slice is identical on both sides.
  lag_o='bb0(%0: []f32, %1: f32, %9: i64):
  %2 = const_int i64 0
  %3 = bitcast u32 %1
  %4 = const_int i64 8
  %5 = rt_call slice_set(%0, %2, %3, %4) void
  %6 = rt_call string_from_int(%9) string
  ret'
  lag_t='bb0(%0: []f32, %1: f32, %9: i64):
  %2 = const_int i64 0
  %6 = rt_call string_from_int(%9) string
  %3 = slice_len %0
  %4 = icmp_ult bool %2, %3
  br %4, bb1(), bb2()
bb2():
  %5 = const_string "index out of range"
  %7 = rt_call panic(%5) void
  unreachable
bb1():
  %10 = field_get %0[0] i64
  %11 = field_get %0[16] i64
  %12 = add i64 %11, %2
  index_set %10[%12] = %1
  ret'
  lag_pin=_tests_/cases/run_float32_interp.bit
  lag_want="7574-f32-store-schedule-lag"
  lag() { explainMismatch "func g() void {
$1
}" "func g() void {
$2
}" "$3" "$4"; }
  expect "$lag_want" "$(lag "$lag_o" "$lag_t" iropt "$lag_pin")" "iropt: a pinned file, the store scheduled past a call"
  expect "" "$(lag "$lag_o" "$lag_t" iropt _tests_/cases/run_float32_interp_other.bit)" "iropt: the same diff in an unpinned file"
  expect "" "$(lag "$lag_o" "$lag_t" ir "$lag_pin")" "ir: the pin is for the iropt arm only"
  expect "" "$(lag "$lag_o" "${lag_t/string_from_int/string_from_uint}" iropt "$lag_pin")" "iropt: a pinned file whose diff also changes an unrelated call"
  expect "" "$(lag "$lag_o" "$(printf '%s\n' "$lag_t" | sed '/string_from_int/d')" iropt "$lag_pin")" "iropt: a pinned file whose diff also drops an unrelated line"
  expect "" "$(lag "$lag_o" "$(printf '%s\n' "$lag_t" | sed 's/^  %6 = rt_call string_from_int(%9) string$/  %6 = rt_call string_from_int(%1) string/')" iropt "$lag_pin")" "iropt: a pinned file whose unrelated call takes another operand"
  expect "$lag_want" "$(lag "$lag_o" "$lag_t" iropt _tests_/cases/run_float_slice_elems.bit)" "iropt: the second pinned file"

  # 7674-forwarded-index-get: the oracle loads a scalar element again where optcse.bit forwards the
  # first load (single-predecessor forward chain, no barrier between, same base, index and type).
  cse_pre='func f(%0: []u8, %1: i64, %9: i64) bool {
bb0(%0: []u8, %1: i64, %9: i64):
  %2 = field_get %0[0] i64
  %3 = index_get %2[%1] u8
  %5 = icmp_ult bool %3, %9
  jump bb1()
bb1():'
  cse_o="$cse_pre
  %4 = index_get %2[%1] u8
  %6 = icmp_ult bool %4, %9
  %7 = icmp_eq bool %5, %6
  ret %7
}"
  cse_b="$cse_pre
  %7 = icmp_eq bool %5, %5
  ret %7
}"
  expect "7674-forwarded-index-get" "$(explainMismatch "$cse_o" "$cse_b" iropt)" "iropt: a repeated element load forwarded, and the compare it made equal"
  expect "" "$(explainMismatch "$cse_o" "$cse_b" ir)" "ir: the pre-opt dump has no CSE, so the forward explains nothing"
  expect "" "$(explainMismatch "$cse_o" "$cse_o" iropt)" "iropt: a tree that kept both loads is not explained"
  cse_kept_cmp="$cse_pre
  %6 = icmp_ult bool %3, %9
  %7 = icmp_eq bool %5, %6
  ret %7
}"
  expect "" "$(explainMismatch "$cse_o" "$cse_kept_cmp" iropt)" "iropt: the load forwarded but the compare it made equal kept"
  cse_barrier_b=$(printf '%s\n' "$cse_b" | sed 's/^bb1():$/bb1():\nBARRIER/')
  for barrier in '  %8 = call @g() void' '  %8 = rt_call string_from_int(%9) string' '  index_set %2[%1] = %9' '  field_set %0[8] = %9' \
    '  %8 = gc_alloc size=8 ptrs=[] T' '  %8 = atomic_load %2 u8' '  %8 = sdiv i64 %9, %1' '  %8 = keep_alive %0'; do
    cse_ob=${cse_o/bb1():/bb1():
$barrier}
    expect "" "$(explainMismatch "$cse_ob" "${cse_barrier_b/BARRIER/$barrier}" iropt)" "iropt: a barrier (${barrier# }) between two loads keeps the second"
  done
  cse_x() { # <sed expr on the oracle's second load> -- the tree drops nothing the walk would not
    explainMismatch "$(printf '%s\n' "$cse_o" | sed "$1")" "$cse_b" iropt
  }
  expect "" "$(cse_x 's/^  %4 = index_get %2\[%1\] u8$/  %4 = index_get %2[%9] u8/')" "iropt: a load of another index is not dropped"
  expect "" "$(cse_x 's/^  %4 = index_get %2\[%1\] u8$/  %4 = index_get %2[%1] i8/')" "iropt: a load of another type is not dropped"
  expect "" "$(cse_x 's/^  %4 = index_get %2\[%1\] u8$/  %4 = index_get %0[%1] u8/')" "iropt: a load of another base is not dropped"
  cse_join_o='func f(%0: []u8, %1: i64, %9: i64) bool {
bb0(%0: []u8, %1: i64, %9: i64):
  %2 = field_get %0[0] i64
  %3 = index_get %2[%1] u8
  br %9, bb1(), bb2()
bb2():
  jump bb1()
bb1():
  %4 = index_get %2[%1] u8
  %7 = icmp_eq bool %3, %4
  ret %7
}'
  cse_join_b="${cse_join_o/  %4 = index_get %2[%1] u8
  %7 = icmp_eq bool %3, %4/  %7 = icmp_eq bool %3, %3}"
  expect "" "$(explainMismatch "$cse_join_o" "$cse_join_b" iropt)" "iropt: a block with two predecessors starts from an empty table"
  # An edge to a block with a LOWER id is a back edge (it carries the safepoint poll): no table crosses it.
  cse_back_o='func f(%0: []u8, %1: i64) bool {
bb0(%0: []u8, %1: i64):
  %2 = field_get %0[0] i64
  jump bb2()
bb2():
  %3 = index_get %2[%1] u8
  jump bb1()
bb1():
  %4 = index_get %2[%1] u8
  %7 = icmp_eq bool %3, %4
  ret %7
}'
  cse_back_b='func f(%0: []u8, %1: i64) bool {
bb0(%0: []u8, %1: i64):
  %2 = field_get %0[0] i64
  jump bb2()
bb2():
  %3 = index_get %2[%1] u8
  jump bb1()
bb1():
  %7 = icmp_eq bool %3, %3
  ret %7
}'
  expect "" "$(explainMismatch "$cse_back_o" "$cse_back_b" iropt)" "iropt: an edge to a lower block id carries no table"
  # The same drop on top of the packing: the oracle reads a u32 element through the scaled address.
  cse_pk_o='func f(%0: []u32, %1: i64) bool {
bb0(%0: []u32, %1: i64):
  %2 = field_get %0[0] i64
  %3 = const_int i64 3
  %4 = shl i64 %1, %3
  %5 = add i64 %2, %4
  %6 = field_get %5[0] u32
  jump bb1()
bb1():
  %7 = field_get %5[0] u32
  %8 = icmp_eq bool %6, %7
  ret %8
}'
  cse_pk_b='func f(%0: []u32, %1: i64) bool {
bb0(%0: []u32, %1: i64):
  %2 = field_get %0[0] i64
  %3 = index_get %2[%1] u32
  jump bb1()
bb1():
  %4 = icmp_eq bool %3, %3
  ret %4
}'
  expect "7674-forwarded-index-get" "$(explainMismatch "$cse_pk_o" "$cse_pk_b" iropt)" "iropt: the forward composes with the narrow packing"
  expect "" "$(explainMismatch "$cse_pk_o" "$cse_pk_b" ir)" "ir: the packing alone does not explain the forward"
  expect "" "$(explainMismatch "$cse_pk_o" "$(printf '%s\n' "$cse_pk_b" | sed 's/index_get %2\[%1\] u32/index_get %2[%2] u32/')" iropt)" "iropt: the forwarded packed read takes another index"

  # 7574, an f32 store into a slice the tree knows starts at offset 0: no f32off read, the guard is on the index.
  f32_zero_o='bb0(%0: []f32, %1: f32):
  %2 = const_int i64 0
  %3 = bitcast u32 %1
  %4 = const_int i64 8
  %5 = rt_call slice_set(%0, %2, %3, %4) void
  ret'
  f32_zero_t='bb0(%0: []f32, %1: f32):
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
  index_set %7[%2] = %1
  ret'
  expect "7574-packed-narrow-slices" "$(explainMismatch "func g() void {
$f32_zero_o
}" "func g() void {
$f32_zero_t
}" ir)" "ir: an f32 store with no offset read, guarded"
  expect "" "$(explainMismatch "func g() void {
$f32_zero_o
}" "func g() void {
${f32_zero_t/icmp_ult bool %2, %3/icmp_ult bool %3, %3}
}" ir)" "ir: an f32 store with no offset read whose guard tests another index"

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

  # 6681-multi-assign-oracle-omits-function: the oracle emits no function for a refused construct.
  om_main='func main() void {
bb0():
  %0 = call @swaps() void
  ret
}'
  om_swaps='func swaps() void {
bb0():
  %0 = const_int i64 1
  ret
}'
  om_o="$om_main"
  om_t="$om_swaps

$om_main"
  expect "6681-multi-assign-oracle-omits-function" "$(explainMismatch "$om_o" "$om_t" ir)" "ir: a called function the oracle omitted"
  expect "6681-multi-assign-oracle-omits-function" "$(explainMismatch "$om_o" "$om_t" iropt)" "iropt: a called function the oracle omitted"
  expect "" "$(explainMismatch "$om_o" "$(printf '%s\n' "$om_t" | sed 's/call @swaps/call @other/')" ir)" "ir: a present function also differs (its callee changed)"
  om_t_diff="$om_swaps

${om_main/ret/%1 = const_int i64 2
  ret}"
  expect "" "$(explainMismatch "$om_o" "$om_t_diff" iropt)" "iropt: a present function also differs (an extra line)"
  expect "" "$(explainMismatch "$om_o" "${om_swaps//swaps/ghost}

$om_t" iropt)" "iropt: a second omitted function that the oracle never calls"
  om_present='func swaps() void {
bb0():
  %0 = rt_call g() void
  ret
}'
  expect "" "$(explainMismatch "$om_present

$om_main" "$om_t" ir)" "ir: the function is present in the oracle with another body"
  expect "" "$(explainMismatch "$om_t" "$om_o" ir)" "ir: the oracle has a function the tree lacks"

  # 7737-forof-len-once: the oracle reads `slice_len` of the ranged slice in the loop header; the tree
  # reads it once in the block that jumps into the loop and carries it as the last block parameter.
  fl_o='func f(%0: []i64) i64 {
bb0(%0: []i64):
  %1 = const_int i64 0
  %2 = const_int i64 0
  jump bb1(%0, %1, %0, %2)
bb1(%4: []i64, %5: i64, %6: []i64, %7: i64):
  %8 = slice_len %6
  %9 = icmp_slt bool %7, %8
  br %9, bb2(), bb4(%4, %5, %6, %7)
bb2():
  %11 = rt_call g(%7) void
  jump bb3(%4, %5, %6, %7)
bb3(%13: []i64, %14: i64, %15: []i64, %16: i64):
  %17 = const_int i64 1
  %18 = add i64 %16, %17
  jump bb1(%13, %14, %15, %18)
bb4(%20: []i64, %21: i64, %22: []i64, %23: i64):
  ret %21
}'
  fl_t='func f(%0: []i64) i64 {
bb0(%0: []i64):
  %1 = const_int i64 0
  %2 = const_int i64 0
  %3 = slice_len %0
  jump bb1(%0, %1, %0, %2, %3)
bb1(%5: []i64, %6: i64, %7: []i64, %8: i64, %9: i64):
  %10 = icmp_slt bool %8, %9
  br %10, bb2(), bb4(%5, %6, %7, %8, %9)
bb2():
  %12 = rt_call g(%8) void
  jump bb3(%5, %6, %7, %8, %9)
bb3(%14: []i64, %15: i64, %16: []i64, %17: i64, %18: i64):
  %19 = const_int i64 1
  %20 = add i64 %17, %19
  jump bb1(%14, %15, %16, %20, %18)
bb4(%22: []i64, %23: i64, %24: []i64, %25: i64, %26: i64):
  ret %23
}'
  expect "7737-forof-len-once" "$(explainMismatch "$fl_o" "$fl_t" ir)" "ir: the loop bound read once before the loop"
  expect "7737-forof-len-once" "$(explainMismatch "$fl_o" "$fl_t" iropt)" "iropt: the loop bound read once before the loop"
  expect "" "$(explainMismatch "$fl_o" "$fl_t" ast)" "ast: not a dump kind this signature reads"
  expect "" "$(explainMismatch "$fl_t" "$fl_o" ir)" "ir: the direction is fixed, the oracle reading once is not explained"
  expect "" "$(explainMismatch "$fl_o" "${fl_t/icmp_slt/icmp_sle}" ir)" "ir: the header compare is not the loop-bound compare"
  expect "" "$(explainMismatch "$fl_o" "${fl_t/rt_call g(%8)/rt_call g(%9)}" ir)" "ir: the carried length is also used in the body"
  expect "" "$(explainMismatch "$fl_o" "${fl_t/ret %23/ret %26}" ir)" "ir: the carried length is returned from the exit block"
  expect "" "$(explainMismatch "$fl_o" "${fl_t/slice_len %0/slice_len %1}" ir)" "ir: the length is not that of the slice the loop ranges over"
  expect "" "$(explainMismatch "${fl_o/slice_len %6/slice_len %4}" "$fl_t" ir)" "ir: the oracle header reads another value than the cursor's slice"
  expect "" "$(explainMismatch "$fl_o" "${fl_t/ret %23/%27 = rt_call h() void
  ret %23}" ir)" "ir: an unrelated extra line next to the rewritten loop"
  expect "" "$(explainMismatch "$fl_o" "${fl_t/rt_call g/rt_call h}" ir)" "ir: an unrelated call differs next to the rewritten loop"
  expect "" "$(explainMismatch "$fl_o" "${fl_t/bb1(%14, %15, %16, %20, %18)/bb1(%14, %15, %16, %20, %17)}" ir)" "ir: the back edge passes something other than the carried length"

  # 7737-forof-len-once, iropt: two hoists of one header word into one block are one value (irMergeLoads).
  ml_o='func g(%0: []i64) void {
bb0(%0: []i64):
  %2 = slice_len %0
  %3 = slice_len %0
  %4 = rt_call h(%2) void
  %5 = rt_call h(%3) void
  ret
}'
  ml_t='func g(%0: []i64) void {
bb0(%0: []i64):
  %2 = slice_len %0
  %4 = rt_call h(%2) void
  %5 = rt_call h(%2) void
  ret
}'
  expect "7737-forof-len-once" "$(explainMismatch "$ml_o" "$ml_t" iropt)" "iropt: a repeated header word load in one block"
  expect "" "$(explainMismatch "$ml_o" "$ml_t" ir)" "ir: the merge is for the optimized dump only"
  ml_oc='func g(%0: []i64) void {
bb0(%0: []i64):
  %2 = slice_len %0
  %4 = rt_call h(%2) void
  %3 = slice_len %0
  %5 = rt_call h(%3) void
  ret
}'
  expect "" "$(explainMismatch "$ml_oc" "$ml_t" iropt)" "iropt: a call between the loads keeps them apart"

  # 7737-forof-len-once, the file pin (irLagPins, iropt only): the tree's BCE dropped the bounds guard
  # of an access the loop test already covers. Only a pinned file, only when the tree lost guards and
  # nothing else differs once the loop-tested ones are removed from both dumps.
  gp_o='func g(%0: []i64) i64 {
bb0(%0: []i64):
  %1 = const_int i64 0
  jump bb1(%0, %1)
bb1(%3: []i64, %4: i64):
  %5 = slice_len %3
  %6 = icmp_slt bool %4, %5
  br %6, bb2(), bb5()
bb2():
  %8 = slice_len %3
  %9 = icmp_ult bool %4, %8
  br %9, bb4(), bb3()
bb3():
  %11 = const_string "index out of range"
  %12 = rt_call panic(%11) void
  unreachable
bb4():
  %14 = rt_call h(%4) void
  %15 = const_int i64 1
  %16 = add i64 %4, %15
  jump bb1(%3, %16)
bb5():
  ret %4
}'
  gp_t='func g(%0: []i64) i64 {
bb0(%0: []i64):
  %1 = const_int i64 0
  jump bb1(%0, %1)
bb1(%3: []i64, %4: i64):
  %5 = slice_len %3
  %6 = icmp_slt bool %4, %5
  br %6, bb2(), bb5()
bb2():
  jump bb4()
bb4():
  %14 = rt_call h(%4) void
  %15 = const_int i64 1
  %16 = add i64 %4, %15
  jump bb1(%3, %16)
bb5():
  ret %4
}'
  gp_pin=stdlib/compress/crc32.bit
  gp_want="7737-forof-len-once"
  expect "$gp_want" "$(explainMismatch "$gp_o" "$gp_t" iropt "$gp_pin")" "iropt: a pinned file, the loop-tested guard dropped"
  expect "" "$(explainMismatch "$gp_o" "$gp_t" iropt stdlib/compress/other.bit)" "iropt: the same diff in an unpinned file"
  expect "" "$(explainMismatch "$gp_o" "$gp_t" ir "$gp_pin")" "ir: the pin is for the iropt arm only"
  expect "" "$(explainMismatch "$gp_t" "$gp_o" iropt "$gp_pin")" "iropt: the tree gained a guard instead of losing one"
  expect "" "$(explainMismatch "${gp_o/icmp_ult bool %4, %8/icmp_ult bool %1, %8}" "$gp_t" iropt "$gp_pin")" "iropt: an unrelated guard (not the loop index) disappears"
  expect "" "$(explainMismatch "${gp_o/icmp_ult bool %4, %8/icmp_ult bool %4, %15}" "$gp_t" iropt "$gp_pin")" "iropt: a guard against another length disappears"
  expect "" "$(explainMismatch "$gp_o" "${gp_t//rt_call h/rt_call k}" iropt "$gp_pin")" "iropt: a guard dropped and an unrelated call changed"
  expect "" "$(explainMismatch "${gp_o/index out of range/slice bounds}" "$gp_t" iropt "$gp_pin")" "iropt: the dropped block is not the out-of-range panic"
  expect "" "$(explainMismatch "$gp_o" "${gp_t/jump bb4()/%20 = rt_call k() void
  jump bb4()}" iropt "$gp_pin")" "iropt: a guard dropped and a call added"

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
  want=$(grep -hoE 'print "[0-9]+-[a-z0-9-]+"' "${ROOT}/scripts/selfhost-ir-signatures.sh" "${ROOT}/scripts/ir-signatures-walk.sh" |
    grep -oE '"[0-9]+-[a-z0-9-]+"' | tr -d '"' | LC_ALL=C sort -u)
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
