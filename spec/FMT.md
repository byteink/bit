# Bit Formatting House Style

Status: normative. This is the canonical form `bit fmt` produces and the form
`#2876`'s gate will hold the repository to once it lands.

`bit fmt` has **no configuration**, and this document does not introduce one:
there is exactly one canonical spelling for any given piece of Bit source, the
same way `gofmt` has none. A rule below that looks like a setting (the line
width, the indent width) is a constant in `compiler/fmt.bit`, not a flag —
changing it is a change to the one true style, reviewed like any other, not a
per-project or per-file choice. If a future PR adds a flag that changes output,
it contradicts this document and this document wins.

This lives beside `spec/SPEC.md` rather than inside it, following
`spec/LINT.md`'s precedent (`spec/LINT.md` §1): SPEC describes the *language* —
what a program means — and reformatting never changes what a program means.
`spec/LINT.md` §1's own table already draws this line: "Column width,
indentation, spacing, and wrapping are all fmt's." This document is what that
sentence has pointed at without a destination until now.

**Every rule below is checkable**, because that is the entire reason to write
this down: `#2876` needs each one turned into a gate, not prose. Each rule
states, in one phrase, how a checker would test it. Where the code has a
settled rule but the corpus (`#2874`'s inventory) also found a *bug* the rule
does not yet hold to in every case, that bug is out of scope here — a bug is
fixed, not codified — and is named as open work instead.

The dispatch lives in four files, one module: `compiler/fmt.bit` (the printer
substrate — comment collection, the `Printer` state, the list/sequence/block
helpers), `compiler/fmtwrap.bit` (`#2896`; the width-aware wrap-decision
machinery split out of `fmt.bit` — flat lists, bracketed comma lists, and
binary/logical chain flattening), `compiler/fmtdispatch.bit` (declarations and
statements), and `compiler/fmtexpr.bit` (expressions and types). Citations
below name the function and file; line numbers are as of `2a915257`.

## 1. Line width

**Rule.** The budget is 100 columns (`fmtMaxWidth`, `compiler/fmt.bit:27`). A
bracketed comma list (see §5), a flat unbracketed list — return values,
assignment sides, `case` expression lists, constraint bounds
(`fmtPrintFlatList`, `compiler/fmtwrap.bit:14-97`) — and a bare
binary/logical/string-concat chain (`fmtPrintBinaryChain`,
`compiler/fmtwrap.bit:410-454`, dispatched from the `Binary`-tag case,
`compiler/fmtexpr.bit:78-81`) each render flat only if that fits; otherwise
one item/operand per line at one deeper indent. A single-item list stays on
one line even over budget — wrapping a lone item never shortens anything (§5).

**Check:** `fmtMaxWidth` in `compiler/fmt.bit` reads `100`; no emitted line in
a bracketed list's, a flat list's, or a binary chain's flattened form exceeds
100 columns.

**Settled for every construct that renders as a list or a chain (`#2889`,
`#2894`).** This was a real gap once — `#2874`'s corpus inventory measured
lines up to 1716 characters on the flat-list and bare-chain paths, because
`fmtPrintFlatList` and `fmtPrintBinaryChain` had no width check at all.
`#2889` gave both the same flat-then-fits-or-wrap shape `fmtPrintCommaList`
already had (all three share one implementation pattern,
`compiler/fmtwrap.bit:1-7`), and `#2894` closed the one remaining interaction
between them (a binary chain nested as a bracketed list's sole item — see
§5). §10 records that history and the exemptions that are the whole of what
is left unsettled; there is currently no construct with zero width check.

## 2. Indentation

**Rule.** 2 spaces per nesting level (`fmtIndentWidth`, `compiler/fmt.bit:29`),
written lazily at the first real content of each line (`fmtRaw`,
`compiler/fmt.bit:226-243`) as `p.indent * fmtIndentWidth` spaces. No tabs.

**Check:** `fmtIndentWidth` in `compiler/fmt.bit` reads `2`; every output
line's leading-space count equals `2 × ` its brace/block nesting depth.

## 3. Blank lines between statements and declarations

**Rule.** Any run of one or more blank source lines between two adjacent
items collapses to **exactly one** blank output line (`fmtGap`'s `allowBlank`
branch, `compiler/fmt.bit:268-270, 282-284`); zero blank lines in the source
stays zero. This applies between top-level declarations and between
statements inside a block (`fmtPrintSeq`, `compiler/fmt.bit:503-513`), and to a
blank line preserved immediately before a block's own closing `}`
(`fmtPrintBlock`'s trailing `fmtGap(p, n.span.end, true)`,
`compiler/fmt.bit:527`).

**Two constructions never get a leading blank line, by the printer's own
design, not as a separate policy:**
- The first statement inside a block, or the first clause of a `switch`,
  `match`, or `select` body, never has a blank line before it even if the
  source had one — `fmtPrintNoLeadBlank` (`compiler/fmt.bit:489-499`) passes
  `allowBlank = false` for the first item, `true` after.
- The very top of a *file* is the one place a leading blank line before the
  first item **is** kept — `Program`'s use of `fmtPrintSeq`
  (`compiler/fmtdispatch.bit:20-24`) gates every item including the first the
  same way it gates the rest.
- Inside a bracketed comma list (§5) — params, args, class/field lists,
  generics, composite literals, imports, tuples — no blank line is ever
  preserved between items or before the closing delimiter, regardless of the
  source (`fmtPrintCommaList`'s per-item and trailing `fmtGap` calls both pass
  `allowBlank = false`, `compiler/fmtwrap.bit:267, 294`).

**Check:** for any two adjacent statements/declarations in the same sequence,
0 source blank lines yields 0 output blank lines and ≥1 yields exactly 1;
0 blank lines ever appear as the first line inside a block/case/arm body or
between two items of a bracketed list.

## 4. Comments

**Rule.** A comment is re-derived from the source by re-lexing and scanning
the trivia gap between tokens (`collectComments`, `compiler/fmt.bit:47-62`),
then replayed in strict source order: it either trails the current output
line (if nothing but whitespace — no newline — separated it from whatever
precedes it in the source) or starts its own new output line immediately
before whichever node begins next in source order (`fmtGap`,
`compiler/fmt.bit:258-285`). **The formatter never reassigns a comment to a
different statement, list item, or clause than the one it was adjacent to in
the source.** Line comments (`//`) force a newline after themselves; block
comments (`/* */`) do not.

This is why `#2879` was a real bug and not a style question: `asm` blocks
printed their `x64`/`arm64`/`result`/`clobber` sub-clauses in a **fixed slot
order** that did not match the order the programmer wrote them in, so a
clause printed ahead of its true source position swept up a neighboring
clause's still-unconsumed comment. The fix — sort the populated clauses by
their own `span.start` before printing, then explicitly flush the gap before
each clause (`fmtAsmStmt`, `compiler/fmtdispatch.bit:662-713`) — is what makes
"attached to the same node it was attached to in the source" hold universally
rather than for every node kind except `asm`.

**Check:** the Nth comment in the source, by source order, is byte-identical
text to the Nth comment in `bit fmt`'s output, and remains immediately
adjacent (same statement/item/clause) to the same code it preceded or
followed in the source — the technique `#2879`'s per-file `asm`-region
comparator used, generalized to any node kind.

## 5. Bracketed comma lists (params, args, class/field/variant lists, generics, composite literals, imports, tuples)

**Rule** (`fmtPrintCommaList`, `compiler/fmtwrap.bit:158-297`, settled by `#2140`
and `#2880` together): the list flattens onto one line only if **both** hold —

1. the source did not already break the list at one of the list's own
   boundaries: right after the opening delimiter (`fmtOpenBroken`,
   `compiler/fmtwrap.bit:138-151`), or between two adjacent items
   (`fmtAnyItemGapHasNewline`, `compiler/fmtwrap.bit:109-121` — deliberately never
   a break nested *inside* one item's own content, which is what made the
   naive version non-idempotent, `#2880`); and
2. the flattened form fits under the 100-column budget (§1) — except a
   single-element list, which always stays flat.

**Nested width decisions inside a single-element list (`#2894`).** Point 2's
single-element override means the list's own accept/reject test never looks
at fit — only at whether the rendered item's text holds a newline. A nested
construct that DOES make its own independent, column-dependent wrap
decision — today only the binary/logical chain flattener (§10,
`fmtPrintBinaryChain`, `compiler/fmtwrap.bit`) — must not measure that
decision against the real, inherited column while it is rendering as a
single-element list's sole item (however many such lists deep): the
ancestor was always going to keep the result flat regardless of overflow,
so a wrap there only manufactures the newline that forces the ancestor, and
every enclosing single-element list in turn, to explode for no shortening
gain. Instead it measures as if starting a fresh line at the current indent
(`Printer.speculativeFlat`, cleared the moment a genuinely multi-item list
is entered, since that decision is never moot). A single unbreakable
argument nested three or more single-item calls deep can therefore render
well past the 100-column budget — this is the same exemption as point 2
above, correctly propagated through nesting instead of re-triggering a
spurious wrap at each level, not a new exception to §1.

**Check:** `b.f(g(x + y)).f(g(h(u | (v & w))))` (nested single-argument
calls three deep, the inner expression alone over budget only once the
outer calls' real column is added in) formats to one unwrapped line; halving
`fmtMaxWidth` in a scratch build wraps the SAME expression at a shallower
nesting depth, confirming the exemption is about nesting depth being moot,
not about the checker ignoring width entirely.

**A trailing same-line comment is OUTSIDE the width budget (`#2899`).** No
construct budgets for it: `fmtGap`'s comment flush runs after the code it
follows is fully printed, with nothing tying the two widths together. A
code-plus-comment combination whose code fits can therefore land over
`fmtMaxWidth` once the comment is appended, and that output is canonical —
`bit fmt` is a no-op on it.

This is a decision, not the absence of one, and the reason it is not merely
a missing check: making the code wrap to make room would require the
construct printing it to measure against the real column, which is exactly
the measurement the `#2894` exemption above exists to suppress. The two
cannot both hold. Choosing the other way would also let a comment *cause* a
wrap in the code it annotates, which this style rejects — the comment is not
part of the expression.

Note that no width rule can rescue the general case anyway: of the five
instances in the tree, the comment text **alone** exceeds 100 columns in two
of them — `compiler/arm64call.bit:335` and `compiler/project.bit:692` — so
those lines are over budget with zero code on them. Re-measure rather than
quoting a figure here; both are near enough to the limit that a reword moves
them, and a stale number in this file has misled a reader before.

**Check:** `tests/cases/fmt_comment_tail_budget.bit` — a single-item call
with a binary-chain argument and a trailing `//` comment, over budget — has
a `.expected` byte-identical to its input, so any future change that starts
wrapping this shape reddens `test-golden` rather than drifting silently.
Any gate that measures line width (`#2876`) must exempt the trailing
comment to agree with this rule.

Otherwise it explodes to one item per line, each with a trailing comma, at
one deeper indent level, preserving the author's own item grouping (`grouped`,
`compiler/fmtwrap.bit:255-283`) — two items the source kept on the same line stay
on the same output line when the list is already exploding for some other
item's sake. `{`/`}` pad with an inner space when the whole thing renders
flat (`Point{x: 0}` → `Point{ x: 0 }`).

**Check:** a hand-wrapped multi-line comma list (one item per source line, or
broken right after the opener) is never rejoined by `bit fmt`, no matter how
short the joined form would be; a list that was never broken at its own
boundary and fits under 100 columns joins onto one line; `bit fmt` applied
twice produces byte-identical output on every comma-list-containing file
(the idempotence check `#2880` and `#2140` both ran over the whole corpus).

## 6. Inline vs. stacked bodies — settled, and reversed once (`#1266`)

**Current rule**, two different answers for two different constructs
(`fmtPrintBodyBlock`, `compiler/fmt.bit:443-459`):

- **A function body** inlines as `{ stmt }` **if and only if the source wrote
  it that way** — a single simple statement, no comment, no nested block or
  `match`, and it fits on one line at the current column
  (`preserveSource = true`, called from `FuncDecl`,
  `compiler/fmtdispatch.bit:131`). The formatter never collapses a stacked
  function body onto one line, and never explodes a source-inline one-liner
  into stacked form as long as it still qualifies and fits.
- **A `match` arm's body** always collapses to `{ stmt }` whenever it
  qualifies (same single-simple-statement, no-comment test), **regardless of
  how the source wrote it** (`preserveSource = false`, called from
  `MatchArm`, `compiler/fmtdispatch.bit:571`).

**This reversed once, and the direction matters for the next reader.** Before
`#1266` (2026-07-14), the rule was "always collapse a one-statement body,"
for both functions and match arms. That broke real code both ways — 101
one-line accessors in `stdlib/crypto/hex.bit` needed to *stay* inline, while
`stdlib/core/option.bit`'s `unwrapOr` (whose one statement was a multi-line
`return match(...) {...}`) got mangled by being forced onto one line. The
owner's decision was that **no single rule works, because the tree
legitimately uses both spellings on purpose** — so the fix bends the
formatter to preserve the author's own choice for functions, while leaving
match arms on the older always-collapse rule, since there the single
expression *is* the point of writing it as a `match` at all. **Do not
re-reverse function bodies back to always-collapse by instinct because match
arms look inconsistent next to them — that inconsistency is the settled
rule, not a residue of it.**

**Check:** a function whose source body was written stacked (`{` and the
statement on different lines) stays stacked after `bit fmt`; a function
whose source body was written inline (`{ stmt }` on one line) and still
qualifies stays inline; a `match` arm with a qualifying one-statement body
is `{ stmt }` in the output even when the source wrote it stacked.

## 7. Parenthesization is re-derived, never preserved

**Why this is the subtlest rule in the formatter.** Parentheses are not in
the AST. The parser discards them and encodes grouping purely as tree shape
via precedence, so the formatter cannot "keep the parens the author wrote" —
there is no author-wrote-parens fact left by the time it runs. Instead it
**re-derives** parens from a style rule and precedence alone
(`fmtPrintBinarySide`, `compiler/fmtwrap.bit:302-332`, using `fmtPrec`,
`fmtIsBitOrShift` and `fmtIsBoolConn`, `compiler/fmt.bit:113-152`):

1. **Precedence-required parens** — the ordinary case: a binary operand that
   would silently regroup under the *other* operator's precedence (with
   left-associativity: an RHS wraps when its precedence is `<=` the parent's,
   an LHS wraps when strictly `<`) gets parenthesized.
2. **Style parens, independent of precedence** — a binary operand that mixes
   a *different* operator with a bitwise/shift operator (`&`, `|`, `^`, `<<`,
   `>>`) is always parenthesized, even where precedence alone would make it
   unambiguous. This reproduces `(a & b) ^ (a & c)` from an AST that carries
   no paren nodes at all. The same rule applies to the boolean connectives:
   a `&&` operand mixed with a `||` parent (or vice versa) is always
   parenthesized too (`#2356`), so `a || b && c` formats to
   `a || (b && c)`. It is scoped to both sides being `&&`/`||` — a
   comparison leaf next to `||` (`a == b || c`) is unaffected, since
   precedence alone is already unambiguous there and stripping it was never
   the complaint.

Rule 2 exists because rule 1 alone strips exactly this shape, and stripping
it was ruled unacceptable (`#1266`, 2026-07-15): `a & b ^ a & c` is
technically unambiguous by precedence, but bitwise/shift code (this repo's
own `stdlib/crypto/*`) is exactly where a reader should not have to hold
operator precedence in their head to read the expression, so the formatter
adds the parens back rather than trust the reader to re-derive them. Same-op
chains (`a & b & c`) and plain arithmetic (`a * b / c`, `(live * pct) / 100`
→ `live * pct / 100`) stay bare — nothing here parenthesizes for its own
sake, only a genuine operator mix at bitwise/shift precedence.

**Check:** `a & b ^ a & c` (no source parens at all) formats to
`(a & b) ^ (a & c)`; `a & b & c` (same operator) formats with no added
parens; `(live * pct) / 100` (same-precedence arithmetic, redundant source
parens) formats to `live * pct / 100`; `typ == 1 || typ == 2 && pass == 0`
(no source parens) formats to `typ == 1 || (typ == 2 && pass == 0)`;
re-formatting any of these outputs is a no-op (idempotent).

## 8. `asm` blocks

**Rule.** An `asm` block's interior statement order and each statement's
attached comment are preserved exactly as the source wrote them — the
formatter may re-indent the block (see §2) but never reorders its clauses
(`fmtAsmStmt`, `compiler/fmtdispatch.bit:662-713`, see §4 for why this needed
a fix rather than being true by default). A block with no comment inside it
still renders on one line, unchanged from before `#2879`.

**Check:** format a copy of every file containing an `asm` block; reduce each
block to its literal instruction/token sequence plus (literal run, trailing
comment) pairs; confirm the sequence and every pairing is unchanged before
and after — `#2879`'s comparator, run over all 17 `asm`-containing files (25
`asm` statements) in the corpus at the time it landed.

## 9. Semicolons

**Rule.** `bit fmt` never writes a redundant `;`: a statement or declaration
gets an explicit trailing `;` in the output **only if** its canonical
rendering's last token is not itself one that Bit's automatic-semicolon-
insertion (SPEC §7) already terminates on (`fmtEndsInBlock`,
`compiler/fmt.bit:365-378`, and `fmtEndsInTerminator`,
`compiler/fmt.bit:383-401` — anything ending in a block's closing `}`, or
whose last real token is already a terminator, gets no `;`).

**Check:** a statement whose canonical form ends in `}` (an `if`, a `for`, a
function declaration, …) is never followed by `;` in the output; a statement
ending in a bare expression, identifier, or literal is.

## 10. Width budget for bare (non-bracketed) constructs — settled (`#2889`, `#2894`)

**Rule.** Return values, assignment sides, `case` expression lists,
constraint bounds (`fmtPrintFlatList`, `compiler/fmtwrap.bit:14-97`, shares
the flat-then-fits-or-wrap shape §5's bracketed lists use) and bare
binary/logical/string-concat chains (`fmtPrintBinaryChain`,
`compiler/fmtwrap.bit:410-454`, dispatched from the `Binary`-tag case,
`compiler/fmtexpr.bit:78-81`) render flat if that fits under the §1 budget
and holds no comment, else one item/operand per line at one deeper indent —
the same rule §1 and §5 state, extended by `#2889` to every construct that
had none. `#2894` is the one interaction the extension needed: a chain
nested as a single-element bracketed list's sole item (§5's "Nested width
decisions") measures against the indent baseline rather than the real column,
because the enclosing single-element list was always going to stay flat
regardless, and measuring for real would only manufacture a wrap that forces
every enclosing single-element list to explode for no shortening gain.

**Check:** `return aVeryLongIdentifier1 + aVeryLongIdentifier2 + ...` (a bare
`+` chain as a sole return value, over 100 columns) wraps one operand per
line; `return a, b` (a flat two-item list) wraps to one item per line when
the joined form is over budget and stays joined when it is not.

This section used to be titled "Explicitly unsettled" and named this exact
gap: `#2874`'s inventory measured lines up to 1716 characters on the
flat-list and bare-chain paths before `#2889`/`#2894` landed. It is kept as
its own section, rather than folded into §1, because it is where a reader
checking whether a *specific* non-bracketed construct is covered should
look first — nothing here is exempt from §1 any longer.

No other category named in this ticket was found unsettled: indentation
(§2), the blank-line policy between declarations (§3), and whether the
formatter may move a comment (§4) each have a specific rule in the printer
today, cited above, with nothing in `#2874`'s inventory or the four fix
tickets contradicting it.
