#!/usr/bin/env bash
# Run `zig build test` for x86_64-linux on the real-hardware box (hl-master) in
# Docker, over the committed tree (git archive HEAD).
#
#   x64gate.sh          # fast: reuse a persistent zig cache volume (only changed
#                       #       files recompile) — for iterative checks
#   x64gate.sh clean    # clean-room: throwaway cache, full cold build — for a
#                       #       final sign-off where no stale artifact may hide
#
# On success prints the log tail; on FAILURE prints the whole log, because the
# tail alone routinely cuts off the one line that names the failing test — a gate
# that cannot say what broke is not a gate. Always ends with `X64LINUX_EXIT=<code>`.
#
#   x64gate.sh <mode> N  # repeat N times, reporting each run — for chasing an
#                        # intermittent, which a single green run cannot rule out.
#   x64gate.sh fuzz      # run `zig build fuzz` (FUZZ_SECS=60 by default) instead
#                        # of the test suite, on real x86_64 hardware.
#
# IT ONLY SEES COMMITTED WORK. `git archive HEAD` ignores the working tree and
# the index, so uncommitted edits are NOT tested. Commit first, then gate.
set -euo pipefail

MODE="${1:-fast}"
RUNS="${2:-1}"
IMAGE="bit-zig-0.16.0-amd64:latest"

# `fuzz` runs the mutation fuzzer instead of the test suite, on REAL x86_64.
# This exists because the amd64 image reports 2 fuzz failures when it runs
# EMULATED on an Apple-Silicon Mac: emulated Zig's native-CPU autodetect returns
# `athlon_xp`, which current Zig rejects for the musl crt1.o sub-compile that the
# fuzz step's `link_libc` needs. That is a toolchain artifact of emulation, not a
# Bit bug — and this mode is how you check that claim instead of inheriting it.
#
# SETTLED 2026-07-19 (#1258), measured both ways at tree ff9ac2e — do not re-chase:
#   real x86_64 (hl-master):  `x64gate.sh fuzz` -> 10,970 iterations, 0 crashes,
#                             X64LINUX_EXIT=0.
#   emulated amd64 on the Mac: `zig build fuzz` never runs a single iteration. It
#                             fails to COMPILE with exactly 2 errors — glibc
#                             `libc_nonshared.a` and `Scrt1.o`, both
#                             "unknown target CPU 'athlon-xp'".
# Zero Bit code executes in the emulated failure, so it cannot be a Bit defect.
STEP="test"
if [ "${MODE}" = "fuzz" ]; then
  STEP="fuzz -- ${FUZZ_SECS:-60}"
  MODE="fast"
fi
VOLUME="bit-zig-cache-amd64"

# Which real-x86_64 box runs the gate. No hostname is baked into the repo —
# machine names are the operator's, not the project's. Resolution order:
#   1. $X64GATE_HOST
#   2. scripts/.x64gate-host  (gitignored, one line: an ssh host alias)
# The host needs ssh access and a `bit-zig-0.16.0-amd64` image. Copy it with
# `docker save | docker load` rather than rebuilding, so every host runs a
# byte-identical image and a host swap cannot change what is being tested.
X64GATE_HOST="${X64GATE_HOST:-}"
if [ -z "${X64GATE_HOST}" ] && [ -f "$(dirname "$0")/.x64gate-host" ]; then
  X64GATE_HOST=$(tr -d '[:space:]' < "$(dirname "$0")/.x64gate-host")
fi
if [ -z "${X64GATE_HOST}" ]; then
  echo "x64gate: no host configured. Set X64GATE_HOST=<ssh-alias>, or write it" >&2
  echo "         to scripts/.x64gate-host (gitignored). The host needs ssh plus" >&2
  echo "         a bit-zig-0.16.0-amd64 image." >&2
  exit 127
fi

if [ "$MODE" = "clean" ]; then
  # Ephemeral in-container cache: nothing persists, guaranteeing a cold build.
  CACHE_ARGS=""
  CACHE_ENV="/tmp/gc"
else
  # Named volume survives across runs so incremental compilation kicks in.
  CACHE_ARGS="-v ${VOLUME}:/cache"
  CACHE_ENV="/cache"
fi

fails=0
for i in $(seq 1 "${RUNS}"); do
  [ "${RUNS}" -gt 1 ] && echo "===RUN ${i}/${RUNS}==="
  code=$(git archive HEAD | ssh "${X64GATE_HOST}" "docker run --rm -i ${CACHE_ARGS} ${IMAGE} bash -c '
    mkdir -p /work && cd /work && tar x &&
    ZIG_GLOBAL_CACHE_DIR=${CACHE_ENV} zig build ${STEP} > /tmp/o 2>&1
    e=\$?
    if [ \$e -eq 0 ]; then
      echo ===TAIL===
      tail -35 /tmp/o
    else
      echo ===FAILURE_FULL_LOG===
      cat /tmp/o
    fi
    echo X64LINUX_EXIT=\$e
  '" | tee /dev/stderr | sed -n 's/^X64LINUX_EXIT=//p')
  [ "${code}" != "0" ] && fails=$((fails + 1))
done

if [ "${RUNS}" -gt 1 ]; then
  echo "===SUMMARY=== ${fails}/${RUNS} runs failed"
fi
# The script's exit status must track the GATE, not merely whether ssh and docker
# ran. This previously returned 0 unconditionally for a single run, so a red
# X64LINUX_EXIT was reported as success by anything reading `$?` — a gate that
# cannot fail is not a gate. An intermittent must not pass either, so a failure in
# ANY run of a repeat sweep is a failure.
[ "${fails}" -gt 0 ] && exit 1
exit 0
