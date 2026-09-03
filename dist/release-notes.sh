#!/usr/bin/env bash
# dist/release-notes.sh — release-notes language guard and pending-notes
# folding, extracted out of dist/release.sh (#4132) as a pure move to bring
# release.sh back under the 800-line ceiling: LANG_NAME_PATTERN,
# checkNotesLanguage() and foldPendingNotes() are unchanged below, only
# relocated. Sourced by dist/release.sh, which still owns the call sites and
# their order (build block before checkNotesLanguage, checkNotesLanguage
# before the draft is created); not a new entry point. Refuses if invoked
# directly rather than silently doing nothing.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
	echo "release-notes.sh: sourced-only, not a standalone script — it only" >&2
	echo "  defines checkNotesLanguage()/foldPendingNotes() for dist/release.sh." >&2
	echo "  Run: dist/release.sh <version> [--dry-run]" >&2
	exit 2
fi

# Refuse a bullet naming another language BEFORE the draft is created (#3973).
# Owner ruling 2026-08-30: "in any release notes we don't want to mention Go
# or any other language for that matter". dist/changelog.sh copies commit
# SUBJECTS into NOTES.md verbatim, and a subject is authored weeks earlier by
# someone not thinking about publication — three 0.4.0 bullets named Go and
# were caught by eye and hand-fixed on the PUBLISHED release. "Write it
# carefully" cannot fix text that comes from a different corpus than the one
# anyone reviews; only a mechanical check at cut time can.
#
# Case-sensitive, one word each: proper-noun capitalization is what makes this
# precise instead of noisy — a bare case-insensitive `go` matches ordinary
# English ("does not go", "let it go") constantly, and this repo's own
# CLAUDE.md draft pattern (`[^a-z]c[^a-z+]` for a bare "C") matches almost
# every short word in the corpus. Verified empirically, not assumed: across
# 3140 non-merge commit subjects and 1315 lines of NOTES.md generated for
# v0.1.25 through the range since v0.5.0 (10 ranges), this pattern hit 7
# times and every hit named the language — 0 observed false positives.
# Golang/Rust/Java/JavaScript/Swift/C++ never occurred at all in that corpus.
#
# `\.(go|c)\b` ADDED (#4125): missed a lowercase language name inside a
# filename — "as matrix.go and matrix.c do" (1921a807) shipped in 0.6.0
# uncaught. `bench/cases/**` carries 12 `.go` and 11 `.c` files that exist
# SPECIFICALLY to be compared against in prose like that, so a `.go`/`.c`
# mention here is always genuine. Re-verified 2026-09-01 against 12 tag
# ranges (v0.1.24..v0.6.0 + open v0.6.0..HEAD: 875 subject + 1286 NOTES.md
# lines) AND full history (3154 subjects): 2 hits, same bullet, 0 false
# positives. `.py`/`.rs`/`.ts`/`.java`/`.cpp` deliberately NOT added: this
# repo's own tooling has `.py`/`.ts` files (dist/sbom.py, gen.py,
# editors/vscode/src/extension.ts), and one IS a real false positive in
# history — "wire dist/sbom.py into dist/release.sh" names Bit's own tooling,
# not a Python comparison. `.rs`/`.java`/`.cpp` have zero tracked files and
# zero corpus hits — unmeasured; add one only with its own corpus re-run.
LANG_NAME_PATTERN='\b(Go|Golang|Rust|Zig|Python|Java|TypeScript|JavaScript|Swift)\b|C\+\+|\.(go|c)\b'

checkNotesLanguage() { # <notes-file>
	local notesFile="$1" hits bad=0 lineno text sha
	[ -f "${notesFile}" ] || {
		echo "release.sh: ${notesFile} does not exist — cannot check it for language mentions" >&2
		return 1
	}
	hits="$(grep -nE "${LANG_NAME_PATTERN}" "${notesFile}" || true)"
	[ -z "${hits}" ] && return 0

	# One bullet per line ("- <subject> (<sha>)", dist/changelog.sh), so the
	# trailing "(<sha>)" is the commit to name alongside the line — the way
	# abiarity.bit's refusal names the symbol and both arities, not just "a
	# mismatch exists somewhere".
	while IFS= read -r line; do
		[ -n "${line}" ] || continue
		lineno="${line%%:*}"
		text="${line#*:}"
		sha="$(printf '%s' "${text}" | grep -oE '\([0-9a-f]{7,40}\)[[:space:]]*$' | tr -d '()' || true)"
		if [ -n "${sha}" ] && [ -n "${RELEASE_NOTES_LANG_ALLOW:-}" ]; then
			case " ${RELEASE_NOTES_LANG_ALLOW} " in
			*" ${sha} "*) continue ;;
			esac
		fi
		bad=1
		echo "release.sh: ${notesFile}:${lineno}: names another language: ${text}" >&2
		[ -n "${sha}" ] && echo "release.sh:   commit ${sha}" >&2
	done <<<"${hits}"
	[ "${bad}" -eq 0 ] && return 0

	echo "release.sh: refusing — release notes must not name another language (owner ruling 2026-08-30)" >&2
	echo "release.sh: reword the commit subject upstream (preferred), or edit ${notesFile} by hand and" >&2
	echo "release.sh:   re-run WITHOUT rebuilding: dist/release.sh ${VERSION} --resume-notes" >&2
	echo "release.sh: or approve a specific bullet (same flag avoids a rebuild here too):" >&2
	echo "release.sh:   RELEASE_NOTES_LANG_ALLOW=\"<sha> ...\" dist/release.sh ${VERSION} --resume-notes" >&2
	return 1
}

# Folds any entries from docs/release/PENDING-NOTES.md into the just-generated
# NOTES.md (#3213, #3392). Entries live PAST the file's `---` separator —
# everything above it is static usage documentation, never release content.
# Appended right after the version heading, not at the end: a security
# disclosure belongs at the top of the notes, not after "Artifacts".
#
# NEVER CLEARS PENDING-NOTES.md ITSELF, on --dry-run or a real run: this
# script only ever creates a DRAFT (see the header comment above), and a
# draft can be abandoned or re-cut. Clearing here would let an abandoned
# draft silently eat the disclosure, with nothing left to fold into the
# release that actually ships it. So this prints an instruction instead —
# the entry is removed by hand, in the commit that records the release notes
# were actually published (see PENDING-NOTES.md's own "How to use this
# file" section).
foldPendingNotes() { # <pending-notes-file> <notes-md-file>
	local pendingFile="$1" notesFile="$2"
	[ -f "${pendingFile}" ] || return 0

	local raw
	raw="$(awk '/^---$/{found=1;next} found{print}' "${pendingFile}")"
	printf '%s\n' "${raw}" | grep -q '[^[:space:]]' || return 0

	# The release skill's own accounting check (grep -cE '^[-*] '
	# dist/out/NOTES.md vs the non-merge commit count, bit-release
	# SKILL.md step 1) would silently miscount a hand-written top-level
	# bullet as a displaced commit bullet — refuse rather than let a
	# pending entry corrupt that assertion into noise.
	local bad
	bad="$(printf '%s\n' "${raw}" | grep -E '^[-*] ' || true)"
	if [ -n "${bad}" ]; then
		echo "release.sh: ${pendingFile} has an entry starting with '- ' or '* ', which the" >&2
		echo "  release skill's bullet-count check would misread as a commit bullet:" >&2
		printf '%s\n' "${bad}" | sed 's/^/  /' >&2
		exit 1
	fi

	# Demote each entry's heading one level (## -> ###) so it nests under
	# the version title the same way "Breaking changes" / "Features" do,
	# instead of competing with it at the same level.
	local demoted title rest count
	demoted="$(printf '%s\n' "${raw}" | sed -E 's/^## /### /')"
	title="$(head -n1 "${notesFile}")"
	rest="$(tail -n +2 "${notesFile}")"
	{
		printf '%s\n\n' "${title}"
		printf '%s\n' "${demoted}"
		printf '\n%s\n' "${rest}"
	} > "${notesFile}"

	count="$(printf '%s\n' "${raw}" | grep -c '^## ' || true)"
	echo "release.sh: folded ${count} pending entry(ies) from ${pendingFile} into ${notesFile}" >&2
	echo "release.sh: ================================================================" >&2
	echo "release.sh: ACTION REQUIRED once this release is PUBLISHED (not on a draft" >&2
	echo "release.sh:   that gets abandoned or re-cut): remove the folded entry(ies) from" >&2
	echo "release.sh:   ${pendingFile} (everything after its '---') and commit that" >&2
	echo "release.sh:   removal. See that file's own \"How to use this file\" section." >&2
	echo "release.sh: ================================================================" >&2
}
