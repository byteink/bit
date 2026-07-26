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

# Markdown table rows under the "## Support matrix" heading only. Anchoring to
# the heading (and stopping at the next one) keeps any other table in the doc
# from bleeding into the matrix.
matrix_rows() {
	awk '
		function esc(s) {
			gsub(/&/, "\\&amp;", s); gsub(/</, "\\&lt;", s)
			gsub(/>/, "\\&gt;", s); gsub(/"/, "\\&quot;", s)
			return s
		}
		function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
		/^##[ \t]+Support matrix/ { insec = 1; next }
		insec && /^##[ \t]/ { insec = 0 }
		insec && /^[ \t]*\|/ {
			line = trim($0)
			if (line ~ /^\|[ \t]*:?-{2,}/) next          # separator row
			sub(/^\|/, "", line); sub(/\|$/, "", line)
			n = split(line, cell, /\|/)
			if (n < 5) next                              # not a matrix row
			if (++seen == 1) { kind = "th" } else { kind = "td" }
			printf "        <tr>"
			for (i = 1; i <= 5; i++) printf "<%s>%s</%s>", kind, esc(trim(cell[i])), kind
			printf "</tr>\n"
		}
		END { if (seen < 2) exit 3 }
	' "$src"
}

# Published advisories only. The state filter is applied twice on purpose:
# server-side so a draft is never sent to us, and again in jq so a future API
# change cannot turn an embargoed draft into a published-looking row here.
#
# A 404 is an empty feed, not a failure: the endpoint 404s while the repo has no
# advisories surface, and a *published* advisory is public by definition, so
# there is nothing being hidden from us. Any other failure is a real outage and
# must not be rendered as an all-clear.
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
	elif grep -q 'HTTP 404' "$err"; then
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
|---|---|---|---|---|
| 1.0 | 2026-10-01 | 2027-10-01 | 2031-10-01 | full support |
| 0.9 <script> | 2026-01-01 | 2026-10-01 | 2026-10-01 | EOL |

## After

| bleed | must | not | happen | here |
|---|---|---|---|---|
MD

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
	assert "matrix cell HTML-escaped" -- '<td>0\.9 &lt;script&gt;</td>'
	refute "table from another section bled in" -- '<td>bleed</td>'
	refute "cadence table bled in" -- '<td>matrix</td>'
	refute "separator row emitted" -- '<td>---</td>'

	# Newest advisory must come first.
	if [ "$(grep -n 'GHSA-new' "$tmp/out.html" | cut -d: -f1 | head -1)" -gt \
	     "$(grep -n 'GHSA-old' "$tmp/out.html" | cut -d: -f1 | head -1)" ]; then
		echo "FAIL: advisory feed not newest-first" >&2; fail=1
	fi

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

rows=$(matrix_rows) || die "no support matrix found in $src"

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

mkdir -p "$(dirname -- "$out")"
render "$rows" "$advisories" "$note" "$(date -u '+%Y-%m-%d %H:%M UTC')" >"$out"
echo "support.sh: wrote $out"
