# Part 3: Request bodies and validation

<!-- doctest: per-block -->

Readers of Inkwell need to write articles, not just read them. That means
accepting a JSON body, and it means two different kinds of "no": a body
that does not have the shape you asked for, and a body that has the right
shape but a value you will not accept, like an empty title. `pkg/web`
answers these with two different status codes, and this part builds
`POST /articles` around both.

## An input type, not the entity

Do not bind the request body straight into `Article`. A client could then
post `{"title":"x","id":999}` and pick its own id. Instead you write a
separate type carrying only what a client is allowed to set:

```bit
import { App, Config, Ctx, Res, minLen, notFound } from "web"
import { Json, JsonEntry } from "std/json"
import { newBuilder, parseInt } from "std/strings"

@json class Article {
  id: i64,
  title: string,
  slug: string,
  body: string,
}

// A stable, lowercase, hyphenated slug: only a-z and 0-9 survive, every
// other byte becomes one dash, and runs of dashes collapse to one.
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

class ArticleStore {
  items: []Article
  nextId: i64

  init() {
    this.items = []Article{
      Article{ id = 1, title = "Hello, Bit", slug = "hello-bit", body = "Our first article." },
    }
    this.nextId = 2
  }

  export list(): []Article {
    return this.items
  }

  export find(id: i64): Article! {
    for a of this.items {
      if (a.id == id) {
        return a
      }
    }
    fail notFound("no article with that id")
  }

  export create(title: string, body: string): Article {
    let a = Article{ id = this.nextId, title = title, slug = slugify(title), body = body }
    this.items = append(this.items, a)
    this.nextId = this.nextId + 1
    return a
  }
}

export @json class CreateArticleInput {
  @minLen(1)
  title: string

  body: string
}

fn createArticle(c: Ctx, store: ArticleStore): Res! {
  let input = c.body<CreateArticleInput>()?
  let a = store.create(input.title, input.body)
  return c.createdUrl("/articles/${a.id}")
}

fn listArticles(c: Ctx, store: ArticleStore): Res! {
  return c.jsonList(store.list())
}

fn showArticle(c: Ctx, store: ArticleStore): Res! {
  let id = parseInt(c.param("id")) catch _ {
    fail notFound("no article with that id")
  }
  let a = store.find(id)?
  return c.json(a)
}

fn mountArticles(app: App, store: ArticleStore) {
  let group = app.group("/articles")
  group.get("/", (c) => listArticles(c, store))
  group.get("/:id", (c) => showArticle(c, store))
  group.post("/", (c) => createArticle(c, store))
}

fn main(): ()! {
  let app = App(Config{ secret = "dev-secret-change-me" })
  let store = ArticleStore()
  mountArticles(app, store)
  app.listen()?
}
```

`CreateArticleInput` has no `id` and no `slug` - `store.create` computes
the slug itself, the same way Inkwell's real version does once it writes to
PostgreSQL. `c.body<CreateArticleInput>()?` parses the request body into
that type; the type argument is never optional, since it is the only thing
the compiler has to build the value from.

This example's `ArticleStore` is a single in-process list, useful for
seeing validation work end to end before the course has a database - it is
not safe for two requests writing at once, which is exactly the gap [part
6](06-connecting-to-postgresql.md) closes with a real connection pool.

## A request that does not parse

Post a body with a field `CreateArticleInput` does not declare:

```text
$ curl -i -X POST http://127.0.0.1:8080/articles \
    -H "Content-Type: application/json" \
    -d '{"title":"x","body":"y","published":true}'
HTTP/1.1 400 Bad Request
Content-Length: 54
Content-Type: application/json
Connection: keep-alive

{"status":400,"error":"json: unknown key 'published'"}
```

This is a `400`: the shape is wrong. `pkg/web` rejects an unknown field by
default rather than dropping it, because a client cannot tell "ignored"
from "accepted" - see [The request](../docs/request.md#unknown-fields-are-a-400-by-default)
for the field-by-field error table.

## A request that parses but fails validation

`@minLen(1)` on `title` is a value rule, checked once the body has the
right shape:

```text
$ curl -i -X POST http://127.0.0.1:8080/articles \
    -H "Content-Type: application/json" \
    -d '{"title":"","body":"x"}'
HTTP/1.1 422 Unprocessable Content
Content-Length: 63
Content-Type: application/json
Connection: keep-alive

{"status":422,"error":"title: must be at least 1 character(s)"}
```

A `422` means the opposite of a `400`: the shape was fine, the value was
not. That distinction is what lets a client show "title cannot be empty"
next to the title field, instead of a generic parse error.

## A request that succeeds

```text
$ curl -i -X POST http://127.0.0.1:8080/articles \
    -H "Content-Type: application/json" \
    -d '{"title":"Routing and route groups","body":"How pkg/web organizes routes."}'
HTTP/1.1 201 Created
Content-Length: 0
Content-Type: text/plain; charset=utf-8
Connection: keep-alive
Location: /articles/2
```

`c.createdUrl(target)` answers `201` with no body and a `Location` header
naming the new resource - the client's next request is `GET` on that URL:

```text
$ curl -i http://127.0.0.1:8080/articles/2
HTTP/1.1 200 OK
Content-Length: 116
Content-Type: application/json
Connection: keep-alive

{"id":2,"title":"Routing and route groups","slug":"routing-and-route-groups","body":"How pkg/web organizes routes."}
```

## What we built

`POST /articles` now validates its input in two layers: a `400` for a body
shaped wrong, a `422` for a value that fails a rule, and a `201` with a
`Location` header on success. You used `c.body<T>()`, `@minLen`, and
`c.createdUrl`.

Next: [Part 4, errors and consistent responses](04-errors-and-consistent-responses.md),
where every route's failures, not only validation's, get one shape.
