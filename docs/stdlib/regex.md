# std/regex

Regular expressions, RE2 syntax, matched by linear-time NFA simulation (a
Pike VM) rather than backtracking. Backreferences and lookaround are never
accepted, not merely unimplemented: both require backtracking to evaluate,
and a backtracking matcher cannot give a statically bounded loop count for
every pattern — which means a service that compiles a user-supplied pattern
is one crafted input away from a denial of service. Trading that away is
the whole point of this module: match time is `O(len(input) x
len(program))`, however the pattern is shaped — there is no input that can
make it exponential, unlike a backtracking engine on a pattern such as
`(a?){n}a{n}`.

`compile` rejects a malformed pattern with a `regex: <reason> at offset <n>`
error, at the exact byte the syntax breaks down. `Regex.matches` runs the
compiled program against a string, an unanchored search (like Go's
`regexp.MatchString`). `Regex.find` and `Regex.findAll` report *where* a
pattern matched, as byte-offset spans (`Match`). Capture groups and named
groups land in a later ticket.

A compiled `Regex` is **immutable** and **safe to share across any number of
green threads** — the natural usage is one `mustCompile` call, shared by
every request handler an HTTP server spawns, rather than recompiling the
same pattern per request.

<!-- doctest: per-block -->

### Flags

Three inline flags, matching RE2/Go:

- **`i`** — case-insensitive matching. **ASCII-only**: it folds `A-Z` and
  `a-z` onto each other and nothing else. `(?i)café` does not match `CAFÉ` —
  the `é`/`É` pair is outside the fold. Full Unicode case folding is a
  separate module (a later ticket); this module never silently does more
  than the ASCII fold it documents.
- **`s`** — dot matches `\n` too. Without it, `.` matches every rune except
  `\n` (a lone `\r` always matches `.`, with or without `s` — only `\n` is
  ever excluded).
- **`m`** — multiline: `^` and `$` also match right after/before a `\n`, not
  only at the very start/end of the subject. **Without `m`**, `$` matches
  ONLY at the true end of the subject — like `\z`, not like Perl's default
  `$` — so `compile("a$").matches("a\n")` is `false`. `\A` and `\z` always
  mean the absolute start/end and ignore `m` either way.

Two syntactic forms:

- **`(?flags)`** — sets flags from that point to the end of the enclosing
  group, including any later `|` branch of that same group (`|` does not
  close a group). `(?-i)` clears a flag the same way; `(?im-s)` sets `i` and
  `m` and clears `s`, all in one.
- **`(?flags:...)`** — a non-capturing group whose flags apply only inside
  it; the outer state is restored, exactly, once its `)` closes — including
  when nested, and independently in each branch of an alternation.

```bit
import { mustCompile } from "std/regex"

fn isColorCI(s: string): bool {
  let re = mustCompile("(?i)^(red|green|blue)$")
  return re.matches(s)
}

fn firstSentence(s: string): string {
  // (?s) so a paragraph spanning newlines still has `.` reach the terminator.
  let re = mustCompile("(?s)^.*?[.!?]")
  return match (re.find(s)) {
    Some(m) => m.text(s)
    None => s
  }
}
```

An unknown flag letter (`(?x)`) is `regex: unknown flag at offset N`; an
empty flag list (`(?)`) is `regex: missing flags at offset N`.

### Counted repetition

`{n}` (exactly `n`), `{n,}` (`n` or more) and `{n,m}` (between `n` and `m`,
inclusive) — each optionally followed by `?` for the lazy form, same as
`*?`/`+?`/`??`. Greedy prefers more repetitions, lazy prefers fewer; both
still find the leftmost match, they differ only in how much of the string
that match covers. `{,m}` is **not** special — it is a literal five-byte
sequence, matching RE2/Go — and any `{...}` that is not a well-formed count
(a bare `{`, a non-numeric or empty count, an unterminated brace) is a
literal `{`, never a syntax error, exactly like Go's `regexp`.

```bit
import { mustCompile } from "std/regex"

fn isZipCode(s: string): bool {
  let re = mustCompile("^[0-9]{5}(-[0-9]{4})?$")
  return re.matches(s)
}
```

### Limits

Three hard caps, all enforced at compile time and reported as an ordinary
`compile` error rather than a panic or a silent truncation. Patterns are
frequently user-supplied — a search box, a validation rule, a router — so
compiling one must stay cheap and bounded no matter how it is shaped:

- **Pattern length**: 4096 bytes.
  `regex: pattern too long (max 4096 bytes)`.
- **A single repeat count** (`{n}`, or either bound of `{n,m}`): 1000.
  `regex: repeat count too large (max 1000) at offset N`.
- **Compiled program size**: 20000 instructions. Counted repetition compiles
  by literal expansion — `x{100}` is 100 separate copies of `x`'s own
  instructions — so nesting it is exponential in the source text:
  `((a{100}){100}){100}` is 20 bytes and would expand to 1,000,000
  instructions. This cap is enforced WHILE the program is being built, with
  a running counter, never by building it in full and measuring afterward —
  that would already have done the unbounded allocation the cap exists to
  prevent. `regex: pattern too complex (program exceeds 20000 instructions)`.

```bit
import { compile } from "std/regex"

fn compileUserPattern(pattern: string): string {
  let re = compile(pattern) catch e {
    return "rejected: ${e.message()}"
  }
  return "compiled: ${re.pattern()}"
}
```

`n > m` in a `{n,m}` (e.g. `a{5,2}`) is a separate, ordinary syntax error,
`regex: repeat count out of order at offset N` — not one of the three caps
above.

### `Regex`

A compiled, validated regular expression. Opaque: its only public operations
are `pattern()`, `groupCount()` and `matches()` below.

### `compile(pattern: string): Regex!`

Parses `pattern` and returns a validated `Regex`, or fails with a
`regex: <reason> at offset <n>` error naming the first place the syntax
breaks down. Never panics on bad input — `pattern` is exactly the kind of
untrusted, possibly-attacker-controlled string this module exists to handle
safely.

```bit
import { compile } from "std/regex"

fn describe(pattern: string): string {
  let re = compile(pattern) catch e {
    return "invalid: ${e.message()}"
  }
  return "valid: ${re.pattern()}"
}
```

### `mustCompile(pattern: string): Regex`

`compile`, panicking instead of returning an error. For a fixed pattern
known at write time — compiled once, then reused — where a malformed pattern
is a programmer error to catch during development, not a run-time condition
to recover from.

```bit
import { mustCompile } from "std/regex"

fn wordGroupCount(): int {
  let re = mustCompile("(a+)(b+)")
  return re.groupCount()
}
```

### `Regex.pattern(): string`

`re`'s source pattern, verbatim — exactly the string `compile` or
`mustCompile` was given.

### `Regex.groupCount(): int`

The number of capturing groups in `re`: `(...)`, `(?<name>...)` and
`(?P<name>...)`, not counting the implicit whole-match group 0 and not
counting a non-capturing `(?:...)`.

### `Regex.matches(s: string): bool`

Whether `re`'s pattern matches anywhere in `s` — an unanchored search, the
same convention as Go's `regexp.MatchString`: anchor the pattern itself
(`^`/`$`) for a whole-string match. Runs a Pike VM over `s`, one
left-to-right pass, so this always finishes in `O(len(s) x len(program))`
time; there is no backtracking, so no pattern and no input can make it
exponential.

```bit
import { mustCompile } from "std/regex"

fn isColor(s: string): bool {
  let re = mustCompile("colou?r")
  return re.matches(s)
}
```

### `Match`

A single match: `start` and `end` are **byte offsets**, never rune indices,
into the string `find`/`findAll` matched against — always safe to use
directly as `s[m.start:m.end]` slice bounds. Which capture group each offset
belongs to is not exposed yet; a later ticket adds `Match.group`/`.named`.

### `Match.text(s: string): string`

The substring of `s` this match covers, `s[m.start:m.end]`. `s` must be the
same string (or an identical copy) the match came from.

```bit
import { mustCompile } from "std/regex"

fn firstNumber(s: string): string {
  let re = mustCompile("[0-9]+")
  return match (re.find(s)) {
    Some(m) => m.text(s)
    None => ""
  }
}
```

### `Regex.find(s: string): Option<Match>`

The leftmost-first match of `re`'s pattern anywhere in `s`, or
`Option.None` when there is none — an unanchored search, the same
convention as `matches`.

```bit
import { mustCompile } from "std/regex"

fn idOf(s: string): string {
  let re = mustCompile("id=([0-9]+)")
  return match (re.find(s)) {
    Some(m) => m.text(s)
    None => "no id"
  }
}
```

### `Regex.findAll(s: string, limit: int): []Match`

Successive non-overlapping matches of `re`'s pattern in `s`, scanning left
to right. `limit < 0` means no limit; `limit == 0` returns an empty slice;
otherwise at most `limit` matches.

Offsets are **byte** offsets throughout, same as `Match`. After a match, the
next search starts at its end offset — except when the match is empty
(`start == end`), where the next search starts one **rune** later instead of
one byte later, so a multi-byte character is never split. Without that rule
`findAll("a*", "bb")` would never terminate; with it, `a*` over `"bb"`
yields three empty matches, at byte offsets 0, 1 and 2.

```bit
import { mustCompile } from "std/regex"

fn wordCount(s: string): int {
  let re = mustCompile("[A-Za-z]+")
  return len(re.findAll(s, -1))
}
```
