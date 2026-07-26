#!/bin/sh
# Generates website/public/support.html — the Support/Security page for
# bit-lang.byteink.com — from docs/release/SUPPORT.md plus the repo's published
# GitHub Security Advisories. Output is static HTML with no client-side JS, so
# the page cannot leak a token and cannot break if GitHub is down.
#
# Sync mechanism and cadence: website/README.md.
#
# ponytail: one POSIX sh script, no site framework and no npm — the page is a
# table and a list. Reach for a static-site generator only if the site grows
# past a handful of pages.
set -eu

REPO=${BIT_REPO:-byteink/bit}
root=$(unset CDPATH; cd -- "$(dirname -- "$0")/.." && pwd)
src=${BIT_SUPPORT_MD:-$root/docs/release/SUPPORT.md}
out=${BIT_SUPPORT_OUT:-$root/website/public/support.html}

die() { echo "support.sh: $1" >&2; exit 1; }

# REPO is spliced into the API request path and into href attributes, so it is a
# value crossing a trust boundary: validate it here rather than escaping it at
# four call sites. Rejecting anything outside owner/name also stops a value
# carrying '?' or extra path segments from reshaping the request and slipping
# past the server-side state=published filter.
echo "$REPO" | grep -Eq '^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$' ||
	die "BIT_REPO must be owner/name, got '$REPO'"

# Markdown table rows under the "## Support matrix" heading only: the section
# opens at that heading and closes at the next heading of ANY level, so neither a
# subheading's table nor a later section's table can bleed into the matrix.
#
# The column count comes from the header row rather than a hardcoded 5. A row
# that disagrees with the header is a hard error, not a silently truncated or
# dropped row — the page's whole job is to list every row of the matrix, so
# quietly publishing a subset is worse than failing the build.
matrix_rows() {
	awk '
		function esc(s) {
			gsub(/&/, "\\&amp;", s); gsub(/</, "\\&lt;", s)
			gsub(/>/, "\\&gt;", s); gsub(/"/, "\\&quot;", s)
			return s
		}
		function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
		# A cell may legally contain an escaped pipe. Park it somewhere split()
		# cannot see before splitting, and put it back per cell afterwards.
		function unpipe(s) { gsub(SUBSEP, "|", s); return s }
		# A GFM delimiter row is all dashes and optional alignment colons —
		# |---|, |:-:|, and |-|-| are all legal and none of them are data.
		function is_delim(nc, c,   i, t) {
			for (i = 1; i <= nc; i++) {
				t = trim(c[i])
				if (t !~ /^:?-+:?$/) return 0
			}
			return 1
		}
		# Fenced blocks are opaque: a shell comment inside one is not a heading and
		# a pipe table inside one is not the matrix. Tracked before anything else,
		# because both mistakes are silent — one truncates the matrix at the fence,
		# the other pulls the fence contents into it.
		/^[ \t]*```/ { fence = !fence; next }
		fence { next }
		/^##[ \t]+Support matrix/ { insec = 1; next }
		insec && /^#+[ \t]/ { insec = 0 }
		insec && /^[ \t]*\|/ {
			line = trim($0)
			gsub(/\\\|/, SUBSEP, line)
			sub(/^\|/, "", line); sub(/\|$/, "", line)
			n = split(line, cell, /\|/)
			if (is_delim(n, cell)) next
			if (++seen == 1) { cols = n; kind = "th" } else { kind = "td" }
			if (n != cols) {
				printf "matrix row %d has %d cells, header has %d\n", NR, n, cols \
					> "/dev/stderr"
				exit 4
			}
			printf "        <tr>"
			for (i = 1; i <= cols; i++)
				printf "<%s>%s</%s>", kind, esc(unpipe(trim(cell[i]))), kind
			printf "</tr>\n"
		}
		END {
			# An unclosed fence would have swallowed the rest of the doc silently.
			if (fence) { print "unterminated code fence" > "/dev/stderr"; exit 5 }
			if (seen < 1) exit 3
			# A header with no releases under it is the state SUPPORT.md declares
			# correct until v1.0 ships ("the matrix below is empty by design"), so
			# it has to render rather than fail the build.
			if (seen == 1)
				printf "        <tr><td colspan=\"%d\">No release is under this policy yet.</td></tr>\n", cols
		}
	' "$src"
}

# Published advisories only. The state filter is applied twice on purpose:
# server-side so a draft is never sent to us, and again in jq so a future API
# change cannot turn an embargoed draft into a published-looking row here.
#
# A 404 is an empty feed ONLY once the repo itself is confirmed reachable. GitHub
# answers 404 — not 403 — for a repo the token cannot see, and also for a renamed
# or mistyped one, so "404" on its own cannot distinguish "this repo has no
# advisory surface" from "we never reached the right repo". Publishing the
# definitive "no advisories" for the second case is a false all-clear on a
# security page. Everything else falls through to the "unavailable" banner,
# including a --paginate run that failed partway: if the body holds a non-empty
# array then some pages arrived and others did not, and a partial feed must not
# be presented as the whole one. (The body is not simply tested for emptiness —
# gh writes the API error object to stdout, so a plain 404 leaves a body too.)
advisories_json() {
	if [ -n "${BIT_ADVISORIES_JSON:-}" ]; then
		cat "$BIT_ADVISORIES_JSON"
		return 0
	fi
	# Buffer both streams: on failure gh prints the error body to stdout, and
	# letting that through would feed the renderer a non-advisory JSON object.
	body=$(mktemp) || return 1
	err=$(mktemp) || { rm -f "$body"; return 1; }
	rc=0
	gh api -X GET "/repos/$REPO/security-advisories" -f state=published --paginate \
		>"$body" 2>"$err" || rc=$?
	if [ "$rc" -eq 0 ]; then
		cat "$body"
	elif grep -q '(HTTP 404)$' "$err" &&
		! jq -e 'type == "array" and length > 0' "$body" >/dev/null 2>&1 &&
		gh api "/repos/$REPO" >/dev/null 2>&1; then
		echo '[]'
		rc=0
	fi
	rm -f "$body" "$err"
	return "$rc"
}

advisory_items() {
	jq -er '
		def h: tostring | @html;
		if type != "array" then error("advisory feed is not a JSON array") else . end
		| [ .[] | select(.state == "published") ]
		| sort_by(.published_at // "") | reverse
		| if length == 0 then
			"        <li class=\"empty\">No published security advisories.</li>"
		  else
			.[] | "        <li>\n"
				+ "          <a href=\"" + ((.html_url // "") | h) + "\">" + ((.ghsa_id // "GHSA") | h) + "</a>\n"
				+ "          <span class=\"sev\">" + ((.severity // "unknown") | h) + "</span>\n"
				+ "          <time>" + ((.published_at // "")[0:10] | h) + "</time>\n"
				+ "          <span class=\"cve\">" + ((.cve_id // "no CVE") | h) + "</span>\n"
				+ "          <p>" + ((.summary // "") | h) + "</p>\n"
				+ "        </li>"
		  end
	'
}

render() {
	rows=$1 advisories=$2 note=$3 stamp=$4
	cat <<HTML
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Support and security — Bit</title>
<link rel="stylesheet" href="/support.css">
</head>
<body>
<main>
  <h1>Support and security</h1>

  <section aria-labelledby="matrix">
    <h2 id="matrix">Support matrix</h2>
    <p>Which release lines get bug fixes, which get security fixes only, and
    when each reaches end of life. The policy that generates these dates is
    <a href="https://github.com/$REPO/blob/main/docs/release/SUPPORT.md">SUPPORT.md</a>.</p>
    <table>
      <tbody>
$rows
      </tbody>
    </table>
  </section>

  <section aria-labelledby="advisories">
    <h2 id="advisories">Security advisories</h2>
    <p>Published advisories for <code>$REPO</code>. Report a vulnerability
    privately via <a href="https://github.com/$REPO/security/advisories/new">GitHub
    Security Advisories</a> — never in a public issue.</p>
    <ul class="advisories">
$advisories
    </ul>$note
  </section>

  <footer>
    <p>Generated $stamp by <code>website/support.sh</code> from
    <code>docs/release/SUPPORT.md</code> and the GitHub Security Advisories API.
    Regenerated on every change to either source; see
    <a href="https://github.com/$REPO/blob/main/website/README.md">website/README.md</a>.</p>
  </footer>
</main>
</body>
</html>
HTML
}

self_check() {
	tmp=$(mktemp -d) || die "mktemp failed"
	trap 'rm -rf "$tmp"' EXIT

	cat >"$tmp/SUPPORT.md" <<'MD'
# Support Policy

## Cadence definitions

| not | the | matrix | table | ignore |
|---|---|---|---|---|

## Support matrix

| version | released | full-support-end | EOL | status |
|:-:|:-:|:-:|:-:|:-:|
| 1.0 | 2026-10-01 | 2027-10-01 | 2031-10-01 | full support |

```sh
# a comment inside a fence is not a heading, and must not end the section
| FENCED | must | not | be | emitted |
```

| 0.9 \| beta <script> | 2026-01-01 | 2026-10-01 | 2026-10-01 | EOL |

### Deprecated lines

| subsec | must | not | bleed | either |
|-|-|-|-|-|

## After

| bleed | must | not | happen | here |
|---|---|---|---|---|
MD

	# Same doc with the release rows removed — the state SUPPORT.md calls correct
	# until v1.0 ships. Must render, not fail the build.
	grep -v '^| \(1\.0\|0\.9\) ' "$tmp/SUPPORT.md" >"$tmp/empty.md"

	# A row that disagrees with the header must fail loudly, not lose a cell.
	sed 's/^| 1\.0 .*/| 1.0 | 2026-10-01 | 2027-10-01 |/' "$tmp/SUPPORT.md" >"$tmp/ragged.md"

	cat >"$tmp/adv.json" <<'JSON'
[
  {"state":"draft","ghsa_id":"GHSA-draft","severity":"critical","published_at":null,
   "cve_id":null,"html_url":"https://example.invalid/draft","summary":"EMBARGOED"},
  {"state":"published","ghsa_id":"GHSA-old","severity":"low","published_at":"2026-01-02T00:00:00Z",
   "cve_id":"CVE-2026-1","html_url":"https://github.com/x/1","summary":"old one"},
  {"state":"published","ghsa_id":"GHSA-new","severity":"high","published_at":"2026-06-02T00:00:00Z",
   "cve_id":null,"html_url":"https://github.com/x/2","summary":"<img src=x onerror=alert(1)>"}
]
JSON

	BIT_SUPPORT_MD=$tmp/SUPPORT.md BIT_SUPPORT_OUT=$tmp/out.html \
		BIT_ADVISORIES_JSON=$tmp/adv.json "$0" >/dev/null

	fail=0
	assert() { # assert <description> <grep-args...>
		d=$1; shift
		if grep -q "$@" "$tmp/out.html"; then return 0; fi
		echo "FAIL: $d" >&2; fail=1
	}
	refute() {
		d=$1; shift
		if grep -q "$@" "$tmp/out.html"; then echo "FAIL: $d" >&2; fail=1; fi
	}

	refute "draft advisory leaked" -- 'GHSA-draft'
	refute "embargoed summary leaked" -- 'EMBARGOED'
	assert "published advisories rendered" -- 'GHSA-new'
	assert "older published advisory rendered" -- 'GHSA-old'
	assert "advisory summary HTML-escaped" -- '&lt;img src=x onerror=alert(1)&gt;'
	refute "raw img tag emitted" -- '<img src=x'
	assert "matrix header row" -- '<th>full-support-end</th>'
	assert "matrix row 1.0" -- '<td>1\.0</td>'
	assert "matrix cell HTML-escaped" -- '<td>0\.9 | beta &lt;script&gt;</td>'
	# A fenced block inside the section must neither end it (dropping every row
	# after the fence) nor contribute rows of its own.
	assert "row after a fenced block survives" -- '<td>0\.9 | beta'
	refute "fenced table bled in" -- '<td>FENCED</td>'
	refute "table from a later h2 bled in" -- '<td>bleed</td>'
	refute "table under an h3 subheading bled in" -- '<td>subsec</td>'
	refute "cadence table bled in" -- '<td>matrix</td>'
	refute "alignment delimiter row emitted" -- '<td>:-:</td>'

	# Newest advisory must come first.
	if [ "$(grep -n 'GHSA-new' "$tmp/out.html" | cut -d: -f1 | head -1)" -gt \
	     "$(grep -n 'GHSA-old' "$tmp/out.html" | cut -d: -f1 | head -1)" ]; then
		echo "FAIL: advisory feed not newest-first" >&2; fail=1
	fi

	# The bare domain must resolve to the page, not to nginx's 403. Checked before
	# the sub-runs below, which write their own index.html into the same $tmp.
	if [ -f "$tmp/index.html" ]; then
		cmp -s "$tmp/out.html" "$tmp/index.html" ||
			{ echo "FAIL: index.html differs from the generated page" >&2; fail=1; }
	else
		echo "FAIL: no index.html written beside the page" >&2; fail=1
	fi

	# A header-only matrix renders an empty state instead of failing the build.
	if BIT_SUPPORT_MD=$tmp/empty.md BIT_SUPPORT_OUT=$tmp/empty.html \
		BIT_ADVISORIES_JSON=$tmp/adv.json "$0" >/dev/null 2>&1; then
		grep -q 'No release is under this policy yet' "$tmp/empty.html" ||
			{ echo "FAIL: header-only matrix lost its empty state" >&2; fail=1; }
		grep -q '<th>status</th>' "$tmp/empty.html" ||
			{ echo "FAIL: header-only matrix lost its header" >&2; fail=1; }
	else
		echo "FAIL: header-only matrix failed the build" >&2; fail=1
	fi

	# A ragged row is a hard error, never a silently shortened page.
	if BIT_SUPPORT_MD=$tmp/ragged.md BIT_SUPPORT_OUT=$tmp/ragged.html \
		BIT_ADVISORIES_JSON=$tmp/adv.json "$0" >/dev/null 2>&1; then
		echo "FAIL: ragged matrix row accepted" >&2; fail=1
	fi
	[ ! -f "$tmp/ragged.html" ] ||
		{ echo "FAIL: ragged matrix still wrote a page" >&2; fail=1; }

	# An unclosed fence would silently swallow the rest of the doc.
	sed '/^```sh$/d' "$tmp/SUPPORT.md" >"$tmp/openfence.md"
	if BIT_SUPPORT_MD=$tmp/openfence.md BIT_SUPPORT_OUT=$tmp/openfence.html \
		BIT_ADVISORIES_JSON=$tmp/adv.json "$0" >/dev/null 2>&1; then
		echo "FAIL: unterminated fence accepted" >&2; fail=1
	fi

	# REPO crosses a trust boundary into an href and the API path.
	for bad in 'byteink/bit" onmouseover="alert(1)' 'byteink/bit?x=1' \
		'byteink/bit/extra' 'byteink' '../../etc'; do
		if BIT_REPO=$bad BIT_SUPPORT_MD=$tmp/SUPPORT.md BIT_SUPPORT_OUT=$tmp/bad.html \
			BIT_ADVISORIES_JSON=$tmp/adv.json "$0" >/dev/null 2>&1; then
			echo "FAIL: BIT_REPO '$bad' accepted" >&2; fail=1
		fi
	done

	[ "$fail" -eq 0 ] || die "self-check failed"
	echo "support.sh: self-check passed"
}

case ${1:-} in
--self-check) self_check; exit 0 ;;
"") ;;
*) die "usage: support.sh [--self-check]" ;;
esac

[ -f "$src" ] || die "missing $src"
command -v jq >/dev/null || die "jq not found"

rc=0
rows=$(matrix_rows) || rc=$?
case $rc in
0) ;;
3) die "no support matrix table found under '## Support matrix' in $src" ;;
4) die "support matrix in $src has a row whose cell count differs from the header" ;;
5) die "unterminated code fence in $src" ;;
*) die "reading the support matrix from $src failed (awk exit $rc)" ;;
esac

note=""
if json=$(advisories_json) && [ -n "$json" ]; then
	advisories=$(printf '%s' "$json" | advisory_items) || die "advisory render failed"
else
	# Never render "no advisories" when we simply could not ask — that reads as
	# an all-clear the page has not earned.
	advisories='        <li class="empty">Advisory feed unavailable at build time.</li>'
	note="
    <p class=\"warn\">This list could not be refreshed when the page was built.
    Check <a href=\"https://github.com/$REPO/security/advisories\">the advisory
    list on GitHub</a> for the authoritative feed.</p>"
fi

dir=$(dirname -- "$out")
mkdir -p "$dir"
render "$rows" "$advisories" "$note" "$(date -u '+%Y-%m-%d %H:%M UTC')" >"$out"
echo "support.sh: wrote $out"

# The site is one page, so the bare domain has to be that page. nginx serves the
# ConfigMap mount with autoindex off, so with no index.html "/" is a 403 — and
# "/" is the URL anyone actually types. Written from the same run as $out, so the
# two copies cannot drift.
if [ "$(basename -- "$out")" != index.html ]; then
	cp -- "$out" "$dir/index.html"
	echo "support.sh: wrote $dir/index.html"
fi
