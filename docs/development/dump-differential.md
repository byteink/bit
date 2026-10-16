# selfhost-diffdump.sh: design record

Moved out of `scripts/selfhost-diffdump.sh`'s header, to keep the
script under the 800-line ceiling `_tests_/bit/shellsize.bit` enforces
on shell scripts. Nothing below was reworded -- only moved and reflowed from
`#`-comments into Markdown.

## Why one driver, not six scripts

`selfhost-diff{ast,tokens,diags,types,ir,iropt}.sh` were six copies of the
same script, one flag apart, and three of the six (ast/tokens/diags) had no
timeout guard at all -- a hung oracle or a hung working-tree `bit` wedged the
gate indefinitely. This is one driver plus a data table (the six `case` arms
in the script, one per row); the six old paths are now thin wrappers that
`exec` into `selfhost-diffdump.sh <name>`.

BOTH sides of every comparison are alarm-guarded (perl `alarm`, the same
mechanism the three already-guarded siblings used) -- see
`selfhost-diffcheck.sh`'s header for why that guard exists: "the oracle side
had no bound at all, so a hung ORACLE wedged the whole gate indefinitely."

THE SECTIONS BELOW ARE CARRIED OVER FROM THE SIX FILES THIS REPLACES, one per
original file -- except the `tokens` section's old two-compilers-in-
different-languages framing, corrected across the family: the
oracle is the pinned stage0 (an earlier release of this same compiler), not a
second implementation written in something else.

## Reading a red types/ir/iropt run: outpaced oracle vs. real regression

All three of these compare against the PINNED STAGE0 -- a fixed earlier
release -- so any inference or lowering improvement that has landed since
that release IS a difference by construction. A mismatch here is not
automatically a divergence: it can be the fix working, with the oracle still
on the buggy side.

What to do about it while landing a fix, in the window before the next repin
(when nothing an author does makes this gate green): land the fix WITH its
golden case, and record on the fix's own ticket that types/ir/iropt are
expected red until stage0 repins past it. Do not delete the case, and do not
try to keep the exercising program out of the swept corpus -- two
`lint_deferloop_*` files are pre-existing corpus entries whose IR a legitimate
lowering fix changed, which is proof there is no such workaround even in
principle: the corpus holds a program for every construct on purpose.

A stage0 repin (`docs/release/bootstrap.md` §4/§5) is what actually clears it
-- not a code change to these scripts. Once the pin moves to a release cut
from a tree containing the fix, oracle and tree agree again and MISMATCH
drops back on its own. A mismatch that SURVIVES a repin is a real
regression, not an oracle lagging the tree, and should be treated like any
other red gate.

Telling the two apart before that repin lands: check that MATCH went UP, not
only that MISMATCH is the number you expected. A repin can make a broken
harness agree for the wrong reason -- both sides silently failing to parse
the same input reads identically to a real fix. This nearly happened on
`selfhost-diffverdict.sh`: its synthesized test source was still emitting
the `function` keyword an earlier lowering change had removed, so runs were
scoring on rejected input until the emission sites were fixed.

Why route 1 (repin) over the alternatives: a scoped expected-mismatch list
was tried and deleted for exactly this class of problem ("nothing is
permitted to differ now" below) -- re-admitting one bets against that
history. Making `--dump-ir-pre` refuse what `build` refuses only fixes the
signature-only-stub sub-case, not a file where both compilers lower and
legitimately disagree because one of them is right, and it would be a
compiler change made to serve a test harness rather than the other way
round.

### UPDATE

A mismatching IR dump can hide a refusal by the pinned oracle: its checker
and dump succeed even when object emission cannot lower the program. The
shared pre-opt/post-opt driver probes only mismatches, first with `check`,
then with bounded O0 object emission if checking succeeds. An actual exit 1,
no emitted object, and only E0092 diagnostics attributed to that source
qualify as `SKIP(lower/check-err)`. This reports lost oracle coverage;
independent native and golden success must establish the current feature.
Successful object emission leaves the difference subject to the existing
signature or regression verdict. Missing compilers, timeout, signal, panic,
unrelated diagnostics and incomplete probes remain non-green. The probe
uses the same alarm bound and clears its object before each attempt (#7931).
It keeps the compiler's native default target, matching the IR dump's
architecture and operating system; a cross-target refusal cannot establish
missing native lowering coverage.

The above repin rule applies to genuine differences between programs both
compilers can lower. But
repin-and-wait made every future lowering IMPROVEMENT (opcode count going
DOWN, not a coverage gap) block on a release cycle by construction -- the
inline slice-index lowering change was the first to hit it. `ir`/`iropt` now
check a mismatch against
`explainMismatch`'s declared-signature table (`scripts/selfhost-ir-signatures.sh`,
used from `run_ir` in `selfhost-diffdump.sh`) first: a divergence that
matches a registered signature is EXPLAINED immediately, no repin needed.
This is deliberately NOT the deleted expected-mismatch list reborn -- see
that function's header for why a signature checked against an identity is a
different, narrower thing than a file checked against nothing. `types` also
checks the same declared signatures. The 0.42.0 stage0 repin retired its
previous dump identities (#8163, #8178).

The optimized-IR identity `8259-owned-byte-header-copy` removes only a full
byte-slice header snapshot immediately before `string_from_byte_range`.
The snapshot must use zero and the source header's saved length. Its source
must be a `field_get` of `[]u8`, and the snapshot has exactly one use: the
next copying string reader with the same length. The source, zero and length
definitions must precede the snapshot on a unique predecessor chain from
entry. Joins or cycles on that predecessor chain leave the difference
unexplained, as do unknown terminators, writes and unknown calls. The string reader remains, so the returned string
still owns an independent copy of the bytes.

All remaining instructions, function and block structure must match under a
bijective SSA-ID mapping within each function. Quoted literals remain exact,
including escaped, non-UTF-8, `%` and `$t` bytes. This matcher does not
canonicalize type IDs or apply to unoptimized IR. At least one actual snapshot
elision is required; counts and file names cannot explain a difference.
The selfcheck covers accepted structure and rejected bounds, uses, effects,
control flow, literal changes and unrelated changes with the same counts.
No corpus coverage count follows from those controls: the next differential
must report every explained and unexplained path against the pinned release.

Unknown differences still fail closed. Both plain and JSON documentation
output must match exactly. The retirement audit and the shared oracle-coverage
probe controls remain active. Retired derivations and fixtures remain available
in Git history.

## AST differential

Parse every corpus `.bit` file with both the oracle and this tree's `bit`
and diff their `--dump-ast` output. They must be byte-identical. Files the
oracle rejects with a parse/lex error are skipped: the two sides do not
agree on how far to parse past an error, so a rejected file compares
diagnostics rather than trees and belongs to diffdiags.

Usage: `./make selfhost && bash scripts/selfhost-diffast.sh`. Exits
non-zero (printing the first divergence) on any mismatch.

## Token differential

Lex every corpus `.bit` file with both the PINNED STAGE0 (the previous
release) and the working tree's compiler, and diff their `--dump-tokens`
output. They must be byte-identical. The contextual `in` token identity
retired with the 0.42.0 repin because both compilers now emit the same token.
Files the oracle rejects with a lex
error are skipped -- the two lexers disagree about how far to lex past an
error, so those files measure the diagnostic renderer rather than the
lexer.

THE ORACLE CHANGED, AND SO DID WHAT A GREEN RUN MEANS. It used to
be `bit-out/bin/bit-seed`, a compiler written in a different language, so
green meant two separately-written implementations agreed. It is now the
last release of this same compiler, so green means "this version did not
change behaviour versus the last release". See `docs/release/bootstrap.md`
§4/§5 -- the loss is recorded there, not papered over.

Usage: `./make selfhost && bash scripts/selfhost-difftokens.sh`. Exits
non-zero (printing the first divergence) on any mismatch.

## Diagnostic differential

Self-host front-end diagnostic differential: run every corpus `.bit` file
through both compilers' `--dump-diags` (lexer + parser diagnostics only --
resolve/check is Stage 2 and not yet ported) and diff. They must be
byte-identical: empty for a clean file, and the same rendered diagnostic for
a lex/parse error. Unlike difftokens/diffast this skips nothing -- a valid
file produces empty output from both, and the oracle's `--dump-diags` is
frontend-only so checker `// error` cases are empty on both sides too.

Usage: `./make selfhost && bash scripts/selfhost-diffdiags.sh`. Exits
non-zero (printing the first divergence) on any mismatch.

## Type differential

Self-host type differential: run every corpus `.bit` through both
compilers' `--dump-types` (the binding/param/call type dump) and diff.
Files the oracle rejects at check time are skipped (bit2's checker is still
partial). This tracks Stage-2 inference coverage: MATCH grows as more
constructs are ported; a byte diff pins the exact expression whose inferred
type differs.

### It had no exit status either

Found in an audit of the differential scripts, one script down from `selfhost-diffiropt.sh`: this
printed `MISMATCH=n` and a first-divergence diff, then fell off the end at
the `if`'s status -- always 0. Quoting it as verification was never a true
claim.

No expected-gap set here, deliberately: unlike the IR differentials this one
is at MISMATCH=0, so the expectation is simply "none", and a set file would
be an empty ceremony. If a gap ever has to be tolerated, add one then -- do
not pin a count.

A timeout is not evidence: a `bit` run killed by the alarm produced no
verdict, so it is reported separately and fails, rather than being scored as
a mismatch.

Usage: `./make selfhost && bash scripts/selfhost-difftypes.sh`.

## IR (pre-opt) differential

Run every corpus `.bit` through both compilers' `--dump-ir-pre` (the lowered
SSA text) and diff. Files the oracle cannot lower/check are skipped (bit2's
lowering is still partial). This tracks Stage-2 lowering coverage: MATCH
grows as more constructs lower; a byte diff pins the exact function whose IR
differs.

### Why this gates on the SET, not the count

It used to print `MISMATCH=4` and name only the first offender. A count is
not a set: MATCH could grow 141 -> 145 with MISMATCH steady at 4 while a
known gap quietly closed and a fresh regression opened in its place, and the
two runs would read identically. Three quarters of the claim was
unverifiable.

So every mismatching path is NAMED, and any mismatch at all fails the gate.
There was an expected-mismatch list for a while, so a known difference
could be written down instead of fixed; its last entry closed and it was
deleted with its reader. Nothing is permitted to differ now.

A timeout is likewise not evidence. A file whose run is killed by the alarm
is reported separately and fails the gate, rather than being folded into
the mismatch count -- a load-sensitive counter that silently self-confirms
is the exact bug this script was fixed for.

### The bound, and why BOTH sides carry it

The alarm is a HANG guard, not a performance budget, so it belongs well
above the slowest legitimate file rather than beside it. 20s was below the
corpus's worst case measured on the post-opt twin (25.20s wall on this
tree, 21.86s on the oracle, for `_tests_/imports/cryptomldsa/main.bit`);
pre-opt IR is cheaper and escaped by luck, not by design. 300s matches the
sibling and is ~12x that.

The oracle used to run UNBOUNDED, so a hung stage0 wedged this script with
no message. Folding that into SKIP would be worse: a skip means the oracle
legitimately declined the file, and quietly shrinking the corpus is how a
gate stops asserting anything. Both sides are bounded, with separate
outcomes.

Usage: `./make selfhost && bash scripts/selfhost-diffir.sh`.

## IR (post-opt) differential

Diff `bit --dump-ir` (optimized) against the pinned stage0's optimized
`--dump-ir` over the corpus. Tracks optimizer coverage -- MATCH grows as
fold/DCE/inline passes land. Mirror of the pre-opt differential above but
for the post-optimizer surface.

### Why this gates on the SET, not the count

It used to print `MISMATCH=3`, name only the first offender, and exit 0 --
so it could not fail under any circumstance, and its output was quoted as
verification anyway. Two separate defects: no verdict, and a count where a
set was needed. A count is not a set: MATCH could grow while MISMATCH held
steady because a known gap closed and a fresh regression opened in its
place, and the two runs would read identically.

A timeout is likewise not evidence. A file whose run is killed by the alarm
is reported separately and fails the gate, rather than being scored as a
mismatch that happens to sit in the expected set.

### The bound, and why BOTH sides carry it

The alarm is a HANG guard, not a performance budget, so it must sit well
above the slowest legitimate file rather than near it. It was 20s while the
corpus's worst case -- `_tests_/imports/cryptomldsa/main.bit` -- needed
25.20s wall and ~14s CPU on THIS tree and 21.86s on the oracle. That is not
a margin; the gate went red with MISMATCH=0 whenever the box was busy,
which is the shape `docs/development.md` warns about ("do not read a TIMED
OUT as a hang until you have timed the program standalone"). 300s is ~12x
the slowest observed file, in the spirit of the suite's own
900s-against-158s choice elsewhere.

The oracle used to run UNBOUNDED, so a hung stage0 wedged this script
forever with no message -- and merging that into SKIP would have been
worse, since a skip means "the oracle legitimately could not lower this"
and silently shrinking the corpus is how a gate stops asserting anything.
Both sides are bounded, and an oracle timeout is its own reported outcome.

Usage: `./make selfhost && bash scripts/selfhost-diffiropt.sh`.

## Retired signatures

Historical registry comments, moved unchanged from the signature registry.

```text
# --- Retirement history ---
#
# A declared signature goes dead without anyone removing it: the oracle is
# the pinned stage0, release N-1 (docs/release/bootstrap.md), and it moves
# every release, so a transform that landed before release N is back IN the
# oracle by N+1 - the two compilers agree again on every site the signature
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
# RETIRED lines named exactly these eight - six under `ir`, nine under
# `iropt` (the `iropt`-only branch-fold variant makes it nine, not eight).
# Not independently confirmed on x86_64-linux or aarch64-linux the way
# #5509's four were; the two prior repins to 0.26.0 and 0.26.1 (dist/stage0/
# SHA256SUMS) folded runtime/compiler fixes affecting all three targets
# identically and neither needed a per-arch re-check, and none of these
# eight identities keys on anything target-ISA-shaped (see WHICH HOSTS
# above - `--dump-ir`/`--dump-ir-pre` do not vary by ISA at all). Their
# per-opcode derivations are preserved in git history at this file's state
# before #5914 - a dead identity's math is not load-bearing for anything
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
# against the same pin - no `ir`/`iropt` signature was declared going in, so
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
# The stage0 0.42.0 repin (#8163) retires the remaining seven dump identities
# (#8178): 7745-loop-defer-stack and 7925-fnvalue-owner-reuse (ir/iropt),
# 7761-range-chain-cse (iropt), 7766-synth-json-helper-column-shift and
# 7933-variadic-type-marker (types), 7936-variadic-doc-marker (doc), and
# 8110-contextual-in-token (tokens). Each source repair is absent from
# v0.41.0 and present in v0.42.0. On edab51f2d, aarch64-macos, tokens and
# types each report MATCH=1826, ir and iropt each MATCH=1173, and doc
# MATCH=263. All five report MISMATCH=0 and EXPLAINED=0, then fail only
# because their old identities are RETIRED. The five obsolete variadic
# selfcheck expectations also fail because the two compilers now agree.
# The direct doc allowance and the loop-defer safepoint fallback retire
# with their shared helpers. The separate 4500 safepoint identity remains.
#
```
