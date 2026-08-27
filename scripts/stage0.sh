#!/bin/sh
# Resolve the PINNED stage0 `bit` — the previous release, which is the oracle
# every `selfhost-diff*.sh` gate compares the working tree against once `seed/`
# is gone (#1593, docs/release/bootstrap.md §4).
#
# Prints ONE line on stdout: the absolute path to the stage0 `bit` binary.
# Everything else goes to stderr, so `ORACLE="$(sh scripts/stage0.sh)"` is safe.
#
# `sh scripts/stage0.sh --stdlib-root` prints a SECOND thing instead: the
# absolute path to the pinned release's OWN `stdlib/` (unpacked from the same
# tarball, fetched/verified exactly as above; no wrapper, no BIT_STDLIB
# involved). test-release-surface (tests/bit/releasesurface/, #3039) is the
# one consumer — it diffs the stdlib SOURCE across a version boundary, which
# needs the previous release's own copy of `stdlib/http`, not the working
# tree's. Every other consumer here wants compiler EQUIVALENCE on one shared
# stdlib (the wrapper's whole reason to exist, per the comment on
# `emit_wrapper` below) and must keep using the default, no-argument form.
#
# WHAT THIS REPLACES, AND HOW THE MEANING CHANGES
#
# Until #1593 the oracle was `bit-out/bin/bit-seed`: a compiler written in a
# different language by different code, so a green diff meant "two independent
# implementations agree". The pinned stage0 is the SAME implementation one
# release back, so a green diff now means "this version did not change
# behaviour versus the last release". Both are useful. They are not the same
# assertion, and bootstrap.md §5 records the loss rather than papering over it.
#
# WHY IT REFUSES INSTEAD OF SKIPPING
#
# A gate that cannot reach its oracle and exits 0 is worse than no gate: it
# reports green for an assertion it never made. Every failure path here is a
# non-zero exit with a message naming what to do.
set -eu

mode=bin
if [ $# -gt 0 ]; then
  case "$1" in
    --stdlib-root) mode=stdlib ;;
    *) printf 'stage0: unknown argument %s (only --stdlib-root is accepted)\n' "$1" >&2; exit 1 ;;
  esac
fi

ROOT="$(unset CDPATH; cd -- "$(dirname -- "$0")/.." && pwd)"
SUMS="${ROOT}/dist/stage0/SHA256SUMS"
CACHE="${BIT_STAGE0_CACHE:-${ROOT}/bit-out/stage0}"

die() { printf 'stage0: %s\n' "$*" >&2; exit 1; }

# THE BOOTSTRAP ESCAPE HATCH (#1857). `BIT_STAGE0_BIN=<path>` makes every
# consumer — tools/build/, dist/release.sh, all fifteen differentials — use that
# compiler as stage0 instead of the pinned release.
#
# It exists for one situation, and it is not hypothetical: when a bug is fixed
# IN THE COMPILER and the runtime's correctness depends on the fix, the pinned
# release cannot build a correct tree, and a correct tree cannot be released
# without a correct compiler. #1857 was exactly that — `parseFloat` had no
# hex-float branch, so stage0 compiled `runtime/root/floatslog.bit`'s
# coefficients to zero and `log(x)` returned 0 for every input. Breaking the
# cycle takes two passes:
#
#   ./make                                        # pass 1: stage0 -> bit with the fix
#   BIT_STAGE0_BIN=$PWD/bit-out/bin/bit ./make    # pass 2: that bit -> correct runtime
#
# then cut a release from pass 2 and repin dist/stage0/SHA256SUMS, after which a
# single pass is correct again and this variable goes back to being unused.
#
# THIS RECIPE COVERS A COMPILER-ONLY FIX. #1857's runtime was unchanged, so
# pass 1's plain `./make` already builds against a runtime stage0 is
# self-consistent with. It does NOT generalise to a runtime ABI or
# wire-format change — there the working tree's `runtime/**` already carries
# the NEW shape, so pass 1's plain `./make` is exactly the configuration
# `tools/build/abiarity.bit`'s runtime ABI arity guard refuses, and running
# the recipe above just reproduces the same refusal. For that case, pass 1
# instead needs the OLD runtime checked out first:
#
#   rm -rf bit-out
#   git checkout <commit before the runtime/** change> -- runtime/
#   ./make                                       # pass 1: new compiler/**, linked against the OLD runtime
#   cp bit-out/bin/bit "$TMPDIR/bit1"
#   git checkout HEAD -- runtime/                # restore before anything else reads the tree
#   BIT_STAGE0_BIN="$TMPDIR/bit1" ./make          # pass 2 -- do NOT rm -rf bit-out here
#
# See docs/development.md, "Landing a runtime ABI change", for why (the OLD
# runtime is what stage0's frozen call-site arity still matches) and for the
# two traps above (no rm -rf between passes; restore runtime/ on every exit
# path, including failure).
#
# DELIBERATELY UNVERIFIED, unlike the pinned path: there is no digest to check an
# arbitrary local binary against. That is the whole point, and it is why this is
# an explicit opt-in that announces itself on stderr rather than a fallback.
if [ -n "${BIT_STAGE0_BIN:-}" ]; then
  # BIT_STAGE0_BIN names an arbitrary local binary, not an unpacked release
  # tarball — there is no `stdlib/` snapshot that goes with it, so a caller
  # asking for one is asking this script for something that does not exist
  # in this mode.
  [ "${mode}" = "bin" ] || die "--stdlib-root has no meaning under BIT_STAGE0_BIN=${BIT_STAGE0_BIN} (it names a binary, not an unpacked release)"
  [ -x "${BIT_STAGE0_BIN}" ] || die "BIT_STAGE0_BIN=${BIT_STAGE0_BIN} is not executable"
  printf 'stage0: OVERRIDDEN by BIT_STAGE0_BIN=%s (unverified; see scripts/stage0.sh)\n' \
    "${BIT_STAGE0_BIN}" >&2
  mkdir -p "${CACHE}"
  binary="${BIT_STAGE0_BIN}"
  wrapper="${CACHE}/bit-oracle"
  tmp="${wrapper}.$$"
  cat > "${tmp}" <<WRAP
#!/bin/sh
# Generated by scripts/stage0.sh from BIT_STAGE0_BIN — NOT the pinned stage0.
BIT_STDLIB="\${BIT_STDLIB:-${ROOT}/stdlib}"
export BIT_STDLIB
exec "${binary}" "\$@"
WRAP
  chmod +x "${tmp}"
  mv -f "${tmp}" "${wrapper}"
  printf '%s\n' "${wrapper}"
  exit 0
fi

[ -f "${SUMS}" ] || die "missing ${SUMS} — the pin is what makes stage0 trustworthy;
  see docs/release/bootstrap.md §1"

# Same triple mapping as dist/stage0-verify.sh. Kept in step with it by the
# gate below rather than by hope: an unsupported host has no stage0 and must
# cross-compile from a supported one (bootstrap.md §2).
case "$(uname -s)-$(uname -m)" in
  Darwin-arm64)              triple=macos-aarch64 ;;
  Linux-aarch64|Linux-arm64) triple=linux-aarch64 ;;
  Linux-x86_64)              triple=linux-x86_64 ;;
  *) die "unsupported host $(uname -s)-$(uname -m); stage0 ships macos-aarch64,
  linux-aarch64 and linux-x86_64 only — bootstrap.md §2" ;;
esac

# The pin names the exact artifact. Reading the FILENAME out of the digest file
# rather than composing it from a version variable means there is one source of
# truth for which build is stage0.
line="$(grep -E "  .*${triple}\.tar\.xz\$" "${SUMS}" || true)"
[ -n "${line}" ] || die "no committed digest for triple '${triple}' in ${SUMS}"
[ "$(printf '%s\n' "${line}" | wc -l | tr -d ' ')" = "1" ] \
  || die "more than one digest for triple '${triple}' in ${SUMS} — ambiguous, refusing"

artifact="${line##* }"
# bit-<version>-<triple>.tar.xz -> <version>
version="$(printf '%s' "${artifact}" | sed -e 's/^bit-//' -e "s/-${triple}\.tar\.xz\$//")"
prefix="${CACHE}/bit-${version}-${triple}"
binary="${prefix}/bin/bit"
wrapper="${CACHE}/bit-oracle"

# WHY THE PATH PRINTED IS A WRAPPER AND NOT `${binary}`
#
# The stage0 tarball ships its OWN stdlib, and `bit` finds the stdlib relative
# to the binary. Invoked bare, the oracle would compile the RELEASE's stdlib
# while the working-tree compiler compiles the repo's — so every differential
# would be diffing two stdlibs instead of two compilers.
#
# That is not hypothetical: it showed up the first time `selfhost-diffcheck.sh`
# ran against stage0, as seven files whose diagnostics pointed at
# `bit-out/stage0/.../stdlib/crypto/mldsantt.bit` on one side and
# `stdlib/crypto/mldsantt.bit` on the other. Same compiler, same source, and the
# only difference was which copy of the stdlib each side read.
#
# Pinning `BIT_STDLIB` here rather than in each of the fifteen gates means no
# gate can forget it, and a gate added later inherits the fix.
emit_wrapper() {
  tmp="${wrapper}.$$"
  cat > "${tmp}" <<WRAP
#!/bin/sh
# Generated by scripts/stage0.sh — do not edit; regenerated on every cache miss.
# Pins the stdlib to the WORKING TREE's so a differential compares compilers.
BIT_STDLIB="\${BIT_STDLIB:-${ROOT}/stdlib}"
export BIT_STDLIB
exec "${binary}" "\$@"
WRAP
  chmod +x "${tmp}"
  mv -f "${tmp}" "${wrapper}"
}

# Emits whatever `mode` asked for, once `${binary}` is known to exist
# (unpacked, either already or freshly below).
emit_result() {
  if [ "${mode}" = "stdlib" ]; then
    [ -d "${prefix}/stdlib" ] || die "unpacked ${artifact} but ${prefix}/stdlib is missing"
    printf '%s\n' "${prefix}/stdlib"
    return
  fi
  emit_wrapper
  printf '%s\n' "${wrapper}"
}

# Already unpacked: say nothing, print the result, touch the network never.
# This is the path every gate takes on every run after the first. The
# wrapper (mode=bin) is rewritten anyway — it is three lines, and a stale one
# that points at a moved checkout is a far worse failure than regenerating it.
if [ -x "${binary}" ]; then
  emit_result
  exit 0
fi

command -v curl >/dev/null || die "curl not found; cannot fetch stage0"
mkdir -p "${CACHE}"
tarball="${CACHE}/${artifact}"

if [ ! -f "${tarball}" ]; then
  url="https://github.com/byteink/bit/releases/download/v${version}/${artifact}"
  printf 'stage0: fetching %s\n' "${url}" >&2
  # -f so an HTML error page is a failure rather than a corrupt "artifact".
  curl -fsSL -o "${tarball}.part" "${url}" \
    || { rm -f "${tarball}.part"; die "download failed: ${url}
  A draft release is NOT publicly downloadable — check the release is published."; }
  mv "${tarball}.part" "${tarball}"
fi

# The digest check is the whole point, so it runs on every fresh unpack and uses
# the COMMITTED sums via the dedicated script — never a SHA256SUMS fetched from
# the same server as the tarball (bootstrap.md §1).
sh "${ROOT}/dist/stage0-verify.sh" "${tarball}" >&2 \
  || { rm -f "${tarball}"; die "stage0 failed digest verification; refusing to use it"; }

rm -rf "${prefix}"
tar xf "${tarball}" -C "${CACHE}"
[ -x "${binary}" ] || die "unpacked ${artifact} but ${binary} is missing or not executable"

emit_result
