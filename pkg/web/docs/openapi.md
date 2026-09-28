# OpenAPI documentation

<!-- doctest: per-block -->

A hand-written OpenAPI file is a second copy of your API, and it goes stale
the day someone adds a field and forgets the YAML. `App.openApi()` renders
the document from the routes your app actually registered, so the paths and
methods can never disagree with what the app serves.

## The paths and methods, for free

Every route you register - its method, its path, its `:param` segments -
already lives on the app. `openApi()` reads that table directly, so this
much of the document needs nothing from you:

```bit
import { App, Config, Ctx, Res, ReplyHandler, OpenApiInfo } from "web"
import { env } from "std/os"
import { jsonEncode } from "std/json"

fn showArticle(c: Ctx): Res! {
  return c.text("article ${c.param("id")}")
}

fn serveOpenApi(app: App): ReplyHandler {
  return (c) => {
    let doc = app.openApi(
      OpenApiInfo{
        title = "Inkwell",
        version = "1.0.0",
        description = "A blogging API",
      },
    )?
    return c.bytes(jsonEncode(doc), "application/json")
  }
}

fn mount(app: App) {
  app.get("/articles/:id", showArticle)
  app.get("/openapi.json", serveOpenApi(app))
}

fn main(): ()! {
  let app = App(Config{ secret = env("APP_SECRET") })
  mount(app)
  app.listen()?
}
```

`GET /articles/:id` becomes the path `/articles/{id}` with one required
`path` parameter named `id`. `openApi()` fails if the router is not frozen
yet, so `serveOpenApi`'s closure calls it lazily, inside the handler: by the
time a request reaches it, `listen()` has already frozen the route table -
calling it eagerly, before `listen()`, would panic instead.

## Request and response bodies, from the type itself

A route's body and response types live inside its handler closure, where
`openApi()` cannot see them. `.requestBody<T>()` and `.responds<T>(status)`
on the `Route` a registration returns close that gap. `T` is the `@json`
class the route actually uses - no sample value to build by hand, and no
schema to keep in sync yourself. A field added to the class changes what the
document says the next time you build:

```bit
import { App, Config, Ctx, Res, notFound, minLen } from "web"
import { env } from "std/os"
import { Json, JsonEntry } from "std/json"

@json class Article {
  id: string,
  title: string,
}

@json class NewArticle {
  @minLen(1)
  title: string
}

@json class ErrorBody {
  message: string,
}

fn createArticle(c: Ctx): Res! {
  let input = c.body<NewArticle>()?
  return c.json(Article{ id = "1", title = input.title }).status(201)
}

fn showArticle(c: Ctx): Res! {
  fail notFound("no article with that id")
}

fn mount(app: App) {
  let create = app.post("/articles", createArticle)
  create.requestBody<NewArticle>()
  create.responds<Article>(201)
  let show = app.get("/articles/:id", showArticle)
  show.responds<Article>(200)
  show.responds<ErrorBody>(404)
}

fn main(): ()! {
  let app = App(Config{ secret = env("APP_SECRET") })
  mount(app)
  // ...
}
```

A route that calls neither `.requestBody<T>()` nor `.responds<T>(status)`
documents a bare `200` with no schema, which is still a valid document,
just an uninformative one.

`NewArticle.title` carries `@minLen(1)`, one of `pkg/web`'s own request
validation rules (see [Request bodies](request.md)). `openApi()` maps a
rule with a matching JSON Schema keyword onto the field's own schema
fragment - `@minLen(1)` becomes `"minLength": 1` - so a client generated
from the document enforces the same rule your handler does. A rule with no
OpenAPI equivalent (an application's own hand-written validator, for
example) is left out of the document rather than guessed at.

## Serving it

The example above mounts the document at `/openapi.json`, but the path is
yours - `openApi()` returns a `Json` value, not a `Jsonable`, so it goes out
through `c.bytes(jsonEncode(doc), "application/json")` rather than
`c.json(...)`. Point Swagger UI, Redoc, or any OpenAPI 3.1 client at that
URL.

Next: [Envelope](envelope.md), for giving every response - success and
failure alike - one shape.
