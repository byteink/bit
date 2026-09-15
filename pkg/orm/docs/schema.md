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
    t.id("id")
    t.string("name", 100)
  })
}
```

`t.id("id")` is an auto-incrementing primary key; the exact mechanism
(`BIGSERIAL`, `IDENTITY`, `AUTO_INCREMENT`) is a dialect's to pick, not
this package's. `op` is a `SchemaOp` - read it back with `match`:

```bit
fn describe() {
  let op = table("people", (t) => {
    t.id("id")
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

## Growing the table: a unique column, an index, a foreign key

`t.string(name, length)` returns the `Column` it just added, so a call
chained onto it - `.unique()`, `.nullable()` - mutates that same column,
not a copy:

```bit
import { ReferentialAction } from "orm"

fn peopleWithConstraints() {
  table("people", (t) => {
    t.id("id")
    t.string("email", 255).unique()
    t.decimal("salary").nullable()
    t.timestamp("joined_at").nullable()
    t.index("joined_at")
    t.foreign("team_id").references("teams", "id").onDelete(ReferentialAction.Cascade)
  })
}
```

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
[Version](version.md)'s `Account`) had no column type to give it. On
Postgres, `Dialect` renders it as bare `numeric` - no precision, no scale.
A hand-picked `numeric(38,9)` would silently round away any value needing
more digits than that after the decimal point, which is exactly the kind
of silent money error a `decimal` type exists to rule out; unconstrained
`numeric` is the only mapping that cannot truncate a legal value.

`AlterTable` carries the same column: adding `salary` to a table that
already exists is `addDecimal`, chainable like every other `addX`:

```bit
import { alter } from "orm"

fn addSalaryToPeople() {
  alter("people", (t) => {
    t.addDecimal("salary").nullable()
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
    t.addString("phone", 20).nullable()
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

## The escape hatch

No builder here expresses a partial index, a trigger, a `CHECK`
constraint, or `CREATE INDEX CONCURRENTLY`. `t.raw(...)` - on both `table`'s
and `alter`'s builder - passes a statement through untouched, per dialect:

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

**`string`/`addString` always take a length**, with no default -
`t.addString("phone")` does not compile:

```
error[E0050]: expected 2 argument(s), found 1
```

A defaulted trailing parameter (`length: int = 255`) works on an ordinary
function but is rejected at the call site on a class method today, even
though the same signature checks on the method declaration itself. Write
the length: `t.addString("phone", 20)`.

**A foreign key with no `.references(...)` is silent, not rejected.**
`t.foreign("team_id")` alone produces a `ForeignKey` node whose `refTable`
and `refColumn` are both `""`. This package checks structure, never SQL
semantics - the dialect that eventually renders the tree is where a
missing target would surface, not here.

## What this package does not do yet

This chapter builds and reads a tree; turning that tree into SQL is
[Dialect](dialect.md)'s job, not this file's. Postgres is the first
renderer; MySQL is separate, later work. There is still no runner to apply
a rendered statement to a database. Use this package today to see the
exact shape a migration will carry and, once you add a dialect, the exact
DDL it renders to; do not expect `migrate up` yet.

## Where to go next

[Dialect](dialect.md) turns the tree this chapter builds into real
Postgres DDL. [Naming](naming.md) covers how a `@table` class's field
names become the table and column names you write here by hand.
[Data](data.md) covers the interface an ORM function takes to actually run
something against a database, once there is something here to run.
