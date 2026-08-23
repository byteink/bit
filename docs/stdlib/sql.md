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
