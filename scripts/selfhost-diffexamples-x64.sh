#!/usr/bin/env bash
# x86_64-linux behavioural differential (#1346): build every example with BOTH
# compilers for x86_64-linux, run both on a real x86-64 box, and diff the
# printed output. This is the only end-to-end guard the x64 backend has — the
# dump differentials compare check/lower, which are shared, so a codegen bug is
# invisible to them (see selfhost-diffexamples.sh for the arm64/macOS twin).
#
# Needs an x86-64 Linux host reachable over ssh. No hostname is baked into the
# repo: set BITX64_HOST, or configure candidates for scripts/x64host.sh.
#
# The two LOCAL `build` calls below (compiling before the binaries are scp'd to
# the remote host) are alarm-guarded (#2866): neither had a bound before, so a
# hung ORACLE or BIT2 build wedged this script indefinitely — the same shape
# selfhost-diffcheck.sh's header warns about. The remote *run* step already
# bounds itself (`timeout 30 ...`, below) and is untouched by this.
#
# Usage: ./make selfhost && bash scripts/selfhost-diffexamples-x64.sh
set -u
# shellcheck source=scripts/alarmrun.sh
. "$(dirname -- "$0")/alarmrun.sh"
# shellcheck source=scripts/diffexit.sh
. "$(dirname -- "$0")/diffexit.sh"
# Oracle: the pinned stage0 -- the same compiler one release back, an EARLIER
# VERSION OF THIS SAME COMPILER, which is exactly what limits the claim below.
# scripts/stage0.sh downloads and DIGEST-VERIFIES it, and refuses rather
# than skipping. A green run proves no behaviour change versus the last
# release; it cannot catch a bug present in both — docs/release/bootstrap.md §4/§5.
ORACLE="$(sh scripts/stage0.sh)" || exit 2
BIT2=${BIT2:-bit-out/bin/bit}

# 60s matches selfhost-diffexamples.sh's own build+run budget for this same
# corpus; DIFFEXAMPLESX64_TIMEOUT overrides for a slower host. Do not go below
# ~12s on a shared box: #2863's mutation run at a 3s bound produced 11 false
# timeouts from ordinary machine load, redone at 12-20s.
TIMEOUT=${DIFFEXAMPLESX64_TIMEOUT:-60}
HOST=${BITX64_HOST:-$(bash "$(dirname "$0")/x64host.sh")}
[ -n "$HOST" ] || exit 127
echo "diffexamples-x64: host=$HOST"
# Both sides link the WORKING TREE's x86_64-linux runtime, not the stage0
# tarball's — see scripts/selfhost-diffexamples.sh for why, and why this cannot
# live in the stage0 wrapper (BIT_LIBBITRT names one archive for one triple, and
# this script cross-compiles).
X64_RT=bit-out/lib/x86_64-linux/libbitrt.a
[ -f "$X64_RT" ] || { echo "diffexamples-x64: missing $X64_RT — run: ./make libbitrt" >&2; exit 2; }
export BIT_LIBBITRT="$PWD/$X64_RT"

REMOTE=/tmp/bitdiff-x64
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"; ssh "$HOST" "rm -rf $REMOTE" >/dev/null 2>&1' EXIT

ssh "$HOST" "rm -rf $REMOTE && mkdir -p $REMOTE" || { echo "cannot reach $HOST"; exit 1; }

# The same list selfhost-diffexamples.sh skips: these need constructs bit2
# cannot lower yet (closures/spawn), so they refuse on EVERY target — they are
# not an x64 gap, and counting them here would just mask a real one appearing.
SKIP="h3fetch httpserver httpsserver http2server tlsclient"

pass=0 diff=0 refused=0 oraclefail=0 skipped=0 scpfail=0 oracletimeout=0 bit2timeout=0
for d in examples/*/; do
  n=$(basename "$d")
  case " $SKIP " in *" $n "*) skipped=$((skipped + 1)); continue;; esac
  # Verdict-deciding (#3422): the local build decides ORACLE-FAIL/REFUSED
  # before anything reaches the remote host, so a single stall must not turn a
  # real build into a false timeout. outfile is the compiler's own -o target
  # (safe to rm-f between attempts, unlike the >"$TMP/oerr_$n" log capture).
  ALARMRUN_KEEP_STDERR=1 alarmrun_retry ORACLE "$TMP/oracle_$n" "$ORACLE" build "$d" -o "$TMP/oracle_$n" --target x86_64-linux >"$TMP/oerr_$n" 2>&1
  rc=$?
  if [ "$rc" -eq 142 ]; then
    oracletimeout=$((oracletimeout + 1)); echo "ORACLE timed out after ${TIMEOUT}s: $n"; continue
  fi
  if [ "$rc" -ne 0 ]; then
    oraclefail=$((oraclefail + 1)); echo "ORACLE-FAIL $n"; continue
  fi
  ALARMRUN_KEEP_STDERR=1 alarmrun_retry BIT2 "$TMP/b2_$n" "$BIT2" build "$d" -o "$TMP/b2_$n" --target x86_64-linux >"$TMP/berr_$n" 2>&1
  rc=$?
  if [ "$rc" -eq 142 ]; then
    bit2timeout=$((bit2timeout + 1)); echo "BIT2 timed out after ${TIMEOUT}s: $n"; continue
  fi
  if [ "$rc" -ne 0 ]; then
    refused=$((refused + 1)); echo "REFUSED $n: $(head -1 "$TMP/berr_$n")"; continue
  fi
  # A failed transfer is a failure, not a silent skip: it printed SCP-FAIL and
  # then fell through to a verdict that never looked at it, so a run where EVERY
  # example failed to reach the host still exited 0 (#1513). Nothing was compared;
  # that cannot read as agreement.
  scp -q "$TMP/oracle_$n" "$TMP/b2_$n" "$HOST:$REMOTE/" || { echo "SCP-FAIL $n"; scpfail=$((scpfail + 1)); continue; }
  so=$(ssh "$HOST" "cd $REMOTE && chmod +x oracle_$n b2_$n && timeout 30 ./oracle_$n 2>&1; echo EXIT=\$?")
  bo=$(ssh "$HOST" "cd $REMOTE && timeout 30 ./b2_$n 2>&1; echo EXIT=\$?")
  if [ "$so" = "$bo" ]; then
    pass=$((pass + 1))
  else
    diff=$((diff + 1))
    echo "DIFF $n"
    echo "--- oracle: $so" | head -5
    echo "--- bit2: $bo" | head -5
  fi
done
echo "x86_64-linux example differential: PASS=$pass DIFF=$diff REFUSED=$refused ORACLE-FAIL=$oraclefail ORACLE-TIMEOUT=$oracletimeout BIT2-TIMEOUT=$bit2timeout SCP-FAIL=$scpfail SKIP(unported)=$skipped"

# A phase that measured nothing must not pass (#1514). On an empty corpus the
# loop runs zero comparisons and every counter below is 0 for the wrong reason.
#
# exit 1, not 2: by the time this floor is reached, the no-host precondition
# above (`[ -n "$HOST" ] || exit 127`) has already passed, so a reachable host
# that still compared nothing means every build failed, every scp failed, or
# the example corpus was empty -- the harness itself is broken, not a
# legitimate skip. Per the reasoning #3380 established for
# selfhost-diffruntime.sh's four floors (and #3402 applied to this file's
# sibling, selfhost-diffdump.sh's run_basic()): selfhost-diffall.sh's ABSENT
# mechanism excuses exit 2 for a constituent listed in
# scripts/selfhost-diffall.absent, and this floor has no "surface not
# implemented yet" case the way selfhost-difffmt.sh's or
# selfhost-diffdoc.sh's capability probes do. Exit 2 would let a future
# ABSENT-list entry silently tolerate that; exit 1 cannot ever be excused.
if [ "$pass" -lt 1 ]; then
  echo "FATAL: the x86_64 example differential compared nothing (PASS=$pass)." >&2
  exit 1
fi

# A real divergence wins over an undecided count: any observed mismatch or
# failure is evidence, regardless of how many builds elsewhere also timed out.
diffexit "examples-x64" -f "$diff" "$oraclefail" "$refused" "$scpfail" \
  -t "ORACLE build(s)=$oracletimeout" "BIT2 build(s)=$bit2timeout"
