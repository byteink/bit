# pkg/yaml

A YAML 1.2 parser and encoder for Bit, with no dependencies outside the
standard library. Reads a document into one `Yaml` value, and writes a
`Yaml` value back out as YAML text.

This package implements a documented subset of YAML 1.2, pinned to the
**core schema** - see [Conformance](docs/conformance.md) for exactly what
that means. The two things it deliberately does not accept are YAML 1.1's
`yes`/`no`/`on`/`off` booleans and merge keys (`<<`); both are explained in
[Types](docs/types.md).

## Install

`bit add bitlang.org/pkg/yaml@^0.1.4` writes:

```json
{
  "dependencies": {
    "yaml": "bitlang.org/pkg/yaml@^0.1.4"
  }
}
```

## Usage

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

Everything else - implicit typing and the Norway problem, quoting and block
scalars, anchors and the expansion budget that bounds them, encoding a
value back to text, and the errors this package raises - is in
[`docs/`](docs/README.md).

<!-- BENCH:START -->
## Benchmarks

In 2 comparisons with other YAML parsers, pkg/yaml is slower in 2; the biggest gap is gopkg.in/yaml.v3 (Go), 3.7x faster than pkg/yaml (Kubernetes manifests).

| File | pkg/yaml vs gopkg.in/yaml.v3 (Go) | pkg/yaml vs goccy/go-yaml (Go) |
|---|---|---|
| Kubernetes manifests, 1.15 MB | 3.7x slower | 1.7x slower |

Memory: pkg/yaml needs 37 MB to parse these files; the other parsers need 34 to 78 MB.

Measured on Apple M5 Max, macOS 27.0, 2026-09-19, with bit 0.21.0.

Full numbers and method: [bench/RESULTS.md](bench/RESULTS.md)
<!-- BENCH:END -->

For how first-party packages in this repository are laid out, gated,
versioned and released, see [`pkg/README.md`](../README.md).
