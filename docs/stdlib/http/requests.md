# Make and serve HTTP requests

Call another service, stream a large body, or answer a request with a handler.
Choose a deadline and decide who closes each connection before it stays open.

See the [HTTP overview and server reference](../http.md),
[client reference](clients.md), and [protocol upgrades](upgrades.md).

<!-- doctest: per-block -->

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
| `getTls` / `postTls` / `requestTls(..., config: TlsConfig)` | pin a CA, a `serverName`, or skip verification in a test - see [`std/tls`](../tls.md) |

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

### Cancelling a request

A timeout answers "the server took too long". Sometimes the reason to stop is
yours: the reader closed the tab, the export a page asked for is no longer
wanted, a sibling upload failed and its other parts are now wasted work.
`Cancel` is the token for that, the same shape as Go's `context.WithCancel`,
.NET's `CancellationToken` and fetch's `AbortSignal`. Put one on
`ClientRequest.cancel`, hand the same token to another task, and `cancel()`
from there fails the request at once, in whichever phase it is waiting:

```bit
import { Client, ClientRequest, Cancel, isCancelled } from "std/http"
import { sleep } from "std/time"

// Calls `stop.cancel()` after `ms` milliseconds.
fn stopAfter(stop: Cancel, ms: int) {
  sleep(ms * 1000000)
  stop.cancel()
}

// The text of Inkwell's export at `url`, or "" when it was cancelled first.
fn fetchExport(c: Client, url: string, stop: Cancel): string! {
  let res = c.send(ClientRequest{ url = url, cancel = Option.Some(stop) }) catch e {
    if (isCancelled(e)) {
      return ""
    }
    fail e
  }
  return res.body
}

fn main() {
  let stop = Cancel()
  spawn stopAfter(stop, 5000)
  let text = fetchExport(Client(), "http://127.0.0.1:8080/export", stop) catch _ {
    return
  }
  println("${len(text)} bytes")
}
```

The request fails within one scheduler turn of the `cancel()` call, not after
the server's next byte: while the connection is being made, during the TLS
handshake, while the response head is awaited, and in the middle of a body. A
buffered `send` fails with a `RequestError` whose `cause` is a `Cancelled`
(`sent` says whether the server may have the request), and a streamed one is
the same until the head has arrived. After that, the pending `BodyReader.read`
fails with the bare `Cancelled`, whose `op` is `"read"`:

```bit
import { Client, ClientRequest, Cancel, Cancelled } from "std/http"

// How many bytes of `url`'s body arrived before `stop` was cancelled.
fn countUntilStopped(c: Client, url: string, stop: Cancel): int! {
  let res = c.send(ClientRequest{ url = url, cancel = Option.Some(stop) }, stream = true)?
  let body = unwrap(res.reader)
  defer body.close()
  let total = 0
  while (!stop.cancelled()) {
    let piece = body.read(65536) catch e {
      let (ce, ok) = e.(Cancelled)
      if (ok && ce.op == "read") {
        return total
      }
      fail e
    }
    if (len(piece) == 0) {
      return total
    }
    total = total + len(piece)
  }
  return total
}
```

`isCancelled(e)` is true for both shapes, so one check covers a request and
its reader. A cancelled body never reads as a complete, shorter one: a
read-to-close response cut by the cancel fails too. The connection a cancel
touched is shut and never returns to the client's pool.

A token is one-shot and `cancel()` is safe to call again and from any task. One
token can be on any number of requests (an upload's parts, say) and stops all
of them. A token cancelled before `send` fails the request before anything is
dialed, with `sent` false. A request that already finished is unaffected: its
connection stays pooled.

A buffered request with a token negotiates HTTP/2 like any other and shares the
origin's h2 connection. `cancel()` resets only that request's stream with
`RST_STREAM` (`CANCEL`, 0x8), fails it with `Cancelled`, and leaves the
connection and the other requests on it running; frames the server had already
sent for the stream are ignored. A request on HTTP/3 (an `https+h3://` URL, an
Alt-Svc upgrade, or a redirect to one) is aborted the same way: `cancel()` resets
only that request's QUIC stream with `RESET_STREAM` and `STOP_SENDING` carrying
`H3_REQUEST_CANCELLED` (0x010c) and fails it with `Cancelled`, and a cancel
during the QUIC handshake fails it too. A streamed request (`stream = true`) is
HTTP/1.1 only.

A `send` that waits for a free connection because the host is at
`maxConnsPerHost` is woken by `cancel()` too: it fails with `Cancelled`, `sent`
false, before it dials.

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
timeout (`getTimeout`, `requestTimeout`) or at its `Cancel`; a request with
neither waits as long as it takes. A request that times out in the queue fails with `http:
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
dialed. HTTP/3 connections are pooled the same way, see below.

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

#### Sharing one HTTP/3 connection

An `https+h3://` origin is shared like an h2 one: the pool keeps one QUIC
connection per origin and TLS configuration, and every request to it is a
stream on that connection. Three requests in a row, or eight at once, make one
QUIC handshake, not one each. Dials to an origin are one at a time, so a burst
dials once.

A connection leaves the pool, and its requests already running on it finish
first, when the server sends `GOAWAY`, when the QUIC connection ends (the peer
closed it, or its idle timeout passed), when it has been idle for
`idleTimeoutMs`, when a request on it fails for any reason but a `Cancel` or a
deadline, and when `close()` or `setPool` retires it. The server's limit on
open streams is honoured: a request that finds the connection at that limit
opens a stream on a second connection instead, which becomes the shared one, and
since nothing was sent on the first, it is repeated there whatever its method.
A `Cancel` or a request deadline aborts only that request's stream. The
connection and the other streams on it run on. `maxIdlePerHost = 0` turns
sharing off for HTTP/3 as well.

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
strings](../http.md#query-strings) below), `headers` as a raw block read with
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
| `Cancel.cancel()` on a request in flight | it fails with `Cancelled`; an HTTP/1.1 connection is shut and never pooled, an h2 stream or an h3 stream is reset and its connection stays shared |
| a redirect to another host, port or scheme | `Authorization`, `Cookie`, `Proxy-Authorization` and `WWW-Authenticate` are dropped, defaults included |
| a redirect from `https` to `http` | the call fails - opt in with `RedirectAllow.Downgrade` |
| a `307` or `308` with a body to another origin | the call fails - opt in with `RedirectAllow.ReplayBody` |
| more redirects than the limit (10 default) | the call fails naming the limit and the last URL |
| `Server.setMaxBodyBytes(0)` or a zero `Limits` field to `parseMultipart` | refuses every body - `0` never means unlimited |
| a client offering ALPN `h2` against a server that shares no protocol | the handshake is aborted, never silently downgraded |
| `req.peer` on a hand-built `Request`, or one whose connection died early | `""`, never a placeholder address |
