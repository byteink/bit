# bitlang.org/pkg/orm

Writing SQL by hand for a table's ordinary reads and writes means the same
five statements over and over, and a typo in a column name that only shows
up when that code path finally runs. `orm` maps a `@table` class to its
table for you - one `open(url)` per process, `db.table<T>()` for a
repository over one class, and a find/write chain with every column name
checked against the class at compile time.

## Install

`bit add bitlang.org/pkg/orm@v0.4.0` writes:

```json
{
  "dependencies": {
    "orm": "bitlang.org/pkg/orm@v0.4.0"
  }
}
```

## Usage

```bit
import { open } from "orm"

@table class Article {
  id: i64,
  title: string,
  body: string,
}

fn main(): ()! {
  let db = open("postgres://localhost/inkwell")?
  let articles = db.table<Article>()

  let a = articles.insert(Article{ id = 0, title = "Hello", body = "First post." })?
  let same = articles.find(a.id)?
  let recent = articles.where("title", "Hello").orderBy("id").limit(10).all()?

  a.title = "Hello, Inkwell"
  articles.update(a)?
  articles.delete(a.id)?
}
```

`open` picks the driver from the URL's own scheme (`postgres://`,
`mysql://`) - nothing else in your program names one. `db.table<Article>()`
already holds the connection, so no function in this package takes `db` as
an argument the way an older version of this package's `find`/`save` did.

## Docs

Reading rows through the find chain (`where`, `orderBy`, `limit`, `offset`,
`after`, `with`) is [`docs/query.md`](docs/query.md). Inserting, updating,
deleting and bulk writes (`insertAll`, `set().updateAll()`, `deleteAll`)
and optimistic locking with `@version` is [`docs/write.md`](docs/write.md).
`@hasMany`/`@belongsTo` and how a relation loads when you read it is
[`docs/relation.md`](docs/relation.md). Many-to-many relations - the join
table's DDL, loading, and `link`/`unlink` - is
[`docs/manytomany.md`](docs/manytomany.md). Marking a row deleted instead
of removing it is [`docs/softdelete.md`](docs/softdelete.md). Filling
`createdAt`/`updatedAt` automatically is
[`docs/timestamps.md`](docs/timestamps.md). Locking a row against a
concurrent writer with `tx.table<T>().lock(mode)` is
[`docs/locking.md`](docs/locking.md). Escaping to raw SQL with
`db.exec`/`db.query<T>` and running inside a transaction with `db.tx(...)`
is [`docs/raw.md`](docs/raw.md).

Table and column names are mapped from a `@table` class's field names - see
[`docs/naming.md`](docs/naming.md). Declaring and altering tables is
[`docs/schema.md`](docs/schema.md), rendered to real DDL by a `Dialect` -
[`docs/dialect.md`](docs/dialect.md), `Postgres` first,
[`docs/mysql.md`](docs/mysql.md) for `Mysql` and where its DDL diverges. A
`jsonb`/`json` column for a `Json` tree or a `@json` class field is
[`docs/json.md`](docs/json.md). An enum field mapped to a `text` column
with a CHECK constraint listing its variants by name is
[`docs/enum.md`](docs/enum.md). Turning a driver's constraint-violation
error into a typed, catchable cause is [`docs/errors.md`](docs/errors.md).
Applying a hand-written migration file against a live database is
[`docs/migrate.md`](docs/migrate.md). Failing CI when your
entities and the live schema disagree is [`docs/check.md`](docs/check.md).
Synchronizing a dev database straight from your entities, no migration
file, is [`docs/sync.md`](docs/sync.md). Running your own test suite inside
a transaction that always rolls back is
[`docs/testing.md`](docs/testing.md).
Restricting which rows an actor may read or write with an authorization
layer passed as `open(url, Options{ authz = guard })` is
[`docs/guard.md`](docs/guard.md).

## `Dialect` vs `ServerDialect`

Two different types answer "which database", and they answer different
questions. [`Dialect`](docs/dialect.md) is an interface with one method,
`render(op: SchemaOp): []Statement` - it turns a schema migration into the
DDL one engine understands, and gains a new implementation per engine
(`Postgres`, then `Mysql` - see [`docs/mysql.md`](docs/mysql.md)).
`ServerDialect` (`pkg/orm/db.bit`) is a value - `Postgres` or
`Mysql(MysqlVersion)` - that `open` derives once from the URL and carries
onto every repository it hands out, deciding a syntax or a capability:
`upsert`'s `ON CONFLICT` vs `ON DUPLICATE KEY UPDATE`, many-to-many
`link`'s idempotent insert, `lock`'s `SKIP LOCKED` (which needs the real
MySQL version, not just the engine), and the migration runner's advisory
lock.

They stay separate types because folding the value into the
interface would make every `upsert` caller hand it a full `Dialect`
implementation to express a syntax choice, and because a `Dialect` renders
DDL while a `ServerDialect` renders nothing at all.

For how first-party packages in this repository are laid out, gated,
versioned and released, see [`pkg/README.md`](../README.md).
