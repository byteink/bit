#!/usr/bin/env bash
# Reproducible-release verifier (#1753): extends the repo's byte-identical
# culture (scripts/selfhost-fixpoint.sh) to the artifacts .github/workflows/
# release.yml actually ships.
#
# Rebuilds all 3 shipping targets (x86_64-linux, aarch64-linux, aarch64-macos)
# from a tag's source in a throwaway git worktree, repackages with
# dist/package.sh, and diffs the EXTRACTED tarball contents + per-file sha256
# against the published release. Compressed .tar.xz bytes are deliberately not
# compared: xz version/thread-count changes the container's metadata without
# changing what unpacks (dist/package.sh already fixes uid/gid/mtime/member
# order so the container is close, but xz itself is out of this repo's
# control). The contract that matters is dist/README.md's SHA256SUMS one:
# what unpacks must be identical, byte for byte.
#
# Usage:
#   scripts/verify-reproducible-release.sh <tag> [published_dir]
#
# <tag> is a published `v*` tag, already fetched (`git fetch --tags`).
# Without [published_dir], the published SHA256SUMS + tarballs are pulled via
# `gh release download`. Pass [published_dir] to compare against artifacts
# already on disk instead (e.g. a local test tag with no real GitHub release) —
# same shape `gh release download` produces: SHA256SUMS plus one
# bit-<version>-<os>-<arch>.tar.xz per target, all in one directory.
#
# A clean git worktree isolates the rebuild from the caller's working tree, so
# this is safe to run against an in-progress checkout. Any content difference
# fails loudly, naming the offending file — see dist/README.md's
# "Known nondeterminism" section if this ever legitimately fires.
set -euo pipefail

TAG="${1:?usage: verify-reproducible-release.sh <tag> [published_dir]}"
PUBLISHED_DIR="${2:-}"
VERSION="${TAG#v}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

git -C "${ROOT}" rev-parse --verify "${TAG}" >/dev/null 2>&1 || {
  echo "verify-reproducible-release.sh: tag '${TAG}' not found locally — git fetch --tags?" >&2
  exit 1
}

WORK="$(mktemp -d)"
cleanup() {
  git -C "${ROOT}" worktree remove --force "${WORK}/src" >/dev/null 2>&1 || true
  rm -rf "${WORK}"
}
trap cleanup EXIT

if [ -z "${PUBLISHED_DIR}" ]; then
  command -v gh >/dev/null || {
    echo "verify-reproducible-release.sh: no [published_dir] given and 'gh' is not installed" >&2
    exit 1
  }
  PUBLISHED_DIR="${WORK}/published"
  mkdir -p "${PUBLISHED_DIR}"
  gh release download "${TAG}" --dir "${PUBLISHED_DIR}" --pattern '*.tar.xz' --pattern 'SHA256SUMS'
fi
[ -f "${PUBLISHED_DIR}/SHA256SUMS" ] || {
  echo "verify-reproducible-release.sh: no SHA256SUMS in ${PUBLISHED_DIR}" >&2
  exit 1
}

git -C "${ROOT}" worktree add --detach "${WORK}/src" "${TAG}" >/dev/null

echo "building seed + runtime archives at ${TAG}..."
( cd "${WORK}/src" && zig build && zig build libbitrt ) >"${WORK}/build.log" 2>&1 ||
  { echo "verify-reproducible-release.sh: build failed, see ${WORK}/build.log" >&2; exit 1; }

FAIL=0
for TARGET in x86_64-linux aarch64-linux aarch64-macos; do
  case "${TARGET}" in
    x86_64-linux)  OS=linux;  ARCH=x86_64 ;;
    aarch64-linux) OS=linux;  ARCH=aarch64 ;;
    aarch64-macos) OS=macos;  ARCH=aarch64 ;;
  esac
  NAME="bit-${VERSION}-${OS}-${ARCH}"
  published_tar="${PUBLISHED_DIR}/${NAME}.tar.xz"

  if [ ! -f "${published_tar}" ]; then
    echo "verify-reproducible-release.sh: ${TARGET}: missing published ${NAME}.tar.xz" >&2
    FAIL=1
    continue
  fi
  expected_sum="$(grep " ${NAME}.tar.xz\$" "${PUBLISHED_DIR}/SHA256SUMS" | awk '{print $1}')"
  [ -n "${expected_sum}" ] || {
    echo "verify-reproducible-release.sh: ${TARGET}: ${NAME}.tar.xz not listed in SHA256SUMS" >&2
    FAIL=1
    continue
  }
  actual_sum="$(shasum -a 256 "${published_tar}" | awk '{print $1}')"
  if [ "${expected_sum}" != "${actual_sum}" ]; then
    echo "verify-reproducible-release.sh: ${TARGET}: ${NAME}.tar.xz FAILS its own SHA256SUMS check (expected ${expected_sum}, got ${actual_sum}) — corrupt or tampered download, refusing to diff it" >&2
    FAIL=1
    continue
  fi

  echo "rebuilding ${TARGET}..."
  mkdir -p "${WORK}/build-${TARGET}/stage/bin"
  "${WORK}/src/zig-out/bin/bit-seed" build selfhost --target "${TARGET}" \
    -o "${WORK}/build-${TARGET}/stage/bin/bit"
  chmod +x "${WORK}/build-${TARGET}/stage/bin/bit"
  ( cd "${WORK}/src" && bash dist/package.sh "${VERSION}" "${TARGET}" "${WORK}/build-${TARGET}" ) >/dev/null
  rebuilt_tar="${WORK}/build-${TARGET}/${NAME}.tar.xz"

  mkdir -p "${WORK}/extract-${TARGET}/published" "${WORK}/extract-${TARGET}/rebuilt"
  tar -C "${WORK}/extract-${TARGET}/published" -xf "${published_tar}"
  tar -C "${WORK}/extract-${TARGET}/rebuilt" -xf "${rebuilt_tar}"

  tree_diff="$(diff <(cd "${WORK}/extract-${TARGET}/published" && find . | sort) \
                     <(cd "${WORK}/extract-${TARGET}/rebuilt" && find . | sort) || true)"
  if [ -n "${tree_diff}" ]; then
    echo "verify-reproducible-release.sh: ${TARGET}: FILE TREE differs:" >&2
    echo "${tree_diff}" >&2
    FAIL=1
    continue
  fi

  hash_diff="$(diff <(cd "${WORK}/extract-${TARGET}/published" && find . -type f -exec shasum -a 256 {} + | sort -k2) \
                     <(cd "${WORK}/extract-${TARGET}/rebuilt" && find . -type f -exec shasum -a 256 {} + | sort -k2) || true)"
  if [ -n "${hash_diff}" ]; then
    echo "verify-reproducible-release.sh: ${TARGET}: CONTENT differs:" >&2
    echo "${hash_diff}" >&2
    FAIL=1
    continue
  fi
  echo "${TARGET}: OK — bit-identical to published ${NAME}.tar.xz"
done

[ "${FAIL}" -eq 0 ] || {
  echo "verify-reproducible-release.sh: FAILED — see differing file(s) above" >&2
  exit 1
}
echo "all 3 shipping artifacts rebuild bit-identical to ${TAG}"
