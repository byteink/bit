#!/usr/bin/env bash
# Self-host FORMATTER differential (#1542): run every corpus `.bit` through both
# compilers' `fmt` and compare the resulting bytes. `fmt` was the last
# self-host readiness surface with no differential and no number attached —
# every sibling axis (difftokens, diffast, difftypes, diffir, diffdiags,
# diffcheck, diffexamples, fuzzdiff) had one; this one did not.
#
# ## What is being compared, and what is NOT
#
# The pinned stage0's fmt output vs bit-fmt output. NOT fmt output vs the file on disk.
# The formatter deliberately disagrees with most of the checked-in corpus
# (it explodes hand-grouped crypto tables and mangles multi-line match bodies),
# and the repo is deliberately NOT gated on `bit fmt` being a no-op: the
# formatter is not yet good enough to be normative.
# So "the formatted text differs from the repo" is expected and is not measured
# here. Only the two compilers disagreeing with EACH OTHER is a finding.
#
# ## `fmt` rewrites in place
#
# Neither compiler has a format-to-stdout mode: `fmt` rewrites the file, and
# `--check` only NAMES non-canonical files without emitting their text. So the
# differential necessarily works on copies — each file is staged into two
# private scratch dirs under an owned `mktemp -d` and formatted there. The
# corpus is never written to. Do not "optimize" this by formatting in place.
#
# ## Preconditions are hard failures, never a vacuous green (#1514)
#
# `fuzzdiff` once scored 6642 MATCH with no compiler on disk. Two gates here:
# a missing binary aborts, and — the one that matters today — a compiler that
# does not IMPLEMENT `fmt` aborts as ABSENT rather than scoring zero files as
# agreement. A surface that does not exist has not been verified to match; it
# has not been tested at all, and those are opposite claims.
#
# As of #1542 the self-hosted `bit` has no `fmt` subcommand at all, so this
# script's expected verdict today is ABSENT/exit 2. It goes green on its own
# when `fmt` is ported — it is written to be the gate for that work, not a
# report of it.
#
# A timeout is its own outcome (#1524/#1525): a `bit` run killed by the alarm
# produced no formatted text, so it is reported separately and fails, rather
# than being scored as a mismatch or silently passing. The `continue` makes the
# byte comparison structurally unreachable unless both sides produced output.
#
# ## The bound, and why BOTH sides carry it (#2863)
#
# The BIT2 side was alarm-guarded from the start; the ORACLE side was not, so a
# hung pinned oracle wedged this script indefinitely — exactly the shape
# selfhost-diffcheck.sh's header warns about ("the seed side had no bound at
# all, so a hung ORACLE wedged the whole gate indefinitely"). An oracle timeout
# is reported through its own counter (ORACLE-TIMEOUT), never folded into SKIP:
# SKIP means the oracle legitimately declined the file (the corpus deliberately
# holds unparseable `// error` cases), a hang means it never reached a verdict.
#
# Usage: ./make selfhost && bash scripts/selfhost-difffmt.sh
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
ORACLE=${DIFFFMT_ORACLE:-$(sh scripts/stage0.sh)} || exit 2
# Overridable so the script can be mutation-tested against a known-agreeing and
# a known-disagreeing formatter. The verdict line always names what was actually
# compared, so an overridden run cannot be quoted as a plain one.
BIT2=${DIFFFMT_BIT:-bit-out/bin/bit}
# 20s was too tight on slower hardware: #1761's own verification needed
# DIFFFMT_TIMEOUT=40 on an older Skylake x86_64 host to format
# compiler/lower.bit (6867 lines, ~23s wall there) without a false
# TIMEOUT/INCONCLUSIVE on an otherwise-correct, just-slow, result. 45s keeps a
# margin above that measured worst case.
TIMEOUT=${DIFFFMT_TIMEOUT:-45}

for bin in "$ORACLE" "$BIT2"; do
  [ -x "$bin" ] || { echo "difffmt: missing $bin — run: ./make selfhost" >&2; exit 2; }
done

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# Capability probe, not a verdict: format a throwaway file and see whether the
# subcommand exists at all. Exit status alone cannot tell "fmt refused this
# file" from "there is no fmt", so the usage text is what distinguishes them —
# it is the only signal that carries that difference.
#
# Bounded like every other call in this script (#3389): a probe run before the
# main loop is still a call to an untrusted binary, and a hang here wedges the
# script before the guarded loop is ever reached — the same shape
# selfhost-diffcheck.sh's header warns about. A probe timeout is NOT evidence
# of absence (a hang proves nothing about whether `fmt` exists), so it is
# never folded into the "unknown subcommand" / ABSENT path below: it is its
# own could-not-decide outcome, exit 2, same code the corpus-floor and ABSENT
# checks already use in this file for "nothing was compared".
probe_fmt() {
  local bin=$1 dir="$work/probe.$2"
  mkdir -p "$dir"
  printf 'fn main() {\n  print("hi\\n")\n}\n' >"$dir/p.bit"
  local out
  # Verdict-deciding (#3422): a single stall aborts the WHOLE differential as
  # could-not-decide, so it gets alarmrun_retry's one retry, same as the main
  # loop below and unlike the two forbidden report-only sites in this file.
  out=$(ALARMRUN_KEEP_STDERR=1 alarmrun_retry "$2" "" "$bin" fmt "$dir/p.bit" 2>&1)
  local rc=$?
  if [ "$rc" -eq 142 ]; then
    echo "difffmt: PROBE TIMEOUT — $bin hung on the capability probe after ${TIMEOUT}s" >&2
    echo "difffmt: nothing was compared — a hung probe is not evidence of absence." >&2
    exit 2
  fi
  if [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -q 'unknown subcommand'; then
    return 1
  fi
  return 0
}

absent=""
probe_fmt "$ORACLE" seed || absent="$absent $ORACLE"
probe_fmt "$BIT2" bit2 || absent="$absent $BIT2"
if [ -n "$absent" ]; then
  echo "difffmt: ABSENT — no \`fmt\` subcommand in:$absent"
  echo "difffmt: nothing was compared. This is NOT agreement — the surface is unimplemented."
  exit 2
fi

: >"$work/mismatch"
: >"$work/timeout"
: >"$work/oracletimeout"
match=0 skip=0

# fmt_retry <side> <target> <pristine> <bin> -- alarmrun_retry's own contract
# (one retry on SIGALRM, 142 iff both attempts stall, stall note on fd 9) but
# with the corpus file's pristine bytes copied into <target> before EVERY
# attempt, not once per corpus file (#3487). `fmt` rewrites <target> IN PLACE
# via truncate-then-write (compiler/fmtcmd.bit's writeFile), so an attempt
# killed by SIGALRM between the truncate and the write leaves <target>
# partial; alarmrun_retry's own outfile arg only ever REMOVES a target, which
# is wrong here (fmt needs the file to exist), so a plain alarmrun_retry call
# lets the retry format the previous attempt's corruption instead of the
# original source. Restoring the pristine bytes first makes every attempt see
# the same input.
fmt_retry() {
  local side=$1 target=$2 pristine=$3 bin=$4 rc
  cp "$pristine" "$target"
  alarmrun "$bin" fmt "$target" >/dev/null
  rc=$?
  if [ "$rc" -eq 142 ]; then
    echo "$side fmt stalled once (SIGALRM after ${TIMEOUT}s), retrying: $bin fmt $target" >&9
    cp "$pristine" "$target"
    alarmrun "$bin" fmt "$target" >/dev/null
    rc=$?
  fi
  return "$rc"
}

# `compiler`, not `selfhost` — the directory was renamed in #1841 and this line
# was not. A missing root makes `find` complain on stderr and carry on with the
# rest, so the gate kept passing while silently scanning 706 files instead of
# 840: every one of the compiler's own sources went format-unchecked from the
# rename until #1922. Nothing failed, which is the whole problem with naming
# corpus roots as bare strings.
#
# So the roots are named once, and checked. A rename now stops the gate instead
# of quietly shrinking it — the same reasoning as the zero-file guard in the IR
# differentials (#1881), one step earlier in the pipeline.
CORPUS="stdlib examples tests/cases tests/imports compiler runtime"
for d in $CORPUS; do
  [ -d "$d" ] || { echo "difffmt: corpus root '$d' does not exist — refusing to scan a partial tree" >&2; exit 2; }
done

# shellcheck disable=SC2086  # CORPUS is a deliberate word-split list of roots.
for f in $(find $CORPUS -name '*.bit' | sort); do
  a="$work/a"; b="$work/b"
  rm -rf "$a" "$b"; mkdir -p "$a" "$b"

  # fmt_retry copies "$f" into the target itself, before EACH attempt (#3487)
  # — do not pre-copy here, that copy would only cover the first attempt.
  fmt_retry ORACLE "$a/s.bit" "$f" "$ORACLE"
  seed_rc=$?
  if [ "$seed_rc" -ge 128 ]; then
    echo "$f" >>"$work/oracletimeout"
    continue
  fi
  # A file the oracle cannot format (the corpus deliberately holds unparseable
  # `// error` cases) is out of scope, exactly as difftypes skips files the
  # oracle's checker rejects.
  if [ "$seed_rc" -ne 0 ]; then
    skip=$((skip + 1))
    continue
  fi

  fmt_retry BIT2 "$b/s.bit" "$f" "$BIT2"
  rc=$?
  if [ "$rc" -ge 128 ]; then
    echo "$f" >>"$work/timeout"
    continue
  fi

  if cmp -s "$a/s.bit" "$b/s.bit"; then
    match=$((match + 1))
  else
    echo "$f" >>"$work/mismatch"
  fi
done

compared=$((match + $(wc -l <"$work/mismatch" | tr -d ' ')))
mismatch=$(wc -l <"$work/mismatch" | tr -d ' ')
timeouts=$(wc -l <"$work/timeout" | tr -d ' ')
oracletimeouts=$(wc -l <"$work/oracletimeout" | tr -d ' ')
echo "fmt differential ($ORACLE vs $BIT2): MATCH=$match MISMATCH=$mismatch TIMEOUT=$timeouts ORACLE-TIMEOUT=$oracletimeouts SKIP(unformattable)=$skip"

# Corpus floor (#1516): comparing nothing is not agreement. If every file was
# skipped or timed out there is no evidence either way, and a green here would
# be a fabricated one.
if [ "$compared" -eq 0 ]; then
  echo
  echo "INVALID: zero files were compared — no evidence of agreement."
  exit 2
fi

if [ -s "$work/mismatch" ]; then
  echo
  # EVERY divergence, named — "first divergence" reports one file and leaves
  # the rest invisible, which is how a set of gaps reads as a single bug.
  echo "MISMATCH: $mismatch file(s) the two formatters render differently:"
  while read -r f; do echo "  $f"; done <"$work/mismatch"
  head -3 "$work/mismatch" | while read -r f; do
    echo
    echo "--- diff (seed vs bit): $f"
    a="$work/da"; b="$work/db"
    rm -rf "$a" "$b"; mkdir -p "$a" "$b"
    cp "$f" "$a/s.bit"; cp "$f" "$b/s.bit"
    alarmrun "$ORACLE" fmt "$a/s.bit" >/dev/null
    alarmrun "$BIT2" fmt "$b/s.bit" >/dev/null
    diff "$a/s.bit" "$b/s.bit" | head -12
  done
fi

if [ -s "$work/timeout" ]; then
  echo
  echo "INVALID: $timeouts file(s) timed out after ${TIMEOUT}s — no verdict, not a match:"
  while read -r f; do echo "  timeout: $f"; done <"$work/timeout"
fi

# Reported apart from BIT2's timeout above because it means something
# different: the PINNED oracle hung, so the corpus shrank rather than this
# tree misbehaving (see selfhost-diffir.sh's identical reasoning for ORACLE-TIMEOUT).
if [ -s "$work/oracletimeout" ]; then
  echo
  echo "INVALID: the pinned oracle timed out on $oracletimeouts file(s) after ${TIMEOUT}s — no verdict, not a match:"
  while read -r f; do echo "  oracle-timeout: $f"; done <"$work/oracletimeout"
fi

# A timeout on either side used to set the same status=1 a real mismatch does
# (#3382 sibling finding, same shape as #3351/#3377/#3378/#3379/#3380):
# diffexit restores the could-not-decide (2) distinction.
[ "$mismatch" -eq 0 ] && [ "$timeouts" -eq 0 ] && [ "$oracletimeouts" -eq 0 ] &&
  { echo; echo "difffmt: the two formatters agree on every compared file."; }
diffexit "fmt" -f "$mismatch" -t "file(s)=$timeouts" "oracle file(s)=$oracletimeouts"
