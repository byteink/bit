#!/usr/bin/env bash
# Run `./make test` for x86_64-linux on the real-hardware box (see
# scripts/x64host.sh) in Docker, over the committed tree (git archive HEAD).
#
#   x64gate.sh          # fast: reuse a persistent build cache volume (only changed
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
IMAGE="bit-linux-gate-amd64:latest"

# `fuzz` runs the mutation fuzzer instead of the test suite, on REAL x86_64 —
# the only place an x86-64 codegen crash can be trusted as a Bit defect rather
# than an emulation artifact. Baseline, measured at tree ff9ac2e (#1258):
# 10,970 iterations, 0 crashes, X64LINUX_EXIT=0.
#
# STEP defaults to the full suite but an exported STEP env wins (scripts/gate.sh
# sets it to a scoped set like "test-golden test-imports-bit"). #1772.
STEP="${STEP:-test}"
if [ "${MODE}" = "fuzz" ]; then
  STEP="fuzz -- ${FUZZ_SECS:-60}"
  MODE="fast"
fi
VOLUME="bit-gate-cache-amd64"

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
# The host needs ssh access and a `bit-linux-gate-amd64` image. Copy it with
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
    echo "         bit-linux-gate-amd64 image." >&2
    exit 127
  }
elif [ -n "${X64GATE_HOST}" ]; then
  HOSTS="${X64GATE_HOST}"
else
  HOSTS=$(bash "$(dirname "$0")/x64host.sh") || {
    echo "x64gate: no host configured (see above). The host also needs a" >&2
    echo "         bit-linux-gate-amd64 image." >&2
    exit 127
  }
fi
echo "x64gate: host(s)=$(printf '%s' "${HOSTS}" | tr '\n' ' ')"

# "clean" always uses an ephemeral cache, so it never needs a peer check.
# "fast" shares a named volume across invocations and DOES need one — done
# below, inside the ssh session, per run (#3733).
if [ "$MODE" = "clean" ]; then
  CACHE_MODE="clean"
else
  CACHE_MODE="fast"
fi

fails=0
total=0
while IFS= read -r host; do
  [ -n "${host}" ] || continue
  # The suite needs a `git` binary INSIDE the image: the package manager fetches
  # dependencies by shelling out to it, so _tests_/imports/pmadd_e2e,
  # _tests_/bit/pmimports.bit and compiler/pmclicheck.bit all fail without it — as
  # `git: not found`, an empty failure, and a bare assertion panic respectively
  # (#1818). Refused here so the cause is named once, instead of three
  # unrelated-looking harnesses going red on the remote box. macOS has git from
  # the host, which is why a git-less image passed the local gate.
  ssh "${host}" "docker run --rm ${IMAGE} sh -c 'command -v git'" >/dev/null 2>&1 || {
    echo "x64gate: ${IMAGE} on ${host} has no git — rebuild it from docker/linux-gate.Dockerfile" >&2; exit 127; }
  for i in $(seq 1 "${RUNS}"); do
    total=$((total + 1))
    { [ "${RUNS}" -gt 1 ] || [ "${X64GATE_ALL_HOSTS:-0}" = "1" ]; } && echo "===RUN host=${host} ${i}/${RUNS}==="
    # Several agents can share the remote box. The peer probe below runs ON
    # THE REMOTE HOST, inside this same ssh session, immediately before the
    # `docker run` it gates — a `docker ps` on the Mac driving this script
    # would inspect the wrong machine and confidently report on containers
    # that were never contending for ${VOLUME} at all.
    #
    # This narrows the race, it does not close it: another invocation's
    # `docker run` can still start in the gap between this host's `docker ps`
    # sample and the `docker run` two lines below it. That gap is one ssh
    # round trip's worth of remote-shell work, not the whole script's setup
    # time — which is what made the old top-of-script, once-per-invocation
    # sample TOCTOU against arm64gate.sh's own RUNS loop.
    # CACHE_FLAG/CACHE_VOL are two separate, space-free words rather than one
    # "-v name:/cache" string in a single variable: this remote command runs
    # under whatever shell the target account's login shell is, and a shell
    # that does not word-split unquoted expansions (zsh, without
    # SH_WORD_SPLIT) would pass a one-token "-v name:/cache" to docker,
    # which is not the two-token form docker's flag parser expects. Each of
    # these two variables holds a single word, so splitting is never needed:
    # an unquoted empty expansion vanishes from the command line and a
    # non-empty one is exactly one argv entry, in every POSIX-ish shell.
    code=$(git archive HEAD | ssh "${host}" "
      if [ \"${CACHE_MODE}\" = clean ]; then
        CACHE_FLAG=''
        CACHE_VOL=''
        CACHE_ENV=/tmp/gc
      else
        PEERS=\$(docker ps -q --filter \"ancestor=${IMAGE}\" | wc -l | tr -d ' ')
        echo X64GATE_PEERS=\$PEERS
        if [ \"\$PEERS\" -gt 0 ]; then
          echo \"x64gate: \$PEERS other ${IMAGE} container(s) running on \$(hostname); not sharing ${VOLUME} -- using an isolated cache (cold, slower, trustworthy)\" >&2
          CACHE_FLAG=''
          CACHE_VOL=''
          CACHE_ENV=/tmp/gc
        else
          CACHE_FLAG='-v'
          CACHE_VOL='${VOLUME}:/cache'
          CACHE_ENV=/cache
        fi
      fi
      docker run --rm -i -e CACHE_ENV=\$CACHE_ENV \$CACHE_FLAG \$CACHE_VOL ${IMAGE} bash -c '
        mkdir -p /work && cd /work && tar x &&
        BIT_STAGE0_CACHE=\$CACHE_ENV/stage0 ./make ${STEP} > /tmp/o 2>&1
        e=\$?
        if [ \$e -eq 0 ]; then
          echo ===TAIL===
          tail -35 /tmp/o
        else
          echo ===FAILURE_FULL_LOG===
          cat /tmp/o
        fi
        echo X64LINUX_EXIT=\$e
      '
    " | tee /dev/stderr | sed -n 's/^X64LINUX_EXIT=//p')
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
