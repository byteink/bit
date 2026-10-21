# Generate the API document from its routes

A client author needs to know which Inkwell paths and methods exist.
Maintaining another route list in JSON invites drift whenever a handler
moves. Generate the document from the same app that serves the requests.

## Serve the real document

Start the [finished app](README.md#run-the-finished-app), then fetch its
root documentation route:

```sh
curl -i http://127.0.0.1:8080/openapi.json
```

The JSON has top-level `openapi`, `info` and `paths` fields. Its `paths`
include `/v1/articles/{id}` and the other mounted routes. There is no
`data` wrapper, even though ordinary Inkwell JSON responses use an envelope.
The OpenAPI format version and `info.version` mean different things:
the generator supplies its supported document format; Inkwell names its
own API contract `v1`.

This complete small app uses the finished app's document handler. The
health route stands in for its resource mounts:

```bit
import { App, Config, Ctx, OpenApiInfo, Res, envelope } from "web"
import { jsonEncode } from "std/json"

fn showOpenApi(c: Ctx, app: App): Res! {
  let document = app.openApi(
    OpenApiInfo{ title = "Inkwell API", version = "v1", description = "Inkwell blogging API" },
  )?
  return c.bytes(jsonEncode(document), "application/json; charset=utf-8")
}

fn main(): ()! {
  let app = App(Config{ secret = "local-example-secret" })
  app.use(envelope())
  let api = app.group("/v1")
  api.get("/health", (c) => c.text("ok"))
  app.get("/openapi.json", (c) => showOpenApi(c, app))
  app.listen()?
}
```

`c.bytes` supplies the already encoded document without a JSON value for
the envelope to wrap. `openApi` returns `Json`, while `c.json` takes a
`Jsonable`; use the encoded bytes directly. A JSON wrapper object would
also produce an application envelope instead of the document a client expects.

## Register first, generate after freezing

`App.openApi` reads the frozen route table. `listen()` freezes registration
before serving requests, so the document handler can call it safely. In an
in-process test, register every route and call `app.freeze()?` before
`app.handle(...)` or generating a document directly. Calling `openApi`
before freezing fails with an error starting
`web: openApi(): the router is not frozen yet`.

The completed app registers `/openapi.json` after all resource mounts and
outside the `/v1` group. That documentation route is itself part of the
registered route table, so it appears in the generated document too.

## Know what the generator can describe

Paths, methods and path parameters come from registered routes; a pattern
such as `/:id` becomes `/{id}`. Request and response schemas require the
route's `requestBody<T>()` and `responds<T>(status)` declarations. The
generator does not infer every handler's body, authorization policy or
error cases from its implementation. Inkwell's document currently exposes
its route inventory; do not treat an absent schema as a promise that a
handler accepts any body.

Use the [OpenAPI reference](../docs/openapi.md) when adding those route
schema declarations. Keep them beside the real registration, rather than
hand-writing a second document. Clients still need the authentication and
error contracts taught in the following chapters.

Previous: [Give the API a versioned address](32-api-versioning.md).
Next: [API tokens with JWT](34-api-tokens-with-jwt.md).
