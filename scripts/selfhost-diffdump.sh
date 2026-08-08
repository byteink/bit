#!/usr/bin/env bash
# Table-driven differential driver (#2743). selfhost-diff{ast,tokens,diags,
# types,ir,iropt}.sh were six copies of the same script, one flag apart, and
# three of the six (ast/tokens/diags) had no timeout guard at all — a hung
# oracle or a hung working-tree `bit` wedged the gate indefinitely. This is one
# driver plus a data table (the six `case` arms below, one per row); the six
# old paths are now thin wrappers that `exec` into `selfhost-diffdump.sh
# <name>`.
#
# BOTH sides of every comparison are now alarm-guarded (perl `alarm`, the same
# mechanism the three already-guarded siblings used) — see
# selfhost-diffcheck.sh's header for why that guard exists: "the seed side had
# no bound at all, so a hung ORACLE wedged the whole gate indefinitely."
#
# THE COMMENTS BELOW ARE CARRIED OVER VERBATIM FROM THE SIX FILES THIS
# REPLACES, one block per original file, unedited — including the "two
# independent implementations" framing in the `tokens` block below, which is
# no longer accurate now that the oracle is the pinned stage0 rather than a
# second implementation (#2600 owns fixing that prose across the family; this
# ticket is a pure code consolidation and does not touch it).
#
# Usage: ./make selfhost && bash scripts/selfhost-diffdump.sh <name>
#   name: ast | tokens | diags | types | ir | iropt
set -uo pipefail

ROOT="$(cd -- "$(dirname -- "$0")/.." && pwd)"
CORPUS="stdlib examples tests/cases tests/imports"
# shellcheck source=scripts/selfhost-ir-canon.sh
. "${ROOT}/scripts/selfhost-ir-canon.sh"

NAME="${1:?usage: selfhost-diffdump.sh <ast|tokens|diags|types|ir|iropt>}"

# --- from scripts/selfhost-diffast.sh ---
# AST differential (#1332/#1335): parse every corpus `.bit` file with both the
# oracle and this tree's `bit` and diff their `--dump-ast` output. They must be
# byte-identical. Files the oracle rejects with a parse/lex error are skipped:
# the two sides do not agree on how far to parse past an error, so a rejected
# file compares diagnostics rather than trees and belongs to diffdiags.
#
# Usage: ./make selfhost && bash scripts/selfhost-diffast.sh
# Exits non-zero (printing the first divergence) on any mismatch.
#
# --- from scripts/selfhost-difftokens.sh ---
# Token differential (#1332/#1334): lex every corpus `.bit` file with both the
# PINNED STAGE0 (the previous release) and the working tree's compiler, and diff
# their `--dump-tokens` output. They must be byte-identical. Files the oracle
# rejects with a lex error are skipped — the two lexers disagree about how far
# to lex past an error, so those files measure the diagnostic renderer rather
# than the lexer.
#
# THE ORACLE CHANGED IN #1593, AND SO DID WHAT A GREEN RUN MEANS. It used to be
# `bit-out/bin/bit-seed`, a compiler written in a different language, so green
# meant "two independent implementations agree". It is now the last release of
# this same compiler, so green means "this version did not change behaviour
# versus the last release". See docs/release/bootstrap.md §4/§5 — the loss is
# recorded there, not papered over.
#
# Usage: ./make selfhost && bash scripts/selfhost-difftokens.sh
# Exits non-zero (printing the first divergence) on any mismatch.
#
# --- from scripts/selfhost-diffdiags.sh ---
# Self-host front-end diagnostic differential (#1335/#363): run every corpus
# `.bit` file through both compilers' `--dump-diags` (lexer + parser diagnostics
# only — resolve/check is Stage 2 and not yet ported) and diff. They must be
# byte-identical: empty for a clean file, and the same rendered diagnostic for a
# lex/parse error. Unlike difftokens/diffast this skips nothing — a valid file
# produces empty output from both, and the seed's --dump-diags is frontend-only
# so checker `// error` cases are empty on both sides too.
#
# Usage: ./make selfhost && bash scripts/selfhost-diffdiags.sh
# Exits non-zero (printing the first divergence) on any mismatch.
#
# --- from scripts/selfhost-difftypes.sh ---
# Self-host type differential (#1337/#364): run every corpus `.bit` through both
# compilers' `--dump-types` (the binding/param/call type dump) and diff. Files
# the seed rejects at check time are skipped (bit2's checker is still partial).
# This tracks Stage-2 inference coverage: MATCH grows as more constructs are
# ported; a byte diff pins the exact expression whose inferred type differs.
#
# ## It had no exit status either (#1478)
#
# Found by the #1478 audit, one script down from `selfhost-diffiropt.sh`: this
# printed `MISMATCH=n` and a first-divergence diff, then fell off the end at the
# `if`'s status — always 0. Quoting it as verification was never a true claim.
#
# No expected-gap set here, deliberately: unlike the IR differentials this one
# is at MISMATCH=0, so the expectation is simply "none", and a set file would be
# an empty ceremony. If a gap ever has to be tolerated, add one then — do not
# pin a count.
#
# A timeout is not evidence: a `bit` run killed by the alarm produced no verdict,
# so it is reported separately and fails, rather than being scored as a mismatch.
#
# Usage: ./make selfhost && bash scripts/selfhost-difftypes.sh
#
# --- from scripts/selfhost-diffir.sh ---
# Self-host IR (pre-opt) differential (#1337/#364): run every corpus `.bit` through both
# compilers' `--dump-ir-pre` (the lowered SSA text) and diff. Files the oracle cannot
# lower/check are skipped (bit2's lowering is still partial). This tracks
# Stage-2 lowering coverage: MATCH grows as more constructs lower; a byte diff
# pins the exact function whose IR differs.
#
# ## Why this gates on the SET, not the count (#1469)
#
# It used to print `MISMATCH=4` and name only the first offender. A count is not
# a set: MATCH could grow 141 -> 145 with MISMATCH steady at 4 while a known gap
# quietly closed and a fresh regression opened in its place, and the two runs
# would read identically. Three quarters of the claim was unverifiable.
#
# So every mismatching path is NAMED, and any mismatch at all fails the gate.
# There was an expected-mismatch list for a while, so a known difference could be
# written down instead of fixed; its last entry closed and it was deleted with its
# reader (#1883). Nothing is permitted to differ now.
#
# A timeout is likewise not evidence. A file whose run is killed by the alarm is
# reported separately and fails the gate, rather than being folded into the
# mismatch count — a load-sensitive counter that silently self-confirms is the
# exact bug this script was fixed for.
#
# ## The bound, and why BOTH sides carry it (#2070)
#
# The alarm is a HANG guard, not a performance budget, so it belongs well above
# the slowest legitimate file rather than beside it. 20s was below the corpus's
# worst case measured on the post-opt twin (25.20s wall on this tree, 21.86s on
# the oracle, for tests/imports/cryptomldsa/main.bit); pre-opt IR is cheaper and
# escaped by luck, not by design. 300s matches the sibling and is ~12x that.
#
# The oracle used to run UNBOUNDED, so a hung stage0 wedged this script with no
# message. Folding that into SKIP would be worse: a skip means the oracle
# legitimately declined the file, and quietly shrinking the corpus is how a gate
# stops asserting anything. Both sides are bounded, with separate outcomes.
#
# Usage: ./make selfhost && bash scripts/selfhost-diffir.sh
#
# --- from scripts/selfhost-diffiropt.sh ---
# Self-host POST-opt IR differential (#1339): diff `bit --dump-ir` (optimized)
# against the pinned stage0's optimized `--dump-ir` over the corpus. Tracks optimizer
# coverage — MATCH grows as fold/DCE/inline passes land. Mirror of
# selfhost-diffir.sh but for the post-optimizer surface.
#
# ## Why this gates on the SET, not the count (#1478)
#
# It used to print `MISMATCH=3`, name only the first offender, and exit 0 — so
# it could not fail under any circumstance, and its output was quoted as
# verification anyway. Two separate defects: no verdict, and a count where a set
# was needed. A count is not a set: MATCH could grow while MISMATCH held steady
# because a known gap closed and a fresh regression opened in its place, and the
# two runs would read identically.
#
# A timeout is likewise not evidence. A file whose run is killed by the alarm is
# reported separately and fails the gate, rather than being scored as a mismatch
# that happens to sit in the expected set.
#
# ## The bound, and why BOTH sides carry it (#2070)
#
# The alarm is a HANG guard, not a performance budget, so it must sit well above
# the slowest legitimate file rather than near it. It was 20s while the corpus's
# worst case — tests/imports/cryptomldsa/main.bit — needed 25.20s wall and ~14s
# CPU on THIS tree and 21.86s on the oracle. That is not a margin; the gate went
# red with MISMATCH=0 whenever the box was busy, which is the shape docs/development.md
# warns about ("do not read a TIMED OUT as a hang until you have timed the
# program standalone"). 300s is ~12x the slowest observed file, in the spirit of
# the suite's own 900s-against-158s choice from #1637/#1652.
#
# The oracle used to run UNBOUNDED, so a hung stage0 wedged this script forever
# with no message — and merging that into SKIP would have been worse, since a
# skip means "the oracle legitimately could not lower this" and silently
# shrinking the corpus is how a gate stops asserting anything. Both sides are
# bounded, and an oracle timeout is its own reported outcome.
#
# Usage: ./make selfhost && bash scripts/selfhost-diffiropt.sh

# name    | flag           | verdict label   | skip label        | verb (ir only) | kind  | timeout (env, default)
case "$NAME" in
  ast)    FLAG=--dump-ast;    LABEL="AST";           SKIPLABEL="parse-err";       VERB="";         KIND=basic; TIMEOUT="${DIFFAST_TIMEOUT:-20}" ;;
  tokens) FLAG=--dump-tokens; LABEL="token";         SKIPLABEL="lex-err";         VERB="";         KIND=basic; TIMEOUT="${DIFFTOKENS_TIMEOUT:-20}" ;;
  diags)  FLAG=--dump-diags;  LABEL="diag";          SKIPLABEL="";                VERB="";         KIND=basic; TIMEOUT="${DIFFDIAGS_TIMEOUT:-20}" ;;
  types)  FLAG=--dump-types;  LABEL="type";          SKIPLABEL="check-err";       VERB="";         KIND=types; TIMEOUT="${DIFFTYPES_TIMEOUT:-20}" ;;
  ir)     FLAG=--dump-ir-pre; LABEL="IR (pre-opt)";  SKIPLABEL="lower/check-err"; VERB="pre-opt";  KIND=ir;    TIMEOUT="${DIFFIR_TIMEOUT:-300}" ;;
  iropt)  FLAG=--dump-ir;     LABEL="IR (post-opt)"; SKIPLABEL="lower/check-err"; VERB="post-opt"; KIND=ir;    TIMEOUT="${DIFFIROPT_TIMEOUT:-300}" ;;
  *) echo "selfhost-diffdump: unknown differential '${NAME}' (want ast|tokens|diags|types|ir|iropt)" >&2; exit 2 ;;
esac
PREFIX="diff${NAME}"

# The oracle is the PINNED STAGE0: the previous release, i.e. an EARLIER VERSION
# OF THIS SAME COMPILER — which is exactly what limits the claim below.
# scripts/stage0.sh downloads and DIGEST-VERIFIES it, and refuses rather
# than skipping, so a failure here is loud. What a green run asserts changed with
# it: "unchanged versus the last release", not "two implementations agree" —
# docs/release/bootstrap.md §4/§5.
ORACLE="$(sh "${ROOT}/scripts/stage0.sh")" || exit 2
BIT2="${ROOT}/bit-out/bin/bit"

# A missing compiler must ABORT, never score a vacuous green (#1514): both sides
# of the differential would produce empty output, and equal-empty compares as
# agreement. Exit 2 to keep this distinct from a real divergence (exit 1).
# [diags' version of the same point:] This gate is the worst of the family
# without it: both sides render empty, and since it skips nothing every file
# scores MATCH — a full green board from no compiler.
for bin in "$ORACLE" "$BIT2"; do
  [ -x "$bin" ] || { echo "${PREFIX}: missing $bin — run: ./make selfhost" >&2; exit 2; }
done

alarmrun() { perl -e 'alarm shift; exec @ARGV' "$TIMEOUT" "$@" 2>/dev/null; }

# Why a child died, for the report. 128+N is death by signal N; 14 is the alarm
# this script set, so that alone is a timeout and every other signal is a crash.
whydied() {
  case "$1" in
    142) echo "timed out after ${TIMEOUT}s" ;;
    139) echo "CRASHED (SIGSEGV)" ;;
    138) echo "CRASHED (SIGBUS)" ;;
    134) echo "CRASHED (SIGABRT)" ;;
    *)   echo "CRASHED (signal $(( $1 - 128 )))" ;;
  esac
}

# ast/tokens/diags row bodies: a single MATCH/MISMATCH pass, first divergence
# reported. diags never skips (SKIPLABEL empty) — a valid file renders empty on
# both sides and a rejected one renders the same diagnostic on both, so nothing
# is excluded; ast/tokens skip a file the oracle could not lex/parse.
run_basic() {
  match=0 mismatch=0 skip=0 firstbad=""
  for f in $(find $CORPUS -name '*.bit' | sort); do
    seed=$(alarmrun "$ORACLE" "$FLAG" "$f")
    rc=$?
    if [ -n "$SKIPLABEL" ] && [ "$rc" -ne 0 ]; then
      skip=$((skip + 1))
      continue
    fi
    b2=$(alarmrun "$BIT2" "$FLAG" "$f")
    if [ "$seed" = "$b2" ]; then
      match=$((match + 1))
    else
      mismatch=$((mismatch + 1))
      [ -z "$firstbad" ] && firstbad="$f"
    fi
  done

  if [ -n "$SKIPLABEL" ]; then
    echo "$LABEL differential: MATCH=$match MISMATCH=$mismatch SKIP($SKIPLABEL)=$skip"
  else
    echo "$LABEL differential: MATCH=$match MISMATCH=$mismatch"
  fi

  # A phase that measured nothing must not pass (#1516). On an empty or unfindable
  # corpus the loop runs zero comparisons and MISMATCH is 0 for the wrong reason.
  if [ "$match" -lt 1 ]; then
    echo "FATAL: the $LABEL differential compared nothing (MATCH=$match) — corpus walk found no .bit file." >&2
    exit 2
  fi

  if [ -n "$firstbad" ]; then
    echo "first divergence: $firstbad"
    diff <(alarmrun "$ORACLE" "$FLAG" "$firstbad") <(alarmrun "$BIT2" "$FLAG" "$firstbad") | head -20
    exit 1
  fi
}

# types row body: a timeout is not evidence — a bit killed by the alarm produced
# no verdict, so it is reported separately and fails, rather than being scored
# as a mismatch.
run_types() {
  work=$(mktemp -d)
  trap 'rm -rf "$work"' EXIT
  : >"$work/mismatch"
  : >"$work/timeout"
  match=0 skip=0

  for f in $(find $CORPUS -name '*.bit' | sort); do
    seed=$("$ORACLE" "$FLAG" "$f" 2>/dev/null) || { skip=$((skip + 1)); continue; }
    b2=$(alarmrun "$BIT2" "$FLAG" "$f")
    rc=$?
    if [ "$rc" -ge 128 ]; then
      echo "$f" >>"$work/timeout"
      continue
    fi
    if [ "$seed" = "$b2" ]; then
      match=$((match + 1))
    else
      echo "$f" >>"$work/mismatch"
    fi
  done

  mismatch=$(wc -l <"$work/mismatch" | tr -d ' ')
  timeouts=$(wc -l <"$work/timeout" | tr -d ' ')
  echo "$LABEL differential: MATCH=$match MISMATCH=$mismatch TIMEOUT=$timeouts SKIP($SKIPLABEL)=$skip"

  status=0
  if [ -s "$work/mismatch" ]; then
    echo
    # EVERY divergence, named. "first divergence" told you one file out of n and
    # left the rest unreported, which is how a set of gaps reads as a single bug.
    echo "MISMATCH: $mismatch file(s) whose inferred types differ:"
    while read -r f; do echo "  $f"; done <"$work/mismatch"
    head -3 "$work/mismatch" | while read -r f; do
      echo
      echo "--- diff (seed vs bit): $f"
      diff <("$ORACLE" "$FLAG" "$f" 2>/dev/null) <(alarmrun "$BIT2" "$FLAG" "$f") | head -12
    done
    status=1
  fi

  if [ -s "$work/timeout" ]; then
    echo
    echo "INVALID: $timeouts file(s) timed out after ${TIMEOUT}s — no verdict, not a match:"
    while read -r f; do echo "  timeout: $f"; done <"$work/timeout"
    status=1
  fi

  [ "$status" -eq 0 ] && { echo; echo "$PREFIX: the two checkers agree on every compared file."; }
  exit "$status"
}

# ir/iropt row bodies: every mismatching path is NAMED and any mismatch fails
# the gate (#1469/#1478 — this used to print a count and name only the first
# offender, or not fail at all); a timeout on either side is its own reported
# outcome, never folded into SKIP or MISMATCH (#2070); $t<id> suffixes are
# canonicalized before comparing (selfhost-ir-canon.sh) since they are
# interning-order artifacts, not structural.
run_ir() {
  work=$(mktemp -d)
  trap 'rm -rf "$work"' EXIT
  sep="  -> "
  match=0 skip=0
  : >"$work/mismatch"
  : >"$work/timeout"
  : >"$work/oracletimeout"
  : >"$work/oraclecrash"

  for f in $(find $CORPUS -name '*.bit' | sort); do
    # The oracle is bounded too, and its timeout is NOT a skip: a skip means the
    # oracle could not lower or check the file, which is a real and expected
    # outcome, while a hang is a broken stage0 that must be named (#2070).
    want=$(alarmrun "$ORACLE" "$FLAG" "$f")
    rc=$?
    if [ "$rc" -eq 142 ]; then
      echo "$f${sep}$(whydied "$rc")" >>"$work/oracletimeout"
      continue
    fi
    if [ "$rc" -ge 128 ]; then
      echo "$f${sep}$(whydied "$rc")" >>"$work/oraclecrash"
      continue
    fi
    [ "$rc" -ne 0 ] && { skip=$((skip + 1)); continue; }
    [ -z "$want" ] && { skip=$((skip + 1)); continue; }

    b2=$(alarmrun "$BIT2" "$FLAG" "$f")
    rc=$?
    # >=128 is death by signal, and WHICH signal is not a detail. 142 is our own
    # SIGALRM — a timeout. Anything else is the compiler dying, and reporting a
    # SIGSEGV as "timed out after ${TIMEOUT}s" sends the reader after a performance
    # problem that does not exist. Either way there is no verdict (#2070).
    if [ "$rc" -ge 128 ]; then
      echo "$f${sep}$(whydied "$rc")" >>"$work/timeout"
      continue
    fi

    # $t<id> suffixes are interning-order artifacts, not structural — canonicalize
    # before comparing (see selfhost-ir-canon.sh). Raw compare first: the
    # overwhelming majority of files already match byte-for-byte, so skip the
    # two awk forks unless the raw strings actually differ.
    if [ "$want" = "$b2" ] || [ "$(canon_ir_ids "$want")" = "$(canon_ir_ids "$b2")" ]; then
      match=$((match + 1))
    else
      echo "$f" >>"$work/mismatch"
    fi
  done

  sort -o "$work/mismatch" "$work/mismatch"

  mismatch=$(wc -l <"$work/mismatch" | tr -d ' ')
  timeouts=$(wc -l <"$work/timeout" | tr -d ' ')
  oracletimeouts=$(wc -l <"$work/oracletimeout" | tr -d ' ')
  oraclecrashes=$(wc -l <"$work/oraclecrash" | tr -d ' ')

  echo "$LABEL differential: MATCH=$match MISMATCH=$mismatch NO-VERDICT=$timeouts ORACLE-TIMEOUT=$oracletimeouts ORACLE-CRASH=$oraclecrashes SKIP($SKIPLABEL)=$skip"

  # A RUN THAT COMPARED NOTHING IS NOT A PASS (#1881). Two ways to get here having
  # verified nothing, and both leave `mismatch` and `timeout` empty, so every check
  # below passes and the success line claims that every file's IR is identical:
  #
  #   - the corpus enumerated no files at all — a renamed or moved directory in the
  #     `find` list above, which `find` reports on stderr and then carries on past;
  #   - every file was skipped, because the oracle could not lower or check a single
  #     one. A stage0 that is broken for the whole corpus scores as agreement.
  #
  # The distinction from the count-vs-set argument in the header is that this is not
  # a threshold on how much matched. Zero is the one count that means the gate did
  # not run, so it is the one count worth asserting.
  if [ "$match" -eq 0 ]; then
    echo
    echo "INVALID: compared 0 files (skipped $skip) — the corpus or the oracle is broken. Nothing was verified." >&2
    exit 1
  fi

  status=0

  # NO DIVERGENCE IS PERMITTED. There is no expected-mismatch list and no way to
  # add one (#1883): a file whose IR differs from the pinned stage0's fails the
  # run. The list existed so a known difference could be written down instead of
  # fixed; its last entry closed with #1882.
  if [ -s "$work/mismatch" ]; then
    echo
    echo "REGRESSION: $mismatch file(s) diverge from the pinned stage0:"
    while read -r f; do echo "  mismatch: $f"; done <"$work/mismatch"
    # Bounded evidence for the first few, so the failure is actionable in one read.
    head -3 "$work/mismatch" | while read -r f; do
      echo
      echo "--- diff (stage0 vs bit, \$t<id> canonicalized): $f"
      # Bounded on BOTH sides, exactly as the compare loop runs them — an unbounded
      # oracle here would hang the failure report of a run that already failed.
      diff <(canon_ir_ids "$(alarmrun "$ORACLE" "$FLAG" "$f")") <(canon_ir_ids "$(alarmrun "$BIT2" "$FLAG" "$f")") | head -20
    done
    status=1
  fi

  if [ -s "$work/timeout" ]; then
    echo
    echo "INVALID: $timeouts file(s) produced no verdict — not a match:"
    while read -r f; do echo "  $f"; done <"$work/timeout"
    status=1
  fi

  # Reported apart from ours because it means something different: the PINNED
  # oracle hung, so the corpus shrank rather than this tree misbehaving. Merging
  # it into SKIP would have hidden that behind a number that is supposed to mean
  # "the oracle declined this file", which is how a gate quietly stops asserting.
  if [ -s "$work/oracletimeout" ]; then
    echo
    echo "INVALID: the pinned stage0 HUNG on $oracletimeouts file(s) — corpus reduced, not verified:"
    while read -r f; do echo "  $f"; done <"$work/oracletimeout"
    status=1
  fi

  # AN ORACLE CRASH IS REPORTED BUT DOES NOT FAIL, and the asymmetry with the hang
  # above is deliberate. The oracle is a PUBLISHED, IMMUTABLE binary: no change to
  # this tree can stop it faulting, so failing here would leave the gate red until
  # the next pin move — the "known-and-ignored red gets routed around" hazard
  # #1895 is about. A hang is different: it means the run could not complete in
  # bounded time and may be masking anything, so it still fails.
  #
  # What this is NOT is the expected-mismatch list #1883 deleted. That recorded
  # DIVERGENCES between the two compilers and let them be written down instead of
  # fixed. This records a defect in the oracle itself, names the file on EVERY run
  # rather than hiding it, and asserts nothing about agreement. Before #2070 the
  # same crash was an anonymous +1 to SKIP and went unnoticed for months (#2084).
  if [ -s "$work/oraclecrash" ]; then
    echo
    echo "NOTE: the pinned stage0 crashed on $oraclecrashes file(s) — no verdict available, tracked as #2084:"
    while read -r f; do echo "  $f"; done <"$work/oraclecrash"
  fi

  [ "$status" -eq 0 ] && { echo; echo "$PREFIX: every file's $VERB IR is identical to the pinned stage0's."; }
  exit "$status"
}

case "$KIND" in
  basic) run_basic ;;
  types) run_types ;;
  ir)    run_ir ;;
esac
