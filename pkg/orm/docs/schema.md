# Schema

A migration has to run against whatever database the team actually uses -
Postgres in production, maybe MySQL in a teammate's local setup - and
hand-writing two sets of `CREATE TABLE` statements means every change
happens twice, and the two copies drift the first time someone forgets one
of them. `table`, `alter` and `drop` describe what you want structurally,
once. The result is never SQL text: it is a tree a dialect renders into
each engine's own DDL, so one migration file targets both.

## Declare a table

```bit
import { table } from "orm"

fn peopleTable() {
  let op = table("people", (t) => {
    t.id()
    t.string("name", 100)
  })
}
```

`t.id()` is an auto-incrementing primary key, defaulting its own column
name to `"id"` (`t.id("id")` names it explicitly, the same column either
way) - the exact mechanism (`BIGSERIAL`, `IDENTITY`, `AUTO_INCREMENT`) is
a dialect's to pick, not this package's. `op` is a `SchemaOp` - read it
back with `match`:

```bit
fn describe() {
  let op = table("people", (t) => {
    t.id()
    t.string("name", 100)
  })
  match (op) {
    CreateTable(created) => println("${created.name}: ${len(created.columns)} columns")
    _ => println("not a create")
  }
}
```

This prints `people: 2 columns`. A dialect (not in this package - see
"What this package does not do yet", below) will do the same kind of
reading to produce DDL.

## Inside a migration: `Schema`

You rarely call `table`/`alter`/`drop` directly the way the two examples
above do. A [migration](migrate.md)'s `up`/`down` methods each take a
`Schema` instead, and call its `create`/`table`/`drop` methods - Laravel's
own `Schema::create`/`Schema::table`/`Schema::drop` names. Each one wraps
exactly the free function above and collects the result, so the tree it
builds is identical either way:

```bit
import { Schema } from "orm"

export class CreatePeople {
  up(s: Schema): ()! {
    s.create("people", (t) => {
      t.id()
      t.string("name", 100)
    })?
  }

  down(s: Schema): ()! {
    s.drop("people")?
  }
}
```

`s.create` is `Schema.create` calling `table(...)` above and appending the
result to `s.ops`; `s.table` calls `alter(...)` the same way, for changes
to a table that already exists. The rest of this page keeps using the free
functions directly, since that is the shortest way to show the tree each
one builds - inside a real migration file, reach for `s.create`/`s.table`/
`s.drop` instead.

## Growing the table: a unique column, an index, a foreign key

`t.string(name, length)` returns the `Column` it just added, so a call
chained onto it - `.unique()`, `.nullable()` - mutates that same column,
not a copy. `length` defaults to 255, so `t.string("email")` and
`t.string("email", 255)` declare the identical column:

```bit
import { ReferentialAction } from "orm"

fn peopleWithConstraints() {
  table("people", (t) => {
    t.id()
    t.string("email").unique()
    t.decimal("salary").nullable()
    t.timestamp("joined_at").nullable()
    t.timestamps()
    t.index("joined_at")
    t.foreign("team_id").references("teams", "id").onDelete(ReferentialAction.Cascade)
  })
}
```

`t.timestamps()` above adds `created_at` and `updated_at` in one call,
both nullable - Laravel's own `$table->timestamps()` shape; `joined_at`
stays a separate, explicitly-named column since it means something else.

`t.index` is variadic - `t.index("teamId", "joinedAt")` is one composite
index, not two calls. `ReferentialAction` (`Cascade`, `Restrict`,
`SetNull`, `NoAction`) is engine-neutral on purpose: nothing in this file
may write a dialect's own keyword, so a table declared once targets every
dialect this package ever gets a renderer for.

## Money columns, and what is still missing

`t.decimal(name)` above declares a `salary` column of `ColumnType.Decimal`
- the type this package reaches for whenever a value is money or anything
else that cannot round. Bit's own `decimal` is a first-class 128-bit type,
not `f64` with extra steps, so the schema builder needed a way to declare
one: before this existed, a class documented with a `decimal` field (see
[Write](write.md)'s `Account`) had no column type to give it. On
Postgres, `Dialect` renders it as bare `numeric` - no precision, no scale.
A hand-picked `numeric(38,9)` would silently round away any value needing
more digits than that after the decimal point, which is exactly the kind
of silent money error a `decimal` type exists to rule out; unconstrained
`numeric` is the only mapping that cannot truncate a legal value.

`AlterTable` carries the same column, under the same name `Table` uses -
adding `salary` to a table that already exists is `decimal`, one method
per concept, chainable like every other column method:

```bit
import { alter } from "orm"

fn addSalaryToPeople() {
  alter("people", (t) => {
    t.decimal("salary").nullable()
  })
}
```

Three other types are deliberately absent, weighed and left out rather
than overlooked:

- **A separate `i32` column.** `ColumnType.Int` stays the single integer
  variant on purpose (this file's own header) - a dialect maps it to
  whichever integer type stores 64 bits, and there is no narrower column
  to ask for. Nothing observed in this package needs a smaller integer
  column badly enough to reopen that decision.
- **`[]byte` (a binary blob).** No table in this package, or in anything
  that uses it, has needed one yet. Add it, rendered and tested, the day
  something does; declaring it earlier would be a column nothing exercises.
- **A date with no time.** `t.timestamp` always renders `timestamptz` - a
  bare `timestamp` has no zone, so an instant read from one is invented
  (see [Dialect](dialect.md)). A calendar date with genuinely no time
  component is rarer still and has no caller here today; `t.raw(...)` is
  the escape hatch until one shows up.

`Option<T>` is not a fourth entry on this list - it was never a distinct
`ColumnType` question. Every column already carries nullability as its own
flag: `t.decimal("salary").nullable()` is how an optional decimal is
declared, the identical mechanism `t.timestamp(...).nullable()` already
uses above.

## Changing a table that already exists

`alter` is the same shape, over a different vocabulary - add, drop, rename:

```bit
fn evolvePeople() {
  alter("people", (t) => {
    t.string("phone", 20).nullable()
    t.dropColumn("legacy_flag")
    t.renameColumn("email", "email_address")
  })
}
```

`renameColumn` is its own node, carrying both names together - never a
`dropColumn` node followed by an `addColumn` node. A diff between two
schemas cannot tell a rename from a delete-and-create, and getting that
wrong destroys the column's data on whichever engine runs it; declaring the
rename is the only way to get it right every time.

Dropping a table entirely is `drop("people")`, producing a `DropTable` node
- there is no builder to open first.

## Full-text search, other index methods, and generated columns

`t.index` defaults to a B-tree, the one index every engine has. `.gin()`,
`.gist()`, `.hash()` and `.brin()` ask for a different storage method by
name - engine-neutral in the tree, the same way `ReferentialAction` is
above; a dialect maps the name to its own keyword, or refuses if it has no
equivalent (MySQL has no GiST or BRIN at all - see [Dialect](dialect.md)).
`t.indexExpr` builds an index on an expression instead of a column list,
and `.where(...)` on either kind adds a partial index's own predicate:

```bit
import { toTsvector } from "orm"

fn articlesTable() {
  table("articles", (t) => {
    t.id("id")
    t.string("title", 200)
    t.text("body")
    t.tsvector("search_vector").storedAs(
      toTsvector("english", ["title", "body"], ["A", "B"]),
    )
    t.index("search_vector").gin()
    t.indexExpr("lower(title)")
    t.index("title").where("title is not null")
  })
}
```

`t.tsvector` declares a Postgres `tsvector` column - MySQL has no
comparable type, so a migration naming one refuses on that dialect rather
than picking a lossy substitute. `.storedAs(expr)` turns any column into a
generated one (`GENERATED ALWAYS AS (expr) STORED`), computed from the
row's own other columns and never written directly. `toTsvector` builds the
recommended weighted expression - `setweight(to_tsvector('english',
coalesce(title, '')), 'A') || ...` - from a list of columns and their
weights (`'A'` through `'D'`), so a full-text search migration never hand-
writes that expression itself. Querying the column it builds is an
ordinary `db.query<T>` call - see [Raw SQL and transactions](raw.md).

## The escape hatch

No builder here expresses a trigger or `CREATE INDEX CONCURRENTLY`.
`t.raw(...)` - on both `table`'s and `alter`'s builder - passes a
statement through untouched, per dialect:

```bit
fn addPartialIndex() {
  alter("people", (t) => {
    t.raw("CREATE INDEX CONCURRENTLY people_active_idx ON people (id) WHERE deleted_at IS NULL")
  })
}
```

A builder with no escape hatch is a ceiling, not a convenience - this is
the same reason Laravel keeps `DB::statement` around. `raw` never parses
its argument; the tree carries it exactly as written.

## Sharp edges

**A foreign key with no `.references(...)` is silent, not rejected.**
`t.foreign("team_id")` alone produces a `ForeignKey` node whose `refTable`
is `""` and whose `refColumns` is empty. This package checks structure,
never SQL semantics - the dialect that eventually renders the tree is where
a missing target would surface, not here.

## What this chapter does not do

This chapter only builds and reads a tree; turning that tree into SQL is
[Dialect](dialect.md)'s job, and actually running it against a database,
tracking what already ran, and undoing it is [Apply
migrations](migrate.md)'s.

## Where to go next

[Apply migrations](migrate.md) covers `Schema` inside a real migration
file, and `bit make migration`/`bit migrate` for writing and running one.
[Dialect](dialect.md) turns the tree this chapter builds into real
Postgres or MySQL DDL. [Naming](naming.md) covers how a `@table` class's
field names become the table and column names you write here by hand.
[Write](write.md) covers the interface an ORM function takes to actually run
something against a database, once there is something here to run.
