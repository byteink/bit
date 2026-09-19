# Sync the dev database to your entities

You add a `phone` field to `Widget`, save the file, and run your app
locally. With [Generate](generate.md) alone, that means stopping, running
`generate`, reading the migration it writes, and applying it with
[Migrate](migrate.md) - three steps for a column you might rename again in
five minutes. That review step exists to protect a database you cannot
casually blow away. Your local database is not that database. `syncSchema`
is the TypeORM `synchronize: true` experience for exactly that case: it
diffs your entities against the live schema and applies the difference
immediately, no file, no review, no prompt.

## The simplest thing that works

```bit
import { Data, Postgres, RunnerDialect, ServerDialect, TableEntity, syncSchema } from "orm"
import { AttrDesc, FieldDesc } from "std/sql"

@table("widgets") class Widget {
  @id
  id: i64
  name: string
}

fn devSync(db: Data): ()! {
  return syncSchema(
    db,
    [Widget{}],
    RunnerDialect{ render = Postgres{}, server = ServerDialect.Postgres },
  )?
}
```

`Widget{}` needs no `implements TableEntity` clause - the same structural
fit [Check](check.md) and [Generate](generate.md) already rely on.
`RunnerDialect` is not a new shape: it is the identical bundle
[Migrate](migrate.md)'s `up`/`down` already take, `render` picking the DDL
renderer and `server` picking the enum-CHECK keyword.

If `widgets` does not exist yet, `devSync(db)` creates it. Add a `phone`
field and call it again - the live table gains a `phone` column, no
migration file involved. Remove a field instead, and the live column is
dropped, not just reported: this is a scratch database, and "drops
included" is the whole point of skipping the review step.

## Growing it: an enum change applies too

An enum's variant list can change without the column itself changing name
or type - [Generate](generate.md)'s own "An enum's variant list drifts too"
section is the reference for why a plain presence diff cannot see this.
`syncSchema` runs through the identical comparison and applies the
drop-and-recreate directly:

```bit
@table("widgets") class WidgetWithStatus {
  @id
  id: i64
  name: string
  @enumVariants("Draft", "Active", "Archived", "Retired")
  status: string
}

fn devSyncStatus(db: Data): ()! {
  return syncSchema(
    db,
    [WidgetWithStatus{}],
    RunnerDialect{ render = Postgres{}, server = ServerDialect.Postgres },
  )?
}
```

The first call against a live `widgets.status` CHECK still listing three
variants drops that constraint and recreates it naming all four - the same
statement [Generate](generate.md) would have written into a file, applied
instead of printed.

## The fence: a database with any migration history is refused

```text
pkg/orm: sync: refusing - schema_history has 3 row(s); this database is
under migration control and applying a computed diff on top of a reviewed
history would make it a lie. Use 'generate' (#5067) to write a migration
and 'up' (#5068) to apply it instead
```

Before touching a single table, `syncSchema` checks whether `schema_history`
- [Migrate](migrate.md)'s own ledger - carries any row. If it does, this
database was built by applying reviewed migrations in order, and `syncSchema`
refuses outright rather than rewriting that history silently. A database
with no `schema_history` table at all, or one that exists with zero rows,
is treated as scratch and synced normally.

This is a structural fact, not a setting. TypeORM's own guard is a
configuration flag wired to an environment variable, which is exactly why
"never enable `synchronize` in production" is advice people routinely
forget to follow. `syncSchema` reads no environment variable, hostname or
connection string to decide - only whether `schema_history` has rows, which
is true if and only if this database has ever run a real migration. Two
databases that are byte-identical except for that one fact get different
answers; nothing else about the connection matters.

## The sharp edge: it is `syncSchema`, not `sync`

[Many-to-many](manytomany.md) already exports `sync` for making a join
table's rows match a given set (`sync(db, desc, ownerId, targetIds,
dialect)`). This package is one flat module, so a second top-level `sync`
would collide with it - this function is named `syncSchema` to stay out of
that function's way, not because the two are related.

## When not to use this

`syncSchema` never drops a whole table - an entity you stop passing is
simply never inspected, the same rule [Generate](generate.md) follows for
why an entity table's removal is always a hand-written decision. It does
not create or manage a `@manyToMany` join table either; that stays
[Generate](generate.md)'s and [Migrate](migrate.md)'s job. And it never
runs against anything with migration history - that boundary is not
configurable, by design. Use [Generate](generate.md) then
[Migrate](migrate.md) for any database you cannot casually recreate.

## Where to go next

[Check](check.md) covers reporting the same disagreement in CI without
applying it. [Generate](generate.md) covers turning it into a reviewed
migration file. [Migrate](migrate.md) covers applying that file to a
database under history, the one `syncSchema` refuses to touch.
