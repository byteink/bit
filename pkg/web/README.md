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

## Views (JSX)

`<div id="x">hi</div>` needs nothing beyond the ordinary install above: JSX
(SPEC §12.12) desugars a lowercase tag to calls to `elem`, `attr`, `frag` and
`text`, resolved by ordinary scope rules like any other call, so importing
those four alongside the constructors they wrap is all a view needs.

```bit
import { Node, elem, attr, frag, text } from "web"

fn Row(name: string): Node {
  let item = <li>{text(name)}</li>
  return item
}

fn page(name: string): Node {
  return <div id="x"><Row name={name} /></div>
}
```

A component is a plain function returning `Node` (`Row` and `page` above); no
`render()` call is needed to return JSX, only to flatten a tree into a string
for something outside Bit - a file, stdout, a socket. `c.html(n)` takes the
`Node` directly. `el(tag, ...kids)` stays the explicit way to build an
element with a dynamic tag name.

## Documentation

Start at [`docs/README.md`](docs/README.md): getting started, routing, the
request and response, middleware and its scope, sessions/CSRF/CORS/security
headers, the operational middleware (rate limiting, static files, compress,
logging, tracing, recovery), errors, the `envelope()`/`page()` response
shape, and every `Config` field.

<!-- BENCH:START -->
<!-- BENCH:END -->

Regenerate with `./pkg/web/bench/run.sh`, which needs an x86-64 Linux host
(`scripts/x64host.sh`) with docker. The six servers it compares are under
[`bench/apps/`](bench/apps); `bench/RESULTS.md` is the same block standalone.
