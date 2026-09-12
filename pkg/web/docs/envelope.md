# Envelope

`envelope()` is a `Middleware` that gives every response one of two shapes,
`{"data": ...}` for a plain success or `{"error": {"code": ..., "message":
...}}` for a failure, so a client never parses more than one response
grammar. It is opt-in per app or per group, never on by default, and a
`page()` result gets a third shape carrying pagination metadata alongside
the same `data` key.

## Mounting it

```bit
import { App, Ctx, Res, envelope } from "web"

@json class User {
  id: int,
  name: string,
}

fn showUser(c: Ctx): Res! {
  return c.json(User{ id: 42, name: "ada" })
}

fn mount(app: App) {
  app.use(envelope())
  app.get("/users/:id", showUser)
}
```

`app.use(envelope())` (or `group.use(envelope())`, see [Middleware](middleware.md)
for the difference in scope) wraps every route it reaches. A route in a
group that never mounts it keeps its handler's own response, unchanged -
useful for a webhook endpoint that must answer with a third party's exact
shape. `GET /users/42` above answers:

```json
{ "data": { "id": 42, "name": "ada" } }
```

## The non-paginated case

An ordinary value, including an array returned through `c.json(v)` without
`page()`, always wraps as `{"data": v}` and nothing else - `envelope()` adds
no `meta` key unless the value was built by `page()`. Returning a plain
`[]User` yields `{"data": [...]}`, with no `total`, `limit` or `cursor`.
`meta` is not inferred from a value merely being an array; it is only ever
produced by the convention below.

## Pagination: page()

```bit
import { page } from "web"

fn listUsers(c: Ctx): Res! {
  let users = []User{ User{ id: 1, name: "ada" }, User{ id: 2, name: "grace" } }
  return page(users, 940, 50, "cursor-abc")
}
```

`page<T: Jsonable>(items, total, limit, cursor): Res` builds a `Res` a handler
returns directly, the same way `c.json`/`c.jsonList` do - it carries its own
`200` and `application/json` `Content-Type`, so it needs no `Ctx`. `items` is
the page a caller already fetched, not the whole collection:

- `total` - the count across every page, not just the ones returned here.
- `limit` - the page size this response used.
- `cursor` - an opaque token a caller passes back to fetch the next page;
  the format is entirely up to the handler that produced it.

Under `envelope()`, `GET /list` above answers:

```json
{
  "data": [
    { "id": 1, "name": "ada" },
    { "id": 2, "name": "grace" }
  ],
  "meta": { "total": 940, "limit": 50, "cursor": "cursor-abc" }
}
```

`page()` is meaningful only behind `envelope()`. Called on a route that
never mounts it, a client sees the marker key `page()` writes internally to
tell its result apart from an ordinary object, not `data`/`meta` - the same
trust `Res.mapValue` already places in whatever middleware reshapes a value.

## The error shape

A failure `envelope()` catches becomes `{"error": {"code": ..., "message":
...}}`, reusing [Errors](errors.md)'s `HttpError` mapping for the status and
the message a client may read - a plain error that never opted into
`HttpError` still gets a generic `500` with its real message going only to
the configured log, never to the client. `notFound("user")` behind
`envelope()` answers:

```json
{ "error": { "code": "not_found", "message": "user" } }
```

This is `envelope()`'s own shape, not [Errors](errors.md)'s default
`{"status": ..., "error": ...}` for a route that never mounted it - the two
are deliberately different, and a route only ever produces one or the
other, never both.

Next: [Configuration](configuration.md).
