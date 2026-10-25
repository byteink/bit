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

## Streaming a response

When a handler produces a response in pieces, open a body writer on its request
`Stream`. The engine sends response headers immediately, writes each piece as
flow-controlled DATA, and sends END_STREAM on `close()`. It does not use HTTP/1.1
chunk framing or require a final body length.

```bit
import { Request, Response, Stream, H2BodyStream, HeaderField } from "std/http2"

fn event(body: H2BodyStream, text: string): ()! {
  body.write([]byte("data: " + text + "\n\n"))?
}

fn feed(_req: Request, s: Stream): Response {
  let headers = [HeaderField{ name = "content-type", value = "text/event-stream", sensitive = false }]
  let body = s.openBodyStream(200, headers) catch _ {
    return Response(500, []byte(0))
  }
  event(body, "ready") catch _ {
    return Response(0, []byte(0))
  }
  body.close() catch _ {
    return Response(0, []byte(0))
  }
  return Response(0, []byte(0))
}
```

One handler thread owns the writer. A write waits for peer flow-control credit
and fails on reset or connection failure. Closing twice is safe; writing after
close fails. Returning from the handler also ends the body, and its returned
`Response` is discarded. Do not use the writer after the handler returns.

Opening twice fails. Bodyless statuses, HEAD requests, `content-length`, and
`transfer-encoding` are refused. Incoming request body limits remain in force.

## Tunnels: WebSocket over one HTTP/2 stream

A WebSocket over HTTP/1.1 takes the whole connection. HTTP/2 multiplexes many
requests on one, so it cannot hand a connection over; RFC 8441 instead turns one
stream into the tunnel. The client sends a `CONNECT` request carrying a
`:protocol` pseudo-header (`websocket`), the server answers 200, and from then on
the stream's DATA frames are the byte stream - RFC 6455 framing, with no Upgrade
handshake. The other streams keep serving requests.

A server opts in with `Config.enableConnectProtocol`, which advertises
`SETTINGS_ENABLE_CONNECT_PROTOCOL`. Without it a request bearing `:protocol` is a
malformed request and the engine resets that stream with `PROTOCOL_ERROR`; a
client's `openTunnel` refuses to send one to a peer that did not advertise it.
Ask `isExtendedConnect(req)` inside the handler, then accept the stream:

```bit
import {
  accept, Config, defaultConfig, isExtendedConnect, Request, Response, Stream, Transport,
} from "std/http2"

// Echo every byte of the tunnel back until the peer ends its half. A handler that
// does not accept returns an ordinary `Response`, which refuses the tunnel.
fn echo(req: Request, s: Stream): Response {
  if (!isExtendedConnect(req)) {
    return Response(400, []byte("tunnels only"))
  }
  let t = s.acceptExtendedConnect() catch e {
    return Response(500, []byte(e.message()))
  }
  while (true) {
    let chunk = t.read(4096) catch e {
      break
    }
    if (len(chunk) == 0) {
      break
    }
    t.write(chunk) catch e {
      break
    }
  }
  return Response(0, []byte(0))
}

fn serveTunnels(t: Transport) {
  let cfg = defaultConfig()
  cfg.enableConnectProtocol = true
  let conn = accept(t, cfg, 0) catch e {
    return
  }
  conn.serve(echo) catch e2 {
    return
  }
}
```

Returning from the handler ends the tunnel: the engine sends END_STREAM and, if the
peer has not ended its own half, `RST_STREAM(NO_ERROR)` (RFC 9113 section 8.1). The
`Response` an accepting handler returns is discarded.

A tunnel is not a message body, so `Config.maxBodyBytes` does not apply to it: a
WebSocket lives for as long as it likes. Flow control still does. `H2Stream.read`
renews the receive window by exactly the bytes it takes, and `H2Stream.write`
returns only once its bytes have left under the peer's window, so a slow peer
blocks the writer instead of growing a buffer.

The client side is `Conn.openTunnel`. In practice you reach for `std/websocket`
(`dialH2`, `upgradeH2`) or [`pkg/web`](/packages/web)'s `wsUpgrade`, which run the
WebSocket protocol over this and need no code change from a route written for
HTTP/1.1.

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

See the [frame codec reference](http2-frames.md#the-frame-header).

## Frame types

See the [frame codec reference](http2-frames.md#frame-types).

## Frame flags

See the [frame codec reference](http2-frames.md#frame-flags).

## Settings parameter ids

See the [frame codec reference](http2-frames.md#settings-parameter-ids).

## Frame-size bounds

See the [frame codec reference](http2-frames.md#frame-size-bounds).

## Error codes

See the [frame codec reference](http2-frames.md#error-codes).

## DATA frames

See the [frame codec reference](http2-frames.md#data-frames).

## HEADERS frames

See the [frame codec reference](http2-frames.md#headers-frames).

## PRIORITY frames

See the [frame codec reference](http2-frames.md#priority-frames).

## RST_STREAM frames

See the [frame codec reference](http2-frames.md#rst_stream-frames).

## SETTINGS frames

See the [frame codec reference](http2-frames.md#settings-frames).

## PUSH_PROMISE frames

See the [frame codec reference](http2-frames.md#push_promise-frames).

## PING frames

See the [frame codec reference](http2-frames.md#ping-frames).

## GOAWAY frames

See the [frame codec reference](http2-frames.md#goaway-frames).

## WINDOW_UPDATE frames

See the [frame codec reference](http2-frames.md#window_update-frames).

## CONTINUATION frames

See the [frame codec reference](http2-frames.md#continuation-frames).

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
`maxConcurrentStreams`, `maxBodyBytes`, and `streamBodies`, plus
`enableConnectProtocol`, which advertises extended CONNECT (RFC 8441) and is off
by default. See "Tuning limits" and "Tunnels" above.

### `defaultConfig(): Config`

A `Config` with the RFC default limits: see "Tuning limits" above for the
exact numbers.

### `Request(method: string, authority: string, path: string)`

An HTTP/2 request: `method`, `scheme`, `authority`, `path`, `protocol`,
`headers`, and `body`. `protocol` is the `:protocol` pseudo-header of an extended
CONNECT, `""` on every other request. The constructor makes one with the `https` scheme, no extra headers,
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

### `Aborted.message`

The fixed text `http2: request aborted`. To tell an abort from a connection failure, test the error with `e.(Aborted)`, because the text carries no stream id or cause to tell two aborts apart.

### `Conn.roundTripStream(req: Request, deadlineNs: int = 0): (Response, Stream)!`

Sends `req` and returns as soon as the response headers arrive, with the body
still to come on the returned `Stream`. Use this for a large response you
want to read a chunk at a time instead of holding whole. `deadlineNs` bounds the
wait exactly as it does for `roundTrip`.

### `Conn.openTunnel(req: Request, deadlineNs: int = 0): (Response, H2Stream)!`

Opens an extended CONNECT tunnel (RFC 8441): `req` must be a `CONNECT` with
`protocol`, `scheme`, `authority` and `path` set. Returns the server's answer and
the tunnel once the status is 2xx. Fails without sending anything when the peer did
not advertise `SETTINGS_ENABLE_CONNECT_PROTOCOL`; on any other status the stream is
reset and the error names it. Close the `H2Stream` when you are done.

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

### `Stream.acceptExtendedConnect(headers: []HeaderField = []HeaderField(0)): H2Stream!`

Accepts this stream as an extended CONNECT: answers 200 with `headers` and no
END_STREAM, and returns the tunnel. Fails unless the engine admitted the stream as
one (`Config.enableConnectProtocol` is set and the request was well formed), or when
the stream was already answered or is closed. To refuse, return an ordinary
`Response` instead.

### `isExtendedConnect(req: Request): bool`

Whether `req` is an extended CONNECT: method `CONNECT` with a `:protocol`. Any
protocol counts; the caller decides which it serves (`std/websocket` serves
`websocket`).

### `H2Stream`

The handle on an accepted tunnel: raw bidirectional bytes over the stream's DATA
frames, under flow control. One green thread reads and one writes.

### `H2Stream.read(n: int): string!`

Up to `n` bytes of the tunnel, blocking until at least one has arrived. `""` means
the peer ended its half. Fails when the stream is reset, the connection dies, or the
deadline from `setDeadline` passes.

### `H2Stream.write(data: string): ()!`

Sends `data` as DATA frames and returns once every byte has left under flow control.
Fails when the stream is closed or reset or the connection is gone.

### `H2Stream.setDeadline(deadlineNs: int)`

Bounds `read` by an absolute `monotonic` deadline in nanoseconds; `0` clears it.

### `H2Stream.close()`

Ends this side of the tunnel with END_STREAM, the orderly close (RFC 8441 section 5),
and releases the connection's hold on it. Call it when done; a server handler need
not, since returning ends the tunnel.

### `H2Stream.reset(errorCode: int)`

The abnormal close: RST_STREAM carrying `errorCode` (RFC 8441 uses `errorCancel`).

### `Stream.read(): BodyChunk!`

Takes the next chunk of this stream's body as it arrives, without waiting for
the whole body. Blocks until at least one byte has arrived or the body has
ended.

### `BodyChunk`

One take from a stream's body: `data` is the bytes taken, `eof` says the peer
has ended the stream.
