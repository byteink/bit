# Middleware: logging, CORS, security headers and rate limits

Inkwell answers requests, but it does it bare. There is no record of what was
asked, no way for a frontend running on another origin to call it, none of
the response headers a browser expects from a well behaved API, and nothing
stopping one client from hammering `/auth/login` as fast as the network lets
it. All four problems live outside any single route, so they belong in
front of every route, not copied into each handler.

That is what middleware is for: code that runs before and after a request,
wrapped around the handler like layers of an onion. `pkg/web` ships five
ready to use, and Inkwell mounts all five in `main.bit`, in this exact
order:

```bit
import {
  App, MemoryCounter, Limit, Cors, Headers, byIp, cors, envelope, logger, rateLimit, recover,
  secureHeaders,
} from "web"

const rateLimitPerMinute = 120
const rateLimitCounterCap = 10_000

fn mountMiddleware(app: App) {
  app.use(recover())
  app.use(logger())
  app.use(secureHeaders(Headers{ https = false }))
  app.use(
    cors(
      Cors{
        origins = []string{ "http://localhost:3000" }, methods = []string{
          "GET", "POST", "PUT", "DELETE",
        },
        headers = []string{ "Content-Type", "Authorization" }, credentials = true, maxAge = 600,
      },
    ),
  )
  app.use(
    rateLimit(
      Limit{
        requests = rateLimitPerMinute, window = 60, by = byIp, store = MemoryCounter(
          rateLimitCounterCap,
        ),
      },
    ),
  )
  app.use(envelope())
}
```

`app.use(m)` runs `m` for every request the app answers, including one for a
path nothing matches. Order matters here in one specific way: each
middleware wraps everything registered after it, so `recover()` has to come
first to catch a panic anywhere downstream, and `logger()` has to come right
after it to time everything that follows.

## Logging every request

`logger()` writes one `INFO` record per request through the app's
`Config.logger` (the `std/log` default on stderr when you set none): the
method, the matched route, the status and how long the whole chain took.

```
$ curl -s http://127.0.0.1:8080/health
$ tail -1 inkwell.log
time=2026-09-27T19:55:43Z level=INFO msg=request method=GET path=/health status=200 took=412us
```

It logs the route *pattern* (`/articles/:id`), never the concrete request
path, so a route like `/reset/:token` never leaks a credential into a log
file. If you want to know which article id was requested, log that
yourself, deliberately, at the place you decide it is safe to.

## Security headers on every response

`secureHeaders()` sets eight fixed headers, the ones every API should send
and almost none remember to:

```
$ curl -s -i http://127.0.0.1:8080/health | grep -E '^(HTTP|X-|Referrer|Cross-Origin|Content-Security)'
HTTP/1.1 200 OK
X-Content-Type-Options: nosniff
X-Frame-Options: DENY
Referrer-Policy: no-referrer
Cross-Origin-Opener-Policy: same-origin
Cross-Origin-Resource-Policy: same-origin
Origin-Agent-Cluster: ?1
X-DNS-Prefetch-Control: off
X-XSS-Protection: 0
Content-Security-Policy: default-src 'self'
```

`Headers{ https = false }` is a declaration, not a detection: this framework
cannot see whether the connection in front of it is TLS-terminated by a
proxy, so it never guesses. Set `https = true` only once you know every
request genuinely arrives over HTTPS; the field controls whether
`Strict-Transport-Security` is sent at all.

## CORS for one browser origin

Inkwell's frontend runs on `http://localhost:3000`, so that is the only
origin `cors()` allows. There is no wildcard in this framework on purpose;
every origin has to be spelled out. A preflight from the allowed origin gets
answered directly, before the route ever runs:

```
$ curl -s -i -X OPTIONS http://127.0.0.1:8080/articles \
    -H "Origin: http://localhost:3000" \
    -H "Access-Control-Request-Method: POST" \
    -H "Access-Control-Request-Headers: Content-Type"
HTTP/1.1 204 No Content
Vary: Origin
Access-Control-Allow-Origin: http://localhost:3000
Access-Control-Allow-Credentials: true
Access-Control-Allow-Methods: GET, POST, PUT, DELETE
Access-Control-Allow-Headers: Content-Type, Authorization
Access-Control-Max-Age: 600
```

An origin that is not on the list is not an error. It just gets no
`Access-Control-Allow-Origin` header back, which is what makes the browser
refuse to hand the response to the page:

```
$ curl -s -i -X OPTIONS http://127.0.0.1:8080/articles \
    -H "Origin: http://evil.example.com" \
    -H "Access-Control-Request-Method: POST"
HTTP/1.1 405 Method Not Allowed
Vary: Origin
Allow: GET, POST
```

`Vary: Origin` is on both responses, allowed or not, because the headers a
client gets back depend on which origin it sent.

## Rate limits

`rateLimit()` counts requests in a sliding window per client (`byIp`, by
default) and rejects once the quota is spent. Every response carries the
quota so a well behaved client can back off on its own:

```
$ curl -s -i http://127.0.0.1:8080/health | grep -i ratelimit
RateLimit-Limit: 120
RateLimit-Remaining: 119
RateLimit-Reset: 60
```

`RateLimit-Remaining` counts down with every request against the same
`Limit`, allowed or rejected. Spend the whole 120/60s quota and the
rejection carries the same headers plus one more:

```
$ curl -s -i http://127.0.0.1:8080/health
HTTP/1.1 429 Too Many Requests
RateLimit-Limit: 120
RateLimit-Remaining: 0
RateLimit-Reset: 14
Retry-After: 21
```

`rateLimit()` refuses to build without a `store`, and panics at startup
rather than serving unlimited traffic that only looks protected. A single
`MemoryCounter` is correct for one process; a deployment with more than one
instance needs a shared store instead, since each of N servers otherwise
permits the whole quota on its own. `RateStore` is a structural interface
(`incr`/`count`), so a Redis-backed one is a type Inkwell could write and
pass to `Limit.store` with no change to `pkg/web` itself.

## Writing your own

A `Middleware` is `(Ctx, Next) => Res!`: it gets the request and the rest of
the chain, and decides whether, and when, to call it. Calling `next(c)`
before doing anything runs code on the way in; acting on the `Res` it
returns runs code on the way out.

```bit
import { Ctx, Middleware, Next } from "web"
import { millis, monotonic, since } from "std/time"

fn timing(): Middleware {
  return (c: Ctx, next: Next) => {
    let start = monotonic()
    let res = next(c)?
    let took = millis(since(start))
    return res.header("X-Response-Time", "${took}ms")
  }
}
```

Register it with `app.use(timing())` like any of the five above, and every
response after it in the chain carries the header. That is the whole
contract: read the request, decide, optionally call `next`, optionally
touch what came back.

## What we built

Inkwell now logs every request, sends the standard security headers, allows
its own frontend's origin and nothing else, and turns away a client that
sends more than 120 requests a minute, all without touching a single route
handler.

Previous: [Authorization](12-authorization.md).
Next: [Pagination, filtering and sorting](14-pagination-filtering-and-sorting.md).
