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
already publishes a number for. Types 3 to 5 need a database and are not
measured: `pkg/postgres`'s type codecs are not implemented yet, so there is no
Bit side to compare yet.

### Plaintext, `text/plain`, 13 bytes

| Framework | req/s c=1 | spread | req/s c=64 | spread | p50 ms c=64 | p99 ms c=64 | vs pkg/web |
|---|--:|--:|--:|--:|--:|--:|--:|
| pkg/web | 4,620 | 2.6% | 840 | 3.2% | 52.11 | 424.7 | 1.00x |
| gin | 10,946 | 0.3% | 78,868 | 0.4% | 0.41 | 5.5 | 93.88x |
| express | 5,419 | 1.1% | 5,459 | 1.4% | 11.35 | 16.9 | 6.50x |
| bun | 15,166 | 1.9% | 40,433 | 3.6% | 1.54 | 3.2 | 48.13x |
| Spring Boot | 9,382 | 2.2% | 50,120 | 0.8% | 1.21 | 2.9 | 59.66x |
| ASP.NET Core | 13,849 | 1.1% | 76,778 | 2.4% | 0.39 | 6.4 | 91.39x |

### JSON, one object serialized per request, 27 bytes

| Framework | req/s c=1 | spread | req/s c=64 | spread | p50 ms c=64 | p99 ms c=64 | vs pkg/web |
|---|--:|--:|--:|--:|--:|--:|--:|
| pkg/web | 4,519 | 1.3% | 794 | 3.7% | 54.30 | 447.7 | 1.00x |
| gin | 10,685 | 0.7% | 74,932 | 1.0% | 0.41 | 5.7 | 94.36x |
| express | 5,626 | 2.1% | 5,574 | 3.8% | 11.18 | 16.8 | 7.02x |
| bun | 14,956 | 6.1% | 40,756 | 6.1% | 1.52 | 3.1 | 51.32x |
| Spring Boot | 8,935 | 3.7% | 50,946 | 3.2% | 1.18 | 3.0 | 64.16x |
| ASP.NET Core | 13,715 | 4.3% | 77,420 | 2.2% | 0.41 | 4.6 | 97.49x |

> Every figure is the median of 5 reps of 5 seconds each, and `spread` is half the min-to-max range as a percent of that median. `c` is the number of concurrent keep-alive connections the load generator held open. `vs pkg/web` divides that framework's c=64 median by pkg/web's, so 2.00x is twice the requests per second.
> Throughput FALLS with concurrency, which is a measurement and not a transcription error, for: pkg/web on plaintext (4,620 at c=1, 840 at c=64); pkg/web on json (4,519 at c=1, 794 at c=64). Every one of those reps answered 200 on every request; what changes is how long each took.
> The two concurrency columns are published together because they do not move together. c=1 is what one request costs with no queue in front of it; c=64 is the server under load. A framework can lead on one and trail on the other, and one column alone would hide which.
> Identical responses were PROVEN before anything was timed, not assumed: all six servers answer the same body byte for byte (sha256 of each body compared against pkg/web's), the same Content-Type, a Content-Length equal to that body, and no chunked framing. The proof is regenerated on every run into `bench/out/verify.txt`. Keep-alive is on for all six and is checked the same way: two requests, one TCP connection.
> Round-robin, not one framework at a time. Every rep visits all six servers, rotating which goes first, and all six stay up for the whole run. The box drifts; interleaving spreads that drift over all six instead of over whichever framework held the noisy window.
> Load generator: oha, 64 concurrent connections, HTTP/1.1 keep-alive, pinned to cores 6-7. Servers pinned to cores 2-5. Disjoint, and read back from `/proc/<pid>/status` `Cpus_allowed_list` of each running process rather than taken on trust from the flag.
> Box AS MEASURED, not as specified: hl-master, `systemd-detect-virt` says `lxc`, 6 cores, `cpu.max` `max 100000`, 16384 MB RAM, Intel(R) Core(TM) i7-6700 CPU @ 3.40GHz, Linux 7.0.14-4-pve. It is a CONTAINER with no CPU quota, so anything else on the physical host competes with this benchmark and is invisible from inside it. During this run: 2-3 process(es) blocked on disk, 56.4-59.2 MB/s read, 13-14% iowait. Read these figures as a RANKING taken under one shared load, not as absolute throughput; they are not comparable to bare-metal published numbers.
> Versions: Bit toolchain 0.19.0, gin v1.12.0, Go go1.27.1, express 5.2.1, Node v22.23.2, bun 1.4.2, Spring Boot 3.5.16, JVM 21.0.12, ASP.NET 9.0.318.
> Generated by `pkg/web/bench/run.sh` from Bit `41bdfdac` on 2026-09-16T17:31:36Z. Do not edit by hand.
<!-- BENCH:END -->

Regenerate with `./pkg/web/bench/run.sh`, which needs an x86-64 Linux host
(`scripts/x64host.sh`) with docker. The six servers it compares are under
[`bench/apps/`](bench/apps); `bench/RESULTS.md` is the same block standalone.
