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
# unrelated text on every kind -- no signature is currently declared for any
# of them (see scripts/selfhost-ir-signatures.sh's Retirement history).
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
  # confirmed dead by hand. Their shaped-delta fixtures lived in this
  # self-check; removed with the arms they tested rather than kept as tests
  # for identities that no longer exist. Git history at this file's state
  # before #5914/#5957/#6187 has them, and scripts/selfhost-ir-
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

  # REJECTION: no signature is currently declared for `types` (#5921 was
  # retired by the stage0 0.28.0 repin, #5957) -- an unrelated type change
  # must not be explained by coincidence, and neither must a real one.
  oracle_unrelated_type='10:5: x: int'
  bit2_unrelated_type='10:5: x: float'
  sigut=$(explainMismatch "$oracle_unrelated_type" "$bit2_unrelated_type" types)
  rcut=$?
  if [ "$rcut" -eq 0 ] || [ -n "$sigut" ]; then
    echo "FAIL: an unrelated types delta was wrongly explained (rc=$rcut sig='$sigut')"
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
