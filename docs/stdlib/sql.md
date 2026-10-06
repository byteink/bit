# std/sql

When Inkwell outgrows a folder of files, it needs a real database - and it
needs the storage swap to cost one import line, not a rewrite of every
handler. `std/sql` is why that works: a driver contract every database
package builds on, plus a connection pool, typed row reading, and closures
for transactions. Reach for it through a driver package like `pkg/postgres`
or `pkg/mysql`, not directly - see [Writing a driver](#writing-a-driver) for
how those fit together.

**The only way to supply a value is `params []Value`.** `query`/`exec` take
the SQL text you wrote and an ordered list of typed `Value`s as two separate
arguments. Nothing in this module ever builds SQL text by pasting a value
into it - that is the whole defense against SQL injection, and it is
structural: there is no function here that accepts a string with values
already substituted in, so there is nothing to misuse into one.

<!-- doctest: per-block -->

## Opening a pool and running a query

A pool is a bounded set of physical connections, handed out one at a time
and returned when the caller is done - the third way to reach a database,
after "one connection per request" (a burst exhausts the server) and "one
shared connection" (requests serialize on it, and a transaction on it leaks
into every other request). `pool` builds one from a `Datasource` (what to
connect to) and an `Adapter` (how - supplied by a driver package):

```bit
import { Adapter, Datasource, Pool, pool } from "std/sql"

fn openInkwellDb(a: Adapter, databaseUrl: string): Pool! {
  return pool(a, Datasource{ uri = databaseUrl })?
}
```

`Pool.query` runs SQL and returns `Rows`; `Pool.exec` runs SQL for its
effect and returns the number of rows it changed. **A query's connection
stays checked out until its `Rows` is closed** - a cursor lives on the
connection that produced it, so an unclosed `Rows` leaks a connection the
same way an unclosed file leaks a descriptor.

```bit
import { Pool, Value, sqlReqText } from "std/sql"

fn draftTitle(db: Pool, id: string): string! {
  let rows = db.query("SELECT title FROM drafts WHERE id = ?", [Value.Text(id)])?
  defer rows.close()
  let has = rows.next()?
  if (!has) {
    fail newError("no such draft: ${id}")
  }
  return sqlReqText(rows, rows.columns(), "title")?
}

fn renameDraft(db: Pool, id: string, title: string): ()! {
  db.exec("UPDATE drafts SET title = ? WHERE id = ?", [Value.Text(title), Value.Text(id)])?
}
```

## Mapping rows into a class

Reading columns one at a time with `sqlReqText`/`sqlReqInt`/... works for
one query. For a whole table, `find`/`findOne`/`findOneOrFail` map every row
straight into a plain class - no separate mapper to write or keep in sync:

```bit
import { Executor, find, findOne, findOneOrFail, Value } from "std/sql"

class Draft {
  id: string,
  title: string,
  wordCount: i64,
}

fn publishedDrafts(db: Executor): []Draft! {
  return find<Draft>(
    db,
    "SELECT id, title, word_count FROM drafts WHERE status = ?",
    Value.Text("published"),
  )?
}

fn draftById(db: Executor, id: string): Option<Draft>! {
  return findOne<Draft>(db, "SELECT id, title, word_count FROM drafts WHERE id = ?", Value.Text(id))?
}
```

A field's column is its own name in **snake_case** (`wordCount` claims
`word_count`) unless the field carries `@column("...")`. A result column no
field claims is ignored, so `SELECT *` against a class that only wants three
columns works fine. `findOne` returns `Option.None` for zero rows - a `GET
/:id` miss is ordinary traffic, not a failure - and fails with a
`SqlRowError` if the query matched more than one; `findOneOrFail` also fails
on zero.

`db` above is typed `Executor`, not `Pool`: an interface both `Pool` and a
running transaction satisfy, so `publishedDrafts` runs standalone or inside
a caller's transaction with no second entry point.

## Transactions are a closure, not a begin/commit pair

There is no `Tx` for a caller to `begin` and `commit` by hand. `tx` runs a
block on one pinned connection: COMMIT when the block returns, ROLLBACK on a
failure or a panic, connection back in the pool either way.

```bit
import { Pool, Value, tx } from "std/sql"

fn moveDraftToArchive(db: Pool, id: string): ()! {
  tx(db, (t) => {
    t.exec("UPDATE drafts SET status = 'archived' WHERE id = ?", [Value.Text(id)])?
    t.exec("INSERT INTO archive_log (draft_id) VALUES (?)", [Value.Text(id)])?
  })?
}
```

The reason is `?`. In a hand-written `let t = db.begin()?` / `t.exec(...)?` /
`t.commit()?` form, every `?` between begin and commit is an early return
that skips the rollback - the transaction stays open and the connection
never comes back, and under load the pool exhausts with nothing in the logs
naming why. The closure makes that failure unreachable instead of merely
unlikely; the handle `t` stops working the moment the block returns, so
nothing can hold on to it and run statements on a connection the pool has
since handed to someone else.

`txValue<T>` is the same shape, returning what the block computed once the
commit has succeeded - useful for an inserted id, since nothing is returned
on a failed transaction:

```bit
import { Pool, Value, asInt, txValue } from "std/sql"

fn createDraft(db: Pool, title: string): i64! {
  return txValue<i64>(db, (t) => {
    let rows = t.query("INSERT INTO drafts (title) VALUES (?) RETURNING id", [Value.Text(title)])?
    defer rows.close()
    let has = rows.next()?
    if (!has) {
      fail newError("insert returned no id")
    }
    return asInt(rows.value(0))?
  })?
}
```

`txAt`/`txValueAt` take a `TxOptions` before the block instead of the
database's own defaults: an `Isolation` level, and `readOnly`. A read-only
transaction makes the server refuse every write in it with its own error (the
Postgres `cannot execute INSERT in a read-only transaction`, the MySQL
`Cannot execute statement in a READ ONLY transaction`), and lets the database
skip write bookkeeping; reads work as usual:

```bit
import { Pool, Value, Isolation, TxOptions, asInt, txAt } from "std/sql"

fn draftCount(db: Pool): ()! {
  txAt(db, TxOptions{ isolation = Isolation.RepeatableRead, readOnly = true }, (t) => {
    let rows = t.query("SELECT COUNT(*) FROM drafts", []Value(0))?
    defer rows.close()
    let _ = rows.next()?
    println("drafts: ${asInt(rows.value(0))?}")
  })?
}
```

**A `tx` nested inside another is a SAVEPOINT**, not a second
transaction - naming which one by passing the handle, since Bit has no
ambient "current transaction" a shared `Pool` could answer for the wrong
caller. An inner failure rolls back only the inner block; the outer one
commits normally.

## Pinning a connection without a transaction

`tx`/`txValue` pin one connection for a block AND wrap it in
BEGIN/COMMIT. Some things need the pin without the transaction: a
session-scoped server lock (`SELECT pg_advisory_lock(...)`, `SELECT
GET_LOCK(...)`) is tied to the connection that took it, not to any SQL
transaction, and MySQL DDL cannot run inside one at all. Calling `Pool.exec`
per statement does not pin anything - each call checks a connection out and
back, so the lock can end up on a connection the pool has since handed to
someone else, and the lock then protects nothing. `Pool.pinned<T>` is the
fix: one connection, for the whole block, with no BEGIN/COMMIT of its own.

```bit
import { Pool, Value, Executor } from "std/sql"

fn archiveWithLock(db: Pool, id: string): int! {
  return db.pinned<int>((conn) => {
    conn.exec("SELECT GET_LOCK('archive', -1)", []Value(0))?
    defer releaseArchiveLock(conn)
    return conn.exec("UPDATE drafts SET status = 'archived' WHERE id = ?", [Value.Text(id)])?.rowsAffected
  })?
}

fn releaseArchiveLock(conn: Executor) {
  conn.exec("SELECT RELEASE_LOCK('archive')", []Value(0)) catch _ {
    return
  }
}
```

`defer` inside the block runs when the block returns (SPEC §18.5) - on the
ordinary path and on a failure inside `f` alike - so the lock releases and
the connection goes back to the pool together, whatever `f` did.

## Read replicas and read-your-own-writes

Set `Datasource.replicas` and `pool` opens one connection pool per replica
URI alongside the writer. `Pool.query` then reads from a replica when one is
in rotation; every write, and everything inside a transaction, always goes
to the writer.

The catch: right after a write, a read on the same request must not land on
a replica that has not caught up yet, or the caller sees its own change as
if it never happened. `Pool.session()` is the fix - a per-request handle
that switches to the writer for every read once it has written:

```bit
import { Pool, Value, sqlReqText } from "std/sql"

fn createThenReadBack(db: Pool, title: string): string! {
  let s = db.session()
  s.exec("INSERT INTO drafts (title) VALUES (?)", [Value.Text(title)])?
  let rows = s.query("SELECT title FROM drafts WHERE title = ?", [Value.Text(title)])?
  defer rows.close()
  rows.next()?
  return sqlReqText(rows, rows.columns(), "title")?
}
```

A handler that calls `pool.query`/`pool.exec` directly instead of routing
every statement through one `Session` gets no protection, silently - there
is nothing to forget out loud, just a stale read that never errors.

## Columns beyond the wire's five types

`Value` carries `Null`/`Int`/`Float`/`Bool`/`Text`/`Blob` - what every
driver can put on the wire. A `decimal`, a timestamp, a date, a uuid, a JSON
document and a Postgres array all still arrive as `Value.Text`, so
`std/sql` ships one parsing accessor per type instead of making every
caller write it by hand:

```bit
import {
  Rows, sqlReqInt, sqlReqTimestamp, sqlOptTimestamp, sqlReqUuid,
  sqlReqJsonAs, sqlReqArray, sqlElemText, sqlReqDecimal,
} from "std/sql"
import { Timestamp } from "std/time"
import { UUID } from "std/uuid"
import { Json } from "std/json"

@json class DraftMeta {
  editor: string,
}

class DraftRow {
  id: i64,
  externalId: UUID,
  publishedAt: Timestamp,
  cancelledAt: Option<Timestamp>,
  meta: DraftMeta,
  tags: []string,
  price: decimal,
}

fn draftRowMapper(rows: Rows): DraftRow! {
  let cols = rows.columns()
  return DraftRow{
    id = sqlReqInt(rows, cols, "id")?,
    externalId = sqlReqUuid(rows, cols, "external_id")?,
    publishedAt = sqlReqTimestamp(rows, cols, "published_at")?,
    cancelledAt = sqlOptTimestamp(rows, cols, "cancelled_at")?,
    meta = sqlReqJsonAs<DraftMeta>(rows, cols, "meta")?,
    tags = sqlReqArray<string>(rows, cols, "tags", sqlElemText)?,
    price = sqlReqDecimal(rows, cols, "price")?,
  }
}
```

Every type has a required (`sqlReq...`) and optional (`sqlOpt...`) form; the
required form fails naming the column on `NULL`, the optional form decodes
`NULL` to `None`. Pass a hand-written mapper like `draftRowMapper` above to
`sqlFindMany`/`sqlFindOne`/`sqlFindOneOrFail` in place of the generated one
whenever a class has a field `find<T>` cannot map on its own - a `decimal`,
a nested `@json` class, or an array.

## Writing a driver

Two drivers exist today, `pkg/postgres` and `pkg/mysql`. Neither implements
`Driver`/`Registry` directly - both plug into the pool through their own
`Adapter`, the one thing a driver implements for `pool`:

```bit
import { Datasource, Conn } from "std/sql"

interface DemoAdapter { connect(cfg: Datasource): Conn! }
```

Switching databases costs one import line: the same handler compiles
against `pkg/postgres` and `pkg/mysql` with nothing else changed. `connect`
reads whichever form of `cfg` the caller filled in, applies the driver's
own default port when `cfg.port` is 0, and renders `cfg.sslmode` into its
own wire spelling.

`Driver`/`Conn`/`Rows`/`Stmt`/`Tx`/`Registry` are the lower-level path -
what a driver that registers itself **by name** implements instead
(`reg.register("postgres", d)`, `reg.open("postgres", dsn)`), and what a
program reaches for directly when it wants one connection with no pool at
all, including `Stmt` for a query prepared once and run many times:

```bit
import { Registry, Driver, Conn, Value } from "std/sql"

fn queryOnce(reg: Registry, driverName: string, dsn: string, id: string): ()! {
  let conn = reg.open(driverName, dsn)?
  defer conn.close()
  let stmt = conn.prepare("SELECT title FROM drafts WHERE id = ?")?
  defer stmt.close()
  let rows = stmt.query([Value.Text(id)])?
  defer rows.close()
}
```

`Value`/`Driver`/`Conn`/`Rows`/`Stmt`/`Tx`/`Registry` are frozen: changing
any of their exported shapes is at minimum a minor release. `Value` can
still grow a new variant when a database needs one none of the others do -
that is how `Bool` was added, for Postgres's native boolean wire type - but
every other type keeps its shape, and a `match` over `Value` with no
catch-all is a compile error the day a new variant needs handling, naming
the exact call site.

A file-based database like SQLite has no host, port or TLS to negotiate,
and no server arbitrating many physical connections - a file-based adapter
ignores `host`/`port`/`sslmode`, and needs its own policy (a single writer,
or retrying on a busy file) instead of the pool's concurrency model.

## Sharp edges

- **`sslmode` defaults to `Negotiate`**, not to a verified TLS connection -
  a field of enum type takes its first declared variant when unset, and
  that variant was chosen to be the least surprising default, not the most
  secure one. Set `sslmode = SslMode.VerifyFull` explicitly for anything
  that leaves your own network.
- **`acquireTimeout` can never be 0.** Zero would mean "wait forever", so an
  outage would park every caller with no error and no log line;
  `Datasource.validate` (which `pool` always calls first) rejects it.
- **A bool column often is not one.** SQL has no boolean wire type of its
  own on most drivers - a MySQL `TINYINT(1)` and SQLite both arrive as
  `Value.Int`, so `sqlReqBool`/`sqlOptBool` read zero/nonzero from an `Int`
  column as well as a native `Bool`.
- **`decimal` is never a `Value` variant.** Every driver sends
  `DECIMAL`/`NUMERIC` as `Value.Text`; `sqlReqDecimal`/`sqlOptDecimal` parse
  it, so `find<T>` cannot map a `decimal` field on its own - use a
  hand-written mapper as shown above.
- **`sqlReqArray<T>` is one dimension.** A Postgres array-of-arrays fails by
  name rather than silently flattening.

## When not to use std/sql

- **A single script with no concurrent callers.** `Registry.open` gives you
  one `Conn`, serialized automatically, with none of `Pool`'s bookkeeping -
  reach for `pool` once more than one goroutine touches the database at
  once.
- **Building SQL text from user input.** Every value goes through `params`,
  never through string interpolation into `sqlText` - there is no supported
  way around this, by design.

## Where to go next

- [std/json](/std/json) - for the `meta`-style JSON columns above.
- [The Book, chapter 10](/book/10-a-real-database) - Inkwell's file store
  becomes a SQL-backed one.
- [Errors](/language/errors) - the `!`/`catch`/`fail` shapes every fallible
  call here uses.

## The wire value

### `Value`

The sum type every driver must carry across the boundary between Bit code
and a database: `Null`, `Int(int)`, `Float(f64)`, `Bool(bool)`, `Text(string)`,
or `Blob([]byte)`. `Bool` exists because Postgres has a native boolean wire
type; a database with none, such as MySQL's `TINYINT(1)` or SQLite, maps a
boolean column to `Int` instead.

### `isNull(v: Value): bool`

Whether `v` is SQL NULL.

### `asInt(v: Value): int!`

The typed accessor for an `Int` value. Fails on any other variant; `match
(v)` directly when the column's type is not known ahead of time.

### `asFloat(v: Value): f64!`

The typed accessor for a `Float` value. Fails on any other variant.

### `asBool(v: Value): bool!`

The typed accessor for a `Bool` value. Fails on any other variant. A driver
that maps a boolean column to `Int` is read with `asInt`/`sqlReqBool`
instead.

### `asText(v: Value): string!`

The typed accessor for a `Text` value. Fails on any other variant.

### `asBlob(v: Value): []byte!`

The typed accessor for a `Blob` value. Fails on any other variant.

### `sqlValue<V>(v: V): Value`

Turns a plain value into the `Value` a query binds, so calling code never
writes a `Value` variant by hand. `sqlValue(draft.title)` is `Value.Text`,
`sqlValue(draft.id)` is `Value.Int`, `sqlValue(draft.summary)` (an
`Option<string>` field) is `Value.Null` when unset. `V` must be
`string`, `int`/`i64`, `bool`, `f64`, `[]byte`, or `Option<>` of one of
those. Any other type is a compile error naming it, not a runtime
surprise.

## The driver contract

### `Driver`

What every concrete driver package implements: `open(dsn: string): Conn!`.
`dsn` is a driver-specific connection string; its format is entirely the
driver's own.

### `Conn`

A single logical database connection, as handed back by `Registry.open`:
`query(sqlText, params): Rows!`, `exec(sqlText, params): ExecResult!`,
`prepare(sqlText): Stmt!`, `begin(opts: TxOptions): Tx!`, `close()`. `query` runs SQL
expected to produce a row set; `exec` runs SQL expected only to change rows
and reports what it did as an `ExecResult`. Several green threads may hold
and use the same `Conn` at once.

### `ExecResult`

What `exec` reports: `rowsAffected: int`, the server's own count of the rows
the statement changed, and `lastInsertId: Option<int>`, the id the server
generated for an auto-increment column. MySQL reports the id in the reply to
the statement itself: for a multi-row `INSERT` it is the first generated id,
and `Some(0)` when the statement generated none. A driver whose protocol has
no such report leaves it `None`; on Postgres, `INSERT ... RETURNING` through
`query` is how a generated id comes back.

```bit
import { Pool, Value } from "std/sql"

fn addNote(db: Pool, body: string): int! {
  let res = db.exec("INSERT INTO notes (body) VALUES (?)", [Value.Text(body)])?
  match (res.lastInsertId) {
    Some(id) => { return id }
    None => { fail newError("this driver reports no generated id") }
  }
}
```

### `TxOptions`

What a transaction is opened with, passed to `Conn.begin` so the driver emits
its own dialect's one correct form: `isolation: Isolation` and `readOnly:
bool`. The zero value is the database's own defaults, and `Isolation.Default`
is variant 0 for exactly that reason. `txAt`/`txValueAt` pass the `TxOptions` they
were given, and `tx`/`txValue` pass the zero value; a driver reads it:

```text
begin(opts: TxOptions): Tx! {
  let level = isolationName(opts.isolation)   // "" for Isolation.Default
  // Postgres: BEGIN ISOLATION LEVEL <level> [READ ONLY], one statement.
  // MySQL: SET TRANSACTION ISOLATION LEVEL <level>, then
  //        START TRANSACTION [READ ONLY]; it refuses the SET once open.
}
```

### `isolationName(level: Isolation): string`

The SQL spelling of `level` (`"READ COMMITTED"`, `"SERIALIZABLE"`, ...), or `""`
for `Isolation.Default`, which asks the database for nothing. Drivers use it
to build their `begin` statements.

### `Rows`

A cursor over a result set: `next(): bool!`, `columns(): []string`,
`value(col: int): Value`, `close()`. `next` advances to the next row,
returning `false`, not an error, once the set is exhausted. `columns` is the
result set's column names in order; `value` reads column `col` (0-based) of
the current row.

### `Stmt`

A prepared statement, from `Conn.prepare`: `query(params): Rows!`,
`exec(params): ExecResult!`, `close()`. `params` is positional, in the same order
as the placeholders in the SQL text the statement was prepared from.

### `Tx`

An open transaction, from `Conn.begin`: `query`, `exec`, `commit(): ()!`,
`rollback(): ()!`. `query`/`exec` behave exactly as `Conn`'s do, scoped to
this transaction. Application code never calls `commit`/`rollback` by hand;
see the [Transactions](#transactions-are-a-closure-not-a-begincommit-pair)
section above for why.

### `Registry`

The driver registry a program builds once and shares. Build one with
`Registry()`, have every driver's own setup code call `register` on it,
and pass it to `open` wherever a connection is needed.

### `Registry()`

An empty `Registry`, ready for `register` calls.

### `Registry.register(name: string, d: Driver): ()!`

Adds `d` under `name`. Fails if `name` is already registered.

### `Registry.open(driverName: string, dsn: string): Conn!`

Looks up the driver registered as `driverName` and opens `dsn` with it. The
returned `Conn` is wrapped so several green threads sharing it never
interleave calls on the one underlying socket it represents.

## The pool

### `pool(a: Adapter, cfg: Datasource): Pool!`

A pool of connections to the database `cfg` names, opened through `a`.
Nothing connects here: `cfg` is checked first and connections are opened on
demand, up to `cfg.maxOpen`. Fails only on a configuration that cannot
describe a pool, so an unset connection string surfaces here, not as a
network error later.

### `Datasource`

Everything a pool needs: one database to reach, and the shape of the pool
that reaches it. Every field has a default, so `Datasource{ uri = ... }` is
a complete configuration.

| Field | Default | Meaning |
| --- | --- | --- |
| `uri` | `""` | Whole target in one string; exclusive with the fields below. |
| `host`/`port`/`user`/`password`/`database` | `""`/`0`/... | The individual form. `port = 0` means the adapter's own default. |
| `sslmode` | `SslMode.Negotiate` | TLS negotiation. |
| `connectTimeout` | `10_000` | ms for one connect attempt. |
| `maxOpen` | `10` | Ceiling on physical connections, in use plus idle. |
| `maxIdle` | `10` | How many may sit idle before a returned connection is closed instead. |
| `maxLifetime` | `1_800_000` | ms after opening before retiring a connection; `<= 0` is no limit. |
| `maxIdleTime` | `600_000` | ms idle before retiring; `<= 0` is no limit. |
| `acquireTimeout` | `5_000` | ms a caller waits for a connection; never 0. |
| `statementCache` | `0` | Server-side prepared statements kept per connection; 0 is off. |
| `replicas` | `[]` | Read replica URIs; empty means every statement runs on the writer. |
| `replicaBackoff` | `2_000` | ms a replica that failed a statement stays out of rotation. |

### `Datasource.validate(): ()!`

Rejects a `Datasource` that cannot describe a pool, before anything opens a
socket: neither `uri` nor `host` set, both set, a `maxOpen` below 1, a
negative `maxIdle`, or an `acquireTimeout` below 1. `pool` calls this first,
so a program that builds its pool through `pool` never has to call it
itself.

### `SslMode`

How the driver should negotiate TLS: `Negotiate`, `VerifyFull`, `VerifyCa`,
`Require`, `Disable`. Each adapter renders these into whatever its own wire
protocol spells. `Negotiate` is the first declared variant deliberately,
because a field of enum type with no explicit default takes its enum's
first variant, and that is the value an omitted `sslmode` means.

### `Adapter`

What turns a `Datasource` into a live connection: `connect(cfg: Datasource):
Conn!`, the one thing a driver package implements for `pool`. `connect`
reads whichever form of `cfg` the caller filled in, applies its own default
port when `cfg.port` is 0, and renders `cfg.sslmode` into its own protocol's
spelling.

### `Pool`

A bounded set of connections to one database, safe to share across green
threads. Built by `pool`; closed by `Pool.close`.

### `Pool.query(sqlText: string, params: []Value): Rows!`

Runs `sqlText` and returns its rows. The connection stays checked out until
the returned `Rows` is closed, so a caller that never closes its `Rows`
leaks a connection.

### `Pool.exec(sqlText: string, params: []Value): ExecResult!`

Runs `sqlText` for its effect and returns what it did (`ExecResult`). The
connection is back in the pool before this returns.

### `Pool.close()`

Closes every idle connection and fails every parked caller. A connection
still checked out is closed as it is returned. Safe to call more than once.

### `Pool.tx(f: (Tx) => ()!): ()!`

`tx` as a method: runs `f` in a transaction at the database's own isolation
level.

### `Pool.txAt(opts: TxOptions, f: (Tx) => ()!): ()!`

`Pool.tx` with the isolation level and read-only flag in `opts` instead of the
database's own defaults.

### `Pool.txValue<T>(f: (Tx) => T!): T!`

`txValue` as a method: runs `f` in a transaction and returns what `f`
returned, once the commit has succeeded.

### `Pool.txValueAt<T>(opts: TxOptions, f: (Tx) => T!): T!`

`Pool.txValue` with `opts` instead of the database's own defaults.

### `Pool.session(): Session`

Opens a per-request read-your-own-writes handle. See the read replicas
section above for what it protects against.

### `Pool.pinned<T>(f: (Executor) => T!): T!`

Checks one connection out, hands it to `f` as an `Executor` for the whole
call, and returns it when `f` returns - on the ordinary path and on a
failure inside `f` alike. Unlike `tx`/`txValue`, opens no transaction: `f`
may run any mix of statements, including ones a transaction cannot carry,
while still never sharing the connection with another caller. See "Pinning
a connection without a transaction" above.

### `FatalError`

The marker a driver failure carries when the failure has poisoned the
connection rather than merely failing the statement: `message(): string`,
`transportFatal(): bool`. The pool never hands such a connection out again.
A failure that does not implement `FatalError`, such as a constraint
violation or a syntax error, leaves the connection usable.

### `transportError(detail: string): error`

A ready-made `FatalError`, for a driver with no error type of its own to
extend.

## Read replicas and sessions

### `Session`

A per-request handle, from `Pool.session`. Once `Session.exec` has committed
a write, every later `Session.query` on the same handle goes to the writer,
never a replica, until the caller takes a fresh `Session`.

### `Session.query(sqlText: string, params: []Value): Rows!`

Routes to the writer once this handle has written; otherwise the same
routing `Pool.query` itself uses.

### `Session.exec(sqlText: string, params: []Value): ExecResult!`

Always runs on the writer, and marks this handle sticky once the write has
actually committed.

## Transactions

### `tx(db: Executor, f: (Tx) => ()!): ()!`

Runs `f` in a transaction at the database's own isolation level. `db` is the
pool, or the handle of a transaction already running, in which case this is
a savepoint inside it rather than a second transaction.

### `txAt(db: Executor, opts: TxOptions, f: (Tx) => ()!): ()!`

`tx`, with the isolation level and read-only flag in `opts` instead of the
database's own defaults. A `txAt` nested inside a running transaction is a
savepoint and cannot change either: asking for a level or `readOnly = true`
there fails.

### `txValue<T>(db: Executor, f: (Tx) => T!): T!`

`tx`, returning what the block returned once the transaction has committed.
Nothing is returned on a failure, because a value is only a result if the
work behind it is durable.

### `txValueAt<T>(db: Executor, opts: TxOptions, f: (Tx) => T!): T!`

`txValue`, with `opts` instead of the database's own defaults. This is
the one implementation; the other three are spellings of it.

### `Executor`

Anything statements can run on: `query(sqlText, params): Rows!`,
`exec(sqlText, params): ExecResult!`. A `Pool` and a running `Tx` both satisfy it,
so a function that takes an `Executor` instead of a `Pool` composes: the
caller decides whether it runs standalone or inside a transaction.

### `Isolation`

How much of other transactions' work a transaction may see: `Default`,
`ReadUncommitted`, `ReadCommitted`, `RepeatableRead`, `Serializable`.
`Default` issues no statement at all, leaving whatever the database and its
driver are configured for in force.

## Mapping rows into a class

### `find<T>(db: Executor, sqlText: string, ...args: Value): []T!`

Maps every row into `T`: a plain class, or one of `i64`/`f64`/`bool`/
`string`/`[]byte` for a single-column result. No mark on `T` is required;
generation happens on demand from the call site itself.

### `findOne<T>(db: Executor, sqlText: string, ...args: Value): Option<T>!`

`find`, for a query expected to match at most one row. The absent row is
`Option.None`, never an error. More than one row fails with a `SqlRowError`.

### `findOneOrFail<T>(db: Executor, sqlText: string, ...args: Value): T!`

`findOne`, requiring exactly one row: zero rows fails distinguishably from
every mapping error, and more than one row also fails.

### `SqlRowCause`

Why one row failed to become a `T`: `MissingColumn`, `TypeMismatch`,
`NullField`, `ColumnCount`, `NoRows`, `TooManyRows`.

### `SqlRowError`

The error every row-mapping failure produces: `cause`, `column` (the claimed
column name, empty for `NoRows`/`TooManyRows`), `expected`, `found`.

### `SqlRowError.message`

The one-sentence summary the caught `error` reports, also callable after
narrowing with `e.(SqlRowError)`.

### `FieldDesc`

One field of a `@table` class: its name and declared type exactly as
written, plus the attributes the compiler recorded rather than called. An
attribute whose name resolves to no function, such as a bare marker like
`@id`, is recorded here; one whose name does resolve is called instead and
never appears in `attrs`.

### `AttrDesc`

One recorded attribute: its name, and its arguments rendered to their
source text. A string literal's argument arrives as its own decoded
content; any other literal arrives as its raw text unchanged.

### `JoinDesc`

One `@manyToMany` relation field's join table: its name, both its foreign-key
columns, and the two related tables and their id columns. Built by the exact
same field computation `link`/`unlink`/`with()` use at run time, so it can
never name a different join table or column than they do.

### `TableSchema`

One `@table` class as the registry below reports it: its table name, its
columns (the same `FieldDesc` list the class's mapper uses), its class-level
attributes, and one `JoinDesc` per `@manyToMany` field.

### `__tables(): []TableSchema`

Every `@table` class in the program, one `TableSchema` each, in module order
then source order. `pkg/orm` calls it to create or update tables, including
any `@manyToMany` join table, without a hand-written list of classes. The
compiler fills in its body only when something calls it, so a program that
never asks pays nothing.

## Row-mapping building blocks

Required (`sqlReq...`, fails on `NULL`) and optional (`sqlOpt...`, `NULL` to
`None`) accessors, all `(rows: Rows, cols: []string, col: string)` unless
noted. Both forms fail naming the column if it is not present in `cols`, or
if it holds a value of the wrong kind.

### `sqlReqInt(rows: Rows, cols: []string, col: string): i64!`

The integer claimed by column `col`.

### `sqlOptInt(rows: Rows, cols: []string, col: string): Option<i64>!`

The integer claimed by column `col`, or `None` on `NULL`.

### `sqlReqFloat(rows: Rows, cols: []string, col: string): f64!`

The float claimed by column `col`.

### `sqlOptFloat(rows: Rows, cols: []string, col: string): Option<f64>!`

The float claimed by column `col`, or `None` on `NULL`.

### `sqlReqBool(rows: Rows, cols: []string, col: string): bool!`

The boolean claimed by column `col`. SQL has no boolean wire type on most
drivers, so this also reads a native `Int` column as zero/nonzero.

### `sqlOptBool(rows: Rows, cols: []string, col: string): Option<bool>!`

The boolean claimed by column `col`, or `None` on `NULL`.

### `sqlReqText(rows: Rows, cols: []string, col: string): string!`

The string claimed by column `col`.

### `sqlOptText(rows: Rows, cols: []string, col: string): Option<string>!`

The string claimed by column `col`, or `None` on `NULL`.

### `sqlReqBlob(rows: Rows, cols: []string, col: string): []byte!`

The bytes claimed by column `col`.

### `sqlOptBlob(rows: Rows, cols: []string, col: string): Option<[]byte>!`

The bytes claimed by column `col`, or `None` on `NULL`.

### `sqlReqDecimal(rows: Rows, cols: []string, col: string): decimal!`

The decimal literal claimed by column `col`. `decimal` is never a `Value`
variant: every driver sends a `DECIMAL`/`NUMERIC` column as `Value.Text`, so
`find<T>` cannot map a `decimal` field on its own; use a hand-written mapper
that calls this accessor instead.

### `sqlOptDecimal(rows: Rows, cols: []string, col: string): Option<decimal>!`

The decimal literal claimed by column `col`, or `None` on `NULL`.

### `sqlReqTimestamp(rows: Rows, cols: []string, col: string): Timestamp!`

The instant claimed by column `col`, reading `timestamp` or `timestamptz`
text alike. An offset-less reading is treated as already UTC.

### `sqlOptTimestamp(rows: Rows, cols: []string, col: string): Option<Timestamp>!`

The same, or `None` on `NULL`.

### `sqlReqDate(rows: Rows, cols: []string, col: string): Date!`

The calendar date claimed by column `col`.

### `sqlOptDate(rows: Rows, cols: []string, col: string): Option<Date>!`

The same, or `None` on `NULL`.

### `sqlReqTime(rows: Rows, cols: []string, col: string): Time!`

The time-of-day claimed by column `col`.

### `sqlOptTime(rows: Rows, cols: []string, col: string): Option<Time>!`

The same, or `None` on `NULL`.

### `sqlReqUuid(rows: Rows, cols: []string, col: string): UUID!`

The uuid claimed by column `col`.

### `sqlOptUuid(rows: Rows, cols: []string, col: string): Option<UUID>!`

The same, or `None` on `NULL`.

### `sqlReqJson(rows: Rows, cols: []string, col: string): Json!`

The `Json` tree claimed by column `col`, for a caller that does not know the
column's shape ahead of time.

### `sqlOptJson(rows: Rows, cols: []string, col: string): Option<Json>!`

The same, or `None` on `NULL`. A SQL NULL and a stored JSON `null` document
stay distinct: NULL becomes `None`, but a stored `null` decodes
successfully.

### `sqlReqJsonAs<T>(rows: Rows, cols: []string, col: string): T!`

Column `col`'s JSON, decoded straight into `T`, a class carrying `@json`.

### `sqlOptJsonAs<T>(rows: Rows, cols: []string, col: string): Option<T>!`

The same, or `None` on `NULL`.

### `sqlReqArray<T>(rows: Rows, cols: []string, col: string, elem: (Value) => T!): []T!`

Column `col`'s Postgres array literal, decoded to `[]T` by applying `elem`
to each element. This accessor handles one array dimension only; a nested
array fails by name rather than silently flattening.

### `sqlOptArray<T>(rows: Rows, cols: []string, col: string, elem: (Value) => T!): Option<[]T>!`

The same, or `None` on `NULL`.

## Array element decoders

The six built-in `elem` decoders for `sqlReqArray<T>`/`sqlOptArray<T>`, one
per scalar type.

### `sqlElemInt(v: Value): i64!`

### `sqlElemFloat(v: Value): f64!`

### `sqlElemBool(v: Value): bool!`

### `sqlElemText(v: Value): string!`

### `sqlElemBlob(v: Value): []byte!`

### `sqlElemDecimal(v: Value): decimal!`

Each matches `Value.Text`, since an array element is its own substring on
the wire, and fails on a `NULL` element or text that does not parse as its
type.

## Scalar single-column results

Five functions serve `find<T>`/`findOne<T>`/`findOneOrFail<T>` for a plain
scalar `T` with no class declared: each requires the result to carry
exactly one column and applies the matching required accessor above to
column 0.

### `sqlRowScalarInt(rows: Rows): i64!`

### `sqlRowScalarFloat(rows: Rows): f64!`

### `sqlRowScalarBool(rows: Rows): bool!`

### `sqlRowScalarText(rows: Rows): string!`

### `sqlRowScalarBlob(rows: Rows): []byte!`

## Row-mapping implementation

The named functions `find`/`findOne`/`findOneOrFail` are written in terms
of. Pass a hand-written `mapper` in place of a generated one for a shape
`find<T>` cannot cover on its own, such as a class with a `decimal` field.

### `sqlFindMany<T>(db: Executor, sqlText: string, args: []Value, mapper: (Rows) => T!): []T!`

Runs `sqlText`/`args` and maps every row through `mapper`.

### `sqlFindOne<T>(db: Executor, sqlText: string, args: []Value, mapper: (Rows) => T!): Option<T>!`

The absent row is `None`, never an error. More than one row fails.

### `sqlFindOneOrFail<T>(db: Executor, sqlText: string, args: []Value, mapper: (Rows) => T!): T!`

Zero rows fails distinguishably from every mapping error; more than one row
also fails.
