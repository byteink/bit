#!/usr/bin/env bash
# Stage and compress one release artifact.
#
#   dist/package.sh <version> <target> <outdir>
#
# <target> is a compiler target triple as `bit --target` spells it
# (x86_64-linux | aarch64-linux | aarch64-macos). <version> is the tag without
# its leading `v`. The staged `bit` binary must already exist at
# <outdir>/stage/bin/bit — the caller produces it, because producing a
# self-hosted `bit` means EXECING the seed and only the workflow knows which
# host it is on (see build.zig's `native` note).
#
# Emits <outdir>/bit-<version>-<os>-<arch>.tar.xz. The artifact contract this
# implements — layout, naming, the BIT_STDLIB/BIT_LIBBITRT env requirement — is
# specified in dist/README.md and consumed by the brew formula (#359), the
# curl|sh installer (#360) and the winget package (#361). Change it there first.
set -euo pipefail

VERSION="${1:?usage: package.sh <version> <target> <outdir>}"
TARGET="${2:?usage: package.sh <version> <target> <outdir>}"
OUTDIR="${3:?usage: package.sh <version> <target> <outdir>}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

case "${TARGET}" in
  x86_64-linux)   OS=linux;  ARCH=x86_64 ;;
  aarch64-linux)  OS=linux;  ARCH=aarch64 ;;
  aarch64-macos)  OS=macos;  ARCH=aarch64 ;;
  *) echo "package.sh: unsupported target '${TARGET}'" >&2; exit 2 ;;
esac

# Every runtime archive the shipped compiler can actually link against, so a
# user who re-points BIT_LIBBITRT can cross-produce the other targets with the
# same install. x86_64-macos is deliberately absent: `zig build libbitrt`
# emits it, but no compiler target selects it (the Mach-O linker has no x86-64
# relocation support yet), so shipping it would advertise a target that fails.
RUNTIME_TRIPLES="x86_64-linux aarch64-linux aarch64-macos"

NAME="bit-${VERSION}-${OS}-${ARCH}"
STAGE="${OUTDIR}/stage"

[ -x "${STAGE}/bin/bit" ] || { echo "package.sh: missing ${STAGE}/bin/bit" >&2; exit 1; }

for triple in ${RUNTIME_TRIPLES}; do
  src="${ROOT}/zig-out/lib/${triple}/libbitrt.a"
  [ -f "${src}" ] || { echo "package.sh: missing ${src} (run 'zig build libbitrt')" >&2; exit 1; }
  mkdir -p "${STAGE}/lib/${triple}"
  cp "${src}" "${STAGE}/lib/${triple}/libbitrt.a"
done

cp -R "${ROOT}/stdlib" "${STAGE}/stdlib"
cp "${ROOT}/LICENSE" "${ROOT}/README.md" "${STAGE}/"
cp "${ROOT}/dist/README.md" "${STAGE}/ARTIFACT.md"

# Rename the stage dir to the artifact name so the tarball unpacks into a single
# self-describing directory rather than a bare `stage/`.
rm -rf "${OUTDIR:?}/${NAME:?}"
mv "${STAGE}" "${OUTDIR}/${NAME}"

# Deterministic-ish tar: fixed owner and a fixed mtime so two builds of the same
# commit produce the same bytes. GNU tar (Linux) also gets --sort=name; bsdtar
# (macOS) has no equivalent, so its member order follows readdir.
TARFLAGS=(--uid 0 --gid 0 --numeric-owner --exclude '._*' --exclude '.DS_Store')
if tar --version 2>/dev/null | grep -q 'GNU tar'; then
  TARFLAGS+=(--sort=name --owner=0 --group=0 --mtime=@0)
else
  # bsdtar: drop macOS-only metadata entirely rather than serialising it into
  # pax `LIBARCHIVE.xattr.*` headers that GNU tar then warns about on unpack.
  TARFLAGS+=(--uname "" --gname "" --no-mac-metadata)
fi

# COPYFILE_DISABLE stops bsdtar (macOS) from serialising each file's extended
# attributes into an AppleDouble `._<name>` member. Without it every stdlib file
# gains a `._foo.bit` sibling carrying `com.apple.provenance`, and the shipped
# compiler globs those as real sources — a macOS-built artifact then fails to
# compile anything at all. Caught by unpacking a macOS-built package inside a
# Linux container; the `--exclude`s above are the belt to this suspenders.
COPYFILE_DISABLE=1 tar -C "${OUTDIR}" "${TARFLAGS[@]}" -cf - "${NAME}" | xz -9 -T0 > "${OUTDIR}/${NAME}.tar.xz"
rm -rf "${OUTDIR:?}/${NAME}"

echo "${OUTDIR}/${NAME}.tar.xz"
