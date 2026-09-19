# Anchors

<!-- doctest: per-block -->

`waypoint.yaml` ([Parsing](parsing.md)) defines one `limits` block and
reuses it for two services rather than copying it twice:

```yaml
limits: &limits
  timeout_ms: 30000
  retries: 3

services:
  auth:
    limits: *limits
  billing:
    limits: *limits
```

`&limits` names the node; `*limits` substitutes it. `yamlParse` resolves
both transparently - a caller walking `services.auth.limits` and
`services.billing.limits` gets two equal `Yaml` values back with no idea an
alias was ever involved:

```bit
import { Yaml, YamlEntry, yamlAsInt, yamlAsMapping, yamlAsString, yamlParse } from "yaml"

fn field(entries: []YamlEntry, key: string): Yaml! {
  for e of entries {
    match (yamlAsString(e.key)) {
      Some(k) => {
        if (k == key) {
          return e.value
        }
      }
      None => {}
    }
  }
  fail newError("no such key: '${key}'")
}

fn main(): ()! {
  let src = "limits: &limits\n  timeout_ms: 30000\n  retries: 3\nservices:\n  auth:\n    limits: *limits\n  billing:\n    limits: *limits\n"
  let root = unwrap(yamlAsMapping(yamlParse(src)?))
  let services = unwrap(yamlAsMapping(field(root, "services")?))
  let auth = unwrap(yamlAsMapping(field(services, "auth")?))
  let authLimits = unwrap(yamlAsMapping(field(auth, "limits")?))
  let retries = unwrap(yamlAsInt(field(authLimits, "retries")?))
  assert(retries == 3, "the alias resolved to the anchored mapping")
  return
}
```

## Why reuse is a resource limit, not a convenience

An alias can point at an anchor that itself contains aliases, and expansion
is multiplicative: nine anchors, each referencing the previous one nine
times, is nine levels of nine-way nesting - the last level alone stands for
9^9, or 387,420,489, materialized nodes from well under a kilobyte of
source. That shape is the "billion laughs" attack: a tiny YAML document
that expands to gigabytes in memory the instant something reads it. This
package bounds every parse against a fixed budget (`pkg/yaml/value.bit`)
rather than trusting the document to be small just because it looks small
on disk:

* `maxDepth: 128` - nesting levels a document's mappings and sequences may
  reach, combined. Real documents rarely exceed 20-30 levels.
* `maxAliasExpansions: 100_000` - total alias resolutions permitted across
  one document. The nine-levels-of-nine example above would hit this at
  its sixth multiplicative level; real reuse (a shared set of anchors
  referenced a few dozen times each) stays in the low thousands.
* `maxTotalNodes: 1_000_000` - scalar and collection nodes materialized for
  one document, counting every alias expansion's copies. This is the
  actual memory bound: the expansion count alone caps how many times
  something is resolved, not how much each resolution copies.
* `maxDocumentBytes: 10_000_000` (10 MB) - the raw input size a document
  may be before parsing starts at all.

None of the four can be disabled or set to "unlimited" - every field of
`YamlLimits` is a plain `i64`, and a parse against them either finishes
inside the budget or fails naming which limit it hit:

```bit
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

  let failed = false
  yamlParseWith(src, opts) catch e {
    failed = true
    return
  }
  assert(failed, "the second alias exceeded maxAliasExpansions of 1 and the parse failed")
  return
}
```

A real document never sets `maxAliasExpansions` this low - the example
does it only to make the ceiling fire on two ordinary aliases instead of
nine levels of them.

## Under the hood: resolving an alias without a document

`AnchorTable` is what `yamlParse` builds and reads internally; it is
exported for a caller assembling `Yaml` values programmatically - a
template system building shared defaults at runtime, say - that wants the
same alias-safe substitution without writing YAML text first:

```bit
import { Yaml, newAnchorTable, yamlAnchorDefine, yamlAnchorResolve, yamlAsInt, yamlDefaultLimits } from "yaml"

fn main(): ()! {
  let t = newAnchorTable()
  yamlAnchorDefine(t, "shared", Yaml.YamlInt(1))?
  let resolved = yamlAnchorResolve(t, "shared", yamlDefaultLimits())?
  assert(unwrap(yamlAsInt(resolved)) == 1, "resolve gave back exactly what define stored")

  let failed = false
  yamlAnchorResolve(t, "missing", yamlDefaultLimits()) catch e {
    failed = true
    return
  }
  assert(failed, "resolving a name nothing defined is an error, never a default")
  return
}
```

`yamlAnchorResolve` charges its running budgets against the SAME
`AnchorTable` on every call for a whole document - never reset per anchor,
per call, or per node - because a cap that resets cannot bound a
multiplicative total the way the example above needs it to.

Next: [Encoding](encoding.md), to write a `Yaml` value back out as text.
