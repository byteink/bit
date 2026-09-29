<!-- doctest: deps orm -->
# Pagination, filtering and sorting

`GET /articles` answers with every article in the database, in whatever
order Postgres feels like returning them. That works for a handful of rows
in development and stops working the day a real blog has a thousand
articles: the response grows without bound, the client has no way to ask
for one writer's posts, and there is no way to ask for the oldest first.

Three things fix that: a page size and offset, a filter, and a sort
direction, all read from the query string.

## Reading and clamping query parameters

`c.query(name)` reads a query parameter as a string, or `""` if the client
did not send it. Nothing forces a client to send a sane `limit`, so Inkwell
clamps whatever arrives before it reaches the database:

```bit
import { parseInt } from "std/strings"
import { Json } from "std/json"

const defaultLimit = 20
const maxLimit = 100

fn clampLimit(raw: string): int {
  let n = parseInt(raw) catch _ {
    return defaultLimit
  }
  if (n < 1) {
    return defaultLimit
  }
  if (n > maxLimit) {
    return maxLimit
  }
  return n
}

fn pageNumber(raw: string): int {
  let n = parseInt(raw) catch _ {
    return 1
  }
  if (n < 1) {
    return 1
  }
  return n
}
```

An unparseable or missing value falls back to a default rather than failing
the request: a page size is a preference, not something worth a 400 over.
`maxLimit` exists so a client asking for `limit=1000000` still gets a
bounded query, not one that reads the whole table.

## The listing itself

Inkwell's `Article` table backs a `Repo<Article>` (see part 8, "Querying and
CRUD", for how `db.table<Article>()` builds one). The list route only needs
a handful of columns, so it maps each row to a smaller `ArticleListItem`
view rather than sending the full entity:

```bit
import { Ctx, Res, page } from "web"
import { Db, Dir, Repo } from "orm"

// The fields a listing needs. The real `Article` also carries its author
// and tags relations (part 9, "Relationships") - this page only needs
// what `toListItem` reads below.
@table("articles") class Article {
  id: i64,
  title: string,
  slug: string,
  authorId: i64,
  createdAt: i64,
}

@json class ArticleListItem {
  id: i64,
  title: string,
  slug: string,
  authorId: i64,
  createdAt: i64,
}

fn toListItem(a: Article): ArticleListItem {
  return ArticleListItem{
    id = a.id, title = a.title, slug = a.slug, authorId = a.authorId, createdAt = a.createdAt,
  }
}
```

## Filtering by author, sorting by date

`Repo.where` narrows the rows; `Repo.orderBy` picks the direction. Both
are applied before the count and the page window, so `total` reflects the
filtered set, not the whole table:

```bit
fn sortDir(raw: string): Dir {
  if (raw == "oldest") {
    return Dir.Asc
  }
  return Dir.Desc
}

fn filteredArticles(db: Db, c: Ctx): Repo<Article> {
  let q = db.table<Article>().orderBy("createdAt", sortDir(c.query("sort")))
  let authorRaw = c.query("author")
  if (len(authorRaw) == 0) {
    return q
  }
  let authorId = parseInt(authorRaw) catch _ {
    return q
  }
  return q.where("authorId", authorId)
}

fn listArticles(c: Ctx, db: Db): Res! {
  let limit = clampLimit(c.query("limit"))
  let pageNum = pageNumber(c.query("page"))
  let q = filteredArticles(db, c)
  let total = q.count()?
  let rows = q.limit(limit).offset((pageNum - 1) * limit).all()?
  let out = []ArticleListItem(0)
  for a of rows {
    out = append(out, toListItem(a))
  }
  return page(out, total, limit, "${pageNum + 1}")
}
```

`Repo<T>.count()` runs `select count(*)` over the same `where()` the chain
built, ignoring `orderBy`/`limit`/`offset` - exactly the number `total`
needs, from the filtered set rather than the whole table.

`sort=newest` (the default) and `sort=oldest` are the only two directions
Inkwell exposes; there is no free-form `sort=title` because an unindexed
column sort is a query someone will ask you to explain in a postmortem
someday. `page()` (from `pkg/web`, see part 4, "Errors and consistent
responses", for how `envelope()` renders its result) wraps the items, the
total row count, the limit that was used, and a cursor for the next page
into one shape.

## Trying it

Four articles exist: two by user 1, two by user 2. Ask for two at a time:

```
$ curl -s "http://127.0.0.1:8080/articles?limit=2&page=1"
{
  "data": [
    { "id": 4, "title": "Filtering and sorting lists", "slug": "filtering-and-sorting-lists-f36c1a8b", "authorId": 2, "createdAt": 1790538920604367000 },
    { "id": 3, "title": "Transactions done right", "slug": "transactions-done-right-f7dcff42", "authorId": 2, "createdAt": 1790538916593926000 }
  ],
  "meta": { "total": 4, "limit": 2, "cursor": "2" }
}

$ curl -s "http://127.0.0.1:8080/articles?limit=2&page=2"
{"data":[{"id":2,"title":"Writing your first middleware","slug":"writing-your-first-middleware-5cf2890f","authorId":1,"createdAt":1790538916470255000},{"id":1,"title":"Getting started with Bit","slug":"getting-started-with-bit-76b48683","authorId":1,"createdAt":1790538916281701000}],"meta":{"total":4,"limit":2,"cursor":"3"}}
```

Filter to one author, and `total` drops to that author's own count:

```
$ curl -s "http://127.0.0.1:8080/articles?author=1"
{"data":[{"id":2, ...},{"id":1, ...}],"meta":{"total":2,"limit":20,"cursor":"2"}}
```

Ask for the oldest first instead of the newest:

```
$ curl -s "http://127.0.0.1:8080/articles?sort=oldest&limit=1"
{"data":[{"id":1,"title":"Getting started with Bit", ...}],"meta":{"total":4,"limit":1,"cursor":"2"}}
```

## What we built

`GET /articles` now answers a bounded page instead of the whole table,
narrows to one author on request, and orders by either the newest or the
oldest first, all from three query parameters a client controls.

Previous: [Middleware](13-middleware.md).
Next: [Transactions](15-transactions.md).
