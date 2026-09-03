# selfhost-diffdump.sh: design record

Moved out of `scripts/selfhost-diffdump.sh`'s header (#4265, to keep the
script under the 800-line ceiling `_tests_/bit/shellsize.bit` (#4232) enforces
on shell scripts). Nothing below was reworded -- only moved and reflowed from
`#`-comments into Markdown.

## Why one driver, not six scripts (#2743)

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
different-languages framing, corrected by #2600 across the family: the
oracle is the pinned stage0 (an earlier release of this same compiler), not a
second implementation written in something else.

## Reading a red types/ir/iropt run: outpaced oracle vs. real regression (#2382)

All three of these compare against the PINNED STAGE0 -- a fixed earlier
release -- so any inference or lowering improvement that has landed since
that release IS a difference by construction. A mismatch here is not
automatically a divergence: it can be the fix working, with the oracle still
on the buggy side.

What to do about it while landing a fix, in the window before the next repin
(when nothing an author does makes this gate green): land the fix WITH its
golden case, and record on the fix's own ticket that types/ir/iropt are
expected red until stage0 repins past it. Do not delete the case, and do not
try to keep the exercising program out of the swept corpus -- #2280's two
lint_deferloop_* files are pre-existing corpus entries whose IR a legitimate
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
the `function` keyword #2773 had removed, so runs were scoring on rejected
input until #2846/#2848/#2850 fixed the emission sites.

Why route 1 (repin) over the alternatives: a scoped expected-mismatch list
was tried and deleted for exactly this class of problem (#1883, "nothing is
permitted to differ now" below) -- re-admitting one bets against that
history. Making `--dump-ir-pre` refuse what `build` refuses only fixes the
signature-only-stub sub-case, not a file where both compilers lower and
legitimately disagree because one of them is right, and it would be a
compiler change made to serve a test harness rather than the other way
round.

### UPDATE (#3125)

The above is still the whole story for `types`, and for any `ir`/`iropt`
divergence that is a genuine gap rather than an intentional improvement. But
repin-and-wait made every future lowering IMPROVEMENT (opcode count going
DOWN, not a coverage gap) block on a release cycle by construction -- #3107
was the first to hit it. `ir`/`iropt` now check a mismatch against
`explainMismatch`'s declared-signature table (`scripts/selfhost-ir-signatures.sh`,
used from `run_ir` in `selfhost-diffdump.sh`) first: a divergence that
matches a registered signature is EXPLAINED immediately, no repin needed.
This is deliberately NOT the #1883 list reborn -- see that function's header
for why a signature checked against an identity is a different, narrower
thing than a file checked against nothing. `types` is unchanged; it has no
signature table.

## AST differential (#1332/#1335)

Parse every corpus `.bit` file with both the oracle and this tree's `bit`
and diff their `--dump-ast` output. They must be byte-identical. Files the
oracle rejects with a parse/lex error are skipped: the two sides do not
agree on how far to parse past an error, so a rejected file compares
diagnostics rather than trees and belongs to diffdiags.

Usage: `./make selfhost && bash scripts/selfhost-diffast.sh`. Exits
non-zero (printing the first divergence) on any mismatch.

## Token differential (#1332/#1334)

Lex every corpus `.bit` file with both the PINNED STAGE0 (the previous
release) and the working tree's compiler, and diff their `--dump-tokens`
output. They must be byte-identical. Files the oracle rejects with a lex
error are skipped -- the two lexers disagree about how far to lex past an
error, so those files measure the diagnostic renderer rather than the
lexer.

THE ORACLE CHANGED IN #1593, AND SO DID WHAT A GREEN RUN MEANS. It used to
be `bit-out/bin/bit-seed`, a compiler written in a different language, so
green meant two separately-written implementations agreed. It is now the
last release of this same compiler, so green means "this version did not
change behaviour versus the last release". See `docs/release/bootstrap.md`
§4/§5 -- the loss is recorded there, not papered over.

Usage: `./make selfhost && bash scripts/selfhost-difftokens.sh`. Exits
non-zero (printing the first divergence) on any mismatch.

## Diagnostic differential (#1335/#363)

Self-host front-end diagnostic differential: run every corpus `.bit` file
through both compilers' `--dump-diags` (lexer + parser diagnostics only --
resolve/check is Stage 2 and not yet ported) and diff. They must be
byte-identical: empty for a clean file, and the same rendered diagnostic for
a lex/parse error. Unlike difftokens/diffast this skips nothing -- a valid
file produces empty output from both, and the oracle's `--dump-diags` is
frontend-only so checker `// error` cases are empty on both sides too.

Usage: `./make selfhost && bash scripts/selfhost-diffdiags.sh`. Exits
non-zero (printing the first divergence) on any mismatch.

## Type differential (#1337/#364)

Self-host type differential: run every corpus `.bit` through both
compilers' `--dump-types` (the binding/param/call type dump) and diff.
Files the oracle rejects at check time are skipped (bit2's checker is still
partial). This tracks Stage-2 inference coverage: MATCH grows as more
constructs are ported; a byte diff pins the exact expression whose inferred
type differs.

### It had no exit status either (#1478)

Found by the #1478 audit, one script down from `selfhost-diffiropt.sh`: this
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

## IR (pre-opt) differential (#1337/#364)

Run every corpus `.bit` through both compilers' `--dump-ir-pre` (the lowered
SSA text) and diff. Files the oracle cannot lower/check are skipped (bit2's
lowering is still partial). This tracks Stage-2 lowering coverage: MATCH
grows as more constructs lower; a byte diff pins the exact function whose IR
differs.

### Why this gates on the SET, not the count (#1469)

It used to print `MISMATCH=4` and name only the first offender. A count is
not a set: MATCH could grow 141 -> 145 with MISMATCH steady at 4 while a
known gap quietly closed and a fresh regression opened in its place, and the
two runs would read identically. Three quarters of the claim was
unverifiable.

So every mismatching path is NAMED, and any mismatch at all fails the gate.
There was an expected-mismatch list for a while, so a known difference
could be written down instead of fixed; its last entry closed and it was
deleted with its reader (#1883). Nothing is permitted to differ now.

A timeout is likewise not evidence. A file whose run is killed by the alarm
is reported separately and fails the gate, rather than being folded into
the mismatch count -- a load-sensitive counter that silently self-confirms
is the exact bug this script was fixed for.

### The bound, and why BOTH sides carry it (#2070)

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

## IR (post-opt) differential (#1339)

Diff `bit --dump-ir` (optimized) against the pinned stage0's optimized
`--dump-ir` over the corpus. Tracks optimizer coverage -- MATCH grows as
fold/DCE/inline passes land. Mirror of the pre-opt differential above but
for the post-optimizer surface.

### Why this gates on the SET, not the count (#1478)

It used to print `MISMATCH=3`, name only the first offender, and exit 0 --
so it could not fail under any circumstance, and its output was quoted as
verification anyway. Two separate defects: no verdict, and a count where a
set was needed. A count is not a set: MATCH could grow while MISMATCH held
steady because a known gap closed and a fresh regression opened in its
place, and the two runs would read identically.

A timeout is likewise not evidence. A file whose run is killed by the alarm
is reported separately and fails the gate, rather than being scored as a
mismatch that happens to sit in the expected set.

### The bound, and why BOTH sides carry it (#2070)

The alarm is a HANG guard, not a performance budget, so it must sit well
above the slowest legitimate file rather than near it. It was 20s while the
corpus's worst case -- `_tests_/imports/cryptomldsa/main.bit` -- needed
25.20s wall and ~14s CPU on THIS tree and 21.86s on the oracle. That is not
a margin; the gate went red with MISMATCH=0 whenever the box was busy,
which is the shape `docs/development.md` warns about ("do not read a TIMED
OUT as a hang until you have timed the program standalone"). 300s is ~12x
the slowest observed file, in the spirit of the suite's own
900s-against-158s choice from #1637/#1652.

The oracle used to run UNBOUNDED, so a hung stage0 wedged this script
forever with no message -- and merging that into SKIP would have been
worse, since a skip means "the oracle legitimately could not lower this"
and silently shrinking the corpus is how a gate stops asserting anything.
Both sides are bounded, and an oracle timeout is its own reported outcome.

Usage: `./make selfhost && bash scripts/selfhost-diffiropt.sh`.
