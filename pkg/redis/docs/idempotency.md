# Idempotency keys across servers

<!-- doctest: per-block -->
<!-- doctest: deps web -->

Inkwell's "Publish" button posts an article, and the request is slow
enough that a phone on a bad connection gives up and sends it again. Without
a guard the article is published twice. `pkg/web`'s `idempotency` middleware
is that guard: a request that carries an `Idempotency-Key` header runs its
handler once, and a retry with the same key gets the first answer back. Its
store decides where "seen this key" lives, and the in-process one only
remembers what one server saw. Run Inkwell on two servers behind a load
balancer and the retry lands on the other one, which has never heard of the
key. `RedisIdempotencyStore` keeps the keys in Redis, so every server answers
for all of them.

## The simplest thing that works

Open a client, hand it to the store, and give the store to the middleware:

```bit
import { App, Config, IdempotencyPolicy, idempotency } from "web"
import { env } from "std/os"
import { open, RedisIdempotencyStore } from "redis"

fn main(): ()! {
  let r = open(env("REDIS_URL"))?
  let store = RedisIdempotencyStore(r)?
  let app = App(Config{ secret = env("APP_SECRET") })
  app.use(idempotency(IdempotencyPolicy{ store = store, ttl = 86400 }))
  app.post("/articles", (c) => c.text("published").status(201))
  app.listen()?
}
```

A client now sends `Idempotency-Key: 7c1f...` with each publish. The first
request with that key runs the handler. A retry with the same key, method,
path and body gets the same `201 published` back with the handler unrun. The
same key with a different body is `422`, and a retry that arrives while the
first request is still running is `409`. Those answers are `pkg/web`'s, the
statuses the IETF `Idempotency-Key` draft asks for; the store only has to
remember. The middleware itself is covered in `pkg/web`'s operational
middleware chapter.

`ttl` is how long a key is remembered, in seconds. It is also the retry
window you promise clients, so pick it for the endpoint: a day is common for
payments, a few minutes for a button that is only ever clicked twice by
mistake.

## Why it is safe when two requests arrive together

Two servers can receive the same key in the same millisecond. A store that
looked the key up and then wrote it would let both see "not seen" and both
run the handler. `begin`, the store's first step, is therefore a single Redis
command:

```text
SET idem:<key> <reserved> PX <ttl in ms> NX GET
```

`NX` writes only when the key is absent and `GET` returns whatever was there
before. Redis runs one command to completion before the next, so of any number
of callers racing one new key, exactly one gets "nothing was there" and
proceeds. Every other caller gets the winner's entry back from the same round
trip and is told `409` (still running) or handed the stored response (done).
The live tests race 16 connections on one key, five times over, and require
exactly one winner each time.

`NX` together with `GET` needs Redis 7.0 or Valkey 7.2. The constructor asks
the server for its version and refuses anything older, naming what it found,
so a Redis 6 server fails at startup and not on the first request that
carries a key.

## What Redis keeps

One string per key, under `prefix + key` (the prefix defaults to `idem:`).
The value starts with a state letter and the request fingerprint, and once
the handler finishes it carries the response:

```text
I<n>:<fingerprint>                                reserved, handler running
D<n>:<fingerprint><status>\n<count>\n<headers><body>   finished
```

`<n>` is the fingerprint's length and each header is `<len>:<name><len>:<value>`.
The body is whatever bytes are left, stored exactly as the handler produced
it: no JSON escaping, no base64, so a response costs its own size plus a few
dozen bytes. A body of any bytes, including binary, comes back identical.

Every key is written with `PX`, so Redis drops it when the window ends and
nothing needs sweeping. `finish` restarts that clock from its own call, so a
slow handler's answer is remembered for the full `ttl`, not for what was left
of the reservation.

Use your own prefix when several apps share a server:

```bit
import { open, RedisIdempotencyStore } from "redis"

fn main(): ()! {
  let r = open("redis://localhost:6379")?
  let store = RedisIdempotencyStore(r, "inkwell:idem:")?
  r.close()
  return
}
```

The client's `Idempotency-Key` is only ever appended to the prefix, so
whatever characters it holds it names one key under it and cannot reach
another part of the keyspace.

## Failures

`begin` failing means the middleware cannot tell whether a duplicate is
running, so it does not run the handler: the request fails, and the client's
retry is the recovery. If `begin`'s command reached Redis but its reply was
lost, the key stays reserved until `ttl` ends and a retry gets `409`, never a
second run. `finish` failing only costs the cache write; the response goes out
regardless and the failure is logged.

A stored value that does not parse (another program wrote to the key, or the
format changed) fails `begin` with `RedisError.Protocol` instead of reading as
"not seen", because treating garbage as absent would run the handler twice.

## Sharp edges

- A handler that raises releases its reservation at once (`abandon` deletes
  the key). A handler that panics cannot, so the key stays `409` until `ttl`
  ends; keep `ttl` short enough that this is bearable.
- `abandon` has no way to tell whose reservation it deletes. If a handler runs
  longer than `ttl`, a second request can reserve the same key, and the first
  handler failing late then frees the second one's reservation. Pick a `ttl`
  longer than your slowest handler.
- A `ttl` is 1 to 9,000,000,000 seconds; anything else is
  `RedisError.Invalid` and nothing is sent.
- Each key is one Redis key, so the store works unchanged on a cluster.

## When not to use it

On a single server, `MemoryIdempotencyStore` is enough and one fewer network
hop. The store also does not make a handler's own side effects idempotent: a
payment provider call made before `finish` can still happen twice if the
process dies in between. Pass the provider the same idempotency key.

Next: [Scripting](scripting.md) for the Lua behind `finish`.
