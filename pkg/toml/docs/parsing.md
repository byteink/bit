# Parsing

Turns TOML text into one `Toml` value you can walk with ordinary Bit code -
no reflection, no schema, no code generation step.

Say your service, `waypoint`, is deployed from a file an operator hand-edits:

```toml
name = "waypoint"
version = "1.4.2"
```

You need `name` and `version` out of that file before the program can do
anything else. `tomlParse` is the whole entry point:

```bit
import { tomlAsString, tomlAsTable, tomlParse } from "toml"

fn main(): ()! {
  let doc = tomlParse("name = \"waypoint\"\nversion = \"1.4.2\"\n")?
  let root = unwrap(tomlAsTable(doc))
  for e of root {
    match (tomlAsString(e.value)) {
      Some(s) => println("${e.key} = ${s}")
      None => println("${e.key} = <non-string>")
    }
  }
  return
}
```

`tomlParse(src): Toml!` fails on malformed input (see
[Errors](errors.md)) and otherwise returns one `Toml` - always a
`TomlTable` at the root, since a bare TOML document has no outer syntax of
its own. `tomlAsTable` gives you its entries back as `[]TomlEntry`, in the
order they appeared in the file: `TomlTable` is a slice, not a map, because
TOML tables have a defined source order and a map would throw it away.

## The real file

A real deploy config nests: a `[server]` section, a list of routes, a
database URL. Here is `deploy.toml` in full - the rest of this section
reads fields out of it:

```toml
name = "waypoint"
version = "1.4.2"
maintainers = ["ops@waypoint.dev", "dev@waypoint.dev"]

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

[database]
url = "postgres://db.internal:5432/waypoint"
pool_size = 10
retry_backoff = 0.5

[metadata]
deployed_at = 2024-03-14T09:00:00-07:00
built_at = 2024-03-14T16:00:00
release_date = 2024-03-14
build_started = 08:55:30
contact.name = "Ops Team"
contact.email = "ops@waypoint.dev"
```

`TomlEntry` has no map lookup built in - walking to `server.host` means
finding `"server"` among the root's entries, then `"host"` among that
table's own entries. A small helper does it once:

```bit
import { readFile } from "std/fs"
import { Toml, TomlEntry } from "toml"

fn field(entries: []TomlEntry, key: string): Toml! {
  for e of entries {
    if (e.key == key) {
      return e.value
    }
  }
  fail newError("no such key: '${key}'")
}

fn loadServerHost(path: string): string! {
  let src = readFile(path)?
  let root = unwrap(tomlAsTable(tomlParse(src)?))
  let server = unwrap(tomlAsTable(field(root, "server")?))
  return unwrap(tomlAsString(field(server, "host")?))
}
```

[Values](values.md) covers every scalar `field` can return, and
[Tables](tables.md) covers the nested and repeated shapes - `[server]`,
`[[server.routes]]`, the inline `healthcheck`, and `contact`'s dotted keys.

## Under the hood: the token stream

`tomlParse` is built on `lex`, this package's own tokenizer, which you can
call directly if you need the raw lexical structure - a syntax highlighter,
say, that wants every meaningful span without building a `Toml` tree at all:

```bit
import { TokenKind, lex } from "toml"

fn significantSpans(src: string): []string {
  let out = []string(0)
  for t of lex(src) {
    if (t.kind == TokenKind.Newline || t.kind == TokenKind.Eof) {
      continue
    }
    out = append(out, src[t.start:t.end])
  }
  return out
}
```

`Token` carries its `kind` and its `[start, end)` byte span, unnormalized -
quotes and brackets included exactly as written. `lex` never fails: an
unrecognized byte becomes one `Invalid` token rather than stopping the scan,
so a caller walking the stream directly decides for itself whether an
`Invalid` token is fatal.

Next: [Values](values.md), for every scalar type this package can hand you.
