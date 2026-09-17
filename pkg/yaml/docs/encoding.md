# Encoding

<!-- doctest: per-block -->

`yamlEncode` is `yamlParse` run backward: a `Yaml` value in, YAML text out.
You reach for it when your program builds or edits configuration rather
than only reading it - writing a fresh `waypoint.yaml`, or reading one,
changing a field, and saving it back.

## The simplest round trip

```bit
import { Yaml, YamlEntry, yamlEncode } from "yaml"

fn main(): ()! {
  let doc = Yaml.YamlMapping(
    [
      YamlEntry{ key: Yaml.YamlString("name"), value: Yaml.YamlString("waypoint") },
      YamlEntry{ key: Yaml.YamlString("version"), value: Yaml.YamlString("1.4.2") },
    ],
  )
  print(yamlEncode(doc)?)
  return
}
```

That prints:

```yaml
name: waypoint
version: "1.4.2"
```

`version` came back quoted even though nothing forced it to be a
`YamlString` on the way in - see the next section for why.

## The inverse Norway problem

[Types](types.md) covers how `flags.debug: no` reads back as a string. The
encoder has to protect the same fact in the other direction: if
`YamlString("no")` were written out bare, re-reading it would produce a
`YamlBool`, and the round trip would have silently changed the data's type.
Before emitting any string scalar, `yamlEncode` runs it through
`schema.bit`'s real resolver - `yamlResolveScalar` - and quotes it whenever
the result is not the same string back:

```bit
import { Yaml, yamlAsString, yamlEncode, yamlIsString, yamlParse } from "yaml"

fn main(): ()! {
  let text = yamlEncode(Yaml.YamlString("no"))?
  let back = yamlParse(text)?
  assert(
    yamlIsString(back) && unwrap(yamlAsString(back)) == "no",
    "\"no\" round-tripped as a string, not a bool",
  )
  return
}
```

Strings the core schema does not type at all - `"no"`, `"010"`, `"y"` - are
emitted bare, with no quoting "just in case": quoting a string that was
never going to be misread on the way back in is noise a reader of the
output file would have to explain to themselves for nothing.

## Round-tripping a real document

`yamlParse(yamlEncode(v)?)?` gets back a value equal to `v` for anything
`yamlEncode` accepts - nested mappings, sequences, and multiple documents
through `yamlEncodeAll`, which separates each with its own `---`:

```bit
import { Yaml, YamlEntry, yamlAsSequence, yamlEncodeAll, yamlParseAll } from "yaml"

fn main(): ()! {
  let docs = [
    Yaml.YamlMapping([YamlEntry{ key: Yaml.YamlString("name"), value: Yaml.YamlString("waypoint") }]),
    Yaml.YamlSequence([Yaml.YamlString("us"), Yaml.YamlString("eu")]),
  ]
  let text = yamlEncodeAll(docs)?
  let back = yamlParseAll(text)?
  assert(len(back) == 2, "yamlEncodeAll's --- separators round-tripped through yamlParseAll")
  assert(len(unwrap(yamlAsSequence(back[1]))) == 2, "the second document's sequence survived")
  return
}
```

## What `yamlEncode` refuses

Shared subtrees are written out in full - `yamlEncode` never emits an
anchor or an alias of its own, so it never has to decide an aliasing
policy for a value it did not parse from anchored text. That means a
cyclic `Yaml` value - a sequence holding itself - cannot be walked to
completion, and `yamlEncode` fails rather than recursing forever:

```bit
import { Yaml, yamlEncode } from "yaml"

fn main(): ()! {
  let inner = append([]Yaml(0), Yaml.YamlNull)
  inner[0] = Yaml.YamlSequence(inner)

  let failed = false
  yamlEncode(inner[0]) catch e {
    failed = true
    return
  }
  assert(failed, "a cyclic value fails fast instead of hanging")
  return
}
```

Next: [Errors](errors.md), for what every fallible call in this package
fails with, and why.
