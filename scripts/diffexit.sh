#!/usr/bin/env bash
# Sourced-only exit-decision helper for the selfhost-diff* family (#3382).
#
# The tail of every selfhost-diff*.sh script decides the same three-way
# verdict from a handful of counters, and that decision was hand-written at
# every call site -- which got it wrong five separate times in one day:
#
#   #3351  selfhost-diffsafepoints.sh    -- bare `&&` chain, no explicit exit;
#          fell off the end at exit 1 whenever mismatch=0 and timeout>0.
#   #3377  selfhost-diffexamples-x64.sh  -- identical bare-`&&` shape.
#   #3378  selfhost-diffdump.sh run_basic() -- worse: folded an ORACLE timeout
#          into the MISMATCH *count* itself, fabricating a "first divergence"
#          from an alarm-killed binary's partial output.
#   #3379  selfhost-diffdump.sh run_types()/run_ir() -- a timeout set the same
#          status as a real mismatch, undocumented, indistinguishable from a
#          bug.
#   #3380  selfhost-diffruntime.sh -- same shape as #3379.
#
# One shared, sourced function replaces every hand-rolled tail so there is
# nowhere left for a sixth copy of this bug to be written.
#
# ## The contract (unchanged -- this is the family's existing agreement)
#
#   0  agreed           -- no failure, no timeout.
#   1  real divergence  -- any failure counter is nonzero. This ALWAYS wins,
#                          even when a timeout counter is also nonzero: an
#                          observed divergence is evidence regardless of how
#                          many files elsewhere timed out.
#   2  could-not-decide -- no failure, but a timeout counter is nonzero.
#                          Prints an UNDECIDED line naming which counter(s)
#                          timed out. This is not a pass.
#
# ## Usage (source it, never execute it as the differential itself)
#
#   . "$(dirname -- "$0")/diffexit.sh"
#   diffexit "<label>" -f <n1> [<n2> ...] -t "<desc1>=<n2>" ["<desc2>=<n3>" ...]
#
# Every argument after `-f` is an already-summed non-negative integer; any
# nonzero one fails the run. Every argument after `-t` is a "<desc>=<count>"
# pair, already summed by the caller (e.g. "file(s)=$timeout"); a nonzero
# count is named in the UNDECIDED line. `-f`/`-t` may each be omitted if the
# script has no counters of that kind, and `-t` may be given with a zero
# count (it is silently skipped in the message).
#
# The caller must already have printed its own failure detail (the MISMATCH
# list, the REGRESSION list, per-file timeout lines, ...) before calling
# diffexit -- this function only decides the exit code and, for the
# could-not-decide case, prints the one summary line naming what timed out.
diffexit() {
  local label=$1
  shift
  local mode="" failsum=0 timeoutsum=0
  local -a tparts=()
  local arg desc n part joined

  while [ $# -gt 0 ]; do
    case "$1" in
      -f) mode=f ;;
      -t) mode=t ;;
      *)
        case "$mode" in
          f)
            failsum=$((failsum + $1))
            ;;
          t)
            desc=${1%%=*}
            n=${1##*=}
            timeoutsum=$((timeoutsum + n))
            [ "$n" -gt 0 ] && tparts+=("$n $desc")
            ;;
          *)
            echo "diffexit: argument '$1' precedes -f/-t" >&2
            exit 2
            ;;
        esac
        ;;
    esac
    shift
  done

  if [ "$failsum" -gt 0 ]; then
    exit 1
  fi

  if [ "$timeoutsum" -gt 0 ]; then
    joined=""
    for part in "${tparts[@]}"; do
      if [ -z "$joined" ]; then
        joined="$part"
      else
        joined="$joined and $part"
      fi
    done
    echo "UNDECIDED: $label: $joined timed out and were NOT compared."
    echo "           This is not a pass. Re-run on a quieter host, or raise the timeout."
    exit 2
  fi

  exit 0
}

# Self-check: run directly (not sourced) to assert diffexit's branch table.
# `bash scripts/diffexit.sh`. diffexit() itself calls `exit`, so every case
# below runs it in a subshell to capture the code without killing the
# self-check. Table-driven, one row per branch combination.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -u
  fail=0

  # $1=want rc  $2=name  $3=required substring (or "")  $4=forbidden substring
  # (or "")  $5..=the diffexit call (label + flags).
  check() {
    local want=$1 name=$2 needle=$3 anti=$4 out rc
    shift 4
    out=$( (diffexit "$@") 2>&1 )
    rc=$?
    [ "$rc" -ne "$want" ] && { echo "FAIL: $name: rc=$rc want=$want ($out)"; fail=1; }
    [ -n "$needle" ] && case "$out" in
      *"$needle"*) ;;
      *) echo "FAIL: $name: missing '$needle' in: $out"; fail=1 ;;
    esac
    [ -n "$anti" ] && case "$out" in
      *"$anti"*) echo "FAIL: $name: forbidden '$anti' present in: $out"; fail=1 ;;
    esac
  }

  check 0 "all clear"                       "" ""              t -f 0 -t "x=0"
  check 1 "single failure counter"          "" ""              t -f 1 -t "x=0"
  check 2 "single timeout counter" \
    "UNDECIDED: t: 3 file(s) timed out and were NOT compared." "" t -f 0 -t "file(s)=3"
  check 1 "failure wins over a concurrent timeout" "" ""       t -f 0 2 -t "file(s)=6"
  check 2 "multi-timeout, only nonzero counters named" \
    "2 oracle and 1 runtime timed out" "0 bit2" \
    t -f 0 -t "oracle=2" "bit2=0" "runtime=1"
  check 0 "no -t given at all"              "" ""              t -f 0

  [ "$fail" -eq 0 ] && echo "diffexit.sh: self-check passed"
  exit "$fail"
fi
