# Tables and migrations with pkg/orm

<!-- doctest: deps orm -->

Inkwell can talk to Postgres now (part 6), but the database is empty. You
need tables for users, articles, tags and comments, and you need a safe way
to change those tables later without hand-writing `CREATE TABLE` and
`ALTER TABLE` twice, once for what is running today and once for what a
teammate's checkout has drifted into. `pkg/orm`'s schema builder and
migration runner are how Inkwell does both.

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

A bare `table(...)` call only builds a tree in memory. `Migration` is what
turns it into something you run once, safely, and record having run:

```bit
import { Migration, drop } from "orm"

fn usersMigration(): Migration {
  return Migration{
    version = 1,
    name = "create_users",
    checksum = "inkwell-users-1",
    apply = () => [
      table("users", (t) => {
        t.id("id")
        t.string("username", 60).unique()
        t.string("email", 255).unique()
        t.string("password_hash", 255)
        t.string("role", 20)
        t.int("created_at")
        t.int("updated_at")
      }),
    ],
    revert = () => [drop("users")],
  }
}
```

`version` orders migrations; `checksum` is a stable identifier you pick by
hand today (`pkg/orm` has no reflection to compute one for you from the
file's contents). `apply` and `revert` are each a function returning the
list of schema operations that statement runs - here, one `CREATE TABLE`
forward and one `DROP TABLE` back.

Bit has no reflection, so nothing can scan a `migrations/` folder and
discover what is in it. The registry is a plain list you write by hand:

```bit
import { Data, Postgres, RunnerDialect, ServerDialect, UpReport, up } from "orm"
import { now } from "std/time"

fn postgresDialect(): RunnerDialect {
  return RunnerDialect{ render = Postgres{}, server = ServerDialect.Postgres }
}

fn deployUsersOnly(db: Data): UpReport! {
  return up(db, postgresDialect(), []Migration{ usersMigration() }, now())?
}
```

`up` takes an advisory lock (so two instances deploying at the same moment
never race each other), checks every already-applied migration's checksum
against what it recorded last time, then applies whatever is still
pending, in order. Run `deployUsersOnly` against a fresh database and you
get:

```text
inkwell: applied 5 migration(s)
```

Run it again and nothing pending is left - `UpReport.applied` comes back
empty, because version 1 is already in the ledger. (That transcript is
from Inkwell's real registry below, all five migrations at once; a
database with only `usersMigration()` registered reports one.)

## Grow the registry: articles, tags, comments, and the tags join table

Inkwell needs four more tables. `articles` and `comments` each reference
`users` with a foreign key; `tags` is a plain lookup table; and an article
can have many tags while a tag can belong to many articles, which is a
relationship [Relationships](09-relationships.md) covers in the app layer,
but the join table itself belongs here, next to the rest of the schema:

```bit
import { ManyToManyDesc, ReferentialAction, manyToManyTable } from "orm"

fn articleTagsDesc(): ManyToManyDesc {
  return ManyToManyDesc{
    joinTable = "article_tags", ownerColumn = "article_id", ownerTable = "articles",
    ownerIdColumn = "id", targetColumn = "tag_id", targetTable = "tags", targetIdColumn = "id",
  }
}

fn articlesMigration(): Migration {
  return Migration{
    version = 2,
    name = "create_articles",
    checksum = "inkwell-articles-1",
    apply = () => [
      table("articles", (t) => {
        t.id("id")
        t.string("title", 200)
        t.string("slug", 220).unique()
        t.text("body")
        t.int("author_id")
        t.int("created_at")
        t.int("updated_at")
        t.index("author_id")
        t.foreign("author_id").references("users", "id").onDelete(ReferentialAction.Cascade)
      }),
    ],
    revert = () => [drop("articles")],
  }
}

fn tagsMigration(): Migration {
  return Migration{
    version = 3,
    name = "create_tags",
    checksum = "inkwell-tags-1",
    apply = () => [
      table("tags", (t) => {
        t.id("id")
        t.string("name", 60).unique()
      }),
    ],
    revert = () => [drop("tags")],
  }
}

fn commentsMigration(): Migration {
  return Migration{
    version = 4,
    name = "create_comments",
    checksum = "inkwell-comments-1",
    apply = () => [
      table("comments", (t) => {
        t.id("id")
        t.int("article_id")
        t.int("author_id")
        t.text("body")
        t.int("created_at")
        t.int("updated_at")
        t.index("article_id")
        t.foreign("article_id").references("articles", "id").onDelete(ReferentialAction.Cascade)
        t.foreign("author_id").references("users", "id").onDelete(ReferentialAction.Cascade)
      }),
    ],
    revert = () => [drop("comments")],
  }
}

fn articleTagsMigration(): Migration {
  return Migration{
    version = 5,
    name = "create_article_tags",
    checksum = "inkwell-article-tags-1",
    apply = () => [manyToManyTable(articleTagsDesc())],
    revert = () => [drop("article_tags")],
  }
}

export fn migrations(): []Migration {
  return [
    usersMigration(), articlesMigration(), tagsMigration(), commentsMigration(),
    articleTagsMigration(),
  ]
}

export fn runMigrations(db: Data): UpReport! {
  return up(db, postgresDialect(), migrations(), now())?
}
```

`onDelete(ReferentialAction.Cascade)` means deleting a user also deletes
their articles and comments - a real decision about Inkwell's data, made
once, here, instead of being an accident of whichever query happens to run
first. `manyToManyTable` builds `article_tags` with a composite primary key
across both foreign keys and an index on the target column; [Many-to-many
relations](../../orm/docs/manytomany.md) covers exactly what DDL that
produces.

`runMigrations` is what `main.bit` calls once, at boot, before mounting any
route. Running it against a fresh database prints:

```text
postgres: connected with sslmode=disable - credentials and query results cross the network in the clear.
inkwell: applied 5 migration(s)
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

## Checking what's pending before you deploy

```bit
import { MigrationStatus, status } from "orm"

fn pendingMigrations(db: Data): []MigrationStatus! {
  return status(db, migrations())?
}
```

`status` reads the ledger without taking the advisory lock `up` takes, so a
health check or a deploy script can ask "is this database caught up"
without blocking a real migration that might be running at the same
moment.

## The sharp edge: rolling back only ever undoes the last one

`down(db, postgresDialect(), migrations(), now(), windowNs)` reverts the
single most recently applied migration, and only if it ran within
`windowNs` of now - a rollback attempted long after the fact refuses,
naming how old the migration actually is. [Apply
migrations](../../orm/docs/migrate.md) covers why: once real writes depend
on a schema change, undoing it isn't safe to automate. A production
rollback is a new, forward migration, not `down`.

## What we built

`db.bit`'s migration registry: five migrations covering `users`,
`articles`, `tags`, `comments` and the `article_tags` join table, and
`runMigrations`, the function `main.bit` calls once at boot before mounting
any route.

Specification: [Schema](../../orm/docs/schema.md), [Apply
migrations](../../orm/docs/migrate.md), [Many-to-many
relations](../../orm/docs/manytomany.md).

Previous: Part 6, Connecting to PostgreSQL.
Next: [Querying and CRUD](08-querying-and-crud.md).
