# Shared per-language build commands for bench/run.sh and bench/profile.sh.
#
# Kept in one place so the two harnesses cannot build a case two different
# ways -- e.g. run.sh's CFLAGS drifting from what profile.sh compiles with
# would make a profile describe a binary the published numbers don't match.
# Sourced, not executed: `source "$(dirname "$0")/buildlib.sh"` after `cd` to
# the repo root. Runs on stock bash 3.2.

BIT=${BIT:-./bit-out/bin/bit}
CFLAGS=${CFLAGS:--O2 -ffp-contract=off}   # -ffp-contract=off: match strict IEEE

# buildBit <case-dir> <case> <output-path>
buildBit() {
  "$BIT" build "$1/$2.bit" -o "$3"
}

# buildC <case-dir> <case> <output-path> [extra cc flags...]
buildC() {
  local d="$1" c="$2" out="$3"
  shift 3
  cc $CFLAGS "$@" "$d/$c.c" -o "$out"
}

# buildGo <case-dir> <case> <output-path>
buildGo() {
  go build -o "$3" "$1/$2.go"
}
