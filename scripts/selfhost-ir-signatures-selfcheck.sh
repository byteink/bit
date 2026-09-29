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

# Self-check: run directly (not sourced) to assert explainMismatch rejects
# unrelated text on every kind. `types` alone currently carries a declared
# signature, `6244-json-attr-implicit-insert` (see scripts/selfhost-ir-
# signatures.sh's header); `ir`/`iropt`/`ast`/`fmt` carry none (see that
# file's Retirement history), so every arm below under those four kinds
# must always return 1.
# `bash scripts/selfhost-ir-signatures-selfcheck.sh`. Same pattern as
# scripts/selfhost-ir-canon.sh's self-check.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -u
  fail=0

  # #3107, #3108, #3898 and #3862 were declared here and RETIRED by #5509.
  # #5486-variant-payload-reorder, #5429-decimal-boxed-slot-explode,
  # #5506-enum-nil-payload-retype, #5445-method-return-explode-direct-call,
  # #5521-void-return-bare-ret and #5486-variant-payload-redundant-read-elim
  # were RETIRED by the stage0 0.20.0 repin (#5607). #5870, #5871 (both
  # arms), #5874, #5876, #5895, #5905, #5906 and #5910 were RETIRED by the
  # stage0 0.27.0 repin (#5914). #5921-ptrof-string-type was RETIRED by the
  # stage0 0.28.0 repin (#5957). #5474-catch-composite-default-ast,
  # #5474-catch-composite-default-fmt and #6051-generic-member-comment-fmt
  # were all RETIRED by the stage0 0.32.0 repin (#6187): 0.32.0's own
  # oracle already parses and formats every shape they used to explain the
  # way the tree does, confirmed by `bash scripts/selfhost-diffast.sh`
  # (MATCH=1410 MISMATCH=0 EXPLAINED=0) and `bash scripts/selfhost-
  # difffmt.sh` (MATCH=2036 MISMATCH=0 EXPLAINED=0) against the 0.32.0 pin
  # -- `ast`/`fmt` have no automated RETIRED audit, so this pair was
  # confirmed dead by hand. #6194-generic-method-receiver-unsubstituted-
  # type/-explode, #6161-json-decode-column-shift/-json-schema-synthesized-
  # insert/-json-decode-enum-error-resolved/-json-schema-specialize-call and
  # #6201-json-schema-generic-wrapper-specialize were RETIRED by the stage0
  # 0.33.0 repin (#6245): 0.33.0 contains #6161, #6194 and #6201, so it is
  # the first oracle that agrees with the tree on every corpus file those
  # seven signatures used to explain. Their shaped-delta fixtures lived in
  # this self-check; removed with the arms they tested rather than kept as
  # tests for identities that no longer exist. Git history at this file's
  # state before #5914/#5957/#6187/#6245 has them, and scripts/selfhost-ir-
  # signatures.sh's own header records why each went dead.

  # An unrelated opcode-shaped delta must NOT be explained by anything
  # declared under `ir`/`iropt` -- no signature is currently declared for
  # either kind (see scripts/selfhost-ir-signatures.sh's Retirement history),
  # so both must always return 1 regardless of what the text looks like.
  oracle_unrelated='%1 = sub %2, %3'
  bit2_unrelated='%1 = sub %2, %3
%4 = sub %5, %6'

  sig2=$(explainMismatch "$oracle_unrelated" "$bit2_unrelated" ir)
  rc2=$?
  if [ "$rc2" -eq 0 ] || [ -n "$sig2" ]; then
    echo "FAIL: an unrelated ir delta was wrongly explained (rc=$rc2 sig='$sig2')"
    fail=1
  fi
  sig2o=$(explainMismatch "$oracle_unrelated" "$bit2_unrelated" iropt)
  rc2o=$?
  if [ "$rc2o" -eq 0 ] || [ -n "$sig2o" ]; then
    echo "FAIL: an unrelated iropt delta was wrongly explained (rc=$rc2o sig='$sig2o')"
    fail=1
  fi

  # An unrelated ast/fmt divergence must NOT be explained by anything --
  # no signature is currently declared for either kind (see scripts/
  # selfhost-ir-signatures.sh's Retirement history), so both must always
  # return 1 regardless of what the text looks like.
  sigau=$(explainMismatch '(program (call foo))' '(program (call bar))' ast)
  rcau=$?
  if [ "$rcau" -eq 0 ] || [ -n "$sigau" ]; then
    echo "FAIL: an unrelated ast delta was wrongly explained (rc=$rcau sig='$sigau')"
    fail=1
  fi
  sigfu=$(explainMismatch 'fn main() { println("a") }' 'fn main() { println("b") }' fmt)
  rcfu=$?
  if [ "$rcfu" -eq 0 ] || [ -n "$sigfu" ]; then
    echo "FAIL: an unrelated fmt delta was wrongly explained (rc=$rcfu sig='$sigfu')"
    fail=1
  fi

  # REJECTION: an unrelated type change (no `Option` involved at all) must
  # not be explained by coincidence, and neither must a real one.
  oracle_unrelated_type='10:5: x: int'
  bit2_unrelated_type='10:5: x: float'
  sigut=$(explainMismatch "$oracle_unrelated_type" "$bit2_unrelated_type" types)
  rcut=$?
  if [ "$rcut" -eq 0 ] || [ -n "$sigut" ]; then
    echo "FAIL: an unrelated types delta was wrongly explained (rc=$rcut sig='$sigut')"
    fail=1
  fi

  # #6244-json-attr-implicit-insert: POSITIVE case, the exact shape
  # scripts/selfhost-ir-signatures.sh's header derives from the real
  # stdlib/sql/rowtypes.test.bit dumps -- a pure insertion (an unrelated
  # line before and after, untouched) plus one `<error>`-containing pair
  # resolving to a real type at the SAME `LINE:COL: <expr>` prefix.
  oracle_6244=$(printf '1:1: before: int\n5:1: entries: []<error>\n9:1: after: string\n')
  bit2_6244=$(printf '1:1: before: int\n2:1: RowtypesSettings: Json\n5:1: entries: []JsonEntry\n9:1: after: string\n')
  sig6244=$(explainMismatch "$oracle_6244" "$bit2_6244" types)
  rc6244=$?
  if [ "$rc6244" -ne 0 ] || [ "$sig6244" != "6244-json-attr-implicit-insert" ]; then
    echo "FAIL: the #6244 json-attr-implicit-insert shape was not explained (rc=$rc6244 sig='$sig6244')"
    fail=1
  fi

  # #6244: REJECTION, a real regression riding along with an otherwise
  # #6244-shaped insertion -- an oracle line that is neither reproduced
  # byte-for-byte nor a jsonAttrTypeResolved pair (here: a well-typed oracle
  # line changing to a DIFFERENT concrete type, not through `<error>`) must
  # still fail closed, never masked by the insertion elsewhere in the file.
  oracle_6244_regress=$(printf '1:1: before: int\n5:1: entries: []<error>\n9:1: after: string\n')
  bit2_6244_regress=$(printf '1:1: before: int\n2:1: RowtypesSettings: Json\n5:1: entries: []JsonEntry\n9:1: after: float\n')
  sig6244r=$(explainMismatch "$oracle_6244_regress" "$bit2_6244_regress" types)
  rc6244r=$?
  if [ "$rc6244r" -eq 0 ] || [ -n "$sig6244r" ]; then
    echo "FAIL: a real regression alongside a #6244-shaped insertion was wrongly explained (rc=$rc6244r sig='$sig6244r')"
    fail=1
  fi

  # #6255-table-row-synth-reposition: POSITIVE, the run_sql_row_persisted.bit
  # shape -- inserted @table static lines plus find<T>'s mapper lines moved
  # to another column of the same synthesized line (once duplicated).
  oracle_6255=$(printf '2:1: a: int\n76:110: cols: []string\n76:248: __row: User\n')
  bit2_6255=$(printf '2:1: a: int\n9:14: User: ()\n76:203: cols: []string\n76:203: cols: []string\n76:226: __row: User\n')
  sig6255=$(explainMismatch "$oracle_6255" "$bit2_6255" types)
  rc6255=$?
  if [ "$rc6255" -ne 0 ] || [ "$sig6255" != "6255-table-row-synth-reposition" ]; then
    echo "FAIL: the #6255 synthesized-mapper reposition shape was not explained (rc=$rc6255 sig='$sig6255')"
    fail=1
  fi
  # #6255: REJECTION -- same line, same column shift, but a DIFFERENT type.
  oracle_6255r=$(printf '76:110: cols: []string\n')
  bit2_6255r=$(printf '76:203: cols: []int\n')
  sig6255r=$(explainMismatch "$oracle_6255r" "$bit2_6255r" types)
  rc6255r=$?
  if [ "$rc6255r" -eq 0 ] || [ -n "$sig6255r" ]; then
    echo "FAIL: a #6255-shaped column shift with a changed type was wrongly explained (rc=$rc6255r sig='$sig6255r')"
    fail=1
  fi

  # #6254-collection-attr-presyntax: POSITIVE, the 0.33.0 oracle's E0136
  # block for `@collection` is its ONLY extra output; the tree says nothing.
  oracle_6254=$(printf "error[E0136]: '@collection' is not an attribute a class accepts\n  --> m.bit:20:7\n   |\n20 | @json @collection(\"sessions\") class Session {\n   |       ^^^^^^^^^^^^^^^^^^^^^^^ '@json', '@table' are the class attributes\n")
  sig6254=$(explainMismatch "$oracle_6254" "" diags)
  rc6254=$?
  if [ "$rc6254" -ne 0 ] || [ "$sig6254" != "6254-collection-attr-presyntax" ]; then
    echo "FAIL: the #6254 @collection presyntax shape was not explained (rc=$rc6254 sig='$sig6254')"
    fail=1
  fi
  # #6254: REJECTION -- the same E0136 block plus any other oracle-only
  # diagnostic, or a tree-only diagnostic, fails closed.
  oracle_6254r=$(printf "error[E0136]: '@collection' is not an attribute a class accepts\n  --> m.bit:20:7\nerror[E0040]: undefined name 'x'\n  --> m.bit:30:1\n")
  sig6254r=$(explainMismatch "$oracle_6254r" "" diags)
  rc6254r=$?
  if [ "$rc6254r" -eq 0 ] || [ -n "$sig6254r" ]; then
    echo "FAIL: an extra oracle-only diagnostic beside the #6254 block was wrongly explained (rc=$rc6254r sig='$sig6254r')"
    fail=1
  fi
  sig6254t=$(explainMismatch "" "error[E0040]: undefined name 'x'" diags)
  rc6254t=$?
  if [ "$rc6254t" -eq 0 ] || [ -n "$sig6254t" ]; then
    echo "FAIL: a tree-only diagnostic was wrongly explained as #6254 (rc=$rc6254t sig='$sig6254t')"
    fail=1
  fi

  # #6264-from-contextual-token: POSITIVE and REJECTION.
  s64t=$(explainMismatch "$(printf 'kw_import 0..6\nkw_from 20..24\n')" "$(printf 'kw_import 0..6\nident 20..24\n')" tokens)
  if [ "$s64t" != "6264-from-contextual-token" ]; then
    echo "FAIL: the #6264 kw_from/ident token shape was not explained (sig='$s64t')"; fail=1
  fi
  s64tr=$(explainMismatch "$(printf 'kw_from 20..24\n')" "$(printf 'ident 20..25\n')" tokens)
  if [ -n "$s64tr" ]; then
    echo "FAIL: a kw_from/ident pair with a different span was wrongly explained (sig='$s64tr')"; fail=1
  fi
  # #6264-from-contextual-diags: the renamed token, and a reserved-word block.
  s64d=$(explainMismatch "error[E0021]: expected a top-level declaration, found kw_from" "error[E0021]: expected a top-level declaration, found an identifier" diags)
  if [ "$s64d" != "6264-from-contextual-diags" ]; then
    echo "FAIL: the #6264 renamed-token diagnostic was not explained (sig='$s64d')"; fail=1
  fi
  s64b=$(explainMismatch "$(printf "error[E0021]: 'from' is a reserved keyword\n  --> m.bit:10:3\n   |\n10 |   from: int,\n")" "" diags)
  if [ "$s64b" != "6264-from-contextual-diags" ]; then
    echo "FAIL: the #6264 reserved-from block was not explained (sig='$s64b')"; fail=1
  fi
  s64dr=$(explainMismatch "error[E0021]: expected a top-level declaration, found kw_from" "error[E0021]: expected an expression, found an identifier" diags)
  if [ -n "$s64dr" ]; then
    echo "FAIL: a #6264-shaped diagnostic with a changed message was wrongly explained (sig='$s64dr')"; fail=1
  fi
  # #6264-from-contextual-types: nameless oracle entry vs a typed `from`.
  s64y=$(explainMismatch "1:1: : i64" "23:7: from: i64" types)
  if [ "$s64y" != "6264-from-contextual-types" ]; then
    echo "FAIL: the #6264 from binding types shape was not explained (sig='$s64y')"; fail=1
  fi
  s64yr=$(explainMismatch "1:1: : i64" "23:7: from: string" types)
  if [ -n "$s64yr" ]; then
    echo "FAIL: a #6264 from binding with a different type was wrongly explained (sig='$s64yr')"; fail=1
  fi

  # #6269-default-id-attr: POSITIVE (post-opt shape, one class) and REJECTION
  # (the same block without the "id" string, and with an extra call).
  o69='%1 = const_nil'
  b69=$(printf '%%1 = rt_call slice_new(%%2, %%2, %%2, %%3) []AttrDesc\n%%4 = gc_alloc size=16 ptrs=[%%0] AttrDesc\n%%5 = const_string "id"\n%%6 = field_get %%1[0] i64\nindex_set %%6[%%7] = %%4\n%%8 = const_nil\n')
  s69=$(explainMismatch "$o69" "$b69" iropt)
  if [ "$s69" != "6269-default-id-attr" ]; then
    echo "FAIL: the #6269 default-id attribute block was not explained (sig='$s69')"; fail=1
  fi
  b69r=$(printf '%%1 = rt_call slice_new(%%2, %%2, %%2, %%3) []AttrDesc\n%%4 = gc_alloc size=16 ptrs=[%%0] AttrDesc\n%%5 = const_string "id"\n%%6 = field_get %%1[0] i64\nindex_set %%6[%%7] = %%4\n%%8 = const_nil\n%%9 = rt_call print(%%5)\n')
  s69r=$(explainMismatch "$o69" "$b69r" iropt)
  if [ -n "$s69r" ]; then
    echo "FAIL: a #6269-shaped block with an extra call was wrongly explained (sig='$s69r')"; fail=1
  fi

  # #6265-closure-bound-static-self (types) and -insert (ir, one file only).
  s65=$(explainMismatch "46:12: apply(x, f): Self!" "46:12: apply(x, f): T!" types)
  if [ "$s65" != "6265-closure-bound-static-self" ]; then
    echo "FAIL: the #6265 Self-to-T shape was not explained (sig='$s65')"; fail=1
  fi
  s65r=$(explainMismatch "46:12: apply(x, f): Self!" "46:12: apply(x, f): U!" types)
  if [ -n "$s65r" ]; then
    echo "FAIL: a Self rebound to the wrong parameter was wrongly explained (sig='$s65r')"; fail=1
  fi
  o65=$(printf 'func main() void {\n  ret\n}\n')
  b65=$(printf 'func main() void {\n  ret\n}\n\nfunc apply$0(%%0: i64) i64 {\n  ret %%0\n}\n')
  s65i=$(explainMismatch "$o65" "$b65" ir "_tests_/cases/run_generic_closure_over_bound_self_static.bit")
  if [ "$s65i" != "6265-closure-bound-static-insert" ]; then
    echo "FAIL: the #6265 inserted-function shape was not explained (sig='$s65i')"; fail=1
  fi
  s65o=$(explainMismatch "$o65" "$b65" ir "_tests_/cases/some_other_file.bit")
  if [ -n "$s65o" ]; then
    echo "FAIL: the #6265 inserted-function shape was explained for a file it is not declared for (sig='$s65o')"; fail=1
  fi
  b65c=$(printf 'func main() void {\n  %%1 = const_int i64 1\n  ret\n}\n\nfunc apply$0(%%0: i64) i64 {\n  ret %%0\n}\n')
  s65c=$(explainMismatch "$o65" "$b65c" ir "_tests_/cases/run_generic_closure_over_bound_self_static.bit")
  if [ -n "$s65c" ]; then
    echo "FAIL: a changed existing function beside an inserted one was wrongly explained (sig='$s65c')"; fail=1
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
