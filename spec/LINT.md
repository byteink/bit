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

### 2.1 Exit codes

| Code | Meaning |
|---|---|
| 0 | no findings |
| 1 | at least one finding |
| 2 | usage error, unreadable path, or malformed override directive |

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

## 3. Diagnostic codes

Lint reserves **E0200–E0299** in the central registry
([diagnostics.zig:44](../seed/diagnostics.zig#L44)), which documents the
per-stage range convention and the rule that a code is never renumbered once
shipped. Lint findings render through the existing path as
`warning[E0200]: ...`, so neither `codeString` nor the JSON emitter changes.

## 4. Rules

### Phase 1 — size and shape

These need only the token stream and the AST. No resolver, no type
information.

| Code | Rule | Default | Rationale |
|---|---|---|---|
| E0200 | `max-file-lines` | 800 | A file past this has stopped being one idea. |
| E0201 | `max-fn-lines` | 80 | A function that does not fit on a screen cannot be checked by eye. |
| E0202 | `max-params` | 5 | Past five, the call site stops being readable and the arguments want to be a struct. |
| E0203 | `max-nesting` | 4 | Deep nesting is nearly always a missing early return. |

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

### Phase 2 — dead weight

These need resolver output and land after phase 1.

| Code | Rule | Rationale |
|---|---|---|
| E0210 | `unused-import` | Left behind by refactors; misleads the next reader about a module's dependencies. |
| E0211 | `unused-local` | Same, at function scope. |
| E0212 | `unreachable-code` | Statements after `return`/`fail`/`break` in the same block. |

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

## 5. Overrides

### 5.1 Grammar

```
LintDirective = "//" ws "bit:lint" ws ( Assignment | Disable ) ws "--" ws Reason .
Assignment    = RuleName "=" Integer .
Disable       = "disable" ws RuleName .
RuleName      = { lower | "-" } .
Reason        = { any character } .          // to end of line, non-empty
```

Examples:

```
// bit:lint max-file-lines=7100 -- bootstrap oracle, split tracked in #1376
// bit:lint disable max-nesting -- generated dispatch table
```

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
file and compares stderr against the sibling `.expected`, matching how
`// error` cases work.

Required coverage:

- one case per rule, at the boundary: `limit` lines passes, `limit + 1` fails
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
| `selfhost/lint.bit` | new — rule passes over the AST |
| `selfhost/main.bit` | `lint` subcommand dispatch |
| `tests/harness.zig` | `.lint` directive |
| `tests/cases/lint_*.bit` | golden cases |
| `docs/reference/` | user-facing rule reference |

`seed/` is **not** touched. The seed compiler's remaining job is to be the
differential oracle for AST, type, and IR dumps; lint changes none of those, so
lint is selfhost-only and the differential stays valid.

## 10. Open questions

1. **Phase 2 placement.** `unused-import` / `unused-local` as lint warnings, or
   as `bit check` errors in Go's style? Decide before 1.0 (§4).
2. **Code prefix.** Lint reuses the `E` registry with a reserved range. A
   distinct `L%04d` prefix would be more greppable and could never collide as
   the error registry grows, at the cost of a change to `codeString` and the
   JSON emitter. Reversible only before the first release that ships these
   codes.
3. **Default values.** 800 / 80 / 5 / 4 are judgement calls, chosen to be
   restrictive enough to bite. Worth revisiting once the whole repo is under
   the limit and the real distribution is visible.
