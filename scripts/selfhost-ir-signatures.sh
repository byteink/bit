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
# #6255-table-row-synth-reposition, #6264-from-contextual-types,
# #6265-closure-bound-static-self and #6363-generic-ctor-type-args (`types`);
# #6269-default-id-attr, #6265-closure-bound-static-insert,
# #6045-closure-tuple-oracle-declines and #6363-generic-ctor-oracle-declines
# (`ir`/`iropt`); #6254-collection-attr-presyntax and
# #6264-from-contextual-diags (`diags`); #6264-from-contextual-token
# (`tokens`) were retired by the stage0 0.34.0 repin (#6395): 0.34.0 contains
# #6244, #6254, #6255, #6264, #6265, #6269, #6045, #6363, #6364 and #6365, so
# it is the first oracle that agrees with the tree on every corpus file those
# eleven signatures used to explain. Confirmed against the 0.34.0 pin (this
# tree at 0c8f066d5 plus the repin, aarch64-macos, the only host this repin
# was built on): selfhost-diffir.sh and selfhost-diffiropt.sh each report
# MATCH=1029 MISMATCH=0 EXPLAINED=0 and named the four ir signatures as
# RETIRED; selfhost-difftypes.sh reported MATCH=1502 MISMATCH=0 EXPLAINED=1
# (the nsstaticcall file above) and named the four types signatures as
# RETIRED; selfhost-diffdiags.sh (MATCH=1503 EXPLAINED=0) and
# selfhost-difftokens.sh (MATCH=1503 EXPLAINED=0) have no automated RETIRED
# audit, so the diags and tokens signatures were confirmed dead by those
# zero counts. Their derivations are preserved in git history at this
# file's state before #6395.
#
# #6244-json-attr-implicit-insert (`types`), #6415-catch-assign-join-args and
# #6432-static-bound-oracle-declines (`ir`/`iropt`, one file each) and
# #6396-generic-bound-type-args-presyntax (`types`, `diags`) were retired by
# the stage0 0.35.0 repin (#6527), the last four declared signatures.
# 0.35.0 contains #6388, #6396, #6415 and #6432, so it is the first oracle
# that agrees with the tree on every corpus file they explained. Confirmed
# against the 0.35.0 pin (this tree at 7c96bb7cd plus the repin, aarch64-
# macos, the only host this repin was built on): selfhost-diffir.sh and
# selfhost-diffiropt.sh each report MATCH=1056 MISMATCH=0 EXPLAINED=0 and name
# 6415 and 6432 as RETIRED; selfhost-difftypes.sh reports MATCH=1530
# MISMATCH=0 EXPLAINED=0 and names 6244 and 6396 as RETIRED;
# selfhost-diffdiags.sh reports MATCH=1530 MISMATCH=0 EXPLAINED=0. Their
# derivations (`jsonAttrImplicitInsert`, `joinArgsThreaded`,
# `boundPresyntaxDiags`/`boundPresyntaxTypes`, `funcsAdded`) are preserved in
# git history at this file's state before #6527.
#
# #6679-generic-join-param-retype (`ir`, `iropt`), #6570-fail-zero-decimal-box
# (`ir`, `iropt`) and #6564-arrow-ctor-seeded (`types`, `ir`, `iropt`) were
# retired by the stage0 0.36.0 repin (#6788), declared by #6711, #6712 and #6713
# against the 0.35.0 oracle. 0.36.0 contains #6564, #6570 and #6679, so it is
# the first oracle that agrees with the tree on every corpus file they
# explained. Confirmed against the 0.36.0 pin (this tree at the #6788 repin,
# aarch64-macos): `--dump-ir`, `--dump-ir-pre` and `--dump-types` of the nine
# files those signatures named (ir_generic_match_join_type, generic_option_
# containers, generic_option_string_field, decimal_fallible_return,
# run_arrow_arg_ctor_init, stdlib/decimal/decimal.bit and the three
# _tests_/imports http2e2e/httpgracefulh2/httpgracefultls mains) are
# byte-identical between the oracle and the tree with no signature consulted.
# Their derivations (`joinParamRetype`, `decimalZeroBox`/`boxHunk`,
# `arrowTypeSeeded`/`arrowIrSeeded`/`invalidFilled`) are preserved in git
# history at this file's state before #6788.
#
# 6730-fallible-enum-words (`ir`, `iropt`), 6847-test-module-counters,
# 6847-test-module-counters-with-fallible-enum-words (`ir`, `iropt`),
# 6847-test-module-functions (`selfhost-diffsafepoints.sh`), 6840-bce-window-guard,
# 6982-error-path-nil, 7058-switch-case-range and 7058-switch-case-range-opt
# (`ir`, `iropt`), 6990-interface-field-presyntax and 6997-where-in-key-presyntax
# (`diags`), 6558-string-from-byte-range (`ir`, `iropt`),
# 6988-table-class-name-synth-shift (`types`) and 5786-licm-wide-const-placement
# (`iropt`, arm64), together with the declared lists of selfhost-diffruntime.sh
# (RELOC_DECLARED), selfhost-diffcheck.sh (FALSEPOS_DECLARED) and
# selfhost-diffverdict.sh (MISSING_DECLARED) and the BIT_ERR_REG=0 pin of
# selfhost-diffdump-setup.sh, were retired by the stage0 0.37.0 repin (#7164),
# declared by #6730, #6847, #6840, #6982, #7058, #7087, #7104, #7109 and #7149
# against the 0.36.0 oracle. 0.37.0 is cut from the tree that carries all of
# them, so its oracle agrees with the tree on every corpus file they explained.
# Their derivations (`canonK`/`shiftOk`/`moveTramp`,
# `explainTestFunctions`, `nilWalk`, `rangeWalk`/`explainSwitchPostOpt`,
# `byteRange`, `explainDiagsPresyntax`, `explainTableSynthTypes`, `licmWalk`)
# are preserved in git history at this file's state before #7164, and
# scripts/ir-signatures-walk.sh, which held the walks, is deleted (the name is
# reused by the 0.39.0 walks below).
#
# Every signature declared against the 0.39.0 oracle was retired by the stage0
# 0.40.0 repin (#7559), declared by #7449, #7450, #7451, #7471 and #7505:
# 7408-assert-ok-nil-compare, 7406-iface-implements-call,
# 7377-append-spread-bulk-move, 7387-self-result-oracle-omits-function,
# 7383-arrow-oracle-leaks-type-param, 7069-neg-literal-const and
# 7482-aliased-generic-iface-slot (`ir`, `iropt`), 7387-self-result-types,
# 7383-arrow-param-types and 7482-aliased-generic-types (`types`),
# 6403-enum-static-method-presyntax, 7035-keyword-member-name-presyntax and
# 6421-ternary-jsx-hash-oracle-panic (`diags`, and the oracle-crash arm of
# selfhost-fuzzdiff.sh), 7380-jsx-text-apostrophe-stray-semicolon (`fmt`), and
# 7377-bulk-spread-append and 7482-aliased-generic-instance-methods
# (selfhost-diffsafepoints.sh, scripts/safepoint-signatures.sh). 0.40.0 carries
# #7482, #7377, #7383, #7387, #7069 and the declarations of #7449, #7450, #7451,
# #7471 and #7505, so it is the first oracle that agrees with the tree on every
# corpus file they explained. Confirmed against the 0.40.0 pin (this tree at the
# #7559 repin, aarch64-macos, the only host this repin was run on):
# selfhost-diffir.sh and selfhost-diffiropt.sh each report MATCH=1142
# MISMATCH=0 EXPLAINED=0 and name all seven `ir` signatures as RETIRED;
# selfhost-difftypes.sh reports MATCH=1750 MISMATCH=0 EXPLAINED=0 and names
# the three `types` signatures as RETIRED; selfhost-diffdiags.sh reports
# MATCH=1750 EXPLAINED=0, selfhost-difffmt.sh MATCH=2483 EXPLAINED=0,
# selfhost-fuzzdiff.sh MATCH=27898 EXPLAINED=0 and selfhost-diffsafepoints.sh
# MATCH=1116 EXPLAINED=0, which is how the `diags`, `fmt` and safepoint
# signatures (no automated RETIRED audit) were found to match no file. Their
# derivations (`explainDiagsLag`, `explainFmtJsxApostrophe`, `explainLagTypes`,
# `lagMatch`, `cseAdds`, `explainSpreadDelta`, `explainInstanceText`) are
# preserved in git history at this file's state before #7559, and both
# scripts/ir-signatures-walk.sh and scripts/safepoint-signatures.sh are
# deleted.
#
# --- Declared signatures (against the 0.40.0 oracle) ---
#
# These retire at the next stage0 repin, which is the first oracle cut from a tree that carries
# #7558, #7562, #7574 and #7637. The walks live in scripts/ir-signatures-walk.sh, sourced below.
#
# 7558-synth-json-alias-column-shift (`types`). #7558 (54c0b8420) binds std/json's `Json` and
# `JsonEntry` under the reserved aliases `__Json`/`__JsonEntry` in the code a `@json` class
# synthesizes, so the synthesized text is longer and every row the dump places on that source line
# after the insertion moves right. The oracle and the tree must have the same row count and agree
# on every row's line, name and type; the column may only grow, must never shrink back along the
# line, and may move only on a source line that carries a synthesized `__json_` row. 23 corpus
# files: the 19 under _tests_/cases/ and the four jsonattr/jsonschema* mains under
# _tests_/imports/ (the rows `cols` and `__row` of run_table_persisted_flag.bit move because they
# sit on the same synthesized line, after the insertion).
#
# 7562-packed-halfword-slices (`ir`, `iropt`). #7562 (05bb7c255, a64ce6f04) packs []i16/[]u16 at
# 2 bytes per element: the elem_size constant of slice_new/slice_append/slice_get is 2 instead of
# 8, an element read is `index_get buf[i]` instead of `field_get (buf + (i << 3))[0]`, a store
# writes the narrow value instead of its word-widened `convert`, ptrOf scales by 2, a signed
# `rt_call slice_get` returns i64 and a `convert i16` narrows it, and optappend.bit's append fast
# path (elem_size equals the element width) now expands for these slices. Both dumps are normalized
# (scripts/ir-signatures-walk.sh), the oracle one rewritten along exactly those shapes and the
# tree one with the append fast path folded back, and the texts must then agree byte for byte.
# The rewrites fire on i16/u16 only, so an i32/u32/i8/bool slice that changed, a tree that left a
# halfword site word-strided, or any other difference anywhere in the file stays a REGRESSION.
# 3 corpus files, on both arms: convert_widen_alias.bit, run_narrow_slice_store_widen.bit and
# run_packed_i16_slice.bit.
#
# 7574-packed-narrow-slices (`ir`, `iropt`). #7574 (8eb73dbbf) extends #7562's packing to every
# narrow prim: []i8/[]bool at 1 byte, []i32/[]u32/[]f32 at 4. The same shapes as 7562 (elem_size
# constant, `index_get` reads, narrow stores without the word-widening `convert`, ptrOf scaling,
# the append fast path) plus the f32 element store, which was `bitcast u32` into `rt_call
# slice_set` and is now an inline `index_set` from the float register, and the read-back of a whole
# f32 lvalue, which is still `rt_call slice_get` plus `bitcast f32` in places and a slice_len-guarded
# `index_get` in others. Every spelling of an f32 element store or read, in BOTH dumps, is collapsed to
# the pseudo-ops `f32_store s[i] = v` and `f32_load s[i] f32` (the guard, its panic block and the two
# field_get reads go with the guarded spelling; a guard that does not match exactly stays and keeps the
# file unexplained). The trial that names it enables the halfword and the narrow widths together. The
# optimizer-driven differences of the post-opt arm are NOT in it: run_float32_interp and
# run_float_slice_elems differ there by where the inline stores sit relative to the following reads'
# guards. A store into a slice the tree knows to start at offset 0 (a fresh literal) has no offset read:
# its guard and buffer read are collapsed the same way. stdlib/crypto/bigint.bit differed by a load the
# oracle CSE'd until #7674 made the tree forward it; it is explained by this signature alone.
#
# 7637-string-from-rune-range (`ir`, `iropt`). #7637 (c8381c0c2) makes `string(rs[lo:hi])` on a
# `[]rune` one `rt_call string_from_rune_range(rs, lo, hi)`; the oracle emitted
# `string_from_byte_range` with the same arguments. The rewrite fires only when the first operand
# is a `[]i32` (or the untyped nil), so a `[]u8` receiver is never touched. A file that needs this
# together with the packing is named 7637 (the one rewrite that is not a width).
#
# 7674-forwarded-index-get (`iropt` only). #7674 (aa32c9bf3) puts the `index_get` of a non-reference
# scalar into optcse.bit's load chain (cseStep, AvailArena.elem, cseScalarType); the pinned stage0
# forwarded only the word-strided `field_get` read it replaced, so it loads such an element twice
# where the tree loads it once. The oracle dump is rewritten by IR_CSE_AWK (scripts/ir-signatures-walk.sh)
# along the rule optcse.bit applies: a block with exactly one predecessor, reached by a forward edge,
# starts from that predecessor's exit table, any other block from an empty one; a later `index_get`
# with the same base, index and prim type as an entry is dropped and its uses renamed to the earlier
# id; every op in isSideEffecting except index_get and the terminators (a call, a store, an
# allocation, a division, an atomic, asm, a syscall, the attention poll, keepAlive) empties the table,
# and so does any op the walk does not know. A compare or a bitwise, shift or float op that the rename
# made equal to an earlier one is dropped too (optcse.bit's pure chain, which no barrier clears), but
# only when it was renamed. The tree dump is never touched, so a tree that kept a load, or a load the
# walk would not drop, stays unexplained; the normalized texts must then agree byte for byte. It
# composes with the packing: the stage runs after the halfword/narrow rewrites. 18 corpus files:
# json_cst_create_intermediate, jsonc_parse_{comments,json5_rejected,trailing_comma,
# two_trailing_commas}, run_append_spread, run_inliner_loop_return, run_tuple_narrow_{boxed,exploded}_
# convert under _tests_/cases/, examples/strslice and examples/syncmutex, and stdlib/{hash/xxhash64,
# time/extend,http2/hpack,json/lex,decimal/decimal,crypto/sha512,crypto/field25519}.
#
# All four retire at the next stage0 repin (#6533).
#
# explainMismatch <oracle_text> <bit2_text> <kind: ir|iropt|ast|fmt|types|diags|tokens> [file]
# Prints the name of the registered signature that explains the divergence
# and returns 0, or prints nothing and returns 1 if none does.
explainMismatch() {
  case "$3" in
    types) explainLagTypes "$1" "$2"; return ;;
    ir|iropt)
      explainIrLag "$1" "$2" "$3" && return 0
      irLagPinned "$3" "${4:-}" && explainIrLagPin "$1" "$2"
      return ;;
  esac
  return 1
}

# --- Per-file lag pins (#7671) ---
#
# 7574-f32-store-schedule-lag (`iropt` only). #7574 stores an f32 element inline, so the optimizer
# of the working tree moves those stores relative to the guards of the reads that follow and shares
# one slice_len between them; the pinned stage0 sees an opaque `rt_call slice_set` there and cannot.
# golden (run_float32_interp, run_float_slice_elems) proves the output
# right. A pin is `kind|file|reason`; it explains its file only when, with every line tied to an
# []f32 slice deleted from both dumps (explainIrLagPin), the rest is identical, and a pinned file
# that no longer needs the pin (it matches, or a declared signature explains it) fails the run as
# STALE-PIN in selfhost-diffdump.sh. Removable at the stage0 repin (#6533). This is the one
# per-file list the family has; #1883 deleted the last one, so an entry here needs a reason a
# reader can check.
irLagPins() {
  printf '%s\n' \
    'iropt|_tests_/cases/run_float32_interp.bit|#7574 inline f32 store scheduled by the optimizer, until the #6533 repin' \
    'iropt|_tests_/cases/run_float_slice_elems.bit|#7574 inline f32 store scheduled by the optimizer, until the #6533 repin'
}
# irLagPinned <kind> <file> -- 0 when the (kind, file) pair is pinned.
irLagPinned() { irLagPins | awk -F'|' -v k="$1" -v f="${2:-}" '$1 == k && $2 == f { found = 1 } END { exit !found }'; }
# irLagPinFiles <kind> -- the pinned files of that arm, one per line.
irLagPinFiles() { irLagPins | awk -F'|' -v k="$1" '$1 == k { print $2 }'; }

# declaredSignatureNames [ir|iropt|ast|fmt|types|diags] -- every name explainMismatch
# CAN print for the given dump kind, one per line (#5509, extended by #5510).
# The single source of truth for the retirement check in
# scripts/selfhost-diffdump.sh's run_ir()/run_types(): a signature this
# function does not list can never be checked for going dead, and one it lists
# that explainMismatch no longer prints would make that check fail on every
# run. Kept in sync by hand, and selfhost-ir-signatures-selfcheck.sh asserts
# the list matches the `print "..."` statements in this file and in
# scripts/ir-signatures-walk.sh.
declaredSignatureNames() {
  local types="7558-synth-json-alias-column-shift"
  local ir="7562-packed-halfword-slices 7574-packed-narrow-slices 7637-string-from-rune-range"
  local lag="7574-f32-store-schedule-lag 7674-forwarded-index-get"
  case "${1:-}" in
    types) printf '%s\n' $types ;;
    ir) printf '%s\n' $ir ;;
    iropt) printf '%s\n' $ir $lag ;;
    "") printf '%s\n' $types $ir $lag ;;
  esac
  return 0
}

# The walks and the canonicalizer they use (scripts/selfhost-ir-canon.sh). Sourced after the
# functions above are defined; nothing here runs until explainMismatch is called.
# shellcheck source=scripts/selfhost-ir-canon.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/selfhost-ir-canon.sh"
# shellcheck source=scripts/ir-signatures-walk.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/ir-signatures-walk.sh"
