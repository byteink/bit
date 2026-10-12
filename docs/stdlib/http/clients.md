# HTTP client reference

Choose a client call for the body and deadline your service needs.
Start with the [request guide](requests.md) for complete examples, then use
this reference to configure pooling, redirects, cancellation and streaming.

See the [HTTP overview and server reference](../http.md) and
[protocol upgrades](upgrades.md).

<!-- doctest: per-block -->

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

As `get`, with an explicit [`std/tls`](../tls.md) configuration: pin a CA, set a
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

### `Client.request(method: string, url: string, body: Body, timeoutMs: int = 0): Response!`

As the package-level `request`, using this client's configuration, with the
body typed: `Body.Text(s)` for a string, `Body.Bytes(b)` for bytes sent as
they are. A `timeoutMs` above 0 bounds the whole request as
`Client.requestTimeout` does.

### `Body`

A request body for `Client.request`: `Text(string)`, or `Bytes([]byte)`,
which is never copied, so a large upload such as a `FormBody.body` costs no
memory beyond itself. The slice is the caller's: it must not change until
the request returns.

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
`body` (`""` by default), `timeoutMs` (`0`, no bound, by default): the bound
in milliseconds on the connect, the response head and each body `read` of a
streamed response, and `cancel` (`Option<Cancel>`, none by default): the token
that stops the request from another task. See [Cancelling a
request](requests.md#cancelling-a-request).

### `RequestError`

The error a request fails with once it reached the network layer: `sent`
(`bool`) is `true` when any byte of the request may have been written, `false`
when nothing was; `cause` (`error`) is the error underneath.

### `RequestError.message(): string`

The cause's text, unchanged: a `RequestError` around a refused connect reads
exactly as the connect error does.

### `TimeoutError`

The error a streamed request fails with when `timeoutMs` ran out (as the `cause`
of a `RequestError` for `"send"`): `op` is
`"send"` (connect, request, head) or `"read"` (one `BodyReader.read`) and `ms`
the bound.

### `TimeoutError.message(): string`

`"http: send timed out after 500 ms"` or `"http: read timed out after 500 ms"`.

### `Cancel`

The cancellation token, made with `Cancel()`. Set it on `ClientRequest.cancel`
and call `cancel()` from any task to fail every request that holds it. One-shot:
a cancelled token stays cancelled.

### `Cancel.cancel()`

Cancels every request holding the token, whatever phase it is in, and every
later one. Shuts their connections, which never return to a pool. Safe from any
task and idempotent; does not block.

### `Cancel.cancelled(): bool`

Whether `cancel()` has been called.

### `Cancelled`

The error a cancelled request fails with, as the `cause` of a `RequestError` for
`Client.send` and bare for `BodyReader.read`: `op` is `"send"` (connect,
handshake, request, head) or `"read"` (one `BodyReader.read`).

### `Cancelled.message(): string`

`"http: send cancelled"` or `"http: read cancelled"`.

### `isCancelled(e: error): bool`

Whether `e` is a `Cancelled`, bare or the `cause` of a `RequestError`.

### `Client.send(req: ClientRequest, stream: bool = false): Response!`

As `Client.requestWith` for `req`. With `stream = true` it returns once the
response head has arrived: `status` and `headers` are set, `body` is `""` and
`reader` holds the `BodyReader` the body is pulled from. See [Reading a body
as it arrives](requests.md#reading-a-body-as-it-arrives) for what a streamed request
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
