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
import { App, Config, Ctx, Res, OpenApiInfo } from "web"
import { env } from "std/os"

fn showArticle(c: Ctx): Res! {
  return c.text("article ${c.param("id")}")
}

fn mount(app: App) {
  app.get("/articles/:id", showArticle)
  app.get("/openapi.json", (c) => c.json(app.openApi(OpenApiInfo{
    title = "Inkwell",
    version = "1.0.0",
    description = "A blogging API",
  })?))
}

fn main(): ()! {
  let app = App(Config{ secret = env("APP_SECRET") })
  mount(app)
  app.listen()?
}
```

`GET /articles/:id` becomes the path `/articles/{id}` with one required
`path` parameter named `id`. `openApi()` fails if the router is not frozen
yet, so the `/openapi.json` handler above calls it lazily, inside the
closure: by the time a request reaches it, `listen()` has already frozen the
route table - calling it eagerly, before `listen()`, would panic instead.

## Request and response bodies, from a real instance

A route's body and response types live inside its handler closure, where
`openApi()` cannot see them. `.requestBody()` and `.responds()` on the
`Route` a registration returns close that gap - not with a hand-written
schema, but with a real instance of the `@json` class the route actually
uses. The schema comes from that instance's own `toJson()`, the same
synthesized method the class's wire format is built from, so a field added
to the class changes what the document says the next time you build:

```bit
import { App, Config, Ctx, Res, notFound } from "web"
import { env } from "std/os"

@json class Article {
  id: string,
  title: string,
}

@json class NewArticle {
  title: string,
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
  create.requestBody(NewArticle{ title = "" })
  create.responds(201, Article{ id = "", title = "" })
  let show = app.get("/articles/:id", showArticle)
  show.responds(200, Article{ id = "", title = "" })
  show.responds(404, ErrorBody{ message = "" })
}

fn main(): ()! {
  let app = App(Config{ secret = env("APP_SECRET") })
  mount(app)
  // ...
}
```

The instance you pass never leaves this process - it exists only for its
`toJson()` output, which `openApi()` walks to infer each field's shape
(`"title": {"type": "string"}` and so on). A route that calls neither method
documents a bare `200` with no schema, which is still a valid document, just
an uninformative one.

## Serving it

The example above mounts the document at `/openapi.json`, but the path is
yours - `openApi()` returns a `Json` value, and `c.json(doc)` serves it like
any other response. Point Swagger UI, Redoc, or any OpenAPI 3.1 client at
that URL.

## Sharp edges

An empty array has no element to infer a type from - `.requestBody()` with a
sample whose list field is `[]string(0)` documents that field as
`{"type": "array", "items": {}}` rather than `{"type": "array", "items":
{"type": "string"}}`. Pass a sample with at least one element in every list
field to get a precise `items` schema.

Every key a sample's `toJson()` produces is marked `required`, because
`@json` always emits every field it declares - an absent `Option<T>` still
writes its key as `null` rather than omitting it, so the document is exactly
as precise as the class's own encoder.

Next: [Envelope](envelope.md), for giving every response - success and
failure alike - one shape.
