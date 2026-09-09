#!/usr/bin/env bash
# scripts/gate-diffclass.sh — the diff-shape helpers behind scripts/gate.sh's
# THREE NARROW EXCEPTIONS (#2435, #3055). Split out of
# scripts/gate-filemap.sh by #4610 as a PURE MOVE: hunk_is_safe(),
# is_additive_registration() and stdlib_docs_pairing_ok() are byte-identical
# below, only relocated, together with the block header #4234 wrote when it
# moved them out of gate.sh in the first place.
#
# WHY THIS IS A SPLIT AND NOT A NEW SCRIPT. This repo's standing rule is "do
# not ADD a script to scripts/ — extend an existing one or add a Gate{}".
# Nothing new is added here: scripts/gate-filemap.sh is still the one and only
# entry point, it sources this file at the exact point these functions used to
# sit, and every caller keeps `. scripts/gate-filemap.sh` unchanged. There is
# no path by which this file is invoked on its own — it defines functions and
# runs nothing at source time. That is the same shape #3480, #4234 and #4454
# already used carving gate-filemap.sh, and gate-envscope.sh out of files that
# had run out of room under the 800-line hard-zero shell ceiling
# (_tests_/bit/shellsize.bit, #4232).
#
# WHY THIS BLOCK AND NOT ANOTHER. gate-filemap.sh is named for, and is about,
# resolving a CHANGED FILE to the gate(s) that cover it (gates_for_file,
# assert_dirgates_current, testsbit_steps_for). These three functions answer a
# different question — whether the SHAPE of a diff to one already-mapped file
# is additive enough to stay in a narrow bucket — and share no state with the
# mapping tables. Moving them buys gates_for_file() back the headroom #4556
# spent its last two lines on: adding an arm is routine (#4426, #4441, #4447,
# #4556 in one month) and had no line left to spend.
#
# Both functions read globals their caller sets, unchanged by the move (bash
# dynamic scope does not care which file defines a function):
# is_additive_registration() reads ${RANGE}; stdlib_docs_pairing_ok() reads
# ${docs_files}/${stdlib_files}, both set by gate.sh's classification loop.
#
# Sourced by scripts/gate-filemap.sh; do not source it directly, and do not
# execute it. Paths below are relative to the repo root, gate.sh's convention.

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
