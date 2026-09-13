#!/usr/bin/env bash
# The fifth, named-single-gate scope assertion, split out of
# scripts/gate-envscope.sh when that file crossed test-shellsize's 800-line
# ceiling (#5199 added the test-package-surface exemption and took it to 810).
# A pure move: the banner comment and assert_taskwordssizing_scope_current()
# below are byte-identical to what gate-envscope.sh carried, and
# gate-envscope.sh sources this file at the point they used to sit, so every
# caller keeps working unchanged.
#
# It sits alone because it is the one assertion scoped to a SINGLE named gate
# rather than to a tree, which is also why it reads as a self-contained unit.

# ---------------------------------------------------------------------------
# A FIFTH, NAMED-SINGLE-GATE CASE (#5087). test-taskwords-sizing
# (_tests_/bit/taskwordssizing.bit) scans its scope by inspection like the
# argvscope class above, but its two scan roots are spelled in a way none of
# the other three assertions' patterns catch: `moduleDirs(root,
# "_tests_/stress", ...)` names a tree that ARGVSCOPE_TREES deliberately
# excludes (envscope_bucket_for_tree("_tests_/stress") has no single static
# bucket — it is per-file-routed, see ARGVSCOPE_TREES's own comment above),
# and `bootDirs = ["runtime/root/darwin", "runtime/root/linux",
# "runtime/root/windows"]` is a bare directory-literal array element, not one
# of argvscope_pattern_for_tree()'s three spellings (a `${repo}/<tree>` walk
# root, an exact `"<tree>"` array element, or a `<tree>/<relpath>.bit"`
# source file). Widening that third arm to match ANY quoted "runtime/..."
# string, not just a real `.bit` source, would turn every path-shaped string
# literal under runtime/ into a candidate — far more over-inclusive than
# #4466's own widening, which stayed anchored to real source files — so this
# is a narrow, named probe for this one gate rather than a sixth tree.
#
# Two refusals, neither a silent pass:
#   1. the harness no longer names the scan root(s) this wiring depends on —
#      it moved, and the wiring below is unverifiable, not confirmed correct.
#   2. the harness still names them, but the wiring is missing — the exact
#      defect #5087 exists to close.
TASKWORDSSIZING_HARNESS="_tests_/bit/taskwordssizing.bit"
assert_taskwordssizing_scope_current() {
  local BUCKET BUILD_STEPS stress_hits root_hits stress_gates
  [ -f "${TASKWORDSSIZING_HARNESS}" ] || {
    echo "gate: assert_taskwordssizing_scope_current: ${TASKWORDSSIZING_HARNESS} is gone — refusing to report a verdict" >&2
    exit 2
  }
  stress_hits="$(command grep -vE '^[[:space:]]*//' "${TASKWORDSSIZING_HARNESS}" |
    command grep -cE '"_tests_/stress"' || true)"
  root_hits="$(command grep -vE '^[[:space:]]*//' "${TASKWORDSSIZING_HARNESS}" |
    command grep -cE '"runtime/root/' || true)"
  if [ "${stress_hits}" = "0" ] || [ "${root_hits}" = "0" ]; then
    echo "gate: assert_taskwordssizing_scope_current: did NOT rediscover ${TASKWORDSSIZING_HARNESS}'s own _tests_/stress and runtime/root scan roots (stress_hits=${stress_hits} root_hits=${root_hits}) — the harness moved and the hand-wiring below is unverified. A pattern matching nothing looks exactly like a correctly wired tree; refusing to report a verdict." >&2
    exit 2
  fi
  stress_gates="$(testsbit_steps_for "_tests_/stress/probe.bit")"
  case " ${stress_gates} " in
    *' test-taskwords-sizing '*) ;;
    *)
      echo "gate: assert_taskwordssizing_scope_current: FAILED — test-taskwords-sizing's own harness scans _tests_/stress/**, but testsbit_steps_for() (probed \"_tests_/stress/probe.bit\") does not include it — union it into scripts/gate-filemap.sh's gates_for_file()" >&2
      exit 2
      ;;
  esac
  BUCKET="runtime"
  build_steps_for_bucket
  case " ${BUILD_STEPS[*]} " in
    *' test-taskwords-sizing '*) ;;
    *)
      echo "gate: assert_taskwordssizing_scope_current: FAILED — test-taskwords-sizing's own harness scans runtime/root/**, but the runtime bucket's BUILD_STEPS (scripts/gate-buildsteps.sh) does not include it — a runtime/root/**-only diff never runs it" >&2
      exit 2
      ;;
  esac
  echo "gate: assert_taskwordssizing_scope_current: test-taskwords-sizing wired into both _tests_/stress/* (gates_for_file) and the runtime bucket (BUILD_STEPS)"
}
