#!/bin/sh
# Verify a stage0 `bit` artifact against the digest COMMITTED IN THIS REPO.
#
# See docs/release/bootstrap.md §1 for why this exists and why it does not reuse
# dist/install.sh's check. In one line: install.sh downloads SHA256SUMS from the
# same base URL as the tarball, which catches corruption but is not a trust
# anchor — anyone who can serve a modified artifact can serve a matching sum.
# Stage0 compiles the compiler, so its digest has to come from a reviewed commit
# instead. That file is dist/stage0/SHA256SUMS and it is the ONLY digest this
# script will consult.
#
# Refuses rather than warns. A bootstrap that continues past a failed digest
# check is a bootstrap with no digest check.
#
# STRICTLY POSIX, AND `sh` NOT `bash` (#1874). scripts/stage0.sh runs this with
# an explicit `sh`, which overrides the shebang — so a `set -o pipefail` here
# was accepted by macOS (bash in POSIX mode) and rejected by dash on every Linux
# gate host, killing the bootstrap with `Illegal option -o pipefail` before a
# single digest was compared. This is the entry point to building the compiler;
# it may not assume a shell richer than the host's /bin/sh.
#
# Losing pipefail costs nothing here because the one pipeline whose failure
# matters is checked explicitly below.
set -eu

REPO="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
SUMS="${REPO}/dist/stage0/SHA256SUMS"

die() { printf 'stage0-verify: %s\n' "$*" >&2; exit 1; }

[ $# -eq 1 ] || die "usage: dist/stage0-verify.sh <artifact.tar.xz>"
artifact="$1"
[ -f "${artifact}" ] || die "no such file: ${artifact}"
[ -f "${SUMS}" ] || die "missing committed digest file: ${SUMS}
  Stage0 cannot be verified without it. Do not work around this by trusting a
  downloaded SHA256SUMS — see docs/release/bootstrap.md §1."

# One of the three supported triples, or nothing. Section 2 of the doc: an
# unsupported host has no stage0 and must cross-compile from a supported one.
case "$(uname -s)-$(uname -m)" in
  Darwin-arm64)          triple=macos-aarch64 ;;
  Linux-aarch64|Linux-arm64) triple=linux-aarch64 ;;
  Linux-x86_64)          triple=linux-x86_64 ;;
  *) die "unsupported host $(uname -s)-$(uname -m); Bit ships macos-aarch64,
  linux-aarch64 and linux-x86_64 only. Cross-compile a stage0 from a supported
  host — docs/release/bootstrap.md §2." ;;
esac

base="$(basename "${artifact}")"
# Match the triple, not the exact filename: the version moves, the triple does
# not, and pinning the whole name here would mean editing this script per release.
line="$(grep -E "  .*${triple}\.tar\.xz\$" "${SUMS}" || true)"
[ -n "${line}" ] || die "no committed digest for triple '${triple}' in ${SUMS}"
[ "$(printf '%s\n' "${line}" | wc -l | tr -d ' ')" = "1" ] \
  || die "more than one digest for triple '${triple}' in ${SUMS} — ambiguous, refusing"

want="${line%% *}"
named="${line##* }"
if [ "${base}" != "${named}" ]; then
  die "artifact '${base}' is not the pinned stage0 for this host.
  Pinned: ${named}
  Bootstrapping from a different build than the committed digest describes is
  exactly what the digest exists to prevent."
fi

if command -v sha256sum >/dev/null 2>&1; then
  got="$(sha256sum "${artifact}" | cut -d' ' -f1)"
elif command -v shasum >/dev/null 2>&1; then
  got="$(shasum -a 256 "${artifact}" | cut -d' ' -f1)"
else
  die "neither sha256sum nor shasum found; cannot verify"
fi

# Checked rather than left to the comparison below. An empty `got` would still
# refuse — as a DIGEST MISMATCH — which blames the artifact for a broken hasher.
[ -n "${got}" ] || die "the checksum tool produced no digest for ${artifact}"

[ "${got}" = "${want}" ] || die "DIGEST MISMATCH for ${base}
  expected ${want}
  actual   ${got}
  Refusing. Do not bootstrap from this artifact."

printf 'stage0-verify: OK  %s  %s\n' "${triple}" "${base}"
