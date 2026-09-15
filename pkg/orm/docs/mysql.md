# Target MySQL instead of Postgres

[Dialect](dialect.md) turns the same `table()`/`alter()`/`drop()` tree into
real DDL, one implementation per engine. `Postgres` was first. `Mysql`
renders the identical intent tree - nothing about how you build a migration
changes - but MySQL's own syntax, type system and transaction model differ
enough that the SQL text, and in two places the guarantees you get, are not
just "Postgres with different keywords".

## The simplest thing that works

```bit
import { Mysql, Postgres, SchemaOp, table } from "orm"

fn createWidgetsOp(): SchemaOp {
  return table("widgets", (t) => {
    t.id("id")
    t.string("name", 100)
  })
}

fn createWidgetsSql(): (string, string) {
  let op = createWidgetsOp()
  let pg = Postgres{}.render(op)
  let my = Mysql{}.render(op)
  return (pg[0].sql, my[0].sql)
}
```

`createWidgetsSql()` returns:

```text
Postgres: create table "widgets" (
  "id" bigint generated always as identity primary key,
  "name" varchar(100) not null
);

MySQL:    create table `widgets` (
  `id` bigint auto_increment primary key,
  `name` varchar(100) not null
);
```

Same tree, same column, two different keywords for `t.id`'s auto-generated
primary key (`generated always as identity` versus `auto_increment`) and two
different identifier-quoting rules (double quotes versus backticks). Neither
is a bug in the other; each is what its own engine's DDL requires.

## Growing it: every divergence in one table

```bit
fn peopleOp(): SchemaOp {
  return table("people", (t) => {
    t.id("id")
    t.string("email", 255).unique()
    t.text("bio").nullable()
    t.bool("is_active")
    t.decimal("balance").nullable()
    t.timestamp("joined_at").nullable()
    t.index("bio")
  })
}

fn peopleMysqlSql(): []string {
  let stmts = Mysql{}.render(peopleOp())
  let out = []string(0)
  for s of stmts {
    out = append(out, s.sql)
  }
  return out
}
```

`peopleMysqlSql()` returns two statements:

```text
create table `people` (
  `id` bigint auto_increment primary key,
  `email` varchar(255) not null unique,
  `bio` text,
  `is_active` tinyint(1) not null,
  `balance` decimal(38,9),
  `joined_at` timestamp
);

create index `people_bio_idx` on `people` (`bio`(255));
```

Four more divergences show up here: `is_active` is `tinyint(1)`, not
`boolean` - MySQL has no native boolean storage type, and `tinyint(1)` is the
convention its own client libraries treat as one. `balance` is
`decimal(38,9)`, not the bare, unconstrained `numeric` Postgres renders -
MySQL has no arbitrary-precision decimal type, so this bound is unavoidable,
and unlike Postgres it can silently round a value needing more than 9
fractional or 29 integer digits. `joined_at` is `timestamp` - which sounds
like Postgres' zone-*naive* `timestamp`, but is MySQL's zone-*aware* type;
MySQL's own zone-naive type is the differently-named `datetime`. Porting the
Postgres mapping by name lands on the wrong one, so `Mysql` never does. And
`bio` is indexed with an explicit `(255)` key-length prefix - MySQL refuses
to index a `text`/`blob` column without one, a limit Postgres never has; this
package always uses `255`, since `Index` carries no per-column length yet.

## Every MySQL statement is non-transactional

```bit
fn everyMysqlStatementIsNonTransactional(): bool {
  let stmts = Mysql{}.render(peopleOp())
  for s of stmts {
    if (s.transactional) {
      return false
    }
  }
  return true
}
```

`everyMysqlStatementIsNonTransactional()` returns `true`. On Postgres, only a
`raw()` statement whose text names `CONCURRENTLY` is flagged
non-transactional (see [Dialect](dialect.md)); every other statement commits
atomically with the migration's own ledger row. On MySQL, InnoDB commits any
open transaction implicitly at almost every DDL statement - `CREATE`,
`ALTER`, `DROP TABLE` and `CREATE INDEX` included, regardless of a
surrounding `BEGIN`/`COMMIT` - so flagging any MySQL statement `true` would
be a lie about what actually happens. `Mysql.render` flags all of them
`false` instead, honestly, and there is no `CONCURRENTLY`-shaped exception to
detect: MySQL has no non-blocking index keyword to scan a `raw()` statement's
text for at all.

That honesty has a real consequence in [the migration runner](migrate.md):
because the runner puts a migration's `schema_history` row inside the same
transaction as its *transactional* statements, and `Mysql` renders none,
that ledger row now commits before the first line of the migration's actual
DDL runs. A migration that fails partway through can leave `schema_history`
recording it as applied when only some of it ran. This is tracked as #5378
(open, not yet fixed as of this page) - a bug in the seam between the runner
and this renderer, not something either one can fix alone. Until it lands,
treat `up`/`down` against MySQL as unsafe for a multi-statement migration;
[Migrate](migrate.md)'s own "On MySQL, none of the paragraph above holds yet"
section covers the mechanism in full.

## The migration runner has no lock on MySQL

The sharpest thing to know before you point `up` at a MySQL database: its
advisory lock is `pg_advisory_lock`, a Postgres statement hardcoded into the
runner. `Dialect` has no lock or unlock method today, so there is nothing for
a MySQL `up` to call - two instances deploying at the same moment both start
applying pending migrations with no coordination between them at all. This
is a separate gap from the ledger-ordering one above; fixing #5378 does not
fix this.

## Every divergence, in one place

| What | Postgres | MySQL |
| ---- | -------- | ----- |
| `t.id(...)`'s primary key | `bigint generated always as identity primary key` | `bigint auto_increment primary key` |
| Zone-aware `t.timestamp(...)` | `timestamptz` | `timestamp` - MySQL's own zone-*naive* type is the differently-named `datetime`; the Postgres mapping ported by name would land on that one instead |
| `t.bool(...)` | `boolean` | `tinyint(1)` - no native boolean type; this is the convention MySQL's own client libraries treat as one |
| `t.decimal(...)` | `numeric`, unconstrained | `decimal(38,9)` - no arbitrary-precision decimal type, so a value needing more than 9 fractional or 29 integer digits is silently rounded |
| Identifier quoting | `"double quotes"`, an embedded `"` doubled | `` `backticks` ``, an embedded `` ` `` doubled |
| Indexing an unbounded `text` column | no prefix needed | an explicit key-length prefix is required; this package always renders `(255)` |
| `CREATE INDEX CONCURRENTLY` via `raw()` | detected in the raw text, flagged non-transactional | no equivalent exists; a `raw()` statement is never scanned for it |
| Every statement's `transactional` flag | `true`, except a `raw()` naming `CONCURRENTLY` | always `false` - MySQL DDL auto-commits (see above) |
| The migration runner's advisory lock | `pg_advisory_lock`, taken by `up` | none - `Dialect` has no lock method, so `up` takes no lock at all (see above) |

## When not to use this

`Mysql{}.render` only produces SQL text - it never opens a connection. Do not
run [Migrate](migrate.md)'s `up`/`down` against a MySQL database in
production today: the ledger can record a partially-applied MySQL migration
as successful (#5378), and no lock stops two deploys from racing each other
on MySQL the way `pg_advisory_lock` does on Postgres. Use
`sql(Mysql{}, migrations(), n)` to render a migration's DDL for review, and
apply it by hand, until both gaps close.

## Where to go next

[Dialect](dialect.md) covers `Postgres.render` and the `Dialect` interface
both implementations share. [Schema](schema.md) covers the `table`/`alter`
vocabulary that `Postgres` and `Mysql` both render. [Migrate](migrate.md)
covers the runner these two divergences bear on.
