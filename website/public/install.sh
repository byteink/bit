#!/bin/sh
# Install the Bit compiler on Linux.
#
#   curl -fsSL https://bitlang.org/install.sh | sh
#
# Downloads the release tarball named per dist/README.md's naming contract
# (bit-<version>-linux-<arch>.tar.xz), verifies it against the release's
# SHA256SUMS, unpacks it under $BITROOT (default ~/.bit) and symlinks its
# bin/bit into $BITROOT/bin. No wrapper script or env vars are needed:
# bin/bit resolves stdlib/libbitrt.a relative to its own install location
# (dist/README.md, "Path resolution"). POSIX sh only, no bashisms.
set -eu

REPO="byteink/bit"
BITROOT="${BITROOT:-$HOME/.bit}"

die() {
  echo "install.sh: $1" >&2
  exit 1
}

need() {
  command -v "$1" >/dev/null 2>&1 || die "'$1' is required but not found"
}

need curl
need tar
need uname

os="$(uname -s)"
case "$os" in
  Linux) os=linux ;;
  *) die "unsupported OS '$os' (this installer only supports Linux)" ;;
esac

arch="$(uname -m)"
case "$arch" in
  x86_64 | aarch64) : ;;
  *) die "unsupported architecture '$arch' (supported: x86_64, aarch64)" ;;
esac

if [ -n "${BIT_VERSION:-}" ]; then
  version="$BIT_VERSION"
else
  latest_url="https://api.github.com/repos/${REPO}/releases/latest"
  tag="$(curl -fsSL "$latest_url" | grep -m1 '"tag_name"' | sed -E 's/.*"tag_name": *"([^"]+)".*/\1/')"
  [ -n "$tag" ] || die "could not resolve latest release tag from $latest_url"
  version="${tag#v}"
fi

artifact="bit-${version}-${os}-${arch}.tar.xz"
base_url="https://github.com/${REPO}/releases/download/v${version}"

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT INT TERM

echo "install.sh: downloading ${artifact} (bit ${version})" >&2
curl -fsSL -o "${work_dir}/${artifact}" "${base_url}/${artifact}" \
  || die "download failed: ${base_url}/${artifact}"
curl -fsSL -o "${work_dir}/SHA256SUMS" "${base_url}/SHA256SUMS" \
  || die "download failed: ${base_url}/SHA256SUMS"

checksum_line="$(grep " ${artifact}\$" "${work_dir}/SHA256SUMS")" \
  || die "${artifact} has no entry in SHA256SUMS"
expected="$(printf '%s' "$checksum_line" | cut -d' ' -f1)"

if command -v sha256sum >/dev/null 2>&1; then
  actual="$(sha256sum "${work_dir}/${artifact}" | cut -d' ' -f1)"
elif command -v shasum >/dev/null 2>&1; then
  actual="$(shasum -a 256 "${work_dir}/${artifact}" | cut -d' ' -f1)"
else
  die "need sha256sum or shasum to verify checksum"
fi

[ "$actual" = "$expected" ] \
  || die "checksum mismatch for ${artifact}: expected ${expected}, got ${actual}"

install_name="bit-${version}-${os}-${arch}"
mkdir -p "$BITROOT"
rm -rf "${BITROOT:?}/${install_name}"
tar -xJf "${work_dir}/${artifact}" -C "$BITROOT" \
  || die "extraction failed"
[ -x "${BITROOT}/${install_name}/bin/bit" ] \
  || die "archive did not contain ${install_name}/bin/bit"

mkdir -p "${BITROOT}/bin"
ln -sf "${BITROOT}/${install_name}/bin/bit" "${BITROOT}/bin/bit"

echo "install.sh: installed bit ${version} to ${BITROOT}/${install_name}" >&2
echo "install.sh: add ${BITROOT}/bin to PATH:" >&2
echo "    export PATH=\"${BITROOT}/bin:\$PATH\"" >&2
