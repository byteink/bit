# bitlang.org/pkg/orm

An ORM for `std/sql`, built on `@table` (SPEC section 10.5's class attribute)
and the descriptor it synthesizes. This package is under active development
(epic #5050); today it exports `Data`, the interface every ORM function is
written against instead of a concrete `Pool`, the name mapping from a Bit
field to its SQL table and column, the schema builder that declares tables,
columns, indexes and foreign keys as an intent tree for a dialect to
render, `t.json`/`AlterTable.addJson`, a `jsonb`/`json` column for a raw
`Json` tree or a `@json` class field, with `jsonColumnValue`/
`jsonColumnRead`/`jsonColumnDecode<T>` as its write and read halves and a
SQL NULL always kept distinct from a stored JSON `null`, `Query<T>`, the
find chain (`where`/`whereIn`/`whereNull`/
`whereLike`/`orderBy`/`limit`/`offset`) whose string-literal column names
are checked against `T`'s fields at compile time, `save`/`delete`/
`upsert`, the three write verbs: one `save` for a new or already-persisted
entity, decided by a hidden flag rather than the primary key, and 0 rows
matched by an UPDATE is an error rather than a silent no-op, and
`update`/`deleteMany`, the patch builder for writing or removing rows by a
`where` clause with no instance loaded - a bare call touching every row is
refused unless `.all()` says so on purpose, `insertAll`, many rows in one
statement, chunked at a computed placeholder limit rather than one
statement per row, `Query<T>.after`, keyset pagination - `WHERE id >
$n` instead of a growing `OFFSET`, so a deep page costs what page 1 does,
`@timestamps`, filling `createdAt` on INSERT and `updatedAt` on every
write, single or bulk, `hasMany`/`hasOne`/`belongsTo` relations with eager
loading via `with()`, batched so loading N parent rows never issues more
than one extra query per relation, never one per row, `manyToManyTable`,
`manyToManyLoader` and `attach`/`detach`/`sync`, the join-table primitives
behind `@manyToMany` - the join table is always named explicitly, never
inferred, `attach`/`sync` are idempotent on both Postgres and MySQL, and
`detach` refuses to become an unfiltered `DELETE`, `@softDelete`,
which makes `delete` mark a row instead of removing it and excludes a
marked row from every ordinary read until
`withTrashed`/`onlyTrashed`/`restore`/`forceDelete` says otherwise, and
`@version`, optimistic locking: `save` on a table carrying it adds the old
version to its UPDATE's WHERE and raises `StaleWriteError`, distinct from a
row-not-found, when another write landed first, `forUpdate`, pessimistic
row locking on the find chain - `FOR UPDATE` blocks until a row is free,
`FOR UPDATE SKIP LOCKED` never blocks and returns fewer rows than the query
matched, and both are refused outside a transaction and on `count()`/
`exists()`, and `Query<T>.whereRaw`/
`orderByField`, the one escape hatch for SQL text or a dynamic column
name the rest of the builder cannot express - values still bind through
placeholders and a dynamic column is checked against an allowlist, never
escaped or quoted, `generate`, which diffs your `@table` entities against
the live schema and writes a reviewed migration file - never applying
anything and never inferring a rename from a drop next to an add, and
`up`/`status`/`sql`/`down`, applying a checked-in migration registry
against a live database with an advisory lock around the run and one
transaction per migration, the ledger row inside it, `Mysql`, the second
`Dialect` implementation - the same intent tree rendered to MySQL's own DDL,
with every place it diverges from Postgres named on one page, and
`withRollback`/`make`/`create`/`Seq`, running your own test suite inside a
transaction that always rolls back, even on success, so nothing a test
writes is ever there to clean up.

## Install

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

They stay separate types (#5325, #5384) because folding the value into the
interface would make every `upsert` caller hand it a full `Dialect`
implementation to express a syntax choice, and because a `Dialect` renders
DDL while a `ServerDialect` renders nothing at all.

`ServerDialect` replaced two narrower types in #5384: `UpsertDialect`, a
bare engine tag, and `LockDialect`, which carried a version. The richer
shape won because a tag cannot answer a version question - and with it went
`LockDialect.Neutral`, whose meaning was "trust me, this MySQL is 8.0 or
later". A MySQL caller now supplies a real version.

For how first-party packages in this repository are laid out, gated,
versioned and released, see [`pkg/README.md`](../README.md).
