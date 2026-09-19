#!/usr/bin/env bash
# scripts/gate-resume.sh — the last-fully-green-baseline mechanism (#3257)
# behind scripts/gate.sh's --mark-green/--resume flags. Split out of
# scripts/gate-filemap.sh by #5610 as a PURE MOVE: gate_step_names_from(),
# registered_gate_names(), registered_gate_names_at(), gates_added_since(),
# read_last_green_sha(), write_last_green_sha(), gatebatch_rc_stamp(),
# gatebatch_stamp_matches(), verify_full_green_now(), gate_do_mark_green(),
# gate_resume_set_range(), gate_resume_inject_new_gates() and
# gate_resume_report_push_ok() are byte-identical below, only relocated.
#
# WHY THIS IS A SPLIT AND NOT A NEW SCRIPT, restated from gate-diffclass.sh's
# own header: this repo's standing rule is "do not ADD a script to scripts/
# — extend an existing one or add a Gate{}". Nothing new is added here:
# scripts/gate-filemap.sh is still the one and only entry point, it sources
# this file at the exact point these functions used to sit, and every caller
# keeps `. scripts/gate-filemap.sh` unchanged. There is no path by which this
# file is invoked on its own — it defines functions and runs nothing at
# source time (unlike gate-filemap.sh itself, which calls
# assert_dirgates_current() and assert_sharedmodule_gates_current() at
# source time — this file's functions only run from gate.sh's own
# --mark-green/--resume branches).
#
# WHY THIS BLOCK AND NOT ANOTHER. gate-filemap.sh sat at exactly 800/800
# (_tests_/bit/shellsize.bit's hard-zero ceiling, #4232) with zero headroom
# for the next _tests_/bit/ subdirectory module's gates_for_file() arm
# (#5610, three such modules created in one day). This baseline mechanism
# never calls gates_for_file(), testsbit_steps_for(), or anything else in the
# file-to-gate mapping half of that file — it answers a different question
# (is HEAD provably reproven since the last full green run, for --resume/
# --mark-green), shares no state with the mapping tables, and was only ever
# bolted onto that file because #3257 predates this ceiling being hit a
# second time. Moving it out, unchanged, is the same shape #4610 already used
# carving gate-diffclass.sh out of this same file.
#
# Sourced by scripts/gate-filemap.sh; do not source it directly, and do not
# execute it. Paths below are relative to the repo root, gate.sh's convention.

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
