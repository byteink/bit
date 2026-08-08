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
# change touching any OTHER path (spec/, docs/, or anything else unlisted),
# or spanning MORE THAN ONE of those five areas, is ambiguous and always runs
# the full `./make test` — never a partial skip.
#
# TWO NARROW EXCEPTIONS (#2435), because registering a gate is mandatory in
# this repo and otherwise forces `full` on every single ticket that adds one:
#   - tests/bit/** joins whichever of the five areas also changed, instead of
#     forcing `full` on its own: its own mapped gate(s) run IN ADDITION to
#     that area's steps (#2510 — a five-area bucket used to silently replace
#     the file's own gate instead of adding to it). If tests/bit/** is the
#     ONLY thing that changed, the gates whose `Gate.argv` names each changed
#     file run — nothing more — or `full` if any changed file cannot be
#     mapped that way, whether or not one of the five areas also fired.
#   - tools/build/defs.bit and tools/build/gates.bit are the same case only
#     when the change is PURELY new `Step{}`/`Gate{}` registration: no edit to
#     an existing entry, no edit to any function body. See
#     `is_additive_registration` below for exactly what that means. Any other
#     tools/build/** file, or any non-additive change to these two, still
#     forces `full` — that code is the driver every step runs under.
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
has_testsbit=0
has_other=0
other_list=""
touched_list=""
testsbit_list=""

# Extracts the gate name(s) whose `Gate.argv` literally names path `$1`, by
# grepping the source rather than building anything — `runArgs("<path>")` is
# how every harness-running gate spells its target in tools/build/gates.bit.
# Prints nothing for a path that isn't named that way (a case-data file under
# tests/bit/checkercases/ or tests/bit/parsercases/, say, which a gate reaches
# through an env var, not argv) — the caller treats empty as ambiguous.
gates_for_file() {
  grep -F "runArgs(\"$1\")" tools/build/gates.bit 2>/dev/null |
    sed -n 's/.*Gate{name: "\([^"]*\)".*/\1/p' || true
}

# Space-joined, de-duplicated union of `gates_for_file` over every path in
# space-separated `$1`. Prints "" the moment ANY path fails to map to a gate —
# a partial guess is worse than `full`, so one unmapped file poisons the set.
testsbit_steps_for() {
  local files="$1" out="" g gg
  for f in ${files}; do
    g="$(gates_for_file "${f}")"
    if [ -z "${g}" ]; then
      printf ''
      return 0
    fi
    for gg in ${g}; do
      case " ${out} " in
        *" ${gg} "*) ;;
        *) out="${out:+${out} }${gg}" ;;
      esac
    done
  done
  printf '%s' "${out}"
}

# Trims a struct-literal-shaped diff hunk `$1` (one field's worth of added
# lines, `+` already stripped, comment/blank lines allowed anywhere) down to
# its first and last non-comment, non-blank line, and requires the first to
# open a NEW entry (starts with `$2`, e.g. `Step{name:`) and the last to close
# one (ends with `}` or `},`). A hunk of comments only (no entry at all) is
# harmless and passes. This is a shape check, not a parser: it cannot see a
# rogue line planted in the MIDDLE of a genuinely new multi-line entry, and it
# does not need to — the earlier all-additions check plus this shape are
# together the mechanical proxy #2435 asks for, and anything they cannot
# clear falls through to `full` via `is_additive_registration`'s caller.
hunk_is_safe() {
  local block="$1" prefix="$2"
  local first="" last="" t
  while IFS= read -r l; do
    t="$(printf '%s' "${l}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    [ -z "${t}" ] && continue
    case "${t}" in
      //*) continue ;;
    esac
    [ -z "${first}" ] && first="${t}"
    last="${t}"
  done <<EOF
${block}
EOF
  [ -z "${first}" ] && return 0
  case "${first}" in
    "${prefix}"*) ;;
    *) return 1 ;;
  esac
  case "${last}" in
    *"},"|*"}") ;;
    *) return 1 ;;
  esac
  return 0
}

# True only if every change to `$1` (tools/build/defs.bit or
# tools/build/gates.bit), across the commit range AND the working tree —
# same three sources CHANGED itself was built from, since a file can carry
# changes in more than one of them at once — is a bare addition of whole new
# `Step{}`/`Gate{}` entries: zero removed lines, and every added block either
# is comment/blank-only or opens and closes exactly one (or more) new entry.
# Editing an existing entry always removes its old line first, so it is
# caught by the deletion check alone; inserting a statement into an existing
# function body without deleting anything is caught by the shape check,
# because that block does not open with `Step{name:`/`Gate{name:}`.
is_additive_registration() {
  local file="$1" diff prefix
  case "${file}" in
    tools/build/defs.bit) prefix="Step{name:" ;;
    tools/build/gates.bit) prefix="Gate{name:" ;;
    *) return 1 ;;
  esac
  diff="$(
    { git diff -U0 "${RANGE}" -- "${file}"
      git diff -U0 -- "${file}"
      git diff --cached -U0 -- "${file}"
    } 2>/dev/null
  )" || true
  [ -z "${diff}" ] && return 0

  local block="" saw_hunk=0
  while IFS= read -r line; do
    case "${line}" in
      "diff --git "*|"index "*|"--- "*|"+++ "*) continue ;;
      @@*)
        if [ "${saw_hunk}" -eq 1 ]; then
          hunk_is_safe "${block}" "${prefix}" || return 1
        fi
        block=""
        saw_hunk=1
        ;;
      -*) return 1 ;;
      +*) block="${block}${line#+}"$'\n' ;;
      *) continue ;;
    esac
  done <<EOF
${diff}
EOF
  if [ "${saw_hunk}" -eq 1 ]; then
    hunk_is_safe "${block}" "${prefix}" || return 1
  fi
  return 0
}

while IFS= read -r f; do
  case "${f}" in
    compiler/*) has_selfhost=1 ;;
    runtime/*) has_runtime=1 ;;
    tests/cases/*) has_testcases=1 ;;
    examples/*) has_examples=1 ;;
    stdlib/*) has_stdlib=1 ;;
    tests/bit/*)
      has_testsbit=1
      if [ -n "${testsbit_list}" ]; then
        testsbit_list="${testsbit_list} ${f}"
      else
        testsbit_list="${f}"
      fi
      ;;
    tools/build/defs.bit|tools/build/gates.bit)
      if is_additive_registration "${f}"; then
        :
      else
        has_other=1
        if [ -n "${other_list}" ]; then
          other_list="${other_list}, ${f}"
        else
          other_list="${f}"
        fi
      fi
      ;;
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

# Computed ONCE, ahead of bucket selection, regardless of whether one of the
# five areas also fired (#2510). Two consequences fall out of computing it
# here rather than only inside the old `has_testsbit` elif branch:
#   - an UNMAPPED tests/bit/** file must force `full` even when it rides
#     alongside a bucket, exactly like it already did when tests/bit/** was
#     the only change — so `testsbit_unmapped` is checked ahead of every
#     concrete bucket below, not after all five have had a chance to win.
#   - a MAPPED file's gate(s) are available to be unioned into whichever
#     bucket is chosen below, instead of only ever being reachable via the
#     dedicated `testsbit` bucket that a five-area change never reaches.
testsbit_steps=""
testsbit_unmapped=0
if [ "${has_testsbit}" -eq 1 ]; then
  testsbit_steps="$(testsbit_steps_for "${testsbit_list}")"
  [ -z "${testsbit_steps}" ] && testsbit_unmapped=1
fi

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
elif [ "${testsbit_unmapped}" -eq 1 ]; then
  BUCKET="full"
  REASON="tests/bit/** changed but at least one file could not be mapped to a gate by name — falling through to full"
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
elif [ "${has_stdlib}" -eq 1 ]; then
  BUCKET="stdlib"
  REASON="only stdlib/** changed"
elif [ "${has_testsbit}" -eq 1 ]; then
  BUCKET="testsbit"
  REASON="only tests/bit/** changed (gate(s): ${testsbit_steps})"
else
  # Nothing in the five buckets or tests/bit/** changed, has_other is 0, and
  # CHANGED is non-empty — the only way here is a purely-additive
  # tools/build/defs.bit/gates.bit registration with no accompanying harness
  # or source change. Nothing to scope narrowly against, so full.
  BUCKET="full"
  REASON="only additive tools/build/** registration changed; nothing left to scope against"
fi

# BUILD_STEPS is always a non-empty literal array, assigned per bucket below —
# never built by splitting a variable, so "${BUILD_STEPS[@]}" is safe to expand
# even on this repo's bash (3.2, where an EMPTY array under `set -u` errors).
# THE DIFFERENTIAL SCRIPTS EACH BUCKET RUNS, as two space-separated lists (no
# path here contains a space). `$1` is the bucket; the caller reads BUCKET_PRE
# and BUCKET_POST.
#
# A FUNCTION rather than the three scalar slots this replaced, because `full`
# has to name MORE scripts than any single bucket and three slots could not hold
# them (#2194). It also makes every bucket's set readable WITHOUT selecting it,
# which is what lets the superset check below exist at all.
bucket_scripts() {
  BUCKET_PRE=""
  BUCKET_POST=""
  case "$1" in
    selfhost)
      BUCKET_PRE="scripts/selfhost-diffcheck.sh scripts/selfhost-fixpoint.sh"
      # #1857 was a COMPILER bug (`parseFloat` had no hex-float branch) whose
      # only visible damage was in runtime codegen, and no differential walked
      # `runtime/`. A compiler/** change must be diffed against it (#1859).
      BUCKET_POST="scripts/selfhost-diffruntime.sh"
      ;;
    runtime)
      BUCKET_POST="scripts/selfhost-diffruntime.sh"
      ;;
    examples)
      BUCKET_POST="scripts/selfhost-diffexamples.sh"
      ;;
    full)
      # THE UNION OF EVERY BUCKET ABOVE, and it must stay that way — enforced
      # below, not merely intended.
      BUCKET_PRE="scripts/selfhost-diffcheck.sh scripts/selfhost-fixpoint.sh"
      BUCKET_POST="scripts/selfhost-diffruntime.sh scripts/selfhost-diffexamples.sh"
      ;;
  esac
}

case "${BUCKET}" in
  full)
    BUILD_STEPS=(test)
    ;;
  selfhost)
    BUILD_STEPS=(test-imports-bit)
    ;;
  runtime)
    # Every name in this bucket was once stale: four of the six named steps did
    # not exist, so a runtime/** change died on `no step named` instead of
    # testing anything. The check after this case block now catches that class
    # before a single step runs — a bucket naming a nonexistent step is a
    # bucket that silently tests less than it claims.
    BUILD_STEPS=(test-stress-exclusive test-stress-batch test-rootpins test-rootabi test-stwwiring test-abimembers test-pollfree)
    ;;
  testcases)
    BUILD_STEPS=(test-golden)
    ;;
  examples)
    BUILD_STEPS=(test-examples)
    ;;
  stdlib)
    BUILD_STEPS=(test-imports-bit test-stdlib-docs)
    ;;
  testsbit)
    # Populated from `testsbit_steps`, which the bucket-selection above
    # already guaranteed is non-empty before choosing this bucket — so this
    # never assigns the empty array the header comment above warns about.
    BUILD_STEPS=()
    for s in ${testsbit_steps}; do
      BUILD_STEPS+=("${s}")
    done
    ;;
esac

# tests/bit/** riding alongside one of the five concrete areas contributes
# its OWN mapped gate(s) too (#2510) — the case above only reflects the AREA
# that also changed, so without this union a changed harness's gate silently
# never ran even though `has_testsbit` was 1 and it mapped cleanly. `full`
# already runs everything and `testsbit` already built its array from
# `testsbit_steps` directly above, so only the five concrete-area buckets
# need the union; `testsbit_unmapped` was already handled by forcing `full`
# before any of them could be chosen, so `testsbit_steps` here is never empty
# when `has_testsbit` is 1.
case "${BUCKET}" in
  full | testsbit) ;;
  *)
    if [ "${has_testsbit}" -eq 1 ]; then
      for s in ${testsbit_steps}; do
        case " ${BUILD_STEPS[*]} " in
          *" ${s} "*) ;;
          *) BUILD_STEPS+=("${s}") ;;
        esac
      done
      REASON="${REASON}; tests/bit/** also changed — added gate(s): ${testsbit_steps}"
    fi
    ;;
esac

# `full` REPLACES a bucket whenever the change spans more than one or touches
# anything outside the five, and this file sells that as the safe direction:
# "cannot confidently scope runs the full suite instead", "never a partial skip".
# It was neither. `full` ran `./make test` and nothing else, while `selfhost`
# ran three differential scripts `./make test` does not contain — so adding one
# unrelated file to a compiler/** change made the gate STRICTLY WEAKER, behind a
# green GATE_RESULT=PASS. Measured on #2084, whose change set was two
# compiler/** files plus tests/bit/golden.bit (#2194).
#
# So the invariant is CHECKED rather than trusted, in the same spirit as the
# stale-step-name check below: adding a script to any bucket without adding it
# to `full` fails here, before a single step runs. Existence is checked too —
# a renamed script is the #1593 class of silent hole.
bucket_scripts full
FULL_SCRIPTS=" ${BUCKET_PRE} ${BUCKET_POST} "
for b in full selfhost runtime testcases examples stdlib testsbit; do
  bucket_scripts "${b}"
  for s in ${BUCKET_PRE} ${BUCKET_POST}; do
    [ -f "${s}" ] || {
      echo "gate: STALE: bucket '${b}' names script '${s}', which does not exist." >&2
      exit 2
    }
    case "${FULL_SCRIPTS}" in
      *" ${s} "*) ;;
      *)
        echo "gate: BROKEN: bucket '${b}' runs '${s}' but the 'full' fallback does not." >&2
        echo "gate: 'full' replaces every bucket, so it must run at least what they do (#2194)." >&2
        exit 2
        ;;
    esac
  done
done

bucket_scripts "${BUCKET}"
PRE_SCRIPTS="${BUCKET_PRE}"
POST_SCRIPTS="${BUCKET_POST}"

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
for s in ${PRE_SCRIPTS}; do echo "  bash ${s}"; done
case "${TARGET}" in
  local) echo "  ./make ${BUILD_STEPS[*]}" ;;
  x64) echo "  STEP=\"${BUILD_STEPS[*]}\" scripts/x64gate.sh   (remote, real x86_64 hardware)" ;;
  arm64) echo "  ARM64GATE_STEP=\"${BUILD_STEPS[*]}\" scripts/arm64gate.sh   (remote, native aarch64-linux)" ;;
esac
for s in ${POST_SCRIPTS}; do echo "  bash ${s}"; done
if [ "${TARGET}" != "local" ]; then
  if [ -n "${PRE_SCRIPTS}${POST_SCRIPTS}" ]; then
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

for s in ${PRE_SCRIPTS}; do run_step bash "${s}"; done

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

for s in ${POST_SCRIPTS}; do run_step bash "${s}"; done

if [ "${OVERALL_RC}" -eq 0 ]; then
  echo "GATE_RESULT=PASS"
else
  echo "GATE_RESULT=FAIL"
fi
exit "${OVERALL_RC}"
