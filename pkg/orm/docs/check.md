# Fail CI when entities and the live schema disagree

Someone adds a `phone` field to `Widget`, ships the code, and forgets to run
[Generate](generate.md). Nothing catches it - the tests pass locally
because the developer's own database happens to be in sync. The first
request against production that touches `phone` fails, because the column
was never there. `generate` closes the gap between "the entity changed" and
"there is a migration to review" - but nothing stops a deploy that skipped
that step entirely. `check` is that stop: it runs the identical diff
`generate` runs, and instead of writing a file, it fails loudly the moment
the entities and the live schema disagree.

## The simplest thing that works

```bit
import { Data, ServerDialect, TableEntity, check } from "orm"
import { AttrDesc, FieldDesc } from "std/sql"

@table("widgets") class Widget {
  @id
  id: i64
  name: string
  phone: string
  @enumVariants("Draft", "Active", "Archived", "Retired")
  status: string
}

fn verifySchema(db: Data): ()! {
  return check(db, [Widget{}], ServerDialect.Postgres)?
}
```

`Widget{}` needs no `implements TableEntity` clause, the same structural
fit [Generate](generate.md) already relies on - `@table` synthesizes
exactly the two members `TableEntity` asks for. `ServerDialect.Postgres`
is the same explicit "which server" argument `generate` takes, for the
same reason: `check` never asks the live connection what it is.

If the live `widgets` table has every column `Widget` declares, with a
matching type and a CHECK listing the same four status variants,
`verifySchema(db)` returns with nothing to report. If `phone` was never
added, it fails instead:

```text
pkg/orm: check: entities and the live schema disagree:
widgets.phone: in entity, not in database
```

Run `verifySchema` as a step in CI against a scratch database with the
committed migrations applied, and a deploy that forgot to run `generate`
turns into a red build instead of a production incident.

## Growing it: every kind of disagreement it catches

`check` is not only "a column is missing." Four different disagreements
each get their own line, never a full schema dump:

```bit
@table("orders") class Order {
  @id
  id: i64
  widgetId: i64
  quantity: i64
}

fn verifyBoth(db: Data): ()! {
  return check(db, [Widget{}, Order{}], ServerDialect.Postgres)?
}
```

Say `orders.quantity` was hand-altered on the live database to a `text`
column, and someone also renamed `widgets.legacy_sku` away in the entity
without ever dropping the column live. `verifyBoth(db)` reports both, one
line each:

```text
pkg/orm: check: entities and the live schema disagree:
orders.quantity: type mismatch, entity declares 'i64', database has 'character varying'
widgets.legacy_sku: in database, not in entity
```

Every difference names the table, the column and the direction -
"in entity, not in database", "in database, not in entity", or "type
mismatch" naming both sides - because the whole value of this output is
that someone reads it at 2am and knows immediately what to fix, not that
it dumped two schemas for them to diff by eye.

## The disagreement generate.bit's own presence diff cannot see

An enum's variant list can drift with the column staying present, same
name, same type - [Generate](generate.md)'s own "An enum's variant list
drifts too" section walks through why: the live CHECK constraint still
lists the old three variants while `Widget` above declares four, and a
diff that only checks column presence and type sees nothing wrong at all.
`check` runs the identical `enumVariantsChanged` comparison `generate`
does, so the same drift that would emit a migration also fails the gate:

```text
pkg/orm: check: entities and the live schema disagree:
widgets.status: enum variants differ, entity declares [Draft, Active, Archived, Retired], database has [Draft, Active, Archived]
```

**Reordering the same variants never trips this** - the comparison is a
set, not a sequence, so resorting `Widget`'s own declaration for
readability changes nothing `check` reports.

## The sharp edge: never applies, only reports

```bit ignore
fn wrong(db: Data): ()! {
  check(db, [Widget{}], ServerDialect.Postgres)?
  // nothing to "fix it" from here - check never writes a file or
  // issues a statement beyond the read-only queries the diff needs
}
```

`check` issues exactly the `information_schema` queries the diff needs and
nothing else - no `db.exec` call exists in this file. When it fails, the
fix is the same one a forgotten `generate` step always needed: run
[Generate](generate.md), review the file it writes, and apply it with
[Migrate](migrate.md). `check` only ever tells you that step is missing;
it never takes it for you.

## When not to use this

`check` does not cover a `@manyToMany` join table's own existence -
[Generate](generate.md)'s `manyToManyDescsFor` diffs that separately, and
today `check` only compares an entity's own columns, their types and an
enum column's CHECK. Run it as a CI gate against a scratch database first;
wiring it into application start behind a config flag, so a deploy that
slipped through still fails fast at boot, is worth adding once CI is
already covered - never the only place it runs.

## Where to go next

[Generate](generate.md) covers turning the identical diff into a reviewed
migration file instead of a pass/fail. [Migrate](migrate.md) covers
applying that file. [Enum columns](enum.md) covers `@enumVariants`'s own
column shape and why reordering is always free.
