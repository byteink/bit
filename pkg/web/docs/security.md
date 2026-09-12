# Sessions, CSRF and security

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
  return App(Config{ secret: env("APP_SECRET"), sessions: MemoryStore(10_000) })
}
```

`MemoryStore` is **bounded**: a write past `maxEntries` evicts the
oldest-expiring entry rather than failing, so a flood costs bounded memory
instead of an ever-growing map - visitors get logged out at the cap, which is
a better failure than the process growing until it is killed, but is still a
failure worth pairing with a rate limit (see
[Operational middleware](operations.md)).

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
  pages.use(rateLimit(Limit{ requests: 30, window: 60, by: byIp, store: MemoryCounter(10_000) }))
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
  app.use(cors(Cors{
    origins: []string{ "https://app.example.com" },
    methods: []string{ "GET", "POST" },
    headers: []string{ "Content-Type", "Authorization" },
    credentials: true,
    maxAge: 600,
  }))
}
```

`credentials: true` adds `Access-Control-Allow-Credentials`, which is what
lets a cross-origin request carry cookies; it is only ever sent alongside an
echoed origin, never alongside a wildcard.

## The standard security headers

`secureHeaders(o)` sets the eight headers that belong on every response -
`Headers{}` is every default. `csp` replaces the default
`Content-Security-Policy` wholesale (no merging, no per-directive override);
the empty string omits it entirely, the right setting for an API that never
returns a document a browser renders. `https: true` is the app's own
declaration that every request arrives over TLS (this package cannot detect
it - `listenAndServe` serves plaintext TCP, and a deployment terminating TLS
in a proxy is the only party that knows), and is what turns on
`Strict-Transport-Security`.

```bit
import { App, Headers, secureHeaders } from "web"

fn mount(app: App) {
  app.use(secureHeaders(Headers{ https: true }))
}
```

Next: [Operational middleware](operations.md).
