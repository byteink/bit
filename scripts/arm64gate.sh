#!/usr/bin/env bash
# Run `zig build test` for aarch64-linux in Docker on this machine, over the
# committed tree (git archive HEAD).
#
# The image `bit-zig-0.16.0:latest` is a NATIVE aarch64 Zig image, so on an
# Apple-Silicon host this is real ARM64 Linux execution — no qemu, no emulation
# artifacts to argue about. `zig build test` inside it resolves host_target to
# aarch64-linux, so the whole suite exercises that backend.
#
#   arm64gate.sh          # fast: reuse a persistent zig cache volume (only changed
#                         #       files recompile) — for iterative checks
#   arm64gate.sh clean    # clean-room: throwaway cache, full cold build — for a
#                         #       final sign-off where no stale artifact may hide
#   arm64gate.sh <mode> N # repeat N times — for chasing an intermittent, which a
#                         # single green run cannot rule out
#   arm64gate.sh selftest # prove the gate can fail: a no-op control run that MUST
#                         # be green, then a deliberately broken tree that MUST be
#                         # red. A gate nobody has seen fail is not a gate.
#
# IT ONLY SEES COMMITTED WORK. `git archive HEAD` ignores the working tree and
# the index entirely, so uncommitted edits are NOT tested. This has surprised
# people; commit first, then gate.
#
# A cold run takes over an hour on a loaded machine and prints nothing until it
# finishes (the container buffers into /tmp/o). To watch progress, find the
# container with `docker ps --filter name=arm64gate` and
# `docker exec <id> tail -f /tmp/o`. Raise the ceiling with ARM64GATE_DEADLINE.
#
# On success prints the log tail; on FAILURE prints the whole log, because the
# tail alone routinely cuts off the one line that names the failing test — a gate
# that cannot say what broke is not a gate. Always ends with `ARM64LINUX_EXIT=<code>`.
set -euo pipefail

MODE="${1:-fast}"
RUNS="${2:-1}"
IMAGE="bit-zig-0.16.0:latest"
VOLUME="bit-zig-cache-arm64"
# Wall-clock ceiling for one suite run. A hang must read as a failure, never as a
# gate that sits forever looking busy.
DEADLINE="${ARM64GATE_DEADLINE:-5400}"

# macOS has no coreutils `timeout`; perl's alarm is the portable stand-in. A
# missing tool must abort, never silently skip the deadline.
command -v perl  >/dev/null || { echo "arm64gate: perl not found (needed for the deadline)" >&2; exit 127; }
command -v docker >/dev/null || { echo "arm64gate: docker not found" >&2; exit 127; }
docker image inspect "${IMAGE}" >/dev/null 2>&1 || {
  echo "arm64gate: image ${IMAGE} missing — build it (debian:bookworm arm64 + zig-aarch64-linux-0.16.0)" >&2; exit 127; }
[ "$(docker run --rm "${IMAGE}" uname -m)" = "aarch64" ] || {
  echo "arm64gate: ${IMAGE} is not native aarch64 — it would gate the wrong backend" >&2; exit 127; }

if [ "${MODE}" = "clean" ]; then
  # Ephemeral in-container cache: nothing persists, guaranteeing a cold build.
  CACHE_ARGS=""
  CACHE_ENV="/tmp/gc"
else
  # Named volume survives across runs so incremental compilation kicks in.
  CACHE_ARGS="-v ${VOLUME}:/cache"
  CACHE_ENV="/cache"
fi

# Several agents share this machine. Two gate runs against one named cache volume
# can read each other's artifacts, so a contended `fast` run is not a sign-off.
# Report the peer count (machine-greppable) and drop to an isolated cache rather
# than hand back a fast-but-untrustworthy result.
PEERS=$(docker ps -q --filter "ancestor=${IMAGE}" | wc -l | tr -d ' ')
echo "ARM64GATE_PEERS=${PEERS}"
if [ "${PEERS}" -gt 0 ] && [ -n "${CACHE_ARGS}" ]; then
  echo "arm64gate: ${PEERS} other ${IMAGE} container(s) running; not sharing ${VOLUME} — using an isolated cache (cold, slower, trustworthy)" >&2
  CACHE_ARGS=""
  CACHE_ENV="/tmp/gc"
fi
# Host load is shared too: a suite killed by memory/CPU pressure reads exactly
# like a real failure. Say so up front instead of letting someone misread it.
echo "ARM64GATE_LOAD=$(uptime | sed -n 's/.*load averages*: *//p' | awk '{print $1}')"

# Run the suite over the tar stream on stdin. Echoes the container log and prints
# ARM64LINUX_EXIT=<code>; returns that code as its own exit status.
run_suite() {
  local code name
  # Name the container so it can be reaped. `docker run` does NOT die with its
  # driving shell: when this script is killed (harness timeout, Ctrl-C, the perl
  # alarm), an unnamed container keeps burning every core on a result nobody will
  # ever read. Observed exactly that on 2026-07-19.
  name="arm64gate-$$-${RANDOM}"
  trap 'docker rm -f "${name}" >/dev/null 2>&1 || true' EXIT INT TERM
  code=$(perl -e 'alarm shift; exec @ARGV' "${DEADLINE}" \
    docker run --rm -i --name "${name}" ${CACHE_ARGS} "${IMAGE}" bash -c '
      mkdir -p /work && cd /work && tar x &&
      ZIG_GLOBAL_CACHE_DIR='"${CACHE_ENV}"' zig build test > /tmp/o 2>&1
      e=$?
      if [ $e -eq 0 ]; then
        echo ===TAIL===
        tail -35 /tmp/o
      else
        echo ===FAILURE_FULL_LOG===
        cat /tmp/o
      fi
      echo ARM64LINUX_EXIT=$e
    ' | tee /dev/stderr | sed -n 's/^ARM64LINUX_EXIT=//p')
  docker rm -f "${name}" >/dev/null 2>&1 || true
  trap - EXIT INT TERM
  # An empty code means the container died or the deadline fired — that is a
  # failure, not an unknown to be shrugged off.
  if [ -z "${code}" ]; then
    echo "ARM64LINUX_EXIT=124  (no exit line: container killed or ${DEADLINE}s deadline hit)"
    return 124
  fi
  return "${code}"
}

if [ "${MODE}" = "selftest" ]; then
  # 1. Control: the unmodified committed tree MUST pass. If this is red the
  #    selftest proves nothing, so stop rather than report a meaningless red.
  echo "===SELFTEST CONTROL (no-op, must be GREEN)==="
  if git archive HEAD | run_suite; then
    echo "SELFTEST_CONTROL=pass"
  else
    echo "SELFTEST_CONTROL=fail  — HEAD is already red; fix that before trusting a mutation result" >&2
    echo "ARM64GATE_SELFTEST=inconclusive"
    exit 1
  fi

  # 2. Mutant: corrupt one golden expectation in a THROWAWAY copy (the repo is
  #    never touched) and require the gate to go red. Breaking an .expected file
  #    rather than the compiler proves the gate sees a genuine TEST failure, not
  #    just a build error.
  tmp=$(mktemp -d)
  trap 'rm -rf "${tmp}"' EXIT
  git archive HEAD | tar x -C "${tmp}"
  victim=$(ls "${tmp}"/tests/cases/*.expected | head -1)
  [ -n "${victim}" ] || { echo "arm64gate: no golden .expected found to mutate" >&2; exit 127; }
  echo "arm64gate: mutating $(basename "${victim}")"
  printf 'arm64gate-deliberate-breakage\n' >> "${victim}"

  echo "===SELFTEST MUTANT (deliberate breakage, must be RED)==="
  if tar c -C "${tmp}" . | run_suite; then
    echo "ARM64GATE_SELFTEST=BROKEN — the gate passed a deliberately broken tree" >&2
    exit 1
  fi
  echo "ARM64GATE_SELFTEST=ok (control green, mutant red)"
  exit 0
fi

fails=0
for i in $(seq 1 "${RUNS}"); do
  [ "${RUNS}" -gt 1 ] && echo "===RUN ${i}/${RUNS}==="
  git archive HEAD | run_suite || fails=$((fails + 1))
done

if [ "${RUNS}" -gt 1 ]; then
  echo "===SUMMARY=== ${fails}/${RUNS} runs failed"
fi
# An intermittent must not report success just because the last run passed.
[ "${fails}" -gt 0 ] && exit 1
exit 0
