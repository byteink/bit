#!/usr/bin/env bash
# Self-host CHECK differential: run every corpus `.bit` through both compilers'
# `check` and diff the rendered diagnostics.
#
# This is the guard the other differentials structurally cannot be. difftypes
# SKIPs every file the oracle rejects (202 of them — the entire invalid-program
# corpus); diffdiags only covers lex+parse, because the oracle's `--dump-diags` is
# front-end only; diffexamples only ever builds VALID programs. So a green board
# across all three said nothing about whether bit2 REJECTS what the oracle
# rejects — and for a long time it rejected nothing at all, silently compiling
# `function f(): i32 { return "hi" }` into a binary that printed a raw pointer.
#
# Four outcomes, and the asymmetry between the last two is the point. Verdict
# (accept/reject) is read from the EXIT CODE, never from stderr emptiness —
# #2499 fixed a proxy that misread any warning-severity diagnostic rendered on
# an ACCEPTED program (#2491) as a rejection, because it used to classify by
# whether the captured stderr text was empty instead of by $src/$brc:
#   MATCH    both compilers reach the same accept/reject verdict, and — when
#            both rejected — the rendered diagnostics are byte-identical. Both
#            ACCEPTING is always a MATCH even if one side also rendered a
#            warning the other's pinned oracle predates: this differential's
#            job is accept/reject fidelity (see above), not warning-text
#            parity on valid programs — that is diffverdict's explicit
#            non-goal for the reject side, applied here to the accept side.
#   MISSING  the oracle rejects, bit2 accepts    — a gap: an emit site not ported
#            yet. Expected to shrink; harmless (the oracle is still the gate).
#   FALSEPOS bit2 rejects, the oracle accepts    — a BUG, and the dangerous one:
#            bit2 refusing valid code breaks builds. Must stay 0.
#   DIFF     both reject, different text        — usually a cascade: bit2 report
#            a downstream error because the root site is not ported.
#
# Diagnostics go to stderr (both compilers), so stdout is discarded.
#
# PATH NORMALIZATION (historical): the oracle's file-check CLI absolutizes the
# display path (it routes a lone file through
# `checkHostProject(absFromCwd(dirname), basename)`, introduced when a lone
# .bit file became a module in 83b511f), so it used to render
# `--> /abs/repo/stdlib/x.bit` where bit2 rendered the path AS GIVEN —
# `--> stdlib/x.bit` — which is what gcc, clang and rustc all do, and what the
# `.expected` goldens encode. That mismatch was once papered over by stripping
# the repo-root prefix from the oracle's output before comparing (44 path-diffs
# at the time, all cosmetic). See the #1893 block below: that filter is gone,
# superseded by pinning BIT_STDLIB identically for both sides, and the script
# now has no path filter of any kind.
#
# A TIMEOUT IS NOT AN OUTCOME (#1538). The alarm-guarded run's exit status used
# to be discarded, so a killed `bit` yielded an empty output that was then
# classified by CONTENT — the classic shape of #1512/#1513/#1514/#1524/#1525.
# Both directions were wrong, and both landed in numbers this workstream steers
# by: a non-empty oracle side scored MISSING (false red straight into the tracked
# MISSING 24 -> 7 -> 4 metric), and the common case of a file with no
# diagnostics scored `"" = ""` -> MATCH (silent false green: never compared).
# Now a timeout gets its own counter and `continue`s BEFORE any comparison, so
# the classification is structurally unreachable unless both sides produced a
# result. Two empty outputs can no longer meet each other.
#
# Exit codes (matching x64gate.sh / selfhost-diffsafepoints.sh / 3977211):
#   0  every file compared, no false positive
#   1  real failure: a FALSEPOS (bit rejects code the oracle accepts)
#   2  could not decide: a file timed out and was never compared. Not a pass.
#
# Usage: ./make selfhost && bash scripts/selfhost-diffcheck.sh
set -u
# shellcheck source=scripts/alarmrun.sh
. "$(dirname -- "$0")/alarmrun.sh"
# shellcheck source=scripts/diffexit.sh
. "$(dirname -- "$0")/diffexit.sh"

# Oracle: the pinned stage0 -- the same compiler one release back, an EARLIER
# VERSION OF THIS SAME COMPILER, which is exactly what limits the claim below.
# scripts/stage0.sh downloads and DIGEST-VERIFIES it, and refuses rather
# than skipping, so a failure here is loud. A green run proves no behaviour
# change versus the last release; it cannot catch a bug present in both —
# docs/release/bootstrap.md §4/§5.
ORACLE="$(sh scripts/stage0.sh)" || exit 2
BIT2=bit-out/bin/bit

# BOTH SIDES must reach the working tree's stdlib THROUGH THE SAME PATH STRING,
# not merely reach the same files (#1920). stage0.sh's wrapper already pins
# BIT_STDLIB for the oracle; BIT2 ran bare, and `stdRootPath` (compiler/main.bit)
# then fell through `resolveNearExe` — there is no `bit-out/stdlib` — to the
# cwd-relative literal `"stdlib"`. A diagnostic's path is whatever string the
# module loader recorded (compiler/project.bit stores `pathResolve(dir)/name`,
# and pathResolve is lexical, so it never absolutises), which made the two sides
# render the same file differently and cost seven files a real comparison.
# Exporting here covers both: the wrapper's `${BIT_STDLIB:-…}` takes this value
# instead of substituting its own.
BIT_STDLIB="$(pwd)/stdlib"
export BIT_STDLIB

# The alarm is a HANG guard, not a performance budget. Measured worst legitimate
# case over this exact corpus is 1.23s (`bit check tests/imports/nethttp/main.bit`,
# on a host running 9 parallel agents) against a 20s budget — 16x headroom, so no
# real work was ever near it and every trip was a DESCHEDULED process, not a slow
# one. Raising the constant would fix a cause that does not exist, so instead a
# trip is RETRIED ONCE: a genuine hang is deterministic and trips twice, a load
# artifact does not. TIMEOUT_S overrides for a slower host.
TIMEOUT_S=${TIMEOUT_S:-20}

# Alarm-guarded run; captures diagnostics (stderr) and discards stdout.
# The exit status is LOAD-BEARING and must be read by every caller: it returns
# 142 (128+SIGALRM) iff the run timed out TWICE. Retry-once-on-stall is
# scripts/alarmrun.sh's alarmrun_retry (#3408); no persistent artifact to clean
# between attempts here, so its outfile arg is "".
run() {
  local out rc side
  local TIMEOUT="$TIMEOUT_S"
  [ "$1" = "$ORACLE" ] && side=ORACLE || side=BIT2
  out=$(ALARMRUN_KEEP_STDERR=1 alarmrun_retry "$side" "" "$@" 2>&1 >/dev/null)
  rc=$?
  printf '%s' "$out"
  return "$rc"
}

# run_cap <side> <capture> <cmd...> -- like run() above, but writes stderr to
# a FILE instead of returning it via `$(...)`, so the caller can background
# it: a shell variable assigned inside `$(...)` run in `&` never reaches the
# parent shell, but a file written before the child exits, read after `wait`
# returns, does (#3783). Mirrors alarmrun_retry's own retry-once-on-stall
# shape rather than calling it directly, because alarmrun_retry_cap merges
# stdout into the capture and this differential discards stdout (see run()
# above) -- so <capture> is truncated before EACH attempt here, same as
# alarmrun_cap does for its own merged capture and for the same reason
# (#3478): a stalled first attempt's partial bytes must never survive into a
# retry's compared payload.
run_cap() {
  local side=$1 cap=$2 rc
  shift 2
  local TIMEOUT="$TIMEOUT_S"
  : >"$cap"
  ALARMRUN_KEEP_STDERR=1 alarmrun "$@" 2>"$cap" >/dev/null
  rc=$?
  if [ "$rc" -eq 142 ]; then
    echo "$side check stalled once (SIGALRM after ${TIMEOUT_S}s), retrying: $*" >&9
    : >"$cap"
    ALARMRUN_KEEP_STDERR=1 alarmrun "$@" 2>"$cap" >/dev/null
    rc=$?
  fi
  return "$rc"
}

match=0 missing=0 falsepos=0 diff=0 timeout=0 firstfp="" firstdiff="" firsthang=""
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
seedcap="$work/seed.out"
b2cap="$work/b2.out"
for f in $(find stdlib examples tests/cases tests/imports -name '*.bit' | sort); do
  # ORACLE and BIT2 are independent per file -- compared only after both
  # return -- so run them CONCURRENTLY rather than back-to-back (#3783).
  # Each is still independently alarm-guarded, so a hung ORACLE still cannot
  # wedge the whole gate: it only stalls this one file's own iteration.
  run_cap ORACLE "$seedcap" "$ORACLE" check "$f" &
  oraclepid=$!
  run_cap BIT2 "$b2cap" "$BIT2" check "$f" &
  bit2pid=$!
  wait "$oraclepid"; src=$?
  wait "$bit2pid"; brc=$?
  seed=$(cat "$seedcap")
  b2=$(cat "$b2cap")
  if [ "$src" -eq 142 ] || [ "$brc" -eq 142 ]; then
    # Undecided: this file was never compared. Counted on its own, and
    # deliberately NOT folded into MISSING or FALSEPOS — those are tracked,
    # pinned counts, and an undecided file sitting inside them corrupts the pin.
    timeout=$((timeout + 1))
    [ -z "$firsthang" ] && firsthang="$f (SIGALRM after ${TIMEOUT_S}s x2, seed=$src bit=$brc)"
    continue
  fi
  # ONE NORMALIZATION, AND IT IS LOAD-BEARING (#1893).
  #
  # There were two. Both were assumed inert; measuring the whole 619-file corpus
  # against the 0.1.4 stage0 — which is what #1893 asked for, rather than the
  # single file they had been spot-checked on — split them:
  #
  #   grep -v '^error: CheckFailed$'   0 of 619 files. Genuinely dead, deleted.
  #                                    That line was never a diagnostic anyway; it
  #                                    was a runtime reporting main's error return.
  #   sed "s#--> ${ROOT}#--> #"        7 of 619 files. Was LIVE; now deleted, see
  #                                    below — the cause was fixed, not filtered.
  #
  # THE PREDICTION THAT SAT HERE WAS WRONG, and it is worth recording because it
  # would have kept this filter forever. It said the line "retires by itself —
  # repin stage0 to any release cut from this tree and the oracle starts printing
  # relative paths too". Measured against the actual 0.1.5 oracle after the pin
  # moved, it still printed absolute. Nothing about the compiler changed between
  # 0.1.4 and this tree; the SAME binary prints either form depending only on
  # BIT_STDLIB, and the wrapper hands the oracle an absolute one. No release can
  # ever retire this on its own.
  #
  # The seven were stdlib/{http3/h3,quic/{conn,packet,tls},tls/{ciphersuites,
  # client,server}}.bit — the files whose diagnostics point into an IMPORTED
  # stdlib file rather than the one named on the command line, which is exactly
  # the set that resolves through `stdRoot`. Pinning BIT_STDLIB for both sides at
  # the top of this file makes them render identically, so the filter measures
  # dead and is gone.
  #
  # A filter on a differential's ORACLE side can only ever hide a difference,
  # never reveal one — the same hazard #1883 deleted the expected-mismatch lists
  # for. Fix the cause; do not add another.
  #
  # VERDICT FIRST, FROM THE EXIT CODE (#2499). $seed/$b2 text is consulted only
  # to split a same-verdict REJECT into MATCH vs DIFF; it never decides
  # accept-vs-reject, and a same-verdict ACCEPT is always MATCH regardless of
  # text (see the header — this is deliberately not warning-text parity).
  if [ "$src" -eq 0 ] && [ "$brc" -eq 0 ]; then
    match=$((match + 1))
  elif [ "$src" -ne 0 ] && [ "$brc" -ne 0 ]; then
    if [ "$seed" = "$b2" ]; then
      match=$((match + 1))
    else
      diff=$((diff + 1))
      [ -z "$firstdiff" ] && firstdiff="$f"
    fi
  elif [ "$src" -eq 0 ] && [ "$brc" -ne 0 ]; then
    falsepos=$((falsepos + 1))
    [ -z "$firstfp" ] && firstfp="$f"
  else
    missing=$((missing + 1))
  fi
done
echo "check differential: MATCH=$match MISSING=$missing FALSEPOS=$falsepos DIFF=$diff TIMEOUT=$timeout"
if [ -n "$firstfp" ]; then
  echo "=== FIRST FALSE POSITIVE (bit2 rejects code the seed accepts): $firstfp"
  run "$BIT2" check "$firstfp" | head -8
fi
if [ -n "$firstdiff" ]; then
  echo "=== first differing text: $firstdiff"
  # Both sides raw, exactly as the compare above sees them. The two must not
  # drift, or the evidence printed here describes a comparison that was never
  # made — which is why the normalization that used to sit on this line came out
  # with the one in the loop (#1920), not separately.
  diff <(run "$ORACLE" check "$firstdiff") \
       <(run "$BIT2" check "$firstdiff") | head -14
fi
# Only a false positive is a build-breaking regression; MISSING shrinks as emit
# sites land, and DIFF is dominated by cascades from unported root sites.
[ "$timeout" -gt 0 ] && echo "first timeout: $firsthang"
diffexit "check" -f "$falsepos" -t "file(s)=$timeout"
