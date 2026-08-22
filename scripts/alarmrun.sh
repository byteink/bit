#!/usr/bin/env bash
# Sourceable wall-clock guard for an ORACLE/BIT2 subprocess call in a
# selfhost-diff* differential (#2866). Extracted from selfhost-diffdump.sh,
# whose nine call sites carried this inline before this file existed. Do not
# paste the perl one-liner at another call site — source this instead.
#
# Usage: source this file, set $TIMEOUT (seconds) in the caller's scope, then
#   out=$(alarmrun "$COMPILER" args...); rc=$?
# 142 (128+SIGALRM) means the alarm fired: a real timeout, not a crash and not
# a normal nonzero exit. alarmrun takes no bound argument itself, so every
# existing diffdump.sh call site's spelling (`alarmrun "$ORACLE" ...`) is
# unchanged by this move.
#
# Default bound: this family's convention is 20s for a single dump/build/check
# call (diffdump.sh's ast/tokens/diags/types rows, diffcheck.sh, diffverdict.sh,
# diffdoc.sh) and up to 300s for a whole-corpus IR pass (diffdump.sh's ir/iropt
# rows, diffruntime.sh). Pick your own default via a `${FOO_TIMEOUT:-N}` env
# var in the caller. Whichever you pick, do not go below ~12s on a shared box:
# #2863's mutation run measured a 3s bound producing 11 FALSE timeouts from
# ordinary machine load alone, and had to be redone at 12-20s.
#
# stderr is discarded by default (this is perl's own diagnostic if exec itself
# failed, not the child's) to match every existing call site. Set
# ALARMRUN_KEEP_STDERR=1 for a call whose caller needs the child's real stderr
# preserved (e.g. merged into a captured file for a later diagnostic) instead
# of dropped — do not let the default silently swallow that.
alarmrun() {
  if [ "${ALARMRUN_KEEP_STDERR:-0}" = 1 ]; then
    perl -e 'alarm shift; exec @ARGV' "$TIMEOUT" "$@"
  else
    perl -e 'alarm shift; exec @ARGV' "$TIMEOUT" "$@" 2>/dev/null
  fi
}

# fd 9 preserves the REAL stderr as of the moment this file is sourced (always
# near the top of every caller, before that caller sets up any per-call
# capture). alarmrun_retry's stall note below writes to it instead of fd 2, so
# the note survives even when the CALLER has locally rebound fd 2 to capture a
# child's own diagnostics as comparison text (selfhost-diffcheck.sh's `run()`
# and others do exactly this with `cmd 2>&1 >/dev/null`) -- without this, the
# note would land inside the captured payload and corrupt the comparison it is
# reporting on.
exec 9>&2

# alarmrun_retry <side> <outfile> <cmd...> -- alarmrun with exactly ONE retry
# on a stall (#3408). Promoted from selfhost-diffsafepoints.sh's build_retried
# (#3352), which four more differentials had already reimplemented under their
# own local helper names before #3406 found a call site #3352 missed inside
# its own script -- one script, one miss; this is the fix for the shape, not
# just the miss.
#
# <side>: a label (ORACLE/BIT2) for the stderr note, named by the CALLER --
# this file does not guess it from a global $ORACLE, since not every caller
# distinguishes sides in the same shape (a build call and a run-the-built-binary
# call both go through this, and only the caller knows which compiler produced
# which artifact).
# <outfile>: a path to remove before EACH attempt, because a process killed by
# SIGALRM mid-write can leave a partial file that a later `[ -f "$outfile" ]`
# check would misread as a completed build. Pass "" when the command writes no
# persistent artifact of its own (a check/dump call, or a call whose output is
# captured by the caller's own redirection instead).
#
# Requires $TIMEOUT in the caller's scope, exactly like alarmrun. Honors
# ALARMRUN_KEEP_STDERR the same way alarmrun does, since it is only an env
# prefix on the whole call and reaches the nested alarmrun invocations below.
#
# A stall on the FIRST attempt is reported even when the retry recovers --
# silence here would let a flaky oracle look healthy forever and nobody would
# ever chase the real cause.
#
# -> rc: 0/nonzero from the command, or 142 iff BOTH attempts stalled.
alarmrun_retry() {
  local side=$1 outfile=$2 rc
  shift 2
  [ -n "$outfile" ] && rm -f "$outfile"
  alarmrun "$@"
  rc=$?
  if [ "$rc" -eq 142 ]; then
    echo "$side build stalled once (SIGALRM after ${TIMEOUT}s), retrying: $*" >&9
    [ -n "$outfile" ] && rm -f "$outfile"
    alarmrun "$@"
    rc=$?
  fi
  return "$rc"
}

# alarmrun_cap <capture> <cmd...> -- alarmrun that always merges the child's
# stdout+stderr into <capture> (#3490). ALARMRUN_KEEP_STDERR does not apply
# here: a capture file IS the case that flag exists to serve, so there is no
# branch to honor it against.
#
# The redirect sits on the `perl` invocation itself (a simple command), not on
# this function -- so it is performed in perl's forked child, and this shell's
# own fd 2 is never bound to <capture>. That matters for alarmrun_retry_cap
# below: when bash reaps a child killed by SIGALRM it writes its own
# "Alarm clock: 14" job-status note to whatever fd 2 currently is, and a
# function-scoped `>"$cap" 2>&1` would make that note land inside the
# comparison payload even when the child emitted zero bytes (#3478).
alarmrun_cap() {
  local cap=$1
  shift
  perl -e 'alarm shift; exec @ARGV' "$TIMEOUT" "$@" >"$cap" 2>&1
}

# alarmrun_retry_cap <side> <outfile> <capture> <cmd...> -- alarmrun_retry's
# sibling for a caller whose own external redirect used to be the sink for
# BOTH attempts (#3490). Fixes: a stalled first attempt's partial bytes
# surviving into the retry's compared payload, because the two attempts
# shared one sink opened once by the caller (#3478).
#
# <capture>: truncated before EACH attempt (`>"$cap"` in alarmrun_cap), so the
# caller reads exactly one attempt's bytes -- never attempt 1's partial output
# followed by attempt 2's full output. This is the load-bearing half of the
# fix; the redirect placement in alarmrun_cap is hardening on top of it.
# <outfile>: same contract as alarmrun_retry -- a build-artifact path removed
# before each attempt, distinct from <capture>. Pass "" when the command
# writes no artifact of its own.
#
# Requires $TIMEOUT in the caller's scope, exactly like alarmrun_retry. Same
# 142 contract (142 iff BOTH attempts stalled), same stall note on fd 9.
#
# -> rc: 0/nonzero from the command, or 142 iff BOTH attempts stalled.
alarmrun_retry_cap() {
  local side=$1 outfile=$2 cap=$3 rc
  shift 3
  [ -n "$outfile" ] && rm -f "$outfile"
  alarmrun_cap "$cap" "$@"
  rc=$?
  if [ "$rc" -eq 142 ]; then
    echo "$side build stalled once (SIGALRM after ${TIMEOUT}s), retrying: $*" >&9
    [ -n "$outfile" ] && rm -f "$outfile"
    alarmrun_cap "$cap" "$@"
    rc=$?
  fi
  return "$rc"
}
