# Encoding

`tomlEncode` is `tomlParse` run backward: a `Toml` value in, TOML 1.0.0 text
out. You reach for it when your program builds or edits configuration
rather than only reading it - writing a fresh `deploy.toml`, or reading one,
changing a field, and saving it back.

## The simplest round trip

`tomlEncode(t: Toml): string!` fails when `t` has no TOML spelling at all -
the only case is a non-table at the root, since a document's root is always
an implicit table with no header of its own:

```bit
import { Toml, TomlEntry, tomlEncode } from "toml"

fn main(): ()! {
  let doc = Toml.TomlTable(
    [
      TomlEntry{ key: "name", value: Toml.TomlString("waypoint") },
      TomlEntry{ key: "version", value: Toml.TomlString("1.4.2") },
    ],
  )
  print(tomlEncode(doc)?)
  return
}
```

That prints:

```toml
name = "waypoint"
version = "1.4.2"
```

## Editing a parsed document

The more common shape: parse a file, change one field, write it back. A
`Toml` value is immutable, so "changing a field" means building a new
`TomlTable` with that one entry replaced - the rest of the entries, and
their order, carried over unchanged:

```bit
import { readFile, writeFile } from "std/fs"
import { tomlAsTable, tomlParse } from "toml"

fn withEntry(entries: []TomlEntry, key: string, value: Toml): []TomlEntry {
  let out = []TomlEntry(0, len(entries))
  for e of entries {
    if (e.key == key) {
      out = append(out, TomlEntry{ key: key, value: value })
    } else {
      out = append(out, e)
    }
  }
  return out
}

fn bumpVersion(path: string, next: string): ()! {
  let root = unwrap(tomlAsTable(tomlParse(readFile(path)?)?))
  let updated = withEntry(root, "version", Toml.TomlString(next))
  writeFile(path, tomlEncode(Toml.TomlTable(updated))?)?
  return
}
```

`tomlParse(tomlEncode(v)?)?` gets you back a value equal to `v` for anything
`tomlEncode` accepted - every scalar, every date-time form, nested tables
and arrays of tables all included. The text itself is not guaranteed to
match byte for byte: a table whose source interleaved scalar keys with
sub-tables re-emits with its scalars first, because once a `[sub]` header
is written every following line belongs to `sub`, not to the table that
opened it. The parsed value is what round-trips, not the formatting.

## What has no TOML spelling

Two shapes `tomlEncode` refuses outright, both because TOML's text format
has no way to write them:

* A non-table at the root - `tomlEncode(Toml.TomlInt(1))` fails, since
  there is no `[header]` for a bare value to attach to.
* `nan`, `inf` or `-inf` in a **key** position is unreachable through this
  package's own constructors (a `TomlEntry.key` is always a `string`), so it
  never comes up in practice; as a **value**, TOML 1.0.0 does define
  `nan`/`inf`/`-inf` spellings and `tomlEncode` writes them.

Everything else round-trips: key quoting, string escaping, and float
precision are all handled so that the text `tomlEncode` writes always
parses back to the value you gave it.

Next: [Errors](errors.md), for what `tomlParse` and `tomlEncode` fail with,
and why.
