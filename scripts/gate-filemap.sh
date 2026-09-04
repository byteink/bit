#!/usr/bin/env bash
# scripts/gate-filemap.sh — file-to-gate mapping subsystem for scripts/gate.sh
# (#3480). Extracted as a pure move: gates_for_file(), assert_dirgates_current()
# and testsbit_steps_for() are unchanged below, only relocated out of gate.sh
# to bring it back under the 800-line ceiling. Source this after `cd`-ing to
# the repo root — every path below (tools/build/gates.bit) is relative to it,
# matching gate.sh's own convention.
#
# WHY scripts/** HAS NO BUCKET OF ITS OWN (#2745) — gate.sh's header points
# here rather than restating this, since gate.sh itself has no line budget
# left to spend on it.
#
# A scripts/**-only diff — most often the selfhost-diff*.sh differential
# family — falls to bucket `full` today, same as any other unmapped path
# (gate.sh's "any other path" paragraph above the THREE NARROW EXCEPTIONS
# block). Without --full that is a loud refusal (exit 3,
# GATE_RESULT=FULL_REQUIRED, #2872), not a run of the 18-18.5 minute
# `./make test` — the harm this ticket was originally filed against (an
# 18-25 min suite run hidden behind a routine shell edit) is already gone.
# What's left is only the inconvenience of no scoped, narrower-than-`full`
# check, and #2745 decided that inconvenience is not worth fixing, because
# both routes to a real bucket hit a wall that was checked, not assumed:
#
#   1. gate.sh sits at 797-799/800 lines, a hard ceiling (never raised, never
#      suppressed — spec/LINT.md's E0200). A bucket needs a has_scripts
#      declaration, a case arm, bucket_count wiring, an elif branch and
#      terminal handling, matching the eight buckets already above — on the
#      order of 25 lines even maximally delegated to this file, which this
#      file's own few lines of headroom cannot absorb without cutting
#      cross-referenced reasoning kept for exactly the reason this block
#      exists: so the next person does not have to re-derive it.
#   2. Wiring a bucket to actually RUN a differential (not just `bash -n` it)
#      collides with assert_full_is_superset() in
#      scripts/gate-buildsteps.sh:239-272 — an unconditional invariant that
#      any script named in a bucket's BUCKET_PRE/BUCKET_POST must also be in
#      `full`'s own script list (today: selfhost-diffcheck.sh,
#      selfhost-fixpoint.sh, selfhost-diffruntime.sh,
#      selfhost-diffexamples.sh — none of the diffdump family). It exists to
#      stop the #2084 class of bug, where escalating to the "safe" fallback
#      ran FEWER checks than the specific bucket would have. Naming e.g.
#      selfhost-diffast.sh in a new bucket without also adding it to `full`
#      fails this check before a single step runs; adding it to `full`
#      instead makes every --full/pre-push run pay for it. Separately,
#      selfhost-diffdump.sh (the shared driver behind six of the family's
#      files — diffast/difftokens/diffdiags/difftypes/diffir/diffiropt) takes
#      a `<name>` argument, and gate.sh's PRE/POST mechanism only runs a bare
#      `bash <path>` with no argument passing — so only those six
#      self-contained shims are even mechanically wireable this way, not the
#      rest of the family (diffdoc ~753s, diffcheck ~531s,
#      diffsafepoints ~437s among them, none of which is "narrower than
#      full" in any useful sense).
#
# Frequency was checked, not assumed idle: 81 commits touched
# scripts/selfhost-diff*.sh in the trailing 30 days (of this writing), and
# every one of those 81 touched only scripts/** paths — so this is a
# real, recurring cost, not a rare one, and still not worth the two walls
# above.
#
# WHAT TO RUN INSTEAD of `--full` for a scripts/**-only change: `bash -n
# <changed-script>` (catches a syntax error, which is most of what a bucket
# here would have bought), then run that one changed differential directly,
# e.g. `bash scripts/selfhost-diffast.sh`. That is strictly cheaper than
# anything a bucket could add, and it is what #3553's agent was already
# observed doing by hand.
#
# _tests_/testproj/** (#4153) is unmapped for the same reason, but it never
# reaches gates_for_file() at all — worth stating precisely, since that is
# the obvious wrong guess. gate.sh's own file-classification loop (the `case
# "${f}"` above its bucket_count arithmetic) has no arm for this path
# either: it is not `_tests_/bit/*`, `_tests_/imports/*`, or `_tests_/stress/*`
# (a different, sibling top-level directory under `_tests_/`), so it never
# sets has_testsbit and never calls testsbit_steps_for() / gates_for_file()
# — it falls straight into gate.sh's generic `*)` catch-all, same as
# scripts/** above, forcing bucket `full` with REASON "touches path(s)
# outside the scoped buckets".
#
# Its SOLE consumer is scripts/selfhost-difftests.sh —
# `PROJ=${1:-_tests_/testproj}` is a shell default, not a `runArgs()` literal
# gates.bit could register — and that script is itself only reached through
# `test-differentials`, a coreSteps() Step deliberately NOT a gateSteps()
# Gate (#2570, so `./make test` stays 18-20 min). gates_for_file() only maps
# to gateSteps()-registered gates by grepping `runArgs()`, so even if this
# path did reach it, there would be nothing to map it to.
#
# A dedicated bucket was rejected for the identical two reasons #2745 gives
# for scripts/** just above, both re-checked on this tree rather than
# assumed: (1) gate.sh sits at 799/800 lines, no room for a ninth bucket's
# ~25 lines of case arm, bucket_count wiring and terminal handling; and (2)
# wiring one to actually RUN scripts/selfhost-difftests.sh would collide
# with assert_full_is_superset() (scripts/gate-buildsteps.sh) — that script
# is in none of `full`'s own BUCKET_PRE/BUCKET_POST lists today, so the
# bucket would fail before running a single step unless also added to
# `full`, taxing every --full/pre-push run for one narrow, rarely-touched
# fixture.
#
# WHAT TO RUN INSTEAD of `--full` for a testproj-only change: `bit test
# _tests_/testproj` directly (fast, no oracle), plus `bash
# scripts/selfhost-difftests.sh` if verifying against the pinned stage0
# oracle matters.
#
# gates_for_file() answers one question: given a changed file path, which
# gate(s) (by name, as registered in tools/build/gates.bit) does it belong to?
# assert_dirgates_current() self-checks that mapping is complete for every
# directory-target gate gates.bit registers, and runs immediately below —
# sourcing this file both defines the mapper and validates it in one step, so
# no caller can use gates_for_file() without that guard having already run.
# testsbit_steps_for() extends the single-file mapping to a whole file list,
# unioning in the two gates (test-filesize, test-lint-filelines) that scan
# _tests_/bit/**, _tests_/imports/**, or _tests_/stress/** recursively rather than
# per-file.
# Extracts the gate name(s) whose `Gate.argv` literally names path `$1`, by
# grepping the source rather than building anything — `runArgs("<path>")` is
# how every harness-running gate spells its target in tools/build/gates.bit.
# THREE NAMED EXCEPTIONS (#2801, #2825): a fixture under _tests_/bit/checkercases/,
# _tests_/bit/parsercases/, or _tests_/imports/ is not passed as an argv path at
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
# DIRECTORY in `runArgs("_tests_/bit/<dir>")` rather than a single file,
# because the directory is one Bit module and the gate runs it as one
# program — so no path INSIDE that directory can ever match the exact-string
# grep below, and every file in all nine (abimembers, benchgate, clicmd,
# pollfree, rootabi, rootpins, spec, stress, stwwiring) was unmapped, forcing
# `full`, until this fix. One arm per
# directory, matching the gate(s) gates.bit actually registers for it — for
# _tests_/bit/stress that is `test-stress-exclusive` only (test-stress-batch
# is DELIBERATELY EXCLUDED, #3319, same reason and same measurement as the
# `runtime` bucket below: #3309 measured it standalone at 11m0s, over the
# subagent Bash tool's 600s ceiling on its own, because
# _tests_/bit/stress/stress.bit's main loop runs checkProgram() serially with
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
# this change, a diff touching BOTH runtime/** and _tests_/bit/stress/** (or
# _tests_/stress/**) resolved to bucket `runtime` (bucket_count counts only
# the five concrete areas, not testsbit) and then the "riding alongside"
# union below (search `has_testsbit` after the case statement) added
# test-stress-batch straight back into runtime's BUILD_STEPS from
# testsbit_steps, since gates_for_file() still emitted it for the stress
# paths. Excluding it here, at the source, fixes both the `testsbit`
# bucket directly and this union path in one change.
gates_for_file() {
  case "$1" in
    _tests_/bit/checkercases/*) printf 'test-checker-diag\n'; return 0 ;;
    _tests_/bit/parsercases/*) printf 'test-parser\n'; return 0 ;;
    _tests_/imports/*) printf 'test-imports-bit\n'; return 0 ;;
    _tests_/bit/objread/*)
      # No gate of its own: a shared Mach-O/ELF relocation reader (#2877)
      # reached only by relative `import { ... } from "../objread"` from two
      # harnesses. That relationship lives in Bit `import` statements, not in
      # gates.bit's `runArgs()` text, so it cannot be derived and is named
      # here by hand — and `assert_dirgates_current` below cannot check it
      # either, for the same reason: `_tests_/bit/objread` has no `runArgs()`
      # entry anywhere in gates.bit, so it never appears in the list that
      # guard probes.
      printf 'test-stwwiring\ntest-rootpins\n'
      return 0
      ;;
    _tests_/bit/childrun/*)
      # Same shape as _tests_/bit/objread/* just above: a shared bounded-
      # child-process harness (#2902) with no main() and no gate of its own,
      # reached only by relative `import { ... } from "../childrun"` — here
      # from exactly two harnesses (verified: `grep -rn 'from "\.\./childrun"'
      # _tests_/bit/` matches only _tests_/bit/rootpins/rootpins.bit:150 and
      # _tests_/bit/stwwiring/stwwiring.bit:136; _tests_/bit/objread/objread.bit
      # only mentions "childrun" in prose comments, not an import). That
      # relationship lives in Bit `import` statements, not in gates.bit's
      # `runArgs()` text, so it cannot be derived and is named here by hand —
      # and `assert_dirgates_current` below cannot check it either, for the
      # same reason: `_tests_/bit/childrun` has no `runArgs()` entry anywhere
      # in gates.bit, so it never appears in the list that guard probes.
      printf 'test-stwwiring\ntest-rootpins\n'
      return 0
      ;;
    _tests_/bit/docsrunner/*)
      # Same shape as _tests_/bit/objread/* and _tests_/bit/childrun/* above: no
      # gate of its own — #2969 split _tests_/bit/docs.bit's batch-runner into a
      # sibling directory, reached only by relative
      # `import { ... } from "./docsrunner"` from exactly one harness
      # (verified: `grep -rln 'from "\./docsrunner"\|from "\.\./docsrunner"'
      # _tests_/bit/*.bit _tests_/bit/*/*.bit` matches only _tests_/bit/docs.bit).
      # That relationship lives in a Bit `import` statement, not in gates.bit's
      # `runArgs()` text, so it cannot be derived and is named here by hand —
      # and `assert_dirgates_current` below cannot check it either, for the
      # same reason: `_tests_/bit/docsrunner` has no `runArgs()` entry anywhere
      # in gates.bit, so it never appears in the list that guard probes.
      # (#2975, folded into #2962's audit: a split that adds a sibling
      # directory silently narrows a gate's mapping the same way a bucket
      # omission silently narrows a bucket's.)
      printf 'test-docs\n'
      return 0
      ;;
    _tests_/stress/*)
      # A different top-level directory from the harness that reads it
      # (_tests_/bit/stress/, matched by the `_tests_/bit/stress/*)` arm just
      # below to the same gate): this is the corpus itself —
      # _tests_/bit/stress/stress.bit:359-376 defaults to `root + "/_tests_/stress"`
      # (root = BIT_STRESSGATE_ROOT, defaulting to ".") — so no
      # `runArgs("_tests_/stress")` entry exists anywhere in gates.bit (only
      # `runArgs("_tests_/bit/stress")`, for the harness), and this relationship
      # cannot be derived and is named here by hand, same shape as
      # _tests_/bit/objread/*, _tests_/bit/childrun/*, and _tests_/bit/docsrunner/*
      # above. `assert_dirgates_current` below cannot check it either, for the
      # same reason: `_tests_/stress` has no `runArgs()` entry anywhere in
      # gates.bit, so it never appears in the list that guard probes. (#2977)
      # test-stress-batch deliberately excluded — see the header comment
      # above `gates_for_file()` (#3319/#3309).
      printf 'test-stress-exclusive\n'
      return 0
      ;;
    _tests_/bit/abimembers/*) printf 'test-abimembers\n'; return 0 ;;
    _tests_/bit/benchgate/*) printf 'test-benchgate\n'; return 0 ;;
    # #2055: gate name is "bench-regex", not "test-bench-regex" — same shape
    # as fuzz-regex's own coreSteps() naming (tools/build/defs.bit).
    _tests_/bit/benchregex/*) printf 'bench-regex\n'; return 0 ;;
    _tests_/bit/clicmd/*) printf 'test-clicmd\n'; return 0 ;;
    # #4262: a directory module from the start (arread.bit split out to stay
    # under the 800-line limit), same shape as _tests_/bit/fmtcitations/*
    # and _tests_/bit/golden/* below.
    _tests_/bit/externarchive/*) printf 'test-extern-archive\n'; return 0 ;;
    # #3458 moved this from a single file (_tests_/bit/fmtcitations.bit) to a
    # directory module — its self-tests split into a sibling to stay under the
    # 800-line limit, the same shape as _tests_/bit/benchgate/* above.
    _tests_/bit/fmtcitations/*) printf 'test-fmt-citations\n'; return 0 ;;
    # #3573 moved this from a single file (_tests_/bit/golden.bit) to a
    # directory module — the directive-name/dispatch helpers split into a
    # sibling to stay under the 800-line limit after `bit fmt`, the same
    # shape as _tests_/bit/fmtcitations/* above.
    _tests_/bit/golden/*) printf 'test-golden\n'; return 0 ;;
    # #3593 moved this from a single file (_tests_/bit/importsrun.bit) to a
    # directory module — the phase-C grading plus a new retry helper split
    # into a sibling to stay under the 800-line limit, the same shape as
    # _tests_/bit/fmtcitations/* and _tests_/bit/golden/* above.
    _tests_/bit/importsrun/*) printf 'test-imports-bit\n'; return 0 ;;
    # #2369 split this from a single file (_tests_/bit/pmrangegate.bit) to a
    # directory module — formatting it past the 800-line limit while the
    # _tests_/bit fmt ratchet demanded it be formatted forced the split, the
    # same shape as _tests_/bit/fmtcitations/*, _tests_/bit/golden/* and
    # _tests_/bit/importsrun/* above.
    _tests_/bit/pmrangegate/*) printf 'test-pmrangegate\n'; return 0 ;;
    # #4308: split from a single file (_tests_/bit/lintcmd.bit, 799 lines with
    # zero headroom on the 800-line ceiling) to a directory module — the
    # individual checkXxx functions split into a lintcmdchecks.bit sibling,
    # the same shape as _tests_/bit/pmrangegate/* above.
    _tests_/bit/lintcmd/*) printf 'test-lint\n'; return 0 ;;
    _tests_/bit/pollfree/*) printf 'test-pollfree\n'; return 0 ;;
    # #3822: split from a single file to a directory module (the receiver-form
    # baseline migration needed its own sibling — see receiverform.bit's own
    # header) the same shape as _tests_/bit/spec/* below.
    _tests_/bit/releasesurface/*) printf 'test-release-surface\n'; return 0 ;;
    _tests_/bit/rootabi/*) printf 'test-rootabi\n'; return 0 ;;
    _tests_/bit/rootpins/*) printf 'test-rootpins\n'; return 0 ;;
    _tests_/bit/spec/*) printf 'test-spec\n'; return 0 ;;
    # test-stress-batch deliberately excluded — see the header comment above
    # gates_for_file() (#3319/#3309).
    _tests_/bit/stress/*) printf 'test-stress-exclusive\n'; return 0 ;;
    _tests_/bit/stwwiring/*) printf 'test-stwwiring\n'; return 0 ;;
    _tests_/bit/testtimeout/*) printf 'test-timeout\n'; return 0 ;;
    # #3039. Not `runArgs()`-registered — it is a plain data file the
    # harness reads at runtime, not Bit source — so the generic grep below
    # can never find it; named by hand, same shape as _tests_/bit/checkercases/*.
    _tests_/bit/releasesurface.allowlist) printf 'test-release-surface\n'; return 0 ;;
    # #2252: same shape as releasesurface.allowlist above — a sidecar
    # `.expected` byte-match target testloc.bit's own main() reads at
    # runtime, not Bit source, so the generic `runArgs()` grep below can
    # never find it either.
    _tests_/bit/testloc.expected) printf 'test-testloc\n'; return 0 ;;
  esac
  # Excludes any extracted name containing a literal `${` — that is a
  # per-instance template (e.g. tools/build/gates.bit's `packageGates()`
  # loop emitting `Gate{name: "test-package-${p}", ...}` inside `for p of
  # ...`), only meaningful once Bit interpolates it at runtime inside its
  # own generator, never a literal invocable step name on its own. The
  # plain-text grep above cannot tell a template apart from a real gate
  # whose `runArgs()` argument happens to match, so both come back; without
  # this filter a diff touching _tests_/bit/packagesgate.bit reports the
  # un-interpolated template as a build step, which the STALE check below
  # correctly (but unhelpfully) rejects, making the whole scoped gate exit 2
  # and run nothing (#3496).
  #
  # Reads BOTH gate-table files (#4169 split `gateTableB()` out of
  # tools/build/gates.bit into tools/build/gatestable2.bit once gates.bit hit
  # the 800-line ceiling) — `-h` suppresses the per-file prefix grep adds once
  # more than one file is given, which the `sed` below does not expect.
  grep -hF "runArgs(\"$1\")" tools/build/gates.bit tools/build/gatestable2.bit 2>/dev/null |
    sed -n 's/.*Gate{name: "\([^"]*\)".*/\1/p' |
    grep -vF '${' || true
}

# Fails loudly, once, on every real invocation — before any file is
# classified into a bucket, and regardless of whether this diff touches
# _tests_/bit/** at all — if gates.bit registers a directory-target gate that
# gates_for_file() above cannot actually resolve a file inside of (#2903).
# PROBES THE MAPPER ITSELF: builds the directory list straight from
# gates.bit (every `runArgs("_tests_/bit/<dir>")` with no `.bit` suffix, same
# extraction gates_for_file()'s own case arms are hand-matched against), then
# calls `gates_for_file "<dir>/probe.bit"` for each and fails if any comes
# back empty. That is the whole point: nothing here is compared against a
# second list a maintainer could "fix" by editing the wrong thing. The only
# way to make this pass is to add a case arm that actually makes
# gates_for_file() resolve the directory — which is the fix the failure
# message asks for and the only fix that is possible.
#
# _tests_/bit/objread and _tests_/bit/childrun are out of scope for this loop,
# correctly and by construction: both have zero `runArgs()` entries anywhere
# in gates.bit (verified: `grep -n 'objread\|childrun' tools/build/gates.bit`
# is empty), so neither ever appears in `dirs` below. Each is a hand-
# maintained exception inside gates_for_file() (see those case arms above)
# that no automated check can cover, because the two-harness relationship
# each encodes lives only in Bit `import` statements, not in gates.bit's
# text.
assert_dirgates_current() {
  local dirs dir probe result
  # Both gate-table files (#4169) — see gates_for_file()'s matching -h note.
  dirs="$(grep -hoE 'runArgs\("_tests_/bit/[^"]+"\)' tools/build/gates.bit tools/build/gatestable2.bit |
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
  # test-filesize (#2962) scans EVERY .bit file recursively under _tests_/bit/
  # (_tests_/bit/filesize.bit's own stated scope: "anywhere under _tests_/bit/,
  # RECURSIVELY"), not just its own harness file (_tests_/bit/filesize.bit,
  # which the loop above already maps via the plain runArgs() grep). So any
  # _tests_/bit/** file can flip its verdict and must run it too — added here
  # rather than inside gates_for_file() itself so assert_dirgates_current()
  # above keeps probing the UNMODIFIED per-file mapping: folding this into
  # gates_for_file() would make every probe return non-empty regardless of
  # whether a real case arm exists, silently defeating that guard.
  # _tests_/imports/** is a different tree filesize.bit never walks, so it is
  # excluded here — this loop only ever reaches this point once every file in
  # `files` mapped successfully (the empty-return above already covers a
  # partial/unmapped set), so it is safe to unconditionally add.
  for f in ${files}; do
    case "${f}" in
      _tests_/bit/*)
        case " ${out} " in
          *" test-filesize "*) ;;
          *) out="${out:+${out} }test-filesize" ;;
        esac
        ;;
    esac
  done
  # test-lint-filelines (#3128) scans _tests_/bit/, _tests_/imports/, and
  # _tests_/stress/ too — _tests_/bit/lintfilelines.bit's own dirs list is
  # ["compiler", "runtime", "stdlib", "_tests_/stress", "examples", "_tests_/bit",
  # "_tests_/imports"], not just compiler/runtime/stdlib. Same shape as the
  # test-filesize loop just above: added here rather than inside
  # gates_for_file() so assert_dirgates_current() keeps probing the
  # UNMODIFIED per-file mapping, and only after the loop above has already
  # proven every file in `files` mapped successfully.
  for f in ${files}; do
    case "${f}" in
      _tests_/bit/*|_tests_/imports/*|_tests_/stress/*)
        case " ${out} " in
          *" test-lint-filelines "*) ;;
          *) out="${out:+${out} }test-lint-filelines" ;;
        esac
        ;;
    esac
  done
  printf '%s' "${out}"
}

# ---------------------------------------------------------------------------
# Diff-classification helpers for scripts/gate.sh's THREE NARROW EXCEPTIONS
# (#2435, #3055) — moved here from gate.sh by #4234, which found gate.sh at
# 799/800 lines with no headroom left for the next tools/build/** split
# (#4169 had already threaded a third filename through is_additive_registration
# below and its case arm, at the cost of the line that took gate.sh to 799).
# Pure move: hunk_is_safe(), is_additive_registration() and
# stdlib_docs_pairing_ok() are unchanged below, only relocated — same
# rationale #3480 already used splitting gates_for_file() et al. into this
# file in the first place. is_additive_registration() reads the `${RANGE}`
# global gate.sh sets before calling it; stdlib_docs_pairing_ok() reads the
# `${docs_files}`/`${stdlib_files}` globals gate.sh's classification loop
# populates before calling it — both are ordinary bash dynamic-scope reads,
# unaffected by which file defines the function.

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

# True only if every change to `$1` (tools/build/defs.bit, or gates.bit's
# Gate{} table split by #4169 into gates.bit and gatestable2.bit), across the
# commit range AND the working tree — same three sources CHANGED itself was
# built from — is a bare addition of whole new `Step{}`/`Gate{}` entries:
# zero removed lines, and every added block either is comment/blank-only or
# opens and closes exactly one (or more) new entry. Editing an existing
# entry always removes its old line first, so it is caught by the deletion
# check alone; inserting a statement into an existing function body without
# deleting anything is caught by the shape check, because that block does
# not open with `Step{name:`/`Gate{name:}`.
is_additive_registration() {
  local file="$1" diff prefix
  case "${file}" in
    tools/build/defs.bit) prefix="Step{name:" ;;
    tools/build/gates.bit) prefix="Gate{name:" ;;
    tools/build/gatestable2.bit) prefix="Gate{name:" ;;
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

# ---------------------------------------------------------------------------
# Last fully-green baseline (#3257) — scoping a re-run against the last
# commit at which the WHOLE `./make test` suite passed, instead of always
# diffing against `main`. Lives here rather than a new scripts/ file, per
# this repo's "extend an existing script" rule: a second, related concern
# bolted onto the file-to-gate mapping module above, the same tradeoff #3480
# already made splitting this module out of gate.sh in the first place.
#
# THE BASELINE IS A COMMIT SHA, PERSISTED AT bit-out/make/gate-last-green,
# NOT DERIVED FROM THE GATEBATCH RC FILES DIRECTLY. Those rc files (#3256)
# live at a fixed path per gate and get overwritten by whatever ran most
# recently — after a partial failure, they can no longer prove the sha of
# the run BEFORE it, the one that actually passed everything. Only a
# separately-persisted marker survives a later failing run.
#
# The marker is written in exactly one place, `gate_do_mark_green` below,
# and only after `verify_full_green_now` proves — from the SAME #3256
# stamps, not a bare claim — that every gate `./make test` runs
# (`registered_gate_names`, i.e. `gateSteps()` in tools/build/defs.bit)
# currently has an rc=0 stamped with one shared (sha, runId): one single,
# fully green `./make test` flush. "Reusing a prior result is only sound if
# it can prove which tree produced it" (#3257's own body), applied one
# level up from #3256's own gate-level guarantee.

GATE_LAST_GREEN_FILE="bit-out/make/gate-last-green"

# Every `Step{name: "..."` inside `fn gateSteps(): []Step { ... }` in Bit
# source text on stdin — the exact set `deps: gateNames()` (tools/build/
# defs.bit) resolves `test` to, i.e. what a plain `./make test` run stamps
# one rc file per name for. Shape-based like `hunk_is_safe` in gate.sh (a
# lone `}` alone on a line closes the fn body, by this file's own
# convention) rather than a real parser.
gate_step_names_from() {
  sed -n '/^fn gateSteps(): \[\]Step {$/,/^}$/p' |
    grep -oE 'Step\{name: "[^"]+"' |
    sed -n 's/^Step{name: "\(.*\)"$/\1/p' |
    sort -u
}

registered_gate_names() {
  gate_step_names_from <tools/build/defs.bit
}

# Same set as of `$1` (a commit-ish). Empty (not an error) when `$1` predates
# tools/build/defs.bit or the file cannot be read at that sha — every caller
# treats that as "nothing existed there yet", the conservative direction.
registered_gate_names_at() {
  git show "$1:tools/build/defs.bit" 2>/dev/null | gate_step_names_from
}

# Gate names registered NOW (current working tree, uncommitted edits
# included, same as registered_gate_names) but not yet at `$1` — the set
# --resume must always treat as not-passed, regardless of whether the diff
# since `$1` happens to touch that gate's own files (#3257 acceptance: "a
# gate registered after the last-green sha is always treated as
# not-passed"). Both sides are already sorted -u; comm requires that.
gates_added_since() {
  comm -13 <(registered_gate_names_at "$1") <(registered_gate_names)
}

# Reads back a previously-written marker. Prints nothing (not an error) if
# absent, unreadable, or not a plausible 40-hex sha — every caller treats
# that the same way: no known last-green baseline.
read_last_green_sha() {
  local sha
  [ -f "${GATE_LAST_GREEN_FILE}" ] || return 0
  sha="$(head -n1 "${GATE_LAST_GREEN_FILE}" 2>/dev/null | tr -d '[:space:]')"
  [[ "${sha}" =~ ^[0-9a-f]{40}$ ]] && printf '%s' "${sha}"
  return 0
}

# Atomic replace (write-then-rename) so a reader never observes a partial
# write. This file is worktree-local (under bit-out/, per checkout, not
# $TMPDIR), so there is no cross-agent scratch collision to guard against
# beyond that.
write_last_green_sha() {
  local tmp
  mkdir -p "$(dirname "${GATE_LAST_GREEN_FILE}")"
  tmp="${GATE_LAST_GREEN_FILE}.tmp.$$"
  printf '%s\n' "$1" >"${tmp}"
  mv -f "${tmp}" "${GATE_LAST_GREEN_FILE}"
}

# The raw stamped content of one gate's rc file (#3256: "<rc> <sha>
# <runId>"), trimmed. Empty if the gate never ran in this bit-out.
gatebatch_rc_stamp() {
  local f="bit-out/make/gatebatch/$1.rc"
  [ -f "${f}" ] || return 0
  tr -d '\n' <"${f}" 2>/dev/null
  return 0
}

# True only for a well-formed rc=0 stamp (`$1..$4` = rc/sha/runid/extra, from
# one `read` of a gatebatch_rc_stamp result) that also agrees with the
# flush-in-progress's want-sha/want-run pair (`$5`/`$6`, empty until the
# first gate sets them). Split out of verify_full_green_now purely to keep
# that loop's own branching low, per this repo's complexity ceiling.
gatebatch_stamp_matches() {
  local rc="$1" sha="$2" runid="$3" extra="$4" want_sha="$5" want_run="$6"
  [ -n "${sha}" ] && [ -n "${runid}" ] && [ -z "${extra}" ] && [ "${rc}" = "0" ] || return 1
  [ -z "${want_sha}" ] && return 0
  [ "${sha}" = "${want_sha}" ] && [ "${runid}" = "${want_run}" ]
}

# True full-suite-green proof, not a claim: every name in
# registered_gate_names must have an rc=0 stamp, and all of them must share
# the identical (sha, runId) — the same pair means the same single
# runGateBatch() flush produced every one of them (gatesexec.bit stamps once
# per flush, reused across every chunk in it), so they are provably about
# the same tree, not a patchwork of an old run and a new one. Prints that
# sha on success; on failure, names exactly which gate(s) broke the proof
# and returns 1 — never a bare "no".
verify_full_green_now() {
  local name stamp rc sha runid extra
  local want_sha="" want_run="" missing="" bad=""
  for name in $(registered_gate_names); do
    stamp="$(gatebatch_rc_stamp "${name}")"
    if [ -z "${stamp}" ]; then
      missing="${missing:+${missing} }${name}"
      continue
    fi
    read -r rc sha runid extra <<<"${stamp}"
    if gatebatch_stamp_matches "${rc}" "${sha}" "${runid}" "${extra}" "${want_sha}" "${want_run}"; then
      [ -z "${want_sha}" ] && want_sha="${sha}" && want_run="${runid}"
    else
      bad="${bad:+${bad} }${name}"
    fi
  done
  if [ -n "${missing}" ] || [ -n "${bad}" ] || [ -z "${want_sha}" ]; then
    echo "gate: cannot prove a fully-green ./make test right now — never ran in this bit-out: [${missing}]; failed or from a different run: [${bad}]" >&2
    return 1
  fi
  printf '%s' "${want_sha}"
}

# --mark-green (gate.sh). Refuses on a dirty tree (#3257): the marker binds
# to a bare commit sha, exactly like the rc stamps it is verified against
# (#3256) — on a dirty tree that sha would not represent the bytes that were
# actually tested, the same lie this whole mechanism exists to prevent one
# layer up.
gate_do_mark_green() {
  local sha
  if [ -n "$(git status --porcelain)" ]; then
    echo "gate: --mark-green refuses on a dirty tree — the marker records a commit sha, and a dirty tree's sha would not be what was actually tested. Commit first." >&2
    exit 2
  fi
  sha="$(verify_full_green_now)" || {
    echo "gate: refusing to mark green — run './make test' (or 'scripts/gate.sh --full') to a clean pass first; see the missing/failed gate(s) above." >&2
    echo "GATE_RESULT=FULL_REQUIRED"
    exit 3
  }
  write_last_green_sha "${sha}"
  echo "gate: marked ${sha} as the last fully-green commit (${GATE_LAST_GREEN_FILE})"
  echo "GATE_RESULT=MARKED"
  exit 0
}

# --resume (gate.sh), called before RANGE is defaulted. Sets RANGE and
# RESUME_NEW_GATES as globals for the rest of gate.sh's existing pipeline to
# consume unchanged, or refuses with the SAME exit-3 FULL_REQUIRED shape as
# every other "cannot scope" case in this script (#2872) — never a silent
# fall-through to `main` and never reported as a pass.
gate_resume_set_range() {
  LAST_GREEN_SHA="$(read_last_green_sha)"
  if [ -z "${LAST_GREEN_SHA}" ]; then
    echo "gate: --resume found no last-green baseline (${GATE_LAST_GREEN_FILE} missing, unreadable, or not a 40-hex sha)." >&2
    echo "gate: establish one first — run './make test' to a clean pass, then 'scripts/gate.sh --mark-green' (or run 'scripts/gate.sh --full')." >&2
    echo "GATE_RESULT=FULL_REQUIRED"
    exit 3
  fi
  if ! git cat-file -e "${LAST_GREEN_SHA}^{commit}" 2>/dev/null; then
    echo "gate: last-green sha ${LAST_GREEN_SHA} is not a commit in this repo — refusing to scope against it. Re-establish with --mark-green." >&2
    echo "GATE_RESULT=FULL_REQUIRED"
    exit 3
  fi
  if ! git merge-base --is-ancestor "${LAST_GREEN_SHA}" HEAD 2>/dev/null; then
    echo "gate: last-green sha ${LAST_GREEN_SHA} is not an ancestor of HEAD (history moved past it) — refusing to scope against a baseline this branch no longer contains. Re-establish with --mark-green." >&2
    echo "GATE_RESULT=FULL_REQUIRED"
    exit 3
  fi
  RANGE="${LAST_GREEN_SHA}..HEAD"
  RESUME_NEW_GATES="$(gates_added_since "${LAST_GREEN_SHA}")"
  echo "gate: --resume: last fully-green commit ${LAST_GREEN_SHA}; scoping against '${RANGE}'"
  if [ -n "${RESUME_NEW_GATES}" ]; then
    echo "gate: gate(s) registered since ${LAST_GREEN_SHA} are always treated as not-passed, force-included below: ${RESUME_NEW_GATES}"
  fi
}

# Folds RESUME_NEW_GATES into BUILD_STEPS (set by build_steps_for_bucket /
# union_testsbit_steps, gate-buildsteps.sh) even when the bucket's own
# curated list, or the changed-file mapping, would not otherwise have
# reached them — the case a bucket's hand-maintained step list cannot cover
# because the gate did not exist when that list was written.
gate_resume_inject_new_gates() {
  local ng
  [ -n "${RESUME_NEW_GATES:-}" ] || return 0
  for ng in ${RESUME_NEW_GATES}; do
    case " ${BUILD_STEPS[*]} " in
    *" ${ng} "*) ;;
    *) BUILD_STEPS+=("${ng}") ;;
    esac
  done
  REASON="${REASON}; gate(s) registered since ${LAST_GREEN_SHA} force-included: ${RESUME_NEW_GATES}"
}

# Printed only after every selected gate has actually passed on HEAD (the
# caller places this right before the script's own final PASS/exit 0) — the
# push predicate from #3257's own body: full suite proven at LAST_GREEN_SHA,
# every gate covering a file changed since then reproven at HEAD.
gate_resume_report_push_ok() {
  echo "gate: --resume: every gate covering a file changed since ${LAST_GREEN_SHA} has now passed on HEAD — safe to treat as green for push."
}
