# Operational middleware

<!-- doctest: per-block -->

Rate limiting, serving static files, compression, request logging, tracing
and panic recovery - the middleware that shapes how an app behaves in
production rather than what it answers.

## Rate limiting

```bit
import { App, Limit, MemoryCounter, byIp, rateLimit } from "web"

fn mount(app: App) {
  let counter = MemoryCounter(10_000)
  app.use(rateLimit(Limit{ requests = 100, window = 60, by = byIp, store = counter }))
}
```

Every request the limiter serves carries `RateLimit-Limit`,
`RateLimit-Remaining` and `RateLimit-Reset` (the IETF draft names). A refused
request is `429` with `Retry-After`, in seconds, and no body.

**You supply the counter store; there is no default.** `Limit.store` panics
at registration when it is absent, the same rule as `Config.sessions`: an
in-process counter is correct on one server and silently wrong behind a load
balancer, where each of N servers permits the whole quota and a limit of 100
becomes 100N with nothing anywhere to indicate it. `MemoryCounter(maxKeys)`
ships and is single-process only; a store shared across processes implements
`RateStore` (`incr`/`count` - `INCR` plus `GET`, so a plain key-value store
implements it with no server-side script).

`maxKeys` bounds memory, not the limit: past the cap an `incr` evicts the
soonest-expiring window and never fails - the evicted key starts a fresh
quota, which is the over-permissive direction and is deliberate. A limiter
that refused requests when its own store filled up would turn a full map
into an outage of the app it protects.

The window is two adjacent fixed buckets, the older weighted by how much of
it is still inside the trailing window - a plain fixed window lets a client
spend the whole quota in the last instant of one window and the whole quota
again in the first instant of the next.

Keying options for `by`:

| `by` | keyed on | reads a header |
|---|---|---|
| `byIp` | `c.peer()`, the socket address | no |
| `bySession` | the session id, or `c.peer()` with no established session | no |
| `byForwardedIp(hops)` | `X-Forwarded-For`, `hops` entries from the trusted end | yes, deliberately |

`byIp` is the default choice. Behind a reverse proxy it is the proxy's
address, so every client behind that proxy shares one bucket - which is why
`byForwardedIp(hops)` exists. `hops` is the number of proxies between the
client and this server: with `hops: 2` and a chain
`client -> P1 -> P2 -> app`, the client sits at `len - hops` in the header's
list and everything an attacker prepended sits to the left of it, unable to
move it. Counting from the left instead is the classic vulnerability. A list
shorter than `hops` falls back to `c.peer()` rather than to anything the
header claimed.

A store outage is logged through `Config.logger` and the request is **served**
- failing closed would turn a counter outage into an outage of the app the
limiter protects. Two registrations with the same policy, store and key
function share one bucket; set `name` on `Limit` to keep two limiters apart
on one store.

## Static files

```bit
import { App, static } from "web"

fn mount(app: App) {
  app.use(static("/assets", "./public"))
}
```

Mounted with `app.use`, not a route, so `GET /assets/app.css` serves
`./public/app.css` with nothing registered on the router. Path traversal is
the whole reason this ships: every component below the served root is
checked with an `lstat`, not just a lexical string check, because a pure
string function cannot see a symlink.

A `Range: bytes=start-end` request comes back `206 Partial Content` with a
`Content-Range` header and exactly the requested bytes, seeked and read
straight off disk at that offset - the read stays proportional to the range,
never to the whole file, which is what makes a browser's video scrub bar or
a resumable download work against a multi-gigabyte file with no more memory
than the chunk it asked for. A range past the end of the file is `416 Range
Not Satisfiable` with `Content-Range: bytes */<size>`. `If-Range` is
honoured - a stale `ETag` or `Last-Modified` falls back to the full `200`,
the same rule a conditional GET already follows - and every response this
middleware serves carries `Accept-Ranges: bytes`. A request naming more than
one range falls back to a full `200` instead of the multi-range reply the
HTTP standard allows, since no mainstream client asks for more than one
range at a time.

`fileRes(path, c)` is the same Range/conditional-GET machinery for a single,
already-authorized file a route handler decides to serve - see
[The response](response.md) for it.

## Compression

`compress()` gzips the response body when the client's `Accept-Encoding`
allows it, the response carries no `Content-Encoding` already, the body is
big enough that compressing is a net win, and the `Content-Type` is on an
allowlist of types that actually compress.

## Logging

`logger()` writes one `INFO` record per request through `Config.logger`
(`getDefault()` when unset): `method`, `path` (the matched route pattern, not
the raw path), `status`, and `took`, a `Duration` for the downstream chain.
Four attributes and nothing else: the framework's default record cannot leak
a credential into a file that ships to a third-party aggregator. A request
whose chain failed carries `failed=true` instead of `status`. See
[Configuration](configuration.md#logging) for choosing the handler.

## Tracing

`tracing(tr)` opens one span per request on a `std/trace` `Tracer`,
continuing an inbound W3C `traceparent` when the request carries a valid one
and starting a fresh trace otherwise, and closes the span with the response
status whether the handler returns, fails, or panics. It takes the `Tracer`
explicitly - `std/trace` ships no hidden default.

```bit
import { App, tracing } from "web"
import { Tracer } from "std/trace"

fn mount(app: App) {
  app.use(tracing(Tracer("", "myapp", 1.0)))
}
```

## Panic recovery

`recover()` turns a panic in a handler, or in any middleware registered after
it, into the same 500 a `fail` already produces - built on the runtime's own
panic boundary, not a second interception point, so a recovered panic is
logged and mapped exactly like an ordinary failure (see
[Errors](errors.md)). Register it early in the chain so it wraps everything
after it:

```bit
import { App, recover, logger } from "web"

fn mount(app: App) {
  app.use(recover())
  app.use(logger())
}
```

## Graceful shutdown

`app.listen()` blocks forever and never hands back the socket it bound -
there is no way to stop it without cutting off every request already in
flight. `app.serve()` binds the same way, but returns immediately with the
running `Server` instead of blocking, so the rest of your program can hold
onto it and stop it later:

```bit
import { App, Config } from "web"

fn main(): ()! {
  let app = App(Config{ secret = "change-me" })
  app.get("/", (c) => c.text("ok"))
  let server = app.serve()?
  // ... the app is serving requests here ...
  server.shutdown(5000)?
}
```

`server.shutdown(timeoutMs)` stops accepting new connections immediately
and gives every connection with a request already in the handler's hands
up to `timeoutMs` milliseconds to finish, force-closing whatever is still
running once that passes. Call it whenever your own process decides it is
time to stop - a deploy script, a test, or an admin endpoint you build
yourself.

The usual trigger is the signal a deployment sends on shutdown - `SIGTERM`
from Docker or Kubernetes, `SIGINT` from a developer's Ctrl-C.
[`std/signal`'s `waitForSignal`](../../../docs/stdlib/signal.md)
blocks a green thread until one of those arrives, so the last line of
`main` is the signal-to-shutdown wire itself:

```bit
import { App, Config } from "web"
import { waitForSignal, Signal } from "std/signal"

fn main(): ()! {
  let app = App(Config{ secret = "change-me" })
  app.get("/", (c) => c.text("ok"))
  let server = app.serve()?

  let _ = waitForSignal([Signal.Term, Signal.Int])
  print("shutting down\n")
  server.shutdown(10000)?
}
```

`app.listen()` is unchanged, and still the right call for a program that
has nothing else to do once it starts serving.

## Idempotency keys

```bit
import { App, IdempotencyPolicy, MemoryIdempotencyStore, idempotency } from "web"

fn mount(app: App) {
  let store = MemoryIdempotencyStore(10_000)
  app.use(idempotency(IdempotencyPolicy{ store = store, ttl = 86400 }))
}
```

A request carrying an `Idempotency-Key` header runs its handler once. A
retry with the same key and the same method, path and body gets back the
exact response the first attempt produced, handler unrun. A retry with the
same key and a different body is `422` - never a silent replay of someone
else's answer. A second request racing the first while it is still running
is `409`: the key is reserved the instant the first request arrives, not
once it finishes.

A request with no `Idempotency-Key` header is untouched, so this is usually
mounted on the write routes that need it rather than the whole app -
`app.group("/api").use(idempotency(p))` - since a safe method has no reason
to send the header at all.

**You supply the store; there is no default**, the same rule `rateLimit`'s
counter and `Config.sessions` both carry: an in-process store is invisible
to a retry that lands on a different server behind a load balancer, and a
duplicate request would run the handler again with nobody able to tell.
`MemoryIdempotencyStore(maxKeys)` ships and is single-process only; a store
shared across processes implements `IdempotencyStore`
(`begin`/`finish`/`abandon` - `begin` is the one call that must be atomic,
the same requirement `RateStore.incr` answers for a counter).

`ttl` is how long a key is remembered, in seconds, from whichever of
`begin()`/`finish()` last touched it - there is no default, because how long
a client may safely retry is a fact about the endpoint. A handler that
raises releases its reservation so a retry after a failed attempt is not
stuck behind it; a handler that panics does not, and the reservation lives
out its `ttl` before a retry can run again.

Next: [Errors](errors.md).
