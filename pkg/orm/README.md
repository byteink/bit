# bitlang.org/pkg/orm

An ORM for `std/sql`: define your tables as classes, then query, write and
migrate against them without hand-writing SQL for the common cases - while
still being able to drop to raw SQL when you need to.

It gives you a schema builder for declaring tables and columns, a find
chain (`where`, `orderBy`, `limit`, and more) with column names checked
against your class at compile time, `save`/`delete`/`upsert` for single
rows, `hasMany`/`hasOne`/`belongsTo` relations with eager loading,
migrations generated from your entities, soft deletes, optimistic locking,
and row locking for concurrent writers. Every one of these has its own
page under [Docs](#docs) below.

## Install

`bit add bitlang.org/pkg/orm@v0.1.0` writes:

```json
{
  "dependencies": {
    "orm": "bitlang.org/pkg/orm@v0.1.0"
  }
}
```

## Usage

```bit
import { Data } from "orm"
import { Value } from "std/sql"

// Written once, against Data instead of a concrete Pool: runs standalone
// (its own transaction per statement) or inside a caller's `pool.tx(...)`
// block (one transaction for the whole call), with no second version.
fn transfer(db: Data, fromId: i64, toId: i64, amt: i64): ()! {
  db.exec("update accounts set balance = balance - ${amt} where id = ${fromId}", []Value(0))?
  db.exec("update accounts set balance = balance + ${amt} where id = ${toId}", []Value(0))?
}
```

## Docs

See [`docs/data.md`](docs/data.md) for `Data` and the call sites (`pool`
alone, `pool.tx(...)`, `pool.txValue<T>(...)`). Table and column names are
mapped from a `@table` class's field names - see
[`docs/naming.md`](docs/naming.md). Declaring and altering tables is
[`docs/schema.md`](docs/schema.md), rendered to real DDL by a
`Dialect` - [`docs/dialect.md`](docs/dialect.md), `Postgres` first,
[`docs/mysql.md`](docs/mysql.md) for `Mysql` and where its DDL diverges.
A `jsonb`/`json` column for a `Json` tree or a `@json` class field, and
why a SQL NULL is never the same value as a stored JSON `null`, is
[`docs/json.md`](docs/json.md).
An enum field mapped to a `text` column with a CHECK constraint listing
its variants by name, never a native database enum type, is
[`docs/enum.md`](docs/enum.md).
Querying rows through the find chain is [`docs/query.md`](docs/query.md).
Saving, deleting and upserting a row is [`docs/write.md`](docs/write.md).
Writing or removing rows with no instance loaded is
[`docs/patch.md`](docs/patch.md). Filling `createdAt`/`updatedAt`
automatically is [`docs/timestamps.md`](docs/timestamps.md). Turning a
driver's constraint-violation error into a typed, catchable cause is
[`docs/errors.md`](docs/errors.md). Inserting many rows in one statement is
[`docs/bulk.md`](docs/bulk.md). Paginating a large table without `OFFSET`'s
cost growing with depth is [`docs/keyset.md`](docs/keyset.md).
`hasMany`/`hasOne`/`belongsTo` and eager loading with `with()` is
[`docs/relation.md`](docs/relation.md). Many-to-many relations - the join
table's DDL, eager loading and `attach`/`detach`/`sync` - is
[`docs/manytomany.md`](docs/manytomany.md). Marking a row deleted instead of
removing it is [`docs/softdelete.md`](docs/softdelete.md). Optimistic
locking against a lost update is [`docs/version.md`](docs/version.md).
Locking a row against a concurrent writer with `forUpdate` is
[`docs/locking.md`](docs/locking.md).
Writing a reviewed migration file from your entities is
[`docs/generate.md`](docs/generate.md). Applying that file against a live
database is [`docs/migrate.md`](docs/migrate.md). Running your own test
suite inside a transaction that always rolls back is
[`docs/testing.md`](docs/testing.md).

## `Dialect` vs `ServerDialect`

Two different types answer "which database", and they answer different
questions. [`Dialect`](docs/dialect.md) is an interface with one method,
`render(op: SchemaOp): []Statement` - it turns a schema migration into the
DDL one engine understands, and gains a new implementation per engine
(`Postgres`, then `Mysql` - see [`docs/mysql.md`](docs/mysql.md)).
`ServerDialect` (`pkg/orm/data.bit`) is a value - `Postgres` or
`Mysql(MysqlVersion)` - that every dialect-sensitive function takes to
decide a syntax or a capability: `upsert`'s `ON CONFLICT` vs `ON DUPLICATE
KEY UPDATE`, `attach`/`sync`'s idempotent insert, `forUpdate`'s
`SKIP LOCKED` (which needs the real MySQL version, not just the engine),
and the migration runner's advisory lock.

They stay separate types because folding the value into the
interface would make every `upsert` caller hand it a full `Dialect`
implementation to express a syntax choice, and because a `Dialect` renders
DDL while a `ServerDialect` renders nothing at all.

For how first-party packages in this repository are laid out, gated,
versioned and released, see [`pkg/README.md`](../README.md).
