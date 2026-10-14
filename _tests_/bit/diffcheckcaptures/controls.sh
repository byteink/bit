#!/usr/bin/env bash
# #8129: exercise real capture code with tiny, deterministic fake checkers.
set -eu
root=$1
scratch=$2

fail() { echo "diffcheckcaptures: $*" >&2; exit 1; }

fixture() {
  local d=$1
  mkdir -p "$d/scripts" "$d/bit-out/bin" "$d/stdlib" "$d/examples" \
    "$d/_tests_/cases" "$d/_tests_/imports" "$d/tmp" "$d/fakebin"
  cp "$root/scripts/selfhost-diffcheck.sh" "$root/scripts/alarmrun.sh" \
    "$root/scripts/diffexit.sh" "$d/scripts/"
  printf 'printf "%%s\\n" "%s/oracle"\n' "$d" >"$d/scripts/stage0.sh"
  printf '// run\n' >"$d/_tests_/cases/a.bit"
  printf '// run\n' >"$d/_tests_/cases/b.bit"
  cat >"$d/oracle" <<'CHECKER'
#!/bin/sh
casefile=$(basename "$2")
countfile="$0.$casefile.count"
n=0
[ ! -f "$countfile" ] || n=$(cat "$countfile")
n=$((n + 1))
printf '%s\n' "$n" >"$countfile"
case "$CAPTURE_MODE" in
  normal) exit 0 ;;
  empty) [ "$n" -ne 1 ] || exit 142; exit 0 ;;
  recompare|finaldiff)
    limit=1
    [ "$CAPTURE_MODE" != finaldiff ] || limit=2
    if [ "$n" -le "$limit" ]; then printf '%s\n' "$0" >&2; exit 1; fi ;;
  firstfp)
    case "$0" in */oracle) exit 0 ;; esac
    [ "$n" -ne 1 ] || { printf 'rejected\n' >&2; exit 1; } ;;
  priority)
    if [ "$casefile" = a.bit ]; then
      case "$0" in */oracle) exit 0 ;; esac
      printf 'rejected\n' >&2; exit 1
    fi ;;
esac
printf '\000\377attempt-%s' "$n" >&2
case "$CAPTURE_MODE" in
  double|priority|recompare|finaldiff|firstfp) exit 142 ;;
esac
[ "$n" -ne 1 ] || exit 142
exit 0
CHECKER
  cp "$d/oracle" "$d/bit-out/bin/bit"
  chmod 700 "$d/oracle" "$d/bit-out/bin/bit"
  cat >"$d/fakebin/cp" <<'COPY'
#!/bin/sh
case "$2" in */1.stderr) exit 1 ;; esac
exec /bin/cp "$@"
COPY
  chmod 700 "$d/fakebin/cp"
  printf '#!/bin/sh\nexit 1\n' >"$d/fakebin/base64"
  chmod 700 "$d/fakebin/base64"
}

run_case() {
  local mode=$1 expected=$2 capturefail=$3 d="$scratch/$1" rc
  fixture "$d"
  if [ "$capturefail" = 1 ]; then
    (cd "$d"; CAPTURE_MODE="$mode" TMPDIR="$d/tmp" PATH="$d/fakebin:$PATH" \
      bash scripts/selfhost-diffcheck.sh) >"$d/log" 2>&1 && rc=0 || rc=$?
  elif [ "$capturefail" = 2 ]; then
    rm "$d/fakebin/cp"
    (cd "$d"; CAPTURE_MODE="$mode" TMPDIR="$d/tmp" PATH="$d/fakebin:$PATH" \
      bash scripts/selfhost-diffcheck.sh) >"$d/log" 2>&1 && rc=0 || rc=$?
  else
    (cd "$d"; CAPTURE_MODE="$mode" TMPDIR="$d/tmp" \
      bash scripts/selfhost-diffcheck.sh) >"$d/log" 2>&1 && rc=0 || rc=$?
  fi
  printf '%s\n' "$rc" >"$d/native.rc"
  [ "$rc" -eq "$expected" ] || fail "$mode: exit $rc, want $expected"
}

decode_frames() {
  local d=$1
  awk -v dir="$d" '
    /^BEGIN CHECKER_CAPTURE / { i++; print > (dir "/frame" i ".header"); state=""; next }
    /^ARGV_BASE64$/ { state="argv"; printf "" > (dir "/frame" i ".argv.base64"); next }
    /^STDERR_BASE64$/ { state="stderr"; printf "" > (dir "/frame" i ".stderr.base64"); next }
    /^END CHECKER_CAPTURE$/ { state=""; next }
    state != "" && $0 != "" { print > (dir "/frame" i "." state ".base64") }
    END { print i+0 > (dir "/frames.count") }
  ' "$d/archived.log"
}

expected_code() {
  if [ "$2" -eq 2 ]; then
    case "$1" in recover|empty|parent-recover) echo 0; return ;; esac
  fi
  echo 142
}

check_frame() {
  local d=$1 i=$2 header attempt provider bytes rc
  header=$(cat "$d/frame$i.header")
  attempt=2
  case "$header" in *attempt=1*) attempt=1 ;; esac
  provider=bit-out/bin/bit
  case "$header" in *side=ORACLE*) provider="$d/oracle" ;; esac
  perl -MMIME::Base64 -ne 'print decode_base64($_)' \
    "$d/frame$i.stderr.base64" >"$d/frame$i.stderr"
  perl -MMIME::Base64 -ne 'print decode_base64($_)' \
    "$d/frame$i.argv.base64" >"$d/frame$i.argv"
  case "$(basename "$d")" in
    empty) : >"$d/expected.stderr" ;;
    *) printf '\000\377attempt-%s' "$attempt" >"$d/expected.stderr" ;;
  esac
  cmp "$d/expected.stderr" "$d/frame$i.stderr" || fail "lost stderr bytes"
  bytes=$(wc -c <"$d/frame$i.stderr")
  case "$header" in *"stderr_bytes=$((bytes)) "*) ;; *) fail "wrong byte count" ;; esac
  bytes=$(wc -c <"$d/frame$i.argv")
  case "$header" in *"argv_bytes=$((bytes)) "*) ;; *) fail "wrong argv byte count" ;; esac
  printf '%s\0' "$provider" check _tests_/cases/a.bit >"$d/expected.argv"
  if ! cmp -s "$d/expected.argv" "$d/frame$i.argv"; then
    printf '%s\0' "$provider" check _tests_/cases/b.bit >"$d/expected.argv"
    cmp "$d/expected.argv" "$d/frame$i.argv" || fail "lost argv bytes"
  fi
  rc=$(expected_code "$(basename "$d")" "$attempt")
  case "$header" in *"native_rc=$rc "*) ;; *) fail "wrong native exit code" ;; esac
}

check_frames() {
  local d=$1 expected=$2 n i
  cp "$d/log" "$d/archived.log"
  # Archived frames must still reconstruct the bytes after container/TMP loss.
  rm -rf "${d:?}/tmp"
  decode_frames "$d"
  n=$(cat "$d/frames.count")
  [ "$n" -eq "$expected" ] || fail "frames $n, want $expected"
  for ((i=1; i<=n; i++)); do check_frame "$d" "$i"; done
}

check_capture_failure() {
  local mode=$1
  run_case "$mode" 2 1
  grep -q 'UNDECIDED: checker capture failed' "$scratch/$mode/log" || fail "lost capture failure"
  ! grep -q 'MATCH=[1-9]' "$scratch/$mode/log" || fail "capture failure scored MATCH"
}

check_parent() {
  local mode=$1 d="$scratch/parent-$1" rc keep
  fixture "$d"
  cp "$root/scripts/selfhost-diffall.sh" "$d/scripts/"
  : >"$d/absent"
  (cd "$d"; CAPTURE_MODE="$mode" TMPDIR="$d/tmp" DIFFALL_DIR=scripts \
    DIFFALL_MIN=1 DIFFALL_JOBS=1 DIFFALL_ABSENT="$d/absent" \
    bash scripts/selfhost-diffall.sh) >"$d/parent.log" 2>&1 && rc=0 || rc=$?
  printf '%s\n' "$rc" >"$d/native.rc"
  [ "$rc" -eq 0 ] || fail "parent $mode: exit $rc"
  grep -q 'diffall: PASS=1 FAIL=0 INCONCLUSIVE=0 TIMEOUT=0 ABSENT=0' "$d/parent.log" || fail "parent verdict changed"
  keep=$(sed -n 's/^full logs for every failing\/undecided constituent kept: //p' "$d/parent.log")
  if [ "$mode" = normal ]; then
    [ -z "$keep" ] || fail "normal parent retained payload"
    return
  fi
  [ -n "$keep" ] || fail "parent discarded recovered capture log"
  cp "$keep/selfhost-diffcheck.sh.log" "$d/kept-child.log"
  [ "$(grep -c '^END CHECKER_CAPTURE$' "$d/kept-child.log")" -eq 8 ] || fail "parent kept incomplete frames"
  cp "$d/parent.log" "$d/log"
  check_frames "$d" 8
}

run_case recover 0 0
check_frames "$scratch/recover" 8
run_case empty 0 0
check_frames "$scratch/empty" 8
run_case double 2 0
grep -q 'timeout: _tests_/cases/a.bit (seed=142 bit=142)' "$scratch/double/log" || fail "lost input a"
grep -q 'timeout: _tests_/cases/b.bit (seed=142 bit=142)' "$scratch/double/log" || fail "lost input b"
check_frames "$scratch/double" 8
run_case normal 0 0
[ -z "$(find "$scratch/normal/tmp" -name 'selfhost-diffcheck-attempt.*' -print)" ] || fail "normal run retained captures"
check_frames "$scratch/normal" 0
run_case priority 1 0
check_capture_failure copyfail
check_capture_failure recompare
check_capture_failure firstfp
check_capture_failure finaldiff
run_case base64fail 2 2
! grep -q 'MATCH=[1-9]' "$scratch/base64fail/log" || fail "encoder failure scored MATCH"
check_parent recover
check_parent normal
echo 'diffcheckcaptures: PASS (binary/empty recovery, double alarm, both inputs, normal, priority, four capture-failure paths, encoder failure, parent retention)'
