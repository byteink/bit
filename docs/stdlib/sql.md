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
import { Executor, Rows, find, findOne, findOneOrFail, Value } from "std/sql"

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

`txAt`/`txValueAt` take an `Isolation` level instead of the database's own
default. **A `tx` nested inside another is a SAVEPOINT**, not a second
transaction - naming which one by passing the handle, since Bit has no
ambient "current transaction" a shared `Pool` could answer for the wrong
caller. An inner failure rolls back only the inner block; the outer one
commits normally.

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
import { Json, JsonEntry } from "std/json"

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
import { Registry, newRegistry, Driver, Conn, Value } from "std/sql"

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

## Reference

### The wire value

| Symbol | Signature | What it does |
| --- | --- | --- |
| `Value` | enum | `Null \| Int(int) \| Float(f64) \| Bool(bool) \| Text(string) \| Blob([]byte)`. |
| `isNull` | `(v: Value): bool` | Whether `v` is `Null`. |
| `asInt`/`asFloat`/`asBool`/`asText`/`asBlob` | `(v: Value): T!` | The typed payload, or fails naming the mismatch. |

### The driver contract

| Symbol | What it is |
| --- | --- |
| `Driver` | `interface { open(dsn: string): Conn! }` - what a named driver implements. |
| `Conn` | `query`, `exec`, `prepare(sqlText): Stmt!`, `begin(): Tx!`, `close()` - one logical connection. |
| `Rows` | `next(): bool!`, `columns(): []string`, `value(col: int): Value`, `close()` - a cursor. |
| `Stmt` | `query(params): Rows!`, `exec(params): int!`, `close()` - from `Conn.prepare`. |
| `Tx` | `query`, `exec`, `commit(): ()!`, `rollback(): ()!` - from `Conn.begin`. |
| `Registry` | `register(name, d: Driver): ()!`, `open(name, dsn): Conn!` - a program's own driver-name map. |
| `newRegistry(): Registry` | An empty `Registry`. |

### The pool

| Symbol | Signature | What it does |
| --- | --- | --- |
| `pool` | `(a: Adapter, cfg: Datasource): Pool!` | Builds a pool; validates `cfg` first, connects lazily. |
| `Adapter` | `interface { connect(cfg: Datasource): Conn! }` | What a driver implements for `pool`. |
| `Datasource` | class | See the field table below. |
| `Datasource.validate` | `(): ()!` | Rejects a config that cannot describe a pool. |
| `SslMode` | enum | `Negotiate \| VerifyFull \| VerifyCa \| Require \| Disable`. |
| `Pool.query`/`Pool.exec` | `(sqlText, params): Rows!` / `int!` | Run SQL; `query`'s connection stays checked out until `Rows.close()`. |
| `Pool.close` | `()` | Closes idle connections; idempotent. |
| `Pool.tx`/`Pool.txAt`/`Pool.txValue`/`Pool.txValueAt` | see [Transactions](#transactions-are-a-closure-not-a-begincommit-pair) | Method form of the free functions below. |
| `Pool.session` | `(): Session` | A read-your-own-writes handle. |
| `FatalError` | `interface { message(): string, transportFatal(): bool }` | Marks a driver failure that poisoned the connection. |
| `transportError` | `(detail: string): error` | A ready-made `FatalError` for a driver with no error type of its own. |
| `Session.query`/`Session.exec` | `(sqlText, params): Rows!` / `int!` | Sticky-to-writer reads once this handle has written. |

### `Datasource` fields

| Field | Default | Meaning |
| --- | --- | --- |
| `uri` | `""` | Whole target in one string; exclusive with the fields below. |
| `host`/`port`/`user`/`password`/`database` | `""`/`0`/... | The individual form. `port = 0` means the adapter's own default. |
| `sslmode` | `SslMode.Negotiate` | TLS negotiation; see [Sharp edges](#sharp-edges). |
| `connectTimeout` | `10_000` | ms for one connect attempt. |
| `maxOpen` | `10` | Ceiling on physical connections, in use plus idle. |
| `maxIdle` | `10` | How many may sit idle before a returned connection is closed instead. |
| `maxLifetime` | `1_800_000` | ms after opening before retiring a connection; `<= 0` is no limit. |
| `maxIdleTime` | `600_000` | ms idle before retiring; `<= 0` is no limit. |
| `acquireTimeout` | `5_000` | ms a caller waits for a connection; never 0. |
| `statementCache` | `0` | Server-side prepared statements kept per connection; 0 is off. |
| `replicas` | `[]` | Read replica URIs; empty means every statement runs on the writer. |
| `replicaBackoff` | `2_000` | ms a replica that failed a statement stays out of rotation. |

### Transactions

| Symbol | Signature | What it does |
| --- | --- | --- |
| `tx` | `(db: Executor, f: (Tx) => ()!): ()!` | Runs `f` at the database's default isolation. |
| `txAt` | `(db: Executor, level: Isolation, f: (Tx) => ()!): ()!` | `tx` at `level`. |
| `txValue<T>` | `(db: Executor, f: (Tx) => T!): T!` | `tx`, returning `f`'s result once committed. |
| `txValueAt<T>` | `(db, level, f: (Tx) => T!): T!` | The one implementation the other three spell. |
| `Executor` | `interface { query, exec }` | Anything statements can run on: `Pool`, or a running `Tx`. |
| `Isolation` | enum | `Default \| ReadUncommitted \| ReadCommitted \| RepeatableRead \| Serializable`. `Default` issues no statement. |

### Mapping a query into a typed `T`

| Symbol | Signature | What it does |
| --- | --- | --- |
| `find<T>` | `(db: Executor, sqlText, ...args: Value): []T!` | Maps every row into `T`. |
| `findOne<T>` | `(db, sqlText, ...args: Value): Option<T>!` | At most one row; more is `SqlRowError`. |
| `findOneOrFail<T>` | `(db, sqlText, ...args: Value): T!` | Exactly one row required. |
| `SqlRowCause` | enum | `MissingColumn \| TypeMismatch \| NullField \| ColumnCount \| NoRows \| TooManyRows`. |
| `SqlRowError` | class | `cause`, `column`, `expected`, `found`, `message()`. |
| `FieldDesc`/`AttrDesc` | classes | What a `@table` class's generated `tableDescriptor()` returns: one `FieldDesc` (`name`, `typeName`, `attrs: []AttrDesc`) per field. |

### Row-mapping building blocks

Required (`sqlReq...`, fails on `NULL`) and optional (`sqlOpt...`, `NULL` to
`None`) accessors, all `(rows: Rows, cols: []string, col: string): T!` /
`Option<T>!` unless noted.

| Symbols | Reads |
| --- | --- |
| `sqlReqInt`/`sqlOptInt` | `i64` |
| `sqlReqFloat`/`sqlOptFloat` | `f64` |
| `sqlReqBool`/`sqlOptBool` | `bool` (from `Bool` or `Int` zero/nonzero) |
| `sqlReqText`/`sqlOptText` | `string` |
| `sqlReqBlob`/`sqlOptBlob` | `[]byte` |
| `sqlReqDecimal`/`sqlOptDecimal` | `decimal`, parsed from `Value.Text` |
| `sqlReqTimestamp`/`sqlOptTimestamp` | `std/time` `Timestamp`, from `timestamp` or `timestamptz` text |
| `sqlReqDate`/`sqlOptDate` | `std/time` `Date` |
| `sqlReqTime`/`sqlOptTime` | `std/time` `Time` |
| `sqlReqUuid`/`sqlOptUuid` | `std/uuid` `UUID` |
| `sqlReqJson`/`sqlOptJson` | `std/json` `Json` tree |
| `sqlReqJsonAs<T>`/`sqlOptJsonAs<T>` | `T` (a `@json` class), via `std/json`'s `jsonDecode<T>` |
| `sqlReqArray<T>`/`sqlOptArray<T>` | `(rows, cols, col, elem: (Value) => T!): []T!` / `Option<[]T>!` - one Postgres `{...}` dimension |
| `sqlElemInt`/`sqlElemFloat`/`sqlElemBool`/`sqlElemText`/`sqlElemBlob`/`sqlElemDecimal` | `(v: Value): T!` - the built-in `elem` decoders for the array accessors above |
| `sqlRowScalarInt`/`sqlRowScalarFloat`/`sqlRowScalarBool`/`sqlRowScalarText`/`sqlRowScalarBlob` | `(rows: Rows): T!` - a one-column result's single value, for `find<T>` against a scalar `T` |
| `sqlFindMany<T>`/`sqlFindOne<T>`/`sqlFindOneOrFail<T>` | `(db: Executor, sqlText, args: []Value, mapper: (Rows) => T!): ...` | `find`/`findOne`/`findOneOrFail`'s own implementation - pass a hand-written `mapper` for a shape `find<T>` cannot generate. |
