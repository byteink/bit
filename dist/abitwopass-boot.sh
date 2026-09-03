#!/usr/bin/env bash
# The two-pass BIT_STAGE0_BIN bootstrap (docs/development.md, "Landing a
# runtime ABI change"), given an already-derived and VERIFIED pass-1 base
# commit (dist/abitwopass.py does the deriving and verifying; this script
# only builds). #4197.
#
#   dist/abitwopass-boot.sh <base-sha>
#
# On success, bit-out/bin/bit is a working compiler built from THIS TREE's
# compiler/** and runtime/**, exactly as `./make libbitrt && ./make` would
# have left it on an ordinary (non-transition) tree -- just reached via an
# extra link (pass 1, off the pinned stage0 and the OLD runtime at
# <base-sha>) instead of directly, because stage0's own call-site lowering
# for the mismatched symbol(s) is baked into its own already-compiled
# machine code and cannot see runtime/**'s new signature (#3152).
#
# runtime/ is restored to HEAD on every exit path, including a mid-pass-1
# kill, via an EXIT trap -- never a trailing line, which a killed pass 1
# would never reach. Do NOT `rm -rf bit-out` between the two passes: `./make`
# links its own build driver against bit-out/lib/<triple>/libbitrt.a, and
# wiping it between passes leaves the driver unbuildable.
set -euo pipefail

BASE="${1:?usage: dist/abitwopass-boot.sh <base-sha>}"

ROOT="$(unset CDPATH; cd -- "$(dirname -- "$0")/.." && pwd)"
cd "${ROOT}"

git diff --quiet -- runtime/ || {
	echo "abitwopass-boot.sh: runtime/ is already dirty before pass 1 -- refusing" >&2
	exit 1
}
git diff --cached --quiet -- runtime/ || {
	echo "abitwopass-boot.sh: runtime/ has staged changes before pass 1 -- refusing" >&2
	exit 1
}

restoreRuntime() {
	git checkout HEAD -- runtime/
}
# Registered before the FIRST tree-mutating command, so a kill at any point
# from here on -- including before pass 1 has written anything -- still
# restores runtime/ rather than leaving it at <base-sha>.
trap restoreRuntime EXIT

rm -rf bit-out
echo "abitwopass-boot.sh: pass 1 -- stage0 builds compiler/** (HEAD) linked against runtime/** at ${BASE}"
git checkout "${BASE}" -- runtime/
./make

PASS1_BIT="$(mktemp "${TMPDIR:-/tmp}/bitrelease-bit1.XXXXXX")"
cp bit-out/bin/bit "${PASS1_BIT}"
# `mktemp` creates its file mode 0600 (no execute), and a plain `cp` into an
# already-existing destination does not change its mode -- verified by
# hitting this for real: pass 2 below failed "is not executable" the first
# time this script ran end to end.
chmod +x "${PASS1_BIT}"

# Restored explicitly here (pass 2 needs runtime/** at HEAD) rather than
# waiting for the EXIT trap, which still fires afterward -- harmlessly, since
# `git checkout HEAD -- runtime/` against an already-clean runtime/ is a
# no-op -- so a kill during pass 2 is covered by the same trap too.
restoreRuntime

echo "abitwopass-boot.sh: pass 2 -- BIT_STAGE0_BIN=${PASS1_BIT} rebuilds compiler/** + runtime/** at HEAD"
BIT_STAGE0_BIN="${PASS1_BIT}" ./make
rm -f "${PASS1_BIT}"

echo "abitwopass-boot.sh: two-pass bootstrap complete, pass-1 base ${BASE}"
