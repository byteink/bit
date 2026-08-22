#!/usr/bin/env bash
# dist/release-verify.sh <version>   (e.g. 0.1.24 — no leading v)
#
# The release completion check: run it, do not remember it.
#
# A release is eight surfaces published by hand, in order, and the steps get
# done out of order under pressure. 0.1.10 was cut, probed, un-drafted,
# verified, brewed, imaged and repinned — and the website step was skipped,
# because the repin jumped the queue, and the site silently kept serving the
# previous release's docs. See .claude/skills/bit-release/SKILL.md §9 for the
# checklist this script replaces.
#
# Silence + exit 0 means every surface serves <version>. Each failure prints
# one "FAIL: ..." line naming the surface, and the exit code is 1.
#
# Design rules (do not undo these — see the ticket that added this script):
#   - every count is DERIVED (from the release's own SHA256SUMS, from digest
#     lines matched by pattern), never hardcoded — a hardcoded asset count
#     stayed wrong for six releases after #2748 added a new artifact.
#   - every query that can legitimately return empty is checked for emptiness
#     before being compared — an empty result is a fact about the query, not
#     a pass.
#   - every check that matters is done ANONYMOUSLY where the surface is
#     public: a draft answers a token-bearing request and 404s an anonymous
#     one, and a ghcr package is private-by-default in a way only an
#     anonymous pull can catch.
#   - `latest` is compared by DIGEST, never by position in a tag listing.
#   - this must work unchanged against an older, already-superseded tag.
set -u

usage() { echo "usage: $0 <version>   (e.g. 0.1.24 — no leading v)" >&2; exit 2; }
[ "$#" -eq 1 ] || usage
X="$1"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIT_REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
# The main worktree is always the first entry `git worktree list` prints, from
# any worktree — so this resolves the real workspace root (bit/'s parent)
# whether invoked from the shared checkout or a ticket worktree, with no
# hardcoded username or path.
MAIN_WORKTREE="$(git -C "$BIT_REPO" worktree list --porcelain 2>/dev/null | awk '/^worktree /{print $2; exit}')"
WS="${BIT_WORKSPACE_ROOT:-$(dirname "$MAIN_WORKTREE")}"

fails=0
fail() { echo "FAIL: $*"; fails=$((fails + 1)); }

# ---- 1. the release object: published, and complete ----
draft="$(gh release view "v$X" -R byteink/bit --json isDraft --jq '.isDraft' 2>/dev/null)"
if [ -z "$draft" ]; then
  fail "v$X: gh release view failed (tag missing, or unreachable)"
else
  [ "$draft" = "false" ] || fail "v$X is still a draft"
fi

# ---- 2. asset set: DERIVED from the release's own SHA256SUMS, never counted ----
# `-f` is load-bearing: GitHub's 404 body is the two words "Not Found", and
# without `-f` that survives `awk 'NF>=2{print $2}'` as a fake asset named
# "Found" — a 404 must fail the fetch, not parse as one confusing asset.
if sums="$(curl -sfL "https://github.com/byteink/bit/releases/download/v$X/SHA256SUMS")" && [ -n "$sums" ]; then
  want_assets="$(printf '%s\n' "$sums" | awk 'NF>=2 {print $2}' | sort)"
  got_assets="$(gh release view "v$X" -R byteink/bit --json assets --jq '.assets[].name' 2>/dev/null | grep -vx SHA256SUMS | sort)"
  [ "$want_assets" = "$got_assets" ] ||
    fail "asset set does not match SHA256SUMS: $(diff <(printf '%s\n' "$want_assets") <(printf '%s\n' "$got_assets") | tr '\n' ' ')"
else
  sums=""
  fail "could not fetch v$X SHA256SUMS anonymously (empty = a fact about the query)"
fi

# ---- 3. shipped bytes: anonymous download, digest, and the binary's own --version ----
# `lib/libbitrt.a` and `bin/bit` disagreed inside one tarball for six releases
# (#2213); the version string is the one assertion every release can make
# generically, without knowing what that release specifically fixed.
tarball="bit-$X-macos-aarch64.tar.xz"
want_digest="$(printf '%s\n' "$sums" | awk -v f="$tarball" '$2==f{print $1}')"
if [ -z "$want_digest" ]; then
  [ -n "$sums" ] && fail "SHA256SUMS has no entry for $tarball"
else
  probe_dir="$(mktemp -d "${TMPDIR:-/tmp}/release-verify.XXXXXX")"
  curl -sL -o "$probe_dir/$tarball" "https://github.com/byteink/bit/releases/download/v$X/$tarball"
  got_digest="$(shasum -a 256 "$probe_dir/$tarball" 2>/dev/null | awk '{print $1}')"
  if [ "$got_digest" != "$want_digest" ]; then
    fail "$tarball: anonymous download digest $got_digest != published $want_digest"
  else
    tar -C "$probe_dir" -xf "$probe_dir/$tarball"
    got_version="$("$probe_dir/bit-$X-macos-aarch64/bin/bit" --version 2>/dev/null)"
    case "$got_version" in
      *"$X"*) : ;;
      *) fail "shipped $tarball's --version says '$got_version', want $X" ;;
    esac
  fi
  rm -rf "$probe_dir"
fi

# ---- 4. brew serves it ----
have_brew="$(/opt/homebrew/bin/bit version 2>/dev/null)"
[ "$have_brew" = "bit $X" ] || fail "brew has '${have_brew:-<nothing>}', want 'bit $X'"

# ---- 5. ghcr, anonymously, by digest, and `latest` moved with it ----
# THE RETRY IS LOAD-BEARING: a single-shot read of `latest` has transiently
# returned an empty digest here before (0.1.11) while `latest` was correct.
tok="$(curl -s "https://ghcr.io/token?scope=repository:byteink/bit:pull&service=ghcr.io" |
       python3 -c 'import sys,json;print(json.load(sys.stdin).get("token",""))' 2>/dev/null)"
ghcr_digest() {
  for _ in 1 2 3; do
    r="$(curl -sI -H "Authorization: Bearer $tok" \
           -H 'Accept: application/vnd.oci.image.index.v1+json' \
           "https://ghcr.io/v2/byteink/bit/manifests/$1" 2>/dev/null |
         awk 'tolower($1) ~ /^docker-content-digest:/ {print $2}' | tr -d '\r')"
    [ -n "$r" ] && { printf '%s' "$r"; return 0; }
    sleep 2
  done
  return 1
}
if [ -z "$tok" ]; then
  fail "could not obtain an anonymous ghcr token"
else
  dx="$(ghcr_digest "$X")"
  dl="$(ghcr_digest latest)"
  if [ -z "$dx" ]; then
    fail "ghcr has no $X tag"
  elif [ "$dx" != "$dl" ]; then
    fail "ghcr latest is ${dl:-<empty>}, want $X's $dx"
  fi
fi

# ---- 6. stage0 pinned to it — match the DIGEST LINES only, never the whole file ----
# `grep -q "$X"` false-passes: the header prose predicts the NEXT version, so a
# plain text search can report the pin as moved while it still points at the
# previous release (caught on 0.1.12).
n="$(grep -cE "^[0-9a-f]{64}  bit-$X-" "$WS/bit/dist/stage0/SHA256SUMS" 2>/dev/null)"
n="${n:-0}"
[ "$n" = "3" ] || fail "stage0 not repinned to $X ($n digest line(s) for $X, want 3)"

# ---- 7. bitlang.org: both pins moved, committed, and pushed ----
vb_head="$(git -C "$WS/bit-website/vendor/bit" rev-parse HEAD 2>/dev/null)"
tag_commit="$(git -C "$WS/bit" rev-parse "v$X^{commit}" 2>/dev/null)"
if [ -z "$tag_commit" ]; then
  fail "v$X does not exist as a tag in $WS/bit"
elif [ "$vb_head" != "$tag_commit" ]; then
  fail "vendor/bit is not at v$X"
fi
grep -q "ghcr.io/byteink/bit:$X" "$WS/bit-website/Dockerfile" 2>/dev/null || fail "Dockerfile pins another toolchain"
[ -z "$(git -C "$WS/bit-website" status --porcelain 2>/dev/null)" ] || fail "bit-website is uncommitted"
[ -z "$(git -C "$WS/bit-website" log --oneline origin/main..HEAD 2>/dev/null)" ] || fail "bit-website is not pushed"

# ---- 8. and the site is actually up ----
code="$(curl -s -o /dev/null -w '%{http_code}' https://bitlang.org/ 2>/dev/null)"
[ "$code" = "200" ] || fail "bitlang.org is not 200 (got ${code:-<none>})"

if [ "$fails" -eq 0 ]; then
  exit 0
fi
exit 1
