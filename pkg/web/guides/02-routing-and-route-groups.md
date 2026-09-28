# Routing and route groups

<!-- doctest: per-block -->

One route is not an API. Inkwell needs articles: a list, and one article by
id. You could register both directly on the app, but a real service has
users, tags and comments too, each with its own set of routes - registering
every one at the top level, with its full path spelled out, gets unreadable
fast. This part adds a second route with a path parameter, then groups both
article routes under one prefix.

The examples below use an in-memory list of articles, seeded with one entry,
so you can see routing work before Inkwell has a database. [Chapter
19](06-connecting-to-postgresql.md) replaces it with a real PostgreSQL
connection; the shape of the code (a store you query and pass into your
routes) stays the same.

## A path parameter

A segment in a route pattern starting with `:` captures one path component
under that name. `c.param(name)` reads it back:

```bit
import { App, Config, Ctx, Res, notFound } from "web"
import { Json, JsonEntry } from "std/json"
import { parseInt } from "std/strings"

@json class Article {
  id: i64,
  title: string,
  slug: string,
}

fn seedArticles(): []Article {
  return []Article{
    Article{ id = 1, title = "Hello, Bit", slug = "hello-bit" },
  }
}

fn showArticle(c: Ctx): Res! {
  let id = parseInt(c.param("id")) catch _ {
    fail notFound("no article with that id")
  }
  for a of seedArticles() {
    if (a.id == id) {
      return c.json(a)
    }
  }
  fail notFound("no article with that id")
}

fn main(): ()! {
  let app = App(Config{ secret = "dev-secret-change-me" })
  app.get("/articles/:id", showArticle)
  app.listen()?
}
```

Run it and ask for the seeded article, then for one that does not exist:

```text
$ curl -i http://127.0.0.1:8080/articles/1
HTTP/1.1 200 OK
Content-Length: 48
Content-Type: application/json
Connection: keep-alive

{"id":1,"title":"Hello, Bit","slug":"hello-bit"}
```

```text
$ curl -i http://127.0.0.1:8080/articles/99
HTTP/1.1 404 Not Found
Content-Length: 69
Content-Type: application/json
Connection: keep-alive

{"status":404,"error":"Not Found","detail":"no article with that id"}
```

`notFound(msg)` fails with an `HttpError`; the framework turns an unhandled
one into the JSON body above rather than the route writing it by hand. [Part
4](04-errors-and-consistent-responses.md) covers the rest of that mapping.

## Grouping routes under a prefix

`app.group(prefix)` returns a `Group` that shares the app's router: register
on it and every route gets the prefix for free. Here is the list route
added, both article routes moved onto an `/articles` group:

```bit
import { App, Config, Ctx, Res, notFound } from "web"
import { Json, JsonEntry } from "std/json"
import { parseInt } from "std/strings"

@json class Article {
  id: i64,
  title: string,
  slug: string,
}

fn seedArticles(): []Article {
  return []Article{
    Article{ id = 1, title = "Hello, Bit", slug = "hello-bit" },
    Article{ id = 2, title = "Routing in pkg/web", slug = "routing-in-pkg-web" },
  }
}

fn listArticles(c: Ctx): Res! {
  return c.jsonList(seedArticles())
}

fn showArticle(c: Ctx): Res! {
  let id = parseInt(c.param("id")) catch _ {
    fail notFound("no article with that id")
  }
  for a of seedArticles() {
    if (a.id == id) {
      return c.json(a)
    }
  }
  fail notFound("no article with that id")
}

fn mountArticles(app: App) {
  let group = app.group("/articles")
  group.get("/", listArticles)
  group.get("/:id", showArticle)
}

fn health(c: Ctx): Res! {
  return c.text("ok")
}

fn main(): ()! {
  let app = App(Config{ secret = "dev-secret-change-me" })
  app.get("/health", health)
  mountArticles(app)
  app.listen()?
}
```

The list route is registered as `"/"` under the group, which is
`/articles` with nothing after it - not `/articles/` with a trailing slash,
which instead matches the `:id` group route with an empty capture:

```text
$ curl -i http://127.0.0.1:8080/articles
HTTP/1.1 200 OK
Content-Length: 116
Content-Type: application/json
Connection: keep-alive

[{"id":1,"title":"Hello, Bit","slug":"hello-bit"},{"id":2,"title":"Routing in pkg/web","slug":"routing-in-pkg-web"}]
```

```text
$ curl -i http://127.0.0.1:8080/articles/2
HTTP/1.1 200 OK
Content-Length: 65
Content-Type: application/json
Connection: keep-alive

{"id":2,"title":"Routing in pkg/web","slug":"routing-in-pkg-web"}
```

`mountArticles(app)` keeps every article route in one function, which is
where Inkwell's real layout is headed: by the time this part of the Book
adds users, tags and comments, each resource gets its own `mount` function
and its own file.

## What we built

Inkwell now answers `GET /articles` with a list and `GET /articles/:id`
with one article, both grouped under `/articles`, backed by an in-memory
seed list. You used a route parameter, `app.group`, and `c.jsonList`.

Next: [Chapter 16, request bodies and validation](03-request-bodies-and-validation.md),
where you add `POST /articles` and reject a bad request before it reaches
your code.
