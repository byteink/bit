#!/usr/bin/env bash
# scripts/regex-difffuzz.sh — #2057's differential fuzzer (epic #2025):
# compares std/regex against Go's regexp over a large deterministic
# pattern/subject corpus, in a throwaway Docker container.
#
# Genuinely a NEW script, not a parameter on an existing one
# (bitlang-ws/CLAUDE.md's "do not bloat scripts/" rule): the job needs a
# host-side Bit run, a containerised Go run and a corpus diff — none of the
# existing scripts do any of that, and the closest precedent (arm64gate.sh)
# earns its own file for the identical reason (a genuinely distinct job).
#
# WHAT IT DOES. tools/fuzz/regexdifffuzz (a Bit directory module) generates
# --count patterns from --seed, five subjects per pattern, and BOTH the
# corpus (patterns.hex, subjects.hex — hex-encoded, so a mutated pattern's
# control bytes or a UTF-8 subject's raw bytes never need shell-escaping)
# and std/regex's own answers (bit-results.tsv). This script then runs
# scripts/regex-oracle/main.go — a PURE ORACLE, no randomness of its own —
# inside a pinned, throwaway `golang:$GO_IMAGE_TAG` container against the
# SAME corpus, producing go-results.tsv in the identical line format. Only
# one side generates (see tools/fuzz/regexdifffuzz/gen.bit's header for
# why: Go's math/rand and Bit's std/rand are different algorithms, so "the
# same seed" would not mean the same patterns in both languages).
#
# KNOWN-DIVERGENT CONSTRUCTS. patterns.hex's second column flags a pattern
# using a construct the two engines deliberately parse differently by
# design (today: only `(?<name>...)`, Bit's alternate named-group spelling
# — Go's regexp/syntax accepts only `(?P<name>...)`, see
# tools/fuzz/regexdifffuzz/corpus.bit's isKnownDivergent). This script
# drops every result line for a flagged pattern from BOTH sides before
# diffing, so an expected compile disagreement never reads as a finding.
# Never extend the flag to a MATCHING disagreement (#2057's own
# constraint) — that decision lives in corpus.bit, not here.
#
# ON THE FIRST UNEXPLAINED DIFFERENCE: prints the seed, the pattern, the
# subject and both engines' full answer line, then exits 1 — #2057's own
# spec ("Any difference stops the run"). On a clean run: prints
# `PASS: N patterns, M subject pairs compared (K skipped as known-divergent)`
# and exits 0.
#
# Not wired into ./make test (#2057's own constraint: needs Docker and can
# run for a long time) and registers no coreSteps() Step — run it by hand:
#   scripts/regex-difffuzz.sh [--seed N] [--count N] [--keep]
set -euo pipefail
cd "$(dirname -- "$0")/.."

SEED="${SEED:-1}"
COUNT="${COUNT:-10000}"
KEEP=0
while [ $# -gt 0 ]; do
  case "$1" in
    --seed) SEED="$2"; shift 2 ;;
    --count) COUNT="$2"; shift 2 ;;
    --keep) KEEP=1; shift ;;
    *) echo "usage: $0 [--seed N] [--count N] [--keep]" >&2; exit 2 ;;
  esac
done

# Pinned, not "golang:alpine" or "golang:latest" — an unpinned oracle is not
# reproducible (#2057's own constraint).
GO_IMAGE="golang:1.26.6-alpine"

BIT="${BIT_BIN:-$PWD/bit-out/bin/bit}"
export BIT_STDLIB="${BIT_STDLIB:-$PWD/stdlib}"
[ -x "$BIT" ] || { echo "regex-difffuzz: $BIT not built (run: ./make selfhost)" >&2; exit 1; }
command -v docker >/dev/null || { echo "regex-difffuzz: docker not found" >&2; exit 127; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
CORPUS="$WORK/corpus"

# Track whether THIS run pulled the image, so cleanup only removes what it
# fetched — never an image another workflow already had cached (checked
# live on this box: golang:1.26.6-alpine was already present).
PULLED_IMAGE=0
if ! docker image inspect "$GO_IMAGE" >/dev/null 2>&1; then
  docker pull "$GO_IMAGE"
  PULLED_IMAGE=1
fi
cleanup_image() {
  if [ "$KEEP" != 1 ] && [ "$PULLED_IMAGE" = 1 ]; then
    docker rmi "$GO_IMAGE" >/dev/null 2>&1 || true
  fi
}
trap 'cleanup_image; rm -rf "$WORK"' EXIT

echo "regex-difffuzz: generating ${COUNT} patterns (seed=${SEED})..." >&2
"$BIT" run tools/fuzz/regexdifffuzz -- --seed "$SEED" --count "$COUNT" --out "$CORPUS"

echo "regex-difffuzz: running the Go oracle (${GO_IMAGE})..." >&2
docker run --rm \
  -v "$PWD/scripts/regex-oracle:/src:ro" \
  -v "$CORPUS:/work" \
  -w /src "$GO_IMAGE" \
  sh -c 'go run main.go --in /work --out /work/go-results.tsv'

# --- diff: drop known-divergent patterns from both sides, then compare ----

# patterns.hex: IDX \t DIVERGENT(0/1) \t HEXPATTERN — the indices flagged 1
# never reach the comparison below (see the header for why).
awk -F'\t' '$2==1{print $1}' "$CORPUS/patterns.hex" > "$WORK/divergent.idx"

# `NR==FNR` two-file idiom breaks when the first (skip) file is EMPTY — a
# genuinely common case here (a run with no known-divergent patterns at
# all): NR and FNR then stay in lockstep for every line of the SECOND file
# too, so every result line is (wrongly) treated as a skip-index and NONE
# of them reach the print — checked live, this produced "0 subject pairs
# compared" on a run with zero divergent patterns. Reading the skip file
# via `getline` in BEGIN sidesteps the multi-file NR/FNR interaction
# entirely.
filter_known_divergent() {
  awk -F'\t' -v skipfile="$WORK/divergent.idx" '
    BEGIN {
      while ((getline line < skipfile) > 0) { skip[line] = 1 }
      close(skipfile)
    }
    !($1 in skip)
  ' "$1"
}
filter_known_divergent "$CORPUS/bit-results.tsv" > "$WORK/bit-filtered.tsv"
filter_known_divergent "$CORPUS/go-results.tsv" > "$WORK/go-filtered.tsv"

TOTAL_PATTERNS=$(wc -l < "$CORPUS/patterns.hex" | tr -d ' ')
SKIPPED=$(wc -l < "$WORK/divergent.idx" | tr -d ' ')
COMPARED=$(wc -l < "$WORK/bit-filtered.tsv" | tr -d ' ')

if cmp -s "$WORK/bit-filtered.tsv" "$WORK/go-filtered.tsv"; then
  echo "PASS: ${TOTAL_PATTERNS} patterns, ${COMPARED} subject pairs compared (${SKIPPED} patterns skipped as known-divergent)"
  exit 0
fi

# First differing line, by BYTE OFFSET (cmp's own report) mapped back to a
# line number, then to the pattern's own idx (result lines' first column)
# so the seed/pattern/subject can be printed — #2057's own spec: "prints
# the seed, the pattern, the subject, and both answers."
FIRST_LINE=$(diff "$WORK/bit-filtered.tsv" "$WORK/go-filtered.tsv" | head -1 | grep -oE '^[0-9]+' || true)
[ -n "$FIRST_LINE" ] || FIRST_LINE=1
BIT_LINE=$(sed -n "${FIRST_LINE}p" "$WORK/bit-filtered.tsv")
GO_LINE=$(sed -n "${FIRST_LINE}p" "$WORK/go-filtered.tsv")
IDX=$(printf '%s\n' "$BIT_LINE" | cut -f1)
KIND=$(printf '%s\n' "$BIT_LINE" | cut -f2)
PATTERN_HEX=$(awk -F'\t' -v idx="$IDX" '$1==idx{print $3}' "$CORPUS/patterns.hex")
SUBJECT_HEX=$(awk -F'\t' -v idx="$IDX" -v kind="$KIND" '$1==idx && $2==kind{print $3}' "$CORPUS/subjects.hex")

echo "regex-difffuzz: DISAGREEMENT at seed=${SEED} pattern idx=${IDX}" >&2
echo "  pattern: $(printf '%s' "$PATTERN_HEX" | xxd -r -p)" >&2
echo "  subject (${KIND}): $(printf '%s' "$SUBJECT_HEX" | xxd -r -p | head -c 200)" >&2
echo "  bit: ${BIT_LINE}" >&2
echo "  go:  ${GO_LINE}" >&2
echo "regex-difffuzz: replay with: bit run tools/fuzz/regexdifffuzz -- --seed ${SEED} --count $((IDX + 1)) --out <dir>" >&2
exit 1
