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

# The box-wide measurement lock, as shell text that runs ON THE REMOTE HOST.
# `x64gate.sh lock-lib` prints it; this script ships it inside every gate ssh
# session, and _tests_/bit/dockerlive/dockerlive.bit ships the same text for its
# remote mode, so both acquirers share ONE acquire/heartbeat/reclaim rule (#7604).
#
# /tmp/benchlock is a DIRECTORY (mkdir takes it) holding `owner` (token, who,
# start, host) and `hb`, a heartbeat the holder touches while it is alive. A lock
# whose `hb` is older than BL_STALE_MIN minutes is stale: the next acquirer
# removes the containers labelled with the owner's token, deletes the lock and
# says so on stderr. A lock with NO `owner` file (a bare `mkdir`) is never
# reclaimed: nothing says it is dead.
# bl_beat's loop exits with the shell that called it, so a SIGKILLed holder goes
# stale 5 minutes later (#7614).
# A holder only deletes the lock it owns (token match), so a reclaimed holder
# that wakes late cannot delete its successor's lock.
lock_lib() {
  cat <<'LIB'
BL=${BENCHLOCK_DIR:-/tmp/benchlock}
BL_STALE_MIN=${BL_STALE_MIN:-5}
BL_LABEL_KEY=bit.live.session
bl_field() { sed -n "s/^$1=//p" "$BL/owner" 2>/dev/null | head -n 1; }
bl_rm_labelled() {
  [ -n "$1" ] || return 0
  ids=$(docker ps -aq --filter "label=$BL_LABEL_KEY=$1" 2>/dev/null)
  [ -z "$ids" ] || docker rm -f $ids >/dev/null 2>&1
  return 0
}
bl_stale() {
  [ -f "$BL/owner" ] || return 1
  ref=$BL/hb
  [ -f "$ref" ] || ref=$BL/owner
  [ -n "$(find "$ref" -mmin +"$BL_STALE_MIN" 2>/dev/null)" ]
}
bl_reclaim() {
  bl_stale || return 0
  [ -z "$(find "$BL.reclaim" -maxdepth 0 -mmin +1 2>/dev/null)" ] || rmdir "$BL.reclaim" 2>/dev/null
  mkdir "$BL.reclaim" 2>/dev/null || return 0
  if bl_stale; then
    echo "benchlock: reclaiming stale $BL (no heartbeat for over ${BL_STALE_MIN}min): $(tr '\n' ' ' < "$BL/owner")" >&2
    bl_rm_labelled "$(bl_field token)"
    rm -rf "$BL"
  fi
  rmdir "$BL.reclaim"
  return 0
}
bl_try() {
  if mkdir "$BL" 2>/dev/null; then
    printf 'token=%s\nwho=%s\nstart=%s\nhost=%s\n' "$1" "$2" "$(date +%s)" "$(hostname)" > "$BL/owner"
    touch "$BL/hb"
    BL_TOKEN=$1
    return 0
  fi
  bl_reclaim
  return 1
}
bl_beat() {
  # The loop stops when the shell that took the lock is gone: a holder that is
  # SIGKILLed runs no trap, and an orphaned loop would keep `hb` fresh forever.
  ( p=$$; while sleep 30 && kill -0 "$p" 2>/dev/null; do touch "$BL/hb"; done ) </dev/null >/dev/null 2>&1 &
  BL_BEATPID=$!
}
bl_release() {
  [ -z "${BL_BEATPID:-}" ] || kill "$BL_BEATPID" 2>/dev/null
  [ -n "${BL_TOKEN:-}" ] || return 0
  bl_rm_labelled "$BL_TOKEN"
  [ "$(bl_field token)" != "$BL_TOKEN" ] || rm -rf "$BL"
  return 0
}
bl_hold() {
  trap bl_release EXIT
  trap 'exit 1' HUP INT TERM PIPE
  until bl_try "$1" "$2"; do sleep 5; done
  echo BENCHLOCK_HELD
  while read -r _; do touch "$BL/hb"; done
}
LIB
}
if [ "${1:-}" = "lock-lib" ]; then
  lock_lib
  exit 0
fi

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

# Environment does NOT cross an ssh plus `docker run` boundary on its own, so a
# knob set on the Mac is silently ignored inside the container unless it is
# named here (BIT_ERR_REG too, #6690: without it an x86-64 gate cannot run the
# error-word convention at all). `_tests_/bit/stress/stress.bit` documents
# BIT_STRESSGATE_ONLY and BIT_STRESSGATE_DIR as the way to narrow a stress run for debugging, and
# neither reached the gate before this: the filter read as accepted and the
# full corpus ran anyway, which looks exactly like the filter matching
# everything. Add a variable here to make it forwardable, and keep the quoting
# so an unset one expands to nothing rather than to an empty assignment.
GATE_ENV=""
for v in BIT_STRESSGATE_ONLY BIT_STRESSGATE_DIR BIT_ERR_REG; do
  eval "val=\${$v-}"
  [ -z "$val" ] || GATE_ENV="$GATE_ENV $v=$val"
done
if [ "${MODE}" = "fuzz" ]; then
  STEP="fuzz -- ${FUZZ_SECS:-60}"
  MODE="fast"
fi
VOLUME="bit-gate-cache-amd64"

# The pinned stage0's `runtime/**` has to travel WITH the tree (#4732). This
# gate ships `git archive HEAD`, so the container has no `.git`, and the
# runtime ABI arity check (`stage0RuntimeBaseline`, tools/build/abiarity.bit)
# could not `git archive <tag>` there: it skipped itself on every Linux gate
# run, leaving the check that caught 164 invisible symbols (#4189) running on
# the Mac alone. `gate_stream` appends a second archive of `<tag>:runtime/`,
# and BIT_ABI_BASELINE_DIR (below, on the container's `./make`) names where it
# lands. Under `bit-out/` because that is where the Mac's own extraction
# already lives, so no source walk in the suite can pick the snapshot up.
#
# The tag is read from the ARCHIVED tree's dist/stage0/SHA256SUMS exactly as
# `stage0Version` reads it: the first non-comment line naming a
# `bit-<version>-<triple>` asset wins. awk, not sed: BSD sed has no `\|`.
ABI_BASELINE_DIR="bit-out/make/abiarity-gate-baseline"
STAGE0_VERSION=$(git show HEAD:dist/stage0/SHA256SUMS | awk '
  /^[[:space:]]*#/ { next }
  found { next }
  { for (i = 1; i <= NF; i++)
      if ($i ~ /^bit-.+-(linux-aarch64|linux-x86_64|macos-aarch64)\.tar\.xz$/) {
        v = $i
        sub(/^bit-/, "", v)
        sub(/-(linux-aarch64|linux-x86_64|macos-aarch64)\.tar\.xz$/, "", v)
        print v
        found = 1
        next
      } }')
[ -n "${STAGE0_VERSION}" ] || {
  echo "x64gate: cannot read the pinned stage0 version from HEAD:dist/stage0/SHA256SUMS" >&2; exit 127; }
STAGE0_TAG="v${STAGE0_VERSION}"
git rev-parse --verify --quiet "${STAGE0_TAG}^{commit}" >/dev/null || {
  echo "x64gate: tag ${STAGE0_TAG} (the pinned stage0) is missing locally: \`git fetch --tags\`. Without it the container cannot run the runtime ABI arity check." >&2; exit 127; }
GATE_HEAD_SHA=$(git rev-parse HEAD)

# The two archives the container unpacks, in one stream. `tar xi` there, not
# `tar x`: GNU tar stops at the first archive's end-of-archive blocks unless
# told to read past them.
baseline_archive() { git archive --prefix="${ABI_BASELINE_DIR}/" "${STAGE0_TAG}" -- runtime; }
gate_stream() { git archive HEAD; baseline_archive; }

# Which real-x86_64 box runs the gate. No hostname is baked into the repo —
# machine names are the operator's, not the project's. Resolution order:
#   1. $X64GATE_HOST
#   2. scripts/.x64gate-host  (gitignored, one line: an ssh host alias) --
#                              PROBED with the same 8s ConnectTimeout budget
#                              x64host.sh's candidates use; an unreachable pin
#                              is skipped, not fatal, so a stale pin cannot
#                              send the gate to a dead host
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
  PIN_HOST=$(tr -d '[:space:]' < "$(dirname "$0")/.x64gate-host")
  if [ -n "${PIN_HOST}" ]; then
    # Same probe x64host.sh's _probe uses: </dev/null so ssh does not drain
    # the caller's stdin (#3899).
    if ssh -o ConnectTimeout=8 -o BatchMode=yes "${PIN_HOST}" true </dev/null >/dev/null 2>&1; then
      X64GATE_HOST="${PIN_HOST}"
    else
      echo "x64gate: scripts/.x64gate-host names ${PIN_HOST}, which did not answer ssh within 8s -- skipping the pin and falling through to scripts/x64host.sh" >&2
    fi
  fi
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
LIB_B64=$(lock_lib | base64 | tr -d '\n')
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
  # </dev/null: a liveness probe must not inherit the caller's stdin (#3899).
  ssh "${host}" "docker run --rm ${IMAGE} sh -c 'command -v git'" </dev/null >/dev/null 2>&1 || {
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
    # /tmp/benchlock is the box-wide measurement lock, a DIRECTORY: bl_try takes
    # it, bl_release deletes it (see lock_lib above). It is taken here rather than by callers so no run
    # can skip it (#5998 ran unlocked through #6001's measurement window).
    # X64GATE_LOCK_TRIES bounds the wait in 10 s tries; 360 is one hour.
    GATE_TOKEN="x64gate-$$-$(date +%s)"
    GATE_WHO="$(hostname):$$:$(date +%s)"
    code=$(gate_stream | ssh "${host}" "
      eval \"\$(echo ${LIB_B64} | base64 -d)\"
      n=0
      until bl_try ${GATE_TOKEN} ${GATE_WHO}; do
        n=\$((n + 1))
        if [ \$n -ge ${X64GATE_LOCK_TRIES:-360} ]; then
          echo \"x64gate: /tmp/benchlock on \$(hostname) still held after \$((n * 10))s: \$(ls -ld /tmp/benchlock 2>&1)\" >&2
          cat >/dev/null
          echo X64LINUX_EXIT=98
          exit 0
        fi
        sleep 10
      done
      trap bl_release EXIT
      trap 'exit 1' HUP INT TERM
      bl_beat
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
      docker run --rm -i --label bit.live.session=${GATE_TOKEN} -e CACHE_ENV=\$CACHE_ENV \$CACHE_FLAG \$CACHE_VOL ${IMAGE} bash -c '
        mkdir -p /work && cd /work && tar xi &&
        BIT_STAGE0_CACHE=\$CACHE_ENV/stage0 BIT_ABI_BASELINE_DIR=${ABI_BASELINE_DIR}/runtime BIT_GATE_HEAD_SHA=${GATE_HEAD_SHA} ${GATE_ENV} ./make ${STEP} > /tmp/o 2>&1
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
