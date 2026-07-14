#!/usr/bin/env bash
# Run `zig build test` for x86_64-linux on the real-hardware box (hl-master) in
# Docker, over the committed tree (git archive HEAD).
#
#   x64gate.sh          # fast: reuse a persistent zig cache volume (only changed
#                       #       files recompile) — for iterative checks
#   x64gate.sh clean    # clean-room: throwaway cache, full cold build — for a
#                       #       final sign-off where no stale artifact may hide
#
# Prints the tail of the build/test log and a final `X64LINUX_EXIT=<code>` line.
set -euo pipefail

MODE="${1:-fast}"
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

git archive HEAD | ssh hl-master "docker run --rm -i ${CACHE_ARGS} ${IMAGE} bash -c '
  mkdir -p /work && cd /work && tar x &&
  ZIG_GLOBAL_CACHE_DIR=${CACHE_ENV} zig build test > /tmp/o 2>&1
  e=\$?
  echo ===TAIL===
  tail -35 /tmp/o
  echo X64LINUX_EXIT=\$e
'"
