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
# --- Declared signatures (each retires at the repin that brings the fix in) ---
#
# 6679-generic-join-param-retype (`ir`, `iropt`). The merge of #6679 ("lower:
# scope a body's checker rebinds to that body") fixed a generic instance's
# `match` join block param being typed from the PREVIOUS instance. The pinned
# 0.35.0 oracle still has the bug (`pick<Node>` gets `bb3(%8: Node, %9: i64)`)
# and refuses to build generic_option_containers.bit and
# generic_option_string_field.bit. The files affected are
# _tests_/cases/ir_generic_match_join_type.bit,
# _tests_/cases/generic_option_containers.bit and
# _tests_/cases/generic_option_string_field.bit. The identity: same line
# count, and every differing line pair is a block header `bbN(...)` on both
# sides with the same label and the same %id list in the same order, so only
# the param TYPES differ. Retires at the first repin to a release containing
# #6679.
#
# 6570-fail-zero-decimal-box (`ir`, `iropt`). The merge of #6570 added
# `zeroDecimal` (compiler/lowerslicefill.bit), which materializes the §13.4
# decimal zero as a real 16-byte box; a `decimal!` function's failing-path
# return uses it, where the 0.35.0 oracle returns `const_int decimal 0`. The
# files affected are _tests_/cases/decimal_fallible_return.bit and
# stdlib/decimal/decimal.bit. The identity, on text with every %id erased:
# each oracle line `const_int decimal 0` is replaced by 0, 1 or 2 lines
# `const_int i64 0`, then `gc_alloc size=16 ptrs=[] (i64, i64)` and the two
# `field_set` of offsets 0 and 8 on that allocation; every other line is equal.
# Retires at the first repin to a release containing #6570.
#
# 6564-arrow-ctor-seeded (`types`, `ir`, `iropt`). The merge of #6564 makes the
# checker seed an arrow argument's expected type from a class `init`'s
# parameters. The 0.35.0 oracle types those arrow params `<error>`/`<invalid>`
# and then lowers the `([]byte) => ()!` argument as a non-fallible
# `fn(<invalid>) void` closure with no `err_set` (a latent 0.35.0
# miscompile). The files affected are _tests_/cases/run_arrow_arg_ctor_init.bit
# (`types` only), _tests_/imports/http2e2e/main.bit,
# _tests_/imports/httpgracefulh2/main.bit and
# _tests_/imports/httpgracefultls/main.bit. `types` identity: same line
# count; every differing pair shares its `LINE:COL: name` prefix, the oracle
# type is exactly `<error>` and the tree type is not; at least one pair. `ir`
# identity (SSA ids unchanged): every oracle-side differing line contains
# `<invalid>` and its tree line equals it with each `<invalid>` replaced by one
# concrete type token, `void!error` read as `void`; the only tree-only lines
# are one `const_nil` plus `rt_call err_set` of it inside a closure whose tree
# signature ends `void!error` and whose oracle signature ends `void`. Retires
# at the first repin to a release containing #6564.
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
    function isHeader(s) { return (s ~ /^bb[0-9]+\(.*\):$/) ? 1 : 0 }
    # hdrKey -- a block header with its param types dropped: the label, then
    # every %id in order.
    function hdrKey(s,    k) {
      k = substr(s, 1, index(s, "("))
      while (match(s, /%[0-9]+/)) { k = k substr(s, RSTART, RLENGTH) ","; s = substr(s, RSTART + RLENGTH) }
      return k
    }
    # joinParamRetype (#6679) -- see the header above explainMismatch.
    function joinParamRetype(nA, linesA, nB, linesB,    i, n) {
      if (nA != nB) { return 0 }
      n = 0
      for (i = 1; i <= nA; i++) {
        if (linesA[i] == linesB[i]) { continue }
        if (!isHeader(linesA[i]) || !isHeader(linesB[i])) { return 0 }
        if (hdrKey(linesA[i]) != hdrKey(linesB[i])) { return 0 }
        n++
      }
      return (n > 0) ? 1 : 0
    }
    function erased(s) { gsub(/%[0-9]+/, "%_", s); return s }
    # idOf -- the %id a line defines (`  %N = ...`), "" when it defines none.
    function idOf(s) { return match(s, /^  %[0-9]+ = /) ? substr(s, 3, RLENGTH - 5) : "" }
    # boxHunk -- tree lines B[j..] are 0-2 `const_int i64 0`, a 16-byte
    # gc_alloc and the two field_set of offsets 0 and 8 on that allocation.
    # Returns the index after the hunk, 0 when it is not one.
    function boxHunk(nB, linesB, j,    c, id) {
      for (c = 0; c < 2 && j <= nB && erased(linesB[j]) == "  %_ = const_int i64 0"; c++) { j++ }
      if (j + 2 > nB || erased(linesB[j]) != "  %_ = gc_alloc size=16 ptrs=[] (i64, i64)") { return 0 }
      id = idOf(linesB[j])
      if (index(linesB[j + 1], "  field_set " id "[0] = ") != 1) { return 0 }
      if (index(linesB[j + 2], "  field_set " id "[8] = ") != 1) { return 0 }
      return j + 3
    }
    # decimalZeroBox (#6570) -- see the header above explainMismatch.
    function decimalZeroBox(nA, linesA, nB, linesB,    i, j, hunks, e) {
      i = 1; j = 1; hunks = 0
      while (i <= nA && j <= nB) {
        if (erased(linesA[i]) == erased(linesB[j])) { i++; j++; continue }
        if (erased(linesA[i]) != "  %_ = const_int decimal 0") { return 0 }
        e = boxHunk(nB, linesB, j)
        if (e == 0) { return 0 }
        i++; j = e; hunks++
      }
      return (i > nA && j > nB && hunks > 0) ? 1 : 0
    }
    function lastColonSpace(s,    i, n, found) {
      found = 0
      n = length(s) - 1
      for (i = 1; i <= n; i++) {
        if (substr(s, i, 2) == ": ") { found = i }
      }
      return found
    }
    # arrowTypeSeeded (#6564, `types`) -- see the header above explainMismatch.
    function arrowTypeSeeded(nA, linesA, nB, linesB,    i, n, cA, cB, tyB) {
      if (nA != nB) { return 0 }
      n = 0
      for (i = 1; i <= nA; i++) {
        if (linesA[i] == linesB[i]) { continue }
        cA = lastColonSpace(linesA[i]); cB = lastColonSpace(linesB[i])
        if (cA == 0 || cB == 0 || substr(linesA[i], 1, cA) != substr(linesB[i], 1, cB)) { return 0 }
        tyB = substr(linesB[i], cB + 2)
        if (substr(linesA[i], cA + 2) != "<error>" || tyB == "" || index(tyB, "<error>") > 0) { return 0 }
        n++
      }
      return (n > 0) ? 1 : 0
    }
    # invalidFilled -- tree line b is oracle line a with each `<invalid>`
    # replaced by one concrete type token (no space, comma or paren), after
    # `void!error` is read as `void`.
    function invalidFilled(a, b,    np, parts, k, pos, nx, gap) {
      gsub(/void!error/, "void", b)
      np = split(a, parts, "<invalid>")
      if (np < 2 || substr(b, 1, length(parts[1])) != parts[1]) { return 0 }
      pos = length(parts[1]) + 1
      for (k = 2; k <= np; k++) {
        if (k == np) {
          nx = length(b) - length(parts[k]) + 1
          if (nx <= pos || substr(b, nx) != parts[k]) { return 0 }
        } else {
          nx = index(substr(b, pos + 1), parts[k])
          if (nx == 0) { return 0 }
          nx += pos
        }
        gap = substr(b, pos, nx - pos)
        if (gap !~ /^[^ ,()]+$/) { return 0 }
        pos = nx + length(parts[k])
      }
      return 1
    }
    # errSetPair -- tree lines B[j], B[j+1] are `const_nil` and the `err_set`
    # call on that value.
    function errSetPair(nB, linesB, j,    id) {
      if (j + 1 > nB) { return 0 }
      id = idOf(linesB[j])
      if (id == "" || linesB[j] != "  " id " = const_nil") { return 0 }
      return (linesB[j + 1] ~ /^  %[0-9]+ = rt_call err_set\(/ && index(linesB[j + 1], "err_set(" id ") void") > 0) ? 1 : 0
    }
    # arrowIrSeeded (#6564, `ir`/`iropt`) -- see the header above
    # explainMismatch. errOk is 1 inside a closure whose signature gained
    # `!error` and that has not yet received its one err_set pair.
    function arrowIrSeeded(nA, linesA, nB, linesB,    i, j, n, errOk) {
      i = 1; j = 1; n = 0; errOk = 0
      while (i <= nA || j <= nB) {
        if (i <= nA && j <= nB && linesA[i] == linesB[j]) {
          if (linesA[i] ~ /^func /) { errOk = 0 }
          i++; j++; continue
        }
        if (errOk && j <= nB && errSetPair(nB, linesB, j)) { errOk = 0; j += 2; continue }
        if (i > nA || j > nB || index(linesA[i], "<invalid>") == 0 || !invalidFilled(linesA[i], linesB[j])) { return 0 }
        if (linesA[i] ~ /^func / && linesA[i] ~ / void [{]$/ && linesB[j] ~ / void!error [{]$/) { errOk = 1 }
        i++; j++; n++
      }
      return (n > 0) ? 1 : 0
    }
    side == 0 && $0 == "@@@BIT2@@@" { side = 1; next }
    side == 0 { nA++; linesA[nA] = $0; next }
    { nB++; linesB[nB] = $0 }
    END {
      if (kind == "types" && arrowTypeSeeded(nA, linesA, nB, linesB)) {
        print "6564-arrow-ctor-seeded"; exit 0
      }
      if (kind != "ir" && kind != "iropt") { exit 1 }
      canonT(linesA, nA); canonT(linesB, nB)
      if (joinParamRetype(nA, linesA, nB, linesB)) {
        print "6679-generic-join-param-retype"; exit 0
      }
      if (decimalZeroBox(nA, linesA, nB, linesB)) {
        print "6570-fail-zero-decimal-box"; exit 0
      }
      if (arrowIrSeeded(nA, linesA, nB, linesB)) {
        print "6564-arrow-ctor-seeded"; exit 0
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
# the list matches the `print "..."` statements in this file (with the kind
# argument omitted there: "does this name exist at all").
declaredSignatureNames() {
  local kind=${1:-}
  case "$kind" in
    ast|fmt|tokens|diags) return ;;
    ir|iropt) printf '%s\n' "6564-arrow-ctor-seeded" "6570-fail-zero-decimal-box" "6679-generic-join-param-retype"; return ;;
    types) printf '%s\n' "6564-arrow-ctor-seeded"; return ;;
  esac
  [ -n "$kind" ] || printf '%s\n' "6564-arrow-ctor-seeded" "6570-fail-zero-decimal-box" "6679-generic-join-param-retype"
}
