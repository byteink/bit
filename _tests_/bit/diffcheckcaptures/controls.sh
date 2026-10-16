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
  normal|malformednormal) exit 0 ;;
  native7) exit 7 ;;
  native125) exit 125 ;;
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
case "$2" in
  */1.stderr) [ "$CAPTURE_MODE" = copytimefail ] || exit 1 ;;
  */1.time) [ "$CAPTURE_MODE" != copytimefail ] || exit 1 ;;
esac
exec /bin/cp "$@"
COPY
  chmod 700 "$d/fakebin/cp"
  printf '#!/bin/sh\nexit 1\n' >"$d/fakebin/base64"
  chmod 700 "$d/fakebin/base64"
  # Faults affect only this copied fixture, after the checker returns.
  sed 's/^alarmrun() {/fixture_alarmrun() {/' "$d/scripts/alarmrun.sh" >"$d/scripts/alarmrun.copy"
  mv "$d/scripts/alarmrun.copy" "$d/scripts/alarmrun.sh"
  cat >>"$d/scripts/alarmrun.sh" <<'TIMING'
alarmrun() {
  local code
  fixture_alarmrun "$@"
  code=$?
  case "$CAPTURE_MODE" in
    missingtime) rm -f "$cap.time" ;;
    malformedtime|malformednormal) TIMEFORMAT='not timing' ;;
    malformedretry) [ "$code" -ne 0 ] || TIMEFORMAT='not timing' ;;
    extratime) TIMEFORMAT=$'wall_seconds=%3R user_seconds=%3U system_seconds=%3S\nextra' ;;
  esac
  return "$code"
}
TIMING
}

run_case() {
  local mode=$1 expected=$2 capturefail=$3 d="$scratch/$1" rc runpath=$PATH
  fixture "$d"
  if [ "$capturefail" != 0 ]; then runpath="$d/fakebin:$PATH"; fi
  case "$capturefail" in
    2) rm "$d/fakebin/cp" ;;
    3)
    cat >"$d/fakebin/rm" <<'REMOVE'
#!/bin/sh
case "$2" in *.attemptdir) mkdir "$2.time"; mv "$2.time" "${2%.attemptdir}.time" ;; esac
exec /bin/rm "$@"
REMOVE
    chmod 700 "$d/fakebin/rm"
    rm "$d/fakebin/cp" "$d/fakebin/base64" ;;
  esac
  (cd "$d"; CAPTURE_MODE="$mode" TMPDIR="$d/tmp" PATH="$runpath" \
    bash scripts/selfhost-diffcheck.sh) >"$d/log" 2>&1 && rc=0 || rc=$?
  printf '%s\n' "$rc" >"$d/native.rc"
  [ "$rc" -eq "$expected" ] || fail "$mode: exit $rc, want $expected"
}

decode_frames() {
  local d=$1
  awk -v dir="$d" '
    /^BEGIN CHECKER_CAPTURE / { i++; print > (dir "/frame" i ".header"); state=""; next }
    /^ARGV_BASE64$/ { state="argv"; printf "" > (dir "/frame" i ".argv.base64"); next }
    /^STDERR_BASE64$/ { state="stderr"; printf "" > (dir "/frame" i ".stderr.base64"); next }
    /^TIMING_BASE64$/ { state="time"; printf "" > (dir "/frame" i ".time.base64"); next }
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

check_timing_frame() {
  local d=$1 i=$2
  perl -MMIME::Base64 -ne 'print decode_base64($_)' \
    "$d/frame$i.time.base64" >"$d/frame$i.time"
  cmp "$d/expected-time$i" "$d/frame$i.time" || fail "lost timing bytes"
  grep -Eq '^wall_seconds=[0-9]+[.,][0-9]{3} user_seconds=[0-9]+[.,][0-9]{3} system_seconds=[0-9]+[.,][0-9]{3}$' \
    "$d/frame$i.time" || fail "invalid timing record"
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
  check_timing_frame "$d" "$i"
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
  local d=$1 expected=$2 n i timing
  cp "$d/log" "$d/archived.log"
  awk '/^BEGIN CHECKER_CAPTURE / { for (i=1;i<=NF;i++) if ($i ~ /^raw=/) dir=substr($i,5); for (i=1;i<=NF;i++) if ($i ~ /^attempt=/) attempt=substr($i,9); print dir "/" attempt ".time" }' \
    "$d/log" >"$d/timing-paths"
  for ((i=1; i<=expected; i++)); do
    IFS= read -r timing || fail "missing raw timing path"
    cp "$timing" "$d/expected-time$i"
  done <"$d/timing-paths"
  # Archived frames must still reconstruct the bytes after container/TMP loss.
  rm -rf "${d:?}/tmp"
  decode_frames "$d"
  n=$(cat "$d/frames.count")
  [ "$n" -eq "$expected" ] || fail "frames $n, want $expected"
  for ((i=1; i<=n; i++)); do check_frame "$d" "$i"; done
}

check_timing_failure() {
  local mode=$1 native=${2:-142} d="$scratch/$1" dir provider
  run_case "$mode" 2 0
  grep -q 'UNDECIDED: checker capture failed (oracle wrapper=125 bit wrapper=125)' "$d/log" || fail "lost timing failure"
  for provider in oracle bit-out/bin/bit; do
    [ "$(cat "$d/$provider.a.bit.count")" -eq 1 ] || fail "timing failure retried"
  done
  for dir in "$d"/tmp/selfhost-diffcheck-attempt.*; do
    [ "$(cat "$dir/1.rc")" -eq "$native" ] || fail "lost native status"
    if [ "$native" -eq 0 ]; then : >"$d/expected.stderr"; else printf '\000\377attempt-1' >"$d/expected.stderr"; fi
    cmp "$d/expected.stderr" "$dir/1.stderr" || fail "lost raw failed attempt"
    [ -s "$dir/1.argv" ] || fail "lost raw failed argv"
    [ ! -e "$dir/2.rc" ] || fail "timing failure added retry"
  done
}

check_capture_failure() {
  local mode=$1
  run_case "$mode" 2 1
  grep -q 'UNDECIDED: checker capture failed' "$scratch/$mode/log" || fail "lost capture failure"
  ! grep -q 'MATCH=[1-9]' "$scratch/$mode/log" || fail "capture failure scored MATCH"
}

check_retry_attempt() {
  local dir=$1 attempt=$2 native=$3
  [ "$(cat "$dir/$attempt.rc")" -eq "$native" ] || fail "lost retry native status"
  printf '\000\377attempt-%s' "$attempt" >"$scratch/expected-retry.stderr"
  cmp "$scratch/expected-retry.stderr" "$dir/$attempt.stderr" || fail "lost retry stderr"
  [ -s "$dir/$attempt.argv" ] || fail "lost retry argv"
}

check_retry_timing_failure() {
  local d="$scratch/malformedretry" dir provider
  run_case malformedretry 2 0
  grep -q 'oracle wrapper=125 bit wrapper=125' "$d/log" || fail "lost retry timing failure"
  for provider in oracle bit-out/bin/bit; do
    [ "$(cat "$d/$provider.a.bit.count")" -eq 2 ] || fail "wrong retry count"
  done
  for dir in "$d"/tmp/selfhost-diffcheck-attempt.*; do
    check_retry_attempt "$dir" 1 142
    check_retry_attempt "$dir" 2 0
    grep -Eq '^wall_seconds=[0-9]+[.,][0-9]{3} user_seconds=[0-9]+[.,][0-9]{3} system_seconds=[0-9]+[.,][0-9]{3}$' \
      "$dir/1.time" || fail "lost valid first timing"
    [ "$(cat "$dir/2.time")" = 'not timing' ] || fail "lost malformed second timing"
    [ ! -e "$dir/3.rc" ] || fail "added third attempt"
  done
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

observer_fixture() {
  local d=$1
  cat >"$d/fakebin/python3" <<'OBSERVER'
#!/bin/bash
set -eu
[ "$#" -eq 7 ] && [ "$1" = trusted-observer ] && [ "$2" = --stock-pair ] || exit 99
[ "$3" = _tests_/cases/jsx_bool_attr.bit ] || exit 99
[ "$6" = "$OBSERVER_ROOT/oracle" ] && [ "$7" = bit-out/bin/bit ] || exit 99
[ "${4%/*}" = "${5%/*}" ] || exit 99
printf 'called\n' >>observer.calls
printf 'same\000bytes' >"$4"
printf 'same\000bytes' >"$5"
status="${4%/*}/observer-pair.status"
case "$OBSERVER_MODE" in
  success) printf 'ORACLE 0 BIT2 0 0\n' >"$status" ;;
  alarm) printf 'ORACLE 142 BIT2 142 0\n' >"$status" ;;
  native125) printf 'ORACLE 125 BIT2 125 0\n' >"$status" ;;
  reject) printf 'ORACLE 7 BIT2 7 0\n' >"$status" ;;
  exit) printf 'ORACLE 0 BIT2 0 0\n' >"$status"; exit 1 ;;
  missing) : ;;
  *) printf '%b' "$OBSERVER_STATUS" >"$status" ;;
esac
OBSERVER
  chmod 700 "$d/fakebin/python3"
}

run_observer_case() {
  local mode=$1 expected=$2 status=${3:-} d="$scratch/observer-$1" rc
  fixture "$d"
  observer_fixture "$d"
  printf '// run\n' >"$d/_tests_/cases/jsx_bool_attr.bit"
  (cd "$d"; CAPTURE_MODE=normal OBSERVER_MODE="$mode" OBSERVER_STATUS="$status" OBSERVER_ROOT="$d" \
    DIFFCHECK_OBSERVER=trusted-observer TMPDIR="$d/tmp" PATH="$d/fakebin:$PATH" \
    bash scripts/selfhost-diffcheck.sh) >"$d/log" 2>&1 && rc=0 || rc=$?
  printf '%s\n' "$rc" >"$d/native.rc"
  [ "$rc" -eq "$expected" ] || fail "observer $mode: exit $rc, want $expected"
  check_observer_calls "$d"
  check_observer_verdict "$d" "$mode"
}

check_observer_calls() {
  local d=$1 provider
  # Only the selected pair is delegated; every other fake checker still runs.
  [ "$(cat "$d/observer.calls")" = called ] || fail "observer not called exactly once"
  for provider in oracle bit-out/bin/bit; do
    [ "$(cat "$d/$provider.a.bit.count")" = 1 ] || fail "unselected a changed"
    [ "$(cat "$d/$provider.b.bit.count")" = 1 ] || fail "unselected b changed"
    [ ! -e "$d/$provider.jsx_bool_attr.bit.count" ] || fail "selected checker ran outside observer"
  done
}

check_observer_verdict() {
  local d=$1
  case "$2" in
    success|reject) grep -q 'MATCH=3 .*TIMEOUT=0' "$d/log" || fail "observer verdict lost" ;;
    alarm) grep -q 'MATCH=2 .*TIMEOUT=1' "$d/log" || fail "observer alarm scored verdict" ;;
    *)
      grep -q 'UNDECIDED: checker capture failed' "$d/log" || fail "observer failure not undecided"
      ! grep -q '^check differential:' "$d/log" || fail "observer failure reached grader" ;;
  esac
}

check_unselected_observer() {
  local d="$scratch/observer-unselected" rc
  fixture "$d"
  observer_fixture "$d"
  (cd "$d"; CAPTURE_MODE=normal DIFFCHECK_OBSERVER=trusted-observer \
    TMPDIR="$d/tmp" PATH="$d/fakebin:$PATH" bash scripts/selfhost-diffcheck.sh) \
    >"$d/log" 2>&1 && rc=0 || rc=$?
  [ "$rc" -eq 0 ] && [ ! -e "$d/observer.calls" ] || fail "unselected input invoked observer"
  grep -q 'MATCH=2 .*TIMEOUT=0' "$d/log" || fail "unselected comparison changed"
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
check_timing_failure missingtime
check_timing_failure malformedtime
check_timing_failure extratime
check_timing_failure malformednormal 0
check_retry_timing_failure
check_capture_failure copytimefail
run_case redirecttime 2 3
for provider in oracle bit-out/bin/bit; do
  [ ! -e "$scratch/redirecttime/$provider.a.bit.count" ] || fail "timing redirection ran checker"
done
for dir in "$scratch/redirecttime"/tmp/selfhost-diffcheck-attempt.*; do
  [ "$(cat "$dir/1.rc")" = UNKNOWN ] || fail "invented native code"
done
run_case native125 2 0
grep -q 'oracle wrapper=125 bit wrapper=125' "$scratch/native125/log" || fail "native125 changed"
run_case native7 0 0
check_frames "$scratch/native7" 0
check_parent recover
check_parent normal
run_observer_case success 0
run_observer_case reject 0
run_observer_case alarm 2
run_observer_case native125 2
run_observer_case exit 2
run_observer_case missing 2
run_observer_case extra 2 'ORACLE 0 BIT2 0 0\nextra\n'
run_observer_case partial 2 'ORACLE 0 BIT2 0 0\nextra'
run_observer_case huge 2 'ORACLE 256 BIT2 0 0\n'
run_observer_case malformed 2 'ORACLE zero BIT2 0 0\n'
run_observer_case failed 2 'ORACLE 0 BIT2 0 1\n'
check_unselected_observer
echo 'diffcheckcaptures: PASS (lossless stderr/argv/timing, recovery, double alarm, capture faults, unknown native status, parent retention, selected observer contract)'
