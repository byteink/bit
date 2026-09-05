#!/usr/bin/env bash
# bench/profile.sh <case> [bit|c|go] -- per-symbol CPU-cycle attribution for
# one bench case, so the next performance ranking is READ off a real profile
# instead of hand-probed (#4360). bench/run.sh reports whole-process cycles
# per case and nothing below that; this is the "read it top-down" step #3772
# proved cheap for the gate suite, applied to a benchmark.
#
# macOS: /usr/bin/sample takes a full-stack snapshot of every thread in the
# target at each tick, `filtercalltree -invertCallTree` re-roots that tree at
# the leaf frame, and the tool below sums each leaf's counts across however
# many distinct call paths reached it. Both ship with macOS; nothing is
# installed. Linux (mustafa-desktop-wsl, hl-master): `perf record` (no -g --
# see below) + `perf report`, if `perf` is on PATH; otherwise this prints one
# line naming that and exits 2, which is a stated result, not a silent skip.
#
# WHAT THIS CANNOT SEE, stated rather than discovered later:
#
#  - sample() timer-ticks EVERY thread regardless of whether it is actually
#    running on a core. A Bit program's OS main thread parks in
#    bit_rt_port_park_wait (waiting for bit_main to finish on a worker
#    thread) and its sysmon thread sleeps in a nanosleep loop the whole run --
#    both are 100% self-samples in a kernel wait primitive with ZERO CPU
#    behind them. Counting those would make "top of profile" report
#    __ulock_wait or __semwait_signal for every case, which is true and
#    useless. This script drops any leaf sample whose call chain passes
#    through bit_rt_port_park_wait or sysmonRun -- named exactly, not by
#    pattern -- and reports how many samples that excluded separately from
#    the real total. A genuinely busy sysmon tick (there are none in the
#    cases this repo ships) would be dropped too; that is the trade this
#    makes, and it is why the excluded count is printed rather than hidden.
#  - The same exclusion covers the leaf symbol `_dyld_start`: dyld's own
#    loader trampoline, sampled before `_start`/`boot` ever runs. It is real
#    CPU (dynamic linking, not a blocked wait) but it is fixed per-process
#    overhead identical across every case and language, and it is the single
#    most contention-sensitive part of the whole run -- it happens before the
#    program has any threads of its own to be scheduled fairly, so under a
#    loaded box (measured here at 1-min load 4+, two sibling agents pinning
#    cores at 100%) it can eat 20%+ of a short case's samples and dominate the
#    ranking with a finding that says nothing about the case. Excluded and
#    counted the same way as the two wait primitives above. Ordinary lazy
#    binding during real execution (dyld_stub_binder) is a different symbol
#    and is NOT excluded.
#  - A symbol that got inlined away never appears; its cost is silently
#    folded into whichever caller frame is still standing when the sample
#    hits. Neither `sample` nor `perf` without --call-graph=dwarf can tell
#    you this happened.
#  - The [rt]/[std]/[user] tag is a NAME PATTERN
#    (bit_rt_*/gc*/sched* -> [rt], m<N>$* -> [std], else [user]), not a
#    lookup into which package defined the symbol. Several genuine
#    runtime-internal helpers compiled directly into the program (this repo
#    has seen scanObject, markObject, allocObject, idxContains, idxHash,
#    spanSkip, linkObject, recoverOverflow, zeroBytes, setSlotBit as
#    examples) carry none of those three prefixes and land in [user]. Do not
#    read a case's [user] share as literally "time in the user's code" --
#    check the named top rows first.
#  - This is a SAMPLING profile: a function whose entire execution fits
#    between two ticks is invisible. That is the sampler's whole design, not
#    a bug in this script, and it is why the guard below refuses to publish
#    a ranking built from too few ticks.
#
# Runs on stock bash 3.2. Reuses bench/buildlib.sh's build functions so this
# can never compile a case differently than bench/run.sh's published numbers
# did.
set -euo pipefail

cd "$(dirname "$0")/.."          # repo root
source bench/buildlib.sh

MINSAMPLES=200
INTERVAL_MS=${PROFILE_INTERVAL_MS:-1}     # sampler tick interval
DURATION_S=${PROFILE_DURATION_S:-60}      # ceiling; sample/perf return once the target exits
TOPN=25

CASE=${1:-}
LANG=${2:-bit}
[ -n "$CASE" ] || { echo "usage: bench/profile.sh <case> [bit|c|go]" >&2; exit 1; }

CASEDIR="bench/cases/$CASE"
SRC="$CASEDIR/$CASE.$LANG"
[ -f "$SRC" ] || { echo "profile.sh: no $SRC -- unknown case/lang combination" >&2; exit 1; }

UNAME=$(uname -s)

# Fail fast on tool availability BEFORE paying for a build -- a platform that
# cannot profile at all should not also burn a compile to find that out.
if [ "$UNAME" = Darwin ]; then
  command -v sample >/dev/null 2>&1 || { echo "profile.sh: /usr/bin/sample not found" >&2; exit 2; }
  command -v filtercalltree >/dev/null 2>&1 || { echo "profile.sh: /usr/bin/filtercalltree not found" >&2; exit 2; }
else
  command -v perf >/dev/null 2>&1 || {
    echo "profile.sh: perf not found on PATH -- cannot profile on $UNAME without it" >&2
    exit 2
  }
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
PROG="$WORK/prog"

case "$LANG" in
  bit) buildBit "$CASEDIR" "$CASE" "$PROG" ;;
  c)   buildC   "$CASEDIR" "$CASE" "$PROG" ;;
  go)  buildGo  "$CASEDIR" "$CASE" "$PROG" ;;
  *)   echo "profile.sh: unknown lang '$LANG' (want bit, c or go)" >&2; exit 1 ;;
esac

# Classifies one symbol name into rt/std/user. Shared between both platform
# branches so the same case profiled on macOS and Linux tags identically.
# Symbol names as printed by `sample` have no leading underscore; `perf`
# strips it too, but the `_?` covers either convention (the ticket's own
# examples are given in objdump's underscore-prefixed style).
TAG_AWK='
function tagof(s) {
  if (s ~ /^_?bit_rt_/) return "rt"
  if (s ~ /^_?gc/)      return "rt"
  if (s ~ /^_?sched/)   return "rt"
  if (s ~ /^_?m[0-9]+\$/) return "std"
  return "user"
}
'

# Renders the final report from a "<count> <symbol>" list (one per unique
# symbol, pre-aggregated, on stdin) plus the totals already known. Same
# renderer for both platforms.
render() {
  local realtotal="$1" idletotal="$2" rawtotal="$3"
  sort -k1,1nr > "$WORK/ranked.txt"
  local nsym; nsym=$(wc -l < "$WORK/ranked.txt" | tr -d ' ')
  awk -v real="$realtotal" -v idle="$idletotal" -v raw="$rawtotal" \
      -v topn="$TOPN" -v nsym="$nsym" "$TAG_AWK"'
    { count[NR]=$1; sym[NR]=$2; tagtot[tagof($2)] += $1 }
    END {
      printf "case=%s lang=%s total_samples=%d excluded(idle+dyld_start)=%d raw_samples=%d distinct_symbols=%d\n",
             ENVIRON["CASE"], ENVIRON["LANG"], real, idle, raw, nsym
      printf "%-4s %-8s %-7s %-6s %s\n", "rank", "samples", "share", "tag", "symbol"
      shown = (nsym < topn) ? nsym : topn
      accounted = 0
      for (i = 1; i <= shown; i++) {
        pct = 100.0 * count[i] / real
        accounted += count[i]
        printf "%-4d %-8d %-6.2f%% [%-4s] %s\n", i, count[i], pct, tagof(sym[i]), sym[i]
      }
      other = real - accounted
      othern = nsym - shown
      if (othern > 0) {
        printf "%-4s %-8d %-6.2f%% %s\n", "...", other, 100.0*other/real, \
               "(" othern " more symbols, not shown)"
        accounted += other
      }
      printf "\n[rt]   subtotal: %d (%.2f%%)\n", tagtot["rt"]+0, 100.0*(tagtot["rt"]+0)/real
      printf "[std]  subtotal: %d (%.2f%%)\n", tagtot["std"]+0, 100.0*(tagtot["std"]+0)/real
      printf "[user] subtotal: %d (%.2f%%)\n", tagtot["user"]+0, 100.0*(tagtot["user"]+0)/real
      printf "shown table + other sum to %.2f%% of total_samples (must be within 1%% of 100%%)\n", \
             100.0*accounted/real
    }' "$WORK/ranked.txt"
}
export CASE LANG

if [ "$UNAME" = Darwin ]; then
  "$PROG" >"$WORK/prog.out" 2>"$WORK/prog.err" &
  PID=$!
  set +e
  sample "$PID" "$DURATION_S" "$INTERVAL_MS" -mayDie -file "$WORK/sample.txt" >"$WORK/sample.log" 2>&1
  SAMPLE_RC=$?
  wait "$PID" 2>/dev/null
  PROG_RC=$?
  set -e
  [ "$SAMPLE_RC" -eq 0 ] || { echo "profile.sh: sample(1) failed (rc=$SAMPLE_RC): $(cat "$WORK/sample.log")" >&2; exit 1; }
  [ "$PROG_RC" -eq 0 ] || echo "profile.sh: note -- $PROG exited $PROG_RC (profiled anyway)" >&2
  [ -s "$WORK/sample.txt" ] || { echo "profile.sh: sample(1) produced no output" >&2; exit 1; }

  filtercalltree "$WORK/sample.txt" -invertCallTree > "$WORK/inverted.txt"

  # Depth-0 lines in the inverted call graph (exactly 4 leading spaces then a
  # digit) are self/leaf sample groups; every deeper line starts with 4
  # spaces then a tree-drawing character (+ ! : |). A block is "idle" if any
  # line in its call chain names one of the two known always-blocked Bit
  # runtime threads (see header). Symbol name is the text before "  (in ".
  awk '
    /^Call graph:/ { insection = 1; next }
    /^Total number in stack/ { insection = 0 }
    !insection { next }
    {
      if ($0 ~ /^    [0-9]/) {
        flush()
        rest = $0; sub(/^    /, "", rest)
        cur_count = rest + 0
        sym = rest; sub(/^[0-9]+ /, "", sym)
        idx = index(sym, "  (in ")
        if (idx > 0) sym = substr(sym, 1, idx - 1)
        cur_sym = sym
        idle = (sym == "_dyld_start") ? 1 : 0
      } else if ($0 ~ /^    [+!:| ]/) {
        if ($0 ~ /bit_rt_port_park_wait|sysmonRun/) idle = 1
      }
    }
    END { flush() }
    function flush() {
      if (cur_count == 0) return
      rawtotal += cur_count
      if (idle) idletotal += cur_count
      else { bysym[cur_sym] += cur_count; realtotal += cur_count }
    }
    END {
      print "TOTAL_RAW", rawtotal+0 > "'"$WORK"'/totals.txt"
      print "TOTAL_IDLE", idletotal+0 > "'"$WORK"'/totals.txt"
      print "TOTAL_REAL", realtotal+0 > "'"$WORK"'/totals.txt"
      for (s in bysym) print bysym[s], s > "'"$WORK"'/symlist.txt"
    }
  ' "$WORK/inverted.txt"

  RAWTOTAL=$(awk '$1=="TOTAL_RAW"{print $2}' "$WORK/totals.txt")
  IDLETOTAL=$(awk '$1=="TOTAL_IDLE"{print $2}' "$WORK/totals.txt")
  REALTOTAL=$(awk '$1=="TOTAL_REAL"{print $2}' "$WORK/totals.txt")

  if [ "${REALTOTAL:-0}" -lt "$MINSAMPLES" ]; then
    echo "profile.sh: only $REALTOTAL on-thread sample(s) collected ($MINSAMPLES required) --" \
         "$CASE/$LANG ran too briefly to profile meaningfully" \
         "(raise PROFILE_DURATION_S or lower PROFILE_INTERVAL_MS)" >&2
    exit 1
  fi

  render "$REALTOTAL" "$IDLETOTAL" "$RAWTOTAL" < "$WORK/symlist.txt"

else
  # No --call-graph: every sample already IS a single leaf PC, so `perf
  # report` sorted purely by symbol gives self-time directly with no
  # inversion step needed (unlike sample(1), which always walks the full
  # stack). This branch has not been exercised end to end: `perf` is absent
  # on both mustafa-desktop-wsl and hl-master as of 2026-09-05 (`command -v
  # perf` rc=1 on both, checked over ssh), so only the "perf missing" branch
  # above has been run against real hardware.
  set +e
  perf record -F 999 -o "$WORK/perf.data" -- "$PROG" >"$WORK/prog.out" 2>"$WORK/prog.err"
  PERF_RC=$?
  set -e
  [ "$PERF_RC" -eq 0 ] || { echo "profile.sh: perf record failed (rc=$PERF_RC): $(cat "$WORK/prog.err")" >&2; exit 1; }

  RAWTOTAL=$(perf script -i "$WORK/perf.data" 2>/dev/null | grep -Evc '^#|^$' || true)
  [ "${RAWTOTAL:-0}" -lt "$MINSAMPLES" ] && {
    echo "profile.sh: only $RAWTOTAL sample(s) collected ($MINSAMPLES required) --" \
         "$CASE/$LANG ran too briefly to profile meaningfully" \
         "(raise PROFILE_DURATION_S or lower PROFILE_INTERVAL_MS)" >&2
    exit 1
  }

  perf report -i "$WORK/perf.data" --stdio --percent-limit 0 \
      --fields overhead,symbol --sort symbol > "$WORK/perf.report" 2>"$WORK/perf.err"

  # perf report lines: "    12.34%  symbolname". No idle-thread problem here
  # (perf only samples on-CPU time by default), so nothing is excluded.
  awk -v raw="$RAWTOTAL" '
    /^ *[0-9.]+% / {
      pct = $1; sub(/%$/, "", pct)
      sym = $0; sub(/^ *[0-9.]+% +/, "", sym)
      count = int(pct/100.0*raw + 0.5)
      print count, sym
    }
  ' "$WORK/perf.report" > "$WORK/symlist.txt"

  REALTOTAL="$RAWTOTAL"
  render "$REALTOTAL" 0 "$RAWTOTAL" < "$WORK/symlist.txt"
fi
