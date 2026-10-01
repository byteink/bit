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
# signatures.sh's header), and `ir`/`iropt` one, file-scoped:
# `6415-catch-assign-join-args`. `ast`/`fmt`/`diags`/`tokens` carry none (see
# that file's Retirement history), so every arm below under those kinds must
# always return 1.
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
  # signatures.sh's own header records why each went dead. The eleven
  # signatures declared for #6254, #6255, #6264, #6265, #6269, #6045 and
  # #6363 were RETIRED by the stage0 0.34.0 repin (#6395), with their
  # positive and rejection fixtures; only #6244 stays.

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

  # diags and tokens declare nothing since #6395: an unrelated divergence on
  # either kind must stay unexplained.
  sigdu=$(explainMismatch 'error[E0040]: undefined name' 'error[E0041]: other' diags)
  sigtu=$(explainMismatch 'kw_from 20..24' 'ident 20..24' tokens)
  if [ -n "$sigdu" ] || [ -n "$sigtu" ]; then
    echo "FAIL: a diags/tokens delta was wrongly explained (diags='$sigdu' tokens='$sigtu')"
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

  # #6244: POSITIVE, the post-0.34.0 shape that keeps the signature alive,
  # _tests_/imports/nsstaticcall/main.bit (#6388): the oracle types a static
  # call through a namespace-qualified class as `<error>`, the tree as its
  # real type, at the same `LINE:COL: <expr>` prefix.
  oracle_6388=$(printf '8:5: m: Counter\n9:19: m.Counter.scaled(3, "abcd"): <error>\n')
  bit2_6388=$(printf '8:5: m: Counter\n9:19: m.Counter.scaled(3, "abcd"): i64\n')
  sig6388=$(explainMismatch "$oracle_6388" "$bit2_6388" types)
  if [ "$sig6388" != "6244-json-attr-implicit-insert" ]; then
    echo "FAIL: the <error>-to-concrete-type shape was not explained (sig='$sig6388')"
    fail=1
  fi

  # #6415-catch-assign-join-args: POSITIVE, lines taken from the real
  # stage0-vs-tree --dump-ir diff of _tests_/cases/run_shortcircuit_catch_assign.bit:
  # the tree threads two locals through the join (leading arguments and
  # parameters) and every later value is renumbered.
  o15=$(printf '  br %%9, bb4(), bb5(%%9)\nbb3(%%43: i64, %%44: i64):\nbb5(%%28: bool):\n  %%29 = const_string "and i="\n')
  b15=$(printf '  br %%9, bb4(), bb5(%%3, %%4, %%9)\nbb3(%%45: i64, %%46: i64):\nbb5(%%30: i64, %%31: i64, %%28: bool):\n  %%31 = const_string "and i="\n')
  f15="_tests_/cases/run_shortcircuit_catch_assign.bit"
  for k in ir iropt; do
    s15=$(explainMismatch "$o15" "$b15" "$k" "$f15")
    if [ "$s15" != "6415-catch-assign-join-args" ]; then
      echo "FAIL: the #6415 threaded-join shape was not explained under $k (sig='$s15')"; fail=1
    fi
  done
  s15o=$(explainMismatch "$o15" "$b15" ir "_tests_/cases/some_other_file.bit")
  if [ -n "$s15o" ]; then
    echo "FAIL: the #6415 threaded-join shape was explained for a file it is not declared for (sig='$s15o')"; fail=1
  fi
  # REJECTION: an opcode change riding along, an argument the tree DROPPED,
  # and an extra line must each fail closed.
  b15op=$(printf '  br %%9, bb4(), bb5(%%3, %%4, %%9)\nbb3(%%45: i64, %%46: i64):\nbb5(%%30: i64, %%31: i64, %%28: bool):\n  %%31 = const_int i64 7\n')
  b15drop=$(printf '  br %%9, bb4(), bb5()\nbb3(%%45: i64, %%46: i64):\nbb5(%%28: bool):\n  %%31 = const_string "and i="\n')
  b15extra=$(printf '%s\n  ret\n' "$b15")
  for bad in "$b15op" "$b15drop" "$b15extra"; do
    s15r=$(explainMismatch "$o15" "$bad" ir "$f15")
    if [ -n "$s15r" ]; then
      echo "FAIL: a non-#6415 delta was wrongly explained as #6415 (sig='$s15r')"; fail=1
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
