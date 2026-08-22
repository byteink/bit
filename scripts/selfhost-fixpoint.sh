#!/usr/bin/env bash
# Fixed-point proof (#1350): `bit` must be able to build ITSELF, reproducibly.
# This is the property that makes the bootstrap terminate rather than regress:
#
#   stageA (the current bit) builds compiler/ -> stageB
#   stageB                   builds compiler/ -> stageC
#   sha256(stageB) == sha256(stageC)    <-- byte-identical fixed point
#
# WHY THIS IS THE RIGHT PROPERTY, and not "matches the compiler that built me".
# The binary produced by the pinned stage0 is NOT byte-identical to stageB, and
# must not be required to be: two compilers can emit different-but-equivalent
# code for the same source (the known case is monomorph instance ordering, see
# selfhost-diffir.sh). Demanding equality there would pin this tree's output
# forever to one past release. What must hold is bit == bit-built-by-bit.
#
# Same-basename outputs in different dirs: the Mach-O codesign identifier derives
# from the output FILENAME, so both stages must be named identically or the hash
# differs for a spurious reason. The writer does NOT mkdir parents — mkdir -p.
#
# #2980: a single stageB != stageC observed while 2-3 OTHER worktrees were
# concurrently self-building elsewhere on the box was reported as "FIXED POINT
# BROKEN", and it was not — three isolated re-runs of the identical operation on
# a quieter box converged on the SAME hash every time. `compiler/build.bit`'s own
# `bit build` has no concurrency and no shared scratch path (unlike `bit run`,
# which uses a nonce specifically to avoid this), so the corruption is upstream
# of codegen — most likely a short/interrupted `read(2)` on a `.bit` source file
# under load (`runtime/root/{darwin,linux}/fs.bit`'s `rtFsReadAll` returns
# whatever it has on ANY `n <= 0`, silently zero-padding the tail instead of
# distinguishing a real EOF from a transient one — see the follow-up filed
# against that). A single comparison here cannot tell "the compiler is broken"
# apart from "one of the two reads got clipped this one time", so a mismatch is
# no longer trusted on its own: see the CONFIRMATION step below.
#
# Usage: ./make selfhost && bash scripts/selfhost-fixpoint.sh
#        (or pass an explicit stageA binary: bash scripts/selfhost-fixpoint.sh path/to/bit)
# Run from the repo root so the CWD-relative libbitrt lookup resolves.
set -eu
# shellcheck source=scripts/alarmrun.sh
. "$(dirname -- "$0")/alarmrun.sh"

# stage() is a FULL self-build (`bit build compiler -o ...`), not a
# single-file dump or a corpus pass, so the family's 20s/300s conventions
# (selfhost-diffdump.sh et al.) do not apply here — they would fire on an
# ordinary contended box. Reuse the bound the build driver ITSELF already
# uses for this exact operation: tools/build/artifacts.bit's
# `buildTimeoutMs()` returns 1800000ms (30 min) and is what bounds the
# driver's own "selfhost" step (`runShell("selfhost", script,
# buildTimeoutMs())`, tools/build/artifactsteps.bit:238). That is an
# already-agreed number for the identical operation, not a new one invented
# for this script.
# Override with FIXPOINT_TIMEOUT for a slower host.
TIMEOUT=${FIXPOINT_TIMEOUT:-1800}
STAGEA="${1:-bit-out/bin/bit}"
WORK="$(pwd)/.fixpoint-work"
rm -rf "$WORK"
mkdir -p "$WORK/b" "$WORK/c" "$WORK/d"

[ -x "$STAGEA" ] || { echo "fixpoint: missing $STAGEA — run: ./make selfhost" >&2; exit 2; }
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
# broken gate) rather than 1 (a broken compiler), naming the log. A timed-out
# build gets its own message for the same reason: a hung stageB/C/D disproves
# nothing about the fixed point — it is could-not-decide, exit 2, same as a
# build failure, not exit 1 (a proven non-fixed-point).
stage() { # <label> <compiler> <out>
  local rc=0
  ALARMRUN_KEEP_STDERR=1 alarmrun "$2" build compiler -o "$3" >"$WORK/$1.log" 2>&1 || rc=$?
  if [ "$rc" -eq 142 ]; then
    echo "fixpoint: $1 TIMED OUT after ${TIMEOUT}s — could not decide, not a broken fixed point" >&2
    sed -n '1,20p' "$WORK/$1.log" >&2
    exit 2
  fi
  if [ "$rc" -ne 0 ]; then
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

# CONFIRMATION (#2980): stageB != stageC decided nothing on its own — it is
# exactly as consistent with "a read got clipped once, on either hop" as with
# a real break, and this script cannot tell those apart from one comparison.
# So ask the question the ticket's own manual repro asked: is stageC — the
# side we have in hand — a fixed point OF ITSELF? Build stageD from stageC.
# If stageC == stageD, stageC is self-stable and the anomaly was upstream of
# it (the A->B hop); that is UNDECIDED, not BROKEN, exactly the shape
# scripts/selfhost-diffcheck.sh uses for a timeout that decided nothing. Only
# a SECOND, independent divergence (stageC != stageD too) is reproducible
# enough to call a real, unstable fixed point.
echo "fixpoint: stageB != stageC — confirming before calling it broken (building stageD from stageC)"
stage stageD "$WORK/c/bit" "$WORK/d/bit"
D=$(shasum -a 256 "$WORK/d/bit" | cut -d' ' -f1)
echo "stageD (stageC built selfhost): $D"
if [ "$C" = "$D" ]; then
  echo "FIXED POINT UNDECIDED — stageB != stageC on the first hop, but stageC == stageD confirms stageC is stable."
  echo "                        This is the shape of a load-induced glitch (#2980), not a proven compiler bug."
  echo "                        Not a pass. Re-run when 'pgrep -fl make-driver' shows nothing else building."
  echo "artifacts kept in $WORK for inspection"
  exit 2
fi
echo "FIXED POINT BROKEN — stageB != stageC, and stageC != stageD on a second, independent build. The self-hosted compiler is not self-reproducible."
echo "artifacts kept in $WORK for diffing"
exit 1
