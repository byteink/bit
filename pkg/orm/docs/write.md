# Write

"If I have an `Article`, whether I just built it or it came back from a
query, saving it should just work" - that's the whole shape of this page.
`save` for either, `insert` for a new row, `update` for one you already
have, and no manual row mapper or `map<string, Value>` in between.

## Insert and update

```bit
import { Db, open } from "orm"

@table class Article {
  id: i64,
  title: string,
  body: string,
  authorId: i64,
}

fn publish(db: Db, authorId: i64, title: string, body: string): Article! {
  return db.table<Article>().insert(
    Article{ id = 0, title = title, body = body, authorId = authorId },
  )?
}

fn rename(db: Db, article: Article, newTitle: string): Article! {
  article.title = newTitle
  db.table<Article>().update(article)?
  return article
}
```

`insert` returns the row the database actually wrote, `id` filled in - the
value you passed for `id` is never sent; `@table` excludes the primary key
from the `INSERT` column list and reads it back from what the database
generated. On PostgreSQL that is one statement, `INSERT ... RETURNING *`.
MySQL has no `RETURNING`, so there `insert` (and `insertAll`) run the
`INSERT`, ask the same connection for `LAST_INSERT_ID()`, and `SELECT` the
rows back by those ids, all inside one transaction; what you get back is the
row as MySQL stored it, defaults and triggers included, exactly as on
PostgreSQL. The `@id` column must be `AUTO_INCREMENT` there (`t.id()` makes
it so), or the insert fails naming that. `update` takes the whole row and writes every column back by
its primary key; there is no separate "patch just this field" call - build
the value you want, then `update` it.

## Save: insert or update, whichever the row needs

```bit
fn saveDraft(db: Db, article: Article): Article! {
  return db.table<Article>().save(article)?
}
```

`save` is for the code that holds an `Article` and does not care whether it
is new. When `id` is `0` (nothing has assigned one yet) it is an `insert`
and returns the row the database wrote, `id` filled in. Any other `id` and it
is an `update`, and you get back the `article` you passed. A composite key
(more than one `@id` field) counts as set only when every part is non-zero.

It costs exactly one statement either way - no `select` first to find out
whether the row exists - and the errors are `insert`'s and `update`'s own: a
non-zero `id` whose row is gone fails the same way `update` does (see
"The sharp edge" below). Inside `db.tx`, `tx.table<Article>().save(article)?`
does the same on the transaction's connection.

## Deleting

```bit
fn unpublish(db: Db, id: i64): ()! {
  db.table<Article>().delete(id)?
}
```

`delete` takes the id, not the row. On a plain `@table` class this is a
real `DELETE`; add `@softDelete` and it hides the row instead, without
changing a single call site - see [Soft delete](softdelete.md).

## The sharp edge: an UPDATE matching no row is an error

```bit
fn renameSafely(db: Db, article: Article, newTitle: string): Article! {
  article.title = newTitle
  db.table<Article>().update(article) catch e {
    fail newError("could not rename: ${e.message()}")
  }
  return article
}
```

If another request already deleted `article`'s row, the `UPDATE` matches
zero rows, and `update` treats that as failure rather than a silent no-op -
your process was holding a row that no longer exists, and without this
error the rename would simply, invisibly, not happen.

## Bulk writes: many rows in one round trip

```bit
fn publishAll(db: Db, drafts: []Article): []Article! {
  return db.table<Article>().insertAll(drafts)?
}

fn renameDraftsBy(db: Db, authorId: i64, prefix: string): int! {
  return db.table<Article>().where("authorId", authorId).set("title", prefix).updateAll()?
}

fn deleteDraftsBy(db: Db, authorId: i64): int! {
  return db.table<Article>().where("authorId", authorId).deleteAll()?
}
```

`insertAll` inserts every row in `drafts` and hands back the same rows with
their generated ids filled in, the same way `insert` does for one.
`updateAll`/`deleteAll` run one `UPDATE`/`DELETE` over every row the chain
in front of them matches - `where(...)` narrows which rows, `set(column,
value)` (repeatable, one call per column) says what `updateAll` writes, and
both return the number of rows affected. Neither loads a row into memory
first: an unfiltered `db.table<Article>().deleteAll()` matches, and
deletes, the whole table - `where` is what keeps a bulk write scoped to the
rows you mean.

## A `@version` column catches a lost update without locking anything

Two editors load the same article, both change different fields, and both
save a few seconds apart - the second `update` silently overwrites the
first editor's change, because neither one knew the other existed. Add
`@version`, and the second save fails instead:

```bit
@table class Draft {
  id: i64
  title: string
  @version
  version: i64
}

fn editDraft(db: Db, draft: Draft, newTitle: string): ()! {
  draft.title = newTitle
  db.table<Draft>().update(draft)?
}
```

Every `update` on a `@version` class adds `and version = <the value you
read>` to the `WHERE` and bumps the column by one. If someone else already
saved (and so already bumped the version), that `WHERE` matches zero rows,
and `update` fails with a `StaleWriteError` instead of the generic
zero-rows error above - carrying `oldVersion` (the version you read) and
`newVersion` (the version you tried to write, `oldVersion + 1`), so the
caller can tell "someone deleted this row" and "someone edited it since I
read it" apart:

```bit
import { StaleWriteError } from "orm"

fn editSafely(db: Db, draft: Draft, newTitle: string): ()! {
  draft.title = newTitle
  db.table<Draft>().update(draft) catch e {
    let (stale, ok) = e.(StaleWriteError)
    if (ok) {
      fail newError("this article changed since you loaded it (had version ${stale.oldVersion})")
    }
    fail e
  }
}
```

No transaction, no row lock held while an editor is thinking - `@version`
only checks at the moment of the write. When the wait itself needs to be
correct instead (a queue worker claiming a row, a balance transfer), reach
for [Locking](locking.md) instead.

## Where to go next

[Query](query.md) covers reading rows back with `find`/`where`/`all`.
[Relations](relation.md) covers `link`/`unlink` for many-to-many columns.
[Soft delete](softdelete.md) covers `@softDelete`, `withDeleted`, `restore`
and `forceDelete`. [Locking](locking.md) covers `tx.table<T>().lock()` for
a row you're about to change inside a transaction.
