# pkg/toml

A TOML 1.0.0 parser and encoder for Bit, with no dependencies outside the
standard library. Reads a document into one `Toml` value, and writes a
`Toml` value back out as TOML text.

## Install

`bit add bitlang.org/pkg/toml@^0.1.8` writes:

```json
{
  "dependencies": {
    "toml": "bitlang.org/pkg/toml@^0.1.8"
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
## Benchmarks

In 2 comparisons with other TOML parsers, pkg/toml is faster in 1 and slower in 1; the biggest gap is go-toml/v2 (pelletier), 3.0x faster than pkg/toml (Cargo manifest).

| File | pkg/toml vs BurntSushi/toml | pkg/toml vs go-toml/v2 (pelletier) |
|---|---|---|
| Cargo manifest, 1.55 MB | 1.3x faster | 3.0x slower |

Memory: pkg/toml needs 21 MB to parse these files; the other parsers need 20 to 29 MB.

Measured on Apple M5 Max, 2026-09-19, with bit 0.21.0.

Full numbers and method: [bench/RESULTS.md](bench/RESULTS.md)
<!-- BENCH:END -->

For how first-party packages in this repository are laid out, gated,
versioned and released, see [`pkg/README.md`](../README.md).
