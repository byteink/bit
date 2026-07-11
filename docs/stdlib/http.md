# std/http

HTTP/1.1 over `std/net` (cleartext) or `std/tls` (TLS 1.3), built entirely in
Bit. A server accepts connections and handles each on its own green thread; a
client dials, sends one request, and reads the response. The wire protocol is the
same on either transport — an `https://` URL or `serveTls` just swaps the socket.
Fallible calls return `T!` — propagate with `?` or handle with `catch`.

Scope: HTTP/1.1 over cleartext or TLS, one request per connection
(`Connection: close`), no chunked transfer encoding, no redirects. Headers are
carried as a raw block and read with `header()`.

<!-- doctest: per-block -->

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

### `ok(body: string): Response`

A `200 OK` response carrying `body` as UTF-8 text.

### `respond(status: int, body: string): Response`

A response with an explicit status and a text body.

```bit
import { Request, Response, ok, respond, header } from "std/http"

// Route a request to a response.
function route(req: Request): Response {
  if (req.path == "/health") {
    return ok("ok")
  }
  return respond(404, "not found")
}

function accepts(req: Request): string {
  return header(req.headers, "Accept")
}
```

## Server

Drive the server with an `accept()` loop, spawning a green thread per exchange so
a slow handler never delays the next accept.

### `Server`

A listening HTTP server.

### `Exchange`

One accepted request (`request`) together with the connection to answer it on.

### `serve(host: string, port: int): Server!`

Binds and starts listening on `host:port`. Port `0` lets the kernel choose one;
read it back with `port()`.

### `Server.port(): int!`

The port the server is bound to.

### `Server.accept(): Exchange!`

Accepts the next connection and reads its request, parking until a client
arrives.

### `Exchange.respond(res: Response): ()!`

Writes `res` to the connection and closes it.

### `Server.close()`

Stops listening.

### `listenAndServe(host: string, port: int, handler: (Request) => Response): ()!`

Serves HTTP on `host:port` forever, dispatching every request to `handler` on its
own green thread — the idiomatic server. `handler` is an ordinary function value.
Returns only on a bind or accept error. For a kernel-chosen port, or to serve a
bounded number of requests, drive `serve`/`accept`/`respond` yourself.

```bit
import { serve, listenAndServe, ok, respond, Server, Exchange, Request, Response } from "std/http"
import { hasPrefix } from "std/strings"

// A request handler is just a function value.
function route(req: Request): Response {
  if (req.path == "/") {
    return ok("hello from bit")
  }
  return respond(404, "not found")
}

function main() {
  listenAndServe("127.0.0.1", 8080, route) catch e {
    print("server failed: ${e.message()}\n")
  }
}

// Or drive the loop yourself for a kernel-chosen port or bounded serving:
function handle(ex: Exchange): ()! {
  ex.respond(ok("hello from bit"))?
}

function runServer(s: Server, n: int): ()! {
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

```bit
import { get, post, request, Response } from "std/http"

function fetchStatus(url: string): int! {
  let res = get(url)?
  return res.status
}

function submit(url: string, payload: string): string! {
  let res = post(url, payload)?
  return res.body
}

function head(url: string): Response! {
  return request("HEAD", url, "")?
}
```

## TLS (HTTPS)

An `https://` URL transparently runs the same request over TLS 1.3, verifying the
server against the operating-system trust store (falling back to a small bundled
root set) — no extra arguments to `request` / `get` / `post`. For a custom trust
configuration — a pinned private CA, a fixed `serverName`, or `insecureSkipVerify`
in a test — pass a `std/tls` `TlsConfig` to the https-only variants.

### `requestTls(method: string, url: string, body: string, config: TlsConfig): Response!`

As `request`, but over https with an explicit `std/tls` `TlsConfig` — pinned
roots, a fixed `serverName`, or `insecureSkipVerify`. `config.alpn` defaults to
`http/1.1` when empty; a non-`https://` URL fails.

### `getTls(url: string, config: TlsConfig): Response!`

GET an https `url` with an explicit `std/tls` `TlsConfig`.

### `postTls(url: string, body: string, config: TlsConfig): Response!`

POST `body` to an https `url` with an explicit `std/tls` `TlsConfig`.

### `serveTls(host, port, certPem, keyPem, handler): ()!`

The TLS mirror of `listenAndServe`: serves HTTPS on `host:port` forever with the
certificate chain `certPem` and matching private key `keyPem` (both PEM),
dispatching each request to `handler` on its own green thread. Offers ALPN
`http/1.1`. Returns only on a bind, accept, or handshake error.

```bit
import { get, getTls, serveTls, ok, respond, Request, Response } from "std/http"
import { newTlsConfig, newTrustStore } from "std/tls"

// An https GET verified against the default (system/bundled) roots.
function fetchStatus(url: string): int! {
  let res = get(url)?
  return res.status
}

// An https GET pinned to a private CA (PEM) — a test fixture or corporate root.
function fetchPinned(url: string, caPem: string): Response! {
  let cfg = newTlsConfig(newTrustStore(caPem)?)
  return getTls(url, cfg)?
}

// Serve HTTPS with a PEM certificate chain and key.
function route(req: Request): Response {
  if (req.path == "/health") {
    return ok("ok")
  }
  return respond(404, "not found")
}

function serveSecure(certPem: string, keyPem: string) {
  serveTls("127.0.0.1", 8443, certPem, keyPem, route) catch e {
    print("server failed: ${e.message()}\n")
  }
}
```
