# Idempotency keys: retry a write without doing it twice

<!-- doctest: per-block -->
<!-- doctest: deps orm postgres -->

A reader on a train posts a comment on one of Inkwell's articles. The tunnel
swallows the response, the app's request times out, and the app does the only
sensible thing: it sends the request again. The first one had reached the
server after all.

```text
$ curl -i -X POST http://127.0.0.1:8080/v1/articles/42/comments \
    -H 'Cookie: sid=9f2c...' -H 'Content-Type: application/json' \
    -d '{"body":"great read"}'
HTTP/1.1 201 Created
Location: /v1/articles/42/comments/17

$ curl -i -X POST http://127.0.0.1:8080/v1/articles/42/comments \
    -H 'Cookie: sid=9f2c...' -H 'Content-Type: application/json' \
    -d '{"body":"great read"}'
HTTP/1.1 201 Created
Location: /v1/articles/42/comments/18
```

Two requests, two comments, and the article now shows "great read" twice. The
server did nothing wrong: from where it sits, two identical requests look like
a reader who meant to post twice. The client is the only one who knows the
second request is a retry of the first, so the client has to say so. This part
adds that to Inkwell for `POST /v1/articles` and `POST /v1/articles/:id/comments`,
the two routes where a repeat does damage.

## The idea: one key per intent

The client puts a header on the request, `Idempotency-Key`, holding a random
value it made up for this one action. A retry of that action sends the same
value. The server remembers the key and the answer it gave:

- The first request with a key runs the handler and the answer is stored.
- A retry with the same key and the same request gets the stored answer back.
  The handler does not run again.
- A retry that arrives while the first is still running is told to wait: `409`.
- The same key with a different request is refused: `422`. A key names one
  action, and a different body is a different action.

This is the behaviour the IETF's Idempotency-Key header draft describes, and
`pkg/web` ships it as the `idempotency` middleware. A request with no
`Idempotency-Key` header is not touched at all, so nothing changes for a client
that never sends one.

## The simplest thing that works

Inkwell already has PostgreSQL, so you can use its SQL-backed store without
adding another service. The finished app's startup opens the store over the
same connection pool as its articles and comments. This function is copied
from [`inkwell/main.bit`](inkwell/main.bit):

```bit
import { SqlIdempotencyStore } from "web"
import { Db } from "orm"

fn openIdempotencyStore(db: Db): SqlIdempotencyStore! {
  let store = SqlIdempotencyStore(db.pool)?
  store.purge()?
  return store
}
```

Run the [finished app](README.md#run-the-finished-app) after applying its
migrations. The following requests target that app, including its real
comment handler and authentication, rather than a separate demo server.
Replace the example session cookie and article id with your own.

A policy connects this store to the middleware and gives each key a lifetime.
Inkwell uses one day: longer than a normal client retry, with expired rows
removed by `purge()`. Keys are kept separately for each signed-in user, so
another reader sending the same key does not receive your response.

## The three answers

Run the same comment again, this time with a key. The first request runs the
handler:

```text
$ curl -i -X POST http://127.0.0.1:8080/v1/articles/42/comments \
    -H 'Cookie: sid=9f2c...' -H 'Content-Type: application/json' \
    -H 'Idempotency-Key: 7c1f0d1a-0b52-4f55-9d1e-2d2f9c5b8a10' \
    -d '{"body":"great read"}'
HTTP/1.1 201 Created
Location: /v1/articles/42/comments/17
```

The retry, with the same key and the same body, gets the first answer back, and
no second comment exists. The `Location` still says `17`:

```text
$ curl -i -X POST http://127.0.0.1:8080/v1/articles/42/comments \
    -H 'Cookie: sid=9f2c...' -H 'Content-Type: application/json' \
    -H 'Idempotency-Key: 7c1f0d1a-0b52-4f55-9d1e-2d2f9c5b8a10' \
    -d '{"body":"great read"}'
HTTP/1.1 201 Created
Location: /v1/articles/42/comments/17
```

The same key with a different body is a mistake, and the server says so instead
of answering with a stale `17`:

```text
$ curl -i -X POST http://127.0.0.1:8080/v1/articles/42/comments \
    -H 'Cookie: sid=9f2c...' -H 'Content-Type: application/json' \
    -H 'Idempotency-Key: 7c1f0d1a-0b52-4f55-9d1e-2d2f9c5b8a10' \
    -d '{"body":"a different comment"}'
HTTP/1.1 422 Unprocessable Entity
Content-Type: text/plain; charset=utf-8

Unprocessable Entity: this Idempotency-Key was already used with a different request
```

The middleware compares the key together with a fingerprint of the method, the
path and the body, so the same key aimed at `POST /v1/articles` instead is also a
`422`, never article 17's answer replayed.

And a retry that arrives before the first request has finished, say a client
that gave up after a second while the handler needed three, is refused rather
than run in parallel:

```text
$ curl -i -X POST http://127.0.0.1:8080/v1/articles \
    -H 'Cookie: sid=9f2c...' -H 'Content-Type: application/json' \
    -H 'Idempotency-Key: 31d6e0a4-5b7e-4c0b-8f3a-6a1d0c9e2b77' \
    -d '{"title":"Hello Inkwell","body":"body text","tags":[]}'
HTTP/1.1 409 Conflict
Content-Type: text/plain; charset=utf-8

Conflict: a request with this Idempotency-Key is already in progress
```

The key is reserved the instant the first request arrives, not when it
finishes, which is what makes two racing requests tell apart: exactly one of them
wins the reservation and runs the handler. The client's move on a `409` is to
wait a moment and retry with the same key, and it then gets the replay.

Other response headers (rate limit, security headers) are left out above; the
replay carries whatever headers the first response had.

## Keep the keys where every server can see them

The in-process store is correct on one server and silently wrong on two. Put
Inkwell behind a load balancer and the retry lands on the other server, which
has never heard of the key, so the comment is posted twice again. That is why
`idempotency` has no default store.

The `SqlIdempotencyStore` opened above takes a `std/sql` pool and works on
PostgreSQL, MySQL 8 and MariaDB. Inkwell uses PostgreSQL.

`SqlIdempotencyStore(pool)` asks the server what it is and fails at startup if
it is not a database it can serve, instead of on the first request that carries
a key. `purge()` deletes the rows whose time is up. Expired rows never cost
correctness, because a key past its `ttl` counts as new, but nothing else
removes them, so Inkwell sweeps once on each start. A server that stays up for
weeks should run `store.purge()` on a schedule too.

The store shares the application's `db.pool` with its repositories. `Db`
exports that pool read-only, so ordinary startup opens one ORM database and
passes its pool to the store. Tests can still inject a held store through
`buildAppWith`. No Inkwell entity reads the store's `bit_idempotency` table.

### The table is a migration like any other

Inkwell's tables come from `bit migrate`, so this one does too. The builder
expresses the store's contract: a key primary key, binary fingerprint and
cached headers/body, reservation token/state/status, and an indexed expiry
instant. `binary` renders `bytea` on PostgreSQL and `longblob` on MySQL;
`timestamptz` renders `timestamptz` or `datetime(6)` respectively. The store
writes UTC expiry values. Inkwell itself runs on PostgreSQL.

```bit
import { Schema } from "orm"

export class CreateIdempotencyKeys {
  up(s: Schema): ()! {
    s.create("bit_idempotency", (t) => {
      t.text("key_hash")
      t.primaryKey("key_hash")
      t.binary("fingerprint")
      t.text("token")
      t.int("state")
      t.int("status")
      t.binary("headers")
      t.binary("body")
      t.timestamptz("expires_at")
      t.index("expires_at")
    })?
  }

  down(s: Schema): ()! {
    s.drop("bit_idempotency")?
  }
}
```

It lives in `migrations/2026_01_06_000001_create_idempotency_keys.bit`, after
the migrations of the earlier parts, and `bit migrate` applies it with the
rest. Running it again changes nothing.

## Mount it on the two POST routes

Inkwell creates one middleware from its store and passes it to
`mountArticles` and `mountComments`. This is the actual policy statement in
`buildAppFromDb` in [`main.bit`](inkwell/main.bit):

```text
let once = idempotency(IdempotencyPolicy{ store = keys, ttl = idempotencyTtlSeconds })
```

`idempotencyTtlSeconds` is the one-day lifetime declared in that same file.
The excerpt uses the app's existing `keys` argument; it is not a standalone
program. The complete app supplies its store, routes and configuration.

Each module receives the `/v1` group as `app: Routes` and puts the
middleware on a child group that holds only its creating route. Here is the write group copied from
[`mountComments`](inkwell/comments.bit):

```text
let write = app.group("/articles/:id/comments")
write.use(once)
write.post("/", (c) => createComment(c, db))
```

The real `createComment` checks the article, reads the signed-in user,
validates the body and inserts the comment. Two groups can share a prefix,
so the separate read group serves `GET /v1/articles/:id/comments` without
reserving a key. `mountArticles` does the same for `POST /v1/articles`.

Because the middleware sits in front of the handler, a handler that fails, say
a `401` for a missing session or a `400` for a body that does not validate,
releases the key at once. The client fixes the request and retries with the same
key and gets a real run, not a stored error.

## Prove it with a test

A replay and a mismatch are easy to test: send two requests, count the rows. The
`409` is the awkward one, because the first request must still be running when
the second arrives. Inkwell's test does not race threads and hope. It wraps the
store in one that lets the handler run and then holds `finish`, so the key stays
in flight for exactly as long as the test wants:

```bit
import { CachedResponse, IdempotencyClaim, SqlIdempotencyStore } from "web"

class HeldStore {
  inner: SqlIdempotencyStore
  reached: chan<bool>
  release: chan<bool>

  export begin(key: string, fingerprint: string, ttl: i64): IdempotencyClaim! {
    return this.inner.begin(key, fingerprint, ttl)?
  }

  export finish(key: string, token: string, resp: CachedResponse, ttl: i64): ()! {
    this.reached <- true
    <- this.release
    this.inner.finish(key, token, resp, ttl)?
  }

  export abandon(key: string, token: string): ()! {
    this.inner.abandon(key, token)?
  }
}
```

`HeldStore` has the three methods of an idempotency store, so `buildAppWith(cfg,
store)`, the variant of `buildApp` that takes the store as an argument, accepts
it. The test named `POST /v1/articles: a duplicate sent while the first is still
running is 409` in
[`idempotency.test.bit`](inkwell/idempotency.test.bit) calls
`expectInFlightConflict` with a real signed-in request. Read that helper
beside the test to see the row-count assertion against PostgreSQL.

The test sends the request on another thread, waits until the handler has run and
`finish` is holding, sends the duplicate (`409`), lets the first request finish,
and sends it a third time (the replay). Its final assertion asks PostgreSQL,
not the response, how many articles exist: one. The same file tests replay
and mismatch for both routes, plus two signed-in users sending the same key
and body: each gets a separate article and its own replay. Run it with the
rest of the suite; it needs the PostgreSQL that [Testing the API](16-testing-the-api.md) set up:

```text
$ bit test pkg/web/guides/inkwell
```

## Sharp edges

- **Keys must be random.** A key names an action. Use a UUID v4 made once per
  action (once per click of "Publish"), never something guessable such as the
  article title, and reuse it only when retrying that same action.
- **A key belongs to the user who sent it.** The middleware stores a hash of the
  signed-in user and the key, so two users who send the same key and body each
  get their own article, and neither is ever handed the other's response. A
  caller with no session is told apart by the address the connection came from.
  Behind a proxy that is the proxy's address, so name the hops you trust with
  `scope = bySubject(byForwardedIp(hops))` on the policy; see "Whose key is it" in
  the [operational middleware chapter](../docs/operations.md#whose-key-is-it).
- **A handler that outlives `ttl` can run twice.** Its reservation expires, a
  retry takes the key, and now two copies run. Keep `ttl` far longer than the
  slowest `POST /v1/articles`.
- **A panic leaves the key at `409` until `ttl` ends.** A handler that fails
  releases its key, but a handler that panics cannot, so a retry with that key
  gets `409` for the whole window, a day as Inkwell sets it. This is the safe
  direction, a refusal and never a duplicate, and the client can still post the
  action again under a new key.
- **If the store is down, the request fails.** The middleware cannot tell
  whether a duplicate is running, and running the handler anyway would risk the
  double post it exists to prevent. The client's retry is the recovery.
- **The key does not make other side effects safe.** If a handler also calls a
  payment provider, pass that provider the same key; a crash between the call and
  the stored answer repeats it.

## When not to use it

Skip it on routes where a repeat is harmless: `GET` reads, and `PUT` or `DELETE`
on a known id, which already give the same result however often they run.
`POST /v1/articles` and `POST /v1/articles/:id/comments` are the ones that create a
new row each time, which is why they carry it.

## What we built

Inkwell's two creating routes now take an `Idempotency-Key`, kept per signed-in
user. A retry with the same key and body returns the first answer and stores one
row, a retry during the first request is a `409`, and the same key with a
different body is a `422`. The keys live in PostgreSQL next to the data, in
a table that `bit migrate` creates, so every server behind the load balancer
answers for all of them.

Previous: [Sign in with Google](36-sign-in-with-google.md).
Next: [Background jobs](../../../docs/book/31-background-jobs.md).
