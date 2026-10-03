# Querying and CRUD

<!-- doctest: deps postgres orm -->

The `articles` table exists ([chapter
20](07-tables-and-migrations-with-pkg-orm.md)), but nothing in Inkwell can read or
write a row yet. This part gives `GET /articles`, `GET /articles/:id`,
`POST /articles`, `PUT /articles/:id` and `DELETE /articles/:id` real
behaviour, backed by `pkg/orm`'s `db.table<T>()` repository. Articles don't
have an author you can log in as yet - that arrives in [chapter
23](10-registering-users-and-hashing-passwords.md) - so for now a request
names its `authorId` directly.

## The class

```bit
import { Db } from "orm"
import { AttrDesc, FieldDesc } from "std/sql"

// `articles`, not the snake_case default `article`, because chapter 7's
// migration already created the table under that name - `@table("articles")`
// overrides the default the same way `@table("accounts")` does in the orm
// package's own docs.
@table("articles") class Article {
  id: i64,
  title: string,
  slug: string,
  body: string,
  authorId: i64,
  createdAt: i64,
  updatedAt: i64,
}
```

That is the whole model: no hand-written mapper, no `TableDesc`, no table
name spelled out a second time anywhere. `id` is the key because it is a
field literally named `id` - no `@id` attribute needed for a single-column
key. `db.table<Article>()` (below) hands back a repository that already
knows how to read a `Rows` into an `Article` and an `Article` back into a
row, because `@table` generates that mapping for every class that carries
it.

## Reading: list and show

```bit
import { App, Ctx, Res, badRequest, notFound } from "web"
import { Dir } from "orm"
import { parseInt } from "std/strings"

fn findArticleById(db: Db, id: i64): Article! {
  return db.table<Article>().find(id)?
}

fn parseId(s: string): i64! {
  return parseInt(s)?
}

@json class ArticleView {
  id: i64,
  title: string,
  slug: string,
  body: string,
  authorId: i64,
}

fn toArticleView(a: Article): ArticleView {
  return ArticleView{
    id = a.id,
    title = a.title,
    slug = a.slug,
    body = a.body,
    authorId = a.authorId,
  }
}

fn listArticles(c: Ctx, db: Db): Res! {
  let rows = db.table<Article>().orderBy("createdAt", Dir.Desc).all()?
  let out = []ArticleView(0)
  for a of rows {
    out = append(out, toArticleView(a))
  }
  return c.jsonList(out)
}

fn showArticle(c: Ctx, db: Db): Res! {
  let id = parseId(c.param("id")) catch _ {
    fail badRequest("id must be an integer")
  }
  let a = findArticleById(db, id) catch _ {
    fail notFound("no article with that id")
  }
  return c.json(toArticleView(a))
}

export fn mountArticles(app: App, db: Db) {
  let group = app.group("/articles")
  group.get("/", (c) => listArticles(c, db))
  group.get("/:id", (c) => showArticle(c, db))
}
```

`app.use(envelope())` is already mounted from [chapter
17](04-errors-and-consistent-responses.md), so every response
here carries `{"data": ...}`. Run Inkwell and try it against an empty
database:

```
$ curl -i http://127.0.0.1:8080/articles
HTTP/1.1 200 OK
Content-Type: application/json

{"data":[]}
```

## Writing: create, update, delete

```bit
import { minLen } from "web"
import { now } from "std/time"
import { Builder } from "std/strings"

fn slugify(title: string): string {
  let b = Builder()
  let lastDash = false
  let i = 0
  while (i < len(title)) {
    let ch = title[i]
    let lower = ch
    if (ch >= 'A' && ch <= 'Z') {
      lower = ch + 32
    }
    if ((lower >= 'a' && lower <= 'z') || (lower >= '0' && lower <= '9')) {
      b.writeByte(lower)
      lastDash = false
    } else if (!lastDash) {
      b.writeByte('-')
      lastDash = true
    }
    i = i + 1
  }
  return b.toString()
}

export @json class CreateArticleInput {
  @minLen(1)
  title: string

  body: string

  authorId: i64
}

fn createArticle(c: Ctx, db: Db): Res! {
  let input = c.body<CreateArticleInput>()?
  let stamp = now().ns
  let a = Article{
    id = 0, title = input.title, slug = slugify(input.title), body = input.body,
    authorId = input.authorId, createdAt = stamp, updatedAt = stamp,
  }
  let saved = db.table<Article>().insert(a)?
  return c.created("${saved.id}")
}
```

`db.table<Article>().insert(a)` writes every field but `id` - a database-
generated identity column, the same `t.id("id")` chapter 7's migration
declared - and hands back the row the database wrote, `id` filled in. There
is no separate "read the generated id back" step to remember: `saved.id` is
already the real one.

Create one, for real:

```
$ curl -i -X POST http://127.0.0.1:8080/articles \
    -H 'Content-Type: application/json' \
    -d '{"title":"Hello Inkwell","body":"My first post.","authorId":1}'
HTTP/1.1 201 Created
Location: /articles/1
```

The SQL `insert` sends, from Postgres's own statement log:

```text
insert into articles (title, slug, body, author_id, created_at, updated_at)
values ($1, $2, $3, $4, $5, $6) returning *
```

Read it back:

```
$ curl -i http://127.0.0.1:8080/articles/1
HTTP/1.1 200 OK
Content-Type: application/json

{"data":{"id":1,"title":"Hello Inkwell","slug":"hello-inkwell","body":"My first post.","authorId":1}}
```

An empty title is rejected before any SQL runs:

```
$ curl -i -X POST http://127.0.0.1:8080/articles \
    -H 'Content-Type: application/json' \
    -d '{"title":"","body":"x","authorId":1}'
HTTP/1.1 422 Unprocessable Entity

{"error":{"code":"unprocessable_entity","message":"title: must be at least 1 character(s)"}}
```

Update and delete:

```bit
export @json class UpdateArticleInput {
  title: string,
  body: string,
}

fn updateArticle(c: Ctx, db: Db): Res! {
  let id = parseId(c.param("id")) catch _ {
    fail badRequest("id must be an integer")
  }
  let existing = findArticleById(db, id) catch _ {
    fail notFound("no article with that id")
  }
  let input = c.body<UpdateArticleInput>()?
  existing.title = input.title
  existing.body = input.body
  existing.updatedAt = now().ns
  db.table<Article>().update(existing)?
  return c.json(toArticleView(existing))
}

fn deleteArticle(c: Ctx, db: Db): Res! {
  let id = parseId(c.param("id")) catch _ {
    fail badRequest("id must be an integer")
  }
  findArticleById(db, id) catch _ {
    fail notFound("no article with that id")
  }
  db.table<Article>().delete(id)?
  return c.noContent()
}
```

`update` writes every column but `id` itself, by `id` - there is no
`isPersisted()` flag to check first: `update` is always an `UPDATE`,
`insert` is always an `INSERT`, and a caller never has to ask a row which
one it means.

```
$ curl -i -X PUT http://127.0.0.1:8080/articles/1 \
    -H 'Content-Type: application/json' \
    -d '{"title":"Hello Inkwell (edited)","body":"Updated body."}'
HTTP/1.1 200 OK

{"data":{"id":1,"title":"Hello Inkwell (edited)","slug":"hello-inkwell","body":"Updated body.","authorId":1}}
```

```text
update articles set title = $1, slug = $2, body = $3, author_id = $4, created_at = $5, updated_at = $6 where id = $7
```

```
$ curl -i -X DELETE http://127.0.0.1:8080/articles/1
HTTP/1.1 204 No Content

$ curl -i http://127.0.0.1:8080/articles/999
HTTP/1.1 404 Not Found

{"error":{"code":"not_found","message":"Not Found","detail":"no article with that id"}}
```

## The sharp edge: `find` always carries a limit

`findArticleById` above ends in `db.table<Article>().find(id)`, not
`.where("id", id).all()[0]`. Postgres's own log for it reads:

```text
select * from articles where id = $1 limit 2
```

`limit 2`, not `limit 1`: `find` wants to know if the key matched MORE than
one row, which a `limit 1` could never tell it. `id` is unique here so that
never happens, but the same guard against a broken key column catches the
mistake instead of quietly returning whichever row Postgres happened to
return first.

## What we built

Full CRUD for `articles`: list, show, create, update and delete, all going
through `pkg/orm`'s `db.table<Article>()` repository, with validation on
the way in and a consistent `{"data": ...}` / `{"error": ...}` envelope on
the way out.

Previous: [Tables and migrations with pkg/orm](07-tables-and-migrations-with-pkg-orm.md).
Next: [Relationships](09-relationships.md).
