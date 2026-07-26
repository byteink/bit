#!/bin/sh
# Deploys the site to bitlang.org via ssd (SSH Deploy), the tool every byteink
# app on that server uses.
#
# This script exists for ONE reason: the pages are generated, so a bare
# `ssd deploy website` could ship a stale support matrix. It regenerates first,
# then hands over. Everything else — the server, the domains, the redirects, the
# nginx image, which files land where — lives in .ssd/ssd.yaml.
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
[ -f "$root/.ssd/ssd.yaml" ] || {
	echo "deploy.sh: no .ssd/ssd.yaml — copy website/ssd.yaml.example to .ssd/ssd.yaml" >&2
	exit 1
}

sh "$root/website/support.sh"

# Run from the repo root: ssd resolves `files:` paths relative to it, not to
# wherever this script was invoked from.
cd "$root"
ssd deploy website

echo "deploy.sh: https://bitlang.org/"
