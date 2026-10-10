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
# only what scripts/selfhost-ir-signatures.sh declares (7745-loop-defer-stack on
# ir/iropt, 7766-synth-json-helper-column-shift on types; the retired ones
# are in its Retirement history), and that
# declaredSignatureNames() stays in sync with it.
# `bash scripts/selfhost-ir-signatures-selfcheck.sh`. Same pattern as
# scripts/selfhost-ir-canon.sh's self-check.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -u
  fail=0

  # Every signature this check once carried a fixture for is RETIRED; the
  # list, and the repin that retired each, is in scripts/selfhost-ir-
  # signatures.sh's Retirement history, and the fixtures are in git history at
  # this file's state before #6527. An unrelated divergence of any shape must
  # stay unexplained on every kind.
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

  expect() { # <want name or ""> <got> <label>
    if [ "$1" != "$2" ]; then
      echo "FAIL: $3: want '$1' got '$2'"
      fail=1
    fi
  }

  # 7745-loop-defer-stack: the oracle keeps a flag and replays the deferred call at the exit; the tree
  # pushes a thunk (a function of its own, numbered in the closures' id space) and pops the stack. `g`
  # is not stack-mode and must come out byte-equal once the closure after the thunk is renumbered.
  ld_o='func f() void {
bb0():
  %0 = const_bool false
  %1 = const_string ""
  jump bb1(%0, %1)
bb1(%3: bool, %4: string):
  %5 = const_bool true
  br %5, bb2(), bb3(%3, %4)
bb2():
  %7 = const_string "x"
  %8 = const_bool true
  jump bb1(%8, %7)
bb3(%10: bool, %11: string):
  br %10, bb4(), bb5()
bb4():
  %13 = rt_call print(%11) void
  jump bb5()
bb5():
  ret
}

func g() void {
bb0():
  %0 = const_nil
  %1 = make_closure @closure$4, %0
  ret
}

func closure$4(%0: fn() void) void {
bb0(%0: fn() void):
  ret
}'
  ld_t='func f() void {
bb0():
  %0 = const_nil
  jump bb1(%0)
bb1(%2: []fn() void):
  %3 = const_bool true
  br %3, bb2(), bb3(%2)
bb2():
  %5 = const_string "x"
  %6 = const_nil
  %7 = gc_alloc size=8 ptrs=[%0] fn() void
  field_set %7[0] = %5
  %9 = make_closure @defer$thunk$3, %7
  %10 = rt_call slice_append(%2, %9) []fn() void
  jump bb1(%10)
bb3(%12: []fn() void):
  ret
}

func g() void {
bb0():
  %0 = const_nil
  %1 = make_closure @closure$5, %0
  ret
}

func closure$5(%0: fn() void) void {
bb0(%0: fn() void):
  ret
}

func defer$thunk$3(%0: fn() void) void {
bb0(%0: fn() void):
  %1 = field_get %0[0] string
  %2 = rt_call print(%1) void
  ret
}'
  expect "7745-loop-defer-stack" "$(explainMismatch "$ld_o" "$ld_t" ir)" "ir: a loop defer on the per-frame stack"
  expect "7745-loop-defer-stack" "$(explainMismatch "$ld_o" "$ld_t" iropt)" "iropt: a loop defer on the per-frame stack"
  expect "" "$(explainMismatch "$ld_o" "$ld_t" ast)" "ast: not a dump kind this signature reads"
  expect "" "$(explainMismatch "$ld_t" "$ld_o" ir)" "ir: the direction is fixed, the oracle on the stack is not explained"
  expect "" "$(explainMismatch "$ld_o" "${ld_t//rt_call print(%1)/rt_call eprint(%1)}" ir)" "ir: the thunk calls another function, the deferred call was dropped"
  expect "" "$(explainMismatch "$ld_o" "${ld_t/@closure\$5, %0/@closure\$6, %0}" ir)" "ir: a closure not renumbered by the thunks before it"
  expect "" "$(explainMismatch "$ld_o" "${ld_t/make_closure @closure\$5, %0
  ret/make_closure @closure\$5, %0
  %2 = rt_call k() void
  ret}" ir)" "ir: a function that is not stack-mode changed"
  expect "" "$(explainMismatch "$ld_o" "$ld_t

func defer\$thunk\$9(%0: fn() void) void {
bb0(%0: fn() void):
  ret
}" ir)" "ir: a thunk no function makes"
  expect "" "$(explainMismatch "$ld_o" "${ld_t//@defer\$thunk\$3/@defer\$thunk\$7}" ir)" "ir: a function makes a thunk the tree does not define"
  expect "" "$(explainMismatch "${ld_o/func f() void/func f2() void}" "$ld_t" ir)" "ir: the oracle has no function of the stack-mode function's name"
  expect "" "$(explainMismatch "$ld_o" "${ld_o/rt_call print/rt_call eprint}" ir)" "ir: no stack-mode function at all"

  # 7745-loop-defer-stack read by scripts/selfhost-diffsafepoints.sh (#7762): explainLoopDeferPolls
  # explains one extra poll per defer-stack pop loop (slice_len down to 0: icmp_sgt, slice_get,
  # call_value, back edge) added to ld_t's f, and nothing else.
  ld_p=${ld_t/"bb3(%12: []fn() void):
  ret"/"bb3(%12: []fn() void):
  %20 = slice_len %12
  jump bb6(%20)
bb6(%21: i64):
  %22 = const_int i64 0
  %23 = icmp_sgt bool %21, %22
  br %23, bb7(), bb8()
bb7():
  %25 = rt_call slice_get(%12, %21, %22) fn() void
  %26 = call_value %25() void
  jump bb6(%21)
bb8():
  ret"}
  expect "7745-loop-defer-stack" "$(explainLoopDeferPolls "$ld_o" "$ld_p" 1 2)" "polls: one pop loop, one extra poll"
  expect "" "$(explainLoopDeferPolls "$ld_o" "$ld_p" 1 3)" "polls: two extra polls for one pop loop"
  expect "" "$(explainLoopDeferPolls "$ld_o" "$ld_p" 1 1)" "polls: a pop loop that gained no poll"
  expect "" "$(explainLoopDeferPolls "$ld_o" "$ld_p" 2 1)" "polls: a MISSING safepoint is never explained"
  expect "" "$(explainLoopDeferPolls "$ld_o" "$ld_t" 1 2)" "polls: an extra poll with no pop loop"
  expect "" "$(explainLoopDeferPolls "$ld_o" "${ld_p/icmp_sgt/icmp_slt}" 1 2)" "polls: a pop loop with no header comparison"
  expect "" "$(explainLoopDeferPolls "$ld_o" "${ld_p/= call_value %25() void/= const_nil}" 1 2)" "polls: a pop loop that makes no deferred call"
  expect "" "$(explainLoopDeferPolls "$ld_o" "${ld_o/rt_call print/rt_call eprint}" 1 2)" "polls: no stack-mode function at all"

  # 7766-synth-json-helper-column-shift: only a column moves, on a line that carries a synthesized
  # `__json_` row, and only a synthesized name moves there; the file declares a `@json` class.
  jt_dir=$(mktemp -d "${TMPDIR:-/tmp}/t7785-sig.XXXXXX") || exit 2
  jt_json="$jt_dir/json.bit"
  jt_plain="$jt_dir/plain.bit"
  printf '// a comment\n@table @json class User { id: int }\n' >"$jt_json"
  printf '// @json is only named in a comment\nclass User { id: int }\n' >"$jt_plain"
  jt_o='7:5: x: i64
9:600: __json_p4: bool
9:610: __json_o: []JsonEntry
9:700: __json_x0: string
9:760: cols: []string
9:780: __row: User
11:3: y: bool'
  jt_b='7:5: x: i64
9:634: __json_p4: bool
9:644: __json_o: []JsonEntry
9:760: __json_x0: string
9:820: cols: []string
9:840: __row: User
11:3: y: bool'
  jt_sig=7766-synth-json-helper-column-shift
  expect "$jt_sig" "$(explainMismatch "$jt_o" "$jt_b" types "$jt_json")" "types: json helper column shift"
  expect "" "$(explainMismatch "$jt_o" "$jt_b" types "$jt_plain")" "types: a file with no @json class (the word only in a comment)"
  expect "" "$(explainMismatch "$jt_o" "$jt_b" types)" "types: no file named"
  expect "" "$(explainMismatch "$jt_o" "$jt_b" types "$jt_dir/missing.bit")" "types: a file that does not exist"
  expect "" "$(explainMismatch "$jt_o" "$jt_o" types "$jt_json")" "types: no row moved"
  expect "" "$(explainMismatch "$jt_o" "$jt_b" ir "$jt_json")" "ir: not a dump kind this signature reads"
  expect "" "$(explainMismatch "$jt_b" "$jt_o" types "$jt_json")" "types: the direction is fixed, a column that shrank"
  expect "" "$(explainMismatch "$jt_o" "${jt_b/__json_o: []JsonEntry/__json_o: []Json}" types "$jt_json")" "types: a __json_ type changed"
  expect "" "$(explainMismatch "$jt_o" "${jt_b/__json_x0/__json_x1}" types "$jt_json")" "types: a __json_ name changed"
  expect "" "$(explainMismatch "$jt_o" "${jt_b/x: i64/x: string}" types "$jt_json")" "types: a user binding changed type"
  expect "" "$(explainMismatch "$jt_o" "${jt_b/7:5:/7:6:}" types "$jt_json")" "types: a user binding moved on a line with no __json_ row"
  expect "" "$(explainMismatch "${jt_o/cols/n}" "${jt_b/cols/n}" types "$jt_json")" "types: a user-named binding moved on a synthesized line"
  expect "" "$(explainMismatch "$jt_o" "${jt_b/9:634:/10:634:}" types "$jt_json")" "types: a line number changed"
  expect "" "$(explainMismatch "$jt_o" "${jt_b/9:760:/9:710:}" types "$jt_json")" "types: a row after the shift did not move as far"
  expect "" "$(explainMismatch "$jt_o" "$(printf '%s\n' "$jt_b" | sed 2d)" types "$jt_json")" "types: a row is missing"
  expect "" "$(explainMismatch "$jt_o" "$jt_b
12:1: z: bool" types "$jt_json")" "types: a row was added"
  rm -f "${jt_json:?}" "${jt_plain:?}"
  rmdir "${jt_dir:?}"

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
