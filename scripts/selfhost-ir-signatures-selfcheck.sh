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

# Self-check: run directly (not sourced) to assert explainMismatch explains
# each declared signature's real divergence and nothing unrelated (see
# scripts/selfhost-ir-signatures.sh's Retirement history), and that
# declaredSignatureNames() stays in sync with it.
# `bash scripts/selfhost-ir-signatures-selfcheck.sh`. Same pattern as
# scripts/selfhost-ir-canon.sh's self-check.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -u
  fail=0

  # Every signature this check once carried a fixture for is RETIRED; the
  # list, and the repin that retired each, is in scripts/selfhost-ir-
  # signatures.sh's Retirement history, and the fixtures are in git history at
  # this file's state before #6527. With nothing declared, an unrelated
  # divergence of any shape must stay unexplained on every kind.
  oracle_unrelated='%1 = sub %2, %3'
  bit2_unrelated='%1 = sub %2, %3
%4 = sub %5, %6'
  for kind in ir iropt ast fmt types diags tokens; do
    sig=$(explainMismatch "$oracle_unrelated" "$bit2_unrelated" "$kind" "_tests_/cases/run_bound_static_amp.bit")
    rc=$?
    if [ "$rc" -eq 0 ] || [ -n "$sig" ]; then
      echo "FAIL: an unrelated $kind delta was wrongly explained (rc=$rc sig='$sig')"
      fail=1
    fi
  done

  # --- the signatures declared against the 0.39.0 oracle (#7451) ---
  #
  # Each fixture is a reduced copy of the real divergence; the negative
  # variants break exactly one clause of the identity.
  expect() { # <want name or ""> <got> <label>
    if [ "$1" != "$2" ]; then
      echo "FAIL: $3: want '$1' got '$2'"
      fail=1
    fi
  }
  at='  --> m.bit:3:17
   |
3 |   export static count(): i64 {
   |                 ^^^^^'
  static_o="error[E0021]: expected '(', found an identifier
$at
error[E0021]: expected ':', found '('
  --> m.bit:3:22
   |
3 |   export static count(): i64 {
   |                      ^
error[E0021]: expected '}', found end of file
  --> m.bit:4:1"
  eof_t="error[E0021]: expected '}', found end of file
  --> m.bit:4:1"
  expect 6403-enum-static-method-presyntax "$(explainMismatch "$static_o" "$eof_t" diags)" "static head and cascade"
  expect "" "$(explainMismatch "$static_o" "" diags)" "static: the tree lost the truncation error too"
  expect "" "$(explainMismatch "${static_o}
error[E0001]: unrelated
  --> m.bit:9:1" "$eof_t" diags)" "static: an extra oracle record"
  kw_o="error[E0021]: 'as' is a reserved keyword
  --> m.bit:2:10
   |
2 |   export as(a: Actor): string {
   |          ^^ reserved words cannot be used as identifiers (SPEC §5.2)"
  expect 7035-keyword-member-name-presyntax "$(explainMismatch "$kw_o" "" diags)" "keyword method name"
  expect "" "$(explainMismatch "$(printf '%s' "$kw_o" | sed 's/as(a/as: a/')" "" diags)" "keyword field name stays rejected"
  mkdir -p "${TMPDIR:-/tmp}" && mf=$(mktemp "${TMPDIR:-/tmp}/ir-sig-selfcheck.XXXXXX")
  printf 'fn a(c: bool): string { return render(c ? <a>a#b</a> : <b>no</b>) }\n' >"$mf"
  panic_o='panic: slice bounds out of range'
  expect 6421-ternary-jsx-hash-oracle-panic "$(explainMismatch "$panic_o" "" diags "$mf")" "oracle panic on a ternary JSX then with #"
  expect "" "$(explainMismatch "$panic_o" "" diags)" "oracle panic without the input file"
  expect "" "$(explainMismatch "$panic_o" "$static_o" diags "$mf")" "oracle panic against a tree that errors"
  printf 'fn a(): int { return 1 }\n' >"$mf"
  expect "" "$(explainMismatch "$panic_o" "" diags "$mf")" "oracle panic on an input without the construct"
  rm -f "$mf"
  jo='  let p = <p>it'"'"'s</p>;'
  jt='  let p = <p>it'"'"'s</p>'
  expect 7380-jsx-text-apostrophe-stray-semicolon "$(explainMismatch "$jo" "$jt" fmt)" "stray ; after JSX text"
  expect "" "$(explainMismatch "  let p = <p>its</p>;" "  let p = <p>its</p>" fmt)" "stray ; with no apostrophe"
  expect "" "$(explainMismatch "$jo
let z = 1" "$jt" fmt)" "fmt: a longer oracle output"

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
