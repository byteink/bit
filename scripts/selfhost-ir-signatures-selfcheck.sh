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
  # scripts/selfhost-ir-signatures.sh's header). #5486-variant-payload-reorder,
  # #5429-decimal-boxed-slot-explode, #5506-enum-nil-payload-retype,
  # #5445-method-return-explode-direct-call, #5521-void-return-bare-ret and
  # #5486-variant-payload-redundant-read-elim were RETIRED by the stage0
  # 0.20.0 repin (#5607) the same way. Their shaped-delta fixtures lived in
  # this self-check; removed with the arms they tested rather than kept as
  # tests for identities that no longer exist. Git history at this file's
  # state before #5607 has them.

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

  # --- #5871: sub-word tuple explosion, both `ir`/`iropt` kinds ---
  #
  # Real dump text from `_tests_/cases/recover_boundary.bit` (this tree at
  # cd7e781c2 vs the pinned stage0): `call @m1$runRecovering` used to return
  # a boxed `(bool, string)`, now returns `bool` plus a `call_word`-read
  # second word.
  oracle_tuple_pre='%5 = call @m1$runRecovering(%4) (bool, string)
%6 = field_get %5[0] bool
%7 = field_get %5[8] string'
  bit2_tuple_pre='%5 = call @m1$runRecovering(%4) bool
%6 = call_word %5[1] string
%7 = gc_alloc size=16 ptrs=[%8] (bool, string)
field_set %7[0] = %5
field_set %7[8] = %6
%10 = field_get %7[0] bool
%11 = field_get %7[8] string'

  sigt1=$(explainMismatch "$oracle_tuple_pre" "$bit2_tuple_pre" ir)
  rct1=$?
  if [ "$rct1" -ne 0 ] || [ "$sigt1" != "5871-tuple-word-explode" ]; then
    echo "FAIL: the real #5871 pre-opt tuple-explode delta was not explained (rc=$rct1 sig='$sigt1')"
    fail=1
  fi

  # Same call site, post-opt: opt.bit forwards the freshly-built box away
  # (dead on arrival), so `field_get`/`gc_alloc` only ever fall now.
  oracle_tuple_opt="$oracle_tuple_pre"
  bit2_tuple_opt='%5 = call @m1$runRecovering(%4) bool
%6 = call_word %5[1] string'

  sigt2=$(explainMismatch "$oracle_tuple_opt" "$bit2_tuple_opt" iropt)
  rct2=$?
  if [ "$rct2" -ne 0 ] || [ "$sigt2" != "5871-tuple-word-explode" ]; then
    echo "FAIL: the real #5871 post-opt tuple-explode delta was not explained (rc=$rct2 sig='$sigt2')"
    fail=1
  fi

  # REJECTION: an unrelated opcode riding along an otherwise-genuine #5871
  # pre-opt delta must still fail -- the identity is the WHOLE delta, not a
  # per-opcode allowlist.
  bit2_tuple_pre_plus="$bit2_tuple_pre
%99 = xor i64 %5, %6"
  sigt3=$(explainMismatch "$oracle_tuple_pre" "$bit2_tuple_pre_plus" ir)
  rct3=$?
  if [ "$rct3" -eq 0 ] || [ -n "$sigt3" ]; then
    echo "FAIL: a #5871 pre-opt delta carrying an unrelated opcode was wrongly explained (rc=$rct3 sig='$sigt3')"
    fail=1
  fi

  # --- #5871, POST-OPT ONLY: branch fold enabled by the box going away ---
  #
  # Real dump text from `_tests_/cases/run_tuple_subword.bit`'s `main()`
  # (this tree at cd7e781c2 vs the pinned stage0): `biDirect(true, 10)` and
  # `biDirect(false, 10)` each fold their `br` on the now-literal bool member
  # away, discarding the opposite arm of the `p.1 + 1` / `p.1 - 1` pair.
  oracle_fold='%81 = const_string "biDirect="
%82 = const_bool true
%83 = const_int i64 10
%84 = gc_alloc size=16 ptrs=[] (bool, i64)
field_set %84[0] = %82
field_set %84[8] = %83
br %82, bb1(), bb2(%82, %83, %84)
bb1():
%88 = field_get %84[8] i64
%89 = const_int i64 1
%90 = add i64 %88, %89
jump bb3(%90)
bb2(%92: bool, %93: i64, %94: (bool, i64)):
%95 = field_get %94[8] i64
%96 = const_int i64 1
%97 = sub i64 %95, %96
jump bb3(%97)
bb3(%99: i64):
%100 = rt_call string_from_int(%99) string
%101 = const_string ","
%102 = const_bool false
%103 = gc_alloc size=16 ptrs=[] (bool, i64)
field_set %103[0] = %102
field_set %103[8] = %83
br %102, bb4(), bb5(%102, %83, %103)
bb4():
%107 = field_get %103[8] i64
%108 = const_int i64 1
%109 = add i64 %107, %108
jump bb6(%109)
bb5(%111: bool, %112: i64, %113: (bool, i64)):
%114 = field_get %113[8] i64
%115 = const_int i64 1
%116 = sub i64 %114, %115
jump bb6(%116)
bb6(%118: i64):
%119 = rt_call string_from_int(%118) string'
  bit2_fold='%81 = const_string "biDirect="
%82 = const_bool true
%83 = const_int i64 10
jump bb1()
bb1():
%85 = const_int i64 11
jump bb2(%85)
bb2(%87: i64):
%88 = rt_call string_from_int(%87) string
%89 = const_string ","
%90 = const_bool false
jump bb3(%90, %83, %90, %83)
bb3(%92: bool, %93: i64, %94: bool, %95: i64):
%96 = const_int i64 9
jump bb4(%96)
bb4(%98: i64):
%99 = rt_call string_from_int(%98) string'

  sigt4=$(explainMismatch "$oracle_fold" "$bit2_fold" iropt)
  rct4=$?
  if [ "$rct4" -ne 0 ] || [ "$sigt4" != "5871-tuple-word-explode-branch-fold" ]; then
    echo "FAIL: the real #5871 branch-fold delta was not explained (rc=$rct4 sig='$sigt4')"
    fail=1
  fi

  # REJECTION: the identical two texts scored under `ir` (the wrong kind) --
  # the branch-fold arm is gated `kind != "ir"` and the plain tuple-explode
  # arm above requires field_get/gc_alloc to RISE at pre-opt, not fall.
  sigt5=$(explainMismatch "$oracle_fold" "$bit2_fold" ir)
  rct5=$?
  if [ "$rct5" -eq 0 ] || [ -n "$sigt5" ]; then
    echo "FAIL: a #5871 branch-fold delta was wrongly explained under kind=ir (rc=$rct5 sig='$sigt5')"
    fail=1
  fi

  # REJECTION: #3125's canonical mutation shape (`Op.Sub` -> `Op.Add` in
  # `compiler/lower.bit` binOpFor) applied to ONE site of this exact real
  # delta -- an extra `sub` disappearing from the oracle side that bit2's
  # `add` count does not match breaks the add==sub lockstep this signature
  # anchors on, even though every opcode is still inside the closed set and
  # gc_alloc/field_get/br still all fall.
  oracle_fold_asym="$oracle_fold
%999 = sub i64 %1, %2"
  sigt6=$(explainMismatch "$oracle_fold_asym" "$bit2_fold" iropt)
  rct6=$?
  if [ "$rct6" -eq 0 ] || [ -n "$sigt6" ]; then
    echo "FAIL: a #5871 branch-fold delta with an asymmetric add/sub mutation was wrongly explained (rc=$rct6 sig='$sigt6')"
    fail=1
  fi

  # REJECTION: an unrelated opcode riding along an otherwise-genuine
  # branch-fold delta must still fail -- same closed-set requirement as the
  # plain tuple-explode arm above.
  bit2_fold_plus="$bit2_fold
%999 = xor i64 %1, %2"
  sigt7=$(explainMismatch "$oracle_fold" "$bit2_fold_plus" iropt)
  rct7=$?
  if [ "$rct7" -eq 0 ] || [ -n "$sigt7" ]; then
    echo "FAIL: a #5871 branch-fold delta carrying an unrelated opcode was wrongly explained (rc=$rct7 sig='$sigt7')"
    fail=1
  fi

  # --- #5474: catch composite-default disambiguation, ast + fmt kinds (#5510) ---
  #
  # Real dump/format text (#5510), from `_tests_/cases/catch_composite_default_single_field.bit`:
  # `bit-oracle --dump-ast` (pre-#5474 parse) vs `bit-out/bin/bit --dump-ast`
  # (post-#5474 parse) on the identical source.
  oracle_catch_ast='(program (struct_decl Circle _ (field_list (field r int _ _))) (func_decl _ f _ (params) (fallible Circle _) (block (fail_stmt (call newError _ (args (arg "boom")))))) (func_decl _ main _ (params) _ (block (let_decl (binding x _ (catch_bind (call f _ (args)) Circle (block (assign = (lhs_list r) (expr_list 1)))))) (expr_stmt (call println _ (args (arg (str_interp "r=" (member x r) ""))))))))'
  bit2_catch_ast='(program (struct_decl Circle _ (field_list (field r int _ _))) (func_decl _ f _ (params) (fallible Circle _) (block (fail_stmt (call newError _ (args (arg "boom")))))) (func_decl _ main _ (params) _ (block (let_decl (binding x _ (catch_default (call f _ (args)) (composite_lit Circle (field_inits (field_init r 1)))))) (expr_stmt (call println _ (args (arg (str_interp "r=" (member x r) ""))))))))'

  sigca=$(explainMismatch "$oracle_catch_ast" "$bit2_catch_ast" ast)
  rcca=$?
  if [ "$rcca" -ne 0 ] || [ "$sigca" != "5474-catch-composite-default-ast" ]; then
    echo "FAIL: the real #5474 ast delta was not explained (rc=$rcca sig='$sigca')"
    fail=1
  fi

  # REJECTION: the identical two texts scored under `ir` (the wrong kind)
  # must not be explained -- catchDisambigAst only ever runs when kind=="ast".
  sigcak=$(explainMismatch "$oracle_catch_ast" "$bit2_catch_ast" ir)
  rccak=$?
  if [ "$rccak" -eq 0 ] || [ -n "$sigcak" ]; then
    echo "FAIL: a #5474 ast delta was wrongly explained under kind=ir (rc=$rccak sig='$sigcak')"
    fail=1
  fi

  # REJECTION: an unrelated ast divergence (no catch_bind at all) must not
  # be explained by coincidence.
  sigcau=$(explainMismatch '(program (call foo))' '(program (call bar))' ast)
  rccau=$?
  if [ "$rccau" -eq 0 ] || [ -n "$sigcau" ]; then
    echo "FAIL: an unrelated ast delta was wrongly explained (rc=$rccau sig='$sigcau')"
    fail=1
  fi

  # REJECTION: a field value containing a paren is not this shape (the
  # identity is for a single SCALAR field_init, nothing deeper).
  bit2_catch_ast_paren='(program (let_decl (binding x _ (catch_default (call f _ (args)) (composite_lit Circle (field_inits (field_init r (call g _ (args)))))))))'
  oracle_catch_ast_paren='(program (let_decl (binding x _ (catch_bind (call f _ (args)) Circle (block (assign = (lhs_list r) (expr_list (call g _ (args))))))))))'
  sigcap=$(explainMismatch "$oracle_catch_ast_paren" "$bit2_catch_ast_paren" ast)
  rccap=$?
  if [ "$rccap" -eq 0 ] || [ -n "$sigcap" ]; then
    echo "FAIL: a #5474 ast delta with a non-scalar field value was wrongly explained (rc=$rccap sig='$sigcap')"
    fail=1
  fi

  # The fmt arm, real formatted-file text (#5510) from the same fixture:
  # `bit-oracle fmt` (multi-line bind-block rendering) vs `bit-out/bin/bit fmt`
  # (single-line composite-default rendering, `=` separator).
  oracle_catch_fmt='// run
class Circle {
  r: int
}
fn f(): Circle! { fail newError("boom") }

fn main() {
  let x = f() catch Circle {
    r = 1
  }
  println("r=${x.r}")
}'
  bit2_catch_fmt='// run
class Circle {
  r: int
}
fn f(): Circle! { fail newError("boom") }

fn main() {
  let x = f() catch Circle{ r = 1 }
  println("r=${x.r}")
}'

  sigcf=$(explainMismatch "$oracle_catch_fmt" "$bit2_catch_fmt" fmt)
  rccf=$?
  if [ "$rccf" -ne 0 ] || [ "$sigcf" != "5474-catch-composite-default-fmt" ]; then
    echo "FAIL: the real #5474 fmt delta was not explained (rc=$rccf sig='$sigcf')"
    fail=1
  fi

  # REJECTION: an unrelated line changed elsewhere in the file, alongside an
  # otherwise-genuine #5474 fmt delta, must still fail -- a signature is an
  # identity the WHOLE delta must satisfy.
  bit2_catch_fmt_plus='// run
class Circle {
  r: int
}
fn f(): Circle! { fail newError("boom") }

fn main() {
  let x = f() catch Circle{ r = 1 }
  println("changed")
}'
  sigcfp=$(explainMismatch "$oracle_catch_fmt" "$bit2_catch_fmt_plus" fmt)
  rccfp=$?
  if [ "$rccfp" -eq 0 ] || [ -n "$sigcfp" ]; then
    echo "FAIL: a #5474 fmt delta carrying an unrelated line change was wrongly explained (rc=$rccfp sig='$sigcfp')"
    fail=1
  fi

  # REJECTION: the identical two texts scored under `ast` (the wrong kind)
  # must not be explained -- catchDisambigFmt only ever runs when kind=="fmt".
  sigcfk=$(explainMismatch "$oracle_catch_fmt" "$bit2_catch_fmt" ast)
  rccfk=$?
  if [ "$rccfk" -eq 0 ] || [ -n "$sigcfk" ]; then
    echo "FAIL: a #5474 fmt delta was wrongly explained under kind=ast (rc=$rccfk sig='$sigcfk')"
    fail=1
  fi

  # --- #5876: field store converted to its own declared type ---
  #
  # Real post-opt dump text from `_tests_/cases/run_tuple_narrow_boxed_convert.bit`
  # (this tree vs the pinned stage0): `int(s[i])` keeps its `convert`
  # (`fieldSetRhsTarget`, compiler/optfold.bit, declines the widening-alias
  # fold that used to erase it) instead of the store reading the narrower
  # `index_get` straight through.
  oracle_fsc_opt='bb2():
  %9 = index_get %0[%3] u8
  br %4, bb4(), bb3()
bb6():
  %21 = index_get %0[%3] u8
  %22 = const_int u8 127
  %23 = icmp_ugt bool %21, %22
  %24 = gc_alloc size=16 ptrs=[] (i64, i32, bool)
  field_set %24[0] = %9'
  bit2_fsc_opt='bb2():
  %9 = index_get %0[%3] u8
  %10 = convert i64 %9
  br %4, bb4(), bb3()
bb6():
  %22 = index_get %0[%3] u8
  %23 = const_int u8 127
  %24 = icmp_ugt bool %22, %23
  %25 = gc_alloc size=16 ptrs=[] (i64, i32, bool)
  field_set %25[0] = %10'

  sigf1=$(explainMismatch "$oracle_fsc_opt" "$bit2_fsc_opt" iropt)
  rcf1=$?
  if [ "$rcf1" -ne 0 ] || [ "$sigf1" != "5876-field-store-declared-type-convert" ]; then
    echo "FAIL: the real #5876 post-opt field-store-convert delta was not explained (rc=$rcf1 sig='$sigf1')"
    fail=1
  fi

  # Real pre-opt dump text from `_tests_/cases/untyped_const_expr_narrow.bit`:
  # `S{ f = 1 + 1 }` stores a compile-time-known `i64` into a `u8` field, so
  # `fieldStoreValue` (compiler/lowertuple.bit) inserts an explicit `convert`
  # at lowering time -- present even before any optimization pass runs.
  oracle_fsc_pre='%26 = const_int i64 2
field_set %24[0] = %26'
  bit2_fsc_pre='%27 = const_int i64 2
%28 = convert u8 %27
field_set %24[0] = %28'

  sigf2=$(explainMismatch "$oracle_fsc_pre" "$bit2_fsc_pre" ir)
  rcf2=$?
  if [ "$rcf2" -ne 0 ] || [ "$sigf2" != "5876-field-store-declared-type-convert" ]; then
    echo "FAIL: the real #5876 pre-opt field-store-convert delta was not explained (rc=$rcf2 sig='$sigf2')"
    fail=1
  fi

  # ACCEPT: the same field-store convert PLUS a sibling store now also being
  # forwarded, dropping a `field_get` -- the real `convert_widen_alias.bit`
  # shape (`r.wide2 = int(hs[1])`), where `field_get` only ever falls or
  # holds, never rises.
  oracle_fsc_fwd='field_set %0[16] = %5
%15 = field_get %2[0] i64
%24 = field_get %0[16] i64'
  bit2_fsc_fwd='%6 = convert i64 %5
field_set %0[16] = %6
%16 = field_get %2[0] i64'

  sigf3=$(explainMismatch "$oracle_fsc_fwd" "$bit2_fsc_fwd" iropt)
  rcf3=$?
  if [ "$rcf3" -ne 0 ] || [ "$sigf3" != "5876-field-store-declared-type-convert" ]; then
    echo "FAIL: the real #5876 forwarded-sibling-store delta was not explained (rc=$rcf3 sig='$sigf3')"
    fail=1
  fi

  # REJECTION: the identical field-store-convert delta with a `field_get`
  # that RISES instead of falling -- a shape this signature never allows,
  # since #5876's own fix only ever lets a read get forwarded away, never
  # adds a new one.
  bit2_fsc_bad_get="$bit2_fsc_opt
%50 = field_get %24[0] i64"
  sigf4=$(explainMismatch "$oracle_fsc_opt" "$bit2_fsc_bad_get" iropt)
  rcf4=$?
  if [ "$rcf4" -eq 0 ] || [ -n "$sigf4" ]; then
    echo "FAIL: a #5876 delta with a field_get that rises was wrongly explained (rc=$rcf4 sig='$sigf4')"
    fail=1
  fi

  # REJECTION: an unrelated opcode riding along an otherwise-genuine #5876
  # delta must still fail -- same closed-set requirement as every other
  # signature in this file.
  bit2_fsc_plus="$bit2_fsc_opt
%99 = xor i64 %9, %10"
  sigf5=$(explainMismatch "$oracle_fsc_opt" "$bit2_fsc_plus" iropt)
  rcf5=$?
  if [ "$rcf5" -eq 0 ] || [ -n "$sigf5" ]; then
    echo "FAIL: a #5876 delta carrying an unrelated opcode was wrongly explained (rc=$rcf5 sig='$sigf5')"
    fail=1
  fi

  # --- #5874: a fallible tuple `(A, B)!` returns its ok value in words ---
  #
  # Real pre-opt dump text from `_tests_/cases/run_tuple_fallible_words.bit`
  # (`two`, this tree vs the pinned stage0): the err path returns one zero
  # word per member where it returned one `const_nil`, and the ok path reads
  # its words out of the box before the `err_set` clear.
  oracle_fw_pre='bb1():
  %4 = gc_alloc size=8 ptrs=[] Neg
  field_set %4[0] = %0
  %6 = rt_call err_set(%4) void
  %7 = const_nil
  ret %7
bb2(%9: i64):
  %15 = gc_alloc size=16 ptrs=[%8] (i64, string)
  field_set %15[0] = %11
  field_set %15[8] = %14
  %18 = const_nil
  %19 = rt_call err_set(%18) void
  ret %15'
  bit2_fw_pre='bb1():
  %4 = gc_alloc size=8 ptrs=[] Neg
  field_set %4[0] = %0
  %6 = rt_call err_set(%4) void
  %7 = const_int i64 0
  %8 = const_nil
  ret %7, %8
bb2(%10: i64):
  %16 = gc_alloc size=16 ptrs=[%8] (i64, string)
  field_set %16[0] = %12
  field_set %16[8] = %15
  %19 = field_get %16[0] i64
  %20 = field_get %16[8] string
  %21 = const_nil
  %22 = rt_call err_set(%21) void
  ret %19, %20'

  sigw1=$(explainMismatch "$oracle_fw_pre" "$bit2_fw_pre" ir)
  rcw1=$?
  if [ "$rcw1" -ne 0 ] || [ "$sigw1" != "5874-fallible-tuple-words" ]; then
    echo "FAIL: the real #5874 pre-opt fallible-words delta was not explained (rc=$rcw1 sig='$sigw1')"
    fail=1
  fi

  # Real post-opt dump text, same file (`three`, `(f64, bool, string)!`): the
  # box is gone and the err path carries a zero in each register class.
  oracle_fw_opt='  %6 = rt_call err_set(%4) void
  %7 = const_nil
  ret %7
bb2(%9: i64):
  %18 = gc_alloc size=24 ptrs=[%16] (f64, bool, string)
  field_set %18[0] = %12
  field_set %18[8] = %14
  field_set %18[16] = %17
  %22 = const_nil
  %23 = rt_call err_set(%22) void
  ret %18'
  bit2_fw_opt='  %6 = rt_call err_set(%4) void
  %7 = const_float f64 0
  %8 = const_bool false
  %9 = const_nil
  ret %7, %8, %9
bb2(%11: i64):
  %20 = const_nil
  %21 = rt_call err_set(%20) void
  ret %14, %16, %19'

  sigw2=$(explainMismatch "$oracle_fw_opt" "$bit2_fw_opt" iropt)
  rcw2=$?
  if [ "$rcw2" -ne 0 ] || [ "$sigw2" != "5874-fallible-tuple-words" ]; then
    echo "FAIL: the real #5874 post-opt fallible-words delta was not explained (rc=$rcw2 sig='$sigw2')"
    fail=1
  fi

  # REJECTION: an err path that LOST its ok value instead of widening it --
  # `ret` with no zero constant at all, so the constants net-fall. Pre-opt the
  # anchor is that every widened site ADDS (W - 1) constants.
  bit2_fw_lost='bb1():
  %4 = gc_alloc size=8 ptrs=[] Neg
  field_set %4[0] = %0
  %6 = rt_call err_set(%4) void
  ret
bb2(%10: i64):
  %16 = gc_alloc size=16 ptrs=[%8] (i64, string)
  field_set %16[0] = %12
  field_set %16[8] = %15
  %19 = field_get %16[0] i64
  %20 = field_get %16[8] string
  %21 = const_nil
  %22 = rt_call err_set(%21) void
  ret %19, %20'
  sigw3=$(explainMismatch "$oracle_fw_pre" "$bit2_fw_lost" ir)
  rcw3=$?
  if [ "$rcw3" -eq 0 ] || [ -n "$sigw3" ]; then
    echo "FAIL: a #5874 delta whose err path lost its ok value was wrongly explained (rc=$rcw3 sig='$sigw3')"
    fail=1
  fi

  # REJECTION: the post-opt delta with a `field_get` that RISES -- a box read
  # the optimizer failed to forward is not this transform. The `call_word`
  # run keeps `call_word - field_get - gc_alloc` positive, so only the sign
  # rule can reject it.
  bit2_fw_bad_get="$bit2_fw_opt
%41 = call_word %40[1] bool
%42 = call_word %40[2] string
%50 = field_get %18[0] f64"
  sigw4=$(explainMismatch "$oracle_fw_opt" "$bit2_fw_bad_get" iropt)
  rcw4=$?
  if [ "$rcw4" -eq 0 ] || [ -n "$sigw4" ]; then
    echo "FAIL: a #5874 post-opt delta with a field_get that rises was wrongly explained (rc=$rcw4 sig='$sigw4')"
    fail=1
  fi

  # REJECTION: an unrelated opcode riding along an otherwise-genuine #5874
  # delta must still fail -- the closed-set requirement every signature here
  # carries.
  bit2_fw_plus="$bit2_fw_pre
%99 = xor i64 %19, %20"
  sigw5=$(explainMismatch "$oracle_fw_pre" "$bit2_fw_plus" ir)
  rcw5=$?
  if [ "$rcw5" -eq 0 ] || [ -n "$sigw5" ]; then
    echo "FAIL: a #5874 delta carrying an unrelated opcode was wrongly explained (rc=$rcw5 sig='$sigw5')"
    fail=1
  fi

  # --- #5870: a `ret` over the 5-integer-word budget boxes again, composed
  # with #5874 in the one file it hits (#5883) ---
  #
  # Real pre-opt dump text (this tree at 1c87cd749 vs the pinned stage0,
  # `_tests_/cases/run_multiword_return.bit`): `eight`'s callee, its call
  # site in `main`, and `checked` (the #5874 fallible-tuple-words function
  # already covered above) -- the three regions that actually diverge in
  # this file; everything else is byte-identical and trimmed out.
  oracle_mw_pre='func eight(%0: i64) (i64, i64, i64, i64, i64, i64, i64, i64) {
bb0(%0: i64):
  %1 = const_int i64 0
  %2 = const_int i64 0
  jump bb1(%0, %1, %2)
bb1(%4: i64, %5: i64, %6: i64):
  %7 = icmp_slt bool %6, %4
  br %7, bb2(), bb3(%4, %5, %6)
bb2():
  %9 = const_int i64 1
  %10 = add i64 %5, %9
  %11 = const_int i64 1
  %12 = add i64 %6, %11
  jump bb1(%4, %10, %12)
bb3(%14: i64, %15: i64, %16: i64):
  %17 = const_int i64 1
  %18 = add i64 %15, %17
  %19 = const_int i64 2
  %20 = add i64 %15, %19
  %21 = const_int i64 3
  %22 = add i64 %15, %21
  %23 = const_int i64 4
  %24 = add i64 %15, %23
  %25 = const_int i64 5
  %26 = add i64 %15, %25
  %27 = const_int i64 6
  %28 = add i64 %15, %27
  %29 = const_int i64 7
  %30 = add i64 %15, %29
  %31 = gc_alloc size=64 ptrs=[] (i64, i64, i64, i64, i64, i64, i64, i64)
  field_set %31[0] = %15
  field_set %31[8] = %18
  field_set %31[16] = %20
  field_set %31[24] = %22
  field_set %31[32] = %24
  field_set %31[40] = %26
  field_set %31[48] = %28
  field_set %31[56] = %30
  %40 = field_get %31[0] i64
  %41 = field_get %31[8] i64
  %42 = field_get %31[16] i64
  %43 = field_get %31[24] i64
  %44 = field_get %31[32] i64
  %45 = field_get %31[40] i64
  %46 = field_get %31[48] i64
  %47 = field_get %31[56] i64
  ret %40, %41, %42, %43, %44, %45, %46, %47
}
  %68 = call @eight(%67) i64
  %69 = call_word %68[1] i64
  %70 = call_word %68[2] i64
  %71 = call_word %68[3] i64
  %72 = call_word %68[4] i64
  %73 = call_word %68[5] i64
  %74 = call_word %68[6] i64
  %75 = call_word %68[7] i64
  %76 = gc_alloc size=64 ptrs=[] (i64, i64, i64, i64, i64, i64, i64, i64)
  field_set %76[0] = %68
  field_set %76[8] = %69
  field_set %76[16] = %70
  field_set %76[24] = %71
  field_set %76[32] = %72
  field_set %76[40] = %73
  field_set %76[48] = %74
  field_set %76[56] = %75
  %85 = field_get %76[0] i64
  %86 = field_get %76[8] i64
  %87 = field_get %76[16] i64
  %88 = field_get %76[24] i64
  %89 = field_get %76[32] i64
  %90 = field_get %76[40] i64
  %91 = field_get %76[48] i64
func checked(%0: i64) (i64, i64) {
bb0(%0: i64):
  %1 = const_int i64 0
  %2 = icmp_slt bool %0, %1
  br %2, bb1(), bb2(%0)
bb1():
  %4 = const_string "negative"
  %5 = field_get %4[0] i64
  %6 = field_get %4[8] i64
  %7 = field_get %4[16] string
  %8 = call @m0$newError(%5, %6, %7) error
  %9 = rt_call err_set(%8) void
  %10 = const_nil
  ret %10
bb2(%12: i64):
  %13 = const_int i64 0
  %14 = const_int i64 0
  jump bb3(%12, %13, %14)
bb3(%16: i64, %17: i64, %18: i64):
  %19 = icmp_slt bool %18, %16
  br %19, bb4(), bb5(%16, %17, %18)
bb4():
  %21 = const_int i64 1
  %22 = add i64 %17, %21
  %23 = const_int i64 1
  %24 = add i64 %18, %23
  jump bb3(%16, %22, %24)
bb5(%26: i64, %27: i64, %28: i64):
  %29 = const_int i64 2
  %30 = mul i64 %27, %29
  %31 = gc_alloc size=16 ptrs=[] (i64, i64)
  field_set %31[0] = %27
  field_set %31[8] = %30
  %34 = const_nil
  %35 = rt_call err_set(%34) void
  ret %31
}'
  bit2_mw_pre='func eight(%0: i64) (i64, i64, i64, i64, i64, i64, i64, i64) {
bb0(%0: i64):
  %1 = const_int i64 0
  %2 = const_int i64 0
  jump bb1(%0, %1, %2)
bb1(%4: i64, %5: i64, %6: i64):
  %7 = icmp_slt bool %6, %4
  br %7, bb2(), bb3(%4, %5, %6)
bb2():
  %9 = const_int i64 1
  %10 = add i64 %5, %9
  %11 = const_int i64 1
  %12 = add i64 %6, %11
  jump bb1(%4, %10, %12)
bb3(%14: i64, %15: i64, %16: i64):
  %17 = const_int i64 1
  %18 = add i64 %15, %17
  %19 = const_int i64 2
  %20 = add i64 %15, %19
  %21 = const_int i64 3
  %22 = add i64 %15, %21
  %23 = const_int i64 4
  %24 = add i64 %15, %23
  %25 = const_int i64 5
  %26 = add i64 %15, %25
  %27 = const_int i64 6
  %28 = add i64 %15, %27
  %29 = const_int i64 7
  %30 = add i64 %15, %29
  %31 = gc_alloc size=64 ptrs=[] (i64, i64, i64, i64, i64, i64, i64, i64)
  field_set %31[0] = %15
  field_set %31[8] = %18
  field_set %31[16] = %20
  field_set %31[24] = %22
  field_set %31[32] = %24
  field_set %31[40] = %26
  field_set %31[48] = %28
  field_set %31[56] = %30
  ret %31
}
  %68 = call @eight(%67) (i64, i64, i64, i64, i64, i64, i64, i64)
  %69 = field_get %68[0] i64
  %70 = field_get %68[8] i64
  %71 = field_get %68[16] i64
  %72 = field_get %68[24] i64
  %73 = field_get %68[32] i64
  %74 = field_get %68[40] i64
  %75 = field_get %68[48] i64
func checked(%0: i64) (i64, i64) {
bb0(%0: i64):
  %1 = const_int i64 0
  %2 = icmp_slt bool %0, %1
  br %2, bb1(), bb2(%0)
bb1():
  %4 = const_string "negative"
  %5 = field_get %4[0] i64
  %6 = field_get %4[8] i64
  %7 = field_get %4[16] string
  %8 = call @m0$newError(%5, %6, %7) error
  %9 = rt_call err_set(%8) void
  %10 = const_int i64 0
  %11 = const_int i64 0
  ret %10, %11
bb2(%13: i64):
  %14 = const_int i64 0
  %15 = const_int i64 0
  jump bb3(%13, %14, %15)
bb3(%17: i64, %18: i64, %19: i64):
  %20 = icmp_slt bool %19, %17
  br %20, bb4(), bb5(%17, %18, %19)
bb4():
  %22 = const_int i64 1
  %23 = add i64 %18, %22
  %24 = const_int i64 1
  %25 = add i64 %19, %24
  jump bb3(%17, %23, %25)
bb5(%27: i64, %28: i64, %29: i64):
  %30 = const_int i64 2
  %31 = mul i64 %28, %30
  %32 = gc_alloc size=16 ptrs=[] (i64, i64)
  field_set %32[0] = %28
  field_set %32[8] = %31
  %35 = field_get %32[0] i64
  %36 = field_get %32[8] i64
  %37 = const_nil
  %38 = rt_call err_set(%37) void
  ret %35, %36
}'

  sigmw1=$(explainMismatch "$oracle_mw_pre" "$bit2_mw_pre" ir)
  rcmw1=$?
  if [ "$rcmw1" -ne 0 ] || [ "$sigmw1" != "5870-multiword-return-rebox" ]; then
    echo "FAIL: the real combined #5870+#5874 pre-opt delta was not explained (rc=$rcmw1 sig='$sigmw1')"
    fail=1
  fi

  # Same two regions, post-opt (`--dump-ir`): `eight`'s box survives (still
  # over budget), `checked`'s does not (#5874's own words already forwarded
  # it away, same as every other #5874 post-opt case above).
  oracle_mw_opt='func eight(%0: i64) (i64, i64, i64, i64, i64, i64, i64, i64) {
bb0(%0: i64):
  %1 = const_int i64 0
  jump bb1(%0, %1, %1)
bb1(%3: i64, %4: i64, %5: i64):
  %6 = icmp_slt bool %5, %3
  br %6, bb2(), bb3(%3, %4, %5)
bb2():
  %8 = const_int i64 1
  %9 = add i64 %4, %8
  %10 = add i64 %5, %8
  jump bb1(%3, %9, %10)
bb3(%12: i64, %13: i64, %14: i64):
  %15 = const_int i64 1
  %16 = add i64 %13, %15
  %17 = const_int i64 2
  %18 = add i64 %13, %17
  %19 = const_int i64 3
  %20 = add i64 %13, %19
  %21 = const_int i64 4
  %22 = add i64 %13, %21
  %23 = const_int i64 5
  %24 = add i64 %13, %23
  %25 = const_int i64 6
  %26 = add i64 %13, %25
  %27 = const_int i64 7
  %28 = add i64 %13, %27
  ret %13, %16, %18, %20, %22, %24, %26, %28
}
  %46 = call @eight(%45) i64
  %47 = call_word %46[1] i64
  %48 = call_word %46[2] i64
  %49 = call_word %46[3] i64
  %50 = call_word %46[4] i64
  %51 = call_word %46[5] i64
  %52 = call_word %46[6] i64
  %53 = call_word %46[7] i64
func checked(%0: i64) (i64, i64) {
bb0(%0: i64):
  %1 = const_int i64 0
  %2 = icmp_slt bool %0, %1
  br %2, bb1(), bb2(%0)
bb1():
  %4 = const_string "negative"
  %5 = field_get %4[0] i64
  %6 = field_get %4[8] i64
  %7 = field_get %4[16] string
  %8 = call @m0$newError(%5, %6, %7) error
  %9 = rt_call err_set(%8) void
  %10 = const_nil
  ret %10
bb2(%12: i64):
  jump bb3(%12, %1, %1)
bb3(%14: i64, %15: i64, %16: i64):
  %17 = icmp_slt bool %16, %14
  br %17, bb4(), bb5(%14, %15, %16)
bb4():
  %19 = const_int i64 1
  %20 = add i64 %15, %19
  %21 = add i64 %16, %19
  jump bb3(%14, %20, %21)
bb5(%23: i64, %24: i64, %25: i64):
  %26 = const_int i64 2
  %27 = mul i64 %24, %26
  %28 = gc_alloc size=16 ptrs=[] (i64, i64)
  field_set %28[0] = %24
  field_set %28[8] = %27
  %31 = const_nil
  %32 = rt_call err_set(%31) void
  ret %28
}'
  bit2_mw_opt='func eight(%0: i64) (i64, i64, i64, i64, i64, i64, i64, i64) {
bb0(%0: i64):
  %1 = const_int i64 0
  jump bb1(%0, %1, %1)
bb1(%3: i64, %4: i64, %5: i64):
  %6 = icmp_slt bool %5, %3
  br %6, bb2(), bb3(%3, %4, %5)
bb2():
  %8 = const_int i64 1
  %9 = add i64 %4, %8
  %10 = add i64 %5, %8
  jump bb1(%3, %9, %10)
bb3(%12: i64, %13: i64, %14: i64):
  %15 = const_int i64 1
  %16 = add i64 %13, %15
  %17 = const_int i64 2
  %18 = add i64 %13, %17
  %19 = const_int i64 3
  %20 = add i64 %13, %19
  %21 = const_int i64 4
  %22 = add i64 %13, %21
  %23 = const_int i64 5
  %24 = add i64 %13, %23
  %25 = const_int i64 6
  %26 = add i64 %13, %25
  %27 = const_int i64 7
  %28 = add i64 %13, %27
  %29 = gc_alloc size=64 ptrs=[] (i64, i64, i64, i64, i64, i64, i64, i64)
  field_set %29[0] = %13
  field_set %29[8] = %16
  field_set %29[16] = %18
  field_set %29[24] = %20
  field_set %29[32] = %22
  field_set %29[40] = %24
  field_set %29[48] = %26
  field_set %29[56] = %28
  ret %29
}
  %46 = call @eight(%45) (i64, i64, i64, i64, i64, i64, i64, i64)
  %47 = field_get %46[0] i64
  %48 = field_get %46[8] i64
func checked(%0: i64) (i64, i64) {
bb0(%0: i64):
  %1 = const_int i64 0
  %2 = icmp_slt bool %0, %1
  br %2, bb1(), bb2(%0)
bb1():
  %4 = const_string "negative"
  %5 = field_get %4[0] i64
  %6 = field_get %4[8] i64
  %7 = field_get %4[16] string
  %8 = call @m0$newError(%5, %6, %7) error
  %9 = rt_call err_set(%8) void
  ret %1, %1
bb2(%11: i64):
  jump bb3(%11, %1, %1)
bb3(%13: i64, %14: i64, %15: i64):
  %16 = icmp_slt bool %15, %13
  br %16, bb4(), bb5(%13, %14, %15)
bb4():
  %18 = const_int i64 1
  %19 = add i64 %14, %18
  %20 = add i64 %15, %18
  jump bb3(%13, %19, %20)
bb5(%22: i64, %23: i64, %24: i64):
  %25 = const_int i64 2
  %26 = mul i64 %23, %25
  %27 = const_nil
  %28 = rt_call err_set(%27) void
  ret %23, %26
}'

  sigmw2=$(explainMismatch "$oracle_mw_opt" "$bit2_mw_opt" iropt)
  rcmw2=$?
  if [ "$rcmw2" -ne 0 ] || [ "$sigmw2" != "5870-multiword-return-rebox" ]; then
    echo "FAIL: the real combined #5870+#5874 post-opt delta was not explained (rc=$rcmw2 sig='$sigmw2')"
    fail=1
  fi

  # ACCEPT, PURE (no #5874 entanglement): `eight` alone in its own file --
  # real dump text, this tree vs the pinned stage0 -- so the residual after
  # subtracting #5870's contribution is completely empty and the identity
  # explains the file on its own, the shape a future non-fallible file
  # hitting this same budget would need.
  oracle_mw_pure='func eight(%0: i64) (i64, i64, i64, i64, i64, i64, i64, i64) {
bb0(%0: i64):
  %1 = const_int i64 0
  %2 = const_int i64 0
  jump bb1(%0, %1, %2)
bb1(%4: i64, %5: i64, %6: i64):
  %7 = icmp_slt bool %6, %4
  br %7, bb2(), bb3(%4, %5, %6)
bb2():
  %9 = const_int i64 1
  %10 = add i64 %5, %9
  %11 = const_int i64 1
  %12 = add i64 %6, %11
  jump bb1(%4, %10, %12)
bb3(%14: i64, %15: i64, %16: i64):
  %17 = const_int i64 1
  %18 = add i64 %15, %17
  %19 = const_int i64 2
  %20 = add i64 %15, %19
  %21 = const_int i64 3
  %22 = add i64 %15, %21
  %23 = const_int i64 4
  %24 = add i64 %15, %23
  %25 = const_int i64 5
  %26 = add i64 %15, %25
  %27 = const_int i64 6
  %28 = add i64 %15, %27
  %29 = const_int i64 7
  %30 = add i64 %15, %29
  %31 = gc_alloc size=64 ptrs=[] (i64, i64, i64, i64, i64, i64, i64, i64)
  field_set %31[0] = %15
  field_set %31[8] = %18
  field_set %31[16] = %20
  field_set %31[24] = %22
  field_set %31[32] = %24
  field_set %31[40] = %26
  field_set %31[48] = %28
  field_set %31[56] = %30
  %40 = field_get %31[0] i64
  %41 = field_get %31[8] i64
  %42 = field_get %31[16] i64
  %43 = field_get %31[24] i64
  %44 = field_get %31[32] i64
  %45 = field_get %31[40] i64
  %46 = field_get %31[48] i64
  %47 = field_get %31[56] i64
  ret %40, %41, %42, %43, %44, %45, %46, %47
}

func main() void {
bb0():
  %0 = const_int i64 1
  %1 = call @eight(%0) i64
  %2 = call_word %1[1] i64
  %3 = call_word %1[2] i64
  %4 = call_word %1[3] i64
  %5 = call_word %1[4] i64
  %6 = call_word %1[5] i64
  %7 = call_word %1[6] i64
  %8 = call_word %1[7] i64
  %9 = gc_alloc size=64 ptrs=[] (i64, i64, i64, i64, i64, i64, i64, i64)
  field_set %9[0] = %1
  field_set %9[8] = %2
  field_set %9[16] = %3
  field_set %9[24] = %4
  field_set %9[32] = %5
  field_set %9[40] = %6
  field_set %9[48] = %7
  field_set %9[56] = %8
  %18 = field_get %9[0] i64
  %19 = field_get %9[8] i64
  %20 = field_get %9[16] i64
  %21 = field_get %9[24] i64
  %22 = field_get %9[32] i64
  %23 = field_get %9[40] i64
  %24 = field_get %9[48] i64
  %25 = field_get %9[56] i64
  ret
}'
  bit2_mw_pure='func eight(%0: i64) (i64, i64, i64, i64, i64, i64, i64, i64) {
bb0(%0: i64):
  %1 = const_int i64 0
  %2 = const_int i64 0
  jump bb1(%0, %1, %2)
bb1(%4: i64, %5: i64, %6: i64):
  %7 = icmp_slt bool %6, %4
  br %7, bb2(), bb3(%4, %5, %6)
bb2():
  %9 = const_int i64 1
  %10 = add i64 %5, %9
  %11 = const_int i64 1
  %12 = add i64 %6, %11
  jump bb1(%4, %10, %12)
bb3(%14: i64, %15: i64, %16: i64):
  %17 = const_int i64 1
  %18 = add i64 %15, %17
  %19 = const_int i64 2
  %20 = add i64 %15, %19
  %21 = const_int i64 3
  %22 = add i64 %15, %21
  %23 = const_int i64 4
  %24 = add i64 %15, %23
  %25 = const_int i64 5
  %26 = add i64 %15, %25
  %27 = const_int i64 6
  %28 = add i64 %15, %27
  %29 = const_int i64 7
  %30 = add i64 %15, %29
  %31 = gc_alloc size=64 ptrs=[] (i64, i64, i64, i64, i64, i64, i64, i64)
  field_set %31[0] = %15
  field_set %31[8] = %18
  field_set %31[16] = %20
  field_set %31[24] = %22
  field_set %31[32] = %24
  field_set %31[40] = %26
  field_set %31[48] = %28
  field_set %31[56] = %30
  ret %31
}

func main() void {
bb0():
  %0 = const_int i64 1
  %1 = call @eight(%0) (i64, i64, i64, i64, i64, i64, i64, i64)
  %2 = field_get %1[0] i64
  %3 = field_get %1[8] i64
  %4 = field_get %1[16] i64
  %5 = field_get %1[24] i64
  %6 = field_get %1[32] i64
  %7 = field_get %1[40] i64
  %8 = field_get %1[48] i64
  %9 = field_get %1[56] i64
  ret
}'

  sigmw3=$(explainMismatch "$oracle_mw_pure" "$bit2_mw_pure" ir)
  rcmw3=$?
  if [ "$rcmw3" -ne 0 ] || [ "$sigmw3" != "5870-multiword-return-rebox" ]; then
    echo "FAIL: the real pure #5870 pre-opt delta (no #5874 entanglement) was not explained (rc=$rcmw3 sig='$sigmw3')"
    fail=1
  fi

  # REJECTION: an unrelated single-opcode delta in a file whose ORACLE side
  # happens to declare an 8-int-word return (so S5870>0) must NOT be
  # explained -- proves the guard requiring `call_word` to have ACTUALLY
  # moved negatively before subtracting anything, not just S5870>0. Without
  # that guard this would fabricate box traffic from S5870/R5870 alone and
  # wrongly pass through to `fallibleWordsOk`.
  # `mul` (not `const_int`): a single-opcode bump needs to be outside EVERY
  # other declared signature's closed set too, or it is a bad control (an
  # earlier version of this test used `const_int` and it was independently,
  # correctly, explained by `5876-field-store-declared-type-convert` before
  # reaching this block at all).
  oracle_mw_unrelated='func eight(%0: i64) (i64, i64, i64, i64, i64, i64, i64, i64) {
  ret %1
}'
  bit2_mw_unrelated='func eight(%0: i64) (i64, i64, i64, i64, i64, i64, i64, i64) {
  %9 = mul i64 %1, %2
  ret %1
}'
  sigmw4=$(explainMismatch "$oracle_mw_unrelated" "$bit2_mw_unrelated" ir)
  rcmw4=$?
  if [ "$rcmw4" -eq 0 ] || [ -n "$sigmw4" ]; then
    echo "FAIL: an unrelated delta in a file with an unrelated wide-int-return oracle header was wrongly explained (rc=$rcmw4 sig='$sigmw4')"
    fail=1
  fi

  # REJECTION: the real pure #5870 shape with one `field_get` read dropped --
  # the relation the identity checks (field_get tied to call_word/gc_alloc
  # through S5870/R5870) is broken, and the residual is not empty and does
  # not fit `fallibleWordsOk` either (no const_* opcode moved).
  bit2_mw_pure_broken=$(printf '%s\n' "$bit2_mw_pure" | grep -v '^  %9 = field_get %1\[56\] i64$')
  sigmw5=$(explainMismatch "$oracle_mw_pure" "$bit2_mw_pure_broken" ir)
  rcmw5=$?
  if [ "$rcmw5" -eq 0 ] || [ -n "$sigmw5" ]; then
    echo "FAIL: a #5870 delta with one field_get read dropped was wrongly explained (rc=$rcmw5 sig='$sigmw5')"
    fail=1
  fi

  # REJECTION: an unrelated opcode riding along an otherwise-genuine
  # composed #5870+#5874 delta must still fail -- same closed-set
  # requirement `fallibleWordsOk` already enforces on the residual.
  bit2_mw_plus="$bit2_mw_pre
%999 = xor i64 %1, %2"
  sigmw6=$(explainMismatch "$oracle_mw_pre" "$bit2_mw_plus" ir)
  rcmw6=$?
  if [ "$rcmw6" -eq 0 ] || [ -n "$sigmw6" ]; then
    echo "FAIL: a composed #5870+#5874 delta carrying an unrelated opcode was wrongly explained (rc=$rcmw6 sig='$sigmw6')"
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
