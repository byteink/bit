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
# #6254 (`types`, NO SEPARATE SIGNATURE — covered by jsonAttrImplicitInsert
# above). Every `@json` class now also gains a synthesized `static
# __collectionName(): string` (compiler/classcollectiondesc.bit),
# unconditionally, the same "one more synthesized member on every `@json`
# class" shape #6244's own toJson-adjacent synthesis is. Unlike #6244, #6254
# introduces no NEW name resolution (nothing that was `<error>` before
# resolves now), so its divergence against the 0.33.0 oracle on any EXISTING
# `@json` corpus file is a PURE insertion — a strict subset of what
# `jsonAttrImplicitInsert` already accepts for `kind == "types"` — and
# `explainMismatch` tries that signature first, so it prints
# `6244-json-attr-implicit-insert` for a #6254-caused divergence too. A
# dedicated `6254-*` entry duplicating the identical predicate would never
# fire (6244 always wins first) and could never be exercised by its own
# selfcheck, so none is declared; this note is the record instead. A NEW
# `_tests_/cases`/checkercases fixture using `@collection` itself (unknown
# syntax to 0.33.0) declines outright on the oracle side (a checker error,
# non-zero exit) and is counted as a legitimate SKIP by every kind's own
# decline path (scripts/selfhost-diffdump.sh's classify_rc) — never a
# MISMATCH, so it needs no signature either. Both retire together at the
# 0.34.0 repin, same as #6244.
#
# #6255-table-row-synth-reposition (`types`) and #6254-collection-attr-presyntax
# (`diags`, also consulted by selfhost-fuzzdiff.sh) -- declared 2026-09-29
# for epic #6253 (orm/kv redesign). 6255: @table classes gain synthesized
# statics that share find<T>'s synthesized text, so the oracle's mapper lines
# move to another column of the same synthesized line (seen on
# _tests_/cases/run_sql_row_persisted.bit). 6254: the 0.33.0 oracle predates
# the `@collection` class attribute and reports E0136 on any file using it
# (_tests_/cases/run_collection_name_static_dispatch.bit and its fuzz
# truncations). #6264-from-contextual-token/-diags/-types: `from` became a
# contextual keyword, so the tree lexes it as an ident where the oracle lexes
# kw_from (every file with an import, tokens), names the token differently in
# a diagnostic, and accepts `from` as a name the oracle rejects
# (_tests_/cases/run_from_identifier.bit). #6269-default-id-attr (`ir`/`iropt`):
# a field named id is the key by default, recorded as an implicit id
# attribute (_tests_/cases/run_table_name_override.bit). #6265-closure-bound-
# static-self/-insert: the oracle types a static reached through a bound
# inside a closure as Self and drops its instantiations
# (_tests_/cases/run_generic_closure_over_bound_self_static.bit). All retire at the
# 0.34.0 repin; `diags` has no automated
# RETIRED audit (like ast/fmt), so 6254 is confirmed dead by hand there.
#
# #6284 (`types`, NO SEPARATE SIGNATURE — same non-fire reason #6254's note
# above gives). `@table class` now needs no import from "std/sql" at all
# (compiler/project.bit's `injectImplicitTableImport`, mirroring #6244's
# `injectImplicitJsonImport`): a zero-import module's `tableDescriptor`/
# `tableAttrs`/`__tableName`/`__columns`/`__values`/`__fromRow` type-check
# where 0.33.0 (predates both #6244's implicit-import mechanism and #6255's
# synthesis) declines. Every line this produces is either a pure insertion
# or a `jsonAttrTypeResolved` pair, a strict subset of what
# `tableRowSynthInsert` (#6255, tried before this could ever be reached)
# already walks — a dedicated `6284-*` entry would never fire and could
# never be exercised by its own selfcheck, so none is declared; this note
# is the record (_tests_/cases/table_attr_zero_import.bit). Not run against
# the pinned oracle from this worktree; the integrator's differential pass
# confirms which of `6244-json-attr-implicit-insert`/
# `6255-table-row-synth-reposition` explains it. Retires at the 0.34.0 repin
# with the other two.
#
# #6045-closure-tuple-oracle-declines (`ir`/`iropt`, ONE file): the 0.33.0
# oracle has #6045's bug (a closure returning two values into a generic call
# fails to lower, E0092) and its --dump-ir swallows that error: for
# _tests_/cases/run_closure_multival_return_generic_call.bit, the fixture
# proving the fix, it drops the functions it could not lower and emits the
# broken closure with a valueless return. Explained only for that file, only
# when every oracle function header is kept and the tree has more functions.
# Retires at the 0.34.0 repin.
#
# explainMismatch <oracle_text> <bit2_text> <kind: ir|iropt|ast|fmt|types|diags>
# Prints the name of the registered signature that explains the divergence
# and returns 0, or prints nothing and returns 1 if none does. Each call
# forks one fresh awk process, so all state below is per-call — no cross-file
# leakage between corpus files. `ast`/`fmt` compare TEXT (an S-expression
# dump / formatted source), not IR opcodes; `types` compares `--dump-types`
# TEXT line-for-line (jsonAttrImplicitInsert, #6244); `ir`/`iropt` compare
# opcode COUNT deltas (6269-default-id-attr is the one `ir`/`iropt` signature;
# none is declared for `ast`/`fmt`, see Retirement history above).
explainMismatch() {
  awk -v kind="$3" -v file="${4:-}" '
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
    # synthReposition (#6255) -- the 0.33.0 oracle types the find<T>
    # synthesized row mapper at one column of the synthesized text; #6255
    # re-plans that text (the @table statics share it), so the SAME
    # `name: type` lands at another column of the SAME synthesized line,
    # sometimes twice. `a`/`b` match when they share the line number and
    # everything after the column, and differ only in the column.
    function synthReposition(a, b,    ra, rb, la, lb) {
      if (a !~ /^[0-9]+:[0-9]+: / || b !~ /^[0-9]+:[0-9]+: /) { return 0 }
      la = a; sub(/:.*/, "", la)
      lb = b; sub(/:.*/, "", lb)
      if (la != lb) { return 0 }
      ra = a; sub(/^[0-9]+:[0-9]+: /, "", ra)
      rb = b; sub(/^[0-9]+:[0-9]+: /, "", rb)
      return (ra == rb) ? 1 : 0
    }
    # tableRowSynthInsert (#6255) -- the jsonAttrImplicitInsert walk plus
    # synthReposition pairs. Fails closed the same way: every oracle line
    # must be consumed by an identical line, a type-resolved pair or a
    # repositioned synthesized line; tree-only lines are insertions.
    function tableRowSynthInsert(nA, linesA, nB, linesB,    i, j) {
      # An empty oracle dump arrives as one empty line: a module holding only
      # a @table class types nothing under 0.33.0, so every tree line is an
      # insertion (#6301, _tests_/cases/table_registry_lib/account.bit).
      # Only when the tree shows the synthesized row mapper (__row:), so an
      # oracle that typed nothing for any other reason still fails closed.
      if (nA == 1 && linesA[1] == "") {
        for (j = 1; j <= nB; j++) { if (linesB[j] ~ /: __row: /) { return 1 } }
        return 0
      }
      i = 1; j = 1
      while (i <= nA && j <= nB) {
        if (linesA[i] == linesB[j]) { i++; j++; continue }
        if (jsonAttrTypeResolved(linesA[i], linesB[j])) { i++; j++; continue }
        if (synthReposition(linesA[i], linesB[j])) { i++; j++; continue }
        j++
      }
      return (i > nA) ? 1 : 0
    }
    # collectionAttrPresyntax (#6254) -- `--dump-diags` of a file using the
    # new `@collection` class attribute: the 0.33.0 oracle predates it and
    # reports E0136 (@collection is not an attribute a class accepts)
    # where the tree reports nothing. Every tree line must appear in the
    # oracle in order; the only oracle-only lines allowed are whole E0136
    # blocks naming @collection (the header plus its indented context
    # lines). Any other oracle-only line fails closed.
    function collectionAttrPresyntax(nA, linesA, nB, linesB,    i, j, skipped) {
      i = 1; j = 1; skipped = 0
      while (i <= nA) {
        if (j <= nB && linesA[i] == linesB[j]) { i++; j++; continue }
        if (linesA[i] ~ /^error\[E0136\]: .@collection. is not an attribute a class accepts/) {
          skipped = 1; i++
          while (i <= nA && (linesA[i] == "" || (linesA[i] ~ /^[ 0-9]/ && linesA[i] !~ /^[0-9]+:[0-9]+: /))) { i++ }
          continue
        }
        return 0
      }
      # An empty tree dump arrives as one empty line.
      while (j <= nB && linesB[j] == "") { j++ }
      return (j > nB && skipped) ? 1 : 0
    }
    # fromContextualToken (#6264) -- `from` is contextual now, so the tree
    # lexes it as an ident where the 0.33.0 oracle lexed kw_from, at the SAME
    # span. Every line equal except such pairs; same line count.
    function fromContextualToken(nA, linesA, nB, linesB,    i, a, b, hit) {
      if (nA != nB) { return 0 }
      hit = 0
      for (i = 1; i <= nA; i++) {
        if (linesA[i] == linesB[i]) { continue }
        a = linesA[i]; b = linesB[i]
        if (a !~ /^kw_from / || b !~ /^ident /) { return 0 }
        sub(/^kw_from /, "", a); sub(/^ident /, "", b)
        if (a != b) { return 0 }
        hit = 1
      }
      return hit
    }
    # fromDiagEqual (#6264) -- the same diagnostic, naming the token the way
    # each compiler lexes it: "found kw_from" (oracle) / "found an
    # identifier" (tree).
    function fromDiagEqual(a, b,    t) {
      t = a
      if (sub(/found kw_from/, "found an identifier", t) == 0) { return 0 }
      return (t == b) ? 1 : 0
    }
    # fromContextualDiags (#6264) -- tree lines appear in the oracle in
    # order (equal, or a fromDiagEqual pair); the only oracle-only lines
    # allowed are whole E0021 blocks the oracle raises because it still
    # reserves `from` (a header naming from as a reserved keyword or a
    # found kw_from token, plus its indented context lines).
    function fromContextualDiags(nA, linesA, nB, linesB,    i, j, hit) {
      i = 1; j = 1; hit = 0
      while (i <= nA) {
        if (j <= nB && linesA[i] == linesB[j]) { i++; j++; continue }
        if (j <= nB && fromDiagEqual(linesA[i], linesB[j])) { i++; j++; hit = 1; continue }
        if (linesA[i] ~ /^error\[E0021\]: .from. is a reserved keyword/ || linesA[i] ~ /^error\[E0021\]: .*found kw_from/) {
          hit = 1; i++
          while (i <= nA && (linesA[i] == "" || (linesA[i] ~ /^[ 0-9]/ && linesA[i] !~ /^[0-9]+:[0-9]+: /))) { i++ }
          continue
        }
        return 0
      }
      while (j <= nB && linesB[j] == "") { j++ }
      return (j > nB && hit) ? 1 : 0
    }
    # fromContextualTypes (#6264) -- where the oracle could not parse a
    # `from` binding it records a nameless entry (`1:1: : T`); the tree
    # records the binding (`L:C: from: T`) with the same type T. Same line
    # count; every other line equal.
    function fromContextualTypes(nA, linesA, nB, linesB,    i, a, b, hit) {
      if (nA != nB) { return 0 }
      hit = 0
      for (i = 1; i <= nA; i++) {
        if (linesA[i] == linesB[i]) { continue }
        a = linesA[i]; b = linesB[i]
        if (a !~ /^[0-9]+:[0-9]+: : / || b !~ /^[0-9]+:[0-9]+: from: /) { return 0 }
        sub(/^[0-9]+:[0-9]+: : /, "", a); sub(/^[0-9]+:[0-9]+: from: /, "", b)
        if (a != b) { return 0 }
        hit = 1
      }
      return hit
    }
    # defaultIdAttr (#6269) -- a @table field named id with no @id now
    # records an implicit id attribute in tableDescriptor(): per such class
    # the tree builds a one-entry []AttrDesc holding "id" where the oracle
    # stored nil. Opcode deltas are exactly k times that block (k >= 1):
    # pre-opt one each of slice_new/gc_alloc/const_string/index_set/field_get
    # plus 4 const_int; post-opt the same without the const_int. The tree
    # dump must also contain the "id" string constant.
    function defaultIdAttr(kind,    k, op, want, seen) {
      if (index(rawB, "const_string \"id\"") == 0) { return 0 }
      k = b["rt_call:slice_new"] - a["rt_call:slice_new"]
      if (k < 1) { return 0 }
      want["rt_call:slice_new"] = k; want["gc_alloc"] = k; want["const_string"] = k
      want["index_set"] = k; want["field_get"] = k
      if (kind == "ir") { want["const_int"] = 4 * k }
      for (op in a) { seen[op] = 1 }
      for (op in b) { seen[op] = 1 }
      for (op in want) { seen[op] = 1 }
      for (op in seen) {
        if (b[op] - a[op] != want[op]) { return 0 }
      }
      return 1
    }
    # selfRebound (#6265) -- a static called through a bound type parameter
    # inside a closure: the 0.33.0 oracle leaves the interface Self in the
    # checked type (`: Self!`), the tree resolves it to the parameter (`: T!`).
    # Same line count; each differing pair differs only in that type.
    function selfRebound(nA, linesA, nB, linesB,    i, a, b, hit) {
      if (nA != nB) { return 0 }
      hit = 0
      for (i = 1; i <= nA; i++) {
        if (linesA[i] == linesB[i]) { continue }
        a = linesA[i]; b = linesB[i]
        if (sub(/: Self!$/, ": T!", a) == 0) { return 0 }
        if (a != b) { return 0 }
        hit = 1
      }
      return hit
    }
    # lastTypeColon -- index of the last ": " in a types-dump line, the one
    # separating the expression from its type (a type never contains ": ").
    function lastTypeColon(s,    i, p) {
      p = 0
      for (i = 1; i < length(s); i++) { if (substr(s, i, 2) == ": ") { p = i } }
      return p
    }
    # genericCtorTypeArgs (#6363/#6364) -- constructing a generic class: the
    # 0.33.0 oracle types the call as the bare template (`: Pair`), the tree
    # as its instantiation (`: Pair<i64, string>`). Same line count; each
    # differing pair has the same expression text and a type that is the
    # oracle name followed by a type-argument list. Declared per corpus file.
    function genericCtorTypeArgs(nA, linesA, nB, linesB,    i, pa, pb, ta, tb, ea, eb, hit) {
      if (nA != nB) { return 0 }
      hit = 0
      for (i = 1; i <= nA; i++) {
        if (linesA[i] == linesB[i]) { continue }
        pa = lastTypeColon(linesA[i]); pb = lastTypeColon(linesB[i])
        if (pa == 0 || pa != pb) { return 0 }
        if (substr(linesA[i], 1, pa) != substr(linesB[i], 1, pb)) { return 0 }
        ta = substr(linesA[i], pa + 2); tb = substr(linesB[i], pb + 2)
        ea = ""; eb = ""
        if (match(ta, /![A-Za-z_][A-Za-z0-9_]*$/)) { ea = substr(ta, RSTART); ta = substr(ta, 1, RSTART - 1) }
        if (match(tb, /![A-Za-z_][A-Za-z0-9_]*$/)) { eb = substr(tb, RSTART); tb = substr(tb, 1, RSTART - 1) }
        if (ea != eb) { return 0 }
        # A method result the oracle left in the own parameters of the template
        # (`Pair<B, A>`) is the same lag as a bare template name.
        if (ta ~ /^[A-Za-z_][A-Za-z0-9_]*<[A-Z](, [A-Z])*>$/) { sub(/<.*$/, "", ta) }
        if (ta !~ /^[A-Za-z_][A-Za-z0-9_]*$/) { return 0 }
        if (index(tb, ta "<") != 1 || tb !~ />$/) { return 0 }
        hit = 1
      }
      return hit
    }
    # funcHeadersKeptModIds (#6363/#6364) -- funcHeadersKept with every
    # instantiation id (`$t<n>`, or `$c<n>` once canonicalized) erased, as a
    # multiset: the oracle types the construction as the template, so it
    # emits fewer instantiations and numbers them differently.
    function funcHeadersKeptModIds(nA, linesA, nB, linesB,    i, h, have, na, nb) {
      na = 0; nb = 0
      for (i = 1; i <= nB; i++) {
        if (linesB[i] !~ /^func /) { continue }
        h = linesB[i]; gsub(/\$[tc][0-9]+/, "$t", h); have[h]++; nb++
      }
      for (i = 1; i <= nA; i++) {
        if (linesA[i] !~ /^func /) { continue }
        h = linesA[i]; gsub(/\$[tc][0-9]+/, "$t", h)
        if (have[h] < 1) { return 0 }
        have[h]--; na++
      }
      return (na > 0 && nb > na) ? 1 : 0
    }
    # pureFuncInsert (#6265) -- the oracle miscompiles a generic reached only
    # through a closure by dropping its instantiations; the tree emits them.
    # Every oracle line appears in the tree in order, and every tree-only
    # line belongs to an inserted `func` block. Only declared for the one
    # corpus file that exercises it.
    # funcHeadersKept (#6045) -- every oracle `func` header line is present in
    # the tree, and the tree has more functions than the oracle. Bodies may
    # differ: the oracle lowers the broken closure to an empty-valued return.
    function funcHeadersKept(nA, linesA, nB, linesB,    i, j, seen, na, nb) {
      na = 0; nb = 0
      for (j = 1; j <= nB; j++) { if (linesB[j] ~ /^func /) { seen[linesB[j]] = 1; nb++ } }
      for (i = 1; i <= nA; i++) {
        if (linesA[i] !~ /^func /) { continue }
        na++
        if (!(linesA[i] in seen)) { return 0 }
      }
      return (na > 0 && nb > na) ? 1 : 0
    }
    function pureFuncInsert(nA, linesA, nB, linesB,    i, j, infn, inserted) {
      i = 1; j = 1; infn = 0; inserted = 0
      while (j <= nB) {
        if (i <= nA && linesA[i] == linesB[j] && !infn) { i++; j++; continue }
        if (linesB[j] ~ /^func /) { infn = 1; inserted = 1; j++; continue }
        if (linesB[j] == "" && !infn) { j++; continue }
        if (infn) {
          if (linesB[j] == "") { infn = 0 }
          j++; continue
        }
        return 0
      }
      return (i > nA && inserted) ? 1 : 0
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
        if (tableRowSynthInsert(nA, linesA, nB, linesB)) {
          print "6255-table-row-synth-reposition"; exit 0
        }
        if (fromContextualTypes(nA, linesA, nB, linesB)) {
          print "6264-from-contextual-types"; exit 0
        }
        if (selfRebound(nA, linesA, nB, linesB)) {
          print "6265-closure-bound-static-self"; exit 0
        }
        if (file ~ /run_generic_class_init_(written_args|inferred)[.]bit$/ && genericCtorTypeArgs(nA, linesA, nB, linesB)) {
          print "6363-generic-ctor-type-args"; exit 0
        }
        exit 1
      }
      if (kind == "tokens") {
        if (fromContextualToken(nA, linesA, nB, linesB)) {
          print "6264-from-contextual-token"; exit 0
        }
        exit 1
      }
      if (kind == "diags") {
        if (collectionAttrPresyntax(nA, linesA, nB, linesB)) {
          print "6254-collection-attr-presyntax"; exit 0
        }
        if (fromContextualDiags(nA, linesA, nB, linesB)) {
          print "6264-from-contextual-diags"; exit 0
        }
        exit 1
      }
      if (kind == "ir" || kind == "iropt") {
        if (defaultIdAttr(kind)) {
          print "6269-default-id-attr"; exit 0
        }
        if (file ~ /run_generic_closure_over_bound_self_static[.]bit$/ && pureFuncInsert(nA, linesA, nB, linesB)) {
          print "6265-closure-bound-static-insert"; exit 0
        }
        if (file ~ /run_closure_multival_return_generic_call[.]bit$/ && funcHeadersKept(nA, linesA, nB, linesB)) {
          print "6045-closure-tuple-oracle-declines"; exit 0
        }
        # #6363/#6364: the oracle cannot lower a generic class constructed
        # through its instantiation and emits only the functions before it.
        if (file ~ /run_generic_class_init_(written_args|inferred)[.]bit$/ && funcHeadersKeptModIds(nA, linesA, nB, linesB)) {
          print "6363-generic-ctor-oracle-declines"; exit 0
        }
      }
      exit 1
    }
  ' <(printf '%s\n@@@BIT2@@@\n%s\n' "$1" "$2")
}

# declaredSignatureNames [ir|iropt|ast|fmt|types|diags] -- every name explainMismatch
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
    ir) printf '%s\n' "6269-default-id-attr" "6265-closure-bound-static-insert" "6045-closure-tuple-oracle-declines" "6363-generic-ctor-oracle-declines"; return ;;
    iropt) printf '%s\n' "6269-default-id-attr" "6265-closure-bound-static-insert" "6045-closure-tuple-oracle-declines" "6363-generic-ctor-oracle-declines"; return ;;
    types) printf '%s\n' "6244-json-attr-implicit-insert" "6255-table-row-synth-reposition" "6264-from-contextual-types" "6265-closure-bound-static-self" "6363-generic-ctor-type-args"; return ;;
    diags) printf '%s\n' "6254-collection-attr-presyntax" "6264-from-contextual-diags"; return ;;
    tokens) printf '%s\n' "6264-from-contextual-token"; return ;;
  esac
  [ -n "$kind" ] || printf '%s\n' "6244-json-attr-implicit-insert" "6255-table-row-synth-reposition" "6264-from-contextual-types" "6254-collection-attr-presyntax" "6264-from-contextual-diags" "6264-from-contextual-token" "6269-default-id-attr" "6265-closure-bound-static-self" "6265-closure-bound-static-insert" "6045-closure-tuple-oracle-declines" "6363-generic-ctor-type-args" "6363-generic-ctor-oracle-declines"
}
