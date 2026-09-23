#!/usr/bin/env bash
# The two-pass BIT_STAGE0_BIN bootstrap (docs/development.md, "Landing a
# runtime ABI change" / "Landing a syntax change that `stdlib/**` then
# uses"), given an already-derived and VERIFIED pass-1 base commit and the
# directory pass 1 must check out at that base (dist/abitwopass.py does the
# deriving and verifying; this script only builds). #4197, #5752.
#
#   dist/abitwopass-boot.sh <base-sha> <dir>
#
# <dir> is "runtime" or "stdlib" -- the top-level directory pass 1 checks
# out at <base-sha> instead of HEAD. Both transitions share the identical
# two-pass shape (stage0 + tree compiler/** linked against an OLD copy of
# one directory, then BIT_STAGE0_BIN relinks everything at HEAD); only WHICH
# directory moves differs, so this is parameterised rather than
# hand-duplicated.
#
# On success, bit-out/bin/bit is a working compiler built from THIS TREE's
# source, exactly as `./make libbitrt && ./make` would have left it on an
# ordinary (non-transition) tree -- just reached via an extra link (pass 1,
# off the pinned stage0 and the OLD <dir>/** at <base-sha>) instead of
# directly. A runtime transition needs this because stage0's own call-site
# lowering for the mismatched symbol(s) is baked into its own already-
# compiled machine code and cannot see runtime/**'s new signature (#3152); a
# stdlib transition needs it because stage0's own PARSER predates the new
# syntax and `tools/build/` (which the top-level `make` wrapper always
# rebuilds with stage0 first) transitively imports stdlib/** (#5752).
#
# <dir>/ is restored to HEAD on every exit path, including a mid-pass-1
# kill, via an EXIT trap -- never a trailing line, which a killed pass 1
# would never reach. Do NOT `rm -rf bit-out` between the two passes: `./make`
# links its own build driver against bit-out/lib/<triple>/libbitrt.a, and
# wiping it between passes leaves the driver unbuildable.
set -euo pipefail

BASE="${1:?usage: dist/abitwopass-boot.sh <base-sha> <dir>}"
DIR="${2:?usage: dist/abitwopass-boot.sh <base-sha> <dir>}"
case "${DIR}" in
	runtime|stdlib) ;;
	*)
		echo "abitwopass-boot.sh: <dir> must be 'runtime' or 'stdlib', got '${DIR}'" >&2
		exit 1
		;;
esac

ROOT="$(unset CDPATH; cd -- "$(dirname -- "$0")/.." && pwd)"
cd "${ROOT}"

git diff --quiet -- "${DIR}/" || {
	echo "abitwopass-boot.sh: ${DIR}/ is already dirty before pass 1 -- refusing" >&2
	exit 1
}
git diff --cached --quiet -- "${DIR}/" || {
	echo "abitwopass-boot.sh: ${DIR}/ has staged changes before pass 1 -- refusing" >&2
	exit 1
}

restoreDir() {
	git checkout HEAD -- "${DIR}/"
}
# Registered before the FIRST tree-mutating command, so a kill at any point
# from here on -- including before pass 1 has written anything -- still
# restores ${DIR}/ rather than leaving it at <base-sha>.
trap restoreDir EXIT

rm -rf bit-out
echo "abitwopass-boot.sh: pass 1 -- stage0 builds compiler/** (HEAD) linked against ${DIR}/** at ${BASE}"
git checkout "${BASE}" -- "${DIR}/"
./make

PASS1_BIT="$(mktemp "${TMPDIR:-/tmp}/bitrelease-bit1.XXXXXX")"
cp bit-out/bin/bit "${PASS1_BIT}"
# `mktemp` creates its file mode 0600 (no execute), and a plain `cp` into an
# already-existing destination does not change its mode -- verified by
# hitting this for real: pass 2 below failed "is not executable" the first
# time this script ran end to end.
chmod +x "${PASS1_BIT}"

# Restored explicitly here (pass 2 needs ${DIR}/** at HEAD) rather than
# waiting for the EXIT trap, which still fires afterward -- harmlessly, since
# `git checkout HEAD -- ${DIR}/` against an already-clean ${DIR}/ is a
# no-op -- so a kill during pass 2 is covered by the same trap too.
restoreDir

echo "abitwopass-boot.sh: pass 2 -- BIT_STAGE0_BIN=${PASS1_BIT} rebuilds compiler/** + runtime/** + stdlib/** at HEAD"
BIT_STAGE0_BIN="${PASS1_BIT}" ./make
rm -f "${PASS1_BIT}"

echo "abitwopass-boot.sh: two-pass bootstrap complete, ${DIR} pass-1 base ${BASE}"
