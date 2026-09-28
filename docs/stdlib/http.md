# std/http

An HTTP/1.1, HTTP/2 and HTTP/3 client and server, built in Bit over `std/net`
(cleartext), `std/tls` (TLS 1.3) and `std/quic`. Use it to call another
service, or to answer requests without pulling in a framework. Building a
web app with routes, middleware and JSON bodies? Skip ahead to [Building a
web app](#building-a-web-app).

<!-- doctest: per-block -->

## Quick start

```bit
import { get, post, Response } from "std/http"

fn fetchStatus(url: string): int! {
  let res = get(url)?
  return res.status
}

fn submit(url: string, payload: string): string! {
  let res = post(url, payload)?
  return res.body
}
```

`get`/`post`/`request` return a `Response!` - propagate the failure with `?`
or handle it with `catch`. An `https://` URL runs over TLS 1.3 automatically,
verifying the server's certificate against the system trust store; nothing
about the call changes between `http://` and `https://`.

## Making requests

```bit
import { requestWith, requestTimeout, Header, Response } from "std/http"

fn createUser(apiBase: string, token: string, body: string): Response! {
  let headers = [
    Header{ name = "Authorization", value = "Bearer ${token}" },
    Header{ name = "Content-Type", value = "application/json" },
  ]
  return requestWith("POST", "${apiBase}/users", headers, body)?
}

fn withDeadline(url: string): Response! {
  // Connect, send and read all share this one 3-second budget.
  return requestTimeout("GET", url, "", 3000)?
}
```

| Function | Use |
|---|---|
| `get(url)` / `post(url, body)` / `request(method, url, body)` | the common case, no extra headers |
| `requestWith(method, url, headers, body)` | attach headers: auth, content type, anything custom |
| `getTimeout` / `postTimeout` / `requestTimeout(..., timeoutMs)` | bound the whole call - connect, send and read share one deadline |
| `getTls` / `postTls` / `requestTls(..., config: TlsConfig)` | pin a CA, a `serverName`, or skip verification in a test - see [`std/tls`](tls.md) |

There is no default timeout on `get`/`post`/`request`: a server that accepts
a connection and never answers parks the caller forever. Use the `*Timeout`
functions for anything talking to a service outside your own control.

A reserved set of headers (`Host`, `Content-Length`, `Accept-Encoding`, and a
few more the transport manages itself) cannot be set through `requestWith` -
this stdlib ships no response decompression, so a hand-set
`Accept-Encoding: gzip` would make a conforming server compress a body
nothing here can inflate. `requestWith` fails, before sending anything, on
that or on a malformed header name or value.

A response body over 32 MiB fails the call rather than being read into
memory; raise or lower that with a `Client` (below), or use the streaming
functions for a multi-gigabyte upload or download:

```bit
import { BodySource, BodySink, Header, getStreaming, requestWithStreamingBody } from "std/http"
import { repeat } from "std/strings"

// A body of `left` zero bytes, handed out one chunk at a time.
class Zeros {
  left: int

  next(n: int): string! {
    let k = n
    if (this.left < k) {
      k = this.left
    }
    this.left = this.left - k
    return repeat("0", k)
  }
}

// Counts the bytes it is handed and keeps none of them.
class Counter {
  total: int

  take(chunk: string): ()! {
    this.total = this.total + len(chunk)
  }
}

fn roundTrip(url: string, size: int): int! {
  let zeros = Zeros{ left = size }
  let source: BodySource = zeros.next
  requestWithStreamingBody("PUT", url, []Header(0), size, source)?
  let counter = Counter{ total = 0 }
  let sink: BodySink = counter.take
  getStreaming(url, []Header(0), sink, size)?
  return counter.total
}
```

`requestWithStreamingBody` sends a request body of exactly `contentLength`
bytes pulled from a `BodySource` (`(int) => string!`, `""` at the end).
`getStreaming` hands a response body to a `BodySink` (`(string) => ()!`) one
chunk at a time and always returns `Response.body == ""`; its `maxBodyBytes`
bounds the memory the *server's* declared length can force, not what this
call buffers. Both cover `http://` and `https://` only; `https+h3://` is
refused.

### A client that reuses connections

The package-level functions above dial a fresh connection every call. A
`Client` reuses configuration - a pinned CA, a bearer token, a body-size
limit - and remembers which servers have advertised HTTP/3, so a second
request to the same host can upgrade automatically.

```bit
import { newClient, Client, Response } from "std/http"

fn authedClient(token: string): Client! {
  let c = newClient()
  c.setHeader("Authorization", "Bearer ${token}")?
  return c
}

fn fetchWith(c: Client, url: string): Response! {
  return c.get(url)?
}
```

`newClient()` is secure by default (verification on, system roots, HTTP/2
offered). `newClientTls(config: TlsConfig)` takes an explicit `std/tls`
config for the same reasons `getTls` does. `Client.request` /
`requestWith` / `get` / `post` / `*Timeout` mirror the package-level
functions; `Client.setHeader` sets a default sent with every call from this
client, and `Client.setMaxBodyBytes(n)` raises or lowers the 32 MiB response
cap - there is no value meaning unlimited, so `0` refuses every body, the
same rule `Server.setMaxBodyBytes` uses below.

## Serving requests: the basics

```bit
import { serve, listenAndServe, listenAndServeOn, ok, respond, Server, Request, Response } from "std/http"

// A request handler is an ordinary function value.
fn route(req: Request): Response {
  if (req.path == "/health") {
    return ok("ok")
  }
  return respond(404, "not found")
}

fn main() {
  listenAndServe("127.0.0.1", 8080, route) catch e {
    print("server failed: ${e.message()}\n")
  }
}

// A kernel-chosen port, learned before the accept loop starts - the shape a
// test uses to start a server and then connect to it, race-free.
fn runOnEphemeralPort(): int! {
  let s = serve("127.0.0.1", 0)?
  let port = s.port()?
  spawn serveForever(s)
  return port
}

fn serveForever(s: Server) {
  listenAndServeOn(s, route) catch e {
    print("server failed: ${e.message()}\n")
  }
}
```

A `Request` carries `method`, `path` (still percent-encoded - see [Query
strings](#query-strings) below), `headers` as a raw block read with
`header(req.headers, name)`, `body`, and `peer` (the client's address, `""`
when none is known - rate-limit and audit by this, never by a client-supplied
`X-Forwarded-For`). Build a `Response` with `ok(body)` (`200`, text) or
`respond(status, body)`, or set fields and headers directly with
`Response.setHeader`/`addHeader`/`getHeader`.

`listenAndServe` dispatches each request to `route` on its own green thread
and never returns except on a bind error. For a bounded number of requests,
or to inspect the connection before reading, drive `serve`/`Server.accept()`/
`Exchange.read()`/`Exchange.respond()` yourself, and stop a running server
with `Server.shutdown(timeoutMs)` (drains in-flight requests, force-closes
whatever is still running once `timeoutMs` elapses) or `Server.close()`
(stops immediately). `Server.setIdleTimeoutMs(ms)` (default 60s) and
`Server.setMaxRequestsPerConn(n)` (default 1000) bound what an idle or
long-lived keep-alive connection can hold onto; `Server.setMaxBodyBytes(n)`
(default 32 MiB, no "unlimited" value) refuses an over-limit body with `400`
before it is read.

## Building a web app

`std/http` gives you the wire protocol: a request in, a response out. It has
no router, no middleware, no JSON body binding, and no session or cookie
helpers - those decisions belong to a framework, not the transport.
[`pkg/web`](/packages/web) is that framework, built on this module: routes,
typed request bodies, error handling, and OpenAPI generation. [The Bit
Book's web course](/book/14-first-endpoint) builds a real service with it,
starting from exactly the handler shown above.

## Sharp edges

| Situation | Behaviour |
|---|---|
| a server that never answers, called with `get`/`post`/`request` | the call parks forever - use `*Timeout` |
| setting `Accept-Encoding` yourself | `requestWith` fails - this stdlib has no response decompressor |
| a response over the body-size budget (32 MiB default) | the call fails before the bytes are read |
| `Server.setMaxBodyBytes(0)` or a zero `Limits` field to `parseMultipart` | refuses every body - `0` never means unlimited |
| a client offering ALPN `h2` against a server that shares no protocol | the handshake is aborted, never silently downgraded |
| an `https+h3://` request today | unauthenticated - QUIC certificate verification has not landed; treat it as experimental |
| `req.peer` on a hand-built `Request`, or one whose connection died early | `""`, never a placeholder address |

## Reference

### Transports

The same `Request`/`Response` types and the same `(Request) => Response`
handler serve all three protocols - only the socket underneath changes.

| Protocol | Client | Server | Transport |
|---|---|---|---|
| HTTP/1.1 | `get`/`request` on `http://` or `https://` | `serve` / `listenAndServe` | TCP, cleartext or TLS 1.3 |
| HTTP/2 | automatic over `https://` when the server offers ALPN `h2` | `serveTls` (no separate entry point - it is what TLS already speaks) | TCP + TLS 1.3 |
| HTTP/3 | explicit `https+h3://`, or after an Alt-Svc upgrade on a `Client` | `serveH3` / `h3Serve`, opt-in, paired with a `serveTls` for discovery | QUIC (UDP) + TLS 1.3 |

### Messages

| Symbol | Meaning |
|---|---|
| `Request` | `method`, `path`, raw `headers`, `body`, `peer`, `headerLines` |
| `Response` | `status`, `contentType`, raw `headers`, `body` |
| `header(block, name): string` | a named header's value from a raw block, or `""` |
| `atoi(s): int` | the non-negative integer `s` names, or `-1` on anything else (no silent overflow) |
| `ok(body): Response` | `200` with a UTF-8 text body |
| `respond(status, body): Response` | an explicit status and text body |
| `Response.setHeader(name, value)!` / `addHeader(name, value)!` | replace / append a header on the way out; fails on an invalid name or a CR/LF/NUL in `value` |
| `Response.getHeader(name): string` | a header already set on this response |

### TLS (HTTPS) server

| Symbol | Meaning |
|---|---|
| `serveTls(host, port, certPem, keyPem, handler)!` | the TLS mirror of `listenAndServe`; also the HTTP/2 server via ALPN |
| `serveTlsOn(listener, handler)!` | serve on an already-bound `std/tls` `Listener` |
| `TlsServer` / `tlsServe(host, port, certPem, keyPem): TlsServer!` | shutdown-capable TLS listener, mirroring `Server` |
| `serveTlsServerOn(ts, handler)!` | serve on a `TlsServer` |
| `TlsServer.setMaxBodyBytes(n)` / `.shutdown(timeoutMs)!` / `.attachH3(hs)` | mirror `Server`'s, plus pairing an `H3Server` so one `shutdown()` drains both |

### HTTP/3

Opt-in because QUIC needs UDP and a heavier handshake than plain TLS-over-TCP.

| Symbol | Meaning |
|---|---|
| `serveH3(host, port, certPem, keyPem, handler)!` | serves HTTP/3 forever; run on its own green thread, paired with `serveTls` on the same port |
| `serveH3On(sock, certPem, keyPem, handler)!` | serve on an already-bound UDP socket |
| `H3Server` / `h3Serve(host, port, certPem, keyPem): H3Server!` | shutdown-capable mirror |
| `serveH3ServerOn(hs, handler)!` / `H3Server.port()!` / `.shutdown(timeoutMs)!` | drive and stop it |

### Hijacking a connection (protocol upgrades)

For a handler that must take over the raw connection - a WebSocket upgrade,
for instance ([`std/websocket`](websocket.md) is built on this).

| Symbol | Meaning |
|---|---|
| `HijackOutcome` | `Answer(res)` to answer normally, or `Hijacked` after calling `hijack()` |
| `serveHijackableOn(s, handler)!` / `serveHijackableBackground(s, handler)` | the hijack-capable sibling of `listenAndServeOn` |
| `Exchange.hijack(): Conn` / `.hijackStream(): byteStream` | take ownership of the connection, raw or transport-agnostic |
| `Exchange.respondKeepAlive(req, res, mustCloseNow): bool!` | answer while driving your own multi-request loop |
| `serveHijackableTlsOn` / `serveHijackableTlsBackground` / `TlsExchange` / `TlsServer.accept()!` | the TLS mirrors of the five above |
| `byteStream` / `newByteStream(c)` / `newTlsByteStream(c)` | the transport-agnostic read/write interface a hijacked connection speaks |

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

### Request headers you build

| Symbol | Meaning |
|---|---|
| `Header{ name, value }` | one outgoing header |
| `serializeHeaders(headers): string!` | validates and joins them into the raw wire block |
| `validateHeaderName(name)!` / `validateHeaderValue(value)!` | the checks `serializeHeaders` and `Response.setHeader` both run |

### Query strings

`Request.path` is the raw, still percent-encoded request target.

| Symbol | Meaning |
|---|---|
| `splitTarget(target): (path, rawQuery)` | split at the first `?` |
| `parseQuery(raw): map<string, string>` | decoded key to decoded value; a duplicate key is last-wins |
| `percentDecode(s): string` | `%XX` to a byte, `+` to a space; a malformed escape passes through unchanged |
| `percentEncode(s): string` | the inverse, for a value you are about to put in a URL |

```bit
import { splitTarget, parseQuery } from "std/http"

fn queryFor(target: string): map<string, string> {
  let (_, rawQuery) = splitTarget(target)
  return parseQuery(rawQuery)
}
```

### Multipart form uploads

`parseMultipart` turns a `Request.body` into named fields and named file
parts. Every `Limits` field is required, and a zero limit rejects everything
that would use it - it never means unlimited, because the body is
attacker-controlled. A file's declared `filename` and `contentType` are
returned exactly as received and are never sanitised: joining `filename` to
a path is the caller's decision to make deliberately.

| Symbol | Meaning |
|---|---|
| `Limits` / `defaultLimits(): Limits` | `maxBodyBytes`, `maxFileBytes`, `maxParts`, `maxHeaderLineBytes`, `maxPartHeaderBytes` |
| `Form` / `parseMultipart(body, boundary, limits): Form!` | `.fields`, `.files`, `.value(name)`, `.file(name)!` |
| `FormField` / `FormFile` | a text field (`name`, `value`); a file part (`name`, `filename`, `contentType`, `content`) |
| `multipartField(body, boundary, name, limits): (string, bool)!` | one field's value without building a whole `Form` - cheap for reading a hidden token out of a large upload |

```bit
import { Form, parseMultipart, defaultLimits } from "std/http"

// `boundary` is the Content-Type header's own "boundary=..." parameter,
// extracted by the caller before this is reached.
fn handleUpload(body: []byte, boundary: string): Form! {
  return parseMultipart(body, boundary, defaultLimits())?
}
```

## Where to go next

- Building routes, JSON bodies and middleware on top of this: [pkg/web](/packages/web) and [the Book's web course](/book/14-first-endpoint).
- Certificates, trust stores and dialing TLS directly: [std/tls](tls.md).
- Framing your own protocol over a hijacked connection: [std/websocket](websocket.md).

---

Specification: `spec/SPEC.md`.
