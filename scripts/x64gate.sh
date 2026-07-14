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
set -euo pipefail

MODE="${1:-fast}"
RUNS="${2:-1}"
IMAGE="bit-zig-0.16.0-amd64:latest"
VOLUME="bit-zig-cache-amd64"

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
  code=$(git archive HEAD | ssh hl-master "docker run --rm -i ${CACHE_ARGS} ${IMAGE} bash -c '
    mkdir -p /work && cd /work && tar x &&
    ZIG_GLOBAL_CACHE_DIR=${CACHE_ENV} zig build test > /tmp/o 2>&1
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
  # An intermittent must not report success just because the last run passed.
  [ "${fails}" -gt 0 ] && exit 1
fi
exit 0
