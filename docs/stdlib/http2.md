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
  connect, accept, Transport, defaultConfig, Request, Response, Stream, newRequest, newResponse,
  errorRefusedStream,
} from "std/http2"

// Answer every request with its path echoed back - except "/elsewhere", which is
// refused on its own stream so the client knows it may retry elsewhere.
fn echo(req: Request, s: Stream): Response {
  if (req.path == "/elsewhere") {
    s.reset(errorRefusedStream)
    return newResponse(0, []byte(0))
  }
  return newResponse(200, []byte("you asked for " + req.path))
}

// `client` and `server` are the two ends of one byte stream. Serve one end and
// fetch "/" from the other. `0` is "no deadline".
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

`roundTrip` blocks for the full response. For a large response, `roundTripStream`
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
import { Config, defaultConfig, Request, Response, Stream, newResponse } from "std/http2"

// Count a request body without ever holding it whole. `streamBodies` calls the
// handler as soon as the headers are in, with `req.body` empty; each `Stream.read`
// takes the next chunk as it lands and renews the connection's flow-control credit
// by exactly what it took.
fn count(_req: Request, s: Stream): Response {
  let n = 0
  while (true) {
    let c = s.read() catch e {
      return newResponse(500, []byte(e.message()))
    }
    n = n + len(c.data)
    if (c.eof) {
      return newResponse(200, []byte("${n} bytes"))
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

## Reference

### HPACK

`newEncoder`/`Encoder` and `newDecoder`/`Decoder` each own a dynamic table; a
matched pair walked over the same header sequence evolve identical tables. A
`sensitive` field (a cookie, a bearer token) is always sent never-indexed, so it
never enters the table.

| | |
|---|---|
| `HeaderField { name, value, sensitive }` | one header field |
| `newEncoder(): Encoder` | encoder with the 4096-byte default table, Huffman on |
| `newEncoderConfig(maxTableSize: int, huffman: bool): Encoder` | encoder with an explicit table size and Huffman choice |
| `Encoder.encode(fields: []HeaderField): []byte` | encode one header block |
| `Encoder.changeTableSize(maxTableSize: int)` | resize the dynamic table |
| `Encoder.tableSize(): int`, `.tableCount(): int`, `.tableEntry(i: int): HeaderField!` | inspect the dynamic table |
| `newDecoder(): Decoder` | decoder with the 4096-byte default table limit |
| `newDecoderConfig(maxTableSize: int): Decoder` | decoder with an explicit table limit |
| `Decoder.decode(block: []byte): []HeaderField!` | decode one header block |
| `Decoder.tableSize(): int`, `.tableCount(): int`, `.tableEntry(i: int): HeaderField!` | inspect the dynamic table |
| `huffmanEncode(data: []byte): []byte` | RFC 7541 Huffman code (`Encoder` uses it for string literals) |
| `huffmanDecode(data: []byte): []byte!` | the inverse |

### Frames

Every frame is a fixed 9-byte header (`FrameHeader`) followed by a type-specific
payload. `readFrame` splits one off a buffer, enforcing `SETTINGS_MAX_FRAME_SIZE`;
each `decode*` interprets the payload, and each `encode*` builds it.

| | |
|---|---|
| `FrameHeader { length, ftype, flags, streamId }`, `Frame { header, payload }` | the parsed header and a whole frame |
| `encodeFrameHeader(h): []byte!`, `decodeFrameHeader(b): FrameHeader!` | codec for the header alone |
| `readFrame(buf, maxFrameSize): Frame!` | split one frame off `buf` |
| `frameData` `frameHeaders` `framePriority` `frameRstStream` `frameSettings` `framePushPromise` `framePing` `frameGoaway` `frameWindowUpdate` `frameContinuation` | the ten `FrameType` codes, for `FrameHeader.ftype` |
| `flagEndStream` `flagEndHeaders` `flagPadded` `flagPriority` `flagAck` | the frame flag bits |
| `settingsHeaderTableSize` `settingsEnablePush` `settingsMaxConcurrentStreams` `settingsInitialWindowSize` `settingsMaxFrameSize` `settingsMaxHeaderListSize` | the six `SettingsParameter` ids, for `Setting.id` |
| `defaultMaxFrameSize` (16384), `maxMaxFrameSize` (2^24-1) | `SETTINGS_MAX_FRAME_SIZE` bounds |
| `errorNoError` `errorProtocolError` `errorInternalError` `errorFlowControlError` `errorSettingsTimeout` `errorStreamClosed` `errorFrameSizeError` `errorRefusedStream` `errorCancel` `errorCompressionError` `errorConnectError` `errorEnhanceYourCalm` `errorInadequateSecurity` `errorHttp11Required` | the fourteen `ErrorCode` values, for `RstStreamFrame.errorCode`/`GoawayFrame.errorCode` |
| `DataFrame { streamId, data, endStream, padLength }`, `encodeData`, `decodeData` | DATA |
| `HeadersFrame { streamId, blockFragment, endStream, endHeaders, padLength, hasPriority, exclusive, streamDependency, weight }`, `encodeHeaders`, `decodeHeaders` | HEADERS |
| `PriorityFrame { streamId, exclusive, streamDependency, weight }`, `encodePriority`, `decodePriority` | PRIORITY |
| `RstStreamFrame { streamId, errorCode }`, `encodeRstStream`, `decodeRstStream` | RST_STREAM |
| `Setting { id, value }`, `SettingsFrame { ack, settings }`, `encodeSettings`, `decodeSettings` | SETTINGS |
| `PushPromiseFrame { streamId, promisedStreamId, blockFragment, endHeaders, padLength }`, `encodePushPromise`, `decodePushPromise` | PUSH_PROMISE |
| `PingFrame { ack, data }`, `encodePing`, `decodePing` | PING |
| `GoawayFrame { lastStreamId, errorCode, debugData }`, `encodeGoaway`, `decodeGoaway` | GOAWAY |
| `WindowUpdateFrame { streamId, increment }`, `encodeWindowUpdate`, `decodeWindowUpdate` | WINDOW_UPDATE |
| `ContinuationFrame { streamId, blockFragment, endHeaders }`, `encodeContinuation`, `decodeContinuation` | CONTINUATION |

### Connection engine

| | |
|---|---|
| `Transport { read, write, shutdown }`, `newTransport(read, write, shutdown): Transport` | wrap your own byte stream |
| `Config { initialWindowSize, maxFrameSize, headerTableSize, maxHeaderListBytes, maxConcurrentStreams, maxBodyBytes, streamBodies }`, `defaultConfig(): Config` | connection limits |
| `Request { method, scheme, authority, path, headers, body }`, `newRequest(method, authority, path): Request` | a request |
| `Response { status, headers, body }`, `newResponse(status, body): Response` | a response (`status` 0 from a `serve` handler aborts the stream instead of answering) |
| `getHeader(headers: []HeaderField, name: string): string` | first header value by name, or `""` |
| `connect(t, cfg, deadlineNs): Conn!` | client handshake over `t` |
| `accept(t, cfg, deadlineNs): Conn!` | server handshake over `t` |
| `Conn.roundTrip(req: Request): Response!` | send one request, wait for the full response |
| `Conn.roundTripStream(req: Request): (Response, Stream)!` | send one request, stream the response body |
| `Conn.serve(handler: (Request, Stream) => Response): ()!` | dispatch inbound requests to `handler`, one green thread each |
| `Conn.close()` | graceful shutdown: send GOAWAY, let in-flight streams finish |
| `Conn.resetStream(streamId: int, errorCode: int)` | abort a stream you started, by id (see Sharp edges) |
| `Conn.waitReaderDone()`, `Conn.waitWriterDone()` | block for the reader/writer thread to stop, before closing the transport (see Sharp edges) |
| `Stream.reset(errorCode: int)` | abort the stream a `serve` handler is answering |
| `Stream.read(): BodyChunk!` | take the next chunk of a streamed body (request or response) |
| `BodyChunk { data, eof }` | one body take |

Specification: RFC 7540/9113 (HTTP/2), RFC 7541 (HPACK).
