#!/usr/bin/env bash
# Render the release notes for <version> from conventional commits.
#
#   dist/changelog.sh <version> [<ref>]
#
# <ref> is the commit the release is cut from (default HEAD). The range is the
# previous `v*` tag reachable from <ref> to <ref>; with no previous tag the
# whole history is used. Requires a full clone (fetch-depth: 0) - a shallow one
# silently yields an empty log, so this fails loudly on an empty range instead.
set -euo pipefail

VERSION="${1:?usage: changelog.sh <version> [<ref>]}"
REF="${2:-HEAD}"

PREV="$(git describe --tags --abbrev=0 --match 'v*' "${REF}^" 2>/dev/null || true)"
if [ -n "${PREV}" ]; then
  RANGE="${PREV}..${REF}"
else
  RANGE="${REF}"
fi

COMMITS="$(git log --no-merges --reverse --pretty=format:'%s|%h' "${RANGE}" || true)"
[ -n "${COMMITS}" ] || { echo "changelog.sh: no commits in range ${RANGE}" >&2; exit 1; }

# Conventional-commit bucketing. `type(scope): subject` and `type!: subject`;
# a `!` marks a breaking change and is listed first regardless of its type.
#
# EVERY COMMIT IS CLAIMED, NOT COPIED. `take` moves the lines it matches out of
# `REMAINING`, so a commit lands in exactly one section and the leftovers are
# always exactly what nothing has explained yet. That is what makes the
# accounting guard below a real assertion rather than a hope.
REMAINING="${COMMITS}"
EMITTED=0
BODY=""

# Move every REMAINING line matching <pattern> into BODY, in log order.
take() {
  BODY="$(printf '%s\n' "${REMAINING}" | grep -E "$1" || true)"
  [ -n "${BODY}" ] || return 0
  # -F with a multi-line pattern is a set of literal patterns; -x anchors each
  # to a whole line, so a subject that is a prefix of another cannot claim it.
  REMAINING="$(printf '%s\n' "${REMAINING}" | grep -vxF -e "${BODY}" || true)"
}

# Internal task ids are meaningless to a reader: nothing outside this workspace
# can resolve one, and this repo writes `(#NNNN)` into almost every commit
# subject. Strip them as the subject is rendered, so a release note cannot carry
# one whatever the commit said. The short sha stays - anyone with a clone can
# resolve that, which is exactly what the id is not.
#
# Three shapes, in order, because the later rules would mangle the earlier ones:
#   1. a parenthetical group opening with the id, with or without trailing words
#      ("(#3842)", "(#5597 fallout)", "(#1906/#4253)")
#   2. a possessive ("#5604's split") -> "the split", which keeps the sentence
#      grammatical; deleting the token outright leaves "after split"
#   3. anything else still bare
# A run is slash- or comma-separated ("Fix #5409/#5410:", "merging #2344/#2022")
# and must be matched as one: a per-id rule consumes the separator, so the
# second id in a run survives. Removing a run that OPENED the subject leaves a
# stray ": " or " : ", hence the two punctuation rules - both narrow, and the
# trailing-colon case is deliberately untouched.
# Deliberately NO punctuation tidying. An earlier draft collapsed " :" to ":"
# and corrupted the subject "fmt: emit = for keyed class field inits, not :",
# whose trailing colon is the thing the commit is about.
stripInternalRefs() {
  sed -E -e 's/[[:space:]]*\(#[0-9]{2,6}[^)]*\)//g' \
         -e "s/#[0-9]{2,6}'s/the/g" \
         -e 's/(^|[^0-9A-Za-z_])#[0-9]{2,6}((\/|, ?)#[0-9]{2,6})*/\1/g' \
         -e 's/[[:space:]]+:([[:space:]])/:\1/g' \
         -e 's/^[[:space:]]*[:,;]*[[:space:]]*//' \
         -e 's/[[:space:]]{2,}/ /g' \
         -e 's/[[:space:]]+$//'
}

emit() {
  local title="$1" body="$2"
  [ -n "${body}" ] || return 0
  EMITTED=$((EMITTED + $(printf '%s\n' "${body}" | grep -c .)))
  printf '### %s\n\n' "${title}"
  printf '%s\n' "${body}" | while IFS='|' read -r subject sha; do
    printf -- '- %s (%s)\n' \
      "$(printf '%s' "${subject}" \
         | sed -E 's/@([A-Za-z0-9][A-Za-z0-9-]*)/`@\1`/g' \
         | stripInternalRefs)" \
      "${sha}"
  done
  printf '\n'
}

printf '## Bit %s\n\n' "${VERSION}"
take '^[a-z][a-z0-9+-]*(\([^)]*\))?!:' ; emit 'Breaking changes' "${BODY}"
take '^feat(\([^)]*\))?:'              ; emit 'Features'         "${BODY}"
take '^fix(\([^)]*\))?:'               ; emit 'Fixes'            "${BODY}"
take '^perf(\([^)]*\))?:'              ; emit 'Performance'      "${BODY}"

# Everything else is classified by the FILES it touched, not its subject. A
# subject prefix is optional evidence (and the repo's history shows most
# commits carry none); the paths a commit changed are never absent. This
# replaces a whitelist of conventional `type:` prefixes that had to be
# maintained against a repo that coins new ones (it named `seed` and
# `selfhost` - a directory deleted in #1593 and one renamed to `compiler` in
# #1841 - and never named `compiler` itself, so 41 of 0.1.5's 59 commits were
# reported nowhere and nothing said so, #2061) and a bare `Uncategorised`
# catch-all that, on 0.1.17, swallowed 66 of 80 commits.
#
# ONE `git log --name-only` pass over the whole range builds sha->category,
# so classifying costs one process rather than one per commit. A commit whose
# paths are ALL `.md` is Documentation outright (a `docs(ABI):` commit that
# only touches `runtime/ABI.md` must not be filed under Runtime because of its
# directory). Otherwise each touched path maps to a top-level area and the
# commit is filed under whichever area touched the most files; a repo-root
# file or any unrecognised top-level directory maps to Documentation. Ties -
# including an all-unrecognised commit, which ties at Documentation by
# definition - are broken by the listed order below, so the result is a pure
# function of the tree and is stable across reruns.
CLASSIFICATION="$(git log --no-merges --reverse --name-only --pretty=format:'@@COMMIT@@%h' "${RANGE}" | awk '
  BEGIN {
    order[1] = "Compiler";           order[2] = "Runtime"
    order[3] = "Standard library";   order[4] = "Tests"
    order[5] = "Documentation";      order[6] = "Build and tooling"
    order[7] = "Benchmarks";         order[8] = "Editor support"
    order[9] = "Examples";           norder = 9

    dirmap["compiler"] = "Compiler";   dirmap["runtime"]  = "Runtime"
    dirmap["stdlib"]   = "Standard library"
    dirmap["_tests_"]    = "Tests"
    dirmap["spec"]     = "Documentation"; dirmap["docs"]  = "Documentation"
    dirmap["scripts"]  = "Build and tooling"
    dirmap["tools"]    = "Build and tooling"
    dirmap["dist"]     = "Build and tooling"
    dirmap["docker"]   = "Build and tooling"
    dirmap["bench"]    = "Benchmarks"
    dirmap["editors"]  = "Editor support"
    dirmap["examples"] = "Examples"
    sha = ""
  }
  function flush(   cat, best, bestn, i, c) {
    if (sha == "") return
    if (nfiles > 0 && allmd) {
      cat = "Documentation"
    } else {
      best = "Documentation"; bestn = -1
      for (i = 1; i <= norder; i++) {
        c = order[i]
        if ((c in cnt) && cnt[c] > bestn) { bestn = cnt[c]; best = c }
      }
      cat = best
    }
    print sha "\t" cat
    delete cnt
  }
  /^@@COMMIT@@/ {
    flush()
    sha = $0
    sub(/^@@COMMIT@@/, "", sha)
    nfiles = 0
    allmd = 1
    next
  }
  /^$/ { next }
  {
    top = $0
    sub(/\/.*/, "", top)
    cnt[(top in dirmap) ? dirmap[top] : "Documentation"]++
    nfiles++
    if ($0 !~ /\.md$/) allmd = 0
  }
  END { flush() }
')"

# Tag each still-unclaimed commit with its path category in one pass over
# CLASSIFICATION, then hand out one category at a time the same way `take`
# does: BODY is claimed and removed from REMAINING, so a commit can only ever
# land in the one section its file counts picked.
#
# CLASSIFICATION and REMAINING are joined as two FILES (via process
# substitution), not by handing CLASSIFICATION to awk through `-v`: macOS's
# /usr/bin/awk (the one-true-awk, not gawk) rejects a raw newline inside a
# `-v` value with "newline in string ... at source line 1", and
# CLASSIFICATION is exactly that - a multi-line sha->category table.
TAGGED="$(awk -F'\t' '
  FNR==NR { sha2cat[$1] = $2; next }
  {
    line = $0
    if (match(line, /\|[^|]*$/)) { sha = substr(line, RSTART + 1) } else { sha = line }
    print sha2cat[sha] "\t" line
  }
' <(printf '%s\n' "${CLASSIFICATION}") <(printf '%s\n' "${REMAINING}"))"

# Claim and emit as ONE step, unlike `take`/`emit` above. If claiming were
# split from emitting, a category whose emit call went missing would still
# have its commits silently stripped out of REMAINING by the classification
# step, so the accounting guard below would catch the shortfall but could
# no longer name which commits caused it - the exact failure mode the guard
# exists to rule out. Deleting one `emit_category` call must leave that
# category's commits sitting in REMAINING, not vanished.
emit_category() {
  local cat="$1" body
  body="$(printf '%s\n' "${TAGGED}" | awk -F'\t' -v cat="${cat}" '$1==cat{print $2}')"
  [ -n "${body}" ] || return 0
  REMAINING="$(printf '%s\n' "${REMAINING}" | grep -vxF -e "${body}" || true)"
  emit "${cat}" "${body}"
}

emit_category 'Compiler'
emit_category 'Runtime'
emit_category 'Standard library'
emit_category 'Tests'
emit_category 'Documentation'
emit_category 'Build and tooling'
emit_category 'Benchmarks'
emit_category 'Editor support'
emit_category 'Examples'

# THE POINT OF THE ACCOUNTING. Every commit in the range must appear exactly
# once: `take` claims, so a duplicate is impossible and a shortfall means a
# pattern lost something. Release notes that quietly omit a third of a release
# read as complete, which is why this exits rather than warns -
# dist/release.sh's fallback writes a minimal note when this fails.
TOTAL="$(printf '%s\n' "${COMMITS}" | grep -c .)"
if [ "${EMITTED}" -ne "${TOTAL}" ]; then
  echo "changelog.sh: listed ${EMITTED} of ${TOTAL} commits in ${RANGE}" >&2
  printf '%s\n' "${REMAINING}" | sed 's/^/  unlisted: /' >&2
  exit 1
fi

# THE TARGET LIST IS DERIVED, NEVER RESTATED. dist/release.sh writes
# SHA256SUMS immediately before it calls this, so the artifacts this release
# actually produced are on disk and can be read. This paragraph used to name
# three targets in a hardcoded sentence while every release since the Windows
# artifact landed shipped four, and nothing noticed, because a sentence cannot
# go red. Same failure the release checklist's asset check was rewritten to
# avoid: a restated value certifies whatever the release happened to do the day
# it was written.
#
# Filenames are <os>-<arch>; the prose says <arch>-<os>, hence the swap.
SUMS_FILE="$(dirname "$0")/out/SHA256SUMS"
TARGETS=""
if [ -f "${SUMS_FILE}" ]; then
  VER_RE="$(printf '%s' "${VERSION}" | sed 's/\./\\./g')"
  TARGETS="$(awk 'NF>=2 {print $2}' "${SUMS_FILE}" |
    sed -n "s/^bit-${VER_RE}-\(.*\)\.tar\.xz$/\1/p; s/^bit-${VER_RE}-\(.*\)\.zip$/\1/p" |
    awk -F- 'NF==2 {print $2"-"$1}' | sort -u)"
  # An empty derivation is a fact about the QUERY, not about the release: it
  # means SHA256SUMS exists and no line in it looked like an artifact for this
  # version. Refuse rather than print a shorter, confident sentence.
  [ -n "${TARGETS}" ] || {
    echo "changelog.sh: ${SUMS_FILE} names no bit-${VERSION}-<target> artifact" >&2
    exit 1
  }
fi

# "a", "a and b", "a, b and c" - an Oxford-comma-free list, built from however
# many targets there turn out to be.
target_sentence() {
  local n item out=""
  n="$(printf '%s\n' "${TARGETS}" | grep -c .)"
  local i=0
  while IFS= read -r item; do
    i=$((i + 1))
    if [ "${i}" -eq 1 ]; then
      out="\`${item}\`"
    elif [ "${i}" -eq "${n}" ]; then
      out="${out} and \`${item}\`"
    else
      out="${out}, \`${item}\`"
    fi
  done <<< "${TARGETS}"
  printf '%s' "${out}"
}

printf '### Artifacts\n\n'
if [ -n "${TARGETS}" ]; then
  printf 'Published for %s.\n' "$(target_sentence)"
fi
printf 'See `dist/README.md` for the full target table, the archive layout,\n'
printf 'the required `BIT_STDLIB`/`BIT_LIBBITRT` environment, and the\n'
printf '`SHA256SUMS` format.\n\n'
printf 'Verify a download before running it:\n\n'
printf '```sh\n'
printf 'sha256sum --check --ignore-missing SHA256SUMS   # shasum -a 256 on macOS\n'
printf '```\n'

if [ -n "${PREV}" ]; then
  printf '\nFull commit log: `%s`\n' "${RANGE}"
fi
