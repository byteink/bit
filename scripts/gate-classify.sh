#!/usr/bin/env bash
# scripts/gate-classify.sh — the diff-classification loop behind
# scripts/gate.sh's bucket selection. Split out of scripts/gate.sh by #4614 as
# a PURE MOVE: the has_*/`*_list` accumulator block and the `while IFS= read
# -r f; do case ... esac done <<EOF ${CHANGED} EOF` loop that fills it are
# byte-identical below, only relocated and wrapped in classify_changed_files().
#
# WHY THIS IS A SPLIT AND NOT A NEW SCRIPT. This repo's standing rule is "do
# not ADD a script to scripts/ — extend an existing one or add a Gate{}".
# Nothing new is added here: scripts/gate.sh is still the one and only entry
# point, it sources this file at the exact point the block used to sit and
# calls classify_changed_files() there, and every caller keeps invoking
# scripts/gate.sh unchanged. There is no path by which this file is invoked on
# its own — it defines one function and runs nothing at source time. That is
# the same shape #3480, #4234, #4454 and #4610 already used carving
# gate-filemap.sh, gate-envscope.sh and gate-diffclass.sh out of files that had
# run out of room under the 800-line hard-zero shell ceiling
# (_tests_/bit/shellsize.bit, #4232).
#
# WHY THIS BLOCK AND NOT ANOTHER. gate.sh was at 800/800 with 406 of those
# lines being comment, so the next `case` arm could only be bought by cutting
# reasoning — #4556 already paid that price once, reflowing the comment above
# its arm to 110 columns to free the two lines its arm needed. Adding an arm is
# routine maintenance (#4426, #4441, #4447, #4556 in one month). This loop is
# the largest self-contained block in the file and the one that grows: it
# answers "which bucket does each changed path belong to", where the rest of
# gate.sh decides what to RUN for the resulting bucket.
#
# THE VARIABLES ARE GLOBALS AND STAY GLOBALS. classify_changed_files() declares
# nothing `local`, so every has_*, *_list, docs_files and stdlib_files it sets
# is read by gate.sh's bucket_count arithmetic afterwards exactly as before;
# bash dynamic scope does not care which file assigns them. It reads ${CHANGED}
# (set by gate.sh) and calls gates_for_file() and is_additive_registration()
# from scripts/gate-filemap.sh / scripts/gate-diffclass.sh, both already sourced
# by gate.sh above the call site — the same cross-file arrangement #4610 left.
#
# THE BODY IS NOT RE-INDENTED, DELIBERATELY. Wrapping it in a function without
# shifting it two columns keeps the move provable as a line multiset — `comm
# -23` of the old gate.sh against the new pair is EMPTY, so nothing was dropped
# or silently reflowed. A pure move in this repo once deleted 205 blank lines
# and passed the full suite; that check is worth more than the indentation.
#
# Sourced by scripts/gate.sh; do not source it directly, and do not execute it.
# Paths below are relative to the repo root, gate.sh's convention.

classify_changed_files() {
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

# gates_for_file(), assert_dirgates_current() and testsbit_steps_for() are
# defined in scripts/gate-filemap.sh. hunk_is_safe(),
# is_additive_registration() and stdlib_docs_pairing_ok() are in
# scripts/gate-diffclass.sh (#4610). Both are sourced above (moved out of gate.sh
# by #3257/#4234 so --mark-green/--resume can use those helpers before this point
# too, and so each file has headroom under its 800-line ceiling); see their headers.

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
    # spec/FMT.md IS read by test-fmt-citations (wired into selfhost, #4453).
    spec/FMT.md) has_selfhost=1 ;;
    # These paths are pure documentation that no gate reads: runtime/**/*.md
    # (the runtime CODE bucket below is for runtime/*.bit etc, not prose),
    # spec/* other than SPEC.md and FMT.md (LINT.md and any future sibling —
    # checked by no automated gate), bench/**/*.md (bench/**/*.bit and
    # bench/run.sh still fall through to `full`, unproven output-irrelevant),
    # and the three standalone READMEs nothing greps.
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
    # _tests_/imports/** joins _tests_/bit/** here (#2825), _tests_/stress/** joins both (#2977), and
    # tools/build/complexity-debt.txt joins all three (#4556: the E0204 ratchet's DATA file, read only by
    # test-lint-complexity — every OTHER tools/build/** path still falls to `*)` below and forces full):
    # each is a path whose gate is known BY NAME, never by path prefix, so they share has_testsbit/
    # testsbit_list end to end — see gates_for_file() above and the comment ahead of testsbit_steps below.
    _tests_/bit/*|_tests_/imports/*|_tests_/stress/*|tools/build/complexity-debt.txt)
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
}
