#!/usr/bin/env bash
# Run the WHOLE self-host differential family and return one verdict (#1568).
#
# ## Why this exists: the checklist was the bug
#
# Five times in one day a new golden case reddened a differential its author
# did not run:
#
#   #1493  the golden used `println`; golden cases compile single-file with NO
#          prelude. Green in the author's worktree (verified through `bit build`,
#          which DOES load the prelude for a single file), red on merged main.
#   #1541  run_generic_arity_ok  -> entered the diffir mismatch set, diffir unrun.
#   #1531  run_match_subject_forms -> same.
#   #1529  reddened difftypes; the brief for that ticket listed diffcheck,
#          diffdiags, diffexamples and fixpoint, and omitted difftypes.
#   #1325  came back red on merged main for the same reason.
#   tonight: goldens from four agents took fuzzdiff from 6895/0 to MISMATCH=3.
#
# Every one of those was preceded by the instruction "run EVERY differential
# that reads it". It kept failing because that instruction is a MANUAL CHECKLIST
# over ~14 scripts, and the correct subset depends on the golden's directive and
# its content. A rule people have to remember is not a control. This script is
# the control: one command that cannot be under-run.
#
# So: add or change anything under tests/cases, examples/, stdlib/ or
# tests/imports -> run THIS, not a subset you chose.
#
# ## The family is DISCOVERED, not listed
#
# `scripts/selfhost-*.sh`, minus `*-x64.sh` (the cross-arch variants belong to
# x64gate.sh and need an emulator) and minus `selfhost-diffdump.sh` (the shared
# table-driven driver behind six of the wrappers below, not itself a
# differential -- it takes a required mode argument and exits 1 on a bare
# usage error that used to be tallied as a real divergence, #2847). A
# hardcoded list goes stale the day someone adds the fifteenth differential,
# and a stale list is exactly the failure this script exists to end.
#
# But a glob that matches nothing must NEVER read as success -- that is the
# #1514 shape (fuzzdiff once scored 6642 MATCH with no compiler on disk). So
# discovery has a FLOOR: fewer than DIFFALL_MIN constituents is a hard exit 2,
# naming what it found. Adding a differential is free; deleting one has to be
# deliberate enough to also lower the floor.
#
# ## Reading a constituent's result
#
# The thing whose exit code is read is the thing being tested. Each constituent
# is spawned, its PID held, `wait`ed, and `$?` captured on its own line. No
# pipelines carry status (`tail`/`head` return THEIR OWN status -- a red diffir
# was read as green that way today, #1568); every `tail` here runs strictly in
# the reporting path, long after the verdict is decided. And nothing is ever
# inferred from output TEXT: `./make test` prints "failed command:" ON
# SUCCESS, so grepping for "fail" is a broken oracle by construction.
#
# Status mapping, matching the family convention (x64gate.sh, diffverdict.sh,
# 3977211) -- exit 2 "could not decide" is deliberately distinct from exit 1
# "real divergence":
#
#   0    PASS
#   1    FAIL          real divergence. Something actually disagrees.
#   2    INCONCLUSIVE  precondition/could-not-decide -- or ABSENT if the script
#                      is listed in the expected-absent set (see below).
#   142  TIMEOUT       killed by this script's outer alarm. Its own outcome:
#                      never PASS, never silently a divergence (#1524/#1525).
#   *    ERROR         a gate exiting something else is a broken gate. Counted
#                      as could-not-decide, never as green.
#
# ## Expected-absent (`scripts/selfhost-diffall.absent`)
#
# A differential for a surface that does not exist yet has not been verified to
# match -- it has not been tested at all, and those are opposite claims. Today
# `selfhost-difffmt.sh` exits 2 because the self-hosted `bit` has no `fmt`
# subcommand (#1542). Tolerating that inline would either make diffall red
# forever (so nobody runs it) or teach it to swallow exit 2 generally (so a real
# precondition failure hides). Instead the tolerated set is an explicit checked-in
# file: it shows up in review, it is one line to delete when `fmt` lands, and it
# only ever excuses exit 2 -- an allowlisted script that FAILS still fails the
# run. A missing set file is itself exit 2; it is not optional.
#
# ## Aggregate exit code
#
#   0  every constituent PASSed (ABSENT ones aside)
#   1  at least one real divergence -- a known-bad answer is the louder signal
#   2  no divergence, but at least one constituent could not decide
#      (INCONCLUSIVE / TIMEOUT / ERROR), or discovery fell below the floor
#
# Constituents run SEQUENTIALLY and all of them run: they share bit-out/ and
# fixpoint rewrites .fixpoint-work, so parallelism would corrupt them, and
# fail-fast would hand back a partial board -- which is the checklist problem
# again, one differential at a time.
#
# Usage: ./make selfhost && bash scripts/selfhost-diffall.sh
#   DIFFALL_TIMEOUT=n   per-constituent hang guard, seconds (default 3600)
#   DIFFALL_MIN=n       discovery floor (default 15)
#   DIFFALL_DIR=path    constituent directory -- for mutation-testing this gate
#   DIFFALL_KEEP=1      keep the per-constituent logs instead of deleting them
#
# A failing or undecided constituent's log is never window-truncated in the
# report (#3678): a 40-line tail once hid 4 of 5 SAFEPOINT DIVERGENCE lines
# because they sorted earlier in a corpus walk than the window covered, and
# the only way to recover them was a standalone re-run. The raw log is also
# copied out from under this script's own cleanup, to
# $TMPDIR/selfhost-diffall-keep.<random>/, printed at the end of any run that
# has something to keep -- DIFFALL_KEEP=1 is the stronger, pre-existing
# option: it keeps EVERY constituent's log, passing ones included, at $work
# itself.
set -uo pipefail
# shellcheck source=scripts/alarmrun.sh
. "$(dirname -- "$0")/alarmrun.sh"
# shellcheck source=scripts/diffexit.sh
. "$(dirname -- "$0")/diffexit.sh"

DIR=${DIFFALL_DIR:-scripts}
MIN=${DIFFALL_MIN:-15}
# A hang guard, not a perf budget: fixpoint builds the compiler twice (three
# times if the first two disagree and it has to confirm, #2980) and
# diffexamples builds 44 examples twice, so the honest ceiling is minutes.
TIMEOUT=${DIFFALL_TIMEOUT:-3600}
ABSENT_SET=${DIFFALL_ABSENT:-scripts/selfhost-diffall.absent}
# Oracle: the pinned stage0 -- the same compiler one release back, an EARLIER
# VERSION OF THIS SAME COMPILER, which is exactly what limits the claim below.
# scripts/stage0.sh downloads and DIGEST-VERIFIES it, and refuses rather
# than skipping. A green run proves no behaviour change versus the last
# release; it cannot catch a bug present in both — docs/release/bootstrap.md §4/§5.
ORACLE="$(sh scripts/stage0.sh)" || exit 2
BIT2=bit-out/bin/bit

# Preconditions abort. A family-wide run with no compiler on disk would have
# every constituent bail at once, and a wall of exit 2 is not a differential
# result (#1514).
if [ "${DIFFALL_DIR:-}" = "" ]; then
  for bin in "$ORACLE" "$BIT2"; do
    [ -x "$bin" ] || { echo "diffall: missing $bin — run: ./make selfhost" >&2; exit 2; }
  done
fi
[ -f "$ABSENT_SET" ] || { echo "diffall: missing expected-absent set $ABSENT_SET" >&2; exit 2; }

# Comments and blank lines out; what remains is one script basename per line.
absent_list=$(sed -e 's/#.*//' -e 's/[[:space:]]*$//' "$ABSENT_SET" | grep -v '^$' || true)

shopt -s nullglob
scripts=()
for s in "$DIR"/selfhost-*.sh; do
  case "$s" in
    *-x64.sh) continue ;;          # cross-arch variant; x64gate.sh owns it
    */selfhost-diffall.sh) continue ;;  # never recurse into itself
    */selfhost-diffdump.sh) continue ;;  # shared driver behind diffast/difftokens/
                                          # diffdiags/difftypes/diffir/diffiropt
                                          # (#2743); takes a REQUIRED mode selector,
                                          # so invoking it bare is a usage error, not
                                          # a differential -- the six wrappers already
                                          # cover its six modes (#2847)
  esac
  [ -f "$s" ] || continue
  scripts+=("$s")
done
shopt -u nullglob
found=${#scripts[@]}

echo "== diffall: the whole self-host differential family =="
echo "constituents: $found discovered in '$DIR/' (floor $MIN), timeout ${TIMEOUT}s each"
[ "${DIFFALL_DIR:-}" = "" ] || echo "NOTE: DIFFALL_DIR override in effect — this run is NOT the real family."
echo

if [ "$found" -lt "$MIN" ]; then
  echo "INCONCLUSIVE: discovered $found constituent(s) in '$DIR/', expected at least $MIN." >&2
  echo "A glob that matches nothing is not agreement. Either the path is wrong or" >&2
  echo "differentials were deleted — if deliberate, lower DIFFALL_MIN in this script." >&2
  # `${scripts[@]}` on an EMPTY array is an unbound-variable error under `set -u`
  # in bash 3.2 (macOS): the zero-constituent case -- the one that must be loudest
  # -- died at exit 1 here, i.e. reported as a divergence. Caught by mutation M4.
  [ "$found" -eq 0 ] || for s in "${scripts[@]}"; do echo "  found: $s" >&2; done
  exit 2
fi

# Belt and braces: DIFFALL_MIN=0 would slip an empty family past the floor, and
# zero comparisons is never agreement (#1516).
[ "$found" -gt 0 ] || { echo "INCONCLUSIVE: no constituents to run." >&2; exit 2; }

work=$(mktemp -d)
[ "${DIFFALL_KEEP:-0}" = "1" ] || trap 'rm -rf "$work"' EXIT

pass=0 fail=0 inconc=0 timeout=0 absent=0
: >"$work/failed"
: >"$work/undecided"
: >"$work/absent"

for s in "${scripts[@]}"; do
  name=$(basename "$s")
  log="$work/$name.log"
  start=$SECONDS

  # Own the process: spawn it, hold its PID, wait on that PID. `alarm` survives
  # exec, so the constituent inherits the deadline and dies with SIGALRM (142).
  ALARMRUN_KEEP_STDERR=1 alarmrun bash "$s" >"$log" 2>&1 &
  pid=$!
  wait "$pid"
  rc=$?
  elapsed=$((SECONDS - start))

  case "$rc" in
    0)
      verdict=PASS
      pass=$((pass + 1))
      ;;
    1)
      verdict=FAIL
      fail=$((fail + 1))
      echo "$name" >>"$work/failed"
      ;;
    2)
      if printf '%s\n' "$absent_list" | grep -qxF "$name"; then
        verdict=ABSENT
        absent=$((absent + 1))
        echo "$name" >>"$work/absent"
      else
        verdict=INCONCLUSIVE
        inconc=$((inconc + 1))
        echo "$name" >>"$work/undecided"
      fi
      ;;
    142)
      verdict=TIMEOUT
      timeout=$((timeout + 1))
      echo "$name" >>"$work/undecided"
      ;;
    *)
      verdict=ERROR
      inconc=$((inconc + 1))
      echo "$name" >>"$work/undecided"
      ;;
  esac

  printf '  %-12s %5ds  %-34s (exit %d)\n' "$verdict" "$elapsed" "$name" "$rc"
done

# Everything below is REPORTING. The verdicts are already decided above, so
# nothing below can influence any status.
#
# Full log, not a tail (#3678): the log was already captured whole at spawn
# time (`>"$log" 2>&1` above has no bound), so this only stops throwing part
# of it away. No marker string is grepped for -- each constituent reports a
# divergence in its own vocabulary (SAFEPOINT DIVERGENCE, MISMATCH:, DIFF,
# REGRESSION:, ...) and hardcoding any one of them here would special-case
# that constituent over the other seventeen.
for kind in failed undecided; do
  [ -s "$work/$kind" ] || continue
  while read -r name; do
    lines=$(wc -l <"$work/$name.log" 2>/dev/null | tr -d '[:space:]')
    echo
    echo "--- $name: full log ($lines lines) ---"
    cat "$work/$name.log"
  done <"$work/$kind"
done

# Copy the same logs somewhere that survives this script's own `rm -rf
# "$work"` EXIT trap below, and print the path -- the full print above covers
# a caller who redirected this script's own output, but not one running it
# interactively with nothing captured. Bounded on both axes: only the logs
# that need a second look are copied (not all $found), and a fresh KEEPDIR
# per run is reaped after 24h so it cannot accumulate the way a fixed-name
# scratch path would -- $TMPDIR is shared by every concurrent agent on this
# box, so a per-run unique prefix is required, never a fixed name.
if [ -s "$work/failed" ] || [ -s "$work/undecided" ]; then
  tmproot=${TMPDIR:-/tmp}
  find "$tmproot" -maxdepth 1 -name 'selfhost-diffall-keep.*' -type d -mmin +1440 \
    -exec rm -rf {} + 2>/dev/null || true
  keepdir=$(mktemp -d "$tmproot/selfhost-diffall-keep.XXXXXX")
  for kind in failed undecided; do
    [ -s "$work/$kind" ] || continue
    while read -r name; do
      cp "$work/$name.log" "$keepdir/$name.log" 2>/dev/null || true
    done <"$work/$kind"
  done
  echo
  echo "full logs for every failing/undecided constituent kept: $keepdir"
fi

echo
echo "diffall: PASS=$pass FAIL=$fail INCONCLUSIVE=$inconc TIMEOUT=$timeout ABSENT=$absent (of $found)"

if [ -s "$work/failed" ]; then
  echo "FAIL (real divergence):"
  while read -r name; do echo "  $name"; done <"$work/failed"
fi
if [ -s "$work/undecided" ]; then
  echo "UNDECIDED (no verdict — not a pass):"
  while read -r name; do echo "  $name"; done <"$work/undecided"
fi
if [ -s "$work/absent" ]; then
  echo "ABSENT (surface not implemented yet, tolerated by $ABSENT_SET):"
  while read -r name; do echo "  $name"; done <"$work/absent"
fi
[ "${DIFFALL_KEEP:-0}" = "1" ] && echo "logs kept: $work"

if [ "$fail" -gt 0 ]; then
  echo "diffall: RED — $fail constituent(s) diverged."
fi
if [ "$fail" -eq 0 ] && [ "$inconc" -eq 0 ] && [ "$timeout" -eq 0 ]; then
  echo "diffall: GREEN — every differential in the family agrees."
fi
diffexit "diffall" -f "$fail" -t "constituent(s)=$((inconc + timeout))"
