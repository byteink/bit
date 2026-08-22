# `bit lint`

A human-readable companion to [spec/LINT.md](../../spec/LINT.md), the
authority for `bit lint`'s rules, override grammar, and CLI contract. Where
the two ever disagree, the spec wins and this page is the bug.

`bit lint` is the third source tool, alongside `bit fmt` and `bit check`, and
each answers a different question:

- **`bit fmt`** - does it look right? Rewrites the file.
- **`bit check`** - is it correct? Errors, fails the build.
- **`bit lint`** - is it healthy? Warnings, fails only its own exit code.

A correct program must not stop compiling because a file reached 801 lines -
that is what makes lint a separate command with its own exit code rather than
a set of `bit check` errors. Lint reports only what the checker does not
consider an error and the formatter cannot mechanically fix: file and function
growth, dead code, and a couple of Bit-specific footguns the type system
cannot express.

## Running it

```
bit lint [--json] [--stats] [paths...]
```

`paths` may be files or directories; a directory walks recursively for
`*.bit`. With no paths, it lints `.`.

| Exit code | Meaning |
| --- | --- |
| 0 | no findings |
| 1 | at least one finding |
| 2 | usage error, unreadable path, malformed override directive, or a file `bit check` would reject |

Every run prints a summary line to stderr, including clean runs, and it is
never suppressed by a flag:

```
lint: 0 findings, 3 overrides active
```

The override count matters on its own: any limit can be raised by editing the
source, and this is the number that makes that visible in review even when the
override line itself is skimmed past.

`--json` prints findings to stdout in the same shape `bit check --json`
already uses. `--stats` prints the overrides in force (`<path>: <rule>=<n>` or
`<path>: disable <rule>`) and no findings.

## The 11 rules

| Code | Rule | Default | What it means when it fires |
| --- | --- | --- | --- |
| E0200 | `max-file-lines` | 800 | The file has stopped being one idea. |
| E0201 | `max-fn-lines` | 80 | The function does not fit on a screen; it cannot be checked by eye. |
| E0202 | `max-params` | 5 | The call site has stopped being readable; group the arguments into a class. |
| E0203 | `max-nesting` | 4 | This is almost always a missing early return. |
| E0204 | `max-complexity` | 10 | Cyclomatic complexity - too many independent paths through one function to reason about. |
| E0205 | `defer-in-loop` | - | A `defer` lexically inside a `while`/`for` runs at function exit, not loop exit - it holds whatever it acquired for the rest of the function. |
| E0210 | `unused-import` | - | An import nothing in the file reads; it misleads the next reader about the file's dependencies. |
| E0211 | `unused-local` | - | A `let`/`const` nothing reads; almost always a leftover from a refactor. |
| E0212 | `unreachable-code` | - | A statement after one that always diverges (`return`/`fail`/`break`/`continue`/`panic`) in the same block. |
| E0213 | `shadowed-local` | - | An inner `let`/`const` hides a name already bound in an enclosing scope; later edits to either binding silently change which one is read. |
| E0214 | `append-aliasing` | - | `append` on a slice **parameter** grows it in place and aliases the caller's backing array - the caller may see writes it never made. |

A rule with a default is a **threshold** rule: its override takes a value
(`rule=N`). A rule with no default (` - ` above) is **boolean**: the only
override it accepts is `disable`.

### Phase 1 - size and shape (E0200–E0205)

These need only the token stream and the AST, and land first for that reason.

- **`max-file-lines`** counts *physical* lines, including blanks and
  comments - the reader pays for those too, so they count.
- **`max-fn-lines`** counts from the line of the `fn` keyword (or an
  arrow's own start) through the line of its closing brace, inclusive.
- **`max-params`** counts declared parameters; a method receiver never
  counts.
- **`max-nesting`** counts nested blocks inside a function body, the body
  itself at depth 0. `if`, `while`, `for`, a `match` arm, and a `catch` block
  each add one.
- **`max-complexity`** is McCabe cyclomatic complexity: start at 1, add one
  for each `if`, `while`, `for` (any of its four forms), a `match` arm, a
  `catch` (either form), and `&&`/`||`. It measures something different from
  `max-fn-lines`: a long flat function is readable and a short tangled one is
  not, so both rules stay - neither catches the other's case.
- **`defer-in-loop`** is lexical scope only, on purpose. A `defer` inside a
  function merely *called* from a loop is not reported - that needs a
  whole-program view this rule deliberately avoids, and a rule that is
  occasionally wrong becomes a rule everyone silences. A `defer` inside an
  arrow function's own body is not reported either, even when the arrow sits
  inside a loop: it binds to the closure's own frame and runs when the arrow
  returns, not when the enclosing function does.

`unreachable-code` (E0212) is grouped with the phase-2 rules below by number - it was assigned its code before the dependency analysis that showed it
needs no resolver was done, and diagnostic codes are never renumbered once
assigned. It reuses the same divergence analysis `bit check` already uses for
missing-return (E0055) and catch-block completeness, so it never disagrees
with the checker about what "always diverts control" means.

### Phase 2 - dead weight and footguns (E0210, E0211, E0213, E0214)

These need the resolver's per-node symbol table, so they land after phase 1.

- **`unused-import`** / **`unused-local`** read whether a binding is ever
  referenced anywhere in the file, including from inside a nested block or a
  closure - a reference resolves to the specific symbol it binds to,
  wherever it sits, so there is no separate "but it's used in a closure"
  case to special-case. An assignment alone (`x = 1`) is not a use; the
  binding must be *read*. The blank identifier (`_`, or `import { f as _ }`)
  never becomes a symbol at all, so it is exempt with no special-casing.
  `unused-local` only looks at function/block-local bindings, not top-level
  module `let`/`const`.
- **`shadowed-local`** closes a real gap: the resolver already warns when a
  name shadows a *predeclared* identifier, but says nothing when an inner
  `let` hides an outer **local** - this rule is exactly that missing case,
  and it never double-reports what the predeclared-shadow warning or a
  same-scope redeclaration error already covers. A parameter or receiver
  shadowing an outer name is deliberately not reported: a parameter's whole
  lexical extent *is* the function body, so there is no earlier read whose
  meaning silently changes the way a mid-block `let` has.
- **`append-aliasing`** fires when `append`'s first argument resolves to a
  slice-typed **parameter** and the result is not assigned straight back to
  that same parameter. It is deliberately narrow: never a class field or a
  call result, and it never tries to prove the caller actually reuses the
  slice afterward - the one shape it accepts as "this function owns it" is
  the exact `p = append(p, x)` reassignment. This is the rule most likely to
  need overriding, since a parameter a function genuinely owns looks
  identical, from the AST, to one the caller still holds.

### Why there is no column-width rule

Line width is `bit fmt`'s job, not lint's - `bit fmt` already wraps
bracketed lists at 100 columns. The one case fmt cannot help is a long token
that cannot be broken (an embedded blob literal, say); a column rule would
fire on exactly that case and nobody could fix it, so it does not exist.

## Overrides

A file can override a rule's default or disable it entirely with a comment
in its **leading comment block** - the unbroken run of `//` lines at the top
of the file. A blank line ends the block, and so does the first declaration:

```
// bit:lint <rule>=<n> -- <reason>
// bit:lint disable <rule> -- <reason>
```

The reason is mandatory - not a stylistic nicety, but the whole review
signal an override carries. A directive with no reason, no `=`, an
unparseable number, or an unknown rule name is a hard error (exit 2), never
a silent no-op - and so is a well-formed directive found AFTER the leading
block ends: every rule's own fix hint is rendered at the offending
construct's span, which is the strongest possible signal that the directive
belongs there, and it is the one placement that never applies it. `bit lint`
reports it (also exit 2) rather than accepting it as an ordinary comment,
pointing at the misplaced `// bit:lint` line and naming the fix. A `bit:`
line for another tool (`// bit:fmt ...`) is still skipped wherever it sits -
this check is specific to `bit:lint`.

Deliberately **not** pinned to line 1: a golden test case's line 1 is
already spoken for by the test harness's own mode directive, so the override
directive can sit on line 2 or later in the same leading comment block.

```bit
// compiler/lower.bit - AST -> SSA IR lowering.
// bit:lint max-file-lines=6869 -- known debt (5-8x the
// limit); stamped at its current size, not a target to grow toward.
```

Precedence is simple and total: **built-in default < file directive**, and
nothing else - no per-directory config, no project manifest, no CLI flag
that changes a limit. Only the file itself decides its own limits, in a
comment any reviewer already reads alongside the code.

Only lint reads these comments. `bit check` never does - a comment
deciding whether code compiles would be a bad property to give a compiler,
so the worst an override can do is make a lint *step* pass.

### Stamping: how a repo adopts this without a baseline file

A file already over a threshold on the day the rule lands gets stamped with
its **current** measurement, not a bigger number and not `disable`:

```
// bit:lint max-file-lines=1300 -- 11 rules landed in one file per the
// registry design; split when a 12th rule pushes it further.
```

The stamped number is the ratchet: it freezes the file at its present size,
so any *further* growth fails, and the only way the number moves is down, as
the file gets split. There is no separate baseline file to keep in sync -
the override *is* the record, sitting next to the code it describes.

Prefer fixing over stamping for `unused-import`/`unused-local`: a dead
import or a leftover binding should be deleted, not excused with a comment.
For `append-aliasing`, prefer the narrower per-finding `allow` below over a
file-wide `disable` - it silences only the call site actually reviewed, not
every genuine hit elsewhere in the file.

### Per-finding overrides: `allow` (E0297)

The forms above are file-scoped. A second, narrower form silences exactly
**one finding**: `// bit:lint allow <CODE> -- <reason>`, placed on the line
directly above the finding it targets.

```bit
fn leak(buf: []int, x: int): []int {
  // bit:lint allow E0214 -- buf is owned entirely by this function, never returned
  let r = append(buf, x)
  return r
}
```

It exists for rules that are not always distinguishable from the AST -
`append-aliasing` (E0214) is the motivating case. Disabling that rule for a
whole file would also blind it to every genuine aliasing bug elsewhere in the
same file; `allow` silences only the one call site the author reviewed.

It differs from the file-scoped forms in every dimension that matters:

- **Placement.** Recognised anywhere in the file, not only the leading
  comment block - on the line immediately *above* the finding. One line below
  is not enough, and it is never reported as a misplaced directive (that
  check is specific to the file-scoped forms).
- **Target.** Named by diagnostic code (`E0214`), not rule name - the string
  already printed on the finding, copy-pasteable from the terminal. The code
  must match the finding directly below it exactly; a directive naming a
  different (but otherwise valid) code, or sitting above a line with no
  matching finding at all, is silently inert, not an error.
- **Scope.** Only rules with no numeric limit accept `allow` - the five
  threshold rules (`max-file-lines`, `max-fn-lines`, `max-params`,
  `max-nesting`, `max-complexity`) are excluded. A per-line escape hatch
  there would undo the reason those rules are file-scoped: the cost of a
  file-wide override is what makes splitting the offending function or file
  the cheaper path.
- **Reason floor.** At least 10 characters after trimming - stricter than the
  file-scoped forms' bare non-empty check, because `allow` is meant to be
  stamped roughly once per call site across a sweep, exactly where a
  placeholder like `"x"` would otherwise pass unnoticed.
- **Malformed `allow`.** An ineligible or unregistered code, a missing `--`,
  or a reason under 10 characters is reported as an ordinary finding, code
  **E0297**, not through the exit-2 hard-error path the file-scoped forms
  use - a broken `allow` in a hundred-site sweep must not blank out the other
  ninety-nine findings. The finding a broken `allow` was aimed at is never
  suppressed by the attempt. A bare `// bit:lint allow` with nothing after it
  is not a directive at all: it suppresses nothing and is not itself a
  finding.

A valid, matching `allow` counts toward the `overrides active` summary the
same as a file-scoped override in force. `--stats` does not enumerate
individual `allow` directives - it stays scoped to the file-scoped `<rule>=<n>`
/`disable` forms it always covered.

## Editor and CI integration

`bit lsp` runs lint's rules over every open file alongside `bit check` and
publishes both through the same `textDocument/publishDiagnostics`,
distinguished by severity: a check error renders as an error, a lint finding
as a warning. Unlike the CLI, a malformed `// bit:lint` directive does not
stop the file's other findings from being computed in the editor - killing
hover and completion over a typo'd override would be exactly the kind of
collateral the CLI's own exit-2 gate is spared from causing here. Only a
file that fails to parse skips lint entirely, the same as it does for
`bit check`.

In CI, `bit lint` runs as its own step and does not gate `bit build` - a
lint finding fails only the lint step's exit code, never the build.
