#!/usr/bin/env bash
# Self-hosted fixed-point proof (#1350): the self-hosted compiler must be able
# to build ITSELF, reproducibly, with NO seed/Zig in the loop. This is the
# guarantee that lets the seed retire — once it is gone there is no stage2 to
# compare against, so the meaningful property is self-reproducibility:
#
#   stageA (the current self-hosted bit) builds compiler/ -> stageB
#   stageB                              builds compiler/ -> stageC
#   sha256(stageB) == sha256(stageC)    <-- byte-identical fixed point
#
# NOTE on stage2 vs stage3: the seed-built self-hosted binary (`bit2`, "stage2")
# is NOT byte-identical to stageB ("stage3") — the seed and bit2 emit
# different-but-equivalent code for the compiler (2 cosmetic monomorph
# instance-ordering diffs, see selfhost-diffir.sh). That is expected and
# irrelevant to retiring the seed: we require bit == bit-built-by-bit, not
# bit == a-compiler-we-are-deleting. Go retired its C bootstrap the same way.
#
# Same-basename outputs in different dirs: the Mach-O codesign identifier derives
# from the output FILENAME, so both stages must be named identically or the hash
# differs for a spurious reason. bit2's writer does NOT mkdir parents — mkdir -p.
#
# Usage: zig build selfhost && bash scripts/selfhost-fixpoint.sh
#        (or pass an explicit stageA binary: bash scripts/selfhost-fixpoint.sh path/to/bit)
# Run from the repo root so the CWD-relative libbitrt lookup resolves.
set -eu
STAGEA="${1:-zig-out/bin/bit}"
WORK="$(pwd)/.fixpoint-work"
rm -rf "$WORK"
mkdir -p "$WORK/b" "$WORK/c"

[ -x "$STAGEA" ] || { echo "fixpoint: missing $STAGEA — run: zig build selfhost" >&2; exit 2; }
[ -d compiler ] || { echo "fixpoint: no compiler/ directory — run from the repo root" >&2; exit 2; }

# A BUILD FAILURE IS NOT A FIXPOINT BREAK, and this script used to make them
# indistinguishable. It passed `selfhost` — the directory's name before #1841
# renamed it to `compiler` — so from 186b57e onward every run died on
# `bit: selfhost: NoMain`. With `set -e` and the output sent to /dev/null, that
# surfaced as a bare `exit 1` and NOTHING printed: the strongest gate in the
# bootstrap story looked like a failing fixed point for months, and gate.sh's
# `selfhost` bucket ran it on every compiler/** change.
#
# So: the stage builds keep their own logs, and a non-zero build exits 2 (a
# broken gate) rather than 1 (a broken compiler), naming the log.
stage() { # <label> <compiler> <out>
  if ! "$2" build compiler -o "$3" >"$WORK/$1.log" 2>&1; then
    echo "fixpoint: $1 FAILED TO BUILD — this is a broken gate, not a broken fixed point" >&2
    sed -n '1,20p' "$WORK/$1.log" >&2
    exit 2
  fi
  # Exit 0 is not proof of an artifact: a stand-in that ignores its arguments
  # (`/bin/echo`) exits 0 and writes nothing, and the next stage would then fail
  # for a misleading reason. Comparing two files requires two files.
  [ -s "$3" ] || { echo "fixpoint: $1 exited 0 but produced no binary at $3" >&2; exit 2; }
}
stage stageB "$STAGEA" "$WORK/b/bit"
stage stageC "$WORK/b/bit" "$WORK/c/bit"

B=$(shasum -a 256 "$WORK/b/bit" | cut -d' ' -f1)
C=$(shasum -a 256 "$WORK/c/bit" | cut -d' ' -f1)
echo "stageB (stageA built selfhost): $B"
echo "stageC (stageB built selfhost): $C"
if [ "$B" = "$C" ]; then
  echo "FIXED POINT OK — the self-hosted compiler reproducibly builds itself."
  rm -rf "$WORK"
  exit 0
fi
echo "FIXED POINT BROKEN — stageB != stageC. The self-hosted compiler is not self-reproducible."
echo "artifacts kept in $WORK for diffing"
exit 1
