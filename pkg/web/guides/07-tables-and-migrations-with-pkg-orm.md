# Tables and migrations with pkg/orm

<!-- doctest: deps orm -->

Inkwell can talk to Postgres now (part 6), but the database is empty. You
need tables for users, articles, tags and comments, and you need a safe way
to change those tables later without hand-writing `CREATE TABLE` and
`ALTER TABLE` twice, once for what is running today and once for what a
teammate's checkout has drifted into. `pkg/orm`'s schema builder and
migration runner are how Inkwell does both.

## Install pkg/orm

```text
$ bit add bitlang.org/pkg/orm@v0.1.1
bit add: orm -> bitlang.org/pkg/orm@0.1.1 (945fa57bcecbb5446737669d43fd8eae3b0f7caa)
```

## Describe a table instead of writing SQL

`table(name, build)` builds a tree, not a SQL string. A dialect (Postgres,
for Inkwell) turns that tree into real DDL later, so the same declaration
can target another database with no second copy to keep in sync:

```bit
import { table } from "orm"

fn usersTable() {
  table("users", (t) => {
    t.id("id")
    t.string("username", 60).unique()
    t.string("email", 255).unique()
    t.string("password_hash", 255)
    t.string("role", 20)
    t.int("created_at")
    t.int("updated_at")
  })
}
```

`t.id("id")` is an auto-incrementing primary key. On Postgres that is a
`GENERATED ALWAYS AS IDENTITY` column, chosen by the dialect, not by this
line - the same declaration would ask MySQL for `AUTO_INCREMENT` instead.
`.unique()` chains onto the column it just added, so `username` and `email`
each get their own constraint.

## Wrap it in a migration you can actually run

A bare `table(...)` call only builds a tree in memory. A class implementing
`Migration` - `up`/`down`, each taking a `Schema` - is what turns it into
something you run once, safely, and record having run. `Schema.create`
wraps the identical `table(...)` builder above. `bit make migration
create_users` creates the file for you, named with the current time in
UTC, and you fill in its `up`/`down`:

```text
$ bit make migration create_users
created migrations/2026_01_01_000001_create_users.bit
```

```bit
import { Schema } from "orm"

export class CreateUsers {
  up(s: Schema): ()! {
    s.create("users", (t) => {
      t.id("id")
      t.string("username", 60).unique()
      t.string("email", 255).unique()
      t.string("password_hash", 255)
      t.string("role", 20)
      t.int("created_at")
      t.int("updated_at")
    })?
  }

  down(s: Schema): ()! {
    s.table("users", (t) => {
      t.dropColumn("role")
    })?
  }
}
```

`CreateUsers` needs no `implements Migration` clause - interfaces are
structural, so declaring both methods is enough. `up` describes the change
forward; `down` describes its own reverse, one column at a time, the exact
opposite of whatever columns `up` added.

Bit has no reflection, so nothing here scans `migrations/` itself and
decides what to run - `bit migrate` does that for you, at build time, every
time you run it. Applying `CreateUsers` alone:

```text
$ bit migrate --url postgres://localhost/inkwell
applied 2026_01_01_000001_create_users
```

Run it again and nothing is left pending - `bit migrate` prints nothing,
because `2026_01_01_000001_create_users` is already recorded. You never
write down which file goes with which class, or in what order: the file
name is both, and `bit migrate` sorts `migrations/` by name to get the
order right.

## Add the rest of the schema: articles, tags, comments, and the tags join table

Inkwell needs four more tables, each its own file. `articles` and
`comments` each reference `users` with a foreign key; `tags` is a plain
lookup table; and an article can have many tags while a tag can belong to
many articles, which is a relationship [Relationships](09-relationships.md)
covers in the app layer, but the join table itself belongs here, next to
the rest of the schema:

```text
$ bit make migration create_articles
created migrations/2026_01_01_000002_create_articles.bit
$ bit make migration create_tags
created migrations/2026_01_01_000003_create_tags.bit
$ bit make migration create_comments
created migrations/2026_01_01_000004_create_comments.bit
$ bit make migration create_article_tags
created migrations/2026_01_01_000005_create_article_tags.bit
```

```bit
import { ReferentialAction } from "orm"

export class CreateArticles {
  up(s: Schema): ()! {
    s.create("articles", (t) => {
      t.id("id")
      t.string("title", 200)
      t.string("slug", 220).unique()
      t.text("body")
      t.int("author_id")
      t.int("created_at")
      t.int("updated_at")
      t.index("author_id")
      t.foreign("author_id").references("users", "id").onDelete(ReferentialAction.Cascade)
    })?
  }

  down(s: Schema): ()! {
    s.table("articles", (t) => {
      t.dropColumn("slug")
    })?
  }
}
```

```bit
export class CreateTags {
  up(s: Schema): ()! {
    s.create("tags", (t) => {
      t.id("id")
      t.string("name", 60).unique()
    })?
  }

  down(s: Schema): ()! {
    s.table("tags", (t) => {
      t.dropColumn("name")
    })?
  }
}
```

```bit
export class CreateComments {
  up(s: Schema): ()! {
    s.create("comments", (t) => {
      t.id("id")
      t.int("article_id")
      t.int("author_id")
      t.text("body")
      t.int("created_at")
      t.int("updated_at")
      t.index("article_id")
      t.foreign("article_id").references("articles", "id").onDelete(ReferentialAction.Cascade)
      t.foreign("author_id").references("users", "id").onDelete(ReferentialAction.Cascade)
    })?
  }

  down(s: Schema): ()! {
    s.table("comments", (t) => {
      t.dropColumn("body")
    })?
  }
}
```

The join table's own file builds its `SchemaOp` differently: no `Schema`
method builds a join table directly, so it calls `manyToManyTable` - which
already returns a full `SchemaOp` - and appends the result to `s.ops`
itself:

```bit
import { ManyToManyDesc, manyToManyTable } from "orm"

fn articleTagsDesc(): ManyToManyDesc {
  return ManyToManyDesc{
    joinTable = "article_tags", ownerColumn = "article_id", ownerTable = "articles",
    ownerIdColumn = "id", targetColumn = "tag_id", targetTable = "tags", targetIdColumn = "id",
  }
}

export class CreateArticleTags {
  up(s: Schema): ()! {
    s.ops = append(s.ops, manyToManyTable(articleTagsDesc()))
  }

  down(s: Schema): ()! {}
}
```

`onDelete(ReferentialAction.Cascade)` means deleting a user also deletes
their articles and comments - a real decision about Inkwell's data, made
once, here, instead of being an accident of whichever query happens to run
first. `manyToManyTable` builds `article_tags` with a composite primary key
across both foreign keys and an index on the target column; [Many-to-many
relations](../../orm/docs/manytomany.md) covers exactly what DDL that
produces. `articleTagsDesc` stays private to its own file - nothing else in
the app builds this description by hand, so nothing else needs to import
it.

Running `bit migrate` against a fresh database picks up all five files, in
file-name order, as one batch:

```text
$ bit migrate --url postgres://localhost/inkwell
applied 2026_01_01_000001_create_users
applied 2026_01_01_000002_create_articles
applied 2026_01_01_000003_create_tags
applied 2026_01_01_000004_create_comments
applied 2026_01_01_000005_create_article_tags
```

and every table exists, verified against a real Postgres container:

```text
create table "users" ( ... )
create table "articles" ( ... )
create index "articles_author_id_idx" on "articles" ("author_id")
create table "tags" ( ... )
create table "comments" ( ... )
create index "comments_article_id_idx" on "comments" ("article_id")
create table "article_tags" ( ... )
create index "article_tags_tag_id_idx" on "article_tags" ("tag_id")
```

## The sharp edge: rolling back only ever undoes the last batch

```text
$ bit migrate rollback --url postgres://localhost/inkwell
rolled back 2026_01_01_000005_create_article_tags
rolled back 2026_01_01_000004_create_comments
rolled back 2026_01_01_000003_create_tags
rolled back 2026_01_01_000002_create_articles
rolled back 2026_01_01_000001_create_users
```

`bit migrate rollback` undoes every migration applied by the MOST RECENT
`bit migrate` run - the highest recorded batch, newest file first - and
nothing older. [Apply migrations](../../orm/docs/migrate.md) covers the
batch rule in full. Each file's own `down` only runs what it wrote above:
`create_article_tags`'s `down` is empty, since nothing here undoes the join
table, and the other four each drop back the one column their own `up`
added last. A schema change that real writes now depend on is undone with
a new, forward migration, never by rolling back an old one that shipped
batches ago.

## What we built

Five migration files under `migrations/` - `users`, `articles`, `tags`,
`comments` and the `article_tags` join table - one class per file, and
`bit migrate` to apply them. Inkwell's own `pkg/web/guides/inkwell/
migrations/` directory is these same five files; its build and test gate
runs `bit migrate` once, against a throwaway Postgres, before the app or
its tests ever start - the app itself opens one database connection and
never calls `migrate` from its own code.

Specification: [Schema](../../orm/docs/schema.md), [Apply
migrations](../../orm/docs/migrate.md), [Many-to-many
relations](../../orm/docs/manytomany.md).

Previous: [Connecting to PostgreSQL](06-connecting-to-postgresql.md).
Next: [Querying and CRUD](08-querying-and-crud.md).
