# Idempotency keys in PostgreSQL and MySQL

<!-- doctest: per-block -->
<!-- doctest: deps postgres mysql -->

Inkwell's "Publish" button posts an article, and the request is slow enough
that a phone on a bad connection gives up and sends it again. Without a guard
the article is published twice. The `idempotency` middleware
([Operational middleware](operations.md)) is that guard: a request that carries
an `Idempotency-Key` header runs its handler once, and a retry with the same
key gets the first answer back. Where "seen this key" lives is the store's
decision, and the in-process store only remembers what one server saw. Run
Inkwell on two servers behind a load balancer and the retry lands on the other
one, which has never heard of the key.

If Inkwell already has a database, `SqlIdempotencyStore` keeps the keys there,
so every server answers for all of them. It runs on PostgreSQL, on MySQL 8 or
newer and on MariaDB 10.6 or newer, and it needs no package beyond `web`: it
takes a `std/sql` `Pool`, the one you already use for everything else.

## The simplest thing that works

Create the table once with `migrateSqlIdempotency`, build the store from the
pool, and give it to the middleware:

```bit
import { App, Config, IdempotencyPolicy, SqlIdempotencyStore, idempotency, migrateSqlIdempotency } from "web"
import { pool, Datasource } from "std/sql"
import { adapter } from "postgres"
import { env } from "std/os"

fn main(): ()! {
  let db = pool(adapter(), Datasource{ uri = env("DATABASE_URL") })?
  migrateSqlIdempotency(db)?
  let store = SqlIdempotencyStore(db)?
  let app = App(Config{ secret = env("APP_SECRET") })
  app.use(idempotency(IdempotencyPolicy{ store = store, ttl = 86400 }))
  app.post("/articles", (c) => c.text("published").status(201))
  app.listen()?
}
```

A client now sends `Idempotency-Key: 7c1f...` with each publish. The first
request with that key runs the handler. A retry with the same key, method, path
and body gets the same `201 published` back with the handler unrun. The same key
with a different body is `422`, and a retry that arrives while the first request
is still running is `409`.

The same program on MySQL or MariaDB changes the adapter and the URL and nothing
else:

```bit
import { App, Config, IdempotencyPolicy, SqlIdempotencyStore, idempotency, migrateSqlIdempotency } from "web"
import { pool, Datasource } from "std/sql"
import { adapter } from "mysql"
import { env } from "std/os"

fn main(): ()! {
  let db = pool(adapter(), Datasource{ uri = "mysql://app:secret@localhost/inkwell" })?
  migrateSqlIdempotency(db)?
  let store = SqlIdempotencyStore(db)?
  let app = App(Config{ secret = env("APP_SECRET") })
  app.use(idempotency(IdempotencyPolicy{ store = store, ttl = 86400 }))
  app.listen()?
}
```

`SqlIdempotencyStore(db)` asks the server what it is with one `SELECT version()`
and keeps the answer, so a server it cannot serve fails at startup naming what it
reported, not on the first request that carries a key:

```text
web: SqlIdempotencyStore supports PostgreSQL, MySQL 8 or newer and MariaDB 10.6 or newer; the server reported '5.7.44-log'
```

## Why it is safe when two requests arrive together

Two servers can receive the same key in the same millisecond. A store that looked
the key up and then wrote it would let both see "not seen" and both run the
handler. `begin`, the store's first step, is therefore one `INSERT` that only
creates the row when the key is absent:

```text
INSERT ... ON CONFLICT (key_hash) DO NOTHING                      PostgreSQL
INSERT ... ON DUPLICATE KEY UPDATE key_hash = key_hash            MySQL, MariaDB
```

The table's primary key serializes concurrent inserts of one key, so of any
number of callers racing a new key exactly one inserts. Neither engine says
reliably which caller that was, so each caller reads the row back and compares
its token: the winner is the caller whose freshly minted 128-bit token is the one
stored. Every other caller gets the winner's entry and is told `409` (still
running) or handed the stored response (done). Both statements run on one pinned
writer connection, so a read replica's lag cannot hide the row just written.

The live tests race 16 connections on one key, five times over, on PostgreSQL,
MySQL 8 and MariaDB 11, and require exactly one winner each time.

## What the table keeps

One row per key, in `bit_idempotency`. The primary key is the SHA-256 of the
`Idempotency-Key`, hex: a header has no length limit and no character set while a
column has both, so hashing gives every key one fixed-width value on both
engines. The request fingerprint, the response headers and the response body are
binary columns, so a body of any bytes comes back identical.

`migrateSqlIdempotency` runs `sqlIdempotencyMigration(dialect)`, a plain
`[]string` with one entry per statement, for the dialect the server reported. If
your app has its own migration tool, run those statements from it instead:

```bit
import { sqlIdempotencyMigration, IdempotencyDialect } from "web"

fn statements(): []string {
  return sqlIdempotencyMigration(IdempotencyDialect.Postgres)
}
```

## Expiry runs on the database's clock

`expires_at` is written and compared with the server's own `NOW()` (PostgreSQL)
or `UTC_TIMESTAMP(6)` (MySQL), never a time the application computed, so servers
with skewed clocks agree on when a key lapses. A key whose window ended is
reusable at once: `begin` finds the expired row, deletes it with a statement that
is itself conditional on `expires_at`, and inserts again. `finish` restarts the
clock from its own call, so a slow handler's answer is remembered for the full
`ttl`.

Expired rows therefore never cost correctness, only space. `purge` deletes them
and returns how many it removed; run it on a schedule, for example from a
[jobs](../../jobs/docs/getting-started.md) cron entry:

```bit
import { SqlIdempotencyStore } from "web"

fn sweep(store: SqlIdempotencyStore): int! {
  return store.purge()?
}
```

## Whose reservation is it

`finish` and `abandon` are one conditional statement each:

```text
UPDATE ... WHERE key_hash = ? AND token = ? AND state = 0 AND expires_at > NOW()
DELETE ... WHERE key_hash = ? AND token = ? AND state = 0
```

Say a handler runs longer than `ttl`: its reservation expires, a retry inserts a
new one under the same key, and then the first handler fails. A `DELETE` naming
only the key would remove the retry's reservation and let a third request run the
handler. With the token, the first handler's `abandon` matches no row and changes
nothing; a late `finish` is refused the same way. Zero rows changed is success,
because the caller has nothing left to protect.

## Failures

`begin` failing means the middleware cannot tell whether a duplicate is running,
so it does not run the handler: the request fails and the client's retry is the
recovery. If the insert committed but its reply was lost, the key stays reserved
until `ttl` ends and a retry gets `409`, never a second run. `finish` failing only
costs the cache write; the response goes out regardless and the failure is
logged. `ttl` is 1 to 2,000,000,000 seconds; anything else is refused before a
statement is sent.

## Sharp edges

- A handler that raises releases its reservation at once. A handler that panics
  cannot, so the key stays `409` until `ttl` ends; keep `ttl` short enough that
  this is bearable.
- A handler that runs longer than `ttl` loses its reservation, and a second
  request can run the handler at the same time, which no token can prevent. Pick
  a `ttl` longer than your slowest handler.
- The store does not make a handler's own side effects idempotent: a payment
  provider call made before `finish` can still happen twice if the process dies in
  between. Pass the provider the same idempotency key.

## When not to use it

On a single server, `MemoryIdempotencyStore` is enough and one fewer network hop.
If Inkwell has Redis and not a database, `RedisIdempotencyStore` in `webredis`
does the same job with Redis expiry in place of a table.

Next: [Errors](errors.md).
