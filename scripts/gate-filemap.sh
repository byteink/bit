#!/usr/bin/env bash
# scripts/gate-filemap.sh — file-to-gate mapping subsystem for scripts/gate.sh
# (#3480). Extracted as a pure move: gates_for_file(), assert_dirgates_current()
# and testsbit_steps_for() are unchanged below, only relocated out of gate.sh
# to bring it back under the 800-line ceiling. Source this after `cd`-ing to
# the repo root — every path below (tools/build/gates.bit) is relative to it,
# matching gate.sh's own convention.
#
# gates_for_file() answers one question: given a changed file path, which
# gate(s) (by name, as registered in tools/build/gates.bit) does it belong to?
# assert_dirgates_current() self-checks that mapping is complete for every
# directory-target gate gates.bit registers, and runs immediately below —
# sourcing this file both defines the mapper and validates it in one step, so
# no caller can use gates_for_file() without that guard having already run.
# testsbit_steps_for() extends the single-file mapping to a whole file list,
# unioning in the two gates (test-filesize, test-lint-filelines) that scan
# tests/bit/**, tests/imports/**, or tests/stress/** recursively rather than
# per-file.
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
    # #3458 moved this from a single file (tests/bit/fmtcitations.bit) to a
    # directory module — its self-tests split into a sibling to stay under the
    # 800-line limit, the same shape as tests/bit/benchgate/* above.
    tests/bit/fmtcitations/*) printf 'test-fmt-citations\n'; return 0 ;;
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
