#!/bin/sh
# Deploys the site to bitlang.org via ssd (SSH Deploy), the tool every byteink
# app on that server uses.
#
# This script exists for ONE reason: the pages are generated, so a bare
# `ssd deploy website` could ship a stale site. It fetches the advisory feed,
# regenerates every page, then hands over. Everything else — the server, the
# domains, the redirects, the image — lives in .ssd/ssd.yaml.
#
# .ssd/ is gitignored (deploy config is machine-local), so the committed
# reference copy is website/ssd.yaml.example. Start from it on a new machine.
#
# Prerequisites outside this repo:
#   - DNS: bitlang.org (and the other five hostnames, if you want the redirects
#     live) resolving to the byteink cluster, direct or via Cloudflare.
#   - .ssd/ssd.yaml present — copy website/ssd.yaml.example.
set -eu

root=$(unset CDPATH; cd -- "$(dirname -- "$0")/.." && pwd)

command -v ssd >/dev/null || { echo "deploy.sh: ssd not found (brew install ssd)" >&2; exit 1; }
[ -x "$root/zig-out/bin/bit" ] || {
	echo "deploy.sh: no built compiler at zig-out/bin/bit — run \`zig build\` first" >&2
	exit 1
}
[ -f "$root/.ssd/ssd.yaml" ] || {
	echo "deploy.sh: no .ssd/ssd.yaml — copy website/ssd.yaml.example to .ssd/ssd.yaml" >&2
	exit 1
}

# The advisory feed first: website/gen renders whatever is on disk, and an absent
# feed renders as "unavailable" rather than as "no advisories". A fetch failure is
# NOT fatal — the page states the truth either way — so this must not be `set -e`'d
# into failing the deploy.
sh "$root/website/advisories.sh" || true

# Then the whole site, from docs/ and examples/. Built with the SELF-HOSTED
# compiler, so a deploy also proves the compiler can build a real program.
gen=$(mktemp -t bitsite) || exit 1
trap 'rm -f "$gen"' EXIT
"$root/zig-out/bin/bit" build "$root/website/gen" -o "$gen"
(cd "$root" && "$gen")

# The server binary the container runs, cross-compiled for the container's
# target. `FROM scratch` has no toolchain and needs none: `bit build` emits a
# static executable with no libc and no dynamic loader.
#
# BIT_SERVER_TARGET exists so a local `docker build` on this Mac can produce an
# aarch64-linux image while the real deploy produces x86_64-linux for
# byteink.main. Getting it wrong is not subtle — the container exits immediately
# with an exec format error.
target=${BIT_SERVER_TARGET:-x86_64-linux}
mkdir -p "$root/website/build"
"$root/zig-out/bin/bit" build "$root/website/server" \
	-o "$root/website/build/staticserver" --target "$target"
echo "deploy.sh: built the server for ${target}"

# Run from the repo root: ssd resolves `files:` paths relative to it, not to
# wherever this script was invoked from.
cd "$root"
ssd deploy website

echo "deploy.sh: https://bitlang.org/"
