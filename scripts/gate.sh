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
#   4  ran a bucket, no constituent FAILED, but at least one of
#      scripts/selfhost-diffcheck.sh or scripts/selfhost-fixpoint.sh exited 2
#      — that exit code is those two scripts' own documented "could not
#      decide" verdict (a differential TIMEOUT, or #2980's fixed-point
#      UNDECIDED), never a proven pass and never a proven divergence
#      (GATE_RESULT=UNDECIDED, #2991). Chosen distinct from 0 for the same
#      reason #2872 chose 3 for FULL_REQUIRED instead of reusing 0: a caller
#      that reads "nothing decided" as "passed" is the same defect in a new
#      place. A real exit-1 divergence anywhere still wins over an undecided
#      sibling and reports GATE_RESULT=FAIL/exit 1 — re-run
#      `scripts/gate.sh` (or the named script directly) when the machine is
#      quieter.
#
# BUCKETS: a change confined to exactly one of compiler/, runtime/,
# tests/cases/, examples/, stdlib/, pkg/, docs/**/*.md, or spec/SPEC.md runs
# only that area's minimal steps. A change touching any OTHER path (anything
# unlisted below), or spanning MORE THAN ONE of those eight areas, is
# ambiguous and always runs the full `./make test` — never a partial skip —
# EXCEPT the narrow stdlib+docs pairing bucket `stdlibdocs` (#3055, see the
# "THREE NARROW EXCEPTIONS" block below).
#
# `pkg/` IS THE ONE BUCKET WHOSE STEP LIST IS NOT ARGV/ENV INTERSECTION
# (#3271, epic: first-party packages under pkg/<name>/). `test-packages`'s own
# argv is `runArgs("tests/bit/packagesgate.bit")` — no `pkg/` path anywhere in
# gates.bit's table for it to intersect — so it is added to the `pkg`,
# `selfhost`, `runtime`, `stdlib`, `stdlibdocs` and `full` buckets BY HAND,
# for the asymmetry bitlang-ws/CLAUDE.md's "First-party packages" section
# states as the whole design: nothing in compiler/**, runtime/**, stdlib/** or
# tools/build/** imports a package, so a pkg/**-only diff can never break the
# language and every OTHER bucket is provably irrelevant to it — but the
# language CAN break a package, so any bucket that can change compiler/
# runtime/stdlib behaviour must run this gate too, or a language change could
# silently break every package with nothing here catching it.
#
# EVERY BUCKET RUNS EVERY GATE WHOSE OWN DECLARED FILE SET (its `argv` or an
# `env` entry in tools/build/gates.bit) INTERSECTS THAT BUCKET'S PATHS, not
# just the one gate the bucket was originally named after (#2962). Read each
# `Gate{}`'s argv/env before assuming a bucket's step list is complete — a
# gate's scope is not its name. Concretely: `stdlib` and `examples` both run
# `test-fmt` (its argv literally names `${repoRoot()}/stdlib` and
# `${repoRoot()}/examples`); `selfhost`, `runtime`, `stdlib` and `examples` all
# run `test-lint-filelines` (tests/bit/lintfilelines.bit's own `dirs =
# ["compiler", "runtime", "stdlib", "tests/stress", "examples", "tests/bit",
# "tests/imports"]` — seven directories, not three; #3128 wired up the fourth
# bucket, `examples`, plus the three directories that never resolve to a
# concrete bucket at all: `tests/bit/**`, `tests/imports/**`, and
# `tests/stress/**` each run it too, added to the `testsbit_steps_for()`
# special-case block next to test-filesize below rather than to a bucket,
# since all three route through the shared `testsbit` bucket instead of one
# of the five concrete areas); `runtime` also runs `test-lint-runtime` (its own
# comment in gates.bit: "points `bit lint` at `${BIT_REPO}/runtime`");
# `selfhost` also runs `test-selfhostcheck` (argv literally
# `["check", "${repoRoot()}/compiler"]`); `docs` also runs `test-stdlib-docs`
# (BIT_DOCS_ROOT — it fails on a `docs/stdlib/<mod>.md` missing a heading, same
# as it does on an undocumented stdlib export); `testcases` also runs
# `test-fuzz` (BIT_FUZZ_CASES=`${repoRoot()}/tests/cases` — it mutates that
# real corpus, not a synthetic one); every tests/bit/** file also runs
# `test-filesize` (tests/bit/filesize.bit's own stated scope: "anywhere under
# tests/bit/, RECURSIVELY", not just its own harness file).
#
# `selfhost` ALSO runs `test-selfcheck` (#3127), but NOT by the argv/env rule
# above — its argv is literally `["selfcheck"]`, no path at all, because it is
# an in-Bit self-test compiled INTO the compiler binary from compiler/**'s own
# backend modules (compiler/selfcheck.bit), not a harness that reads a
# directory argument. Any compiler/** change recompiles it, so it belongs in
# `selfhost` by construction. It was missing here for as long as #2962's own
# audit, and #1852/#1853 both broke it — in compiler/**'s own backend
# selectors, arm64 and x86-64 respectively — while this bucket stayed green.
#
# A gate whose file set could not be determined by argv/env intersection, and
# is not (like test-selfcheck) inherently scoped to one of the five bucket
# areas by what it compiles rather than what it reads (no gates.bit comment
# naming a scope either — e.g. `test-version-cli`), is deliberately left out
# rather than guessed at from its harness's full source.
#
# PROSE IS CLASSIFIED BY FILE TYPE, NOT PATH PREFIX (#2801): a markdown file
# cannot change what any gate compiles or runs, so it must never select a
# CODE bucket by riding a shared prefix (runtime/*.md is not runtime/*.bit).
# docs/**/*.md gets its own bucket (test-docs compiles its code fences), and
# spec/SPEC.md gets its own bucket too (test-spec, #2758, is a real gate over
# it — it is NOT prose with no gate, unlike its sibling spec/LINT.md).
# runtime/**/*.md, spec/LINT.md (and any other spec/* besides SPEC.md),
# bench/**/*.md, README.md, CONTRIBUTING.md, and dist/README.md are known to
# have no gate at all — a diff confined to those runs nothing and says so,
# distinct from a `full` PASS that implies something ran. Mixed with a real
# bucket, they are silently ignored rather than downgrading or widening that
# bucket's selection. Any OTHER path (not scripts or dist/stage0/SHA256SUMS,
# which feeds the runtime rebuild fingerprint) still falls through to `full` —
# under-selection is the failure this script exists to prevent, so a prefix
# only gets a prose exception once it's proven output-irrelevant.
#
# THREE NARROW EXCEPTIONS (#2435, #3055), because registering a gate is
# mandatory in this repo and otherwise forces `full` on every single ticket
# that adds one:
#   - tests/bit/**, tests/imports/**, and tests/stress/** (#2825 added the
#     second — a new fixture directory under tests/imports/ used to fall
#     through to the catch-all below and force `full` on its own; #2977 added
#     the third — tests/stress/ is the corpus tests/bit/stress/stress.bit
#     reads by default, root + "/tests/stress", but is a different top-level
#     directory from its harness and so was never mapped at all) join
#     whichever of the five areas also changed, instead of forcing `full` on
#     their own: their own mapped gate(s) run IN ADDITION to that area's steps
#     (#2510 — a five-area bucket used to silently replace the file's own gate
#     instead of adding to it). If tests/bit/**/tests/imports/**/tests/stress/**
#     is the ONLY thing that changed, the gates whose `Gate.argv` names each
#     changed file (or, for tests/stress/**, the hand-named exception in
#     `gates_for_file()` below) run — nothing more — or `full` if any changed
#     file cannot be mapped that way, whether or not one of the five areas
#     also fired.
#   - tools/build/defs.bit and tools/build/gates.bit are the same case only
#     when the change is PURELY new `Step{}`/`Gate{}` registration: no edit to
#     an existing entry, no edit to any function body. See
#     `is_additive_registration` below for exactly what that means. Any other
#     tools/build/** file, or any non-additive change to these two, still
#     forces `full` — that code is the driver every step runs under.
#   - stdlib/** paired ONLY with its own mandatory docs/stdlib/**.md page
#     (#3055): tests/bit/stdlibdocs.bit fails the build on any exported
#     stdlib symbol whose module lacks a docs/stdlib/<mod>.md heading, so an
#     ordinary stdlib-export ticket is structurally required to touch both
#     the `stdlib` and `docs` buckets in the same diff — the `bucket_count
#     -gt 1` rule below would otherwise force `full` on every single one of
#     them, which is exactly the cost this script exists to avoid paying on
#     every ticket (#2704's std/sort hit this and could not use the scoped
#     gate at all). Resolves to bucket `stdlibdocs` — the union of the
#     `stdlib` and `docs` buckets' own steps — only when stdlib and docs are
#     the ONLY two buckets touched (no selfhost/runtime/testcases/examples/
#     spec) and every changed docs/**/*.md file is either
#     docs/stdlib/README.md (carries no gate of its own) or
#     docs/stdlib/<mod>.md for a <mod> that also has a stdlib/<mod>/** change
#     in the same diff. See `stdlib_docs_pairing_ok` below for the exact
#     check. Any docs/*.md outside docs/stdlib/, or a docs/stdlib/<mod>.md
#     with no matching stdlib/<mod>/** change, still forces `full`.
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
has_pkg=0
has_docs=0
has_spec=0
has_testsbit=0
has_other=0
has_noop=0
other_list=""
touched_list=""
testsbit_list=""
docs_list=""
spec_list=""
noop_list=""
# Space-separated (never comma-joined, unlike docs_list/other_list above,
# which exist only for human-readable REASON text): stdlib_docs_pairing_ok
# above word-splits these, so a comma in the string would corrupt the match.
docs_files=""
stdlib_files=""

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
#
# NINE MORE EXCEPTIONS (#2903, recounted #3047 — recount from the case arms
# below at fix time, not from this number, which has already drifted twice as
# later tickets added arms without updating it): nine gates register a whole
# DIRECTORY in `runArgs("tests/bit/<dir>")` rather than a single file,
# because the directory is one Bit module and the gate runs it as one
# program — so no path INSIDE that directory can ever match the exact-string
# grep below, and every file in all nine (abimembers, benchgate, clicmd,
# pollfree, rootabi, rootpins, spec, stress, stwwiring) was unmapped, forcing
# `full`, until this fix. One arm per
# directory, matching the gate(s) gates.bit actually registers for it — for
# tests/bit/stress that is `test-stress-exclusive` only (test-stress-batch
# is DELIBERATELY EXCLUDED, #3319, same reason and same measurement as the
# `runtime` bucket below: #3309 measured it standalone at 11m0s, over the
# subagent Bash tool's 600s ceiling on its own, because
# tests/bit/stress/stress.bit's main loop runs checkProgram() serially with
# no concurrency available — no batching win, independent of which bucket
# triggers it). NOT the redundant unpartitioned `test-stress` either, which
# runs the identical corpus a third time and is deliberately excluded from
# the `runtime` bucket below for the same reason (gates.bit's comment on
# `test-stress` is itself stale on this point — it was written before that
# bucket was changed from `test-stress` to the split pair in cc574965).
# `assert_dirgates_current`, defined and called right after this function,
# PROBES this exact function for every directory-target path gates.bit
# registers, rather than checking gates.bit against a second hardcoded list —
# a separate list is the same bug this ticket exists to fix, one level up: a
# maintainer told "add an arm" could instead edit the second list, leaving
# the real case arm missing and the guard green. Probing means the only way
# to turn the guard green is to make this function actually resolve the
# path — it only requires a NON-EMPTY result per directory, not the full set
# of gates.bit's registered gates, so dropping test-stress-batch here does
# not trip it (test-stress-exclusive alone keeps the probe non-empty).
#
# This also closes a gap the `runtime` bucket's #3309 fix did not: before
# this change, a diff touching BOTH runtime/** and tests/bit/stress/** (or
# tests/stress/**) resolved to bucket `runtime` (bucket_count counts only
# the five concrete areas, not testsbit) and then the "riding alongside"
# union below (search `has_testsbit` after the case statement) added
# test-stress-batch straight back into runtime's BUILD_STEPS from
# testsbit_steps, since gates_for_file() still emitted it for the stress
# paths. Excluding it here, at the source, fixes both the `testsbit`
# bucket directly and this union path in one change.
gates_for_file() {
  case "$1" in
    tests/bit/checkercases/*) printf 'test-checker-diag\n'; return 0 ;;
    tests/bit/parsercases/*) printf 'test-parser\n'; return 0 ;;
    tests/imports/*) printf 'test-imports-bit\n'; return 0 ;;
    tests/bit/objread/*)
      # No gate of its own: a shared Mach-O/ELF relocation reader (#2877)
      # reached only by relative `import { ... } from "../objread"` from two
      # harnesses. That relationship lives in Bit `import` statements, not in
      # gates.bit's `runArgs()` text, so it cannot be derived and is named
      # here by hand — and `assert_dirgates_current` below cannot check it
      # either, for the same reason: `tests/bit/objread` has no `runArgs()`
      # entry anywhere in gates.bit, so it never appears in the list that
      # guard probes.
      printf 'test-stwwiring\ntest-rootpins\n'
      return 0
      ;;
    tests/bit/childrun/*)
      # Same shape as tests/bit/objread/* just above: a shared bounded-
      # child-process harness (#2902) with no main() and no gate of its own,
      # reached only by relative `import { ... } from "../childrun"` — here
      # from exactly two harnesses (verified: `grep -rn 'from "\.\./childrun"'
      # tests/bit/` matches only tests/bit/rootpins/rootpins.bit:150 and
      # tests/bit/stwwiring/stwwiring.bit:136; tests/bit/objread/objread.bit
      # only mentions "childrun" in prose comments, not an import). That
      # relationship lives in Bit `import` statements, not in gates.bit's
      # `runArgs()` text, so it cannot be derived and is named here by hand —
      # and `assert_dirgates_current` below cannot check it either, for the
      # same reason: `tests/bit/childrun` has no `runArgs()` entry anywhere
      # in gates.bit, so it never appears in the list that guard probes.
      printf 'test-stwwiring\ntest-rootpins\n'
      return 0
      ;;
    tests/bit/docsrunner/*)
      # Same shape as tests/bit/objread/* and tests/bit/childrun/* above: no
      # gate of its own — #2969 split tests/bit/docs.bit's batch-runner into a
      # sibling directory, reached only by relative
      # `import { ... } from "./docsrunner"` from exactly one harness
      # (verified: `grep -rln 'from "\./docsrunner"\|from "\.\./docsrunner"'
      # tests/bit/*.bit tests/bit/*/*.bit` matches only tests/bit/docs.bit).
      # That relationship lives in a Bit `import` statement, not in gates.bit's
      # `runArgs()` text, so it cannot be derived and is named here by hand —
      # and `assert_dirgates_current` below cannot check it either, for the
      # same reason: `tests/bit/docsrunner` has no `runArgs()` entry anywhere
      # in gates.bit, so it never appears in the list that guard probes.
      # (#2975, folded into #2962's audit: a split that adds a sibling
      # directory silently narrows a gate's mapping the same way a bucket
      # omission silently narrows a bucket's.)
      printf 'test-docs\n'
      return 0
      ;;
    tests/stress/*)
      # A different top-level directory from the harness that reads it
      # (tests/bit/stress/, matched by the `tests/bit/stress/*)` arm just
      # below to the same gate): this is the corpus itself —
      # tests/bit/stress/stress.bit:359-376 defaults to `root + "/tests/stress"`
      # (root = BIT_STRESSGATE_ROOT, defaulting to ".") — so no
      # `runArgs("tests/stress")` entry exists anywhere in gates.bit (only
      # `runArgs("tests/bit/stress")`, for the harness), and this relationship
      # cannot be derived and is named here by hand, same shape as
      # tests/bit/objread/*, tests/bit/childrun/*, and tests/bit/docsrunner/*
      # above. `assert_dirgates_current` below cannot check it either, for the
      # same reason: `tests/stress` has no `runArgs()` entry anywhere in
      # gates.bit, so it never appears in the list that guard probes. (#2977)
      # test-stress-batch deliberately excluded — see the header comment
      # above `gates_for_file()` (#3319/#3309).
      printf 'test-stress-exclusive\n'
      return 0
      ;;
    tests/bit/abimembers/*) printf 'test-abimembers\n'; return 0 ;;
    tests/bit/benchgate/*) printf 'test-benchgate\n'; return 0 ;;
    tests/bit/clicmd/*) printf 'test-clicmd\n'; return 0 ;;
    tests/bit/pollfree/*) printf 'test-pollfree\n'; return 0 ;;
    tests/bit/rootabi/*) printf 'test-rootabi\n'; return 0 ;;
    tests/bit/rootpins/*) printf 'test-rootpins\n'; return 0 ;;
    tests/bit/spec/*) printf 'test-spec\n'; return 0 ;;
    # test-stress-batch deliberately excluded — see the header comment above
    # gates_for_file() (#3319/#3309).
    tests/bit/stress/*) printf 'test-stress-exclusive\n'; return 0 ;;
    tests/bit/stwwiring/*) printf 'test-stwwiring\n'; return 0 ;;
    tests/bit/testtimeout/*) printf 'test-timeout\n'; return 0 ;;
    # #3039. Not `runArgs()`-registered — it is a plain data file the
    # harness reads at runtime, not Bit source — so the generic grep below
    # can never find it; named by hand, same shape as tests/bit/checkercases/*.
    tests/bit/releasesurface.allowlist) printf 'test-release-surface\n'; return 0 ;;
  esac
  # Excludes any extracted name containing a literal `${` — that is a
  # per-instance template (e.g. tools/build/gates.bit's `packageGates()`
  # loop emitting `Gate{name: "test-package-${p}", ...}` inside `for p of
  # ...`), only meaningful once Bit interpolates it at runtime inside its
  # own generator, never a literal invocable step name on its own. The
  # plain-text grep above cannot tell a template apart from a real gate
  # whose `runArgs()` argument happens to match, so both come back; without
  # this filter a diff touching tests/bit/packagesgate.bit reports the
  # un-interpolated template as a build step, which the STALE check below
  # correctly (but unhelpfully) rejects, making the whole scoped gate exit 2
  # and run nothing (#3496).
  grep -F "runArgs(\"$1\")" tools/build/gates.bit 2>/dev/null |
    sed -n 's/.*Gate{name: "\([^"]*\)".*/\1/p' |
    grep -vF '${' || true
}

# Fails loudly, once, on every real invocation — before any file is
# classified into a bucket, and regardless of whether this diff touches
# tests/bit/** at all — if gates.bit registers a directory-target gate that
# gates_for_file() above cannot actually resolve a file inside of (#2903).
# PROBES THE MAPPER ITSELF: builds the directory list straight from
# gates.bit (every `runArgs("tests/bit/<dir>")` with no `.bit` suffix, same
# extraction gates_for_file()'s own case arms are hand-matched against), then
# calls `gates_for_file "<dir>/probe.bit"` for each and fails if any comes
# back empty. That is the whole point: nothing here is compared against a
# second list a maintainer could "fix" by editing the wrong thing. The only
# way to make this pass is to add a case arm that actually makes
# gates_for_file() resolve the directory — which is the fix the failure
# message asks for and the only fix that is possible.
#
# tests/bit/objread and tests/bit/childrun are out of scope for this loop,
# correctly and by construction: both have zero `runArgs()` entries anywhere
# in gates.bit (verified: `grep -n 'objread\|childrun' tools/build/gates.bit`
# is empty), so neither ever appears in `dirs` below. Each is a hand-
# maintained exception inside gates_for_file() (see those case arms above)
# that no automated check can cover, because the two-harness relationship
# each encodes lives only in Bit `import` statements, not in gates.bit's
# text.
assert_dirgates_current() {
  local dirs dir probe result
  dirs="$(grep -oE 'runArgs\("tests/bit/[^"]+"\)' tools/build/gates.bit |
    sed -E 's/runArgs\("(.*)"\)/\1/' | sort -u)"
  for dir in ${dirs}; do
    case "${dir}" in
      *.bit) continue ;;
    esac
    probe="${dir}/probe.bit"
    result="$(gates_for_file "${probe}")"
    if [ -z "${result}" ]; then
      echo "gate: tools/build/gates.bit registers directory-target gate \"${dir}\" but gates_for_file() (scripts/gate.sh) cannot resolve a file inside it (probed \"${probe}\")" >&2
      echo "gate: add a case arm to gates_for_file() that matches \"${dir}/*\", or files inside it will silently force bucket 'full'" >&2
      exit 2
    fi
  done
}
assert_dirgates_current

# Space-joined, de-duplicated union of `gates_for_file` over every path in
# space-separated `$1`. Prints "" the moment ANY path fails to map to a gate —
# a partial guess is worse than `full`, so one unmapped file poisons the set.
testsbit_steps_for() {
  local files="$1" out="" g gg f
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
  # test-filesize (#2962) scans EVERY .bit file recursively under tests/bit/
  # (tests/bit/filesize.bit's own stated scope: "anywhere under tests/bit/,
  # RECURSIVELY"), not just its own harness file (tests/bit/filesize.bit,
  # which the loop above already maps via the plain runArgs() grep). So any
  # tests/bit/** file can flip its verdict and must run it too — added here
  # rather than inside gates_for_file() itself so assert_dirgates_current()
  # above keeps probing the UNMODIFIED per-file mapping: folding this into
  # gates_for_file() would make every probe return non-empty regardless of
  # whether a real case arm exists, silently defeating that guard.
  # tests/imports/** is a different tree filesize.bit never walks, so it is
  # excluded here — this loop only ever reaches this point once every file in
  # `files` mapped successfully (the empty-return above already covers a
  # partial/unmapped set), so it is safe to unconditionally add.
  for f in ${files}; do
    case "${f}" in
      tests/bit/*)
        case " ${out} " in
          *" test-filesize "*) ;;
          *) out="${out:+${out} }test-filesize" ;;
        esac
        ;;
    esac
  done
  # test-lint-filelines (#3128) scans tests/bit/, tests/imports/, and
  # tests/stress/ too — tests/bit/lintfilelines.bit's own dirs list is
  # ["compiler", "runtime", "stdlib", "tests/stress", "examples", "tests/bit",
  # "tests/imports"], not just compiler/runtime/stdlib. Same shape as the
  # test-filesize loop just above: added here rather than inside
  # gates_for_file() so assert_dirgates_current() keeps probing the
  # UNMODIFIED per-file mapping, and only after the loop above has already
  # proven every file in `files` mapped successfully.
  for f in ${files}; do
    case "${f}" in
      tests/bit/*|tests/imports/*|tests/stress/*)
        case " ${out} " in
          *" test-lint-filelines "*) ;;
          *) out="${out:+${out} }test-lint-filelines" ;;
        esac
        ;;
    esac
  done
  printf '%s' "${out}"
}

# Trims a class-literal-shaped diff hunk `$1` (one field's worth of added
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

# THIRD NARROW EXCEPTION (#3055), same shape as `is_additive_registration`
# just above: true only when every docs/**/*.md file in `docs_files` (a
# space-separated list, populated by the classification loop below) is
# either docs/stdlib/README.md, which test-stdlib-docs does not read as a
# per-module page and so carries no gate of its own, or docs/stdlib/<mod>.md
# for a <mod> that also has a stdlib/<mod>/** change in `stdlib_files` (same
# loop). Called only when bucket_count already says stdlib and docs are the
# only two of the seven areas touched — callers still must confirm that,
# this function does not repeat it.
stdlib_docs_pairing_ok() {
  local f mod
  for f in ${docs_files}; do
    case "${f}" in
      docs/stdlib/README.md) continue ;;
      docs/stdlib/*.md)
        mod="${f#docs/stdlib/}"
        mod="${mod%.md}"
        case " ${stdlib_files} " in
          *" stdlib/${mod}/"*) continue ;;
          *) return 1 ;;
        esac
        ;;
      *) return 1 ;;
    esac
  done
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
      docs_files="${docs_files:+${docs_files} }${f}"
      ;;
    # spec/SPEC.md compiles nothing, but tests/bit/spec/ (#2758's
    # test-spec) DOES read it — a grammar-consistency check, not prose with no
    # gate — so it gets a REAL bucket too (#2962), matched ahead of the
    # `spec/*` no-gate arm below the same way docs/*.md is matched ahead of
    # nothing-reads-this prose. spec/LINT.md and every other spec/* path still
    # fall through to that arm unchanged.
    spec/SPEC.md)
      has_spec=1
      if [ -n "${spec_list}" ]; then
        spec_list="${spec_list}, ${f}"
      else
        spec_list="${f}"
      fi
      ;;
    # These paths are pure documentation that no gate reads: runtime/**/*.md
    # (the runtime CODE bucket below is for runtime/*.bit etc, not prose),
    # spec/* other than SPEC.md (LINT.md and any future sibling — checked by
    # no automated gate), bench/**/*.md (bench/**/*.bit and bench/run.sh still
    # fall through to `full`, unproven output-irrelevant), and the three
    # standalone READMEs nothing greps.
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
    stdlib/*)
      has_stdlib=1
      stdlib_files="${stdlib_files:+${stdlib_files} }${f}"
      ;;
    # First-party packages (#3271) — a leaf by design (bitlang-ws/CLAUDE.md,
    # "First-party packages"): nothing in the other seven areas ever imports
    # anything under pkg/, so a pkg/**-only diff can only ever need this
    # bucket's own steps.
    pkg/*) has_pkg=1 ;;
    # tests/imports/** joins tests/bit/** here (#2825), and tests/stress/**
    # joins both (#2977): all three are fixture-only paths whose gate is known
    # by name, never by path prefix, so they share has_testsbit/testsbit_list
    # end to end — see gates_for_file() above and the comment ahead of
    # testsbit_steps below.
    tests/bit/*|tests/imports/*|tests/stress/*)
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
if [ "${has_pkg}" -eq 1 ]; then
  if [ -n "${touched_list}" ]; then touched_list="${touched_list}, pkg"; else touched_list="pkg"; fi
fi
if [ "${has_docs}" -eq 1 ]; then
  if [ -n "${touched_list}" ]; then touched_list="${touched_list}, docs"; else touched_list="docs"; fi
fi
if [ "${has_spec}" -eq 1 ]; then
  if [ -n "${touched_list}" ]; then touched_list="${touched_list}, spec"; else touched_list="spec"; fi
fi

# has_noop is deliberately excluded here — see its case arm above.
bucket_count=$((has_selfhost + has_runtime + has_testcases + has_examples + has_stdlib + has_pkg + has_docs + has_spec))

# Computed ONCE, ahead of bucket selection, regardless of whether one of the
# five areas also fired (#2510). Two consequences fall out of computing it
# here rather than only inside the old `has_testsbit` elif branch:
#   - an UNMAPPED tests/bit/**, tests/imports/**, or tests/stress/** file must
#     force `full` even when it rides alongside a bucket, exactly like it
#     already did when tests/bit/** was the only change — so
#     `testsbit_unmapped` is checked ahead of every concrete bucket below, not
#     after all five have had a chance to win.
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
  REASON="touches path(s) outside the scoped buckets: ${other_list}"
elif [ "${bucket_count}" -eq 2 ] && [ "${has_stdlib}" -eq 1 ] && [ "${has_docs}" -eq 1 ] &&
  [ "${testsbit_unmapped}" -eq 0 ] && stdlib_docs_pairing_ok; then
  # THIRD NARROW EXCEPTION (#3055) — see the header comment block above and
  # stdlib_docs_pairing_ok() for what this requires. Guarded by
  # testsbit_unmapped here (rather than only in the elif below) so an
  # unmapped tests/bit/** file riding alongside stdlib+docs still forces
  # `full` exactly as it did before this exception existed.
  BUCKET="stdlibdocs"
  REASON="only stdlib/** and its paired docs/stdlib/**.md changed (${touched_list})"
elif [ "${bucket_count}" -gt 1 ]; then
  BUCKET="full"
  REASON="spans more than one bucket: ${touched_list}"
elif [ "${testsbit_unmapped}" -eq 1 ]; then
  BUCKET="full"
  REASON="tests/bit/**, tests/imports/**, or tests/stress/** changed but at least one file could not be mapped to a gate by name — falling through to full"
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
elif [ "${has_pkg}" -eq 1 ]; then
  BUCKET="pkg"
  REASON="only pkg/** changed"
elif [ "${has_docs}" -eq 1 ]; then
  BUCKET="docs"
  REASON="only docs/**/*.md changed (${docs_list})"
elif [ "${has_spec}" -eq 1 ]; then
  BUCKET="spec"
  REASON="only spec/SPEC.md changed"
elif [ "${has_testsbit}" -eq 1 ]; then
  BUCKET="testsbit"
  REASON="only tests/bit/**, tests/imports/**, or tests/stress/** changed (gate(s): ${testsbit_steps})"
elif [ "${has_noop}" -eq 1 ]; then
  BUCKET="noop"
  REASON="matched only path(s) known to be pure documentation with no gate: ${noop_list}"
else
  # Nothing in the five buckets, docs/**/*.md, spec/SPEC.md, tests/bit/**,
  # tests/imports/**, or a known no-gate prose path changed, has_other is 0,
  # and CHANGED is non-empty — the only
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
UNDECIDED_SEEN=0

# The only two constituents whose OWN documented exit 2 means "could not
# decide" rather than "usage/internal error" — see each script's own header
# comment (selfhost-diffcheck.sh: "2  could not decide: a file timed out and
# was never compared", selfhost-fixpoint.sh: "a non-zero build exits 2 (a
# broken gate) rather than 1 (a broken compiler)", including its explicit
# `exit 2` for "FIXED POINT UNDECIDED", #2980). No other constituent's exit 2
# is given this meaning — a stale-step exit 2 from `./make` or from the
# --x64/--arm64 wrappers must stay FAILED, unchanged.
is_undecided_script() {
  case "$1" in
    scripts/selfhost-diffcheck.sh|scripts/selfhost-fixpoint.sh) return 0 ;;
    *) return 1 ;;
  esac
}

run_step() {
  echo "gate: + $*"
  local rc=0
  "$@" || rc=$?
  if [ "${rc}" -eq 0 ]; then
    return 0
  fi
  # Only "bash <script>" invocations (PRE_SCRIPTS/POST_SCRIPTS) can match —
  # the ./make and x64/arm64-wrapper invocations below have $1 = "./make" or
  # "env", so they fall straight through to FAILED regardless of $2.
  if [ "${rc}" -eq 2 ] && [ "$1" = "bash" ] && is_undecided_script "${2:-}"; then
    echo "gate: UNDECIDED: $*" >&2
    UNDECIDED_SEEN=1
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

# A real FAILED constituent always wins, even alongside an undecided one — an
# inconclusive sibling must never downgrade a proven divergence (#2991).
if [ "${OVERALL_RC}" -ne 0 ]; then
  echo "GATE_RESULT=FAIL"
  exit "${OVERALL_RC}"
fi
if [ "${UNDECIDED_SEEN}" -eq 1 ]; then
  echo "GATE_RESULT=UNDECIDED"
  exit 4
fi
echo "GATE_RESULT=PASS"
exit 0
