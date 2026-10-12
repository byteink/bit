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
# on types; the retired ones are in its Retirement history), and that
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
while [ "$#" -gt 0 ]; do
  if [ "$1" = -o ]; then object=$2; break; fi
  shift
done
case "$PROBE_CASE" in
  success|check-warning) printf object > "$object"; exit 0 ;;
  object-warning) printf object > "$object"; echo 'warning: accepted'; exit 0 ;;
  object-success-panic) printf object > "$object"; echo 'panic: failed'; exit 0 ;;
  no-object) exit 0 ;;
  refusal|stale) refusal; exit 1 ;;
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
  for row in 'success:ok' 'no-object:undecided' 'refusal:decline' 'notes:decline' \
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
