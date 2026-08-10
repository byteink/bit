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
