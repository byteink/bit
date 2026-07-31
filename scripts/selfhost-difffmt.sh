#!/usr/bin/env bash
# Self-host FORMATTER differential (#1542): run every corpus `.bit` through both
# compilers' `fmt` and compare the resulting bytes. `fmt` was the last
# self-host readiness surface with no differential and no number attached —
# every sibling axis (difftokens, diffast, difftypes, diffir, diffdiags,
# diffcheck, diffexamples, fuzzdiff) had one; this one did not.
#
# ## What is being compared, and what is NOT
#
# seed-fmt output vs bit-fmt output. NOT fmt output vs the file on disk.
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
# Usage: ./make selfhost && bash scripts/selfhost-difffmt.sh
set -uo pipefail
# The oracle is the PINNED STAGE0: the previous release, i.e. an EARLIER VERSION
# OF THIS SAME COMPILER — which is exactly what limits the claim below.
# scripts/stage0.sh downloads and DIGEST-VERIFIES it, and refuses rather
# than skipping. What a green run asserts changed with it: "unchanged versus the
# last release", not "two implementations agree" — docs/release/bootstrap.md §4/§5.
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
probe_fmt() {
  local bin=$1 dir="$work/probe.$2"
  mkdir -p "$dir"
  printf 'function main() {\n  print("hi\\n")\n}\n' >"$dir/p.bit"
  local out
  out=$("$bin" fmt "$dir/p.bit" 2>&1)
  local rc=$?
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
match=0 skip=0

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
  cp "$f" "$a/s.bit"
  cp "$f" "$b/s.bit"

  "$ORACLE" fmt "$a/s.bit" >/dev/null 2>&1
  seed_rc=$?
  # The seed is the oracle: a file it cannot format (the corpus deliberately
  # holds unparseable `// error` cases) is out of scope, exactly as difftypes
  # skips files the seed's checker rejects.
  if [ "$seed_rc" -ne 0 ]; then
    skip=$((skip + 1))
    continue
  fi

  perl -e 'alarm shift; exec @ARGV' "$TIMEOUT" "$BIT2" fmt "$b/s.bit" >/dev/null 2>&1
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
echo "fmt differential ($ORACLE vs $BIT2): MATCH=$match MISMATCH=$mismatch TIMEOUT=$timeouts SKIP(unformattable)=$skip"

status=0

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
    "$ORACLE" fmt "$a/s.bit" >/dev/null 2>&1
    perl -e 'alarm shift; exec @ARGV' "$TIMEOUT" "$BIT2" fmt "$b/s.bit" >/dev/null 2>&1
    diff "$a/s.bit" "$b/s.bit" | head -12
  done
  status=1
fi

if [ -s "$work/timeout" ]; then
  echo
  echo "INVALID: $timeouts file(s) timed out after ${TIMEOUT}s — no verdict, not a match:"
  while read -r f; do echo "  timeout: $f"; done <"$work/timeout"
  status=1
fi

[ "$status" -eq 0 ] && { echo; echo "difffmt: the two formatters agree on every compared file."; }
exit "$status"
