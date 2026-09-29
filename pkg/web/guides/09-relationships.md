# Relationships

<!-- doctest: deps postgres orm -->

An article has an author, and it can carry any number of tags. Load them
the naive way and a list of 20 articles costs 20 extra queries just for the
authors, and 20 more for the tags. `pkg/orm`'s `with()` turns "one query per
row" into "one query for the parent rows, plus one more per relation you
asked for" - three statements total for this page's `GET /articles/:id`,
no matter how many tags an article has.

## The other two tables: User and Tag

`users.bit` already declares `User` ([chapter 21](08-querying-and-crud.md)'s
own pattern, one level up), and `tags.bit` needs the same shape for `Tag`.
This page repeats the minimum of both so every block below is complete on
its own:

```bit
import { Db } from "orm"

@table class User {
  id: i64,
  username: string,
  email: string,
  passwordHash: string,
  role: string,
}

@table class Tag {
  id: i64,
  name: string,
}
```

## belongsTo and manyToMany, declared on Article together

```bit
import { App, Ctx, Res, badRequest, notFound } from "web"
import { parseInt } from "std/strings"

@table @timestamps class Article {
  id: i64,
  title: string,
  slug: string,
  body: string,
  authorId: i64,
  @belongsTo("authorId")
  author: User,
  @manyToMany("article_tags")
  tags: []Tag,
  createdAt: i64,
  updatedAt: i64,
}

fn parseId(s: string): i64! {
  return parseInt(s)?
}

fn findArticleById(db: Db, id: i64): Article! {
  return db.table<Article>().with("author").with("tags").find(id)?
}
```

`@belongsTo("authorId")` names the foreign key already on `Article` - the
owning side. `@manyToMany("article_tags")` names the join table [chapter
20](07-tables-and-migrations-with-pkg-orm.md) already migrated. Unlike the
old query-builder API, nothing here writes a loader by hand: `@table`
synthesizes `with("author")`/`with("tags")` from the two attributes above,
so `db.table<Article>()` already knows how to batch-load either relation -
one extra query per name you ask for, never one per row.

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
select * from article where id = $1 limit 2
select * from user where id in ($1)
select tag.*, article_tags.article_id as mtm_owner_id
  from tag join article_tags on tag.id = article_tags.tag_id
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

## Writing: insert() and link() replace save() and attach()

Adding a relation field to a class used to break `save()`, whose generic
`INSERT` wrote every field it knew about, `author` and `tags` included, and
neither is a real column. `db.table<Article>().insert()` already excludes
`author`/`tags` - a relation field is never treated as a column to write -
so an article insert needs no hand-written column list. The tags still need
their own step: `insert()` writes `Article` alone, then `link()` attaches
whichever tag ids the tag names resolved to, through the identical
`article_tags` join table the `@manyToMany` attribute already named.

```bit
import { UniqueViolation, classify } from "orm"
import { minLen } from "web"
import { newBuilder } from "std/strings"
import { isSome, unwrap } from "std/core"

export @json class CreateArticleInput {
  @minLen(1)
  title: string,

  body: string,

  authorId: i64,

  tags: []string,
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

// Idempotent under a race: a unique-violation on the insert means another
// request created the same name first, so re-reading it is correct rather
// than surfacing the error.
fn findOrCreateTag(db: Db, name: string): Tag! {
  let tags = db.table<Tag>()
  let found = tags.where("name", name).first()?
  if (isSome(found)) {
    return unwrap(found)
  }
  return tags.insert(Tag{ id = 0, name = name }) catch e {
    let cause = classify(e, "tags")
    let (_, unique) = cause.(UniqueViolation)
    if (!unique) {
      fail cause
    }
    let retry = tags.where("name", name).first()?
    if (!isSome(retry)) {
      fail cause
    }
    return unwrap(retry)
  }
}

fn createArticle(c: Ctx, db: Db): Res! {
  let input = c.body<CreateArticleInput>()?
  let articles = db.table<Article>()
  let a = articles.insert(
    Article{
      id = 0, title = input.title, slug = slugify(input.title), body = input.body,
      authorId = input.authorId, author = User{
        id = 0, username = "", email = "", passwordHash = "", role = "",
      },
      tags = []Tag(0), createdAt = 0, updatedAt = 0,
    },
  )?
  let ids = []i64(0)
  for name of input.tags {
    let t = findOrCreateTag(db, name)?
    ids = append(ids, t.id)
  }
  if (len(ids) > 0) {
    articles.link(a, "tags", ids)?
  }
  return c.created("${a.id}")
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
an article and links its tags - one statement each, not yet wrapped in a
single transaction, which [chapter 28](15-transactions.md) adds.
`ArticleView` now carries `authorUsername` and `tags` alongside what
[chapter 21](08-querying-and-crud.md) built.

Specification: [Relations](../../orm/docs/relation.md), [Many-to-many
relations](../../orm/docs/manytomany.md).

Previous: [Querying and CRUD](08-querying-and-crud.md).
Next: [Registering users and hashing passwords](10-registering-users-and-hashing-passwords.md).
