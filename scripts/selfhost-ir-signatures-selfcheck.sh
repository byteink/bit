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
# shellcheck source=scripts/alarmrun.sh
. "${ROOT}/scripts/alarmrun.sh"
# shellcheck source=scripts/selfhost-diffdump-setup.sh
. "${ROOT}/scripts/selfhost-diffdump-setup.sh"
# shellcheck source=scripts/diffexit.sh
. "${ROOT}/scripts/diffexit.sh"

# Assert that unknown deltas fail and the registry matches the dispatch.
# The 0.42.0 repin retired the former identities; #8259 adds one strict identity.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -u
  fail=0

  # Retired fixtures remain in Git history; unrelated deltas must fail on every kind.
  oracle_unrelated='%1 = sub %2, %3'
  bit2_unrelated='%1 = sub %2, %3
%4 = sub %5, %6'
  for kind in ir iropt ast fmt types diags tokens doc; do
    sig=$(explainMismatch "$oracle_unrelated" "$bit2_unrelated" "$kind" "_tests_/cases/run_bound_static_amp.bit")
    rc=$?
    if [ "$rc" -eq 0 ] || [ -n "$sig" ]; then
      echo "FAIL: an unrelated $kind delta was wrongly explained (rc=$rc sig='$sig')"
      fail=1
    fi
  done

  expect() { # <want name or ""> <got> <label>
    if [ "$1" != "$2" ]; then
      echo "FAIL: $3: want '$1' got '$2'"
      fail=1
    fi
  }

  # The former contextual-token identity must now fail like any other delta.
  expect "" "$(explainMismatch 'kw_in 0..2' 'ident 0..2' tokens)" 'retired token identity'
  for kind in ir iropt ast fmt types diags tokens doc; do
    want=""
    [ "$kind" = iropt ] && want=8259-owned-byte-header-copy
    expect "$want" "$(declaredSignatureNames "$kind")" "$kind registry"
  done

  # The matcher sees raw IR: quoted IDs and non-UTF-8 bytes stay literal.
  python3 - "$ROOT/scripts/selfhost-ir-signatures.sh" <<'PYTHON'
import subprocess
import sys

helper = sys.argv[1]
old = b"""func tail$t59(%0: Builder, %1: i64) string {
bb0(%0: Builder, %1: i64):
  %2 = const_int i64 0
  %3 = icmp_slt bool %1, %2
  br %3, bb2(), bb1()
bb1():
  %5 = field_get %0[0] []u8
  %6 = slice_len %5
  %7 = icmp_sgt bool %1, %6
  br %7, bb2(), bb3(%1)
bb2():
  %9 = const_string "literal %13 $t59 \\" \xc0"
  %10 = rt_call panic(%9) void
  unreachable
bb3(%12: i64):
  %13 = rt_call slice_slice(%5, %2, %6) []u8
  %14 = rt_call string_from_byte_range(%13, %12, %6) string
  %15 = field_get %14[0] i64
  %16 = field_get %14[8] i64
  ret %15, %16, %14
}"""
new = old.replace(b"  %13 = rt_call slice_slice(%5, %2, %6) []u8\n", b"")
new = new.replace(b"string_from_byte_range(%13,", b"string_from_byte_range(%5,")
new = new.replace(b"%14", b"%113").replace(b"%15", b"%114").replace(b"%16", b"%115")


def verdict(a, b, kind="iropt"):
    result = subprocess.run(["bash", "-c", 'source "$1"; explainMismatch "$2" "$3" "$4"',
                             "fixture", helper, a, b, kind], capture_output=True)
    assert result.stderr == b"", result.stderr
    return result.returncode, result.stdout


expected = (0, b"8259-owned-byte-header-copy\n")
assert verdict(old, new) == expected, "actual-shaped single function"
assert verdict(old + b"\n\n" + old.replace(b"func tail", b"func other"),
               new + b"\n\n" + new.replace(b"func tail", b"func other")) == expected
negatives = {
    "slice base": (old.replace(b"slice_slice(%5,", b"slice_slice(%0,"), new),
    "lower bound": (old.replace(b"const_int i64 0", b"const_int i64 1"),
                    new.replace(b"const_int i64 0", b"const_int i64 1")),
    "slice upper bound": (old.replace(b"slice_slice(%5, %2, %6)", b"slice_slice(%5, %2, %1)"), new),
    "reader length": (old, new.replace(b"%12, %6)", b"%12, %1)")),
    "reader lower index": (old, new.replace(b"%12, %6)", b"%2, %6)")),
    "additional copy use": (old.replace(b"  ret %15", b"  ret %13, %15"), new),
    "inserted operation": (old, new.replace(b"  ret %114", b"  %120 = const_int i64 0\n  ret %114")),
    "SSA collapse": (old, new.replace(b"%115", b"%114")),
    "changed literal SSA": (old, new.replace(b"literal %13", b"literal %12")),
    "changed literal type": (old, new.replace(b"literal %13 $t59", b"literal %13 $t60")),
    "changed non-UTF-8 literal": (old, new.replace(b"\xc0", b"\xc1")),
    "same counts": (old, new.replace(b"icmp_sgt", b"icmp_slt")),
    "changed field type": (old.replace(b"%0[0] []u8", b"%0[0] []i8"),
                           new.replace(b"%0[0] []u8", b"%0[0] []i8")),
    "header store": (old.replace(b"bb3(%12: i64):", b"bb3(%12: i64):\n  field_set %5[8] = %2"),
                     new.replace(b"bb3(%12: i64):", b"bb3(%12: i64):\n  field_set %5[8] = %2")),
    "unknown operation": (old.replace(b"bb3(%12: i64):", b"bb3(%12: i64):\n  store %5"),
                          new.replace(b"bb3(%12: i64):", b"bb3(%12: i64):\n  store %5")),
    "join predecessor": (old.replace(b"br %3, bb2(), bb1()", b"br %3, bb3(%1), bb1()"),
                         new.replace(b"br %3, bb2(), bb1()", b"br %3, bb3(%1), bb1()")),
    "entry backedge": (old.replace(b"  unreachable", b"  jump bb0(%0, %1)"),
                       new.replace(b"  unreachable", b"  jump bb0(%0, %1)")),
    "unknown terminator": (old.replace(b"  unreachable", b"  unknown_term"),
                           new.replace(b"  unreachable", b"  unknown_term")),
    "type IDs exact": (old, new.replace(b"tail$t59", b"tail$t60")),
    "unknown call": (old.replace(b"bb3(%12: i64):", b"bb3(%12: i64):\n  %30 = rt_call mutate(%5) void"),
                     new.replace(b"bb3(%12: i64):", b"bb3(%12: i64):\n  %30 = rt_call mutate(%5) void")),
    "outside function": (old + b"\nmodule %10", new + b"\nmodule %11"),
    "separated reader": (old.replace(b"  %14 = rt_call", b"\n  %14 = rt_call"), new),
    "no transform": (new, new),
}
symbol = b"\nfunc helper%80() void {\nbb0():\n  ret\n}"
negatives.update({
    "function symbol": (old + symbol, new + symbol.replace(b"helper%80", b"helper%81")),
    "percent-leading function": (old + symbol.replace(b"helper%80", b"%80"),
                                 new + symbol.replace(b"helper%80", b"%81")),
    "callee symbol": (old + symbol.replace(b"  ret", b"  %0 = call @callee%80() void\n  ret"),
                      new + symbol.replace(b"  ret", b"  %0 = call @callee%81() void\n  ret")),
    "type symbol": (old + symbol.replace(b"() void", b"(%0: Type%80) void"),
                    new + symbol.replace(b"() void", b"(%0: Type%81) void")),
    "local symbol": (old + symbol.replace(b"  ret", b"  %0 = field_get %1[local%80] i64\n  ret"),
                     new + symbol.replace(b"  ret", b"  %0 = field_get %1[local%81] i64\n  ret")),
    "numeric adjacency": (old + symbol.replace(b"  ret", b"  %0 = const_int i64 1%80\n  ret"),
                          new + symbol.replace(b"  ret", b"  %0 = const_int i64 1%81\n  ret")),
    "trailing identifier": (old + symbol.replace(b"  ret", b"  %0 = ret %80foo\n  ret"),
                            new + symbol.replace(b"  ret", b"  %0 = ret %81foo\n  ret")),
})
for name, pair in negatives.items():
    assert verdict(*pair) == (1, b""), name
for kind in ("ir", "types", "ast", "fmt", "diags", "tokens", "doc"):
    assert verdict(old, new, kind) == (1, b""), kind
print("8259 structural signature: 2 positive, 30 negative, 7 kind controls passed")
PYTHON
  rc=$?
  [ "$rc" -eq 0 ] || fail=1

  # #7931: the shared IR probe must distinguish unsupported lowering from
  # absent tools, failed execution, stale objects and unrelated diagnostics.
  probe_dir=$(mktemp -d "${TMPDIR:-/tmp}/t7931-probe.XXXXXX") || exit 2
  trap 'rm -rf "${probe_dir:?}"' EXIT
  ORACLE="$probe_dir/compiler"
  TIMEOUT=300
  cat > "$ORACLE" <<'PROBE'
#!/usr/bin/env bash
source=$2
refusal() {
  printf 'bit: %s: refusing to emit an object\n' "$source"
  printf 'error[E0092]: unsupported lowering\n --> %s:1:1\n  |\n1 | source\n  | ^\n' "$source"
}
if [ "$1" = check ]; then
  case "$PROBE_CASE" in
    check-decline) echo 'error[E0053]: rejected'; exit 1 ;;
    check-panic) echo 'panic: failed'; exit 2 ;;
    check-timeout) exit 142 ;;
    check-signal) kill -TERM "$$" ;;
    check-127) exit 127 ;;
    check-warning) echo 'warning: accepted' ;;
    check-success-panic) echo 'panic: failed'; exit 0 ;;
  esac
  exit 0
fi
if [ "$PROBE_CASE" = host-target ]; then
  for arg in "$@"; do
    case "$arg" in --target|--target=*) exit 86 ;; esac
  done
fi
while [ "$#" -gt 0 ]; do
  if [ "$1" = -o ]; then object=$2; break; fi
  shift
done
case "$PROBE_CASE" in
  success|check-warning) printf object > "$object"; exit 0 ;;
  object-warning) printf object > "$object"; echo 'warning: accepted'; exit 0 ;;
  object-success-panic) printf object > "$object"; echo 'panic: failed'; exit 0 ;;
  no-object) exit 0 ;;
  refusal|stale|host-target) refusal; exit 1 ;;
  notes) refusal; printf "note: while emitting 'f<i64>', instantiated here\n --> %s:2:1\n" "$source"; exit 1 ;;
  mixed) refusal; echo 'error[E0053]: unrelated'; exit 1 ;;
  wrong-source) source=wrong.bit; refusal; exit 1 ;;
  wrong-location) printf 'bit: %s: refusing to emit an object\nerror[E0092]: unsupported\n --> wrong.bit:1:1\n' "$source"; exit 1 ;;
  malformed-location) printf 'bit: %s: refusing to emit an object\nerror[E0092]: unsupported\n --> %s\n' "$source" "$source"; exit 1 ;;
  missing-location) printf 'bit: %s: refusing to emit an object\nerror[E0092]: unsupported\n' "$source"; exit 1 ;;
  panic) refusal; echo 'panic: failed'; exit 1 ;;
  object-refusal) printf object > "$object"; refusal; exit 1 ;;
  other-error) echo 'error[E0053]: unrelated'; exit 1 ;;
  status-126) exit 126 ;;
  status-127) exit 127 ;;
  timeout) exit 142 ;;
  signal) kill -TERM "$$" ;;
esac
PROBE
  chmod +x "$ORACLE"
  for row in 'success:ok' 'no-object:undecided' 'refusal:decline' 'host-target:decline' 'notes:decline' \
    'stale:decline' 'mixed:undecided' 'wrong-source:undecided' 'wrong-location:undecided' \
    'malformed-location:undecided' 'missing-location:undecided' \
    'panic:undecided' 'object-refusal:undecided' 'other-error:undecided' \
    'status-126:undecided' 'status-127:undecided' 'timeout:undecided' 'signal:undecided' \
    'check-decline:decline' 'check-panic:undecided' 'check-timeout:undecided' \
    'check-signal:undecided' 'check-127:undecided' 'check-warning:ok' 'object-warning:ok' \
    'check-success-panic:undecided' 'object-success-panic:undecided'; do
    PROBE_CASE=${row%%:*}; export PROBE_CASE
    printf stale > "$probe_dir/oracle-object.o"
    status=$(oracle_ir_coverage "$probe_dir/input.bit" "$probe_dir")
    expect "${row#*:}" "$status" "oracle coverage: $PROBE_CASE"
    case "$status" in
      ok) mismatch=1; undecided=0 ;;
      decline) mismatch=0; undecided=0 ;;
      *) mismatch=0; undecided=1 ;;
    esac
    (diffexit probe -f "$mismatch" -t "probe=$undecided") >/dev/null
    rc=$?
    case "${row#*:}" in
      ok) expect 1 "$rc" 'lowerable unexplained difference stays red' ;;
      decline) expect 0 "$rc" 'actual refusal is coverage' ;;
      *) expect 2 "$rc" 'failed probe never passes' ;;
    esac
  done
  chmod -x "$ORACLE"
  expect undecided "$(oracle_ir_coverage input.bit "$probe_dir")" 'nonexecutable oracle'
  ORACLE="$probe_dir/missing"
  expect undecided "$(oracle_ir_coverage input.bit "$probe_dir")" 'missing oracle'
  unset ORACLE PROBE_CASE

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
  want=$(grep -oE 'print[ (]+"[0-9]+-[a-z-]+"' "${ROOT}/scripts/selfhost-ir-signatures.sh" |
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
