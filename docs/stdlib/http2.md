# std/http2

The HTTP/2 wire layer, built from scratch in Bit: **HPACK** header compression
(RFC 7541) and the **frame** codec (RFC 7540 / 9113). Both are pure byte codecs -
they turn values into wire bytes and back with no I/O, no TLS, and no connection
state machine - so they compose under a real HTTP/2 connection without carrying
any transport of their own. The two files share one flat module: import
everything from `"std/http2"`.

HPACK's `Encoder` and `Decoder` each hold their own dynamic-table state; a matched
pair walked over the same header sequence evolve identical tables. The frame codec
is a set of typed encode/decode pairs over the fixed 9-byte frame header. Both
halves are strict on decode - every malformed input (a bad index, an EOS symbol in
a Huffman string, a frame over `SETTINGS_MAX_FRAME_SIZE`, padding larger than its
payload, a connection-level frame on the wrong stream) is rejected with a `!`
error rather than best-guessed.

<!-- doctest: per-block -->

## HPACK

HPACK (RFC 7541) compresses a list of `(name, value)` header fields against two
tables: a fixed 61-entry **static table** and a per-connection **dynamic table**
that both peers grow in lock-step. A field that is already in a table costs a
single index byte; a new field is sent as a string literal - optionally
**Huffman**-coded - and (usually) added to the dynamic table for next time.

An `Encoder` and a `Decoder` are the two halves. Reuse one of each per connection
so their dynamic tables track each other. This example round-trips a request:

```bit
import { newEncoder, newDecoder, HeaderField } from "std/http2"

// Build a header block, then decode it back to the same fields. `enc` and `dec`
// each hold their own dynamic table, evolving identically across calls.
fn roundTrip(): []HeaderField! {
  let enc = newEncoder()
  let fields = []HeaderField{
    HeaderField{ name: ":method", value: "GET", sensitive: false },
    HeaderField{ name: ":path", value: "/", sensitive: false },
    HeaderField{ name: ":authority", value: "example.com", sensitive: false },
  }
  let block = enc.encode(fields)

  let dec = newDecoder()
  return dec.decode(block)?
}
```

A `sensitive` field (a cookie, an authorization token) is always sent
**never-indexed** so it never enters the dynamic table:

```bit
import { newEncoder, HeaderField } from "std/http2"

// A sensitive field is encoded never-indexed (RFC 7541 §6.2.3).
fn encodeSecret(): []byte {
  let enc = newEncoder()
  let fields = []HeaderField{
    HeaderField{ name: "authorization", value: "Bearer s3cr3t", sensitive: true },
  }
  return enc.encode(fields)
}
```

### `HeaderField`

One header field: a `name`, its `value`, and a `sensitive` flag. All three fields
are exported. Set `sensitive` to force a never-indexed representation when
encoding; a decoder sets it on any field it received that way. Build a list of
these to hand to `Encoder.encode`, and receive one from `Decoder.decode`.

### `newEncoder(): Encoder`

A fresh encoder with the HTTP/2 default 4096-byte dynamic table and Huffman string
literals enabled.

### `newEncoderConfig(maxTableSize: int, huffman: bool): Encoder`

An encoder with an explicit dynamic-table byte limit and Huffman on/off. Use it to
match a negotiated `SETTINGS_HEADER_TABLE_SIZE`, or to emit raw (non-Huffman)
literals.

### `Encoder`

The stateful HPACK encoder. It owns its dynamic table and, per field, picks the
smallest representation: an indexed field for a full table match, otherwise a
literal with incremental indexing (which it adds to the table). A `sensitive`
field is always never-indexed. Reuse one encoder across a connection.

### `Encoder.encode(fields: []HeaderField): []byte`

Encode `fields` into one HPACK header block, evolving the dynamic table. Any
pending size update from `changeTableSize` is emitted first.

### `Encoder.changeTableSize(maxTableSize: int)`

Change the encoder's dynamic-table maximum size (RFC 7541 §4.2, §6.3). The table
is resized (evicting as needed) immediately, and the next `encode` prepends the
required dynamic-table size-update instruction(s).

### `Encoder.tableSize(): int`

The current byte size of the encoder's dynamic table (RFC 7541 §4.1: the sum of
each entry's name + value + 32).

### `Encoder.tableCount(): int`

The number of entries currently in the encoder's dynamic table.

### `Encoder.tableEntry(i: int): HeaderField!`

The `i`-th dynamic-table entry, newest first (`i == 0` is index 62). Fails if `i`
is out of range. Useful for inspecting or asserting the table state.

### `newDecoder(): Decoder`

A fresh decoder with the 4096-byte default table limit.

### `newDecoderConfig(maxTableSize: int): Decoder`

A decoder with an explicit table-size `limit`, matching the
`SETTINGS_HEADER_TABLE_SIZE` it advertised. A peer size update above this limit is
rejected.

### `Decoder`

The stateful HPACK decoder. It owns its dynamic table and enforces its advertised
size limit against peer size updates. Reuse one decoder across a connection so its
table tracks the peer encoder.

### `Decoder.decode(block: []byte): []HeaderField!`

Decode a full HPACK header block into its fields, evolving the dynamic table and
applying any size updates. Fails on any malformed representation: a zero or
out-of-range index, a size update over the decoder's limit, or a bad
string/integer/Huffman encoding.

### `Decoder.tableSize(): int`

The current byte size of the decoder's dynamic table.

### `Decoder.tableCount(): int`

The number of entries currently in the decoder's dynamic table.

### `Decoder.tableEntry(i: int): HeaderField!`

The `i`-th dynamic-table entry, newest first (`i == 0` is index 62). Fails if `i`
is out of range.

### `huffmanEncode(data: []byte): []byte`

Huffman-encode `data` with the RFC 7541 Appendix B code, padding the final byte
with 1-bits. Exposed for direct use; `Encoder` calls it for its string literals.

```bit
import { huffmanEncode, huffmanDecode } from "std/http2"

// Huffman is self-inverse for well-formed input.
fn huffRoundTrip(s: string): []byte! {
  return huffmanDecode(huffmanEncode([]byte(s)))?
}
```

### `huffmanDecode(data: []byte): []byte!`

Huffman-decode `data`. Fails on a code that never resolves within 30 bits, on the
EOS symbol appearing in the stream, or on final padding that is longer than 7 bits
or not all 1-bits (RFC 7541 §5.2).

## Frames

Every HTTP/2 message is a stream of frames: a fixed 9-byte header - a 24-bit
payload length, an 8-bit type, an 8-bit flags field, a reserved bit, and a 31-bit
stream id (RFC 7540 §4.1) - followed by a type-specific payload. `readFrame`
splits one frame off a buffer, enforcing the negotiated `SETTINGS_MAX_FRAME_SIZE`;
the typed `decode*` helpers then interpret the payload.

```bit
import { readFrame, decodeSettings, frameSettings, defaultMaxFrameSize } from "std/http2"

// Read one frame off `buf`, and if it is SETTINGS, pull out its parameters.
fn firstSettings(buf: []byte): int! {
  let frame = readFrame(buf, defaultMaxFrameSize)?
  if (frame.header.ftype != frameSettings) {
    return 0
  }
  let s = decodeSettings(frame)?
  return len(s.settings)
}
```

Encoding is the mirror: build a typed frame value and call its `encode*`.

```bit
import { encodeSettings, SettingsFrame, Setting, settingsMaxFrameSize } from "std/http2"

// A SETTINGS frame advertising a 32 KiB max frame size.
fn settingsBytes(): []byte! {
  let params = []Setting{ Setting{ id: settingsMaxFrameSize, value: 32768 } }
  return encodeSettings(SettingsFrame{ ack: false, settings: params })?
}
```

A HEADERS frame carries an HPACK block fragment - encode the headers with an
`Encoder`, then frame the bytes:

```bit
import { newEncoder, HeaderField, encodeHeaders, HeadersFrame } from "std/http2"

// Frame a header block onto stream `sid`, ending both the headers and the stream.
fn headersFrame(sid: int): []byte! {
  let enc = newEncoder()
  let block = enc.encode(
    []HeaderField{ HeaderField{ name: ":status", value: "200", sensitive: false } },
  )
  return encodeHeaders(
    HeadersFrame{
      streamId: sid,
      blockFragment: block,
      endStream: true,
      endHeaders: true,
      padLength: 0 - 1,
      hasPriority: false,
      exclusive: false,
      streamDependency: 0,
      weight: 0,
    },
  )?
}
```

### The frame header

### `FrameHeader`

A parsed 9-byte frame header: the payload `length`, the frame `ftype`, its
`flags`, and the 31-bit `streamId` (the reserved bit is ignored on read, zero on
write). All fields are exported.

### `Frame`

A whole frame: its `header` and the raw `payload` bytes. `readFrame` produces one;
a `decode*` helper turns it into a typed frame.

### `encodeFrameHeader(h: FrameHeader): []byte!`

The 9 wire bytes of a frame header. Fails if `length` does not fit 24 bits or
`streamId` does not fit 31 bits.

### `decodeFrameHeader(b: []byte): FrameHeader!`

The frame header the first 9 bytes of `b` spell. Fails on fewer than 9 bytes; the
reserved bit of the stream id is masked off.

### `readFrame(buf: []byte, maxFrameSize: int): Frame!`

Read one whole frame off the front of `buf`, enforcing `maxFrameSize`
(`SETTINGS_MAX_FRAME_SIZE`). Fails on a short header, a declared length over
`maxFrameSize`, or a payload past `buf`. Advance by `9 + frame.header.length` for
the next frame.

### Frame types

The `FrameType` code points (RFC 7540 §6), for `FrameHeader.ftype` and dispatch.

### `frameData: int`

DATA (0x0): a stream's message body.

### `frameHeaders: int`

HEADERS (0x1): opens a stream and carries a header block fragment.

### `framePriority: int`

PRIORITY (0x2): a stream's priority dependency and weight.

### `frameRstStream: int`

RST_STREAM (0x3): abrupt termination of a stream.

### `frameSettings: int`

SETTINGS (0x4): connection configuration parameters.

### `framePushPromise: int`

PUSH_PROMISE (0x5): a server's promise to push a stream.

### `framePing: int`

PING (0x6): a connection liveness / round-trip probe.

### `frameGoaway: int`

GOAWAY (0x7): connection shutdown with the last processed stream.

### `frameWindowUpdate: int`

WINDOW_UPDATE (0x8): a flow-control window increment.

### `frameContinuation: int`

CONTINUATION (0x9): a continued header block fragment.

### Frame flags

The frame flag bits (RFC 7540 §6). `flagAck` shares the bit value of
`flagEndStream` on the frame types where END_STREAM does not apply.

### `flagEndStream: int`

END_STREAM (0x1) on DATA/HEADERS: the last frame for the stream.

### `flagEndHeaders: int`

END_HEADERS (0x4) on HEADERS/PUSH_PROMISE/CONTINUATION: the header block is
complete.

### `flagPadded: int`

PADDED (0x8) on DATA/HEADERS/PUSH_PROMISE: the payload is padded.

### `flagPriority: int`

PRIORITY (0x20) on HEADERS: a priority section precedes the header block.

### `flagAck: int`

ACK (0x1) on SETTINGS/PING: acknowledges the peer's frame.

### SETTINGS parameters

The `SettingsParameter` identifiers (RFC 7540 §6.5.2), for `Setting.id`.

### `settingsHeaderTableSize: int`

SETTINGS_HEADER_TABLE_SIZE (0x1): the HPACK dynamic-table size limit.

### `settingsEnablePush: int`

SETTINGS_ENABLE_PUSH (0x2): whether server push is permitted.

### `settingsMaxConcurrentStreams: int`

SETTINGS_MAX_CONCURRENT_STREAMS (0x3): the peer's concurrent-stream cap.

### `settingsInitialWindowSize: int`

SETTINGS_INITIAL_WINDOW_SIZE (0x4): the initial flow-control window.

### `settingsMaxFrameSize: int`

SETTINGS_MAX_FRAME_SIZE (0x5): the largest frame payload the peer accepts.

### `settingsMaxHeaderListSize: int`

SETTINGS_MAX_HEADER_LIST_SIZE (0x6): the largest header list the peer accepts.

### Frame-size bounds

### `defaultMaxFrameSize: int`

The default and minimum `SETTINGS_MAX_FRAME_SIZE` (2^14 = 16384).

### `maxMaxFrameSize: int`

The largest `SETTINGS_MAX_FRAME_SIZE` (2^24 - 1), the widest the 24-bit length
field can express.

### Error codes

The `ErrorCode` values (RFC 7540 §7), for `RstStreamFrame.errorCode` and
`GoawayFrame.errorCode`.

### `errorNoError: int`

NO_ERROR (0x0): graceful shutdown.

### `errorProtocolError: int`

PROTOCOL_ERROR (0x1): an unspecific protocol violation.

### `errorInternalError: int`

INTERNAL_ERROR (0x2): an implementation fault.

### `errorFlowControlError: int`

FLOW_CONTROL_ERROR (0x3): a flow-control window was exceeded.

### `errorSettingsTimeout: int`

SETTINGS_TIMEOUT (0x4): a SETTINGS frame was not acknowledged in time.

### `errorStreamClosed: int`

STREAM_CLOSED (0x5): a frame arrived on a closed stream.

### `errorFrameSizeError: int`

FRAME_SIZE_ERROR (0x6): a frame's size was invalid for its type.

### `errorRefusedStream: int`

REFUSED_STREAM (0x7): the stream was refused before processing.

### `errorCancel: int`

CANCEL (0x8): the stream is no longer needed.

### `errorCompressionError: int`

COMPRESSION_ERROR (0x9): the HPACK decoder state is unrecoverable.

### `errorConnectError: int`

CONNECT_ERROR (0xa): a CONNECT tunnel failed.

### `errorEnhanceYourCalm: int`

ENHANCE_YOUR_CALM (0xb): the peer is generating excessive load.

### `errorInadequateSecurity: int`

INADEQUATE_SECURITY (0xc): the transport is not secure enough.

### `errorHttp11Required: int`

HTTP_1_1_REQUIRED (0xd): the peer requires HTTP/1.1.

### DATA (§6.1)

### `DataFrame`

A DATA frame: the `streamId`, the `data` body fragment, `endStream`, and
`padLength` (>= 0 requests PADDED with that many padding octets; -1 = no padding).

### `encodeData(f: DataFrame): []byte!`

The wire bytes of a DATA frame. Fails on a zero stream id or an out-of-range pad
length.

### `decodeData(f: Frame): DataFrame!`

The DATA frame `f` carries. Fails on a wrong type, a zero stream id, or padding at
least the payload size.

### HEADERS (§6.2)

### `HeadersFrame`

A HEADERS frame: `streamId`, the `blockFragment` (an HPACK header block),
`endStream`, `endHeaders`, `padLength` (-1 for none), and an optional priority
section (`hasPriority`, `exclusive`, `streamDependency`, the raw 8-bit `weight`).

### `encodeHeaders(f: HeadersFrame): []byte!`

The wire bytes of a HEADERS frame. Fails on a zero stream id or an out-of-range
pad length.

### `decodeHeaders(f: Frame): HeadersFrame!`

The HEADERS frame `f` carries. Fails on a wrong type, a zero stream id, padding at
least the payload size, or a priority section that does not fit.

### PRIORITY (§6.3)

### `PriorityFrame`

A PRIORITY frame: the `streamId`, its `exclusive` flag, its `streamDependency`,
and the raw 8-bit `weight`. The payload is always 5 bytes.

### `encodePriority(f: PriorityFrame): []byte!`

The wire bytes of a PRIORITY frame. Fails on a zero stream id.

### `decodePriority(f: Frame): PriorityFrame!`

The PRIORITY frame `f` carries. Fails on a wrong type, a zero stream id, or a
payload that is not exactly 5 bytes.

### RST_STREAM (§6.4)

### `RstStreamFrame`

A RST_STREAM frame: the `streamId` and the `errorCode` it is being reset with. The
payload is always 4 bytes.

### `encodeRstStream(f: RstStreamFrame): []byte!`

The wire bytes of a RST_STREAM frame. Fails on a zero stream id.

### `decodeRstStream(f: Frame): RstStreamFrame!`

The RST_STREAM frame `f` carries. Fails on a wrong type, a zero stream id, or a
payload that is not exactly 4 bytes.

### SETTINGS (§6.5)

### `Setting`

One SETTINGS parameter: a 16-bit `id` (a `settings*` constant) and its 32-bit
`value`.

### `SettingsFrame`

A SETTINGS frame: either an `ack` (empty) or a list of `settings`. Always on
stream 0.

### `encodeSettings(f: SettingsFrame): []byte!`

The wire bytes of a SETTINGS frame - six bytes per parameter. Fails if `ack` is set
together with a non-empty `settings` list.

### `decodeSettings(f: Frame): SettingsFrame!`

The SETTINGS frame `f` carries. Fails on a wrong type, a non-zero stream id, a
payload length that is not a multiple of 6, or an ACK with a non-empty payload.

### PUSH_PROMISE (§6.6)

### `PushPromiseFrame`

A PUSH_PROMISE frame: the carrying `streamId`, the `promisedStreamId`, the
`blockFragment` request headers, `endHeaders`, and `padLength` (-1 for none).

### `encodePushPromise(f: PushPromiseFrame): []byte!`

The wire bytes of a PUSH_PROMISE frame. Fails on a zero carrying stream id or an
out-of-range pad length.

### `decodePushPromise(f: Frame): PushPromiseFrame!`

The PUSH_PROMISE frame `f` carries. Fails on a wrong type, a zero carrying stream
id, padding at least the payload size, or a payload too short for the promised
stream field.

### PING (§6.7)

### `PingFrame`

A PING frame: 8 opaque `data` bytes, echoed back with `ack` set. Always on stream
0.

### `encodePing(f: PingFrame): []byte!`

The wire bytes of a PING frame. Fails unless `data` is exactly 8 bytes.

### `decodePing(f: Frame): PingFrame!`

The PING frame `f` carries. Fails on a wrong type, a non-zero stream id, or a
payload that is not exactly 8 bytes.

### GOAWAY (§6.8)

### `GoawayFrame`

A GOAWAY frame: the `lastStreamId` processed, an `errorCode`, and optional
`debugData`. Always on stream 0.

### `encodeGoaway(f: GoawayFrame): []byte!`

The wire bytes of a GOAWAY frame.

### `decodeGoaway(f: Frame): GoawayFrame!`

The GOAWAY frame `f` carries. Fails on a wrong type, a non-zero stream id, or a
payload shorter than the fixed 8-byte header.

### WINDOW_UPDATE (§6.9)

### `WindowUpdateFrame`

A WINDOW_UPDATE frame: a flow-control `increment`. `streamId` 0 targets the whole
connection; a non-zero id targets that stream.

### `encodeWindowUpdate(f: WindowUpdateFrame): []byte!`

The wire bytes of a WINDOW_UPDATE frame.

### `decodeWindowUpdate(f: Frame): WindowUpdateFrame!`

The WINDOW_UPDATE frame `f` carries. Fails on a wrong type or a payload that is not
exactly 4 bytes.

### CONTINUATION (§6.10)

### `ContinuationFrame`

A CONTINUATION frame: the `streamId`, a continued `blockFragment`, and
`endHeaders`. The stream id must match the HEADERS/PUSH_PROMISE it continues.

### `encodeContinuation(f: ContinuationFrame): []byte!`

The wire bytes of a CONTINUATION frame. Fails on a zero stream id.

### `decodeContinuation(f: Frame): ContinuationFrame!`

The CONTINUATION frame `f` carries. Fails on a wrong type or a zero stream id.
## Connection engine

HPACK and the frame codec are pure - no I/O, no state machine. `conn.bit` puts
them to work over a live connection. A `Conn` runs the client preface and the
SETTINGS exchange, tracks each stream through the idle → open → half-closed →
closed lifecycle (RFC 9113 §5.1), reassembles HEADERS + CONTINUATION blocks into
header lists, paces DATA against the per-stream and connection flow-control
windows, and multiplexes many concurrent request/response exchanges over the one
byte stream. It is transport-agnostic and TLS-free: a `Transport` is any
bidirectional byte stream, so the same engine runs over a socket or an in-memory
pipe.

A `Conn` is an actor. Three green threads run underneath it - a reader that turns
transport bytes into frames, a writer that drains queued frames, and a loop that
owns every piece of mutable state - and they talk only over channels, so there is
no shared mutable memory to race on. Because the one loop encodes outgoing header
blocks and decodes incoming ones in wire order, the two peers' HPACK dynamic
tables stay in lock-step automatically. `connect` returns once the peer's opening
SETTINGS is in effect, so the peer's window and frame-size limits are known
before the first request goes out.

A stream leaves the loop's stream table as soon as it closes. A late
RST_STREAM, WINDOW_UPDATE or PRIORITY arriving after that - which RFC 9113 §5.1
allows, since the peer's frames were already in flight when the stream ended -
is answered without a table entry: it is ignored, exactly as it was when the
entry was still there. DATA on such a stream is still refused with
STREAM_CLOSED, and the identifier is not reusable, because the ordering state a
new stream is judged against belongs to the connection rather than to the table.

```bit
import { connect, accept, Transport, defaultConfig, Request, Response, newRequest, newResponse } from "std/http2"

// Answer every request with its path echoed back in the body.
fn echo(req: Request): Response {
  return newResponse(200, []byte("you asked for " + req.path))
}

// `client` and `server` are the two ends of one byte stream - a socket pair, or
// an in-memory pipe in a test. Serve one end and fetch "/" from the other. `0`
// is "no deadline" - see `connect` below for a bounded wait.
fn demo(client: Transport, server: Transport): Response! {
  spawn serveOn(server)
  let conn = connect(client, defaultConfig(), 0)?
  return conn.roundTrip(newRequest("GET", "example.com", "/"))?
}

fn serveOn(t: Transport) {
  let conn = accept(t, defaultConfig(), 0) catch e {
    return
  }
  conn.serve(echo) catch e2 {
    return
  }
}
```

### `Transport`

A bidirectional byte stream, the substrate a `Conn` runs on. `read(n)` returns up
to `n` bytes and an empty slice at end-of-stream; `write(b)` delivers every byte
or fails; `shutdown()` releases the stream. All three fields are exported and are
plain function values, so any stream - a `std/net` connection, an in-memory pipe -
satisfies it. (The close hook is named `shutdown`, not `close`, to avoid
shadowing the `close` channel builtin.)

### `newTransport(read: (int) => []byte, write: ([]byte) => ()!, shutdown: () => ()): Transport`

Bundle the three closures into a `Transport`.

### `Config`

The SETTINGS a `Conn` advertises: `initialWindowSize` (the per-stream receive
window it grants the peer), `maxFrameSize` (the largest frame payload it
accepts), `headerTableSize` (its HPACK dynamic-table bound),
`maxHeaderListBytes` (SETTINGS_MAX_HEADER_LIST_SIZE), and
`maxConcurrentStreams` (SETTINGS_MAX_CONCURRENT_STREAMS) - plus `maxBodyBytes`,
the one local limit that is not a SETTINGS parameter. All six fields are
exported.

`initialWindowSize` is the receive window granted to each stream; the
connection's own window starts at the RFC's fixed 65535 and is not configurable.
Both are accounted rather than merely advertised: a DATA frame spends the credit
it uses when the frame is counted, and the credit comes back on the
WINDOW_UPDATE that renews it, so a peer sending past the credit it holds fails
the connection with GOAWAY carrying `errorFlowControlError` (RFC 9113 §6.9.1).
A conforming peer never reaches that ceiling, because the engine buffers the
whole body and so renews the credit as the DATA lands.

The connection window is renewed for every DATA frame the connection counts,
including the two whose bytes it drops: a body refused by `maxBodyBytes` below,
and a frame for a stream that is already closed or has been released. Those
bytes are counted (RFC 9113 §5.1 puts DATA for a closed stream under the
connection window like any other) and granted straight back, because the peer's
own send window stays down until our WINDOW_UPDATE arrives - so a discard that
kept the credit would stall every stream on the connection, four refused bodies
at the default 16384-byte frame size being enough to consume all 65535 bytes of
it. Only the connection window: the stream is being reset or is gone, and a
WINDOW_UPDATE on it would grant credit nobody can spend.

Because the credit for a frame is granted in the same act that spends it, the
connection window is a per-frame ceiling in practice rather than a running
total. Bounding what a peer may upload is `maxBodyBytes`' job, not flow
control's.

`maxHeaderListBytes` is the largest header block the connection will accumulate
across a HEADERS frame and every CONTINUATION continuing it. `maxFrameSize`
bounds each *frame* and says nothing about their sum, so without this a peer
could send HEADERS without END_HEADERS and then CONTINUATION frames forever. A
fragment that would take the block past the budget is refused before it is
accumulated, and the connection fails with GOAWAY carrying
`errorEnhanceYourCalm` (RFC 9113 §7).

The failure is at the *connection* level, not the stream level, because the
HPACK decoder's dynamic table is shared by every stream on the connection and is
only advanced by decoding a block: skipping one desyncs the table for every
later block, and decoding it is the work being refused. The code is
ENHANCE_YOUR_CALM rather than PROTOCOL_ERROR because the peer's framing is
legal - it is generating more load than we will process, which is what that code
says.

The number is counted in the HPACK-*encoded* octets the connection holds, while
SETTINGS_MAX_HEADER_LIST_SIZE is defined on the *uncompressed* field list (name
+ value + 32 per field). Huffman coding does not only shrink - an octet above
`0x7f` costs 20 to 30 bits - so the default carries headroom for that asymmetry
rather than matching the advertised number exactly. As with `maxBodyBytes` there
is no value meaning "unlimited": `0` refuses every header block.

This limit too runs in both directions. The peer's own advertised
SETTINGS_MAX_HEADER_LIST_SIZE bounds the header lists *this* endpoint sends: a
`roundTrip` whose request exceeds it fails locally, before a stream is opened
and before anything reaches the wire, with a message naming both the size
measured and the limit; a `serve` handler whose response exceeds it has no
caller to fail, so that stream is reset with `errorInternalError` and the block
is never encoded. Neither refusal drops header fields to fit.

What is compared there is the *uncompressed* list the RFC defines - name + value
+ 32 per field - and not the encoded octets `maxHeaderListBytes` counts, because
that is the accounting the peer itself applies. The two differ in both
directions, so they are not interchangeable: Huffman coding can push an encoded
block above the list it decodes to, and the dynamic table can pull a repeated
block far below it. A peer that advertises nothing imposes no limit, which is
what the parameter's absence means on the wire; `0` from a peer is a limit of
zero, meaning it will accept no header list at all.

`maxBodyBytes` is the most DATA one stream may accumulate. A frame that would
take a stream's buffered body past it is refused before those bytes are
appended, and the stream is reset with `errorEnhanceYourCalm` (RFC 9113 §7); the
rest of the connection's streams carry on. It has no wire representation on
purpose: flow control bounds bytes *in flight*, and this engine replenishes both
windows the instant DATA lands - precisely because it buffers the whole body -
so only a local budget bounds bytes *resident*. There is deliberately no value
meaning "unlimited": `0` refuses every body.

The budget is per stream, and the connection's total is bounded by the stream
table holding only streams that are still in flight: a stream is dropped from it
the moment it reaches the closed state, taking its buffered body with it. So a
connection kept open for hours does not accumulate every body it ever carried,
and `maxBodyBytes` times the number of concurrent streams is the ceiling rather
than `maxBodyBytes` times every request ever served.

`maxConcurrentStreams` is what bounds that multiplier: the most streams a peer
may have open at once. It is advertised as SETTINGS_MAX_CONCURRENT_STREAMS, so a
conforming peer stops on its own side, and it is also enforced - a peer-initiated
HEADERS that would open one stream too many is answered with RST_STREAM carrying
`errorRefusedStream` and no stream is created, so the refused request costs no
stream state, no body buffer and no handler thread. That is a *stream* error, not
a connection one (RFC 9113 §5.1.2): the peer's framing is legal and the streams
already running are unaffected. REFUSED_STREAM rather than PROTOCOL_ERROR because
§8.7 makes it the positive statement that the request was not processed, so the
peer may safely retry it on another connection.

The limit runs in both directions. The peer's own advertised
SETTINGS_MAX_CONCURRENT_STREAMS is applied to the streams *this* endpoint opens:
a `roundTrip` that would exceed it fails locally, with a message naming the
limit, rather than opening a stream the peer must reject. A peer that advertises
nothing is treated as having no limit, which is what the parameter's absence
means on the wire. As with the byte budgets there is no value meaning
"unlimited": `0` refuses every stream.

### `defaultConfig(): Config`

The RFC defaults: a 65535-byte initial window, a 16384-byte max frame size, a
4096-byte header table, a 128 KiB header-block budget, 250 concurrent streams,
and a 32 MiB per-stream body budget - the last the same number `std/http`'s
`setMaxBodyBytes` setters default to, so an HTTP/2 exchange and an HTTP/1.1 one
are bounded alike.

250 concurrent streams matches what Go's `http2` server allows; RFC 9113 §6.5.2
asks implementations not to advertise fewer than 100.

128 KiB is twice `std/http`'s own `maxHeaderBytes` (65536), which bounds a
decoded HTTP/1.1 block rather than an encoded HPACK one. The headroom is
measured against the largest header block the test corpus sends: the 60000-byte
value in `_tests_/imports/http2conn` Huffman-codes to 56920 octets, 56947 for
the whole block, which is 43% of the budget.

### `Request`

An HTTP/2 request: the `:method`, `:scheme`, `:authority`, and `:path`
pseudo-headers as named fields, the remaining regular `headers` as a
`[]HeaderField`, and the `body` bytes. All fields are exported.

### `Response`

An HTTP/2 response: the numeric `status`, the regular `headers`, and the `body`.
All fields are exported. A `status` of 0 returned from a `serve` handler is the
signal to abort that stream with RST_STREAM (CANCEL) instead of answering.

### `newRequest(method: string, authority: string, path: string): Request`

A request with the `https` scheme, no extra headers, and no body. Set `headers`
and `body` on the result for anything more.

### `newResponse(status: int, body: []byte): Response`

A response with a status and a body and no extra headers.

### `getHeader(headers: []HeaderField, name: string): string`

The value of the first header named `name` (case-sensitive - HTTP/2 field names
are lower-case), or "" if absent.

### `connect(t: Transport, cfg: Config, deadlineNs: int): Conn!`

Run the client side of the connection: send the preface and our SETTINGS over
`t`, and return a `Conn` once the peer's SETTINGS is in effect. Drive it with
`roundTrip`.

`deadlineNs` bounds the wait for the peer's opening SETTINGS - an absolute
monotonic nanosecond deadline (`std/time`'s `monotonic().ns` plus a budget), or
`0` for no bound. Fails if the connection tears down before SETTINGS arrives,
or if the deadline elapses first - either way before this function returns, so
there is never a `Conn` left half-built. Pass the same deadline `t`'s own
reads are bounded by; a deadline over a transport whose reads are not bounded
by it can make this wait time out while the read underneath it keeps blocking
unrelated and unbounded.

### `accept(t: Transport, cfg: Config, deadlineNs: int): Conn!`

Run the server side: read and validate the client preface over `t`, exchange
SETTINGS, and return a `Conn`. Fails on a malformed preface. Drive it with
`serve`. `deadlineNs` is as `connect`'s.

### `Conn`

A live connection. Opaque - its mutable protocol state lives in the loop thread,
and every operation is a method that talks to it over a channel, so a `Conn` is
safe to share across green threads.

### `Conn.roundTrip(req: Request): Response!`

Send `req` on a fresh stream and block until its full response arrives. Safe to
call from many green threads at once - each call rides its own stream, multiplexed
over the one connection. Fails if the stream is reset by the peer or the
connection is closing.

It also fails when the peer sends GOAWAY naming a `lastStreamId` below this
stream's id: the peer is stating that the stream was not processed and never
will be (RFC 9113 §6.8), so the request is safe to retry on a new connection.
The message names the GOAWAY's error code. Streams at or below `lastStreamId`
are unaffected - the peer may still answer those - so a graceful shutdown lets
in-flight requests finish.

And it fails when this side resets the stream through `Conn.resetStream`, with
`http2: stream reset locally (code N)` - deliberately different wording from
the peer's reset, because no peer acted. That call is how a parked `roundTrip`
is cancelled: this method has no cancellation of its own.

### `Conn.serve(handler: (Request) => Response): ()!`

Accept inbound requests and dispatch each to `handler` on its own green thread,
until the connection closes. A handler that returns a `Response` with status 0
aborts that stream with RST_STREAM (CANCEL).

Two things end it: the transport dying, and this side raising a *connection
error* against a misbehaving peer - a malformed frame, an illegal stream id, a
header block past `maxHeaderListBytes`, and so on. In both cases the engine
stops its loop and releases this call, so the caller that owns the transport is
the one that closes it. A connection error queues its GOAWAY before it stops
the writer, so the peer is always told why (RFC 9113 §5.4.1).

### `Conn.waitReaderDone()`

Block until the reader green thread spawned by `connect`/`accept` has noticed
the transport is gone and returned. The reader signals right before it
returns, and that signal is the only way anything outside that thread can know
it has stopped touching the transport - this runtime has no way to interrupt a
green thread parked in a transport read from outside.

Needed because a bare `close()` on the transport does not wake a reader
already parked in a read on it. The required teardown order is: shut the
transport down (the real wakeup), call this to block until the reader has
observed it, THEN close. Getting the order wrong deadlocks - waiting on this
after a bare close hangs forever, since nothing produced the wakeup the
parked read is waiting for.

### `Conn.waitWriterDone()`

Block until the writer green thread spawned by `connect`/`accept` has stopped
touching the transport. Unlike the reader, the writer is normally parked on an
empty command channel rather than a transport read, so closing or shutting
down the transport does not wake it by itself - only the connection's own
teardown queues the stop message that releases it, on either of the two paths
that end a connection: the transport's EOF, or a connection error this side
raised.

Call this AFTER `waitReaderDone()` and BEFORE reusing anything the transport
owned, for the identical use-after-close reason `waitReaderDone()` documents -
the writer's last queued write is a real transport write, and closing out from
under it is the same fd-reuse hazard a stale reader creates. NOT idempotent -
call it exactly once per `Conn`, from a single teardown path.

### `Conn.close()`

Begin a graceful shutdown by sending GOAWAY: the peer starts no new streams and
subsequent `roundTrip` calls are refused, while in-flight streams still complete.

Deliberately *not* a teardown: the loop keeps running and the writer keeps
draining, which is what lets those in-flight streams finish. That is the whole
difference between this GOAWAY and the one a connection error sends.

### `Conn.resetStream(streamId: int, errorCode: int)`

Abort stream `streamId` by sending RST_STREAM with `errorCode` (an `error*`
constant). A `roundTrip` parked on that stream is released with
`http2: stream reset locally (code N)`; a stream that has already finished, or
that never existed, sends the RST_STREAM and changes nothing else (RFC 9113
§6.4 permits both).

**You must track the stream id yourself.** Nothing in this API hands one out:
`roundTrip` returns a `Response` and `serve` hands its handler a `Request`,
neither of which carries the id. So this is usable from exactly one position -
a client that knows which stream its own request rode. Each accepted
`roundTrip` takes the next client id in order, starting at 1 and stepping by 2
(a request refused because the connection is closing takes none), so a caller
that keeps one `roundTrip` in flight per `Conn` knows that request's id and can
cancel it from another green thread. Callers that run several `roundTrip` calls
at once on one `Conn` cannot: those race for ids and nothing reports which one
each got. There is no way to reset a stream from inside a `serve` handler
today.
