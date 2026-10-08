#!/usr/bin/env bash
# Shared by selfhost-diffir.sh and selfhost-diffiropt.sh (#1766).
#
# `$t<id>` type-id suffixes are assigned in first-touch interning order, which
# depends on hash-map and call-site-checking iteration order — two compiler
# versions can intern the same set of types in a different order and emit
# structurally-identical IR with different `$t<id>` numbers (see
# tests/selfhost-ir-gaps.txt: run_generic_method.bit). A raw byte compare
# flags that as a mismatch even though nothing is actually wrong.
#
# canon_ir_ids rewrites every `$t<N>` token to a canonical `$c<idx>` label in
# first-appearance order, scanning top to bottom. Applied independently to
# each side, structurally-equal IR collapses to identical text; a real
# divergence (leaked `<T>`, wrong concrete type, different symbol, missing
# body) still changes the surrounding non-numeric text and still mismatches.
#
# ONLY the `$t<id>` numeric suffix is touched — no whitespace/address/other-id
# normalization. Source with `. scripts/selfhost-ir-canon.sh`, then call
# canon_ir_ids on a string variable (not a stream, to keep call sites simple).
canon_ir_ids() {
  # LC_ALL=C: a dump can hold bytes that are not valid UTF-8 (a string literal);
  # awk in a UTF-8 locale dies on them with `towc: multibyte conversion failure` (#6716).
  LC_ALL=C awk '
    {
      line = $0
      out = ""
      while (match(line, /\$t[0-9]+/)) {
        tok = substr(line, RSTART, RLENGTH)
        if (!(tok in map)) {
          map[tok] = "$c" n++
        }
        out = out substr(line, 1, RSTART - 1) map[tok]
        line = substr(line, RSTART + RLENGTH)
      }
      print out line
    }
  ' <<<"$1"
}

# Self-check: run directly (not sourced) to assert canon_ir_ids does its one
# job and nothing else. `bash scripts/selfhost-ir-canon.sh`.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -u
  fail=0

  assert_eq() {
    if [ "$2" != "$3" ]; then
      echo "FAIL: $1"
      echo "  got:  $2"
      echo "  want: $3"
      fail=1
    fi
  }

  # Same structure, different literal $t numbers -> identical canonical text.
  a=$(canon_ir_ids 'func push$t37(%0: Stack) Stack {
  call @size$t37(%1)
}
func other$t41() {}')
  b=$(canon_ir_ids 'func push$t99(%0: Stack) Stack {
  call @size$t99(%1)
}
func other$t12() {}')
  assert_eq "identical structure canonicalizes identically" "$a" "$b"

  # Distinct ids used consistently -> canonical labels in first-appearance order.
  want='func push$c0(%0: Stack) Stack {
  call @size$c0(%1)
}
func other$c1() {}'
  assert_eq "canonical labels are first-appearance order" "$a" "$want"

  # Leaked generic parameter is not a $t<id> and must survive untouched, so the
  # mismatch is still visible after canonicalization.
  c=$(canon_ir_ids 'func push$t37(%0: Stack<T>) Stack {}')
  d=$(canon_ir_ids 'func push$t99(%0: Stack) Stack {}')
  [ "$c" = "$d" ] && { echo "FAIL: leaked <T> was masked by canonicalization"; fail=1; }

  # A different symbol name is not a $t<id> and must still mismatch.
  e=$(canon_ir_ids 'func push$t37() {}')
  f=$(canon_ir_ids 'func pop$t99() {}')
  [ "$e" = "$f" ] && { echo "FAIL: differing symbol name was masked by canonicalization"; fail=1; }

  # Only the $t<id> suffix is touched: no whitespace/other-token normalization.
  g=$(canon_ir_ids '  %38 = call @size$t37(%26)  i64')
  assert_eq "non-\$t tokens and whitespace are untouched" "$g" '  %38 = call @size$c0(%26)  i64'

  # A non-UTF-8 byte in a const_string must not truncate the dump (#6716): both
  # sides keep all 4 lines and a difference after the byte still shows. Forced
  # to a UTF-8 locale, where awk without LC_ALL=C stops at the byte.
  bad=$(printf '  %%1 = const_string "\300A"')
  h=$(LC_ALL=en_US.UTF-8 canon_ir_ids "func f\$t1() {
${bad}
  ret \$t1 x
}")
  i=$(LC_ALL=en_US.UTF-8 canon_ir_ids "func f\$t2() {
${bad}
  ret \$t2 y
}")
  [ "$h" = "$i" ] && { echo "FAIL: a difference after a non-UTF-8 byte was truncated away"; fail=1; }
  assert_eq "non-UTF-8 byte keeps every line" "$(printf '%s\n' "$h" | wc -l | tr -d ' ')" 4

  if [ "$fail" -eq 0 ]; then
    echo "selfhost-ir-canon.sh: self-check passed"
  fi
  exit "$fail"
fi
