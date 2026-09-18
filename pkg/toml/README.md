# pkg/toml

A TOML 1.0.0 parser and encoder for Bit, with no dependencies outside the
standard library. Reads a document into one `Toml` value, and writes a
`Toml` value back out as TOML text.

## Install

```json
{
  "dependencies": {
    "toml": "bitlang.org/pkg/toml@v0.1.0"
  }
}
```

## Usage

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

Everything else - walking nested tables and arrays of tables, the four
date-time forms, encoding a value back to text, and the errors this package
raises - is in [`docs/`](docs/README.md).

<!-- BENCH:START -->
Parse-throughput comparison against BurntSushi/toml and go-toml/v2: the
harness ([`bench/`](bench/README.md), `./bench/run.sh`) is built and proves
all three parsers agree on the checked-in fixture, but has not yet run its
timed measurement - `run.sh` (no flags) writes the table here.
<!-- BENCH:END -->

For how first-party packages in this repository are laid out, gated,
versioned and released, see [`pkg/README.md`](../README.md).
