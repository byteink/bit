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
# See exit code 3 below for how to actually verify a diff that lands here.
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
#   scripts/gate.sh --mark-green       # after a real full `./make test` pass
#                                      # (or --full), record HEAD as the last
#                                      # fully-green commit (#3257). Verifies
#                                      # via #3256's own rc stamps — refuses
#                                      # (exit 3) unless every gate `./make
#                                      # test` runs shows an rc=0 stamped by
#                                      # ONE shared flush; never a bare claim.
#                                      # Also refuses on a dirty tree (exit 2).
#   scripts/gate.sh --resume           # scope against the last-green commit
#                                      # instead of `main`, re-running only
#                                      # what could have broken since — for
#                                      # re-proving a fix after a partial
#                                      # `./make test` failure (#3257). No
#                                      # baseline, a stale/foreign baseline, or
#                                      # an unmappable diff all exit 3
#                                      # (FULL_REQUIRED) like every other
#                                      # "cannot scope" case here — never a
#                                      # silent fallback, never a false pass.
#                                      # A gate registered since the baseline
#                                      # is always force-run.
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
# _tests_/cases/, examples/, stdlib/, pkg/, docs/**/*.md, or spec/SPEC.md runs
# only that area's minimal steps. A change touching any OTHER path (anything
# unlisted below), or spanning MORE THAN ONE of those eight areas, is
# ambiguous and always runs the full `./make test` — never a partial skip —
# EXCEPT the narrow stdlib+docs pairing bucket `stdlibdocs` (#3055, see the
# "THREE NARROW EXCEPTIONS" block below).
#
# `pkg/` IS THE ONE BUCKET WHOSE STEP LIST IS NOT ARGV/ENV INTERSECTION
# (#3271, epic: first-party packages under pkg/<name>/). `test-packages`'s own
# argv is `runArgs("_tests_/bit/packagesgate.bit")` — no `pkg/` path anywhere in
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
# run `test-lint-filelines` (_tests_/bit/lintfilelines.bit's own `dirs =
# ["compiler", "runtime", "stdlib", "_tests_/stress", "examples", "_tests_/bit",
# "_tests_/imports"]` — seven directories, not three; #3128 wired up the fourth
# bucket, `examples`, plus the three directories that never resolve to a
# concrete bucket at all: `_tests_/bit/**`, `_tests_/imports/**`, and
# `_tests_/stress/**` each run it too, added to the `testsbit_steps_for()`
# special-case block next to test-filesize below rather than to a bucket,
# since all three route through the shared `testsbit` bucket instead of one
# of the five concrete areas); `runtime` also runs `test-lint-runtime` (its own
# comment in gates.bit: "points `bit lint` at `${BIT_REPO}/runtime`");
# `selfhost` also runs `test-selfhostcheck` (argv literally
# `["check", "${repoRoot()}/compiler"]`); `docs` also runs `test-stdlib-docs`
# (BIT_DOCS_ROOT — it fails on a `docs/stdlib/<mod>.md` missing a heading, same
# as it does on an undocumented stdlib export); `testcases` also runs
# `test-fuzz` (BIT_FUZZ_CASES=`${repoRoot()}/_tests_/cases` — it mutates that
# real corpus, not a synthetic one); every _tests_/bit/** file also runs
# `test-filesize` (_tests_/bit/filesize.bit's own stated scope: "anywhere under
# _tests_/bit/, RECURSIVELY", not just its own harness file).
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
# scripts/** IS DELIBERATELY IN THAT "any other" set (#2745), not a gap: a
# scoped bucket was considered and rejected — this file's 800-line ceiling
# and the assert_full_is_superset() invariant (gate-buildsteps.sh:239-272)
# both block it. Run `bash -n <script>` plus the one changed differential
# directly instead of `--full`; see gate-filemap.sh's header for the full
# reasoning.
#
# FOUR NARROW EXCEPTIONS (#2435, #3055, #4136), because registering a gate is
# mandatory in this repo and otherwise forces `full` on every single ticket
# that adds one:
#   - _tests_/bit/**, _tests_/imports/**, and _tests_/stress/** (#2825 added the
#     second — a new fixture directory under _tests_/imports/ used to fall
#     through to the catch-all below and force `full` on its own; #2977 added
#     the third — _tests_/stress/ is the corpus _tests_/bit/stress/stress.bit
#     reads by default, root + "/_tests_/stress", but is a different top-level
#     directory from its harness and so was never mapped at all) join
#     whichever of the five areas also changed, instead of forcing `full` on
#     their own: their own mapped gate(s) run IN ADDITION to that area's steps
#     (#2510 — a five-area bucket used to silently replace the file's own gate
#     instead of adding to it). If _tests_/bit/**/_tests_/imports/**/_tests_/stress/**
#     is the ONLY thing that changed, the gates whose `Gate.argv` names each
#     changed file (or, for _tests_/stress/**, the hand-named exception in
#     `gates_for_file()` below) run — nothing more — or `full` if any changed
#     file cannot be mapped that way, whether or not one of the five areas
#     also fired.
#   - tools/build/defs.bit, tools/build/gates.bit and tools/build/gatestable2.bit
#     (gates.bit's Gate{} table, split by #4169) are the same case only for a
#     PURE new `Step{}`/`Gate{}` registration — no edited entry, no edited
#     function body (see `is_additive_registration` below). Any other
#     tools/build/** file, or a non-additive change to these three, still
#     forces `full` — that code is the driver every step runs under.
#   - stdlib/** paired ONLY with its own mandatory docs/stdlib/**.md page
#     (#3055): _tests_/bit/stdlibdocs.bit fails the build on any exported
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
#   - spec/SPEC.md paired with exactly ONE other bucket (#4136): spec/SPEC.md's
#     own gate (test-spec, #2758) is a single self-contained grammar check
#     with no PRE/POST script and no cross-file consistency requirement
#     (unlike the stdlib+docs pairing just above, which needs
#     stdlib_docs_pairing_ok's per-module check) — pairing it with ANY other
#     single bucket can never make that bucket's own steps insufficient, so
#     unioning in test-spec is unconditionally safe. Resolves to the OTHER
#     bucket's own name (not a new "<x>spec" bucket) with test-spec unioned
#     into its BUILD_STEPS by union_spec_steps() (scripts/gate-buildsteps.sh)
#     — the same shape testsbit already uses to ride alongside a bucket
#     without owning one (see the first exception above). Only fires when
#     spec is paired with exactly one of the other seven areas (bucket_count
#     == 2, computed below): spec alongside an already-multi-area diff —
#     including stdlibdocs, which is itself two areas — still forces `full`,
#     since that is genuinely more than "exactly two buckets".
#
# selfhost and examples pull in a non-`./make` diff script
# (selfhost-diffcheck.sh/selfhost-fixpoint.sh, selfhost-diffexamples.sh).
# Under --x64/--arm64 only the `./make` portion runs remotely; those diff
# scripts always run locally, because they need both compilers already built
# on this machine, not merely the remote target's build steps.
set -euo pipefail

cd "$(dirname "$0")/.."

FULL=0
RESUME=0
MARK_GREEN=0
TARGET=local
for arg in "$@"; do
  case "$arg" in
    --full) FULL=1 ;;
    --resume) RESUME=1 ;;
    --mark-green) MARK_GREEN=1 ;;
    --x64) TARGET=x64 ;;
    --arm64) TARGET=arm64 ;;
    *)
      echo "gate: unknown flag '${arg}' (expected --full, --resume, --mark-green, --x64, or --arm64)" >&2
      exit 2
      ;;
  esac
done

if [ "${RESUME}" -eq 1 ] && [ "${FULL}" -eq 1 ]; then
  echo "gate: --resume and --full are mutually exclusive" >&2
  exit 2
fi
if [ "${MARK_GREEN}" -eq 1 ] && { [ "${FULL}" -eq 1 ] || [ "${RESUME}" -eq 1 ]; }; then
  echo "gate: --mark-green is exclusive of --full/--resume" >&2
  exit 2
fi

# File-to-gate mapping AND the last-green-baseline helpers (#3257) are a
# separate sourced module (#3480) — see scripts/gate-filemap.sh's own header.
# Sourced here, ahead of RANGE, so --mark-green/--resume below can use it
# before this script's own diff-scoping machinery needs it too.
# shellcheck source=scripts/gate-filemap.sh
. scripts/gate-filemap.sh

if [ "${MARK_GREEN}" -eq 1 ]; then
  gate_do_mark_green
fi

if [ "${RESUME}" -eq 1 ]; then
  if [ -n "${RANGE:-}" ]; then
    echo "gate: --resume computes its own scoping range from the last-green baseline; do not also set RANGE" >&2
    exit 2
  fi
  gate_resume_set_range
fi

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
# _tests_/cases/*.bit is exactly the change that must select a bucket, and no form
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
has_windows=0
other_list=""
touched_list=""
testsbit_list=""
docs_list=""
spec_list=""
noop_list=""
windows_list=""
# Space-separated (never comma-joined, unlike docs_list/other_list above,
# which exist only for human-readable REASON text): stdlib_docs_pairing_ok
# above word-splits these, so a comma in the string would corrupt the match.
docs_files=""
stdlib_files=""

# gates_for_file(), assert_dirgates_current(), testsbit_steps_for(),
# hunk_is_safe(), is_additive_registration() and stdlib_docs_pairing_ok() are
# all defined in scripts/gate-filemap.sh, already sourced above (moved there
# by #3257 and #4234 so --mark-green/--resume can use that module's other
# helpers before this point too, and so this file has headroom under its own
# 800-line ceiling); see that file's header for what each does.

while IFS= read -r f; do
  case "${f}" in
    # PROSE, CLASSIFIED BY FILE TYPE, NOT JUST PATH PREFIX (#2801). Placed
    # ahead of the five-bucket matches below because e.g. `runtime/*.md` is a
    # more specific case of `runtime/*` and must win it: a markdown file
    # cannot change what any gate compiles or runs.
    #
    # docs/**/*.md compiles the code fences inside it (_tests_/bit/docs.bit),
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
    # spec/SPEC.md compiles nothing, but _tests_/bit/spec/ (#2758's
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
    # Deliberately NOT added to has_other or bucket_count — has_noop and
    # noop_list ARE set below, but mixed with a real bucket the noop path
    # must be silently ignored, never force `full` and never downgrade the
    # real bucket (constraint in #2801).
    runtime/*.md|spec/*|bench/*.md|README.md|CONTRIBUTING.md|dist/README.md)
      has_noop=1
      if [ -n "${noop_list}" ]; then
        noop_list="${noop_list}, ${f}"
      else
        noop_list="${f}"
      fi
      ;;
    compiler/*) has_selfhost=1 ;;
    # A runtime/<pair>/windows/*.bit change ALSO sets has_windows, on top of
    # (never instead of) has_runtime=1 — the compiler can already cross-build
    # for x86_64-windows with no hardware (scripts/g2archive.sh), and #4294 had
    # to verify that by hand for lack of a gate here. This does not replace
    # test-windows-smoke (_tests_/bit/windowssmoke.bit), which needs the
    # reachable mustafa-desktop-win host and stays a manual
    # `./make test-windows-smoke` step — this is compile+link only, run below
    # via has_windows regardless of which bucket the diff resolves to (#4311).
    runtime/*/windows/*.bit)
      has_runtime=1
      has_windows=1
      windows_list="${windows_list:+${windows_list}, }${f}"
      ;;
    runtime/*) has_runtime=1 ;;
    _tests_/cases/*) has_testcases=1 ;;
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
    # _tests_/imports/** joins _tests_/bit/** here (#2825), and _tests_/stress/**
    # joins both (#2977): all three are fixture-only paths whose gate is known
    # by name, never by path prefix, so they share has_testsbit/testsbit_list
    # end to end — see gates_for_file() above and the comment ahead of
    # testsbit_steps below.
    _tests_/bit/*|_tests_/imports/*|_tests_/stress/*)
      # #4230: a DELETED path that was NEVER mapped to a gate needs no gate
      # rerun — there is nothing left on disk for any gate to read, so
      # removing it cannot change any gate's outcome. Existence on disk is
      # the correct test (not any one diff source's own status letter):
      # this script's own "the working tree is always included, on top of
      # the range" rule above already makes the working tree the final
      # word on what changed, and it applies here identically. A DELETED
      # path that DOES still resolve via gates_for_file() (e.g. one file
      # removed from a directory-mapped fixture dir, whose mapping is by
      # directory prefix, not by the individual file) is NOT exempted —
      # it falls through to the normal testsbit_list path below exactly as
      # before, so that gate still reruns.
      if [ ! -e "${f}" ] && [ -z "$(gates_for_file "${f}")" ]; then
        has_noop=1
        if [ -n "${noop_list}" ]; then
          noop_list="${noop_list}, ${f}"
        else
          noop_list="${f}"
        fi
      else
        has_testsbit=1
        if [ -n "${testsbit_list}" ]; then
          testsbit_list="${testsbit_list} ${f}"
        else
          testsbit_list="${f}"
        fi
      fi
      ;;
    tools/build/defs.bit|tools/build/gates.bit|tools/build/gatestable2.bit)
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
  if [ -n "${touched_list}" ]; then touched_list="${touched_list}, _tests_/cases"; else touched_list="_tests_/cases"; fi
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
#   - an UNMAPPED _tests_/bit/**, _tests_/imports/**, or _tests_/stress/** file must
#     force `full` even when it rides alongside a bucket, exactly like it
#     already did when _tests_/bit/** was the only change — so
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

# FOURTH NARROW EXCEPTION (#4136) — see the header comment block above.
# Computed here, ahead of bucket selection, the same way SPEC_PARTNER is the
# one OTHER area (of the seven non-spec ones) spec may safely pair with; empty
# unless bucket_count is exactly 2 with spec as one of the two, so it can
# never fire alongside stdlibdocs (already 2 areas on its own) or any wider
# diff. union_spec_steps() (scripts/gate-buildsteps.sh) reads this same
# global to union test-spec into whichever bucket SPEC_PARTNER names.
SPEC_PARTNER=""
if [ "${bucket_count}" -eq 2 ] && [ "${has_spec}" -eq 1 ]; then
  if [ "${has_selfhost}" -eq 1 ]; then SPEC_PARTNER="selfhost"
  elif [ "${has_runtime}" -eq 1 ]; then SPEC_PARTNER="runtime"
  elif [ "${has_testcases}" -eq 1 ]; then SPEC_PARTNER="testcases"
  elif [ "${has_examples}" -eq 1 ]; then SPEC_PARTNER="examples"
  elif [ "${has_stdlib}" -eq 1 ]; then SPEC_PARTNER="stdlib"
  elif [ "${has_pkg}" -eq 1 ]; then SPEC_PARTNER="pkg"
  elif [ "${has_docs}" -eq 1 ]; then SPEC_PARTNER="docs"
  fi
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
  # unmapped _tests_/bit/** file riding alongside stdlib+docs still forces
  # `full` exactly as it did before this exception existed.
  BUCKET="stdlibdocs"
  REASON="only stdlib/** and its paired docs/stdlib/**.md changed (${touched_list})"
elif [ -n "${SPEC_PARTNER}" ] && [ "${testsbit_unmapped}" -eq 0 ]; then
  # FOURTH NARROW EXCEPTION (#4136) — see the header comment block and the
  # SPEC_PARTNER computation above. BUCKET stays the partner's own name (not
  # a new combined bucket) so bucket_scripts()/build_steps_for_bucket() need
  # no new case arms; union_spec_steps() below adds test-spec on top. Guarded
  # by testsbit_unmapped for the same reason the stdlibdocs exception above
  # is: an unmapped _tests_/bit/** file riding alongside must still force
  # `full`.
  BUCKET="${SPEC_PARTNER}"
  REASON="only ${SPEC_PARTNER}/** and spec/SPEC.md changed (${touched_list})"
elif [ "${bucket_count}" -gt 1 ]; then
  BUCKET="full"
  REASON="spans more than one bucket: ${touched_list}"
elif [ "${testsbit_unmapped}" -eq 1 ]; then
  BUCKET="full"
  REASON="_tests_/bit/**, _tests_/imports/**, or _tests_/stress/** changed but at least one file could not be mapped to a gate by name — falling through to full"
elif [ "${has_selfhost}" -eq 1 ]; then
  BUCKET="selfhost"
  REASON="only compiler/** changed"
elif [ "${has_runtime}" -eq 1 ]; then
  BUCKET="runtime"
  REASON="only runtime/** changed"
elif [ "${has_testcases}" -eq 1 ]; then
  BUCKET="testcases"
  REASON="only _tests_/cases/** changed"
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
  REASON="only _tests_/bit/**, _tests_/imports/**, or _tests_/stress/** changed (gate(s): ${testsbit_steps})"
elif [ "${has_noop}" -eq 1 ]; then
  BUCKET="noop"
  # Two kinds of entry land in noop_list: known no-gate prose (see the case
  # arm above _tests_/bit/**'s), and, since #4230, a deleted _tests_/bit/**,
  # _tests_/imports/**, or _tests_/stress/** path that was never mapped to a
  # gate either. The REASON text stays generic across both rather than
  # naming "documentation", which would be wrong for the second kind.
  REASON="matched only path(s) with no gate to run: ${noop_list}"
else
  # Nothing in the five buckets, docs/**/*.md, spec/SPEC.md, _tests_/bit/**,
  # _tests_/imports/**, or a known no-gate prose path changed, has_other is 0,
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

# Per-bucket step selection and validation is a separate sourced module
# (#3480) — bucket_scripts(), build_steps_for_bucket(), union_testsbit_steps()
# and assert_full_is_superset() all live in scripts/gate-buildsteps.sh; see
# its header comment for what each does. Pure move, wrapped into named
# functions: the call order below is exactly the order this code used to run
# inline. union_spec_steps() (#4136) is the one addition — same shape as
# union_testsbit_steps() just above it, folding SPEC_PARTNER's gate in on top
# of whichever bucket build_steps_for_bucket already selected.
# shellcheck source=scripts/gate-buildsteps.sh
. scripts/gate-buildsteps.sh

build_steps_for_bucket
union_testsbit_steps
union_spec_steps
if [ "${RESUME}" -eq 1 ]; then
  gate_resume_inject_new_gates
fi
assert_full_is_superset

bucket_scripts "${BUCKET}"
PRE_SCRIPTS="${BUCKET_PRE}"
POST_SCRIPTS="${BUCKET_POST}"

# STALE build-step validation (against `./make --list`) is
# validate_build_steps() in scripts/gate-buildsteps.sh, sourced above (#3480,
# pure move — see that function's own comment for the #1593/#1873 history).
validate_build_steps

echo "gate: bucket: ${BUCKET} (${REASON})"
echo "gate: plan:"
for s in ${PRE_SCRIPTS}; do echo "  bash ${s}"; done
case "${TARGET}" in
  local) echo "  ./make ${BUILD_STEPS[*]}" ;;
  x64) echo "  STEP=\"${BUILD_STEPS[*]}\" scripts/x64gate.sh   (remote, real x86_64 hardware)" ;;
  arm64) echo "  ARM64GATE_STEP=\"${BUILD_STEPS[*]}\" scripts/arm64gate.sh   (remote, native aarch64-linux)" ;;
esac
for s in ${POST_SCRIPTS}; do echo "  bash ${s}"; done
if [ "${has_windows}" -eq 1 ]; then
  echo "  bash scripts/g2archive.sh x86_64-windows <tmp.a>   (windows: ${windows_list})"
fi
if [ "${TARGET}" != "local" ]; then
  if [ -n "${PRE_SCRIPTS}${POST_SCRIPTS}" ] || [ "${has_windows}" -eq 1 ]; then
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

# #4311: a runtime/<pair>/windows/*.bit change also gets a compile+link-only
# cross-build check, on top of (never instead of) whatever bucket the diff
# already resolved to — the same "additive, not a bucket of its own" shape as
# union_testsbit_steps()/union_spec_steps() above, but for a raw script rather
# than a ./make step name, so it lives here rather than in BUILD_STEPS. Needs
# bit-out/bin/bit already built, exactly like the selfhost-diffruntime.sh POST
# script above under --x64/--arm64 (see the note printed above). Deliberately
# NOT _tests_/bit/windowssmoke.bit — that needs the reachable
# mustafa-desktop-win host and stays a manual `./make test-windows-smoke` step.
if [ "${has_windows}" -eq 1 ]; then
  WIN_SCRATCH="$(mktemp -d)"
  run_step scripts/g2archive.sh x86_64-windows "${WIN_SCRATCH}/libbitrt-windows-gate.a"
  rm -rf "${WIN_SCRATCH}"
fi

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
if [ "${RESUME}" -eq 1 ]; then
  gate_resume_report_push_ok
fi
echo "GATE_RESULT=PASS"
exit 0
