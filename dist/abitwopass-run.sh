#!/usr/bin/env bash
# Bootstraps bit1 off the pinned stage0 for dist/release.sh, transparently
# handling a runtime ABI transition (#4197). ALL progress output goes to
# STDERR; stdout carries exactly one line, always, on success: the derived
# and verified pass-1 base sha (two-pass path), or empty (ordinary path,
# unchanged `./make libbitrt && ./make`).
#
# Ordinary path, unchanged: `./make libbitrt` then `./make`. On the
# documented runtime ABI arity refusal (checkRuntimeAbiArity,
# tools/build/abiarity.bit — see #3152) this instead derives pass 1's base
# MECHANICALLY (dist/abitwopass.py) and performs the two-pass
# BIT_STAGE0_BIN bootstrap (dist/abitwopass-boot.sh, docs/development.md
# "Landing a runtime ABI change") rather than accepting an opaque override,
# which would make the SBOM's provenance claim unre-derivable from the tag
# alone. Any OTHER `./make libbitrt` failure is re-raised with its original
# exit code, unexamined.
set -euo pipefail

ROOT="$(unset CDPATH; cd -- "$(dirname -- "$0")/.." && pwd)"
cd "${ROOT}"

echo "release.sh: building the bootstrap runtime archives (L0, stage0-built)" >&2
ABI_LOG="$(mktemp "${TMPDIR:-/tmp}/bitrelease-abi.XXXXXX")"
set +e
./make libbitrt 2>&1 | tee "${ABI_LOG}" >&2
LIBBITRT_RC="${PIPESTATUS[0]}"
set -e

PASS1_BASE=""
if [ "${LIBBITRT_RC}" -eq 0 ]; then
	echo "release.sh: bootstrapping the host self-hosted compiler with stage0 (bit1)" >&2
	./make >&2
else
	echo "release.sh: ./make libbitrt failed (${LIBBITRT_RC}); checking whether this is the documented runtime ABI transition" >&2
	PLAN="$(mktemp "${TMPDIR:-/tmp}/bitrelease-abiplan.XXXXXX")"
	if ! python3 dist/abitwopass.py "${ABI_LOG}" >"${PLAN}"; then
		echo "release.sh: ./make libbitrt failed for a reason other than the documented runtime ABI transition — see ${ABI_LOG}" >&2
		rm -f "${PLAN}"
		exit "${LIBBITRT_RC}"
	fi
	PASS1_BASE="$(sed -n 's/^ABI_TWOPASS_BASE=//p' "${PLAN}")"
	rm -f "${PLAN}"
	[ -n "${PASS1_BASE}" ] || {
		echo "release.sh: dist/abitwopass.py exited 0 but printed no ABI_TWOPASS_BASE" >&2
		exit 1
	}
	echo "release.sh: runtime ABI transition detected; two-pass bootstrap, pass-1 base ${PASS1_BASE}" >&2
	bash dist/abitwopass-boot.sh "${PASS1_BASE}" >&2
fi
rm -f "${ABI_LOG}"
echo "${PASS1_BASE}"
