<!-- doctest: per-block -->

# Errors and consistent responses

So far every Inkwell handler builds its own response by hand. Ask for an
article that does not exist and you get whatever the handler happens to
return: a panic, a bare `c.text("not found")` with no structure, or nothing
at all if you forgot the check. Two different mistakes should not turn into
two different response shapes, and a client should not have to guess whether
a route answers its errors with `c.text` or `c.json`.

`pkg/web` answers this with `HttpError`: a type that carries a status and a
client-safe message. Writing one is a decision that shows up in your diff,
not a config flag you set somewhere else. Everything that is not an
`HttpError` becomes a plain `500`, with the real message logged on the
server and never sent to the client.

## Step 1: fail with a status

Inkwell keeps its articles in memory for now (the real database arrives in
part 6). Here is a route that looks one up by id:

```bit
import { App, Config, Ctx, Res, notFound } from "web"
import { parseInt } from "std/strings"
import { Json } from "std/json"

@json class Article {
  id: int,
  title: string,
}

fn articles(): []Article {
  return [Article{ id = 1, title = "Hello, Inkwell" }]
}

fn findArticle(id: int): Article! {
  for a of articles() {
    if (a.id == id) {
      return a
    }
  }
  fail notFound("no article with that id")
}

fn showArticle(c: Ctx): Res! {
  let id = parseInt(c.param("id"))?
  let a = findArticle(id)?
  return c.json(a)
}

fn build(): App {
  let app = App(Config{ secret = "dev-secret" })
  app.get("/articles/:id", showArticle)
  return app
}

fn main(): ()! {
  build().listen()?
}
```

Run it and ask for the article that exists:

```
$ curl -s http://127.0.0.1:8080/articles/1
{"id":1,"title":"Hello, Inkwell"}
```

Now ask for one that does not:

```
$ curl -i -s http://127.0.0.1:8080/articles/9 | tail -1
{"status":404,"error":"Not Found","detail":"no article with that id"}
```

`fail notFound(...)` set the status to `404`, the body's `error` field to
the fixed phrase for that status, and `detail` to the message you passed -
the shape the framework builds for every `HttpError`. Nothing in
`showArticle` formatted that JSON by hand.

## Step 2: one shape for success and failure alike

`{"id":1,"title":"..."}` on success and `{"status":404,"error":"..."}` on
failure are two different envelopes for the same API. `envelope()` is a
middleware that gives every response, success or failure, one top-level
shape: `{"data": ...}` when the handler returned a value, `{"error": {...}}`
when it failed.

```bit
import { App, Config, Ctx, Res, envelope, notFound } from "web"
import { parseInt } from "std/strings"
import { Json } from "std/json"

@json class Article {
  id: int,
  title: string,
}

fn articles(): []Article {
  return [Article{ id = 1, title = "Hello, Inkwell" }]
}

fn findArticle(id: int): Article! {
  for a of articles() {
    if (a.id == id) {
      return a
    }
  }
  fail notFound("no article with that id")
}

fn showArticle(c: Ctx): Res! {
  let id = parseInt(c.param("id"))?
  let a = findArticle(id)?
  return c.json(a)
}

fn build(): App {
  let app = App(Config{ secret = "dev-secret" })
  app.use(envelope())
  app.get("/articles/:id", showArticle)
  return app
}

fn main(): ()! {
  build().listen()?
}
```

The same two requests now answer consistently:

```
$ curl -s http://127.0.0.1:8080/articles/1
{"data":{"id":1,"title":"Hello, Inkwell"}}

$ curl -s http://127.0.0.1:8080/articles/9
{"error":{"code":"not_found","message":"Not Found","detail":"no article with that id"}}
```

`envelope()` still reads the status from the same `HttpError` your handler
raised, and it still redacts an error that never opted in: a plain
`newError(...)` or a database driver's own error type maps to a `500` whose
message is a fixed string, never the original error, which stays server side
in the log. Inkwell mounts `envelope()` on the whole app in `main.bit`, and
every route from here on answers inside it.

## What we built

Inkwell's routes now fail with a status and a client-safe message instead of
building their own error text, and every response, success or failure,
shares one shape a client can parse without a special case per route.

Previous: [Request bodies and validation](03-request-bodies-and-validation.md)
Next: [Configuration](05-configuration.md)
