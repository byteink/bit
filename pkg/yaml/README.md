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

```json
{
  "dependencies": {
    "yaml": "bitlang.org/pkg/yaml@v0.1.0"
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
Pending: `pkg/yaml/bench/run.sh` (#5501) publishes the parse-throughput table
against `github.com/goccy/go-yaml` and `gopkg.in/yaml.v3` here on its next
full run (15+ runs, an idle box — see `pkg/yaml/bench/README.md`). The
harness is built, and every implementation is proven to parse
`bench/data/k8s-manifests.yaml` to the identical checksum by `./run.sh
--verify`; only the timed measurement itself has not been taken yet.
<!-- BENCH:END -->

For how first-party packages in this repository are laid out, gated,
versioned and released, see [`pkg/README.md`](../README.md).
