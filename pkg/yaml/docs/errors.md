# Errors

<!-- doctest: per-block -->

Every failure this package raises - a malformed document, an undefined
alias, a value with no YAML spelling - surfaces the same way: the fallible
call returns `error`, the plain `message(): string` interface every
fallible function in Bit uses. There is no package-specific error type to
import and no field to pull a structured reason out of; the reason is the
message text.

## Catching one

```bit
import { yamlParse } from "yaml"

fn parseOrReport(src: string): ()! {
  yamlParse(src) catch e {
    eprint("yaml: ${e.message()}\n")
    return
  }
  return
}
```

## Byte offsets, and where they stop

Most of this package's own errors - anything the scanner, the block-context
parser, the flow-collection parser or the scalar decoder raises - name the
exact byte offset that went wrong, formatted as `"... at byte N"`:

```bit
import { contains } from "std/strings"
import { yamlParse } from "yaml"

fn main(): ()! {
  let failed = false
  yamlParse("key: [1, 2\n") catch e {
    failed = true
    assert(contains(e.message(), "at byte"), e.message())
    return
  }
  assert(failed, "an unterminated flow sequence is a named byte offset, not a silent truncation")
  return
}
```

Two error sources do NOT carry a byte offset, and this package does not
pretend otherwise: `scan`'s `maxDocumentBytes` check runs before a single
byte is scanned, so there is no position to name yet; every anchor/alias
budget error (`maxAliasExpansions`, `maxDepth`, `maxTotalNodes`) names the
alias and the limit it hit instead of a position, since the violation is a
running total across the whole document, not one byte:

```bit
import { contains } from "std/strings"
import { YamlLimits, YamlOptions, yamlParseWith, yamlResolveScalar } from "yaml"

fn main(): ()! {
  let limits = YamlLimits{
    maxDepth = 128,
    maxAliasExpansions = 1,
    maxTotalNodes = 1_000_000,
    maxDocumentBytes = 10_000_000,
  }
  let opts = YamlOptions{ limits = limits, resolver = yamlResolveScalar }
  let src = "value: &shared 1\nfirst: *shared\nsecond: *shared\n"

  yamlParseWith(src, opts) catch e {
    assert(contains(e.message(), "maxAliasExpansions"), e.message())
    assert(!contains(e.message(), "at byte"), "a budget error names the limit, not a position")
    return
  }
  fail newError("expected the second alias to exceed the budget")
}
```

## What gets rejected, and why

* **A duplicate key.** The same key appearing twice inside one mapping -
  block or flow style - fails rather than letting the second write win
  silently.
* **Merge keys (`<<`).** YAML 1.1's merge-key mapping shorthand is
  explicitly out of scope for this package's 1.2 core-schema subset, and a
  document using one is rejected by name rather than silently treated as
  an ordinary string key `"<<"`:

  ```bit
  import { contains } from "std/strings"
  import { yamlParse } from "yaml"

  fn main(): ()! {
    let failed = false
    yamlParse("<<: *base\nname: a\n") catch e {
      failed = true
      assert(contains(e.message(), "merge keys"), e.message())
      return
    }
    assert(failed, "a merge key is a named rejection, not a silent string key")
    return
  }
  ```

* **More than one document where exactly one was asked for.** `yamlParse`
  (singular) fails naming the count it actually found rather than
  returning the first document and discarding the rest:

  ```bit
  import { contains } from "std/strings"
  import { yamlParse } from "yaml"

  fn main(): ()! {
    let failed = false
    yamlParse("a: 1\n---\nb: 2\n") catch e {
      failed = true
      assert(contains(e.message(), "found 2"), e.message())
      return
    }
    assert(failed, "yamlParse names the document count instead of picking one")
    return
  }
  ```

  Call `yamlParseAll` ([Parsing](parsing.md)) instead when a document
  stream might legitimately hold more than one.

* **An unterminated quoted or flow-collection scalar.** A `[`, `{`, `'` or
  `"` that never closes fails at the offset where the scan gave up, rather
  than reading past the end of the intended value into whatever comes
  next in the file.

* **Nesting or an alias chain past the budget.** [Anchors](anchors.md)
  covers all four limits and what happens at each one.

Next: [Conformance](conformance.md), for how "YAML 1.2" is actually
verified rather than just claimed.
