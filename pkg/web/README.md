# pkg/web

A web framework for Bit: a radix-trie router, `App`/`Group` with scoped
middleware, a `Ctx` carrying the parsed request, `Res` helpers, an HTML node
tree with escaping, sessions, and the middleware set (`logger`, `cors`,
`csrf`, `static`, `compress`, `secureHeaders`, `rateLimit`, `recover`).

Versioning, tags and the release procedure for every first-party package are in
[`pkg/README.md`](../README.md).

## Install

```json
{
  "dependencies": {
    "web": "bitlang.org/pkg/web@v0.1.0"
  }
}
```

## A minimal server

```bit
import { App, Config } from "web"
import { env } from "std/os"

fn main(): ()! {
  let app = App(Config{ secret: env("APP_SECRET") })
  app.get("/", (c) => c.text("hello, bit"))
  app.listen()?
}
```

## Documentation

Start at [`docs/README.md`](docs/README.md): getting started, routing, the
request and response, middleware and its scope, sessions/CSRF/CORS/security
headers, the operational middleware (rate limiting, static files, compress,
logging, tracing, recovery), errors, the `envelope()`/`page()` response
shape, and every `Config` field.
