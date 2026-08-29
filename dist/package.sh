#!/usr/bin/env bash
# Stage and compress one release artifact.
#
#   dist/package.sh <version> <target> <outdir> [archivedir]
#
# <target> is a compiler target triple as `bit --target` spells it
# (x86_64-linux | aarch64-linux | aarch64-macos | x86_64-windows). <version> is
# the tag without its leading `v`. The staged binary must already exist at
# <outdir>/stage/bin/bit (bit.exe for x86_64-windows) — the caller produces it,
# because producing a self-hosted `bit` means EXECING the seed and only the
# workflow knows which host it is on (see tools/build/artifacts.bit's
# hostTriple note).
#
# [archivedir] is where the runtime archives (<triple>/libbitrt.a) are read
# from, defaulting to `bit-out/lib` — the tree `./make libbitrt` writes, so
# every existing caller is unaffected. `dist/release.sh` (#3034) passes its
# own scratch directory instead: its shipped archives are built by THIS tree's
# own compiler, not stage0, and writing them into `bit-out/lib` would make
# `./make libbitrt`'s own staleness check blind to it — the fingerprint covers
# runtime/** SOURCE, not which compiler last produced the archive on disk, so a
# second run in the same tree would see "up to date" over an archive that is
# actually a previous run's output, silently breaking release.sh's own
# idempotency (and #3035's reproducibility check, which relies on a fresh
# tree's `bit-out/lib` staying genuinely stage0-built).
#
# Emits <outdir>/bit-<version>-<os>-<arch>.tar.xz — except x86_64-windows,
# which emits a .zip (#3342: a Windows user has no tar.xz extractor by
# default). The artifact contract this implements — layout, naming, the
# BIT_STDLIB/BIT_LIBBITRT env requirement — is specified in dist/README.md and
# consumed by the brew formula (#359), the curl|sh installer (#360) and the
# winget package (#361). Change it there first.
set -euo pipefail

VERSION="${1:?usage: package.sh <version> <target> <outdir> [archivedir]}"
TARGET="${2:?usage: package.sh <version> <target> <outdir> [archivedir]}"
OUTDIR="${3:?usage: package.sh <version> <target> <outdir> [archivedir]}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARCHIVE_DIR="${4:-${ROOT}/bit-out/lib}"

case "${TARGET}" in
  x86_64-linux)   OS=linux;   ARCH=x86_64;  BIN_NAME=bit ;;
  aarch64-linux)  OS=linux;   ARCH=aarch64; BIN_NAME=bit ;;
  aarch64-macos)  OS=macos;   ARCH=aarch64; BIN_NAME=bit ;;
  x86_64-windows) OS=windows; ARCH=x86_64;  BIN_NAME=bit.exe ;;
  *) echo "package.sh: unsupported target '${TARGET}'" >&2; exit 2 ;;
esac

# Every runtime archive the shipped compiler can actually link against, so a
# user who re-points BIT_LIBBITRT can cross-produce the other targets with the
# same install. x86_64-macos is deliberately absent: `./make libbitrt`
# emits it, but no compiler target selects it (the Mach-O linker has no x86-64
# relocation support yet), so shipping it would advertise a target that fails.
#
# x86_64-windows's OWN archive is added ONLY for the windows package, not
# folded into the base list every target ships: the three existing artifacts
# must stay byte-identical across this change (#3342 acceptance), and adding a
# fourth member here would change what they contain. The windows package still
# needs its own archive so a bare `bit.exe run foo.bit` resolves it without an
# explicit BIT_LIBBITRT, the same as every other target already does for
# itself.
RUNTIME_TRIPLES="x86_64-linux aarch64-linux aarch64-macos"
[ "${TARGET}" = "x86_64-windows" ] && RUNTIME_TRIPLES="${RUNTIME_TRIPLES} x86_64-windows"

NAME="bit-${VERSION}-${OS}-${ARCH}"
STAGE="${OUTDIR}/stage"

[ -x "${STAGE}/bin/${BIN_NAME}" ] || { echo "package.sh: missing ${STAGE}/bin/${BIN_NAME}" >&2; exit 1; }

for triple in ${RUNTIME_TRIPLES}; do
  src="${ARCHIVE_DIR}/${triple}/libbitrt.a"
  [ -f "${src}" ] || { echo "package.sh: missing ${src} (run './make libbitrt', or pass the right [archivedir])" >&2; exit 1; }
  mkdir -p "${STAGE}/lib/${triple}"
  cp "${src}" "${STAGE}/lib/${triple}/libbitrt.a"
done

cp -R "${ROOT}/stdlib" "${STAGE}/stdlib"
# Shipped so README.md's relative docs/ links (tutorial, development,
# release/SUPPORT, release/VERSIONING, ...) resolve inside the install
# instead of 404ing (#3500). Whole tree, not an enumerated subset: an
# enumerated list goes stale the next time a doc is added, silently, the
# way this repo's release steps keep going stale when hand-maintained.
cp -R "${ROOT}/docs" "${STAGE}/docs"
cp "${ROOT}/LICENSE" "${ROOT}/README.md" "${STAGE}/"
cp "${ROOT}/dist/README.md" "${STAGE}/ARTIFACT.md"

# Rename the stage dir to the artifact name so the tarball unpacks into a single
# self-describing directory rather than a bare `stage/`.
rm -rf "${OUTDIR:?}/${NAME:?}"
mv "${STAGE}" "${OUTDIR}/${NAME}"

# NORMALISE THE TREE, DO NOT ASK TAR TO DO IT (#2060). The two properties that
# make an archive reproducible are a fixed mtime on every member and a fixed
# member order, and both used to be requested through GNU-only flags
# (`--mtime=@0`, `--sort=name`) that sat in the GNU branch below. Releases are
# cut on macOS. bsdtar 3.5.3 implements NEITHER — `--mtime=@0` is rejected
# outright ("Option --mtime=@0 is not supported") — so on the one host that
# actually produces artifacts the comment promised determinism the code never
# delivered. Measured: cutting 0.1.5 twice from the same commit, minutes apart,
# gave six different digests for three files, because `cp` restamped every
# staged file's mtime on each run.
#
# Doing it to the tree instead works on both tars and cannot silently not apply.
touch -h -t 197001010000 "${OUTDIR}/${NAME}"
find "${OUTDIR}/${NAME}" -exec touch -h -t 197001010000 {} +
# -h stamps a symlink itself rather than its target; a link whose target is
# outside the tree would otherwise be followed and the tree's own entry left
# with today's date.

# Member order, the other half. `find | sort` under LC_ALL=C is a stable total
# order that both tars honour through `-T`, so this replaces --sort=name.
MEMBERS="${OUTDIR}/.members"
( cd "${OUTDIR}" && find "${NAME}" | LC_ALL=C sort > "${MEMBERS}" )

# `--numeric-owner` and the excludes are the only flags BOTH tars take. Zeroing
# the owner is spelled differently by each, and it was in the shared part: GNU
# tar 1.34 answers `--uid` with "unrecognized option" and exits 64, so this
# script could never have run on Linux at all. Nobody noticed because releases
# are cut on macOS — but the GNU branch existed precisely for a host that would
# have died on line one of it. Found while verifying #2060 on both tars.
TARFLAGS=(--numeric-owner --exclude '._*' --exclude '.DS_Store')
if tar --version 2>/dev/null | grep -q 'GNU tar'; then
  TARFLAGS+=(--owner=0 --group=0)
else
  # bsdtar's spelling of the same thing.
  TARFLAGS+=(--uid 0 --gid 0)
  # bsdtar: drop macOS-only metadata entirely rather than serialising it into
  # pax `LIBARCHIVE.xattr.*` headers that GNU tar then warns about on unpack.
  #
  # BOTH flags are needed and they are not the same mechanism. --no-mac-metadata
  # suppresses the AppleDouble `._name` copyfile members; --no-xattrs suppresses
  # the pax `LIBARCHIVE.xattr.*` / `SCHILY.xattr.*` headers. With only the first,
  # every member of a macOS-built artifact still carried
  # `com.apple.provenance`, and GNU tar printed a warning per file on unpack —
  # verified by unpacking one on Linux and on real x86-64 hardware.
  TARFLAGS+=(--uname "" --gname "" --no-mac-metadata --no-xattrs)
fi

# COPYFILE_DISABLE stops bsdtar (macOS) from serialising each file's extended
# attributes into an AppleDouble `._<name>` member. Without it every stdlib file
# gains a `._foo.bit` sibling carrying `com.apple.provenance`, and the shipped
# compiler globs those as real sources — a macOS-built artifact then fails to
# compile anything at all. Caught by unpacking a macOS-built package inside a
# Linux container; the `--exclude`s above are the belt to this suspenders.
#
# A Windows user has no tar.xz extractor by default (#3342), so x86_64-windows
# ships a .zip instead — everything above this line (staging, mtime
# normalisation, member ordering) is format-agnostic and applies unchanged.
if [ "${OS}" = "windows" ]; then
  ARTIFACT="${OUTDIR}/${NAME}.zip"
  rm -f "${ARTIFACT}"
  # -X: no extra timestamp/uid-gid fields (the mtime normalisation above is
  # what actually makes this reproducible; -X stops zip re-adding its own
  # higher-precision timestamps on top of it). -x: belt to tar's --exclude
  # suspenders above, in case a stray macOS sidecar ever lands in the tree.
  ( cd "${OUTDIR}" && zip -q -X -r "${ARTIFACT}" -@ -x '*.DS_Store' -x '*._*' < "${MEMBERS}" )
else
  ARTIFACT="${OUTDIR}/${NAME}.tar.xz"
  COPYFILE_DISABLE=1 tar -C "${OUTDIR}" "${TARFLAGS[@]}" -cf - -T "${MEMBERS}" | xz -9 -T0 > "${ARTIFACT}"
fi
rm -f "${MEMBERS}"
rm -rf "${OUTDIR:?}/${NAME}"

echo "${ARTIFACT}"
