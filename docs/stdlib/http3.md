# std/http3

Most programs never import `std/http3` directly. [`pkg/web`](/packages/web) and
[`std/http`](http.md) negotiate HTTP/3 automatically and speak it for you - this
module is the wire layer underneath: QPACK header compression (RFC 9204, HPACK's
role redesigned for QUIC's out-of-order delivery) and the request/response layer
(RFC 9114) running over [`std/quic`](quic.md).

Reach for `std/http3` yourself when you are embedding an HTTP/3 client or server
over a transport `std/http` does not manage for you.

<!-- doctest: per-block -->

## Dialing and serving

`h3Dial` completes the QUIC handshake and opens the control and QPACK streams;
`H3Conn.request` sends one request and reads the response back on the same
stream:

```bit
import { h3Dial, H3Request, H3Response, HeaderField } from "std/http3"

// Dial an HTTP/3 server and GET "/".
fn getIndex(): H3Response! {
  let conn = h3Dial("127.0.0.1", 443, "example.com")?
  let req = H3Request{
    method = "GET",
    scheme = "https",
    authority = "example.com",
    path = "/",
    headers = []HeaderField(0),
    body = []byte(0),
  }
  return conn.request(req)?
}
```

`h3Dial` verifies the server's certificate against the system trust roots -
secure by default, like [`std/quic`](quic.md)'s own `dialQuic`. For a pinned
CA or another custom TLS config, use `h3DialTls`:

```bit
import { h3DialTls, H3Request, H3Response, HeaderField } from "std/http3"
import { TlsConfig } from "std/tls"
import { TrustStore } from "std/crypto"

// Dial an HTTP/3 server, pinning a specific CA instead of the system roots -
// the shape std/http's `getTls`/`requestTls` use for the same reason.
fn getIndexPinned(trust: TrustStore): H3Response! {
  let conn = h3DialTls("127.0.0.1", 443, "example.com", TlsConfig(trust))?
  let req = H3Request{
    method = "GET",
    scheme = "https",
    authority = "example.com",
    path = "/",
    headers = []HeaderField(0),
    body = []byte(0),
  }
  return conn.request(req)?
}
```

Cancel one request without touching the others. `H3Conn.request` takes an
optional channel; a value on it resets and stops just that request's QUIC stream
with `H3_REQUEST_CANCELLED` (0x010c, RFC 9114 section 4.1.1) and fails the call
with `H3Aborted`. The connection and every other request on it keep running. The
same `H3Bound` that carries a deadline carries a channel that ends the QUIC
handshake early:

```bit
import { h3DialTlsBounded, H3Bound, H3Conn, H3Request, H3Aborted, HeaderField } from "std/http3"
import { TlsConfig } from "std/tls"

fn get(conn: H3Conn, path: string, abort: chan<int>): int! {
  let req = H3Request{
    method = "GET", scheme = "https", authority = "example.com", path = path,
    headers = []HeaderField(0), body = []byte(0),
  }
  let res = conn.request(req, Option.Some(abort))?
  return res.status
}

fn dialAbortable(host: string, port: int, cfg: TlsConfig, wake: chan<int>): H3Conn! {
  return h3DialTlsBounded(host, port, host, cfg, H3Bound{ deadlineNs = 0, wake = wake })?
}

fn isAborted(e: error): bool {
  let (_, aborted) = e.(H3Aborted)
  return aborted
}
```

`h3Accept` is the server side of one connection on a bound UDP socket;
`H3Conn.accept` reads the next request and `H3Conn.respond` answers it:

```bit
import { h3Accept, H3Response, HeaderField } from "std/http3"
import { udpBind } from "std/net"

// Accept one HTTP/3 connection, read a request, and reply 200 with a short body.
fn serve(certChainPem: string, keyPem: string): ()! {
  let sock = udpBind("127.0.0.1", 8443)?
  let conn = h3Accept(sock, certChainPem, keyPem)?
  let sr = conn.accept()?
  if (sr.req.method == "") {
    // End a malformed request without response headers; keep other streams open.
    conn.reject(sr, 0x010e)
    conn.close()
    return
  }
  let resp = H3Response{
    status = 200,
    headers = []HeaderField(0),
    body = []byte("ok"),
  }
  conn.respond(sr, resp)?
  conn.close()
}
```

A server expecting more than one client uses `h3Listen` instead of `h3Accept`: it
demultiplexes many clients on one socket, and each established connection arrives
through `H3Listener.accept()`.

## Extended CONNECT

An Inkwell draft feed can keep one request stream open while ordinary requests
continue on the same connection. Enable extended CONNECT when accepting the
connection, then use `openTunnel` on the client. It waits for the peer's settings
and fails if the peer has not advertised support.

The following helpers establish a draft feed and exchange a bounded chunk of
already encoded WebSocket bytes. Your application supplies WebSocket framing
and checks authentication and browser origins before accepting a request.
`H3Stream` carries DATA bytes; it does not perform those application checks.

```bit
import {
  h3Accept, H3Conn, H3Request, H3Response, H3ServerRequest, H3Stream,
  HeaderField, isExtendedConnect, H3CleanupIncomplete,
} from "std/http3"
import { UdpSocket } from "std/net"

fn acceptDraftPeer(sock: UdpSocket, certPem: string, keyPem: string): H3Conn! {
  return h3Accept(sock, certPem, keyPem, true)?
}

fn openDraftFeed(conn: H3Conn): H3Stream! {
  return conn.openTunnel(
    H3Request{
      method = "CONNECT", protocol = "websocket", scheme = "https",
      authority = "localhost", path = "/drafts",
      headers = []HeaderField{
        HeaderField{ name = "sec-websocket-version", value = "13", sensitive = false },
      },
      body = []byte(0),
    },
  )?
}

fn draftVersion(req: H3Request): bool {
  let versions = 0
  for field of req.headers {
    if (field.name == "sec-websocket-version") {
      if (field.value != "13") {
        return false
      }
      versions = versions + 1
    }
  }
  return versions == 1
}

fn acceptDraftFeed(conn: H3Conn, received: H3ServerRequest): H3Stream! {
  if (!isExtendedConnect(received.req) || received.req.path != "/drafts") {
    conn.respond(received, H3Response{ status = 400 })?
    fail newError("draft feed: invalid request")
  }
  if (received.req.protocol != "websocket") {
    conn.respond(received, H3Response{ status = 501 })?
    fail newError("draft feed: unsupported protocol")
  }
  if (!draftVersion(received.req)) {
    conn.respond(received, H3Response{ status = 400 })?
    fail newError("draft feed: invalid request")
  }
  return received.acceptExtendedConnect()?
}

fn exchangeDraftChunk(stream: H3Stream, encodedFrame: string, wake: chan<int>): string! {
  if (len(encodedFrame) == 0 || len(encodedFrame) > 4096) {
    fail newError("draft feed: chunk must contain 1 to 4096 bytes")
  }
  stream.writeUntil(encodedFrame, wake) catch e {
    let (incomplete, ok) = e.(H3CleanupIncomplete)
    if (ok) {
      fail newError("draft feed cleanup incomplete: ${incomplete.message()}")
    }
    fail e
  }
  let chunk = stream.read(4096) catch e {
    stream.reset()
    fail e
  }
  return chunk
}

// Use this form only when the connection idle bound is the intended limit.
fn sendDraftNotice(stream: H3Stream, encodedFrame: string): ()! {
  stream.write(encodedFrame)?
}

fn finishDraftFeed(stream: H3Stream, abort: bool): ()! {
  if (abort) {
    stream.reset()
    return
  }
  stream.close()?
}
```

Use `conn.accept()` to obtain the server request passed to `acceptDraftFeed`.
Both peers may exchange DATA before either sends FIN. Reads can split an
application frame, so keep feeding chunks to your protocol decoder until it has
a complete frame. For a positive read size, an empty string means peer FIN.
`close()` ends your sending half; you can still read the peer's final bytes.
`reset()` aborts both directions without closing the other request streams.

The byte transport is available here; `std/websocket` and `pkg/web` do not yet
wire it into their WebSocket APIs. DATA writes now wait for QUIC acknowledgments
before retaining another frame. Supply a capacity-one `wake` channel to
`writeUntil` and signal it from your deadline or cancellation path. Cancellation
aborts this tunnel because an interrupted DATA frame cannot be resumed safely.
One reader and one writer may use a tunnel; application framing, message size
limits and WebSocket close handshakes remain the caller's responsibility.

`h3: peer did not enable extended CONNECT` means the server did not opt in;
do not retry the same tunnel on that connection. `h3: tunnel is closed` means
you tried to write after closing or resetting your handle. Establish another
tunnel for a new exchange.

## Sharp edges

**Our encoder never grows the table; the peer's may.** `H3Conn` advertises a
4096-byte dynamic table and no blocked streams. Everything it writes is a literal
or a static-table reference, so the encoder/decoder table-mutation API below
(`Encoder.insertLiteral` and friends) is exercised only if you drive it yourself.
The peer's QPACK encoder and decoder streams are read for the life of the
connection, so their bytes never hold QUIC connection credit: its inserts go into
the connection's `Decoder` and each is answered with an Insert Count Increment
(no blocked streams means the peer references an entry only after that), and its
acknowledgements go into the `Encoder`. The peer ending either stream closes the
connection with `H3_CLOSED_CRITICAL_STREAM`; a malformed instruction closes it with
`QPACK_ENCODER_STREAM_ERROR` or `QPACK_DECODER_STREAM_ERROR`.

**Read `H3Conn.peerIp()` once per connection, not once per request.** HTTP/3
multiplexes many requests over one connection, and the address is a property of
the connection, frozen at the handshake - a later call returns the same value.

## When not to use it directly

If you are building an HTTP service, use [`pkg/web`](/packages/web) or
[`std/http`](http.md): they negotiate HTTP/3 for you and give you the plain
request/handler API over HTTP/1.1, HTTP/2, and HTTP/3 alike.

## QPACK

`Encoder` and `Decoder` each own a dynamic table. Unlike
HPACK, table growth is explicit: the encoder emits instructions on a separate
encoder stream, and the decoder must apply them (`applyEncoderStream`) before it
can decode a section that references the new entries.

### `HeaderField`

One header field: a `name`, its `value`, and a `sensitive` flag. Set `sensitive` to force a never-index literal, so an authorization token or cookie is never copied into the dynamic table, where a compression side channel could recover it. A decoder sets it on any field it received that way.

### `Encoder(capacity: int = 4096, huffman: bool = true)`

A stateful QPACK encoder. It owns its dynamic table and tracks its outstanding field sections. Reuse one encoder per connection so its table tracks the peer decoder.

`Encoder()` starts with a 4096-byte dynamic table and Huffman string literals enabled. `capacity` is the initial table capacity and `huffman` the string-literal choice. Pass `capacity = 0` to start with no dynamic table, then raise it with `setCapacity`:

```bit
import { Encoder, Decoder, HeaderField } from "std/http3"

// An encoder that starts with no dynamic table and plain string literals, and
// the decoder that will accept a table up to 4096 bytes when the encoder
// raises it.
fn startPlain(fields: []HeaderField, streamId: int): []HeaderField! {
  let enc = Encoder(capacity = 0, huffman = false)
  let dec = Decoder(limit = 4096)
  dec.applyEncoderStream(enc.setCapacity(4096))?
  let section = enc.encodeFieldSection(streamId, 0, fields)
  return dec.decodeFieldSection(section)?
}

fn startDefault(fields: []HeaderField, streamId: int): []byte {
  return Encoder().encodeFieldSection(streamId, 0, fields)
}
```

### `Encoder.setCapacity(capacity: int): []byte`

Resizes the dynamic table, evicting entries that no longer fit, and returns the encoder-stream bytes to send the peer.

### `Encoder.insertNameRef(isStatic: bool, index: int, value: string): []byte!`

Inserts a new entry that reuses an existing name: a static table entry when `isStatic`, otherwise a dynamic one. Fails on a bad index or an entry too large for the table.

### `Encoder.insertLiteral(name: string, value: string): []byte!`

Inserts a new entry with both a literal name and a literal value. Fails if the entry is too large for the table.

### `Encoder.duplicate(relIndex: int): []byte!`

Re-inserts an existing entry, keeping a header that is about to be evicted alive. Fails on a bad index.

### `Encoder.encodeFieldSection(streamId: int, base: int, fields: []HeaderField): []byte`

Encodes `fields` into one field section for `streamId`, referencing the static and dynamic tables where possible. It never inserts new dynamic entries itself; pre-populate the table with the encoder-stream methods above first.

### `Encoder.applyDecoderStream(data: []byte): ()!`

Processes the peer's acknowledgments: a section acknowledgment retires it, a stream cancellation retires an outstanding section, and an insert count increment advances how many insertions the peer has acknowledged. Fails on a malformed instruction.

### `Encoder.insertCount(): int`

How many insertions this encoder has made so far.

### `Encoder.tableSize(): int`

The current byte size of the encoder's dynamic table.

### `Encoder.tableCount(): int`

The number of live entries in the encoder's dynamic table.

### `Encoder.capacity(): int`

The current dynamic-table capacity in bytes.

### `Encoder.knownReceivedCount(): int`

How many of this encoder's insertions the peer decoder has acknowledged.

### `Decoder(limit: int = 4096)`

A stateful QPACK decoder. It owns its dynamic table and enforces the capacity limit it advertised. Reuse one decoder per connection so its table tracks the peer encoder.

`Decoder()` has no dynamic table yet and is willing to accept a capacity up to the 4096-byte default. `Decoder(limit = n)` sets that ceiling; a peer that tries to grow the table past it is rejected.

### `Decoder.applyEncoderStream(data: []byte): int!`

Applies the encoder's table-mutation instructions in `data` and returns the resulting insert count. Fails on a malformed instruction or a capacity over the decoder's limit.

### `Decoder.decodeFieldSection(data: []byte): []HeaderField!`

Decodes one encoded field section into its header fields. Fails, as "blocked", if the section needs insertions the decoder has not applied yet, and on any malformed input.

### `Decoder.sectionAck(streamId: int): []byte`

Builds the acknowledgment bytes for a field section decoded on `streamId`, to send back on the decoder stream.

### `Decoder.streamCancel(streamId: int): []byte`

Builds a cancellation for the outstanding field section on `streamId`, to send back on the decoder stream.

### `Decoder.insertCountIncrement(n: int): []byte`

Builds an acknowledgment that advances the encoder's known-received count by `n`, without acknowledging a specific section.

### `Decoder.insertCount(): int`

How many insertions this decoder has processed so far.

### `Decoder.tableSize(): int`

The current byte size of the decoder's dynamic table.

### `Decoder.tableCount(): int`

The number of live entries in the decoder's dynamic table.

### `Decoder.capacity(): int`

The current dynamic-table capacity in bytes.

## HTTP/3 core

The request/response layer, built on the QPACK compressor above and `std/quic`.
Its own field lines are literals or static-table references; the peer's may
use the dynamic table; see [Sharp edges](#sharp-edges).

### `H3Request`

An HTTP/3 request: `method`, `scheme`, `authority`, and `path` become the pseudo-headers; `headers` are the regular header fields; `body` is the request body. Set `protocol` for an extended CONNECT request, as in [Extended CONNECT](#extended-connect); leave it empty for an ordinary request.

### `isExtendedConnect(req: H3Request): bool`

Reports whether the method is `CONNECT` and `protocol` is nonempty. It does not validate the protocol's handshake; the draft feed example performs its own header checks.

### `H3Response`

An HTTP/3 response: `status`, `headers`, and `body`.

### `H3Conn`

An established HTTP/3 connection over one QUIC connection. It owns the per-connection QPACK encoder and decoder. Issue every request and response through the one `H3Conn` so the QPACK tables stay in sync with the peer.

### `H3ServerRequest`

A received request paired with the stream it arrived on. `req` is the decoded `H3Request`; `respond` answers on the stream it carries.

### `H3Stream`

The DATA byte stream returned by `H3Conn.openTunnel` or `H3ServerRequest.acceptExtendedConnect`. Use at most one reader and one writer at a time. [Extended CONNECT](#extended-connect) shows its request and lifecycle.

### `H3Stream.read(n: int): string!`

Reads up to `n` bytes, preserving any remaining DATA for the next call. With positive `n`, an empty string marks peer FIN. A nonpositive `n` returns an empty string without reading. A chunk can contain part of an application frame.

### `H3Stream.write(data: string): ()!`

Writes DATA in payloads of at most 16384 bytes and waits for each frame to be acknowledged before the next frame is retained. It does not send FIN. The application supplies its own protocol framing. A write after local `close` or `reset` fails. `write` has no caller cancellation; the connection idle bound still applies.

### `H3Stream.writeUntil(data: string, wake: chan<int>): ()!`

Like `write`, but a value on the capacity-one `wake` channel interrupts the write with `H3Aborted`. The running example uses this form for a deadline or cancellation. Any write error closes the local writer and tries to abort both tunnel directions without waiting for command admission; queued bytes may already have reached the peer. Retry on a new tunnel, never within the partial DATA frame.

### `H3CleanupIncomplete`

If cleanup cannot be queued immediately, the failure is `H3CleanupIncomplete`. Its `cause` retains `H3Aborted` or the original transport error. Earlier admitted cleanup commands remain queued, and other streams remain open. Do not call the unbounded `reset` from this error path when cancellation must stay bounded; the example reports incomplete cleanup instead of starting another wait.

### `H3CleanupIncomplete.message(): string`

Returns the original cause message followed by `; h3: stream cleanup incomplete`. Use it for diagnostics; inspect `cause` when handling cancellation. The [extended CONNECT example](#extended-connect) shows both the typed error and its message.

### `H3Stream.close(): ()!`

Ends the local sending half with FIN and waits for queued bytes to be acknowledged. Calling it again does nothing. Reads remain available, and other request streams on the connection remain open.

### `H3Stream.reset()`

Aborts both directions of this stream with request cancellation. Use it when a protocol exchange fails or is abandoned; other request streams remain open.

### `h3Dial(host: string, port: int, serverName: string): H3Conn!`

Dials an HTTP/3 server at `host:port`, verifying its certificate against `serverName` and the system trust roots (secure by default, like `std/quic`'s `dialQuic`), completes the QUIC handshake, and sets up the control and QPACK streams. Fails if the connection, verification, or handshake fails.

### `h3DialTls(host: string, port: int, serverName: string, config: TlsConfig): H3Conn!`

Like `h3Dial`, with an explicit `std/tls` `TlsConfig` - a pinned CA, `insecureSkipVerify` for tests, or another custom config, the same shape `std/http`'s `getTls`/`requestTls` use.

### `h3DialDeadline(host: string, port: int, serverName: string, deadlineNs: int): H3Conn!`

Like `h3Dial`, bounded by an absolute deadline in nanoseconds. Once the handshake succeeds, the connection's idle timeout is lowered to whatever budget remains, so a peer that never answers is torn down within the deadline instead of the default.

### `h3DialTlsDeadline(host: string, port: int, serverName: string, config: TlsConfig, deadlineNs: int): H3Conn!`

`h3DialTls` bounded by an absolute deadline, exactly as `h3DialDeadline` bounds `h3Dial`.

### `h3DialTlsBounded(host: string, port: int, serverName: string, config: TlsConfig, bound: H3Bound): H3Conn!`

`h3DialTls` bounded by `bound`: a nonzero `deadlineNs` lowers the idle timeout as `h3DialDeadline` does, and a value on `wake` ends the wait for the QUIC handshake with `H3Aborted`, closing the connection being set up.

### `H3Bound`

`deadlineNs` (absolute, 0 for none) and `wake` (a `chan<int>` of capacity 1, so the sender never blocks).

### `H3Aborted`

What `H3Conn.request` and `h3DialTlsBounded` fail with when their channel received a value. A request that was aborted had only its own stream reset and stopped.

### `H3Aborted.message`

The fixed text `http3: request aborted`. It names no stream and no cause, so branch on `e.(H3Aborted)` to tell an abort from a connection failure and use the text only for a log line.

### `H3Unsent`

What `H3Conn.request` fails with when it could not open a request stream: the QUIC connection had closed, or the peer's limit on open streams was reached. Nothing was written, so the request may be repeated on another connection whatever its method. `cause` is the error underneath.

### `H3Unsent.message`

The text of `cause`, unchanged, so a log line for an unsent request reads as the QUIC failure that stopped it. Reach `cause` itself, to decide whether the connection is worth keeping, with `e.(H3Unsent)`.

### `H3Conn.watchPeer()`

Starts reading the peer's own streams so that `reusable` learns of a `GOAWAY` or an ended connection. Call it once on a client connection shared between requests; the watcher takes every peer-initiated stream, so do not also call `rawConn().acceptStream()` on that connection.

### `H3Conn.reusable(): bool`

Whether a new request may be started on this connection: false once either side sent `GOAWAY` or the connection ended. It sees the peer's side only after `watchPeer`.

### `h3Accept(sock: UdpSocket, certChainPem: string, keyPem: string, enableConnectProtocol: bool = false): H3Conn!`

Accepts one HTTP/3 connection on the bound UDP socket `sock`, using the certificate chain and private key for the handshake. Serves a single connection; use `h3Listen` for many.

Extended CONNECT is disabled by default. Pass `true` only when your application accepts and validates those requests.

### `h3Listen(sock: UdpSocket, certChainPem: string, keyPem: string, enableConnectProtocol: bool = false): H3Listener!`

Starts an HTTP/3 listener on the bound UDP socket `sock`. The underlying QUIC listener demultiplexes many client connections on the one socket. Returns immediately; each established connection is handed back by `accept`.

Pass `enableConnectProtocol = true` to advertise extended CONNECT on each accepted connection. The default preserves ordinary request/response behavior.

### `H3Listener`

An HTTP/3 server listener: many client connections on one bound UDP socket. Obtain one from `h3Listen`.

### `H3Listener.accept(): H3Conn!`

Accepts the next HTTP/3 connection, blocking until a client completes its handshake. Run each returned `H3Conn` on its own green thread.

### `H3Listener.stopAccepting()`

Stops admitting new connections on the underlying socket; connections already accepted keep being served.

### `H3Conn.request(req: H3Request): H3Response!`

Sends `req` and reads the response back on the same stream. Fails on a transport or decode error.

### `H3Conn.openTunnel(req: H3Request): H3Stream!`

Opens an extended CONNECT request. The peer must advertise support, the request must include its method, protocol, scheme, authority and path, and the response must be successful. The returned stream carries DATA without waiting for FIN. See [Extended CONNECT](#extended-connect).

### `H3Conn.accept(): H3ServerRequest!`

Accepts the next request, blocking until one opens. Fails on a transport or decode error.

### `H3ServerRequest.acceptExtendedConnect(): H3Stream!`

Accepts this request with status 200 after your application validates the protocol handshake. The connection must have advertised support. Rejects a malformed, ordinary or already accepted request; use the handle from the same connection that received it.

### `H3Conn.respond(sr: H3ServerRequest, resp: H3Response): ()!`

Answers the request in `sr` with `resp` on its stream. Fails on a transport error.

### `H3Conn.reject(sr: H3ServerRequest, code: int)`

Ends both directions of the accepted request stream with `code`, without response
headers. Other streams on the connection remain usable. For a malformed request,
use `0x010e` (`H3_MESSAGE_ERROR`), as the server example above shows. Like
`respond`, pass a request accepted by this connection. The reset is best effort
if the stream has already ended.

### `H3Conn.peerIp(): string`

The peer's IPv4 address, or `""` when it is not known. Read it once per connection, not once per request: see [Sharp edges](#sharp-edges).

### `H3Conn.goAway()`

Begins a graceful shutdown of this connection. Every request already accepted is left alone; a request opened after this point is refused instead of being read.

### `H3Conn.draining(): bool`

Whether `goAway` has already run on this connection.

### `H3Conn.rawConn(): Conn`

The underlying QUIC connection this one runs over, for a caller that needs to drive a raw stream directly instead of through `request`/`accept`/`respond`.

### `H3Conn.close()`

Closes the connection: sends this connection's GOAWAY if one was not already sent, then closes the underlying QUIC connection.

Specification: RFC 9114 (HTTP/3), RFC 9204 (QPACK).
