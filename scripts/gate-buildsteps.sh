#!/usr/bin/env bash
# scripts/gate-buildsteps.sh — per-bucket step selection and validation for
# scripts/gate.sh (#3480). Extracted as a pure move, wrapped into named
# functions: bucket_scripts() is unchanged; build_steps_for_bucket(),
# union_testsbit_steps(), assert_full_is_superset() and validate_build_steps()
# each wrap a previously-inline block with no change to the statements inside
# it. Source this after `cd`-ing to the repo root, and after BUCKET/REASON/
# testsbit_steps/has_testsbit are already set by gate.sh's own bucket-
# selection logic — every function here reads those as globals rather than
# taking parameters, matching gate.sh's own existing style (bucket_scripts()
# already did this for BUCKET_PRE/BUCKET_POST before this file existed).
#
# Call order, exactly as gate.sh used to run this code inline:
#   build_steps_for_bucket   # sets BUILD_STEPS from BUCKET
#   union_testsbit_steps     # folds testsbit_steps into BUILD_STEPS + REASON
#   assert_full_is_superset  # every bucket's scripts must be gate_scripts+ #2194
#   bucket_scripts "${BUCKET}"; PRE_SCRIPTS=...; POST_SCRIPTS=...
#   validate_build_steps     # STALE check against ./make --list

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
      # selfhost-diffcheck.sh and selfhost-fixpoint.sh are DELIBERATELY NOT
      # BUCKET_PRE here (#3347). Measured standalone on a box with no
      # make-driver competing: `selfhost-diffcheck.sh` 415s (808-file corpus,
      # MATCH=808), `selfhost-fixpoint.sh` 153s (builds the compiler twice) —
      # 568s together, before the bucket's own `./make` gates (275s standalone
      # with selfhost warm) or a real selfhost rebuild (76s for a one-line
      # compiler/** comment) even start. The full old bucket did not finish in
      # 600s (killed at the ceiling still mid-`make: selfhost` rebuild),
      # matching #3328's five failed attempts. Same defect class as #3309
      # (test-stress-batch out of the runtime bucket): a single-file, no-
      # concurrency serial loop over hundreds of corpus files that no batching
      # can shrink.
      #
      # Coverage is NOT lost. Both scripts match `scripts/selfhost-*.sh` and
      # are picked up by `scripts/selfhost-diffall.sh`'s discovery, which is
      # what `./make test-differentials` (tools/build/defs.bit's
      # `coreSteps()`, #2570) runs — already part of the mandatory three-
      # command pre-push gate (CLAUDE.md "the verify loop"), and already the
      # sanctioned home for this exact family precisely because it is too
      # slow for `./make test` (defs.bit's own `test-differentials` comment:
      # folding it in "would roughly double the ~19-minute pre-push suite").
      # Only the diff-scoped working-loop gate stops paying for it a second
      # time on every scoped run.
      #
      # #1857 was a COMPILER bug (`parseFloat` had no hex-float branch) whose
      # only visible damage was in runtime codegen, and no differential walked
      # `runtime/`. A compiler/** change must be diffed against it (#1859).
      # selfhost-diffruntime.sh stays here: measured standalone at 22s, it was
      # never the problem.
      BUCKET_POST="scripts/selfhost-diffruntime.sh"
      ;;
    runtime)
      BUCKET_POST="scripts/selfhost-diffruntime.sh"
      ;;
    examples)
      BUCKET_POST="scripts/selfhost-diffexamples.sh"
      ;;
    # spec and pkg (test-spec/test-packages, tests/bit/spec//tests/bit/
    # packagesgate.bit) have no differential script — same shape as
    # testcases/stdlib/docs/testsbit above, which also fall through with
    # both empty.
    full)
      # THE UNION OF EVERY BUCKET ABOVE, and it must stay that way — enforced
      # below, not merely intended.
      BUCKET_PRE="scripts/selfhost-diffcheck.sh scripts/selfhost-fixpoint.sh"
      BUCKET_POST="scripts/selfhost-diffruntime.sh scripts/selfhost-diffexamples.sh"
      ;;
  esac
}

build_steps_for_bucket() {
case "${BUCKET}" in
  full)
    # test-packages (#3271) is added explicitly: it is registered in
    # tools/build/defs.bit's `coreSteps()`, deliberately not `gateSteps()`
    # (same reason as test-differentials beside it — see that Step{}'s own
    # comment), so plain `test` never reaches it on its own.
    BUILD_STEPS=(test test-packages)
    ;;
  selfhost)
    # test-lint-filelines (its own harness: dirs = ["compiler", "runtime",
    # "stdlib", "tests/stress", "examples", "tests/bit", "tests/imports"])
    # and test-selfhostcheck (argv literally
    # ["check", "${repoRoot()}/compiler"]) both examine compiler/ content
    # directly and were missing here (#2962) — a compiler/**-only change ran
    # neither. test-selfcheck (argv literally ["selfcheck"]) was missed in
    # that same audit (#3127) — it is the compiler's own self-test over
    # compiler/**'s backend modules, and #1852/#1853 both broke it while this
    # bucket stayed green. The stale-name check below the case statement only
    # rejects a listed step that no longer exists; it has no way to notice a
    # relevant step that was never listed, which is how this stayed missing
    # for as long as it did.
    # test-packages (#3271) too: nothing under pkg/ imports compiler/**, but
    # compiler/** can break every package, so a compiler/**-only change owes
    # it the same way `full` above does.
    BUILD_STEPS=(test-imports-bit test-lint-filelines test-selfhostcheck test-selfcheck test-packages)
    ;;
  runtime)
    # Every name in this bucket was once stale: four of the six named steps did
    # not exist, so a runtime/** change died on `no step named` instead of
    # testing anything. The check after this case block now catches that class
    # before a single step runs — a bucket naming a nonexistent step is a
    # bucket that silently tests less than it claims.
    #
    # test-lint-filelines (compiler/runtime/stdlib line-count scan) and
    # test-lint-runtime (its own gates.bit comment: "points `bit lint` at
    # `${BIT_REPO}/runtime`", E0211 unused-local) both examine runtime/
    # content directly and were missing here too (#2962).
    #
    # test-stress-batch is DELIBERATELY NOT in this bucket (#3309). Measured
    # standalone on an idle box: `make: test-stress-batch — 11m0s` (65/65
    # programs judged, PASS) — over the subagent Bash tool's 600s ceiling on
    # its own, serially: tests/bit/stress/stress.bit's main loop calls
    # checkProgram() once per eligible program with no concurrency, so there
    # is no batching win available here the way the concurrent gate batch
    # gives every OTHER step in this bucket. With it included, the same idle
    # box measured the whole bucket at `./make ... — total 13m27s` plus
    # scripts/selfhost-diffruntime.sh after it (839s / 13m59s end to end for
    # `bash scripts/gate.sh`) — nine agents in one night could not complete
    # this bucket because of it (#3280, #3294-3297, #3300, #3307, #3312,
    # #3291). It stays exactly where it was in gateSteps() below (defs.bit),
    # so `./make test` still runs it unchanged — only the diff-scoped
    # working-loop gate stops paying for it. test-stress-exclusive (2
    # programs, real elapsed-time asserts, 0m8s) stays here: it is fast and
    # was never the problem.
    # test-packages (#3271) too, same reason as the selfhost bucket above:
    # runtime/** can break every package even though no package imports it.
    BUILD_STEPS=(test-stress-exclusive test-rootpins test-rootabi test-stwwiring test-abimembers test-pollfree test-lint-filelines test-lint-runtime test-packages)
    ;;
  testcases)
    # test-fuzz mutates the real tests/cases corpus (BIT_FUZZ_CASES=
    # ${repoRoot()}/tests/cases, not a synthetic one — tests/bit/fuzz.bit's own
    # header: "measured ~22 inputs/second over the real tests/cases corpus"),
    # so a tests/cases/**-only change ran test-golden but never the fuzzer
    # against its own new/changed seeds (#2962). exclusive: true in gates.bit,
    # same as this bucket's existing test-stress-exclusive, so mixing it in
    # here is already a proven shape.
    BUILD_STEPS=(test-golden test-fuzz)
    ;;
  examples)
    # test-fmt's argv literally includes "${repoRoot()}/examples" alongside
    # stdlib — missing here was the same bug this ticket exists to fix (#2962).
    # test-lint-filelines scans examples/ too (tests/bit/lintfilelines.bit's own
    # dirs list includes it) and was missing here the same way (#3128).
    BUILD_STEPS=(test-examples test-fmt test-lint-filelines)
    ;;
  stdlib)
    # test-fmt's argv literally includes "${repoRoot()}/stdlib" (#2962, the
    # instance that opened this ticket — #2955 shipped unformatted
    # stdlib/tls/server.bit and this bucket stayed green). test-lint-filelines
    # scans stdlib/ too (dirs = ["compiler", "runtime", "stdlib", "tests/stress",
    # "examples", "tests/bit", "tests/imports"] in its own harness).
    # test-packages (#3271) too, same reason as the selfhost/runtime buckets
    # above: stdlib/** can break every package even though no package
    # imports it directly by name — every package still builds against it.
    BUILD_STEPS=(test-imports-bit test-stdlib-docs test-fmt test-lint-filelines test-packages)
    ;;
  docs)
    # test-stdlib-docs reads docs/stdlib/*.md directly (BIT_DOCS_ROOT — it
    # fails when a docs/stdlib/<mod>.md is missing a heading for an exported
    # symbol, the same check it runs from the stdlib side), so a
    # docs/stdlib/*.md-only edit ran test-docs but never it (#2962).
    BUILD_STEPS=(test-docs test-stdlib-docs)
    ;;
  stdlibdocs)
    # The union of the `stdlib` and `docs` buckets' own steps just above
    # (#3055) — a stdlib export's page can be wrong in either direction (a
    # stale heading, or a missing one) and both buckets' own checks are
    # needed to catch either. Carries `stdlib`'s own test-packages (#3271)
    # forward for the same reason.
    BUILD_STEPS=(test-imports-bit test-stdlib-docs test-fmt test-lint-filelines test-docs test-packages)
    ;;
  pkg)
    # #3271. THE ONE BUCKET that runs test-packages and NOTHING else — see
    # the header comment block's "pkg/ IS THE ONE BUCKET..." paragraph and
    # tools/build/defs.bit's test-packages Step{} comment for the asymmetry
    # this rests on: a pkg/**-only diff can never reach compiler/, runtime/
    # or stdlib/, so every compiler gate is provably irrelevant here, not
    # merely expensive.
    BUILD_STEPS=(test-packages)
    ;;
  spec)
    BUILD_STEPS=(test-spec)
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
}

union_testsbit_steps() {
# tests/bit/**, tests/imports/**, or tests/stress/** riding alongside one of
# the five concrete areas contributes its OWN mapped gate(s) too (#2510) — the
# case above only reflects the AREA that also changed, so without this union a
# changed harness's gate silently never ran even though `has_testsbit` was 1
# and it mapped cleanly. `full`
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
      REASON="${REASON}; tests/bit/**, tests/imports/**, or tests/stress/** also changed — added gate(s): ${testsbit_steps}"
    fi
    ;;
esac
}

assert_full_is_superset() {
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
for b in full selfhost runtime testcases examples stdlib pkg docs stdlibdocs spec testsbit; do
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
}

validate_build_steps() {
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
}
