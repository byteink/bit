#!/usr/bin/env bash
# Render the release notes for <version> from conventional commits.
#
#   dist/changelog.sh <version> [<ref>]
#
# <ref> is the commit the release is cut from (default HEAD). The range is the
# previous `v*` tag reachable from <ref> to <ref>; with no previous tag the
# whole history is used. Requires a full clone (fetch-depth: 0) — a shallow one
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
# always exactly what nothing has explained yet. That is what lets the last
# section be a catch-all and the guard below be a real assertion.
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

emit() {
  local title="$1" body="$2"
  [ -n "${body}" ] || return 0
  EMITTED=$((EMITTED + $(printf '%s\n' "${body}" | grep -c .)))
  printf '### %s\n\n' "${title}"
  printf '%s\n' "${body}" | while IFS='|' read -r subject sha; do
    printf -- '- %s (%s)\n' "${subject}" "${sha}"
  done
  printf '\n'
}

printf '## Bit %s\n\n' "${VERSION}"
take '^[a-z][a-z0-9+-]*(\([^)]*\))?!:' ; emit 'Breaking changes' "${BODY}"
take '^feat(\([^)]*\))?:'              ; emit 'Features'         "${BODY}"
take '^fix(\([^)]*\))?:'               ; emit 'Fixes'            "${BODY}"
take '^perf(\([^)]*\))?:'              ; emit 'Performance'      "${BODY}"
# Everything else conventional-shaped, as a COMPLEMENT rather than a whitelist.
# The whitelist this replaces named `seed` and `selfhost` — a directory deleted
# in #1593 and one renamed to `compiler` in #1841 — and never named `compiler`
# itself, so 41 of 0.1.5's 59 commits were reported nowhere and nothing said so
# (#2061). A list of types has to be maintained against a repo that coins new
# ones; a complement does not. The charset admits `zig-removal` and
# `dist+website`, both of which appear in that range.
take '^[a-z][a-z0-9+-]*(\([^)]*\))?:'  ; emit 'Other'            "${BODY}"
# No conventional prefix at all. Listed rather than discarded — a subject nobody
# formatted is still a change that shipped.
emit 'Uncategorised' "${REMAINING}"

# THE POINT OF THE ACCOUNTING. Every commit in the range must appear exactly
# once: `take` claims, so a duplicate is impossible and a shortfall means a
# pattern lost something. Release notes that quietly omit a third of a release
# read as complete, which is why this exits rather than warns —
# dist/release.sh's fallback writes a minimal note when this fails.
TOTAL="$(printf '%s\n' "${COMMITS}" | grep -c .)"
if [ "${EMITTED}" -ne "${TOTAL}" ]; then
  echo "changelog.sh: listed ${EMITTED} of ${TOTAL} commits in ${RANGE}" >&2
  printf '%s\n' "${REMAINING}" | sed 's/^/  unlisted: /' >&2
  exit 1
fi

printf '### Artifacts\n\n'
printf 'Published for `x86_64-linux`, `aarch64-linux` and `aarch64-macos`.\n'
printf 'Windows and `x86_64-macos` are not built yet — see `dist/README.md`\n'
printf 'for the full target table, the archive layout, the required\n'
printf '`BIT_STDLIB`/`BIT_LIBBITRT` environment, and the `SHA256SUMS` format.\n\n'
printf 'Verify a download before running it:\n\n'
printf '```sh\n'
printf 'sha256sum --check --ignore-missing SHA256SUMS   # shasum -a 256 on macOS\n'
printf '```\n'

if [ -n "${PREV}" ]; then
  printf '\nFull commit log: `%s`\n' "${RANGE}"
fi
