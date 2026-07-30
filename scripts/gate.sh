#!/usr/bin/env bash
# scripts/gate.sh — diff-scoped test gate (#1795).
#
# `./make test` runs all 28 harnesses (~270-450s). Most changes only touch
# one area of the tree, so most of that time is wasted proving things that
# could not have broken. This script looks at what actually changed and runs
# only the steps that area needs — falling back to the full suite whenever
# the change is ambiguous. It never silently skips a test: any change it
# cannot confidently scope runs the full suite instead.
#
# Usage:
#   scripts/gate.sh                    # scope to `main...HEAD` PLUS the working tree
#   RANGE=HEAD~1..HEAD scripts/gate.sh # use a different range (the working tree is
#                                      # still included on top of it)
#   scripts/gate.sh --full             # always run the full `./make test`
#   scripts/gate.sh --x64              # route the computed build steps through
#                                      # scripts/x64gate.sh (real x86_64 hardware)
#   scripts/gate.sh --arm64            # route the computed build steps through
#                                      # scripts/arm64gate.sh (native aarch64-linux)
#
# BUCKETS: a change confined to exactly one of compiler/, runtime/,
# tests/cases/, examples/, stdlib/ runs only that area's minimal steps. A
# change touching any OTHER path (tools/build/, spec/, docs/, or
# anything else unlisted), or spanning MORE THAN ONE of those five areas, is
# ambiguous and always runs the full `./make test` — never a partial skip.
#
# selfhost and examples pull in a non-`./make` diff script
# (selfhost-diffcheck.sh/selfhost-fixpoint.sh, selfhost-diffexamples.sh).
# Under --x64/--arm64 only the `./make` portion runs remotely; those diff
# scripts always run locally, because they need both compilers already built
# on this machine, not merely the remote target's build steps.
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

# THE WORKING TREE IS ALWAYS INCLUDED, on top of the range (#1892). This used to
# be `git diff --name-only "${RANGE}"` alone, which is commit-to-commit only and
# never sees the working tree or the index — and `main...HEAD` is empty by
# definition while HEAD *is* main. So the default invocation on main, with
# `compiler/**` modified and sitting right there, printed "nothing to test" and
# exited 0. A caller checking `$?` reads that as a pass on an unverified change,
# which is the same defect as a differential that prints a count and cannot fail.
#
# `ls-files --others` matters as much as the diffs: a brand new untracked
# tests/cases/*.bit is exactly the change that must select a bucket, and no form
# of `git diff` reports one.
CHANGED="$(
  {
    git diff --name-only "${RANGE}"
    git diff --name-only                        # unstaged
    git diff --cached --name-only                # staged
    git ls-files --others --exclude-standard     # new, untracked
  } | sed '/^$/d' | sort -u
)"

# --full always forces the full suite, even over an empty diff: it is an
# explicit request, not something the diff-scoping should second-guess.
if [ -z "${CHANGED}" ] && [ "${FULL}" -eq 0 ]; then
  # Empty set on a DIRTY tree is a contradiction in this script's own logic, not
  # a clean bill of health. Refuse rather than report success.
  if [ -n "$(git status --porcelain)" ]; then
    echo "gate: tree is dirty but no files were resolved from range '${RANGE}'" >&2
    echo "gate: refusing to report success — this is a bug in gate.sh, not a pass" >&2
    git status --short >&2
    exit 2
  fi
  echo "gate: no changed files in range '${RANGE}' and a clean tree — nothing to test"
  exit 0
fi

echo "gate: changed files (range '${RANGE}' + working tree):"
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

# BUILD_STEPS is always a non-empty literal array, assigned per bucket below —
# never built by splitting a variable, so "${BUILD_STEPS[@]}" is safe to expand
# even on this repo's bash (3.2, where an EMPTY array under `set -u` errors).
PRE1=""
PRE2=""
POST1=""
case "${BUCKET}" in
  full)
    BUILD_STEPS=(test)
    ;;
  selfhost)
    BUILD_STEPS=(test-imports-bit)
    PRE1="scripts/selfhost-diffcheck.sh"
    PRE2="scripts/selfhost-fixpoint.sh"
    # #1857 was a COMPILER bug (`parseFloat` had no hex-float branch) whose only
    # visible damage was in runtime codegen, and no differential walked
    # `runtime/`. A compiler/** change must be diffed against it (#1859).
    POST1="scripts/selfhost-diffruntime.sh"
    ;;
  runtime)
    # Every name in this bucket was once stale: four of the six named steps did
    # not exist, so a runtime/** change died on `no step named` instead of
    # testing anything. The check after this case block now catches that class
    # before a single step runs — a bucket naming a nonexistent step is a
    # bucket that silently tests less than it claims.
    BUILD_STEPS=(test-stress test-rootpins test-rootabi test-stwwiring test-abimembers test-pollfree)
    POST1="scripts/selfhost-diffruntime.sh"
    ;;
  testcases)
    BUILD_STEPS=(test-golden)
    ;;
  examples)
    BUILD_STEPS=(test-examples)
    POST1="scripts/selfhost-diffexamples.sh"
    ;;
  stdlib)
    BUILD_STEPS=(test-imports-bit test-stdlib-docs)
    ;;
esac

# A step name that no longer exists is a STALE GATE, and it must say so. Renaming
# a harness silently invalidated a whole bucket here twice — #1593 found four dead
# names in `runtime`, and #1873 found `test-imports` in `selfhost` and `stdlib`,
# which this check is what caught. The raw `unknown step` the driver would print
# does not point at this file, so nobody connects the two.
#
# The oracle is `./make --list`, and it is NOT OPTIONAL. It used to be guarded
# by a `command -v` probe for a tool the build no longer needs, so on any host
# without that tool the check skipped SILENTLY rather than failing. An
# unreadable list now fails here rather than flagging every name as stale, since
# "the oracle is missing" and "the name is wrong" need different fixes.
STEP_LIST="$(./make --list 2>/dev/null)" || STEP_LIST=""
if [ -z "${STEP_LIST}" ]; then
  echo "gate: cannot read the step list — './make --list' produced nothing." >&2
  echo "gate: the bucket step names cannot be validated, so nothing is run." >&2
  exit 2
fi
for s in "${BUILD_STEPS[@]}"; do
  [ "${s}" = "test" ] && continue
  printf '%s\n' "${STEP_LIST}" | grep -q "^${s} " || {
    echo "gate: STALE: bucket '${BUCKET}' names build step '${s}', which does not exist." >&2
    echo "gate: fix scripts/gate.sh — a renamed harness leaves this list behind." >&2
    exit 2
  }
done

echo "gate: bucket: ${BUCKET} (${REASON})"
echo "gate: plan:"
if [ -n "${PRE1}" ]; then echo "  bash ${PRE1}"; fi
if [ -n "${PRE2}" ]; then echo "  bash ${PRE2}"; fi
case "${TARGET}" in
  local) echo "  ./make ${BUILD_STEPS[*]}" ;;
  x64) echo "  STEP=\"${BUILD_STEPS[*]}\" scripts/x64gate.sh   (remote, real x86_64 hardware)" ;;
  arm64) echo "  ARM64GATE_STEP=\"${BUILD_STEPS[*]}\" scripts/arm64gate.sh   (remote, native aarch64-linux)" ;;
esac
if [ -n "${POST1}" ]; then echo "  bash ${POST1}"; fi
if [ "${TARGET}" != "local" ]; then
  if [ -n "${PRE1}" ] || [ -n "${POST1}" ]; then
    echo "gate: note: the compiler/examples diff script(s) above run LOCALLY even under --${TARGET} — they need both compilers already built on this machine, not just the remote build steps."
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
    run_step ./make "${BUILD_STEPS[@]}"
    ;;
  x64)
    run_step env STEP="${BUILD_STEPS[*]}" bash scripts/x64gate.sh
    ;;
  arm64)
    run_step env ARM64GATE_STEP="${BUILD_STEPS[*]}" bash scripts/arm64gate.sh
    ;;
esac

if [ -n "${POST1}" ]; then run_step bash "${POST1}"; fi

if [ "${OVERALL_RC}" -eq 0 ]; then
  echo "GATE_RESULT=PASS"
else
  echo "GATE_RESULT=FAIL"
fi
exit "${OVERALL_RC}"
