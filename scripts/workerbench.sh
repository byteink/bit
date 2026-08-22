#!/usr/bin/env bash
# scripts/workerbench.sh — idle CPU and spawn speedup at a given BIT_WORKERS (#2591).
#
# There was no single command that produced the two numbers epic #1911's
# BIT_WORKERS default flip is judged on. This runs two measurements against
# the built `bit-out/bin/bit` and prints them in a fixed, greppable format:
#
#   idle BIT_WORKERS=<n> cpu=<seconds>s      (once each for n = 1,2,4,8,18)
#   spawn BIT_WORKERS=<n> cpu_percent=<p>%   (once, for the BIT_WORKERS given
#                                              via the env var of that name,
#                                              default 4)
#
# Usage:
#   bash scripts/workerbench.sh                 # measurement B uses BIT_WORKERS=4
#   BIT_WORKERS=8 bash scripts/workerbench.sh    # measurement B uses BIT_WORKERS=8
#
# Measurement A (idle) always sweeps the fixed list 1,2,4,8,18 regardless of
# the env var — it is answering "what does the scheduler cost when nothing
# needs it", at every count worth knowing about, not just the one under test.
#
# Measurement B (spawn) starts four CPU-bound `spawn` tasks (trial-division
# prime counting, independent, no shared lock) and reports what fraction of
# a single core's worth of CPU time they used relative to how long they took
# — the parallelism signal.
#
# THIS SCRIPT REFUSES RATHER THAN MEASURING ON A BUSY BOX, before the run
# step, because both numbers above are worthless if something else is eating
# CPU. Three independent checks, any one refuses:
#   - a make-driver process running anywhere (a sibling build)   -> exits
#     non-zero and prints exactly "refusing: make-driver is running", per
#     this ticket's acceptance criterion.
#   - total system CPU utilization above a rough busy line -- builds are not
#     the only confound; a non-build process (seen in practice: syncthing)
#     can eat a full core just as invisibly to a make-driver-only check.
#   - macOS memory pressure critically low -- every real OOM incident on
#     this Mac read a HEALTHY load average minutes beforehand, so load is
#     not the signal for this hazard.
# Deliberately NOT load average anywhere in this script, for either purpose:
# macOS counts parked threads in it, and it has read 128 on a box that was
# not CPU-saturated at all.
#
# Also prints `head=<sha>` up front and re-checks HEAD after the run: a
# number with no commit attached goes stale silently, and one taken across a
# moving tree is unattributable to either commit.
#
# Exit codes: 0 measured successfully. 1 refused (busy box, HEAD moved
# mid-run, or a measured program itself failed).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BIT="$REPO_ROOT/bit-out/bin/bit"
SPAWN_WORKERS="${BIT_WORKERS:-4}"

# --- refuse on a busy box, before touching bit-out at all -------------------

check_quiet() {
  local hits
  hits="$(pgrep -fl make-driver 2>/dev/null || true)"
  if [ -n "$hits" ]; then
    echo "refusing: make-driver is running" >&2
    echo "$hits" >&2
    exit 1
  fi

  local ncpu total_pcpu busy_threshold
  ncpu="$(sysctl -n hw.ncpu)"
  total_pcpu="$(ps -Ao pcpu= | awk '{s+=$1} END{printf "%d", s+0}')"
  busy_threshold=$(( ncpu * 30 ))
  if [ "$total_pcpu" -gt "$busy_threshold" ]; then
    echo "refusing: cpu busy (total ${total_pcpu}%, threshold ${busy_threshold}% across ${ncpu} cores)" >&2
    ps -Ao pcpu=,comm= | sort -rn | head -5 >&2
    exit 1
  fi

  local free_pct
  free_pct="$(memory_pressure -Q 2>/dev/null | awk -F'[: %]+' '/free percentage/{print $(NF-1)}')"
  if [ -n "$free_pct" ] && [ "$free_pct" -lt 10 ]; then
    echo "refusing: memory pressure high (${free_pct}% free)" >&2
    exit 1
  fi
}

check_quiet

[ -x "$BIT" ] || {
  echo "workerbench: no compiler at ${BIT} -- run ./make selfhost first" >&2
  exit 1
}

HEAD_SHA="$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || echo unknown)"
echo "head=${HEAD_SHA}"

workdir="$(mktemp -d "${TMPDIR:-/tmp}/workerbench.XXXXXX")"
trap 'rm -rf "$workdir"' EXIT

# --- the two Bit programs, heredocs only, never written into the checkout ---

cat >"$workdir/idle.bit" <<'BITEOF'
// workerbench idle probe: no parallel work at all. Measures the scheduler's
// baseline cost at a given BIT_WORKERS with nothing for the extra workers
// to do.
import { sleep, Second } from "std/time"

fn main() {
  sleep(3 * Second)
}
BITEOF

cat >"$workdir/spawn.bit" <<'BITEOF'
// workerbench spawn probe: four CPU-bound tasks (trial-division prime
// counting), each writing its own results slot so no lock is needed and the
// workload stays purely CPU-bound rather than contended.
import { WaitGroup, newWaitGroup } from "std/sync"

const tasks = 4
const primeCeiling = 50000

fn isPrime(n: int): bool {
  if (n < 2) {
    return false
  }
  let d = 2
  while (d * d <= n) {
    if (n % d == 0) {
      return false
    }
    d = d + 1
  }
  return true
}

fn burn(id: int, results: []i64, wg: WaitGroup) {
  let n = 2
  let count = 0
  while (n < primeCeiling) {
    if (isPrime(n)) {
      count = count + 1
    }
    n = n + 1
  }
  results[id] = count
  wg.done()
}

fn main() {
  let results = []i64(tasks)
  let wg = newWaitGroup()
  wg.add(tasks)
  let i = 0
  while (i < tasks) {
    spawn burn(i, results, wg)
    i = i + 1
  }
  wg.wait()

  let total = 0
  i = 0
  while (i < tasks) {
    total = total + results[i]
    i = i + 1
  }
  print("primes: ${total}\n")
}
BITEOF

# --- run one program under `/usr/bin/time -l`, parse its report -------------
# Sets TIME_REAL/TIME_USER/TIME_SYS (seconds, as printed) on success; exits
# non-zero itself if the measured program failed, since a number derived from
# a failed run is not a number.

run_timed() {
  local workers=$1 prog=$2 timefile
  timefile="$(mktemp "$workdir/time.XXXXXX")"
  if ! BIT_WORKERS="$workers" /usr/bin/time -l "$BIT" run "$prog" >/dev/null 2>"$timefile"; then
    echo "workerbench: program failed (BIT_WORKERS=${workers} ${prog})" >&2
    cat "$timefile" >&2
    exit 1
  fi
  TIME_REAL="$(awk '/ real /{print $1; exit}' "$timefile")"
  TIME_USER="$(awk '/ real /{print $3; exit}' "$timefile")"
  TIME_SYS="$(awk '/ real /{print $5; exit}' "$timefile")"
  rm -f "$timefile"
}

# --- measurement A: idle cost at each of the fixed worker counts ------------

for n in 1 2 4 8 18; do
  run_timed "$n" "$workdir/idle.bit"
  cpu="$(awk -v u="$TIME_USER" -v s="$TIME_SYS" 'BEGIN{printf "%.2f", u+s}')"
  echo "idle BIT_WORKERS=${n} cpu=${cpu}s"
done

# --- measurement B: spawn parallelism at the given worker count ------------

run_timed "$SPAWN_WORKERS" "$workdir/spawn.bit"
pct="$(awk -v u="$TIME_USER" -v s="$TIME_SYS" -v r="$TIME_REAL" \
  'BEGIN{ if (r+0>0) printf "%.0f", (u+s)/r*100; else printf "0" }')"
echo "spawn BIT_WORKERS=${SPAWN_WORKERS} cpu_percent=${pct}%"

# --- pin: the tree must not have moved while these numbers were taken -------

END_SHA="$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || echo unknown)"
if [ "$END_SHA" != "$HEAD_SHA" ]; then
  echo "refusing: HEAD moved during the run (${HEAD_SHA} -> ${END_SHA}); these numbers are unattributable" >&2
  exit 1
fi
