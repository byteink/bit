# Operational middleware

Rate limiting, serving static files, compression, request logging, tracing
and panic recovery - the middleware that shapes how an app behaves in
production rather than what it answers.

## Rate limiting

```bit
import { App, Limit, MemoryCounter, byIp, rateLimit } from "bitlang.org/pkg/web"

fn mount(app: App) {
  let counter = MemoryCounter(10_000)
  app.use(rateLimit(Limit{ requests: 100, window: 60, by: byIp, store: counter }))
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

A store outage is logged through `Config.logs` and the request is **served**
- failing closed would turn a counter outage into an outage of the app the
limiter protects. Two registrations with the same policy, store and key
function share one bucket; set `name` on `Limit` to keep two limiters apart
on one store.

## Static files

```bit
import { App, static } from "bitlang.org/pkg/web"

fn mount(app: App) {
  app.use(static("/assets", "./public"))
}
```

Mounted with `app.use`, not a route, so `GET /assets/app.css` serves
`./public/app.css` with nothing registered on the router. Path traversal is
the whole reason this ships: every component below the served root is
checked with an `lstat`, not just a lexical string check, because a pure
string function cannot see a symlink.

## Compression

`compress()` gzips the response body when the client's `Accept-Encoding`
allows it, the response carries no `Content-Encoding` already, the body is
big enough that compressing is a net win, and the `Content-Type` is on an
allowlist of types that actually compress.

## Logging

`logger()` writes one line per request - timestamp, method, the matched
route pattern (not the raw path), status, and how long the downstream chain
took. Five space-separated fields and nothing else: the framework's default
log line cannot leak a credential into a file that ships to a third-party
aggregator.

## Tracing

`tracing(tr)` opens one span per request on a `std/trace` `Tracer`,
continuing an inbound W3C `traceparent` when the request carries a valid one
and starting a fresh trace otherwise, and closes the span with the response
status whether the handler returns, fails, or panics. It takes the `Tracer`
explicitly - `std/trace` ships no hidden default.

```bit
import { App, tracing } from "bitlang.org/pkg/web"
import { newTracer } from "std/trace"

fn mount(app: App) {
  app.use(tracing(newTracer("", "myapp", 1.0)))
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
import { App, recover, logger } from "bitlang.org/pkg/web"

fn mount(app: App) {
  app.use(recover())
  app.use(logger())
}
```

Next: [Errors](errors.md).
