# std/http3

The HTTP/3 wire layer, built from scratch in Bit. Its first piece is **QPACK**
header compression (RFC 9204): the format HTTP/3 carries its headers in, playing
HPACK's role but redesigned for QUIC's out-of-order delivery. QPACK is a pure
byte codec — it turns header fields and control instructions into wire bytes and
back, with no QUIC, no streams, and no flow control — so it composes under a real
HTTP/3 connection without carrying any transport of its own.

QPACK shares the RFC 7541 Huffman code and prefix-integer encoding with HPACK, so
`std/http3` reuses `huffmanEncode`/`huffmanDecode` from `std/http2` rather than
duplicating the 257-symbol table. Everything else — the 99-entry static table, the
dynamic-table accounting, the encoder/decoder instruction streams, and the field-
line representations — is specific to QPACK and lives here. Import it all from
`"std/http3"`.

<!-- doctest: per-block -->

## QPACK

QPACK compresses a list of `(name, value)` header fields against two tables: a
fixed 99-entry **static table** (distinct from HPACK's — index 0 is `:authority`,
index 1 is `:path=/`) and a per-connection **dynamic table** both peers grow in
lock-step. Because QUIC can deliver streams out of order, QPACK cannot let a field
section depend on the exact position of a dynamic-table insertion the way HPACK
does. It splits the work over three streams:

- The **encoder stream** carries table mutations: set capacity, insert with a
  static or dynamic name reference, insert with a literal name, and duplicate.
- The **decoder stream** carries acknowledgements back: section acknowledgment,
  stream cancellation, and insert count increment.
- Each request/response stream carries an **encoded field section**: a prefix
  (Required Insert Count + Base) followed by field-line representations that index
  the static table, index the dynamic table relative to or after the Base, or
  spell a name/value out literally.

The dynamic table is addressed by a monotonic **absolute index** (0 for the first
entry ever inserted); eviction drops the oldest entries but never renumbers the
survivors. A section's prefix names the Required Insert Count — the number of
insertions the decoder must have processed before the section can be decoded —
which is how a section stays correct under reordering: one that arrives early
blocks until the encoder stream catches up.

An `Encoder` and a `Decoder` are the two halves; reuse one of each per connection
so their dynamic tables track each other. This example round-trips a field section
that references only the static table, so its prefix is Required Insert Count 0,
Base 0 and no dynamic-table state is involved:

```bit
import { newEncoder, newDecoder, HeaderField } from "std/http3"

// Encode a static-table-only field section, then decode it back to the same
// fields. `:method: GET` is a full static match (one index byte); `:path` reuses
// the static name with a literal value.
function roundTrip(): []HeaderField! {
  let enc = newEncoder()
  let fields = []HeaderField{
    HeaderField{ name: ":method", value: "GET", sensitive: false },
    HeaderField{ name: ":path", value: "/index.html", sensitive: false },
  }
  let block = enc.encodeFieldSection(0, enc.insertCount(), fields)

  let dec = newDecoder()
  return dec.decodeFieldSection(block)?
}
```

To reference a header not in the static table, insert it into the dynamic table
on the encoder stream first. The decoder must apply that instruction before it can
decode a section that indexes the new entry:

```bit
import { newEncoder, newDecoder, HeaderField } from "std/http3"

// Grow the dynamic table on the encoder stream, mirror it on the decoder, then
// encode a section that indexes the freshly inserted entry by a single byte.
function dynamic(): []HeaderField! {
  let enc = newEncoder()
  let dec = newDecoder()

  dec.applyEncoderStream(enc.setCapacity(4096))?
  dec.applyEncoderStream(enc.insertLiteral("x-trace-id", "abc123")?)?

  let fields = []HeaderField{
    HeaderField{ name: "x-trace-id", value: "abc123", sensitive: false },
  }
  let block = enc.encodeFieldSection(0, enc.insertCount(), fields)
  return dec.decodeFieldSection(block)?
}
```

After a decoder processes a section it acknowledges it, and the encoder folds that
into its Known Received Count — the high-water mark of insertions it may safely
reference without risking a blocked stream:

```bit
import { newEncoder, newDecoder, HeaderField } from "std/http3"

// Encode a section on stream 4, then apply the decoder's acknowledgment.
function acknowledge(): int! {
  let enc = newEncoder()
  let dec = newDecoder()

  dec.applyEncoderStream(enc.setCapacity(4096))?
  dec.applyEncoderStream(enc.insertLiteral("x-trace-id", "abc123")?)?

  let fields = []HeaderField{
    HeaderField{ name: "x-trace-id", value: "abc123", sensitive: false },
  }
  let block = enc.encodeFieldSection(4, enc.insertCount(), fields)
  dec.decodeFieldSection(block)?
  enc.applyDecoderStream(dec.sectionAck(4))?
  return enc.knownReceivedCount()
}
```

### `HeaderField`

One header field: a `name`, its `value`, and a `sensitive` flag. All three fields
are exported. Set `sensitive` to force a never-index literal representation (an
authorization token or cookie is never copied into the dynamic table, where a
compression side channel could recover it); a decoder sets it on any field it
received that way.

### `newEncoder(): Encoder`

A fresh encoder: a 4096-byte dynamic table and Huffman string literals enabled.

### `newEncoderConfig(capacity: int, huffman: bool): Encoder`

An encoder with an explicit initial table `capacity` and `huffman` choice. Pass
`capacity` 0 to start with no dynamic table (then raise it with `setCapacity`),
and `huffman` false to emit raw (non-Huffman) string literals.

### `Encoder`

A stateful QPACK encoder. It owns its dynamic table and tracks its Known Received
Count and its outstanding field sections. Reuse one encoder per connection so its
table tracks the peer decoder.

### `Encoder.setCapacity(capacity: int): []byte`

Emit a Set Dynamic Table Capacity instruction (RFC 9204 §4.3.1) and resize the
table, evicting entries that no longer fit. Returns the encoder-stream bytes.

### `Encoder.insertNameRef(isStatic: bool, index: int, value: string): []byte!`

Emit an Insert With Name Reference instruction (§4.3.2) and add the entry. When
`isStatic`, `index` is a static absolute index; otherwise it is a dynamic index
relative to the current insert count. Fails on a bad index or an entry too large
for the table.

### `Encoder.insertLiteral(name: string, value: string): []byte!`

Emit an Insert With Literal Name instruction (§4.3.3) and add the entry. Fails if
the entry is too large for the table.

### `Encoder.duplicate(relIndex: int): []byte!`

Emit a Duplicate instruction (§4.3.4) and re-insert an existing entry, given as a
dynamic index relative to the current insert count. Duplicating an about-to-be-
evicted entry keeps a still-referenced header alive. Fails on a bad index.

### `Encoder.encodeFieldSection(streamId: int, base: int, fields: []HeaderField): []byte`

Encode `fields` into one field section on `streamId` against the given `base`
(§4.5). Each field is emitted as, in preference order: an indexed static line, an
indexed dynamic line (relative or post-base per `base`), a literal with a
static/dynamic name reference, or a literal with a literal name; a `sensitive`
field is always a never-index literal. No new dynamic entries are inserted here —
pre-populate the table with the encoder-stream methods. `base` is typically the
current `insertCount()` but may be lower to force post-base indexing. The section
is recorded as outstanding until acknowledged.

### `Encoder.applyDecoderStream(data: []byte): ()!`

Process decoder-stream bytes (§4.4): a Section Acknowledgment raises the Known
Received Count to the acked section's Required Insert Count and retires it; a
Stream Cancellation retires an outstanding section; an Insert Count Increment
advances the Known Received Count. Fails on a malformed instruction, an ack for an
unknown stream, or an increment past the insert count.

### `Encoder.insertCount(): int`

The number of insertions the encoder has made (also the next absolute index).

### `Encoder.tableSize(): int`

The current byte size of the encoder's dynamic table.

### `Encoder.tableCount(): int`

The number of live entries in the encoder's dynamic table.

### `Encoder.capacity(): int`

The current dynamic-table capacity in bytes.

### `Encoder.knownReceivedCount(): int`

How many insertions the decoder has acknowledged (the Known Received Count).

### `newDecoder(): Decoder`

A fresh decoder: no dynamic table yet, willing to accept a capacity up to the
4096-byte default.

### `newDecoderConfig(limit: int): Decoder`

A decoder with an explicit capacity `limit`. A Set Dynamic Table Capacity above
this is rejected.

### `Decoder`

A stateful QPACK decoder. It owns its dynamic table and enforces the capacity
`limit` it advertised. Reuse one decoder per connection so its table tracks the
peer encoder.

### `Decoder.applyEncoderStream(data: []byte): int!`

Apply the encoder-stream instructions in `data` (§4.3), mutating the dynamic
table, and return the resulting insert count. Fails on a malformed instruction, a
bad index, or a capacity over the decoder's limit.

### `Decoder.decodeFieldSection(data: []byte): []HeaderField!`

Decode one encoded field section (§4.5) into its header fields. Reads the prefix
to recover the Required Insert Count and Base, fails ("blocked") if the section
needs insertions not yet applied, then decodes each field line. Fails on any
malformed representation or out-of-range index.

### `Decoder.sectionAck(streamId: int): []byte`

Emit a Section Acknowledgment for `streamId` (§4.4.1).

### `Decoder.streamCancel(streamId: int): []byte`

Emit a Stream Cancellation for `streamId` (§4.4.2).

### `Decoder.insertCountIncrement(n: int): []byte`

Emit an Insert Count Increment of `n` (§4.4.3).

### `Decoder.insertCount(): int`

The number of insertions the decoder has processed (also the next absolute index).

### `Decoder.tableSize(): int`

The current byte size of the decoder's dynamic table.

### `Decoder.tableCount(): int`

The number of live entries in the decoder's dynamic table.

### `Decoder.capacity(): int`

The current dynamic-table capacity in bytes.
