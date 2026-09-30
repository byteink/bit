# Keep your database in step with your entities automatically

You add a `phone` field to `Widget`, save the file, and run your app. With
[Migrate](migrate.md) alone, that means stopping, hand-writing a migration
file, and applying it - two steps for a column you might rename again in
five minutes while you're still shaping the schema. `open`'s own
`synchronize` option is the TypeORM `synchronize: true` experience: on
every connect, it looks at every `@table` class in your project and adds
whatever the live database is missing, with no file, no review and no
prompt.

## The simplest thing that works

```bit
import { Db, open, Options } from "orm"

@table("widgets") class Widget {
  @id
  id: i64
  name: string
}

fn main(): ()! {
  let db = open("postgres://localhost/inkwell", Options{ synchronize = true })?
  let widgets = db.table<Widget>()
  widgets.insert(Widget{ id = 0, name = "First" })?
}
```

If `widgets` does not exist yet, this `open` call creates it before
returning `db` - there is nothing to run first. `Widget` needs no
migration file for this to work.

## Growing it: add a field, reopen, done

```bit ignore
@table("widgets") class Widget {
  @id
  id: i64
  name: string
  phone: string
}
```

Add `phone` to the class and restart your app. The next `open(url,
Options{ synchronize = true })` call sees the live `widgets` table is
missing `phone` and adds the column before your code runs a single query -
still no migration file.

## The real use case: connect once, at startup

A typical app calls `open` exactly once, where it builds every other
service:

```bit
fn startApp(url: string): Db! {
  return open(url, Options{ synchronize = true })?
}
```

Every table any `@table` class in your project declares gets checked on
that one call - you never list your own entities, the way you would for
[Check](check.md).

## The sharp edge: it only ever adds

`synchronize` never drops a column and never renames one - there is no way
to tell a rename from a delete-and-create by looking at the two schemas
alone, and guessing would destroy the dropped column's data. Remove
`phone` from `Widget` and reopen, and the live `phone` column stays
exactly where it is; you get one line on stderr instead:

```text
pkg/orm: sync: "widgets"."phone" has no matching field on the @table class; kept, not dropped
```

It never drops a whole table either: stop declaring an entity, and its
table is simply never inspected. And it is safe to run against a database
that already has migrations applied through [Migrate](migrate.md) - adding
a missing table or column on top of reviewed history is safe precisely
because this option never removes anything to get there.

## When not to use this

`synchronize` is the owner's own call to make for any environment,
production included - there is no dev-only guard to lean on here. Reach
for [Migrate](migrate.md) instead when you need a real drop, a rename, a
data backfill, or a `@manyToMany` join table: none of those are something
`synchronize` will ever do for you, on purpose.

## Where to go next

[Migrate](migrate.md) covers writing and applying a hand-written migration
for the changes `synchronize` will not make. [Check](check.md) covers
reporting the same kind of disagreement in CI without applying anything.
