# Shared by selfhost-diffir.sh and selfhost-diffiropt.sh (#1766).
#
# `$t<id>` type-id suffixes are assigned in first-touch interning order, which
# depends on Zig HashMap / call-site-checking iteration order — the seed and
# `bit` can intern the same set of types in a different order and emit
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
  awk '
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

  if [ "$fail" -eq 0 ]; then
    echo "selfhost-ir-canon.sh: self-check passed"
  fi
  exit "$fail"
fi
