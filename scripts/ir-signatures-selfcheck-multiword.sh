#!/usr/bin/env bash
# Sourced-only case data for scripts/selfhost-ir-signatures-selfcheck.sh's
# #5870 group (#5885): a pure move of that block, unchanged, out of the
# driver so it stays under the 800-line ceiling (spec/LINT.md) as new
# signatures are added -- same shape #5442 already used to split this
# self-check out of scripts/selfhost-ir-signatures.sh in the first place.
#
# NOT named `selfhost-*.sh` on purpose: scripts/selfhost-diffall.sh discovers
# and runs every `scripts/selfhost-*.sh` file directly as its own
# differential constituent (see that script's header). This file has no
# `explainMismatch`/`ROOT`/`fail` of its own -- it runs in whatever shell
# already sourced it -- so being swept into that glob and executed standalone
# would fail on unset variables. Sourced only, from
# scripts/selfhost-ir-signatures-selfcheck.sh, at the point this block used
# to run inline.
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

