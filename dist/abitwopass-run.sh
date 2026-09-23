#!/usr/bin/env bash
# Bootstraps bit1 off the pinned stage0 for dist/release.sh, transparently
# handling TWO documented transitions the ordinary `./make libbitrt && ./make`
# cannot survive: a runtime ABI change (#4197/#4416) and a stdlib syntax
# change `stdlib/**` starts using before the next stage0 repin (#5752). ALL
# progress output goes to STDERR; stdout carries exactly one line, always, on
# success: the derived and verified pass-1 base sha (two-pass path), or empty
# (ordinary path, unchanged `./make libbitrt && ./make`).
#
# Ordinary path, unchanged: `./make libbitrt` then `./make`. EITHER step can
# fail on one of the two documented refusals. A runtime ABI mismatch
# (checkRuntimeAbiArity / checkRuntimeAbiLayout, tools/build/abiarity.bit /
# abilayout.bit) always surfaces at `./make libbitrt`, because that is the
# step that links against runtime/**. A stdlib syntax refusal can surface at
# EITHER step: `./make`'s own shell wrapper recompiles the Bit-written build
# driver (tools/build/, which imports std/fs, std/os, std/time) before
# running ANY step at all, so whether that recompile is even attempted
# depends on what is already cached in bit-out/make/ -- a warm driver built
# before the offending stdlib change lets `./make libbitrt` succeed and the
# refusal only surfaces once a later step needs to re-check stdlib/**, a
# cold one fails right there. Both steps' logs are guarded identically
# rather than assuming only one of them can fail.
#
# On a documented refusal this derives pass 1's base MECHANICALLY
# (dist/abitwopass.py) and performs the two-pass BIT_STAGE0_BIN bootstrap
# (dist/abitwopass-boot.sh, docs/development.md "Landing a runtime ABI
# change" / "Landing a syntax change that `stdlib/**` then uses") rather than
# accepting an opaque override, which would make the SBOM's provenance claim
# unre-derivable from the tag alone. Any OTHER failure -- of either step --
# is re-raised with its original exit code, unexamined.
#
# #5753: a caller that also needs to know WHICH directory (runtime|stdlib)
# triggered the two-pass build -- dist/release.sh, for its NOTES.md/SBOM
# provenance wording -- sets PASS1_DIR_FILE to a path before invoking this
# script; on a documented refusal this writes that word there. Not stdout:
# this script runs inside the caller's `$(...)`, a subshell, so nothing it
# sets in its own environment survives past its exit, and stdout's contract
# above must stay exactly one line. Left unset, the write is skipped -- a
# caller that only wants the sha pays nothing for it.
set -euo pipefail

ROOT="$(unset CDPATH; cd -- "$(dirname -- "$0")/.." && pwd)"
cd "${ROOT}"

PASS1_BASE=""

# Examines ${1} (a failed step's captured combined stdout+stderr log) for a
# documented two-pass transition. On a match: derives+verifies the base,
# runs the two-pass bootstrap, and leaves PASS1_BASE set (return 0). On no
# match: prints nothing of its own (dist/abitwopass.py already explained
# itself on stderr) and returns 1, so the caller re-raises the ORIGINAL rc
# rather than this function's.
tryTwoPass() {
	local log="$1"
	local plan
	plan="$(mktemp "${TMPDIR:-/tmp}/bitrelease-twopassplan.XXXXXX")"
	if ! python3 dist/abitwopass.py "${log}" >"${plan}"; then
		rm -f "${plan}"
		return 1
	fi
	PASS1_BASE="$(sed -n 's/^ABI_TWOPASS_BASE=//p' "${plan}")"
	local dir
	dir="$(sed -n 's/^ABI_TWOPASS_DIR=//p' "${plan}")"
	rm -f "${plan}"
	[ -n "${PASS1_BASE}" ] && [ -n "${dir}" ] || {
		echo "release.sh: dist/abitwopass.py exited 0 but printed no ABI_TWOPASS_BASE/ABI_TWOPASS_DIR" >&2
		exit 1
	}
	echo "release.sh: two-pass transition detected (${dir}/**); pass-1 base ${PASS1_BASE}" >&2
	[ -n "${PASS1_DIR_FILE:-}" ] && printf '%s' "${dir}" >"${PASS1_DIR_FILE}"
	bash dist/abitwopass-boot.sh "${PASS1_BASE}" "${dir}" >&2
}

echo "release.sh: building the bootstrap runtime archives (L0, stage0-built)" >&2
LIBBITRT_LOG="$(mktemp "${TMPDIR:-/tmp}/bitrelease-libbitrt.XXXXXX")"
set +e
./make libbitrt 2>&1 | tee "${LIBBITRT_LOG}" >&2
LIBBITRT_RC="${PIPESTATUS[0]}"
set -e

if [ "${LIBBITRT_RC}" -ne 0 ]; then
	echo "release.sh: ./make libbitrt failed (${LIBBITRT_RC}); checking whether this is a documented two-pass transition" >&2
	if ! tryTwoPass "${LIBBITRT_LOG}"; then
		echo "release.sh: ./make libbitrt failed for a reason other than a documented two-pass transition - see ${LIBBITRT_LOG}" >&2
		exit "${LIBBITRT_RC}"
	fi
	rm -f "${LIBBITRT_LOG}"
else
	rm -f "${LIBBITRT_LOG}"
	echo "release.sh: bootstrapping the host self-hosted compiler with stage0 (bit1)" >&2
	MAKE_LOG="$(mktemp "${TMPDIR:-/tmp}/bitrelease-make.XXXXXX")"
	set +e
	./make 2>&1 | tee "${MAKE_LOG}" >&2
	MAKE_RC="${PIPESTATUS[0]}"
	set -e
	if [ "${MAKE_RC}" -ne 0 ]; then
		echo "release.sh: ./make failed (${MAKE_RC}); checking whether this is a documented two-pass transition" >&2
		if ! tryTwoPass "${MAKE_LOG}"; then
			echo "release.sh: ./make failed for a reason other than a documented two-pass transition - see ${MAKE_LOG}" >&2
			exit "${MAKE_RC}"
		fi
	fi
	rm -f "${MAKE_LOG}"
fi

echo "${PASS1_BASE}"
