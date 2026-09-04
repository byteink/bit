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
shared with the resolver ([diagnostics.bit:93](../compiler/diagnostics.bit#L93)).
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
([compiler/diagnostics.bit](../compiler/diagnostics.bit)), which documents the
per-stage range convention and the rule that a code is never renumbered once
shipped. Lint findings render through the existing path as
`warning[E0200]: ...`, so neither `codeString` nor the JSON emitter changes.

The range is allocated from both ends: **rules from E0200 upward**, and
**directive-machinery codes from E0299 downward**, so a new rule never has to
step over a meta-code.

| Code | Meaning |
|---|---|
| E0200–E0289 | lint rules (§4) |
| E0297 | per-finding `allow` override is malformed, ineligible, or its reason is too short (§5.5) |
| E0298 | override directive names an unknown rule |
| E0299 | override directive is malformed, its reason is missing or empty, or it is well-formed but placed outside the leading comment block (§5.2) |

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
- **`codeString` is shared with the differential oracle.** `compiler/diagnostics.bit`
  must render identically to the pinned stage0, which is the oracle for the
  bootstrap (§9). A prefix parameter would make the renderer diverge from it for a
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
| E0202 | `max-params` | 5 | Past five, the call site stops being readable and the arguments want to be a class. |
| E0203 | `max-nesting` | 4 | Deep nesting is nearly always a missing early return. |
| E0204 | `max-complexity` | 10 | Independent paths through a function, the count a reader must hold at once. |
| E0205 | `defer-in-loop` | — | Defers run at function exit, so one inside a loop holds every resource until the function returns. |
| E0212 | `unreachable-code` | — | A statement after `return`/`fail`/`break`/`continue`/`panic` in the same block. |
| E0216 | `empty-test-file` | — | A `.test.bit` file's own suffix (§19) promises tests; declaring none is almost always a rename that lost its content or a stub nobody finished. |

Counting rules, so the numbers are reproducible:

- `max-file-lines` counts physical lines, including blanks and comments. Not
  "logical" lines: the cost being bounded is the reader's, and a reader pays
  for blank lines too.
- `max-fn-lines` counts from the line of the `fn` keyword through the
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
completeness (compiler/validatestmt.bit:610).

`empty-test-file` is E0216 for the same reason `unreachable-code` is E0212:
assigned from the next free E02xx slot at the time, landing here despite the
number because it needs no resolver either — a rule reads a file's own
FILENAME (never a directory component; a plain `.bit` helper inside a
`_tests_/` directory is never in scope) and whether its top level declares at
least one test-shaped `fn` (§19: no parameters, no return type), both
answered from the AST and the file path alone.

### Phase 2 — dead weight and footguns (needs the resolver)

These need scope and symbol information and land after phase 1.

| Code | Rule | Rationale |
|---|---|---|
| E0210 | `unused-import` | Left behind by refactors; misleads the next reader about a module's dependencies. |
| E0211 | `unused-local` | Same, at function scope. |
| E0213 | `shadowed-local` | A `let` that hides a name from an enclosing scope. Later edits to either binding silently change which one is read. |
| E0214 | `append-aliasing` | `append` on a slice parameter grows it in place and aliases the caller's backing array, so the caller sees writes it never made. |
| E0215 | `unused-result` | A bare call whose non-void result is thrown away with no assignment at all — the one case E0211 cannot see because nothing was ever named. See §4.3. |

(E0212 `unreachable-code` is numbered in this block but requires no resolver;
see phase 1 above, where it is actually implemented.)

**`unused-import` (E0210) is scoped to the MODULE, not the file being linted**
(#2284) — a directory of sibling `.bit` files sharing one flat import
namespace, matching [compiler/project.bit](../compiler/project.bit)'s
`SrcModule` contract: the same scope the binder already uses for cross-file
name resolution, and the reason #2121's E0042 "already declared in this
scope" fires across sibling files at all. An import used only by a sibling
file in the same module is not reported — the finding's own suggested fix is
"remove the import", and removing one a sibling genuinely needs would break
the build. This module view applies only when the file was reached by a
directory walk (§2); a file named directly on the command line is its own
singleton module, so an import unused in that file is reported regardless of
what any neighbour does. `unused-local` (E0211) needs none of this: a
function-local `let`/`const` cannot be read from another file, so its scope
was already correct at plain function scope, file boundaries notwithstanding.

`shadowed-local` closes a real gap: the resolver warns on shadowing a
*predeclared* name ([compiler/resolve.bit](../compiler/resolve.bit)) but says
nothing when an inner `let` hides an outer local. Prelude names are already
covered, so this rule must not double-report them.

**That predeclared-name warning is `shadows_predeclared` (E0048) — a `bit
check` diagnostic, not an E02xx lint rule** (it predates this registry and is
numbered in the resolver's own 40s diagnostic-code block alongside
`undefined_name`/`duplicate_declaration`/etc — see `compiler/resolve.bit` and
spec/SPEC.md §5.3, which is where it is normatively defined). It is documented
here rather than only in SPEC.md because it is the direct sibling of
`shadowed-local` above and a reader comparing the two rules should not have
to leave this file. It fires (as a warning, never blocking
`bit check`) on any module-scope or local declaration whose name matches a
predeclared identifier (SPEC §5.3) — with two exemptions, both **narrowing
when the rule fires, never suppressing an individual finding** (#3383):

- **An `extern fn` declaration is never reported.** Its bare declared name IS
  the external symbol it binds (SPEC §11.7); there is no alternate spelling,
  so the shadow is structurally forced. `runtime/root/darwin/fs.bit`'s
  `extern fn close` is SPEC §11.7's own cited example.
- **An `export`ed declaration named for one of SPEC §5.3's own documented
  predeclared *functions* — `len cap append delete close panic assert
  parseFloat` — is not reported**, on the grounds that reusing one of these
  specific, spec-documented names for a public API is a deliberate interface
  decision, not an accidental collision. `std/strings.parseFloat`
  (stdlib/strings/strings.bit), a fallible wrapper deliberately sharing the
  builtin's name, is the motivating case.

**This second exemption is deliberately narrower than "any exported
declaration."** The resolver also reserves a much wider set of ABI-boundary
primitive names beyond SPEC §5.3's list (`netLocalPort`, `netResolve`,
`fsOpen`, ... — `compiler/symbols.bit`'s `predeclaredFuncs()`), and an
exported function accidentally reusing one of *those* still warns: #3353
found and renamed exactly two such accidents in `runtime/net/**`
(`netResolve`, `netLocalPort`, both `export`ed), and a broader exemption would
silently stop warning if either recurred. Only the eight names SPEC §5.3
itself documents are exempt when exported.

A **local** shadowing a predeclared name (a `let`/`const`/parameter matching
`len`, `close`, etc.) is unaffected by either exemption and still warns —
only module-scope `extern fn` and `export` declarations are in scope for this
narrowing.

**Decided: a parameter (or receiver) shadowing an outer name is not reported,
only a `let`/`const` is** (this includes a `for`/`catch`/`match` binder — they
activate as the same kind as a block-local `let`). `fn f(count: int)`
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
is not assigned back to that same parameter **and then handed out of the
function through its own return value** (#3688). It is the rule most likely to
need overriding, since appending to a locally-owned copy is legitimate and not
always distinguishable from the AST.

**Assigning back to a parameter is not equivalent to returning it — that used
to be the whole exemption, and it was wrong.** `out = append(out, x)` reassigns
a local binding; a parameter's binding is exactly as local as any other
variable's, so on its own this never reaches the caller. It becomes safe only
when the function's *own* return value carries the grown slice back out —
concretely, one of three shapes, checked once per function and not chased past
one hop:

- `return out` — the parameter itself, bare;
- `return append(out, ...)` — grown once more on the way out, so a function
  whose every `append` is self-assigned-then-returned-through-another-`append`
  is not misread as never returning its parameter at all;
- `return Bundle{ field: out, ... }` — threaded through one field of a
  returned composite literal (`compiler/emitelf.bit`'s
  `EmElfBlobs{ symbols: symbols, ... }`, #3648).

A self-assignment whose function does none of the three is reported exactly
like a bare, unassigned `append(out, x)` — self-assignment alone reaches none
of the three shapes above, so this rule's own former suggested fix, "assign
the result back to the parameter," was recommending the exact broken pattern
it should have been catching (#3688). The current suggestion instead names
the two shapes above that actually work: return the slice, or thread it
through a returned bundle field.

**One shape remains genuinely ambiguous from the AST, and is not attempted:**
a slice parameter used purely as a local work buffer — grown across a loop,
fully drained, and never read by the caller again — inside a function that
returns nothing at all. `compiler/strip.bit`'s `closeKeptOverRelocs` is
exactly this: `stack: []int` grows via `append` and shrinks via reslicing
within one `while (len(stack) > 0)` drain, the function returns `()!`, and its
caller (`deadStrip`) never touches its own `stack` local again after the call.
That is indistinguishable, from this function's own body, from the shape the
rule exists to catch — telling them apart needs the *caller's* body, which is
the whole-program view this rule already declines elsewhere in this section.
It is resolved the way every other AST-ambiguous case here is: a
`// bit:lint allow E0214` directive naming the reason a human, not the rule,
established.

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

- **Empty or non-diverting `catch`.** Already errors in `bit check` — E0067
  ([compiler/validatestmt.bit](../compiler/validatestmt.bit)).
- **`spawn` capturing a loop variable.** Go's classic bug. Bit closures capture
  by value, so the bug cannot occur — no rule for a defect the semantics
  already prevent.
- **Anything requiring a proof** — lock discipline, index bounds, reachability
  of an error path. That is checker or verifier work. Lint reports only what is
  cheap and certain from the AST, because a rule that is occasionally wrong
  becomes a rule everyone silences, and a silenced rule reports nothing.

**"Discarded call result" used to be listed here too, as "already errors in
`bit check` — E0065".** That was wrong (#2117) and is corrected, not merely
removed, because the mechanism is worth recording: E0065 `invalid-expr-statement`
([compiler/validatecall.bit](../compiler/validatecall.bit)) governs which
*shapes* of expression may stand alone as a statement — a bare `x + 1` is
rejected, a bare call is not — and it accepts **every** call regardless of its
declared result type (`vLegalExprStmt`'s `Tag.Call` arm has no type check at
all). So `double(x)` beside `fn double(n: int): int` compiles, and `bit check`
says nothing — confirmed empirically by the ticket's own repro before this
bullet was corrected. §4.3 is the rule this repository actually needed.

### 4.3 `unused-result` (E0215, #2117): why it is scoped to same-file calls

The obvious reading — flag any statement-position call whose declared result is
non-void — would also fire on a builder returning an updated copy of itself
used for chaining, or a map-like `insert` returning the old value, both
legitimate call-for-effect shapes. A narrower reading — fallible (`T!`) results
only, or `Option`/`Result` only — was considered and **rejected**: it would not
even catch this section's own motivating case, `fn double(n: int): int`
(§4, table), which returns a plain `int`.

The rule actually shipped is narrower in a different, cheaper way: it fires on
**any** non-void result, but only for a call whose callee is a bare identifier
resolving to a plain function (never a method) **declared in the same file**.
This falls out of how every phase-2 rule here already works, not from a new
restriction invented for this one — `bit lint` resolves one file at a time
against synthetic stub import modules that carry only the imported *names*,
never their signatures (§1: lint has no project-wide view), so a call into
another module can never be typed here, and a method call cannot be resolved
at all without the receiver's type, which is checker work lint does not do.
The practical effect is that most of the noisy cases (a chained builder, a map
insert) are already excluded by construction, because they are almost always
either a method call or a call across a module boundary — so the "everything
non-void" reading turns out to be affordable once the rule is this narrow, and
restricting it further to fallible/`Option`/`Result` was not needed to keep it
quiet. See the finding counts recorded against #2117 for the measurement that
justifies this.

The corollary, stated plainly so it is not rediscovered as a bug report: this
rule does **not** catch `#2117`'s own headline example, `strings.Builder.write`
returning a new `Builder` instead of mutating one, when called from outside
the file that declares it — that is a method call, out of reach by the same
constraint. Catching it needs `bit lint` to gain cross-file type information,
which is a materially larger change than adding one AST-only rule.

Escape hatch: bind the result to `_` — `let _ = f()` — the same idiom E0210
and E0211's own hints already teach for "discard this on purpose" (§2.1's
override machinery is unaffected; `_` never binds a real symbol, so the rule
never visits a `LetDecl` written this way). The file-scoped `// bit:lint
disable unused-result` directive (§5) is available too, for a file where the
pattern is pervasive enough that call-by-call annotation is not worth it.

## 5. Overrides

### 5.1 Grammar

```
LintDirective = "//" ws "bit:lint" ws ( Assignment | Disable | Allow ) ws "--" ws Reason .
Assignment    = RuleName "=" Integer .
Disable       = "disable" ws RuleName .
Allow         = "allow" ws Code .             // §5.5 — placement and scope differ
Code          = "E" Digit Digit Digit Digit .
RuleName      = lower { lower | "-" } .
Reason        = { any character } .          // to end of line, non-empty
```

Examples:

```
// bit:lint max-file-lines=7100 -- bootstrap oracle, split tracked in #1376
// bit:lint disable max-nesting -- generated dispatch table
// bit:lint allow E0214 -- the function owns this buffer, never returns it
```

A `RuleName` must begin with a lowercase letter. Without that, `disable --
reason` scans `--` as the rule name and is rejected as an *unknown rule* — a
wrong diagnosis of a right rejection, and one that sends the reader looking for
a rule they never wrote.

`Allow` names its rule by diagnostic **code**, not `RuleName` — the string
already printed on the finding it targets (`warning[E0214]: ...`), so it is
copy-pasteable from the terminal rather than requiring a lookup from code to
name. It is documented separately, in §5.5: its placement, its reason
threshold, and what happens when it is malformed all differ from `Assignment`
and `Disable`, which the rest of this section (§5.1-§5.4) describes.

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
for the harness mode directive ([_tests_/bit/golden.bit](../_tests_/bit/golden.bit)),
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

**A well-formed directive found after the leading block ends is not silently
accepted as an ordinary comment either.** Every rule's own fix hint is
rendered at the *offending construct's* span, the strongest possible signal of
where the directive belongs — and outside the leading block is the one
placement that never applies it. `bit lint` reports it as a hard error (exit
2, `E0299` — the same code a malformed directive uses, §3), pointing at the
misplaced `// bit:lint` line and naming the fix: move it into the leading
block. The per-finding `// bit:lint allow ...` form (§5.5) is exempt from this
check — it is recognised anywhere in the file and has its own placement rule.

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
built-in default  <  bit.json "lint" key  <  file directive
```

Most specific wins. `bit.json`'s top-level `"lint"` key (#4156) is a
project-wide layer between the built-in default and a file's own directive:

```jsonc
// bit.json
{
  "lint": {
    "rules": { "max-file-lines": 900 },
    "overrides": [
      { "paths": ["_tests_/cases"], "allow": ["E0021"] },
      { "paths": ["_tests_/bit/parsercases"], "disable": true },
      { "paths": ["bench"], "rules": { "max-fn-lines": 200 } }
    ]
  }
}
```

`bit.json` is parsed as JSONC (comments and one trailing comma allowed, the
same grammar `bit.json`'s `dependencies` map already uses — §17.7 of
SPEC.md). `lint.rules` seeds a project-wide limit for a THRESHOLD rule (the
same five rules a `<rule>=<n>` file directive can set); `lint.overrides` is a
list of `{ paths, rules?, disable?, allow? }` entries, applied to every file
under a matching **directory prefix** — never a glob, and a `*`/`?` in a
path is a config error rather than a silent non-match. `overrides[].rules`
narrows the project rule further for that path; `overrides[].disable: true`
exempts every file under it from `bit lint` entirely, dropped from the walk
before it is even opened, so a corpus of deliberately-malformed fixtures can
never turn a parse error into the whole run's exit 2; `overrides[].allow`
suppresses specific diagnostic codes (not limited to lint's own — a parse
error's code works too) for files under it, as a post-filter over the run's
diagnostics.

A file's own directive always wins for that file, over whatever `bit.json`
set — this is the "most specific wins" rule, and its cost is symmetric: a
project **cannot** use `bit.json` to tighten a limit a file's own directive
has already relaxed. A `bit.json` with no `"lint"` key, or no `bit.json` at
all, is exactly today's model — no project layer, no user layer, no
inheritance beyond what is shown above.

### 5.4 Day-one adoption

Rules fail by default from the first commit. The repository is made green not
by a baseline file but by stamping overrides on the files already in
violation:

| File | Lines |
|---|---|
| `compiler/selfcheck.bit` | 7078 |
| `compiler/lower.bit` | 5109 |
| `compiler/x64.bit` | 2748 |
| `stdlib/quic/conn.bit` | 2536 |
| `compiler/check.bit` | 2458 |
| `compiler/arm64.bit` | 2294 |
| `compiler/parser.bit` | 1585 |
| `stdlib/crypto/bcrypt.bit` | 1498 |
| `stdlib/http2/conn.bit` | 1353 |
| `compiler/validate.bit` | 1280 |
| `compiler/machoexec.bit` | 1221 |

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

### 5.5 Per-finding overrides (`allow`, #2438)

`// bit:lint allow <CODE> -- <reason>` silences exactly **one finding**: the
one reported on the line directly below it. It exists for the rules §4 already
documents as not always distinguishable from the AST — `append-aliasing`
(E0214) is the motivating case, called out there as "the rule most likely to
need overriding, since appending to a locally-owned copy is legitimate and not
always distinguishable from the AST." Disabling that rule for a whole file
(§5.2) would also blind it to every genuine aliasing bug elsewhere in the same
file; `allow` silences only the call site the author actually reviewed.

**Placement**, and why it does not follow §5.2. A file-scoped directive lives
only in the leading comment block; `allow` is recognised **anywhere in the
file**, on the line immediately above the finding it targets, one line below
is not enough. `readLintDirectives` (compiler/lint.bit) skips a
`// bit:lint allow ...` line entirely rather than routing it through the
leading-block check — it is never a "misplaced directive" error (§5.2), it has
its own placement rule, read by compiler/lintallow.bit.

**Not available for a threshold rule.** `allow` only resolves to a rule with
no numeric limit (`max-file-lines`, `max-fn-lines`, `max-params`,
`max-nesting`, `max-complexity` are excluded). §5.2's file-scoped design is
coarse **on purpose** — overriding `max-fn-lines` for one function costs
exactly as much as disabling it for the whole file, and that cost is what
makes splitting the function the cheaper path. A per-line escape hatch for
those five rules would undo that on purpose. `allow` addresses a different
problem — an AST that cannot always tell a true positive from a legitimate
pattern — and does not reopen §5.2's decision.

**Code, not rule name.** `Allow` names its target by the diagnostic code
already printed on the finding (`E0214`), copy-pasteable from the terminal.
The named code must equal the finding's own code; a directive that names a
different (but otherwise valid, eligible) code, or that sits above a line with
no matching finding at all, is silently inert — not an error. Detecting a
*stale* `allow` that no longer matches anything is deliberately out of scope
(open question, §10): lines move, findings get fixed elsewhere, and an
`allow` two lines out of date is not the failure mode this override exists to
prevent.

**The reason threshold is stricter than §5.1's bare non-empty check: at
least 10 characters after trimming.** `Assignment` and `Disable` are added
rarely and reviewed individually; `allow` is meant to be stamped at the rate
of roughly one per call site across a repository-wide sweep (#2440-#2442),
which is exactly the setting where a placeholder like `"x"` or `"why not"`
would otherwise go unnoticed. 10 characters forces a few real words without
demanding a paragraph.

**A defective `allow` — an ineligible or unregistered code, a missing `--`,
or a reason under 10 characters — is reported as an ORDINARY finding, code
E0297, not through §2.1's hard-error/exit-2 path.** This is a deliberate
difference from every other directive error in this spec. §5.1's forms are
one-per-file and a broken one invalidating the *entire file's* run (findings
withheld, exit 2) is a proportionate cost. `allow` is one-per-call-site, and a
sweep touching hundreds of them cannot have call site #200's typo blank out
every finding call sites #1-#199 already fixed. The underlying finding an
invalid `allow` was aimed at is **never suppressed** by the attempt — a
broken override must not make its target silently vanish. A bare
`// bit:lint allow` with no code following is not a directive at all: it
suppresses nothing and is not a defect either (no E0297), a deliberate escape
hatch distinct from `disable`'s stricter "a rule name is mandatory" rule,
since a template or placeholder comment must not itself become a lint
finding.

**A valid, matching `allow` counts toward the `overrides active` summary
(§2.2), the same as a file-scoped override in force** — the same
transparency argument applies: a silenced finding must be visible in the
run's own numbers even when the `allow` line itself is skimmed past in
review. `--stats` (§2, `--stats` lists overrides without computing findings)
does **not** enumerate individual `allow` directives or count them: it
short-circuits before findings are ever computed for a file, so it has
nothing to check `allow` against. This is a known scope boundary, not an
oversight — `--stats`'s per-path listing stays scoped to the file-scoped
`<rule>=<n>`/`disable` forms it always covered.

## 6. Output

Human-readable output reuses the existing diagnostic renderer — same span,
caret, and hint machinery as `bit check`:

```
warning[E0200]: file is 1204 lines, limit is 800
  --> compiler/lower.bit:1:1
  = hint: split it, or raise the limit with
          `// bit:lint max-file-lines=1204 -- <reason>`
```

`--json` emits the schema `bit check --json` already produces
([compiler/diagnostics.bit](../compiler/diagnostics.bit)), so editors and CI parse
one format for both tools.

## 7. Integration

- **Editor.** `bit lsp` publishes lint findings alongside check errors. Same
  transport, distinguished by severity — warnings render as warnings.
- **CI.** `bit lint` runs as its own step. It does not gate `bit build`.
- **`bit fmt`.** No interaction. fmt never reads a lint directive, and lint
  never reports anything fmt would have fixed.

## 8. Testing

A new golden mode, `// lint`, joins the existing set in
[_tests_/bit/golden.bit](../_tests_/bit/golden.bit). A case runs `bit lint` over the
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
- a per-finding `allow` (§5.5) with an adequate reason directly above a
  matching finding: the finding is gone, exit 0
- the identical `allow`, with an inadequate reason: `E0297` AND the original
  finding are both reported, exit 1

## 9. Implementation surface

| File | Change |
|---|---|
| `compiler/lint.bit` | new — registry, directive reader, runner, rule passes |
| `compiler/lintallow.bit` | new — per-finding `allow` override (§5.5, #2438) |
| `compiler/lintcheck.bit` | new — in-Bit self-checks, run by `selfcheck()` |
| `compiler/main.bit` | `lint` subcommand dispatch |
| `_tests_/bit/lintcmd/lintcmd.bit` | CLI contract: exit codes, walk, summary, `--json`, `--stats` |
| `_tests_/bit/golden.bit` | `// lint` directive |
| `_tests_/cases/lint_*.bit` | golden cases |
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
