# pkg/webredis

Web framework stores backed by Redis: the adapter between [`pkg/web`](../web)
and [`pkg/redis`](../redis). Neither of those depends on the other, so an app
that serves HTTP pulls in a Redis client only when it asks for a Redis-backed
store, and a program that only talks to Redis (jobs, mail) never resolves a web
framework. Today the package holds `RedisIdempotencyStore`; session and rate-limit
stores belong here too.

## Install

`bit add bitlang.org/pkg/webredis@v0.1.0` writes the dependency below, and
`bit add` fetches `web` and `redis` with it:

```json
{
  "dependencies": {
    "webredis": "bitlang.org/pkg/webredis@v0.1.0"
  }
}
```

## Usage

A publish request that a phone retries runs its handler once, even when the
retry lands on another server:

```bit
import { App, Config, IdempotencyPolicy, idempotency } from "web"
import { RedisIdempotencyStore } from "webredis"
import { env } from "std/os"
import { open } from "redis"

fn main(): ()! {
  let r = open(env("REDIS_URL"))?
  let store = RedisIdempotencyStore(r)?
  let app = App(Config{ secret = env("APP_SECRET") })
  app.use(idempotency(IdempotencyPolicy{ store = store, ttl = 86400 }))
  app.post("/articles", (c) => c.text("published").status(201))
  app.listen()?
}
```

`RedisIdempotencyStore` needs Redis 7.0 or Valkey 7.2; the constructor refuses an
older server at startup. Every chapter, with the failure modes, is in
[`docs/`](docs/README.md).

For how first-party packages in this repository are laid out, gated,
versioned and released, see [`pkg/README.md`](../README.md).
