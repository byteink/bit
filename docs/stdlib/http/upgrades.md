# Take over an HTTP connection

When a handler switches protocols, take ownership of the connection before
reading or writing the new protocol. These calls transfer that ownership and
let you use the same stream interface across plain, TLS and HTTP/2 connections.

See the [HTTP overview and server reference](../http.md),
[request guide](requests.md), and [client reference](clients.md).

<!-- doctest: per-block -->

## Hijacking a connection (protocol upgrades)

For a handler that must take over the raw connection - a WebSocket upgrade,
for instance ([`std/websocket`](../websocket.md) is built on this).

### `HijackOutcome`

What a hijackable handler decided: `Answer(res)` to answer the request
normally, or `Hijacked` after it has already called `hijack()` and taken
the connection over.

### `serveHijackableOn(s: Server, handler: (Request, Exchange) => HijackOutcome): ()!`

The hijack-capable sibling of `listenAndServeOn`: `handler` answers most
requests normally and keeps the connection open, or takes it over by
returning `Hijacked`.

### `serveHijackableBackground(s: Server, handler: (Request, Exchange) => HijackOutcome): ()`

As `serveHijackableOn`, run in the background: its return is not reported
anywhere, since a server stopping is the expected outcome, not a failure.

### `Exchange.hijack(): Conn`

Takes ownership of the raw connection this exchange is serving. Nothing else
reads from or writes to it afterward except the caller.

### `Exchange.hijackStream(): byteStream`

As `Exchange.hijack`, returning a transport-agnostic `byteStream` instead of
the raw connection type.

### `Exchange.respondKeepAlive(req: Request, res: Response, mustCloseNow: bool): bool!`

Answers `req` with `res` while driving your own multi-request loop over one
connection, returning whether the connection stays open for another
request.

### `TlsExchange`

The TLS mirror of `Exchange`: one accepted TLS connection, before its
request is read.

### `TlsExchange.read(): Request!`

As `Exchange.read`, for a TLS connection.

### `TlsExchange.respond(res: Response): ()!`

As `Exchange.respond`, for a TLS connection.

### `TlsExchange.hijack(): TlsConn`

As `Exchange.hijack`, for a TLS connection.

### `TlsExchange.hijackStream(): byteStream`

As `Exchange.hijackStream`, for a TLS connection.

### `TlsExchange.respondKeepAlive(req: Request, res: Response, mustCloseNow: bool): bool!`

As `Exchange.respondKeepAlive`, for a TLS connection.

### `TlsServer.accept(): TlsExchange!`

Blocks until the next TLS connection arrives and returns it, without
reading anything off it yet.

### `serveHijackableTlsOn(ts: TlsServer, hijackHandler: (Request, TlsExchange) => HijackOutcome, plainHandler: (Request) => Response, tunnel: Option<(Request, Stream) => Response> = Option.None): ()!`

The hijack-capable sibling of `serveTlsServerOn`. `hijackHandler` serves
HTTP/1.1 connections and may take one over; `plainHandler` serves the ordinary
requests of every HTTP/2 connection, which cannot be hijacked.

`tunnel` takes the HTTP/2 streams that arrive as RFC 8441 extended CONNECT. Give it
and the server advertises `SETTINGS_ENABLE_CONNECT_PROTOCOL`; leave it out and no
client can open one. A WebSocket request (`:protocol websocket`) reaches `tunnel` as
the GET its HTTP/1.1 Upgrade replaces, with the `std/http2` `Stream` it may accept
(`Stream.acceptExtendedConnect`) or leave unanswered by returning an ordinary
`Response`. `std/websocket`'s `upgradeH2` does both checks and the accept.

### `serveHijackableTlsBackground(ts: TlsServer, hijackHandler: (Request, TlsExchange) => HijackOutcome, plainHandler: (Request) => Response, tunnel: Option<(Request, Stream) => Response> = Option.None): ()`

As `serveHijackableTlsOn`, run in the background.

### `byteStream`

The transport-agnostic read/write interface a hijacked connection speaks,
whether it came from a plain or a TLS connection.

### `ByteStream(conn: Option<Conn> = None, tls: Option<TlsConn> = None, h2: Option<H2Stream> = None): ByteStream!`

Wraps a connection you already hold as a `byteStream`, for code that has no
`Exchange` to ask for one. `ByteStream(conn = Option.Some(c))?` takes a plain
[`std/net`](../net.md) connection, `ByteStream(tls = Option.Some(t))?` a
`std/tls` one, and `ByteStream(h2 = Option.Some(t))?` an accepted
[`std/http2`](../http2.md) extended CONNECT tunnel (RFC 8441). Give exactly one:
passing more than one, or none, fails with an error instead of picking one for you.

```bit
import { ByteStream, byteStream } from "std/http"
import { dial } from "std/net"
import { TlsConn } from "std/tls"

fn ping(s: byteStream): string! {
  s.writeStr("PING\r\n")?
  return s.readUp(64)?
}

fn pingPlain(host: string, port: int): string! {
  let s = ByteStream(conn = Option.Some(dial(host, port)?))?
  defer s.shut()
  return ping(s)?
}

fn pingTls(c: TlsConn): string! {
  let s = ByteStream(tls = Option.Some(c))?
  defer s.shut()
  return ping(s)?
}
```

### `ByteStream.readUp(n: int): string!`

Reads up to `n` bytes, or returns `""` at end of stream. Bytes given back with
`unread` come out first.

### `ByteStream.writeStr(s: string): ()!`

Writes all of `s` to the connection.

### `ByteStream.writeBytes(b: []byte): ()!`

As `writeStr`, for bytes you already hold, with no conversion to a string.

### `ByteStream.shut()`

Closes the connection.

### `ByteStream.forceClose()`

Interrupts a read parked on another green thread, which sees an orderly end of
stream. Never blocks.

### `ByteStream.peer(): string`

The peer's address as `Conn.peerIp` renders it (a dotted quad for IPv4, RFC 5952
for IPv6, an IPv4-mapped peer as its IPv4 address), or `""` when the connection
cannot name one.

### `ByteStream.unread(extra: string)`

Puts `extra` back in front of whatever the stream returns next, for a reader
that took more bytes than the message it was parsing.

### `ByteStream.setIdleDeadline(deadlineNs: int)`

Bounds the next read, and everything read to complete the message it starts, by
an absolute monotonic deadline in nanoseconds. `0` clears it.

```bit
import { Server, Exchange, Request, HijackOutcome, ok, serve, serveHijackableOn } from "std/http"

fn dispatch(req: Request, ex: Exchange): HijackOutcome {
  if (req.path == "/upgrade") {
    let conn = ex.hijack()
    conn.write("HTTP/1.1 101 Switching Protocols\r\n\r\n") catch _ {}
    return HijackOutcome.Hijacked
  }
  return HijackOutcome.Answer(ok("hi"))
}

fn runHijackable(): ()! {
  let s = serve("127.0.0.1", 8080)?
  serveHijackableOn(s, dispatch)?
}
```
