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
# unrelated text on every kind, and correctly explains/rejects the one
# currently declared signature (#6194, `types`/`ir`/`iropt` -- see
# scripts/selfhost-ir-signatures.sh's header). `ast`/`fmt` still have no
# signature declared at all (see that file's Retirement history).
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

  # --- #6194 POSITIVE: real captured `--dump-types`/`--dump-ir-pre`/
  # `--dump-ir` output for _tests_/cases/run_generic_method_receiver_explode.bit,
  # this tree vs the pinned 0.32.0 stage0 (captured 2026-09-28, ticket #6199) ---
  oracle_6194_types='48:12: Option<T>.Some(this.v): Option
57:7: opt: Option
57:13: mkBox(id): Box<Person>
57:13: mkBox(id).get(): Option
58:8: isSome<Person>(opt): bool
61:10: unwrap<Person>(opt): Person
65:7: f: () => i64
66:9: opt: Option
66:15: mkBox(id): Box<Person>
66:15: mkBox(id).get(): Option
67:10: isSome<Person>(opt): bool
70:12: unwrap<Person>(opt): Person
72:10: f(): i64
76:3: print("direct ${readDirect(7)}\n"): ()
76:19: readDirect(7): i64
77:3: print("closure ${readViaClosure(9)}\n"): ()
77:20: readViaClosure(9): i64'
  bit2_6194_types='48:12: Option<T>.Some(this.v): Option<T>
57:7: opt: Option<Person>
57:13: mkBox(id): Box<Person>
57:13: mkBox(id).get(): Option<Person>
58:8: isSome<Person>(opt): bool
61:10: unwrap<Person>(opt): Person
65:7: f: () => i64
66:9: opt: Option<Person>
66:15: mkBox(id): Box<Person>
66:15: mkBox(id).get(): Option<Person>
67:10: isSome<Person>(opt): bool
70:12: unwrap<Person>(opt): Person
72:10: f(): i64
76:3: print("direct ${readDirect(7)}\n"): ()
76:19: readDirect(7): i64
77:3: print("closure ${readViaClosure(9)}\n"): ()
77:20: readViaClosure(9): i64'
  sig6194t=$(explainMismatch "$oracle_6194_types" "$bit2_6194_types" types)
  rc6194t=$?
  if [ "$rc6194t" -ne 0 ] || [ "$sig6194t" != "6194-generic-method-receiver-unsubstituted-type" ]; then
    echo "FAIL: the real #6194 types divergence was not explained (rc=$rc6194t sig='$sig6194t')"
    fail=1
  fi

  # --- #6194 MUTATION (types): the SAME two lines differing, but with no
  # `Option<T>.` call anywhere in the file -- must be rejected. Proves the
  # signature does not swallow an ordinary Option->Option<X> substitution
  # outside the unsubstituted-generic-receiver shape it names. ---
  oracle_6194_types_mut='10:5: opt: Option'
  bit2_6194_types_mut='10:5: opt: Option<Person>'
  sig6194tm=$(explainMismatch "$oracle_6194_types_mut" "$bit2_6194_types_mut" types)
  rc6194tm=$?
  if [ "$rc6194tm" -eq 0 ] || [ -n "$sig6194tm" ]; then
    echo "FAIL: a types divergence with no Option<T>. call was wrongly explained (rc=$rc6194tm sig='$sig6194tm')"
    fail=1
  fi

  # --- #6194 POSITIVE (ir/iropt): minimal synthetic dumps matching the
  # measured shape -- pre-opt gains field_get/gc_alloc in a [2x,4x] ratio,
  # post-opt loses ONLY gc_alloc. ---
  oracle_6194_ir='%1 = call @get(%0) Option'
  bit2_6194_ir='%1 = call @get(%0) Option
%2 = field_get %1[0] i64
%3 = field_get %1[8] i64
%4 = gc_alloc size=16 ptrs=[] Option'
  sig6194i=$(explainMismatch "$oracle_6194_ir" "$bit2_6194_ir" ir)
  rc6194i=$?
  if [ "$rc6194i" -ne 0 ] || [ "$sig6194i" != "6194-generic-method-receiver-explode" ]; then
    echo "FAIL: the synthetic #6194 ir divergence was not explained (rc=$rc6194i sig='$sig6194i')"
    fail=1
  fi
  oracle_6194_iropt='%1 = gc_alloc size=16 ptrs=[] Option
%2 = gc_alloc size=16 ptrs=[] Option'
  bit2_6194_iropt='%1 = gc_alloc size=16 ptrs=[] Option'
  sig6194o=$(explainMismatch "$oracle_6194_iropt" "$bit2_6194_iropt" iropt)
  rc6194o=$?
  if [ "$rc6194o" -ne 0 ] || [ "$sig6194o" != "6194-generic-method-receiver-explode" ]; then
    echo "FAIL: the synthetic #6194 iropt divergence was not explained (rc=$rc6194o sig='$sig6194o')"
    fail=1
  fi

  # --- #6194 MUTATION (ir/iropt): a DIFFERENT divergence using the same two
  # opcodes must NOT be swallowed. ir: field_get/gc_alloc both +1 (ratio 1,
  # below the measured floor of 2). iropt: gc_alloc INCREASES instead of
  # decreasing (the direction a real regression would take), and separately,
  # gc_alloc decreases but field_get also moves (not gc_alloc-only). ---
  oracle_6194_ir_mut='%1 = call @get(%0) Option'
  bit2_6194_ir_mut='%1 = call @get(%0) Option
%2 = field_get %1[0] i64
%3 = gc_alloc size=16 ptrs=[] Option'
  sig6194im=$(explainMismatch "$oracle_6194_ir_mut" "$bit2_6194_ir_mut" ir)
  rc6194im=$?
  if [ "$rc6194im" -eq 0 ] || [ -n "$sig6194im" ]; then
    echo "FAIL: an ir delta below the 2x ratio floor was wrongly explained (rc=$rc6194im sig='$sig6194im')"
    fail=1
  fi
  oracle_6194_iropt_mut1='%1 = call @get(%0) Option'
  bit2_6194_iropt_mut1='%1 = call @get(%0) Option
%2 = gc_alloc size=16 ptrs=[] Option'
  sig6194iom1=$(explainMismatch "$oracle_6194_iropt_mut1" "$bit2_6194_iropt_mut1" iropt)
  rc6194iom1=$?
  if [ "$rc6194iom1" -eq 0 ] || [ -n "$sig6194iom1" ]; then
    echo "FAIL: an iropt gc_alloc INCREASE was wrongly explained (rc=$rc6194iom1 sig='$sig6194iom1')"
    fail=1
  fi
  oracle_6194_iropt_mut2='%1 = gc_alloc size=16 ptrs=[] Option
%2 = gc_alloc size=16 ptrs=[] Option
%3 = field_get %1[0] i64'
  bit2_6194_iropt_mut2='%1 = gc_alloc size=16 ptrs=[] Option'
  sig6194iom2=$(explainMismatch "$oracle_6194_iropt_mut2" "$bit2_6194_iropt_mut2" iropt)
  rc6194iom2=$?
  if [ "$rc6194iom2" -eq 0 ] || [ -n "$sig6194iom2" ]; then
    echo "FAIL: an iropt delta that also moved field_get was wrongly explained (rc=$rc6194iom2 sig='$sig6194iom2')"
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
