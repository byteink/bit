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

## Sharp edges

**This connection's dynamic table has zero capacity.** Every field line is a
literal or a static-table reference, so no request ever blocks waiting on the
QPACK encoder stream - but it also means the encoder/decoder table-mutation API
below (`Encoder.insertLiteral` and friends) is exercised only if you drive it
yourself; `H3Conn` never grows the table on its own.

**Read `H3Conn.peerIp()` once per connection, not once per request.** HTTP/3
multiplexes many requests over one connection, and the address is a property of
the connection, frozen at the handshake - a later call returns the same value.

## When not to use it directly

If you are building an HTTP service, use [`pkg/web`](/packages/web) or
[`std/http`](http.md): they negotiate HTTP/3 for you and give you the plain
request/handler API over HTTP/1.1, HTTP/2, and HTTP/3 alike.

## Reference

### QPACK

`newEncoder`/`Encoder` and `newDecoder`/`Decoder` each own a dynamic table. Unlike
HPACK, table growth is explicit: the encoder emits instructions on a separate
encoder stream, and the decoder must apply them (`applyEncoderStream`) before it
can decode a section that references the new entries.

| | |
|---|---|
| `HeaderField { name, value, sensitive }` | one header field (`sensitive` forces a never-index literal) |
| `newEncoder(): Encoder` | encoder with the 4096-byte default table, Huffman on |
| `newEncoderConfig(capacity: int, huffman: bool): Encoder` | encoder with an explicit initial capacity and Huffman choice |
| `Encoder.setCapacity(capacity: int): []byte` | resize the dynamic table |
| `Encoder.insertNameRef(isStatic, index, value): []byte!` | insert an entry by name reference |
| `Encoder.insertLiteral(name, value): []byte!` | insert an entry with a literal name |
| `Encoder.duplicate(relIndex): []byte!` | re-insert an existing entry to keep it alive |
| `Encoder.encodeFieldSection(streamId, base, fields): []byte` | encode one field section for a stream |
| `Encoder.applyDecoderStream(data): ()!` | process the peer's acknowledgments |
| `Encoder.insertCount(): int`, `.knownReceivedCount(): int` | insertions made / acknowledged so far |
| `Encoder.tableSize(): int`, `.tableCount(): int`, `.capacity(): int` | inspect the dynamic table |
| `newDecoder(): Decoder` | decoder willing to accept up to the 4096-byte default capacity |
| `newDecoderConfig(limit: int): Decoder` | decoder with an explicit capacity limit |
| `Decoder.applyEncoderStream(data): int!` | apply the encoder's table mutations, return the new insert count |
| `Decoder.decodeFieldSection(data): []HeaderField!` | decode one field section |
| `Decoder.sectionAck(streamId): []byte` | acknowledge a decoded section |
| `Decoder.streamCancel(streamId): []byte` | cancel an outstanding section |
| `Decoder.insertCountIncrement(n): []byte` | advance the encoder's Known Received Count without a section ack |
| `Decoder.insertCount(): int` | insertions processed so far |
| `Decoder.tableSize(): int`, `.tableCount(): int`, `.capacity(): int` | inspect the dynamic table |

### HTTP/3 core

| | |
|---|---|
| `H3Request { method, scheme, authority, path, headers, body }` | a request |
| `H3Response { status, headers, body }` | a response |
| `H3Conn` | one HTTP/3 connection; owns the connection's QPACK state |
| `H3ServerRequest { req, ... }` | a received request paired with the stream it arrived on |
| `h3Dial(host, port, serverName): H3Conn!` | dial and complete the handshake |
| `h3DialDeadline(host, port, serverName, deadlineNs): H3Conn!` | as `h3Dial`, bounded by a deadline |
| `h3Accept(sock, certChainPem, keyPem): H3Conn!` | accept one connection on a bound socket |
| `h3Listen(sock, certChainPem, keyPem): H3Listener!` | bind a listener for many concurrent connections |
| `H3Listener.accept(): H3Conn!` | accept the next connection |
| `H3Listener.stopAccepting()` | stop admitting new connections; existing ones are unaffected |
| `H3Conn.request(req): H3Response!` | send a request, read the response |
| `H3Conn.accept(): H3ServerRequest!` | accept the next request |
| `H3Conn.respond(sr, resp): ()!` | answer a received request |
| `H3Conn.peerIp(): string` | the peer address the handshake established (see Sharp edges) |
| `H3Conn.goAway()` | begin a graceful shutdown of this connection |
| `H3Conn.draining(): bool` | whether `goAway` has already run |
| `H3Conn.rawConn(): Conn` | the underlying `quic.Conn`, for driving a raw stream directly |
| `H3Conn.close()` | send GOAWAY (if not already sent), then close the QUIC connection |

Specification: RFC 9114 (HTTP/3), RFC 9204 (QPACK).
