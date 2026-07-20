#!/usr/bin/env bash
# Self-host BEHAVIOURAL differential (#1346): build every example with both
# compilers and compare what the programs actually PRINT, not what the compiler
# dumps.
#
# The --dump-types/--dump-ir differentials compare the compiler's own view of a
# program, so a bug that is consistent between check and lower is invisible to
# them: bit2 once typed `mapped<i64,i64>(...)`'s result as `[]T` with `T`
# unsubstituted, emitted a binary happily, and printed 0 instead of 56. Only
# running the output catches that class. This is the end-to-end guard.
#
# A REFUSED example is a known lowering gap (main.bit's stub guard declining to
# emit a binary): an honest "not ported yet", not a miscompile. It is therefore
# tolerated — but only up to a PINNED COUNT (#1424).
#
# Tolerating refusals unconditionally is what a mid-flight port relies on, and
# is also how a real regression hides: #1419 reverted the selfhost half of its
# own variadic fix and the only signal was PASS dropping 42->41 with the script
# still exiting 0. That conflates "not ported yet" with "regressed", for every
# example. So the count is pinned and compared EXACTLY:
#
#   - refusals ABOVE the pin  -> a construct that used to lower no longer does.
#   - refusals BELOW the pin  -> good news, but the pin must be tightened in the
#                                same commit, or it silently re-opens headroom
#                                for a future regression to hide in.
#
# Landing a port that refuses mid-flight (as #1364 does) means raising the pin
# deliberately, in the commit that causes it — which is the point: a refusal
# becomes a reviewed decision instead of an unasserted number scrolling past.
#
# Usage: zig build && zig build selfhost && bash scripts/selfhost-diffexamples.sh
#
# Exit codes (matching x64gate.sh / selfhost-diffsafepoints.sh):
#   0  every example built, ran, and agreed
#   1  real failure: a DIFF (miscompile), a SEED-FAIL, or REFUSED off its pin
#   2  could not decide: an example timed out and was never compared. Not a
#      pass — see #1524/#1525.
set -u
SEED=zig-out/bin/bit-seed
BIT2=${BIT2:-zig-out/bin/bit}

# TIMEOUT is its own outcome — never PASS, never DIFF (#1524/#1525).
#
# The alarm exists because a miscompile can hang rather than print, so it must
# stay. But its exit code (142 = 128+SIGALRM) used to be fed straight into the
# exit-code comparison below, which broke BOTH ways on a loaded host:
#
#   - one side times out -> "seed=0 bit2=142" reported as DIFF, a false RED
#     against compilers that agree. Worse when the SEED is the side killed: the
#     board then accuses the self-hosted compiler of breaking a working example.
#   - BOTH sides time out -> 142 == 142 and `cmp` finds two EMPTY files equal,
#     so it scored PASS. Measured: 15 alarms in one run, 5 became DIFFs and the
#     other 10 were both-sides pairs counted green. A hanging miscompile — the
#     exact case the alarm was added to catch — was being absorbed into PASS.
#
# So a timeout now `continue`s to its own counter, which makes the comparison
# below UNREACHABLE unless both sides actually produced a result. Two empty
# outputs can no longer meet each other.
#
# The budget is a HANG guard, not a performance budget: measured worst case for
# an example build+run is under 0.1s, so the old 30s was never crossed by real
# work — only by a process descheduled under load. Rather than trade one
# arbitrary constant for another, a trip is RETRIED ONCE: a hang is
# deterministic and trips twice, a scheduling artifact does not. Override the
# budget with TIMEOUT_S for a slower host.
TIMEOUT_S=${TIMEOUT_S:-60}

# alarm_run <outfile> <cmd...> — returns 142 iff the run timed out twice.
# `timeout` is not on macOS, perl is. alarm(2) survives exec, and exec resets
# SIGALRM to its default (terminate), so the child dies even though the handler
# does not carry over. Caveat: a child that deliberately exits 142 is
# indistinguishable from a timeout — no example does, and the retry means such a
# child would have to do it twice.
# The subshell wrapper silences the shell's own "Alarm clock: 14" job message —
# it also fires for a trip that RECOVERS on retry, so it would smear noise across
# a green log and inflate any count of alarm lines. The TIMEOUT line below is the
# reportable signal.
alarm_run() {
  local out=$1 rc
  shift
  ( perl -e 'alarm shift; exec @ARGV' "$TIMEOUT_S" "$@" >"$out" 2>&1 ) 2>/dev/null
  rc=$?
  [ "$rc" -ne 142 ] && return "$rc"
  ( perl -e 'alarm shift; exec @ARGV' "$TIMEOUT_S" "$@" >"$out" 2>&1 ) 2>/dev/null
  return $?
}
# The pin. Override only to explore locally; the committed value is the gate.
EXPECTED_REFUSED=${EXPECTED_REFUSED:-0}
# Network-dependent examples: they talk to the outside world, so their output is
# not a function of the compiler alone.
SKIP="h3fetch httpserver httpsserver http2server tlsclient"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

pass=0 diff=0 refused=0 seedfail=0 skipped=0 timedout=0
for d in examples/*/; do
  n=$(basename "$d")
  case " $SKIP " in *" $n "*) skipped=$((skipped + 1)); continue;; esac

  # The BUILDS are alarm-guarded too: a compiler that hangs while compiling was
  # previously unbounded by this script, and a hung bit2 build would have been
  # scored REFUSED ("not ported yet") rather than surfaced.
  alarm_run "$TMP/bs_$n" "$SEED" build "$d" -o "$TMP/seed_$n"
  rc=$?
  if [ "$rc" -eq 142 ]; then
    echo "TIMEOUT   $n (seed build, SIGALRM after ${TIMEOUT_S}s, twice)"
    timedout=$((timedout + 1))
    continue
  fi
  if [ "$rc" -ne 0 ]; then
    echo "SEED-FAIL $n"
    seedfail=$((seedfail + 1))
    continue
  fi

  alarm_run "$TMP/err_$n" "$BIT2" build "$d" -o "$TMP/b2_$n"
  rc=$?
  if [ "$rc" -eq 142 ]; then
    echo "TIMEOUT   $n (bit2 build, SIGALRM after ${TIMEOUT_S}s, twice)"
    timedout=$((timedout + 1))
    continue
  fi
  if [ "$rc" -ne 0 ]; then
    echo "REFUSED   $n: $(tail -1 "$TMP/err_$n")"
    refused=$((refused + 1))
    continue
  fi

  alarm_run "$TMP/o_seed_$n" "$TMP/seed_$n"
  se=$?
  alarm_run "$TMP/o_b2_$n" "$TMP/b2_$n"
  b2=$?

  # Undecided, not agreement: bail BEFORE the comparison so two absent results
  # can never be found equal.
  if [ "$se" -eq 142 ] || [ "$b2" -eq 142 ]; then
    side="seed"
    [ "$se" -ne 142 ] && side="bit2"
    [ "$se" -eq 142 ] && [ "$b2" -eq 142 ] && side="BOTH"
    echo "TIMEOUT   $n (run: $side, SIGALRM after ${TIMEOUT_S}s, twice)"
    timedout=$((timedout + 1))
    continue
  fi

  if [ "$se" != "$b2" ] || ! cmp -s "$TMP/o_seed_$n" "$TMP/o_b2_$n"; then
    echo "DIFF      $n (exit seed=$se bit2=$b2)"
    command diff "$TMP/o_seed_$n" "$TMP/o_b2_$n" | head -6
    diff=$((diff + 1))
    continue
  fi
  pass=$((pass + 1))
done

echo "example differential: PASS=$pass DIFF=$diff TIMEOUT=$timedout REFUSED=$refused (pinned $EXPECTED_REFUSED) SEED-FAIL=$seedfail SKIP(network)=$skipped"
# A DIFF is a miscompile; a SEED-FAIL means the oracle itself did not build.
if [ "$diff" -gt 0 ] || [ "$seedfail" -gt 0 ]; then
  exit 1
fi
# A TIMEOUT decided nothing: those examples were never differentially tested, so
# the run cannot be called green. Exit 2 = could-not-decide, matching the
# precondition/fatal convention of x64gate.sh and selfhost-diffsafepoints.sh and
# staying distinct from exit 1 = real divergence.
if [ "$timedout" -gt 0 ]; then
  echo "UNDECIDED: $timedout example(s) timed out after ${TIMEOUT_S}s x2 and were NOT compared."
  echo "           This is not a pass. Re-run on a quieter host, or raise TIMEOUT_S."
  echo "           If it reproduces on an idle host, that is a real hang — investigate it."
  exit 2
fi
# A REFUSED example is an honest "not ported yet" only while it matches the pin.
if [ "$refused" -gt "$EXPECTED_REFUSED" ]; then
  echo "FAIL: REFUSED rose $EXPECTED_REFUSED -> $refused. A construct that used to lower no longer does."
  echo "      Fix the regression, or raise EXPECTED_REFUSED in this script if the refusal is deliberate."
  exit 1
fi
if [ "$refused" -lt "$EXPECTED_REFUSED" ]; then
  echo "FAIL: REFUSED fell $EXPECTED_REFUSED -> $refused. Lower EXPECTED_REFUSED to $refused in this script,"
  echo "      otherwise the pin leaves $((EXPECTED_REFUSED - refused)) refusals of slack for a regression to hide in."
  exit 1
fi
exit 0
