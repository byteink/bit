# Render a migration to SQL

[Schema](schema.md) builds `people` and `teams` as a tree: `table`, `alter`
and `drop` describe what changed, never SQL text. That tree does not run
anywhere on its own. You need actual `CREATE TABLE` statements to hand to a
real Postgres database, and the exact syntax (`generated always as
identity`, a quoted column name, `CREATE INDEX CONCURRENTLY` outside a
transaction) is the kind of detail that is easy to get right once and wrong
the second time you write it by hand.

A `Dialect` renders the tree for you, once per engine. `Postgres` is
the first one.

## The simplest thing that works

```bit
import { table } from "orm"
import { Postgres } from "orm"

fn createPeopleSql(): string {
  let op = table("people", (t) => {
    t.id("id")
    t.string("name", 100)
  })
  let stmts = Postgres{}.render(op)
  return stmts[0].sql
}
```

`createPeopleSql()` returns:

```
create table "people" (
  "id" bigint generated always as identity primary key,
  "name" varchar(100) not null
);
```

`render` never returns a bare string: it returns `[]Statement`, because one
`SchemaOp` can need more than one SQL statement to apply (the next section
shows why). `stmts[0]` is always the table's own `CREATE TABLE`; here it is
the only one.

## Growing it: a unique column, an index, a foreign key

Continue `people`/`teams` from schema.md:

```bit
import { ReferentialAction, SchemaOp } from "orm"

fn peopleWithConstraintsOp(): SchemaOp {
  return table("people", (t) => {
    t.id("id")
    t.string("email", 255).unique()
    t.int("team_id")
    t.index("team_id")
    t.foreign("team_id").references("teams", "id").onDelete(ReferentialAction.Cascade)
  })
}
```

```bit
fn peopleWithConstraintsSql(): []string {
  let stmts = Postgres{}.render(peopleWithConstraintsOp())
  let out = []string(0)
  for s of stmts {
    out = append(out, s.sql)
  }
  return out
}
```

This renders two statements: the `CREATE TABLE` (with the column, the
`not null unique` on email, and a `constraint ... foreign key ... on delete
cascade` clause naming `teams`), then a separate `CREATE INDEX
"people_team_id_idx" on "people" ("team_id");` for the `t.index("team_id")`
call. A dialect renders one `t.index()` per `CREATE INDEX`, not folded into
the table statement, because the next section needs some indexes to run
outside a transaction and others not to.

## The real case: a statement you cannot run inside a transaction

`t.raw(...)` is schema.bit's escape hatch for anything the builder does not
express, including `CREATE INDEX CONCURRENTLY` - and Postgres refuses to
run `CONCURRENTLY` inside a transaction at all. A migration runner that
wraps every statement in one transaction would fail at run time on exactly
this statement, so `Statement` carries a flag that tells the runner which
ones to pull out:

```bit
import { alter } from "orm"

fn addConcurrentIndexOp(): SchemaOp {
  return alter("people", (t) => {
    t.raw("CREATE INDEX CONCURRENTLY people_email_lower_idx ON people (lower(email))")
  })
}

fn concurrentStatementIsFlagged(): bool {
  let stmts = Postgres{}.render(addConcurrentIndexOp())
  return !stmts[0].transactional
}
```

`concurrentStatementIsFlagged()` returns `true`. Every other statement this
package renders - `CREATE TABLE`, `ALTER TABLE`, `DROP TABLE`, a plain
`t.index()` - is `transactional: true`; only a `raw()` whose text names
`CONCURRENTLY` is not.

## Writing dialect-agnostic code

Nothing above needed to know it was talking to `Postgres` specifically -
every call went through `render`, the one method `Dialect` declares. Code
that applies a migration can take the interface instead of a concrete
dialect, so it keeps working once a second one (MySQL) exists:

```bit
import { Dialect, Statement } from "orm"

fn renderAll(dialect: Dialect, ops: []SchemaOp): []Statement {
  let all = []Statement(0)
  for op of ops {
    for s of dialect.render(op) {
      all = append(all, s)
    }
  }
  return all
}
```

Calling `renderAll(Postgres{}, [peopleWithConstraintsOp()])` renders the
same two statements the earlier example did; nothing here changes when a
second `Dialect` is added.

`pkg/orm/write.bit`'s `upsert` also takes a "which database" parameter,
`UpsertDialect` - a plain two-value tag for `ON CONFLICT` vs `ON DUPLICATE
KEY UPDATE` syntax, not this interface. See [Write](write.md) and
[`pkg/orm/README.md`](../README.md#dialect-vs-upsertdialect) for why the
two stay separate types.

## Sharp edges

**Every identifier is quoted and escaped, always** - table names, column
names, the index and foreign-key constraint names the renderer generates
itself. `table("people", ...)`/`alter("people", ...)` take a plain string
from whoever wrote the migration, not necessarily one that went through
[naming.md](naming.md)'s snake_case conversion (that only runs for a
`@table` class's reflected descriptor, a different code path). Postgres'
own identifier-quoting rule - double the identifier, double any embedded
`"` - closes that off regardless of what the string contains.

**`t.raw(...)` is the one place that guarantee is suspended, on purpose.**
Its text is passed to SQL exactly as written, unquoted and unescaped -
schema.bit's own design for the escape hatch. Writing a migration's own
raw SQL is still the migration author's job to get right; the dialect does
not parse or check it.

**A foreign key with no `.references(...)` panics when you render it, not
when you build it:**

```bit
fn brokenForeignKeyOp(): SchemaOp {
  return table("orders", (t) => {
    t.foreign("customer_id")
  })
}
```

`Postgres{}.render(brokenForeignKeyOp())` panics naming the column and the
table. schema.bit's own builder leaves an unfinished `t.foreign(...)` as a
structurally incomplete node on purpose (see schema.md's own "Sharp
edges"); the dialect is where a migration that forgot `.references(...)`
is finally caught.

**Postgres only renders the six column types schema.bit's `ColumnType`
carries** - `Id`, `Int` (always `bigint`, since Bit's `int` is Bit's only
ordinary integer size), `String(length)` (`varchar(length)`), `Text`,
`Bool` and `Timestamp` (always `timestamptz`, never a bare `timestamp` -
an instant read from a zoneless column is invented). There is no `f64`,
`decimal`, `[]byte` or `Option<T>` column yet, because the intent tree
does not carry one; that is schema.bit's surface to grow, not this file's.

## When not to use this

`render` only produces SQL text - it does not open a connection or run
anything. There is no runner yet to apply a `Statement` list to a real
database or track which migrations already ran; that is separate, later
work. Use this package today to see the exact DDL a migration will emit;
do not expect `migrate up`.

## Where to go next

[Schema](schema.md) is where `SchemaOp` and its builders (`table`, `alter`,
`drop`) come from. [Naming](naming.md) covers how a `@table` class's field
names become the identifiers this page quotes. [Data](data.md) and
[Write](write.md) cover running queries and writes once a table exists.
