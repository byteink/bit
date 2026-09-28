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
# #6194 (46b6d13eb, "Fix foreignTypeDeclParam to scan every module, not just
# the caller's own") landed AFTER the 0.32.0 pin above, so the pinned oracle
# still carries the pre-fix bug on the one corpus file it touches
# (_tests_/cases/run_generic_method_receiver_explode.bit, added by #6194
# itself to pin the corrected shape): a generic method's `Option<T>` result
# read through its receiver stays unsubstituted in the oracle (`--dump-types`
# reports the bare `Option`; `--dump-ir-pre`/`--dump-ir` keep it boxed, one
# heap object read by `field_get`), while this tree substitutes it to
# `Option<Person>` and explodes the payload to words at every call/return
# site that consumes it. Two signatures declared below:
# `6194-generic-method-receiver-unsubstituted-type` (`types`, the
# `optionUnsubstitutedType` line-for-line identity, same shape as #5921's
# `ptrofStringType`) and `6194-generic-method-receiver-explode` (`ir`/
# `iropt`, an opcode-count-delta identity on `field_get`/`gc_alloc` only,
# same shape as #5871). EXPECTED TO RETIRE AT THE 0.33.0 REPIN: 0.33.0 will
# contain #6194, so it will be the first oracle that agrees with the tree on
# this file, and both signatures will explain zero files that run — the
# automated RETIRED check below (declaredSignatureNames) is what catches
# that, the same way it caught #5921/the eight 0.27.0-era signatures.
#
# #6161 (668088908, "jsonSchema<T>() for classes, enums, optionals, nested
# and generic types") landed on the same tree, AFTER the 0.32.0 pin, and
# reddened `types`/`ir`/`iropt` on 8 corpus files the pinned oracle predates
# (#6208). ROOT CAUSE (compiler/synthtext.bit): a synthesized member's
# identifier text is never spelled by any real source span, so it is
# APPENDED to the module's own source once and given a span pointing into
# that appended tail (`appendSynthText`) — every earlier synthesis in the
# SAME module pushes every later one's tail position further out. #6161
# added a new synthesis (the schema/decode-enum machinery) that runs ahead
# of the pre-existing `Json.decode<T>()` helper-name synthesis in 4 files,
# so those files' `__json_x*`/`__json_d*` helper spans all land at a
# CONSTANT +32 columns versus the pinned oracle — same line, same name, same
# inferred type, only the column moved. Three signatures declared below:
#
# `6161-json-decode-column-shift` (`types`) — the constant-column-delta
# identity: every mismatched line pair shares its line number and its
# `<name>: <type>` suffix, and `bit2's column - oracle's column` is the SAME
# nonzero constant for every mismatched line in the file. Derived from and
# checked against the real dumps of _tests_/cases/run_json_decode.bit,
# run_json_decode_errors.bit, run_json_decode_generic.bit and
# run_json_decode_lenient.bit (captured 2026-09-28, ticket #6208): all four
# shift by exactly +32 columns, every other field byte-identical.
#
# `6161-json-schema-synthesized-insert` (`types`) — #6161's SECOND `types`
# shape, on run_json_schema.bit and run_json_schema_attrs.bit: the new
# schema synthesis type-checks real, NEW AST nodes (a monomorphized schema
# builder, anchored at the class's own field declarations) that the
# pre-#6161 oracle never visited at all, so there is no shared column to
# shift — the oracle's dump is instead an exact ORDERED SUBSEQUENCE of the
# tree's (every line the oracle prints still appears, in the same order,
# byte-for-byte, in the tree's dump; the tree only ever ADDS lines, never
# alters or drops one). That is checked as an exact identity, not eyeballed:
# a single greedy subsequence match, which is correct here because we only
# need EXISTENCE of oracle-as-subsequence, not an alignment. WHY THIS IS NOT
# A MASK: any regression that corrupts, reorders or drops so much as one
# line the oracle already reports fails the
# subsequence check immediately and is scored a real MISMATCH — only a
# divergence whose ENTIRE effect is new lines, disturbing nothing the oracle
# already agrees on, is ever explained, which is the tightest bound
# available for content the oracle has no opinion on at all (the class
# fields/schema body #6161 newly synthesizes did not exist for oracle
# purposes before this feature). Same posture as `6194-generic-method-
# receiver-explode`'s opcode-count bound below: the NEW content's shape is
# bounded structurally, not validated byte-for-byte, because there is
# nothing on the oracle side to validate it against.
#
# `6161-json-decode-enum-error-resolved` (`types`) — #6161's THIRD `types`
# shape, on run_json_decode_enum.bit alone: this fixture exercises #6177's
# payload-free `enum` field decode (`jsonDecode<Item>(j)` where `Item` has a
# `Status` enum field), which the pre-#6161 oracle cannot type-check at all
# — every downstream use of that decode result is `<error>` in the oracle
# and a real type in the tree — PLUS the same leading/trailing pure-insert
# shape `6161-json-schema-synthesized-insert` explains elsewhere. Checked as
# a two-pointer walk over both dumps: a byte-identical line advances both
# sides; a line pair sharing the same `LINE:COL: <expr>` prefix where the
# oracle's type is literally `<error>` and the tree's is a real, non-empty
# type advances both sides and counts as a resolution; anything else is
# treated as a pure insertion on the tree side only. Explained only when
# EVERY oracle line is eventually consumed this way AND at least one real
# `<error>`-resolution occurred — a REAL regression (an already-well-typed
# oracle expression changing to a DIFFERENT concrete type, or degrading to
# `<error>`) can never satisfy the resolution shape and fails the walk
# (the oracle pointer never catches up), same fail-closed posture as
# `6161-json-schema-synthesized-insert` above.
#
# `6161-json-schema-specialize-call` (`ir`/`iropt`) — on
# run_json_schema_attrs.bit, jsonschemacrossmod/main.bit and
# jsonschemanested/main.bit: the oracle still lowers `jsonSchema<Widget>()`
# to a generic call (`@m3$jsonSchema$14()`), while this tree specializes it
# per type argument (`@__json_schema_Widget()`, `@m4$__json_schema_Widget()`
# depending which module owns it). Checked as an identity: EXACTLY one
# `  %N = call @<callee>() <Type>` line may change, and only by renaming an
# oracle callee matching `(m<N>$)?jsonSchema$<N>` to a tree callee matching
# `(m<N>$)?__json_schema_<Ident>` with the same `<Type>`; when the
# specialization is DEFINED in the dumped file (run_json_schema_attrs.bit),
# the tree may ALSO insert exactly one new function directly — `func
# __json_schema_<Ident>(...) ... {` through a matching top-level `}`, naming
# the SAME `<Ident>` the call was renamed to, with no second `func ` line or
# premature `}` inside it — with every other line on both sides identical
# before and after that insertion point. Not opcode-content-validated for
# the same reason `6161-json-schema-synthesized-insert` above is not: the
# oracle has no opinion on a function it never lowers. Derived from and
# checked against the real dumps of all three files (captured 2026-09-28,
# ticket #6208; jsonschemacrossmod/main.bit and jsonschemanested/main.bit
# have no insertion at all, run_json_schema_attrs.bit inserts the full
# specialized function body). Declared once for both `ir` and `iropt`, same
# convention as `6194-generic-method-receiver-explode`: the inserted
# function's exact opcode count differs pre/post-opt, but its boundary shape
# does not.
#
# EXPECTED TO RETIRE AT THE 0.33.0 REPIN, same reasoning as #6194 above:
# 0.33.0 will contain #6161, so it will be the first oracle that agrees with
# the tree on all 8 of these files, and all three signatures will explain
# zero files that run.
#
# explainMismatch <oracle_text> <bit2_text> <kind: ir|iropt|ast|fmt|types>
# Prints the name of the registered signature that explains the divergence
# and returns 0, or prints nothing and returns 1 if none does. Each call
# forks one fresh awk process, so all state below is per-call — no cross-file
# leakage between corpus files. `ast`/`fmt` compare TEXT (an S-expression
# dump / formatted source), not IR opcodes; `types` compares `--dump-types`
# TEXT line-for-line (optionUnsubstitutedType, #6194); `ir`/`iropt` compare
# opcode COUNT deltas (the same #6194 identity, kind-gated). No signature is
# currently declared for `ast`/`fmt` (see Retirement history above).
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
    # optionUnsubstitutedType (#6194) -- same shape as #5921s ptrofStringType:
    # `--dump-types` output is `LINE:COL: <expr>: <type>` per line, one line
    # per typed node, same LINE COUNT on both sides (never reflows). A line is
    # accepted only when its prefix (everything before the LAST ": ") is
    # byte-identical on both sides and the oracles trailing type is exactly
    # the bare `Option` while the trees is `Option<X>` for a single bare
    # identifier X -- ANY other kind of difference on ANY line rejects the
    # whole file. At least one accepted lines prefix must contain the literal
    # `Option<T>.` substring (the unsubstituted generic-method-receiver call
    # syntax #6194 fixed) -- gates this to the exact defect shape, not any
    # `Option`-typed expression that happens to gain a type argument.
    function optionUnsubstitutedType(nA, linesA, nB, linesB,    i, la, lb, cutA, cutB, pfxA, pfxB, tyA, tyB, diffCount, sawCall) {
      if (nA != nB || nA == 0) { return 0 }
      diffCount = 0
      sawCall = 0
      for (i = 1; i <= nA; i++) {
        la = linesA[i]; lb = linesB[i]
        if (la == lb) { continue }
        diffCount++
        cutA = lastColonSpace(la)
        cutB = lastColonSpace(lb)
        if (cutA == 0 || cutB == 0) { return 0 }
        pfxA = substr(la, 1, cutA - 1)
        tyA = substr(la, cutA + 2)
        pfxB = substr(lb, 1, cutB - 1)
        tyB = substr(lb, cutB + 2)
        if (pfxA != pfxB) { return 0 }
        if (tyA != "Option") { return 0 }
        if (tyB !~ /^Option<[A-Za-z_][A-Za-z0-9_]*>$/) { return 0 }
        if (index(pfxA, "Option<T>.") > 0) { sawCall = 1 }
      }
      if (diffCount == 0 || sawCall == 0) { return 0 }
      return 1
    }
    # splitLineCol -- parses a `--dump-types` line `LINE:COL: <rest>` into
    # out[1]=LINE out[2]=COL out[3]=<rest>. Returns 0 (out left untouched) if
    # the line is not in that shape.
    function splitLineCol(line, out,    p, parts) {
      if (!match(line, /^[0-9]+:[0-9]+: /)) { return 0 }
      p = substr(line, 1, RLENGTH - 2)
      split(p, parts, ":")
      out[1] = parts[1] + 0
      out[2] = parts[2] + 0
      out[3] = substr(line, RLENGTH + 1)
      return 1
    }
    # columnShiftType (#6161) -- see this files header for the derivation
    # (constant appended-synth-text offset, compiler/synthtext.bit). Same
    # LINE COUNT both sides; every mismatched line pair shares its line
    # number and its `<name>: <type>` suffix, and `colB - colA` is the same
    # nonzero constant across every mismatched line in the file.
    function columnShiftType(nA, linesA, nB, linesB,    i, la, lb, oa, ob, delta, d, diffCount, hasDelta) {
      if (nA != nB || nA == 0) { return 0 }
      diffCount = 0
      hasDelta = 0
      delta = 0
      for (i = 1; i <= nA; i++) {
        la = linesA[i]; lb = linesB[i]
        if (la == lb) { continue }
        diffCount++
        if (!splitLineCol(la, oa)) { return 0 }
        if (!splitLineCol(lb, ob)) { return 0 }
        if (oa[1] != ob[1]) { return 0 }
        if (oa[3] != ob[3]) { return 0 }
        d = ob[2] - oa[2]
        if (d == 0) { return 0 }
        if (!hasDelta) { delta = d; hasDelta = 1 } else if (d != delta) { return 0 }
      }
      if (diffCount == 0) { return 0 }
      return 1
    }
    # orderedSubsequenceInsert (#6161) -- see this files header above for the
    # derivation and the WHY THIS IS NOT A MASK note. True only when every
    # oracle line still appears, in order, byte-for-byte, somewhere in the
    # trees dump (a pure insertion, never an alteration or a drop) and the
    # trees dump is strictly longer. A single greedy left-to-right scan is
    # a correct subsequence test here -- we only need EXISTENCE, not the
    # cheapest alignment.
    function orderedSubsequenceInsert(nA, linesA, nB, linesB,    i, j) {
      if (nA == 0 || nB <= nA) { return 0 }
      i = 1
      for (j = 1; j <= nB; j++) {
        if (i > nA) { break }
        if (linesB[j] == linesA[i]) { i++ }
      }
      return (i > nA) ? 1 : 0
    }
    # errorResolvedPair -- true when `a` (oracle) and `b` (tree) share the
    # same `LINE:COL: <expr>` prefix (everything before the LAST `: `), the
    # oracles trailing type is literally `<error>`, and the trees is a
    # non-empty, non-`<error>` type. A REAL regression -- a well-typed oracle
    # expression turning into a DIFFERENT concrete type, or into `<error>` --
    # is never accepted here, only the one direction #6161 legitimately
    # produces (the oracle could not type this expression at all; the tree
    # now can).
    function errorResolvedPair(a, b,    cutA, cutB, pfxA, pfxB, tyA, tyB) {
      cutA = lastColonSpace(a); cutB = lastColonSpace(b)
      if (cutA == 0 || cutB == 0) { return 0 }
      pfxA = substr(a, 1, cutA - 1); tyA = substr(a, cutA + 2)
      pfxB = substr(b, 1, cutB - 1); tyB = substr(b, cutB + 2)
      if (pfxA != pfxB) { return 0 }
      if (tyA != "<error>") { return 0 }
      if (tyB == "" || tyB == "<error>") { return 0 }
      return 1
    }
    # errorResolvedInsert (#6161) -- run_json_decode_enum.bit shape: the
    # oracle predates #6161/#6177s payload-free enum decode entirely, so it
    # cannot type `jsonDecode<Item>(j)` at all (every use of the result is
    # `<error>`), while the tree resolves it and every downstream use. A
    # left-to-right two-pointer walk: a matching line advances both sides; an
    # errorResolvedPair advances both sides and counts as a resolution; any
    # other tree line is treated as a pure insertion (advances only the tree
    # side). Explained only when EVERY oracle line is eventually consumed
    # this way (a real drop or reorder of an oracle line fails closed, since
    # the oracle pointer never catches up) and at least one real
    # `<error>`-resolution occurred (a pure insertion with zero resolutions
    # is `6161-json-schema-synthesized-insert`s shape, not this ones).
    function errorResolvedInsert(nA, linesA, nB, linesB,    i, j, subCount) {
      i = 1; j = 1; subCount = 0
      while (i <= nA && j <= nB) {
        if (linesA[i] == linesB[j]) { i++; j++; continue }
        if (errorResolvedPair(linesA[i], linesB[j])) { subCount++; i++; j++; continue }
        j++
      }
      if (i <= nA) { return 0 }
      if (subCount == 0) { return 0 }
      return 1
    }
    # isSchemaCallRename (#6161) -- true when `a` (oracle) is
    # `  %N = call @(m<N>$)?jsonSchema$<N>() <Type>` and `b` (tree) is the
    # SAME `%N = call @` prefix and the SAME trailing `<Type>`, renaming only
    # the callee to `(m<N>$)?__json_schema_<Ident>`. Sets the global
    # `jsonSchemaRenameIdent` to `<Ident>` on success.
    function isSchemaCallRename(a, b,    pa, pb, ra, rb, ca, cb, calleeA, calleeB, tyA, tyB, idx) {
      if (a !~ /^  %[0-9]+ = call @/) { return 0 }
      if (b !~ /^  %[0-9]+ = call @/) { return 0 }
      pa = index(a, "@"); pb = index(b, "@")
      if (substr(a, 1, pa) != substr(b, 1, pb)) { return 0 }
      ra = substr(a, pa + 1)
      rb = substr(b, pb + 1)
      ca = index(ra, "("); cb = index(rb, "(")
      if (ca == 0 || cb == 0) { return 0 }
      calleeA = substr(ra, 1, ca - 1)
      calleeB = substr(rb, 1, cb - 1)
      tyA = substr(ra, ca + 3)
      tyB = substr(rb, cb + 3)
      if (tyA != tyB) { return 0 }
      if (calleeA !~ /^(m[0-9]+\$)?jsonSchema\$[0-9]+$/) { return 0 }
      if (calleeB !~ /^(m[0-9]+\$)?__json_schema_[A-Za-z_][A-Za-z0-9_]*$/) { return 0 }
      idx = index(calleeB, "__json_schema_")
      jsonSchemaRenameIdent = substr(calleeB, idx + length("__json_schema_"))
      return 1
    }
    # schemaForwardWalk -- walks linesA/linesB INDEX-ALIGNED (position i on
    # both sides) for as long as that alignment can possibly still be valid:
    # a byte-identical line, or the one call-rename isSchemaCallRename
    # accepts, both keep walking; anything else means index alignment has
    # broken -- either the tree has started inserting new lines here, or
    # this is a real, unexplained divergence -- so the walk stops and
    # records the split point (global jsonSchemaSplitK = i-1). A BACKWARD
    # (tail-first) search for this boundary was tried and rejected: IR text
    # is full of short, generic lines (`}`, a blank separator) that recur
    # throughout a function body, so matching from the end can align on the
    # WRONG occurrence of one and misplace the split by exactly the inserted
    # functions own length -- reproduced on the real run_json_schema_attrs.bit
    # fixture, where a backward scan lands 2 lines short because the
    # inserted functions own closing `}` coincidentally matches the ORIGINAL
    # functions `}` two lines earlier. A forward, index-aligned walk has no
    # such ambiguity: index i can only mean one specific position.
    function schemaForwardWalk(nA, linesA, nB, linesB,    i, subCount) {
      subCount = 0
      jsonSchemaSplitK = nA
      for (i = 1; i <= nA; i++) {
        if (linesA[i] == linesB[i]) { continue }
        if (isSchemaCallRename(linesA[i], linesB[i])) {
          subCount++
          if (subCount > 1) { return 0 }
          continue
        }
        jsonSchemaSplitK = i - 1
        break
      }
      return (subCount == 1) ? 1 : 0
    }
    # schemaInsertBlockOk -- true when linesB[k+1 .. k+insLen] is exactly one
    # well-formed appended function named __json_schema_<ident>: its header
    # (`func __json_schema_<ident>(...) ... {`) is the FIRST inserted line
    # (the blank line before it, if any, already existed in the shared
    # prefix as the ordinary inter-function separator, so it is never part
    # of the insertion itself); its closing `}` is either the LAST inserted
    # line, or the second-to-last when the dump format also needs a fresh
    # blank separator before the next, unmoved function; and no second
    # `func ` or premature `}` appears anywhere between header and closer.
    function schemaInsertBlockOk(linesB, k, insLen, ident,    i, hdr, closeIdx) {
      hdr = "^func __json_schema_" ident "\\(\\) [A-Za-z_][A-Za-z0-9_<>]* \\{$"
      if (linesB[k + 1] !~ hdr) { return 0 }
      closeIdx = (linesB[k + insLen] == "") ? (k + insLen - 1) : (k + insLen)
      if (linesB[closeIdx] != "}") { return 0 }
      for (i = k + 2; i < closeIdx; i++) {
        if (linesB[i] == "}") { return 0 }
        if (linesB[i] ~ /^func /) { return 0 }
      }
      return 1
    }
    # jsonSchemaSpecializeCall (#6161) -- orchestrates the helpers above; see
    # this files header above for the derivation.
    function jsonSchemaSpecializeCall(nA, linesA, nB, linesB,    insLen, k) {
      insLen = nB - nA
      if (insLen < 0) { return 0 }
      if (!schemaForwardWalk(nA, linesA, nB, linesB)) { return 0 }
      k = jsonSchemaSplitK
      if (insLen == 0) { return (k == nA) ? 1 : 0 }
      if (k == nA) { return 0 }
      return schemaInsertBlockOk(linesB, k, insLen, jsonSchemaRenameIdent)
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
      # `ast`/`fmt` never reach the opcode-delta machinery below -- meaningless
      # for both (no IR opcodes in either text).
      if (kind == "ast") { exit 1 }
      if (kind == "fmt") { exit 1 }
      if (kind == "types") {
        if (optionUnsubstitutedType(nA, linesA, nB, linesB)) {
          print "6194-generic-method-receiver-unsubstituted-type"; exit 0
        }
        if (columnShiftType(nA, linesA, nB, linesB)) {
          print "6161-json-decode-column-shift"; exit 0
        }
        if (orderedSubsequenceInsert(nA, linesA, nB, linesB)) {
          print "6161-json-schema-synthesized-insert"; exit 0
        }
        if (errorResolvedInsert(nA, linesA, nB, linesB)) {
          print "6161-json-decode-enum-error-resolved"; exit 0
        }
        exit 1
      }

      for (op in a) allop[op] = 1
      for (op in b) allop[op] = 1
      # `moved` is the set of opcodes that ACTUALLY changed. `delta` cannot
      # serve that purpose on its own: merely READING delta["x"] creates the
      # element in awk, which is why the identity below checks `moved`
      # membership before ever reading `delta`.
      for (op in allop) {
        d = b[op] - a[op]
        if (d != 0) { delta[op] = d; moved[op] = 1 }
      }

      # --- #6194: generic method receiver Option<T> result stays boxed in
      # the oracle, explodes to words in this tree ---
      #
      # PRE-OPT (kind=ir): every consuming site unpacks the oracles single
      # boxed Option with 2 `field_get`s, then REBOXES those 2 words into a
      # fresh same-shape Option (1 `gc_alloc`, its `field_set`s unscored) so
      # the exploded ABI can read it back with 2 more `field_get`s before the
      # call/return -- net +4 `field_get`/+1 `gc_alloc` per isSome-shaped
      # site, +2 `field_get`/+1 `gc_alloc` per unwrap-shaped site (the
      # existing single-field unpack of the Person payload is unchanged on
      # both sides). Measured on the real #6194 fixture (this tree vs the
      # 0.32.0 pin, 2 call sites of each shape across its 2 functions):
      # field_get +12, gc_alloc +4, nothing else moves. Checked as an
      # identity, not the exact fixture counts: only field_get/gc_alloc may
      # move, both strictly positive, and field_get must fall in
      # [2x, 4x] of gc_alloc -- the structural floor (every rebox needs at
      # least 2 field_gets to read back) and ceiling (never more than the
      # isSome-shaped sites 4 measured here) a different, unrelated
      # field_get/gc_alloc-only delta is not expected to satisfy by
      # coincidence.
      if (kind == "ir") {
        ok6194 = 1
        for (op in moved) { if (op != "field_get" && op != "gc_alloc") ok6194 = 0 }
        Nfg6194 = delta["field_get"] + 0
        Nga6194 = delta["gc_alloc"] + 0
        if (Nga6194 <= 0 || Nfg6194 <= 0) ok6194 = 0
        if (Nfg6194 < 2 * Nga6194 || Nfg6194 > 4 * Nga6194) ok6194 = 0
        if (ok6194) { print "6194-generic-method-receiver-explode"; exit 0 }
      }

      # POST-OPT (kind=iropt): opt.bit CSE/DCE forwards the unpacked words
      # directly to their consumers, so every rebox `field_get` pair is dead
      # on arrival and removed along with it -- field_get nets to NO delta
      # (both sides end up reading the payload exactly once), while the
      # rebox `gc_alloc` itself becomes dead code and is dropped, a pure
      # DECREASE. Measured on the same fixture: gc_alloc -2 (2 functions x 1
      # net dead box each, once isSome/unwraps own reboxes both fold away),
      # field_get identical on both sides (no entry in `moved` at all).
      # Checked as an identity: gc_alloc must be the ONLY opcode that moved,
      # strictly negative -- an unrelated field_get delta, or a gc_alloc
      # INCREASE, is never explained here.
      if (kind == "iropt") {
        ok6194o = 1
        for (op in moved) { if (op != "gc_alloc") ok6194o = 0 }
        Nga6194o = delta["gc_alloc"] + 0
        if (Nga6194o >= 0) ok6194o = 0
        if (ok6194o) { print "6194-generic-method-receiver-explode"; exit 0 }
      }

      # #6161: generic jsonSchema<T>() call specialized to a synthesized
      # per-type function -- see this files header above for the derivation.
      # Declared once for both `ir` and `iropt`, same convention as #6194
      # above: the boundary shape (one renamed call, at most one inserted
      # function) does not differ pre/post-opt even though the inserted
      # functions own opcode count does.
      if (kind == "ir" || kind == "iropt") {
        if (jsonSchemaSpecializeCall(nA, linesA, nB, linesB)) {
          print "6161-json-schema-specialize-call"; exit 0
        }
      }

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
    types)
      printf '%s\n' \
        "6194-generic-method-receiver-unsubstituted-type" \
        "6161-json-decode-column-shift" \
        "6161-json-schema-synthesized-insert" \
        "6161-json-decode-enum-error-resolved"
      return
      ;;
    ir) printf '%s\n' "6194-generic-method-receiver-explode" "6161-json-schema-specialize-call"; return ;;
    iropt) printf '%s\n' "6194-generic-method-receiver-explode" "6161-json-schema-specialize-call"; return ;;
  esac
  [ -n "$kind" ] || printf '%s\n' \
    "6194-generic-method-receiver-unsubstituted-type" \
    "6194-generic-method-receiver-explode" \
    "6161-json-decode-column-shift" \
    "6161-json-schema-synthesized-insert" \
    "6161-json-decode-enum-error-resolved" \
    "6161-json-schema-specialize-call"
}
