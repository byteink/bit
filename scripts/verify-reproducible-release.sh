#!/usr/bin/env bash
# Reproducible-release verifier (#1753): extends the repo's byte-identical
# culture (scripts/selfhost-fixpoint.sh) to the artifacts dist/release.sh
# actually ships.
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
# #2500 (this fix): until this landed, the rebuild loop below invoked the
# seed compiler binary that the self-host transition deleted from
# `bit-out/bin/` on 2026-07-29 (#1593) — so every run since then died at
# rc=1 before rebuilding or comparing a single byte, for a reason that had
# nothing to do with reproducibility. 0.1.9 was the first release cut entirely
# after #2060's determinism fix, so it is the first release whose
# reproducibility claim is even checkable — and this script, the checker, was
# the broken part.
# dist/stage0/SHA256SUMS's 0.1.9 and 0.1.10 headers record the claim as
# UNVERIFIED BY TOOLING for exactly that reason; that admission is #2495's to
# revise, once a real run against a published tag is green (recorded on
# #2500, not assumed from this fix compiling).
#
# #3035 (this fix): #3034 changed what dist/release.sh actually ships, so the
# rebuild below now mirrors THAT sequence — three stages, not one:
#   L0/C1 — `./make libbitrt` builds the bootstrap runtime archives, then the
#     PINNED stage0 builds a native host compiler ("bit1", bit-out/bin/bit)
#     linking the host L0 archive, exactly as `tools/build/artifacts.bit`'s
#     `stepSelfhost` does for `install`. Stage0's role ends here: it never
#     builds the artifact compared against the release, only the compiler
#     that builds it.
#   L1/C2 — bit1 (this tag's own codegen, not stage0's) builds the runtime
#     archive and the shipped `bit` for every target via `scripts/
#     g2archive.sh` and a direct `bit1 build`, exactly as release.sh's L1/C2
#     steps do. C2's output is what gets packaged and compared below.
# Both stage0 and bit1 are resolved/built INSIDE the tag's own worktree, so an
# old tag rebuilds with the toolchain it was actually cut with (see the block
# above the L1/C2 loop). The staged, version-stamped copy of compiler/
# (below, "stage compiler/") is still a DELIBERATE duplicate of
# dist/release.sh's staging lines, not a shared helper, for the same reason
# as before: this script must not change what release.sh itself does, so it
# re-derives the same staged tree independently rather than couple the two
# through a shared file.
#
# A tag cut BEFORE #3034 (v0.1.15 and earlier) was built by the old chain —
# the pinned stage0 built the compared artifact directly, with no bit1 stage
# at all. Rebuilding one of those tags with this script is expected to print
# CONTENT differs: that is a chain mismatch, not a reproducibility defect,
# and this script does not attempt to detect or special-case it. Verify a
# pre-#3034 tag with the git revision of this script from before #3035, or
# accept that only tags cut with the new chain are checkable here.
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
# fails loudly, naming the offending file.
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

echo "L0: building bootstrap runtime archives at ${TAG}..."
( cd "${WORK}/src" && ./make libbitrt ) >"${WORK}/build.log" 2>&1 ||
  { echo "verify-reproducible-release.sh: ./make libbitrt failed, see ${WORK}/build.log" >&2; exit 1; }

# THE PINNED STAGE0 AT THIS TAG, never a compiler built from this tree — same
# reason dist/release.sh uses it and the differentials use it as their oracle:
# a compiler bug introduced in the tag being verified must not be able to
# compile itself into its own "reproduction". Resolved from inside the
# worktree so it reads THAT COMMIT's dist/stage0/SHA256SUMS, not this
# checkout's — the pin moves release to release, and a release must be
# rebuilt with whatever it actually pinned at the time it was cut.
#
# Its job stops here (#3034/#3035): stage0 builds C1 — a native host compiler
# ("bit1") — and nothing else. Everything compared against the release below
# is built by bit1, not by stage0.
echo "resolving the pinned stage0 at ${TAG}..."
STAGE0="$(cd "${WORK}/src" && sh scripts/stage0.sh)" ||
  { echo "verify-reproducible-release.sh: stage0 resolution failed" >&2; exit 1; }
echo "stage0 = ${STAGE0}"

# C1: stage0 builds compiler/ AS IT SITS ON DISK (unstamped — the version
# stamp is for C2's STAGED copy below) for the HOST triple, linking the L0
# archive `./make libbitrt` just wrote. This is stage0's ENTIRE job in this
# script: bit1 is a native host binary that can cross-produce every shipped
# target below the same way stage0 always has, exactly as dist/release.sh's
# own comment describes its C1 step.
#
# A DELIBERATE duplicate of `stepSelfhost` (tools/build/artifacts.bit:311-314)
# rather than a call to `./make` — same reasoning as the STAGE_SRC staging
# duplicate above: this script must not depend on the driver's own caching or
# side effects (it writes bit-out/make/*.stamp, bit-out/make/host.triple), and
# spelling the recipe out here keeps it auditable as the one thing stage0 is
# still trusted to build.
case "$(uname -s)-$(uname -m)" in
  Darwin-arm64)              HOST_TRIPLE=aarch64-macos ;;
  Linux-aarch64|Linux-arm64) HOST_TRIPLE=aarch64-linux ;;
  Linux-x86_64)              HOST_TRIPLE=x86_64-linux ;;
  *) echo "verify-reproducible-release.sh: unsupported host $(uname -s)-$(uname -m)" >&2; exit 1 ;;
esac
l0host="${WORK}/src/bit-out/lib/${HOST_TRIPLE}/libbitrt.a"
[ -f "${l0host}" ] || {
  echo "verify-reproducible-release.sh: missing ${l0host} (./make libbitrt did not produce it)" >&2
  exit 1
}
echo "C1: bootstrapping the host self-hosted compiler with stage0 (bit1) at ${TAG}..."
BIT1="${WORK}/src/bit-out/bin/bit"
mkdir -p "$(dirname "${BIT1}")"
( cd "${WORK}/src" && BIT_LIBBITRT="${l0host}" "${STAGE0}" build compiler -o "${BIT1}" ) \
  >>"${WORK}/build.log" 2>&1 ||
  { echo "verify-reproducible-release.sh: stage0 build of bit1 failed, see ${WORK}/build.log" >&2; exit 1; }
chmod +x "${BIT1}"
echo "bit1 = ${BIT1}"

# Stamp the version into a staged copy of compiler/ — DELIBERATELY duplicating
# dist/release.sh lines ~89-104 rather than sharing a helper (see this file's
# header). `compiler/version.bit` as it sits in the tag's tree carries the
# checked-in DEV version, so building it unmodified would rebuild a binary
# that reports the wrong version and can never match what was actually shipped.
STAGE_SRC="${WORK}/stagesrc/compiler"
mkdir -p "${STAGE_SRC}"
find "${WORK}/src/compiler" -maxdepth 1 -name '*.bit' ! -name 'version.bit' -exec cp {} "${STAGE_SRC}/" \;
printf '// Generated by scripts/verify-reproducible-release.sh, mirroring dist/release.sh.\nconst bitVersion: string = "%s"\n' \
  "${VERSION}" > "${STAGE_SRC}/version.bit"
decls="$(grep -l 'const bitVersion' "${STAGE_SRC}"/*.bit | wc -l | tr -d ' ')"
[ "${decls}" = "1" ] || {
  echo "verify-reproducible-release.sh: staged tree declares bitVersion ${decls} times, expected 1" >&2
  exit 1
}
staged="$(find "${STAGE_SRC}" -maxdepth 1 -name '*.bit' | wc -l | tr -d ' ')"
real="$(find "${WORK}/src/compiler" -maxdepth 1 -name '*.bit' | wc -l | tr -d ' ')"
[ "${staged}" = "${real}" ] || {
  echo "verify-reproducible-release.sh: staged ${staged} of ${real} compiler/ files — the copy lost some" >&2
  exit 1
}

# L1: bit1 — this tag's own codegen, not stage0's — builds the runtime
# archive for every target, mirroring dist/release.sh's L1 step exactly
# (including calling THAT TAG's own scripts/g2archive.sh, not this checkout's).
#
# WRITTEN TO SCRATCH, NEVER INTO "${WORK}/src/bit-out/lib/" — that path is the
# L0 archive `./make libbitrt` already wrote above, and it is what C1 above
# linked into bit1. Overwriting it here would make this script indistinguishable
# from dist/release.sh's own first-pass defect (#3034): a fingerprint-based
# staleness check over runtime/** SOURCE that is blind to which compiler last
# produced the bytes on disk. All three built up front because dist/package.sh
# embeds every target's archive into every target's tarball, regardless of
# which one it is packaging.
LIB1="${WORK}/lib1"
for TARGET in x86_64-linux aarch64-linux aarch64-macos; do
  echo "L1: building runtime archive for ${TARGET} with bit1..."
  mkdir -p "${LIB1}/${TARGET}"
  BIT="${BIT1}" bash "${WORK}/src/scripts/g2archive.sh" "${TARGET}" "${LIB1}/${TARGET}/libbitrt.a" ||
    { echo "verify-reproducible-release.sh: L1 build failed for ${TARGET}" >&2; exit 1; }
done

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

  # REFUSE rather than fall back (mirrors dist/release.sh): an absent archive
  # would silently link whatever runtime stage0 ships with, which is the
  # exact defect BIT_LIBBITRT exists to prevent (#2213).
  archive="${LIB1}/${TARGET}/libbitrt.a"
  if [ ! -f "${archive}" ]; then
    echo "verify-reproducible-release.sh: ${TARGET}: missing ${archive} (the L1 build above should have written it)" >&2
    FAIL=1
    continue
  fi

  # C2: bit1 builds the STAGED, version-stamped compiler/, linking L1. This is
  # the artifact dist/release.sh actually ships as bin/bit — not stage0, and
  # not the STAGE0 variable resolved above, which built bit1 and nothing past
  # it. BIT_LIBBITRT is still load-bearing (#2213, unchanged by #3034): bit1
  # resolves libbitrt.a relative to itself absent an override, which is the L0
  # archive under bit-out/lib, never ${archive} — L1 lives entirely under
  # ${WORK} and bit1's sibling lib/ cannot see it.
  echo "C2: rebuilding ${TARGET} with bit1..."
  mkdir -p "${WORK}/build-${TARGET}/stage/bin"
  BIT_LIBBITRT="${archive}" "${BIT1}" build "${STAGE_SRC}" --target "${TARGET}" \
    -o "${WORK}/build-${TARGET}/stage/bin/bit"
  chmod +x "${WORK}/build-${TARGET}/stage/bin/bit"
  # [archivedir] passed EXPLICITLY as ${LIB1}, not left to package.sh's
  # default `bit-out/lib` — that default resolves (relative to package.sh's
  # own location inside ${WORK}/src) to the L0, stage0-built archive this
  # script deliberately never packages. Passing nothing here would silently
  # ship the wrong runtime family and compare against it.
  ( cd "${WORK}/src" && bash dist/package.sh "${VERSION}" "${TARGET}" "${WORK}/build-${TARGET}" "${LIB1}" ) >/dev/null
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
