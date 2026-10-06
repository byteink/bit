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
# are preserved in git history at this file's state before #7164, and the
# scripts/ir-signatures-walk.sh that held the walks was deleted then (the name
# is reused by #7449 below for the 0.39.0 walks).
#
# Declared (#7451) against the 0.39.0 oracle; retires at the next repin. Four
# signatures, all in the `diags` and `fmt` kinds, each the oracle failing on
# something the tree already handles:
#
#   6403-enum-static-method-presyntax (`diags`, also the `diags` row of
#     selfhost-fuzzdiff.sh). #6403 parses `static` methods in an enum body;
#     the oracle reads `static` as the member name and reports a cascade of
#     E0021 errors on that line. Files: _tests_/cases/run_enum_static.bit and
#     its truncations.
#   7035-keyword-member-name-presyntax (`diags`, fuzzdiff). #7035 lets a
#     reserved word name a method (`as(`, `in<`, `match(`) and follow a glued
#     `.`; the oracle reports E0021 `'as' is a reserved keyword` at each. Files:
#     _tests_/cases/run_keyword_member_names.bit and its truncations.
#   6421-ternary-jsx-hash-oracle-panic (`diags`, fuzzdiff only). The oracle
#     PANICS (`slice bounds out of range`, exit 2) on a file holding a ternary
#     whose JSX `then` branch contains `#`; the tree (#6421) parses it. Files:
#     the truncations of _tests_/cases/parse_ternary_jsx_then.bit that keep its
#     `attrs` function.
#   7380-jsx-text-apostrophe-stray-semicolon (`fmt`). The oracle's fmt lexes a
#     statement whole, so an apostrophe in JSX text opens a rune and it appends
#     a `;` after the closing tag; the tree does not (SPEC/FMT.md section 9).
#     File: _tests_/cases/jsx_text_raw_chars.bit.
#
# Each is an exact identity over the FULL dumps (see explainDiagsLag and
# explainFmtJsxApostrophe below), so a second, unrelated difference on an
# explained file still fails. The input protocol is the oracle's text, the
# tree's text, the kind and, for the panic arm, the file the tree was run on.
# A new entry must satisfy the rules in the header: an exact identity, derived
# from FULL dumps (the oracle's from `sh scripts/stage0.sh`, the tree's from
# `bit-out/bin/bit`), never an excerpt.

#
# Declared (#7449) against the 0.39.0 oracle; retires at the next repin. Seven
# signatures in the `ir`, `iropt` and `types` kinds. diffir, diffiropt and
# difftypes were red on 15 corpus files (MATCH=1116 MISMATCH=15, difftypes 2);
# in every one the tree is correct and the oracle is the older compiler. Each
# file was built with the tree and run to its `.expected` before it was declared.
# The identity is exact over the FULL dumps: constants are erased, the oracle's
# functions get the named rewrite, ids are renumbered, and every function must
# then agree byte for byte (see ir-signatures-walk.sh), so a second,
# unrelated difference on an explained file still fails.
#
#   7408-assert-ok-nil-compare (`ir`, `iropt`). #7408 takes the ok of a type
#     assertion as `v != nil`; the oracle calls `rt_call iface_as_ok()` straight
#     after `iface_as`, `iface_as_enum` or the interface test. Rewrite: that call
#     becomes `icmp_ne bool <the assertion result>, nil`. Files: run_type_assert,
#     run_chan_close_zero_object, run_generic_type_assert,
#     run_map_commaok_present_null, panic_enum_type_assert_boxed,
#     examples/interfaces/interfaces.bit, stdlib/http/requesterror.bit.
#   7406-iface-implements-call (`ir`, `iropt`). #7406 replaces the per-method
#     `rt_call iface_has` chain of an interface assertion by one
#     `iface_implements(recv, "id,id")` with the ids as a pooled string. Rewrite:
#     a chain whose links each feed only the next becomes the const_string and
#     that call. Files: panic_iface_assert_iface, run_iface_assert_iface,
#     run_field_attr_all, run_type_assert_ok_nil (these also carry 7408).
#   7377-append-spread-bulk-move (`ir`, `iropt`). #7377 lowers
#     `append(dst, ...src)` to one `rt_call slice_append_slice(dst, src, is_ref,
#     elem_size)`; the oracle emits a header, a body holding exactly one
#     `slice_append` and an exit block. Rewrite: the loop (index from 0, stepping
#     by 1, every other value passed through) becomes that call and the exit
#     block continues the entry block. Files: run_append_spread,
#     decimal_collections.
#   7387-self-result-oracle-omits-function (`ir`, `iropt`). #7387 lowers an
#     interface method whose result is `Self`; the oracle never lowered the
#     function that calls one. Identity: the oracle lacks only functions the
#     tree has, each holding a `call_iface` whose result type is its receiver
#     type, and the rest agree. File: run_iface_self_result.
#   7383-arrow-oracle-leaks-type-param (`ir`, `iropt`). #7383 types an untyped
#     arrow parameter from a generic method; the oracle leaves `<T>` and
#     `<invalid>` in a closure header and never lowered `main`. Identity: the
#     leaky oracle closures and every tree function the oracle lacks (all `main`
#     or `closure$N`) are dropped and the rest agree. In `iropt` only the function
#     headers are compared: the oracle has no `main`, so whole-program
#     specialization of the callees (closure inlining) legitimately differs there,
#     and the bodies are proven by the `ir` row. File: arrow_generic_method_recv.
#   7387-self-result-types, 7383-arrow-param-types (`types`): the same two
#     changes in `--dump-types`; see explainLagTypes (ir-signatures-walk.sh).
#     Files: run_iface_self_result and arrow_generic_method_recv.
#
#
# Declared (#7069) against the 0.39.0 oracle; retires at the next repin. One signature, in the
# `ir` and `iropt` kinds. #7069 lowers `-N` for an integer literal to the one `const_int T -N`;
# the oracle emits `%a = const_int T N` then `%b = neg T %a`. Constant VALUES are never erased:
#
#   ir. Every function of the oracle dump must equal the tree's byte for byte after ids are
#     renumbered and two folds are applied to the ORACLE text: (1) a `const_int T N` directly
#     followed by the `neg T` that alone uses it becomes the one `const_int T -N` (same signed
#     type, exact negation; the minimum of T negates to itself, and a value that does not fit T
#     is not folded); (2) the icmp_eq/bor chain over constants that forms one contiguous run with
#     at least one negative label, which the oracle could not range because a label was a `neg`,
#     becomes the const/sub/const/icmp_ule range test #7058 emits, the label constants kept. At
#     least one fold must fire, so a changed constant, a dropped `neg` of a non-literal or any
#     other difference fails.
#   iropt. Given the pre-opt dumps of the same file (explainMismatch's fifth and sixth
#     arguments, which selfhost-diffdump.sh supplies) and the `ir` proof of the whole file, each
#     function must agree once constants are erased from the text and ids renumbered AND hold the
#     same set of distinct (type, value) const_int pairs. Where the oracle function holds a `neg`
#     of the exact minimum of a type (`-128` for i8, ...), which it cannot fold, the tree folds
#     what follows it and the bodies cannot match: that function alone is compared by header,
#     its body being the one the `ir` proof covers.
#
#   7069-neg-literal-const. Files, measured against the 0.39.0 oracle over `stdlib examples
#     _tests_/cases _tests_/imports` (the differentials' corpus, with their skip rules): 127
#     files, 127 `ir` and 31 `iropt` rows, among them ir_switch_case_range, run_switch_range,
#     run_debug_neg_literal_min, run_slice_lit_inline_fill, run_slice_u8_store_inline and
#     decimal_to_int_roundtrip. A file that also holds another named lag below keeps that name.
#
# shellcheck source=scripts/ir-signatures-walk.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/ir-signatures-walk.sh"
irWalkAwk

# explainDiagsLag <oracle_diags> <tree_diags> <input_file> -- the three `diags`
# signatures declared against the 0.39.0 oracle. Prints the name and returns 0
# when the divergence is exactly the oracle failing on syntax the tree accepts;
# else prints nothing, returns 1. <input_file> is read only by the panic arm.
#
# A diags text is a run of `error[E....]: msg` blocks: code, message, the
# `--> path:L:C` position and the one source line each quotes. Records the
# tree lacks are the "lag" records; the records left over must be the tree's
# own, byte for byte and in order. A static or keyword record that the tree
# also reports (a field named `as`, a bare `as(`) is not removed, so it still
# has to appear in the tree's text.
explainDiagsLag() {
  local ternary=0
  [ -n "${3:-}" ] && grep -qE '\? *<[A-Za-z].*#' -- "$3" && ternary=1
  awk -v ternary="$ternary" '
    function load(txt, arr,    n, lines, i, cur, c, src) {
      sub(/\n+$/, "", txt)
      n = split(txt, lines, "\n"); cur = 0; arr["n"] = 0
      for (i = 1; i <= n; i++) {
        if (lines[i] ~ /^error\[E[0-9]+\]: /) {
          cur = ++arr["n"]; arr["text", cur] = lines[i]
          arr["code", cur] = substr(lines[i], 7, index(lines[i], "]") - 7)
          arr["msg", cur] = substr(lines[i], index(lines[i], "]: ") + 3)
          arr["line", cur] = 0; arr["col", cur] = 0; arr["src", cur] = ""
        } else if (cur > 0) {
          arr["text", cur] = arr["text", cur] "\n" lines[i]
          if (match(lines[i], /^ *--> .*:[0-9]+:[0-9]+$/)) {
            c = lines[i]; sub(/^.*:[0-9]+:/, "", c); arr["col", cur] = c + 0
            c = lines[i]; sub(/:[0-9]+$/, "", c); sub(/^.*:/, "", c); arr["line", cur] = c + 0
          } else if (match(lines[i], /^ *[0-9]+ [|] /)) {
            arr["src", cur] = substr(lines[i], RSTART + RLENGTH)
          }
        }
      }
    }
    function isEof(arr, k) {
      return arr["code", k] == "E0021" && arr["msg", k] ~ /, found end of file$/
    }
    # The head of a `static` method in an enum body: the oracle takes `static`
    # for the member name and wants `(` where the real name stands.
    function isStatic(arr, k,    s, pre, id) {
      s = arr["src", k]
      if (arr["code", k] != "E0021" || arr["msg", k] != "expected " q "(" q ", found an identifier") { return 0 }
      if (!match(s, /static[ \t]+[A-Za-z_][A-Za-z0-9_]*/)) { return 0 }
      pre = substr(s, 1, RSTART - 1); id = substr(s, RSTART, RLENGTH); sub(/^static[ \t]+/, "", id)
      return pre ~ /^[ \t]*(export[ \t]+)?$/ && arr["col", k] == RSTART + RLENGTH - length(id)
    }
    function isKeyword(arr, k,    s, name, after) {
      s = arr["src", k]; name = arr["msg", k]
      if (arr["code", k] != "E0021" || name !~ /^.[A-Za-z]+. is a reserved keyword$/) { return 0 }
      sub(/ is a reserved keyword$/, "", name); name = substr(name, 2, length(name) - 2)
      if (arr["col", k] < 1 || substr(s, arr["col", k], length(name)) != name) { return 0 }
      after = substr(s, arr["col", k] + length(name), 1)
      return after == "(" || after == "<"
    }
    # The oracle recovers from a static head with the cascade of E0021 errors
    # still on that line; none of them is a truncation error.
    function inCascade(arr, k, head) {
      return arr["code", k] == "E0021" && !isEof(arr, k) && arr["line", k] == arr["line", head]
    }
    function arm(kind,    i, rest, nlag, head) {
      nlag = 0; rest = 0
      for (i = 1; i <= A["n"]; i++) {
        if ((kind == "static" && isStatic(A, i)) || (kind == "kw" && isKeyword(A, i))) {
          nlag++; head = i
          if (kind == "static") { while (i < A["n"] && inCascade(A, i + 1, head)) { i++ } }
          continue
        }
        rest++
        if (rest > B["n"] || A["text", i] != B["text", rest]) { return 0 }
      }
      return nlag > 0 && rest == B["n"]
    }
    function panicArm(    i) {
      if (!ternary || ta != "panic: slice bounds out of range\n") { return 0 }
      for (i = 1; i <= B["n"]; i++) { if (!isEof(B, i)) { return 0 } }
      return 1
    }
    BEGIN { q = "\047" }
    FNR == 1 { fi++ }
    fi == 1 { ta = ta $0 "\n"; next }
    { tb = tb $0 "\n" }
    END {
      load(ta, A); load(tb, B)
      if (arm("static")) { print "6403-enum-static-method-presyntax"; exit 0 }
      if (arm("kw")) { print "7035-keyword-member-name-presyntax"; exit 0 }
      if (panicArm()) { print "6421-ternary-jsx-hash-oracle-panic"; exit 0 }
      exit 1
    }
  ' <(printf '%s\n' "$1") <(printf '%s\n' "$2")
}

# explainFmtJsxApostrophe <oracle_fmt> <tree_fmt> -- the `fmt` signature
# 7380-jsx-text-apostrophe-stray-semicolon. Prints the name and returns 0 when
# the two outputs have the same line count and every differing line is the
# tree's line plus a trailing `;` in the oracle's, the tree's line being a
# closing tag (`</name>`) whose element holds an apostrophe; else prints
# nothing, returns 1. At least one line must differ (the caller only asks when
# the outputs differ).
explainFmtJsxApostrophe() {
  awk '
    FNR == 1 { fi++ }
    fi == 1 { a[++na] = $0; next }
    { b[++nb] = $0 }
    END {
      if (na != nb) { exit 1 }
      for (i = 1; i <= na; i++) {
        if (a[i] == b[i]) { continue }
        if (a[i] != b[i] ";" || b[i] !~ /<[A-Za-z][^<]*\047[^<]*<\/[A-Za-z][A-Za-z0-9_.]*>$/) { exit 1 }
        nd++
      }
      if (nd == 0) { exit 1 }
      print "7380-jsx-text-apostrophe-stray-semicolon"; exit 0
    }
  ' <(printf '%s\n' "$1") <(printf '%s\n' "$2")
}

# explainIrLag <oracle_ir> <tree_ir> <ir|iropt> [<oracle_ir_pre> <tree_ir_pre>] -- the six `ir`/`iropt`
# signatures above, via IR_WALK_AWK (ir-signatures-walk.sh). The two pre-opt dumps of the same file
# are read only for `iropt`, by 7069-neg-literal-const, which holds an optimized dump to the exact
# pre-opt proof. Prints the name and returns 0, or prints nothing and returns 1.
explainIrLag() {
  LC_ALL=C awk -v kind="$3" "${IR_WALK_AWK}" <(printf '%s\n@@@BIT2@@@\n%s\n@@@PREA@@@\n%s\n@@@PREB@@@\n%s\n' "$1" "$2" "${4:-}" "${5:-}")
}

# explainMismatch <oracle_text> <bit2_text> <kind: ir|iropt|ast|fmt|types|diags|tokens> [file [oracle_pre tree_pre]]
# Prints the name of the registered signature that explains the divergence
# and returns 0, or prints nothing and returns 1 if none does. `file` is the
# input the tree ran on, read only by the `diags` panic arm.
explainMismatch() {
  case "$3" in
    diags) explainDiagsLag "$1" "$2" "${4:-}"; return ;;
    fmt) explainFmtJsxApostrophe "$1" "$2"; return ;;
    types) explainLagTypes "$1" "$2"; return ;;
    ir|iropt) explainIrLag "$1" "$2" "$3" "${5:-}" "${6:-}"; return ;;
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
# the list matches the `print "..."` statements in this file.
declaredSignatureNames() {
  local diags="6403-enum-static-method-presyntax 7035-keyword-member-name-presyntax 6421-ternary-jsx-hash-oracle-panic"
  local fmt="7380-jsx-text-apostrophe-stray-semicolon"
  local types="7387-self-result-types 7383-arrow-param-types"
  local ir="7408-assert-ok-nil-compare 7406-iface-implements-call 7377-append-spread-bulk-move 7387-self-result-oracle-omits-function 7383-arrow-oracle-leaks-type-param 7069-neg-literal-const"
  case "${1:-}" in
    diags) printf '%s\n' $diags ;;
    fmt) printf '%s\n' $fmt ;;
    types) printf '%s\n' $types ;;
    ir|iropt) printf '%s\n' $ir ;;
    "") printf '%s\n' $diags $fmt $types $ir ;;
  esac
  return 0
}
