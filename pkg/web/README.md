# pkg/web

A web framework for Bit: a radix-trie router, `App`/`Group` with scoped
middleware, a `Ctx` carrying the parsed request, `Res` helpers, an HTML node
tree with escaping, sessions, and the middleware set (`logger`, `cors`,
`csrf`, `static`, `compress`, `secureHeaders`, `rateLimit`, `recover`).

Versioning, tags and the release procedure for every first-party package are in
[`pkg/README.md`](../README.md).

## Compiler requirement

As of #5798, `static()` imports `std/fs/secure` (`openBeneath`/`statOpen`),
which exists only past commit 44fb9b844 on this repository: no compiler
release ships it yet (the latest release at the time of #5798 is `v0.24.0`).
`bit.json` has no field a package can use to declare a minimum compiler
version (`docs/package-manager.md`: "There is no `version` field. Nothing in
the compiler reads a `"version"` key anywhere in `bit.json`"), so this is
stated here rather than enforced: install a `bit` built from `main` at or
past that commit, or wait for the release that repins it. A `bit.json`
resolving `web` against an older compiler fails at compile time with "cannot
find module std/fs/secure" (E0045), not silently.

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
  let app = App(Config{ secret = env("APP_SECRET") })
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
## Benchmarks

TechEmpower's test types 1 and 2, the same two every framework here
already publishes a number for. Types 3 to 5 need a database-backed
endpoint, and none of the six apps under `bench/apps/` has one, so there
is no Bit side to compare yet.

### Plaintext, `text/plain`, 13 bytes

| Framework | req/s c=1 | spread | req/s c=64 | spread | p50 ms c=64 | p99 ms c=64 | vs pkg/web |
|---|--:|--:|--:|--:|--:|--:|--:|
| pkg/web | 8,655 | 2.5% | 24,267 | 0.3% | 1.66 | 5.8 | 1.00x |
| gin | 10,950 | 0.4% | 78,918 | 1.2% | 0.41 | 5.6 | 3.25x |
| express | 5,355 | 4.2% | 5,472 | 4.1% | 11.22 | 16.5 | 0.23x |
| bun | 15,782 | 3.7% | 46,417 | 6.0% | 1.30 | 2.7 | 1.91x |
| Spring Boot | 9,235 | 4.0% | 50,511 | 1.7% | 1.20 | 2.8 | 2.08x |
| ASP.NET Core | 14,005 | 1.3% | 77,554 | 1.3% | 0.38 | 6.4 | 3.20x |

### JSON, one object serialized per request, 27 bytes

| Framework | req/s c=1 | spread | req/s c=64 | spread | p50 ms c=64 | p99 ms c=64 | vs pkg/web |
|---|--:|--:|--:|--:|--:|--:|--:|
| pkg/web | 8,173 | 2.1% | 22,460 | 0.8% | 1.76 | 6.4 | 1.00x |
| gin | 10,660 | 1.1% | 75,040 | 1.8% | 0.41 | 5.6 | 3.34x |
| express | 5,584 | 1.2% | 5,702 | 3.7% | 10.95 | 15.6 | 0.25x |
| bun | 15,653 | 5.6% | 40,879 | 11.4% | 1.52 | 3.1 | 1.82x |
| Spring Boot | 8,916 | 1.0% | 51,863 | 1.1% | 1.16 | 2.9 | 2.31x |
| ASP.NET Core | 13,993 | 8.9% | 77,731 | 0.4% | 0.39 | 6.5 | 3.46x |

> Every figure is the median of 5 reps of 5 seconds each, and `spread` is half the min-to-max range as a percent of that median. `c` is the number of concurrent keep-alive connections the load generator held open. `vs pkg/web` divides that framework's c=64 median by pkg/web's, so 2.00x is twice the requests per second.
> The two concurrency columns are published together because they do not move together. c=1 is what one request costs with no queue in front of it; c=64 is the server under load. A framework can lead on one and trail on the other, and one column alone would hide which.
> Identical responses were PROVEN before anything was timed, not assumed: all six servers answer the same body byte for byte (sha256 of each body compared against pkg/web's), the same Content-Type, a Content-Length equal to that body, and no chunked framing. The proof is regenerated on every run into `bench/out/verify.txt`. Keep-alive is on for all six and is checked the same way: two requests, one TCP connection.
> Round-robin, not one framework at a time. Every rep visits all six servers, rotating which goes first, and all six stay up for the whole run. The box drifts; interleaving spreads that drift over all six instead of over whichever framework held the noisy window.
> Load generator: oha, 64 concurrent connections, HTTP/1.1 keep-alive, pinned to cores 6-7. Servers pinned to cores 2-5. Disjoint, and read back from `/proc/<pid>/status` `Cpus_allowed_list` of each running process rather than taken on trust from the flag.
> Box AS MEASURED, not as specified: hl-master, `systemd-detect-virt` says `lxc`, 6 cores, `cpu.max` `max 100000`, 16384 MB RAM, Intel(R) Core(TM) i7-6700 CPU @ 3.40GHz, Linux 7.0.14-4-pve. It is a CONTAINER with no CPU quota, so anything else on the physical host competes with this benchmark and is invisible from inside it. During this run: 2-3 process(es) blocked on disk, 55.8-60.7 MB/s read, 12-15% iowait. Read these figures as a RANKING taken under one shared load, not as absolute throughput; they are not comparable to bare-metal published numbers.
> Versions: Bit toolchain ghcr.io/byteink/bit:0.21.1 (0.21.1), gin v1.12.0, Go go1.27.1, express 5.2.1, Node v22.23.2, bun 1.4.2, Spring Boot 3.5.16, JVM 21.0.12, ASP.NET 9.0.318.
> Generated by `pkg/web/bench/run.sh` from Bit `fa7ffd89` on 2026-09-19T21:44:07Z. Do not edit by hand.
<!-- BENCH:END -->

Regenerate with `./pkg/web/bench/run.sh`, which needs an x86-64 Linux host
(`scripts/x64host.sh`) with docker. The six servers it compares are under
[`bench/apps/`](bench/apps); `bench/RESULTS.md` is the same block standalone.
