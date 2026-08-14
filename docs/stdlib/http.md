# std/http

HTTP/1.1, HTTP/2, and HTTP/3 - built entirely in Bit over `std/net` (cleartext),
`std/tls` (TLS 1.3), and `std/quic` (QUIC). A server accepts connections and handles each on its own green thread; a
client dials, sends one request, and reads the response. The wire protocol is the
same on either transport - an `https://` URL or `serveTls` just swaps the socket.
Fallible calls return `T!` - propagate with `?` or handle with `catch`.

Scope: HTTP/1.1 over cleartext or TLS, one request per connection
(`Connection: close`), no redirects. Headers are carried as a raw block and
read with `header()`. Request framing follows RFC 9112 §6: a body is read only
when `Content-Length` or `Transfer-Encoding: chunked` says so (chunked is
decoded, never passed through raw); a request declaring both, or a
Content-Length or chunk stream this parser cannot make sense of, is rejected
with 400. Responses are always sent with an exact Content-Length - the server
itself never emits chunked.

<!-- doctest: per-block -->

## Transports

The `Request`/`Response` types and the `(Request) => Response` handler are the
same across all three protocols - only the socket underneath changes.

| Protocol | How to use | Transport | Notes |
| --- | --- | --- | --- |
| HTTP/1.1 | `serve` / `listenAndServe`; `get`/`request` on `http://` or `https://` | TCP, cleartext or TLS 1.3 | Always available; the fallback for the other two. |
| HTTP/2 | ALPN `h2`, negotiated by `serveTls` and `getTls`/`requestTls` over TLS | TCP + TLS 1.3 | Selected automatically when both peers offer `h2`; falls back to HTTP/1.1. |
| HTTP/3 | `serveH3`; client via `https+h3://` or Alt-Svc discovery | QUIC (UDP) + TLS 1.3 | Opt-in - see [HTTP/3](#http3). |

## Messages

### `Request`

A parsed request: `method`, `path`, the raw `headers` block, and `body`. Read a
named header with `header(req.headers, "...")`.

### `Response`

A response: `status`, `contentType`, extra raw `headers`, and `body`. A server
fills in `Content-Length` and `Connection` for you.

### `header(block: string, name: string): string`

The value of header `name` in a raw header block, matched case-insensitively at a
line start, or `""` if absent.

### `atoi(s: string): int`

The non-negative integer `s` denotes, or `-1` on any non-digit (including the
empty string) or a magnitude that would overflow `int` — it never silently
wraps. Used internally for a request's `Content-Length`, a response status
code, and a URL port; exported so callers parsing the same kind of untrusted,
network-sourced decimal text get the same overflow-safe guard.

### `ok(body: string): Response`

A `200 OK` response carrying `body` as UTF-8 text.

### `respond(status: int, body: string): Response`

A response with an explicit status and a text body.

```bit
import { Request, Response, ok, respond, header } from "std/http"

// Route a request to a response.
fn route(req: Request): Response {
  if (req.path == "/health") {
    return ok("ok")
  }
  return respond(404, "not found")
}

fn accepts(req: Request): string {
  return header(req.headers, "Accept")
}
```

## Server

Drive the server with an `accept()` loop, spawning a green thread per exchange
and calling `Exchange.read()` there. `accept()` only accepts — it returns as
soon as a connection exists, before anything is read off it — so a slow or
stalled client's read can only ever block its own exchange, never the next
accept or another exchange's read.

### `Server`

A listening HTTP server.

### `Exchange`

One accepted connection, and the connection to answer it on. Call `read()` to
get the request.

### `serve(host: string, port: int): Server!`

Binds and starts listening on `host:port`. Port `0` lets the kernel choose one;
read it back with `port()`.

### `Server.port(): int!`

The port the server is bound to.

### `Server.accept(): Exchange!`

Accepts the next connection, parking until a client arrives. Returns
immediately once the connection exists — it does not read anything off it;
call `Exchange.read()` for that, on its own spawned green thread.

### `Exchange.read(): Request!`

Reads the request (headers and body) off this exchange's connection. Parks
until the whole request arrives. Fails on a malformed request (bad framing, a
Content-Length/Transfer-Encoding conflict, a control character in a header, or
a header block over the 64 KiB cap) — answer 400 and drop the connection
rather than pass the failure to a handler. Call this on its own green thread
(spawned right after `accept()`), never inline in the accept loop.

### `Exchange.respond(res: Response): ()!`

Writes `res` to the connection and closes it.

### `Server.close()`

Stops listening.

### `listenAndServe(host: string, port: int, handler: (Request) => Response): ()!`

Serves HTTP on `host:port` forever, dispatching every request to `handler` on its
own green thread - the idiomatic server. `handler` is an ordinary function value.
Returns only on a bind or accept error. For a kernel-chosen port, or to serve a
bounded number of requests, drive `serve`/`accept`/`respond` yourself.

```bit
import { serve, listenAndServe, ok, respond, Server, Exchange, Request, Response } from "std/http"
import { hasPrefix } from "std/strings"

// A request handler is just a function value.
fn route(req: Request): Response {
  if (req.path == "/") {
    return ok("hello from bit")
  }
  return respond(404, "not found")
}

fn main() {
  listenAndServe("127.0.0.1", 8080, route) catch e {
    print("server failed: ${e.message()}\n")
  }
}

// Or drive the loop yourself for a kernel-chosen port or bounded serving.
// `read()` runs on the spawned thread, not the accept loop, so one slow
// client cannot delay anyone else's accept or read.
fn handle(ex: Exchange): ()! {
  let req = ex.read()?
  ex.respond(ok("hello from bit"))?
}

fn runServer(s: Server, n: int): ()! {
  let i = 0
  while (i < n) {
    let ex = s.accept()?
    spawn handle(ex)
    i = i + 1
  }
  s.close()
}
```

## Client

### `request(method: string, url: string, body: string): Response!`

Sends `method url` with an optional body and returns the response. The request
asks the server to close the connection, so the whole response is read to EOF. An
`https://` URL runs over TLS 1.3, verifying the server's certificate chain and
hostname against the default roots; an `http://` URL runs over cleartext TCP.

### `get(url: string): Response!`

GETs `url`.

### `post(url: string, body: string): Response!`

POSTs `body` to `url`.

### `requestTimeout(method: string, url: string, body: string, timeoutMs: int): Response!`

Like `request`, but bounded by a whole-request `timeoutMs` - connect, send and
read of headers and body all share ONE deadline, resolved once before dial
rather than restarted per read. A server that accepts and never answers gets
you a `fail` instead of an indefinite park. Covers `http://`, `https://` and
`https+h3://` - an `https://` URL dials through [`std/tls`](tls.md)'s
`dialDeadline`, whose `TlsConn` inherits the same deadline for the handshake
and every later record-layer read/write. `https+h3://` runs over its own QUIC
transport ([`std/http3`](http3.md)'s `h3DialDeadline`), which has no
per-operation deadline primitive; instead the deadline lowers the QUIC
connection's own RFC 9000 idle timeout, so a peer that accepts the handshake
and never answers is torn down within the deadline. Two gaps relative to
http/https: the QUIC handshake itself is still bounded by a fixed internal 5s
abandon timer rather than by `timeoutMs`, and the idle timer resets on any
received datagram rather than tracking request progress specifically. There
is no default on `request`/`get`/`post` themselves: a caller downloading a
large file over a bare `get` is unaffected by this change.

### `getTimeout(url: string, timeoutMs: int): Response!`

GETs `url` (`http://`, `https://`, or `https+h3://`), bounded by a
whole-request `timeoutMs`.

### `postTimeout(url: string, body: string, timeoutMs: int): Response!`

POSTs `body` to `url` (`http://`, `https://`, or `https+h3://`), bounded by a
whole-request `timeoutMs`.

```bit
import { get, post, request, Response } from "std/http"

fn fetchStatus(url: string): int! {
  let res = get(url)?
  return res.status
}

fn submit(url: string, payload: string): string! {
  let res = post(url, payload)?
  return res.body
}

fn head(url: string): Response! {
  return request("HEAD", url, "")?
}
```

## TLS (HTTPS)

An `https://` URL transparently runs the same request over TLS 1.3, verifying the
server against the operating-system trust store (falling back to a small bundled
root set) - no extra arguments to `request` / `get` / `post`. For a custom trust
configuration - a pinned private CA, a fixed `serverName`, or `insecureSkipVerify`
in a test - pass a `std/tls` `TlsConfig` to the https-only variants.

### `requestTls(method: string, url: string, body: string, config: TlsConfig): Response!`

As `request`, but over https with an explicit `std/tls` `TlsConfig` - pinned
roots, a fixed `serverName`, or `insecureSkipVerify`. `config.alpn` defaults to
`["h2","http/1.1"]` when empty, so the request runs over HTTP/2 whenever the
server selects `h2`; set it to `["http/1.1"]` to force HTTP/1.1. A non-`https://`
URL fails.

### `getTls(url: string, config: TlsConfig): Response!`

GET an https `url` with an explicit `std/tls` `TlsConfig`.

### `postTls(url: string, body: string, config: TlsConfig): Response!`

POST `body` to an https `url` with an explicit `std/tls` `TlsConfig`.

### `serveTls(host, port, certPem, keyPem, handler): ()!`

The TLS mirror of `listenAndServe`: serves HTTPS on `host:port` forever with the
certificate chain `certPem` and matching private key `keyPem` (both PEM),
dispatching each request to `handler` on its own green thread. Returns only on a
bind error; a single connection's failed or rejected handshake drops that
connection and the server keeps serving.

This is also the HTTP/2 server: `serveTls` offers ALPN `["h2","http/1.1"]`, so a
client that negotiates `h2` is served over HTTP/2 and everything else over
HTTP/1.1 - the same `handler` serves both, and you write nothing extra to get
HTTP/2. There is no `serveH2` because there is nothing for it to do. See
[HTTP/2](#http2) below and `examples/http2server`.

A client that offers ALPN but shares no protocol with the server has its
handshake **aborted** (RFC 7301 §3.2 `no_application_protocol`), not silently
downgraded to HTTP/1.1 - so a client that offers only `h2` is either served over
HTTP/2 or refused, never quietly served over something it did not ask for.

```bit
import { get, getTls, serveTls, ok, respond, Request, Response } from "std/http"
import { newTlsConfig, newTrustStore } from "std/tls"

// An https GET verified against the default (system/bundled) roots.
fn fetchStatus(url: string): int! {
  let res = get(url)?
  return res.status
}

// An https GET pinned to a private CA (PEM) - a test fixture or corporate root.
fn fetchPinned(url: string, caPem: string): Response! {
  let cfg = newTlsConfig(newTrustStore(caPem)?)
  return getTls(url, cfg)?
}

// Serve HTTPS with a PEM certificate chain and key.
fn route(req: Request): Response {
  if (req.path == "/health") {
    return ok("ok")
  }
  return respond(404, "not found")
}

fn serveSecure(certPem: string, keyPem: string) {
  serveTls("127.0.0.1", 8443, certPem, keyPem, route) catch e {
    print("server failed: ${e.message()}\n")
  }
}
```

## HTTP/2

Over TLS, the protocol is chosen by ALPN during the handshake - HTTP/2 (`h2`, RFC
9113) when both ends support it, HTTP/1.1 otherwise. This is transparent: the same
`get`/`request`/`serveTls` calls and the same `(Request) => Response` handler drive
either protocol. Requests and responses map to HTTP/2 streams - the
`:method`/`:scheme`/`:authority`/`:path` and `:status` pseudo-headers become the
`Request`/`Response` fields, the rest become the raw header block - and HTTP/2
multiplexing, HPACK, and flow control are handled by the `std/http2` engine
underneath.

- **Client**: `request`/`get`/`post` over an `https://` URL offer ALPN
  `["h2","http/1.1"]`. If the server selects `h2`, the exchange runs over the
  HTTP/2 engine; otherwise it falls back to HTTP/1.1. `requestTls`/`getTls`/`postTls`
  do the same, and default `config.alpn` to `["h2","http/1.1"]` when it is empty -
  set it to `["http/1.1"]` to force HTTP/1.1.
- **Server**: `serveTls` advertises ALPN `["h2","http/1.1"]`. Each accepted
  connection is served over HTTP/2 or HTTP/1.1 by what it negotiated; HTTP/2
  streams are each dispatched to the handler on their own green thread.
- **Cleartext** (`http://`, `listenAndServe`) is always HTTP/1.1 - HTTP/2 here
  requires TLS ALPN.

There is deliberately no `serveH2` entry point: HTTP/2 is not a separate server,
it is what `serveTls` already speaks whenever ALPN selects it. `serveH3` is
separate only because HTTP/3 is a different *transport* - QUIC over UDP, a socket
`serveTls` does not own - not because HTTP/2 is missing. `examples/http2server`
is a runnable HTTP/2 server that proves the negotiated protocol is `h2`.

| API / URL | Transport | Protocol |
|---|---|---|
| `http://` - `get`/`request`/`listenAndServe` | cleartext TCP | HTTP/1.1 |
| `https://` - `get`/`request`/`getTls` | TLS 1.3 + ALPN | HTTP/2 when the server picks `h2`, else HTTP/1.1 |
| `serveTls` | TLS 1.3 + ALPN `["h2","http/1.1"]` | per client: HTTP/2 or HTTP/1.1 |

```bit
import { get, serveTls, ok, respond, Request, Response } from "std/http"

// One transport-agnostic handler serves HTTP/1.1 and HTTP/2 alike.
fn route(req: Request): Response {
  if (req.path == "/") {
    return ok("hello over h1 or h2")
  }
  return respond(404, "not found")
}

// serveTls advertises ALPN ["h2","http/1.1"]; a client that negotiates h2 is
// served over the HTTP/2 engine, any other over HTTP/1.1 - same handler.
fn serveSecure(certPem: string, keyPem: string) {
  serveTls("127.0.0.1", 8443, certPem, keyPem, route) catch e {
    print("server failed: ${e.message()}\n")
  }
}

// The client offers h2 then http/1.1 by default, so get()/request() transparently
// use HTTP/2 when the server supports it.
fn fetchStatus(url: string): int! {
  let res = get(url)?
  return res.status
}
```

## HTTP/3

HTTP/3 (RFC 9114) runs over QUIC - a TLS 1.3 transport on UDP, not TCP - so unlike
the HTTP/1.1 ↔ HTTP/2 choice it is **opt-in**, never negotiated behind a plain
`https://` request: QUIC needs UDP and is heavier to set up, so the same
`https://` URL always stays on TLS-over-TCP. A client reaches HTTP/3 one of two
ways:

- **Explicit scheme** - an `https+h3://` URL dials QUIC and speaks HTTP/3 directly.
- **Alt-Svc discovery** - a `serveTls` server advertises `Alt-Svc: h3=":<port>"`
  (RFC 7838) on every response, naming an HTTP/3 endpoint on the same port number
  over UDP. A `Client` remembers that advertisement and upgrades a later request to
  the same authority to HTTP/3 automatically.

The `Request`/`Response` types and the `(Request) => Response` handler are the
same across all three transports; only the socket underneath changes. HTTP/3
streams carry the `:method`/`:scheme`/`:authority`/`:path` and `:status`
pseudo-headers as the `Request`/`Response` fields, the rest as the raw header
block, and QPACK + QUIC framing are handled by the `std/http3` engine.

The QUIC transport is one connection per UDP socket in this build, so `serveH3`
serves one client connection's requests - run it on its own green thread, and pair
it with a `serveTls` on the same port for discovery. The h3 client is one request
per connection, like the rest of this module. (The QUIC layer does not yet verify
server certificates, so the h3 client leg is unauthenticated - treat `https+h3://`
and the Alt-Svc upgrade as experimental until QUIC certificate verification lands.)

| API / URL | Transport | Protocol |
|---|---|---|
| `http://` - `get`/`request`/`listenAndServe` | cleartext TCP | HTTP/1.1 |
| `https://` - `get`/`request`/`getTls` | TLS 1.3 + ALPN | HTTP/2 when the server picks `h2`, else HTTP/1.1 |
| `serveTls` | TLS 1.3 + ALPN `["h2","http/1.1"]` | per client: HTTP/2 or HTTP/1.1; advertises h3 via Alt-Svc |
| `https+h3://` - `get`/`request` | QUIC (UDP) | HTTP/3 |
| `Client` - after an Alt-Svc upgrade | QUIC (UDP) | HTTP/3 |
| `serveH3` | QUIC (UDP) | HTTP/3 |

### `serveH3(host, port, certPem, keyPem, handler): ()!`

Serves HTTP/3 over QUIC on `host:port` (UDP) with the certificate chain `certPem`
and matching private key `keyPem` (both PEM), dispatching each request to the same
`(Request) => Response` handler `serve`/`serveTls` use. Run it on its own green
thread; pair it with a `serveTls` on the same port so `https://` clients discover
it through the Alt-Svc header.

```bit
import { serveH3, serveTls, get, ok, respond, Request, Response } from "std/http"

// One transport-agnostic handler serves HTTP/1.1, HTTP/2, and HTTP/3 alike.
fn route(req: Request): Response {
  if (req.path == "/") {
    return ok("hello over h1, h2, or h3")
  }
  return respond(404, "not found")
}

// serveH3 binds a UDP socket; pair it with serveTls on the same port number so
// https:// clients can discover the h3 endpoint via the Alt-Svc header. Each is a
// void function value the caller can `spawn` onto its own green thread.
fn serveH3Secure(certPem: string, keyPem: string) {
  serveH3("127.0.0.1", 8443, certPem, keyPem, route) catch e {
    print("h3 server failed: ${e.message()}\n")
  }
}

fn serveTlsSecure(certPem: string, keyPem: string) {
  serveTls("127.0.0.1", 8443, certPem, keyPem, route) catch e {
    print("tls server failed: ${e.message()}\n")
  }
}

// A direct HTTP/3 fetch via the explicit, opt-in https+h3:// scheme.
fn fetchH3(url: string): int! {
  let res = get(url)?
  return res.status
}
```

### `Client`

An HTTP client that remembers the HTTP/3 endpoints servers advertise via Alt-Svc,
so a later request to the same authority upgrades to HTTP/3. It carries its own TLS
config and Alt-Svc cache - there is **no global state**: hold one `Client` across
requests to reuse the cache.

### `newClient(): Client`

A `Client` with secure-by-default TLS (verification on, system/bundled roots, ALPN
`h2` then `http/1.1`) and an empty Alt-Svc cache.

### `newClientTls(config: TlsConfig): Client`

A `Client` with an explicit `std/tls` config for its `https://` leg - pinned roots,
a fixed `serverName`, or `insecureSkipVerify` - and an empty Alt-Svc cache.

### `Client.request(method: string, url: string, body: string): Response!`

Sends `method url` with an optional body. An `https+h3://` URL always uses HTTP/3;
an `https://` URL upgrades to HTTP/3 when this client has cached an Alt-Svc endpoint
for the authority (otherwise it runs over TLS and learns any Alt-Svc the response
advertises); an `http://` URL runs over cleartext HTTP/1.1.

### `Client.get(url: string): Response!`

GETs `url` through this client (HTTP/3 when discovered, else TLS or cleartext).

### `Client.post(url: string, body: string): Response!`

POSTs `body` to `url` through this client.

### `Client.requestTimeout(method: string, url: string, body: string, timeoutMs: int): Response!`

Like the package-level `requestTimeout`: a whole-request deadline covering
`http://`, `https://`, and `https+h3://`. Does not consult this client's
Alt-Svc cache - an `https+h3://` URL is still the only way to reach the h3
path here, same as `Client.request` - but DOES use its TLS config for
`http://`/`https://`: an `https://` URL dials with `c.tls`, so a `Client`
built with `newClientTls` (pinned roots, a fixed `serverName`,
`insecureSkipVerify`) gets that config applied here, the same as
`Client.request`/`requestTls` already do.

### `Client.getTimeout(url: string, timeoutMs: int): Response!`

GETs `url` through this client (`http://`, `https://`, or `https+h3://`),
bounded by a whole-request `timeoutMs`.

### `Client.postTimeout(url: string, body: string, timeoutMs: int): Response!`

POSTs `body` to `url` through this client (`http://`, `https://`, or
`https+h3://`), bounded by a whole-request `timeoutMs`.

```bit
import { newClient, newClientTls, Client, Response } from "std/http"
import { newTlsConfig, newTrustStore } from "std/tls"

// A client that auto-upgrades to HTTP/3 once a server advertises it via Alt-Svc.
// Hold one across requests so its Alt-Svc cache persists (no global state).
fn browse(): Response! {
  let c = newClient()
  // First request runs over HTTPS (HTTP/2 or HTTP/1.1) and learns any Alt-Svc.
  let first = c.get("https://example.com/")?
  if (first.status != 200) {
    return first
  }
  // A later request to the same authority upgrades to HTTP/3 automatically.
  return c.get("https://example.com/")?
}

// A client pinned to a private CA for its https leg (a test or corporate root).
fn browsePinned(caPem: string): Response! {
  let c = newClientTls(newTlsConfig(newTrustStore(caPem)?))
  return fetchWith(c, "https://internal.example/")?
}

fn fetchWith(c: Client, url: string): Response! {
  return c.get(url)?
}
```
