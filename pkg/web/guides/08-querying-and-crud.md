# Querying and CRUD

<!-- doctest: deps postgres orm -->

The `articles` table exists ([chapter
20](07-tables-and-migrations-with-pkg-orm.md)), but nothing in Inkwell can read or
write a row yet. This part gives `GET /articles`, `GET /articles/:id`,
`POST /articles`, `PUT /articles/:id` and `DELETE /articles/:id` real
behaviour, backed by `pkg/orm`'s query builder and `save()`. Articles don't
have an author you can log in as yet - that arrives in [chapter
23](10-registering-users-and-hashing-passwords.md) - so for now a request
names its `authorId` directly.

## The class, and the two functions every other one calls

```bit
import { Data, Query, TableDesc, find } from "orm"
import { AttrDesc, FieldDesc, Rows, Value, sqlReqInt, sqlReqText } from "std/sql"
import { Json } from "std/json"

@table @timestamps class Article {
  @id
  id: i64
  title: string
  slug: string
  body: string
  authorId: i64
  createdAt: i64
  updatedAt: i64
}

fn articlePlaceholder(): Article {
  return Article{
    id = 0,
    title = "",
    slug = "",
    body = "",
    authorId = 0,
    createdAt = 0,
    updatedAt = 0,
  }
}

fn articleDesc(): TableDesc {
  return TableDesc{
    table = "articles", fields = articlePlaceholder().tableDescriptor(),
    classAttrs = articlePlaceholder().tableAttrs(),
  }
}

fn articleMapper(rows: Rows): Article! {
  let cols = rows.columns()
  let a = Article{
    id = sqlReqInt(rows, cols, "id")?,
    title = sqlReqText(rows, cols, "title")?,
    slug = sqlReqText(rows, cols, "slug")?,
    body = sqlReqText(rows, cols, "body")?,
    authorId = sqlReqInt(rows, cols, "author_id")?,
    createdAt = sqlReqInt(rows, cols, "created_at")?,
    updatedAt = sqlReqInt(rows, cols, "updated_at")?,
  }
  a.markPersisted(true)
  return a
}

fn articles(db: Data): Query<Article> {
  return find<Article>(db, "articles", articleDesc().fields, articleMapper)
}
```

`articleDesc()` and `articles(db)` are the one place `Article`'s shape is
spelled out - [Query](../../orm/docs/query.md) covers why `find<T>` takes an
explicit table name, field list and mapper instead of inferring them.
`articleMapper` calls `a.markPersisted(true)` before returning: that flag is
what `save()` reads to decide `INSERT` versus `UPDATE` later in this page,
and nothing sets it for you on a hand-written mapper - a row that came back
from a query is, as far as `save()` is concerned, already in the database.

## Reading: list and show

```bit
import { App, Ctx, Res, badRequest, notFound } from "web"
import { Dir } from "orm"
import { parseInt } from "std/strings"

fn findArticleById(db: Data, id: i64): Article! {
  return articles(db).where("id", Value.Int(id)).oneOrFail()?
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

fn listArticles(c: Ctx, db: Data): Res! {
  let rows = articles(db).orderBy("createdAt", Dir.Desc).all()?
  let out = []ArticleView(0)
  for a of rows {
    out = append(out, toArticleView(a))
  }
  return c.jsonList(out)
}

fn showArticle(c: Ctx, db: Data): Res! {
  let id = parseId(c.param("id")) catch _ {
    fail badRequest("id must be an integer")
  }
  let a = findArticleById(db, id) catch _ {
    fail notFound("no article with that id")
  }
  return c.json(toArticleView(a))
}

export fn mountArticles(app: App, db: Data) {
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
import { save } from "orm"
import { applyTimestamps } from "orm"
import { minLen } from "web"
import { now } from "std/time"
import { newBuilder } from "std/strings"

fn slugify(title: string): string {
  let b = newBuilder()
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

fn articleValues(a: Article): map<string, Value> {
  return map<string, Value>{
    "id": Value.Int(a.id), "title": Value.Text(a.title), "slug": Value.Text(a.slug),
    "body": Value.Text(a.body), "authorId": Value.Int(a.authorId),
  }
}

fn createArticle(c: Ctx, db: Data): Res! {
  let input = c.body<CreateArticleInput>()?
  let a = Article{
    id = 0, title = input.title, slug = slugify(input.title), body = input.body,
    authorId = input.authorId, createdAt = 0, updatedAt = 0,
  }
  let values = articleValues(a)
  let desc = applyTimestamps(articleDesc(), values, a.isPersisted(), a.tableAttrs(), now())?
  let result = save(db, desc, values, a.isPersisted())?
  let (idv, ok) = result.generated["id"]
  if (!ok) {
    fail newError("createArticle: no id returned")
  }
  return c.created("${intValue(idv)}")
}

fn intValue(v: Value): i64 {
  match (v) {
    Int(n) => return n
    _ => return 0
  }
}
```

`a.isPersisted()` is `false` for the fresh `Article{...}` composite literal
above, so `save` builds an `INSERT`. `articleValues` never supplies `"id"`
in a way that reaches the statement: `id` is `t.id("id")`, database-generated
on Postgres, and `save` excludes a generated identity column from the
column list it writes and reads the real one back through
`result.generated["id"]` instead. `applyTimestamps` fills `createdAt` and
`updatedAt` on the SAME `values` map `save` goes on to read - call
`articleValues(a)` once and hold onto it, not twice, or the second call
builds a fresh map that never saw the timestamps ([Write](../../orm/docs/write.md),
[Timestamps](../../orm/docs/timestamps.md)).

Create one, for real:

```
$ curl -i -X POST http://127.0.0.1:8080/articles \
    -H 'Content-Type: application/json' \
    -d '{"title":"Hello Inkwell","body":"My first post.","authorId":1}'
HTTP/1.1 201 Created
Location: /articles/1
```

The SQL `save` sends, from Postgres's own statement log:

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

fn updateArticle(c: Ctx, db: Data): Res! {
  let id = parseId(c.param("id")) catch _ {
    fail badRequest("id must be an integer")
  }
  let existing = findArticleById(db, id) catch _ {
    fail notFound("no article with that id")
  }
  let input = c.body<UpdateArticleInput>()?
  existing.title = input.title
  existing.body = input.body
  let values = articleValues(existing)
  let desc = applyTimestamps(
    articleDesc(),
    values,
    existing.isPersisted(),
    existing.tableAttrs(),
    now(),
  )?
  save(db, desc, values, existing.isPersisted())?
  return c.json(toArticleView(existing))
}

import { delete as ormDelete } from "orm"

fn deleteArticle(c: Ctx, db: Data): Res! {
  let id = parseId(c.param("id")) catch _ {
    fail badRequest("id must be an integer")
  }
  let existing = findArticleById(db, id) catch _ {
    fail notFound("no article with that id")
  }
  ormDelete(db, articleDesc(), articleValues(existing))?
  return c.noContent()
}
```

`delete` is imported under another name on purpose: `delete` is also a
built-in name (for removing a map key), and a bare, unimported `delete(...)`
call silently resolves to the wrong one with no diagnostic - a known
compiler gap. Importing it explicitly, under a name that can't collide, is
the way every file in this part that calls `orm`'s `delete` writes it.

`existing` came back from `findArticleById`, whose mapper already called
`markPersisted(true)`, so `save` here builds an `UPDATE`, not a second
`INSERT`:

```
$ curl -i -X PUT http://127.0.0.1:8080/articles/1 \
    -H 'Content-Type: application/json' \
    -d '{"title":"Hello Inkwell (edited)","body":"Updated body."}'
HTTP/1.1 200 OK

{"data":{"id":1,"title":"Hello Inkwell (edited)","slug":"hello-inkwell","body":"Updated body.","authorId":1}}
```

```text
update articles set title = $1, slug = $2, body = $3, author_id = $4, updated_at = $5 where id = $6
```

`updated_at` is the only timestamp column in that `SET` list - `applyTimestamps`
drops `created_at` from the statement entirely on the `UPDATE` branch, so a
row's real creation time can never be overwritten by editing it later.

```
$ curl -i -X DELETE http://127.0.0.1:8080/articles/1
HTTP/1.1 204 No Content

$ curl -i http://127.0.0.1:8080/articles/999
HTTP/1.1 404 Not Found

{"error":{"code":"not_found","message":"Not Found","detail":"no article with that id"}}
```

## The sharp edge: `one`/`oneOrFail` always carry a limit

`findArticleById` above ends in `.oneOrFail()`, not `.where(...).all()[0]`.
Postgres's own log for it reads:

```text
select * from articles where id = $1 limit 2
```

`limit 2`, not `limit 1`: `oneOrFail` wants to know if the query matched
MORE than one row, which a `limit 1` could never tell it. `id` is unique
here so that never happens, but the same method on a non-unique column
catches the mistake instead of quietly returning whichever row Postgres
happened to return first. See [Query](../../orm/docs/query.md)'s "the five
terminals" for the rest of `all`/`one`/`oneOrFail`/`count`/`exists`.

## What we built

Full CRUD for `articles`: list, show, create, update and delete, all going
through `pkg/orm`'s `find<T>`/`Query<T>`/`save`/`delete`, with validation on
the way in and a consistent `{"data": ...}` / `{"error": ...}` envelope on
the way out.

Specification: [Query](../../orm/docs/query.md), [Write](../../orm/docs/write.md),
[Timestamps](../../orm/docs/timestamps.md).

Previous: [Tables and migrations with pkg/orm](07-tables-and-migrations-with-pkg-orm.md).
Next: [Relationships](09-relationships.md).
