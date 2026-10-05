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

Certificate verification is on by default for every https leg, including
`https+h3://` (system roots, `insecureSkipVerify` false) - `getTls`/
`postTls`/`requestTls` and a `Client`'s own config carry through to the HTTP/3
leg exactly as they do to `https://`.

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
import { BodySource, BodySink, Header, StreamBody, getStreaming, requestWithStreamingBody } from "std/http"
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
  let body = StreamBody{ source = source, length = Option.Some(size) }
  requestWithStreamingBody("PUT", url, []Header(0), body)?
  let counter = Counter{ total = 0 }
  let sink: BodySink = counter.take
  getStreaming(url, []Header(0), sink, size)?
  return counter.total
}
```

`requestWithStreamingBody` sends a request body of exactly `length`
bytes (a `Content-Length` request) pulled from a `BodySource` (`(int) => string!`, `""` at the end).
`getStreaming` hands a response body to a `BodySink` (`(string) => ()!`) one
chunk at a time and always returns `Response.body == ""`; its `maxBodyBytes`
bounds the memory the *server's* declared length can force, not what this
call buffers. Both cover `http://` and `https://` only; `https+h3://` is
refused.

### Sending a body of unknown length

When the producer cannot say how much it will write (a compressor, a live
feed, an `aws-chunked` upload), leave `length` out of the `StreamBody`. The
same `requestWithStreamingBody` call then sends the body as
`Transfer-Encoding: chunked` (RFC 9112 section 7.1) in chunks of up to 4096
bytes, the zero-size last chunk, and the trailer fields, if any. A declared
`length` always wins: that request carries a `Content-Length` and no chunked
framing.

Trailer fields (RFC 9110 section 6.5) are computed after the last body byte, so
they can carry a value derived from everything sent, such as a checksum or a
length. Announce them in a `Trailer` request header. Fields a trailer section
may not carry (`Content-Length`, `Host`, `Authorization`, `Content-Type` and
the rest of RFC 9110 section 6.5.1) are refused. Trailers need chunked
framing, so a body with both `length` and `trailers` is refused before
anything is sent.

```bit
import { BodySource, Header, StreamBody, TrailerSource, requestWithStreamingBody } from "std/http"

// A producer that hands out `data` and counts what it has handed out.
class Feed {
  data: string
  pos: int

  next(n: int): string! {
    let end = this.pos + n
    if (end > len(this.data)) {
      end = len(this.data)
    }
    let out = this.data[this.pos:end]
    this.pos = end
    return out
  }

  // Called once the body is complete, so `pos` is the final byte count.
  length(): []Header! {
    return [Header{ name = "x-body-length", value = "${this.pos}" }]
  }
}

fn upload(url: string, data: string): int! {
  let feed = Feed{ data = data, pos = 0 }
  let source: BodySource = feed.next
  let trailers: TrailerSource = feed.length
  let body = StreamBody{ source = source, trailers = Option.Some(trailers) }
  let announce = [Header{ name = "Trailer", value = "x-body-length" }]
  return requestWithStreamingBody("PUT", url, announce, body)?.status
}
```

Chunked is the default for an unknown length, as in Go's `net/http`, curl and
undici. RFC 9112 section 6.1 lets a client rely on what it knows about the
server from configuration or an earlier response. This call dials a fresh
connection each time and keeps no record of an earlier response's HTTP
version, so it never refuses a chunked request on those grounds; a server
that cannot read chunked requests needs a `length`. The source may answer with
fewer bytes than asked; the writer keeps pulling until a chunk is full, so a
slow producer still sends full-size chunks.

### Reading a body as it arrives

`getStreaming` pushes a body into a callback. `Client.send` with
`stream = true` is the pull form: it returns as soon as the status line and
headers have arrived, and the body stays on the wire until you ask for it, so
a 404 is visible before its error document is read and a 5 GiB object never
sits in memory.

```bit
import { Client, ClientRequest } from "std/http"

// The size of `url`'s body, or -1 for any status but 200. Holds one
// 64 KiB read at a time, however large the body is.
fn download(c: Client, url: string): int! {
  let res = c.send(ClientRequest{ url = url }, stream = true)?
  let body = unwrap(res.reader)
  if (res.status != 200) {
    body.close()
    return 0 - 1
  }
  let total = 0
  while (true) {
    let piece = body.read(65536)?
    if (len(piece) == 0) {
      return total
    }
    total = total + len(piece)
  }
}
```

`res.reader` is the `BodyReader`; `res.body` is `""`. `read(max)` returns at
least one byte and at most `max` (never more than 65536), and an empty slice
only at the end of the body. It never reports a truncated body as complete:
a connection that closes before its `Content-Length` bytes, or before the
final chunk, fails the read. Content-Length, chunked and read-to-close bodies
all work.

A reader owns its connection until the body ends. When `read` returns the
empty slice (or the last byte of a `Content-Length` body), the connection goes
back to the client's pool for the next request, provided the response left it
at a message boundary: HTTP/1.1, no `Connection: close`, a `Content-Length` or
chunked body with its final chunk and trailers consumed, and nothing after the
end. When you call `close()` before that, or a read fails or times out, the
connection is shut instead and never reused, because the rest of the body is
still on the wire. Call `close()` for any body you stop reading early or never
start, such as the 404 above. A streamed request is HTTP/1.1 only, is not
redirected (a 3xx comes back as it is), takes a pooled connection or dials one
and counts against `maxConnsPerHost` until the reader is done, and is not
limited by `setMaxBodyBytes`: you bound it by how much you read.

A response whose framing is ambiguous is refused before any body is read:
`Content-Length` fields that differ, a `Content-Length` together with
`Transfer-Encoding`, or a repeated `Transfer-Encoding` (RFC 9112 section 6.3).
The buffered client and the server refuse the same messages.

Set `timeoutMs` on the request to bound the connect, the response head and each
`read`. A stall in `read` fails with a `TimeoutError`, which you tell from other
errors with `e.(TimeoutError)`; a connect, request or head that outlives it fails
the `send` with a `RequestError` whose `cause` is the `TimeoutError`:

```bit
import { Client, ClientRequest, TimeoutError } from "std/http"

// The first `n` bytes of `url`'s body, or "" when the server stalled for
// more than two seconds between reads.
fn head(c: Client, url: string, n: int): string! {
  let res = c.send(ClientRequest{ url = url, timeoutMs = 2000 }, stream = true)?
  let body = unwrap(res.reader)
  defer body.close()
  let piece = body.read(n) catch e {
    let (te, ok) = e.(TimeoutError)
    if (ok && te.op == "read") {
      return ""
    }
    fail e
  }
  return string(piece)
}
```

### A client that reuses connections

The package-level functions above share one connection pool for the whole
process, so a loop of plain `http.get` calls to one host already pays for one
TCP connect and one TLS handshake, not one per call (the hops of a redirect
chain ride the same connection). A `Client` adds what a shared pool cannot
hold: its own configuration - a pinned CA, a bearer token, a body-size
limit - and a pool with bounds of its own (`setPool`). It also remembers which
servers have advertised HTTP/3, so a second request to the same host can
upgrade automatically.

```bit
import { Client, Response } from "std/http"

fn authedClient(token: string): Client! {
  let c = Client()
  c.setHeader("Authorization", "Bearer ${token}")?
  return c
}

fn fetchWith(c: Client, url: string): Response! {
  return c.get(url)?
}
```

`Client()` is secure by default (verification on, system roots, HTTP/2
offered). `Client(tls = config)` takes an explicit `std/tls` config for the
same reasons `getTls` does, such as Inkwell's staging API behind a private CA:

```bit
import { Client } from "std/http"
import { TlsConfig } from "std/tls"

fn stagingClient(pinned: TlsConfig): Client {
  return Client(tls = pinned)
}
```

`Client.request` / `requestWith` / `get` / `post` / `*Timeout` mirror the package-level
functions; `Client.setHeader` sets a default sent with every call from this
client, and `Client.setMaxBodyBytes(n)` raises or lowers the 32 MiB response
cap - there is no value meaning unlimited, so `0` refuses every body, the
same rule `Server.setMaxBodyBytes` uses below.

### Keeping connections between requests

Inkwell's sync job pulls a few hundred drafts from the API in a loop. With
one `Client` the first request opens a connection and the rest ride it; a
response is parked for reuse only when it ended exactly at a message
boundary (HTTP/1.1, no `Connection: close`, a `Content-Length` or chunked
body). Three bounds keep the idle list from growing without limit, a fourth
caps how many connections one host may have open at once, and `PoolLimits`
names them with Go's defaults:

```bit
import { Client, PoolLimits } from "std/http"

fn pullDrafts(host: string, ids: []string): int! {
  let c = Client()
  c.setPool(PoolLimits{ maxIdlePerHost = 4, idleTimeoutMs = 30000, maxConnsPerHost = 8 })?
  let bytes = 0
  for id of ids {
    let res = c.get("http://${host}/drafts/${id}")?
    bytes = bytes + len(res.body)
  }
  c.close()
  return bytes
}
```

`maxIdlePerHost` (default 2) is how many idle connections one host may
keep, `maxIdleTotal` (default 100) the same across every host, and
`idleTimeoutMs` (default 90000) how long a connection may sit unused. Each
is checked when the pool is next used, not by a background thread, so an idle
`Client` costs nothing. `setPool` fails on a mistake - a negative
`maxIdlePerHost`, a `maxIdleTotal` below it, an `idleTimeoutMs` that is not
positive, a negative `maxConnsPerHost` - and `maxIdlePerHost = 0` is how you
turn reuse off. `close()` drops the connections that are idle now; the
`Client` stays usable.

The sync job above runs one request at a time, but the export screen runs
dozens, and a `Client` shared by dozens of green threads would open a socket
for each. `maxConnsPerHost` (default 0, no limit) caps the connections open at
once to one host, idle ones included. With `maxConnsPerHost = 8`, the ninth
concurrent `get` to a host waits until a request finishes and its connection
is parked or closed, then runs on it. The wait ends at the request's own
timeout (`getTimeout`, `requestTimeout`); a request with no timeout waits as
long as it takes. A request that times out in the queue fails with `http:
timed out waiting for a free connection (PoolLimits.maxConnsPerHost = 8
connections to http://host:80 already open)`, so the cap is named, not guessed
at. The cap is per host and per `Client`: another host has its own eight.
It applies to HTTP/1.1 only. An HTTP/2 origin carries many requests on one
connection, so `maxH2Streams` (below) is what limits it, and a request that
finds the origin speaks HTTP/2 hands its slot back before its stream starts.

A server may close an idle connection at any time, and the client learns
that only when it next uses it. A `GET`, `HEAD`, `PUT`, `DELETE`, `OPTIONS`
or `TRACE` that fails on a reused connection is retried once on a new one. A
`POST` is not: it may already have been processed, so replaying it would
repeat its effect, and the call fails with the error instead.

Each `Client` has a pool of its own and one TLS configuration, so connections
are never shared between clients. The package-level calls (`get`, `post`,
`request`, `requestTimeout` and the `Tls` variants) share one process-wide
pool with the default `PoolLimits`, which `setPool` and `close` cannot reach.
An `https://` connection in it is keyed by the whole TLS configuration the call
passed - roots, `serverName`, `insecureSkipVerify`, `alpn` and the rest - so a
`getTls` with a pinned CA never rides a connection another configuration
dialed. HTTP/3 connections are not pooled yet: each call still opens its own.

#### Sharing one HTTP/2 connection

Inkwell's export screen fetches forty drafts at once, one `get` per draft on
its own green thread. An HTTP/1.1 connection carries one request at a time, so
that is forty connections. An `https://` server that negotiates HTTP/2 carries
many requests at once, so the `Client` keeps one connection per origin and
every request becomes a stream on it: forty concurrent `get` calls make one
TCP connect and one TLS handshake.

```bit
import { Client, PoolLimits } from "std/http"

fn fetchDraft(c: Client, host: string, id: string, out: chan<int>) {
  let res = c.get("https://${host}/drafts/${id}") catch _ {
    out <- 0
    return
  }
  out <- len(res.body)
}

fn exportDrafts(host: string, ids: []string): int! {
  let c = Client()
  c.setPool(PoolLimits{ maxH2Streams = 20 })?
  let out = chan<int>(len(ids))
  for id of ids {
    spawn fetchDraft(c, host, id, out)
  }
  let bytes = 0
  for id of ids {
    let n = <- out
    bytes = bytes + n
  }
  c.close()
  return bytes
}
```

`maxH2Streams` (default 100) is the most requests in flight on the shared
connection. The cap is the lower of it and the server's own
`SETTINGS_MAX_CONCURRENT_STREAMS`; a request over the cap waits for a stream
to finish, within its own timeout, instead of being refused or opening a
second connection. `maxH2Streams` must be at least 1. The connection is closed
when it has been idle for `idleTimeoutMs`, when `close()` or `setPool` retires
it (requests already running on it finish first), and when a request on it
fails, because a timed-out or reset stream leaves it in a state the next
request should not share. `maxIdlePerHost = 0` turns sharing off here too:
each request gets its own connection and closes it. Retrying follows the same
rule as HTTP/1.1: a `GET` that fails on a shared connection is retried once on
a new one, a `POST` is not.

### Following redirects

Inkwell's API answers an export request with a redirect to a CDN host that
holds the file. You want the file, and you do not want the CDN to learn your
API token. A `Client` follows redirects by default, up to 10 hops, and takes
the token off the request the moment the next hop leaves the origin it was
meant for.

```bit
import { Client, Redirects, RedirectAllow } from "std/http"

fn inkwellClient(token: string): Client! {
  let c = Client()
  c.setHeader("Authorization", "Bearer ${token}")?
  return c
}

fn exportDraft(c: Client, id: string): string! {
  let res = c.get("https://api.inkwell.example/drafts/${id}/export")?
  // `res.url` is where the body came from; `res.redirects` is how many hops
  // it took to get there. The CDN host never saw the Authorization header.
  return "${res.url} after ${res.redirects} redirects: ${res.body}"
}

// The raw 3xx response, for a caller that wants to read `Location` itself.
fn rawRedirects(c: Client) {
  c.setRedirects(Redirects.None)
}

// A tighter limit than the default 10.
fn threeHops(c: Client) {
  c.setRedirects(Redirects.Follow(3))
}

// The two opt-ins, each named for what it permits: an https URL redirecting
// to plain http, and a POST or PUT body sent again to another origin.
fn trustedInternalHops(c: Client) {
  c.setRedirects(Redirects.FollowAllowing(10, RedirectAllow.Downgrade))
  c.setRedirects(Redirects.FollowAllowing(10, RedirectAllow.ReplayBody))
  c.setRedirects(Redirects.FollowAllowing(10, RedirectAllow.Both))
}
```

The package-level `get`, `post` and `request` follow redirects the same way,
with the default policy. What happens on each hop:

- A change of scheme, host or port removes `Authorization`, `Cookie`,
  `Proxy-Authorization` and `WWW-Authenticate` from the request, including
  the ones you set with `Client.setHeader`. A later hop that returns to the
  original origin does not get them back.
- A redirect from https to http fails, and the error names the opt-in. Only
  `http`, `https` and `https+h3` targets are followed; any other scheme in
  `Location` fails.
- A `303`, and a `301` or `302` answering a `POST`, become a `GET` with no
  body and no `Content-Type`; a `HEAD` stays a `HEAD`. A `307` or `308` keeps
  the method and the body. To another origin, a request with no body (a
  plain `GET`) is followed with the credentials removed, and a request that
  still carries a body fails rather than send it there.
- A `Location` can be relative (`../next`, `?page=2`, `//other.example/x`).
  A missing or malformed one hands you the `3xx` response unchanged.
- An eleventh redirect fails with the limit and the last URL in the message.
- The body of a redirect response is read, within the body cap, before the
  next hop. A `requestTimeout` deadline covers every hop together.

### Retrying a request that failed

Inkwell charges a card by posting to a payment service. When that call fails
with a reset, did the service charge the card or not? Repeating a request that
was processed is a double charge, and RFC 9110 section 9.2.2 says a client must
not repeat a `POST` unless it knows the request was not processed.

A request that fails once it reached the network layer fails with a
`RequestError`. Its `sent` is `true` once the client began writing the request,
so the server may have acted on it, and `false` when nothing left: a refused or
timed-out connect, a failed TLS handshake, a wait for a free connection that ran
out. `cause` is the error underneath, so a `HandshakeError` is still one
(`e.cause.(HandshakeError)`).

```bit
import { Client, RequestError } from "std/http"

fn charge(c: Client, body: string): string! {
  let res = c.post("https://pay.inkwell.example/charges", body) catch e {
    let (r, ok) = e.(RequestError)
    if (ok && !r.sent) {
      // The request never left: sending it again cannot double charge.
      return c.post("https://pay.inkwell.example/charges", body)?.body
    }
    fail e
  }
  return res.body
}
```

`sent` is conservative: it is `true` after a write that may have been partial,
and after a followed redirect whichever hop failed. A failure before the
network layer (a URL that does not parse, a header that cannot be sent) is a
plain error and sent nothing. A streamed request (`Client.send` with
`stream = true`) fails the same way, and one that outlives `timeoutMs` fails
with a `RequestError` whose `cause` is the `TimeoutError`. A reused connection
that fails is repeated on a fresh one for an idempotent method only, and a
`POST` fails with the `RequestError` of that connection.

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
(stops immediately). `Server.setIdleTimeoutMs(ms)` (default 60s),
`Server.setWriteTimeoutMs(ms)` (default 60s) and
`Server.setMaxRequestsPerConn(n)` (default 1000) bound what an idle, slow or
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
| a `BodyReader` neither read to the end nor closed | its connection and its `maxConnsPerHost` slot stay held - `close()` it |
| a `BodyReader` closed after a partial read | its connection is shut, never reused |
| a redirect to another host, port or scheme | `Authorization`, `Cookie`, `Proxy-Authorization` and `WWW-Authenticate` are dropped, defaults included |
| a redirect from `https` to `http` | the call fails - opt in with `RedirectAllow.Downgrade` |
| a `307` or `308` with a body to another origin | the call fails - opt in with `RedirectAllow.ReplayBody` |
| more redirects than the limit (10 default) | the call fails naming the limit and the last URL |
| `Server.setMaxBodyBytes(0)` or a zero `Limits` field to `parseMultipart` | refuses every body - `0` never means unlimited |
| a client offering ALPN `h2` against a server that shares no protocol | the handshake is aborted, never silently downgraded |
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

## Messages

### `Request`

A parsed HTTP request: `method`, `path`, the raw `headers` block, `body`, and
`peer` (the client's address, `""` when none is known). Read an individual
header with `header(req.headers, name)`.

### `Response`

An HTTP response: `status`, `contentType`, the raw `headers` block, and
`body`. The server fills in `Content-Length` and `Connection` for you. A
response a client returns also carries `url`, the address it finally came
from, and `redirects`, the number of redirects followed to get there. One
returned by `Client.send(req, stream = true)` has `reader`, an
`Option<BodyReader>` holding the unread body, and `body == ""`; on every other
response `reader` is `None`.

### `header(block: string, name: string): string`

The value of header `name` in a raw header block, or `""` if it is absent.

### `atoi(s: string): int`

The non-negative integer `s` names, or `-1` if `s` is not a valid one
(including a value too large to fit).

### `ok(body: string): Response`

A `200 OK` response carrying `body` as UTF-8 text.

### `respond(status: int, body: string): Response`

A response with an explicit status and a text body.

### `Response.setHeader(name: string, value: string): ()!`

Replaces header `name` with `value` on the way out. Fails on an invalid
name or a CR/LF/NUL in `value`.

### `Response.addHeader(name: string, value: string): ()!`

Appends another header `name: value` without removing an existing one of
the same name. Fails the same way `setHeader` does.

### `Response.getHeader(name: string): string`

The value already set for header `name` on this response, or `""` if none.

## Clients

### `get(url: string): Response!`

Fetches `url` over `http://` or `https://`.

### `post(url: string, body: string): Response!`

Sends `body` to `url` over `http://` or `https://`.

### `request(method: string, url: string, body: string): Response!`

Sends `method url` with an optional `body` and returns the response. An
`https://` URL runs over TLS 1.3; the server's certificate is verified
against the system trust store.

### `requestWith(method: string, url: string, headers: []Header, body: string): Response!`

As `request`, with extra `headers` attached: authentication, content type,
or anything custom. Fails before sending if a header is invalid or names one
this module manages itself.

### `getTimeout(url: string, timeoutMs: int): Response!`

As `get`, bounded by one deadline covering connect, send and read.

### `postTimeout(url: string, body: string, timeoutMs: int): Response!`

As `post`, bounded by one deadline covering connect, send and read.

### `requestTimeout(method: string, url: string, body: string, timeoutMs: int): Response!`

As `request`, bounded by one deadline covering connect, send and read.

### `getTls(url: string, config: TlsConfig): Response!`

As `get`, with an explicit [`std/tls`](tls.md) configuration: pin a CA, set a
`serverName`, or skip verification in a test.

### `postTls(url: string, body: string, config: TlsConfig): Response!`

As `post`, with an explicit TLS configuration.

### `requestTls(method: string, url: string, body: string, config: TlsConfig): Response!`

As `request`, with an explicit TLS configuration. Fails if `url` is not
`https`.

### `getStreaming(url: string, headers: []Header, sink: BodySink, maxBodyBytes: int): Response!`

Fetches `url`, delivering the response body to `sink` in bounded chunks
instead of returning it whole. `Response.body` is always `""`.

### `requestWithStreamingBody(method: string, url: string, headers: []Header, body: StreamBody): Response!`

Sends a request body pulled from `body.source` one chunk at a time and
returns the response: `Content-Length` framing when `body.length` is set,
`Transfer-Encoding: chunked` with the optional `body.trailers` when it is not.

### `StreamBody`

`StreamBody{ source: BodySource, length: Option<int>, trailers: Option<TrailerSource> }`:
the request body for `requestWithStreamingBody`. `length = Option.Some(n)`
declares exactly `n` bytes; leaving it out means unknown length. `trailers`
is only valid without a `length`.

### `TrailerSource`

A function `() => []Header!` called once, after the body source has returned
`""`; its fields form the trailer section.

### `BodySource`

A function `(int) => string!` that pulls up to `n` bytes of a request body
for `requestWithStreamingBody`; `""` marks the end.

### `BodySink`

A function `(string) => ()!` that receives one chunk of a response body at a
time for `getStreaming`, called repeatedly until the body is exhausted.

### `Client(tls: TlsConfig = ...)`

An HTTP client that reuses its configuration and connections across calls,
and remembers which servers have advertised HTTP/3.

`Client()` is secure by default: TLS verification on, system trust roots,
HTTP/2 offered. `Client(tls = config)` takes an explicit TLS configuration
for its `https://` calls, such as a pinned CA or a fixed server name.

### `Client.get(url: string): Response!`

As the package-level `get`, using this client's configuration and
connections.

### `Client.post(url: string, body: string): Response!`

As the package-level `post`, using this client's configuration.

### `Client.request(method: string, url: string, body: string): Response!`

As the package-level `request`, using this client's configuration.

### `Client.requestWith(method: string, url: string, headers: []Header, body: string): Response!`

As the package-level `requestWith`, using this client's configuration and
default headers.

### `Client.getTimeout(url: string, timeoutMs: int): Response!`

As `Client.get`, bounded by one deadline.

### `Client.postTimeout(url: string, body: string, timeoutMs: int): Response!`

As `Client.post`, bounded by one deadline.

### `Client.requestTimeout(method: string, url: string, body: string, timeoutMs: int): Response!`

As `Client.request`, bounded by one deadline.

### `ClientRequest`

A request for `Client.send`: `method` (`"GET"` by default), `url`, `headers`
(`[]Header`, layered onto the client's own as `Client.requestWith` does),
`body` (`""` by default) and `timeoutMs` (`0`, no bound, by default): the bound
in milliseconds on the connect, the response head and each body `read` of a
streamed response.

### `RequestError`

The error a request fails with once it reached the network layer: `sent`
(`bool`) is `true` when any byte of the request may have been written, `false`
when nothing was; `cause` (`error`) is the error underneath. `message()` is
the cause's text.

### `TimeoutError`

The error a streamed request fails with when `timeoutMs` ran out (as the `cause`
of a `RequestError` for `"send"`): `op` is
`"send"` (connect, request, head) or `"read"` (one `BodyReader.read`) and `ms`
the bound.

### `TimeoutError.message(): string`

`"http: send timed out after 500 ms"` or `"http: read timed out after 500 ms"`.

### `Client.send(req: ClientRequest, stream: bool = false): Response!`

As `Client.requestWith` for `req`. With `stream = true` it returns once the
response head has arrived: `status` and `headers` are set, `body` is `""` and
`reader` holds the `BodyReader` the body is pulled from. See [Reading a body
as it arrives](#reading-a-body-as-it-arrives) for what a streamed request
does and does not do.

### `BodyReader`

The unread body of a streamed response, from `Response.reader`. It owns an
open connection until the body ends, a read fails or `close()` is called.

### `BodyReader.read(max: int): []byte!`

Up to `max` bytes of the body, at least one, at most 65536; an empty slice only
at the end of the body, and again on every call after it. Fails, and closes the
connection, when the connection ends or breaks before the body does or the
framing is malformed, and on a read deadline (`TimeoutError`); every later call fails too. Fails after `close()`, and
for a `max` below 1 (leaving the reader as it was).

### `BodyReader.close()`

Shuts the connection if the body has not ended and makes every later `read`
fail. After a full read the connection is already back in the pool and `close()`
leaves it there. Calling it again does nothing.

### `PoolLimits`

The bounds of a `Client`'s connections: `maxIdlePerHost: int`
(2), `maxIdleTotal: int` (100), `idleTimeoutMs: int` (90000) and
`maxH2Streams: int` (100), the most requests in flight on one shared HTTP/2
connection, and `maxConnsPerHost: int` (0, unlimited), the most HTTP/1.1
connections open at once to one host. Every field has a default, so `PoolLimits{}` is the configuration `Client()` uses.

### `Client.setPool(limits: PoolLimits): ()!`

Replaces the client's pool bounds, closing the connections already idle. Fails
on a negative `maxIdlePerHost`, a `maxIdleTotal` below it, an `idleTimeoutMs`
that is not positive, or a negative `maxConnsPerHost`.

### `Client.close()`

Closes every idle connection the client holds. A request in flight finishes
and the client stays usable.

### `Client.setHeader(name: string, value: string): ()!`

Sets a default header sent with every call this client makes from now on.

### `Client.setMaxBodyBytes(n: int): ()`

Raises or lowers the response-size cap for this client, in bytes. There is
no value meaning unlimited; `0` refuses every body.

### `Redirects`

How a `Client` treats a `3xx` response: `Redirects.None` returns it as is,
`Redirects.Follow(n)` follows up to `n` redirects (the default is
`Redirects.Follow(10)`), and `Redirects.FollowAllowing(n, allow)` follows up
to `n` with the opt-ins in `allow`.

### `RedirectAllow`

What `Redirects.FollowAllowing` permits beyond the strict default:
`RedirectAllow.Downgrade` (https to http), `RedirectAllow.ReplayBody` (a
`307` or `308` body sent again to another origin) or `RedirectAllow.Both`.

### `Client.setRedirects(policy: Redirects)`

Sets how this client treats `3xx` responses from now on.

## Serving requests

### `Server`

A listening HTTP server, accepting connections without reading them. Spawn
a green thread per connection and call `Exchange.read()` there.

### `serve(host: string, port: int): Server!`

Binds `host:port` and starts listening. Pass `0` for `port` to let the
kernel choose one, then read it back with `Server.port()`.

### `Server.port(): int!`

The port this server is actually bound to.

### `Server.accept(): Exchange!`

Blocks until the next connection arrives and returns it, without reading
anything off it yet.

### `Server.close()`

Stops the server immediately.

### `Server.shutdown(timeoutMs: int): ()!`

Stops the server gracefully: drains requests already in flight, then
force-closes whatever is still running once `timeoutMs` elapses.

### `Server.setIdleTimeoutMs(ms: int)`

How long, in milliseconds, an idle keep-alive connection is kept open. The
default is 60 seconds.

### `Server.setWriteTimeoutMs(ms: int)`

How long, in milliseconds, writing one response may take before the server
closes the connection. A client that reads a large response slowly, or not
at all, otherwise holds the connection open without limit. The default is
60 seconds; raise it for a handler whose response legitimately takes longer
to deliver.

### `Server.setMaxRequestsPerConn(n: int)`

The most requests one keep-alive connection may serve before it is closed.
The default is 1000.

### `Server.setMaxBodyBytes(n: int)`

The largest request body this server accepts, in bytes. The default is 32
MiB; there is no value meaning unlimited, so `0` refuses every body with
`400` before it is read.

### `Exchange`

One accepted connection, before its request is read. Call `Exchange.read()`
on its own spawned green thread to get the request.

### `Exchange.read(): Request!`

Reads and parses the next request on this connection.

### `Exchange.respond(res: Response): ()!`

Sends `res` as the answer to the request this exchange read.

### `listenAndServe(host: string, port: int, handler: (Request) => Response): ()!`

Binds `host:port` and serves HTTP forever, dispatching every request to
`handler` on its own green thread. Returns only on a bind error.

### `listenAndServeOn(s: Server, handler: (Request) => Response): ()!`

As `listenAndServe`, on a `Server` you already bound with `serve`. Use this
when you need to know the bound port, such as a kernel-chosen one, before
serving starts.

## TLS (HTTPS) server

### `serveTls(host: string, port: int, certPem: string, keyPem: string, handler: (Request) => Response): ()!`

The TLS mirror of `listenAndServe`, using certificate chain `certPem` and
private key `keyPem` (both PEM). Also the HTTP/2 server: a client that
negotiates ALPN `h2` is served over HTTP/2 automatically.

### `serveTlsOn(listener: TlsListener, handler: (Request) => Response): ()!`

As `serveTls`, on an already-bound [`std/tls`](tls.md) `Listener`.

### `TlsServer`

A shutdown-capable TLS listener, the TLS mirror of `Server`.

### `tlsServe(host: string, port: int, certPem: string, keyPem: string): TlsServer!`

Binds `host:port` for TLS and returns a `TlsServer`. Drive it with
`serveTlsServerOn`.

### `serveTlsServerOn(ts: TlsServer, handler: (Request) => Response): ()!`

Serves HTTPS forever on `ts`, dispatching every request to `handler`.

### `TlsServer.port(): int!`

The port this TLS server is actually bound to.

### `TlsServer.setMaxBodyBytes(n: int)`

As `Server.setMaxBodyBytes`, for this TLS server.

### `TlsServer.shutdown(timeoutMs: int): ()!`

As `Server.shutdown`, for this TLS server.

### `TlsServer.attachH3(hs: H3Server)`

Pairs this TLS server with an `H3Server` so one `shutdown()` call drains
both.

## HTTP/3

Opt-in because QUIC needs UDP and a heavier handshake than plain TLS-over-TCP.

### `H3Server`

A shutdown-capable HTTP/3 server handle, bound with `h3Serve`.

### `H3Server.port(): int!`

The port this HTTP/3 server is actually bound to.

### `H3Server.shutdown(timeoutMs: int): ()!`

Stops this HTTP/3 server gracefully: drains requests already in flight,
then force-closes whatever is still running once `timeoutMs` elapses.

### `h3Serve(host: string, port: int, certPem: string, keyPem: string): H3Server!`

Binds `host:port` (UDP) for HTTP/3 and returns a shutdown-capable handle.
Drive it with `serveH3ServerOn`.

### `serveH3ServerOn(hs: H3Server, handler: (Request) => Response): ()!`

Serves HTTP/3 forever on `hs`, dispatching every request to `handler`. Run
this on its own green thread.

### `serveH3(host: string, port: int, certPem: string, keyPem: string, handler: (Request) => Response): ()!`

Binds `host:port` (UDP) and serves HTTP/3 forever. Run on its own green
thread, paired with a `serveTls` server on the same port so `https://`
clients can discover and upgrade to it.

### `serveH3On(sock: UdpSocket, certPem: string, keyPem: string, handler: (Request) => Response): ()!`

As `serveH3`, on an already-bound UDP socket. Use this to learn the bound
port before serving starts.

## Hijacking a connection (protocol upgrades)

For a handler that must take over the raw connection - a WebSocket upgrade,
for instance ([`std/websocket`](websocket.md) is built on this).

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

### `serveHijackableTlsOn(ts: TlsServer, hijackHandler: (Request, TlsExchange) => HijackOutcome, plainHandler: (Request) => Response): ()!`

The hijack-capable sibling of `serveTlsServerOn`. `hijackHandler` serves
HTTP/1.1 connections and may take one over; `plainHandler` serves every
HTTP/2 connection, which cannot be hijacked.

### `serveHijackableTlsBackground(ts: TlsServer, hijackHandler: (Request, TlsExchange) => HijackOutcome, plainHandler: (Request) => Response): ()`

As `serveHijackableTlsOn`, run in the background.

### `byteStream`

The transport-agnostic read/write interface a hijacked connection speaks,
whether it came from a plain or a TLS connection.

### `ByteStream(conn: Option<Conn> = None, tls: Option<TlsConn> = None): ByteStream!`

Wraps a connection you already hold as a `byteStream`, for code that has no
`Exchange` to ask for one. `ByteStream(conn = Option.Some(c))?` takes a plain
[`std/net`](net.md) connection and `ByteStream(tls = Option.Some(t))?` a
`std/tls` one. Give exactly one: passing both, or neither, fails with an error
instead of picking one for you.

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

The peer's IPv4 address in dotted form, or `""` when the connection cannot name
one.

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

## Request headers you build

### `Header`

One outgoing header: a `name` and a `value`, validated before it reaches the
wire.

### `serializeHeaders(headers: []Header): string!`

Validates `headers` and joins them into the raw wire block. Fails on the
first invalid header, with no partial result.

### `validateHeaderName(name: string): ()!`

Fails unless `name` is a legal header name.

### `validateHeaderValue(value: string): ()!`

Fails if `value` contains a raw CR, LF or NUL.

## Query strings

`Request.path` is the raw, still percent-encoded request target.

### `splitTarget(target: string): (string, string)`

Splits a request target at its first `?` into `(path, rawQuery)`. A target
with no `?` returns the whole target as the path and `""` as the query.

### `parseQuery(raw: string): map<string, string>`

Parses a raw query string, as returned by `splitTarget`, into decoded keys
and values. A duplicate key keeps the last value.

### `percentDecode(s: string): string`

Percent-decodes `s`: `%XX` becomes a byte, `+` becomes a space. A malformed
escape passes through unchanged rather than failing.

### `percentEncode(s: string): string`

Percent-encodes every byte of `s` that is not safe to put directly in a URL.
The inverse of `percentDecode` for building a query value.

```bit
import { splitTarget, parseQuery } from "std/http"

fn queryFor(target: string): map<string, string> {
  let (_, rawQuery) = splitTarget(target)
  return parseQuery(rawQuery)
}
```

## Multipart form uploads

`parseMultipart` turns a `Request.body` into named fields and named file
parts. Every `Limits` field is required, and a zero limit rejects everything
that would use it - it never means unlimited, because the body is
attacker-controlled. A file's declared `filename` and `contentType` are
returned exactly as received and are never sanitised: joining `filename` to
a path is the caller's decision to make deliberately.

### `Limits`

The size and count bounds `parseMultipart` enforces: `maxBodyBytes`,
`maxFileBytes`, `maxParts`, `maxHeaderLineBytes`, and `maxPartHeaderBytes`.

### `defaultLimits(): Limits`

Reasonable defaults for an ordinary web upload form.

### `Form`

The result of a successful `parseMultipart`: every text field and file part,
in the order they appeared.

### `parseMultipart(body: []byte, boundary: string, limits: Limits): Form!`

Parses `body` as a multipart form message delimited by `boundary`, the value
of the request's `Content-Type: multipart/form-data; boundary=...`
parameter without the leading `--`. Fails with no partial `Form` on the
first problem, such as an over-limit body, file, or part count.

### `Form.value(name: string): string`

The value of the first text field named `name`, or `""` if absent.

### `Form.file(name: string): FormFile!`

The first file part named `name`. Fails if there is none.

### `FormField`

One text field: its form `name` and `value`, exactly as sent.

### `FormFile`

One file part: its form `name`, the sender's declared `filename` and
`contentType`, and the raw file `content`. `filename` and `contentType` are
untrusted input, returned exactly as received.

### `multipartField(body: []byte, boundary: string, name: string, limits: Limits): (string, bool)!`

The value of the first text field named `name` in `body`, and whether such a
field was present at all, without building a whole `Form`. Cheaper than
`parseMultipart` when you only need one field out of a large upload.

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
