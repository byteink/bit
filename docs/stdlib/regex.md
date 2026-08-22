# std/regex

Regular expressions, RE2 syntax, matched by linear-time NFA simulation (a
Pike VM, #2027) rather than backtracking. Backreferences and lookaround are
never accepted, not merely unimplemented: both require backtracking to
evaluate, and a backtracking matcher cannot give a statically bounded loop
count for every pattern — which means a service that compiles a
user-supplied pattern is one crafted input away from a denial of service.
Trading that away is the whole point of this module: match time is
`O(len(pattern) x len(input))`, however the pattern is shaped.

This first ticket parses a pattern into an AST and validates it — `compile`
rejects anything malformed with a `regex: <reason> at offset <n>` error, at
the exact byte the syntax breaks down. Matching (`Regex.matches`, `find`,
capture groups) lands in later tickets; nothing here matches anything yet.

A compiled `Regex` is **immutable** and **safe to share across any number of
green threads** — the natural usage is one `mustCompile` call, shared by
every request handler an HTTP server spawns, rather than recompiling the
same pattern per request.

<!-- doctest: per-block -->

### `Regex`

A compiled, validated regular expression. Opaque: its only public operations
are `pattern()` and `groupCount()` below (plus matching, once #2027 lands).

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
