#!/usr/bin/env bash
# Self-check for scripts/selfhost-ir-signatures.sh's explainMismatch, split
# into its own file by #5442 so the main file (which both selfhost-diffdump.sh
# and selfhost-diffruntime.sh source) stays under the 800-line ceiling
# (spec/LINT.md) as new signatures are added. Pure move of the self-check
# block, plus the #5429 cases below it: no scoring logic changed. Discovered
# and run directly by scripts/selfhost-diffall.sh's `scripts/selfhost-*.sh`
# glob, same as the file it tests.
ROOT="$(cd -- "$(dirname -- "$0")/.." && pwd)"
# shellcheck source=scripts/selfhost-ir-signatures.sh
. "${ROOT}/scripts/selfhost-ir-signatures.sh"

# Self-check: run directly (not sourced) to assert explainMismatch still
# accepts the #3107 shape and still rejects an unrelated single-opcode delta.
# `bash scripts/selfhost-ir-signatures-selfcheck.sh`. Same pattern as
# scripts/selfhost-ir-canon.sh's self-check.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -u
  fail=0

  # #3107, #3108, #3898 and #3862 were declared here and RETIRED by #5509
  # (each explained zero corpus files by the time #5486 landed — see
  # scripts/selfhost-ir-signatures.sh's header). Their shaped-delta fixtures
  # lived in this self-check; removed with the arms they tested rather than
  # kept as tests for identities that no longer exist. Git history at this
  # file's state before #5509 has them.

  # An unrelated single-opcode delta (the #3125 mutation-test shape: a binop
  # flipped from sub to add) must NOT be explained by anything declared.
  oracle_unrelated='%1 = sub %2, %3'
  bit2_unrelated='%1 = sub %2, %3
%4 = sub %5, %6'

  sig2=$(explainMismatch "$oracle_unrelated" "$bit2_unrelated" ir)
  rc2=$?
  if [ "$rc2" -eq 0 ] || [ -n "$sig2" ]; then
    echo "FAIL: an unrelated opcode delta was wrongly explained (rc=$rc2 sig='$sig2')"
    fail=1
  fi

  # --- #5429: decimal boxed-slot explode, both dump kinds (#5442) ---
  #
  # Real dump text (#5442), not hand-tuned: `bit-oracle --dump-ir-pre`/`--dump-ir`
  # and `bit-out/bin/bit --dump-ir-pre`/`--dump-ir` on the actual
  # `_tests_/cases/decimal_tuple_member.bit` fixture #5429 added -- one write
  # site (building the `(decimal, i64)` return) and one read site (destructuring
  # and printing it), Nw=1 Nr=1 at pre-opt.
  oracle_5429_pre='func pair() (decimal, i64) {
bb0():
  %0 = const_int i64 35
  %1 = const_int i64 4294967296
  %2 = gc_alloc size=16 ptrs=[] (i64, i64)
  field_set %2[0] = %0
  field_set %2[8] = %1
  %5 = const_int i64 7
  %6 = gc_alloc size=24 ptrs=[] (decimal, i64)
  field_set %6[0] = %2
  field_set %6[16] = %5
  ret %6
}

func main() void {
bb0():
  %0 = call @pair() (decimal, i64)
  %1 = field_get %0[0] decimal
  %2 = field_get %0[16] i64
  %3 = field_get %1[0] i64
  %4 = field_get %1[8] i64
  %5 = rt_call string_from_decimal(%3, %4) string
  %6 = const_string " "
  %7 = rt_call string_from_int(%2) string
  %8 = const_string ""
  %9 = rt_call string_concat5(%5, %6, %7, %8, %8) string
  %10 = call @m0$println(%9) void
  ret
}'
  bit2_5429_pre='func pair() (decimal, i64) {
bb0():
  %0 = const_int i64 35
  %1 = const_int i64 4294967296
  %2 = gc_alloc size=16 ptrs=[] (i64, i64)
  field_set %2[0] = %0
  field_set %2[8] = %1
  %5 = const_int i64 7
  %6 = gc_alloc size=24 ptrs=[] (decimal, i64)
  %7 = field_get %2[0] i64
  %8 = field_get %2[8] i64
  field_set %6[0] = %7
  field_set %6[8] = %8
  field_set %6[16] = %5
  ret %6
}

func main() void {
bb0():
  %0 = call @pair() (decimal, i64)
  %1 = field_get %0[0] i64
  %2 = field_get %0[8] i64
  %3 = gc_alloc size=16 ptrs=[] (i64, i64)
  field_set %3[0] = %1
  field_set %3[8] = %2
  %6 = field_get %0[16] i64
  %7 = field_get %3[0] i64
  %8 = field_get %3[8] i64
  %9 = rt_call string_from_decimal(%7, %8) string
  %10 = const_string " "
  %11 = rt_call string_from_int(%6) string
  %12 = const_string ""
  %13 = rt_call string_concat5(%9, %10, %11, %12, %12) string
  %14 = call @m0$println(%13) void
  ret
}'

  sig5429=$(explainMismatch "$oracle_5429_pre" "$bit2_5429_pre" ir)
  rc5429=$?
  if [ "$rc5429" -ne 0 ] || [ "$sig5429" != "5429-decimal-boxed-slot-explode" ]; then
    echo "FAIL: a real #5429 pre-opt delta was not explained (rc=$rc5429 sig='$sig5429')"
    fail=1
  fi

  # Post-opt: same fixture, `--dump-ir`. The optimizer inlines pair() into
  # main() on the oracle side (still needing the two-alloc box roundtrip) and
  # eliminates it entirely on the bit2 side (the flat (i64, i64) words never
  # need a box at all once nothing observes the pointer) -- field_get and
  # gc_alloc both fall by exactly 3, nothing else moves.
  oracle_5429_post='func pair() (decimal, i64) {
bb0():
  %0 = const_int i64 35
  %1 = const_int i64 4294967296
  %2 = gc_alloc size=16 ptrs=[] (i64, i64)
  field_set %2[0] = %0
  field_set %2[8] = %1
  %5 = const_int i64 7
  %6 = gc_alloc size=24 ptrs=[] (decimal, i64)
  field_set %6[0] = %2
  field_set %6[16] = %5
  ret %6
}

func main() void {
bb0():
  %0 = const_int i64 35
  %1 = const_int i64 4294967296
  %2 = gc_alloc size=16 ptrs=[] (i64, i64)
  field_set %2[0] = %0
  field_set %2[8] = %1
  %5 = const_int i64 7
  %6 = gc_alloc size=24 ptrs=[] (decimal, i64)
  field_set %6[0] = %2
  field_set %6[16] = %5
  %9 = field_get %6[0] decimal
  %10 = field_get %9[0] i64
  %11 = field_get %9[8] i64
  %12 = rt_call string_from_decimal(%10, %11) string
  %13 = const_string " "
  %14 = rt_call string_from_int(%5) string
  %15 = const_string ""
  %16 = rt_call string_concat5(%12, %13, %14, %15, %15) string
  %17 = call @m0$println(%16) void
  ret
}'
  bit2_5429_post='func pair() (decimal, i64) {
bb0():
  %0 = const_int i64 35
  %1 = const_int i64 4294967296
  %2 = const_int i64 7
  %3 = gc_alloc size=24 ptrs=[] (decimal, i64)
  field_set %3[0] = %0
  field_set %3[8] = %1
  field_set %3[16] = %2
  ret %3
}

func main() void {
bb0():
  %0 = const_int i64 35
  %1 = const_int i64 4294967296
  %2 = const_int i64 7
  %3 = rt_call string_from_decimal(%0, %1) string
  %4 = const_string " "
  %5 = rt_call string_from_int(%2) string
  %6 = const_string ""
  %7 = rt_call string_concat5(%3, %4, %5, %6, %6) string
  %8 = call @m0$println(%7) void
  ret
}'

  sig5429p=$(explainMismatch "$oracle_5429_post" "$bit2_5429_post" iropt)
  rc5429p=$?
  if [ "$rc5429p" -ne 0 ] || [ "$sig5429p" != "5429-decimal-boxed-slot-explode" ]; then
    echo "FAIL: a real #5429 post-opt delta was not explained (rc=$rc5429p sig='$sig5429p')"
    fail=1
  fi

  # The SAME text scored under the OTHER kind must be REJECTED -- the two
  # kinds are different identities, not one loosened check (same cross-kind
  # pin #3898/#3862 already make).
  sig5429x=$(explainMismatch "$oracle_5429_post" "$bit2_5429_post" ir)
  rc5429x=$?
  if [ "$rc5429x" -eq 0 ] || [ -n "$sig5429x" ]; then
    echo "FAIL: a post-opt-shaped #5429 delta was wrongly explained as pre-opt (rc=$rc5429x sig='$sig5429x')"
    fail=1
  fi

  # REJECTION: an ODD remainder after removing the gc_alloc share from
  # field_get is not this shape at all -- Nw would be a fraction. Minimal
  # instance: one read site (Nr=1, contributing gc_alloc+1, field_get+1) with
  # one EXTRA, unaccounted field_get bolted on.
  bit2_5429_odd="$bit2_5429_pre
%15 = field_get %0[0] i64"

  sig5429o=$(explainMismatch "$oracle_5429_pre" "$bit2_5429_odd" ir)
  rc5429o=$?
  if [ "$rc5429o" -eq 0 ] || [ -n "$sig5429o" ]; then
    echo "FAIL: a #5429 delta with an odd field_get remainder was wrongly explained (rc=$rc5429o sig='$sig5429o')"
    fail=1
  fi

  # REJECTION: post-opt with field_get and gc_alloc moving by DIFFERENT
  # amounts -- the lockstep-fold identity does not hold, so this is not a
  # #5429 shape even though both declared opcodes moved.
  bit2_5429_uneven="$bit2_5429_post
%9 = gc_alloc size=16 ptrs=[] (i64, i64)"

  sig5429u=$(explainMismatch "$oracle_5429_post" "$bit2_5429_uneven" iropt)
  rc5429u=$?
  if [ "$rc5429u" -eq 0 ] || [ -n "$sig5429u" ]; then
    echo "FAIL: a #5429 post-opt delta with mismatched field_get/gc_alloc was wrongly explained (rc=$rc5429u sig='$sig5429u')"
    fail=1
  fi

  # THE MUTATION SHAPE (the ticket's own acceptance bar, unit-tested here too):
  # a second, unrelated opcode change landing ALONGSIDE an otherwise-genuine
  # #5429 delta must still fail -- a signature is an identity the WHOLE delta
  # must satisfy, not a file allowed to differ elsewhere once it has one
  # explained divergence on record.
  bit2_5429_plus="$bit2_5429_pre
%15 = call @somethingElse()"

  sig5429m=$(explainMismatch "$oracle_5429_pre" "$bit2_5429_plus" ir)
  rc5429m=$?
  if [ "$rc5429m" -eq 0 ] || [ -n "$sig5429m" ]; then
    echo "FAIL: a #5429 delta carrying an unrelated op was wrongly explained (rc=$rc5429m sig='$sig5429m')"
    fail=1
  fi

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
  want=$(grep -oE '^ *print "[0-9]+-[a-z-]+"' "${ROOT}/scripts/selfhost-ir-signatures.sh" |
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
