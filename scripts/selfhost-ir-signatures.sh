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
# Every signature declared against the 0.40.0 oracle was retired by the stage0
# 0.41.0 repin (#6533), declared by #7558, #7562, #7564, #7574, #7637, #7671,
# #7674, #7700, #6681 and #7737: 7562-packed-halfword-slices,
# 7574-packed-narrow-slices, 7637-string-from-rune-range,
# 6681-multi-assign-oracle-omits-function and 7737-forof-len-once (`ir`,
# `iropt`), 7574-f32-store-schedule-lag and 7674-forwarded-index-get (`iropt`),
# 7558-synth-json-alias-column-shift and 7564-synth-table-alias-column-shift
# (`types`), the three per-file lag pins of irLagPins (run_float32_interp,
# run_float_slice_elems, stdlib/compress/crc32.bit) with the STALE-PIN check of
# selfhost-diffdump.sh, and the ORACLE_LAG list of selfhost-diffexamples.sh.
# 0.41.0 carries #7562, #7574 (so the pinned compiler strides narrow slices the
# way the tree does), #7637, #7674, #6681, #7558, #7564 and #7737, so it is the
# first oracle that agrees with the tree on every corpus file they explained.
# Confirmed against the 0.41.0 pin (this tree at the #6533 repin, aarch64-macos,
# the only host this repin was run on): selfhost-diffir.sh reports MATCH=1162
# MISMATCH=0 EXPLAINED=0 and names the five `ir` signatures as RETIRED;
# selfhost-diffiropt.sh reports MATCH=1162 MISMATCH=0 EXPLAINED=0, names all
# seven `ir`/`iropt` signatures as RETIRED and the three pinned files as
# STALE-PIN; selfhost-difftypes.sh reports MATCH=1793 MISMATCH=0 EXPLAINED=0 and
# names the two `types` signatures as RETIRED; selfhost-diffcheck.sh MATCH=1793
# FALSEPOS=0 DIFF=0, selfhost-diffsafepoints.sh MATCH=1134 MISMATCH=0
# EXPLAINED=0 and selfhost-diffexamples.sh PASS=48 DIFF=0 REFUSED=0 LAG=0. Their
# derivations (`irWalkAwk` and its stage 1, fold, renumber, f32, CSE and types
# programs, `irTrial`, `explainIrLagPin`, `explainOmittedFunctions`,
# `explainLagTypes`, and the #7737 `irForOfAwk`, `irDedupAwk`, `irMergeLoads`,
# `irLenToHeader`, `irGuardOff`) are preserved in git history at this file's
# state before #6533; scripts/ir-signatures-walk.sh and
# scripts/ir-signatures-forof.sh are deleted.
#
# --- Declared signatures (against the 0.41.0 oracle) ---
#
# Retires at the next stage0 repin, the first oracle cut from a tree that carries #7745.
#
# 7745-loop-defer-stack (`ir`, `iropt`). #7745 (lowerdefer.bit) lowers a function with a `defer`
# inside a loop onto a per-frame stack of thunks: every execution of a defer builds
# `make_closure @defer$thunk$N` (a function that unpacks the captured receiver/arguments and makes the
# deferred call) and appends it to a `[]fn() void`, and every exit pops the stack. The pinned stage0 kept
# one flag and one set of slots per defer statement and replayed each at every exit. The two shapes share
# nothing a rewrite could map line to line, so the identity is on the function level, in three parts.
# `explainLoopDeferStack` prints the signature and returns 0 only when ALL hold:
#   1. A tree function is STACK-MODE when its body holds a `make_closure @defer$thunk$N`. There is at
#      least one, every `defer$thunk$N` function of the tree is made by some stack-mode function, every
#      thunk a stack-mode function makes exists, and the oracle has a function of the same name for each
#      stack-mode function.
#   2. Every other function is byte-equal. Both dumps lose the stack-mode functions; the tree also loses
#      the thunks, and a `closure$N` or `trampoline$N` name (they share the thunks' id space, so every
#      one after a thunk moved up by the thunks before it) is renumbered back by that count.
#   3. For each stack-mode function every callee (`call @f`, `rt_call f`, `call_iface`) of the oracle
#      function is a callee of the tree function or of a thunk it makes, so no deferred call was dropped.
#      The tree may hold more: the oracle replays a defer only at an exit it can reach, and a loop with
#      no exit has none. The stack's own `rt_call slice_append`/`slice_get` are not callees here.
# What it does not check is the body of a stack-mode function beyond that callee set; the golden case
# _tests_/cases/run_defer_each_loop_iteration.bit proves its behaviour. Files: see the run output.
#
# explainLoopDeferStack <oracle_text> <bit2_text> -- see the 7745 entry above.
irLoopDeferAwk() {
  IR_LOOPDEFER_AWK='
function fname(s,   n) { n = s; sub(/^func /, "", n); sub(/\(.*$/, "", n); return n }
function isThunk(n) { return n ~ /^defer\$thunk\$[0-9]+$/ }
function thunkId(n,   i) { i = n; sub(/^defer\$thunk\$/, "", i); return i + 0 }
# The callee tokens of one function text, as " tok " items appended to the set string s.
function callees(text, s,   a, n, i, l, t) {
  n = split(text, a, "\n")
  for (i = 1; i <= n; i++) {
    l = a[i]; t = ""
    if (match(l, /= call @[^(]+\(/)) { t = substr(l, RSTART + 2, RLENGTH - 3) }
    else if (match(l, /= rt_call [^(]+\(/)) { t = substr(l, RSTART + 2, RLENGTH - 3) }
    else if (l ~ /= call_iface /) { t = "call_iface" }
    if (t != "" && t != "rt_call slice_append" && t != "rt_call slice_get" && index(s, " " t " ") == 0) { s = s " " t " " }
  }
  return s
}
# Whether every item of the set string x is in the set string y.
function subsetSet(x, y,   a, n, i) {
  n = split(x, a, "  ")
  for (i = 1; i <= n; i++) {
    gsub(/^ +| +$/, "", a[i])
    if (a[i] != "" && index(y, " " a[i] " ") == 0) { return 0 }
  }
  return 1
}
# Renumbers every closure$N / trampoline$N of a line down by the thunks with a smaller id.
function renumber(line,   out, tok, id, k, c) {
  out = ""
  while (match(line, /(closure|trampoline)\$[0-9]+/)) {
    tok = substr(line, RSTART, RLENGTH)
    id = tok; sub(/^[a-z]+\$/, "", id); id = id + 0
    c = 0
    for (k = 1; k <= nth; k++) { if (TID[k] < id) { c++ } }
    sub(/\$[0-9]+$/, "", tok)
    out = out substr(line, 1, RSTART - 1) tok "$" (id - c)
    line = substr(line, RSTART + RLENGTH)
  }
  return out line
}
$0 == "@@@BIT2@@@" { side = 1; cur = ""; next }
{
  if ($0 ~ /^func /) {
    cur = fname($0)
    if (side == 0) { on++; ON[on] = cur; OT[cur] = "" } else { tn++; TN[tn] = cur; TT[cur] = "" }
  }
  if (cur != "") { if (side == 0) { OT[cur] = OT[cur] $0 "\n" } else { TT[cur] = TT[cur] $0 "\n" } }
}
END {
  nth = 0; ns = 0
  for (i = 1; i <= tn; i++) {
    f = TN[i]
    if (isThunk(f)) { nth++; TID[nth] = thunkId(f); TNAME[nth] = f; continue }
    if (index(TT[f], "make_closure @defer$thunk$") > 0) { ns++; SN[ns] = f; ISS[f] = 1 }
  }
  if (ns == 0) { exit 1 }
  # 1. thunks and stack-mode functions pair up, and the oracle has every stack-mode function.
  for (i = 1; i <= ns; i++) {
    f = SN[i]
    if (!(f in OT)) { exit 1 }
    m = split(TT[f], L, "\n"); need = ""
    for (j = 1; j <= m; j++) {
      if (match(L[j], /make_closure @defer\$thunk\$[0-9]+/)) {
        t = substr(L[j], RSTART + 14, RLENGTH - 14)
        if (!(t in TT)) { exit 1 }
        MADE[t] = 1; need = need " " t
      }
    }
    NEED[f] = need
  }
  for (i = 1; i <= nth; i++) { if (!(TNAME[i] in MADE)) { exit 1 } }
  # 3. the callee sets.
  for (i = 1; i <= ns; i++) {
    f = SN[i]
    ts = callees(TT[f], ""); m = split(NEED[f], P, " ")
    for (j = 1; j <= m; j++) { ts = callees(TT[P[j]], ts) }
    os = callees(OT[f], "")
    if (!subsetSet(os, ts)) { exit 1 }
  }
  # 2. everything else is byte-equal.
  ot = ""; tt = ""
  for (i = 1; i <= on; i++) { if (!(ON[i] in ISS)) { ot = ot OT[ON[i]] } }
  for (i = 1; i <= tn; i++) {
    f = TN[i]
    if ((f in ISS) || isThunk(f)) { continue }
    m = split(TT[f], L, "\n")
    for (j = 1; j < m; j++) { tt = tt renumber(L[j]) "\n" }
  }
  # A dump ends at its last function; the one the tree loses may have been followed by that blank line.
  sub(/\n+$/, "", ot); sub(/\n+$/, "", tt)
  if (ot != tt) { exit 1 }
  print "7745-loop-defer-stack"
}'
}

explainLoopDeferStack() {
  irLoopDeferAwk
  printf '%s\n@@@BIT2@@@\n%s\n' "$(canon_ir_ids "$1")" "$(canon_ir_ids "$2")" | LC_ALL=C awk "${IR_LOOPDEFER_AWK}"
}

# explainLoopDeferPolls <oracle_ir> <bit2_ir> <seed_count> <self_count> -- the 7745 entry above,
# read by scripts/selfhost-diffsafepoints.sh for an EXTRA-SAFEPOINT divergence. Prints the signature
# and returns 0 only when explainLoopDeferStack holds (so the dumps differ in the stack-mode
# functions and their thunks only) AND, summed over the stack-mode functions, with
# d = self - seed and P = the added `rt_call slice_get` (one per pop loop, `slice_len` down to 0):
#   d > 0 and P == d     every extra poll is a pop loop's back edge, and each loop adds one
#   added call_value == P   each loop body makes exactly one deferred call
#   added icmp_sgt == P     each loop has exactly one header comparison
# The pushes add none: `make_closure` and `slice_append` carry no back edge, so a closure
# allocation per defer is not a poll. A poll with no pop loop (d > P), a pop loop that lost its
# poll (d < P), or a missing safepoint (d < 0) is refused. Retires with the 7745 entry above.
explainLoopDeferPolls() {
  explainLoopDeferStack "$1" "$2" >/dev/null || return 1
  printf '%s\n@@@BIT2@@@\n%s\n' "$1" "$2" | LC_ALL=C awk -v d="$(($4 - $3))" '
function bump(k) {
  if ($0 ~ /rt_call slice_get\(/) { N[k, "get"]++ }
  else if ($0 ~ / call_value /)    { N[k, "val"]++ }
  else if ($0 ~ / icmp_sgt /)      { N[k, "sgt"]++ }
  else if (side == 1 && $0 ~ /make_closure @defer\$thunk\$/) { S[cur] = 1 }
}
$0 == "@@@BIT2@@@" { side = 1; cur = ""; next }
/^func / { cur = $2; sub(/\(.*$/, "", cur); next }
cur != "" { bump(side SUBSEP cur) }
END {
  split("get val sgt", K, " ")
  for (f in S) {
    for (i = 1; i <= 3; i++) { delta[K[i]] += N[1 SUBSEP f, K[i]] - N[0 SUBSEP f, K[i]] }
  }
  if (d > 0 && delta["get"] == d && delta["val"] == d && delta["sgt"] == d) { print "7745-loop-defer-stack"; exit 0 }
  exit 1
}'
}

# explainMismatch <oracle_text> <bit2_text> <kind: ir|iropt|ast|fmt|types|diags|tokens> [file]
# Prints the name of the registered signature that explains the divergence
# and returns 0, or prints nothing and returns 1 if none does. Only 7745-loop-defer-stack is
# registered, on the `ir` and `iropt` kinds.
explainMismatch() {
  case "$3" in
    ir|iropt) explainLoopDeferStack "$1" "$2"; return ;;
  esac
  return 1
}

# declaredSignatureNames [ir|iropt|ast|fmt|types|diags] -- every name explainMismatch
# CAN print for the given dump kind, one per line (#5509, extended by #5510).
# The single source of truth for the retirement check in
# scripts/selfhost-diffdump.sh's run_ir()/run_types(): a signature this
# function does not list can never be checked for going dead, and one it lists
# that explainMismatch no longer prints would make that check fail on every
# run. Kept in sync by hand, and selfhost-ir-signatures-selfcheck.sh asserts
# the list matches the `print "..."` statements in this file. Declared for
# `ir` and `iropt` only.
declaredSignatureNames() {
  case "${1:-}" in
    ir|iropt|"") printf '%s\n' 7745-loop-defer-stack ;;
  esac
  return 0
}

# shellcheck source=scripts/selfhost-ir-canon.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/selfhost-ir-canon.sh"
