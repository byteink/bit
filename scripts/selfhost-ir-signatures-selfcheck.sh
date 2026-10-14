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
# shellcheck source=scripts/alarmrun.sh
. "${ROOT}/scripts/alarmrun.sh"
# shellcheck source=scripts/selfhost-diffdump-setup.sh
. "${ROOT}/scripts/selfhost-diffdump-setup.sh"
# shellcheck source=scripts/diffexit.sh
. "${ROOT}/scripts/diffexit.sh"

# Self-check: run directly (not sourced) to assert explainMismatch explains
# only what scripts/selfhost-ir-signatures.sh declares (7745-loop-defer-stack on
# ir/iropt, 7761-range-chain-cse on iropt, 7766-synth-json-helper-column-shift
# on types; the retired ones are in dump-differential.md), and that
# declaredSignatureNames() stays in sync with it.
# `bash scripts/selfhost-ir-signatures-selfcheck.sh`. Same pattern as
# scripts/selfhost-ir-canon.sh's self-check.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -u
  fail=0

  # Every signature this check once carried a fixture for is RETIRED; the
  # list, and the repin that retired each, is in scripts/selfhost-ir-
  # signatures registry's history in dump-differential.md, and fixtures are in git history at
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

  # #8110: complete token streams, raw UTF-8 witnesses and mixed regressions.
  token_dir=$(mktemp -d "${TMPDIR:-/tmp}/t8110-selfcheck-XXXXXX") || exit 2
  printf '\303\251 in in' > "$token_dir/source"
  token_old='ident 0..2
kw_in 3..5
semi 5..5
kw_in 6..8
eof 8..8'
  token_new='ident 0..2
ident 3..5
semi 5..5
ident 6..8
eof 8..8'
  token_sig=8110-contextual-in-token
  expect "$token_sig" "$(explainMismatch "$token_old" "$token_new" tokens "$token_dir/source")" 'contextual in multiple byte witnesses'
  expect "$token_sig" "$(explainMismatch 'kw_in 3..5' 'ident 3..5' tokens "$token_dir/source")" 'contextual in one witness'
  for token_kind in ir iropt ast fmt types diags; do
    expect "" "$(explainMismatch "$token_old" "$token_new" "$token_kind" "$token_dir/source")" "contextual in wrong kind $token_kind"
  done
  expect "" "$(explainMismatch "$token_new" "$token_old" tokens "$token_dir/source")" 'contextual in reverse'
  expect "" "$(explainMismatch "$token_old" "$token_old" tokens "$token_dir/source")" 'contextual in equal'
  expect "" "$(explainMismatch "$token_old" "$token_new" tokens)" 'contextual in missing source argument'
  expect "" "$(explainMismatch "$token_old" "$token_new" tokens "$token_dir/missing")" 'contextual in absent source'
  printf '\303\251 on in' > "$token_dir/wrong"
  expect "" "$(explainMismatch "$token_old" "$token_new" tokens "$token_dir/wrong")" 'contextual in wrong source bytes'
  printf '\303\251 in' > "$token_dir/short"
  expect "" "$(explainMismatch "$token_old" "$token_new" tokens "$token_dir/short")" 'contextual in source bounds'
  for token_change in 'ident 3..6' 'ident 03..5' 'ident 3..5 changed' 'kw_for 3..5'; do
    expect "" "$(explainMismatch 'kw_in 3..5' "$token_change" tokens "$token_dir/source")" "contextual in rejects $token_change"
  done
  expect "" "$(explainMismatch 'kw_in 2..4' 'ident 2..4' tokens "$token_dir/source")" 'contextual in character offsets are not bytes'
  expect "" "$(explainMismatch 'kw_in 3..6' 'ident 3..6' tokens "$token_dir/source")" 'contextual in span length'
  expect "" "$(explainMismatch 'kw_in 99999999999999999..100000000000000001' 'ident 99999999999999999..100000000000000001' tokens "$token_dir/source")" 'contextual in oversized span'
  token_rejects=("$token_new
extra 8..8" "${token_new%eof*}" 'ident 3..5
ident 0..2
semi 5..5
ident 6..8
eof 8..8' "${token_new/ident 0..2/string 0..2}" "${token_new/semi 5..5/semi 5..6}")
  for token_change in "${token_rejects[@]}"; do
    expect "" "$(explainMismatch "$token_old" "$token_change" tokens "$token_dir/source")" 'contextual in mixed row/order/cardinality/ASI delta'
  done
  cp() { command cp "$@" && printf x >> "$token_dir/source"; }
  expect "" "$(explainMismatch "$token_old" "$token_new" tokens "$token_dir/source")" 'contextual in source changed during witness'
  unset -f cp
  rm -rf "${token_dir:?}"

  # #7931: the shared IR probe must distinguish unsupported lowering from
  # absent tools, failed execution, stale objects and unrelated diagnostics.
  probe_dir=$(mktemp -d "${TMPDIR:-/tmp}/t7931-probe.XXXXXX") || exit 2
  trap 'rm -rf "${probe_dir:?}"' EXIT
  ORACLE="$probe_dir/compiler"
  TIMEOUT=300
  cat > "$ORACLE" <<'PROBE'
#!/usr/bin/env bash
source=$2
refusal() {
  printf 'bit: %s: refusing to emit an object\n' "$source"
  printf 'error[E0092]: unsupported lowering\n --> %s:1:1\n  |\n1 | source\n  | ^\n' "$source"
}
if [ "$1" = check ]; then
  case "$PROBE_CASE" in
    check-decline) echo 'error[E0053]: rejected'; exit 1 ;;
    check-panic) echo 'panic: failed'; exit 2 ;;
    check-timeout) exit 142 ;;
    check-signal) kill -TERM "$$" ;;
    check-127) exit 127 ;;
    check-warning) echo 'warning: accepted' ;;
    check-success-panic) echo 'panic: failed'; exit 0 ;;
  esac
  exit 0
fi
if [ "$PROBE_CASE" = host-target ]; then
  for arg in "$@"; do
    case "$arg" in --target|--target=*) exit 86 ;; esac
  done
fi
while [ "$#" -gt 0 ]; do
  if [ "$1" = -o ]; then object=$2; break; fi
  shift
done
case "$PROBE_CASE" in
  success|check-warning) printf object > "$object"; exit 0 ;;
  object-warning) printf object > "$object"; echo 'warning: accepted'; exit 0 ;;
  object-success-panic) printf object > "$object"; echo 'panic: failed'; exit 0 ;;
  no-object) exit 0 ;;
  refusal|stale|host-target) refusal; exit 1 ;;
  notes) refusal; printf "note: while emitting 'f<i64>', instantiated here\n --> %s:2:1\n" "$source"; exit 1 ;;
  mixed) refusal; echo 'error[E0053]: unrelated'; exit 1 ;;
  wrong-source) source=wrong.bit; refusal; exit 1 ;;
  wrong-location) printf 'bit: %s: refusing to emit an object\nerror[E0092]: unsupported\n --> wrong.bit:1:1\n' "$source"; exit 1 ;;
  malformed-location) printf 'bit: %s: refusing to emit an object\nerror[E0092]: unsupported\n --> %s\n' "$source" "$source"; exit 1 ;;
  missing-location) printf 'bit: %s: refusing to emit an object\nerror[E0092]: unsupported\n' "$source"; exit 1 ;;
  panic) refusal; echo 'panic: failed'; exit 1 ;;
  object-refusal) printf object > "$object"; refusal; exit 1 ;;
  other-error) echo 'error[E0053]: unrelated'; exit 1 ;;
  status-126) exit 126 ;;
  status-127) exit 127 ;;
  timeout) exit 142 ;;
  signal) kill -TERM "$$" ;;
esac
PROBE
  chmod +x "$ORACLE"
  for row in 'success:ok' 'no-object:undecided' 'refusal:decline' 'host-target:decline' 'notes:decline' \
    'stale:decline' 'mixed:undecided' 'wrong-source:undecided' 'wrong-location:undecided' \
    'malformed-location:undecided' 'missing-location:undecided' \
    'panic:undecided' 'object-refusal:undecided' 'other-error:undecided' \
    'status-126:undecided' 'status-127:undecided' 'timeout:undecided' 'signal:undecided' \
    'check-decline:decline' 'check-panic:undecided' 'check-timeout:undecided' \
    'check-signal:undecided' 'check-127:undecided' 'check-warning:ok' 'object-warning:ok' \
    'check-success-panic:undecided' 'object-success-panic:undecided'; do
    PROBE_CASE=${row%%:*}; export PROBE_CASE
    printf stale > "$probe_dir/oracle-object.o"
    status=$(oracle_ir_coverage "$probe_dir/input.bit" "$probe_dir")
    expect "${row#*:}" "$status" "oracle coverage: $PROBE_CASE"
    case "$status" in
      ok) mismatch=1; undecided=0 ;;
      decline) mismatch=0; undecided=0 ;;
      *) mismatch=0; undecided=1 ;;
    esac
    (diffexit probe -f "$mismatch" -t "probe=$undecided") >/dev/null
    rc=$?
    case "${row#*:}" in
      ok) expect 1 "$rc" 'lowerable unexplained difference stays red' ;;
      decline) expect 0 "$rc" 'actual refusal is coverage' ;;
      *) expect 2 "$rc" 'failed probe never passes' ;;
    esac
  done
  chmod -x "$ORACLE"
  expect undecided "$(oracle_ir_coverage input.bit "$probe_dir")" 'nonexecutable oracle'
  ORACLE="$probe_dir/missing"
  expect undecided "$(oracle_ir_coverage input.bit "$probe_dir")" 'missing oracle'
  unset ORACLE PROBE_CASE

  # The owner signature needs native evidence, even for plausible root text.
  fnv_old='func fnvalue$trampoline$9(%0: fn(i64) i64, %1: i64) i64 {'
  fnv_new='  %0 = global_addr @__bitfnv_8'
  expect "" "$(explainMismatch "$fnv_old" "$fnv_new" ir)" "fnvalue: missing source stays unexplained"
  expect "" "$(explainMismatch "$fnv_old" "$fnv_new" iropt /no/such/source.bit)" "fnvalue: unavailable evidence stays unexplained"

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

  # 7761-range-chain-cse: f's `c < '0' || c > '9'` is fused into one `icmp_ule` on `c - '0'` (one block and
  # one `br` gone, the `||` mirror: edges swapped), and the body's `c - '0'` on the if body's param is
  # forwarded to that `sub` (#7770). h is #7770 alone: an `add` on a single-edge param forwarded to its
  # twin. g does not move.
  rc_o='func f(%0: u8) i64 {
bb0(%0: u8):
  %1 = const_int u8 48
  %2 = icmp_ult bool %0, %1
  br %2, bb2(), bb1()
bb1():
  %4 = const_int u8 57
  %5 = icmp_ugt bool %0, %4
  br %5, bb2(), bb3(%0)
bb2():
  %7 = const_int i64 -1
  ret %7
bb3(%9: u8):
  %10 = sub u8 %9, %1
  %11 = convert i64 %10
  ret %11
}

func h(%0: i64, %1: bool) i64 {
bb0(%0: i64, %1: bool):
  %2 = const_int i64 1
  %3 = add i64 %0, %2
  br %1, bb1(%0), bb2()
bb1(%5: i64):
  %6 = add i64 %5, %2
  ret %6
bb2():
  ret %3
}

func g() void {
bb0():
  ret
}'
  rc_t='func f(%0: u8) i64 {
bb0(%0: u8):
  %1 = const_int u8 48
  %2 = sub u8 %0, %1
  %3 = const_int u8 9
  %4 = icmp_ule bool %2, %3
  br %4, bb2(%0), bb1()
bb1():
  %6 = const_int i64 -1
  ret %6
bb2(%8: u8):
  %9 = convert i64 %2
  ret %9
}

func h(%0: i64, %1: bool) i64 {
bb0(%0: i64, %1: bool):
  %2 = const_int i64 1
  %3 = add i64 %0, %2
  br %1, bb1(), bb2()
bb1():
  ret %3
bb2():
  ret %3
}

func g() void {
bb0():
  ret
}'
  rc_h=${rc_t%%"func h"*}${rc_o#*"}

"}
  # Each variant is built by a bare assignment: bash 3.2 keeps the quotes of a `${v/"a"/"b"}` that sits
  # inside a double-quoted word, so the pattern never matches and the "variant" would be the base.
  rc_sub=${rc_t/"  %9 = convert"/"  %12 = sub u8 %8, %1
  %13 = sub u8 %12, %1
  %9 = convert"}
  rc_ugt=${rc_t/"  %9 = convert"/"  %12 = icmp_ugt bool %8, %1
  %9 = convert"}
  rc_ule=${rc_t/"  %9 = convert"/"  %12 = icmp_ule bool %8, %1
  %9 = convert"}
  rc_add=${rc_t/"  %9 = convert"/"  %12 = add u8 %8, %1
  %9 = convert"}
  rc_ren=${rc_t/"func g()"/"func k()"}
  rc_jmp=${rc_t/"bb2(%8: u8):"/"bb3():
  jump bb2(%0)
bb2(%8: u8):"}
  rc_ret=${rc_t/"  %9 = convert i64 %2
  ret %9
}"/"  %9 = convert i64 %2
}"}
  rc_conv=${rc_t/"  %9 = convert i64 %2
  ret %9"/"  ret %2"}
  rc_blk=${rc_t/"bb2(%8: u8):"/"bb3():
bb2(%8: u8):"}
  rc_opnd=${rc_o/"bb2():
  ret %3"/"bb2():
  ret %0"}
  rc_slt=${rc_o/icmp_ult/icmp_slt}
  rc_nog=${rc_t%%"func g"*}
  rc_pre="global @g i64
$rc_t"
  for v in "$rc_h" "$rc_sub" "$rc_ugt" "$rc_ule" "$rc_add" "$rc_ren" "$rc_jmp" "$rc_ret" "$rc_conv" "$rc_blk" "$rc_nog" "$rc_pre"; do
    [ "$v" != "$rc_t" ] || { echo "FAIL: a 7761 fixture variant equals its base"; fail=1; }
  done
  [ "$rc_opnd" != "$rc_o" ] && [ "$rc_slt" != "$rc_o" ] || { echo "FAIL: a 7761 oracle variant equals its base"; fail=1; }
  expect "7761-range-chain-cse" "$(explainMismatch "$rc_o" "$rc_t" iropt)" "iropt: a fused range check and a param-keyed CSE"
  expect "7761-range-chain-cse" "$(explainMismatch "$rc_o" "$rc_h" iropt)" "iropt: a fused range check alone"
  expect "" "$(explainMismatch "$rc_o" "$rc_t" ir)" "ir: both transforms are post-opt, the pre-opt dump never moves"
  expect "" "$(explainMismatch "$rc_t" "$rc_o" iropt)" "iropt: the direction is fixed, an unfused tree is not explained"
  expect "" "$(explainMismatch "$rc_o" "$rc_sub" iropt)" "iropt: two more subs than fused sites"
  expect "" "$(explainMismatch "$rc_o" "$rc_ugt" iropt)" "iropt: a fused || that kept its icmp_ugt"
  expect "" "$(explainMismatch "$rc_o" "$rc_ule" iropt)" "iropt: one icmp_ule more than fused || sites"
  expect "" "$(explainMismatch "$rc_o" "$rc_add" iropt)" "iropt: an op neither transform adds (add)"
  expect "" "$(explainMismatch "$rc_o" "$rc_ren" iropt)" "iropt: a function renamed"
  expect "" "$(explainMismatch "$rc_o" "$rc_jmp" iropt)" "iropt: a block added behind a jump"
  expect "" "$(explainMismatch "$rc_o" "$rc_ret" iropt)" "iropt: a ret dropped"
  expect "" "$(explainMismatch "$rc_o" "$rc_conv" iropt)" "iropt: a dropped op CSE never forwards (convert)"
  expect "" "$(explainMismatch "$rc_o" "$rc_blk" iropt)" "iropt: an emptied block kept for a fused site"
  expect "" "$(explainMismatch "$rc_slt" "$rc_t" iropt)" "iropt: a signed compare is never fused"
  expect "" "$(explainMismatch "$rc_o" "$rc_opnd" iropt)" "iropt: an operand changed with no op removed"
  expect "" "$(explainMismatch "$rc_o" "$rc_nog" iropt)" "iropt: a function went missing"
  expect "" "$(explainMismatch "$rc_o" "$rc_pre" iropt)" "iropt: the text ahead of the first function differs"
  expect "" "$(explainMismatch "$rc_o" "$rc_o" iropt)" "iropt: nothing differs"

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

  # #7933: the registered types identity must fire on a real swept source.
  vt_dir=$(mktemp -d "${TMPDIR:-/tmp}/t7933-selfcheck-XXXXXX") || exit 2
  ORACLE="${ROOT}/bit-out/stage0/bit-oracle"; BIT2="${ROOT}/bit-out/bin/bit"
  BIT_STDLIB="${ROOT}/stdlib"; export BIT_STDLIB
  TIMEOUT=20
  vt_sig=7933-variadic-type-marker
  vt_corpus="${ROOT}/_tests_/cases/run_func_value_args_ok.bit"
  vt_old=$(alarmrun "$ORACLE" --dump-types "$vt_corpus"); vt_rc=$?
  expect 0 "$vt_rc" 'variadic corpus: oracle dump succeeds'
  vt_new=$(alarmrun "$BIT2" --dump-types "$vt_corpus"); vt_rc=$?
  expect 0 "$vt_rc" 'variadic corpus: current dump succeeds'
  expect "$vt_sig" "$(explainMismatch "$vt_old" "$vt_new" types "$vt_corpus")" 'variadic corpus: live registered identity'
  vt_source="$vt_dir/input.bit"
  cat > "$vt_source" <<'BIT'
fn ordinary(x: int): int { return x }
fn variadic(prefix: string, ...xs: int): int { return len(xs) }
fn main() {
  let a = ordinary
  let b = variadic
  let nested = [](int) => int{ ordinary }
  println("${a(3)} ${b("x", 4, 5)} ${nested[0](7)}")
}
BIT
  vt_old=$(alarmrun "$ORACLE" --dump-types "$vt_source"); vt_rc=$?
  expect 0 "$vt_rc" 'variadic fixture: oracle dump succeeds'
  vt_new=$(alarmrun "$BIT2" --dump-types "$vt_source"); vt_rc=$?
  expect 0 "$vt_rc" 'variadic fixture: current dump succeeds'
  expect "$vt_sig" "$(explainMismatch "$vt_old" "$vt_new" types "$vt_source")" 'variadic fixed prefix, ordinary and nested rows preserved'
  expect "" "$(explainMismatch "$vt_old" "$vt_old" types "$vt_source")" 'variadic marker removed'
  expect "" "$(explainMismatch "$vt_new" "$vt_old" types "$vt_source")" 'variadic marker direction reversed'
  expect "" "$(explainMismatch "$vt_old" "$vt_new" ir "$vt_source")" 'variadic identity does not widen IR'
  for vt_delta in ordinary return param slot position name nested; do
    case "$vt_delta" in
      ordinary) vt_bad=${vt_new/a: (i64) => i64/a: (...i64) => i64} ;;
      return) vt_bad=${vt_new/b: (string, ...i64) => i64/b: (string, ...i64) => string} ;;
      param) vt_bad=${vt_new/b: (string, ...i64)/b: (string, ...u64)} ;;
      slot) vt_bad=${vt_new/b: (string, ...i64)/b: (...string, i64)} ;;
      position) vt_bad=${vt_new/5:7: b:/5:8: b:} ;;
      name) vt_bad=${vt_new/b: (/other: (} ;;
      nested) vt_bad=${vt_new/nested: [](/nested: [](...} ;;
    esac
    expect "" "$(explainMismatch "$vt_old" "$vt_bad" types "$vt_source")" "variadic rejects $vt_delta delta"
  done
  expect "" "$(explainMismatch "$vt_old" "$(printf '%s\n' "$vt_new" | sed '2d')" types "$vt_source")" 'variadic removed row'
  expect "" "$(explainMismatch "$vt_old" "$vt_new
9:1: extra: i64" types "$vt_source")" 'variadic added row'
  expect "" "$(explainMismatch "$vt_old" "$(printf '%s\n' "$vt_new" | sed '1h;1d;2G')" types "$vt_source")" 'variadic reordered rows'
  printf 'fn main() { let b = 3 }\n' > "$vt_dir/unrelated.bit"
  expect "" "$(explainMismatch "$vt_old" "$vt_new" types "$vt_dir/unrelated.bit")" 'variadic unrelated source'
  printf 'fn ordinary(x: int): int { return x }\nfn variadic(...xs: int): int { return len(xs) }\nfn main() { let variadic = ordinary; let b = variadic }\n' > "$vt_dir/shadow.bit"
  expect "" "$(explainMismatch "$vt_old" "$vt_new" types "$vt_dir/shadow.bit")" 'variadic shadowed source'
  # Each accepted binder shadows the variadic declaration with an ordinary callback.
  for vt_pattern in loop tuple match catch; do
    vt_shadow="$vt_dir/$vt_pattern.bit"
    printf 'fn ordinary(x: int): int { return x }\nfn variadic(...xs: int): int { return len(xs) }\n' > "$vt_shadow"
    case "$vt_pattern" in
      loop) printf 'fn main() { for variadic of [](int) => int{ ordinary } { let b = variadic; } }\n' ;;
      tuple) printf 'fn main() { let (variadic, n) = (ordinary, 3); let b = variadic; }\n' ;;
      match) printf 'enum Callback { One((int) => int) }\nfn main() { match (Callback.One(ordinary)) { One(variadic) => { let b = variadic; } } }\n' ;;
      catch) printf 'type Callback = (int) => int\nfn failure(): int!Callback { fail ordinary }\nfn main() { let n = failure() catch variadic { let b = variadic; return } }\n' ;;
    esac >> "$vt_shadow"
    vt_shadow_old=$(alarmrun "$ORACLE" --dump-types "$vt_shadow"); vt_rc=$?
    expect 0 "$vt_rc" "variadic $vt_pattern shadow: oracle dump succeeds"
    vt_shadow_new=$(alarmrun "$BIT2" --dump-types "$vt_shadow"); vt_rc=$?
    expect 0 "$vt_rc" "variadic $vt_pattern shadow: current dump succeeds"
    for vt_binary in "$ORACLE" "$BIT2"; do
      alarmrun "$vt_binary" check "$vt_shadow" > "$vt_dir/check"; vt_rc=$?
      expect 0 "$vt_rc" "variadic $vt_pattern shadow: accepted source"
    done
    expect "$vt_shadow_old" "$vt_shadow_new" "variadic $vt_pattern shadow: unchanged ordinary type"
    vt_forged=${vt_shadow_new/b: (i64) => i64/b: (...i64) => i64}
    expect no "$([ "$vt_forged" = "$vt_shadow_new" ] && printf yes || printf no)" "variadic $vt_pattern shadow: forged row differs"
    expect "" "$(explainMismatch "$vt_shadow_old" "$vt_forged" types "$vt_shadow")" "variadic rejects $vt_pattern binder shadow"
  done
  VT_REAL_ORACLE=$ORACLE; export VT_REAL_ORACLE
  cat > "$vt_dir/failed" <<'PROBE'
#!/bin/sh
case "$VT_WITNESS_FAILURE:$1" in
  fail:check) exit 1 ;;
  timeout:--dump-ast) exit 142 ;;
  tokens:--dump-tokens) printf 'ident 0..1\n'; exit 0 ;;
  ast:--dump-ast) printf '(program)\n'; exit 0 ;;
esac
exec "$VT_REAL_ORACLE" "$@"
PROBE
  chmod +x "$vt_dir/failed"
  ORACLE="$vt_dir/failed"
  for VT_WITNESS_FAILURE in fail timeout tokens ast; do
    export VT_WITNESS_FAILURE
    expect "" "$(explainMismatch "$vt_old" "$vt_new" types "$vt_source")" "variadic failed $VT_WITNESS_FAILURE witness"
  done
  ORACLE="$vt_dir/missing"
  expect "" "$(explainMismatch "$vt_old" "$vt_new" types "$vt_source")" 'variadic missing witness'
  ORACLE=$VT_REAL_ORACLE
  expect "" "$(explainMismatch "$vt_old" "$vt_new" types "$vt_dir/missing.bit")" 'variadic missing source'
  unset ORACLE BIT2 VT_WITNESS_FAILURE VT_REAL_ORACLE
  rm -rf "${vt_dir:?}"

  # #7936: real SQL module captures, with one shared same-source AST parser.
  vd_dir=$(mktemp -d "${TMPDIR:-/tmp}/t7936-selfcheck-XXXXXX") || exit 2
  ORACLE="${ROOT}/bit-out/stage0/bit-oracle"; BIT2="${ROOT}/bit-out/bin/bit"
  vd_module="${ROOT}/stdlib/sql"
  for vd_side in old new; do
    vd_binary=$ORACLE; [ "$vd_side" = new ] && vd_binary=$BIT2
    alarmrun "$vd_binary" doc "$vd_module" > "$vd_dir/$vd_side"; vd_rc=$?
    expect 0 "$vd_rc" "doc variadic $vd_side plain capture"
    alarmrun "$vd_binary" doc --json "$vd_module" > "$vd_dir/${vd_side}json"; vd_rc=$?
    expect 0 "$vd_rc" "doc variadic $vd_side JSON capture"
  done
  vd_sig=7936-variadic-doc-marker
  expect "$vd_sig" "$(explainVariadicDocMarker "$vd_dir/old" "$vd_dir/new" "$vd_dir/oldjson" "$vd_dir/newjson" "$vd_module")" 'doc variadic native SQL identity'
  variadicDocWitness "$vd_dir" "$vd_module"; vd_rc=$?
  expect 0 "$vd_rc" 'doc variadic accepted SQL metadata'
  variadicMarkerParse "$vd_dir" doc; vd_rc=$?
  expect 0 "$vd_rc" 'doc variadic shared parser positive'
  perl - "$vd_dir" <<'PERL'
use strict; use warnings; use File::Path qw(make_path);
my $d = shift;
sub readall { open my $f, '<:raw', $_[0] or die; local $/; return <$f> }
my @files = qw(old new oldjson newjson source 0--dump-ast);
my %base = map { $_ => readall("$d/$_") } @files;
my @deltas = (
  ['name','new',qr/function find<T>/,'function other<T>'],
  ['generic','new',qr/function find<T>/,'function find<U>'],
  ['type','new',qr/Executor, string, \.\.\.Value/,'Executor, string, ...string'],
  ['count','new',qr/Executor, string, \.\.\.Value/,'Executor, ...Value'],
  ['slot','new',qr/Executor, string, \.\.\.Value/,'...Executor, string, Value'],
  ['return','new',qr/=> \[\]T!/,'=> T!'],
  ['other','new',qr/interface Executor/,'interface Different'],
  ['json-name','newjson',qr/"name": "find"/,'"name": "other"'],
  ['json-generic','newjson',qr/"params": "<T>"/,'"params": "<U>"'],
  ['json-type','newjson',qr/Executor, string, \.\.\.Value/,'Executor, string, ...string'],
  ['json-doc','newjson',qr/"doc": "/,'"doc": "changed'],
  ['no-rest','0--dump-ast',qr/param_rest args Value/,'param args Value'],
  ['ast-return','0--dump-ast',qr/\(func_decl _ find \(generic_params \(generic_param T _\)\) \(params \(param db Executor\) \(param sqlText string\) \(param_rest args Value\)\) \(fallible \(slice_type T\) _\)/,'(func_decl _ find (generic_params (generic_param T _)) (params (param db Executor) (param sqlText string) (param_rest args Value)) (fallible T _)'],
  ['ambiguous','0--dump-ast',qr/\)\s*\z/,' (func_decl _ find _ (params (param_rest args Value)) T (block)))'],
);
for my $delta (@deltas) {
  my ($label,$file,$from,$to) = @$delta; my %case = %base;
  die unless $case{$file} =~ s/$from/$to/;
  make_path("$d/$label");
  for my $f (@files) { open my $out, '>:raw', "$d/$label/$f" or die; print {$out} $case{$f} or die; close $out or die }
}
for my $label (qw(added removed order duplicate)) {
  my %case = %base; my @rows = split /\n/, $case{new};
  if ($label eq 'added') { push @rows, 'function extra () => i64' }
  if ($label eq 'removed') { pop @rows }
  if ($label eq 'order') { @rows[0,1] = @rows[1,0] }
  if ($label eq 'duplicate') {
    push @rows, (grep { /^function find</ } @rows)[0];
    $case{old} .= (grep { /^function find</ } split /\n/, $case{old})[0] . "\n";
  }
  $case{new} = join("\n", @rows) . "\n"; make_path("$d/$label");
  for my $f (@files) { open my $out, '>:raw', "$d/$label/$f" or die; print {$out} $case{$f} or die; close $out or die }
}
PERL
  vd_rc=$?; expect 0 "$vd_rc" 'doc variadic adversarial controls are real deltas'
  for vd_control in name generic type count slot return other json-name json-generic json-type json-doc no-rest ast-return ambiguous added removed order duplicate; do
    variadicMarkerParse "$vd_dir/$vd_control" doc > "$vd_dir/reject" 2>&1; vd_rc=$?
    expect no "$([ "$vd_rc" -eq 0 ] && printf yes || printf no)" "doc variadic rejects $vd_control"
  done
  mkdir "$vd_dir/module"
  printf 'export fn sum(xs: int): int { return xs }\n' > "$vd_dir/module/m.bit"
  for vd_side in old new; do
    vd_binary=$ORACLE; [ "$vd_side" = new ] && vd_binary=$BIT2
    alarmrun "$vd_binary" check "$vd_dir/module" > "$vd_dir/check"; vd_rc=$?
    expect 0 "$vd_rc" "doc ordinary $vd_side accepted"
    alarmrun "$vd_binary" doc "$vd_dir/module" > "$vd_dir/${vd_side}ordinary"
    vd_rc=$?; expect 0 "$vd_rc" "doc ordinary $vd_side plain"
    alarmrun "$vd_binary" doc --json "$vd_dir/module" > "$vd_dir/${vd_side}ordinaryjson"
    vd_rc=$?; expect 0 "$vd_rc" "doc ordinary $vd_side JSON"
  done
  sed 's/(i64)/(...i64)/' "$vd_dir/newordinary" > "$vd_dir/forgedordinary"
  sed 's/(i64)/(...i64)/' "$vd_dir/newordinaryjson" > "$vd_dir/forgedordinaryjson"
  expect "" "$(explainVariadicDocMarker "$vd_dir/oldordinary" "$vd_dir/forgedordinary" "$vd_dir/oldordinaryjson" "$vd_dir/forgedordinaryjson" "$vd_dir/module")" 'doc ordinary native marker forgery'
  printf 'export fn sum(...xs: int): int { return len(xs) }\nfn main() { let sum = (x: int) => x; let b = sum; }\n' > "$vd_dir/module/m.bit"
  for vd_side in old new; do
    vd_binary=$ORACLE; [ "$vd_side" = new ] && vd_binary=$BIT2
    alarmrun "$vd_binary" check "$vd_dir/module" > "$vd_dir/check"; vd_rc=$?
    expect 0 "$vd_rc" "doc shadow $vd_side accepted"
    alarmrun "$vd_binary" doc "$vd_dir/module" > "$vd_dir/${vd_side}shadow"
    vd_rc=$?; expect 0 "$vd_rc" "doc shadow $vd_side plain"
    alarmrun "$vd_binary" doc --json "$vd_dir/module" > "$vd_dir/${vd_side}shadowjson"
    vd_rc=$?; expect 0 "$vd_rc" "doc shadow $vd_side JSON"
  done
  expect "" "$(explainVariadicDocMarker "$vd_dir/oldshadow" "$vd_dir/newshadow" "$vd_dir/oldshadowjson" "$vd_dir/newshadowjson" "$vd_dir/module")" 'doc native shadow metadata declines'
  VD_REAL_ORACLE=$ORACLE; export VD_REAL_ORACLE
  cat > "$vd_dir/failed" <<'PROBE'
#!/bin/sh
case "$VD_FAILURE:$1" in
  check:check|doc:doc) exit 1 ;;
  json:doc) [ "${2:-}" != --json ] || exit 1 ;;
  timeout:doc|timeout-check:check) exit 142 ;;
  crash:check|crash-doc:doc) exit 139 ;;
  ast:--dump-ast) printf '(program)\n'; exit 0 ;;
  tokens:--dump-tokens) printf 'ident 0..1\n'; exit 0 ;;
  source:doc) printf '// changed during witness\n' >> "$VD_MODULE/m.bit" ;;
esac
exec "$VD_REAL_ORACLE" "$@"
PROBE
  chmod +x "$vd_dir/failed"
  VD_REAL_BIT2=$BIT2
  ORACLE="$vd_dir/failed"
  for VD_FAILURE in check doc json timeout timeout-check crash crash-doc ast tokens; do
    export VD_FAILURE
    expect "" "$(explainVariadicDocMarker "$vd_dir/old" "$vd_dir/new" "$vd_dir/oldjson" "$vd_dir/newjson" "$vd_module")" "doc variadic failed $VD_FAILURE witness"
  done
  ORACLE=$VD_REAL_ORACLE
  VD_REAL_ORACLE=$VD_REAL_BIT2; export VD_REAL_ORACLE
  BIT2="$vd_dir/failed"; VD_FAILURE=ast; export VD_FAILURE
  expect "" "$(explainVariadicDocMarker "$vd_dir/old" "$vd_dir/new" "$vd_dir/oldjson" "$vd_dir/newjson" "$vd_module")" 'doc variadic current AST differs'
  BIT2=$VD_REAL_BIT2
  printf 'export fn sum(...xs: int): int { return len(xs) }\n' > "$vd_dir/module/m.bit"
  expect "$vd_sig" "$(explainVariadicDocMarker "$vd_dir/oldshadow" "$vd_dir/newshadow" "$vd_dir/oldshadowjson" "$vd_dir/newshadowjson" "$vd_dir/module")" 'doc source-change control begins with a live witness'
  VD_REAL_ORACLE=$ORACLE; VD_MODULE="$vd_dir/module"; VD_FAILURE=source
  export VD_REAL_ORACLE VD_MODULE VD_FAILURE
  ORACLE="$vd_dir/failed"
  expect "" "$(explainVariadicDocMarker "$vd_dir/oldshadow" "$vd_dir/newshadow" "$vd_dir/oldshadowjson" "$vd_dir/newshadowjson" "$vd_dir/module")" 'doc module bytes changed during witness'
  ORACLE=$VD_REAL_ORACLE
  expect "" "$(explainVariadicDocMarker "$vd_dir/old" "$vd_dir/new" "$vd_dir/oldjson" "$vd_dir/newjson" "${ROOT}/stdlib/strings")" 'doc variadic different module source'
  unset ORACLE BIT2 VD_REAL_ORACLE VD_REAL_BIT2 VD_FAILURE VD_MODULE
  rm -rf "${vd_dir:?}"

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
