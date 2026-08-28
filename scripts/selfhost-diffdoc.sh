#!/usr/bin/env bash
# Self-host `bit doc` differential (#1590): run every corpus MODULE through both
# compilers' `doc` and compare the exported-surface bytes. `doc` derives a
# module's public API from the checker (not a text scrape), and `_tests_/bit/stdlibdocs.bit`
# fails the build on any undocumented export — so this surface is a live gate.
# This is the standing differential that keeps the
# two `doc` implementations in step.
#
# ## What is being compared
#
# The pinned stage0's `doc <dir>` output vs `bit doc <dir>` output, in BOTH forms — the plain
# "<kind> <name> <type>" listing and the `--json` array. The unit is a module
# DIRECTORY, not a `.bit` file: `bit doc` documents a whole module (its files are
# concatenated), and a lone-file root has no doc form (SPEC §17.1). So the corpus
# is `stdlib/*/`, `examples/*/` and `_tests_/imports/*/`, not a `-name '*.bit'` glob.
#
# ## Scope: only what the oracle can document
#
# A directory the oracle cannot `doc` (an internal helper dir that is not a
# module, or a module that does not compile) is out of scope and SKIPPED —
# exactly as difftypes skips files the oracle's checker rejects. Only the two
# compilers disagreeing on a module the oracle DID document is a finding.
#
# ## Concurrency (#3782)
#
# Per module directory, the ORACLE pair (plain + --json) and the BIT2 pair
# run CONCURRENTLY, not sequentially -- they are independent of each other
# and are only ever compared after both finish. #3770 measured the two
# halves as a near-even split (oracle=386.61s, bit2=386.47s of the family's
# ~815s), so overlapping them cuts this script's own wall clock close to in
# half. BIT2 now runs on every directory rather than only ones the ORACLE
# went on to accept -- see run_bit2_pair's comment for why that is safe.
#
# ## Preconditions are hard failures, never a vacuous green (#1514)
#
# Two gates: a missing binary aborts, and a compiler that does not IMPLEMENT `doc`
# aborts as ABSENT rather than scoring zero modules as agreement. A surface that
# does not exist has not been verified to match; it has not been tested at all,
# and those are opposite claims. And a corpus floor: comparing zero modules is
# never agreement (#1516).
#
# Read the exit code of the thing being tested, on its own line — never through a
# pipe (a `| tail` returns tail's status, which is how a red diffir read green,
# #1568). Nothing is inferred from output text.
#
# Usage: ./make selfhost && bash scripts/selfhost-diffdoc.sh
set -uo pipefail
# shellcheck source=scripts/alarmrun.sh
. "$(dirname -- "$0")/alarmrun.sh"
# shellcheck source=scripts/diffexit.sh
. "$(dirname -- "$0")/diffexit.sh"

# Oracle: the pinned stage0 -- the same compiler one release back, an EARLIER
# VERSION OF THIS SAME COMPILER, which is exactly what limits the claim below.
# scripts/stage0.sh downloads and DIGEST-VERIFIES it, and refuses rather
# than skipping. A green run proves no behaviour change versus the last
# release; it cannot catch a bug present in both — docs/release/bootstrap.md §4/§5.
ORACLE=${DIFFDOC_ORACLE:-$(sh scripts/stage0.sh)} || exit 2
# Overridable so the script can be mutation-tested against a known-agreeing and a
# known-disagreeing doc surface. The verdict line names what was actually compared.
BIT2=${DIFFDOC_BIT:-bit-out/bin/bit}
# The alarm is a HANG guard, not a performance budget (#2863): `doc` derives a
# module's public surface from the checker, comparable in cost to `check`,
# whose measured worst case over this exact corpus is ~1.2s
# (selfhost-diffcheck.sh). 20s matches the "basic" differentials in
# selfhost-diffdump.sh that bound a single fast subcommand. Overridable so a
# slower host does not read a scheduling delay as a hang.
TIMEOUT=${DIFFDOC_TIMEOUT:-20}

for bin in "$ORACLE" "$BIT2"; do
  [ -x "$bin" ] || { echo "diffdoc: missing $bin — run: ./make selfhost" >&2; exit 2; }
done

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# Capability probe, not a verdict: `doc` a throwaway module and see whether the
# subcommand exists at all. Exit status alone cannot tell "doc rejected this" from
# "there is no doc", so the usage text is what distinguishes them.
#
# Bounded like every other call in this script (#3389): a probe run before the
# main loop is still a call to an untrusted binary, and a hang here wedges the
# script before the guarded loop is ever reached — the same shape
# selfhost-diffcheck.sh's header warns about. A probe timeout is NOT evidence
# of absence (a hang proves nothing about whether `doc` exists), so it is never
# folded into the "unknown subcommand" / ABSENT path below: it is its own
# could-not-decide outcome, exit 2, same code the corpus-floor and ABSENT
# checks already use in this file for "nothing was compared".
probe_doc() {
  local bin=$1 dir="$work/probe.$2"
  mkdir -p "$dir"
  printf 'export fn inc(n: i64): i64 {\n  return n + 1\n}\n' >"$dir/m.bit"
  local out
  # Verdict-deciding (#3422): a single stall here aborts the WHOLE differential
  # as could-not-decide, so it gets alarmrun_retry's one retry like the main
  # loop below, not the bare alarmrun the two forbidden report sites keep.
  out=$(ALARMRUN_KEEP_STDERR=1 alarmrun_retry "$2" "" "$bin" doc "$dir" 2>&1)
  local rc=$?
  if [ "$rc" -eq 142 ]; then
    echo "diffdoc: PROBE TIMEOUT — $bin hung on the capability probe after ${TIMEOUT}s" >&2
    echo "diffdoc: nothing was compared — a hung probe is not evidence of absence." >&2
    exit 2
  fi
  if printf '%s' "$out" | grep -q 'unknown subcommand'; then
    return 1
  fi
  return 0
}

absent=""
probe_doc "$ORACLE" seed || absent="$absent $ORACLE"
probe_doc "$BIT2" bit2 || absent="$absent $BIT2"
if [ -n "$absent" ]; then
  echo "diffdoc: ABSENT — no \`doc\` subcommand in:$absent"
  echo "diffdoc: nothing was compared. This is NOT agreement — the surface is unimplemented."
  exit 2
fi

: >"$work/mismatch"
: >"$work/timeout"
match=0 skip=0 nonempty=0

# doc_surface_nonempty <json-file> -- true iff the ORACLE's `doc --json` array
# in <json-file> has at least one entry (#3518). docJson (compiler/doc.bit)
# renders each symbol as exactly ONE line, `  {"name": ...}`, and never
# breaks a line inside an entry -- docVariantsJson's own "[...]" stays inline
# on that same line, including a type string like "[]u8". So counting lines
# with this fixed two-space-then-`{"name":` prefix cannot mistake a bracket
# inside a type for a second entry, which is the trap that broke a naive
# strip-and-count attempt at this ticket (false positives on `json`, `quic`).
# An empty array is exactly the two lines `[` and `]`, so the count is 0.
doc_surface_nonempty() {
  [ "$(grep -c '^  {"name": ' "$1")" -gt 0 ]
}

# run_oracle_pair / run_bit2_pair <dir> -- the two per-module halves (#3782).
# Backgrounded concurrently by the loop below instead of run sequentially:
# they are compared only after both finish, so nothing downstream needs them
# in order, and #3770 measured the two halves at oracle=386.61s/bit2=386.47s
# -- a near-even split, so overlapping them cuts this script's wall clock
# close to in half.
#
# Each writes ONLY to its own files ($work/seed.* / $work/oracle.status vs
# $work/bit.* / $work/bit2.status) so the two backgrounded subshells never
# race on a shared path. The decision tree that reads the two status files
# back is UNCHANGED from the sequential version -- only how the four
# alarmrun_retry calls are scheduled moved; every rc comparison below is
# byte-for-byte the same branch the old inline loop made.
#
# bash 3.2 (this Mac's /bin/bash) has no `wait -n`, but that primitive is for
# reaping "whichever of N finishes first" -- here N is fixed at exactly 2 and
# the caller needs BOTH before it can decide anything, so a plain `wait "$pid"`
# on each of the two held PIDs (order irrelevant) is sufficient and needs no
# FIFO. `kill -0` is not used anywhere in this file.
#
# Deliberate change from the sequential version (ticket-sanctioned: "keep
# [the SKIP short-circuit] or change it deliberately"): BIT2 now runs on
# EVERY directory, concurrently with ORACLE, even one the oracle will go on
# to SKIP or time out on -- discovering that only after both have already
# run costs nothing extra in wall clock (they were concurrent), and the
# decision tree below still discards BIT2's result on that path exactly as
# before, so SKIP/TIMEOUT/MATCH/MISMATCH counts are unaffected.
run_oracle_pair() {
  local d=$1 seed_rc seed_json_rc=skipped
  # The oracle is bounded too (#2863): it had no bound at all here, so a hung
  # ORACLE wedged this script indefinitely — exactly the shape
  # selfhost-diffcheck.sh's header warns about ("the seed side had no bound at
  # all, so a hung ORACLE wedged the whole gate indefinitely"). Verdict-deciding
  # (#3422): alarmrun_retry's one retry-on-stall, outfile "" since the redirect
  # below already targets a fresh per-iteration path.
  alarmrun_retry ORACLE "" "$ORACLE" doc "$d" >"$work/seed.plain"
  seed_rc=$?
  if [ "$seed_rc" -eq 0 ]; then
    alarmrun_retry ORACLE "" "$ORACLE" doc --json "$d" >"$work/seed.json"
    seed_json_rc=$?
  else
    : >"$work/seed.json"
  fi
  printf '%s %s\n' "$seed_rc" "$seed_json_rc" >"$work/oracle.status"
}

run_bit2_pair() {
  local d=$1 bit_rc bit_json_rc
  alarmrun_retry BIT2 "" "$BIT2" doc "$d" >"$work/bit.plain"
  bit_rc=$?
  alarmrun_retry BIT2 "" "$BIT2" doc --json "$d" >"$work/bit.json"
  bit_json_rc=$?
  printf '%s %s\n' "$bit_rc" "$bit_json_rc" >"$work/bit2.status"
}

for d in stdlib/*/ examples/*/ _tests_/imports/*/; do
  [ -d "$d" ] || continue

  run_oracle_pair "$d" &
  oracle_pid=$!
  run_bit2_pair "$d" &
  bit2_pid=$!
  # Both PIDs are always waited on before either status file is read, so a
  # backgrounded call never outlives this iteration as an orphan/zombie --
  # regardless of which branch below discards its result.
  wait "$oracle_pid"
  wait "$bit2_pid"
  read -r seed_rc seed_json_rc <"$work/oracle.status"
  read -r bit_rc bit_json_rc <"$work/bit2.status"

  if [ "$seed_rc" -ge 128 ]; then
    echo "$d (ORACLE timed out after ${TIMEOUT}s, rc=$seed_rc)" >>"$work/timeout"
    continue
  fi
  # A directory the oracle cannot document is out of scope.
  if [ "$seed_rc" -ne 0 ]; then
    skip=$((skip + 1))
    continue
  fi
  if [ "$seed_json_rc" -ge 128 ]; then
    echo "$d (ORACLE --json timed out after ${TIMEOUT}s, rc=$seed_json_rc)" >>"$work/timeout"
    continue
  fi
  # Classified once, from the ORACLE side, as soon as its surface is known --
  # counted into $nonempty below only on a path that also counts into
  # $match/$mismatch, so the denominator always covers exactly the
  # $compared set, never a BIT2-timeout or an oracle SKIP.
  module_nonempty=0
  doc_surface_nonempty "$work/seed.json" && module_nonempty=1

  if [ "$bit_rc" -ge 128 ] || [ "$bit_json_rc" -ge 128 ]; then
    echo "$d (BIT2 timed out after ${TIMEOUT}s, rc=$bit_rc/$bit_json_rc)" >>"$work/timeout"
    continue
  fi

  if [ "$bit_rc" -ne 0 ] || [ "$bit_json_rc" -ne 0 ]; then
    echo "$d (bit doc exit $bit_rc / --json exit $bit_json_rc, seed exit 0)" >>"$work/mismatch"
    [ "$module_nonempty" -eq 1 ] && nonempty=$((nonempty + 1))
    continue
  fi

  if cmp -s "$work/seed.plain" "$work/bit.plain" && cmp -s "$work/seed.json" "$work/bit.json"; then
    match=$((match + 1))
  else
    echo "$d" >>"$work/mismatch"
  fi
  [ "$module_nonempty" -eq 1 ] && nonempty=$((nonempty + 1))
done

mismatch=$(wc -l <"$work/mismatch" | tr -d ' ')
timeouts=$(wc -l <"$work/timeout" | tr -d ' ')
compared=$((match + mismatch))
echo "doc differential ($ORACLE vs $BIT2): MATCH=$match MISMATCH=$mismatch TIMEOUT=$timeouts SKIP(not a module)=$skip ($nonempty of $compared compared module(s) have a non-empty exported surface)"

# Corpus floor (#1516): comparing nothing is not agreement.
if [ "$compared" -eq 0 ]; then
  echo
  echo "INVALID: zero modules were compared — no evidence of agreement."
  exit 2
fi

# Surface-collapse guard (#3553): a structural rule, not a hardcoded floor --
# 25 non-empty stdlib modules is what the tree happens to hold today and WILL
# go stale (this repo has had a hardcoded corpus count go stale three times:
# expectedCases, the corpus MATCH baseline, the release asset count). What
# never changes is that zero is always wrong: $compared > 0 with $nonempty
# == 0 means every one of those comparisons was empty-vs-empty, so
# MATCH=$match is a gate reporting it compared NOTHING, in the shape of a
# pass -- the "measurement query must prove itself non-zero" trap, one level
# deeper than #3518's denominator print. Printed unconditionally (not only
# on the would-be-clean-pass path below) so it is visible even when a
# mismatch or timeout report follows it.
surface_collapsed=0
if [ "$compared" -gt 0 ] && [ "$nonempty" -eq 0 ]; then
  surface_collapsed=1
  echo
  echo "REFUSED: 0 of $compared compared module(s) have a non-empty exported surface."
  echo "         Every comparison above is empty-vs-empty -- MATCH=$match proves nothing;"
  echo "         this differential's entire discriminating power just vanished."
fi

if [ -s "$work/mismatch" ]; then
  echo
  # EVERY divergence, named — a "first divergence" report leaves the rest invisible.
  echo "MISMATCH: $mismatch module(s) the two doc surfaces render differently:"
  while read -r d; do echo "  $d"; done <"$work/mismatch"
  head -3 "$work/mismatch" | while read -r d; do
    dir=${d%% *}
    echo
    echo "--- diff (seed vs bit): $dir"
    # Bounded on BOTH sides here too, exactly as the compare loop runs them —
    # an unbounded oracle in the failure report would hang a run that already
    # failed.
    alarmrun "$ORACLE" doc "$dir" >"$work/da"
    alarmrun "$BIT2" doc "$dir" >"$work/db"
    diff "$work/da" "$work/db" | head -12
  done
fi

if [ -s "$work/timeout" ]; then
  echo
  echo "INVALID: $timeouts module(s) timed out after ${TIMEOUT}s — no verdict, not a match:"
  while read -r d; do echo "  $d"; done <"$work/timeout"
fi

# A timeout used to set the same status=1 a real mismatch does (#3382 sibling
# finding, same shape as #3351/#3377/#3378/#3379/#3380): diffexit restores the
# could-not-decide (2) distinction.
if [ "$mismatch" -eq 0 ] && [ "$timeouts" -eq 0 ]; then
  if [ "$surface_collapsed" -eq 1 ]; then
    # Would otherwise be the clean exit-0 "agree" path below -- refuse
    # instead of printing it. A collapsed surface is not evidence of
    # agreement, so a silent green here is exactly the false pass #3553
    # exists to close. Exit 2 (could-not-decide), not 1: nothing diverged,
    # so this is not the same claim a real MISMATCH makes, and not 0: a
    # comparison of nothing is not a pass either (same reasoning as the
    # compared==0 corpus floor above, distinct wording per #3553's own
    # constraint not to reuse INVALID).
    echo
    echo "diffdoc: REFUSING to report agreement — see REFUSED above."
    exit 2
  fi
  echo
  echo "diffdoc: the two doc surfaces agree on every compared module."
fi
diffexit "doc" -f "$mismatch" -t "module(s)=$timeouts"
