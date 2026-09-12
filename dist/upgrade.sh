#!/bin/sh
# Replace an install.sh-managed Bit install with the newest release.
#
#   dist/upgrade.sh [--check]
#
# This is what `bit upgrade` (compiler/upgrade.bit, `upgradeCmd`) executes; it
# is also runnable on its own. It is the upgrade half of dist/install.sh and
# deliberately reuses that script's contracts: the artifact naming of
# dist/README.md ("Naming"), the same `SHA256SUMS` digest check, the same
# `$BITROOT` layout (default ~/.bit) with `bin/bit` a symlink into
# `$BITROOT/bit-<version>-<os>-<arch>/bin/bit`, and the same `BIT_VERSION`
# override for the version to move to.
#
# THE INSTALL BEING UPGRADED IS THE ONE $BITROOT/bin/bit POINTS AT, and its
# version is read off that symlink's target rather than from the compiler that
# invoked this script. Those are the same thing for a user (`bit` on PATH is
# that symlink) and different for a maintainer running a build-tree compiler
# against a test root, and the install on disk is the one being replaced.
#
# NOTHING EXISTING IS TOUCHED UNTIL THE DOWNLOAD IS VERIFIED: the artifact is
# fetched into a fresh directory inside $BITROOT, digest-checked, unpacked
# there, and only then moved into place - and the live `bin/bit` symlink is
# replaced by renaming a second symlink over it, which is atomic, never by
# writing through the running binary. A failure at any step leaves the previous
# install runnable, and it is left on disk afterwards too.
#
# POSIX sh only, no bashisms.
set -eu

REPO="byteink/bit"
BITROOT="${BITROOT:-$HOME/.bit}"

die() {
  echo "upgrade.sh: $1" >&2
  exit 1
}

need() {
  command -v "$1" >/dev/null 2>&1 || die "'$1' is required but not found"
}

check_only=no
for a in "$@"; do
  case "$a" in
    --check) check_only=yes ;;
    *) die "unknown argument '$a' (usage: upgrade.sh [--check])" ;;
  esac
done

need curl
need tar
need uname

os="$(uname -s)"
case "$os" in
  Linux) os=linux ;;
  Darwin) os=macos ;;
  *) die "unsupported OS '$os' (supported: Linux, Darwin)" ;;
esac

# `uname -m` spelling to the artifact spelling of dist/README.md ("Naming"):
# macOS reports arm64 where the artifact says aarch64.
arch="$(uname -m)"
case "$arch" in
  arm64 | aarch64) arch=aarch64 ;;
  x86_64) arch=x86_64 ;;
  *) die "unsupported architecture '$arch' (supported: x86_64, aarch64)" ;;
esac

link="${BITROOT}/bin/bit"
[ -L "$link" ] \
  || die "no install.sh-managed install at ${link} (install with dist/install.sh, or set BITROOT)"
target="$(readlink "$link")"
case "$target" in
  */bin/bit) : ;;
  *) die "${link} does not point at an install's bin/bit (points at '${target}')" ;;
esac
install_dir="$(basename "$(dirname "$(dirname "$target")")")"
current="${install_dir#bit-}"
current="${current%-${os}-${arch}}"
[ "bit-${current}-${os}-${arch}" = "$install_dir" ] \
  || die "cannot read a version out of install directory '${install_dir}'"

if [ -n "${BIT_VERSION:-}" ]; then
  version="$BIT_VERSION"
else
  latest_url="https://api.github.com/repos/${REPO}/releases/latest"
  # The body is captured whole and parsed after, rather than piped into a
  # `grep -m1` that exits on the first match: the early exit leaves curl
  # writing into a closed pipe, and curl reports that on stderr as
  # `curl: (56) Failure writing output to destination` on every single run.
  latest_json="$(curl -fsSL "$latest_url")" \
    || die "could not reach $latest_url"
  tag="$(printf '%s\n' "$latest_json" | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -n 1)"
  [ -n "$tag" ] || die "could not resolve latest release tag from $latest_url"
  version="${tag#v}"
fi

if [ "$current" = "$version" ]; then
  echo "upgrade.sh: bit ${current} is already the newest release"
  exit 0
fi

if [ "$check_only" = yes ]; then
  echo "upgrade.sh: installed ${current}, newest ${version} - run 'bit upgrade' to replace it"
  exit 0
fi

artifact="bit-${version}-${os}-${arch}.tar.xz"
base_url="https://github.com/${REPO}/releases/download/v${version}"
install_name="bit-${version}-${os}-${arch}"

# Inside $BITROOT, so every later `mv` is a rename within one filesystem rather
# than a copy that can half-finish.
work_dir="$(mktemp -d "${BITROOT}/.upgrade.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT INT TERM

echo "upgrade.sh: downloading ${artifact} (bit ${current} -> ${version})" >&2
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
  || die "checksum mismatch for ${artifact}: expected ${expected}, got ${actual} (install left at ${current})"

tar -xJf "${work_dir}/${artifact}" -C "${work_dir}" \
  || die "extraction failed (install left at ${current})"
[ -x "${work_dir}/${install_name}/bin/bit" ] \
  || die "archive did not contain ${install_name}/bin/bit (install left at ${current})"

rm -rf "${BITROOT:?}/${install_name}"
mv "${work_dir}/${install_name}" "${BITROOT}/${install_name}"

# The swap: build the new symlink out of the way, then rename it over the live
# one. `ln -sf` on the live path would unlink it first, leaving a window with
# no `bit` on PATH at all; rename(2) has no such window.
ln -s "${BITROOT}/${install_name}/bin/bit" "${work_dir}/bit"
mv -f "${work_dir}/bit" "${BITROOT}/bin/bit"

echo "upgrade.sh: upgraded bit ${current} -> ${version} in ${BITROOT}" >&2
echo "upgrade.sh: the previous install is still at ${BITROOT}/${install_dir}" >&2
