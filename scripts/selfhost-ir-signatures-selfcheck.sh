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

  # A minimal N=1, Nn=0, Nf=0 instance of the #3107 identity: one inlined
  # `xs[i]` read, plain element type, no float round-trip. Every opcode named
  # in the identity appears with exactly the delta the formula requires and
  # nothing else changes.
  #
  # Both sides are real dump text (#4370), not hand-tuned to satisfy the
  # equation: `oracle_explained` is `bit-oracle --dump-ir-pre` on a `[]i64`
  # slice read (elem_size const_int + 3-operand rt_call slice_get, #3120,
  # ABI.md §9); `bit2_explained` is `bit-out/bin/bit --dump-ir-pre` on the
  # identical source, renumbered from real register ids.
  oracle_explained='%1 = const_int i64 8
%2 = rt_call slice_get(%0, %i, %1) i64'
  bit2_explained='%1 = slice_len %0
%2 = icmp_ult bool %i, %1
br %2, bb2(), bb1()
bb1():
%4 = const_string "index out of range"
%5 = rt_call panic(%4) void
unreachable
bb2():
%7 = field_get %0[0] i64
%8 = field_get %0[16] i64
%9 = add i64 %8, %i
%10 = index_get %7[%9] i64'

  sig=$(explainMismatch "$oracle_explained" "$bit2_explained" ir)
  rc=$?
  if [ "$rc" -ne 0 ] || [ "$sig" != "3107-slice-read-inline" ]; then
    echo "FAIL: a #3107-shaped delta was not explained (rc=$rc sig='$sig')"
    fail=1
  fi

  # The #3108 half: one inlined `xs[i] = v` STORE, no reads. Ng = 0, Ns = 1,
  # Nn = 0. Same prologue as the read (the two share `emitInlineSliceElem`),
  # ending in `index_set` instead of `index_get` — and `index_set` is a void op,
  # so this also pins the recognizer line that makes it visible at all.
  #
  # `oracle_store` is real dump text (#4370): `bit-oracle --dump-ir-pre` on a
  # narrow-element `xs[i] = v` store, which never inlines (`canInlineSliceStore`
  # requires an 8-byte element) and so still shows the un-narrowed
  # `elem_size`-carrying call on BOTH oracle and branch — the exact operand
  # shape an 8-byte store's call took before #3108 inlined it, which is the
  # transform this fixture models. `bit2_store` is `--dump-ir-pre` on an
  # actual `[]i64` store, renumbered from real register ids.
  oracle_store='%1 = const_int i64 8
%2 = rt_call slice_set(%0, %i, %v, %1) void'
  bit2_store='%1 = slice_len %0
%2 = icmp_ult bool %i, %1
br %2, bb2(), bb1()
bb1():
%4 = const_string "index out of range"
%5 = rt_call panic(%4) void
unreachable
bb2():
%7 = field_get %0[0] i64
%8 = field_get %0[16] i64
%9 = add i64 %8, %i
index_set %7[%9] = %v'

  sigs=$(explainMismatch "$oracle_store" "$bit2_store" ir)
  rcs=$?
  if [ "$rcs" -ne 0 ] || [ "$sigs" != "3108-slice-store-inline" ]; then
    echo "FAIL: a #3108-shaped delta was not explained (rc=$rcs sig='$sigs')"
    fail=1
  fi

  # A store delta whose `index_set` did NOT appear must be REJECTED: that is the
  # shape of a store that lost its write, and before the recognizer line above
  # it scored identically to a correct one.
  bit2_store_lost=$(printf '%s\n' "$bit2_store" | grep -v '^index_set ')
  sigl=$(explainMismatch "$oracle_store" "$bit2_store_lost" ir)
  rcl=$?
  if [ "$rcl" -eq 0 ] || [ -n "$sigl" ]; then
    echo "FAIL: a store with no index_set was wrongly explained (rc=$rcl sig='$sigl')"
    fail=1
  fi

  # An unrelated single-opcode delta (the #3125 mutation-test shape: a binop
  # flipped from sub to add) must NOT be explained — there is no slice_get
  # delta at all, so N is never positive.
  oracle_unrelated='%1 = sub %2, %3'
  bit2_unrelated='%1 = sub %2, %3
%4 = sub %5, %6'

  sig2=$(explainMismatch "$oracle_unrelated" "$bit2_unrelated" ir)
  rc2=$?
  if [ "$rc2" -eq 0 ] || [ -n "$sig2" ]; then
    echo "FAIL: an unrelated opcode delta was wrongly explained (rc=$rc2 sig='$sig2')"
    fail=1
  fi

  # --- #3898: the pointer-scale / right-shift cancellation, both kinds ---
  #
  # Pre-opt, Nm = 1: the `const_int 8` + `mul` pair becomes `const_int -8` +
  # `band`, and the dead `ashr`/`const_int 3` are still emitted, so `ashr` and
  # `const_int` must NOT move.
  oracle_ptr='%1 = const_int i64 3
%2 = ashr i64 %0, %1
%3 = const_int i64 8
%4 = mul i64 %2, %3
%5 = convert i64 %4'
  bit2_ptr='%1 = const_int i64 3
%2 = ashr i64 %0, %1
%3 = const_int i64 -8
%4 = band i64 %0, %3
%5 = convert i64 %4'

  sigp=$(explainMismatch "$oracle_ptr" "$bit2_ptr" ir)
  rcp=$?
  if [ "$rcp" -ne 0 ] || [ "$sigp" != "3898-ptr-scale-shift-fold" ]; then
    echo "FAIL: a #3898-shaped pre-opt delta was not explained (rc=$rcp sig='$sigp')"
    fail=1
  fi

  # Post-opt, Nm = 1: DCE has removed the dead shift and its count constant, so
  # `ashr` and `const_int` each fall by exactly Nm. The SAME text scored as
  # `ir` must be REJECTED there and vice versa — the two kinds are different
  # identities, not one loosened check.
  bit2_ptr_opt='%3 = const_int i64 -8
%4 = band i64 %0, %3
%5 = convert i64 %4'

  sigq=$(explainMismatch "$oracle_ptr" "$bit2_ptr_opt" iropt)
  rcq=$?
  if [ "$rcq" -ne 0 ] || [ "$sigq" != "3898-ptr-scale-shift-fold" ]; then
    echo "FAIL: a #3898-shaped post-opt delta was not explained (rc=$rcq sig='$sigq')"
    fail=1
  fi

  sigr=$(explainMismatch "$oracle_ptr" "$bit2_ptr_opt" ir)
  rcr=$?
  if [ "$rcr" -eq 0 ] || [ -n "$sigr" ]; then
    echo "FAIL: a post-opt-shaped delta was wrongly explained as pre-opt (rc=$rcr sig='$sigr')"
    fail=1
  fi

  # THE MASK IS THE WHOLE CORRECTNESS ARGUMENT, so a fold that DROPPED it — the
  # tempting `(e >> k) * 2^k == e` non-identity, which truncates for a
  # misaligned `e` — must NOT be explained. It removes the mul and its constant
  # and adds no band at all.
  bit2_ptr_nomask='%1 = const_int i64 3
%2 = ashr i64 %0, %1
%5 = convert i64 %0'

  sigs2=$(explainMismatch "$oracle_ptr" "$bit2_ptr_nomask" ir)
  rcs2=$?
  if [ "$rcs2" -eq 0 ] || [ -n "$sigs2" ]; then
    echo "FAIL: a mask-dropping fold was wrongly explained (rc=$rcs2 sig='$sigs2')"
    fail=1
  fi

  # A second, unrelated opcode moving alongside a real #3898 delta must still
  # fail: a signature names an identity the WHOLE delta must satisfy, not a
  # file that is allowed to differ.
  bit2_ptr_plus="$bit2_ptr
%6 = call @somethingElse()"

  sigt=$(explainMismatch "$oracle_ptr" "$bit2_ptr_plus" ir)
  rct=$?
  if [ "$rct" -eq 0 ] || [ -n "$sigt" ]; then
    echo "FAIL: a #3898 delta carrying an unrelated op was wrongly explained (rc=$rct sig='$sigt')"
    fail=1
  fi

  # --- #3862: inline slice elements, both dump kinds (#3907) ---
  #
  # Minimal Ng=1 instance (a for-of-style whole-element READ inlined): one
  # `rt_call slice_get` replaced by a bounds check + address computation.
  oracle_si_read='%1 = const_int i64 8
%2 = rt_call slice_get(%0, %i, %1) T
%3 = field_get %2[0] i64'
  bit2_si_read='%1 = slice_len %0
%2 = icmp_ult bool %i, %1
br %2, bb1, bb2
%3 = const_string "index out of range"
%4 = rt_call panic(%3) void
unreachable
%5 = field_get %0[0] i64
%6 = field_get %0[16] i64
%7 = add i64 %6, %i
%8 = const_int i64 16
%9 = mul i64 %7, %8
%10 = add i64 %5, %9
%11 = field_get %10[0] i64'

  sigsi=$(explainMismatch "$oracle_si_read" "$bit2_si_read" ir)
  rcsi=$?
  if [ "$rcsi" -ne 0 ] || [ "$sigsi" != "3862-slice-inline-elements" ]; then
    echo "FAIL: a #3862-shaped Ng read delta was not explained (rc=$rcsi sig='$sigsi')"
    fail=1
  fi

  # Minimal Na=1 instance (an `append` growth reindexed via `slice_len - 1`),
  # pinning the `sub`-derived Na and its 3-per-site const_int contribution
  # (stride, the null value-pointer arg, and the literal `1`).
  oracle_si_append='%1 = const_int i64 1
%2 = const_int i64 8
%3 = gc_alloc size=16 ptrs=[] T
%4 = const_int i64 42
field_set %3[0] = %4
%6 = rt_call slice_append(%0, %3, %1, %2) []T'
  bit2_si_append='%1 = const_int i64 0
%2 = const_int i64 16
%3 = const_int i64 0
%4 = rt_call slice_append(%0, %3, %1, %2) []T
%5 = slice_len %4
%6 = const_int i64 1
%7 = sub i64 %5, %6
%8 = slice_len %4
%9 = icmp_ult bool %7, %8
br %9, bb1, bb2
%11 = const_string "index out of range"
%12 = rt_call panic(%11) void
unreachable
%14 = field_get %4[0] i64
%15 = field_get %4[16] i64
%16 = add i64 %15, %7
%17 = const_int i64 16
%18 = mul i64 %16, %17
%19 = add i64 %14, %18
%20 = const_int i64 42
field_set %19[0] = %20'

  sigsa=$(explainMismatch "$oracle_si_append" "$bit2_si_append" ir)
  rcsa=$?
  if [ "$rcsa" -ne 0 ] || [ "$sigsa" != "3862-slice-inline-elements" ]; then
    echo "FAIL: a #3862-shaped Na append delta was not explained (rc=$rcsa sig='$sigsa')"
    fail=1
  fi

  # Post-opt: DCE folds one `add x, 0` identity (observed on real corpus
  # files whose written index is a literal 0), so `add` must be accepted
  # with ONE FEWER occurrence than the pre-opt identity requires — but ONLY
  # under `iropt`. The same text scored as `ir` must be REJECTED, exactly
  # the cross-kind check #3898's post-opt arm already makes.
  bit2_si_read_opt='%1 = slice_len %0
%2 = icmp_ult bool %i, %1
br %2, bb1, bb2
%3 = const_string "index out of range"
%4 = rt_call panic(%3) void
unreachable
%5 = field_get %0[0] i64
%6 = field_get %0[16] i64
%8 = const_int i64 16
%9 = mul i64 %6, %8
%10 = add i64 %5, %9
%11 = field_get %10[0] i64'

  sigso=$(explainMismatch "$oracle_si_read" "$bit2_si_read_opt" iropt)
  rcso=$?
  if [ "$rcso" -ne 0 ] || [ "$sigso" != "3862-slice-inline-elements" ]; then
    echo "FAIL: a #3862-shaped post-opt (add-folded) delta was not explained (rc=$rcso sig='$sigso')"
    fail=1
  fi

  sigso2=$(explainMismatch "$oracle_si_read" "$bit2_si_read_opt" ir)
  rcso2=$?
  if [ "$rcso2" -eq 0 ] || [ -n "$sigso2" ]; then
    echo "FAIL: a post-opt-folded #3862 delta was wrongly explained as pre-opt (rc=$rcso2 sig='$sigso2')"
    fail=1
  fi

  # REJECTION 1: the bounds check dropped (the safety-relevant fold this
  # signature exists to refuse to paper over) — same read, minus the
  # const_string/panic/unreachable trio. `unreachable`'s delta then reads 0
  # against a required B=1, so this must NOT be explained on either kind.
  bit2_si_read_nocheck='%1 = slice_len %0
%2 = icmp_ult bool %i, %1
br %2, bb1, bb2
%5 = field_get %0[0] i64
%6 = field_get %0[16] i64
%7 = add i64 %6, %i
%8 = const_int i64 16
%9 = mul i64 %7, %8
%10 = add i64 %5, %9
%11 = field_get %10[0] i64'

  sigrc=$(explainMismatch "$oracle_si_read" "$bit2_si_read_nocheck" ir)
  rcrc=$?
  if [ "$rcrc" -eq 0 ] || [ -n "$sigrc" ]; then
    echo "FAIL: a #3862 delta with its bounds check dropped was wrongly explained (rc=$rcrc sig='$sigrc')"
    fail=1
  fi

  # REJECTION 2: an unrelated opcode moving alongside an otherwise-valid
  # #3862 delta must still fail — a signature is an identity the WHOLE delta
  # must satisfy, not a file allowed to differ elsewhere (same shape as the
  # #3898 rejection above).
  bit2_si_read_plus="$bit2_si_read
%12 = call @somethingElse()"

  sigrd=$(explainMismatch "$oracle_si_read" "$bit2_si_read_plus" ir)
  rcrd=$?
  if [ "$rcrd" -eq 0 ] || [ -n "$sigrd" ]; then
    echo "FAIL: a #3862 delta carrying an unrelated op was wrongly explained (rc=$rcrd sig='$sigrd')"
    fail=1
  fi

  # REJECTION 3: an extra, unaccounted field_get — the shape of a fold that
  # reads one field too many. field_get must be exactly 2*B; a third read
  # breaks the count even though field_get is already a declared opcode.
  bit2_si_read_extraread="$bit2_si_read
%12 = field_get %10[8] i64"

  sigre=$(explainMismatch "$oracle_si_read" "$bit2_si_read_extraread" ir)
  rcre=$?
  if [ "$rcre" -eq 0 ] || [ -n "$sigre" ]; then
    echo "FAIL: a #3862 delta with a spurious extra field_get was wrongly explained (rc=$rcre sig='$sigre')"
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

  if [ "$fail" -eq 0 ]; then
    echo "selfhost-ir-signatures-selfcheck.sh: self-check passed"
  fi
  exit "$fail"
fi
