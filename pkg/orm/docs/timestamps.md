# Timestamps

Almost every table ends up with a `createdAt` and an `updatedAt` column, and
almost every app re-implements them slightly differently: one forgets to
update `updatedAt` on a bulk job, another lets an `UPDATE` accidentally
overwrite `createdAt` because it writes every column. `@timestamps` does the
whole thing once: `createdAt` is set on insert and never touched again;
`updatedAt` is set on insert and every update, single or bulk.

## Marking the table

Add `@timestamps` alongside `@table`, and declare the two columns it fills:

```bit
import { Db, open } from "orm"

@table @timestamps class Article {
  id: i64,
  authorId: i64,
  title: string,
  createdAt: i64,
  updatedAt: i64,
}

fn publish(db: Db, authorId: i64, title: string): Article! {
  return db.table<Article>().insert(
    Article{ id = 0, authorId = authorId, title = title, createdAt = 0, updatedAt = 0 },
  )?
}
```

`publish` never sets `createdAt`/`updatedAt` itself - `insert` fills both
from the same clock reading, so a freshly inserted row's two columns come
out byte-identical. The zero values you pass for them in the composite
literal are never sent to the database; they exist only because Bit
composite literals require every field.

## Why an update never touches `createdAt`

```bit
fn rename(db: Db, article: Article, newTitle: string): ()! {
  article.title = newTitle
  db.table<Article>().update(article)?
}
```

[Write](write.md) documents that `update` writes every column back by
primary key - there is no per-column exclusion of its own, except this one:
`@timestamps` drops `createdAt` from that statement specifically, so
rewriting it on every update - which would destroy the row's real age -
never happens. `rename`'s `update(article)` still sets `updatedAt` to a
fresh reading, even though `article.title` is the only field the caller
actually changed.

## Bulk updates bump `updatedAt` too

```bit
fn renameDraftsBy(db: Db, authorId: i64, prefix: string): int! {
  return db.table<Article>().where("authorId", authorId).set("title", prefix).updateAll()?
}
```

`updateAll` adds its own `updatedAt = <now>` to the `SET` list automatically
on a `@timestamps` class - you never write `.set("updatedAt", ...)`
yourself. `deleteAll` never calls it: a `DELETE` (or, on a `@softDelete`
class, the `UPDATE` that stands in for one) has no `SET` list of ordinary
columns to add one to.

## The sharp edge: a `@timestamps` class missing either column

`@timestamps` requires both `createdAt` and `updatedAt` to exist as real
fields. A class that carries the mark without one is rejected at the first
write, naming the missing field:

```bit ignore
@table @timestamps class Draft {
  id: i64,
  title: string,
  createdAt: i64,
}
```

```text
pkg/orm: the class mapped to 'draft' carries '@timestamps' but declares no 'updatedAt' field
```

This is a caught error, not a panic - it reaches your code through the
ordinary `?` on `insert`/`update`/`updateAll`, the same shape every other
failure on this page already is, so a caller can report which field is
missing rather than crash outright.

## When not to use this

If a table's `createdAt`/`updatedAt` follow a different rule than "set once,
touch on every write" - a soft-deleted row that should stop updating, or a
column driven by a database trigger instead of the application - write the
value into the composite literal yourself, the way you would for any other
column, and skip `@timestamps` for that class.

## Where to go next

[Write](write.md) covers `insert`/`update`, the two calls `@timestamps`
extends. [Soft delete](softdelete.md) covers `@softDelete`, the other
class-level mark that changes what `delete` does without changing any call
site.
