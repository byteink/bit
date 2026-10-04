# std/cbor

CBOR (RFC 8949) is a compact binary format for the same things JSON carries:
numbers, text, lists and maps, plus byte strings, which JSON cannot hold.
Inkwell meets it the moment an author signs in with a passkey: the browser
hands the server an attestation object, and that object, with the public key
inside it, is CBOR.

You read it with `decode`, which turns bytes into a tree of `Cbor` values, and
you write it with `encode`. Everything you decode came from outside, so every
failure is an error you can catch: truncated input, a length that claims more
bytes than exist, nesting that goes too deep, text that is not UTF-8. A decode
never panics and never allocates for a length it has not checked first.

<!-- doctest: per-block -->

## Read a value

The smallest thing that works: a map with one text key and a number, decoded
from its bytes.

```bit
import { Cbor, decode } from "std/cbor"

fn main() {
  // {"words": 412}
  let data = []byte([0xa1, 0x65, 0x77, 0x6f, 0x72, 0x64, 0x73, 0x19, 0x01, 0x9c])
  let v = decode(data) catch e {
    println("bad cbor: ${e.message()}")
    return
  }
  match (v) {
    Map(entries) => println("${len(entries)} entry")
    _ => println("not a map")
  }
}
```

### `Cbor`

One CBOR data item. A `match` over it names every kind there is:

- `Null`, `Undefined`, `Bool(bool)`: the simple values `null`, `undefined`,
  `true` and `false`.
- `Uint(uint)` is a non-negative integer. `Negative(uint)` holds `n` for the
  integer `-1 - n`, so the whole CBOR range down to -18446744073709551616
  fits without a wider type: `Negative(0)` is -1, `Negative(9)` is -10.
- `Bytes([]byte)` and `Text(string)`. Text is always valid UTF-8; a text
  string that is not fails the decode.
- `Array([]Cbor)` and `Map([]CborEntry)`. A map keeps wire order and may hold
  any item as a key, not only text.
- `Tag(uint, Cbor)`: a tag number and the item it labels, such as tag 1 over
  an integer for a timestamp.
- `Simple(u8)`: any other simple value (0 to 19 and 32 to 255).
- `Float(f64)`: a half, single or double precision float. Which width it came
  in is not kept; `encode` always picks the shortest.

`Cbor` starts with `Null`, so `let v: Cbor` is a usable `null`.

### `CborEntry`

One key and value of a map: `key: Cbor` and `value: Cbor`. A map is a slice of
these instead of a `map<K, V>` because CBOR keys can be any item, and because
a decode must not hide the order or a repeated key from you.

The sign-in example reads a COSE public key, which is a CBOR map keyed by small
integers (`1` is the key type, `-2` the x coordinate):

```bit
import { Cbor, CborEntry, decode } from "std/cbor"

// The value stored under the integer key `n`, if the map has one.
fn byInt(entries: []CborEntry, n: int): Option<Cbor> {
  for e of entries {
    match (e.key) {
      Uint(k) => {
        if (n >= 0 && k == uint(n)) {
          return Option.Some(e.value)
        }
      }
      Negative(k) => {
        if (n < 0 && k == uint(-1 - n)) {
          return Option.Some(e.value)
        }
      }
      _ => {}
    }
  }
  return Option.None
}

// The 32-byte x coordinate of an ES256 COSE key, or an error.
fn coordinateX(key: []byte): []byte! {
  let v = decode(key)?
  match (v) {
    Map(entries) => {
      match (unwrapOr(byInt(entries, -2), Cbor.Null)) {
        Bytes(x) => return x
        _ => fail newError("key has no x coordinate")
      }
    }
    _ => fail newError("key is not a map")
  }
}
```

## Limits and strict mode

A decode is bounded, so a hostile attestation cannot cost you more than you
allow. `decode` takes an optional `DecodeOptions`.

### `DecodeOptions`

| Field | Default | Meaning |
|---|---|---|
| `maxDepth` | 16 | How deep arrays, maps and tags may nest. Sixteen nested arrays decode; a seventeenth is an error. |
| `maxItems` | 65536 | The most data items one decode may produce, counting nested ones. |
| `maxBytes` | 16777216 | The most string bytes one decode may produce, byte and text strings together. |
| `strict` | `false` | Accept only what `encode` would write. |

`DecodeOptions{}` is a complete configuration. A length that claims more
elements or bytes than the input still holds is refused before anything is
allocated, whatever the limits say, so a header claiming 2^63 bytes costs one
comparison.

By default a decoder accepts everything valid CBOR allows, including integers
written longer than they need to be and indefinite-length strings, arrays and
maps. `strict` turns those into errors, along with floats wider than needed
and map keys that are repeated or out of order. A strict decode accepts exactly
the bytes `encode` produces: `encode(decode(x))` equals `x` for every `x` it
accepts. Use it when the bytes are signed or hashed, because two encodings of
one value would otherwise be two different messages.

```bit
import { Cbor, DecodeOptions, decode } from "std/cbor"

// Read a signed payload: tight limits, and exactly one encoding allowed.
fn readSigned(data: []byte): Cbor! {
  let opts = DecodeOptions{ maxDepth = 4, maxItems = 256, maxBytes = 4096, strict = true }
  return decode(data, opts)?
}
```

A few things fail no matter what the options say: the reserved additional
information values 28 to 30, a break byte with nothing to end, a tag with no
item after it, a two-byte simple value below 32, and `decode` with bytes left
over after the item.

## Read a value that is followed by more bytes

Some formats put a CBOR item inside something larger. In a WebAuthn
authenticator-data block the credential public key is a CBOR map, and extension
data follows it. `decodePrefix` reads the first item and tells you how many
bytes it used.

### `decodePrefix(data: []byte, opts: DecodeOptions = DecodeOptions{}): (Cbor, int)!`

Decodes the first item in `data` and returns it with the number of bytes it
occupied. What follows is not looked at.

```bit
import { Cbor, decodePrefix } from "std/cbor"

// Split a credential key from the extension bytes behind it.
fn splitKey(block: []byte): (Cbor, []byte)! {
  let (key, used) = decodePrefix(block)?
  return (key, block[used:len(block)])
}
```

### `decode(data: []byte, opts: DecodeOptions = DecodeOptions{}): Cbor!`

Decodes `data` as exactly one item. Bytes after it are an error: use
`decodePrefix` when something legitimately follows.

## Write a value

### `encode(v: Cbor): []byte!`

The deterministic encoding of `v` (the core deterministic encoding of RFC
8949), the same bytes every time for the same value:

- integers and lengths use the shortest form;
- a float uses the shortest of 2, 4 or 8 bytes that holds its value exactly,
  and every NaN is the one canonical NaN;
- map keys are sorted bytewise by their own encoding, so the order you build
  a map in does not matter;
- nothing is indefinite-length.

It fails on a map with two equal keys, on a `Simple` value from 24 to 31 (those
are not valid items), and on a value nested more than 1024 deep.

```bit
import { Cbor, CborEntry, encode } from "std/cbor"

// An Inkwell draft summary as CBOR. Key order does not matter: the bytes
// are the same whichever way round the entries are listed.
fn summary(title: string, words: uint): []byte! {
  let draft = Cbor.Map([
    CborEntry{ key = Cbor.Text("words"), value = Cbor.Uint(words) },
    CborEntry{ key = Cbor.Text("title"), value = Cbor.Text(title) },
    CborEntry{ key = Cbor.Text("tags"), value = Cbor.Array([Cbor.Text("notes")]) },
    CborEntry{ key = Cbor.Text("public"), value = Cbor.Bool(false) },
    CborEntry{ key = Cbor.Text("edited"), value = Cbor.Null },
    CborEntry{ key = Cbor.Text("delta"), value = Cbor.Negative(0) },
    CborEntry{ key = Cbor.Text("ratio"), value = Cbor.Float(0.5) },
    CborEntry{ key = Cbor.Text("cover"), value = Cbor.Bytes([]byte([1, 2, 3])) },
    CborEntry{ key = Cbor.Text("stamp"), value = Cbor.Tag(1, Cbor.Uint(1363896240)) },
    CborEntry{ key = Cbor.Text("mark"), value = Cbor.Simple(16) },
    CborEntry{ key = Cbor.Text("scratch"), value = Cbor.Undefined },
  ])
  return encode(draft)?
}
```

## Sharp edges

- Text, byte and container lengths are checked against the input before any
  allocation, but a limit you raise is yours to answer for: `maxBytes` of 4 GiB
  lets a 4 GiB input produce 4 GiB of strings.
- `==` on a `Cbor` is not a good test of two decodes: floats compare as floats
  (NaN is never equal to itself), and slices do not compare. Compare the
  `encode` of both, which is the same bytes exactly when the values are the
  same.
- A map decoded without `strict` may hold the same key twice. Both entries are
  kept in wire order, and `encode` will refuse to write the tree back.

## Where to go next

JSON text goes through [json](json.md). Signatures over the bytes you encode
are in [crypto](crypto.md).
