# Parsing

<!-- doctest: per-block -->

Turns YAML text into one `Yaml` value you can walk with ordinary Bit code -
no reflection, no schema, no code generation step.

Say your service, `waypoint`, is deployed from a file an operator hand-edits:

```yaml
name: waypoint
version: "1.4.2"
```

You need `name` and `version` out of that file before the program can do
anything else. `yamlParse` is the whole entry point:

```bit
import { yamlAsMapping, yamlAsString, yamlParse } from "yaml"

fn main(): ()! {
  let doc = yamlParse("name: waypoint\nversion: \"1.4.2\"\n")?
  let root = unwrap(yamlAsMapping(doc))
  for e of root {
    match (yamlAsString(e.key)) {
      Some(k) => {
        match (yamlAsString(e.value)) {
          Some(v) => println("${k} = ${v}")
          None => println("${k} = <non-string>")
        }
      }
      None => {}
    }
  }
  return
}
```

`yamlParse(src): Yaml!` fails on malformed input (see [Errors](errors.md))
and otherwise returns exactly one `Yaml` value. Unlike a format such as
TOML, that value is not guaranteed to be a mapping: YAML has no implicit
top-level container, so a document that is just `42` or `- a\n- b\n` parses
to a bare `YamlInt` or `YamlSequence` at the root. Checking with
`yamlAsMapping` before walking the result as one, the way the example above
does, is how a caller finds out which it got instead of assuming.

`YamlEntry.key` is a `Yaml`, not a `string` - `e.key` above goes through
`yamlAsString` for the same reason `e.value` does. YAML permits a
non-scalar mapping key (a sequence or a mapping used as a key), so typing
`key` as a plain `string` would make that unrepresentable.

`yamlAsMapping` hands back `[]YamlEntry` in the exact order the document
wrote it, so a caller that cares about that order - re-emitting the file
with [Encoding](encoding.md), say - never loses it. That is preserving
fidelity to what was written, not a claim about equality: two YAML
mappings with the same keys and values in a different order are the same
value, the way two JSON objects are. [Conformance](conformance.md) has a
concrete case where the corpus's own reference data disagrees with itself
on order for exactly this reason.

## The real file

A real deploy config nests further: server settings, a list of regions, a
block of shared limits reused by more than one service. Here is
`waypoint.yaml` in full - the rest of this chapter, and every other
chapter, reads fields out of it:

```yaml
name: waypoint
version: "1.4.2"

server:
  host: 0.0.0.0
  port: 8080
  tls: true

flags:
  debug: no
  metrics: off
  beta: y

regions:
  - us
  - eu
  - no

build:
  number: 010

limits: &limits
  timeout_ms: 30000
  retries: 3

services:
  auth:
    limits: *limits
  billing:
    limits: *limits
```

`YamlEntry` has no map lookup built in - walking to `server.port` means
finding `"server"` among the root's entries, then `"port"` among that
table's own entries. A small helper does it once, comparing a plain key
against each entry's `Yaml` key through `yamlAsString`:

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

fn loadServerPort(src: string): i64! {
  let root = unwrap(yamlAsMapping(yamlParse(src)?))
  let server = unwrap(yamlAsMapping(field(root, "server")?))
  return unwrap(yamlAsInt(field(server, "port")?))
}
```

[Types](types.md) covers why `flags.debug` above comes back a `YamlString`
holding `"no"`, never a `YamlBool` - the chapter that matters most in this
package, and the reason `regions` ends with `no` rather than a two-letter
country code that would trip a YAML 1.1 reader instead. [Anchors](anchors.md)
covers `limits: &limits` and the two `*limits` aliases under `services`.

## Every variant, and its accessor pair

`Yaml` has seven variants, and a caller never matches on it directly the
way `field` above matches on the built-in `Option`: every variant instead
has a `yamlIsX`/`yamlAsX` pair - `yamlIsX` answers "is this one of those",
`yamlAsX` gives you the payload as an `Option`, `None` when it is not:

```bit
import {
  yamlAsBool,
  yamlAsFloat,
  yamlAsInt,
  yamlAsMapping,
  yamlAsSequence,
  yamlAsString,
  yamlIsBool,
  yamlIsFloat,
  yamlIsMapping,
  yamlIsNull,
  yamlIsSequence,
  yamlParse,
} from "yaml"

fn main(): ()! {
  assert(yamlIsNull(yamlParse("~")?), "~ is YamlNull")
  assert(unwrap(yamlAsBool(yamlParse("true")?)), "true is YamlBool")
  assert(unwrap(yamlAsInt(yamlParse("8080")?)) == 8080, "8080 is YamlInt")
  assert(unwrap(yamlAsFloat(yamlParse("0.5")?)) == 0.5, "0.5 is YamlFloat")

  let name = unwrap(yamlAsString(yamlParse("waypoint")?))
  assert(name == "waypoint", "a bare word is YamlString")

  assert(len(unwrap(yamlAsSequence(yamlParse("[us, eu]")?))) == 2, "[us, eu] is YamlSequence")
  assert(yamlIsMapping(yamlParse("{host: 0.0.0.0}")?), "{...} is YamlMapping")
  assert(!yamlIsFloat(yamlParse("8080")?), "and an int is never also a float")
  return
}
```

## Under the hood: the token stream

`yamlParse` is built on `scan`, this package's own tokenizer, exported for a
caller who wants the raw lexical structure directly - a syntax highlighter,
say, that wants every meaningful span without building a `Yaml` tree at all:

```bit
import { TokenKind, scan, yamlDefaultLimits } from "yaml"

fn significantSpans(src: string): []string! {
  let out = []string(0)
  for t of scan(src, yamlDefaultLimits())? {
    if (t.kind == TokenKind.Eof) {
      continue
    }
    out = append(out, src[t.start:t.end])
  }
  return out
}
```

`Token` carries its `kind` and its `[start, end)` byte span, unnormalized.
`scan` is fallible: `yamlDefaultLimits().maxDocumentBytes` (the rest of the
budget is [Anchors](anchors.md)'s subject) is checked before a single byte
is scanned, so an oversized input fails here rather than returning a token
stream part way through.

Flow parsing (`yamlParseFlow` in `flow.bit`) is internal, not a second entry
point: it takes a `Scanner`, and `Scanner` is deliberately unexported (only
this package's own `scan` and parser drive it, mirroring
`stdlib/json/lex.bit`'s unexported `Lexer`). Flow collections (`[a, b]`,
`{a: b}`) work correctly through `yamlParse` itself, which is the only
documented entry point for a caller outside this package.

Next: [Types](types.md), for the implicit typing rules this package pins
and the Norway problem they exist to fix.
