# std/http2

The HTTP/2 wire layer, built from scratch in Bit: **HPACK** header compression
(RFC 7541) and the **frame** codec (RFC 7540 / 9113). Both are pure byte codecs —
they turn values into wire bytes and back with no I/O, no TLS, and no connection
state machine — so they compose under a real HTTP/2 connection without carrying
any transport of their own. The two files share one flat module: import
everything from `"std/http2"`.

HPACK's `Encoder` and `Decoder` each hold their own dynamic-table state; a matched
pair walked over the same header sequence evolve identical tables. The frame codec
is a set of typed encode/decode pairs over the fixed 9-byte frame header. Both
halves are strict on decode — every malformed input (a bad index, an EOS symbol in
a Huffman string, a frame over `SETTINGS_MAX_FRAME_SIZE`, padding larger than its
payload, a connection-level frame on the wrong stream) is rejected with a `!`
error rather than best-guessed.

<!-- doctest: per-block -->

## HPACK

HPACK (RFC 7541) compresses a list of `(name, value)` header fields against two
tables: a fixed 61-entry **static table** and a per-connection **dynamic table**
that both peers grow in lock-step. A field that is already in a table costs a
single index byte; a new field is sent as a string literal — optionally
**Huffman**-coded — and (usually) added to the dynamic table for next time.

An `Encoder` and a `Decoder` are the two halves. Reuse one of each per connection
so their dynamic tables track each other. This example round-trips a request:

```bit
import { newEncoder, newDecoder, HeaderField } from "std/http2"

// Build a header block, then decode it back to the same fields. `enc` and `dec`
// each hold their own dynamic table, evolving identically across calls.
function roundTrip(): []HeaderField! {
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
function encodeSecret(): []byte {
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
function huffRoundTrip(s: string): []byte! {
  return huffmanDecode(huffmanEncode([]byte(s)))?
}
```

### `huffmanDecode(data: []byte): []byte!`

Huffman-decode `data`. Fails on a code that never resolves within 30 bits, on the
EOS symbol appearing in the stream, or on final padding that is longer than 7 bits
or not all 1-bits (RFC 7541 §5.2).

## Frames

Every HTTP/2 message is a stream of frames: a fixed 9-byte header — a 24-bit
payload length, an 8-bit type, an 8-bit flags field, a reserved bit, and a 31-bit
stream id (RFC 7540 §4.1) — followed by a type-specific payload. `readFrame`
splits one frame off a buffer, enforcing the negotiated `SETTINGS_MAX_FRAME_SIZE`;
the typed `decode*` helpers then interpret the payload.

```bit
import { readFrame, decodeSettings, frameSettings, defaultMaxFrameSize } from "std/http2"

// Read one frame off `buf`, and if it is SETTINGS, pull out its parameters.
function firstSettings(buf: []byte): int! {
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
function settingsBytes(): []byte! {
  let params = []Setting{ Setting{ id: settingsMaxFrameSize, value: 32768 } }
  return encodeSettings(SettingsFrame{ ack: false, settings: params })?
}
```

A HEADERS frame carries an HPACK block fragment — encode the headers with an
`Encoder`, then frame the bytes:

```bit
import { newEncoder, HeaderField, encodeHeaders, HeadersFrame } from "std/http2"

// Frame a header block onto stream `sid`, ending both the headers and the stream.
function headersFrame(sid: int): []byte! {
  let enc = newEncoder()
  let block = enc.encode([]HeaderField{ HeaderField{ name: ":status", value: "200", sensitive: false } })
  return encodeHeaders(HeadersFrame{
    streamId: sid,
    blockFragment: block,
    endStream: true,
    endHeaders: true,
    padLength: 0 - 1,
    hasPriority: false,
    exclusive: false,
    streamDependency: 0,
    weight: 0,
  })?
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

The wire bytes of a SETTINGS frame — six bytes per parameter. Fails if `ack` is set
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

HPACK and the frame codec are pure — no I/O, no state machine. `conn.bit` puts
them to work over a live connection. A `Conn` runs the client preface and the
SETTINGS exchange, tracks each stream through the idle → open → half-closed →
closed lifecycle (RFC 9113 §5.1), reassembles HEADERS + CONTINUATION blocks into
header lists, paces DATA against the per-stream and connection flow-control
windows, and multiplexes many concurrent request/response exchanges over the one
byte stream. It is transport-agnostic and TLS-free: a `Transport` is any
bidirectional byte stream, so the same engine runs over a socket or an in-memory
pipe.

A `Conn` is an actor. Three green threads run underneath it — a reader that turns
transport bytes into frames, a writer that drains queued frames, and a loop that
owns every piece of mutable state — and they talk only over channels, so there is
no shared mutable memory to race on. Because the one loop encodes outgoing header
blocks and decodes incoming ones in wire order, the two peers' HPACK dynamic
tables stay in lock-step automatically. `connect` returns once the peer's opening
SETTINGS is in effect, so the peer's window and frame-size limits are known
before the first request goes out.

```bit
import { connect, accept, Transport, defaultConfig, Request, Response, newRequest, newResponse } from "std/http2"

// Answer every request with its path echoed back in the body.
function echo(req: Request): Response {
  return newResponse(200, []byte("you asked for " + req.path))
}

// `client` and `server` are the two ends of one byte stream — a socket pair, or
// an in-memory pipe in a test. Serve one end and fetch "/" from the other.
function demo(client: Transport, server: Transport): Response! {
  spawn serveOn(server)
  let conn = connect(client, defaultConfig())?
  return conn.roundTrip(newRequest("GET", "example.com", "/"))?
}

function serveOn(t: Transport) {
  let conn = accept(t, defaultConfig()) catch e {
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
plain function values, so any stream — a `std/net` connection, an in-memory pipe —
satisfies it. (The close hook is named `shutdown`, not `close`, to avoid
shadowing the `close` channel builtin.)

### `newTransport(read: (int) => []byte, write: ([]byte) => ()!, shutdown: () => ()): Transport`

Bundle the three closures into a `Transport`.

### `Config`

The SETTINGS a `Conn` advertises: `initialWindowSize` (the per-stream receive
window it grants the peer), `maxFrameSize` (the largest frame payload it
accepts), and `headerTableSize` (its HPACK dynamic-table bound). All three fields
are exported.

### `defaultConfig(): Config`

The RFC defaults: a 65535-byte initial window, a 16384-byte max frame size, and a
4096-byte header table.

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

The value of the first header named `name` (case-sensitive — HTTP/2 field names
are lower-case), or "" if absent.

### `connect(t: Transport, cfg: Config): Conn!`

Run the client side of the connection: send the preface and our SETTINGS over
`t`, and return a `Conn` once the peer's SETTINGS is in effect. Drive it with
`roundTrip`.

### `accept(t: Transport, cfg: Config): Conn!`

Run the server side: read and validate the client preface over `t`, exchange
SETTINGS, and return a `Conn`. Fails on a malformed preface. Drive it with
`serve`.

### `Conn`

A live connection. Opaque — its mutable protocol state lives in the loop thread,
and every operation is a method that talks to it over a channel, so a `Conn` is
safe to share across green threads.

### `Conn.roundTrip(req: Request): Response!`

Send `req` on a fresh stream and block until its full response arrives. Safe to
call from many green threads at once — each call rides its own stream, multiplexed
over the one connection. Fails if the stream is reset by the peer or the
connection is closing.

### `Conn.serve(handler: (Request) => Response): ()!`

Accept inbound requests and dispatch each to `handler` on its own green thread,
until the connection closes. A handler that returns a `Response` with status 0
aborts that stream with RST_STREAM (CANCEL).

### `Conn.close()`

Begin a graceful shutdown by sending GOAWAY: the peer starts no new streams and
subsequent `roundTrip` calls are refused, while in-flight streams still complete.

### `Conn.resetStream(streamId: int, errorCode: int)`

Abort stream `streamId` by sending RST_STREAM with `errorCode` (an `error*`
constant).
