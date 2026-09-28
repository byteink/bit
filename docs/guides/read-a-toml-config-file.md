# Read a TOML config file

`std/*` alone cannot read this page's example: it imports the first-party
`toml` package. A page under `docs/` names an extra first-party dependency
with a `doctest: deps` comment directly above its block, the same one
`pkg/*/docs/` pages already use (see [`docs/STYLE.md`](../STYLE.md#code-blocks)).

<!-- doctest: deps toml -->

```bit
import { readFile } from "std/fs"
import { tomlAsString, tomlAsTable, tomlParse } from "toml"

fn main(): ()! {
  let src = readFile("deploy.toml")?
  let root = unwrap(tomlAsTable(tomlParse(src)?))
  for e of root {
    match (tomlAsString(e.value)) {
      Some(s) => println("${e.key} = ${s}")
      None => {}
    }
  }
  return
}
```

`tomlParse` reads the file into one `Toml` value. `tomlAsTable` views the
root as a table of entries; `tomlAsString` reads one entry's value as a
string, `None` when it holds a different TOML type. See
[`pkg/toml`](../../pkg/toml/README.md) for the rest: nested tables, arrays
of tables, the four date-time forms, and encoding a value back to text.
