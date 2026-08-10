#!/usr/bin/env bash
# scripts/gate.sh — diff-scoped test gate (#1795).
#
# `./make test` runs all 28 harnesses (~270-450s). Most changes only touch
# one area of the tree, so most of that time is wasted proving things that
# could not have broken. This script looks at what actually changed and runs
# only the steps that area needs — falling back to the `full` bucket whenever
# the change is ambiguous. It never silently skips a test: any change it
# cannot confidently scope resolves to `full`.
#
# `full` IS A VERDICT, NOT AN ACTION, UNLESS YOU PASS --full (#2872). Without
# --full, a diff that resolves to `full` prints the bucket and REASON and
# exits 3 — it runs NOTHING, least of all the 18-18.5 minute `./make test`.
# To actually verify a diff that lands here, run `scripts/gate.sh --full` or
# `./make test` directly. In THIS repo's own workflow that full run is
# batched once per push by whoever integrates (CLAUDE.md's verify-loop rule:
# "the full suite runs once per push, and nobody else runs it at all") — but
# that batching is a convention for this repo's own contributors, not a
# substitute for verifying your own change if you have no integrator to
# batch it for you.
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
# EXIT CODES:
#   0  ran and PASSED — covers GATE_RESULT=PASS and the two distinct
#      "nothing to run" verdicts: an empty diff on a clean tree ("nothing to
#      test") and a diff confined to known no-gate prose (GATE_RESULT=NOOP).
#      Neither of those two means bucket `full` was resolved; see exit 3.
#   1  ran a bucket, including a --full-forced full suite, and it FAILED
#      (GATE_RESULT=FAIL).
#   2  usage or internal error: an unknown flag, a dirty tree contradicting
#      an empty diff, or a bucket naming a stale/missing script or step.
#   3  the diff resolved to bucket `full` but --full was NOT passed, so
#      NOTHING RAN (GATE_RESULT=FULL_REQUIRED). Not a pass, not a fail — the
#      printed BUCKET/REASON say why. Run `scripts/gate.sh --full` or
#      `./make test` directly (18-18.5 min) to verify it; this repo's own
#      contributors normally leave that run batched once per push for
#      whoever integrates, but that is a convention, not this script's
#      answer for someone with no integrator to hand it to.
#
# BUCKETS: a change confined to exactly one of compiler/, runtime/,
# tests/cases/, examples/, stdlib/, or docs/**/*.md runs only that area's
# minimal steps. A change touching any OTHER path (anything unlisted below),
# or spanning MORE THAN ONE of those six areas, is ambiguous and always runs
# the full `./make test` — never a partial skip.
#
# PROSE IS CLASSIFIED BY FILE TYPE, NOT PATH PREFIX (#2801): a markdown file
# cannot change what any gate compiles or runs, so it must never select a
# CODE bucket by riding a shared prefix (runtime/*.md is not runtime/*.bit).
# docs/**/*.md gets its own bucket (test-docs compiles its code fences).
# runtime/**/*.md, spec/**, bench/**/*.md, README.md, CONTRIBUTING.md, and
# dist/README.md are known to have no gate at all — a diff confined to those
# runs nothing and says so, distinct from a `full` PASS that implies
# something ran. Mixed with a real bucket, they are silently ignored rather
# than downgrading or widening that bucket's selection. Any OTHER path (spec
# was JUST the two files above, not scripts or dist/stage0/SHA256SUMS, which
# feeds the runtime rebuild fingerprint) still falls through to `full` —
# under-selection is the failure this script exists to prevent, so a prefix
# only gets a prose exception once it's proven output-irrelevant.
#
# TWO NARROW EXCEPTIONS (#2435), because registering a gate is mandatory in
# this repo and otherwise forces `full` on every single ticket that adds one:
#   - tests/bit/** and tests/imports/** (#2825 added the latter — a new
#     fixture directory under tests/imports/ used to fall through to the
#     catch-all below and force `full` on its own) join whichever of the five
#     areas also changed, instead of forcing `full` on their own: their own
#     mapped gate(s) run IN ADDITION to that area's steps (#2510 — a
#     five-area bucket used to silently replace the file's own gate instead
#     of adding to it). If tests/bit/**/tests/imports/** is the ONLY thing
#     that changed, the gates whose `Gate.argv` names each changed file run —
#     nothing more — or `full` if any changed file cannot be mapped that way,
#     whether or not one of the five areas also fired.
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
has_docs=0
has_testsbit=0
has_other=0
has_noop=0
other_list=""
touched_list=""
testsbit_list=""
docs_list=""
noop_list=""

# Extracts the gate name(s) whose `Gate.argv` literally names path `$1`, by
# grepping the source rather than building anything — `runArgs("<path>")` is
# how every harness-running gate spells its target in tools/build/gates.bit.
# THREE NAMED EXCEPTIONS (#2801, #2825): a fixture under tests/bit/checkercases/,
# tests/bit/parsercases/, or tests/imports/ is not passed as an argv path at
# all — its gate reaches the fixture directory through an env var
# (BIT_CHECKER_CASES_DIR, BIT_PARSER_CASES_DIR, BIT_IMPORTS_DIR) rather than a
# per-file `runArgs` entry, so the grep below would find nothing for it and
# the caller would treat a perfectly ordinary fixture as unmapped, forcing
# `full`. Prints nothing for any OTHER path that isn't named via `runArgs`;
# the caller treats that empty result as ambiguous.
gates_for_file() {
  case "$1" in
    tests/bit/checkercases/*) printf 'test-checker-diag\n'; return 0 ;;
    tests/bit/parsercases/*) printf 'test-parser\n'; return 0 ;;
    tests/imports/*) printf 'test-imports-bit\n'; return 0 ;;
  esac
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
    # PROSE, CLASSIFIED BY FILE TYPE, NOT JUST PATH PREFIX (#2801). Placed
    # ahead of the five-bucket matches below because e.g. `runtime/*.md` is a
    # more specific case of `runtime/*` and must win it: a markdown file
    # cannot change what any gate compiles or runs.
    #
    # docs/**/*.md compiles the code fences inside it (tests/bit/docs.bit),
    # so it gets a REAL bucket, same shape as the five below.
    docs/*.md)
      has_docs=1
      if [ -n "${docs_list}" ]; then
        docs_list="${docs_list}, ${f}"
      else
        docs_list="${f}"
      fi
      ;;
    # These paths are pure documentation that no gate reads: runtime/**/*.md
    # (the runtime CODE bucket below is for runtime/*.bit etc, not prose),
    # spec/** (SPEC.md/LINT.md only, checked by no automated gate), bench/**/*.md
    # (bench/**/*.bit and bench/run.sh still fall through to `full`, unproven
    # output-irrelevant), and the three standalone READMEs nothing greps.
    # Deliberately NOT added to has_other, has_noop, or bucket_count: mixed
    # with a real bucket it must be silently ignored, never force `full` and
    # never downgrade the real bucket (constraint in #2801).
    runtime/*.md|spec/*|bench/*.md|README.md|CONTRIBUTING.md|dist/README.md)
      has_noop=1
      if [ -n "${noop_list}" ]; then
        noop_list="${noop_list}, ${f}"
      else
        noop_list="${f}"
      fi
      ;;
    compiler/*) has_selfhost=1 ;;
    runtime/*) has_runtime=1 ;;
    tests/cases/*) has_testcases=1 ;;
    examples/*) has_examples=1 ;;
    stdlib/*) has_stdlib=1 ;;
    # tests/imports/** joins tests/bit/** here (#2825): both are fixture-only
    # paths whose gate is known by name, never by path prefix, so they share
    # has_testsbit/testsbit_list end to end — see gates_for_file() above and
    # the comment ahead of testsbit_steps below.
    tests/bit/*|tests/imports/*)
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
if [ "${has_docs}" -eq 1 ]; then
  if [ -n "${touched_list}" ]; then touched_list="${touched_list}, docs"; else touched_list="docs"; fi
fi

# has_noop is deliberately excluded here — see its case arm above.
bucket_count=$((has_selfhost + has_runtime + has_testcases + has_examples + has_stdlib + has_docs))

# Computed ONCE, ahead of bucket selection, regardless of whether one of the
# five areas also fired (#2510). Two consequences fall out of computing it
# here rather than only inside the old `has_testsbit` elif branch:
#   - an UNMAPPED tests/bit/** or tests/imports/** file must force `full` even
#     when it rides alongside a bucket, exactly like it already did when
#     tests/bit/** was the only change — so `testsbit_unmapped` is checked
#     ahead of every concrete bucket below, not after all five have had a
#     chance to win.
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
  REASON="tests/bit/** or tests/imports/** changed but at least one file could not be mapped to a gate by name — falling through to full"
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
elif [ "${has_docs}" -eq 1 ]; then
  BUCKET="docs"
  REASON="only docs/**/*.md changed (${docs_list})"
elif [ "${has_testsbit}" -eq 1 ]; then
  BUCKET="testsbit"
  REASON="only tests/bit/** or tests/imports/** changed (gate(s): ${testsbit_steps})"
elif [ "${has_noop}" -eq 1 ]; then
  BUCKET="noop"
  REASON="matched only path(s) known to be pure documentation with no gate: ${noop_list}"
else
  # Nothing in the five buckets, docs/**/*.md, tests/bit/**, tests/imports/**,
  # or a known no-gate prose path changed, has_other is 0, and CHANGED is
  # non-empty — the only
  # way here is a purely-additive tools/build/defs.bit/gates.bit registration
  # with no accompanying harness or source change. Nothing to scope narrowly
  # against, so full.
  BUCKET="full"
  REASON="only additive tools/build/** registration changed; nothing left to scope against"
fi

# `noop` has NOTHING to run — no BUILD_STEPS, no pre/post script, no
# `./make --list` validation to do. Exit here rather than threading an empty
# case through the machinery below, which the header comment on BUILD_STEPS
# explicitly says must never hold an empty array under this repo's bash 3.2.
# Prints a distinct verdict, not GATE_RESULT=PASS, because nothing ran (#2801).
if [ "${BUCKET}" = "noop" ]; then
  echo "gate: bucket: noop (${REASON})"
  echo "gate: no gate covers these path(s) — nothing to run"
  echo "GATE_RESULT=NOOP"
  exit 0
fi

# `full` is a VERDICT by default, not an action (#2872). Resolving to `full`
# used to execute the 18-18.5 minute `./make test` immediately — the one
# thing CLAUDE.md's verify-loop rule reserves for the integrator's single run
# before `git push`. A ticket subagent told to "run scripts/gate.sh" had no
# way to learn which bucket this diff needs without also triggering that
# run. So: print BUCKET and REASON exactly as already computed above, run
# nothing, and exit with a code distinct from every other outcome — NOOP
# above also runs nothing, but because no gate exists for the changed paths,
# not because the suite was too broad to scope here; PASS/FAIL both mean a
# bucket actually ran. --full bypasses this and remains the only way this
# script itself executes the full suite.
#
# THE MESSAGE MUST NAME AN ACTION, not just a person (#2872 follow-up).
# CONTRIBUTING.md sends every outside contributor here, and an outside
# contributor has no integrator to hand a "this belongs to the integrator"
# refusal to — they are the only one who will ever run this diff through
# anything. So the printed text leads with the two commands that actually
# verify it (`--full` or `./make test` directly) and states the batched
# pre-push convention as context for THIS repo's own workflow, not as the
# instruction.
if [ "${BUCKET}" = "full" ] && [ "${FULL}" -eq 0 ]; then
  echo "gate: bucket: full (${REASON})"
  echo "gate: nothing ran — this diff is too broad to scope here. To verify it yourself, run 'scripts/gate.sh --full' or './make test' directly (18-18.5 min)."
  echo "gate: in this repo's own workflow that run is batched once per push by whoever integrates — that is a convention, not a substitute for verifying your own change."
  echo "GATE_RESULT=FULL_REQUIRED"
  exit 3
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
  docs)
    BUILD_STEPS=(test-docs)
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

# tests/bit/** or tests/imports/** riding alongside one of the five concrete
# areas contributes its OWN mapped gate(s) too (#2510) — the case above only
# reflects the AREA that also changed, so without this union a changed
# harness's gate silently never ran even though `has_testsbit` was 1 and it
# mapped cleanly. `full`
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
      REASON="${REASON}; tests/bit/** or tests/imports/** also changed — added gate(s): ${testsbit_steps}"
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
for b in full selfhost runtime testcases examples stdlib docs testsbit; do
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
