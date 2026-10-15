# Keep deleted articles recoverable

<!-- doctest: per-block -->
<!-- doctest: deps orm postgres -->

An author deletes the wrong article. If the row is gone, recovering it needs
a backup. Inkwell instead marks the row as deleted and hides it from ordinary
reads, so the database still has the article.

## Delete through the existing route

Start the [finished app](README.md#run-the-finished-app) with its migrations
applied. Use a real article id and the session cookie of its author or an
admin. The route returns `204` after it marks the row:

```text
curl -i -X DELETE http://127.0.0.1:8080/articles/42 \
  -H 'Cookie: sid=YOUR_SESSION_COOKIE'
```

That article disappears from `GET /articles`, `GET /articles/42` and
[full-text search](28-full-text-search.md). Deleting it again returns `404`
because the handler's initial lookup no longer sees it.

## Store a nullable deletion time

This complete migration from
[`AddArticleDeletedAtAndVersion`](inkwell/migrations/2026_01_02_000001_add_article_deleted_at_and_version.bit)
adds both the deletion time and the version used in the next chapter:

```bit
import { Schema } from "orm"

export class AddArticleDeletedAtAndVersion {
  up(s: Schema): ()! {
    s.table("articles", (t) => {
      t.int("deleted_at").nullable()
      t.int("version")
    })?
  }

  down(s: Schema): ()! {
    s.table("articles", (t) => {
      t.dropColumn("deleted_at")
      t.dropColumn("version")
    })?
  }
}
```

`deleted_at` holds epoch nanoseconds, the same convention as Inkwell's
`created_at` and `updated_at`. It is a nullable integer column, not a native
PostgreSQL timestamp. Null means the article is visible.

The migration adds `version` without a default. The course applies it to an
empty articles table. On an existing populated database, plan a backfill
before adding that required column.

## Mark the model, keep the handler

The complete `Article` declaration in
[`articles.bit`](inkwell/articles.bit) carries `@softDelete` and declares
`deletedAt: Option<i64>`. This excerpt shows those declarations in their
surrounding model; its related classes live in the app:

```text
@table("articles") @timestamps @softDelete class Article {
  id: i64
  title: string
  slug: string
  body: string
  authorId: i64
  @belongsTo("authorId")
  author: User
  @manyToMany("article_tags")
  tags: []Tag
  createdAt: i64
  updatedAt: i64
  deletedAt: Option<i64>
  @version
  version: i64
}
```

The mark changes repository behavior. `delete(id)` writes the deletion time;
normal repository reads, including `find`, `first`, `all` and `count`, exclude
marked rows. A class with `@softDelete` but no `deletedAt` field fails with
an error naming the missing field.

The complete route handler stays small. This excerpt from the app uses its
existing authorization and lookup helpers:

```text
fn deleteArticle(c: Ctx, db: Db): Res! {
  let id = parseId(c.param("id")) catch _ {
    fail badRequest("id must be an integer")
  }
  let existing = findArticleById(db, id) catch _ {
    fail notFound("no article with that id")
  }
  requireOwnerOrAdmin(c, existing.authorId)?
  db.table<Article>().delete(id)?
  return c.noContent()
}
```

Ownership still matters. The handler loads the visible article, checks the
signed-in user, and only then marks the row. A missing row becomes `404`.
A caller who owns neither the article nor an admin role is refused.

The mark does not rewrite arbitrary SQL. Inkwell's raw search query has its
own `deleted_at is null` condition. Any new raw read needs the same decision
about whether it may expose deleted articles.

## Prove that the row survives

The test named `a soft-deleted article is excluded from listing but the row survives in the database`
in [`app.test.bit`](inkwell/app.test.bit) checks both sides: the HTTP list
hides the title, and a direct PostgreSQL query finds the row with a non-null
`deleted_at`. It does not treat a successful DELETE response as proof that
the database kept the article.

You can inspect your own deleted row with the same query. Bind `$1` to its
id through your database client:

```text
select deleted_at from articles where id = $1
```

Run the app tests against the migrated PostgreSQL database from
[Testing the API](16-testing-the-api.md):

```text
bit test pkg/web/guides/inkwell
```

## Recovery and permanent removal

The ORM provides `withDeleted()` to include hidden rows, `restore(id)` to
clear the deletion time, and `forceDelete(id)` to remove the row permanently.
See [Soft deletes](../../orm/docs/softdelete.md) for those operations.
Inkwell does not expose a trash list, restore route or permanent-delete route.
Adding one requires its own authorization policy.

A soft delete does not run a database `ON DELETE` action: it updates the
article row. Related rows remain, and unique constraints still see the
article's slug. This chapter does not add a cascade policy for related
comments or tags.

## When to choose another policy

Soft deletion helps with accidental removal. It is not data erasure, an
audit history, or a backup. Deleted rows still hold their original contents
and continue to use storage. Choose explicit retention and permanent-removal
rules when the data must actually leave the database.

Previous: [Find articles by their words](28-full-text-search.md).
Next: [Refuse an edit based on an old article](30-optimistic-locking.md).
