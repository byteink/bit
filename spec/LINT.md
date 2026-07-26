# Bit Lint Specification

Status: proposed (smash #1376). Normative once implemented.

`bit lint` reports code-health problems that the type checker does not consider
errors and the formatter cannot mechanically fix. It exists to bound the growth
of files and functions. Nothing in a compiler stops a file from being appended
to indefinitely, and left unbounded that is the direction every long-lived file
drifts.

## 1. Scope

Bit ships three source tools. Each answers one question, and the boundaries
between them are load-bearing:

| Tool | Question | Output | Fails a build |
|---|---|---|---|
| `bit fmt` | Does it *look* right? | rewrites the file | only with `--check` |
| `bit check` | Is it *correct*? | errors | yes |
| `bit lint` | Is it *healthy*? | warnings | yes, via exit code |

**Rule admission test.** A rule belongs to lint only if `bit fmt` cannot fix it
mechanically. Column width, indentation, spacing, and wrapping are all fmt's:
a formatter that fixes them costs the author nothing, while a linter that only
complains about them assigns homework. Lint gets what requires a human
decision — no tool can decide how to split a 5000-line file.

This is why there is **no `max-columns` lint rule**. See §4.

### 1.1 Non-goals

- **No plugin or custom-rule API.** The ruleset is fixed and ships with the
  toolchain, the clippy model. eslint's plugin ecosystem exists because
  JavaScript has no canonical style; Bit has a formatter and a spec.
- **No style rules.** Naming conventions, comment format, and import order are
  either fmt's job or nobody's.
- **No project manifest.** Bit has no `bit.json`, and three integers do not
  justify inventing one — a manifest will later have to carry dependencies,
  versions, and targets, and deserves its own design. Configuration lives in
  the source (§5).
- **No autofix.** Every rule here describes a problem whose fix is a judgement
  call. A tool that guesses at those produces worse code, not less work.

## 2. Command-line interface

```
bit lint [flags] [paths...]
```

`paths` may be files or directories; directories are walked recursively for
`*.bit`. Default is `.`.

| Flag | Effect |
|---|---|
| `--json` | machine-readable findings, same schema as `bit check --json` |
| `--stats` | print override accounting only, report no findings |

`--json` writes its array to **stdout**; the summary line (§2.2) and every
rendered diagnostic go to **stderr**, so a consumer can pipe the JSON without
filtering.

`--stats` lists one line per override in force, `<path>: <rule>=<n>` or
`<path>: disable <rule>`, then the summary. The count alone says overrides
exist; the listing says which and where.

### 2.1 Exit codes

| Code | Meaning |
|---|---|
| 0 | no findings |
| 1 | at least one finding |
| 2 | usage error, unreadable path, malformed override directive, or a file `bit check` would reject |

Exit 2 covers an unknown flag, a path that does not exist or cannot be read,
any directive error from §5.2, and a file that fails to parse (§10 open
question 2). A path the user named and lint could not read is a silent hole in
the run, which is why it is a failure and not a warning.

A run with a directive error or a parse failure reports those errors
**instead of** findings, not alongside them: either decides what the findings
would be, so reporting findings computed past a broken override set or an
unparseable file would report a result nobody asked for. Every such error in
the walk is reported before exiting, so one run fixes them all.

Lint findings are recorded at `severity=1` (warning) so they do not bump
`errorCount` — `Diagnostics.warn` deliberately does not, and that semantic is
shared with the resolver ([diagnostics.bit:93](../selfhost/diagnostics.bit#L93)).
Failure is expressed by the exit code of `bit lint`, not by the severity of the
diagnostic. This keeps a lint finding from failing an unrelated `bit build`.

### 2.2 Override accounting

Every run prints one summary line to stderr, including clean runs:

```
lint: 0 findings, 12 overrides active
```

Any limit may be raised by editing the source (§5), so the count is what keeps
that from happening quietly: raising a limit changes this number, and the
change is visible in review even when the override line itself is skimmed past.

What it counts, exactly:

- **Distinct rules with a directive, not directive lines.** Two assignments to
  the same rule are one override, because the line reports what is in *effect*
  and only the last assignment is.
- **Over every file walked, not only files with findings.** The number exists
  to make a raised limit visible, and a raised limit is precisely a file that
  no longer has a finding.
- **A directive that restates the default counts.** It changes no behaviour,
  but it is still a claim about this file and belongs in the accounting.

It is printed unconditionally, on clean runs too, and there is no flag that
suppresses it.

## 3. Diagnostic codes

Lint reserves **E0200–E0299** in the central registry
([diagnostics.zig:44](../seed/diagnostics.zig#L44)), which documents the
per-stage range convention and the rule that a code is never renumbered once
shipped. Lint findings render through the existing path as
`warning[E0200]: ...`, so neither `codeString` nor the JSON emitter changes.

The range is allocated from both ends: **rules from E0200 upward**, and
**directive-machinery codes from E0299 downward**, so a new rule never has to
step over a meta-code.

| Code | Meaning |
|---|---|
| E0200–E0289 | lint rules (§4) |
| E0298 | override directive names an unknown rule |
| E0299 | override directive is malformed, or its reason is missing or empty |

### 3.1 Why the `E` registry and not a distinct `L%04d` (settled, #1378)

Decided, and effectively **irreversible from the first release that ships a
lint code** — the registry rule is that a code is never renumbered once shipped,
and by then users have written overrides and CI filters against these strings.

The case for a distinct `L` prefix is that a reader should be able to tell
"your program is wrong" from "your program is untidy" at a glance, and that is
the entire reason lint is a separate command. Three things already carry that
distinction, and none of them is the code:

1. **The severity word.** Findings render `warning[...]`, never `error[...]`.
2. **The command.** A finding only appears because the user ran `bit lint`;
   `bit build` and `bit check` never emit one.
3. **The message.** "file is 1204 lines, limit is 800" is not mistakable for a
   compile failure.

A prefix letter would add a fourth signal, not a first one. Against that:

- **One registry, one collision authority.** Two prefixes means the
  never-renumber rule has to be enforced in two places, and "is E0213 taken?"
  becomes two questions.
- **`codeString` is shared with the frozen seed.** `selfhost/diagnostics.bit`
  mirrors `seed/diagnostics.zig` byte for byte, and the seed is still the
  differential oracle for the bootstrap (§9). A prefix parameter would make the
  two diagnostic renderers structurally divergent, mid-bootstrap, for a
  distinction the severity word already carries. This is the decisive argument
  and it is specific to the project's current state, not a general preference.
- **Greppability is a wash.** `grep -rn 'E02'` is exactly as clean as
  `grep -rn 'L02'`.
- **It is the cheaper mistake.** If consumers do report confusion, moving
  E02xx → L02xx later costs one function signature and a JSON-emitter change.
  Shipping `L` and wanting it back costs the same, plus a break in every
  consumer that learned to parse two prefixes. Under uncertainty, take the
  option that is cheaper to reverse.

Revisit only if a real consumer reports real confusion, and only before 1.0.

## 4. Rules

### Phase 1 — size and shape (AST only)

These need only the token stream and the AST. No resolver, no type
information, so they can land first.

| Code | Rule | Default | Rationale |
|---|---|---|---|
| E0200 | `max-file-lines` | 800 | A file past this has stopped being one idea. |
| E0201 | `max-fn-lines` | 80 | A function that does not fit on a screen cannot be checked by eye. |
| E0202 | `max-params` | 5 | Past five, the call site stops being readable and the arguments want to be a struct. |
| E0203 | `max-nesting` | 4 | Deep nesting is nearly always a missing early return. |
| E0204 | `max-complexity` | 10 | Independent paths through a function, the count a reader must hold at once. |
| E0205 | `defer-in-loop` | — | Defers run at function exit, so one inside a loop holds every resource until the function returns. |
| E0212 | `unreachable-code` | — | A statement after `return`/`fail`/`break`/`continue`/`panic` in the same block. |

Counting rules, so the numbers are reproducible:

- `max-file-lines` counts physical lines, including blanks and comments. Not
  "logical" lines: the cost being bounded is the reader's, and a reader pays
  for blank lines too.
- `max-fn-lines` counts from the line of the `function` keyword through the
  line of its closing brace, inclusive.
- `max-params` counts declared parameters. A method receiver does not count.
- `max-nesting` counts nested *blocks* inside a function body; the body itself
  is depth 0. `if`, `while`, `for`, `match` arms, and `catch` blocks each add
  one.
- `max-complexity` is cyclomatic complexity: start at 1, add one for each `if`,
  `while`, `for`, `match` arm, `catch`, `&&`, and `||`. Unlike `max-nesting` it
  is flat-sensitive — a 300-line `match` with 60 one-line arms scores 61 while
  nesting stays at 1.
- `defer-in-loop` fires on a `defer` statement lexically inside any `while` or
  `for` in the same function. A `defer` inside a function *called* from a loop
  is fine and is not reported.

`max-fn-lines` and `max-complexity` measure different things and both stay: a
long flat function is readable, a short tangled one is not, and neither metric
catches the other's case.

`unreachable-code` is E0212 despite landing here, not E020x: it was assigned
its code inside the E021x dead-weight block for family coherence with its
neighbours below, before the dependency analysis that moved it here was done.
Diagnostic codes are never renumbered once assigned (§3), so the code stays
E0212; only its table row moves. It needs no resolver — whether a statement
follows one that diverges (`return`/`fail`/`break`/`continue`/`panic`) is
answered from the AST alone, by reusing the same `diverges` analysis
`bit check` already uses for E0055 missing-return and catch-block
completeness (seed/check.zig:5539, ported at selfhost/validatestmt.bit:610).

### Phase 2 — dead weight and footguns (needs the resolver)

These need scope and symbol information and land after phase 1.

| Code | Rule | Rationale |
|---|---|---|
| E0210 | `unused-import` | Left behind by refactors; misleads the next reader about a module's dependencies. |
| E0211 | `unused-local` | Same, at function scope. |
| E0213 | `shadowed-local` | A `let` that hides a name from an enclosing scope. Later edits to either binding silently change which one is read. |
| E0214 | `append-aliasing` | `append` on a slice parameter grows it in place and aliases the caller's backing array, so the caller sees writes it never made. |

(E0212 `unreachable-code` is numbered in this block but requires no resolver;
see phase 1 above, where it is actually implemented.)

`shadowed-local` closes a real gap: the resolver warns on shadowing a
*predeclared* name ([resolve.zig:386](../seed/resolve.zig#L386)) but says
nothing when an inner `let` hides an outer local. Prelude names are already
covered, so this rule must not double-report them.

**Decided: a parameter (or receiver) shadowing an outer name is not reported,
only a `let`/`const` is** (this includes a `for`/`catch`/`match` binder — they
activate as the same kind as a block-local `let`). `function f(count: int)`
beside a module-level `count` is the single highest-volume shape of shadowing
in real code, and it is close to harmless: a parameter's whole lexical extent
*is* the function body, so there is no earlier read in the same scope whose
meaning silently changes the way a mid-block `let` does. Reporting it would
make the rule noisy enough that a team would reach for `disable
shadowed-local` wholesale rather than fix the rarer, genuinely confusing case
this rule exists for — which defeats the rule. `let`/`const` stays in scope
because that is the shape with no lexical-extent excuse: it appears partway
through a block that already has the outer name in play.

`append-aliasing` has no equivalent in other languages' linters — it encodes a
Bit-specific aliasing rule the type system does not express, and one this
repository has already paid for once in the self-hosted compiler. It fires when
`append`'s first argument resolves to a parameter of slice type, and the result
is not assigned back to that same parameter. It is the rule most likely to need
overriding, since appending to a locally-owned copy is legitimate and not
always distinguishable from the AST.

Note the tension, recorded rather than resolved: in Go these three are
*compiler* errors, not vet findings. Making them hard errors in `bit check` is
defensible and would be more in Go's spirit. They are specified as lint rules
here because that path is overridable and does not break existing code on the
day it lands. Revisit before Bit 1.0.

### 4.1 Why there is no column rule

Line width is fmt's, per §1. The one case fmt cannot help is a long token that
cannot be broken — `stdlib/crypto/truststore.bit:207` is 1925 characters, an
embedded blob. A lint rule for it would fire on exactly the lines nobody can
fix, and would immediately need a suppression form, which is the mechanism
this spec is trying to avoid. So: fmt wraps what it can, leaves unbreakable
tokens alone, and lint says nothing.

### 4.2 Rules deliberately not included

Recorded so they are not re-proposed.

- **Discarded call result**, **empty or non-diverting `catch`.** Already errors
  in `bit check` — E0065 and E0067 ([check.zig:3513](../seed/check.zig#L3513)).
  In Go this is what `errcheck` exists for; here the checker got there first,
  which removes what would otherwise be a linter's headline rule.
- **`spawn` capturing a loop variable.** Go's classic bug. Bit closures capture
  by value, so the bug cannot occur — no rule for a defect the semantics
  already prevent.
- **Anything requiring a proof** — lock discipline, index bounds, reachability
  of an error path. That is checker or verifier work. Lint reports only what is
  cheap and certain from the AST, because a rule that is occasionally wrong
  becomes a rule everyone silences, and a silenced rule reports nothing.

## 5. Overrides

### 5.1 Grammar

```
LintDirective = "//" ws "bit:lint" ws ( Assignment | Disable ) ws "--" ws Reason .
Assignment    = RuleName "=" Integer .
Disable       = "disable" ws RuleName .
RuleName      = lower { lower | "-" } .
Reason        = { any character } .          // to end of line, non-empty
```

Examples:

```
// bit:lint max-file-lines=7100 -- bootstrap oracle, split tracked in #1376
// bit:lint disable max-nesting -- generated dispatch table
```

A `RuleName` must begin with a lowercase letter. Without that, `disable --
reason` scans `--` as the rule name and is rejected as an *unknown rule* — a
wrong diagnosis of a right rejection, and one that sends the reader looking for
a rule they never wrote.

An `Integer` is a plain run of decimal digits, at most 1,000,000,000. The cap is
not policy; it is what keeps `max-file-lines=99999999999999999999` from wrapping
into a small number and silently *tightening* the rule it was meant to relax.

The reason is **mandatory**. A directive without one, or with only whitespace
after the `--`, is an error (exit 2).

A limit is a claim about how large a file should be, and raising it is a claim
that this file is the exception. Requiring the exception to be stated in one
sentence costs the author nothing when the reason is good, and is the whole
review signal when it is not: a number by itself passes review unread, while a
weak justification is obvious on sight. It also survives the author — the next
person to open the file learns why the limit was lifted instead of guessing.

### 5.2 Placement and scope

A directive is recognised only in the **file's leading comment block** — the
run of `//` comment lines from the start of the file up to the first blank
line, declaration, or non-comment token. Multiple directives may appear; the
last assignment for a given rule wins.

It is deliberately *not* pinned to line 1: golden test cases already use line 1
for the harness mode directive ([harness.zig:240](../tests/harness.zig#L240)),
and a `// lint` case must be able to carry both.

Overrides are **file-scoped**. There is no line-scoped or function-scoped
suppression. This is coarse on purpose: overriding `max-fn-lines` for one long
function disables the rule for every function in that file, which makes the
override expensive enough that splitting the function is usually the cheaper
path. That pressure is the point of the tool.

A malformed directive is a hard error (exit 2), never a silent no-op. A
directive naming an unknown rule is likewise an error — otherwise a renamed
rule turns every existing override into a silent no-op, and files that were
green because of an override would start failing for reasons no one can see
in the diff.

**"Unknown" means not registered, which includes not yet implemented.** A rule
enters the registry with its check function, so an override for a rule that has
not landed is rejected. That is deliberate: accepting it would be the same
silent no-op, only displaced from a typo to a future feature.

The `bit:` prefix is a namespace claim for the whole toolchain, not a lint
token. A directive for another tool (`// bit:fmt ...`) is skipped by the lint
reader rather than rejected by it, so a second `bit:<tool>` can be added without
reworking this.

### 5.3 Precedence

```
built-in default  <  file directive
```

That is the whole model. No project layer, no user layer, no inheritance.

### 5.4 Day-one adoption

Rules fail by default from the first commit. The repository is made green not
by a baseline file but by stamping overrides on the files already in
violation:

| File | Lines |
|---|---|
| `selfhost/selfcheck.bit` | 7078 |
| `selfhost/lower.bit` | 5109 |
| `selfhost/x64.bit` | 2748 |
| `stdlib/quic/conn.bit` | 2536 |
| `selfhost/check.bit` | 2458 |
| `selfhost/arm64.bit` | 2294 |
| `selfhost/parser.bit` | 1585 |
| `stdlib/crypto/bcrypt.bit` | 1498 |
| `stdlib/http2/conn.bit` | 1353 |
| `selfhost/validate.bit` | 1280 |
| `selfhost/machoexec.bit` | 1221 |

Each stamped number is that file's current length, so the file is frozen at its
present size and any growth fails:

```
// bit:lint max-file-lines=5109 -- pre-dates lint; split tracked separately
```

The number only ever moves down, as the file is split. The override *is* the
ratchet — no separate baseline mechanism, and nothing to keep in sync. Since
every stamp carries a reason, the initial commit also records which files are
known debt rather than deliberate exceptions.

New files get the default and no grace.

## 6. Output

Human-readable output reuses the existing diagnostic renderer — same span,
caret, and hint machinery as `bit check`:

```
warning[E0200]: file is 1204 lines, limit is 800
  --> selfhost/lower.bit:1:1
  = hint: split it, or raise the limit with
          `// bit:lint max-file-lines=1204 -- <reason>`
```

`--json` emits the schema `bit check --json` already produces
([diagnostics.zig:500](../seed/diagnostics.zig#L500)), so editors and CI parse
one format for both tools.

## 7. Integration

- **Editor.** `bit lsp` publishes lint findings alongside check errors. Same
  transport, distinguished by severity — warnings render as warnings.
- **CI.** `bit lint` runs as its own step. It does not gate `bit build`.
- **`bit fmt`.** No interaction. fmt never reads a lint directive, and lint
  never reports anything fmt would have fixed.

## 8. Testing

A new golden mode, `// lint`, joins the existing set in
[harness.zig:240](../tests/harness.zig#L240). A case runs `bit lint` over the
file and compares stderr against the sibling `.expected` — except that lint
also asserts the process exit code, since 0 (clean), 1 (findings), and 2 (bad
directive) are all reachable and a stderr diff alone cannot separate 1 from 2.

The exit code is a mandatory `exit=<0|1|2>` suffix on the directive itself,
`// lint exit=1`, rather than a second line in `.expected` or an inferred
default: the directive line is where every other golden mode's contract lives,
and a case that gets the exit code wrong should fail to parse rather than pass
by accident. It costs nothing against §5.2's line-1/leading-comment-block
split — the harness still reads only line 1 for both the mode and the exit
code, and a `// bit:lint` override still lives anywhere in the leading comment
block, so `// lint exit=0` / `// bit:lint max-file-lines=20 -- ...` on lines 1
and 2 exercises both readers at once.

Required coverage:

- one case per threshold rule, at the boundary: `limit` passes, `limit + 1` fails
- one positive and one negative case per non-threshold rule — for
  `append-aliasing` the negative case must include an append to a local slice,
  and for `shadowed-local` an inner `let` of a prelude name, which
  `shadows_predeclared` already reports and this rule must not duplicate, PLUS
  a same-scope redeclaration, which `duplicate_declaration` (E0042) already
  reports and this rule must not overlap
- an override raising a limit
- an override disabling a rule
- a malformed directive, exit 2
- a directive with no reason, exit 2
- a directive whose reason is whitespace only, exit 2
- an unknown rule name in a directive, exit 2
- a directive after the leading comment block, correctly ignored
- a clean file, exit 0, with the summary line still printed

## 9. Implementation surface

| File | Change |
|---|---|
| `selfhost/lint.bit` | new — registry, directive reader, runner, rule passes |
| `selfhost/lintcheck.bit` | new — in-Bit self-checks, run by `selfcheck()` |
| `selfhost/main.bit` | `lint` subcommand dispatch |
| `tests/lintcmd.zig` | CLI contract: exit codes, walk, summary, `--json`, `--stats` |
| `tests/harness.zig` | `.lint` directive |
| `tests/cases/lint_*.bit` | golden cases |
| `docs/reference/` | user-facing rule reference |

A rule is a **registry entry plus a check function**, and landing one touches
nothing else — not the walk, not the renderer, not the exit-code logic. That
constraint is the point of the split: eleven rules should cost eleven small
diffs, not eleven edits to a growing runner.

`seed/` is **not** touched. The seed compiler's remaining job is to be the
differential oracle for AST, type, and IR dumps; lint changes none of those, so
lint is selfhost-only and the differential stays valid.

## 10. Open questions

1. **Phase 2 placement.** `unused-import` / `unused-local` as lint warnings, or
   as `bit check` errors in Go's style? Decide before 1.0 (§4).
2. **A file that does not parse (settled, #1383).** Decided: the parser's own
   diagnostics are reported through the same sink and exit path as a malformed
   override directive (§2.1, §5.2) — exit 2, findings withheld for that run.
   Linting the parser's recovered tree would invent findings from nodes it
   filled with the poison placeholder; a bespoke "does not parse, run
   `bit check`" message would only repeat what the parser's own diagnostic
   already says with an exact span. Reusing the directive-error path costs
   nothing new: both are "the findings for this run were never computed,"
   which is why the exit-2 summary line reads `N errors`, not
   `N directive errors`, now that a directive error is not the only kind.
3. **Default values.** 800 / 80 / 5 / 4 are judgement calls, chosen to be
   restrictive enough to bite. Worth revisiting once the whole repo is under
   the limit and the real distribution is visible.
