#!/usr/bin/env bash
# Declared-transform-signature scoring for the IR differentials (#3125).
#
# Extracted from scripts/selfhost-diffdump.sh's ir/iropt rows into its own
# sourced file by #3132, so scripts/selfhost-diffruntime.sh's SEPARATE
# per-file IR walk (its own `--dump-ir-pre` shell-out, never routed through
# selfhost-diffdump.sh) can reuse the identical scoring logic instead of
# re-implementing it — the exact "a fix reaches some callers and misses
# others" shape #2743/#2866 already cost this repo once (six pasted
# selfhost-diff*.sh scripts, a safety fix that reached three and missed
# three). Both callers source THIS file with `. scripts/selfhost-ir-signatures.sh`;
# neither defines its own copy of explainMismatch.
#
# --- Declared-transform-signature escape valve (#3125, same shape as #3103) ---
#
# selfhost-diffdump.sh's ir/iropt rows, and selfhost-diffruntime.sh's
# per-file `runtime/**` walk, each compare a file's lowered IR TEXT against
# the pinned stage0's, byte for byte (mod $t<id> canon on the diffdump side),
# with NO divergence permitted at all. That held only as long as no
# intentional lowering improvement had landed since the pin — #3107 was the
# first that did, and it reddened every IR arm by construction: a mismatch is
# no longer automatically a REGRESSION. It is checked first against a small
# table of DECLARED TRANSFORM SIGNATURES (`explainMismatch` below) — a strict
# structural identity, proven against the pinned oracle and tested with
# positive and negative controls. Only a divergence that satisfies a signature
# is downgraded to EXPLAINED (printed, not failed); anything else still fails
# exactly as before.
#
# WHY NOT A PER-FILE ALLOWLIST INSTEAD. There was one — the expected-mismatch
# list #1883 deleted, "so a known difference could be written down instead of
# fixed." A signature is not that list reborn: an allowlist names a FILE and
# accepts anything it does next; a signature names an IDENTITY the delta must
# satisfy, checked fresh on every run, and a second, unrelated bug landing on
# an already-explained file still fails it.
#
# WHY NOT TREE-AGAINST-TREE (the other option this ticket weighed). #3103
# rejected two self-build generations of the SAME tree because `bit build
# compiler` links a pre-built libbitrt.a, so that comparison never touched
# runtime codegen at all — vacuous by construction. That specific mechanism
# does not apply here: `--dump-ir-pre`/`--dump-ir` lower one file standalone,
# no link step. The DEEPER reason still does, though: two generations of ONE
# tree share whatever lowering bug that tree has, so a bug baked into both
# generations identically never diverges — the same self-reproducing-bug
# blind spot, independent of why #3103 hit it. A signature checked against an
# INDEPENDENT, unchanged oracle (the pinned release) does not have that blind
# spot: a real bug fails the identity and is reported as a regression exactly
# like any other divergence.
#
# WHICH HOSTS. Every declared signature applies on EVERY host (aarch64-macos,
# aarch64-linux, x86_64-linux) — unlike #3103's diffruntime object-byte arm,
# which is aarch64-only because it disassembles target MACHINE CODE.
# `--dump-ir-pre`/`--dump-ir` are pre-codegen: the SSA text carries no
# register or instruction-selection content, so it does not vary by target
# ISA at all.
#
# COST PER LANDING, as this ticket names up front: a future lowering change
# that alters IR shape needs its OWN signature added to `explainMismatch`
# below: compare the real branch with the pinned oracle, prove the transform's
# structural preconditions, and reject unrelated differences with controls.
# Every eligible and unexplained corpus path must remain visible. A signature
# cannot accept a file merely because its name or opcode counts match; #1883
# is why that is rejected.
#
# Retirement history is preserved in docs/development/dump-differential.md.
#
# No signature remains after the 0.43.0 stage0 repin (#8267).
# The retired #8259 identity and its derivation remain in Git history.

# explainMismatch <oracle_text> <bit2_text> <kind> [file]
# Unknown differences stay unexplained, including every former identity.
explainMismatch() {
  return 1
}

# declaredSignatureNames [kind] -- the retirement audit still consults this table.
declaredSignatureNames() {
  return 0
}

# shellcheck source=scripts/selfhost-ir-canon.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/selfhost-ir-canon.sh"
