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
# The 0.42.0 repin retired the former identities (#8178).
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
    expect "" "$(declaredSignatureNames "$kind")" "empty $kind registry after repin"
  done

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
