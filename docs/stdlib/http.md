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

See the [full section](http/requests.md#making-requests).
### Sending a body of unknown length

See the [full section](http/requests.md#sending-a-body-of-unknown-length).
### Reading a body as it arrives

See the [full section](http/requests.md#reading-a-body-as-it-arrives).
### Cancelling a request

See the [full section](http/requests.md#cancelling-a-request).
### A client that reuses connections

See the [full section](http/requests.md#a-client-that-reuses-connections).
### Keeping connections between requests

See the [full section](http/requests.md#keeping-connections-between-requests).
#### Sharing one HTTP/2 connection

See the [full section](http/requests.md#sharing-one-http-2-connection).
#### Sharing one HTTP/3 connection

See the [full section](http/requests.md#sharing-one-http-3-connection).
### Following redirects

See the [full section](http/requests.md#following-redirects).
### Retrying a request that failed

See the [full section](http/requests.md#retrying-a-request-that-failed).
## Serving requests: the basics

See the [full section](http/requests.md#serving-requests-the-basics).
## Building a web app

See the [full section](http/requests.md#building-a-web-app).
## Sharp edges

See the [full section](http/requests.md#sharp-edges).

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

See the [full section](http/clients.md#clients).
### `get(url: string): Response!`

See the [full section](http/clients.md#get-url-string-response).
### `post(url: string, body: string): Response!`

See the [full section](http/clients.md#post-url-string-body-string-response).
### `request(method: string, url: string, body: string): Response!`

See the [full section](http/clients.md#request-method-string-url-string-body-string-response).
### `requestWith(method: string, url: string, headers: []Header, body: string): Response!`

See the [full section](http/clients.md#requestwith-method-string-url-string-headers-header-body-string-response).
### `getTimeout(url: string, timeoutMs: int): Response!`

See the [full section](http/clients.md#gettimeout-url-string-timeoutms-int-response).
### `postTimeout(url: string, body: string, timeoutMs: int): Response!`

See the [full section](http/clients.md#posttimeout-url-string-body-string-timeoutms-int-response).
### `requestTimeout(method: string, url: string, body: string, timeoutMs: int): Response!`

See the [full section](http/clients.md#requesttimeout-method-string-url-string-body-string-timeoutms-int-response).
### `getTls(url: string, config: TlsConfig): Response!`

See the [full section](http/clients.md#gettls-url-string-config-tlsconfig-response).
### `postTls(url: string, body: string, config: TlsConfig): Response!`

See the [full section](http/clients.md#posttls-url-string-body-string-config-tlsconfig-response).
### `requestTls(method: string, url: string, body: string, config: TlsConfig): Response!`

See the [full section](http/clients.md#requesttls-method-string-url-string-body-string-config-tlsconfig-response).
### `getStreaming(url: string, headers: []Header, sink: BodySink, maxBodyBytes: int): Response!`

See the [full section](http/clients.md#getstreaming-url-string-headers-header-sink-bodysink-maxbodybytes-int-response).
### `requestWithStreamingBody(method: string, url: string, headers: []Header, body: StreamBody): Response!`

See the [full section](http/clients.md#requestwithstreamingbody-method-string-url-string-headers-header-body-streambody-response).
### Wait before uploading a draft

Set `Expect: 100-continue` when you want the server to reject an upload before
reading its body. A final response returns without calling your source. A `100`
response starts the upload. A silent server starts it after 1000 ms by default.
Set `StreamBody.expectContinueTimeoutMs` to another non-negative wait; zero sends
immediately. An out-of-range value fails with
`StreamBody.expectContinueTimeoutMs is out of range`.

```bit
import { Header, StreamBody, requestWithStreamingBody } from "std/http"

fn uploadDraft(url: string): int! {
  let draft = "A new Inkwell draft"
  let pos = 0
  let body = StreamBody{
    length = Option.Some(len(draft)),
    expectContinueTimeoutMs = 250,
    source = (n) => {
      let end = pos + n
      if (end > len(draft)) { end = len(draft) }
      let part = draft[pos:end]
      pos = end
      return part
    },
  }
  let res = requestWithStreamingBody(
    "PUT", url, [Header{ name = "Expect", value = "100-continue" }], body,
  )?
  return res.status
}
```

### `StreamBody`

See the [full section](http/clients.md#streambody).
### `TrailerSource`

See the [full section](http/clients.md#trailersource).
### `BodySource`

See the [full section](http/clients.md#bodysource).
### `BodySink`

See the [full section](http/clients.md#bodysink).
### `Client(tls: TlsConfig = ...)`

See the [full section](http/clients.md#client-tls-tlsconfig).
### `Client.get(url: string): Response!`

See the [full section](http/clients.md#client-get-url-string-response).
### `Client.post(url: string, body: string): Response!`

See the [full section](http/clients.md#client-post-url-string-body-string-response).
### `Client.request(method: string, url: string, body: Body, timeoutMs: int = 0): Response!`

See the [full section](http/clients.md#client-request-method-string-url-string-body-body-timeoutms-int-0-response).
### `Body`

See the [full section](http/clients.md#body).
### `Client.requestWith(method: string, url: string, headers: []Header, body: string): Response!`

See the [full section](http/clients.md#client-requestwith-method-string-url-string-headers-header-body-string-response).
### `Client.getTimeout(url: string, timeoutMs: int): Response!`

See the [full section](http/clients.md#client-gettimeout-url-string-timeoutms-int-response).
### `Client.postTimeout(url: string, body: string, timeoutMs: int): Response!`

See the [full section](http/clients.md#client-posttimeout-url-string-body-string-timeoutms-int-response).
### `Client.requestTimeout(method: string, url: string, body: string, timeoutMs: int): Response!`

See the [full section](http/clients.md#client-requesttimeout-method-string-url-string-body-string-timeoutms-int-response).
### `ClientRequest`

See the [full section](http/clients.md#clientrequest).
### `RequestError`

See the [full section](http/clients.md#requesterror).
### `RequestError.message(): string`

See the [full section](http/clients.md#requesterror-message-string).
### `TimeoutError`

See the [full section](http/clients.md#timeouterror).
### `TimeoutError.message(): string`

See the [full section](http/clients.md#timeouterror-message-string).
### `Cancel`

See the [full section](http/clients.md#cancel).
### `Cancel.cancel()`

See the [full section](http/clients.md#cancel-cancel).
### `Cancel.cancelled(): bool`

See the [full section](http/clients.md#cancel-cancelled-bool).
### `Cancelled`

See the [full section](http/clients.md#cancelled).
### `Cancelled.message(): string`

See the [full section](http/clients.md#cancelled-message-string).
### `isCancelled(e: error): bool`

See the [full section](http/clients.md#iscancelled-e-error-bool).
### `Client.send(req: ClientRequest, stream: bool = false): Response!`

See the [full section](http/clients.md#client-send-req-clientrequest-stream-bool-false-response).
### `BodyReader`

See the [full section](http/clients.md#bodyreader).
### `BodyReader.read(max: int): []byte!`

See the [full section](http/clients.md#bodyreader-read-max-int-byte).
### `BodyReader.close()`

See the [full section](http/clients.md#bodyreader-close).
### `PoolLimits`

See the [full section](http/clients.md#poollimits).
### `Client.setPool(limits: PoolLimits): ()!`

See the [full section](http/clients.md#client-setpool-limits-poollimits).
### `Client.close()`

See the [full section](http/clients.md#client-close).
### `Client.setHeader(name: string, value: string): ()!`

See the [full section](http/clients.md#client-setheader-name-string-value-string).
### `Client.setMaxBodyBytes(n: int): ()`

See the [full section](http/clients.md#client-setmaxbodybytes-n-int).
### `Redirects`

See the [full section](http/clients.md#redirects).
### `RedirectAllow`

See the [full section](http/clients.md#redirectallow).
### `Client.setRedirects(policy: Redirects)`

See the [full section](http/clients.md#client-setredirects-policy-redirects).

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

## Parse a WebSocket endpoint

### `parseWebSocketUrl(url: string): (string, int, string, bool, string)!`

When an Inkwell client needs to inspect a WebSocket endpoint before it connects,
`parseWebSocketUrl(url)` returns `(host, port, resource, secure, authority)`.
The host is bare for dialing; the authority keeps IPv6 brackets and includes
the port for the Host header. `ws` and `wss` are case-insensitive, default to
ports 80 and 443, and default an empty resource to `/`. Query-only resources
start with `/?`. Userinfo, raw fragments, control bytes, spaces and invalid
hosts or ports fail. This parser does not change HTTP URL parsing.

```bit
import { parseWebSocketUrl } from "std/http"

fn main(): ()! {
  let (host, port, resource, secure, authority) = parseWebSocketUrl("wss://[::1]:9443/notes?draft=1")?
  assert(host == "::1" && port == 9443 && resource == "/notes?draft=1", "notes endpoint")
  assert(secure && authority == "[::1]:9443", "TLS authority")
}
```

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

See the [full section](http/upgrades.md#hijacking-a-connection-protocol-upgrades).
### `HijackOutcome`

See the [full section](http/upgrades.md#hijackoutcome).
### `serveHijackableOn(s: Server, handler: (Request, Exchange) => HijackOutcome): ()!`

See the [full section](http/upgrades.md#servehijackableon-s-server-handler-request-exchange-hijackoutcome).
### `serveHijackableBackground(s: Server, handler: (Request, Exchange) => HijackOutcome): ()`

See the [full section](http/upgrades.md#servehijackablebackground-s-server-handler-request-exchange-hijackoutcome).
### `Exchange.hijack(): Conn`

See the [full section](http/upgrades.md#exchange-hijack-conn).
### `Exchange.hijackStream(): byteStream`

See the [full section](http/upgrades.md#exchange-hijackstream-bytestream).
### `Exchange.respondKeepAlive(req: Request, res: Response, mustCloseNow: bool): bool!`

See the [full section](http/upgrades.md#exchange-respondkeepalive-req-request-res-response-mustclosenow-bool-bool).
### `TlsExchange`

See the [full section](http/upgrades.md#tlsexchange).
### `TlsExchange.read(): Request!`

See the [full section](http/upgrades.md#tlsexchange-read-request).
### `TlsExchange.respond(res: Response): ()!`

See the [full section](http/upgrades.md#tlsexchange-respond-res-response).
### `TlsExchange.hijack(): TlsConn`

See the [full section](http/upgrades.md#tlsexchange-hijack-tlsconn).
### `TlsExchange.hijackStream(): byteStream`

See the [full section](http/upgrades.md#tlsexchange-hijackstream-bytestream).
### `TlsExchange.respondKeepAlive(req: Request, res: Response, mustCloseNow: bool): bool!`

See the [full section](http/upgrades.md#tlsexchange-respondkeepalive-req-request-res-response-mustclosenow-bool-bool).
### `TlsServer.accept(): TlsExchange!`

See the [full section](http/upgrades.md#tlsserver-accept-tlsexchange).
### `serveHijackableTlsOn(ts: TlsServer, hijackHandler: (Request, TlsExchange) => HijackOutcome, plainHandler: (Request) => Response, tunnel: Option<(Request, Stream) => Response> = Option.None): ()!`

See the [full section](http/upgrades.md#servehijackabletlson-ts-tlsserver-hijackhandler-request-tlsexchange-hijackoutcome-plainhandler-request-response-tunnel-option-request-stream-response-option-none).
### `serveHijackableTlsBackground(ts: TlsServer, hijackHandler: (Request, TlsExchange) => HijackOutcome, plainHandler: (Request) => Response, tunnel: Option<(Request, Stream) => Response> = Option.None): ()`

See the [full section](http/upgrades.md#servehijackabletlsbackground-ts-tlsserver-hijackhandler-request-tlsexchange-hijackoutcome-plainhandler-request-response-tunnel-option-request-stream-response-option-none).
### `byteStream`

See the [full section](http/upgrades.md#bytestream).
### `StreamSource`

See the [full section](http/upgrades.md#streamsource).

<a id="bytestream-conn-option-conn-none-tls-option-tlsconn-none-h2-option-h2stream-none-bytestream"></a>

### `ByteStream(source: StreamSource): ByteStream`

See the [full section](http/upgrades.md#bytestream-source-streamsource-bytestream).
### `ByteStream.readUp(n: int): string!`

See the [full section](http/upgrades.md#bytestream-readup-n-int-string).
### `ByteStream.writeStr(s: string): ()!`

See the [full section](http/upgrades.md#bytestream-writestr-s-string).
### `ByteStream.writeBytes(b: []byte): ()!`

See the [full section](http/upgrades.md#bytestream-writebytes-b-byte).
### `ByteStream.shut()`

See the [full section](http/upgrades.md#bytestream-shut).
### `ByteStream.forceClose()`

See the [full section](http/upgrades.md#bytestream-forceclose).
### `ByteStream.peer(): string`

See the [full section](http/upgrades.md#bytestream-peer-string).
### `ByteStream.unread(extra: string)`

See the [full section](http/upgrades.md#bytestream-unread-extra-string).
### `ByteStream.setIdleDeadline(deadlineNs: int)`

See the [full section](http/upgrades.md#bytestream-setidledeadline-deadlinens-int).

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

## Writing a multipart form

Uploading a file, or posting a form that carries one, needs a
`multipart/form-data` body: parts separated by a boundary that must not
occur in any of them. `FormBuilder` writes that body and the `Content-Type`
that names the boundary, and what it writes is what `parseMultipart` reads
back byte for byte.

### `FormBuilder`

A body being assembled. `FormBuilder()` is empty. Parts are written in the
order they are added and a name may repeat, as the wire format allows.

### `FormBuilder.field(name: string, value: string): ()!`

Adds a text field. Inside the quoted `name`, a `"` and a `\` are written
behind a `\` (RFC 7578 section 4.2, the quoted-pair the parser reads). A CR, a
LF or a NUL in `name` cannot be quoted and would end the header line, so
`field` fails on one.

### `FormBuilder.file(name: string, filename: string, contentType: string, content: []byte): ()!`

Adds a file part announced as `filename` and declared as `contentType`
(`application/octet-stream` when empty), holding `content` exactly. `content`
is kept as it is, not copied, until `build` copies it into the body, so do not
change it before then. `name` and `filename` are quoted as in `field`; `file`
fails on a CR, a LF or a NUL in `name`, `filename` or `contentType`.

### `FormBuilder.build(): FormBody!`

Returns the body and its `Content-Type`. The boundary is `bit-form-` and 128
bits from the system CSPRNG in hex, drawn again for every `build`, and it is
searched for in every part's headers and content: a candidate that occurs in
a part is dropped for the next, and eight in a row fail the build. The body
is written into one buffer allocated at its final size, and each part's bytes
are copied into it once: a 25 MiB file costs 25 MiB, not three times that.
Fails when nothing was added.

### `FormBody`

What `build` returns: `contentType`, the value of the request's
`Content-Type` header with the boundary in it, and `body`, a `[]byte` that
`Client.request` sends as it is in a `Body.Bytes`.

```bit
import { Body, Client, FormBuilder, Response, Form, parseMultipart, defaultLimits } from "std/http"
import { indexOf } from "std/strings"

fn upload(url: string, avatar: []byte): Response! {
  let form = FormBuilder()
  form.field("user", "ada")?
  form.file("avatar", "ada.png", "image/png", avatar)?
  let out = form.build()?
  let c = Client()
  c.setHeader("Content-Type", out.contentType)?
  return c.request("POST", url, Body.Bytes(out.body))?
}

// The server's side of the same body: `boundary=` is the last part of
// `contentType`.
fn readBack(avatar: []byte): Form! {
  let form = FormBuilder()
  form.file("avatar", "ada.png", "image/png", avatar)?
  let out = form.build()?
  let at = indexOf(out.contentType, "boundary=")
  return parseMultipart(out.body, out.contentType[at + 9:], defaultLimits())?
}
```

## Where to go next

- Building routes, JSON bodies and middleware on top of this: [pkg/web](/packages/web) and [the Book's web course](/book/14-first-endpoint).
- Certificates, trust stores and dialing TLS directly: [std/tls](tls.md).
- Framing your own protocol over a hijacked connection: [std/websocket](websocket.md).
