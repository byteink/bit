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
