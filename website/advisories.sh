#!/bin/sh
# Fetches byteink/bit's published GitHub Security Advisories to
# website/advisories.json, for website/gen to render.
#
# This is the ONE piece of the old website/support.sh worth keeping in shell: it
# owns GitHub auth (via the `gh` CLI, so no token lives here) and one rule that
# must not be reimplemented casually.
#
# THE RULE: a 404 means "this repo has no advisory surface" ONLY after the repo
# itself is confirmed reachable. GitHub answers 404 — not 403 — for a repo the
# token cannot see, and for a renamed or mistyped one. Treating either as an empty
# feed publishes a false all-clear on a security page. Anything this script cannot
# prove is an empty feed leaves NO file behind, and the generator renders its
# "unavailable" banner instead.
#
# Writing nothing is therefore a correct outcome, not a failure to paper over.
set -eu

REPO=${BIT_REPO:-byteink/bit}
root=$(unset CDPATH; cd -- "$(dirname -- "$0")/.." && pwd)
out=${BIT_ADVISORIES_OUT:-$root/website/advisories.json}

# REPO is spliced into the request path, so it is a value crossing a trust
# boundary. Rejecting anything outside owner/name also stops a value carrying `?`
# or extra path segments from reshaping the request and slipping past the
# server-side state=published filter.
echo "$REPO" | grep -Eq '^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$' || {
	echo "advisories.sh: BIT_REPO must be owner/name, got '$REPO'" >&2
	exit 2
}

command -v gh >/dev/null || {
	echo "advisories.sh: gh not found — leaving no feed; the page will say so" >&2
	rm -f "$out"
	exit 0
}

body=$(mktemp) || exit 1
err=$(mktemp) || { rm -f "$body"; exit 1; }
trap 'rm -f "$body" "$err"' EXIT

rc=0
# state=published server-side so a draft is never sent to us at all. The
# generator filters again, so a future API change cannot turn an embargoed draft
# into a published-looking row on the page.
gh api -X GET "/repos/$REPO/security-advisories" -f state=published --paginate \
	>"$body" 2>"$err" || rc=$?

if [ "$rc" -eq 0 ]; then
	mv "$body" "$out"
	trap 'rm -f "$err"' EXIT
	echo "advisories.sh: wrote $out"
	exit 0
fi

# The one recoverable case. All three conditions are required:
#   - the failure really was a 404, not a network or auth error;
#   - the body holds no non-empty array — a --paginate run that died partway
#     leaves some pages behind, and a partial feed must never be presented as the
#     whole one. (The body is not merely tested for emptiness: gh writes the API
#     error object to stdout, so even a plain 404 leaves a body.)
#   - the repo itself is reachable, which is what separates "no advisories" from
#     "wrong or invisible repo".
if grep -q '(HTTP 404)$' "$err" &&
	! jq -e 'type == "array" and length > 0' "$body" >/dev/null 2>&1 &&
	gh api "/repos/$REPO" >/dev/null 2>&1; then
	echo '[]' >"$out"
	echo "advisories.sh: no published advisories for $REPO"
	exit 0
fi

# Everything else: leave no feed. The page will say the feed is unavailable, which
# is true, rather than claiming there are no advisories, which would not be.
rm -f "$out"
echo "advisories.sh: could not fetch advisories for $REPO — the page will say the feed is unavailable" >&2
sed 's/^/advisories.sh: gh: /' "$err" >&2
exit 0
