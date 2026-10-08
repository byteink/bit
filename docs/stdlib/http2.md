# std/http2

Most programs never import `std/http2` directly. [`std/http`](http.md) and
[`pkg/web`](/packages/web) negotiate HTTP/2 over TLS automatically and speak it for
you - this module is the wire layer underneath them: HPACK header compression (RFC
7541), the frame codec (RFC 7540/9113), and the connection engine that runs both
over a live transport.

Reach for `std/http2` yourself when you are running the protocol over a transport
`std/http` does not manage for you - an in-memory pipe in a test, a tunnel, a proxy
- or when you need a connection limit `std/http` does not expose, such as the
per-stream body budget.

<!-- doctest: per-block -->

## Running a connection over your own transport

A `Conn` runs HTTP/2 over any `Transport`: a `read`/`write`/`shutdown` triple, so
the same engine works over a socket, a pipe, or (as here) an in-memory pair used in
a test. `connect` runs the client preface and SETTINGS handshake; `accept` runs the
server side; `Conn.serve` dispatches inbound requests to a handler on their own
green thread.

```bit
import {
  connect, accept, Conn, Transport, defaultConfig, Request, Response, Stream,
  errorRefusedStream,
} from "std/http2"

// Answer every request with its path echoed back - except "/elsewhere", which is
// refused on its own stream so the client knows it may retry elsewhere.
fn echo(req: Request, s: Stream): Response {
  if (req.path == "/elsewhere") {
    s.reset(errorRefusedStream)
    return Response(0, []byte(0))
  }
  return Response(200, []byte("you asked for " + req.path))
}

// `client` and `server` are the two ends of one byte stream. Serve one end and
// fetch "/" from the other. `0` is "no deadline".
fn demo(client: Transport, server: Transport): Response! {
  spawn serveOn(server)
  let conn = connect(client, defaultConfig(), 0)?
  return conn.roundTrip(Request("GET", "example.com", "/"))?
}

// How many of `n` requests to put on the wire at once. The server's opening
// SETTINGS named how many streams it will hold open; asking for more is refused
// stream by stream, so stay at or under `peerMaxStreams()`.
fn batchSize(conn: Conn, n: int): int {
  let limit = conn.peerMaxStreams()
  if (n < limit) {
    return n
  }
  return limit
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

`roundTrip` blocks for the full response, and several green threads may call it on
one `Conn` at once: each rides its own stream. `batchSize` shows the one number such
a caller needs from the connection, `Conn.peerMaxStreams()`. For a large response, `roundTripStream`
returns as soon as the headers arrive and hands you a `Stream` to read the body a
chunk at a time - the same shape a `serve` handler uses under `Config.streamBodies`,
below.

## Tuning limits

`defaultConfig()` gives you the RFC defaults: a 65535-byte window, 16384-byte max
frame, 4096-byte HPACK table, 250 concurrent streams, and a 32 MiB per-stream body
budget. Start from it and change only what your workload needs - a server accepting
uploads larger than 32 MiB raises `maxBodyBytes`; a server whose handlers want the
body as it arrives, rather than complete, sets `streamBodies`:

```bit
import { Config, defaultConfig, Request, Response, Stream } from "std/http2"

// Count a request body without ever holding it whole. `streamBodies` calls the
// handler as soon as the headers are in, with `req.body` empty; each `Stream.read`
// takes the next chunk as it lands and renews the connection's flow-control credit
// by exactly what it took.
fn count(_req: Request, s: Stream): Response {
  let n = 0
  while (true) {
    let c = s.read() catch e {
      return Response(500, []byte(e.message()))
    }
    n = n + len(c.data)
    if (c.eof) {
      return Response(200, []byte("${n} bytes"))
    }
  }
}

fn streamingConfig(): Config {
  let cfg = defaultConfig()
  cfg.streamBodies = true
  return cfg
}
```

## Sharp edges

**Tearing down a `Conn` has a required order.** `connect`/`accept` spawn a reader
and a writer green thread. A bare `shutdown()` on the transport does not wake a
reader parked in a read on it, so the order is: shut the transport down, call
`Conn.waitReaderDone()` to block until the reader has noticed, THEN
`Conn.waitWriterDone()`, then close. Waiting on either before the matching wakeup
hangs forever.

**`roundTrip` and `Config.streamBodies` do not mix.** A handler under
`streamBodies` takes its own body; `roundTrip` can only return a whole `Response`
and refuses to run under it with a message telling you to call `roundTripStream`
instead.

**`Conn.resetStream` needs a stream id you must track yourself.** Nothing in this
API hands one out - `roundTrip` returns a `Response`, `serve` hands its handler a
`Stream` with no id on it. It only works from the one position that knows its own
id: a client with exactly one `roundTrip` in flight per `Conn`, which took the next
client id (starting at 1, stepping by 2). A server handler needs none of this -
`Stream.reset` is the same call with the id already bound.

## When not to use it directly

If you are serving HTTP to browsers or ordinary clients over TLS, use
[`pkg/web`](/packages/web) or [`std/http`](http.md): they negotiate HTTP/2 with
ALPN, run this engine underneath, and give you the plain request/handler API
either way. Reach for `std/http2` only when you own the transport yourself.

## HPACK: header compression

HPACK (RFC 7541) compresses request and response headers against two tables:
a fixed static table and a per-connection dynamic table that grows as headers
are sent. An `Encoder` and a `Decoder` each hold their own copy of the
dynamic table; run one of each per connection so the two stay in step.

### `HeaderField`

One header field: a `name`, a `value`, and a `sensitive` flag. Set `sensitive`
on a field such as a cookie or a bearer token to force it to be sent without
ever entering the dynamic table.

### `Encoder(maxTableSize: int = 4096, huffman: bool = true)`

The stateful HPACK encoder. It picks the smallest representation for each
field and keeps its dynamic table current as it encodes. Reuse one across a
connection.

`Encoder()` has the default 4096-byte dynamic table and Huffman coding on.
`maxTableSize` and `huffman` match a table size the peer negotiated or switch
Huffman off:

```bit
import { Encoder, Decoder, HeaderField } from "std/http2"

// A connection whose peer advertised a 1 KiB header table and asked for plain
// string literals. The decoder's limit is the table size it advertised.
fn roundTrip(fields: []HeaderField): []HeaderField! {
  let enc = Encoder(maxTableSize = 1024, huffman = false)
  let dec = Decoder(maxTableSize = 1024)
  return dec.decode(enc.encode(fields))?
}

fn defaults(fields: []HeaderField): []byte {
  return Encoder().encode(fields)
}
```

### `Encoder.encode(fields: []HeaderField): []byte`

Encodes `fields` into one header block, updating the dynamic table as it
goes.

### `Encoder.changeTableSize(maxTableSize: int)`

Resizes the encoder's dynamic table, evicting entries if it shrinks.

### `Encoder.tableSize(): int`

The current size in bytes of the encoder's dynamic table.

### `Encoder.tableCount(): int`

The number of entries currently in the encoder's dynamic table.

### `Encoder.tableEntry(i: int): HeaderField!`

The dynamic-table entry at index `i`, newest first. Fails if `i` is out of
range.

### `Decoder(maxTableSize: int = 4096)`

The stateful HPACK decoder. It keeps its dynamic table current as it decodes
and rejects a peer size update above its limit. Reuse one across a
connection.

`Decoder()` has the default 4096-byte table limit. `Decoder(maxTableSize = n)`
sets the limit to what was advertised to the peer.

### `Decoder.decode(block: []byte): []HeaderField!`

Decodes one header block into its fields. Fails on any malformed input.

### `Decoder.tableSize(): int`

The current size in bytes of the decoder's dynamic table.

### `Decoder.tableCount(): int`

The number of entries currently in the decoder's dynamic table.

### `Decoder.tableEntry(i: int): HeaderField!`

The dynamic-table entry at index `i`, newest first. Fails if `i` is out of
range.

### `huffmanEncode(data: []byte): []byte`

Huffman-codes `data`. `Encoder` calls this for its string literals; it is
exported for direct use too.

### `huffmanDecode(data: []byte): []byte!`

The inverse of `huffmanEncode`. Fails on invalid Huffman-coded input.

## The frame header

Every HTTP/2 message is a stream of frames: a fixed 9-byte header followed by
a type-specific payload.

### `FrameHeader`

A parsed frame header: the payload `length`, the frame type `ftype`, the
`flags`, and the `streamId` it belongs to.

### `Frame`

A whole frame: its `header` and the raw `payload` bytes. `readFrame` produces
one; a `decode*` function turns it into a typed frame such as `DataFrame`.

### `encodeFrameHeader(h: FrameHeader): []byte!`

The 9 wire bytes of a frame header.

### `decodeFrameHeader(b: []byte): FrameHeader!`

The frame header the first 9 bytes of `b` spell out. Fails on fewer than 9
bytes.

### `readFrame(buf: []byte, maxFrameSize: int): Frame!`

Reads one whole frame off the front of `buf`, rejecting a frame larger than
`maxFrameSize`. Advance past `9 + frame.header.length` bytes to read the next
one.

## Frame types

The ten frame type codes, used on `FrameHeader.ftype` to tell frames apart.

### `frameData: int`

DATA: a piece of a stream's message body.

### `frameHeaders: int`

HEADERS: opens a stream and carries a header block.

### `framePriority: int`

PRIORITY: a stream's priority dependency and weight.

### `frameRstStream: int`

RST_STREAM: abrupt termination of a stream.

### `frameSettings: int`

SETTINGS: connection configuration parameters.

### `framePushPromise: int`

PUSH_PROMISE: a server's promise to push a stream.

### `framePing: int`

PING: a connection liveness probe.

### `frameGoaway: int`

GOAWAY: connection shutdown, naming the last stream processed.

### `frameWindowUpdate: int`

WINDOW_UPDATE: a flow-control window increment.

### `frameContinuation: int`

CONTINUATION: a continued header block.

## Frame flags

The frame flag bits, read from `FrameHeader.flags`.

### `flagEndStream: int`

END_STREAM on DATA/HEADERS: this is the last frame for the stream.

### `flagEndHeaders: int`

END_HEADERS on HEADERS/PUSH_PROMISE/CONTINUATION: the header block is
complete.

### `flagPadded: int`

PADDED on DATA/HEADERS/PUSH_PROMISE: the payload carries padding.

### `flagPriority: int`

PRIORITY on HEADERS: a priority section precedes the header block.

### `flagAck: int`

ACK on SETTINGS/PING: this frame acknowledges the peer's frame.

## Settings parameter ids

The six SETTINGS parameter ids, used on `Setting.id`.

### `settingsHeaderTableSize: int`

The HPACK dynamic-table size limit the sender advertises.

### `settingsEnablePush: int`

Whether server push is permitted.

### `settingsMaxConcurrentStreams: int`

The most streams the sender will allow open at once.

### `settingsInitialWindowSize: int`

The initial per-stream flow-control window the sender grants.

### `settingsMaxFrameSize: int`

The largest frame payload the sender accepts.

### `settingsMaxHeaderListSize: int`

The largest header list the sender accepts.

## Frame-size bounds

### `defaultMaxFrameSize: int`

The default and minimum allowed max frame size, 16384 bytes.

### `maxMaxFrameSize: int`

The largest allowed max frame size, the widest value the 24-bit length field
can hold.

## Error codes

The error codes a stream or connection can be closed with, used on
`RstStreamFrame.errorCode` and `GoawayFrame.errorCode`.

### `errorNoError: int`

Graceful shutdown, no problem occurred.

### `errorProtocolError: int`

An unspecified protocol violation.

### `errorInternalError: int`

An internal fault on the sender's side.

### `errorFlowControlError: int`

A flow-control window was exceeded.

### `errorSettingsTimeout: int`

A SETTINGS frame was not acknowledged in time.

### `errorStreamClosed: int`

A frame arrived on a stream that was already closed.

### `errorFrameSizeError: int`

A frame's size was invalid for its type.

### `errorRefusedStream: int`

The stream was refused before any processing, safe to retry elsewhere.

### `errorCancel: int`

The stream is no longer needed.

### `errorCompressionError: int`

The HPACK decoder state could not be recovered.

### `errorConnectError: int`

A CONNECT tunnel failed.

### `errorEnhanceYourCalm: int`

The peer is generating more load than will be processed.

### `errorInadequateSecurity: int`

The transport is not secure enough for this request.

### `errorHttp11Required: int`

The peer requires HTTP/1.1 for this request.

## DATA frames

### `DataFrame`

A DATA frame: `streamId`, the body `data`, `endStream`, and `padLength`.

### `encodeData(f: DataFrame): []byte!`

The wire bytes of a DATA frame.

### `decodeData(f: Frame): DataFrame!`

The DATA frame `f` carries. Fails if `f` is not a DATA frame.

## HEADERS frames

### `HeadersFrame`

A HEADERS frame: `streamId`, the header block `blockFragment`, `endStream`,
`endHeaders`, `padLength`, and an optional priority section.

### `encodeHeaders(f: HeadersFrame): []byte!`

The wire bytes of a HEADERS frame.

### `decodeHeaders(f: Frame): HeadersFrame!`

The HEADERS frame `f` carries. Fails if `f` is not a HEADERS frame.

## PRIORITY frames

### `PriorityFrame`

A PRIORITY frame: `streamId`, `exclusive`, `streamDependency`, and `weight`.

### `encodePriority(f: PriorityFrame): []byte!`

The wire bytes of a PRIORITY frame.

### `decodePriority(f: Frame): PriorityFrame!`

The PRIORITY frame `f` carries. Fails if `f` is not a PRIORITY frame.

## RST_STREAM frames

### `RstStreamFrame`

A RST_STREAM frame: `streamId` and the `errorCode` it is reset with.

### `encodeRstStream(f: RstStreamFrame): []byte!`

The wire bytes of a RST_STREAM frame.

### `decodeRstStream(f: Frame): RstStreamFrame!`

The RST_STREAM frame `f` carries. Fails if `f` is not a RST_STREAM frame.

## SETTINGS frames

### `Setting`

One SETTINGS parameter: an `id` (a `settings*` constant) and its `value`.

### `SettingsFrame`

A SETTINGS frame: either `ack` set, or a list of `settings`.

### `encodeSettings(f: SettingsFrame): []byte!`

The wire bytes of a SETTINGS frame.

### `decodeSettings(f: Frame): SettingsFrame!`

The SETTINGS frame `f` carries. Fails if `f` is not a SETTINGS frame.

## PUSH_PROMISE frames

### `PushPromiseFrame`

A PUSH_PROMISE frame: the carrying `streamId`, the `promisedStreamId`, the
request headers in `blockFragment`, `endHeaders`, and `padLength`.

### `encodePushPromise(f: PushPromiseFrame): []byte!`

The wire bytes of a PUSH_PROMISE frame.

### `decodePushPromise(f: Frame): PushPromiseFrame!`

The PUSH_PROMISE frame `f` carries. Fails if `f` is not a PUSH_PROMISE frame.

## PING frames

### `PingFrame`

A PING frame: 8 opaque `data` bytes, echoed back with `ack` set.

### `encodePing(f: PingFrame): []byte!`

The wire bytes of a PING frame.

### `decodePing(f: Frame): PingFrame!`

The PING frame `f` carries. Fails if `f` is not a PING frame.

## GOAWAY frames

### `GoawayFrame`

A GOAWAY frame: the `lastStreamId` processed, an `errorCode`, and optional
`debugData`.

### `encodeGoaway(f: GoawayFrame): []byte!`

The wire bytes of a GOAWAY frame.

### `decodeGoaway(f: Frame): GoawayFrame!`

The GOAWAY frame `f` carries. Fails if `f` is not a GOAWAY frame.

## WINDOW_UPDATE frames

### `WindowUpdateFrame`

A WINDOW_UPDATE frame: a flow-control `increment`. `streamId` 0 targets the
whole connection; a non-zero id targets that stream.

### `encodeWindowUpdate(f: WindowUpdateFrame): []byte!`

The wire bytes of a WINDOW_UPDATE frame.

### `decodeWindowUpdate(f: Frame): WindowUpdateFrame!`

The WINDOW_UPDATE frame `f` carries. Fails if `f` is not a WINDOW_UPDATE
frame.

## CONTINUATION frames

### `ContinuationFrame`

A CONTINUATION frame: `streamId`, a continued `blockFragment`, and
`endHeaders`.

### `encodeContinuation(f: ContinuationFrame): []byte!`

The wire bytes of a CONTINUATION frame.

### `decodeContinuation(f: Frame): ContinuationFrame!`

The CONTINUATION frame `f` carries. Fails if `f` is not a CONTINUATION frame.

## The connection engine

HPACK and the frame codec are pure byte codecs. This part of the module puts
them to work over a live connection: it runs the handshake, tracks streams,
paces bodies against flow control, and multiplexes many requests over one
transport.

### `Transport(read: (int) => []byte, write: ([]byte) => ()!, shutdown: () => ())`

A bidirectional byte stream: `read`, `write`, and `shutdown` function values.
Any stream, such as a `std/net` connection or an in-memory pipe, can satisfy
this by supplying the three functions.

`Transport(read, write, shutdown)` bundles the three functions:

```bit
import { Transport } from "std/http2"

// A transport that never delivers a byte: reads return end of stream and
// writes are dropped. Useful for exercising a `Conn` that must not touch the
// network.
fn silent(): Transport {
  return Transport((n) => []byte(0), (b) => {}, () => {})
}
```

### `Config`

The connection limits a `Conn` advertises: `initialWindowSize`,
`maxFrameSize`, `headerTableSize`, `maxHeaderListBytes`,
`maxConcurrentStreams`, `maxBodyBytes`, and `streamBodies`. See "Tuning
limits" above.

### `defaultConfig(): Config`

A `Config` with the RFC default limits: see "Tuning limits" above for the
exact numbers.

### `Request(method: string, authority: string, path: string)`

An HTTP/2 request: `method`, `scheme`, `authority`, `path`, `headers`, and
`body`. The constructor makes one with the `https` scheme, no extra headers,
and no body; set `headers` and `body` afterwards when the request needs them.

### `Response(status: int, body: []byte)`

An HTTP/2 response: `status`, `headers`, and `body`. The constructor makes one
with a status and a body and no extra headers. A `status` of 0 returned from a
`serve` handler aborts the stream instead of sending a response.

### `getHeader(headers: []HeaderField, name: string): string`

The value of the first header named `name`, or `""` if it is absent.

### `connect(t: Transport, cfg: Config, deadlineNs: int, abort: Option<chan<int>> = Option.None): Conn!`

Runs the client side of the handshake over `t` and returns a `Conn` once the
peer's settings are in effect. `deadlineNs` bounds the wait; `0` means no
bound. A value sent on `abort` (capacity 1) ends the wait early: the transport
is shut down and `connect` fails with `Aborted`.

### `accept(t: Transport, cfg: Config, deadlineNs: int): Conn!`

Runs the server side of the handshake over `t` and returns a `Conn`. Fails on
a malformed client preface.

### `Conn`

A live HTTP/2 connection. Safe to use from many green threads at once; every
operation is a method that talks to its own background threads.

### `Conn.roundTrip(req: Request, deadlineNs: int = 0, abort: Option<chan<int>> = Option.None): Response!`

Sends `req` on a fresh stream and blocks for the full response. Fails if the
stream is reset, the connection is closing, or `Config.streamBodies` is set
(use `roundTripStream` instead).

`deadlineNs` is an absolute `monotonic` deadline for this one request, so
requests with different deadlines can share a connection. `0`, the default, falls
back to the deadline `connect` or `accept` received, where `0` means no bound.

`abort` is a channel of capacity 1 that another green thread sends one value on to
cancel just this request, in any phase: waiting for the headers or for the body.
The stream is reset with `RST_STREAM` carrying `errorCancel`, the connection
credit of the body bytes it had buffered goes back to the peer, frames the peer
had already sent for it are ignored, and the call fails with `Aborted`. The
connection and every other stream on it keep running.

### `Aborted`

The error `Conn.roundTrip` fails with after its `abort` channel received a value.
`message()` reads `http2: request aborted`. Unlike any other `roundTrip` failure it
says nothing about the connection, which stays usable.

### `Conn.roundTripStream(req: Request, deadlineNs: int = 0): (Response, Stream)!`

Sends `req` and returns as soon as the response headers arrive, with the body
still to come on the returned `Stream`. Use this for a large response you
want to read a chunk at a time instead of holding whole. `deadlineNs` bounds the
wait exactly as it does for `roundTrip`.

### `Conn.peerMaxStreams(): int`

The most streams the peer will let this side keep open at once: its
`SETTINGS_MAX_CONCURRENT_STREAMS` from the opening SETTINGS, or 2^32-1 when it
named none. A caller sharing one `Conn` between many requests caps its own
in-flight count at this number (as `batchSize` does in "Running a connection over
your own transport") instead of finding out from a refused stream.

The number is a bound, not a promise: a later SETTINGS from the peer can lower
it, and a stream the engine then may not open fails with an error.

### `Conn.serve(handler: (Request, Stream) => Response): ()!`

Accepts inbound requests and dispatches each to `handler` on its own green
thread, until the connection closes.

### `Conn.close()`

Begins a graceful shutdown: sends GOAWAY, refuses new requests, and lets
streams already in flight finish.

### `Conn.resetStream(streamId: int, errorCode: int)`

Aborts the stream `streamId` by sending RST_STREAM with `errorCode`. See
"Sharp edges" above for how to know which id to pass.

### `Conn.waitReaderDone()`

Blocks until the connection's background reader has noticed the transport is
gone and stopped. Part of the required shutdown order, see "Sharp edges"
above.

### `Conn.waitWriterDone()`

Blocks until the connection's background writer has stopped. Call this after
`waitReaderDone()`, see "Sharp edges" above.

### `Stream`

One inbound stream, handed to a `serve` handler as its second argument. Used
to read a streamed request body or to abort the stream.

### `Stream.reset(errorCode: int)`

Aborts this stream by sending RST_STREAM with `errorCode`.

### `Stream.read(): BodyChunk!`

Takes the next chunk of this stream's body as it arrives, without waiting for
the whole body. Blocks until at least one byte has arrived or the body has
ended.

### `BodyChunk`

One take from a stream's body: `data` is the bytes taken, `eof` says the peer
has ended the stream.
