# Lint remediation policy: the non-aliasing rules

Epic #2354. This is the policy for what to do with every `bit lint` finding in
`compiler/` and `stdlib/` **except E0214** `append-aliasing`, which is a
correctness rule, not a readability one, and has its own settled history
(#2440, #2441, #2442, #3205, #3208, #3209). Do not use this document to
disposition an E0214 finding.

**This is not a second rulebook.** [spec/LINT.md](../../spec/LINT.md) is the
authority for every rule's definition, default limit, and override grammar;
[docs/reference/lint.md](../reference/lint.md) is the user-facing companion
that explains the same mechanics in prose. Neither states what THIS codebase
should do with the findings it currently has — that decision is this
document's only job. Where this document quotes a message or a default, it is
citing those two, not restating a competing definition.

## How to read this document

For each rule: a decision (`fix`, `raise the limit to N`, or `suppress with
allow`), the reason, and a **mechanical test** — a command whose output
settles whether that rule is clean, so an executor never has to guess. Every
test command follows the two rules this epic already learned the hard way:

1. `bit lint` writes every finding to **stderr**. Every command below
   redirects `2>&1` before counting anything.
2. The denominator is `bit lint`'s own printed `lint: N findings` summary
   line, never a count reconstructed by subtraction.

```sh
LOG=$(mktemp)
BIT_STDLIB="$PWD/stdlib" bit lint compiler > "$LOG" 2>&1
RC=$?
tail -1 "$LOG"                        # lint: N findings, M overrides active
grep -c '^warning\[E02..\]' "$LOG"    # per-code count, from the SAME log
```

Run once for `compiler`, once for `stdlib`. A rule is "clean" when its own
`grep -c '\[E0NNN\]'` reads 0 against that log, regardless of `RC` (other
rules may still have open findings) and regardless of what `bit lint`'s
overall exit code is.

## Counts this policy was written against

Measured this session, `main` @ `e6f170d3`, with `bit lint compiler 2>&1` /
`bit lint stdlib 2>&1` and the linter's own summary line as the denominator.
**Re-derive before trusting these** — the ticket that produced them says so
explicitly, and this run already drifted from the same-day baseline quoted in
the dispatch (E0201 compiler 77→79; every other cell matched exactly):

| rule | compiler/ | stdlib/ | decision |
|---|--:|--:|---|
| E0211 `unused-local` | 148 | 532 | fix |
| E0204 `max-complexity` | 235 | 48 | fix, or raise per-function (test below) |
| E0212 `unreachable-code` | 112 | 12 | suppress with `allow` (checker-gap shape), else fix |
| E0202 `max-params` | 83 | 21 | fix, or raise per-function (test below) |
| E0201 `max-fn-lines` | 79 | 18 | fix, or raise per-function (test below) |
| E0215 `unused-result` | 22 | 23 | fix (`let _ = ...`), unless the result is fallible |
| E0203 `max-nesting` | 24 | 2 | fix |
| E0213 `shadowed-local` | 1 | 1 | fix |
| E0210 `unused-import` | 0 | 1 | fix |

`compiler/ 712 findings, stdlib/ 680 findings` including E0214 (8 compiler, 22
stdlib — out of scope here, live on #3208/#3209). Excluding E0214: compiler
704, stdlib 658.

## The constraint this whole document is answerable to

Inherited from #2354, verbatim: *"Do not silence this with a blanket
suppression or by raising every limit until the count reaches zero — an
override must carry the reason it is safe."* Nowhere below is "raise the
limit" applied uniformly to a rule's whole finding set. Every raise is
**per-function or per-file**, gated by a mechanical test, and the written
reason it requires is not optional decoration — see §5.1 of spec/LINT.md: the
reason is the whole review signal, and a stamped number with a weak reason is
supposed to be obvious on sight.

## E0211 `unused-local` — FIX

> `'${name}' is declared but never used`
> hint: `remove it, or bind it to '_' if the value must be discarded`

**Decision: fix. No raise path exists** — `max-fn-lines`/`max-params`/etc. are
threshold rules with a numeric override; `unused-local` is boolean and has
none. `docs/reference/lint.md` already states the house rule directly: *"Prefer
fixing over stamping for `unused-import`/`unused-local`: a dead import or a
leftover binding should be deleted, not excused with a comment."* This
document adopts that rule for the current 680 combined findings without
change.

**The fix, precisely:**
- If the binding is genuinely dead (nothing downstream needed it — a
  refactor left it behind): delete the `let`/`const`.
- If the binding must stay because of destructuring or a pattern that
  requires naming every position (a `for (k, v) of m` where only `k` is
  read, a multi-assign that only cares about one side): rename it to the
  **literal blank identifier `_`**, not an underscore-prefixed name.

**Verified this session, empirically, per the ticket's own instruction to
check rather than assume — an `_`-prefix does NOT silence E0211, only the
bare `_` does:**

```sh
$ cat t.bit
fn f() {
  let _foo = 1
}
$ bit lint t.bit 2>&1
warning[E0211]: '_foo' is declared but never used
lint: 1 findings, 0 overrides active     # RC=1 — still fires

$ cat t.bit
fn f() {
  let _ = 1
}
$ bit lint t.bit 2>&1
lint: 0 findings, 0 overrides active     # RC=0 — exempt
```

This is not a convention this codebase invented — it falls out of
`compiler/resolve.bit`'s `rInsertModuleSymbol`, which never binds a symbol at
all for the literal name `"_"` (three call sites: lines 273, 300, 361). A
name that merely starts with `_` is bound normally and is exactly as reportable
as any other unused local. `#2444`/`#2445`/`#2446` must rename to bare `_`,
never to `_foo`, when the binding has to stay.

**Test:**
```sh
grep -c '^warning\[E0211\]' "$LOG"   # must be 0
```

## E0210 `unused-import` — FIX

> `'${name}' is imported but never used`
> hint: `remove the import, or bind it to '_' if it is needed only for a side effect`

**Decision: fix.** Same rule and same reasoning as E0211 — `docs/reference/lint.md`
names both together. #2443 already cleared this rule's findings; the single
remaining `stdlib/` finding is either new debt from a later commit or drift
between #2443's landing and this session's baseline. Delete it, or if the
import exists purely for a side effect (registering something at load time),
bind it `as _`.

**Test:**
```sh
grep -c '^warning\[E0210\]' "$LOG"   # must be 0
```

## E0201 `max-fn-lines` — FIX, OR RAISE PER-FUNCTION

> `function is ${lines} lines, limit is ${limit}` (default 80)
> hint: `split it, or raise the limit with `// bit:lint max-fn-lines=${lines} -- <reason>``

**Decision: fix by default. Raise, file-scoped, only for a function that is
long because it is FLAT, not because it is doing multiple things** —
spec/LINT.md §4 draws this line itself: *"a long flat function is readable, a
short tangled one is not."* The rule cannot tell those apart on its own; this
policy adds the test that can.

**The discriminator: check whether the SAME function also appears in this
file's E0203 `max-nesting` findings.**
- **Nesting clean** (the function does not also trip E0203) → the length
  comes from breadth, not depth — most often a single-level dispatch, one
  arm per case, each arm trivial. Verified on three of this session's largest
  E0201 hits: `compiler/lexkinds.bit:102` (`kindName`, an if-chain, one
  `return` per `Kind` variant, zero nesting), `compiler/fmtdispatch.bit:9`
  (`fmtDispatch`, the same shape over AST tags), `compiler/main.bit:256`
  (`main`, the CLI subcommand dispatch). Raise `max-fn-lines` for that file to
  the function's current line count, with a reason naming the function and
  the enumeration shape it is.
- **Nesting also over the limit** → the function is doing real sequential
  work at multiple depths, which is the shape spec/LINT.md calls "tangled."
  Fix: extract the cohesive sub-steps into named helpers.

**Test:**
```sh
grep -c '^warning\[E0201\]' "$LOG"   # must be 0
# for a candidate raise, confirm the SAME function is absent from E0203:
grep -B2 'max-fn-lines' "$LOG" | grep -A1 'E0201\]' | grep '\-\->'
grep -B2 'max-nesting'  "$LOG" | grep -A1 'E0203\]' | grep '\-\->'
# the raised function's file:line must not appear in the second list
```

## E0202 `max-params` — FIX, OR RAISE PER-FUNCTION WITH A NAMED EXTERNAL CONTRACT

> `function has ${n} params, limit is 5`
> hint: `group them into a struct, or raise the limit with `// bit:lint max-params=${n} -- <reason>``

**Decision: fix by default — group the parameters into a struct, exactly as
the rule's own hint says.** Measured overage is modest (6–8 against a limit
of 5; nothing pathological) and concentrated in codegen instruction
selection/encoding (`arm64encode.bit`, `x64select.bit`, `arm64select.bit`,
`arm64.bit`) plus `pmcli.bit`, `validatestmt.bit`, `optfold.bit`.

**The one legitimate raise path: the parameter list mirrors a fixed external
contract this repo does not control** — an ISA encoding's own operand order
from the architecture manual, a wire format's field order, a C ABI signature.
For that shape, a file-scoped raise is defensible **only if the reason names
the specific external document or spec section it mirrors** — "matches
AAPCS64 §6.8.2, encoding table C4-4" is a real reason; "already has 7 params"
or "hard to refactor" is not and must be rejected on review. If in doubt,
default to fix: a params struct costs nothing at the ISA-encoder call sites
this repo already uses that pattern for elsewhere.

**Test:**
```sh
grep -c '^warning\[E0202\]' "$LOG"   # must be 0
```

## E0203 `max-nesting` — FIX

> `function nests ${depth} deep, limit is 4`
> hint: `add an early return, or raise the limit with `// bit:lint max-nesting=${depth} -- <reason>``

**Decision: fix, with no raise path exercised.** Only 26 findings combined
(24 compiler, 2 stdlib), overage is modest (5–6 against a limit of 4), and
spec/LINT.md's own rationale — "nearly always a missing early return" — holds
at this volume: this is small enough that per-function judgement about
whether to raise costs more than just adding the early return would. If a
specific case turns out to need real, irreducible nesting (walking a
genuinely nested wire/document format with no early-return shape), it needs
its own written reason at raise time, same standard as every other rule here
— but expect that to be the rare exception, not the default disposition.

**Test:**
```sh
grep -c '^warning\[E0203\]' "$LOG"   # must be 0
```

## E0204 `max-complexity` — FIX, OR RAISE PER-FUNCTION (same discriminator as E0201)

> `function complexity is ${score}, limit is 10`
> hint: `split it, or raise the limit with `// bit:lint max-complexity=${score} -- <reason>``

**Decision: fix by default. Raise, file-scoped, only for a function proven
flat by the SAME nesting cross-check used for E0201.** This is the rule with
the widest spread (scores from 11 to 112 against a limit of 10 — up to 11x),
so a single global number is not defensible and is exactly what the epic
constraint forbids. Every raise is decided function by function.

**The discriminator, verified on this session's four highest scores:**
`compiler/fmtdispatch.bit:9` (`fmtDispatch`, complexity 112), `compiler/ast.bit:213`
(complexity 108), `compiler/lexkinds.bit:102` (`kindName`, complexity 93),
`compiler/main.bit:256` (`main`, complexity 84) are all flat one-branch-per-case
dispatches or if-chains with no nested nesting — none of them also appears in
this file's E0203 findings. Cyclomatic complexity conflates "many independent
flat branches" with "genuinely tangled logic"; spec/LINT.md §4 says as much
("a 300-line match with 60 one-line arms scores 61 while nesting stays at 1").
Nesting is the signal that tells them apart.

- **Nesting clean on the same function** → read it to confirm each branch is
  independently trivial (no branch itself contains further compounding
  logic), then raise `max-complexity` for that file to the function's score,
  reason naming the function and citing this discriminator.
- **Nesting also over the limit, or a "flat" branch turns out to contain its
  own multi-way logic** → fix: extract the branch's own logic into a helper,
  or split the function along its independent concerns.

**Test:** identical shape to E0201's, substituting the rule codes:
```sh
grep -c '^warning\[E0204\]' "$LOG"   # must be 0
# candidate raise: confirm the function is absent from this file's E0203 findings
```

## E0212 `unreachable-code` — FIX (it is real dead code, not a checker gap)

> `unreachable code`
> hint: `line ${n} always diverts control; nothing after it in this block runs`

**#2439 documented this rule set under the wrong theory, and #3211 disproved it
empirically rather than by argument.** The claim this section used to make was
that two shapes were structurally forced on the author — the checker itself
supposedly required a trailing filler statement that E0212 then flagged as
dead, making this "mostly a checker gap" pending a rule change. That is false.
Both shapes compile fine with the filler deleted, in the tree as it exists
today. #3211 deleted the filler statements outright: 112 in `compiler/`
(`b172585e`) and 12 in `stdlib/` (`c4e63d81`) — not because a rule changed, but
because the code really was unreachable and always had been.

**Why the two can never actually disagree.** E0212 is not a second,
independently-invented divergence check — `lintUnreachableCode`
(`compiler/lintapply.bit:388-399`) reuses the exact same `vDiverges`/
`vBlockDiverges` analysis (`compiler/validatestmt.bit`) that `bit check` itself
uses for E0055 missing-return and for catch-block completeness. The comment at
the call site says why: *"A second, hand-rolled divergence check would
disagree with the checker's on some construct and report a finding on code the
checker itself considers fine."* Because both consumers run the identical
predicate, nothing the checker treats as "control cannot fall through here" can
ever be a case E0212 gets wrong — so a trailing statement after such a point is
never checker-mandated. The two shapes:

- **`catch e { panic(...) ; <filler> }`.** `vCatchBind`
  (`compiler/validatestmt.bit:71`) only requires the catch block's tail to
  match the tried expression's type when that tail does *not* diverge:
  `if (!unitOk && !vDiverges(c, last, true)) { vExpectExpr(...) }`. A bare
  `panic(...)` as the last statement satisfies `vDiverges`'s own
  `Tag.ExprStmt` case (`vIsPanicCall`, `validatestmt.bit:339`), so the type
  check is skipped and no filler value is required. This exemption landed in
  `4c32c6d5` and is proven by an existing golden case,
  `tests/cases/run_parseint_intmin.bit`, which ships `catch e { panic("...") }`
  with no filler and has always compiled.
- **A trailing `return <dummy>` after an internally-exhaustive loop or an
  all-arms-diverging `match`.** `vDiverges`'s `WhileStmt` case
  (`compiler/validatestmt.bit:345-348`) already treats a break-less
  `while (true)` as diverging, and its `MatchStmt` case
  (`compiler/validatestmt.bit:367-375`) already treats a match whose every arm
  diverges as diverging — both independent of anything written after them. So
  E0055's missing-return check was already satisfied without the dummy
  `return`, in every one of the twelve `stdlib` findings #3211 removed.

**Policy: fix — delete the trailing statement. There is no `allow` path and no
downstream ticket to file**, because there is no rule defect to track.
Mechanically, for a live E0212 finding:

1. Read the statement immediately preceding the flagged one.
2. If it is `panic(...)` as the last statement of a `catch` block, or the
   block/function's only exit before the flagged statement is a break-less
   `while (true)` loop or a `match` whose every arm diverges, delete
   the flagged trailing statement. Verify with `bit check` on the containing
   module: exit 0 expected, no new diagnostics.
3. Anything else is real dead code from a stale edit, not one of the two
   known shapes — delete it the same way; if it is not obviously dead, read
   the surrounding control flow by hand before removing it.

**Test:**
```sh
grep -c '^warning\[E0212\]' "$LOG"   # must be 0
```

## E0213 `shadowed-local` — FIX

> `'${name}' shadows an outer binding of the same name`
> hint: `outer '${name}' declared at ${file}:${line}:${col}`

**Decision: fix.** Only 2 findings combined (1 compiler — `compiler/macholink.bit:152`,
`'gi'` — 1 stdlib). At this volume there is no case for a blanket disposition;
rename the inner binding. If a specific instance turns out to be a deliberate,
harmless reuse (rare, given spec/LINT.md's own rule that a `let`/`const` is
the one shape with "no earlier-lexical-extent excuse"), `allow` is available
(boolean rule) with a reason — but the default, and the expected outcome for
both current findings, is fix.

**Test:**
```sh
grep -c '^warning\[E0213\]' "$LOG"   # must be 0
```

## E0215 `unused-result` — FIX with `let _ = ...`, UNLESS THE RESULT IS FALLIBLE

> `'${name}' returns a value that is discarded here`
> hint: `bind it to '_' if the value is unused on purpose: let _ = ${name}(...)`

**Decision: fix, using the escape hatch spec/LINT.md §4.3 already documents** —
`let _ = f(x)` is a `LetDecl`, never visited by this rule at all, the same
idiom E0210/E0211's own hints teach.

**One check first, per finding, that is not optional:** if the discarded
value's declared type is fallible (`T!`) or an `Option`/`Result`, silently
discarding it may hide a real error rather than a harmless byproduct — that
is a correctness question, not a lint-policy one, and this document does not
authorise rubber-stamping it with `_`. Route that case to whoever owns the
call site's correctness, not to the mechanical `let _ =` rewrite. For every
other case (a plain-typed result genuinely unused — most sampled findings are
named like self-check helpers, e.g. `lintTestRead`, `rejectExternForTarget`,
`resolveNamed`, called for effect or assertion elsewhere), apply `let _ = ...`.

**Test:**
```sh
grep -c '^warning\[E0215\]' "$LOG"   # must be 0
```
