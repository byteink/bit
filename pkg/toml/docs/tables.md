# Tables

TOML gives you four ways to write nested structure - `[table]`, dotted keys,
`[[array of tables]]`, and inline `{ }` - and all four decode onto the same
two `Toml` variants, `TomlTable` and `TomlArray`. This chapter is about
reading whichever one a file actually used.

`deploy.toml` ([Parsing](parsing.md)) uses all four:

```toml
[server]
host = "0.0.0.0"
port = 8080
tls = true
healthcheck = { path = "/health", interval_s = 5 }

[server.limits]
max_connections = 1024
request_timeout_ms = 30000

[[server.routes]]
path = "/health"
handler = "health_check"

[[server.routes]]
path = "/metrics"
handler = "metrics"

[metadata]
contact.name = "Ops Team"
contact.email = "ops@waypoint.dev"
```

## `[table]` and dotted keys are the same tree

`[server.limits]` and a dotted key like `contact.name` both build the same
shape: a table nested inside another table. Reading either one is
`tomlAsTable` twice, once per level - there is nothing special about the
dotted spelling once the document is parsed:

```bit
import { Toml, TomlEntry, tomlAsString, tomlAsTable } from "toml"

fn field(entries: []TomlEntry, key: string): Toml! {
  for e of entries {
    if (e.key == key) {
      return e.value
    }
  }
  fail newError("no such key: '${key}'")
}

fn subTable(entries: []TomlEntry, key: string): []TomlEntry! {
  let sub = tomlAsTable(field(entries, key)?)
  match (sub) {
    Some(t) => { return t }
    None => { fail newError("'${key}' is not a table") }
  }
}

fn contactEmail(root: []TomlEntry): string! {
  let metadata = subTable(root, "metadata")?
  let contact = subTable(metadata, "contact")?
  for e of contact {
    if (e.key == "email") {
      return unwrap(tomlAsString(e.value))
    }
  }
  fail newError("contact has no email")
}
```

`contact.name = "..."` and `contact.email = "..."` in the source produce one
`metadata.contact` table with two entries - the same `[]TomlEntry` you would
get from writing `[metadata.contact]` as its own header instead. Pick
whichever spelling reads better in the file; the parsed value cannot tell
them apart.

## `[[array of tables]]`

`server.routes` is a `TomlArray` whose every element is itself a
`TomlTable` - `tomlAsArray` once, then `tomlAsTable` per element, the same
two accessors as anything else:

```bit
import { tomlAsArray } from "toml"

class Route { path: string, handler: string }

fn routes(server: []TomlEntry): []Route! {
  let arr = unwrap(tomlAsArray(field(server, "routes")?))
  let out = []Route(0, len(arr))
  for item of arr {
    let t = unwrap(tomlAsTable(item))
    let path = unwrap(tomlAsString(field(t, "path")?))
    let handler = unwrap(tomlAsString(field(t, "handler")?))
    out = append(out, Route{ path: path, handler: handler })
  }
  return out
}
```

A single `[[server.routes]]` block with no entries at all would still parse
as a one-element array - TOML has no way to write a zero-length array of
tables with the header form. An empty list in the source is always the
inline `routes = []` spelling instead, which decodes the same way any other
empty `TomlArray` does.

## Inline tables

`healthcheck = { path = "/health", interval_s = 5 }` decodes to a
`TomlTable` exactly like `[server.healthcheck]` would - `tomlAsTable` does
not know or care which syntax produced the value:

```bit
fn healthcheckPath(server: []TomlEntry): string! {
  let hc = unwrap(tomlAsTable(field(server, "healthcheck")?))
  return unwrap(tomlAsString(field(hc, "path")?))
}
```

The one real difference is source-only: an inline table closes the moment
its `}` is read, so nothing later in the document can add another key to
it - `[server.healthcheck]` appearing further down the file would be a
redefinition error, not an extension. [Errors](errors.md) covers that
rejection and the ones next to it.

Next: [Encoding](encoding.md), to write a `Toml` value back out as text.
