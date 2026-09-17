# Values

Every TOML scalar and the four date-time forms, and how each one comes back
as a typed Bit value instead of a bare string you have to reparse yourself.

`Toml` is a ten-variant enum - one arm per TOML scalar type, plus arrays and
tables. A caller never matches on it directly: an exhaustive match with one
arm per variant runs past this package's own function complexity ceiling
once you get to ten. Instead, every variant has a `tomlIsX`/`tomlAsX` pair:
`tomlIsX` answers "is this one of those", and `tomlAsX` gives you the
payload as an `Option`, `None` when it is not.

The four temporal arms are not new types - they reuse `std/time`'s own
`DateTime`, `NaiveDateTime`, `Date` and `Time`, the same ones you would
already use anywhere else in a Bit program:

| TOML form | `Toml` variant | Payload |
|---|---|---|
| string | `TomlString` | `string` |
| integer | `TomlInt` | `i64` |
| float | `TomlFloat` | `f64` |
| boolean | `TomlBool` | `bool` |
| offset date-time (`...-07:00` / `...Z`) | `TomlOffsetDateTime` | `std/time.DateTime` |
| local date-time (no zone) | `TomlLocalDateTime` | `std/time.NaiveDateTime` |
| local date | `TomlLocalDate` | `std/time.Date` |
| local time | `TomlLocalTime` | `std/time.Time` |
| array | `TomlArray` | `[]Toml` |
| table | `TomlTable` | `[]TomlEntry` |

## Reading a field, with the type checked

Trusting a config file's layout blindly turns a typo (`port = "8080"`
instead of `port = 8080`) into a panic three functions away from the parse
call. A small typed helper per scalar type, built on `tomlIsX`/`tomlAsX`,
catches it at the point you read the field instead:

```bit
import { Toml, TomlEntry } from "toml"
import {
  tomlAsArray,
  tomlAsBool,
  tomlAsFloat,
  tomlAsInt,
  tomlAsLocalDate,
  tomlAsLocalDateTime,
  tomlAsLocalTime,
  tomlAsOffsetDateTime,
  tomlAsString,
  tomlAsTable,
  tomlIsArray,
  tomlIsBool,
  tomlIsFloat,
  tomlIsInt,
  tomlIsLocalDate,
  tomlIsLocalDateTime,
  tomlIsLocalTime,
  tomlIsOffsetDateTime,
  tomlIsString,
  tomlIsTable,
} from "toml"
import { Date, DateTime, NaiveDateTime, Time } from "std/time"

fn field(entries: []TomlEntry, key: string): Toml! {
  for e of entries {
    if (e.key == key) {
      return e.value
    }
  }
  fail newError("no such key: '${key}'")
}

fn stringField(entries: []TomlEntry, key: string): string! {
  let v = field(entries, key)?
  if (!tomlIsString(v)) {
    fail newError("'${key}' must be a string")
  }
  return unwrap(tomlAsString(v))
}

fn intField(entries: []TomlEntry, key: string): int! {
  let v = field(entries, key)?
  if (!tomlIsInt(v)) {
    fail newError("'${key}' must be an integer")
  }
  return unwrap(tomlAsInt(v))
}

fn floatField(entries: []TomlEntry, key: string): f64! {
  let v = field(entries, key)?
  if (!tomlIsFloat(v)) {
    fail newError("'${key}' must be a float")
  }
  return unwrap(tomlAsFloat(v))
}

fn boolField(entries: []TomlEntry, key: string): bool! {
  let v = field(entries, key)?
  if (!tomlIsBool(v)) {
    fail newError("'${key}' must be a boolean")
  }
  return unwrap(tomlAsBool(v))
}

fn arrayField(entries: []TomlEntry, key: string): []Toml! {
  let v = field(entries, key)?
  if (!tomlIsArray(v)) {
    fail newError("'${key}' must be an array")
  }
  return unwrap(tomlAsArray(v))
}

fn tableField(entries: []TomlEntry, key: string): []TomlEntry! {
  let v = field(entries, key)?
  if (!tomlIsTable(v)) {
    fail newError("'${key}' must be a table")
  }
  return unwrap(tomlAsTable(v))
}

fn offsetDateTimeField(entries: []TomlEntry, key: string): DateTime! {
  let v = field(entries, key)?
  if (!tomlIsOffsetDateTime(v)) {
    fail newError("'${key}' must be an offset date-time")
  }
  return unwrap(tomlAsOffsetDateTime(v))
}

fn localDateTimeField(entries: []TomlEntry, key: string): NaiveDateTime! {
  let v = field(entries, key)?
  if (!tomlIsLocalDateTime(v)) {
    fail newError("'${key}' must be a local date-time")
  }
  return unwrap(tomlAsLocalDateTime(v))
}

fn localDateField(entries: []TomlEntry, key: string): Date! {
  let v = field(entries, key)?
  if (!tomlIsLocalDate(v)) {
    fail newError("'${key}' must be a local date")
  }
  return unwrap(tomlAsLocalDate(v))
}

fn localTimeField(entries: []TomlEntry, key: string): Time! {
  let v = field(entries, key)?
  if (!tomlIsLocalTime(v)) {
    fail newError("'${key}' must be a local time")
  }
  return unwrap(tomlAsLocalTime(v))
}
```

## Reading `deploy.toml`'s own scalars

[Parsing](parsing.md) introduced `deploy.toml`. Its `metadata` table alone
carries all four date-time forms - when the release was cut (a bare date),
when the build started (a bare time), when the build finished (no zone, so
it's read wherever the build ran) and when it actually went live (a zone
attached, so it means the same instant no matter who reads it later):

```bit
import { readFile } from "std/fs"
import { tomlParse } from "toml"

fn describeDeploy(path: string): string! {
  let root = unwrap(tomlAsTable(tomlParse(readFile(path)?)?))
  let name = stringField(root, "name")?
  let maintainers = arrayField(root, "maintainers")?

  let server = tableField(root, "server")?
  let port = intField(server, "port")?
  let tls = boolField(server, "tls")?

  let database = tableField(root, "database")?
  let backoff = floatField(database, "retry_backoff")?

  let metadata = tableField(root, "metadata")?
  let releaseDate = localDateField(metadata, "release_date")?
  let buildStarted = localTimeField(metadata, "build_started")?
  let builtAt = localDateTimeField(metadata, "built_at")?
  let deployedAt = offsetDateTimeField(metadata, "deployed_at")?

  let out = "${name}: ${len(maintainers)} maintainer(s), :${port} tls=${tls} backoff=${backoff}"
  out = out + " release=${releaseDate.toString()} build-started=${buildStarted.toString()}"
  out = out + " built=${builtAt.toString()} live=${deployedAt.toString()}"
  return out
}
```

`DateTime.toString()`, `NaiveDateTime.toString()`, `Date.toString()` and
`Time.toString()` all round-trip through RFC 3339 - the same text
[Encoding](encoding.md) writes back out.

## Under the hood: decoding one literal

`tomlParse` calls `tomlDecodeString`, `tomlDecodeNumber` and
`tomlDecodeDateTime` once per scalar token it reads. They are exported for
the same reason `lex` is (see [Parsing](parsing.md)): a caller who already
has a raw `Token` - from `lex`, not from `tomlParse` - can decode just that
one span without building a whole document around it.

```bit
import { TokenKind, lex, tomlDecodeDateTime, tomlDecodeNumber, tomlDecodeString } from "toml"

fn decodeLiteral(src: string): Toml! {
  let t = lex(src)[0]
  switch (t.kind) {
    case TokenKind.Number:
      return tomlDecodeNumber(src, t.start, t.end)?
    case TokenKind.DateTime:
      return tomlDecodeDateTime(src, t.start, t.end)?
    default:
      return Toml.TomlString(tomlDecodeString(src, t.kind, t.start, t.end)?)
  }
}
```

Next: [Tables](tables.md), for `[server]`, `[[server.routes]]`, the inline
`healthcheck`, and `contact`'s dotted keys.
