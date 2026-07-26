#!/usr/bin/env bash
# Publish Formula/bit.rb to byteink/homebrew-tap for a released Bit version.
#
#   dist/brew/publish.sh <version> [--dry-run]
#
# <version> is the release tag without its leading `v` (e.g. 0.1.0). The
# release `v<version>` must already exist on byteink/bit with a SHA256SUMS
# asset covering bit-<version>-macos-aarch64.tar.xz (dist/package.sh +
# `gh release upload` produce that artifact and checksum; this script does
# not build or upload it — its job is the formula only).
#
# --dry-run prints the rendered formula to stdout and exits; it pushes
# nothing to the tap.
#
# Credential: the operator's own `gh auth login` session on this Mac, which
# already has write access to byteink/homebrew-tap. No token, no secret file.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RELEASE_REPO="byteink/bit"
TAP_REPO="byteink/homebrew-tap"

VERSION="${1:?usage: publish.sh <version> [--dry-run]}"
# ponytail: --dry-run must be exactly the 2nd positional arg; no getopts, no
# flag reordering. The only caller is the operator running this by hand.
DRY_RUN=0
[ "${2:-}" = "--dry-run" ] && DRY_RUN=1

if ! printf '%s' "${VERSION}" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$'; then
  echo "publish.sh: '${VERSION}' is not a semver version" >&2
  exit 1
fi

TAG="v${VERSION}"
# ponytail: aarch64-macos only — the only macOS target that ships
# (dist/README.md, "Which targets actually ship").
ARTIFACT="bit-${VERSION}-macos-aarch64.tar.xz"

if ! SUMS="$(gh release download "${TAG}" --repo "${RELEASE_REPO}" --pattern SHA256SUMS --output -)"; then
  echo "publish.sh: could not fetch SHA256SUMS from ${RELEASE_REPO} release ${TAG}" >&2
  exit 1
fi

SHA="$(printf '%s\n' "${SUMS}" | grep " ${ARTIFACT}\$" | cut -d' ' -f1)" || true
if [ -z "${SHA}" ]; then
  echo "publish.sh: no checksum for ${ARTIFACT} in ${TAG}'s SHA256SUMS" >&2
  exit 1
fi

FORMULA="$(sed -e "s|@VERSION@|${VERSION}|g" -e "s|@SHA256@|${SHA}|g" "${ROOT}/dist/brew/bit.rb.tmpl")"

if [ "${DRY_RUN}" -eq 1 ]; then
  printf '%s\n' "${FORMULA}"
  exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

gh repo clone "${TAP_REPO}" "${WORK}/tap" -- --depth 1
printf '%s\n' "${FORMULA}" > "${WORK}/tap/Formula/bit.rb"

cd "${WORK}/tap"
# `git add` BEFORE the comparison, then compare the INDEX. `git diff` ignores
# untracked files, so on the very first publish - when Formula/bit.rb does not
# exist in the tap yet - the old `git diff --quiet` saw no change and reported
# "nothing to push". It pushed nothing, said so cheerfully, and exited 0. That is
# exactly the case this script exists for.
git add Formula/bit.rb
if git diff --cached --quiet -- Formula/bit.rb; then
  echo "publish.sh: Formula/bit.rb unchanged for ${VERSION}, nothing to push"
  exit 0
fi
git commit -m "bit ${VERSION}"
git push
