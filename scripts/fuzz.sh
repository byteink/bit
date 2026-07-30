#!/usr/bin/env bash
# scripts/fuzz.sh — mutation-fuzz the compiler front end, replacing `./make fuzz`.
#
# Runs tests/bit/fuzz.bit. Two phases in one process: replay every saved crash
# under tests/fuzz/crashes/, then mutate tests/cases/*.bit until the budget
# runs out. Both phases bound each child with `osRunBounded` (ABI.md §19).
#
# Usage:
#   scripts/fuzz.sh              # 60s, seed from the clock (echoed)
#   scripts/fuzz.sh 600          # 10 minutes
#   scripts/fuzz.sh 60 12345     # replay a specific seed
#
# A red run prints `FAIL:` and exits 1, and any input that crashed or hung the
# compiler is already in tests/fuzz/crashes/ — commit it, it is a regression
# case from then on.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

bit="${BIT:-$root/bit-out/bin/bit}"
[[ -x "$bit" ]] || { echo "scripts/fuzz.sh: no compiler at $bit (run ./make first)" >&2; exit 1; }

export BIT_STDLIB="${BIT_STDLIB:-$root/stdlib}"
export BIT_FUZZ_BIN="$bit"
export BIT_FUZZ_CASES="$root/tests/cases"
export BIT_FUZZ_CRASHES="$root/tests/fuzz/crashes"
export BIT_FUZZ_WORK="${BIT_FUZZ_WORK:-${TMPDIR:-/tmp}/bit-fuzz}"
export BIT_FUZZ_SECONDS="${1:-60}"
[[ $# -ge 2 ]] && export BIT_FUZZ_SEED="$2"

exec "$bit" run tests/bit/fuzz.bit
