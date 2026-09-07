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
}
