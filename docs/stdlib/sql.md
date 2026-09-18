# std/sql

The database driver contract. Two drivers exist today, `bit/pkg/postgres` and
`bit/pkg/mysql` - see "The freeze" below for what building both proved.
Neither talks to `std/sql` through the `Driver`/`Registry` pair this page
opens with; both ship their own `Adapter` instead (`Datasource` and `Adapter`
are documented under "The connection pool"). Shipping the contract from
stdlib rather than as a package is still deliberate: a contract shipped as a
package invites a second, competing one, and every driver ends up picking a
side. Go's `database/sql` is the shape this follows.

**The only way to supply a value is `params []Value`.** `query`/`exec` take
the literal SQL text and an ordered list of typed `Value`s as two separate
arguments; nothing in this module ever builds SQL text by concatenating a
value into it. There is no function anywhere in `std/sql` that accepts a
pre-interpolated string with values already substituted in.

**Placeholder syntax is not specified here.** Postgres numbers its
placeholders (`$1`, `$2`, ...); MySQL and SQLite use a positional `?`. This
module picks neither - `sqlText` carries whatever placeholder marker the
caller and the target driver agree on, and each driver renders it into its
own wire format from the ordered `params` list it is given.

<!-- doctest: per-block -->

```bit ignore
import { Value, isNull, asInt, asFloat, asText, asBlob } from "std/sql"
import { Driver, Conn, Rows, Stmt, Tx } from "std/sql"
import { Registry, newRegistry } from "std/sql"
```

## `Value` - the wire type every driver carries

### `Value`

A sum type over the wire types every driver must be able to carry: `Null` is
SQL NULL, `Int`/`Float`/`Text`/`Blob` cover every scalar column type a driver
maps its own types onto.

```bit
import { Value } from "std/sql"

fn describe(v: Value): string {
  match (v) {
    Null => return "null"
    Int(n) => return "int ${n}"
    Float(f) => return "float ${f}"
    Text(s) => return "text ${s}"
    Blob(b) => return "blob of ${len(b)} byte(s)"
  }
}
```

### `isNull(v: Value): bool`

True if `v` is SQL NULL.

### `asInt(v: Value): int!`

The typed accessor for an `Int` value. Fails if `v` holds any other variant -
`match (v)` directly when the column's type is not known ahead of time.

### `asFloat(v: Value): f64!`

The typed accessor for a `Float` value. Fails on any other variant.

### `asText(v: Value): string!`

The typed accessor for a `Text` value. Fails on any other variant.

### `asBlob(v: Value): []byte!`

The typed accessor for a `Blob` value. Fails on any other variant.

## The driver contract

### `Driver`

`open(dsn: string): Conn!` - the one thing every concrete driver package
implements. `dsn` is a driver-specific connection string; its format is
entirely the driver's own.

### `Conn`

A single logical database connection, as handed back by `Registry.open`.
Several green threads may hold and use the same `Conn` at once - see
`newRegistry`'s entry below for how that is made safe.

```
query(sqlText: string, params: []Value): Rows!
exec(sqlText: string, params: []Value): int!
prepare(sqlText: string): Stmt!
begin(): Tx!
close()
```

`query` runs SQL expected to produce a row set (`SELECT` and friends);
`exec` runs SQL expected only to change rows and reports how many were
affected - never a row set. Postgres's `RETURNING` clause can turn an
insert into a query with rows and MySQL has no equivalent, so nothing in
this module may assume an `exec` can return rows: a driver that wants to
expose `RETURNING` does so through `query`, the same call any `SELECT` uses.

### `Rows`

A cursor over a result set.

```
next(): bool!
columns(): []string
value(col: int): Value
close()
```

`next` advances to the next row, returning `false` (not an error) once the
set is exhausted; a driver-side read failure mid-iteration is reported
through the fallible result instead. `columns` is the result set's column
names in order; `value` reads column `col` (0-based) of the current row -
match it, or pass it to `asInt`/`asText`/... above.

### `Stmt`

A prepared statement, from `Conn.prepare`.

```
query(params: []Value): Rows!
exec(params: []Value): int!
close()
```

`params` is positional, in the same order as the placeholders in the
`sqlText` the statement was prepared from.

### `Tx`

An open transaction, from `Conn.begin`.

```
query(sqlText: string, params: []Value): Rows!
exec(sqlText: string, params: []Value): int!
commit(): ()!
rollback(): ()!
```

`query`/`exec` behave exactly as `Conn`'s do, scoped to this transaction.
`commit`/`rollback` are the **driver's** side of the contract: a driver
implements them, and `tx` (below) is the only thing that calls them. Application
code never ends a transaction by hand - the handle `tx` gives a block fails both
calls, and fails every call once that block has returned.

## The registry

### `Registry`

The driver registry a program builds once and shares. Go's
`sql.Register`/`sql.Open` write into one process-wide map, relying on an
import-time init hook to run the registration side effect; Bit has neither
that hook nor (SPEC §11.11) a way for module-level state to hold a `map` or
an `interface` value, so a real package-level singleton is not expressible.
`Registry` is the explicit alternative already used elsewhere in stdlib for
shared, mutable, driver-style state (see `TlsTicketStore` in
[tls](tls.md)): build one with `newRegistry()`, have every driver's setup
code call `register` on it, and pass it to `open` wherever a connection is
needed.

### `newRegistry(): Registry`

An empty `Registry`, ready for `register` calls.

### `Registry.register(name: string, d: Driver): ()!`

Adds `d` under `name`. Fails if `name` is already registered.

### `Registry.open(driverName: string, dsn: string): Conn!`

Looks up the driver registered as `driverName` and opens `dsn` with it.
Fails if `driverName` was never registered, or if the driver's own `open`
fails. The returned `Conn` is wrapped so that several green threads sharing
it never interleave calls on the one underlying socket it represents - a
single-slot connection pool, sized at exactly one physical connection per
`open()` call, the minimum that satisfies "must not let two green threads
interleave on one socket". A driver that wants true N-way concurrency pools
several physical connections internally and hands one out per `open`; the
registry still serializes access to whichever one it gets.

```bit
import { Registry, Driver, Conn, Value, asText } from "std/sql"

// A program wires up a driver package's setup once, naming it by string -
// the only two places anything needs to import a concrete driver package
// are the call that constructs `d` and this one, never the call sites that
// go on to use the resulting Conn.
fn wireUp(reg: Registry, d: Driver): Conn! {
  reg.register("mydb", d)?
  return reg.open("mydb", "host=localhost dbname=app")?
}

fn firstName(conn: Conn, id: string): string! {
  let rows = conn.query("SELECT name FROM users WHERE id = ?", [Value.Text(id)])?
  let has = rows.next()?
  if (!has) {
    fail newError("no such user: ${id}")
  }
  return asText(rows.value(0))?
}
```

## The freeze

`bit/pkg/postgres` (#3987-3989) and `bit/pkg/mysql` (#3993-3995) were built
together, deliberately, to answer one question: is `std/sql`'s contract
actually driver-agnostic, or does building the first driver quietly bend it
to fit? Postgres landed first. MySQL was explicitly free to change `Value`,
`Driver`, `Conn`, `Rows`, `Stmt`, `Tx` or `Registry` if it needed to. This is
the record of what it actually needed, checked against the real history
rather than against what either ticket expected to find - and, now that both
have shipped, the point at which these seven names stop moving.

### Proving the swap is one line

The design's whole claim is that switching database costs one import line.
Here it is checked directly rather than asserted: the same tiny handler,
built once against each driver.

```bit ignore
// pkg/postgres version
import { pool, Datasource, sqlReqText, Value, Pool } from "std/sql"
import { adapter } from "postgres"
import { App, Config, Ctx, Res } from "web"
import { env } from "std/os"

fn userName(c: Ctx, db: Pool): Res! {
  let rows = db.query("select name from users where id = $1", []Value{ Value.Text(c.param("id")) })?
  defer rows.close()
  rows.next()?
  return c.text(sqlReqText(rows, rows.columns(), "name")?)
}

fn main(): ()! {
  let db = pool(adapter(), Datasource{ uri: env("DATABASE_URL") })?
  let app = App(Config{ secret: env("APP_SECRET") })
  app.get("/users/:id", (c) => userName(c, db))
  app.listen()?
}
```

```bit ignore
// pkg/mysql version
import { pool, Datasource, sqlReqText, Value, Pool } from "std/sql"
import { adapter } from "mysql"
import { App, Config, Ctx, Res } from "web"
import { env } from "std/os"

fn userName(c: Ctx, db: Pool): Res! {
  let rows = db.query("select name from users where id = $1", []Value{ Value.Text(c.param("id")) })?
  defer rows.close()
  rows.next()?
  return c.text(sqlReqText(rows, rows.columns(), "name")?)
}

fn main(): ()! {
  let db = pool(adapter(), Datasource{ uri: env("DATABASE_URL") })?
  let app = App(Config{ secret: env("APP_SECRET") })
  app.get("/users/:id", (c) => userName(c, db))
  app.listen()?
}
```

Both are fenced `ignore` here because a page checked by `test-docs` only ever
resolves `std/*` (`_tests_/bit/docs.bit`'s own header: "against the real
prelude and the real `std/*`"), and no gate anywhere typechecks a page that
imports two `pkg/` packages at once - `test-package-docs` wires exactly one
package (the one whose own `docs/` tree it is scanning) as a local
dependency per page (`_tests_/bit/pkgdocsgate.bit`'s header). So this pair
was checked by hand instead of by a standing gate: a scratch project per
variant, each declaring `postgres`/`web` or `mysql`/`web` as a local-path
dependency on this checkout's own `pkg/`, `bit check` on both (clean, exit
0), and a mutation control - breaking the import name - failing loudly (exit
1, `E0045`) to confirm the check was live rather than vacuous. `diff` on the
two source files shows exactly one changed line, the import naming the
driver package; nothing else in the handler, the route or `main` moves. This
is a one-time hand verification, not a gate; a future change to either
adapter's public shape is not re-checked by it automatically.

### What each interface actually did, six of six

`stdlib/sql/sql.bit` - the file declaring `Value`, `Driver`, `Conn`, `Rows`,
`Stmt`, `Tx` and `Registry` - has exactly four commits since it was created
(`9b720102`): the creation itself, and three purely mechanical, repo-wide
formatter sweeps (`13017a3e`'s receiver-form-to-class-body move, and
`1e15ec44` plus its own revert `143f9e02` for the `=` `field_init` spelling).
**Zero commits from #3987-3995 - either driver's own work - touch this
file at all.** Checked directly: neither `mysql` nor `#399[3-5]` matches
any commit on `stdlib/sql/sql.bit`, `stdlib/sql/config.bit`
(`Adapter`/`Datasource`) or `stdlib/sql/tx.bit` (`Executor`).

| Interface | Changed by either driver | What actually happened |
|---|---|---|
| `Value` | No | Stayed `{Null, Int, Float, Text, Blob}` (#5421, owner ruling: extend by accessor, not by enum variant - see below). |
| `Driver` | No | Neither adapter implements it. `pkg/postgres/adapter.bit:86` and `pkg/mysql/adapter.bit:104` both export `fn adapter(): Adapter` (`config.bit`'s `Adapter`, added by #3962 before either driver existed), never a `Driver`. The only implementer anywhere in the tree is `stdlib/sql/sqlcheck.bit`'s `fakeDriver`, a self-test double. |
| `Conn` | No | `pgConn` (`pkg/postgres/conn.bit:30`) and `myConn` (`pkg/mysql/conn.bit:34`) implement `query`/`exec`/`prepare`/`begin`/`close` with the exact signatures declared in 2026-08 - see "The one gap this froze open," below, for `begin`. |
| `Rows` | No | `pgRows`/`myRows` implement `next`/`columns`/`value`/`close` verbatim. MySQL's `TINYINT(1)`-as-bool and JSON-as-the-field's-own-type ambiguities are resolved by which accessor the caller reaches for (`sqlReqBool` vs `sqlReqInt`, `sqlReqJson`), never by `Rows` itself. |
| `Stmt` | No | `pgStmt`/`myStmt` implement `query`/`exec`/`close` verbatim. MySQL's `$1`-to-`?` placeholder rewrite (`pkg/mysql/rewrite.bit`) and its statement cache both run *inside* `prepare`, invisible at the `Stmt` boundary. |
| `Tx` | No (but see below) | Signature untouched, and both drivers fail `begin` with the same shape - which is the interesting finding, not a change. |
| `Registry` | No | Unused by both real drivers, same as `Driver`; exercised only by `sqlcheck.bit`'s fake. |

**6 of 6 checked. 0 of 6 changed.** What MySQL actually needed - the session
`time_zone='+00:00'` pin at connect, the reversed `TIMESTAMP`/`DATETIME`
mapping, its own DECIMAL binary format - all landed *inside* `myConn`/its
codecs, never at the `Conn`/`Rows`/`Stmt` boundary. The one place the design
predicted an extension point and a driver actually used it is `Value`:
#5421 settled that a type a codec produces (`decimal`, later `Instant`,
`UUID`, `Json`, arrays) gets a `sqlReqX`/`sqlOptX` pair in
`stdlib/sql/row.bit`/`rowtypes.bit`, reading `Value.Text` and converting -
exactly the shape `pkg/mysql`'s own `mysqlDecimal` had already shipped by
hand before the decision was written down. `Value` itself never grew a
variant.

### The one gap this froze open

`Conn.begin(): Tx!` is declared and implemented by both drivers - and both
implementations are the same one line:

```
pkg/postgres/conn.bit:70   fail newError("postgres: begin is not implemented yet (epic #3986)")
pkg/mysql/conn.bit:217     fail newError("mysql: begin is not implemented yet (epic #3986)")
```

Neither ever issues `BEGIN`/`START TRANSACTION`. That stub predates #3979
(closure-scoped transactions, the *only* public transaction API - see
[Transactions](#transactions)), which built `tx`/`txAt`/`txValue`/`txValueAt`
on top of `Pool`'s own (unexported) `begin`, which in turn calls straight
through to `Conn.begin`. Nobody went back to wire either driver's `begin` up
once #3979 landed. The result: `pool.tx((db) => { ... })` against a real
Postgres or MySQL connection fails immediately, every time, with the message
above - not a gap in the interface, a gap in both implementations of it.
`stdlib/sql/pool.test.bit`'s `stubConn.begin()` is the only `begin` in the
whole tree that actually starts anything, which is why `tx.test.bit`'s and
`pool.test.bit`'s own suites are green: they prove the closure machinery
against a fake that behaves, never against either shipped driver. Filed as
#5587, since fixing two drivers' connection code is out of a docs ticket's
reach and out of this ticket's own "do not change an interface" constraint -
`Conn.begin`'s signature is fine as declared; issuing real SQL from inside it
is the missing part.

### What a third driver breaks

Postgres and MySQL are both networked servers with users, passwords and a
TLS handshake, so building only these two hid every place the contract
assumes that. SQLite does not:

- **`Datasource.host`/`port`/`connectTimeout`.** `config.bit`'s own comment
  on the class already flags this for this ticket by number: *"`host`/
  `port`/`sslmode` bake a network database assumption into the generic
  layer. SQLite has no host and no port and would leave all three at their
  defaults."* A SQLite adapter's `connect` would ignore three of
  `Datasource`'s fields outright rather than reading them, which is a
  silent gap the type system cannot flag.
- **`SslMode`.** All five variants (`Negotiate`, `VerifyFull`, `VerifyCa`,
  `Require`, `Disable`) describe a TLS negotiation against a server socket.
  SQLite opens a local file; there is no handshake to negotiate, so a
  SQLite `Adapter.connect` has no correct answer for a caller who sets
  `sslmode=verify-full` beyond refusing it outright.
- **`Pool`'s concurrency model.** `Datasource.maxOpen` defaults to 10
  because a *server* arbitrates many physical connections concurrently
  (`config.bit`'s own HikariCP citation). SQLite locks at the database
  file, not per-connection, so a pool of ten connections against one
  SQLite file mostly serializes on `SQLITE_BUSY` rather than gaining the
  concurrency the default was sized for - the pool would need a
  fundamentally different policy (a single writer, or busy-retry with
  backoff), not just a smaller number.
- **`FatalError`.** The marker exists so `Pool` can tell a dead *transport*
  (a dropped socket, a short read) from an ordinary statement failure and
  discard only the former. SQLite has no transport to drop; its
  connection-poisoning failure modes - a corrupted file, a lock that never
  clears - are a different class this interface was never shaped to name.

### The freeze itself

After this ticket, `Value`, `Driver`, `Conn`, `Rows`, `Stmt`, `Tx` and
`Registry` are frozen: a change to any of their exported shapes is a stdlib
API change under
[`docs/release/VERSIONING.md`](../release/VERSIONING.md)'s surface 3, which
takes at minimum a MINOR bump (MAJOR is pinned at 0 pre-1.0) whether the
change is additive or breaking. Two independent drivers built against these
seven names without moving one of them; a third driver is expected to extend
`Value`'s reach through a new `sqlReqX`/`sqlOptX` pair, the way #5421 already
settled, not by asking any of the seven to change shape.

## The connection pool

A server has two wrong ways to reach a database and one right one. Open a
connection per request and every request pays a TCP handshake plus
authentication, and a burst exhausts the database's own connection limit.
Share one connection between requests and the application serialises on it -
and a transaction started by one request becomes visible to every other
request using that connection. `pool` is the third way: a bounded set of
physical connections, handed out one at a time, returned when the caller is
done, and closed when they are too old or have gone bad.

Four rules hold, and the tests in `stdlib/sql/pool.test.bit` assert each one
against a fake driver that counts every connection ever opened:

1. **A transaction pins its connection** for its whole life, returned on
   `commit` or `rollback`. The `Tx` holds the driver's own transaction, made
   on one connection, and has no way to reach another.
2. **A connection handed back with an open transaction is closed**, never
   reused - including after a `commit` that failed, since the pool cannot
   know what the server did with it.
3. **A connection a driver reported a transport failure on is discarded**
   (see `FatalError` below).
4. **Waiters are served in arrival order.** LIFO would starve a request
   under sustained load, so a caller that arrives while anyone is queued
   joins the queue rather than taking an idle connection out from under it.

### `pool(a: Adapter, cfg: Datasource): Pool!`

A pool of connections to the database `cfg` names, opened through `a`.
Nothing connects here: `cfg` is checked (`Datasource.validate`) and
connections are opened on demand, up to `cfg.maxOpen`. This fails only on a
configuration that cannot describe a pool - an unset `DATABASE_URL` surfaces
here, not as a DNS error from inside a driver later.

```bit
import { Adapter, Datasource, Pool, pool, SslMode } from "std/sql"

// The whole target in one string, as DATABASE_URL supplies it.
fn fromUrl(a: Adapter, url: string): Pool! {
  return pool(a, Datasource{ uri: url })?
}

// Or field by field, with a bigger pool.
fn fromFields(a: Adapter, password: string): Pool! {
  return pool(
    a,
    Datasource{
      host: "db.internal", user: "app", password: password,
      database: "erp", sslmode: SslMode.VerifyFull, maxOpen: 20,
    },
  )?
}
```

### `Datasource`

Everything a pool needs: one database to reach, and the shape of the pool
that reaches it. One class, not two - splitting connection settings from
pool settings puts a nested value and a second `?` at every call site.

| field | default | meaning |
| ----- | ------- | ------- |
| `uri` | `""` | the whole target in one string, `postgres://app:pw@host:5432/db?sslmode=...` |
| `host` | `""` | the individual form; exclusive with `uri` |
| `port` | `0` | 0 means the adapter's own default (5432, 3306) |
| `user` | `""` | |
| `password` | `""` | |
| `database` | `""` | |
| `sslmode` | `SslMode.Negotiate` | |
| `connectTimeout` | `10_000` | ms for one connect attempt, applied by the adapter |
| `maxOpen` | `10` | ceiling on physical connections, in use plus idle |
| `maxIdle` | `10` | how many may sit idle rather than being closed |
| `maxLifetime` | `1800_000` | ms after opening before a connection is retired; 0 or less, never |
| `maxIdleTime` | `600_000` | ms a connection may sit idle before it is retired; 0 or less, never |
| `acquireTimeout` | `5_000` | ms a caller waits for a connection before failing |
| `statementCache` | `0` | prepared statements kept per connection; 0 is off |
| `replicas` | `[]` | read replica URIs (see "Read replicas" below); empty means every statement runs on the writer |
| `replicaBackoff` | `2_000` | ms a replica that failed a statement stays out of rotation |

**`uri` and the individual fields are mutually exclusive.** Setting both is
an error naming both, not one silently winning. Parsing `uri` is the
adapter's job, not this module's: Postgres spells the TLS setting
`sslmode=verify-full` and MySQL spells it `ssl-mode=VERIFY_IDENTITY`, so
there is deliberately no `parseUrl` here.

**`maxOpen` is 10, argued not guessed.** Postgres ships
`max_connections = 100`, so one instance defaulting to 100 takes the
server's whole budget and the second container - or the operator's `psql` -
cannot connect at all. A large pool is also slower: past a small pool,
throughput drops as the database thrashes between processes competing for
the same cores and disks (HikariCP's benchmarks are the citation; 10 is its
default and node-postgres's). The rough optimum is `cores * 2 + spindles` on
the *database* box, never a count taken from the application host.

**`acquireTimeout` is never 0.** Zero would mean wait forever, so a database
outage would park every worker with no error and no log line; `validate`
rejects it, as it rejects a `maxOpen` below 1.

### `Datasource.validate(): ()!`

Rejects a `Datasource` that cannot describe a pool, before anything opens a
socket: neither `uri` nor `host` set (nothing to connect to - the unset
`DATABASE_URL` case, which must not surface as a DNS or parse failure), both
set (mutually exclusive), a `maxOpen` below 1, a negative `maxIdle`, or an
`acquireTimeout` below 1. `pool` calls it, so a program that builds its pool
through `pool` never has to.

### `SslMode`

```
enum SslMode { Negotiate, VerifyFull, VerifyCa, Require, Disable }
```

How the driver should negotiate TLS. The names are Bit's; each adapter
renders them into whatever its own wire protocol spells.

`Negotiate` is the first variant deliberately. A class field of enum type
cannot carry an explicit default - a variant is not a constant expression
(SPEC §10.5, `E0064`) - so an omitted `sslmode` takes the enum's *first
declared variant*. Ordering the connect-to-anything mode first is the only
way that default survives, and reordering this enum silently changes what an
omitted `sslmode` means.

### `Adapter`

```
connect(cfg: Datasource): Conn!
```

What turns a `Datasource` into a live connection: the one thing a driver
package implements for `pool`, as `Driver`/`Conn` is what it implements for
everything else. `connect` reads whichever form of `cfg` the caller filled
in, applies its own default port when `cfg.port` is 0, and renders
`cfg.sslmode` into its own protocol's spelling. `pool` calls
`cfg.validate()` before it ever calls `connect`, so an adapter never sees a
`Datasource` with both forms set or with neither.

### `Pool`

A bounded set of connections to one database, safe to share across green
threads. Built by `pool`; closed by `Pool.close`.

### `Pool.query(sqlText: string, params: []Value): Rows!`

Runs `sqlText` and returns its rows. **The connection stays checked out
until the returned `Rows` is closed** - a cursor lives on the connection
that produced it - so a caller that never closes its `Rows` leaks a
connection exactly as one that never closes a file leaks a descriptor.

```bit
import { Pool, Value, asText } from "std/sql"

fn firstName(db: Pool, id: string): string! {
  let rows = db.query("SELECT name FROM users WHERE id = ?", [Value.Text(id)])?
  defer rows.close()
  let has = rows.next()?
  if (!has) {
    fail newError("no such user: ${id}")
  }
  return asText(rows.value(0))?
}
```

### `Pool.exec(sqlText: string, params: []Value): int!`

Runs `sqlText` for its effect and returns the number of rows it changed. The
connection is back in the pool before this returns.

### `Pool.close()`

Closes every idle connection and fails every parked caller. Connections
still checked out are closed as they are returned. Idempotent.

### `Pool.tx(f: (Tx) => ()!): ()!`

`tx` as a method: runs `f` in a transaction at the database's own isolation
level. `db.tx(f)` and `tx(db, f)` (see "Transactions" below) run the same
code - this is a call shape, not a second implementation.

### `Pool.txAt(level: Isolation, f: (Tx) => ()!): ()!`

`Pool.tx` at the isolation level `level` instead of the database's own.

### `Pool.txValue<T>(f: (Tx) => T!): T!`

`txValue` as a method: runs `f` in a transaction and returns what `f`
returned, once the commit has succeeded. Nothing is returned on a failure,
because the value is only a result if the work behind it is durable.
`db.txValue(f)` and `txValue(db, f)` run the same code.

### `Pool.txValueAt<T>(level: Isolation, f: (Tx) => T!): T!`

`Pool.txValue` at the isolation level `level` instead of the database's own.
This is the one implementation; the other three are spellings of it.

### `Pool.session(): Session`

Opens a per-request read-your-own-writes handle. See "Read replicas" below
for what it is for and what it costs to forget.

### `FatalError`

```
message(): string
transportFatal(): bool
```

The marker a driver failure carries when the failure has poisoned the
*connection* rather than merely failing the statement: a closed socket, a
short read, a protocol desync. The pool never hands such a connection out
again (rule 3). A failure that does not implement `FatalError` - a
constraint violation, a syntax error - leaves the connection usable, which
is the common case and needs no cooperation from the driver at all.

### `transportError(detail: string): error`

A ready-made `FatalError`, for a driver with no error type of its own to
extend.

## Read replicas

Reads go to a replica, writes to the writer, and **everything inside a
transaction goes to the writer** - a read inside a transaction that landed on
a replica would not see the transaction's own uncommitted writes. This needs
no code at the call site: set `Datasource.replicas`, and `pool` opens one
connection pool per replica URI alongside the writer's own.

```bit
import { Adapter, Datasource, Pool, pool } from "std/sql"

fn withReplicas(a: Adapter, writerUrl: string, replicaUrls: []string): Pool! {
  return pool(a, Datasource{ uri: writerUrl, replicas: replicaUrls })?
}
```

**Read-your-own-writes** is the hard part: a read issued right after a write
in the same request must not land on a replica that has not caught up, or the
caller is shown stale data it just changed. `Pool` cannot hold that flag
itself - a `Pool` is shared by every green thread using it, so a pool-level
"has written" would answer with some other task's write.

### `Session`

A per-request handle, from `Pool.session`. `written` starts false; once
`Session.exec` has committed a write, every later `Session.query` on the
SAME handle goes to the writer, never a replica, until the caller takes a
fresh `Session`. A `query` on a `Session` that has not written may still land
on a replica.

**What it costs when it is wrong.** A handler that keeps calling
`pool.query`/`pool.exec` directly instead of routing every statement through
one `Session` gets no read-your-own-writes protection, silently - there is
nothing to forget out loud. The next read then runs on a replica that may not
have caught up, the caller sees data older than the write it just made, and
nothing errors.

### `Session.query(sqlText: string, params: []Value): Rows!`

Routes to the writer once this handle has written; otherwise the same
routing `Pool.query` itself uses.

### `Session.exec(sqlText: string, params: []Value): int!`

Always the writer. Marks this handle sticky only once the write has actually
committed - a failed write leaves nothing to be stale about.

**Replica health.** A replica that fails a statement is dropped from
rotation for `Datasource.replicaBackoff` milliseconds and the statement is
retried on the writer, so one dead replica degrades throughput rather than
erroring the caller. A write is never retried on a replica: `Pool.exec`
always runs on the writer and never consults the replica set at all.

## Transactions

**The only transaction API is a closure.** `tx` takes a block, runs it on one
pinned connection and ends the transaction itself: COMMIT when the block
returns, ROLLBACK on a failure or a panic, and the connection back in the pool
on every path. There is no `begin` for a caller to pair with a `commit`.

The reason is `?`. In the hand-written form every `?` between the begin and the
commit is an early return that skips the rollback, so the transaction stays open
and the pooled connection is never returned; under load the pool exhausts and
the service stops, with nothing in the logs naming the function that did it.
`defer` can guard it, but a correctness property that depends on every caller
remembering a line is not a property. The closure form makes that failure
unreachable rather than unlikely.

`stdlib/sql/tx.test.bit` asserts each promise below against a fake driver that
logs every statement tagged with the connection that ran it.

### `tx(db: Executor, f: (Tx) => ()!): ()!`

Runs `f` in a transaction at the database's own isolation level and returns
nothing. `db` is the `Pool`, or the handle of a transaction already running - in
which case this is a savepoint inside it, not a second transaction.

```bit
import { Pool, Value, tx } from "std/sql"

fn transfer(db: Pool, payer: string, payee: string, cents: int): ()! {
  tx(db, (t) => {
    t.exec(
      "UPDATE accounts SET balance = balance - ? WHERE id = ?",
      [Value.Int(cents), Value.Text(payer)],
    )?
    t.exec(
      "UPDATE accounts SET balance = balance + ? WHERE id = ?",
      [Value.Int(cents), Value.Text(payee)],
    )?
  })?
}
```

The handle `t` works only inside the block. Every method on it fails once the
block has returned - a handle that still worked would run statements outside the
transaction, on a connection the pool has since given to somebody else - and
`t.commit()`/`t.rollback()` fail whenever they are called, because ending the
transaction is `tx`'s job.

A failure inside the block propagates **unchanged**: the caller gets the
driver's own error, never a transaction error wrapped around it. A panic rolls
back too, and is then re-raised; `tx` installs the panic boundary itself
(`std/runtime`), because a recovered panic runs no deferred call.

### `txAt(db: Executor, level: Isolation, f: (Tx) => ()!): ()!`

`tx`, at `level` instead of the database's own isolation level.

```bit
import { Pool, Isolation, Value, txAt } from "std/sql"

fn post(db: Pool, batch: string): ()! {
  txAt(db, Isolation.Serializable, (t) => {
    t.exec("UPDATE ledger SET posted = 1 WHERE batch = ?", [Value.Text(batch)])?
  })?
}
```

### `txValue<T>(db: Executor, f: (Tx) => T!): T!`

`tx`, returning what the block returned once the transaction has committed - so
a transaction can produce an inserted id without a mutable captured outside it.
Nothing is returned on a failure: a value is a result only if the work behind it
is durable.

The type argument is written out because a block's result type is not inferred
through a generic parameter, and it cannot be `()` - a block that returns
nothing goes through `tx`.

```bit
import { Pool, Value, asInt, txValue } from "std/sql"

fn placeOrder(db: Pool, sku: string): int! {
  return txValue<int>(db, (t) => {
    let rows = t.query(
      "INSERT INTO orders (sku) VALUES (?) RETURNING id",
      [Value.Text(sku)],
    )?
    defer rows.close()
    let has = rows.next()?
    if (!has) {
      fail newError("insert returned no id")
    }
    return asInt(rows.value(0))?
  })?
}
```

### `txValueAt<T>(db: Executor, level: Isolation, f: (Tx) => T!): T!`

`txValue`, at `level` instead of the database's own isolation level. The other
three entry points are spellings of this one.

### `Executor`

```
query(sqlText: string, params: []Value): Rows!
exec(sqlText: string, params: []Value): int!
```

Anything statements can run on: a `Pool`, or a transaction already running on
one. A function that takes an `Executor` rather than a `Pool` composes - the
caller decides whether it runs on its own or inside a transaction:

```bit
import { Executor, Value, tx } from "std/sql"

// Runs standalone when it is given the pool, and as a savepoint of the
// caller's transaction when it is given that transaction's handle.
fn archive(db: Executor, id: string): ()! {
  tx(db, (t) => {
    t.exec(
      "INSERT INTO archive SELECT * FROM orders WHERE id = ?",
      [Value.Text(id)],
    )?
    t.exec("DELETE FROM orders WHERE id = ?", [Value.Text(id)])?
  })?
}
```

**A nested `tx` is a savepoint, never a second transaction.** It issues
`SAVEPOINT bit_sp_N` on the same connection, `RELEASE SAVEPOINT bit_sp_N` when
its block returns, and `ROLLBACK TO SAVEPOINT bit_sp_N` when its block fails -
so an inner failure undoes exactly the inner block and the outer one goes on to
commit. Joining the outer transaction silently would let an inner rollback take
the outer work with it.

Which transaction a nested `tx` belongs to is named by **passing the handle**,
because there is no ambient "current transaction" to consult: Bit has no
task-local storage, and one `Pool` is shared by every green thread using it, so
pool-level state would answer with some other task's transaction. If a savepoint
rollback itself fails, the transaction is marked: the outer block cannot commit
over it and is rolled back instead.

### `Isolation`

```
Default | ReadUncommitted | ReadCommitted | RepeatableRead | Serializable
```

How much of other transactions' work a transaction may see. `Default` issues no
statement at all, leaving whatever the database and its driver are configured
for in force - `std/sql` picks no level for you, because an ERP has both
read-committed reporting and serializable posting and either one chosen
invisibly is wrong for the other.

Any other level is issued as SQL-92's `SET TRANSACTION ISOLATION LEVEL x`, as
the first statement after the BEGIN: the driver contract's `Conn.begin()` takes
no argument, and this module knows no dialect. That is what Postgres wants.
MySQL refuses the statement once a transaction is open, so a MySQL driver that
means to support levels honours it in its own `Tx.exec` - the driver's job, the
same way placeholder syntax already is.

## `@table` descriptors - what the compiler hands a mapper

A class carrying the `@table` attribute (SPEC §10.5) gains a synthesized
`tableDescriptor(): []FieldDesc`, one entry per field in declaration order. The
compiler fills these in; nothing here is written by hand.

The compiler attaches no meaning to any of it. `unique` is a word it copied off
a field and passed along. What an attribute name means, if anything at all, is
decided by whatever reads the descriptor - `bitlang.org/pkg/orm` treats `@id` as
a primary key, and a different mapper is free to treat it as nothing. That split
is the point: a mapper can add `@check(...)` or `@collation(...)` without a
compiler release, because the compiler never learned the first set of names
either.

### `FieldDesc`

One field of a `@table` class: its name and declared type exactly as written,
and the attributes the compiler recorded rather than called.

An attribute is RECORDED when its name resolves to no function at all, which is
what a marker like `@id` looks like. An attribute whose name does resolve is
CALLED from the class's `validateFields()` instead, unchanged, and never appears
in `attrs`. So a field carrying `@unique` and `@maxLen(255)` records the first
and calls the second.

```bit
import { FieldDesc, AttrDesc } from "std/sql"

@table class User {
  @id
  id: i64
  @unique
  email: string
}

fn columns(u: User): []string {
  let out = []string(0)
  for f of u.tableDescriptor() {
    out = append(out, "${f.name} ${f.typeName}")
  }
  return out
}
```

A module that declares a `@table` class without importing `FieldDesc` and
`AttrDesc` is **E0150**, and a class that declares `tableDescriptor` itself is
**E0148**, naming both.

### `AttrDesc`

One recorded attribute: its name, and its arguments as text.

Arguments must be constant expressions - a non-constant one is **E0149**. Each
is rendered to its source spelling and never interpreted here: a string
literal's own decoded content, any other literal's raw text unchanged. So
`@check("age > 0")` arrives as the nine characters `age > 0`, without the
quotes, and `@scale(2, 3)` arrives as `"2"` and `"3"` in that order. Parsing
them is the mapper's job, which is why they are `[]string` and not a value type
this module would have to define.

## Mapping a query result into a typed `T`

`find`/`findOne`/`findOneOrFail` map every row a query returns into `T`: a
plain class, or one of `i64`/`f64`/`bool`/`string`/`[]byte` for a
single-column result. **No mark is required** - unlike `@json`/`@table`,
generation is demand-driven by the call site itself, so a class nobody
passes to one of these three gets no mapper.

```bit
import { Executor, Rows, Value, find, findOne, findOneOrFail } from "std/sql"

class User {
  id: i64,
  email: string,
}

fn activeUsers(db: Executor): []User! {
  return find<User>(db, "SELECT id, email FROM users WHERE active = ?", Value.Int(1))?
}

fn userById(db: Executor, id: i64): Option<User>! {
  return findOne<User>(db, "SELECT id, email FROM users WHERE id = ?", Value.Int(id))?
}

fn mustUserById(db: Executor, id: i64): User! {
  return findOneOrFail<User>(db, "SELECT id, email FROM users WHERE id = ?", Value.Int(id))?
}
```

A field's column is its own name in **snake_case** - `createdAt` claims
`created_at` - unless the field carries `@column("...")`, which overrides it
exactly: `@column("e_mail")` claims `e_mail`. `@column` is compiler-known,
excluded from #3879's field-attribute call-desugaring the same way `@key`
is, so a plain class needs no import to use it.

A result column no field claims is **ignored**: `select *` is ordinary SQL,
and a class is often a projection. A field whose type is not one of the five
scalars, or `Option<>` of one, is a compile error (`E0154`) naming the field
and its type.

### A `@table` class is marked persisted at hydration

When `T` also carries `@table`, the generated mapper calls
`markPersisted(true)` (SPEC §10.5) on the value it built, right before
handing it back - so anything `find`/`findOne`/`findOneOrFail` returns reads
`isPersisted() == true`. A composite literal never does this: `User{ id: 1,
email: "a@b.com" }` reads `isPersisted() == false` until something calls
`markPersisted(true)` on it by hand. That distinction is what `db.save` (in
`bitlang.org/pkg/orm`) needs to choose an UPDATE over an INSERT without
inspecting the primary key, which a UUID or application-assigned key rules
out.

```bit
import { Executor, Rows, Value, findOneOrFail, FieldDesc, AttrDesc } from "std/sql"

@table class User {
  @id
  id: i64
  email: string
}

fn firstActiveUser(db: Executor): User! {
  return findOneOrFail<User>(db, "SELECT id, email FROM users WHERE active = ?", Value.Int(1))?
}
```

`firstActiveUser`'s result has `isPersisted() == true`. A class with no
`@table` has neither accessor at all - the mapper only ever calls a member
the class actually declares.

### `find<T>(db: Executor, sqlText: string, ...args: Value): []T!`

Maps every row into `T`. `T` must be a plain class - refusing one that
declares `init` (`E0152`, naming the class and the `init`: the mapper
assigns fields directly through a composite literal, bypassing whatever
invariant a hand-written `init` enforces) - or one of the five scalar types
for a single-column result. Anything else, or a call with no explicit type
argument, is `E0151`.

### `findOne<T>(db: Executor, sqlText: string, ...args: Value): Option<T>!`

`find`, for a query expected to match at most one row. The absent row is
`Option.None`, never an error - a `GET /:id` miss is ordinary traffic, not a
failure. More than one row is a `SqlRowError` (`TooManyRows`).

### `findOneOrFail<T>(db: Executor, sqlText: string, ...args: Value): T!`

`findOne`, requiring exactly one row: zero rows fails distinguishably
(`SqlRowCause.NoRows`) from every mapping error, and more than one row fails
with `TooManyRows`.

### `SqlRowCause`

```
MissingColumn | TypeMismatch | NullField | ColumnCount | NoRows | TooManyRows
```

Why one row failed to become a `T`: a claimed column absent from the result,
a type mismatch, a `NULL` landing in a field that is not `Option`, a plain
scalar `T` against a result that is not exactly one column, and
`findOne`/`findOneOrFail`'s own row-count contract.

### `SqlRowError`

```
cause: SqlRowCause
column: string
expected: string
found: string
```

The error every row-mapping failure produces, satisfying the predeclared
`error` interface through `message()`. `column` is the claimed column name -
empty for `NoRows`/`TooManyRows`, which name no column. `expected`/`found`
are filled for `TypeMismatch` (the two type names) and `ColumnCount` (the
wanted and the actual column count).

## Row-mapping primitives

The named functions the compiler's synthesised mapper is written in terms
of. They are exported because the generated code lives in the CLASS's own
module and calls them by name, and they are a usable API in their own
right for a hand-written mapper over a shape `find<T>` does not cover: pass
one as the `mapper` argument of `sqlFindMany`/`sqlFindOne`/
`sqlFindOneOrFail` below in place of a synthesised one.

Each scalar type has a **required** and an **Option** form, taking the
result's columns (`Rows.columns()`, read once) and the column name to
claim. The required form fails with `NullField` on `NULL`; the `Option` form
decodes `NULL` to `None` instead. Both fail with `MissingColumn` when `col`
is not in `cols`, and `TypeMismatch` when the column holds neither the
wanted variant nor (for `sqlReqBool`/`sqlOptBool`) an `Int`. SQL has no
boolean wire type (`Value`, ./sql.bit), so a `bool` field reads an `Int`
column as zero/nonzero.

### `sqlReqInt(rows: Rows, cols: []string, col: string): i64!`

The integer claimed by column `col`.

### `sqlReqFloat(rows: Rows, cols: []string, col: string): f64!`

The float claimed by column `col`.

### `sqlReqBool(rows: Rows, cols: []string, col: string): bool!`

The boolean claimed by column `col`, read from an `Int` column as
zero/nonzero.

### `sqlReqText(rows: Rows, cols: []string, col: string): string!`

The string claimed by column `col`.

### `sqlReqBlob(rows: Rows, cols: []string, col: string): []byte!`

The bytes claimed by column `col`.

### `sqlOptInt(rows: Rows, cols: []string, col: string): Option<i64>!`

The integer claimed by column `col`, or `None` on `NULL`.

### `sqlOptFloat(rows: Rows, cols: []string, col: string): Option<f64>!`

The float claimed by column `col`, or `None` on `NULL`.

### `sqlOptBool(rows: Rows, cols: []string, col: string): Option<bool>!`

The boolean claimed by column `col`, or `None` on `NULL`.

### `sqlOptText(rows: Rows, cols: []string, col: string): Option<string>!`

The string claimed by column `col`, or `None` on `NULL`.

### `sqlOptBlob(rows: Rows, cols: []string, col: string): Option<[]byte>!`

The bytes claimed by column `col`, or `None` on `NULL`.

### `decimal` columns: `sqlReqDecimal`/`sqlOptDecimal`

`decimal` is not a `Value` variant - `Value` stays the five wire types above,
and every driver sends a `DECIMAL`/`NUMERIC` column as `Value.Text` (the
literal a database renders it as, `"1234.5678"`). `sqlReqDecimal` and
`sqlOptDecimal` are the accessor: the same conversion every driver's own
codec already does (`pkg/mysql`'s `mysqlDecimal` is `asText` then
`parseDecimal`), so one accessor serves every driver with no per-driver
mechanism. `find<T>` cannot map a `decimal` field itself - it is not one of
the five scalar types - so a class with one is mapped by hand:

```bit
import { Rows, sqlReqInt, sqlReqDecimal, sqlOptDecimal } from "std/sql"

class Order {
  id: i64,
  price: decimal,
  refunded: Option<decimal>,
}

fn orderMapper(rows: Rows): Order! {
  let cols = rows.columns()
  return Order{
    id: sqlReqInt(rows, cols, "id")?,
    price: sqlReqDecimal(rows, cols, "price")?,
    refunded: sqlOptDecimal(rows, cols, "refunded")?,
  }
}
```

### `sqlReqDecimal(rows: Rows, cols: []string, col: string): decimal!`

The decimal literal claimed by column `col`, parsed with `std/decimal`'s
`parseDecimal`. Fails naming the column if the text is not a valid decimal,
or if the column overflows `decimal`'s 96-bit magnitude / scale-28 range
(`std/decimal`'s own limit, never a silent round).

### `sqlOptDecimal(rows: Rows, cols: []string, col: string): Option<decimal>!`

The decimal literal claimed by column `col`, or `None` on `NULL`.

### Temporal, uuid, json and array columns

A date, a time, a timestamp, a uuid, a JSON document and an array are the
rest of the standard SQL type surface, and until now `find<T>` and a
hand-written mapper both had no way to read one: `Value` stops at
`Null`/`Int`/`Float`/`Text`/`Blob`, so a `timestamptz` or a `uuid` column
arrived as a `Text` a caller had to parse by hand, per driver. These
accessors are that parse, written once here rather than in every caller -
and, like `decimal` above, every one of these types stays `Value.Text` on
the wire on both drivers, because a database renders a date or a uuid as
text even when it renders an integer as one.

One accessor covers `timestamp` and `timestamptz` together:
`sqlReqTimestamp` reads a trailing UTC offset when the text carries one
(`timestamptz`) and treats an offset-less reading as already UTC
(`timestamp`), returning a true instant either way - a `Value` carries no
record of which SQL type produced it, so there is nothing to switch on.

Arrays are **one generic accessor over an element decoder**, the same
generic-plus-closure shape `sqlFindMany<T>` already uses for a whole row:
`sqlReqArray<T>(rows, cols, col, elem)` splits a Postgres `{...}` array
literal into its elements and applies `elem: (Value) => T!` to each.
`sqlElemInt`/`sqlElemFloat`/`sqlElemBool`/`sqlElemText`/`sqlElemBlob`/
`sqlElemDecimal` are the six built-in decoders, one per scalar type,
mirroring `sqlReqInt`/`sqlReqFloat`/... above; pass the matching one, or
write a closure for anything else.

A shipment row exercises every one of them - required and optional forms,
a `Json` tree, a `Json`-backed class, and an array of each scalar:

```bit
import {
  Rows, sqlReqInt, sqlReqTimestamp, sqlOptTimestamp, sqlReqDate, sqlOptDate,
  sqlReqTime, sqlOptTime, sqlReqUuid, sqlOptUuid, sqlReqJson, sqlOptJson,
  sqlReqJsonAs, sqlOptJsonAs, sqlReqArray, sqlOptArray,
  sqlElemInt, sqlElemFloat, sqlElemBool, sqlElemText, sqlElemBlob, sqlElemDecimal,
} from "std/sql"
import { Timestamp, Date, Time } from "std/time"
import { UUID } from "std/uuid"
import { Json, JsonEntry } from "std/json"

@json class ShipmentSettings {
  carrier: string,
  insured: bool,
}

class Shipment {
  id: i64,
  trackingId: UUID,
  externalId: Option<UUID>,
  placedAt: Timestamp,
  cancelledAt: Option<Timestamp>,
  shipDate: Date,
  deliveredDate: Option<Date>,
  cutoff: Time,
  pickupTime: Option<Time>,
  manifest: Json,
  extra: Option<Json>,
  settings: ShipmentSettings,
  backorderSettings: Option<ShipmentSettings>,
  itemIds: []i64,
  weights: []f64,
  flags: []bool,
  notes: []string,
  photos: [][]byte,
  totals: []decimal,
  backorderIds: Option<[]i64>,
}

fn shipmentMapper(rows: Rows): Shipment! {
  let cols = rows.columns()
  return Shipment{
    id: sqlReqInt(rows, cols, "id")?,
    trackingId: sqlReqUuid(rows, cols, "tracking_id")?,
    externalId: sqlOptUuid(rows, cols, "external_id")?,
    placedAt: sqlReqTimestamp(rows, cols, "placed_at")?,
    cancelledAt: sqlOptTimestamp(rows, cols, "cancelled_at")?,
    shipDate: sqlReqDate(rows, cols, "ship_date")?,
    deliveredDate: sqlOptDate(rows, cols, "delivered_date")?,
    cutoff: sqlReqTime(rows, cols, "cutoff")?,
    pickupTime: sqlOptTime(rows, cols, "pickup_time")?,
    manifest: sqlReqJson(rows, cols, "manifest")?,
    extra: sqlOptJson(rows, cols, "extra")?,
    settings: sqlReqJsonAs<ShipmentSettings>(rows, cols, "settings")?,
    backorderSettings: sqlOptJsonAs<ShipmentSettings>(rows, cols, "backorder_settings")?,
    itemIds: sqlReqArray<i64>(rows, cols, "item_ids", sqlElemInt)?,
    weights: sqlReqArray<f64>(rows, cols, "weights", sqlElemFloat)?,
    flags: sqlReqArray<bool>(rows, cols, "flags", sqlElemBool)?,
    notes: sqlReqArray<string>(rows, cols, "notes", sqlElemText)?,
    photos: sqlReqArray<[]byte>(rows, cols, "photos", sqlElemBlob)?,
    totals: sqlReqArray<decimal>(rows, cols, "totals", sqlElemDecimal)?,
    backorderIds: sqlOptArray<i64>(rows, cols, "backorder_ids", sqlElemInt)?,
  }
}
```

`sqlReqJson`/`sqlOptJson` return a `Json` tree for a caller that does not
know the column's shape ahead of time - `manifest` above. `sqlReqJsonAs<T>`/
`sqlOptJsonAs<T>` decode straight into a class instead, the shape most
callers actually want - `settings` above. Both pairs keep a SQL NULL and a
stored JSON `null` distinct, matching `pkg/orm/docs/json.md`: a SQL NULL
fails `NullField` (`Req`) or decodes to `None` (`Opt`); a stored JSON `null`
document decodes successfully, to `Json.JsonNull` or a class's own
`null`-shaped field, because it is data the row actually holds.

### `sqlReqTimestamp(rows: Rows, cols: []string, col: string): Timestamp!`

### `sqlOptTimestamp(rows: Rows, cols: []string, col: string): Option<Timestamp>!`

The instant claimed by column `col`, reading `timestamp` or `timestamptz`
text alike.

### `sqlReqDate(rows: Rows, cols: []string, col: string): Date!`

### `sqlOptDate(rows: Rows, cols: []string, col: string): Option<Date>!`

The calendar date claimed by column `col`.

### `sqlReqTime(rows: Rows, cols: []string, col: string): Time!`

### `sqlOptTime(rows: Rows, cols: []string, col: string): Option<Time>!`

The time-of-day claimed by column `col`, with 0..6 fractional-second digits.

### `sqlReqUuid(rows: Rows, cols: []string, col: string): UUID!`

### `sqlOptUuid(rows: Rows, cols: []string, col: string): Option<UUID>!`

The uuid claimed by column `col`, parsed with `std/uuid`'s `parse`.

### `sqlReqJson(rows: Rows, cols: []string, col: string): Json!`

### `sqlOptJson(rows: Rows, cols: []string, col: string): Option<Json>!`

The `Json` tree claimed by column `col`, parsed with `std/json`'s
`jsonParse`.

### `sqlReqJsonAs<T>(rows: Rows, cols: []string, col: string): T!`

### `sqlOptJsonAs<T>(rows: Rows, cols: []string, col: string): Option<T>!`

Column `col`'s JSON, decoded straight into `T` with `std/json`'s
`jsonDecode<T>` - `T` must carry `@json`, the same mark `jsonDecode<T>`
itself requires.

### `sqlReqArray<T>(rows: Rows, cols: []string, col: string, elem: (Value) => T!): []T!`

### `sqlOptArray<T>(rows: Rows, cols: []string, col: string, elem: (Value) => T!): Option<[]T>!`

Column `col`'s Postgres `{...}` array literal, decoded to `[]T` by applying
`elem` to each element. `{}` is an empty slice; a nested `{{1,2},{3,4}}`
fails by name rather than silently flattening - Postgres arrays may be
multi-dimensional, this accessor is one dimension only. An embedded `NULL`
element fails naming the column, unless `elem` itself tolerates
`Value.Null`.

### `sqlElemInt(v: Value): i64!`

### `sqlElemFloat(v: Value): f64!`

### `sqlElemBool(v: Value): bool!`

### `sqlElemText(v: Value): string!`

### `sqlElemBlob(v: Value): []byte!`

### `sqlElemDecimal(v: Value): decimal!`

The six built-in element decoders for `sqlReqArray<T>`/`sqlOptArray<T>`,
one per scalar type above. Each matches `Value.Text` - an array element is
its own substring on the wire, never a typed sub-`Value` - and fails on a
`NULL` element or text that does not parse as its type.

Five more functions serve `find<T>`/`findOne<T>`/`findOneOrFail<T>` for a
**plain scalar `T`** (no class declared): each requires the result to carry
**exactly one** column, failing with `ColumnCount` otherwise, then applies
the matching required accessor above to column `0`.

### `sqlRowScalarInt(rows: Rows): i64!`

### `sqlRowScalarFloat(rows: Rows): f64!`

### `sqlRowScalarBool(rows: Rows): bool!`

### `sqlRowScalarText(rows: Rows): string!`

### `sqlRowScalarBlob(rows: Rows): []byte!`

### `sqlFindMany<T>(db: Executor, sqlText: string, args: []Value, mapper: (Rows) => T!): []T!`

`find<T>`'s own implementation: runs `sqlText`/`args` and maps every row
through `mapper`.

### `sqlFindOne<T>(db: Executor, sqlText: string, args: []Value, mapper: (Rows) => T!): Option<T>!`

`findOne<T>`'s own implementation.

### `sqlFindOneOrFail<T>(db: Executor, sqlText: string, args: []Value, mapper: (Rows) => T!): T!`

`findOneOrFail<T>`'s own implementation.
