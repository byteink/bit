#!/usr/bin/env bash
# dist/release-notes.sh - pending-notes folding for dist/release.sh, split out
# of it (#4132) so release.sh stays under the 800-line ceiling. It defines
# foldPendingNotes() and nothing else; dist/release.sh owns the call site and
# its position (after NOTES.md is generated, before the draft is created), so
# this is not a second entry point. Refuses if invoked directly rather than
# silently doing nothing.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
	echo "release-notes.sh: sourced-only, not a standalone script - it only" >&2
	echo "  defines foldPendingNotes() for dist/release.sh." >&2
	echo "  Run: dist/release.sh <version> [--dry-run]" >&2
	exit 2
fi

# Folds any entries from docs/release/PENDING-NOTES.md into the just-generated
# NOTES.md (#3213, #3392). Entries live PAST the file's `---` separator -
# everything above it is static usage documentation, never release content.
# Appended right after the version heading, not at the end: a security
# disclosure belongs at the top of the notes, not after "Artifacts".
#
# NEVER CLEARS PENDING-NOTES.md ITSELF, on --dry-run or a real run: this
# script only ever creates a DRAFT (see the header comment above), and a
# draft can be abandoned or re-cut. Clearing here would let an abandoned
# draft silently eat the disclosure, with nothing left to fold into the
# release that actually ships it. So this prints an instruction instead -
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
	# bullet as a displaced commit bullet - refuse rather than let a
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
