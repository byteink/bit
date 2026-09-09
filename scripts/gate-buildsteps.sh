#!/usr/bin/env bash
# scripts/gate-buildsteps.sh — per-bucket step selection and validation for
# scripts/gate.sh (#3480). Extracted as a pure move, wrapped into named
# functions: bucket_scripts() is unchanged; build_steps_for_bucket(),
# union_testsbit_steps(), assert_full_is_superset() and validate_build_steps()
# each wrap a previously-inline block with no change to the statements inside
# it. union_spec_steps() (#4136) and assert_fmt_gate_per_bucket() (#4328) are
# the two functions here that are NOT a pure move — see their own comments.
# This file owns the BUCKET-side invariants (what a bucket must run);
# scripts/gate-envscope.sh owns the GATE-side ones (what a gate declares).
# IT IS NOW NEAR THE 800-LINE HARD-ZERO CEILING (_tests_/bit/shellsize.bit).
# The next addition SPLITS the three assert_*() functions and their helpers out
# rather than buying room from the reasoning — #4454's move, one file further. Source this after `cd`-ing to the repo root,
# and after BUCKET/REASON/testsbit_steps/has_testsbit/SPEC_PARTNER are
# already set by gate.sh's own bucket-selection logic — every function here
# reads those as globals rather than taking parameters, matching gate.sh's
# own existing style (bucket_scripts() already did this for
# BUCKET_PRE/BUCKET_POST before this file existed).
#
# Call order, exactly as gate.sh runs this code:
#   build_steps_for_bucket   # sets BUILD_STEPS from BUCKET
#   union_testsbit_steps     # folds testsbit_steps into BUILD_STEPS + REASON
#   union_spec_steps         # folds test-spec into BUILD_STEPS + REASON (#4136)
#   assert_full_is_superset  # every bucket's scripts must be gate_scripts+ #2194
#   assert_composite_is_superset # a composite runs >= each constituent #4480
#   assert_fmt_gate_per_bucket # every .bit tree's bucket runs a fmt gate #4328
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
    # spec and pkg (test-spec/test-packages, _tests_/bit/spec//_tests_/bit/
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

# THE COMPOSITE BUCKETS AND THEIR CONSTITUENTS — the one place the membership
# is written down. build_steps_for_bucket()'s `stdlibdocs` arm derives its step
# list from this, and assert_composite_is_superset() checks the result against
# it, so the two cannot disagree the way a bucket and its hand-copied union did
# for the whole life of that arm (#4480). Prints nothing and returns 1 for a
# bucket that is not composite.
composite_parents() {
  case "$1" in
    stdlibdocs) printf 'stdlib docs\n' ;;
    *) return 1 ;;
  esac
}

# Prints the composite bucket names, one per line — the iteration order for
# assert_composite_is_superset(). Kept beside composite_parents() so adding a
# composite means editing two adjacent lines, and forgetting the second means
# the new bucket is unchecked rather than wrongly checked.
composite_buckets() {
  printf 'stdlibdocs\n'
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
    # "stdlib", "_tests_/stress", "examples", "_tests_/bit", "_tests_/imports"])
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
    #
    # test-fmt-strict (#4445) declares its scope in an ENV entry
    # (BIT_FMTZERO_TREES=compiler:compiler runtime:runtime tools:tools,
    # tools/build/gatestable2.bit), not in argv, so it was invisible to every
    # mapping in this file — three separate batches landed an unformatted
    # compiler/*.bit file on merged `main` with every branch green before this
    # was caught. Same "examines this bucket's content directly" reason as
    # test-lint-filelines/test-selfhostcheck/test-selfcheck above.
    #
    # #4454's env-scope audit found nine more gates in the identical shape,
    # each with a compiler/** component to its scope: test-lint-self
    # (_tests_/bit/lintself.bit scans compiler/+stdlib/+runtime/, #4448),
    # test-lint-complexity and test-lint-sweep (both scan the same
    # ["runtime","compiler","stdlib","tools","pkg"], #4448/#4449),
    # test-threadtokenbytes (compiler/arm64call.bit + compiler/x64call.bit +
    # runtime/gc/*/gcthread.bit cross-tree agreement, #4452), test-version-cli
    # (compiler/version.bit, #4452), test-fmt-citations (compiler/fmt*.bit
    # citations in spec/FMT.md, #4453), and test-fmt-roundtrip (compiler/**'s
    # formatter must round-trip all nine corpus trees, #4451, wired here only
    # — see that ticket's own comment for why the other eight trees are not
    # wired the same way).
    #
    # test-abimembers (#4465) is the same class reached by a THIRD route: its
    # scope is neither in argv (which names only its own fixture directory,
    # `_tests_/bit/abimembers`) nor in an env entry — it is baked into
    # _tests_/bit/abimembers/abimembers.bit's own walk, `bitSources(
    # "${repo}/compiler")` at :216 plus `"${repo}/compiler/irrtfns.bit"` at
    # :373, which reads EVERY `Op.RtCall` name in compiler/*.bit as an ABI
    # demand that runtime/ must provide. It was listed in the `runtime` bucket
    # only, so a compiler-only diff never ran the gate that exists to catch a
    # compiler-only defect: ae8a2581 went red on it in the pre-push suite after
    # #4455's branch ran gate.sh PASS and ~20 gates by hand
    # (compiler/arm64checklayout.bit's layout fixture had named the invented
    # rt_call tag "f"; symptom fixed at d1534308). It stays in `runtime` too —
    # it scans both trees and either half can break it.
    #
    # test-string-explode and test-string-keepalive (#4578) are a FOURTH
    # route to the same gap. Their scope is not in argv (which names only
    # their own fixtures, `_tests_/bit/stringexplode` and
    # `_tests_/bit/stringkeepalive.bit`), not in an env entry, and not in a
    # harness walk of compiler/ the way test-abimembers' is — each one
    # COMPILES AND RUNS a fixture twice, once with BIT_STRING_EXPLODE_TEST=1,
    # and the code under test is the flip itself, which lives entirely in
    # compiler/lowerexplode*, compiler/lower.bit and compiler/codegenlive.bit.
    # So `gates_for_file compiler/codegenlive.bit` is empty (correctly — the
    # changed file is compiler/*.bit, which resolves to this bucket, not to
    # one gate) and before this line a compiler-only diff ran NEITHER gate
    # that executes the BIT_STRING_EXPLODE_TEST path at all.
    #
    # The gap is narrower than "unguarded", and the narrower statement is the
    # useful one: test-selfcheck is in this bucket and does fire on the
    # obvious mutation — emptying `extendKeepAlive` gives `panic: assertion
    # failed` via checkKeepAliveInterval (measured on #4425). What that arm
    # cannot see is anything its synthetic IrFunc does not model, which is
    # #4406's own stated residual: the four recording sites cover the shapes
    # lowerexplode produces TODAY. A new binding site that forgets
    # `recordWordKeepAlive` builds a correct-looking IrFunc, passes
    # checkKeepAliveInterval, and is caught only by RUNNING a flipped
    # program — which is exactly what these two gates do and no other step in
    # this bucket does.
    #
    # test-gc-retention (#4408) is the #4578 shape again — its scope is in
    # neither argv (which names only its own harness) nor an env entry: it
    # COMPILES AND RUNS fixtures and pins the `swept=`/`live=` split of their
    # BIT_GC_STATS=1 summary, and the code that decides that split is compiler/**'s codegen as much as runtime/**'s collector.
    # #4402's own move came from compiler/lowermemprim.bit making a runtime
    # leaf leaf-shaped, which stopped runtime/stw/stwscan.bit's conservative
    # `[sp, top)` scan reading its spilled frame as 941,761 false roots — one
    # commit in each tree could have caused it and no bucket ran anything that
    # reads the counters.
    BUILD_STEPS=(test-imports-bit test-lint-filelines test-selfhostcheck test-selfcheck test-packages test-fmt-strict test-lint-self test-lint-complexity test-lint-sweep test-threadtokenbytes test-version-cli test-fmt-citations test-fmt-roundtrip test-abimembers test-string-explode test-string-keepalive test-gc-retention)
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
    # its own, serially: _tests_/bit/stress/stress.bit's main loop calls
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
    #
    # test-fmt-strict (#4445): same env-declared-scope gap as the selfhost
    # bucket above — BIT_FMTZERO_TREES names `runtime` alongside `compiler`
    # and `tools`, so a runtime/**-only change owes it too.
    #
    # test-lint-self and test-lint-complexity (#4448) both scan runtime/
    # directly (same #4454 audit as test-fmt-strict above); test-lint-sweep
    # (#4449) too, same shape as test-lint-filelines/test-lint-runtime just
    # above it; test-threadtokenbytes (#4452) checks runtime/gc/*/gcthread.bit
    # against compiler/{arm64,x64}call.bit, so a runtime-only edit to the asm
    # side of that pair owes it exactly as much as a compiler-only edit does.
    #
    # test-gc-retention (#4408) is the #4578 shape again — its scope is in
    # neither argv (which names only its own harness) nor an env entry: it
    # COMPILES AND RUNS fixtures and pins the `swept=`/`live=` split of their
    # BIT_GC_STATS=1 summary, and the code that decides that split is runtime/**'s collector and conservative scan as much as compiler/**'s codegen.
    # #4402's own move came from compiler/lowermemprim.bit making a runtime
    # leaf leaf-shaped, which stopped runtime/stw/stwscan.bit's conservative
    # `[sp, top)` scan reading its spilled frame as 941,761 false roots — one
    # commit in each tree could have caused it and no bucket ran anything that
    # reads the counters.
    BUILD_STEPS=(test-stress-exclusive test-rootpins test-rootabi test-stwwiring test-abimembers test-pollfree test-lint-filelines test-lint-runtime test-packages test-fmt-strict test-lint-self test-lint-complexity test-lint-sweep test-threadtokenbytes test-gc-retention)
    ;;
  testcases)
    # test-fuzz mutates the real _tests_/cases corpus (BIT_FUZZ_CASES=
    # ${repoRoot()}/_tests_/cases, not a synthetic one — _tests_/bit/fuzz.bit's own
    # header: "measured ~22 inputs/second over the real _tests_/cases corpus"),
    # so a _tests_/cases/**-only change ran test-golden but never the fuzzer
    # against its own new/changed seeds (#2962). exclusive: true in gates.bit,
    # same as this bucket's existing test-stress-exclusive, so mixing it in
    # here is already a proven shape.
    #
    # test-fmt-cases (#4447) declares BIT_FMTZERO_TREES=cases:_tests_/cases —
    # this bucket's own tree, by name — so a _tests_/cases/**-only change
    # owes it the same way it owes test-golden/test-fuzz above.
    BUILD_STEPS=(test-golden test-fuzz test-fmt-cases)
    ;;
  examples)
    # test-fmt's argv literally includes "${repoRoot()}/examples" alongside
    # stdlib — missing here was the same bug this ticket exists to fix (#2962).
    # test-lint-filelines scans examples/ too (_tests_/bit/lintfilelines.bit's own
    # dirs list includes it) and was missing here the same way (#3128).
    BUILD_STEPS=(test-examples test-fmt test-lint-filelines)
    ;;
  stdlib)
    # test-fmt's argv literally includes "${repoRoot()}/stdlib" (#2962, the
    # instance that opened this ticket — #2955 shipped unformatted
    # stdlib/tls/server.bit and this bucket stayed green). test-lint-filelines
    # scans stdlib/ too (dirs = ["compiler", "runtime", "stdlib", "_tests_/stress",
    # "examples", "_tests_/bit", "_tests_/imports"] in its own harness).
    # test-packages (#3271) too, same reason as the selfhost/runtime buckets
    # above: stdlib/** can break every package even though no package
    # imports it directly by name — every package still builds against it.
    #
    # test-lint-self, test-lint-complexity and test-lint-sweep (#4448/#4449)
    # all scan stdlib/ directly, same #4454 audit as the selfhost/runtime
    # buckets above.
    #
    # test-stdlib-unit (#4478) is the same argv-path-literal shape as test-fmt
    # above: its argv is literally ["test", "${repoRoot()}/stdlib"]
    # (tools/build/gates.bit:195), and it is registered in gateSteps()
    # (tools/build/defs.bit:247), so `./make test` runs it and this bucket owes
    # it. Without it here a stdlib/**-only diff never ran `bit test stdlib` —
    # every stdlib `*.test.bit` (#4212) — under scripts/gate.sh. Found by
    # assert_argvliteral_gates_current() (scripts/gate-envscope.sh, #4477) the
    # first time it ran.
    #
    # test-gc-retention (#4408) is the #4578 shape again — its scope is in
    # neither argv (which names only its own harness) nor an env entry: it
    # COMPILES AND RUNS fixtures and pins the `swept=`/`live=` split of their
    # BIT_GC_STATS=1 summary, and the code that decides that split is stdlib/** too — three of its five pinned rows run std/strings and std/json.
    # #4402's own move came from compiler/lowermemprim.bit making a runtime
    # leaf leaf-shaped, which stopped runtime/stw/stwscan.bit's conservative
    # `[sp, top)` scan reading its spilled frame as 941,761 false roots — one
    # commit in each tree could have caused it and no bucket ran anything that
    # reads the counters.
    BUILD_STEPS=(test-imports-bit test-stdlib-docs test-fmt test-lint-filelines test-packages test-lint-self test-lint-complexity test-lint-sweep test-stdlib-unit test-gc-retention)
    ;;
  docs)
    # test-stdlib-docs reads docs/stdlib/*.md directly (BIT_DOCS_ROOT — it
    # fails when a docs/stdlib/<mod>.md is missing a heading for an exported
    # symbol, the same check it runs from the stdlib side), so a
    # docs/stdlib/*.md-only edit ran test-docs but never it (#2962).
    BUILD_STEPS=(test-docs test-stdlib-docs)
    ;;
  stdlibdocs)
    # THE UNION OF `stdlib` AND `docs` (#3055) — a stdlib export's page can be
    # wrong in either direction (a stale heading, or a missing one) and both
    # buckets' own checks are needed to catch either.
    #
    # COMPUTED from those two arms, not copied from them (#4480). This was a
    # hand-written third list for as long as it existed, and it went stale
    # twice without a word: #4448/#4449 added test-lint-self,
    # test-lint-complexity and test-lint-sweep to `stdlib` and #4478 added
    # test-stdlib-unit, none of them reaching here. So a diff touching
    # stdlib/** AND its docs page ran FOUR FEWER checks over the stdlib change
    # than the same diff without the docs edit — the #2084 shape
    # assert_full_is_superset() below already exists to prevent for `full`,
    # reached at a composite bucket that check does not cover.
    #
    # `local BUCKET` shadows the caller's for the recursion only: the two
    # probing calls read it, and gate.sh's own BUCKET is untouched on return.
    # BUILD_STEPS stays global — it is this function's output — and is built by
    # a loop from `acc` rather than assigned as a literal, the same shape the
    # `testsbit` arm below already uses, so the header's "never empty" rule is
    # kept by both parents being non-empty.
    local parent step acc="" seen=" "
    local BUCKET
    for parent in $(composite_parents stdlibdocs); do
      BUCKET="${parent}"
      build_steps_for_bucket
      for step in "${BUILD_STEPS[@]}"; do
        case "${seen}" in
          *" ${step} "*) ;;
          *) acc="${acc}${step} "; seen="${seen}${step} " ;;
        esac
      done
    done
    BUILD_STEPS=()
    for step in ${acc}; do
      BUILD_STEPS+=("${step}")
    done
    ;;
  pkg)
    # #3271. See the header comment block's "pkg/ IS THE ONE BUCKET..."
    # paragraph and tools/build/defs.bit's test-packages Step{} comment for
    # the asymmetry this rests on: a pkg/**-only diff can never reach
    # compiler/, runtime/ or stdlib/, so every compiler gate is provably
    # irrelevant here, not merely expensive.
    # test-lint-sweep (#3806) is the one exception: its dirNames array
    # (_tests_/bit/lintsweep.bit) now sweeps pkg/ for E0200 max-file-lines
    # alongside runtime/compiler/stdlib/tools, exactly the same
    # "examines this bucket's content directly" reason test-lint-filelines
    # is in the selfhost/runtime/stdlib buckets above — without it here, a
    # pkg/**-only diff that added an 800+-line file would pass this scoped
    # bucket and only fail the full suite.
    #
    # test-fmt (#4477) is the second exception, and the same shape: its argv
    # (tools/build/gatestable2.bit:116-118) literally names
    # `"${repoRoot()}/pkg"` alongside stdlib and examples, both of whose
    # buckets already carry it. Without it here, an unformatted file added in
    # a pkg/**-only diff passed this scoped bucket and failed only in the
    # integrator's pre-push suite. Nothing mechanical could catch this before
    # #4477: test-fmt declares its scope as bare argv path literals, which
    # neither assert_dirgates_current() (greps `runArgs("...")`) nor
    # assert_envscoped_gates_current() (greps `BIT_*_TREES=`) reads —
    # assert_argvliteral_gates_current() (scripts/gate-envscope.sh) is the
    # third assertion, added by that ticket, that does.
    BUILD_STEPS=(test-packages test-lint-sweep test-fmt)
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
# _tests_/bit/**, _tests_/imports/**, or _tests_/stress/** riding alongside one of
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
      REASON="${REASON}; a name-mapped path (_tests_/bit/**, _tests_/imports/**, _tests_/stress/**, or tools/build/complexity-debt.txt) also changed — added gate(s): ${testsbit_steps}"
    fi
    ;;
esac
}

# #4136's FOURTH NARROW EXCEPTION — same shape as union_testsbit_steps() just
# above: folds one extra gate (test-spec) into whichever bucket
# build_steps_for_bucket already selected, rather than owning a bucket of its
# own. SPEC_PARTNER (scripts/gate.sh, set ahead of bucket selection) is empty
# unless the diff resolved BUCKET by way of the spec-pairing exception, so
# this is a no-op for every other bucket, including `full` (test-spec already
# runs there via the aggregate `test` step) and `testsbit`/`stdlibdocs` (spec
# cannot pair with either — see SPEC_PARTNER's own computation).
union_spec_steps() {
  [ -n "${SPEC_PARTNER:-}" ] || return 0
  case " ${BUILD_STEPS[*]} " in
    *" test-spec "*) ;;
    *) BUILD_STEPS+=("test-spec") ;;
  esac
  REASON="${REASON}; spec/SPEC.md also changed — added gate(s): test-spec"
}

assert_full_is_superset() {
# `full` REPLACES a bucket whenever the change spans more than one or touches
# anything outside the five, and this file sells that as the safe direction:
# "cannot confidently scope runs the full suite instead", "never a partial skip".
# It was neither. `full` ran `./make test` and nothing else, while `selfhost`
# ran three differential scripts `./make test` does not contain — so adding one
# unrelated file to a compiler/** change made the gate STRICTLY WEAKER, behind a
# green GATE_RESULT=PASS. Measured on #2084, whose change set was two
# compiler/** files plus _tests_/bit/golden.bit (#2194).
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

assert_composite_is_superset() {
# A COMPOSITE BUCKET REPLACES ITS CONSTITUENTS, so it must run at least what
# they do — the same invariant assert_full_is_superset() above enforces for
# `full`, reached at a bucket that check does not cover. #2084's lesson,
# recurring: `stdlibdocs` is chosen instead of `stdlib` when a stdlib/** diff
# also touches its docs/stdlib/*.md page, and for the whole life of that arm it
# was a hand-copied list that went stale twice — measured 2026-09-08 it ran FOUR
# FEWER checks (test-lint-self, test-lint-complexity, test-lint-sweep,
# test-stdlib-unit) than the plain `stdlib` bucket, so ADDING a file to a diff
# made the gate strictly weaker behind a green GATE_RESULT=PASS (#4480).
#
# The arm derives its list from composite_parents() now, so this cannot fail
# without someone hand-writing the list back. It is checked rather than trusted
# because the previous arm's own comment claimed the union while not being it,
# and no comment fails a gate. Probes the LIVE build_steps_for_bucket() for
# every bucket involved, never a second copy of any step list; shadows
# BUCKET/BUILD_STEPS as locals so it never disturbs the real diff's own bucket
# selection running around it in scripts/gate.sh.
local composite parents parent step composite_steps denom=0 bad=""
local BUCKET BUILD_STEPS
composite="$(composite_buckets)"
if [ -z "${composite}" ]; then
  echo "gate: assert_composite_is_superset: composite_buckets() named NOTHING — today it names at least stdlibdocs, so that is this file's own table breaking, not a fact about the tree. An empty list checks nothing and prints like a clean run." >&2
  exit 2
fi
while IFS= read -r composite; do
  [ -n "${composite}" ] || continue
  denom=$((denom + 1))
  parents="$(composite_parents "${composite}")" || {
    echo "gate: assert_composite_is_superset: composite_buckets() names '${composite}' but composite_parents() has no arm for it — the two adjacent tables in scripts/gate-buildsteps.sh have diverged." >&2
    exit 2
  }
  BUCKET="${composite}"
  BUILD_STEPS=(__no_arm__)
  build_steps_for_bucket
  composite_steps=" ${BUILD_STEPS[*]} "
  case "${composite_steps}" in
    *" __no_arm__ "*)
      echo "gate: assert_composite_is_superset: bucket '${composite}' has no arm in build_steps_for_bucket() — it would run nothing." >&2
      exit 2
      ;;
  esac
  for parent in ${parents}; do
    BUCKET="${parent}"
    BUILD_STEPS=(__no_arm__)
    build_steps_for_bucket
    case " ${BUILD_STEPS[*]} " in
      *" __no_arm__ "*)
        echo "gate: assert_composite_is_superset: composite '${composite}' names constituent '${parent}', which has no arm in build_steps_for_bucket()." >&2
        exit 2
        ;;
    esac
    for step in "${BUILD_STEPS[@]}"; do
      case "${composite_steps}" in
        *" ${step} "*) ;;
        *)
          bad="${bad:+${bad}
}composite bucket '${composite}' is missing '${step}', which its constituent '${parent}' runs — the composite REPLACES that bucket, so a diff touching both areas would run FEWER checks over ${parent}/** than a ${parent}-only diff (#4480/#2084)"
          ;;
      esac
    done
  done
done <<EOF
${composite}
EOF

if [ -n "${bad}" ]; then
  echo "gate: assert_composite_is_superset: FAILED —" >&2
  echo "${bad}" | sed 's/^/gate:   /' >&2
  exit 2
fi
echo "gate: assert_composite_is_superset: ${denom} composite bucket(s); each runs a superset of every constituent's steps"
}

# ---------------------------------------------------------------------------
# EVERY .bit TREE'S BUCKET RUNS A FMT GATE (#4328).
#
# scripts/gate-envscope.sh's three assertions all ask one question from the
# GATE's side: gate G declares tree T, so the bucket owning T must list G. That
# question is vacuous for a tree NO gate declares. #4325 edited
# runtime/root/rootconfig.bit, scripts/gate.sh reported GATE_RESULT=PASS, and
# merged `main` (ab12ff28) then failed test-fmt-strict on the file it had just
# edited — the `runtime` bucket ran no formatter at all. #4445 closed that
# instance and assert_envscoped_gates_current() holds it shut. The other end of
# the same wire is still open: drop `runtime:runtime` from BIT_FMTZERO_TREES and
# all three stay green — the env half has no runtime pair left to check, the
# bucket still lists the step — while runtime/*.bit is formatted by nothing.
#
# So this asks it from the BUCKET's side, which is why it lives here beside
# assert_full_is_superset(): every tree holding `.bit` sources must be
# `fmt --check`ed by some gate, and the bucket that tree resolves to must run
# one of the gates that checks it. Called from scripts/gate.sh after every
# module is sourced — it probes argvliteral_bucket_for_dir() (gate-envscope.sh)
# and testsbit_steps_for() (gate-filemap.sh), neither of which exists at this
# file's own source time.

# Emits "<gate> <tree>" for every gate that runs `bit fmt --check` over a source
# tree, from the two live gate tables, by the two spellings that exist:
#
#   1. `BIT_FMTZERO_TREES=name:relpath ...` — the four zero-tolerance gates on
#      the shared driver _tests_/bit/fmtzerocheck.bit (#3713). Matched on that
#      var by name, not on any `_TREES=`: this asks who FORMATS a tree, and a
#      future BIT_<other>_TREES= gate would be a different claim.
#   2. a Gate{} whose argv opens `["fmt", "--check"` — its bare
#      `"${repoRoot()}/<dir>"` argv literals are the trees it formats. Keyed on
#      the COMMAND the gate runs, not its name, so a fmt gate named something
#      else is still found and a gate merely NAMED test-fmt-* is not miscounted
#      (test-fmt-roundtrip and test-fmt-citations neither `--check` a tree).
#
# Line-based and name-tracking, exactly like gate-envscope.sh's
# envscoped_gate_trees()/argvliteral_gate_paths(), including the `fn ` reset so
# a `${repoRoot()}` literal in a helper is never attributed to the last Gate{}
# scanned. An `env:` line ends an argv scan: test-fmt's argv spans three lines
# with its env on the fourth, and an env path is not a formatted tree.
fmt_gate_trees() {
  local file line name m pair p inargv=0
  for file in tools/build/gates.bit tools/build/gatestable2.bit; do
    name=""
    inargv=0
    while IFS= read -r line; do
      case "${line}" in
        'fn '*) name=""; inargv=0 ;;
      esac
      case "${line}" in
        *'Gate{name: "'*)
          name="$(printf '%s' "${line}" | sed -n 's/.*Gate{name: "\([^"]*\)".*/\1/p')"
          inargv=0
          ;;
      esac
      [ -n "${name}" ] || continue
      case "${line}" in
        *'BIT_FMTZERO_TREES='*)
          m="$(printf '%s' "${line}" | sed -n 's/.*BIT_FMTZERO_TREES=\([^"]*\)".*/\1/p')"
          [ -n "${m}" ] || continue
          for pair in ${m}; do
            printf '%s %s\n' "${name}" "${pair#*:}"
          done
          continue
          ;;
      esac
      case "${line}" in
        *'"fmt", "--check"'*) inargv=1 ;;
        *'env:'*) inargv=0 ;;
      esac
      [ "${inargv}" -eq 1 ] || continue
      m="$(printf '%s' "${line}" | command grep -oE '"\$\{repoRoot\(\)\}/[^"$]+"' || true)"
      [ -n "${m}" ] || continue
      for p in ${m}; do
        p="${p#\"\$\{repoRoot()\}/}"
        printf '%s %s\n' "${name}" "${p%\"}"
      done
    done <"${file}"
  done
}

# Prints one tree name per `.bit`-holding source tree, sorted and deduplicated.
# DERIVED FROM DISK, never a hand list — `git ls-files '*.bit'` cut to its tree,
# where git's pathspec `*` crosses `/` (a shell glob does not) and so one
# pattern reaches every depth. Tracked or staged files only: a `--others` query
# is perturbed by any other agent's scratch file in a shared checkout, and a new
# tree is `git add`ed before it can be committed. `_tests_/` is cut one level
# deeper because that is the granularity every routing table here and in
# scripts/gate-classify.sh uses. A `.bit` file at the repo root belongs to no
# tree and is skipped — there are none, and one would resolve to `full` anyway.
bit_source_trees() {
  git ls-files '*.bit' |
    awk -F/ 'NF < 2 { next } { if ($1 == "_tests_") print $1 "/" $2; else print $1 }' |
    sort -u
}

# The live-query floor, named rather than counted for the same reason
# gate-envscope.sh's ARGVSCOPE_COMPILER_FLOOR and ARGVLITERAL_FLOOR are:
# bit_source_trees() returning nothing (a pathspec that stopped crossing `/`, a
# `cd` that never happened) passes this assertion over an empty list, printing
# exactly like a correctly wired tree.
FMTGATE_TREE_FLOOR="compiler runtime stdlib examples pkg _tests_/cases _tests_/bit"

# NAMED EXEMPTION: trees holding `.bit` sources that NO fmt gate names today, so
# no bucket can carry one. Measured 2026-09-09 at dec67909 — 4 files, which
# `./make test` does not format either. Filed as #4681; delete a name here when
# that lands, or this assertion goes on skipping it. Both match no arm in
# scripts/gate-classify.sh, so both resolve to has_other=1 -> bucket `full`.
FMTGATE_UNGATED_TREES="_tests_/freestanding _tests_/testproj"

# Fails loudly if this is called before the modules it probes are sourced.
# Absent, `$(...)` yields empty and every tree looks unwired — a plausible WRONG
# answer naming real trees, which is worse than a crash. Same reason as
# gate-envscope.sh's assert_envscope_deps(), which this cannot reuse: that one
# does not check argvliteral_bucket_for_dir(), the one this needs most.
assert_fmtgate_deps() {
  local fn missing=""
  for fn in argvliteral_bucket_for_dir testsbit_steps_for; do
    command -v "${fn}" >/dev/null 2>&1 || missing="${missing:+${missing} }${fn}"
  done
  [ -z "${missing}" ] && return 0
  echo "gate: assert_fmt_gate_per_bucket: called without its dependencies (${missing} undefined) — source scripts/gate-filemap.sh and scripts/gate-envscope.sh first, as scripts/gate.sh does. Refusing to report a verdict: with these absent every tree looks unwired and the failure list would name real trees for a reason that is not true of the tree." >&2
  exit 2
}

# Asserts (1) every `.bit` source tree is formatted by some gate and (2) the
# bucket that tree resolves to runs one of those gates. Probes the LIVE
# build_steps_for_bucket()/testsbit_steps_for()/argvliteral_bucket_for_dir(),
# never a second copy, so the only way to pass is to be wired. Shadows
# BUCKET/BUILD_STEPS as locals, so it never disturbs the real diff's own bucket
# selection running around it in scripts/gate.sh.
assert_fmt_gate_per_bucket() {
  local pairs trees tree want gate bucket probe result covering
  local denom=0 routed=0 bad=""
  local BUCKET BUILD_STEPS
  assert_fmtgate_deps
  pairs="$(fmt_gate_trees)"
  if [ -z "${pairs}" ]; then
    echo "gate: assert_fmt_gate_per_bucket: found ZERO gates formatting a tree across both gate tables — that is this function's own extraction breaking (today there are at least 5: test-fmt plus test-fmt-strict/-stress/-testsbit/-cases), not a fact about the tree" >&2
    exit 2
  fi
  trees="$(bit_source_trees)"
  for want in ${FMTGATE_TREE_FLOOR}; do
    case "
${trees}
" in
      *"
${want}
"*) ;;
      *)
        echo "gate: assert_fmt_gate_per_bucket: did NOT rediscover \"${want}\", which holds .bit sources by inspection — bit_source_trees() (scripts/gate-buildsteps.sh) has stopped matching. A discovery matching nothing looks exactly like a correctly wired tree; refusing to report a verdict." >&2
        exit 2
        ;;
    esac
  done

  while IFS= read -r tree; do
    [ -n "${tree}" ] || continue
    case " ${FMTGATE_UNGATED_TREES} " in
      *" ${tree} "*) continue ;;
    esac
    denom=$((denom + 1))
    covering="$(printf '%s\n' "${pairs}" | awk -v t="${tree}" '$2 == t { print $1 }')"
    if [ -z "${covering}" ]; then
      bad="${bad:+${bad}
}tree \"${tree}\" holds .bit sources but NO gate runs \`bit fmt --check\` over it — add it to an existing BIT_FMTZERO_TREES gate or to test-fmt's argv (tools/build/gatestable2.bit), or name it in FMTGATE_UNGATED_TREES here with its ticket"
      continue
    fi
    bucket="$(argvliteral_bucket_for_dir "${tree}")" || {
      bad="${bad:+${bad}
}tree \"${tree}\" holds .bit sources and is formatted by \"${covering}\", but argvliteral_bucket_for_dir() (scripts/gate-envscope.sh) does not know how to route it — add a case arm naming its bucket, or a named exemption with its reason"
      continue
    }
    # An empty bucket is that table's own named exemption (tools, bench,
    # editors): every diff touching one resolves to `full`, which runs every
    # gate via the aggregate `test` step.
    [ -n "${bucket}" ] || continue
    routed=$((routed + 1))
    if [ "${bucket}" = "testsbit" ]; then
      case "${tree}" in
        _tests_/bit) probe="_tests_/bit/golden/probe.bit" ;;
        _tests_/stress) probe="_tests_/stress/probe.bit" ;;
        _tests_/imports) probe="_tests_/imports/probe.bit" ;;
      esac
      result=" $(testsbit_steps_for "${probe}") "
    else
      BUCKET="${bucket}"
      build_steps_for_bucket
      result=" ${BUILD_STEPS[*]} "
    fi
    for gate in ${covering}; do
      case "${result}" in
        *" ${gate} "*) continue 2 ;;
      esac
    done
    bad="${bad:+${bad}
}tree \"${tree}\" is formatted by \"${covering}\", but bucket \"${bucket}\" runs none of those — a ${tree}/**-only diff reports PASS while unformatted (#4328)"
  done <<EOF
${trees}
EOF

  if [ -n "${bad}" ]; then
    echo "gate: assert_fmt_gate_per_bucket: FAILED — ${denom} .bit source tree(s) checked, ${routed} routed to a bucket:" >&2
    echo "${bad}" | sed 's/^/gate:   /' >&2
    exit 2
  fi
  echo "gate: assert_fmt_gate_per_bucket: ${denom} .bit source tree(s), ${routed} routed to a bucket; each is fmt-gated and its bucket runs a gate that formats it"
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
