#!/bin/sh
# Entry point for the Bit build driver (#1868, epic #1867).
#
# All the logic lives in `tools/build/` and is written in Bit. This file exists
# only to break the one bootstrap step that cannot be written in Bit: something
# has to compile the driver before the driver can run. It resolves the pinned
# stage0 (a `bit`), builds `tools/build/` with it, and execs the result.
#
# WHY SHELL IS ACCEPTABLE HERE, when the point of #1867 was to stop needing a
# second toolchain to build Bit at all. `sh` is already a hard dependency of
# this repo: the fifteen `scripts/selfhost-diff*.sh`, `gate.sh`, `g2archive.sh`,
# `stage0.sh`, `release.sh` and the harnesses' own generated wrappers all use
# it. Ten lines of POSIX `sh` add nothing that was not already required. This
# file must stay that small — logic belongs in `tools/build/`, in Bit.
#
# Usage: ./make [--list] [<step>...]
set -eu

ROOT="$(unset CDPATH; cd -- "$(dirname -- "$0")" && pwd)"
# Every step runs relative to the repo, and the harnesses need ABSOLUTE paths:
# several generate a wrapper that `cd`s elsewhere before exec'ing, so a relative
# BIT_BIN or BIT_STDLIB would resolve against the wrong directory.
cd "${ROOT}"
BIT_MAKE_ROOT="${ROOT}"
export BIT_MAKE_ROOT
CACHE="${ROOT}/bit-out/make"
DRIVER="${CACHE}/make-driver"
SRC="${ROOT}/tools/build"

mkdir -p "${CACHE}"

# Rebuild only when a source file is newer than the driver, so the common path
# — running a step on an unchanged tree — does not pay a compile. `find -newer`
# rather than a hash: this is a developer convenience, and the correctness gate
# that actually matters (the libbitrt fingerprint) is #1869's problem, not this
# file's.
needs_build=0
if [ ! -x "${DRIVER}" ]; then
  needs_build=1
elif [ -n "$(find "${SRC}" -name '*.bit' -newer "${DRIVER}" -print -quit 2>/dev/null)" ]; then
  needs_build=1
fi

if [ "${needs_build}" -eq 1 ]; then
  STAGE0="$(sh "${ROOT}/scripts/stage0.sh")" || exit 2
  # Refuse rather than fall back to a stale driver: running yesterday's build
  # logic against today's tree is exactly the silent-wrong-answer class this
  # driver is being written to avoid.
  "${STAGE0}" build "${SRC}" -o "${DRIVER}" || {
    echo "make: cannot build the driver from ${SRC}" >&2
    exit 2
  }
  chmod +x "${DRIVER}"
fi

exec "${DRIVER}" "$@"
