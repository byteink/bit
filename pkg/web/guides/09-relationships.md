# Relationships

<!-- doctest: deps postgres orm -->

An article has an author, and it can carry any number of tags. Load them
the naive way and a list of 20 articles costs 20 extra queries just for the
authors, and 20 more for the tags. `pkg/orm`'s `with()` turns "one query per
row" into "one query for the parent rows, plus one more per relation you
asked for" - three statements total for this page's `GET /articles/:id`,
no matter how many tags an article has.

## The other two tables: User and Tag

`users.bit` already declares `User`/`users(db)`/`findUserById` (part 8's own
pattern, one level up), and `tags.bit` needs the same shape for `Tag`. This
page repeats the minimum of both so every block below is complete on its
own:

```bit
import { Data, Query, TableDesc, find } from "orm"
import { AttrDesc, FieldDesc, Rows, Value, sqlReqInt, sqlReqText } from "std/sql"
import { App, Ctx, Res, badRequest, notFound } from "web"
import { Json, JsonEntry } from "std/json"
import { parseInt } from "std/strings"

@table @timestamps class User {
  @id
  id: i64
  username: string
  email: string
  passwordHash: string
  role: string
  createdAt: i64
  updatedAt: i64
}

fn userPlaceholder(): User {
  return User{
    id = 0, username = "", email = "", passwordHash = "", role = "", createdAt = 0, updatedAt = 0,
  }
}

fn userDesc(): TableDesc {
  return TableDesc{
    table = "users", fields = userPlaceholder().tableDescriptor(), classAttrs = []AttrDesc(0),
  }
}

fn userMapper(rows: Rows): User! {
  let cols = rows.columns()
  return User{
    id = sqlReqInt(rows, cols, "id")?,
    username = sqlReqText(rows, cols, "username")?,
    email = sqlReqText(rows, cols, "email")?,
    passwordHash = sqlReqText(rows, cols, "password_hash")?,
    role = sqlReqText(rows, cols, "role")?,
    createdAt = sqlReqInt(rows, cols, "created_at")?,
    updatedAt = sqlReqInt(rows, cols, "updated_at")?,
  }
}

fn users(db: Data): Query<User> {
  return find<User>(db, "users", userDesc().fields, userMapper)
}

@table class Tag {
  @id
  id: i64
  name: string
}

fn tagPlaceholder(): Tag {
  return Tag{ id = 0, name = "" }
}

fn tagDesc(): TableDesc {
  return TableDesc{
    table = "tags", fields = tagPlaceholder().tableDescriptor(), classAttrs = []AttrDesc(0),
  }
}

fn tagMapper(rows: Rows): Tag! {
  let cols = rows.columns()
  return Tag{ id = sqlReqInt(rows, cols, "id")?, name = sqlReqText(rows, cols, "name")? }
}

fn tags(db: Data): Query<Tag> {
  return find<Tag>(db, "tags", tagDesc().fields, tagMapper)
}

fn parseId(s: string): i64! {
  return parseInt(s)?
}
```

## belongsTo and manyToMany, declared on Article together

```bit
import { ManyToManyDesc, RelationLoader, belongsTo, manyToManyLoader, withRelations } from "orm"

@table @timestamps class Article {
  @id
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

fn authorPlaceholder(): User {
  return User{
    id = 0, username = "", email = "", passwordHash = "", role = "", createdAt = 0, updatedAt = 0,
  }
}

fn articlePlaceholder(): Article {
  return Article{
    id = 0, title = "", slug = "", body = "", authorId = 0, author = authorPlaceholder(),
    createdAt = 0, updatedAt = 0,
  }
}

fn articleDesc(): TableDesc {
  return TableDesc{
    table = "articles", fields = articlePlaceholder().tableDescriptor(), classAttrs = []AttrDesc(0),
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
    author = authorPlaceholder(),
    createdAt = sqlReqInt(rows, cols, "created_at")?,
    updatedAt = sqlReqInt(rows, cols, "updated_at")?,
  }
  a.markPersisted(true)
  return a
}

fn articleTagsDesc(): ManyToManyDesc {
  return ManyToManyDesc{
    joinTable = "article_tags", ownerColumn = "article_id", ownerTable = "articles",
    ownerIdColumn = "id", targetColumn = "tag_id", targetTable = "tags", targetIdColumn = "id",
  }
}

fn authorLoader(): RelationLoader<Article> {
  return belongsTo<Article, User>(
    (a) => a.authorId,
    (db) => users(db),
    "id",
    (u) => u.id,
    (a, u) => {
      a.author = u
    },
  )
}

fn tagsLoader(): RelationLoader<Article> {
  return manyToManyLoader<Article, Tag>((a) => a.id, articleTagsDesc(), tagMapper, (a, ts) => {
    a.tags = ts
  })
}

fn articles(db: Data): Query<Article> {
  return withRelations(
    find<Article>(db, "articles", articleDesc().fields, articleMapper),
    map<string, RelationLoader<Article>>{ "author": authorLoader(), "tags": tagsLoader() },
  )
}

fn findArticleById(db: Data, id: i64): Article! {
  return articles(db).with("author").with("tags").where("id", Value.Int(id)).oneOrFail()?
}
```

`@belongsTo("authorId")` names the foreign key already on `Article` - the
owning side. `@manyToMany("article_tags")` names the join table part 7
already migrated - both attributes are metadata the compiler keeps; Bit has
no reflection to read them back at runtime, which is why `articleTagsDesc()`
hand-writes the same table and column names for `tagsLoader` to use.

Neither `author: User` nor `tags: []Tag` has a zero value in Bit that means
"not loaded yet" - a class reference and a slice both need a real value, so
`articlePlaceholder`/`articleMapper` fill them in even before `with()` runs.
A `with()`-requested loader's `assign` overwrites the placeholder exactly
like any other field write.

`authorLoader` and `tagsLoader` are the part that isn't automatic. Bit has
no reflection - no way to read or write `Article.author`/`Article.tags` by
the strings `"author"`/`"tags"` - so you tell each loader how: read the
parent's key or the child's foreign key, build a fresh unfiltered query,
name the matching column on the other side, and write the result back.
Both batch it - one query total per relation, never one per row.

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

fn showArticle(c: Ctx, db: Data): Res! {
  let id = parseId(c.param("id")) catch _ {
    fail badRequest("id must be an integer")
  }
  let a = findArticleById(db, id) catch _ {
    fail notFound("no article with that id")
  }
  return c.json(toArticleView(a))
}
```

## The sharp edge: `save()` can no longer write `Article` directly

Add a relation field to a class, and `save()` breaks. Its generic `INSERT`
writes every field `tableDescriptor()` knows about, `author` and `tags`
included, and neither is a real column - there is nothing to bind a `User`
or a `[]Tag` to. This is a real `pkg/orm` gap (filed as #6115), not
something to work around quietly. Inkwell writes an article and its tags
through one explicit `INSERT` naming only the real columns, then attaches
the tags:

```bit
import { ServerDialect, UniqueViolation, attach, classify } from "orm"
import { minLen } from "web"
import { join, newBuilder } from "std/strings"
import { now } from "std/time"

export @json class CreateArticleInput {
  @minLen(1)
  title: string

  body: string

  authorId: i64

  tags: []string
}

fn findTagByName(db: Data, name: string): Tag! {
  return tags(db).where("name", Value.Text(name)).oneOrFail()?
}

// `db.bit`'s own helper for the id-column issue #6101 fixes: name the real
// columns by hand, read the generated `id` back through `returning id`,
// never touch `tableDescriptor()`'s full field list.
fn insertGeneratedId(db: Data, targetTable: string, cols: []string, args: []Value): i64! {
  let marks = []string(0)
  let i = 0
  while (i < len(args)) {
    marks = append(marks, "$${i + 1}")
    i = i + 1
  }
  let sqlText = "insert into ${targetTable} (${join(cols, ", ")}) values (${join(marks, ", ")}) returning id"
  let rows = db.query(sqlText, args)?
  defer rows.close()
  if (!rows.next()?) {
    fail newError("insertGeneratedId: insert into '${targetTable}' returned no row")
  }
  return sqlReqInt(rows, rows.columns(), "id")?
}

fn findOrCreateTag(db: Data, name: string): Tag! {
  return findTagByName(db, name) catch _ {
    insertGeneratedId(db, "tags", ["name"], [Value.Text(name)]) catch e {
      let cause = classify(e, "tags")
      let (_, ok) = cause.(UniqueViolation)
      if (ok) {
        return findTagByName(db, name)?
      }
      fail cause
    }
    return findTagByName(db, name)?
  }
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

fn attachTagNames(db: Data, articleId: i64, names: []string): ()! {
  let ids = []i64(0)
  for name of names {
    let t = findOrCreateTag(db, name)?
    ids = append(ids, t.id)
  }
  if (len(ids) == 0) {
    return
  }
  attach(db, articleTagsDesc(), articleId, ids, ServerDialect.Postgres)?
}

fn createArticle(c: Ctx, db: Data): Res! {
  let input = c.body<CreateArticleInput>()?
  let stamp = now().ns
  let cols = ["title", "slug", "body", "author_id", "created_at", "updated_at"]
  let args = [
    Value.Text(input.title), Value.Text(slugify(input.title)), Value.Text(input.body),
    Value.Int(input.authorId), Value.Int(stamp), Value.Int(stamp),
  ]
  let newId = insertGeneratedId(db, "articles", cols, args)?
  attachTagNames(db, newId, input.tags)?
  return c.created("${newId}")
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

`attach` is idempotent - it inserts the pairs that aren't already there, one
statement, and calling it twice with the same tag ids is safe:

```text
insert into article_tags (article_id, tag_id) values ($1, $2), ($3, $4)
  on conflict (article_id, tag_id) do nothing
```

`insertGeneratedId` sidesteps #6115 the same way `update<Article>(db,
"articles", articleDesc().fields).where(...).set("title",
...).set("body", ...).run()` does for an edit - the query-builder path
[Patch](../../orm/docs/patch.md) covers: both name each column by hand and
never try to write `author`/`tags`.

## What we built

`GET /articles/:id` eager-loads an article's author and tags in three
queries through `with("author").with("tags")`, and `POST /articles` creates
an article and attaches its tags - one statement each, not yet wrapped in a
single transaction, which part 15 adds. `ArticleView` now carries
`authorUsername` and `tags` alongside what part 8 built.

Specification: [Relations](../../orm/docs/relation.md), [Many-to-many
relations](../../orm/docs/manytomany.md), [Patch](../../orm/docs/patch.md).

Previous: [Querying and CRUD](08-querying-and-crud.md).
Next: Part 10, Registering users and hashing passwords.
