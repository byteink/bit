# Idempotency keys: retry a write without doing it twice

<!-- doctest: per-block -->
<!-- doctest: deps orm postgres -->

A reader on a train posts a comment on one of Inkwell's articles. The tunnel
swallows the response, the app's request times out, and the app does the only
sensible thing: it sends the request again. The first one had reached the
server after all.

```text
$ curl -i -X POST http://127.0.0.1:8080/articles/42/comments \
    -H 'Cookie: sid=9f2c...' -H 'Content-Type: application/json' \
    -d '{"body":"great read"}'
HTTP/1.1 201 Created
Location: /articles/42/comments/17

$ curl -i -X POST http://127.0.0.1:8080/articles/42/comments \
    -H 'Cookie: sid=9f2c...' -H 'Content-Type: application/json' \
    -d '{"body":"great read"}'
HTTP/1.1 201 Created
Location: /articles/42/comments/18
```

Two requests, two comments, and the article now shows "great read" twice. The
server did nothing wrong: from where it sits, two identical requests look like
a reader who meant to post twice. The client is the only one who knows the
second request is a retry of the first, so the client has to say so. This part
adds that to Inkwell for `POST /articles` and `POST /articles/:id/comments`,
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

`idempotency` takes a policy: where to remember keys and for how long. This is
a complete program with the in-process store, the one to use while you are
trying it out:

```bit
import {
  App, Config, Ctx, IdempotencyPolicy, MemoryIdempotencyStore, Res, idempotency,
} from "web"

fn createComment(c: Ctx): Res! {
  return c.createdUrl("/articles/42/comments/17")
}

fn main(): ()! {
  let app = App(Config{ secret = "dev-secret-change-me" })
  let write = app.group("/articles/:id/comments")
  write.use(idempotency(IdempotencyPolicy{ store = MemoryIdempotencyStore(10_000), ttl = 86400 }))
  write.post("/", createComment)
  app.listen()?
}
```

`ttl` is how many seconds a key is remembered, here one day: long enough for any
retry a client will make, short enough that the table does not grow forever.
`MemoryIdempotencyStore(10_000)` keeps at most 10,000 keys, and there is no
default store on purpose, for the reason in the next section.

## The three answers

Run the same comment again, this time with a key. The first request runs the
handler:

```text
$ curl -i -X POST http://127.0.0.1:8080/articles/42/comments \
    -H 'Cookie: sid=9f2c...' -H 'Content-Type: application/json' \
    -H 'Idempotency-Key: 7c1f0d1a-0b52-4f55-9d1e-2d2f9c5b8a10' \
    -d '{"body":"great read"}'
HTTP/1.1 201 Created
Location: /articles/42/comments/17
```

The retry, with the same key and the same body, gets the first answer back, and
no second comment exists. The `Location` still says `17`:

```text
$ curl -i -X POST http://127.0.0.1:8080/articles/42/comments \
    -H 'Cookie: sid=9f2c...' -H 'Content-Type: application/json' \
    -H 'Idempotency-Key: 7c1f0d1a-0b52-4f55-9d1e-2d2f9c5b8a10' \
    -d '{"body":"great read"}'
HTTP/1.1 201 Created
Location: /articles/42/comments/17
```

The same key with a different body is a mistake, and the server says so instead
of answering with a stale `17`:

```text
$ curl -i -X POST http://127.0.0.1:8080/articles/42/comments \
    -H 'Cookie: sid=9f2c...' -H 'Content-Type: application/json' \
    -H 'Idempotency-Key: 7c1f0d1a-0b52-4f55-9d1e-2d2f9c5b8a10' \
    -d '{"body":"a different comment"}'
HTTP/1.1 422 Unprocessable Entity
Content-Type: text/plain; charset=utf-8

Unprocessable Entity: this Idempotency-Key was already used with a different request
```

The middleware compares the key together with a fingerprint of the method, the
path and the body, so the same key aimed at `POST /articles` instead is also a
`422`, never article 17's answer replayed.

And a retry that arrives before the first request has finished, say a client
that gave up after a second while the handler needed three, is refused rather
than run in parallel:

```text
$ curl -i -X POST http://127.0.0.1:8080/articles \
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

Inkwell already has PostgreSQL, so its keys go there: `SqlIdempotencyStore`
takes a `std/sql` pool and works on PostgreSQL, MySQL 8 and MariaDB. The app's
`main.bit` builds it next to its other startup work:

```bit
import { SqlIdempotencyStore } from "web"
import { Db } from "orm"

fn openIdempotencyStore(db: Db): SqlIdempotencyStore! {
  let store = SqlIdempotencyStore(db.pool)?
  store.purge()?
  return store
}
```

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

`idempotency(...)` is a `Middleware`, built once from the policy. Inkwell builds
it in `buildApp` and hands it to the two modules that own the routes:

```bit
import { IdempotencyPolicy, IdempotencyStore, Middleware, idempotency } from "web"

const idempotencyTtlSeconds: i64 = 86400

fn guardWrites(keys: IdempotencyStore): Middleware {
  return idempotency(IdempotencyPolicy{ store = keys, ttl = idempotencyTtlSeconds })
}
```

Each module puts it on a group that holds only its `POST` route, next to the
group that holds the reads. `comments.bit` does it like this:

```bit
import { App, Ctx, Middleware, Res } from "web"
import { Db } from "orm"

fn listComments(c: Ctx, db: Db): Res! {
  return c.text("[]")
}

fn createComment(c: Ctx, db: Db): Res! {
  return c.createdUrl("/articles/42/comments/17")
}

export fn mountComments(app: App, db: Db, once: Middleware) {
  let onArticle = app.group("/articles/:id/comments")
  onArticle.get("/", (c) => listComments(c, db))
  let write = app.group("/articles/:id/comments")
  write.use(once)
  write.post("/", (c) => createComment(c, db))
}
```

(The handlers here are stubs so the block stands on its own; the real ones are
in `comments.bit`.) Two groups can share a prefix. A middleware on a group
covers every route of that group, so giving the `POST` its own group is what
keeps `GET /articles/:id/comments` out of it. `articles.bit` does the same for
`POST /articles`.

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
it. The test then reads like the story:

```bit ignore
test "POST /articles: a duplicate sent while the first is still running is 409" {
  let (app, held) = heldApp()
  let cookie = registerAndLogin(app, uniqueName("idem"), "correct horse battery") catch e {
    panic(e.message())
  }
  let title = uniqueName("inflight")
  let req = keyedPost("/articles", cookie, uniqueName("key"), articleBody(title))
  let out = chan<Response>(1)
  spawn sendInto(app, req, out)
  <- held.reached
  let duplicate = app.handle(req)
  assert(duplicate.status == 409, "want 409 while the first is running")
  held.release <- true
  let first = <- out
  assert(first.status == 201, "want 201 from the first request")
  let after = app.handle(req)
  assert(after.status == 201, "want the replayed 201")
  assert(countRows(articleCount, title) == 1, "exactly one row must exist")
}
```

The test sends the request on another thread, waits until the handler has run and
`finish` is holding, sends the duplicate (`409`), lets the first request finish,
and sends it a third time (the replay). The last line asks PostgreSQL, not the
response, how many articles exist: one. The same file does the replay and the
mismatch for both routes. Run it with the rest of the suite; it needs the
PostgreSQL that [Testing the API](16-testing-the-api.md) set up:

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
  the operational middleware chapter.
- **A handler that outlives `ttl` can run twice.** Its reservation expires, a
  retry takes the key, and now two copies run. Keep `ttl` far longer than the
  slowest `POST /articles`.
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
`POST /articles` and `POST /articles/:id/comments` are the ones that create a
new row each time, which is why they carry it.

## What we built

Inkwell's two creating routes now take an `Idempotency-Key`, kept per signed-in
user. A retry with the same key and body returns the first answer and stores one
row, a retry during the first request is a `409`, and the same key with a
different body is a `422`. The keys live in PostgreSQL next to the data, in a table that `bit migrate` creates,
so every server behind the load balancer answers for all of them.

Previous: [Operations](17-operations.md). This is the last chapter written so
far; the course continues from here.
