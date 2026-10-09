# Lint

`bit lint` is the third source tool, alongside `bit fmt` and `bit check`,
and each answers a different question:

- **`bit fmt`** - does it look right? Rewrites the file.
- **`bit check`** - is it correct? Errors, fails the build.
- **`bit lint`** - is it healthy? Warnings, fails only its own exit code.

A correct program must not stop compiling because a file reached 801
lines - that is why lint is a separate command with its own exit code
rather than a set of `bit check` errors. Lint reports only what the checker
does not consider an error and the formatter cannot mechanically fix: file
and function growth, dead code, and a handful of Bit-specific footguns the
type system cannot express. `spec/LINT.md` is the full grammar for every
rule and override; this page is the plain-English tour.

## Running it

```
bit lint [--json] [--stats] [paths...]
```

`paths` may be files or directories; a directory walks recursively for
`.bit` files. With no paths, it lints `.`.

| Exit code | Meaning |
| --- | --- |
| 0 | no findings |
| 1 | at least one finding |
| 2 | a usage error, an unreadable path, a malformed override, or a file `bit check` would reject |

Every run prints a summary line to stderr, including clean runs:

```
lint: 0 findings, 3 overrides active
```

`--json` prints findings to stdout as JSON. `--stats` prints the overrides
in force instead of findings.

## The rules

| Rule | Default limit | What it means when it fires |
| --- | --- | --- |
| `max-file-lines` | 800 | The file has stopped being one idea. |
| `max-fn-lines` | 80 | The function does not fit on a screen; it cannot be checked by eye. |
| `max-params` | 5 | The call site has stopped being readable; group the arguments into a class. |
| `max-nesting` | 4 | This is almost always a missing early return. |
| `max-complexity` | 10 | Too many independent paths through one function to reason about (cyclomatic complexity). |
| `defer-in-loop` | - | A `defer` lexically inside a `while`/`for` runs at function exit, not loop exit: each iteration schedules its own call, and every one holds what it acquired until the function returns. |
| `unused-import` | - | An import nothing in the file reads. |
| `unused-local` | - | A `let`/`const` nothing reads - almost always a leftover from a refactor. |
| `unreachable-code` | - | A statement after one that always exits the block (`return`/`fail`/`break`/`continue`/`panic`). |
| `shadowed-local` | - | An inner `let`/`const` hides a name already bound in an enclosing scope. |
| `append-aliasing` | - | `append` on a slice parameter grows it in place and aliases the caller's backing array - the caller may see writes it never made. |
| `unused-result` | - | A bare call whose result is thrown away with no assignment at all. |
| `empty-test-file` | - | A `.test.bit` file declares no tests - almost always a rename that lost its content. |

A rule with a default limit takes a numeric override (`rule=N`). A rule with
no default is boolean - the only override it accepts is `disable`.

**`max-complexity` and `max-fn-lines` measure different things**, and both
stay for that reason: a long flat function (one branch per case, each
trivial) is readable and a short tangled one is not. If a function trips
one of these and you're deciding whether to split it or raise the limit,
check whether it also trips `max-nesting` on the same function - a function
that is long or complex but not nested is usually flat and safe to allow; a
function that is also nested is usually genuinely tangled and worth
splitting.

## Overrides

A file can override a rule's default, or disable it, with a comment in its
leading comment block - the unbroken run of `//` lines at the top of the
file:

```
// bit:lint <rule>=<n> -- <reason>
// bit:lint disable <rule> -- <reason>
```

The reason is mandatory. A directive with no reason, no `=`, an unparsable
number, or an unknown rule name is a hard error (exit 2), never a silent
no-op.

```bit
// draftstore.bit - the file store for saved drafts.
// bit:lint max-file-lines=900 -- every function here reads one record shape;
// splitting it would only move the boundary, not shrink it.
```

Prefer fixing over overriding for `unused-import`/`unused-local`: delete the
dead import or binding rather than excuse it with a comment. When you do
raise a threshold rule for a function that is genuinely flat rather than
excusing tangled logic, stamp it at the function's *current* size - the
number is a ratchet, and it should only ever move down as the file shrinks.

## Per-finding overrides: `allow`

The forms above are file-scoped. A narrower form silences exactly one
finding: `// bit:lint allow <CODE> -- <reason>`, placed on the line directly
above the finding it targets, named by the diagnostic code printed on the
finding (for example `E0214`):

```bit
fn keepRef(buf: []int, x: int): []int {
  // bit:lint allow E0214 -- buf is owned entirely by this function, never returned
  let r = append(buf, x)
  return r
}
```

It exists for rules the checker cannot always tell apart from the code
shape alone, `append-aliasing` being the clearest example: disabling that
rule for a whole file would also blind it to every genuine aliasing bug
elsewhere in the same file, where `allow` silences only the one call site
you actually reviewed. Only rules with no numeric limit accept `allow`; the
five threshold rules do not, on purpose - the cost of a file-wide override
is what makes splitting the function the cheaper path for those.

## Editor and CI integration

`bit lsp` runs lint's rules over every open file alongside `bit check` and
reports both through the editor's normal diagnostics, distinguished by
severity: a check error renders as an error, a lint finding as a warning.

In CI, run `bit lint` as its own step; it does not gate `bit build` - a lint
finding fails only the lint step, never the build.

## Where next

[Packages](packages.md) covers `bit add`/`bit up`/`bit remove`, the other
half of keeping a project healthy day to day.
