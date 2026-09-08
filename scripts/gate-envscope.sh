#!/usr/bin/env bash
# scripts/gate-envscope.sh — env-declared-tree gate mapping for
# scripts/gate.sh (#4454). Split out of scripts/gate-filemap.sh, which had no
# headroom left under the 800-line hard-zero shell ceiling (_tests_/bit/
# shellsize.bit, #4232) for this addition — a distinct concern from that
# file's own argv/directory-target mapping, the same split rationale #3480
# and #4234 already used carving modules out of gate.sh itself.
#
# Source this AFTER scripts/gate-filemap.sh (needs testsbit_steps_for()) and
# AFTER scripts/gate-buildsteps.sh (needs build_steps_for_bucket()) — gate.sh
# sources it right alongside the latter. Nothing here self-invokes at source
# time, unlike gate-filemap.sh's assert_dirgates_current(): the one function
# gate.sh actually needs to run, assert_envscoped_gates_current(), depends on
# build_steps_for_bucket() not existing yet at gate-filemap.sh's own source
# time, so gate.sh calls it explicitly once every module is loaded.
#
# THE RULE THIS FILE ENFORCES: gate.sh's own header already claims "EVERY
# BUCKET RUNS EVERY GATE WHOSE OWN DECLARED FILE SET, its argv OR AN ENV
# ENTRY, INTERSECTS THAT BUCKET'S PATHS." scripts/gate-filemap.sh's
# assert_dirgates_current() has checked the argv/directory half since #2903;
# nothing checked the env half until #4445 found test-fmt-strict's
# BIT_FMTZERO_TREES scope silently unwired and #4454 built this to make sure
# the next one like it cannot happen the same way.

# Emits "<gate> <tree>" pairs, one per name:relpath entry inside a
# `"BIT_*_TREES=name:relpath name:relpath ..."` env string, scanning both gate
# tables in one pass. Line-based, like scripts/gate-filemap.sh's
# `is_additive_registration()`'s hunk scan: tracks the most recently seen
# `Gate{name: "..."` as it goes, and pairs any `"..._TREES=..."` string that
# follows it. Good enough because every Gate{} in this codebase opens with
# its own `name:` on its own logical line and none is ever nested inside
# another's env list — the exact assumption assert_dirgates_current's own sed
# already makes about this source's shape.
envscoped_gate_trees() {
  local file line name m pair
  for file in tools/build/gates.bit tools/build/gatestable2.bit; do
    name=""
    while IFS= read -r line; do
      case "${line}" in
        *'Gate{name: "'*)
          name="$(printf '%s' "${line}" | sed -n 's/.*Gate{name: "\([^"]*\)".*/\1/p')"
          ;;
        *'_TREES='*)
          m="$(printf '%s' "${line}" | sed -n 's/.*_TREES=\([^"]*\)".*/\1/p')"
          [ -n "${m}" ] && [ -n "${name}" ] || continue
          for pair in ${m}; do
            printf '%s %s\n' "${name}" "${pair#*:}"
          done
          ;;
      esac
    done <"${file}"
  done
}

# Maps a source-tree relpath (the right side of one BIT_*_TREES= name:relpath
# pair) to the gate.sh bucket whose step list must carry the gate that
# declares it. "testsbit" covers the three fixture trees that route through
# testsbit_steps_for() rather than a static per-bucket list (checked
# differently in the caller below, same as gates_for_file() already treats
# them). Prints nothing (not an error) for "tools" — a NAMED EXEMPTION
# (#4445): every tools/** diff outside a purely-additive tools/build/{defs,
# gates,gatestable2}.bit registration already resolves to bucket `full`,
# which runs every gate via the aggregate `test` step, so no scoped bucket
# needs to carry it by hand. Any OTHER tree name is a hard failure in the
# caller, not a silent skip — an env-declared tree this function cannot route
# is exactly the "next gate" case #4454 exists to catch.
envscope_bucket_for_tree() {
  case "$1" in
    tools) return 0 ;;
    compiler) printf 'selfhost\n' ;;
    runtime) printf 'runtime\n' ;;
    stdlib) printf 'stdlib\n' ;;
    examples) printf 'examples\n' ;;
    pkg) printf 'pkg\n' ;;
    _tests_/cases) printf 'testcases\n' ;;
    _tests_/bit | _tests_/stress | _tests_/imports) printf 'testsbit\n' ;;
    *) return 1 ;;
  esac
}

# Fails loudly, once, if a gate declaring its scope via a BIT_*_TREES= env
# entry is missing from a bucket its own declared tree maps to — the
# mechanical half of the rule gate.sh's own header claims, that nothing
# previously checked. #4445 found test-fmt-strict dark this way; #4447-#4453
# wire the rest of that manual audit's finds by hand. Modelled on
# scripts/gate-filemap.sh's assert_dirgates_current(): probes the LIVE
# machinery (build_steps_for_bucket()/testsbit_steps_for()) rather than a
# second hand-maintained list, so the only way to pass is to actually wire
# the gate in.
#
# Shadows BUCKET/BUILD_STEPS as locals for the duration of its own probing,
# via bash's dynamic scoping, so it never disturbs the real diff's own bucket
# selection running around it in scripts/gate.sh.
#
# SCOPE, STATED PRECISELY, so nobody assumes this catches more than it does:
# this only covers a gate whose tree list is spelled out in gates.bit's own
# env — today that is exactly the four BIT_FMTZERO_TREES gates
# (test-fmt-strict/-stress/-testsbit/-cases). The other six gates #4445's
# audit found dark (test-lint-self, test-lint-complexity, test-lint-sweep,
# test-lint-tests, test-fmt-roundtrip, test-threadtokenbytes,
# test-version-cli) declare their scope as a dirNames array or similar INSIDE
# the harness .bit source, not in gates.bit's env — there is nothing here to
# grep, and inferring it would mean parsing Bit source as a second
# interpreter. #4447-#4452 wire those seven by hand; nothing here re-checks
# them, and that gap is real and stated, not silently assumed shut.
assert_envscoped_gates_current() {
  local pairs pair gate tree bucket probe result denom=0 bad="" seen=""
  local BUCKET BUILD_STEPS
  assert_envscope_deps
  pairs="$(envscoped_gate_trees)"
  if [ -z "${pairs}" ]; then
    echo "gate: assert_envscoped_gates_current: found ZERO gates declaring a BIT_*_TREES= env entry across both gate tables — almost certainly this function's own extraction breaking (today there are at least 4: test-fmt-strict/-stress/-testsbit/-cases), not a fact about the tree" >&2
    exit 2
  fi
  while IFS= read -r pair; do
    [ -z "${pair}" ] && continue
    gate="${pair%% *}"
    case " ${seen} " in
      *" ${gate} "*) ;;
      *)
        seen="${seen:+${seen} }${gate}"
        denom=$((denom + 1))
        ;;
    esac
  done <<EOF
${pairs}
EOF
  echo "gate: assert_envscoped_gates_current: ${denom} env-declared-tree gate(s) found, checking each against gate-buildsteps.sh"

  while IFS= read -r pair; do
    [ -z "${pair}" ] && continue
    gate="${pair%% *}"
    tree="${pair#* }"
    bucket="$(envscope_bucket_for_tree "${tree}")" || {
      bad="${bad:+${bad}
}gate \"${gate}\" declares env tree \"${tree}\" that envscope_bucket_for_tree() (scripts/gate-envscope.sh) does not know how to route — add a case arm naming the bucket, or a named exemption with its reason"
      continue
    }
    [ -z "${bucket}" ] && continue
    if [ "${bucket}" = "testsbit" ]; then
      case "${tree}" in
        _tests_/bit) probe="_tests_/bit/golden/probe.bit" ;;
        _tests_/stress) probe="_tests_/stress/probe.bit" ;;
        _tests_/imports) probe="_tests_/imports/probe.bit" ;;
      esac
      result="$(testsbit_steps_for "${probe}")"
      case " ${result} " in
        *" ${gate} "*) ;;
        *)
          bad="${bad:+${bad}
}gate \"${gate}\" declares env tree \"${tree}\" but testsbit_steps_for() (probed \"${probe}\") does not include it — union it into scripts/gate-filemap.sh's testsbit_steps_for()"
          ;;
      esac
    else
      BUCKET="${bucket}"
      build_steps_for_bucket
      case " ${BUILD_STEPS[*]} " in
        *" ${gate} "*) ;;
        *)
          bad="${bad:+${bad}
}gate \"${gate}\" declares env tree \"${tree}\" but bucket \"${bucket}\"'s BUILD_STEPS (scripts/gate-buildsteps.sh) does not include it"
          ;;
      esac
    fi
  done <<EOF
${pairs}
EOF

  if [ -n "${bad}" ]; then
    echo "gate: assert_envscoped_gates_current: FAILED —" >&2
    echo "${bad}" | sed 's/^/gate:   /' >&2
    exit 2
  fi
  echo "gate: assert_envscoped_gates_current: all ${denom} env-declared-tree gate(s) correctly wired"

  # The argv-scoped half (#4465) runs from here rather than from a second call
  # site in scripts/gate.sh: that file sits at exactly 800 lines against
  # _tests_/bit/shellsize.bit's hard-zero ceiling, so it has no room for one
  # more line. Both halves check the same rule gate.sh's own header states, and
  # neither is optional, so one entry point is the honest shape anyway.
  assert_argvscoped_gates_current
}

# ---------------------------------------------------------------------------
# THE ARGV-SCOPED HALF (#4465).
#
# assert_envscoped_gates_current() above covers a gate whose scanned trees are
# spelled out in gates.bit's own `env:`. #4465 is the same defect reached by a
# THIRD route, which that assertion states plainly it cannot see: a gate whose
# argv names only its own fixture (`runArgs("_tests_/bit/abimembers")`), whose
# env carries nothing but `std`, and whose real scope is a walk INSIDE the
# harness source — `bitSources("${repo}/compiler")`. test-abimembers sat in
# the `runtime` bucket alone while reading every `Op.RtCall` name in
# compiler/*.bit as an ABI demand, so it was dark for exactly the compiler-only
# diffs it exists to catch (ae8a2581, symptom fixed at d1534308).
#
# WHY DISCOVERY IS A GREP AND NOT A HAND TABLE. A hand table of "gate ->
# tree" would be a second list to keep in step with the harnesses, and this
# repo's whole complaint about the manual wiring in gate-buildsteps.sh is that
# a hand list goes stale silently. So the harness sources ARE the list: the
# scan-root spellings below are derived from the source every time. What is
# hand-held is only the FLOOR — a small set of gates known to be in this class
# — which exists so that a broken pattern (matching nothing) fails loudly
# instead of passing vacuously, the failure mode CLAUDE.md records for the
# `compiler/**/*.bit` glob and the ARM64_RELOC_BRANCH26 count.
#
# SCOPE, STATED PRECISELY: this covers the `compiler` tree only, which is
# #4465's acceptance. Widening it to the other eight trees means deciding a
# bucket for every gate a wider pattern turns up, and each of those decisions
# is its own finding — filed separately rather than guessed at here.

# Fails loudly if this file was sourced without the modules it probes. Sourced
# alone, `build_steps_for_bucket` and `testsbit_steps_for` are simply absent,
# `$(...)` yields empty, and every gate then looks unwired — a plausible
# WRONG answer naming real gate names, which is worse than a crash (#4454
# hit exactly this by hand). A missing dependency is a caller bug, not a
# finding about the tree, and must not be reported as one.
assert_envscope_deps() {
  local fn missing=""
  for fn in build_steps_for_bucket testsbit_steps_for; do
    command -v "${fn}" >/dev/null 2>&1 || missing="${missing:+${missing} }${fn}"
  done
  [ -z "${missing}" ] && return 0
  echo "gate: scripts/gate-envscope.sh: sourced without its dependencies (${missing} undefined) — source scripts/gate-filemap.sh and scripts/gate-buildsteps.sh first, as scripts/gate.sh does. Refusing to report a verdict: with these absent every gate looks unwired and the failure list would name real gates for a reason that is not true of the tree." >&2
  exit 2
}

# Emits "<gate> <argv-path>" for every Gate{} whose argv is a single
# runArgs("<path>") fixture target. The gates whose argv names a source tree
# directly (test-fmt, test-selfcheck, test-selfhostcheck, ...) do not match and
# do not need to: gate-filemap.sh's gates_for_file() already ties those back to
# their bucket by argv-literal matching, which is the half that has worked
# since #2903.
argv_gate_paths() {
  sed -n 's/.*Gate{name: "\([^"]*\)".*runArgs("\([^"]*\)").*/\1 \2/p' \
    tools/build/gates.bit tools/build/gatestable2.bit
}

# The scan-root spellings a harness uses to name the compiler tree, as an
# extended regex over its own .bit source:
#   ${repo}/compiler , ${repoRoot()}/compiler   — a walk root
#   [ "compiler"  or  , "compiler"  or  ^"compiler"  — a dirNames array element
#   "compiler/<name>.bit"                        — a named compiler source
# Deliberately NOT a bare `"compiler"` anywhere: _tests_/bit/walkbitcheck.bit
# mentions `walk("compiler")` in a comment and scans nothing, and a pattern
# that cannot tell a comment from a scan root produces a candidate list nobody
# will trust; whole-line `//` comments are stripped before matching for the
# same reason. Verified against all 103 argv-path gates: 9 candidates, every
# one of which genuinely reads compiler sources, and it independently
# re-derives the two gates (test-version-cli, test-threadtokenbytes) that
# #4454's HAND audit had found by reading — their matches are real
# `exists("${c}/compiler/codegen.bit")`/`slurp(...)` calls, not prose.
#
# WHAT IT CANNOT DO, measured rather than assumed: the `compiler/<name>.bit"`
# arm matches that spelling anywhere in code, including inside a diagnostic
# STRING. Renaming both of abimembers.bit's real scan roots
# (`bitSources("${repo}/compiler")`, `"${repo}/compiler/irrtfns.bit"`) still
# leaves it discovered, off its own message text at :398. So this discovers
# membership in the class; it does not prove a gate has LEFT it. That is the
# over-inclusive direction — at worst it demands a gate be wired that need not
# be, which fails loudly and is settled by wiring it or naming an exemption.
# The direction that matters, a gate silently going dark, is the one it
# catches.
ARGVSCOPE_COMPILER_PATTERN='\$\{repo(Root\(\))?\}/compiler|(^|[[,])[[:space:]]*"compiler"|compiler/[a-zA-Z0-9_]+\.bit"'

# Prints the gate names whose own harness source scans the compiler tree, one
# per line, sorted and deduplicated.
argvscoped_compiler_gates() {
  local gate path srcs src hits
  argv_gate_paths | while IFS=' ' read -r gate path; do
    [ -n "${gate}" ] || continue
    if [ -d "${path}" ]; then
      srcs="$(ls "${path}"/*.bit 2>/dev/null || true)"
    elif [ -f "${path}" ]; then
      srcs="${path}"
    else
      continue
    fi
    [ -n "${srcs}" ] || continue
    for src in ${srcs}; do
      # -c, not -q: `grep -q` exits on the FIRST match, so the upstream grep
      # takes SIGPIPE on any file bigger than the pipe buffer and `set -o
      # pipefail` then reads a real match as a failure — a miss that grows
      # with file size and passes on every small file you test it with. -c
      # drains its input. Zero matches is exit 1 with "0" on stdout, hence the
      # `|| true` and the explicit compare rather than reading the status.
      hits="$(command grep -vE '^[[:space:]]*//' "${src}" \
        | command grep -cE "${ARGVSCOPE_COMPILER_PATTERN}" || true)"
      [ "${hits}" = "0" ] && continue
      printf '%s\n' "${gate}"
      break
    done
  done | sort -u
}

# The live-query floor. These four are in this class by inspection and none of
# them can leave it without the harness being rewritten, so a run that fails to
# rediscover any one of them has a broken pattern, not a cleaner tree. Named
# rather than counted on purpose: a count silently absorbs one gate leaving the
# class while another joins it, exactly the property that retired this repo's
# fmt ceilings (#3713).
ARGVSCOPE_COMPILER_FLOOR="test-abimembers test-lint-filelines test-lint-self test-fmt-roundtrip"

# Asserts every gate whose harness scans the compiler tree is in the `selfhost`
# bucket's BUILD_STEPS. Probes the LIVE build_steps_for_bucket() rather than a
# second copy of the step list, same as assert_envscoped_gates_current() above,
# so the only way to pass is to actually wire the gate in.
#
# Shadows BUCKET/BUILD_STEPS as locals, so it never disturbs the real diff's
# own bucket selection running around it in scripts/gate.sh.
assert_argvscoped_gates_current() {
  local gates gate want denom=0 wired=0 bad=""
  local BUCKET BUILD_STEPS
  assert_envscope_deps
  gates="$(argvscoped_compiler_gates)"
  for want in ${ARGVSCOPE_COMPILER_FLOOR}; do
    case "
${gates}
" in
      *"
${want}
"*) ;;
      *)
        echo "gate: assert_argvscoped_gates_current: did NOT rediscover \"${want}\", which scans the compiler tree by inspection — ARGVSCOPE_COMPILER_PATTERN (scripts/gate-envscope.sh) has stopped matching, or that harness moved. A pattern matching nothing looks exactly like a correctly wired tree; refusing to report a verdict." >&2
        exit 2
        ;;
    esac
  done

  BUCKET="selfhost"
  build_steps_for_bucket
  while IFS= read -r gate; do
    [ -n "${gate}" ] || continue
    denom=$((denom + 1))
    case " ${BUILD_STEPS[*]} " in
      *" ${gate} "*) wired=$((wired + 1)) ;;
      *)
        bad="${bad:+${bad}
}gate \"${gate}\"'s own harness scans the compiler tree, but the \"selfhost\" bucket's BUILD_STEPS (scripts/gate-buildsteps.sh) does not include it — a compiler-only diff never runs it. Wire it into that bucket, or, if it is a coreSteps() gate outside \`./make test\` and so outside gate.sh's scoping responsibility, add it here as a NAMED exemption with its reason."
        ;;
    esac
  done <<EOF
${gates}
EOF

  if [ -n "${bad}" ]; then
    echo "gate: assert_argvscoped_gates_current: FAILED — ${wired} of ${denom} argv-scoped compiler gate(s) wired" >&2
    echo "${bad}" | sed 's/^/gate:   /' >&2
    exit 2
  fi
  echo "gate: assert_argvscoped_gates_current: ${wired} of ${denom} gate(s) whose harness scans compiler/ are in the selfhost bucket"
}
