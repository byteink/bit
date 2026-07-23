# std/json

The `Json` value: a sum type over the seven shapes RFC 8259 §3 defines, plus
`JsonEntry`, one object key/value pair. This is the primitive the rest of the
json epic (#1479) — parser, encoder — builds on. Nothing here parses or
encodes JSON text; these are pure constructors and accessors over an
already-built `Json` value.

`JsonObject` is `[]JsonEntry`, not `map<string, Json>`: it keeps entries in
source order and allows duplicate keys, both of which a `map` would erase.
`jsonGet` resolves a duplicate key by returning the **last** matching entry —
the same policy most JSON decoders apply.

<!-- doctest: per-block -->

## The value type

### `JsonEntry`

One `key`/`value` pair of a `JsonObject`, in source order.

### `Json`

A JSON value: `JsonNull`, `JsonBool(bool)`, `JsonInt(i64)`, `JsonFloat(f64)`,
`JsonString(string)`, `JsonArray([]Json)`, or `JsonObject([]JsonEntry)`.

## Variant checks

### `jsonIsNull(j: Json): bool`

Whether `j` is `JsonNull`.

### `jsonIsBool(j: Json): bool`

Whether `j` is a `JsonBool`.

### `jsonIsInt(j: Json): bool`

Whether `j` is a `JsonInt`.

### `jsonIsFloat(j: Json): bool`

Whether `j` is a `JsonFloat`.

### `jsonIsString(j: Json): bool`

Whether `j` is a `JsonString`.

### `jsonIsArray(j: Json): bool`

Whether `j` is a `JsonArray`.

### `jsonIsObject(j: Json): bool`

Whether `j` is a `JsonObject`.

## Accessors

Each of these unwraps the matching variant's payload, or reports `None` on any
other shape — a caller decoding untrusted JSON handles a shape mismatch as
data, never a crash.

### `jsonAsBool(j: Json): Option<bool>`

`Some` of the payload when `j` is a `JsonBool`, else `None`.

### `jsonAsInt(j: Json): Option<i64>`

`Some` of the payload when `j` is a `JsonInt`, else `None`.

### `jsonAsFloat(j: Json): Option<f64>`

`Some` of the payload when `j` is a `JsonFloat`, else `None`.

### `jsonAsString(j: Json): Option<string>`

`Some` of the payload when `j` is a `JsonString`, else `None`.

### `jsonAsArray(j: Json): Option<[]Json>`

`Some` of the payload when `j` is a `JsonArray`, else `None`.

### `jsonGet(o: Json, key: string): Option<Json>`

Looks up `key` in `o`. `None` when `o` is not a `JsonObject` or `key` is
absent. On a duplicate key, returns the **last** matching entry.

```bit
import { Json, JsonEntry, jsonGet, jsonAsInt } from "std/json"

// Last-key-wins: two entries named "a", jsonGet returns the second (2).
function lastWins(): i64 {
  let obj = Json.JsonObject([]JsonEntry{
    JsonEntry{ key: "a", value: Json.JsonInt(1) },
    JsonEntry{ key: "a", value: Json.JsonInt(2) },
  })
  match (jsonGet(obj, "a")) {
    Some(v) => {
      match (jsonAsInt(v)) {
        Some(i) => return i
        None => return -1
      }
    }
    None => return -1
  }
}
```
