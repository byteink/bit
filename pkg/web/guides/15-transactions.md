<!-- doctest: deps orm -->
# Transactions

Creating an article in Inkwell is not one write, it is several: insert the
article row, then for each tag name the client sent, find or create that
tag, then attach it to the article. If the process crashes, the database
connection drops, or one of those tag inserts fails halfway through, a
naive implementation leaves an article in the table with only some of its
tags attached, or worse, an article with none. Nothing about the request
told the client that happened, because from the client's side the request
either succeeded or it did not.

A transaction is the fix: every statement inside it commits together, or
none of them do.

## The only way to run one

`std/sql` gives you exactly one way to run a transaction: a closure.

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
than merely easy to avoid. `tx(pool, f)` is the same thing for a block that
returns nothing; `txValue` is for a block whose result you want, like a new
row's id.

## Inkwell's transaction

`POST /articles` is Inkwell's one transactional endpoint: insert the
article, then find-or-create and attach every tag the client named, all
inside one `pool.txValue` call.

```bit
import { Ctx, Res } from "web"
import { Data, attach, ManyToManyDesc, ServerDialect } from "orm"
import { join } from "std/strings"

// The `article_tags` join table's shape, shared with the tags helper below.
fn articleTagsDesc(): ManyToManyDesc {
  return ManyToManyDesc{
    joinTable = "article_tags", ownerColumn = "article_id", ownerTable = "articles",
    ownerIdColumn = "id", targetColumn = "tag_id", targetTable = "tags", targetIdColumn = "id",
  }
}

// Inserts a row and reads its generated id back with `returning id`, in
// one statement. See part 7, "Tables and migrations with pkg/orm", for the
// migration that makes `id` a generated identity column.
fn insertGeneratedId(db: Data, table: string, cols: []string, args: []Value): i64! {
  let marks = []string(0)
  let i = 0
  while (i < len(args)) {
    marks = append(marks, "$${i + 1}")
    i = i + 1
  }
  let sqlText = "insert into ${table} (${join(cols, ", ")}) values (${join(marks, ", ")}) returning id"
  let rows = db.query(sqlText, args)?
  defer rows.close()
  if (!rows.next()?) {
    fail newError("insertGeneratedId: insert into '${table}' returned no row")
  }
  return sqlReqInt(rows, rows.columns(), "id")?
}

fn findOrCreateTag(db: Data, name: string): i64! {
  let rows = db.query("select id from tags where name = $1", [Value.Text(name)])?
  defer rows.close()
  if (rows.next()?) {
    return sqlReqInt(rows, rows.columns(), "id")?
  }
  return insertGeneratedId(db, "tags", ["name"], [Value.Text(name)])?
}

fn attachTagNames(db: Data, articleId: i64, names: []string): ()! {
  let ids = []i64(0)
  for name of names {
    let id = findOrCreateTag(db, name)?
    ids = append(ids, id)
  }
  if (len(ids) == 0) {
    return
  }
  attach(db, articleTagsDesc(), articleId, ids, ServerDialect.Postgres)?
}

// The real `insertArticle` (articles.bit) also derives a unique slug from
// the title (part 8, "Querying and CRUD") - omitted here since it has
// nothing to do with the transaction.
fn insertArticle(db: Data, authorId: i64, title: string, body: string, tags: []string): i64! {
  let cols = ["title", "body", "author_id"]
  let args = [Value.Text(title), Value.Text(body), Value.Int(authorId)]
  let newId = insertGeneratedId(db, "articles", cols, args)?
  attachTagNames(db, newId, tags)?
  return newId
}

fn createArticle(
  c: Ctx,
  pool: Pool,
  authorId: i64,
  title: string,
  body: string,
  tags: []string,
): Res! {
  let newId = pool.txValue<i64>((db) => insertArticle(db, authorId, title, body, tags))?
  return c.createdUrl("/articles/${newId}")
}
```

`db: Data` is the transaction handle, not the pool: `insertArticle` and
everything it calls run on the one connection `txValue` opened, so the
article insert and every tag insert and attach are part of the same
transaction with no extra plumbing to wire them together.

## Proving it

Four articles already exist. Send one more, naming a tag name over 60
characters, which is longer than the `tags.name` column allows:

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
