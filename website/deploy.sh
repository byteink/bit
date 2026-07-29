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
[ -x "$root/bit-out/bin/bit" ] || {
	echo "deploy.sh: no built compiler at bit-out/bin/bit — run \`./make\` first" >&2
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
"$root/bit-out/bin/bit" build "$root/website/gen" -o "$gen"
(cd "$root" && "$gen")

# ssd ships the build context with `git archive HEAD`, so the SERVER builds from
# committed source only — the pages just regenerated are invisible to it until they
# are committed. Deploying with them dirty would silently publish the previous
# site, which is the worst kind of deploy bug: it succeeds.
if ! git -C "$root" diff --quiet -- website/public; then
	echo "deploy.sh: website/public/ has uncommitted changes." >&2
	echo "deploy.sh: ssd builds on the server from \`git archive HEAD\`, so these" >&2
	echo "deploy.sh: pages would NOT ship — the previous site would deploy instead." >&2
	echo "deploy.sh: commit them, then deploy." >&2
	git -C "$root" --no-pager diff --stat -- website/public >&2
	exit 1
fi

# The server binary is NOT built here: website/Dockerfile builds it in a stage, on
# the server, from committed source. Anything built here would live under a
# gitignored path and never reach the build context.

# Run from the repo root: ssd resolves `files:` paths relative to it, not to
# wherever this script was invoked from.
cd "$root"
ssd deploy website

echo "deploy.sh: https://bitlang.org/"
