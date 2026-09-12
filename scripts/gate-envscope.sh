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
#
# There are now THREE assertions here, one per way a gate can declare its
# scope, and each states its own limits:
#   assert_envscoped_gates_current   env: BIT_*_TREES=          (#4454)
#   assert_argvscoped_gates_current  a walk inside the harness  (#4465/#4466)
#   assert_argvliteral_gates_current argv: bare "${repoRoot()}/<dir>" (#4477)
# The third exists because the first two provably could not see test-fmt, whose
# argv literally named ${repoRoot()}/pkg while the pkg bucket did not run it.

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

  # The argv-path-literal half (#4477), chained from the same entry point and
  # for the same reason: scripts/gate.sh sits at exactly 800 lines against the
  # hard-zero shell ceiling and has no room for another call site. All three
  # halves check the one rule gate.sh's header states, and none is optional.
  assert_argvliteral_gates_current

  # The single-gate case (#5087), chained here for the same line-budget
  # reason as the three halves above.
  assert_taskwordssizing_scope_current
}

# ---------------------------------------------------------------------------
# THE ARGV-SCOPED HALF (#4465, widened to five trees by #4466).
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
# SCOPE, STATED PRECISELY: #4465 shipped this for the `compiler` tree ONLY and
# said so; #4466 widened it to the five trees ARGVSCOPE_TREES names below, and
# the four trees it still does not cover are listed there with the measurement
# behind each. Widening was not mechanical — a wider pattern turns up
# CANDIDATES, not dark gates, and #4466 judged each one: four joined a bucket
# (test-fmt-citations in runtime and stdlib, test-release-surface in stdlib,
# test-lint-complexity in pkg) and eight became named exemptions in
# argvscope_exempt_gate() below, each with its evidence. A candidate list is
# not a wiring list.

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
# directly (test-fmt, test-selfhostcheck, test-stdlib-unit) do not match here —
# assert_argvliteral_gates_current() below covers those.
#
# THIS COMMENT USED TO SAY THEY "do not need to: gate-filemap.sh's
# gates_for_file() already ties those back to their bucket by argv-literal
# matching, which is the half that has worked since #2903." THAT WAS WRONG, and
# it is the reasoning that let #4477 through. gates_for_file() resolves a
# CHANGED FILE to a gate, and only for _tests_/** paths; it never reads a gate's
# argv and has nothing to say about whether a BUCKET's step list carries one.
# test-fmt named ${repoRoot()}/pkg in its argv and was absent from the pkg
# bucket for as long as that bucket existed, with this comment asserting it was
# covered.
argv_gate_paths() {
  sed -n 's/.*Gate{name: "\([^"]*\)".*runArgs("\([^"]*\)").*/\1 \2/p' \
    tools/build/gates.bit tools/build/gatestable2.bit
}

# The scan-root spellings a harness uses to name the tree "$1", as an extended
# regex over its own .bit source:
#   ${repo}/<tree> , ${repoRoot()}/<tree>      — a walk root
#   [ "<tree>"  or  , "<tree>"  or  ^"<tree>"  — a dirNames array element
#   "<tree>/<relpath>.bit"                     — a named source inside it
# Deliberately NOT a bare `"<tree>"` anywhere: _tests_/bit/walkbitcheck.bit
# mentions `walk("compiler")` in a comment and scans nothing, and a pattern
# that cannot tell a comment from a scan root produces a candidate list nobody
# will trust; whole-line `//` comments are stripped before matching for the
# same reason.
#
# Concatenated, never printf'd: `\$` and `\{` are not printf escapes, and what
# bash's printf does with an unknown escape is not something to rest a regex on.
#
# #4466 WIDENED THE THIRD ARM, `<tree>/[a-zA-Z0-9_]+\.bit"` -> `[a-zA-Z0-9_/]+`,
# so the leaf may cross `/`. compiler/ is flat, so this changes nothing there
# (still exactly the 9 gates #4465 measured, re-derived on this tree). runtime/
# and stdlib/ are not flat, and a literal naming one of their sources is
# spelled `"${repo}/runtime/root/rootclasses.bit"`: the narrow leaf found 9
# runtime candidates, the wide one 11. Both extra gates (test-stwwiring,
# test-threadtokenbytes) are already in the runtime bucket, so the widening
# cost no new wiring and closed a real blind spot.
#
# WHAT IT CANNOT DO, measured on #4465 rather than assumed: the
# `<tree>/<relpath>.bit"` arm matches that spelling anywhere in the source,
# including inside a diagnostic STRING — renaming both of abimembers.bit's real
# scan roots still leaves it discovered, off its own message text. So this
# proves membership in the class, not that a gate has LEFT it. That is the
# over-inclusive direction: at worst it demands a gate be wired that need not
# be, which fails loudly and is settled by wiring it or naming it below.
argvscope_pattern_for_tree() {
  printf '%s\n' '\$\{repo(Root\(\))?\}/'"$1"'|(^|[[,])[[:space:]]*"'"$1"'"|'"$1"'/[a-zA-Z0-9_/]+\.bit"'
}

# Prints the gate names whose own harness source scans tree "$1", one per line,
# sorted and deduplicated.
argvscoped_gates_for_tree() {
  local pat gate path srcs src hits
  pat="$(argvscope_pattern_for_tree "$1")"
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
        | command grep -cE "${pat}" || true)"
      [ "${hits}" = "0" ] && continue
      printf '%s\n' "${gate}"
      break
    done
  done | sort -u
}

# THE TREES THIS ASSERTION COVERS. #4465 shipped `compiler` alone and said so;
# #4466 added the other four trees that envscope_bucket_for_tree() routes to a
# STATIC bucket. The four it does not cover, each for a measured reason:
#
#   tools            — envscope_bucket_for_tree()'s own named exemption: every
#                      tools/** diff outside a purely-additive registration
#                      resolves to `full`, which runs every gate. (6 candidates
#                      here, and no bucket for any of them to be missing from.)
#   _tests_/cases    — 1 candidate on this tree, test-fuzz
#                      (`envOr("BIT_FUZZ_CASES", "_tests_/cases")`), and it is
#                      already in the `testcases` bucket. Measured, not assumed:
#                      the tree is clean today, so wiring nothing is the honest
#                      outcome and a loop over it would only add a report line.
#   _tests_/bit, _tests_/stress, _tests_/imports
#                    — these route through testsbit_steps_for(<probe file>),
#                      per changed FILE rather than to one static step list, so
#                      "the bucket that tree maps to" is not a single list to
#                      compare against (9 candidates for _tests_/bit). The two
#                      assertions above that DO handle those trees each carry a
#                      probe-path table for exactly this reason; adding a third
#                      is a decision about which probe stands for a whole tree,
#                      which is its own ticket, not a widening of this one.
ARGVSCOPE_TREES="compiler runtime stdlib examples pkg"

# The live-query floor, per tree. These gates are in their tree's class by
# inspection and none can leave it without its harness being rewritten, so a
# run that fails to rediscover one has a broken pattern, not a cleaner tree.
# Named rather than counted on purpose: a count silently absorbs one gate
# leaving the class while another joins it, the property that retired this
# repo's fmt ceilings (#3713). A tree in ARGVSCOPE_TREES with no floor arm is
# itself a hard failure in the caller — an empty floor cannot fail.
argvscope_floor_for_tree() {
  case "$1" in
    compiler) printf '%s\n' "test-abimembers test-lint-filelines test-lint-self test-fmt-roundtrip" ;;
    runtime) printf '%s\n' "test-abimembers test-lint-runtime test-lint-self test-fmt-citations" ;;
    stdlib) printf '%s\n' "test-lint-self test-lint-sweep test-release-surface" ;;
    examples) printf '%s\n' "test-examples test-lint-filelines" ;;
    pkg) printf '%s\n' "test-packages test-lint-sweep test-lint-complexity test-package-release-drift" ;;
    *) return 1 ;;
  esac
}

# NAMED EXEMPTIONS: (tree, gate) pairs this assertion discovers but must NOT
# demand a bucket for. Every one is a judgment with its evidence, never a
# silent skip — #4466's whole point is that the candidate list is not a wiring
# list. Returns 0 when exempt.
#
#   test-fmt-roundtrip, every tree but compiler — #4451 wired it into
#     `selfhost` ONLY, with its reason stated on that ticket: the regression it
#     exists for is a formatter bug in compiler/fmt*.bit, which is
#     compiler-domain and forces `selfhost`; the corpus-content risk for the
#     other eight trees (a new file hitting an existing formatter edge case) is
#     covered by test-fmt / test-fmt-strict running `bit fmt --check` over
#     those trees, which every one of these buckets already runs. It stays
#     CHECKED for compiler, where it is wired.
#   stdlib test-pmimports / test-pmvanity / test-pmaddgit / test-pmrangegate —
#     a FIXTURE PATH, not a scan root. Each harness's hit is
#     `envOr("BIT_STDLIB_UNDER_TEST", "stdlib")`, and the gate table sets that
#     var to ${stdlibRoot()}; the value is passed straight through to a child
#     compiler as `BIT_STDLIB=` under `env -i` (see runBitCli in
#     _tests_/bit/pmimports.bit) so a scratch project can resolve `std/...`.
#     The stdlib is a BUILD INPUT there, not the subject of any assertion. If a
#     build input counted as scope, every gate that compiles a Bit program would
#     be stdlib-scoped and the `stdlib` bucket would BE the full suite.
#   stdlib test-stdlib-rebuild — a coreSteps() Step, "not part of `test`" by its
#     own desc (tools/build/defs.bit), so no bucket runs it and gate.sh has no
#     scoping responsibility for it. Same class the failure text below names.
#   (test-release-surface WAS exempted here ON COST — 25m42s measured on
#     2026-09-09 — and is now WIRED into the stdlib bucket by #4691. That cost
#     was never this gate's own work: it wrote 291 single-use scripts per run
#     and `execve`'d each one, paying macOS's system-wide `com.apple.provenance`
#     validation 291 times — #3778's `test-golden` tax again, in a harness that
#     never got #3778's fix. With the exec removed the same run does ~15s of
#     real compiler work. See _tests_/bit/releasesurface/shellrun.bit's header.)
#   pkg test-package-${p} — not a gate name: gates.bit builds one Gate per
#     package inside a `for p of packageNames()` loop, so the TABLE holds the
#     unexpanded template. Its expansions are one-package subsets of
#     test-packages, which the pkg bucket already runs, and defs.bit marks them
#     "not part of `test` or `test-packages`".
#   compiler test-taskwords-sizing (#5087) — its sole compiler-pattern hit is
#     `exists("${c}/compiler/codegen.bit")`, the repo-root-locator idiom
#     _tests_/bit/threadtokenbytes.bit's own header cites as shared convention
#     (used only to FIND the repo root by walking up, same as BIT_REPO's
#     fallback search). It never reads compiler/ content: its real scan roots
#     are `_tests_/stress` and the three `runtime/root/<os>/boot.bit` modules,
#     already wired via gates_for_file() and the runtime bucket. Wiring it into
#     `selfhost` too would run it on every compiler-only diff, which the
#     ticket that added it (#5087) states is exactly what a scoped bucket must
#     not do.
argvscope_exempt_gate() {
  case "$1 $2" in
    "compiler test-fmt-roundtrip") return 1 ;;
    *' test-fmt-roundtrip') return 0 ;;
  esac
  case "$1 $2" in
    'stdlib test-pmimports' | 'stdlib test-pmvanity' | 'stdlib test-pmaddgit') return 0 ;;
    'stdlib test-pmrangegate' | 'stdlib test-stdlib-rebuild') return 0 ;;
    'pkg test-package-${p}') return 0 ;;
    'compiler test-taskwords-sizing') return 0 ;;
  esac
  return 1
}

# Refuses unless every floor gate for tree "$1" is in the discovered list "$2".
argvscope_assert_floor() {
  local want
  for want in $(argvscope_floor_for_tree "$1"); do
    case "
$2
" in
      *"
${want}
"*) ;;
      *)
        echo "gate: assert_argvscoped_gates_current: did NOT rediscover \"${want}\", which scans the ${1} tree by inspection — argvscope_pattern_for_tree() (scripts/gate-envscope.sh) has stopped matching, or that harness moved. A pattern matching nothing looks exactly like a correctly wired tree; refusing to report a verdict." >&2
        exit 2
        ;;
    esac
  done
}

# Checks one tree and prints its own verdict line. Appends to the CALLER's
# `bad` (bash dynamic scoping, the same mechanism this file already uses to
# shadow BUCKET/BUILD_STEPS) rather than returning findings through a command
# substitution, which would run in a subshell and lose them.
argvscope_check_tree() {
  local tree="$1" bucket gates gate denom=0 wired=0 exempt=0
  local BUCKET BUILD_STEPS
  bucket="$(envscope_bucket_for_tree "${tree}")" || bucket=""
  if [ -z "${bucket}" ] || [ "${bucket}" = "testsbit" ]; then
    echo "gate: assert_argvscoped_gates_current: tree \"${tree}\" is in ARGVSCOPE_TREES but envscope_bucket_for_tree() gives it no single static bucket — it is exempt or per-file-routed, and this assertion cannot compare it against one step list. Remove it from ARGVSCOPE_TREES or give it a probe table." >&2
    exit 2
  fi
  gates="$(argvscoped_gates_for_tree "${tree}")"
  argvscope_assert_floor "${tree}" "${gates}"
  BUCKET="${bucket}"
  build_steps_for_bucket
  while IFS= read -r gate; do
    [ -n "${gate}" ] || continue
    if argvscope_exempt_gate "${tree}" "${gate}"; then
      exempt=$((exempt + 1))
      continue
    fi
    denom=$((denom + 1))
    case " ${BUILD_STEPS[*]} " in
      *" ${gate} "*) wired=$((wired + 1)) ;;
      *)
        bad="${bad:+${bad}
}gate \"${gate}\"'s own harness scans the ${tree} tree, but the \"${bucket}\" bucket's BUILD_STEPS (scripts/gate-buildsteps.sh) does not include it — a diff touching only ${tree} never runs it. Wire it into that bucket, or, if it is a coreSteps() gate outside \`./make test\` and so outside gate.sh's scoping responsibility, or a fixture path rather than a scan root, add it to argvscope_exempt_gate() here with its reason."
        ;;
    esac
  done <<EOF
${gates}
EOF
  echo "gate: assert_argvscoped_gates_current: ${tree}: ${wired} of ${denom} gate(s) whose harness scans ${tree}/ are in the ${bucket} bucket (${exempt} named exemption(s))"
}

# Asserts, for every tree in ARGVSCOPE_TREES, that each gate whose harness
# scans that tree is in the bucket that tree maps to. Probes the LIVE
# build_steps_for_bucket() rather than a second copy of the step list, same as
# assert_envscoped_gates_current() above, so the only way to pass is to
# actually wire the gate in.
assert_argvscoped_gates_current() {
  local tree bad=""
  assert_envscope_deps
  for tree in ${ARGVSCOPE_TREES}; do
    argvscope_check_tree "${tree}"
  done
  if [ -n "${bad}" ]; then
    echo "gate: assert_argvscoped_gates_current: FAILED — argv-scoped gate(s) missing from the bucket their tree maps to:" >&2
    echo "${bad}" | sed 's/^/gate:   /' >&2
    exit 2
  fi
}

# ---------------------------------------------------------------------------
# THE ARGV-PATH-LITERAL HALF (#4477).
#
# A FOURTH route to the same defect, and the one neither assertion above can
# see. assert_envscoped_gates_current() reads scope out of `env:`
# (BIT_*_TREES); assert_argvscoped_gates_current() reads it out of a harness's
# own source for gates whose argv is a single runArgs() fixture target. A gate
# whose argv is a list of BARE SOURCE-TREE PATHS — `["fmt", "--check",
# "${repoRoot()}/stdlib", ..., "${repoRoot()}/pkg", ...]` — is in neither set:
# argv_gate_paths() above matches only `runArgs("...")` and says so, and
# gates_for_file() (scripts/gate-filemap.sh) resolves a CHANGED FILE to a gate,
# which is a different question from whether a BUCKET's step list carries it.
#
# test-fmt sat in the `stdlib` and `examples` buckets and not in `pkg`, while
# its own argv named all three, so a pkg/**-only diff never ran the formatter
# gate that literally names pkg/ (#4477). Two more of the same shape fell out
# of this assertion the first time it ran: test-stdlib-unit missing from the
# `stdlib` bucket (#4478) and test-fmt missing from the `_tests_/imports`
# per-file mapping (#4479).
#
# WHAT IT CANNOT DO, two limits, both real:
#
#   1. It reads the gate TABLE, so it only sees scope a gate spells out in its
#      own argv. A gate that computes a path at runtime, or takes it from an env
#      var, is invisible here — that is what the other two assertions cover,
#      each within its own stated limits.
#   2. It maps an argv path to exactly ONE bucket, and has no notion of a
#      COMPOSITE bucket that must also carry the gate. `stdlibdocs` (chosen when
#      a diff touches stdlib/** and docs/stdlib/*.md together) claims in its own
#      comment to be the union of `stdlib` and `docs`, and is not — measured
#      2026-09-08, it is missing four of `stdlib`'s steps, so adding a docs edit
#      to a stdlib diff makes gate.sh run FEWER checks over the stdlib change.
#      That is #4480, and this assertion is green across it: `stdlib` carries
#      test-fmt and test-stdlib-unit, which is all it asks.

# Emits "<gate> <relpath>" for every BARE `"${repoRoot()}/<relpath>"` argv
# string, scanning both gate tables in one pass. Line-based and name-tracking,
# exactly like envscoped_gate_trees() above, with two extra rules:
#
#   * the opening quote must sit immediately before `${repoRoot()}`, which is
#     what separates an argv path (`"${repoRoot()}/pkg"`) from an env entry
#     (`"BIT_CASES_DIR=${repoRoot()}/_tests_/cases"`). The env entries are
#     already assert_envscoped_gates_current()'s business and must not be
#     double-counted here under a different routing table.
#   * `[^"$]` after the prefix drops any path with a further `${...}` in it —
#     `"${repoRoot()}/${src}"` (runArgs()'s own body) and
#     `"${repoRoot()}/bit-out/lib/${hostTriple()}/libbitrt.a"` are templates,
#     not literals, and neither names a source tree.
#
# `name` is also reset on every line opening a top-level `fn `, so a
# `${repoRoot()}` literal inside a HELPER can never be attributed to whichever
# Gate{} happened to be scanned last.
#
# STATED HONESTLY: that reset is INERT on today's tree — removing it changes
# nothing (measured: same 6 gates / 10 paths / 6 routed pairs, rc=0), because
# every helper holding such a literal (bitBin(), stdlibRoot(), hostArchive(),
# packageNames()'s `let dir = "${repoRoot()}/pkg"`) sits ABOVE the first Gate{}
# in tools/build/gates.bit, and runArgs()'s own `"${repoRoot()}/${src}"` is
# dropped by the `[^"$]` rule regardless. It is kept because that ordering is
# nobody's invariant. Proven load-bearing rather than assumed: appending
# `fn synthHelper(): string { return "${repoRoot()}/nosuchtree" }` after the
# last Gate{} in gatestable2.bit is clean with the reset (rc=0) and, without
# it, blames test-extern-archive for a path that gate never declared (rc=2,
# 7 gates / 11 paths) — a false finding that fails loudly at an innocent gate.
argvliteral_gate_paths() {
  local file line name m p
  for file in tools/build/gates.bit tools/build/gatestable2.bit; do
    name=""
    while IFS= read -r line; do
      case "${line}" in
        'fn '*) name="" ;;
      esac
      case "${line}" in
        *'Gate{name: "'*)
          name="$(printf '%s' "${line}" | sed -n 's/.*Gate{name: "\([^"]*\)".*/\1/p')"
          ;;
      esac
      [ -n "${name}" ] || continue
      m="$(printf '%s' "${line}" | command grep -oE '"\$\{repoRoot\(\)\}/[^"$]+"' || true)"
      [ -n "${m}" ] || continue
      # No path in either table contains a space, same assumption
      # envscoped_gate_trees()'s own `for pair in ${m}` already makes.
      for p in ${m}; do
        p="${p#\"\$\{repoRoot()\}/}"
        printf '%s %s\n' "${name}" "${p%\"}"
      done
    done <"${file}"
  done
}

# Maps a source-tree relpath named in a gate's argv to the gate.sh bucket whose
# step list must carry that gate. Deliberately a SEPARATE table from
# envscope_bucket_for_tree() above even though the two overlap: that one routes
# BIT_*_TREES names, this one routes argv paths, and the two sets of spellings
# are not the same (this one sees `docs`, `bench`, `editors` and
# `tools/fuzz/*.bit`, which no BIT_*_TREES entry names).
#
# NAMED EXEMPTIONS — print nothing, return 0. Each states its reason; an
# unknown path is a hard failure in the caller, never a silent skip.
#
#   bench, editors — no bucket exists for either (scripts/gate.sh's per-path
#     case block has no arm for them), so any diff touching one sets
#     has_other=1 and resolves to bucket `full`, which runs every gate via the
#     aggregate `test` step. Verified, not assumed: `RANGE=... bash
#     scripts/gate.sh` on a bench/-only diff prints `bucket: full` and exits 3.
#   _tests_/freestanding, _tests_/testproj — the same has_other=1 -> `full`
#     route, and stated as such in scripts/gate-filemap.sh's own header for
#     testproj: scripts/gate-classify.sh's `case` has no arm for either (they
#     are siblings of _tests_/bit, _tests_/imports and _tests_/stress, not
#     those paths), so a diff touching one never sets has_testsbit and falls
#     to the generic `*)` catch-all. #4681 put both trees in test-fmt's argv
#     because NO fmt gate named them, which is what brings them here; a bucket
#     of their own was rejected for testproj by #4153 on two measured grounds
#     (no line budget in gate.sh, and wiring its only consumer
#     scripts/selfhost-difftests.sh would fail assert_full_is_superset()).
#   tools, tools/** — the same has_other=1 -> `full` route (the one narrow
#     exception, a purely-additive Step{}/Gate{} registration, is handled by
#     is_additive_registration() in scripts/gate-diffclass.sh and still runs the
#     added gate). The three gates reaching this arm today
#     (test-fuzz-selfcheck/-odiff/-xtarget) are additionally outside gate.sh's
#     scoping responsibility altogether: all three are registered in
#     tools/build/defs.bit's coreSteps(), not gateSteps() — their own desc
#     strings say "not part of `test`" — so no bucket runs them at all.
argvliteral_bucket_for_dir() {
  case "$1" in
    bench | editors | tools | tools/*) return 0 ;;
    _tests_/freestanding | _tests_/testproj) return 0 ;;
    compiler) printf 'selfhost\n' ;;
    runtime) printf 'runtime\n' ;;
    stdlib) printf 'stdlib\n' ;;
    examples) printf 'examples\n' ;;
    pkg) printf 'pkg\n' ;;
    docs) printf 'docs\n' ;;
    spec) printf 'spec\n' ;;
    _tests_/cases) printf 'testcases\n' ;;
    _tests_/bit | _tests_/stress | _tests_/imports) printf 'testsbit\n' ;;
    *) return 1 ;;
  esac
}

# The live-query floor, named rather than counted for the same reason
# argvscope_floor_for_tree() is: a count silently absorbs one gate leaving the
# class while another joins it. These three declare a bare source-tree argv
# path today and cannot stop doing so without being rewritten, so a run that
# fails to rediscover one has a broken extraction, not a cleaner tree — the
# failure mode that reads as an all-clear.
ARGVLITERAL_FLOOR="test-fmt test-selfhostcheck test-stdlib-unit"

# Asserts every gate naming a bare source-tree path in its argv is in the
# bucket that path maps to. Probes the LIVE build_steps_for_bucket() /
# testsbit_steps_for(), never a second copy of the step lists, so the only way
# to pass is to actually wire the gate in.
#
# Shadows BUCKET/BUILD_STEPS as locals, so it never disturbs the real diff's
# own bucket selection running around it in scripts/gate.sh.
assert_argvliteral_gates_current() {
  local pairs pair gate dir bucket probe result want
  local gates=0 dirs=0 checked=0 seen="" seendir="" bad=""
  local BUCKET BUILD_STEPS
  assert_envscope_deps
  pairs="$(argvliteral_gate_paths)"
  for want in ${ARGVLITERAL_FLOOR}; do
    case "
${pairs}
" in
      *"
${want} "*) ;;
      *)
        echo "gate: assert_argvliteral_gates_current: did NOT rediscover \"${want}\", whose argv names a bare \${repoRoot()}/<dir> path by inspection — argvliteral_gate_paths() (scripts/gate-envscope.sh) has stopped matching, or that gate's argv changed. An extraction matching nothing looks exactly like a correctly wired tree; refusing to report a verdict." >&2
        exit 2
        ;;
    esac
  done

  while IFS= read -r pair; do
    [ -z "${pair}" ] && continue
    gate="${pair%% *}"
    dir="${pair#* }"
    case " ${seen} " in
      *" ${gate} "*) ;;
      *) seen="${seen:+${seen} }${gate}"; gates=$((gates + 1)) ;;
    esac
    case " ${seendir} " in
      *" ${dir} "*) ;;
      *) seendir="${seendir:+${seendir} }${dir}"; dirs=$((dirs + 1)) ;;
    esac

    bucket="$(argvliteral_bucket_for_dir "${dir}")" || {
      bad="${bad:+${bad}
}gate \"${gate}\" names argv path \"${dir}\" that argvliteral_bucket_for_dir() (scripts/gate-envscope.sh) does not know how to route — add a case arm naming the bucket, or a named exemption with its reason"
      continue
    }
    [ -z "${bucket}" ] && continue
    checked=$((checked + 1))
    if [ "${bucket}" = "testsbit" ]; then
      case "${dir}" in
        _tests_/bit) probe="_tests_/bit/golden/probe.bit" ;;
        _tests_/stress) probe="_tests_/stress/probe.bit" ;;
        _tests_/imports) probe="_tests_/imports/probe.bit" ;;
      esac
      result="$(testsbit_steps_for "${probe}")"
      case " ${result} " in
        *" ${gate} "*) ;;
        *)
          bad="${bad:+${bad}
}gate \"${gate}\" names argv path \"${dir}\" but testsbit_steps_for() (probed \"${probe}\") does not include it — union it into scripts/gate-filemap.sh's gates_for_file()"
          ;;
      esac
    else
      BUCKET="${bucket}"
      build_steps_for_bucket
      case " ${BUILD_STEPS[*]} " in
        *" ${gate} "*) ;;
        *)
          bad="${bad:+${bad}
}gate \"${gate}\" names argv path \"${dir}\" but bucket \"${bucket}\"'s BUILD_STEPS (scripts/gate-buildsteps.sh) does not include it — a ${dir}/**-only diff never runs it"
          ;;
      esac
    fi
  done <<EOF
${pairs}
EOF

  if [ -n "${bad}" ]; then
    echo "gate: assert_argvliteral_gates_current: FAILED — ${gates} gate(s) naming ${dirs} distinct argv path(s), ${checked} (gate,path) pair(s) routed to a bucket:" >&2
    echo "${bad}" | sed 's/^/gate:   /' >&2
    exit 2
  fi
  echo "gate: assert_argvliteral_gates_current: ${gates} gate(s) naming ${dirs} distinct argv path(s); ${checked} (gate,path) pair(s) routed to a bucket, all wired"
}

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
