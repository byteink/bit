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
section() {
  local title="$1" pattern="$2" body=""
  body="$(printf '%s\n' "${COMMITS}" | grep -E "${pattern}" || true)"
  [ -n "${body}" ] || return 0
  printf '### %s\n\n' "${title}"
  printf '%s\n' "${body}" | while IFS='|' read -r subject sha; do
    printf -- '- %s (%s)\n' "${subject}" "${sha}"
  done
  printf '\n'
}

printf '## Bit %s\n\n' "${VERSION}"
section 'Breaking changes' '^[a-z]+(\([^)]*\))?!:'
section 'Features'         '^feat(\([^)]*\))?:'
section 'Fixes'            '^fix(\([^)]*\))?:'
section 'Performance'      '^perf(\([^)]*\))?:'
section 'Other'            '^(build|chore|ci|docs|refactor|spec|test|seed|selfhost|runtime)(\([^)]*\))?:'

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
