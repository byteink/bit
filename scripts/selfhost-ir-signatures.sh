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
# The input protocol is the text the awk body reads: the oracle's dump, a line
# `@@@BIT2@@@`, then the tree's dump, with the kind and the corpus file as
# `-v` variables. A new entry must satisfy the rules in the header: an exact
# identity, derived from FULL dumps (the oracle's from `sh scripts/stage0.sh`,
# the tree's from `bit-out/bin/bit`), never an excerpt.
#
# explainMismatch <oracle_text> <bit2_text> <kind: ir|iropt|ast|fmt|types|diags|tokens> [file]
# Prints the name of the registered signature that explains the divergence
# and returns 0, or prints nothing and returns 1 if none does.
explainMismatch() {
  awk -v kind="$3" -v file="${4:-}" '
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
      exit 1
    }
  ' <(printf '%s\n@@@BIT2@@@\n%s\n' "$1" "$2")
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
  local kind=${1:-}
  case "$kind" in
    ast|fmt|tokens|diags|types) return ;;
    ir|iropt) printf '%s\n' "6730-fallible-enum-words"; return ;;
  esac
  [ -n "$kind" ] || printf '%s\n' "6730-fallible-enum-words"
}
