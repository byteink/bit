#!/usr/bin/env bash
# Run `./make test` for aarch64-linux in Docker on this machine, over the
# committed tree (git archive HEAD).
#
# The image `bit-linux-gate:latest` is a NATIVE aarch64 Linux image, so on an
# Apple-Silicon host this is real ARM64 Linux execution — no qemu, no emulation
# artifacts to argue about. `./make test` inside it resolves host_target to
# aarch64-linux, so the whole suite exercises that backend.
#
#   arm64gate.sh          # fast: reuse a persistent build cache volume (only changed
#                         #       files recompile) — for iterative checks
#   arm64gate.sh clean    # clean-room: throwaway cache, full cold build — for a
#                         #       final sign-off where no stale artifact may hide
#   arm64gate.sh <mode> N # repeat N times — for chasing an intermittent, which a
#                         # single green run cannot rule out
#   arm64gate.sh selftest # prove the gate can fail: a no-op control run that MUST
#                         # be green, then a deliberately broken tree that MUST be
#                         # red. A gate nobody has seen fail is not a gate.
#   arm64gate.sh mutant [build|golden]
#                         # the breakage half alone — for when HEAD is already red
#                         # on this target and a control run cannot be green.
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
# IMAGE=<tag-or-id> overrides the image. Needed when #1497 makes `docker image inspect`
# deny a tag that `docker images` lists — pass the id instead of editing a copy.
#
# On success prints the log tail; on FAILURE prints the whole log, because the
# tail alone routinely cuts off the one line that names the failing test — a gate
# that cannot say what broke is not a gate. Always ends with `ARM64LINUX_EXIT=<code>`.
set -euo pipefail

MODE="${1:-fast}"
RUNS="${2:-1}"
# Overridable so #1497 (docker denying a tag that `docker images` lists) is not a hard
# block: point it at the same image by id. The uname -m check below still applies, and
# matters MORE with an id, which carries no descriptive name.
IMAGE="${IMAGE:-bit-linux-gate:latest}"
VOLUME="bit-gate-cache-arm64"
# Wall-clock ceiling for one suite run. A hang must read as a failure, never as a
# gate that sits forever looking busy.
# 3h: a COLD run on a machine already loaded by other agents was measured at
# >90min and still progressing, so a tighter ceiling kills good runs. The deadline
# exists to catch a hang, not to enforce a performance budget.
DEADLINE="${ARM64GATE_DEADLINE:-10800}"
# Which build step to gate on. Override to narrow a run to one step, or to
# `--help` for a green-path control that proves a zero exit really reports green.
STEP="${ARM64GATE_STEP:-test}"

command -v docker >/dev/null || { echo "arm64gate: docker not found" >&2; exit 127; }
docker image inspect "${IMAGE}" >/dev/null 2>&1 || {
  echo "arm64gate: image ${IMAGE} missing — build it: docker build -f docker/linux-gate.Dockerfile -t ${IMAGE} ." >&2; exit 127; }
[ "$(docker run --rm "${IMAGE}" uname -m)" = "aarch64" ] || {
  echo "arm64gate: ${IMAGE} is not native aarch64 — it would gate the wrong backend" >&2; exit 127; }
# The suite needs a `git` binary INSIDE the image: the package manager fetches
# dependencies by shelling out to it, so tests/imports/pmadd_e2e,
# tests/bit/pmimports.bit and compiler/pmclicheck.bit all fail without it — as
# `git: not found`, an empty failure, and a bare assertion panic respectively
# (#1818). Refusing here names the cause once instead of leaving three
# unrelated-looking harnesses red. macOS has git from the host, which is why a
# git-less image passed the local gate and only failed on Linux.
docker run --rm "${IMAGE}" sh -c 'command -v git' >/dev/null 2>&1 || {
  echo "arm64gate: ${IMAGE} has no git — rebuild it from docker/linux-gate.Dockerfile" >&2; exit 127; }

# "clean" always uses an ephemeral cache, so it never needs a peer check.
# "fast" shares a named volume across invocations and DOES need one — sampled
# below, freshly, inside run_suite() on every call (#3733).
if [ "${MODE}" = "clean" ]; then
  CACHE_MODE="clean"
else
  CACHE_MODE="fast"
fi

# Host load is shared too: a suite killed by memory/CPU pressure reads exactly
# like a real failure. Say so up front instead of letting someone misread it.
echo "ARM64GATE_LOAD=$(uptime | sed -n 's/.*load averages*: *//p' | awk '{print $1}')"

# Run the suite over the tar stream on stdin. Echoes the container log and prints
# ARM64LINUX_EXIT=<code>; returns that code as its own exit status.
run_suite() {
  local code name cache_args cache_env peers
  if [ "${CACHE_MODE}" = "clean" ]; then
    cache_args=""
    cache_env="/tmp/gc"
  else
    # Several agents share this machine. Two gate runs against one named cache
    # volume can read each other's artifacts, so a contended `fast` run is not
    # a sign-off. Sampled HERE, immediately before the `docker run` below,
    # rather than once at script startup: a single startup sample was reused
    # across every call this function makes — the whole RUNS loop and the
    # selftest/mutant control-then-mutant pair — so a peer that started after
    # that one sample was invisible for the rest of the invocation (#3733).
    # This narrows the window to the gap between this line and the `docker
    # run` a few lines down; it does not close it — a peer can still start in
    # that gap and go undetected.
    peers=$(docker ps -q --filter "ancestor=${IMAGE}" | wc -l | tr -d ' ')
    echo "ARM64GATE_PEERS=${peers}"
    if [ "${peers}" -gt 0 ]; then
      echo "arm64gate: ${peers} other ${IMAGE} container(s) running; not sharing ${VOLUME} — using an isolated cache (cold, slower, trustworthy)" >&2
      cache_args=""
      cache_env="/tmp/gc"
    else
      cache_args="-v ${VOLUME}:/cache"
      cache_env="/cache"
    fi
  fi
  # Name the container so it can be reaped. `docker run` does NOT die with its
  # driving shell: when this script is killed (harness timeout, Ctrl-C, the perl
  # alarm), an unnamed container keeps burning every core on a result nobody will
  # ever read. Observed exactly that on 2026-07-19.
  name="arm64gate-$$-${RANDOM}"
  trap 'docker rm -f "${name}" >/dev/null 2>&1 || true' EXIT INT TERM

  # Enforce the deadline by REMOVING THE CONTAINER, not by signalling the client.
  # `perl -e 'alarm N; exec docker run ...'` — the obvious portable idiom, and what
  # this script shipped with — is VACUOUS: the docker CLI is a Go program and Go's
  # runtime swallows SIGALRM, so the alarm never lands. Measured 2026-07-19:
  # `perl -e 'alarm 3; exec @ARGV' docker run --rm alpine sleep 25` ran the full
  # 25s and exited 0. That defect let a genuinely hung run burn 2h of CPU.
  # Its stdout MUST be closed: `code=$(...)` below waits for every writer of the
  # substitution pipe to exit, and a watchdog that inherits stdout is one — the
  # gate would then sit idle until the full deadline elapsed even after the suite
  # had finished, looking exactly like the hang it exists to catch.
  ( sleep "${DEADLINE}"; docker rm -f "${name}" >/dev/null 2>&1 ) >/dev/null 2>&1 &
  local watchdog=$!

  code=$(docker run --rm -i --name "${name}" ${cache_args} "${IMAGE}" bash -c '
      mkdir -p /work && cd /work && tar x &&
      BIT_STAGE0_CACHE='"${cache_env}"'/stage0 ./make '"${STEP}"' > /tmp/o 2>&1
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
  kill "${watchdog}" 2>/dev/null || true
  wait "${watchdog}" 2>/dev/null || true
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

# Emit a tar of HEAD with one deliberate breakage applied, in a throwaway copy —
# the repo itself is never touched. $1 selects what to break:
#   golden — corrupt a `.expected` file. The STRONG proof: it shows the gate sees
#            a real TEST failure, not merely a build error. Needs a full build.
#   build  — corrupt the build driver. The CHEAP proof: fails in seconds, so it
#            is usable even when the suite cannot run to completion on this
#            target. The victim is tools/build/main.bit; breaking it makes `./make`
#            fail to compile the driver before any step body runs.
mutant_stream() {
  local kind="${1:-build}" tmp victim
  tmp=$(mktemp -d)
  git archive HEAD | tar x -C "${tmp}"
  if [ "${kind}" = "golden" ]; then
    victim=$(ls "${tmp}"/tests/cases/*.expected 2>/dev/null | head -1)
    [ -n "${victim}" ] || { echo "arm64gate: no golden .expected to mutate" >&2; rm -rf "${tmp}"; exit 127; }
    printf 'arm64gate-deliberate-breakage\n' >> "${victim}"
  else
    victim="${tmp}/tools/build/main.bit"
    [ -f "${victim}" ] || { echo "arm64gate: tools/build/main.bit missing" >&2; rm -rf "${tmp}"; exit 127; }
    printf '\nthis is not valid bit — arm64gate deliberate breakage\n' >> "${victim}"
  fi
  echo "arm64gate: mutating ${victim#"${tmp}"/}" >&2
  # This is the ONLY tar in the repo built from the local filesystem; everything
  # else pipes `git archive HEAD`, whose tar comes from git objects and carries no
  # xattrs. That difference is the whole reason the two flags below are needed
  # here and nowhere else.
  #
  # Every file `git archive | tar x` writes on macOS gets a com.apple.provenance
  # xattr. --no-xattrs stops GNU tar in the container warning once per file
  # (~100KB of noise). COPYFILE_DISABLE=1 stops something worse: bsdtar cannot
  # hold an xattr natively in this format, so it emits each one as a separate
  # AppleDouble `._<name>` MEMBER. bsdtar re-merges those on read, which hides
  # them from any check run on this host — `tar c … | tar t | grep '\._'` finds
  # nothing — while GNU tar in the container materializes them as real files.
  # Measured against bit-linux-gate:latest: 2119 of them without this, 0 with it.
  #
  # Since #1871 the build driver discovers sources by globbing `*.bit`, and
  # `._core.bit` matches, so those blobs get COMPILED — thousands of
  # `unexpected byte 0x00`, a broken pipe, and no verdict at all, which is
  # `mutant`/`selftest` unable to prove this gate can fail (#1890).
  #
  # --exclude '._*' does NOT work and was measured: still 2119. The members are
  # synthesized at write time and never exist as paths for a filter to match.
  COPYFILE_DISABLE=1 tar c --no-xattrs -C "${tmp}" .
  rm -rf "${tmp}"
}

# Run the suite over a mutated tree and report ONLY on the gate's verdict.
#
# The status must come from the suite, not from the container's lifecycle (#1513).
# `mutant_stream | run_suite` conflated the two: run_suite returns 124 when the
# container was reaped by the deadline or died before printing a verdict, and
# "any non-zero means the gate went red" scored that as a successful mutation
# test — a run in which the mutant was never actually judged. Worse, a failure
# inside mutant_stream (`exit 127`) only killed the pipeline subshell, so a
# harness that could not even build the mutant also reported ok. The tar is
# therefore materialized first, where its exit status is the script's.
mutant_verdict() { # $1=kind -> 0 gate went red (good), 1 gate passed it, 2 no verdict
  local tar rc=0
  tar="$(mktemp)"
  # Not a pipeline: mutant_stream's own `exit 127` must be the script's status.
  mutant_stream "$1" > "${tar}"
  run_suite < "${tar}" || rc=$?
  rm -f "${tar}"
  [ "${rc}" -eq 0 ] && return 1
  [ "${rc}" -eq 124 ] && return 2
  return 0
}

# `mutant [build|golden]` — run ONLY the deliberate-breakage half. Use this when
# HEAD is already known-red on this target (as aarch64-linux is today), where a
# control run cannot be green and `selftest` would correctly refuse to conclude.
if [ "${MODE}" = "mutant" ]; then
  echo "===MUTANT (deliberate breakage, must be RED)==="
  mrc=0
  mutant_verdict "${2:-build}" || mrc=$?
  case "${mrc}" in
    0) echo "ARM64GATE_MUTANT=ok (gate went red on a broken tree)"; exit 0 ;;
    2) echo "ARM64GATE_MUTANT=inconclusive — no verdict (container died or deadline hit); the mutant was never judged" >&2 ;;
    *) echo "ARM64GATE_MUTANT=BROKEN — the gate passed a deliberately broken tree" >&2 ;;
  esac
  exit 1
fi

if [ "${MODE}" = "selftest" ]; then
  # 1. Control: the unmodified committed tree MUST pass. If this is red the
  #    selftest proves nothing, so stop rather than report a meaningless red.
  echo "===SELFTEST CONTROL (no-op, must be GREEN)==="
  if git archive HEAD | run_suite; then
    echo "SELFTEST_CONTROL=pass"
  else
    echo "SELFTEST_CONTROL=fail  — HEAD is already red; fix that before trusting a mutation result" >&2
    echo "ARM64GATE_SELFTEST=inconclusive  (use \`arm64gate.sh mutant\` to check the failure path alone)"
    exit 1
  fi

  echo "===SELFTEST MUTANT (deliberate breakage, must be RED)==="
  smrc=0
  mutant_verdict golden || smrc=$?
  case "${smrc}" in
    0) echo "ARM64GATE_SELFTEST=ok (control green, mutant red)"; exit 0 ;;
    2) echo "ARM64GATE_SELFTEST=inconclusive — the mutant run produced no verdict (container died or deadline hit)" >&2 ;;
    *) echo "ARM64GATE_SELFTEST=BROKEN — the gate passed a deliberately broken tree" >&2 ;;
  esac
  exit 1
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
