# std/sql

The database driver contract — an interface with **no driver behind it**.
Nothing here talks to a database; `bit/pkg/` is where a concrete driver will
eventually live, consumed by name through the `Registry` this module defines.
Shipping the contract from stdlib rather than as a package is deliberate: a
contract shipped as a package invites a second, competing one, and every
driver ends up picking a side. Go's `database/sql` is the shape this follows.

**The only way to supply a value is `params []Value`.** `query`/`exec` take
the literal SQL text and an ordered list of typed `Value`s as two separate
arguments; nothing in this module ever builds SQL text by concatenating a
value into it. There is no function anywhere in `std/sql` that accepts a
pre-interpolated string with values already substituted in.

**Placeholder syntax is not specified here.** Postgres numbers its
placeholders (`$1`, `$2`, ...); MySQL and SQLite use a positional `?`. This
module picks neither — `sqlText` carries whatever placeholder marker the
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

The typed accessor for an `Int` value. Fails if `v` holds any other variant —
`match (v)` directly when the column's type is not known ahead of time.

### `asFloat(v: Value): f64!`

The typed accessor for a `Float` value. Fails on any other variant.

### `asText(v: Value): string!`

The typed accessor for a `Text` value. Fails on any other variant.

### `asBlob(v: Value): []byte!`

The typed accessor for a `Blob` value. Fails on any other variant.

## The driver contract

### `Driver`

`open(dsn: string): Conn!` — the one thing every concrete driver package
implements. `dsn` is a driver-specific connection string; its format is
entirely the driver's own.

### `Conn`

A single logical database connection, as handed back by `Registry.open`.
Several green threads may hold and use the same `Conn` at once — see
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
affected — never a row set. Postgres's `RETURNING` clause can turn an
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
names in order; `value` reads column `col` (0-based) of the current row —
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

`query`/`exec` behave exactly as `Conn`'s do, scoped to this transaction;
exactly one of `commit`/`rollback` must be called to end it, and using the
`Tx` afterward is a caller bug, same as using a `Conn` after `close`.

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
it never interleave calls on the one underlying socket it represents — a
single-slot connection pool, sized at exactly one physical connection per
`open()` call, the minimum that satisfies "must not let two green threads
interleave on one socket". A driver that wants true N-way concurrency pools
several physical connections internally and hands one out per `open`; the
registry still serializes access to whichever one it gets.

```bit
import { Registry, Driver, Conn, Value, asText } from "std/sql"

// A program wires up a driver package's setup once, naming it by string —
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

## The connection pool

A server has two wrong ways to reach a database and one right one. Open a
connection per request and every request pays a TCP handshake plus
authentication, and a burst exhausts the database's own connection limit.
Share one connection between requests and the application serialises on it —
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
   reused — including after a `commit` that failed, since the pool cannot
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
configuration that cannot describe a pool — an unset `DATABASE_URL` surfaces
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
that reaches it. One class, not two — splitting connection settings from
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

**`uri` and the individual fields are mutually exclusive.** Setting both is
an error naming both, not one silently winning. Parsing `uri` is the
adapter's job, not this module's: Postgres spells the TLS setting
`sslmode=verify-full` and MySQL spells it `ssl-mode=VERIFY_IDENTITY`, so
there is deliberately no `parseUrl` here.

**`maxOpen` is 10, argued not guessed.** Postgres ships
`max_connections = 100`, so one instance defaulting to 100 takes the
server's whole budget and the second container — or the operator's `psql` —
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
socket: neither `uri` nor `host` set (nothing to connect to — the unset
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
cannot carry an explicit default — a variant is not a constant expression
(SPEC §10.5, `E0064`) — so an omitted `sslmode` takes the enum's *first
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
until the returned `Rows` is closed** — a cursor lives on the connection
that produced it — so a caller that never closes its `Rows` leaks a
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

### `Pool.begin(): Tx!`

Starts a transaction on one connection and keeps that connection until
`commit` or `rollback` ends it. Every statement issued through the returned
`Tx` runs on that one connection — rule 1, held by the object graph rather
than by a check.

```bit
import { Pool, Value } from "std/sql"

fn transfer(db: Pool, payer: string, payee: string, cents: int): ()! {
  let tx = db.begin()?
  tx.exec(
    "UPDATE accounts SET balance = balance - ? WHERE id = ?",
    [Value.Int(cents), Value.Text(payer)],
  ) catch e {
    tx.rollback()?
    fail e
  }
  tx.exec(
    "UPDATE accounts SET balance = balance + ? WHERE id = ?",
    [Value.Int(cents), Value.Text(payee)],
  ) catch e {
    tx.rollback()?
    fail e
  }
  tx.commit()?
}
```

### `Pool.close()`

Closes every idle connection and fails every parked caller. Connections
still checked out are closed as they are returned. Idempotent.

### `FatalError`

```
message(): string
transportFatal(): bool
```

The marker a driver failure carries when the failure has poisoned the
*connection* rather than merely failing the statement: a closed socket, a
short read, a protocol desync. The pool never hands such a connection out
again (rule 3). A failure that does not implement `FatalError` — a
constraint violation, a syntax error — leaves the connection usable, which
is the common case and needs no cooperation from the driver at all.

### `transportError(detail: string): error`

A ready-made `FatalError`, for a driver with no error type of its own to
extend.
