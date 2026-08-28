#!/bin/sh
# Run one dev command under two ceilings: a time wall and an RSS cap. Kill the
# whole process GROUP when either is breached, and say which one it was.
#
# WHY THIS EXISTS. Two unsupervised processes on one machine in one day:
# `bit lsp --stdio` reached 12,577 MB and pegged a core for 5h34m while idle
# (#2326), and a `bit run` test binary survived its parent as ppid=1 for 5h14m
# (the shape of #2274). Earlier, six concurrent agents running Bit programs
# exhausted memory and took the machine down. Nothing capped any of them and
# nothing noticed; a human spotted a fan.
#
# THE PROCESS GROUP IS THE POINT. Killing the leader is what LEAVES the orphan:
# `./make` spawns make-driver which spawns compilers, and a test harness spawns
# the binary under test. We put the child in its own process group and signal
# `-PGID`, so the whole tree dies together. Sampling RSS follows the same group,
# because the leader's own RSS stays small while its children do the allocating.
#
# NOT `ulimit -v`: it does not work for this on macOS: it is accepted and then
# does not bound what we care about. A polling RSS watchdog is what works here.
#
# NOT `pgrep`/`pkill`: several agents build concurrently in sibling worktrees and
# every one of them matches any name pattern you would choose. We hold the PID.
#
# Usage:
#   scripts/watchdog.sh --expect 90 -- ./make
#   scripts/watchdog.sh --expect 8 --rss-mb 512 --label golden -- bit run _tests_/...
#
#   --expect <s>       REQUIRED. How long this is expected to take. The wall is
#                      derived from it, because a wall picked without one is
#                      either uselessly loose or spuriously tight.
#   --wall <s>         Hard time wall. Default: expect * wall-factor.
#   --wall-factor <n>  Default 4. A normally-90s build dies at 6 min, not never.
#   --rss-mb <n>       Ceiling on the group's summed RSS. Default 4096.
#   --poll <s>         Sample interval. Default 2.
#   --label <name>     What to call this in messages. Default: the command.
#
# Exit codes: 124 = time wall (matching GNU timeout), 125 = RSS cap. Anything
# else is the child's OWN exit code, passed through unchanged, signal deaths
# included. A caller must be able to tell "your build failed" from "the watchdog
# stopped it".

set -eu

# Job control off. With it on, the shell prints its own asynchronous
# "Terminated: 15" notice when it reaps the group we just signalled, which lands
# on stderr AFTER the watchdog's own message and reads like a second, unexplained
# failure. The exit code is unaffected either way; this is about the caller being
# able to trust what it reads on stderr.
set +m 2>/dev/null || true

expect=""
wall=""
wall_factor=4
rss_mb=4096
poll=2
label=""

while [ $# -gt 0 ]; do
  case "$1" in
    --expect)      expect="$2"; shift 2 ;;
    --wall)        wall="$2"; shift 2 ;;
    --wall-factor) wall_factor="$2"; shift 2 ;;
    --rss-mb)      rss_mb="$2"; shift 2 ;;
    --poll)        poll="$2"; shift 2 ;;
    --label)       label="$2"; shift 2 ;;
    --)            shift; break ;;
    *) echo "watchdog: unknown option '$1'" >&2; exit 2 ;;
  esac
done

[ $# -gt 0 ] || { echo "watchdog: no command given (did you forget --)" >&2; exit 2; }
[ -n "$expect" ] || { echo "watchdog: --expect <seconds> is required" >&2; exit 2; }
[ -n "$label" ] || label="$1"
[ -n "$wall" ] || wall=$((expect * wall_factor))

# Own process group, so the whole tree is one signalling target. macOS ships no
# setsid(1); perl's setpgrp is the portable spelling that is present on both
# macOS and the Linux gate images.
perl -e 'setpgrp(0,0); exec @ARGV or die "watchdog: exec failed: $!\n"' "$@" &
child=$!

# The child IS its own group leader, so PGID == its PID.
pgid="$child"

# Summed RSS (KB on both macOS and Linux) of every process in the group. The
# leader alone is not enough: ./make's own footprint is trivial next to the
# compilers it spawns.
group_rss_kb() {
  ps -Ao pgid=,rss= 2>/dev/null | awk -v g="$pgid" '$1==g {s+=$2} END {print s+0}'
}

reap() {
  # TERM the GROUP first so children get a chance to exit cleanly, then KILL.
  # `|| true` on both: after we have signalled it, `wait` reports 143 and would
  # take this script down under `set -e`. Redirecting stderr hides the message,
  # not the status.
  kill -TERM "-$pgid" 2>/dev/null || true
  sleep 3
  kill -KILL "-$pgid" 2>/dev/null || true
  wait "$child" 2>/dev/null || true
}

elapsed=0
peak_kb=0

while kill -0 "$child" 2>/dev/null; do
  now_kb=$(group_rss_kb)
  [ "$now_kb" -gt "$peak_kb" ] && peak_kb="$now_kb"

  if [ "$((now_kb / 1024))" -gt "$rss_mb" ]; then
    echo "watchdog: killed ${label} at $((now_kb / 1024)) MB RSS (cap ${rss_mb} MB) after ${elapsed}s" >&2
    reap
    exit 125
  fi

  if [ "$elapsed" -ge "$wall" ]; then
    echo "watchdog: killed ${label} after ${elapsed}s (wall ${wall}s, expected ~${expect}s), peak $((peak_kb / 1024)) MB" >&2
    reap
    exit 124
  fi

  sleep "$poll"
  elapsed=$((elapsed + poll))
done

# Clean exit: recover the child's own status. `wait` on an already-reaped child
# returns its code; `|| rc=$?` keeps `set -e` from firing on a nonzero one.
rc=0
wait "$child" || rc=$?

echo "watchdog: ${label} finished in ${elapsed}s (expected ~${expect}s), peak $((peak_kb / 1024)) MB, rc=${rc}" >&2
exit "$rc"
