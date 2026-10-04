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
# each declared signature's real shape and refuses its near misses, that an
# unrelated divergence stays unexplained on every kind, and that
# declaredSignatureNames() stays in sync with it.
# `bash scripts/selfhost-ir-signatures-selfcheck.sh`. Same pattern as
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
    if [ "$sig" != "$5" ] || { [ -n "$5" ] && [ "$rc" -ne 0 ]; } || { [ -z "$5" ] && [ "$rc" -eq 0 ]; }; then
      echo "FAIL: $1: expected '$5' (rc=$rc sig='$sig')"
      fail=1
    fi
  }

  # --- 6730-fallible-enum-words: a fallible enum ok value in two words ---
  # Call site, rebuilt box standing for the handle (pre-opt; post-opt when the
  # box escapes, as in run_sql_row_find).
  call_oracle='func f(%0: P) i64 {
bb0(%0: P):
  %1 = call @next(%0) Option
  %2 = rt_call err_get() error
  field_set %0[8] = %1
  ret %2
}'
  call_tree='func f(%0: P) i64 {
bb0(%0: P):
  %1 = call @next(%0) i64
  %2 = call_word %1[1] i64
  %3 = gc_alloc size=16 ptrs=[] Option
  field_set %3[0] = %1
  field_set %3[8] = %2
  %6 = rt_call err_get() error
  field_set %0[8] = %3
  ret %6
}'
  # Call site with no box: the oracle reads of the handle become the words,
  # including a use laid out before its read (a for-of body block).
  read_oracle='func d(%0: P) i64 {
bb0(%0: P):
  %1 = call @next(%0) Option
  jump bb2()
bb1():
  %5 = add i64 %3, %3
  ret %5
bb2():
  %2 = field_get %1[0] i64
  %3 = field_get %1[8] i64
  br %2, bb1(), bb1()
}'
  read_tree='func d(%0: P) i64 {
bb0(%0: P):
  %1 = call @next(%0) i64
  %2 = call_word %1[1] i64
  jump bb2()
bb1():
  %4 = add i64 %2, %2
  ret %4
bb2():
  br %1, bb1(), bb1()
}'
  # Callee: an ok return reads its box out; a fail return drops the zero box.
  ret_oracle='func next(%0: P) Option {
bb0(%0: P):
  %1 = gc_alloc size=16 ptrs=[] Option
  %2 = const_int i64 1
  field_set %1[0] = %2
  field_set %1[8] = %2
  %5 = const_nil
  %6 = rt_call err_set(%5) void
  ret %1
bb1():
  %8 = gc_alloc size=16 ptrs=[] Option
  %9 = const_int i64 0
  field_set %8[0] = %9
  %11 = const_nil
  field_set %8[8] = %11
  ret %8
}'
  ret_tree='func next(%0: P) Option {
bb0(%0: P):
  %1 = gc_alloc size=16 ptrs=[] Option
  %2 = const_int i64 1
  field_set %1[0] = %2
  field_set %1[8] = %2
  %5 = field_get %1[0] i64
  %6 = field_get %1[8] i64
  %7 = const_nil
  %8 = rt_call err_set(%7) void
  ret %5, %6
bb1():
  %10 = const_int i64 0
  %11 = const_nil
  ret %10, %11
}'
  # refuse <label> <oracle> <base tree> <mutated tree> <kind>: a near miss must
  # stay unexplained, and the mutation must really have changed the tree.
  refuse() {
    if [ "$3" = "$4" ]; then
      echo "FAIL: $1: the mutation did not apply"
      fail=1
    fi
    expect "$1" "$2" "$4" "$5" ""
  }
  for kind in ir iropt; do
    expect "6730 call+box ($kind)" "$call_oracle" "$call_tree" "$kind" 6730-fallible-enum-words
    expect "6730 reads ($kind)" "$read_oracle" "$read_tree" "$kind" 6730-fallible-enum-words
    expect "6730 returns ($kind)" "$ret_oracle" "$ret_tree" "$kind" 6730-fallible-enum-words
    refuse "6730 box stores the call twice ($kind)" "$call_oracle" "$call_tree" "${call_tree/field_set %3\[8\] = %2/field_set %3[8] = %1}" "$kind"
    refuse "6730 raw word escapes for the box ($kind)" "$call_oracle" "$call_tree" "${call_tree/field_set %0\[8\] = %3/field_set %0[8] = %1}" "$kind"
    refuse "6730 three words ($kind)" "$call_oracle" "$call_tree" "${call_tree/  %3 = gc_alloc/  %9 = call_word %1[2] i64
  %3 = gc_alloc}" "$kind"
    refuse "6730 payload read as tag ($kind)" "$read_oracle" "$read_tree" "${read_tree/add i64 %2, %2/add i64 %1, %2}" "$kind"
    refuse "6730 ok words swapped ($kind)" "$ret_oracle" "$ret_tree" "${ret_tree/ret %5, %6/ret %6, %5}" "$kind"
    refuse "6730 zero words swapped ($kind)" "$ret_oracle" "$ret_tree" "${ret_tree/ret %10, %11/ret %11, %10}" "$kind"
    refuse "6730 unrelated line changed too ($kind)" "$ret_oracle" "$ret_tree" "${ret_tree/const_int i64 1/const_int i64 2}" "$kind"
    used_oracle="${ret_oracle/  ret %8/  field_set %0[0] = %8
  ret %8}"
    if [ "$used_oracle" = "$ret_oracle" ]; then
      echo "FAIL: 6730 deleted box still used ($kind): the oracle mutation did not apply"
      fail=1
    fi
    refuse "6730 deleted box still used ($kind)" "$used_oracle" "$ret_tree" "${ret_tree/  ret %10, %11/  field_set %0[0] = %10
  ret %10, %11}" "$kind"
  done
  expect "6730 is not a types signature" "$call_oracle" "$call_tree" types ""

  # --- 6847-test-module-counters: interning counters renumbered ---
  # Removing the test files of an imported module renumbers whatever the
  # compiler interned after them: module ids, closure / trampoline / instance
  # suffixes, function-value hashes and interface method slots.
  cnt_oracle='func main() void {
bb0():
  %0 = call @m15$read(%9) i64
  %1 = make_closure @closure$36, %0
  %2 = global_addr @__bitfnv_2214
  %3 = call @m15$sqlValue$35(%1) Value
  %4 = call_iface %0.292() []string
  %5 = func_addr @spawn$trampoline$723
  ret
}
func closure$36(%0: fn() void) void {
bb0(%0: fn() void):
  ret
}'
  cnt_tree='func main() void {
bb0():
  %0 = call @m14$read(%9) i64
  %1 = make_closure @closure$21, %0
  %2 = global_addr @__bitfnv_1965
  %3 = call @m14$sqlValue$16(%1) Value
  %4 = call_iface %0.277() []string
  %5 = func_addr @spawn$trampoline$646
  ret
}
func closure$21(%0: fn() void) void {
bb0(%0: fn() void):
  ret
}'
  # Two module ids swapped by a different load order are still a renaming.
  swap_oracle='%0 = call @m7$a(%1) i64
%2 = call @m6$b(%1) i64'
  swap_tree='%0 = call @m6$a(%1) i64
%2 = call @m7$b(%1) i64'
  # A forwarder trampoline the oracle leaves to the imported module.
  tramp_oracle='func main() void {
bb0():
  %0 = global_addr @__bitfnv_2197
  ret
}
'
  tramp_tree='func main() void {
bb0():
  %0 = global_addr @__bitfnv_1966
  ret
}

func fnvalue$trampoline$1966(%0: fn(Rows) i64!error, %1: Rows) i64 {
bb0(%0: fn(Rows) i64!error, %1: Rows):
  %2 = call @m13$scalar(%1) i64
  ret %2
}
'
  for kind in ir iropt; do
    expect "6847 counters ($kind)" "$cnt_oracle" "$cnt_tree" "$kind" 6847-test-module-counters
    expect "6847 swapped module ids ($kind)" "$swap_oracle" "$swap_tree" "$kind" 6847-test-module-counters
    expect "6847 moved trampoline ($kind)" "$tramp_oracle" "$tramp_tree" "$kind" 6847-test-module-counters
    refuse "6847 callee renamed ($kind)" "$cnt_oracle" "$cnt_tree" "${cnt_tree/@m14\$read/@m14\$write}" "$kind"
    refuse "6847 a counter used by one more function ($kind)" "$cnt_oracle" "$cnt_tree" "${cnt_tree/@closure\$21, %0/@closure\$22, %0}" "$kind"
    refuse "6847 operand changed ($kind)" "$cnt_oracle" "$cnt_tree" "${cnt_tree/call @m14\$read(%9)/call @m14\$read(%8)}" "$kind"
    refuse "6847 unrelated line added ($kind)" "$cnt_oracle" "$cnt_tree" "${cnt_tree/  ret
\}/  %8 = sub %1, %1
  ret
\}}" "$kind"
    refuse "6847 forwarder calls twice ($kind)" "$tramp_oracle" "$tramp_tree" "${tramp_tree/  ret %2/  %3 = call @m13\$scalar(%1) i64
  ret %3}" "$kind"
    refuse "6847 forwarder never referenced ($kind)" "$tramp_oracle" "$tramp_tree" "${tramp_tree/@__bitfnv_1966/@__bitfnv_1967}" "$kind"
  done
  expect "6847 counters on a string literal line" 'x = const_string "m15$read"' 'x = const_string "m14$read"' ir ""
  expect "6847 is not a types signature" "$cnt_oracle" "$cnt_tree" types ""

  # The #6730 identity on top of the counter renaming, with a box whose ptrs
  # list names an offset: the 6982/7058 walks rewrite those in place and must
  # put them back before this one runs (#7074).
  comb_oracle="${call_oracle/@next/@m15\$next}"
  comb_tree="${call_tree/@next/@m14\$next}"
  comb_tree="${comb_tree/ptrs=\[\]/ptrs=[%8]}"
  if [ "$comb_tree" = "$call_tree" ] || [ "$comb_oracle" = "$call_oracle" ]; then echo "FAIL: 6847 combined: the mutation did not apply"; fail=1; fi
  for kind in ir iropt; do
    expect "6847 counters with fallible enum words, box with a ptrs offset ($kind)" "$comb_oracle" "$comb_tree" "$kind" 6847-test-module-counters-with-fallible-enum-words
    refuse "6847 combined, box stores the call twice ($kind)" "$comb_oracle" "$comb_tree" "${comb_tree/field_set %3\[8\] = %2/field_set %3[8] = %1}" "$kind"
  done

  # --- 6840-bce-window-guard: a bounds check dropped (post-opt only) ---
  bce_oracle='func f(%0: []u8, %1: i64) void {
bb0(%0: []u8, %1: i64):
  %2 = len i64 %0
  %3 = icmp_ult bool %1, %2
  br %3, bb1(), bb2()
bb1():
  %5 = index_get %0[%1] u8
  jump bb3()
bb2():
  %7 = const_string "index out of range"
  %8 = rt_call panic(%7) void
  unreachable
bb3():
  ret
}'
  bce_tree='func f(%0: []u8, %1: i64) void {
bb0(%0: []u8, %1: i64):
  %2 = len i64 %0
  jump bb1()
bb1():
  %5 = index_get %0[%1] u8
  jump bb3()
bb3():
  ret
}'
  expect "6840 one check dropped (iropt)" "$bce_oracle" "$bce_tree" iropt 6840-bce-window-guard
  expect "6840 is post-opt only" "$bce_oracle" "$bce_tree" ir ""
  refuse "6840 an opcode changed too (iropt)" "$bce_oracle" "$bce_tree" "${bce_tree/len i64/cap i64}" iropt
  refuse "6840 a second line dropped (iropt)" "$bce_oracle" "$bce_tree" "${bce_tree/  %2 = len i64 %0
/}" iropt
  expect "6840 nothing dropped" "$bce_oracle" "$bce_oracle" iropt ""

  # --- 6847-test-module-functions: object-level safepoint sites ---
  sp_oracle='m3$keep 2
m3$test$0 1
m3$test$1 0
m3$helper 3
@@total 6
@@other 0'
  sp_tree='m3$keep 2
@@total 2
@@other 0'
  spexpect() {
    local got
    got=$(explainTestFunctions "$2" "$3" "$4" "$5")
    if [ "$got" != "$6" ]; then
      echo "FAIL: $1: expected '$6', got '$got'"
      fail=1
    fi
  }
  spexpect "6847 test functions and their helper removed" "$sp_oracle" "$sp_tree" 6 2 6847-test-module-functions
  spexpect "6847 module and instance ids ignored" 'm3$keep$7 2
m3$test$0 1
@@total 3
@@other 0' 'm2$keep$4 2
@@total 2
@@other 0' 3 2 6847-test-module-functions
  spexpect "6847 a kept function lost a poll" "$sp_oracle" 'm3$keep 1
@@total 1
@@other 0' 6 1 ""
  spexpect "6847 a function the oracle lacks" "$sp_oracle" 'm3$keep 2
m3$extra 0
@@total 2
@@other 0' 6 2 ""
  spexpect "6847 nothing removed is a test block" 'm3$keep 2
m3$helper 3
@@total 5
@@other 0' "$sp_tree" 5 2 ""
  spexpect "6847 the listing disagrees with the object count" "$sp_oracle" "$sp_tree" 7 2 ""
  spexpect "6847 outside-text sites differ" "$sp_oracle" 'm3$keep 2
@@total 2
@@other 1' 6 2 ""
  spexpect "6847 a poll gained is not a removal" "$sp_tree" "$sp_oracle" 2 6 ""

  # --- 6982-error-path-nil: the zero box of an error return becomes nil ---
  nil_oracle='func f(%0: Pages) Option {
bb0(%0: Pages):
  %1 = const_string "page"
  %2 = call @newError(%1) error
  %3 = rt_call err_set(%2) void
  %4 = gc_alloc size=16 ptrs=[%8] Option
  %5 = const_int i64 0
  field_set %4[0] = %5
  %7 = const_int i64 0
  field_set %4[8] = %7
  ret %4
bb1():
  %9 = gc_alloc size=16 ptrs=[%8] Option
  %10 = const_int i64 1
  field_set %9[0] = %10
  field_set %9[8] = %10
  %13 = const_nil
  %14 = rt_call err_set(%13) void
  ret %9
}'
  nil_tree='func f(%0: Pages) Option {
bb0(%0: Pages):
  %1 = const_string "page"
  %2 = call @newError(%1) error
  %3 = rt_call err_set(%2) void
  %4 = const_nil
  ret %4
bb1():
  %6 = gc_alloc size=16 ptrs=[%8] Option
  %7 = const_int i64 1
  field_set %6[0] = %7
  field_set %6[8] = %7
  %10 = const_nil
  %11 = rt_call err_set(%10) void
  ret %6
}'
  # Post-opt: one zero const shared by the box stores and by a second box.
  nilo_oracle='func f(%0: Pages) Option {
bb0(%0: Pages):
  %1 = rt_call err_get() error
  %2 = rt_call err_set(%1) void
  %3 = gc_alloc size=16 ptrs=[%8] Option
  %4 = const_int i64 0
  field_set %3[0] = %4
  field_set %3[8] = %4
  br %0, bb1(), bb2()
bb1():
  %8 = rt_call err_set(%1) void
  ret %3
bb2():
  %9 = rt_call err_set(%1) void
  ret %3
}'
  nilo_tree='func f(%0: Pages) Option {
bb0(%0: Pages):
  %1 = rt_call err_get() error
  %2 = rt_call err_set(%1) void
  %3 = const_nil
  br %0, bb1(), bb2()
bb1():
  %5 = rt_call err_set(%1) void
  ret %3
bb2():
  %6 = rt_call err_set(%1) void
  ret %3
}'
  for kind in ir iropt; do
    expect "6982 box returned at once ($kind)" "$nil_oracle" "$nil_tree" "$kind" 6982-error-path-nil
    expect "6982 box built once, returned from two error paths ($kind)" "$nilo_oracle" "$nilo_tree" "$kind" 6982-error-path-nil
    refuse "6982 a success-path box is nil too ($kind)" "$nil_oracle" "$nil_tree" "${nil_tree/  %6 = gc_alloc size=16 ptrs=\[%8\] Option/  %6 = const_nil}" "$kind"
    refuse "6982 the box is kept ($kind)" "$nil_oracle" "$nil_tree" "$nil_oracle" "$kind"
    refuse "6982 another line changed too ($kind)" "$nil_oracle" "$nil_tree" "${nil_tree/\"page\"/\"pagf\"}" "$kind"
    refuse "6982 a different value returned ($kind)" "$nil_oracle" "$nil_tree" "${nil_tree/  ret %4/  ret %1}" "$kind"
    refuse "6982 the nil is not returned ($kind)" "$nilo_oracle" "$nilo_tree" "${nilo_tree/  %5 = rt_call err_set(%1) void
  ret %3/  %5 = rt_call err_set(%1) void
  ret %1}" "$kind"
    nz_oracle="${nil_oracle/  %5 = const_int i64 0/  %5 = const_int i64 7}"
    if [ "$nz_oracle" = "$nil_oracle" ]; then echo "FAIL: 6982 nonzero store ($kind): the mutation did not apply"; fail=1; fi
    expect "6982 the box stored a nonzero value ($kind)" "$nz_oracle" "$nil_tree" "$kind" ""
    ne_oracle="${nil_oracle/  %3 = rt_call err_set(%2) void/  %3 = call @g() void}"
    if [ "$ne_oracle" = "$nil_oracle" ]; then echo "FAIL: 6982 no err_set ($kind): the mutation did not apply"; fail=1; fi
    expect "6982 no err_set before the return ($kind)" "$ne_oracle" "$nil_tree" "$kind" ""
    nu_oracle="${nilo_oracle/  %8 = rt_call err_set(%1) void
  ret %3/  %20 = add i64 %3, %3
  %8 = rt_call err_set(%1) void
  ret %3}"
    if [ "$nu_oracle" = "$nilo_oracle" ]; then echo "FAIL: 6982 box used elsewhere ($kind): the mutation did not apply"; fail=1; fi
    expect "6982 the box is used by more than a return ($kind)" "$nu_oracle" "$nilo_tree" "$kind" ""
  done
  expect "6982 nothing changed" "$nil_oracle" "$nil_oracle" ir ""

  # --- 7058-switch-case-range: a switch case's labels lowered first / range test ---
  sw_head='func f(%0: i64) i64 {
bb0(%0: i64):'
  sw_tail='
bb1():
  ret %1
bb2():
  ret %0
}'
  hoist_oracle="$sw_head
  %1 = const_int i64 1
  %2 = icmp_eq bool %0, %1
  %3 = const_int i64 2
  %4 = icmp_eq bool %0, %3
  %5 = bor bool %2, %4
  %6 = const_int i64 4
  %7 = icmp_eq bool %0, %6
  %8 = bor bool %5, %7
  br %8, bb1(), bb2()$sw_tail"
  hoist_tree="$sw_head
  %1 = const_int i64 1
  %2 = const_int i64 2
  %3 = const_int i64 4
  %4 = icmp_eq bool %0, %1
  %5 = icmp_eq bool %0, %2
  %6 = bor bool %4, %5
  %7 = icmp_eq bool %0, %3
  %8 = bor bool %6, %7
  br %8, bb1(), bb2()$sw_tail"
  run_oracle="$sw_head
  %1 = const_int i64 1
  %2 = icmp_eq bool %0, %1
  %3 = const_int i64 2
  %4 = icmp_eq bool %0, %3
  %5 = bor bool %2, %4
  %6 = const_int i64 3
  %7 = icmp_eq bool %0, %6
  %8 = bor bool %5, %7
  br %8, bb1(), bb2()$sw_tail"
  run_tree="$sw_head
  %1 = const_int i64 1
  %2 = const_int i64 2
  %3 = const_int i64 3
  %4 = const_int u64 1
  %5 = sub u64 %0, %4
  %6 = const_int u64 2
  %7 = icmp_ule bool %5, %6
  br %7, bb1(), bb2()$sw_tail"
  neg_oracle="$sw_head
  %1 = const_int i64 5
  %2 = neg i64 %1
  %3 = icmp_eq bool %0, %2
  %4 = const_int i64 6
  %5 = neg i64 %4
  %6 = icmp_eq bool %0, %5
  %7 = bor bool %3, %6
  br %7, bb1(), bb2()$sw_tail"
  neg_tree="$sw_head
  %1 = const_int i64 5
  %2 = neg i64 %1
  %3 = const_int i64 6
  %4 = neg i64 %3
  %5 = icmp_eq bool %0, %2
  %6 = icmp_eq bool %0, %4
  %7 = bor bool %5, %6
  br %7, bb1(), bb2()$sw_tail"
  expect "7058 hoisted labels (ir)" "$hoist_oracle" "$hoist_tree" ir 7058-switch-case-range
  expect "7058 range test (ir)" "$run_oracle" "$run_tree" ir 7058-switch-case-range
  expect "7058 negated labels hoisted (ir)" "$neg_oracle" "$neg_tree" ir 7058-switch-case-range
  refuse "7058 compares reordered (ir)" "$hoist_oracle" "$hoist_tree" "${hoist_tree/  %5 = icmp_eq bool %0, %2/  %5 = icmp_eq bool %0, %3}" ir
  refuse "7058 a label const changed (ir)" "$hoist_oracle" "$hoist_tree" "${hoist_tree/const_int i64 4/const_int i64 5}" ir
  refuse "7058 the subject changed (ir)" "$hoist_oracle" "$hoist_tree" "${hoist_tree/  %7 = icmp_eq bool %0, %3/  %7 = icmp_eq bool %1, %3}" ir
  refuse "7058 hoisting a gap as a range (ir)" "$hoist_oracle" "$hoist_tree" "${run_tree/const_int i64 3/const_int i64 4}" ir
  refuse "7058 range lo wrong (ir)" "$run_oracle" "$run_tree" "${run_tree/const_int u64 1/const_int u64 2}" ir
  refuse "7058 range width wrong (ir)" "$run_oracle" "$run_tree" "${run_tree/const_int u64 2/const_int u64 3}" ir
  refuse "7058 range type signed (ir)" "$run_oracle" "$run_tree" "${run_tree/sub u64/sub i64}" ir
  refuse "7058 range compare signed (ir)" "$run_oracle" "$run_tree" "${run_tree/icmp_ule/icmp_ult}" ir
  refuse "7058 range of negated labels (ir)" "$neg_oracle" "$neg_tree" "${run_tree/const_int i64 1/const_int i64 5}" ir
  refuse "7058 range subject changed (ir)" "$run_oracle" "$run_tree" "${run_tree/sub u64 %0, %4/sub u64 %1, %4}" ir
  refuse "7058 another line changed too (ir)" "$hoist_oracle" "$hoist_tree" "${hoist_tree/  ret %0/  ret %1}" ir
  expect "7058 is not a post-opt text identity" "$run_oracle" "$run_tree" iropt ""

  # switchPostOptOk <pre_o> <pre_t> <post_o> <post_t>: the post-opt arm.
  pre_o="func a() void {
bb0():
  %0 = const_int i64 1
  ret
}

func b() void {
bb0():
  %0 = call @a() void
  ret
}

func c() void {
bb0():
  ret
}"
  pre_t="${pre_o/const_int i64 1/const_int u64 1}"
  post_o="$pre_o"
  post_ok="${pre_o/const_int i64 1/const_int u64 7}"
  post_ok="${post_ok/%0 = call @a() void/%0 = call @a() void
  %1 = add i64 %0, %0}"
  postcheck() {
    switchPostOptOk "$2" "$3" "$4" "$5"
    local rc=$?
    if [ "$rc" -ne "$6" ]; then echo "FAIL: $1: switchPostOptOk rc=$rc, expected $6"; fail=1; fi
  }
  postcheck "7058 post-opt: the changed function and its caller differ" "$pre_o" "$pre_t" "$post_o" "$post_ok" 0
  post_c2="${post_ok/func c() void \{
bb0():
  ret/func c() void \{
bb0():
  %0 = const_int i64 9
  ret}"
  if [ "$post_c2" = "$post_ok" ]; then echo "FAIL: 7058 post-opt mutation did not apply"; fail=1; fi
  postcheck "7058 post-opt: an untouched function differs too" "$pre_o" "$pre_t" "$post_o" "$post_c2" 1
  postcheck "7058 post-opt: nothing differs" "$pre_o" "$pre_t" "$post_o" "$post_o" 1
  postcheck "7058 post-opt: a function is missing" "$pre_o" "$pre_t" "$post_o" "${post_ok%%
func c*}" 1

  # An unrelated divergence of any shape stays unexplained on every kind.
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
  want=$(grep -ohE "(print|printf '%s\\\\n') \"[0-9]+-[a-z-]+\"" "${ROOT}/scripts/selfhost-ir-signatures.sh" "${ROOT}/scripts/ir-signatures-walk.sh" |
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
