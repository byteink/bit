#!/usr/bin/env bash
# Run `./make test` for x86_64-linux on the real-hardware box (see
# scripts/x64host.sh) in Docker, over the committed tree (git archive HEAD).
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
#   x64gate.sh fuzz      # run `./make fuzz` (FUZZ_SECS=60 by default) instead
#                        # of the test suite, on real x86_64 hardware.
#
# IT ONLY SEES COMMITTED WORK. `git archive HEAD` ignores the working tree and
# the index, so uncommitted edits are NOT tested. Commit first, then gate.
#
# X64GATE_ALL_HOSTS=1 x64gate.sh   # run against EVERY reachable candidate from
#                                  # x64host.sh, not just the first that answers.
# One machine-local candidate list can rank a fast box first and a slow one
# second (e.g. a faster box over a slower one); a hardware-timing-sensitive gate that
# stops at the first answer can pass on the fast box while a real regression
# stays invisible there (#1690). Opt into this for any gate checking timing,
# not for routine runs — it costs one full run per reachable box.
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
#   real x86_64 hardware:     `x64gate.sh fuzz` -> 10,970 iterations, 0 crashes,
#                             X64LINUX_EXIT=0.
#   emulated amd64 on the Mac: `./make fuzz` never runs a single iteration. It
#                             fails to COMPILE with exactly 2 errors — glibc
#                             `libc_nonshared.a` and `Scrt1.o`, both
#                             "unknown target CPU 'athlon-xp'".
# Zero Bit code executes in the emulated failure, so it cannot be a Bit defect.
# STEP defaults to the full suite but an exported STEP env wins (scripts/gate.sh
# sets it to a scoped set like "test-golden test-imports-bit"). #1772.
STEP="${STEP:-test}"
if [ "${MODE}" = "fuzz" ]; then
  STEP="fuzz -- ${FUZZ_SECS:-60}"
  MODE="fast"
fi
VOLUME="bit-zig-cache-amd64"

# Which real-x86_64 box runs the gate. No hostname is baked into the repo —
# machine names are the operator's, not the project's. Resolution order:
#   1. $X64GATE_HOST
#   2. scripts/.x64gate-host  (gitignored, one line: an ssh host alias)
#   3. scripts/x64host.sh     (shared resolver: $BIT_X64_HOST, $BIT_X64_HOSTS,
#                              $BIT_X64_HOSTS_FILE, ./.x64hosts,
#                              ~/.config/bit/x64hosts — first candidate that
#                              ANSWERS wins, so a sleeping box falls through)
# The resolved host is ECHOED before the run: which box a number came from is
# part of the result, and x86-64-vs-aarch64 disagreement is this repo's standard
# tell for an ABI-boundary bug.
# The host needs ssh access and a `bit-zig-0.16.0-amd64` image. Copy it with
# `docker save | docker load` rather than rebuilding, so every host runs a
# byte-identical image and a host swap cannot change what is being tested.
X64GATE_HOST="${X64GATE_HOST:-}"
if [ -z "${X64GATE_HOST}" ] && [ -f "$(dirname "$0")/.x64gate-host" ]; then
  X64GATE_HOST=$(tr -d '[:space:]' < "$(dirname "$0")/.x64gate-host")
fi
if [ "${X64GATE_ALL_HOSTS:-0}" = "1" ]; then
  # Opt-in: every reachable candidate, not just the first that answers — see
  # the file header for why a hardware-timing-sensitive gate needs this.
  HOSTS=$(bash "$(dirname "$0")/x64host.sh" --all) || {
    echo "x64gate: no host configured (see above). Each host also needs a" >&2
    echo "         bit-zig-0.16.0-amd64 image." >&2
    exit 127
  }
elif [ -n "${X64GATE_HOST}" ]; then
  HOSTS="${X64GATE_HOST}"
else
  HOSTS=$(bash "$(dirname "$0")/x64host.sh") || {
    echo "x64gate: no host configured (see above). The host also needs a" >&2
    echo "         bit-zig-0.16.0-amd64 image." >&2
    exit 127
  }
fi
echo "x64gate: host(s)=$(printf '%s' "${HOSTS}" | tr '\n' ' ')"

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
total=0
while IFS= read -r host; do
  [ -n "${host}" ] || continue
  # The suite needs a `git` binary INSIDE the image: the package manager fetches
  # dependencies by shelling out to it, so tests/imports/pmadd_e2e,
  # tests/pmimports.zig and compiler/pmclicheck.bit all fail without it — as
  # `git: not found`, an empty failure, and a bare assertion panic respectively
  # (#1818). Refused here so the cause is named once, instead of three
  # unrelated-looking harnesses going red on the remote box. macOS has git from
  # the host, which is why a git-less image passed the local gate.
  ssh "${host}" "docker run --rm ${IMAGE} sh -c 'command -v git'" >/dev/null 2>&1 || {
    echo "x64gate: ${IMAGE} on ${host} has no git — rebuild it from docker/zig-linux.Dockerfile" >&2; exit 127; }
  for i in $(seq 1 "${RUNS}"); do
    total=$((total + 1))
    { [ "${RUNS}" -gt 1 ] || [ "${X64GATE_ALL_HOSTS:-0}" = "1" ]; } && echo "===RUN host=${host} ${i}/${RUNS}==="
    code=$(git archive HEAD | ssh "${host}" "docker run --rm -i ${CACHE_ARGS} ${IMAGE} bash -c '
      mkdir -p /work && cd /work && tar x &&
      BIT_STAGE0_CACHE=${CACHE_ENV}/stage0 ./make ${STEP} > /tmp/o 2>&1
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
done <<< "${HOSTS}"

if [ "${total}" -gt 1 ]; then
  echo "===SUMMARY=== ${fails}/${total} runs failed"
fi
# The script's exit status must track the GATE, not merely whether ssh and docker
# ran. This previously returned 0 unconditionally for a single run, so a red
# X64LINUX_EXIT was reported as success by anything reading `$?` — a gate that
# cannot fail is not a gate. An intermittent must not pass either, so a failure in
# ANY run of a repeat sweep is a failure.
[ "${fails}" -gt 0 ] && exit 1
exit 0
