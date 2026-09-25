#!/usr/bin/env bash
# Sourced-only case data for scripts/selfhost-ir-signatures-selfcheck.sh's
# #5910 group: a pure move of that block, unchanged, out of the driver so it
# stays under the 800-line ceiling (spec/LINT.md) as new signatures are added
# -- same shape #5885 already used for the #5870 group
# (scripts/ir-signatures-selfcheck-multiword.sh).
#
# NOT named `selfhost-*.sh` on purpose: scripts/selfhost-diffall.sh discovers
# and runs every `scripts/selfhost-*.sh` file directly as its own
# differential constituent (see that script's header). This file has no
# `explainMismatch`/`ROOT`/`fail` of its own -- it runs in whatever shell
# already sourced it -- so being swept into that glob and executed standalone
# would fail on unset variables. Sourced only, from
# scripts/selfhost-ir-signatures-selfcheck.sh, at the point this block used
# to run inline.
  # --- #5910: closed-channel recv / failed type assertion builds the live
  # zero object (§13.4) ---
  #
  # Real dump text from `_tests_/cases/run_chan_close_zero_object.bit`'s
  # `main` (this tree at 2d89b3c33 vs stage0): a closed-channel two-result
  # recv of a class `Point`.
  oracle_cz='  %4 = rt_call chan_recv(%2) Point
  %5 = rt_call chan_recv_ok() bool
  %6 = const_string "two-result class x="
  %7 = field_get %4[0] i64'
  bit2_cz='  %4 = rt_call chan_recv(%2) Point
  %5 = rt_call chan_recv_ok() bool
  %6 = const_nil
  %7 = icmp_ne bool %4, %6
  br %7, bb2(%4), bb1()
bb1():
  %9 = gc_alloc size=8 ptrs=[] Point
  jump bb2(%9)
bb2(%11: Point):
  %12 = const_string "two-result class x="
  %13 = field_get %11[0] i64'
  for cz in "ir|$oracle_cz|$bit2_cz" "iropt|$oracle_cz|$bit2_cz"; do
    IFS='|' read -r -d '' czk czo czb <<<"$cz"
    czb=${czb%$'\n'}
    sigcz=$(explainMismatch "$czo" "$czb" "$czk")
    rccz=$?
    if [ "$rccz" -ne 0 ] || [ "$sigcz" != "5910-chan-typeassert-live-zero" ]; then
      echo "FAIL: the real #5910 $czk closed-recv delta was not explained (rc=$rccz sig='$sigcz')"
      fail=1
    fi
  done

  # Real post-opt text from `run_chan_close_zero_object.bit`'s two-result
  # tuple site: `gc_alloc` still moves by N here (nothing DCE's it away),
  # plus the tuple's own `const_int` pair for its zero members.
  oracle_czt='  %24 = rt_call chan_recv(%22) (i64, i64)
  %25 = rt_call chan_recv_ok() bool'
  bit2_czt='  %24 = rt_call chan_recv(%22) (i64, i64)
  %25 = rt_call chan_recv_ok() bool
  %26 = const_nil
  %27 = icmp_ne bool %24, %26
  br %27, bb4(%24), bb3()
bb3():
  %29 = const_int i64 0
  %30 = const_int i64 0
  %31 = gc_alloc size=16 ptrs=[] (i64, i64)
  field_set %31[0] = %29
  field_set %31[8] = %30
  jump bb4(%31)
bb4(%35: (i64, i64)):'
  sigczt=$(explainMismatch "$oracle_czt" "$bit2_czt" iropt)
  rcczt=$?
  if [ "$rcczt" -ne 0 ] || [ "$sigczt" != "5910-chan-typeassert-live-zero" ]; then
    echo "FAIL: the real #5910 tuple-site delta was not explained (rc=$rcczt sig='$sigczt')"
    fail=1
  fi

  # COMPOSED with #5906 on the same file (`run_map_commaok_present_null.bit`'s
  # `fromAssert`/`lookStr`, real text): a genuine #5910 assert site plus the
  # pre-existing map-str-key rename, on ONE combined delta -- `msw` must be
  # subtracted before this identity is checked, the same composition #5905
  # already proves against #5906.
  oracle_cm5906='  %51 = rt_call iface_as(%1, %2) A
  %52 = rt_call iface_as_ok() bool
  %53 = field_get %51[0] i64
  %60 = gc_alloc size=24 ptrs=[%16] string
  field_set %60[0] = %61
  field_set %60[8] = %62
  field_set %60[16] = %63
  %64 = rt_call map_slot(%0, %60) i64'
  bit2_cm5906='  %51 = rt_call iface_as(%1, %2) A
  %52 = rt_call iface_as_ok() bool
  %53 = const_nil
  %54 = icmp_ne bool %51, %53
  br %54, bb2(%51), bb1()
bb1():
  %56 = gc_alloc size=8 ptrs=[] A
  jump bb2(%56)
bb2(%58: A):
  %59 = field_get %58[0] i64
  %60 = gc_alloc size=24 ptrs=[%16] string
  field_set %60[0] = %61
  field_set %60[8] = %62
  field_set %60[16] = %63
  %65 = field_get %60[0] i64
  %66 = field_get %60[8] i64
  %67 = field_get %60[16] string
  %68 = rt_call map_slot_str(%0, %65, %66) i64'
  sigcm5906=$(explainMismatch "$oracle_cm5906" "$bit2_cm5906" ir)
  rccm5906=$?
  if [ "$rccm5906" -ne 0 ] || [ "$sigcm5906" != "5910-chan-typeassert-live-zero" ]; then
    echo "FAIL: a #5910 delta composed with #5906 on one file was not explained (rc=$rccm5906 sig='$sigcm5906')"
    fail=1
  fi

  # REJECTION: an unrelated opcode riding along an otherwise-genuine #5910
  # delta must still fail -- the closed-set requirement every signature here
  # carries.
  bit2_cz_plus="$bit2_cz
%99 = xor i64 %4, %5"
  sigcz2=$(explainMismatch "$oracle_cz" "$bit2_cz_plus" ir)
  rccz2=$?
  if [ "$rccz2" -eq 0 ] || [ -n "$sigcz2" ]; then
    echo "FAIL: a #5910 delta carrying an unrelated opcode was wrongly explained (rc=$rccz2 sig='$sigcz2')"
    fail=1
  fi

  # REJECTION: `icmp_ne`/`br`/`const_nil` no longer move in lockstep -- a
  # second `icmp_ne` with no matching `br`/`const_nil` is not one more site
  # reached, so the anchor must reject it.
  bit2_cz_asym="$bit2_cz
%98 = icmp_ne bool %4, %6"
  sigcz3=$(explainMismatch "$oracle_cz" "$bit2_cz_asym" ir)
  rccz3=$?
  if [ "$rccz3" -eq 0 ] || [ -n "$sigcz3" ]; then
    echo "FAIL: a #5910 delta with icmp_ne/br/const_nil out of lockstep was wrongly explained (rc=$rccz3 sig='$sigcz3')"
    fail=1
  fi
