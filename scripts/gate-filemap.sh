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

# SHARED HARNESS MODULES (#4673, #4678) — `_tests_/bit/objread`,
# `_tests_/bit/childrun` and `_tests_/bit/docsrunner` are Bit modules with
# no main(), no gate of their own
# and no `runArgs()` entry in either gate table; they are reached only by a
# relative `import { ... } from "../<mod>"`. That relationship lives in Bit
# source, not in gates.bit's text, so assert_dirgates_current() below cannot
# probe it. gates_for_file()'s arms for them were hand-written gate lists and
# both went stale: on e685013b the objread arm omitted test-extern-archive
# (#4262 added _tests_/bit/externarchive/arread.bit) and the childrun arm
# omitted test-schedmultideadlock, so a diff touching only the shared module
# never ran the consumer most likely to break. The arms now DERIVE their gate
# set from the source. docsrunner was still correct when #4678 converted it
# (one importer, _tests_/bit/docs.bit) — it is here because a hand list that
# happens to be right today is the same latent staleness, not because it had
# drifted. This list is the only hand-maintained part left and is read only by
# assert_sharedmodule_gates_current(): a module missing from it loses its
# assertion, not its mapping.
SHARED_HARNESS_MODULES="objread childrun docsrunner pmvanityhelpers"

# Every file that imports shared harness module `_tests_/bit/$1`. Both
# spellings are matched and both are ANCHORED at column 1: `import { ... }
# from "./$1"` on one line, and `} from "./$1"` closing a multi-line import
# block (_tests_/bit/schedmultideadlock.bit:48). The anchor is load-bearing —
# the identical text sits mid-line inside `//` comments at
# _tests_/bit/objread/objread.bit:12 and _tests_/bit/childrun/childrun.bit:12,
# so an unanchored grep reports each module as importing ITSELF, which
# shared_module_gates() would then recurse on forever; the `grep -v` below
# drops the same case belt-and-braces. Two levels (`_tests_/bit/*.bit`,
# `_tests_/bit/*/*.bit`) is every harness file there is — the only deeper
# `.bit` files are checker fixtures under _tests_/bit/checkercases/*/, which
# import nothing out of _tests_/bit.
shared_module_importers() {
  grep -lE "^(import .*|\}) from \"(\.\./|\./)$1\"" \
    _tests_/bit/*.bit _tests_/bit/*/*.bit 2>/dev/null |
    grep -v "^_tests_/bit/$1/" || true
}

# The gate set of shared harness module `_tests_/bit/$1`: the union of the
# gates of everything that imports it, each importer resolved by
# gates_for_file() ITSELF rather than by a second table — assert_dirgates_
# current()'s own rule, one level down. There is no duplicate list to "fix"
# instead: _tests_/bit/externarchive/arread.bit resolves through the
# `_tests_/bit/externarchive/*` arm that already exists, and
# _tests_/bit/schedmultideadlock.bit through the plain `runArgs()` grep at the
# bottom of gates_for_file(). Empty output is not tolerated silently —
# assert_sharedmodule_gates_current() below fails the run for it.
shared_module_gates() {
  local f
  for f in $(shared_module_importers "$1"); do
    gates_for_file "${f}"
  done | sort -u
}

gates_for_file() {
  case "$1" in
    _tests_/bit/checkercases/*) printf 'test-checker-diag\n'; return 0 ;;
    _tests_/bit/parsercases/*) printf 'test-parser\n'; return 0 ;;
    # test-fmt (#4479): its argv (tools/build/gatestable2.bit:116-118) names
    # `"${repoRoot()}/_tests_/imports"` among its six trees, and this tree has
    # no static per-bucket BUILD_STEPS list — it routes through here and
    # testsbit_steps_for() — so this arm is the one place that wiring can live.
    # Same defect as #4477's pkg/ case via the per-file mapping; found by the
    # same assertion (assert_argvliteral_gates_current, gate-envscope.sh).
    _tests_/imports/*) printf 'test-imports-bit\ntest-fmt\n'; return 0 ;;
    # DERIVED, NOT LISTED (#4673, #4678) — see SHARED_HARNESS_MODULES above
    # gates_for_file() for why these three modules have no gate of their own.
    # shared_module_gates() greps their importers out of _tests_/bit/ and maps
    # each through gates_for_file(), so no arm can be narrower than the tree
    # again. As derived on dec67909, objread -> test-const-immfold
    # (_tests_/bit/constimmfold.bit), test-extern-archive
    # (_tests_/bit/externarchive/arread.bit), test-rootpins
    # (_tests_/bit/rootpins/rootpins.bit), test-stwwiring
    # (_tests_/bit/stwwiring/stwwiring.bit); childrun -> the same four with
    # test-schedmultideadlock (_tests_/bit/schedmultideadlock.bit) in place of
    # test-extern-archive; docsrunner -> test-docs (_tests_/bit/docs.bit, the
    # single importer #2969 left when it split the batch-runner out). Those
    # sets are illustrations of the derivation, never an input to it — do not
    # re-sync them by hand.
    _tests_/bit/objread/*) shared_module_gates objread; return 0 ;;
    _tests_/bit/childrun/*) shared_module_gates childrun; return 0 ;;
    _tests_/bit/docsrunner/*) shared_module_gates docsrunner; return 0 ;;
    # #5595: pmvanityhelpers has had no arm since #4183 split it out of
    # pmvanity.bit; pmvanitymulti (#5586) is the same unmapped shape.
    # pmvanitychecks (#5604's second E0200 split of pmvanity.bit) is a third
    # instance — missing since #5604's merge, tripping the source-time
    # `assert_sharedmodule_importer` check on every branch off main (found
    # while verifying #5606). Neither is added to SHARED_HARNESS_MODULES:
    # both are themselves importers of pmvanityhelpers, and
    # assert_sharedmodule_importer's cycle guard trips on any importer
    # inside a LISTED module's directory either way — each mapping below is
    # still fully derived, only its staleness self-check is skipped.
    _tests_/bit/pmvanityhelpers/*) shared_module_gates pmvanityhelpers; return 0 ;;
    _tests_/bit/pmvanitymulti/*) shared_module_gates pmvanitymulti; return 0 ;;
    _tests_/bit/pmvanitychecks/*) shared_module_gates pmvanitychecks; return 0 ;;
    _tests_/stress/*)
      # A different top-level directory from the harness that reads it
      # (_tests_/bit/stress/, matched by the `_tests_/bit/stress/*)` arm just
      # below to the same gate): this is the corpus itself —
      # _tests_/bit/stress/stress.bit:359-376 defaults to `root + "/_tests_/stress"`
      # (root = BIT_STRESSGATE_ROOT, defaulting to ".") — so no
      # `runArgs("_tests_/stress")` entry exists anywhere in gates.bit (only
      # `runArgs("_tests_/bit/stress")`, for the harness), and this relationship
      # cannot be derived and is named here by hand. It has no `runArgs()`
      # entry, like the three shared-module arms above, but unlike them it is
      # NOT derivable from Bit source either (#4678): the harness reaches this
      # tree through a runtime path default, not an `import`, so
      # shared_module_importers() has nothing to grep for and
      # `assert_dirgates_current` below cannot see it — `_tests_/stress` never
      # appears in the list that guard probes. (#2977)
      # test-stress-batch deliberately excluded — see the header comment
      # above `gates_for_file()` (#3319/#3309). test-fmt-stress (#4447) is
      # this tree's OWN gate too — its scope is BIT_FMTZERO_TREES=
      # stress:_tests_/stress (tools/build/gatestable2.bit), an env entry
      # naming this exact directory, so a _tests_/stress/**-only diff owes it
      # the same way it owes test-stress-exclusive.
      # test-taskwords-sizing (#5045/#5087) scans this tree by inspection
      # (moduleDirs(root, "_tests_/stress", ...) in its own harness), a
      # spelling the argvscope machinery in scripts/gate-envscope.sh cannot
      # route here (that tree has no single static bucket — see
      # ARGVSCOPE_TREES's own comment there), so it is named by hand here
      # too, same as its sibling arms above.
      printf 'test-stress-exclusive\ntest-fmt-stress\ntest-taskwords-sizing\n'
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
    # #5393: a directory module from the start (a fixture/ sibling holding
    # the two-file same-module repro the harness drives `bit check` against
    # directly), same shape as _tests_/bit/externarchive/* above.
    _tests_/bit/fieldattrcollision/*) printf 'test-fieldattrcollision\n'; return 0 ;;
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
    # #4441: split from a single file (_tests_/bit/checkerdiag.bit, 799 lines
    # with zero headroom on the 800-line ceiling) to a directory module — the
    # wrapped-process/run machinery split into a checkerdiagrun.bit sibling,
    # the same shape as _tests_/bit/pmrangegate/* and _tests_/bit/lintcmd/*
    # above.
    _tests_/bit/checkerdiag/*) printf 'test-checker-diag\n'; return 0 ;;
    _tests_/bit/pollfree/*) printf 'test-pollfree\n'; return 0 ;;
    # #3822: split from a single file to a directory module (the receiver-form
    # baseline migration needed its own sibling — see receiverform.bit's own
    # header) the same shape as _tests_/bit/spec/* below.
    _tests_/bit/releasesurface/*) printf 'test-release-surface\n'; return 0 ;;
    _tests_/bit/rootabi/*) printf 'test-rootabi\n'; return 0 ;;
    _tests_/bit/rootpins/*) printf 'test-rootpins\n'; return 0 ;;
    # #4623 split this from a single file (_tests_/bit/shebangmode.bit, 796
    # lines) to a directory module — its self-tests needed a sibling, and a
    # single-file gate target never loads one (#4441), the same shape as
    # _tests_/bit/stringexplode/* below.
    _tests_/bit/shebangmode/*) printf 'test-shebang-mode\n'; return 0 ;;
    _tests_/bit/spec/*) printf 'test-spec\n'; return 0 ;;
    # test-stress-batch deliberately excluded — see the header comment above
    # gates_for_file() (#3319/#3309).
    _tests_/bit/stress/*) printf 'test-stress-exclusive\n'; return 0 ;;
    # #4426 split this from a single file (_tests_/bit/stringexplode.bit, 771
    # lines) to a directory module — the container fixtures needed a sibling,
    # and a single-file gate target never loads one (#4441).
    _tests_/bit/stringexplode/*) printf 'test-string-explode\n'; return 0 ;;
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
    # #4556: same shape as the two arms above — the E0204 ratchet's data file, read at runtime by _tests_/bit/lintcomplexity.bit (never a `runArgs()` path), not build-driver code. gate.sh's classification arm routes it here; every OTHER tools/build/** path still falls to that case's `*)` and forces full.
    tools/build/complexity-debt.txt) printf 'test-lint-complexity\n'; return 0 ;;
    # #2453/#4149: same shape as the complexity-debt.txt arm above — the lint-self gate's data file (one `<CODE> <repo-relative-path>` line per live finding pair, which replaced the lint-ceiling.txt counts), read at runtime by _tests_/bit/lintself.bit, never a `runArgs()` path.
    tools/build/lint-debt.txt) printf 'test-lint-self\n'; return 0 ;;
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
# The shared harness modules are out of scope for this loop, correctly and by
# construction: all three have zero `runArgs()` entries in either gate-table
# file (verified on dec67909: `grep -n 'objread\|childrun\|docsrunner'
# tools/build/gates.bit tools/build/gatestable2.bit` exits 1 with no output),
# so none ever appears in `dirs` below. They are covered by their own guard,
# assert_sharedmodule_gates_current() right after this one (#4673, #4678):
# this loop's question is "does gates.bit register a directory this mapper
# cannot resolve", theirs is "does the mapper still see every importer of a
# module gates.bit never mentions". Neither can answer the other.
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

# The shared-harness-module half of the guard above (#4673): fails the run, at
# source time, when any derived arm in gates_for_file() has stopped
# describing the tree. Three checks per module, IN THIS ORDER, because check 2
# is what makes check 3 terminate:
#
#   1. the importer set is NON-EMPTY. A wrong cwd, a renamed module or a
#      broken pattern all return "" here, and an empty derivation reads
#      exactly like a module nothing imports: the arm prints nothing, the file
#      comes back unmapped, and the diff falls to bucket `full` with no
#      indication why. A stale hand-written list could never be caught this
#      way, because it is never empty.
#   2. no importer is itself inside a shared module's directory. Two shared
#      modules importing each other would make shared_module_gates() recurse
#      between the two arms forever, and no guard that runs gates_for_file()
#      could report it — so this is decided on the path text, before check 3
#      calls into the mapper.
#   3. every importer maps to a NON-EMPTY gate set. An importer with no gate
#      of its own would otherwise contribute nothing and narrow the arm
#      silently — the exact failure this ticket fixed.
#
# exit 2 matches assert_dirgates_current above: gate.sh reads it as a refusal
# to classify, not as a gate failure.
assert_sharedmodule_gates_current() {
  local mod imps f
  for mod in ${SHARED_HARNESS_MODULES}; do
    imps="$(shared_module_importers "${mod}")"
    if [ -z "${imps}" ]; then
      echo "gate: gates_for_file() derives _tests_/bit/${mod}'s gate set from its importers (scripts/gate-filemap.sh, shared_module_importers) and found NONE" >&2
      echo "gate: source this file from the repo root; if _tests_/bit/${mod} is gone, delete its case arm and its SHARED_HARNESS_MODULES entry" >&2
      exit 2
    fi
    for f in ${imps}; do
      assert_sharedmodule_importer "${mod}" "${f}"
    done
  done
}

# One importer of one shared module: checks 2 and 3 above. Split out of
# assert_sharedmodule_gates_current() to keep both readable at a glance.
assert_sharedmodule_importer() {
  local other
  for other in ${SHARED_HARNESS_MODULES}; do
    case "$2" in
      _tests_/bit/${other}/*)
        echo "gate: shared harness module _tests_/bit/${other} imports _tests_/bit/$1 ($2); gates_for_file()'s derived arms would recurse into each other forever" >&2
        echo "gate: break the cycle, or give _tests_/bit/${other} a gate of its own" >&2
        exit 2
        ;;
    esac
  done
  if [ -z "$(gates_for_file "$2")" ]; then
    echo "gate: $2 imports _tests_/bit/$1 but gates_for_file() maps it to no gate, so deriving _tests_/bit/$1's arm from it drops it silently" >&2
    echo "gate: add a case arm for $2 (or a runArgs() entry naming it) — see gates_for_file() above" >&2
    exit 2
  fi
}
assert_sharedmodule_gates_current

# envscoped_gate_trees(), envscope_bucket_for_tree() and
# assert_envscoped_gates_current() (#4454, the env-entry half of the
# argv/env rule gate.sh's header states) live in scripts/gate-envscope.sh, a
# sibling sourced right after scripts/gate-buildsteps.sh — this file had no
# room left under its own 800-line ceiling for that ~150-line addition.

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
  #
  # test-fmt-testsbit (#4447, BIT_FMTZERO_TREES=testsbit:_tests_/bit) shares
  # this exact _tests_/bit/* scope, so it is unioned in the SAME loop rather
  # than a second one over the same file list.
  for f in ${files}; do
    case "${f}" in
      _tests_/bit/*)
        case " ${out} " in
          *" test-filesize "*) ;;
          *) out="${out:+${out} }test-filesize" ;;
        esac
        case " ${out} " in
          *" test-fmt-testsbit "*) ;;
          *) out="${out:+${out} }test-fmt-testsbit" ;;
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
  #
  # test-lint-tests (#4450) sweeps the identical three trees
  # (_tests_/bit/lintTests.bit's own dirNames), so it is unioned in the SAME
  # loop too.
  for f in ${files}; do
    case "${f}" in
      _tests_/bit/*|_tests_/imports/*|_tests_/stress/*)
        case " ${out} " in
          *" test-lint-filelines "*) ;;
          *) out="${out:+${out} }test-lint-filelines" ;;
        esac
        case " ${out} " in
          *" test-lint-tests "*) ;;
          *) out="${out:+${out} }test-lint-tests" ;;
        esac
        ;;
    esac
  done
  printf '%s' "${out}"
}

# ---------------------------------------------------------------------------
# Diff-classification helpers for scripts/gate.sh's THREE NARROW EXCEPTIONS
# (#2435, #3055) — hunk_is_safe(), is_additive_registration() and
# stdlib_docs_pairing_ok() — used to be spelled out right here, moved in from
# gate.sh by #4234. #4610 moved them one file further out, unchanged, because
# this file hit 800/800 (the hard-zero ceiling in _tests_/bit/shellsize.bit,
# #4232) and the next gates_for_file() arm had no line to spend; they are a
# diff-SHAPE question, not the file-to-gate mapping this file is named for.
# Sourced HERE, at the point they used to be defined, so gate.sh's single
# `. scripts/gate-filemap.sh` still defines everything in the same order.
# shellcheck source=scripts/gate-diffclass.sh
. scripts/gate-diffclass.sh


# ---------------------------------------------------------------------------
# Last fully-green baseline (#3257) — gate_do_mark_green(),
# gate_resume_set_range(), gate_resume_inject_new_gates(),
# gate_resume_report_push_ok() and the verification/persistence helpers
# behind them — used to be spelled out right here, added by #3257. #5610
# moved them one file further out, unchanged, because this file hit 800/800
# again (the hard-zero ceiling in _tests_/bit/shellsize.bit, #4232) and the
# next gates_for_file() arm had no line to spend; the baseline mechanism is a
# push-safety cache, not the file-to-gate mapping this file is named for, and
# calls none of gates_for_file(), testsbit_steps_for() or the shared-harness
# helpers above. Sourced HERE, at the point it used to be defined, so
# gate.sh's single `. scripts/gate-filemap.sh` still defines everything in
# the same order.
# shellcheck source=scripts/gate-resume.sh
. scripts/gate-resume.sh
