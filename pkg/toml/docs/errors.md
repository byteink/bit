# Errors

Every failure this package raises - a malformed document, a value with no
TOML spelling - is the same type, `TomlError`, and every one of them names
the byte offset of the exact character it objects to. You are never left
turning a vague "parse failed" into a line and column yourself.

## Catching one

`tomlParse` and `tomlEncode` both return a fallible `Toml!`/`string!`. A
`catch` block gets you the raw `error` interface, but `TomlError` is the
concrete type underneath it, and its `offset` field is exported for exactly
this - a type assertion gets it back:

```bit
import { TomlError, tomlParse } from "toml"

fn parseOrReport(src: string): ()! {
  tomlParse(src) catch e {
    let (te, ok) = e.(TomlError)
    if (ok) {
      eprint("toml: ${e.message()} at byte ${te.offset}\n")
    } else {
      eprint("toml: ${e.message()}\n")
    }
    return
  }
  return
}
```

`TomlError.message()` already includes the offset in its text (`"toml: ...
(byte N)"`), so the `ok` branch above is for a caller who wants the number
on its own - highlighting the exact character in an editor, say - not for
one who only wants to print something readable.

## What gets rejected, and why

Every rejection below is `deploy.toml` ([Parsing](parsing.md)) with one line
changed:

* **A duplicate key.** `port = 8080` appearing twice inside `[server]`
  fails with `duplicate key 'port'` at the second one's own offset - TOML
  has no "last write wins" rule.
* **Redefining a table.** A second `[server]` header later in the file
  fails with `table 'server' redefined`. Extending `server` with more keys
  after the fact needs a dotted key or a nested header, never a repeated
  `[server]`.
* **Extending a closed inline table.** `healthcheck = { path = "/health" }`
  followed anywhere later by `healthcheck.timeout_s = 5` fails - an inline
  table closes at its own `}`, so nothing after it can add a key, the same
  rule [Tables](tables.md) names for `[server.healthcheck]`.
* **A value where a table was promised.** `server = "down for maintenance"`
  after `[server.limits]` has already opened `server` as a table fails:
  `server` is already a table, not a string, and cannot be redefined as one.
* **Nesting past the compiled-in limit.** `tomlParse` and the value
  constructors `tomlEncode` walks both refuse to recurse past
  `tomlMaxDepth` levels of `[`/`{` or table nesting - a malicious or
  malformed document with thousands of nested arrays fails loudly instead
  of growing the call stack without bound:

  ```bit
  import { tomlMaxDepth } from "toml"

  fn main(): ()! {
    println("this package refuses to parse or build past ${tomlMaxDepth} levels of nesting")
    return
  }
  ```

Every one of these is a real rejection this package's own test suite
exercises with the exact source text and the exact expected offset - see
`pkg/toml/parse.test.bit` if you want the precise inputs.

Next: [Conformance](conformance.md), for how "TOML 1.0.0" is actually
verified rather than just claimed.
