#!/usr/bin/env bash
# Self-hosted fixed-point proof (#1350): the self-hosted compiler must be able
# to build ITSELF, reproducibly, with NO seed/Zig in the loop. This is the
# guarantee that lets the seed retire — once it is gone there is no stage2 to
# compare against, so the meaningful property is self-reproducibility:
#
#   stageA (the current self-hosted bit) builds selfhost/ -> stageB
#   stageB                              builds selfhost/ -> stageC
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

"$STAGEA" build selfhost -o "$WORK/b/bit" >/dev/null 2>&1
"$WORK/b/bit" build selfhost -o "$WORK/c/bit" >/dev/null 2>&1

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
