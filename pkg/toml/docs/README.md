# pkg/toml documentation

Read in this order. Each row is one chapter; this table is the order
bitlang.org's sidebar reads it in.

| Chapter | Covers |
|---|---|
| [Parsing](parsing.md) | `tomlParse`, the `Toml` value type, walking a document into it |
| [Values](values.md) | the scalar types, and the four date-time forms mapped onto `std/time` |
| [Tables](tables.md) | dotted keys, `[table]`, `[[array of tables]]`, inline tables |
| [Encoding](encoding.md) | `tomlEncode`, round-tripping, what has no TOML spelling |
| [Errors](errors.md) | `TomlError`, byte offsets, what gets rejected and why |
| [Conformance](conformance.md) | the pinned TOML version, the toml-test pass counts, every exclusion |

See the [package front page](../README.md) for install and a minimal example.
