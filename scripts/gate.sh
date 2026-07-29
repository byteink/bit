#!/usr/bin/env bash
# scripts/gate.sh — diff-scoped test gate (#1795).
#
# `zig build test` runs all 28 harnesses (~270-450s). Most changes only touch
# one area of the tree, so most of that time is wasted proving things that
# could not have broken. This script looks at what actually changed and runs
# only the steps that area needs — falling back to the full suite whenever
# the change is ambiguous. It never silently skips a test: any change it
# cannot confidently scope runs the full suite instead.
#
# Usage:
#   scripts/gate.sh                    # scope to `git diff --name-only main...HEAD`
#   RANGE=HEAD~1..HEAD scripts/gate.sh # scope to a different range
#   scripts/gate.sh --full             # always run the full `zig build test`
#   scripts/gate.sh --x64              # route the computed zig steps through
#                                      # scripts/x64gate.sh (real x86_64 hardware)
#   scripts/gate.sh --arm64            # route the computed zig steps through
#                                      # scripts/arm64gate.sh (native aarch64-linux)
#
# BUCKETS: a change confined to exactly one of compiler/, runtime/,
# tests/cases/, examples/, stdlib/ runs only that area's minimal steps. A
# change touching any OTHER path (build.zig, seed/, spec/, .github/, or
# anything else unlisted), or spanning MORE THAN ONE of those five areas, is
# ambiguous and always runs the full `zig build test` — never a partial skip.
#
# selfhost and examples pull in a non-`zig build` diff script
# (selfhost-diffcheck.sh/selfhost-fixpoint.sh, selfhost-diffexamples.sh).
# Under --x64/--arm64 only the `zig build` portion runs remotely; those diff
# scripts always run locally, because they need both compilers already built
# on this machine, not merely the remote target's zig steps.
#
# KNOWN LIMITATION (#1772): scripts/x64gate.sh currently hardcodes
# STEP="test" and ignores an exported STEP override the way
# scripts/arm64gate.sh already honors ARM64GATE_STEP. This script exports
# STEP correctly on its end; until #1772 lands, --x64 has no narrowing effect
# remotely and silently runs the full remote suite regardless of the
# computed bucket. --arm64 narrows correctly today.
set -euo pipefail

cd "$(dirname "$0")/.."

FULL=0
TARGET=local
for arg in "$@"; do
  case "$arg" in
    --full) FULL=1 ;;
    --x64) TARGET=x64 ;;
    --arm64) TARGET=arm64 ;;
    *)
      echo "gate: unknown flag '${arg}' (expected --full, --x64, or --arm64)" >&2
      exit 2
      ;;
  esac
done

RANGE="${RANGE:-main...HEAD}"
CHANGED="$(git diff --name-only "${RANGE}")"

# --full always forces the full suite, even over an empty diff: it is an
# explicit request, not something the diff-scoping should second-guess.
if [ -z "${CHANGED}" ] && [ "${FULL}" -eq 0 ]; then
  echo "gate: no changed files in range '${RANGE}' — nothing to test"
  exit 0
fi

echo "gate: changed files (range '${RANGE}'):"
if [ -n "${CHANGED}" ]; then
  printf '%s\n' "${CHANGED}" | sed 's/^/  /'
else
  echo "  (none)"
fi

has_selfhost=0
has_runtime=0
has_testcases=0
has_examples=0
has_stdlib=0
has_other=0
other_list=""
touched_list=""

while IFS= read -r f; do
  case "${f}" in
    compiler/*) has_selfhost=1 ;;
    runtime/*) has_runtime=1 ;;
    tests/cases/*) has_testcases=1 ;;
    examples/*) has_examples=1 ;;
    stdlib/*) has_stdlib=1 ;;
    *)
      has_other=1
      if [ -n "${other_list}" ]; then
        other_list="${other_list}, ${f}"
      else
        other_list="${f}"
      fi
      ;;
  esac
done <<EOF
${CHANGED}
EOF

if [ "${has_selfhost}" -eq 1 ]; then touched_list="selfhost"; fi
if [ "${has_runtime}" -eq 1 ]; then
  if [ -n "${touched_list}" ]; then touched_list="${touched_list}, runtime"; else touched_list="runtime"; fi
fi
if [ "${has_testcases}" -eq 1 ]; then
  if [ -n "${touched_list}" ]; then touched_list="${touched_list}, tests/cases"; else touched_list="tests/cases"; fi
fi
if [ "${has_examples}" -eq 1 ]; then
  if [ -n "${touched_list}" ]; then touched_list="${touched_list}, examples"; else touched_list="examples"; fi
fi
if [ "${has_stdlib}" -eq 1 ]; then
  if [ -n "${touched_list}" ]; then touched_list="${touched_list}, stdlib"; else touched_list="stdlib"; fi
fi

bucket_count=$((has_selfhost + has_runtime + has_testcases + has_examples + has_stdlib))

BUCKET=""
REASON=""
if [ "${FULL}" -eq 1 ]; then
  BUCKET="full"
  REASON="--full forced the full suite"
elif [ "${has_other}" -eq 1 ]; then
  BUCKET="full"
  REASON="touches path(s) outside the five scoped buckets: ${other_list}"
elif [ "${bucket_count}" -gt 1 ]; then
  BUCKET="full"
  REASON="spans more than one bucket: ${touched_list}"
elif [ "${has_selfhost}" -eq 1 ]; then
  BUCKET="selfhost"
  REASON="only compiler/** changed"
elif [ "${has_runtime}" -eq 1 ]; then
  BUCKET="runtime"
  REASON="only runtime/** changed"
elif [ "${has_testcases}" -eq 1 ]; then
  BUCKET="testcases"
  REASON="only tests/cases/** changed"
elif [ "${has_examples}" -eq 1 ]; then
  BUCKET="examples"
  REASON="only examples/** changed"
else
  BUCKET="stdlib"
  REASON="only stdlib/** changed"
fi

# ZIG_STEPS is always a non-empty literal array, assigned per bucket below —
# never built by splitting a variable, so "${ZIG_STEPS[@]}" is safe to expand
# even on this repo's bash (3.2, where an EMPTY array under `set -u` errors).
PRE1=""
PRE2=""
POST1=""
case "${BUCKET}" in
  full)
    ZIG_STEPS=(test)
    ;;
  selfhost)
    ZIG_STEPS=(test-imports)
    PRE1="scripts/selfhost-diffcheck.sh"
    PRE2="scripts/selfhost-fixpoint.sh"
    # #1857 was a COMPILER bug (`parseFloat` had no hex-float branch) whose only
    # visible damage was in runtime codegen, and no differential walked
    # `runtime/`. A compiler/** change must be diffed against it (#1859).
    POST1="scripts/selfhost-diffruntime.sh"
    ;;
  runtime)
    # Every name here was stale (#1593). `test-gcdiff` was deleted with the Zig
    # collector in #1854, and `rootpins`/`rootabi`/`stwwiring` gained a `test-`
    # prefix when they moved from tests/*.zig to tests/bit/*.bit in #1591 — so a
    # runtime/** change ran FOUR nonexistent steps and died on `no step named`.
    # The check after this case block now catches that class before anything runs.
    ZIG_STEPS=(test-stress test-rootpins test-rootabi test-stwwiring test-abimembers test-pollfree)
    POST1="scripts/selfhost-diffruntime.sh"
    ;;
  testcases)
    ZIG_STEPS=(test-golden)
    ;;
  examples)
    ZIG_STEPS=(test-examples)
    POST1="scripts/selfhost-diffexamples.sh"
    ;;
  stdlib)
    ZIG_STEPS=(test-imports test-stdlib-docs)
    ;;
esac

# A step name that no longer exists is a STALE GATE, and it must say so. Renaming
# a harness silently invalidated a whole bucket here once (#1593 found four dead
# names in `runtime`); the raw `error: no step named rootpins` that produced does
# not point at this file, so nobody connected the two. Checked before any work is
# done, and `test` is the umbrella step which `--help` does not list.
if command -v zig >/dev/null 2>&1; then
  STEP_LIST="$(zig build --help 2>/dev/null || true)"
  for s in "${ZIG_STEPS[@]}"; do
    [ "${s}" = "test" ] && continue
    printf '%s\n' "${STEP_LIST}" | grep -q "^  ${s} " || {
      echo "gate: STALE: bucket '${BUCKET}' names build step '${s}', which does not exist." >&2
      echo "gate: fix scripts/gate.sh — a renamed harness leaves this list behind." >&2
      exit 2
    }
  done
fi

echo "gate: bucket: ${BUCKET} (${REASON})"
echo "gate: plan:"
if [ -n "${PRE1}" ]; then echo "  bash ${PRE1}"; fi
if [ -n "${PRE2}" ]; then echo "  bash ${PRE2}"; fi
case "${TARGET}" in
  local) echo "  zig build ${ZIG_STEPS[*]}" ;;
  x64) echo "  STEP=\"${ZIG_STEPS[*]}\" scripts/x64gate.sh   (remote, real x86_64 hardware)" ;;
  arm64) echo "  ARM64GATE_STEP=\"${ZIG_STEPS[*]}\" scripts/arm64gate.sh   (remote, native aarch64-linux)" ;;
esac
if [ -n "${POST1}" ]; then echo "  bash ${POST1}"; fi
if [ "${TARGET}" != "local" ]; then
  if [ -n "${PRE1}" ] || [ -n "${POST1}" ]; then
    echo "gate: note: the compiler/examples diff script(s) above run LOCALLY even under --${TARGET} — they need both compilers already built on this machine, not just the remote zig steps."
  fi
fi

OVERALL_RC=0

run_step() {
  echo "gate: + $*"
  if "$@"; then
    return 0
  fi
  echo "gate: FAILED: $*" >&2
  OVERALL_RC=1
  return 0
}

if [ -n "${PRE1}" ]; then run_step bash "${PRE1}"; fi
if [ -n "${PRE2}" ]; then run_step bash "${PRE2}"; fi

case "${TARGET}" in
  local)
    run_step zig build "${ZIG_STEPS[@]}"
    ;;
  x64)
    run_step env STEP="${ZIG_STEPS[*]}" bash scripts/x64gate.sh
    ;;
  arm64)
    run_step env ARM64GATE_STEP="${ZIG_STEPS[*]}" bash scripts/arm64gate.sh
    ;;
esac

if [ -n "${POST1}" ]; then run_step bash "${POST1}"; fi

if [ "${OVERALL_RC}" -eq 0 ]; then
  echo "GATE_RESULT=PASS"
else
  echo "GATE_RESULT=FAIL"
fi
exit "${OVERALL_RC}"
