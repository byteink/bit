<!-- doctest: deps orm -->
# Transactions

Creating an article in Inkwell is not one write, it is several: insert the
article row, then for each tag name the client sent, find or create that
tag, then link it to the article. If the process crashes, the database
connection drops, or one of those tag inserts fails halfway through, a
naive implementation leaves an article in the table with only some of its
tags linked, or worse, an article with none. Nothing about the request
told the client that happened, because from the client's side the request
either succeeded or it did not.

A transaction is the fix: every statement inside it commits together, or
none of them do.

## The only way to run one

`std/sql` gives you exactly one way to run a transaction that hands a value
back: a closure.

```bit
import { Pool, Value, sqlReqInt } from "std/sql"

fn tagCount(pool: Pool): i64! {
  return pool.txValue<i64>((t) => {
    let rows = t.query("select count(*) as n from tags", []Value(0))?
    defer rows.close()
    rows.next()?
    return sqlReqInt(rows, rows.columns(), "n")?
  })?
}
```

`pool.txValue<T>(f)` opens a transaction, runs `f` on the one connection it
pinned for that transaction, and ends it itself: `COMMIT` if `f` returns
normally, `ROLLBACK` if it fails or panics. There is no `begin()` paired
with a `commit()` you have to remember to call, and that is deliberate: a
`?` between a `begin()` and a `commit()` returns early and skips the
rollback, leaving the transaction open and the connection never given back
to the pool. The closure form makes that mistake impossible to write rather
than merely easy to avoid.

`pkg/orm`'s own `db.tx((tx) => { ... })?` is the same closure shape, over
`TxHandle` instead of a raw `Data` handle: every `tx.table<T>()` inside the
block runs on that one pinned connection, so ordinary repository calls -
`insert`, `link`, `find` - compose into a transaction with no extra
plumbing. Unlike `std/sql`'s `txValue<T>`, `db.tx` never hands a value back
out of the closure (rule 6: all or nothing, nothing more) - Inkwell's own
transaction below reads the value it needs out of a slice it declared
before the closure and wrote into from inside it.

## Inkwell's transaction

`POST /articles` is Inkwell's one transactional endpoint: insert the
article, then find-or-create and link every tag the client named, all
inside one `db.tx` call.

```bit
import { Ctx, Res } from "web"
import { Db, TxHandle } from "orm"
import { isSome, unwrap } from "std/core"

// The `author` side (part 9, "Relationships") is left out
// here - this page's own transaction never reads it back, and a plain
// `@manyToMany` field is all `Article` needs to be a full `Tabled` class.
@table class Tag {
  id: i64,
  name: string,
}

@table class Article {
  id: i64
  title: string
  body: string
  authorId: i64
  @manyToMany("article_tags")
  tags: []Tag
}

fn findOrCreateTag(tx: TxHandle, name: string): Tag! {
  let tags = tx.table<Tag>()
  let found = tags.where("name", name).first()?
  if (isSome(found)) {
    return unwrap(found)
  }
  return tags.insert(Tag{ id = 0, name = name })?
}

// The real `insertArticle` (articles.bit) also derives a unique slug from
// the title (part 8, "Querying and CRUD") - omitted here since it has
// nothing to do with the transaction.
fn insertArticle(
  tx: TxHandle,
  authorId: i64,
  title: string,
  body: string,
  tagNames: []string,
): Article! {
  let articles = tx.table<Article>()
  let a = articles.insert(
    Article{ id = 0, title = title, body = body, authorId = authorId, tags = []Tag(0) },
  )?
  let ids = []i64(0)
  for name of tagNames {
    let t = findOrCreateTag(tx, name)?
    ids = append(ids, t.id)
  }
  if (len(ids) > 0) {
    articles.link(a, "tags", ids)?
  }
  return a
}

fn createArticle(
  c: Ctx,
  db: Db,
  authorId: i64,
  title: string,
  body: string,
  tagNames: []string,
): Res! {
  let newId = []i64{ 0 }
  db.tx((tx) => {
    let a = insertArticle(tx, authorId, title, body, tagNames)?
    newId[0] = a.id
  })?
  return c.createdUrl("/articles/${newId[0]}")
}
```

`tx: TxHandle` is the transaction handle, not `db`: `insertArticle` and
everything it calls run on the one connection `db.tx` opened, so the
article insert and every tag insert and link are part of the same
transaction with no extra plumbing to wire them together.

## Proving it

Four articles already exist. Send one more, naming a tag name over 60
characters, which is longer than the `tag.name` column allows:

```
$ curl -s "http://127.0.0.1:8080/articles?limit=1" | grep -o '"total":[0-9]*'
"total":4

$ curl -s -i -b ada.cookies -X POST http://127.0.0.1:8080/articles \
    -H "Content-Type: application/json" \
    -d '{"title":"This one should not be saved","body":"rollback proof","tags":["ok","xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"]}'
HTTP/1.1 500 Internal Server Error
{"error":{"code":"internal_error","message":"Internal Server Error"}}

$ curl -s "http://127.0.0.1:8080/articles?limit=1" | grep -o '"total":[0-9]*'
"total":4
```

The article insert happens first, before the failing tag insert ever runs,
so on a system without transactions it would be sitting in the table right
now. It is not: `total` is unchanged. The `"ok"` tag, which was successfully
inserted moments before the long one failed, is gone too:

```
$ curl -s "http://127.0.0.1:8080/tags"
{"data":[{"id":1,"name":"bit"},{"id":2,"name":"tutorial"},{"id":3,"name":"web"},{"id":4,"name":"database"}]}
```

No `"ok"` anywhere in that list. Both the article and the tag rows were
written on the same connection, inside the same transaction, and the whole
thing rolled back together when one statement inside it failed.

## What we built

`POST /articles` now writes the article and every one of its tags as a
single unit: all of it lands, or none of it does, with no code anywhere
that has to remember to check.

Previous: [Pagination, filtering and sorting](14-pagination-filtering-and-sorting.md).
Next: [Testing the API](16-testing-the-api.md).
