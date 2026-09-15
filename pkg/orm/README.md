# bitlang.org/pkg/orm

An ORM for `std/sql`, built on `@table` (SPEC section 10.5's class attribute)
and the descriptor it synthesizes. This package is under active development
(epic #5050); today it exports `Data`, the interface every ORM function is
written against instead of a concrete `Pool`, the name mapping from a Bit
field to its SQL table and column, the schema builder that declares tables,
columns, indexes and foreign keys as an intent tree for a dialect to
render, `Query<T>`, the find chain (`where`/`whereIn`/`whereNull`/
`whereLike`/`orderBy`/`limit`/`offset`) whose string-literal column names
are checked against `T`'s fields at compile time, `save`/`delete`/
`upsert`, the three write verbs: one `save` for a new or already-persisted
entity, decided by a hidden flag rather than the primary key, and 0 rows
matched by an UPDATE is an error rather than a silent no-op, and
`update`/`deleteMany`, the patch builder for writing or removing rows by a
`where` clause with no instance loaded - a bare call touching every row is
refused unless `.all()` says so on purpose, and `@timestamps`, filling
`createdAt` on INSERT and `updatedAt` on every write, single or bulk.

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
`SchemaDialect` - [`docs/dialect.md`](docs/dialect.md), `Postgres` first.
Querying rows through the find chain is [`docs/query.md`](docs/query.md).
Saving, deleting and upserting a row is [`docs/write.md`](docs/write.md).
Writing or removing rows with no instance loaded is
[`docs/patch.md`](docs/patch.md). Filling `createdAt`/`updatedAt`
automatically is [`docs/timestamps.md`](docs/timestamps.md). Turning a
driver's constraint-violation error into a typed, catchable cause is
[`docs/errors.md`](docs/errors.md).

For how first-party packages in this repository are laid out, gated,
versioned and released, see [`pkg/README.md`](../README.md).
