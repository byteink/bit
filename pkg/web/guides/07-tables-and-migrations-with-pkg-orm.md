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
wraps the identical `table(...)` builder above:

```bit
import { Migration, Schema } from "orm"

class CreateUsers {
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
    s.drop("users")?
  }
}
```

Interfaces are structural: `CreateUsers` satisfies `Migration` simply by
declaring both methods, no `implements` clause needed. `up` describes the
change forward, `down` describes its exact reverse - here, one
`CREATE TABLE` and one `DROP TABLE`.

Bit has no reflection, so nothing can scan a `migrations/` folder and
discover what is in it. The registry is a plain list you write by hand,
pairing each class with a file name - the string the ledger records, and
the order migrations apply in:

```bit
import { Data, MigrationFile, Postgres, RunnerDialect, ServerDialect, migrate } from "orm"
import { now } from "std/time"

fn postgresDialect(): RunnerDialect {
  return RunnerDialect{ render = Postgres{}, server = ServerDialect.Postgres }
}

fn deployUsersOnly(db: Data): ()! {
  let files = [MigrationFile{ name = "0001_create_users", m = CreateUsers{} }]
  migrate(db, postgresDialect(), files, now())?
}
```

`migrate` takes an advisory lock (so two instances deploying at the same
moment never race each other), then applies every migration not yet
recorded in the ledger, in ascending file-name order, all as one new
batch. Run `deployUsersOnly` against a fresh database and you get:

```text
inkwell: applied 5 migration(s)
```

Run it again and nothing pending is left - the report's `applied` list
comes back empty, because `0001_create_users` is already in the ledger.
(That transcript is from Inkwell's real registry below, all five
migrations at once; a database with only `CreateUsers` registered reports
one.)

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

class CreateArticles {
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
    s.drop("articles")?
  }
}

class CreateTags {
  up(s: Schema): ()! {
    s.create("tags", (t) => {
      t.id("id")
      t.string("name", 60).unique()
    })?
  }

  down(s: Schema): ()! {
    s.drop("tags")?
  }
}

class CreateComments {
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
    s.drop("comments")?
  }
}

// No `Schema` method builds a join table directly - `manyToManyTable`
// already returns a full `SchemaOp`, so `up` appends it to `s.ops` (`export`
// exactly so a prebuilt op can be added this way).
class CreateArticleTags {
  up(s: Schema): ()! {
    s.ops = append(s.ops, manyToManyTable(articleTagsDesc()))
  }

  down(s: Schema): ()! {
    s.drop("article_tags")?
  }
}

export fn migrations(): []MigrationFile {
  return [
    MigrationFile{ name = "0001_create_users", m = CreateUsers{} },
    MigrationFile{ name = "0002_create_articles", m = CreateArticles{} },
    MigrationFile{ name = "0003_create_tags", m = CreateTags{} },
    MigrationFile{ name = "0004_create_comments", m = CreateComments{} },
    MigrationFile{ name = "0005_create_article_tags", m = CreateArticleTags{} },
  ]
}

export fn runMigrations(db: Data): ()! {
  migrate(db, postgresDialect(), migrations(), now())?
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

## The sharp edge: rolling back only ever undoes the last batch

```bit
import { rollback } from "orm"

fn undoLastDeploy(db: Data): ()! {
  rollback(db, postgresDialect(), migrations())?
}
```

`rollback(db, postgresDialect(), migrations())` undoes every migration
applied by the MOST RECENT `migrate` call - the highest recorded batch,
newest file first - and nothing older. [Apply
migrations](../../orm/docs/migrate.md) covers the batch rule in full. A
schema change that real writes now depend on is undone with a new,
forward migration, never by rolling back an old one that shipped batches
ago.

## What we built

`db.bit`'s migration registry: five migrations covering `users`,
`articles`, `tags`, `comments` and the `article_tags` join table, and
`runMigrations`, the function `main.bit` calls once at boot before mounting
any route.

Specification: [Schema](../../orm/docs/schema.md), [Apply
migrations](../../orm/docs/migrate.md), [Many-to-many
relations](../../orm/docs/manytomany.md).

Previous: [Connecting to PostgreSQL](06-connecting-to-postgresql.md).
Next: [Querying and CRUD](08-querying-and-crud.md).
