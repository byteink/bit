# Sessions, CSRF and security

<!-- doctest: per-block -->

Server-side sessions, the CSRF token bound to one, cross-origin responses,
and the standard security response headers - the package's opt-in security
middleware, in the order an app usually reaches for them.

## Sessions

The session cookie carries a random id and nothing else; every byte of
session data lives in a store the app supplies through `Config.sessions`
(see [Configuration](configuration.md)). There is deliberately **no
default**: an app that calls `c.session()` without one gets a failure naming
the `sessions` field, not a working in-memory session that quietly stops
working the day a second process appears. `MemoryStore(maxEntries)` ships for
development, tests, and a single-process service content to log everyone out
on restart - it is never the default, it is one line at the call site.

```bit
import { App, Config, MemoryStore } from "web"
import { env } from "std/os"

fn build(): App {
  return App(Config{ secret = env("APP_SECRET"), sessions = MemoryStore(10_000) })
}
```

`MemoryStore` is **bounded**: a write past `maxEntries` evicts the
oldest-expiring entry rather than failing, so a flood costs bounded memory
instead of an ever-growing map - visitors get logged out at the cap, which is
a better failure than the process growing until it is killed, but is still a
failure worth pairing with a rate limit (see
[Operational middleware](operations.md)).

Every write a `SessionStore` accepts is a versioned compare-and-set: two
requests that raced the same cookie - one calling `destroy()` while the other
still held the session it loaded before that - must never let the loser's
`save()` resurrect a destroyed session or silently overwrite the winner's
update. A `Session` tracks the version it last saw and sends it back on
`save()`; a store whose version has moved fails the write with a conflict
instead of applying it, and the app decides whether to reload and retry. A
type implementing `SessionStore` directly - a future `SqlStore` or
`RedisStore` - carries this contract too, including `destroy()` leaving a
tombstone bounded by the same session ttl, so a stale writer can never bring
a destroyed id back once its tombstone exists.

### Revoking every session of one user

A session is addressable by its id alone, so "log this user out everywhere"
- after a password reset, or when an identity provider sends a back-channel
logout - needs a second way in. A session can carry an **index**: `key` to
`value` pairs, one value per key, set with `session.index(key, value)` and
written with the session's data in the same `compareAndSet`, so the index
never disagrees with the data and costs no extra store round trip.
`destroyIndexed(key, value, except, tombstoneTtl)` then destroys every live
session holding that pair, leaving the same tombstones `destroy()` does, and
returns how many it destroyed. `except` is the one session to keep (the
caller's own), or `""` for none. `tombstoneTtl` is always
`sessionTTLSeconds` (24 hours, exported by `web`): a tombstone must outlive the
session it replaces, or a stale writer can bring the id back. Namespace the keys (`"auth:sub"`); both the
key and the value must be non-empty.

```bit
import { Ctx, Res, SessionStore, sessionTTLSeconds } from "web"

fn markLogin(c: Ctx, userId: string): ()! {
  c.session()?.index("auth:sub", userId)
}

fn logoutOthers(c: Ctx, store: SessionStore, userId: string): Res! {
  let s = c.session()?
  let n = store.destroyIndexed("auth:sub", userId, s.id(), sessionTTLSeconds)?
  return c.text("signed out of ${n} other session(s)")
}
```

A store you write yourself must maintain what makes this cheap: a secondary
index on `(key, value)` to session id, replaced in the same transaction (or
script) as the `compareAndSet` that writes the session - drop the session's
old pairs, insert the new ones - and emptied when the session expires or is
destroyed. `load` returns the session's index with its data. `destroyIndexed`
must cost the number of sessions holding the pair, not a scan of every
session, and must neither count nor tombstone a session whose ttl has passed.
`MemoryStore` does this with a reverse map under its one lock, swept and
bounded together with its entries.

### Saving is automatic

`session.set()`/`delete()`/`regenerate()` only change this request's own
copy of the data; none of them writes to the store by themselves. The
framework saves a session that changed once the handler returns, before the
response goes out, so this is already enough:

```bit
import { Ctx } from "web"

fn addToCart(c: Ctx, sku: string): ()! {
  c.session()?.set("cart:" + sku, "1")
}
```

No `save()` call, and the value is still there on the next request. A
session nothing touched costs the store no write at all. `save()` is still
there for a handler that wants to force a write before it returns - call it
any number of times; once nothing is left to flush it is a no-op.

A save failure - the store is down, or lost the race described above -
becomes the same 500 an ordinary handler failure would, never a response
that silently forgot the write.

The one place autosave cannot reach is a hijacked connection: a WebSocket or
an SSE stream (see [Realtime](realtime.md)) writes its own status line
before the framework gets a say, so there is no response left to fail. A
session written before or during one of those is still saved, best-effort;
a failure there is logged rather than turned into a response nobody can
send.

### Regenerating the id after login

`Session.regenerate()` moves this session's data to a freshly minted id,
destroys the old one, and arms a `Set-Cookie` for the new one. Call it the
moment a request proves who it is - a successful password check, an OIDC
callback, any change of privilege - and before writing that identity onto the
session:

```bit
import { Ctx } from "web"

fn afterLogin(c: Ctx): ()! {
  c.session()?.regenerate()?
}
```

This closes session fixation: without it, an id an attacker set on a victim
before login (in a cookie the attacker already knows) stays valid after
login, so the attacker's known id now carries an authenticated session. OWASP's
Session Management Cheat Sheet states the rule this follows: renew the
session id after any privilege change, not only at login. The old id is
destroyed through the store's atomic path (see above), so it is invalid the
instant `regenerate()` returns, even to a request that had already loaded it.

## CSRF and anonymous visitors

`c.csrfToken()` returns the value a form puts in its hidden `_csrf` field. It
is `HMAC(Config.secret, session id)`, so calling it **creates a session for
every anonymous visitor** who loads the page - N requests to a public form
cost N store entries, with no authentication in front of them. That is
inherent to binding the token to the session, not a store defect, so a page
calling `c.csrfToken()` wants a rate limit in front of it, ideally alongside
`csrf()`:

```bit
import { App, Limit, MemoryCounter, byIp, rateLimit, csrf } from "web"

fn mount(app: App) {
  let pages = app.group("/")
  pages.use(rateLimit(Limit{ requests = 30, window = 60, by = byIp, store = MemoryCounter(10_000) }))
  pages.use(csrf())
}
```

`csrf()` is layer two of two: layer one is always on - the session cookie
carries `SameSite=Lax`, which every current browser enforces against a
cross-site form POST at no cost to anyone. Mount `csrf()` on the groups that
serve HTML forms and leave a bearer-token API group untouched.

## CORS

`cors(cfg)` answers cross-origin responses for an **explicit** list of
origins and nothing else - no wildcard, anywhere, ever, because the wildcard
left behind is the shape of every CORS incident in the wild. An origin is
allowed when it is byte-for-byte one of the strings the app wrote down.

```bit
import { App, Cors, cors } from "web"

fn mount(app: App) {
  app.use(
    cors(
      Cors{
        origins = []string{ "https://app.example.com" },
        methods = []string{ "GET", "POST" },
        headers = []string{ "Content-Type", "Authorization" },
        credentials = true,
        maxAge = 600,
      },
    ),
  )
}
```

`credentials: true` adds `Access-Control-Allow-Credentials`, which is what
lets a cross-origin request carry cookies; it is only ever sent alongside an
echoed origin, never alongside a wildcard.

## Serving over TLS

`app.listen()` serves plain HTTP - fine behind a proxy that terminates TLS
for you, wrong for anything that answers the internet directly.
`app.listenTls()` and `app.serveTls()` bind the same routes over TLS
instead, given a certificate chain and matching private key (both PEM):

```bit
import { App, Config } from "web"
import { readFile } from "std/fs"

fn main(): ()! {
  let app = App(
    Config{
      secret = "change-me",
      certPem = readFile("cert.pem")?,
      keyPem = readFile("key.pem")?,
    },
  )
  app.get("/", (c) => c.text("ok"))
  app.listenTls()?
}
```

Both fail immediately, naming the missing field, if either `certPem` or
`keyPem` is still empty - there is no placeholder certificate the framework
falls back to. A client that speaks HTTP/2 is served over it automatically
(negotiated by ALPN on the same TLS connection, no separate step), and
HTTP/3 is served over QUIC on the same port number, on UDP - the response's
`Alt-Svc` header advertises it, so a client that already speaks HTTP/3 can
open that connection directly on a later request.

`app.serveTls()` is the TLS mirror of [`app.serve()`](operations.md): it
returns the running `TlsServer` immediately instead of blocking, so you can
call `server.shutdown(timeoutMs)` on it later - see
[Graceful shutdown](operations.md) for what that guarantees. Its shutdown
drains the TLS connection's HTTP/1.1 and HTTP/2 traffic; an HTTP/3 request
in flight at the moment `shutdown()` is called is not drained yet.

## The standard security headers

`secureHeaders(o)` sets the eight headers that belong on every response -
`Headers{}` is every default. `csp` replaces the default
`Content-Security-Policy` wholesale (no merging, no per-directive override);
the empty string omits it entirely, the right setting for an API that never
returns a document a browser renders. `https: true` is the app's own
declaration that every request arrives over TLS - true whether that TLS
connection is terminated by `app.listenTls()`/`app.serveTls()` themselves or
by a proxy in front of a plain `app.listen()`, since either way this package
has no way to tell the two apart from inside a handler - and is what turns
on `Strict-Transport-Security`.

```bit
import { App, Headers, secureHeaders } from "web"

fn mount(app: App) {
  app.use(secureHeaders(Headers{ https = true }))
}
```

Next: [Operational middleware](operations.md).
