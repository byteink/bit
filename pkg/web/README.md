# pkg/web

A web framework for Bit: a radix-trie router, `App`/`Group` with scoped
middleware, a `Ctx` carrying the parsed request, `Res` helpers, an HTML node
tree with escaping, sessions, and the middleware set (`logger`, `cors`,
`csrf`, `static`, `compress`, `secureHeaders`, `rateLimit`, `recover`).

Versioning, tags and the release procedure for every first-party package are in
[`pkg/README.md`](../README.md).

## Compiler requirement

Requires Bit 0.25.0 or later. Static file serving opens files through
`std/fs/secure`, which first shipped in 0.25.0. With an older compiler, a
build fails at compile time with "cannot find module std/fs/secure" (E0045),
never silently. `bit.json` has no field for a minimum compiler version, so
this is stated here rather than enforced.

## Install

`bit add bitlang.org/pkg/web@^0.9.0` writes:

```json
{
  "dependencies": {
    "web": "bitlang.org/pkg/web@^0.9.0"
  }
}
```

## A minimal server

```bit
import { App, Config } from "web"
import { env } from "std/os"

fn main(): ()! {
  let app = App(Config{ secret = env("APP_SECRET") })
  app.get("/", (c) => c.text("hello, bit"))
  app.listen()?
}
```

## Views (JSX)

`<div id="x">hi</div>` needs nothing beyond the ordinary install above:
each tag is a call to `elem`, `attr`, `frag` or `text`, so importing those
four alongside the constructors they wrap is all a view needs.

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
logging, tracing, recovery, idempotency keys), errors, the
`envelope()`/`page()` response shape, and every `Config` field.

<!-- BENCH:START -->
## Benchmarks

pkg/web is faster than its rivals in 18 of 20 comparisons, about the same in 1, and slower in 1. The hardest rival is ASP.NET Core: with 64 clients at once, pkg/web handles about 92% of its plaintext rate and 95% of its JSON rate.

| pkg/web, requests per second | vs gin | vs express | vs bun | vs Spring Boot | vs ASP.NET Core |
|---|--:|--:|--:|--:|--:|
| Plain text reply, 1 client at a time | 1.6x faster | 3.5x faster | 1.2x faster | 2.0x faster | 1.4x faster |
| Plain text reply, 64 clients at once | 1.6x faster | 9.5x faster | 1.2x faster | 2.7x faster | 1.1x slower |
| JSON reply, 1 client at a time | 1.6x faster | 3.2x faster | 1.2x faster | 1.9x faster | 1.4x faster |
| JSON reply, 64 clients at once | 1.5x faster | 8.8x faster | 1.2x faster | 2.5x faster | about the same |

- With 64 clients at once on plaintext, a typical pkg/web reply takes 1.03 ms and 99 in 100 finish within 2.19 ms; only ASP.NET Core is quicker on both.
- Every server sent identical replies, checked byte for byte before timing, and every timed request got a 200 OK.

Measured on Intel(R) Core(TM) i7-6700 CPU @ 3.40GHz (4 cores) on 2026-09-27, one core per server and a shared host, so compare the rows rather than reading them as absolute speeds.

Full numbers and method: [bench/RESULTS.md](bench/RESULTS.md)
<!-- BENCH:END -->

Regenerate with `./pkg/web/bench/run.sh`, which needs an x86-64 Linux host
(`scripts/x64host.sh`) with docker, or rebuild this block from the last
recorded run with `./pkg/web/bench/run.sh --render`, which measures nothing.
The six servers it compares are under [`bench/apps/`](bench/apps);
`bench/RESULTS.md` holds every table and the method.
