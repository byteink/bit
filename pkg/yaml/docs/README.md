# pkg/yaml documentation

Read in this order. Each row is one chapter; this table is the order
bitlang.org's sidebar reads it in.

| Chapter | Covers |
|---|---|
| [Parsing](parsing.md) | `yamlParse`, `yamlParseAll`, the `Yaml` value type |
| [Types](types.md) | the core schema's implicit typing, and the Norway problem |
| [Scalars](scalars.md) | quoting styles, block scalars, chomping and folding |
| [Anchors](anchors.md) | anchors, aliases, and the expansion budget that bounds them |
| [Encoding](encoding.md) | `yamlEncode`, round-tripping, and what stays quoted |
| [Errors](errors.md) | how a failure surfaces, byte offsets, and every rejection |
| [Conformance](conformance.md) | the pinned YAML version, the yaml-test-suite counts, every exclusion |

See the [package front page](../README.md) for install and a minimal example.
