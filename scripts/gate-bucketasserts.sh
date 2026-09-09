#!/usr/bin/env bash
# scripts/gate-bucketasserts.sh — the three BUCKET-SIDE invariants behind
# scripts/gate.sh, carved out of scripts/gate-buildsteps.sh by #4466 as a PURE
# MOVE: assert_full_is_superset() (#2194), assert_composite_is_superset()
# (#4480) and assert_fmt_gate_per_bucket() (#4328) with its three helpers
# (fmt_gate_trees, bit_source_trees, assert_fmtgate_deps) and the two named
# lists FMTGATE_TREE_FLOOR / FMTGATE_UNGATED_TREES are unchanged below, only
# relocated. Nothing is added here and nothing was trimmed to fit.
#
# WHY, and why now: gate-buildsteps.sh's own header has said since #4328 that
# it sits near the 800-line hard-zero ceiling (_tests_/bit/shellsize.bit,
# #4232) and that the NEXT addition splits these functions out rather than
# buying room from the reasoning. #4466 is that addition — three gates joining
# three buckets, each owing the comment that says why — so the split is done
# first, in its own commit, exactly as #4610 carved gate-diffclass.sh out of
# gate-filemap.sh.
#
# SOURCED BY scripts/gate-buildsteps.sh, not by gate.sh: every caller keeps
# `. scripts/gate-buildsteps.sh` unchanged and gets these three definitions as
# before, the same shape gate-filemap.sh uses for gate-diffclass.sh. Do not
# source it directly.
#
# The dependency order is unchanged too. These read BUCKET/BUILD_STEPS as
# globals and probe build_steps_for_bucket() (gate-buildsteps.sh),
# argvliteral_bucket_for_dir() (gate-envscope.sh) and testsbit_steps_for()
# (gate-filemap.sh) at CALL time, not at source time — assert_fmtgate_deps()
# below is what turns a caller that skipped one into a refusal instead of a
# plausible wrong answer.

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
# gate-envscope.sh's argvscope_floor_for_tree() and ARGVLITERAL_FLOOR are:
# bit_source_trees() returning nothing (a pathspec that stopped crossing `/`, a
# `cd` that never happened) passes this assertion over an empty list, printing
# exactly like a correctly wired tree.
FMTGATE_TREE_FLOOR="compiler runtime stdlib examples pkg _tests_/cases _tests_/bit"

# NAMED EXEMPTION: trees holding `.bit` sources that NO fmt gate names, so no
# bucket can carry one. EMPTY since #4681 put the last two (_tests_/freestanding,
# _tests_/testproj — 4 files `./make test` never formatted) into test-fmt's argv,
# so every `.bit` tree on disk is checked below. A name added back needs its
# ticket: while it sits here this assertion skips that tree, which reads clean.
FMTGATE_UNGATED_TREES=""

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
