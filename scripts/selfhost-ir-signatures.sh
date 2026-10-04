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
# --- Declared signatures (each retires at the repin that brings the fix in) ---
#
# 6730-fallible-enum-words (`ir`, `iropt`). #6730 returns a fallible enum ok
# value (`next(): Option<T>!`) in its two words {tag, payload} instead of one
# box (`fallibleOkWordTypes`, compiler/lowerfail.bit). The 0.36.0 oracle
# predates it. Files affected: _tests_/cases/run_sql_row_find.bit,
# _tests_/cases/run_forof_iterator_fail.bit,
# _tests_/cases/run_forof_iterator_done.bit and stdlib/fs/secure/secure.bit.
# The identity, walked line by line under ONE oracle-to-tree %id bijection per
# function (every unchanged line must agree under it, so a wrong operand
# anywhere fails), with only these hunks allowed:
#   call site: `%c = call @F(args) T` becomes `%c2 = call @F(args) i64` and
#     `%w = call_word %c2[1] P` (exactly two words), then either the rebuilt
#     box `%b = gc_alloc size=16 ptrs=[..] T`, `field_set %b[0] = %c2`,
#     `field_set %b[8] = %w` standing for %c, or no box, and %c is then used
#     only by oracle reads `field_get %c[0] i64` / `field_get %c[8] P`, which
#     are deleted and stand for %c2 / %w;
#   callee return: `ret %h` becomes `ret %r0, %r1`, where either the tree
#     inserted `%r0 = field_get %x[0] i64`, `%r1 = field_get %x[8] P` and %x
#     stands for %h, or the oracle's `%h = gc_alloc size=16` and its two
#     `field_set %h[0|8]` are deleted and %r0, %r1 stand for their values.
# Every deleted box must be returned, every inserted read pair consumed by the
# next `ret`. Retires at the first repin after 0.36.0.
#
# 6847-test-module-counters, 6847-test-module-counters-with-fallible-enum-words
# (`ir`, `iropt`) and 6847-test-module-functions (the safepoint differential,
# scripts/selfhost-diffsafepoints.sh). #6847 stops loading the .test.bit files
# of an imported std/ or package module. The 0.36.0 oracle still compiles them,
# so every corpus file that imports http, json, sql, time, a websocket, JSX and
# the like differs from it in what the test files interned, and in the
# functions only they reach. Attributed by building the parent of the #6847
# merge (bedc8a4cc), the merge (770579612) and main (950af70fa), and diffing
# the dumps and objects of every diverging file: the oracle and bedc8a4cc agree
# on all 86 IR files (bar the four #6730 ones) and on all 127 safepoint files;
# 770579612 and 950af70fa agree on every pre-opt dump and on every object.
#   counters: the dumps are identical once every interning counter is renamed
#     in first-appearance order within its class (module id `m<N>$`, a `$<N>`
#     suffix per symbol stem, `__bitfnv_<N>`, `call_iface %x.<N>(`), the two
#     sides name the same number of counters per class, and a counter id
#     differs somewhere. A line holding a string literal is never renamed. A
#     deduplicated function-value trampoline the oracle leaves to the imported
#     module (owned by whichever module lowers it first) may also be present
#     only in the tree: one `fnvalue$trampoline` forwarder (entry block, one
#     call, `ret` of its result) of a type the oracle dump defines no
#     trampoline for, whose counter the tree takes the address of.
#   with-fallible-enum-words: the #6730 identity above on top of the same
#     renaming (_tests_/cases/run_sql_row_find.bit, both #6730 and #6847).
#   functions (objFnSites, explainTestFunctions): the tree object is the oracle
#     object minus functions. Names compared with module id and counters
#     erased; every tree function has an oracle function of the same name and
#     poll-site count, at least one removed function is a `test` block, and
#     the removed functions hold exactly seed - self sites.
# Retire at the first repin after 0.36.0 (0.37.0 contains #6847).
#
# 6840-bce-window-guard (`iropt`). #6840 (optbce) drops the bounds checks a
# header `i + k < len(s)` proves; the 0.36.0 oracle keeps them. Files:
# _tests_/cases/run_while_index_bce_window.bit and
# _tests_/imports/cryptonistecavp/main.bit. Post-opt only; the pre-opt dumps
# agree. With %ids and bb ids erased, every line agrees in count except k more
# `icmp_ult bool %, %`, `br %, bb(), bb()`, `bb():`, `const_string "index out of
# range"`, `rt_call panic(%) void` and `unreachable` in the oracle and k fewer
# `jump bb()`, k > 0. Retires at the first repin after 0.36.0.
#
# 6982-error-path-nil (`ir`, `iropt`). #6982 returns nil instead of a freshly
# allocated zero box on a fallible function's error path (a boxed-enum ok
# value; `fail` and `?`). The 0.36.0 oracle allocates it. Files:
# _tests_/cases/jsonc_parse_comments, jsonc_parse_json5_rejected,
# jsonc_parse_trailing_comma, jsonc_parse_two_trailing_commas,
# run_errword_methods, run_forof_iterator_iface, run_json_decode_lenient,
# stdlib/jwt/jwt.bit and stdlib/quic/frames.bit. The identity (nilWalk in
# ir-signatures-walk.sh), walked under one %id bijection per
# function, every other line unchanged: the oracle holds, straight after
# `rt_call err_set(%e)`, `%a = gc_alloc size=16 ptrs=[..] T` (T a named type,
# not a string), up to two `const_int i64 0`, one `field_set %a[0]` and one
# `field_set %a[8]` of a zero `const_int i64 0` (any definition in the
# function), then `ret %a`; the tree holds `%b = const_nil`, `ret %b`. A box
# built after the `err_set(nil)` of a success return is not this shape.
# Retires at the first repin after 0.36.0.
#
# 7058-switch-case-range (`ir`) and 7058-switch-case-range-opt (`iropt`).
# #7058 lowers a switch case with two or more labels over one integer word (an
# integer prim or a tag-only enum) after lowering every label: hoisted, all
# `const_int` labels first and then the same compares and ors in the same
# order; or, when the constants are the integers [lo, hi], one `sub uT %S, lo`
# and `icmp_ule bool %off, width` (uT the unsigned prim of the subject's width,
# u64 for an enum; lo masked to it). Files: _tests_/cases/ir_switch_case_range,
# run_switch, run_switch_eq_agreement, run_switch_range and examples/switch/
# switch.bit. `ir`: rangeWalk, one %id bijection per function, every other
# line unchanged; the oracle chain is `%e1 = icmp_eq bool %S, %c1` then
# (`const_int T v`, `icmp_eq`, `bor`) per further label, then `br` of the last
# `bor`, all labels of one type T, and the tree is the hoisted form or the
# range form with lo = min, width = max - min, the values contiguous. `iropt`:
# no text identity holds (a constant subject folds the range test and the
# cascade rewires the CFG of main), so the identity is on functions
# (explainSwitchPostOpt): the pre-opt dumps of the file are explained by
# 7058-switch-case-range, and every function whose post-opt text differs has a
# pre-opt text that differs or transitively calls one that does. The post-opt
# text inside those functions is not independently verified; their behaviour
# is what _tests_/cases/run_switch*.bit and the examples differential run.
# Retires at the first repin after 0.36.0.
#
# The input protocol is the text the awk body reads: the oracle's dump, a line
# `@@@BIT2@@@`, then the tree's dump, with the kind and the corpus file as
# `-v` variables. A new entry must satisfy the rules in the header: an exact
# identity, derived from FULL dumps (the oracle's from `sh scripts/stage0.sh`,
# the tree's from `bit-out/bin/bit`), never an excerpt.
#
# shellcheck source=scripts/ir-signatures-walk.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/ir-signatures-walk.sh"

# explainMismatch <oracle_text> <bit2_text> <kind: ir|iropt|ast|fmt|types|diags|tokens> [file]
# Prints the name of the registered signature that explains the divergence
# and returns 0, or prints nothing and returns 1 if none does.
explainMismatch() {
  awk -v kind="$3" -v file="${4:-}" "${IR_WALK_AWK}"'
    # canonT -- rewrite every `$t<N>` of arr[1..n] to `$c<idx>` in first-
    # appearance order, the same canonicalization scripts/selfhost-ir-canon.sh
    # applies, so interning-order numbering never hides an identity.
    function canonT(arr, n,    i, line, out, tok, cnt, map) {
      cnt = 0
      for (i = 1; i <= n; i++) {
        line = arr[i]; out = ""
        while (match(line, /\$t[0-9]+/)) {
          tok = substr(line, RSTART, RLENGTH)
          if (!(tok in map)) { map[tok] = "$c" cnt++ }
          out = out substr(line, 1, RSTART - 1) map[tok]
          line = substr(line, RSTART + RLENGTH)
        }
        arr[i] = out line
      }
    }
    # canonK (#6847) -- rewrite every global interning counter of arr[1..n]
    # to its first-appearance index within its class and record the original
    # values in ids[side, key, idx]. A counter is a module id `m<N>$` (class
    # "m"), a `$<N>` suffix (class: the symbol stem before it, already
    # canonicalized -- closure, spawn$trampoline, bit$init, an instance name),
    # `__bitfnv_<N>` (class "fnv") or the method slot of
    # `call_iface %x.<N>(` (class "iface"). `$t<id>` belongs to canonT. A line
    # holding a string literal is left alone, so no literal is ever rewritten.
    function canonK(arr, n, side,    i, line, out, tok, key, v, c, idx, stem) {
      for (i = 1; i <= n; i++) {
        if (index(arr[i], "\"") > 0) { continue }
        line = arr[i]; out = ""
        while (match(line, /[$][0-9]+|m[0-9]+[$]|__bitfnv_[0-9]+|\.[0-9]+\(/)) {
          tok = substr(line, RSTART, RLENGTH)
          c = RSTART > 1 ? substr(line, RSTART - 1, 1) : substr(out, length(out), 1)
          out = out substr(line, 1, RSTART - 1)
          line = substr(line, RSTART + RLENGTH)
          key = ""
          if (tok ~ /^[$]/) { match(out, /[A-Za-z0-9_$#]*$/); key = "$" substr(out, RSTART); v = substr(tok, 2) }
          else if (tok ~ /^m/ && c !~ /[A-Za-z0-9_$]/) { key = "m"; v = substr(tok, 2, length(tok) - 2) }
          else if (tok ~ /^__bitfnv_/) { key = "fnv"; v = substr(tok, 10) }
          else if (tok ~ /^[.]/ && arr[i] ~ /= call_iface %[0-9]+[.][0-9]+[(]/) { key = "iface"; v = substr(tok, 2, length(tok) - 2) }
          if (key == "") { out = out tok; continue }
          if (!((side, key, v) in seen)) { seen[side, key, v] = cnt[side, key]++; ids[side, key, seen[side, key, v]] = v; keys[key] = 1 }
          idx = seen[side, key, v]
          if (tok ~ /^[$]/) { out = out "$#" idx }
          else if (tok ~ /^m/) { out = out "m#" idx "$" }
          else if (tok ~ /^__bitfnv_/) { out = out "__bitfnv_#" idx }
          else { out = out ".#" idx "(" }
        }
        arr[i] = out line
      }
    }
    # shiftOk -- the two sides name the same number of counters per class, so
    # the first-appearance rewrite above is a bijection between the oracle ids
    # and the tree ids. Removing the test files of a module renumbers whatever
    # was interned after them, and a different load order can swap two module
    # ids, so no ordering or direction is required of it. Sets `shifted` when
    # any id differs.
    function shiftOk(    key, k) {
      shifted = 0
      for (key in keys) {
        if ((cnt["A", key] + 0) != (cnt["B", key] + 0)) { return 0 }
        for (k = 0; k < cnt["A", key]; k++) {
          if (ids["A", key, k] != ids["B", key, k]) { shifted = 1 }
        }
      }
      return 1
    }
    # headKey -- a fnvalue trampoline header with its counter removed.
    function headKey(s) { sub(/^func fnvalue[$]trampoline[$][0-9]+/, "func fnvalue$trampoline", s); return s }
    # moveTramp (#6847) -- a function-value trampoline is one synthesized
    # function per function type, owned by whichever module lowers it first.
    # With the test files of an imported module gone the root module lowers it
    # first, so the tree dump gains a forwarder the oracle dump leaves to the
    # imported module. Drops from linesB each 5-line forwarder (header, entry
    # block, one call, `ret` of its result, `}`, and the blank line after it) whose counter the tree dump
    # takes the address of (`global_addr @__bitfnv_<id>`) and whose type the
    # oracle dump defines no trampoline for; sets `moved` when one went.
    function moveTramp(    i, k, n, id, defd, drop) {
      moved = 0
      for (i = 1; i <= nA; i++) { if (linesA[i] ~ /^func fnvalue[$]trampoline[$]/) { defd[headKey(linesA[i])] = 1 } }
      n = 0
      for (i = 1; i <= nB; i++) {
        drop = 0
        if (linesB[i] ~ /^func fnvalue[$]trampoline[$][0-9]+[(]/ && i + 4 <= nB && linesB[i + 4] == "}" && !(headKey(linesB[i]) in defd) \
            && linesB[i + 1] ~ /^bb0[(]/ && linesB[i + 2] ~ /^  %[0-9]+ = call @/ && linesB[i + 3] == "  ret " idOf(linesB[i + 2])) {
          id = linesB[i]; sub(/^func fnvalue[$]trampoline[$]/, "", id); sub(/[(].*$/, "", id)
          for (k = 1; k <= nB; k++) {
            if (linesB[k] ~ /^  %[0-9]+ = global_addr @__bitfnv_[0-9]+$/ && lastTok(linesB[k]) == "@__bitfnv_" id) { drop = 1; break }
          }
        }
        if (drop) { i += (i + 5 <= nB && linesB[i + 5] == "") ? 5 : 4; moved = 1; continue }
        linesBn[++n] = linesB[i]
      }
      split("", linesB)
      for (i = 1; i <= n; i++) { linesB[i] = linesBn[i] }
      nB = n
    }
    # bceWindow (#6840) -- a header testing `i + k < len(s)` proves the
    # bounds checks of `s[i]` .. `s[i + k]`, and optbce drops them in the
    # post-opt IR: each check is an `icmp_ult` branching to a block that
    # panics "index out of range", and the block that held the compare ends in
    # a `jump` instead. Counting every line with its %ids and bb ids erased,
    # the oracle holds exactly k more of each of the seven lines of a check
    # (`icmp_ult`, its `br`, the failing block header, `const_string`, `rt_call
    # panic`, `unreachable`) and k fewer `jump bb()`, k > 0, and every other
    # line agrees in count. Post-opt only: the pre-opt dump carries every check.
    function bceWindow(    i, l, key, d, k) {
      for (i = 1; i <= nA + nB; i++) {
        l = i <= nA ? linesA[i] : linesB[i - nA]
        if (index(l, "\"") == 0) { gsub(/%[0-9]+/, "%", l); gsub(/bb[0-9]+/, "bb", l) } else { sub(/^  %[0-9]+ = /, "  % = ", l) }
        d[l] += i <= nA ? 1 : -1
      }
      k = d["  % = icmp_ult bool %, %"] + 0
      if (k <= 0) { return 0 }
      for (key in d) {
        if (d[key] == 0) { continue }
        if (key == "  % = icmp_ult bool %, %" || key == "  br %, bb(), bb()" || key == "bb():" || key == "  % = const_string \"index out of range\"" \
            || key == "  % = rt_call panic(%) void" || key == "  unreachable") { if (d[key] != k) { return 0 }; continue }
        if (key == "  jump bb()") { if (d[key] != -k) { return 0 }; continue }
        return 0
      }
      return 1
    }
    function sameText(    i) {
      for (i = 1; i <= nA; i++) { if (linesA[i] != linesB[i]) { return 0 } }
      return 1
    }
    function idList(s, arr,    n) {
      n = 0
      while (match(s, /%[0-9]+/)) { arr[++n] = substr(s, RSTART, RLENGTH); s = substr(s, RSTART + RLENGTH) }
      return n
    }
    function skel(s) { gsub(/%[0-9]+/, "%", s); return s }
    # idOf -- the %id a line defines (`  %N = ...`), "" when it defines none.
    function idOf(s) { return match(s, /^  %[0-9]+ = /) ? substr(s, 3, RLENGTH - 5) : "" }
    function lastTok(s,    n, p) { n = split(s, p, " "); return p[n] }
    # same -- oracle line a and tree line b agree under the bijection M/R,
    # binding ids seen for the first time; binds nothing when it fails.
    function same(a, b,    n, xa, xb, k, tM, tR) {
      if (skel(a) != skel(b)) { return 0 }
      n = idList(a, xa); idList(b, xb)
      for (k = 1; k <= n; k++) {
        if (xa[k] in M) { if (M[xa[k]] != xb[k]) { return 0 } continue }
        if (xa[k] in tM) { if (tM[xa[k]] != xb[k]) { return 0 } continue }
        if (xb[k] in tR) { return 0 }
        if ((xb[k] in R) && (R[xb[k]] != "<new>" || fwdRead(xa[k]) != xb[k])) { return 0 }
        tM[xa[k]] = xb[k]; tR[xb[k]] = xa[k]
      }
      for (k in tM) { M[k] = tM[k]; R[tM[k]] = k }
      return 1
    }
    function reset() { split("", M); split("", R); split("", C2); split("", W); split("", WT); split("", D); split("", Z0); split("", Z8); pend = ""; boxes = 0 }
    # isBox -- `%h = gc_alloc size=16 ptrs=[..] T`, T given or any named type.
    function isBox(s, T) {
      if (s !~ /^  %[0-9]+ = gc_alloc size=16 ptrs=\[(%[0-9]+)?\] [A-Za-z_]/) { return 0 }
      return (T == "" || lastTok(s) == T) ? 1 : 0
    }
    # callHunk -- the call-site hunk at A[i], B[j]; the next j, or 0.
    function callHunk(i, j,    a, b, T, c, c2, w) {
      a = linesA[i]; b = linesB[j]
      if (a !~ /^  %[0-9]+ = call @/ || b !~ /^  %[0-9]+ = call @/ || lastTok(b) != "i64") { return 0 }
      T = lastTok(a)
      if (T == "i64" || j + 1 > nB) { return 0 }
      c = idOf(a); c2 = idOf(b); w = idOf(linesB[j + 1])
      if (c in M || c2 in R || w == "" || w in R) { return 0 }
      if (!same(substr(a, length(c) + 6, length(a) - length(c) - 5 - length(T)), substr(b, length(c2) + 6, length(b) - length(c2) - 8))) { return 0 }
      if (index(linesB[j + 1], "  " w " = call_word " c2 "[1] ") != 1) { return 0 }
      if (j + 2 <= nB && index(linesB[j + 2], " = call_word " c2 "[") > 0) { return 0 }
      R[c2] = "<new>"; R[w] = "<new>"; C2[c] = c2; W[c] = w; WT[c] = lastTok(linesB[j + 1])
      if (j + 4 <= nB && isBox(linesB[j + 2], T) && linesB[j + 3] == "  field_set " idOf(linesB[j + 2]) "[0] = " c2 && linesB[j + 4] == "  field_set " idOf(linesB[j + 2]) "[8] = " w) {
        M[c] = idOf(linesB[j + 2]); R[M[c]] = c
        return j + 5
      }
      M[c] = "<gone>"
      return j + 2
    }
    # readWord -- the tree word an oracle read `field_get %c[0] i64` or
    # `field_get %c[8] P` of a call-hunk handle %c stands for, else "".
    function readWord(s,    t, c) {
      if (!match(s, /^  %[0-9]+ = field_get %[0-9]+\[(0|8)\] /)) { return "" }
      t = idOf(s); c = substr(s, length(t) + 16); c = substr(c, 1, index(c, "[") - 1)
      if (!(c in C2)) { return "" }
      if (s == "  " t " = field_get " c "[0] i64") { return C2[c] }
      if (s == "  " t " = field_get " c "[8] " WT[c]) { return W[c] }
      return ""
    }
    # fwdRead -- readWord of the line defining oracle %x in this function,
    # for a use printed before its definition (a block laid out earlier).
    function fwdRead(x,    k) {
      for (k = fnStart; k <= nA; k++) {
        if (k > fnStart && linesA[k] ~ /^func /) { return "" }
        if (index(linesA[k], "  " x " = ") == 1) { return readWord(linesA[k]) }
      }
      return ""
    }
    # readDel -- oracle A[i] is a deleted read of a call-hunk handle.
    function readDel(s,    t, w) {
      w = readWord(s); t = idOf(s)
      if (w == "" || ((t in M) && M[t] != w)) { return 0 }
      M[t] = w
      return 1
    }
    # boxDel -- oracle A[i] is a deleted enum box or one of its two stores.
    function boxDel(s,    h, v) {
      if (isBox(s, "") && lastTok(s) !~ /^(string|\()/) {
        h = idOf(s)
        if (h in M) { return 0 }
        M[h] = "<deleted>"; D[h] = 1; boxes++
        return 1
      }
      if (!match(s, /^  field_set %[0-9]+\[(0|8)\] = %[0-9]+$/)) { return 0 }
      h = substr(s, 13); h = substr(h, 1, index(h, "[") - 1); v = lastTok(s)
      if (!(h in D)) { return 0 }
      if (index(s, "[0] = ") > 0 && !(h in Z0)) { Z0[h] = v; return 1 }
      if (index(s, "[8] = ") > 0 && !(h in Z8)) { Z8[h] = v; return 1 }
      return 0
    }
    # readIns -- tree B[j], B[j+1] read a returned box`s two words.
    function readIns(j,    x, r0, r1) {
      if (pend != "" || j + 1 > nB || !match(linesB[j], /^  %[0-9]+ = field_get %[0-9]+\[0\] i64$/)) { return 0 }
      r0 = idOf(linesB[j]); r1 = idOf(linesB[j + 1]); x = substr(linesB[j], length(r0) + 16)
      x = substr(x, 1, index(x, "[") - 1)
      if (!(x in R) || R[x] == "<new>" || r1 == "" || index(linesB[j + 1], "  " r1 " = field_get " x "[8] ") != 1) { return 0 }
      R[r0] = "<new>"; R[r1] = "<new>"; pend = x " " r0 " " r1
      return 1
    }
    # retHunk -- oracle `ret %h`, tree `ret %a, %b`.
    function retHunk(a, b,    h, p) {
      if (a !~ /^  ret %[0-9]+$/ || b !~ /^  ret %[0-9]+, %[0-9]+$/) { return 0 }
      h = substr(a, 7); split(substr(b, 7), p, ", ")
      if ((h in D) && (h in Z0) && (h in Z8)) {
        if (M[Z0[h]] != p[1] || M[Z8[h]] != p[2]) { return 0 }
        delete D[h]; boxes--
        return 1
      }
      if (pend == "" || pend != M[h] " " p[1] " " p[2]) { return 0 }
      pend = ""
      return 1
    }
    # enumWords (#6730) -- see the header above explainMismatch.
    function enumWords(    i, j, n, e) {
      i = 1; j = 1; n = 0; fnStart = 0; reset()
      while (i <= nA || j <= nB) {
        if (i <= nA && i != fnStart && linesA[i] ~ /^func /) {
          if (pend != "" || boxes != 0) { return 0 }
          reset(); fnStart = i
        }
        if (i <= nA && j <= nB && same(linesA[i], linesB[j])) { i++; j++; continue }
        if (i <= nA && j <= nB && (e = callHunk(i, j)) > 0) { i++; j = e; n++; continue }
        if (j <= nB && readIns(j)) { j += 2; continue }
        if (i <= nA && j <= nB && retHunk(linesA[i], linesB[j])) { i++; j++; n++; continue }
        if (i <= nA && (readDel(linesA[i]) || boxDel(linesA[i]))) { i++; continue }
        return 0
      }
      return (n > 0 && pend == "" && boxes == 0) ? 1 : 0
    }
    side == 0 && $0 == "@@@BIT2@@@" { side = 1; next }
    side == 0 { nA++; linesA[nA] = $0; next }
    { nB++; linesB[nB] = $0 }
    END {
      if (kind != "ir" && kind != "iropt") { exit 1 }
      canonT(linesA, nA); canonT(linesB, nB)
      if (enumWords()) {
        print "6730-fallible-enum-words"; exit 0
      }
      if (kind == "iropt" && bceWindow()) {
        print "6840-bce-window-guard"; exit 0
      }
      ptrsLit()
      if (nilWalk()) { print "6982-error-path-nil"; exit 0 }
      if (kind == "ir" && rangeWalk()) { print "7058-switch-case-range"; exit 0 }
      moveTramp()
      canonK(linesA, nA, "A"); canonK(linesB, nB, "B")
      if (!shiftOk()) { exit 1 }
      if ((shifted || moved) && nA == nB && sameText()) {
        print "6847-test-module-counters"; exit 0
      }
      if ((shifted || moved) && enumWords()) {
        print "6847-test-module-counters-with-fallible-enum-words"; exit 0
      }
      exit 1
    }
  ' <(printf '%s\n@@@BIT2@@@\n%s\n' "$1" "$2")
}

# objFnSites <object> -- one line per text function, "<name> <bit_rt_safepoint
# call sites inside it>", then "@@total <sites>" and "@@other <sites outside
# any text function>" (#6847). A site belongs to the
# function whose symbol is the last one at or below its relocation offset; the
# leading `_` of a Mach-O symbol is dropped so both object formats print the
# same name. The total is what `objdump -r | grep -c bit_rt_safepoint` counts;
# a few sites sit outside the text section (a data table naming the poll).
objFnSites() {
  awk '
    function hex(s,    i, v) { v = 0; for (i = 1; i <= length(s); i++) { v = v * 16 + index("0123456789abcdef", tolower(substr(s, i, 1))) - 1 } return v }
    FNR == NR { if ($2 == "T" || $2 == "t") { n++; ad[n] = hex($1); nm[n] = $3; sub(/^_/, "", nm[n]) } next }
    /RELOCATION RECORDS FOR/ { intext = ($0 ~ /\[(__text|\.text)\]/); next }
    /bit_rt_safepoint/ { tot++ }
    intext && /bit_rt_safepoint/ {
      o = hex($1); lo = 1; hi = n
      while (lo < hi) { mid = int((lo + hi + 1) / 2); if (ad[mid] <= o) { lo = mid } else { hi = mid - 1 } }
      cnt[lo]++; txt++
    }
    END { for (i = 1; i <= n; i++) { print nm[i], cnt[i] + 0 } print "@@total", tot + 0; print "@@other", tot - txt }
  ' <(nm -n "$1" 2>/dev/null) <(objdump -r "$1" 2>/dev/null)
}

# explainTestFunctions <oracle_sites> <tree_sites> <seed> <self> -- the
# 6847-test-module-functions signature over two objFnSites listings. Prints
# its name and returns 0 when the tree object is the oracle object with
# functions removed and nothing else changed; else prints nothing, returns 1.
# #6847 stops compiling the test files of an imported std/ or package module,
# so the oracle object (0.36.0, which does) carries `test` blocks, their
# helpers and whatever only they reach, each with its own poll sites. Names
# are compared with the module id (`m<N>$`) and every `$<N>`/`$t<N>` counter
# erased. The identity: the listings total seed and self and agree on the
# sites outside the text section; every tree function
# has an oracle function of the same name and the same site count (a missing
# or extra poll in a kept function breaks it); at least one removed function
# is a `test` block (`m$test$#`), so the removal is the test files and not
# some other dead code; the sites of the removed functions add up to
# seed - self, which must be positive.
explainTestFunctions() {
  awk -v seed="$3" -v self="$4" '
    function norm(s) { sub(/^m[0-9]+[$]/, "m$", s); gsub(/[$]t?[0-9]+/, "$#", s); return s }
    FNR == 1 { fi++ }
    /^@@total/ { tot[fi] = $2; next }
    /^@@other/ { oth[fi] = $2; next }
    { k = norm($1) " " $2; if (fi == 1) { o[k]++ } else { t[k]++ } }
    END {
      if (tot[1] != seed || tot[2] != self || self >= seed || oth[1] != oth[2]) { exit 1 }
      for (k in t) { if (t[k] > o[k]) { exit 1 } }
      for (k in o) {
        if (o[k] == t[k]) { continue }
        split(k, p, " "); gone += (o[k] - t[k]) * p[2]
        if (p[1] == "m$test$#") { hasTest = 1 }
      }
      if (!hasTest || gone != seed - self) { exit 1 }
      print "6847-test-module-functions"; exit 0
    }
  ' <(printf '%s\n' "$1") <(printf '%s\n' "$2")
}

# declaredSignatureNames [ir|iropt|safepoints|ast|fmt|types|diags] -- every name explainMismatch
# CAN print for the given dump kind, one per line (#5509, extended by #5510).
# The single source of truth for the retirement check in
# scripts/selfhost-diffdump.sh's run_ir()/run_types(): a signature this
# function does not list can never be checked for going dead, and one it lists
# that explainMismatch no longer prints would make that check fail on every
# run. Kept in sync by hand, and selfhost-ir-signatures-selfcheck.sh asserts
# the list matches the `print "..."` statements in this file.
declaredSignatureNames() {
  local kind=${1:-}
  case "$kind" in
    ast|fmt|tokens|diags|types) return ;;
    ir) printf '%s\n' "6730-fallible-enum-words" "6847-test-module-counters" "6847-test-module-counters-with-fallible-enum-words" "6982-error-path-nil" "7058-switch-case-range"; return ;;
    iropt) printf '%s\n' "6730-fallible-enum-words" "6847-test-module-counters" "6847-test-module-counters-with-fallible-enum-words" "6840-bce-window-guard" "6982-error-path-nil" "7058-switch-case-range-opt"; return ;;
    safepoints) printf '%s\n' "6847-test-module-functions"; return ;;
  esac
  printf '%s\n' "6730-fallible-enum-words" "6847-test-module-counters" "6847-test-module-counters-with-fallible-enum-words" "6840-bce-window-guard" "6847-test-module-functions" "6982-error-path-nil" "7058-switch-case-range" "7058-switch-case-range-opt"
}
