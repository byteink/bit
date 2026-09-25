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

  # --- #5895: a bounds check the loop test proved, post-opt only ---
  #
  # Real dump text from `_tests_/cases/run_while_index_bce.bit`'s
  # `nestedAndContinue` (this tree vs the pinned stage0): the check before
  # the outer load and its panic block are gone, the `br` is a `jump`.
  oracle_bce='  br %12, bb4(), bb3()
bb3():
  %11 = icmp_ult bool %9, %6
  br %11, bb5(), bb4()
bb4():
  %13 = const_string "index out of range"
  %14 = rt_call panic(%13) void
  unreachable
bb5():
  %16 = index_get %5[%9] i64'
  bit2_bce='  br %12, bb4(), bb3()
bb3():
  jump bb5()
bb5():
  %16 = index_get %5[%9] i64'
  sigb1=$(explainMismatch "$oracle_bce" "$bit2_bce" iropt)
  rcb1=$?
  if [ "$rcb1" -ne 0 ] || [ "$sigb1" != "5895-bce-trivial-param" ]; then
    echo "FAIL: the real #5895 dropped-check delta was not explained (rc=$rcb1 sig='$sigb1')"
    fail=1
  fi
  # REJECTION: pre-opt IR never drops a check, so the same delta under `ir`.
  sigb2=$(explainMismatch "$oracle_bce" "$bit2_bce" ir)
  rcb2=$?
  if [ "$rcb2" -eq 0 ] || [ -n "$sigb2" ]; then
    echo "FAIL: a #5895 delta was wrongly explained pre-opt (rc=$rcb2 sig='$sigb2')"
    fail=1
  fi
  # REJECTION: the compare is gone but the panic block survives -- not the
  # shape of a proven check, so nothing may explain it.
  bit2_bce_half='  br %12, bb4(), bb3()
bb3():
  jump bb5()
bb4():
  %13 = const_string "index out of range"
  %14 = rt_call panic(%13) void
  unreachable
bb5():
  %16 = index_get %5[%9] i64'
  sigb3=$(explainMismatch "$oracle_bce" "$bit2_bce_half" iropt)
  rcb3=$?
  if [ "$rcb3" -eq 0 ] || [ -n "$sigb3" ]; then
    echo "FAIL: a half-dropped #5895 check was wrongly explained (rc=$rcb3 sig='$sigb3')"
    fail=1
  fi
  # COMPOSED: stdlib/smtp/header.bit carries a dropped check AND the #5871
  # post-opt delta; the residual after the five opcodes goes on to #5871.
  oracle_bce_tuple="${oracle_bce}
%20 = gc_alloc size=16 ptrs=[%8] (bool, string)
%21 = field_get %20[8] string"
  bit2_bce_tuple="${bit2_bce}
%22 = call_word %5[1] string"
  sigb4=$(explainMismatch "$oracle_bce_tuple" "$bit2_bce_tuple" iropt)
  rcb4=$?
  if [ "$rcb4" -ne 0 ] || [ "$sigb4" != "5871-tuple-word-explode" ]; then
    echo "FAIL: a #5895 check composed with a #5871 delta was not explained (rc=$rcb4 sig='$sigb4')"
    fail=1
  fi

  # --- #5905: a comma-ok miss's unread zero object, post-opt only ---
  #
  # Real dump text from `_tests_/cases/ir_map_commaok_miss.bit`'s `hitOnly`
  # (this tree vs the pinned stage0): the miss block passes the probed word.
  oracle_cm='  %5 = rt_call map_val_at(%0, %2) Obj
  br %7, bb2(%5), bb1()
bb1():
  %9 = gc_alloc size=8 ptrs=[] Obj
  jump bb2(%9)'
  bit2_cm='  %5 = rt_call map_val_at(%0, %2) Obj
  br %7, bb2(%5), bb1()
bb1():
  jump bb2(%5)'
  sigc1=$(explainMismatch "$oracle_cm" "$bit2_cm" iropt)
  rcc1=$?
  if [ "$rcc1" -ne 0 ] || [ "$sigc1" != "5905-commaok-miss-zero-drop" ]; then
    echo "FAIL: the real #5905 dropped zero object was not explained (rc=$rcc1 sig='$sigc1')"
    fail=1
  fi
  # REJECTION: lowering never drops it, so the same delta under `ir`.
  sigc2=$(explainMismatch "$oracle_cm" "$bit2_cm" ir)
  rcc2=$?
  if [ "$rcc2" -eq 0 ] || [ -n "$sigc2" ]; then
    echo "FAIL: a #5905 delta was wrongly explained pre-opt (rc=$rcc2 sig='$sigc2')"
    fail=1
  fi
  # REJECTION: an allocation dropped where no comma-ok read exists is not
  # this signature's (#5871's looser tuple identity may still take it).
  sigc3=$(explainMismatch "${oracle_cm//map_val_at/map_get}" "${bit2_cm//map_val_at/map_get}" iropt)
  if [ "$sigc3" = "5905-commaok-miss-zero-drop" ]; then
    echo "FAIL: a dropped allocation with no map_val_at was explained as #5905"
    fail=1
  fi
  # REJECTION: the zero object is gone AND another opcode moved.
  sigc4=$(explainMismatch "$oracle_cm" "${bit2_cm}
  %99 = field_get %5[0] i64" iropt)
  rcc4=$?
  if [ "$rcc4" -eq 0 ] || [ -n "$sigc4" ]; then
    echo "FAIL: a #5905 delta carrying an unrelated opcode was wrongly explained (rc=$rcc4 sig='$sigc4')"
    fail=1
  fi

  # --- #5870: a `ret` over the 5-integer-word budget boxes again, composed
  # with #5874 in the one file it hits (#5883) --- moved verbatim to
  # scripts/ir-signatures-selfcheck-multiword.sh by #5885 to stay under the
  # 800-line ceiling; sourced here so it still runs as part of this
  # self-check, same `fail`/`explainMismatch` scope.
  # shellcheck source=scripts/ir-signatures-selfcheck-multiword.sh
  . "${ROOT}/scripts/ir-signatures-selfcheck-multiword.sh"

  # --- #5906: a map read keyed by a fresh `string` box passes its words ---
  #
  # Real dump text (this tree at 65e6265d4 vs the pinned stage0):
  # `get` in _tests_/cases/run_map_str_key_words.bit pre-opt, and the
  # #4628-diamond `map_slot` in run_map_string_key_align.bit's `growLost`
  # post-opt.
  oracle_ms_pre='func get(%0: map<string, i64>, %1: i64, %2: i64, %3: string) i64 {
bb0(%0: map<string, i64>, %1: i64, %2: i64, %3: string):
  %4 = gc_alloc size=24 ptrs=[%16] string
  field_set %4[0] = %1
  field_set %4[8] = %2
  field_set %4[16] = %3
  %8 = rt_call map_get(%0, %4) i64
  ret %8
}'
  bit2_ms_pre='func get(%0: map<string, i64>, %1: i64, %2: i64, %3: string) i64 {
bb0(%0: map<string, i64>, %1: i64, %2: i64, %3: string):
  %4 = gc_alloc size=24 ptrs=[%16] string
  field_set %4[0] = %1
  field_set %4[8] = %2
  field_set %4[16] = %3
  %8 = field_get %4[0] i64
  %9 = field_get %4[8] i64
  %10 = field_get %4[16] string
  %11 = rt_call map_get_str(%0, %8, %9) i64
  ret %11
}'
  oracle_ms_opt='func growLost() i64 {
bb25():
  %111 = call @growKey(%106) i64
  %112 = call_word %111[1] i64
  %113 = call_word %111[2] string
  %114 = const_nil
  %115 = icmp_ne bool %113, %114
  br %115, bb26(), bb28()
bb26():
  %117 = field_get %113[0] i64
  %118 = icmp_eq bool %117, %111
  br %118, bb27(), bb28()
bb27():
  %120 = field_get %113[8] i64
  %121 = icmp_eq bool %120, %112
  br %121, bb29(%113), bb28()
bb28():
  %123 = gc_alloc size=24 ptrs=[%16] string
  field_set %123[0] = %111
  field_set %123[8] = %112
  field_set %123[16] = %113
  jump bb29(%123)
bb29(%128: string):
  %129 = rt_call map_slot(%105, %128) i64
}'
  bit2_ms_opt='func growLost() i64 {
bb25():
  %111 = call @growKey(%106) i64
  %112 = call_word %111[1] i64
  %113 = call_word %111[2] string
  %114 = rt_call map_slot_str(%105, %111, %112) i64
}'
  for ms in "ir|$oracle_ms_pre|$bit2_ms_pre" "iropt|$oracle_ms_opt|$bit2_ms_opt"; do
    IFS='|' read -r -d '' msk mso msb <<<"$ms"
    msb=${msb%$'\n'}
    sigms=$(explainMismatch "$mso" "$msb" "$msk")
    rcms=$?
    if [ "$rcms" -ne 0 ] || [ "$sigms" != "5906-map-str-key-words" ]; then
      echo "FAIL: the real #5906 $msk delta was not explained (rc=$rcms sig='$sigms')"
      fail=1
    fi
  done

  # REJECTION: an unrelated single-opcode delta riding along a genuine
  # pre-opt site, and the same rename with the key a handle the oracle did
  # NOT box (the site count comes from the oracle, so it is zero).
  oracle_ms_handle='  %8 = rt_call map_get(%0, %3) i64'
  bit2_ms_handle='  %8 = field_get %3[0] i64
  %9 = field_get %3[8] i64
  %10 = field_get %3[16] string
  %11 = rt_call map_get_str(%0, %8, %9) i64'
  for ms in "$oracle_ms_pre|$bit2_ms_pre
%999 = xor i64 %1, %2" "$oracle_ms_handle|$bit2_ms_handle"; do
    IFS='|' read -r -d '' mso msb <<<"$ms"
    msb=${msb%$'\n'}
    sigms=$(explainMismatch "$mso" "$msb" ir)
    rcms=$?
    if [ "$rcms" -eq 0 ] || [ -n "$sigms" ]; then
      echo "FAIL: a #5906-shaped delta that is not #5906 was wrongly explained (rc=$rcms sig='$sigms')"
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
