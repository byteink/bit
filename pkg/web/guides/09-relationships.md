# Relationships

<!-- doctest: deps postgres orm -->

An article has an author, and it can carry any number of tags. Load them
the naive way and a list of 20 articles costs 20 extra queries just for the
authors, and 20 more for the tags. `pkg/orm`'s `with()` turns "one query per
row" into "one query for the parent rows, plus one more per relation you
asked for" - three statements total for this page's `GET /articles/:id`,
no matter how many tags an article has.

## The other two tables: User and Tag

`Article` needs a `User` and a `Tag` to relate to. Both follow the same
`@table` pattern [chapter 21](08-querying-and-crud.md) already established
for `Article` itself - no mapper, no `TableDesc`, the table name spelled out
once:

```bit
import { Db } from "orm"

@table("users") class User {
  id: i64,
  username: string,
}

@table("tags") class Tag {
  id: i64,
  name: string,
}
```

## belongsTo and manyToMany, declared on Article together

```bit
import { Dir } from "orm"
import { isSome, unwrap } from "std/core"

@table("articles") class Article {
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
}

fn findArticleById(db: Db, id: i64): Article! {
  return db.table<Article>().with("author").with("tags").find(id)?
}
```

`find()` eager-loads every queued `with()` the same way `all()`/`first()`
do, and already fails naming the table if no row (or, on a primary key,
more than one) matches - no `where("id", ...).first()` workaround needed.

`@belongsTo("authorId")` names the foreign key already on `Article` - the
owning side. `@manyToMany("article_tags")` names the join table [chapter
20](07-tables-and-migrations-with-pkg-orm.md) already migrated. Neither
`author` nor `tags` needs a value in a composite literal that builds an
`Article` without one: both start in a "not loaded" state that a bare read
rejects, and `with("author")`/`with("tags")` are the only things that fill
them in.

Fetch an article that has an author and tags:

```
$ curl -i http://127.0.0.1:8080/articles/1
HTTP/1.1 200 OK
Content-Type: application/json

{"data":{"id":1,"title":"Relations in Bit","authorUsername":"ada","tags":[{"id":1,"name":"bit"},{"id":2,"name":"orm"}]}}
```

Three statements, from Postgres's own log, however many tags that article
has:

```text
select * from articles where id = $1 limit 2
select * from users where id in ($1)
select tags.*, article_tags.article_id as mtm_owner_id
  from tags join article_tags on tags.id = article_tags.tag_id
  where article_tags.article_id in ($1)
```

## Rendering it

```bit
@json class TagView {
  id: i64,
  name: string,
}

fn toTagView(t: Tag): TagView {
  return TagView{ id = t.id, name = t.name }
}

@json class ArticleView {
  id: i64,
  title: string,
  authorUsername: string,
  tags: []TagView,
}

fn toArticleView(a: Article): ArticleView {
  let tagViews = []TagView(0)
  for t of a.tags {
    tagViews = append(tagViews, toTagView(t))
  }
  return ArticleView{
    id = a.id,
    title = a.title,
    authorUsername = a.author.username,
    tags = tagViews,
  }
}
```

```bit
import { App, Ctx, Res, badRequest, notFound } from "web"
import { parseInt } from "std/strings"

fn parseId(s: string): i64! {
  return parseInt(s)?
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
```

## Creating an article with tags: insert, then link

`db.table<Article>().insert(a)` writes only the real columns - `author` and
`tags` are relation fields, never columns, so `insert` skips both the same
way it already skips a database-generated `id`. Attaching the tags is a
second, explicit step: `link()` writes the join rows.

```bit
import { UniqueViolation, classify } from "orm"
import { minLen } from "web"
import { newBuilder } from "std/strings"
import { now } from "std/time"

export @json class CreateArticleInput {
  @minLen(1)
  title: string

  body: string

  authorId: i64

  tags: []string
}

fn slugify(title: string): string {
  let b = newBuilder()
  let i = 0
  while (i < len(title)) {
    let ch = title[i]
    if ((ch >= 'a' && ch <= 'z') || (ch >= '0' && ch <= '9')) {
      b.writeByte(ch)
    } else if (ch >= 'A' && ch <= 'Z') {
      b.writeByte(ch + 32)
    } else {
      b.writeByte('-')
    }
    i = i + 1
  }
  return b.toString()
}

fn findOrCreateTag(db: Db, name: string): Tag! {
  let tags = db.table<Tag>()
  let existing = tags.where("name", name).first()?
  if (isSome(existing)) {
    return unwrap(existing)
  }
  return tags.insert(Tag{ id = 0, name = name }) catch e {
    let cause = classify(e, "tags")
    let (_, ok) = cause.(UniqueViolation)
    if (ok) {
      return unwrap(tags.where("name", name).first()?)
    }
    fail cause
  }
}

fn attachTagNames(db: Db, a: Article, names: []string): ()! {
  let ids = []i64(0)
  for name of names {
    let t = findOrCreateTag(db, name)?
    ids = append(ids, t.id)
  }
  if (len(ids) == 0) {
    return
  }
  db.table<Article>().link(a, "tags", ids)?
}

fn createArticle(c: Ctx, db: Db): Res! {
  let input = c.body<CreateArticleInput>()?
  let stamp = now().ns
  let a = Article{
    id = 0, title = input.title, slug = slugify(input.title), body = input.body,
    authorId = input.authorId, createdAt = stamp, updatedAt = stamp,
  }
  let saved = db.table<Article>().insert(a)?
  attachTagNames(db, saved, input.tags)?
  return c.created("${saved.id}")
}
```

Create one, with tags, for real:

```
$ curl -i -X POST http://127.0.0.1:8080/articles \
    -H 'Content-Type: application/json' \
    -d '{"title":"Relations in Bit","body":"belongsTo and manyToMany.","authorId":1,"tags":["bit","orm"]}'
HTTP/1.1 201 Created
Location: /articles/1
```

`link()` is idempotent - it inserts the pairs that aren't already there, one
statement, and calling it twice with the same tag ids is safe:

```text
insert into article_tags (article_id, tag_id) values ($1, $2), ($3, $4)
  on conflict (article_id, tag_id) do nothing
```

## What we built

`GET /articles/:id` eager-loads an article's author and tags in three
queries through `with("author").with("tags")`, and `POST /articles` creates
an article and attaches its tags - `insert()` for the row, `link()` for the
join table, not yet wrapped in a single transaction, which [chapter
28](15-transactions.md) adds. `ArticleView` now carries `authorUsername`
and `tags` alongside what [chapter 21](08-querying-and-crud.md) built.

Specification: [Relations](../../orm/docs/relation.md), [Many-to-many
relations](../../orm/docs/manytomany.md).

Previous: [Querying and CRUD](08-querying-and-crud.md).
Next: [Registering users and hashing passwords](10-registering-users-and-hashing-passwords.md).
