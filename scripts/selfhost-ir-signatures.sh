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
# table of DECLARED TRANSFORM SIGNATURES (`explainMismatch` below) — an exact
# opcode-COUNT-delta identity, proven against the real branch that motivated
# it, not eyeballed. Only a divergence that satisfies a registered signature
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
# below, derived the same way — diff the real branch against the pinned
# oracle, aggregate every nonzero opcode delta across every diverging file,
# and solve for the coefficients. A signature that only explains the one file
# its author happened to look at is not a signature; it is a scoped allowlist
# wearing a disguise, and #1883 is why that is rejected.
#
# --- Retirement history ---
#
# A declared signature goes dead without anyone removing it: the oracle is
# the pinned stage0, release N-1 (docs/release/bootstrap.md), and it moves
# every release, so a transform that landed before release N is back IN the
# oracle by N+1 — the two compilers agree again on every site the signature
# used to explain. The retirement check in scripts/selfhost-diffdump.sh's
# run_ir() (`declaredSignatureNames` below) is what catches the next one
# instead of leaving it to a manual audit.
#
# #3107 (inline slice element READ), #3108 (…STORE), #3898 (pointer-scale/
# shift fold) and #3862 (inline slice elements, packed class) were retired by
# #5509 on the 0.20.0-era tree. #5486-variant-payload-reorder,
# #5429-decimal-boxed-slot-explode, #5506-enum-nil-payload-retype,
# #5445-method-return-explode-direct-call, #5521-void-return-bare-ret and
# #5486-variant-payload-redundant-read-elim were retired by the stage0
# 0.20.0 repin (#5607).
#
# #5870-multiword-return-rebox, #5871-tuple-word-explode (both `ir` and its
# `iropt` branch-fold variant), #5874-fallible-tuple-words,
# #5876-field-store-declared-type-convert, #5895-bce-trivial-param,
# #5905-commaok-miss-zero-drop, #5906-map-str-key-words and
# #5910-chan-typeassert-live-zero were retired by the stage0 0.27.0 repin
# (#5914): every fix each one explained landed on the tree before 0.27.0 was
# cut, so 0.27.0 is the first oracle that agrees with the tree on every site
# they used to explain. Confirmed by `bash scripts/selfhost-diffir.sh` and
# `bash scripts/selfhost-diffiropt.sh` against the 0.27.0 pin (this tree at
# d1c6a09f4, aarch64-macos, the only host this repin was built on):
# MATCH=961 MISMATCH=0 EXPLAINED=0 on both arms, and both scripts' own
# RETIRED lines named exactly these eight — six under `ir`, nine under
# `iropt` (the `iropt`-only branch-fold variant makes it nine, not eight).
# Not independently confirmed on x86_64-linux or aarch64-linux the way
# #5509's four were; the two prior repins to 0.26.0 and 0.26.1 (dist/stage0/
# SHA256SUMS) folded runtime/compiler fixes affecting all three targets
# identically and neither needed a per-arch re-check, and none of these
# eight identities keys on anything target-ISA-shaped (see WHICH HOSTS
# above — `--dump-ir`/`--dump-ir-pre` do not vary by ISA at all). Their
# per-opcode derivations are preserved in git history at this file's state
# before #5914 — a dead identity's math is not load-bearing for anything
# still declared.
#
# #5921-ptrof-string-type was retired by the stage0 0.28.0 repin (#5957):
# 0.28.0 contains #5921 (`ptrOf(s: string): *u8`), so 0.28.0 is the first
# oracle that agrees with the tree on the `--dump-types` sites it used to
# explain. Confirmed by `bash scripts/selfhost-difftypes.sh` against the
# 0.28.0 pin (this tree at 35599936e, aarch64-macos, the only host this
# repin was built on): MATCH=1412 MISMATCH=0 EXPLAINED=0, and the script's
# own RETIRED line named exactly this one signature. `selfhost-diffir.sh`
# and `selfhost-diffiropt.sh` both report MATCH=963 MISMATCH=0 EXPLAINED=0
# against the same pin — no `ir`/`iropt` signature was declared going in, so
# neither RETIRED anything. Its opcode-free line-diff derivation (the
# ptrofStringType/lastColonSpace functions) is preserved in git history at
# this file's state before #5957.
#
# The `catch`-composite-default `ast`/`fmt` disambiguation pair (#5474,
# #5510) and the generic-class-member leading-comment `fmt` signature were
# both retired by the stage0 0.32.0 repin: 0.32.0's own oracle already
# parses and formats both shapes the way the tree does, so neither explains
# anything anymore. Confirmed by `bash scripts/selfhost-diffast.sh` (MATCH=
# 1410 MISMATCH=0 EXPLAINED=0) and `bash scripts/selfhost-difffmt.sh`
# (MATCH=2036 MISMATCH=0 EXPLAINED=0) against the 0.32.0 pin (this tree,
# aarch64-macos, the only host this repin was built on) -- no divergence
# remains for either kind, so there is nothing left for any signature to
# explain. `ast`/`fmt` had no automated RETIRED audit (unlike `ir`/`iropt`/
# `types`, checked by scripts/selfhost-diffdump.sh's run_ir()/run_types()),
# so this pair was confirmed dead by hand rather than by that mechanism
# failing. Their `catchDisambigAst`/`catchDisambigFmt`/`fmtCodeOnly`/
# `genericMemberCommentFmt` derivations and ticket numbers are preserved in
# git history and in scripts/selfhost-ir-signatures-selfcheck.sh's
# retirement note, at this file's state before that repin.
#
# #6194-generic-method-receiver-unsubstituted-type/-explode,
# #6161-json-decode-column-shift/-json-schema-synthesized-insert/-json-decode-
# enum-error-resolved/-json-schema-specialize-call and
# #6201-json-schema-generic-wrapper-specialize were retired by the stage0
# 0.33.0 repin (#6245): 0.33.0 contains #6161, #6194 and #6201, so it is the
# first oracle that agrees with the tree on every corpus file those seven
# signatures used to explain. Their `optionUnsubstitutedType`,
# `columnShiftType`, `orderedSubsequenceInsert`, `errorResolvedPair`/
# `errorResolvedInsert`, `isSchemaCallRename`/`schemaForwardWalk`/
# `schemaInsertBlockOk`/`jsonSchemaSpecializeCall` and
# `schemaGenericWrapperInsertOk`/`jsonSchemaGenericWrapperCall` derivations
# are preserved in git history at this file's state before this repin.
#
# #6244-json-attr-implicit-insert (`types`) — `@json class` no longer needs
# any import from "std/json" to synthesize (compiler/project.bit's
# injectImplicitJsonImport, BIT_IMPLICIT_SYNTH_IMPORTS default ON): a module
# whose ONLY std/json need is `@json` now type-checks toJson's/
# __jsonAppend's synthesized body, which the pinned 0.33.0 oracle (no such
# feature) cannot — it declines to synthesize at all and simply omits those
# lines. Two shapes, both in ONE file: (1) a pure INSERTION of the
# synthesized member's own type-checked lines (everything else in the file
# typed identically, in the same order — the `6161-json-schema-synthesized-
# insert` shape retired by the 0.33.0 repin), and (2) any expression
# elsewhere in the SAME module whose type depended on the class now
# resolving flips from a container of `<error>` on the oracle side (it could
# not resolve `JsonEntry` either, having declined the whole class) to a real
# type on the tree side (the `6161-json-decode-enum-error-resolved` shape,
# same repin) — `jsonAttrTypeResolved` below generalizes that pair's exact-
# `<error>` match to a CONTAINING one (`[]<error>`, `[]<error>!`, ...) since
# nothing in `--dump-types` output marks a container boundary for this
# check to anchor on instead. `jsonAttrImplicitInsert` combines both as one
# two-pointer walk (mirrors `errorResolvedInsert`'s shape): a byte-identical
# line or a `jsonAttrTypeResolved` pair advances both sides, anything else
# on the tree side alone is a pure insertion (advances only the tree), and
# it explains only when every oracle line is eventually consumed this way —
# a real regression (a well-typed oracle line changing to a DIFFERENT
# concrete type, or an unrelated `<error>` that widens) can never satisfy
# either branch and fails the walk closed, the oracle pointer never
# catching up. Derived from and checked against the real `--dump-types`
# dumps of stdlib/sql/rowtypes.test.bit (captured 2026-09-29, ticket #6244):
# 365 oracle lines vs 379 tree lines, 13 lines inserted before line 17
# (`RowtypesSettings`'/`theme`'s/`retries`' synthesized-member type checks),
# one `jsonAttrTypeResolved` pair at oracle line 199-200 (`entries`/
# `jsonObjectEntries(j)`: `[]<error>`/`[]<error>!` -> `[]JsonEntry`/
# `[]JsonEntry!`), one line inserted at the end (`__json_entries`) — full
# `diff` gives exactly these 18 changed lines, nothing else in the file
# differs. EXPECTED TO RETIRE AT THE 0.34.0 REPIN: 0.34.0 will contain
# #6244, so it will be the first oracle that agrees with the tree on this
# file (and any other `@json`-with-no-import file landing before then).
#
# explainMismatch <oracle_text> <bit2_text> <kind: ir|iropt|ast|fmt|types>
# Prints the name of the registered signature that explains the divergence
# and returns 0, or prints nothing and returns 1 if none does. Each call
# forks one fresh awk process, so all state below is per-call — no cross-file
# leakage between corpus files. `ast`/`fmt` compare TEXT (an S-expression
# dump / formatted source), not IR opcodes; `types` compares `--dump-types`
# TEXT line-for-line (jsonAttrImplicitInsert, #6244); `ir`/`iropt` compare
# opcode COUNT deltas. No signature is currently declared for `ir`/`iropt`/
# `ast`/`fmt` (see Retirement history above).
explainMismatch() {
  awk -v kind="$3" '
    function opcode(line,    s) {
      if (match(line, /= rt_call [A-Za-z_][A-Za-z0-9_]*\(/)) {
        s = substr(line, RSTART, RLENGTH)
        sub(/^= rt_call /, "", s)
        sub(/\($/, "", s)
        return "rt_call:" s
      }
      if (match(line, /= [a-zA-Z_][a-zA-Z0-9_]*/)) {
        return substr(line, RSTART + 2, RLENGTH - 2)
      }
      if (line ~ /^[[:space:]]*br /) { return "br" }
      if (line ~ /^[[:space:]]*unreachable/) { return "unreachable" }
      if (line ~ /^[[:space:]]*index_set /) { return "index_set" }
      return ""
    }
    function lastColonSpace(s,    i, n, found) {
      found = 0
      n = length(s) - 1
      for (i = 1; i <= n; i++) {
        if (substr(s, i, 2) == ": ") { found = i }
      }
      return found
    }
    # jsonAttrTypeResolved (#6244) -- `a` (oracle)/`b` (tree) share the same
    # `LINE:COL: <expr>` prefix (everything before the LAST ": "), the
    # oracle side CONTAINS the literal substring "<error>" somewhere in its
    # type (bare or inside a container: `<error>`, `[]<error>`,
    # `[]<error>!`, ...) and the tree side is non-empty and contains no
    # "<error>" at all.
    function jsonAttrTypeResolved(a, b,    cutA, cutB, pfxA, pfxB, tyA, tyB) {
      cutA = lastColonSpace(a); cutB = lastColonSpace(b)
      if (cutA == 0 || cutB == 0) { return 0 }
      pfxA = substr(a, 1, cutA - 1); tyA = substr(a, cutA + 2)
      pfxB = substr(b, 1, cutB - 1); tyB = substr(b, cutB + 2)
      if (pfxA != pfxB) { return 0 }
      if (index(tyA, "<error>") == 0) { return 0 }
      if (tyB == "" || index(tyB, "<error>") > 0) { return 0 }
      return 1
    }
    # jsonAttrImplicitInsert (#6244) -- see the header above this function
    # for the derivation. A two-pointer walk: a byte-identical line advances
    # both sides, and so does a jsonAttrTypeResolved pair; any other tree
    # line is a pure insertion (advances only the tree side). Explains only
    # when every oracle line is eventually consumed this way -- a dropped,
    # reordered or wrongly-changed oracle line leaves the oracle pointer
    # short at the end and fails closed.
    function jsonAttrImplicitInsert(nA, linesA, nB, linesB,    i, j) {
      i = 1; j = 1
      while (i <= nA && j <= nB) {
        if (linesA[i] == linesB[j]) { i++; j++; continue }
        if (jsonAttrTypeResolved(linesA[i], linesB[j])) { i++; j++; continue }
        j++
      }
      return (i > nA) ? 1 : 0
    }
    side == 0 && $0 == "@@@BIT2@@@" { side = 1; next }
    side == 0 {
      nA++; linesA[nA] = $0
      rawA = (nA == 1 ? $0 : rawA "\n" $0)
      op = opcode($0); if (op != "") a[op]++
      next
    }
    {
      nB++; linesB[nB] = $0
      rawB = (nB == 1 ? $0 : rawB "\n" $0)
      op = opcode($0); if (op != "") b[op]++
    }
    END {
      if (kind == "types") {
        if (jsonAttrImplicitInsert(nA, linesA, nB, linesB)) {
          print "6244-json-attr-implicit-insert"; exit 0
        }
        exit 1
      }
      # No signature is currently declared for `ir`/`iropt`/`ast`/`fmt` (see
      # Retirement history above): every divergence under those kinds is
      # unexplained.
      exit 1
    }
  ' <(printf '%s\n@@@BIT2@@@\n%s\n' "$1" "$2")
}

# declaredSignatureNames [ir|iropt|ast|fmt|types] -- every name explainMismatch
# CAN print for the given dump kind, one per line, in the same order as the
# `print "…"` statements above (#5509, extended by #5510). The single source
# of truth for the retirement check in scripts/selfhost-diffdump.sh's
# run_ir()/run_types(): a signature this function does not list for a kind can
# never be checked for going dead under that kind, and one it lists that
# explainMismatch no longer prints would make that check fail on every run
# for a signature that does not exist. Kept in sync by hand -- there is no
# safe way to grep `print "…"` lines back out of the awk script above and
# have that be more trustworthy than typing the same names twice, and
# selfhost-ir-signatures-selfcheck.sh asserts the two lists match (with the
# kind argument omitted there, since that check is "does this name exist at
# all", not "under which kind").
declaredSignatureNames() {
  local kind=${1:-}
  case "$kind" in
    ast) return ;;
    fmt) return ;;
    ir) return ;;
    iropt) return ;;
    types) printf '%s\n' "6244-json-attr-implicit-insert"; return ;;
  esac
  [ -n "$kind" ] || printf '%s\n' "6244-json-attr-implicit-insert"
}
