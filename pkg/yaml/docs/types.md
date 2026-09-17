# Types

<!-- doctest: per-block -->

A YAML mapping's values are text on disk. Something has to decide that
`port: 8080` is an integer and `host: 0.0.0.0` is not, and that decision
has burned people before: a spreadsheet of country codes saved as YAML,
with Norway's `NO` written bare, came back from a YAML 1.1 parser as the
boolean `false`. This package pins **YAML 1.2's core schema**
(spec.yaml.org, 10.3.2), which closed exactly that hole, and this chapter
is the one place that says so plainly enough that nobody here gets bitten
by it twice.

## What gets typed, and what does not

`waypoint.yaml` ([Parsing](parsing.md)) has a `flags` block and a
`regions` list written the way an operator actually writes them:

```yaml
flags:
  debug: no
  metrics: off
  beta: y

regions:
  - us
  - eu
  - no
```

Under the 1.2 core schema, every one of those values stays a string.
`yes`, `no`, `on`, `off`, `y` and `n` are YAML **1.1** spellings for
booleans; 1.2's core schema recognizes only `true`/`True`/`TRUE` and
`false`/`False`/`FALSE`, so `flags.debug` and the `no` in `regions` both
come back `YamlString`, never `YamlBool`:

```bit
import { Yaml, YamlEntry, yamlAsMapping, yamlAsSequence, yamlAsString, yamlIsString, yamlParse } from "yaml"

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
  let src = "flags:\n  debug: no\n  metrics: off\n  beta: y\nregions:\n  - us\n  - eu\n  - no\n"
  let root = unwrap(yamlAsMapping(yamlParse(src)?))
  let flags = unwrap(yamlAsMapping(field(root, "flags")?))
  let debug = field(flags, "debug")?
  assert(yamlIsString(debug) && unwrap(yamlAsString(debug)) == "no", "debug stayed a string")

  let regions = unwrap(yamlAsSequence(field(root, "regions")?))
  let last = regions[len(regions) - 1]
  assert(
    yamlIsString(last) && unwrap(yamlAsString(last)) == "no",
    "the region code stayed a string too",
  )
  return
}
```

A caller who genuinely wants the YAML 1.1 reading has to do it themselves,
explicitly, after parsing - this package will not do it implicitly, in
either direction.

## The four tags, and nothing else

The core schema types exactly four things, everything else falls through
to `YamlString`:

- **null** - `null`, `Null`, `NULL`, `~`, and the empty scalar (`key:` with
  nothing after it).
- **bool** - `true`/`True`/`TRUE`, `false`/`False`/`FALSE`. Nothing else,
  ever - see above.
- **int** - decimal (`123`, `-4`), hex (`0x1F`), octal (`0o17`).
- **float** - `1.5`, `1.5e10`, `.inf`, `-.inf`, `.nan`.

`waypoint.yaml`'s `build.number: 010` is the sharpest edge in that list. A
bare leading zero is not decimal 10 and not legacy octal 8 - it is a
`YamlString` holding the exact text `"010"`. Only the explicit `0o`
prefix means octal:

```bit
import { yamlAsInt, yamlAsString, yamlIsInt, yamlIsString, yamlParse } from "yaml"

fn main(): ()! {
  let leadingZero = yamlParse("010")?
  assert(yamlIsString(leadingZero) && unwrap(yamlAsString(leadingZero)) == "010", "010 is a string")

  let explicitOctal = yamlParse("0o10")?
  assert(yamlIsInt(explicitOctal) && unwrap(yamlAsInt(explicitOctal)) == 8, "0o10 is 8")
  return
}
```

Two more edges that surprise people the first time, not the second:

- **Overflow is a string, not a wraparound.** A decimal, hex or octal
  literal past `i64` range fails to resolve as a number and falls all the
  way through to `YamlString` holding the original text - it never wraps
  to a smaller, wrong number.
- **NaN is never signed.** `.nan` has exactly one spelling family
  (`.nan`/`.NaN`/`.NAN`); there is no `-.nan`, matching IEEE 754's own
  NaN, which carries no meaningful sign.

## Only a plain scalar is typed

Every rule above applies to a **plain** scalar - unquoted text with no `|`
or `>` block marker. A quoted or block scalar is always a string,
regardless of what its text looks like. That is how a document author
opts a value out of typing on purpose: `"no"` is the string `"no"` whether
or not the core schema would have typed the bare spelling `no` as
something else, and it always would not (`no` stays a string either way -
try `"true"` instead to see the quoting actually change the outcome):

```bit
import { ScalarStyle, yamlIsBool, yamlIsString, yamlResolveScalar } from "yaml"

fn main(): ()! {
  let bare = yamlResolveScalar("true", ScalarStyle.Plain)
  assert(yamlIsBool(bare), "a plain 'true' is typed")

  let quoted = yamlResolveScalar("true", ScalarStyle.Quoted)
  assert(yamlIsString(quoted), "a quoted \"true\" stays a string")
  return
}
```

## Opting a whole parse out of typing

Sometimes every value in a document needs to stay a string - reading a
column of country codes or a `version: 1.20` field that must keep its
trailing zero, with no per-field quoting at all. `YamlOptions.resolver`
is where the default (`yamlResolveScalar`) is swapped for `yamlResolveRaw`,
which returns `YamlString` unconditionally regardless of style or content:

```bit
import {
  Yaml,
  YamlEntry,
  yamlAsMapping,
  yamlAsString,
  yamlDefaultOptions,
  yamlIsString,
  yamlParseWith,
  yamlResolveRaw,
} from "yaml"

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
  // yamlDefaultOptions() is exactly what yamlParse itself uses - starting
  // from it and swapping only the resolver keeps the budget the same and
  // changes nothing else.
  let opts = yamlDefaultOptions()
  opts.resolver = yamlResolveRaw
  let docs = yamlParseWith("version: 1.20\nenabled: no\n", opts)?
  let root = unwrap(yamlAsMapping(docs[0]))
  let version = field(root, "version")?
  assert(
    yamlIsString(version) && unwrap(yamlAsString(version)) == "1.20",
    "1.20 kept its trailing zero",
  )
  return
}
```

That last example reuses the `field` helper [Parsing](parsing.md)
introduces; a caller wiring this into a real program keeps one copy of it,
not one per call site.

Next: [Scalars](scalars.md), for the quoting styles and block-scalar forms
that produce the raw text this chapter types.
