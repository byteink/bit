# Routing

The router is a radix trie over path segments: lookup cost is the number of
segments in the *request*, not the number of routes registered, and it
short-circuits on the first segment that matches nothing. This chapter is
about registering a route and getting back what it captured.

## Static, param and wildcard segments

A segment starting with `:` captures one path component under that name; a
segment starting with `*` must be the pattern's last segment and captures
everything from there to the end of the path. Precedence at each node is
static, then param, then wildcard - decided at match time, never by
registration order.

```bit
import { App, Ctx, Res } from "bitlang.org/pkg/web"

fn showUser(c: Ctx): Res! {
  return c.text("user ${c.param("id")}")
}

fn serveFile(c: Ctx): Res! {
  return c.text("path ${c.param("path")}")
}

fn mount(app: App) {
  app.get("/users/:id", showUser)
  app.get("/files/*path", serveFile)
}
```

`c.param(name)` reads a captured segment; `c.query(name)` and `c.header(name)`
read the query string and a request header the same way - see
[The request](request.md) for the rest of `Ctx`'s surface.

## Every registration method

`get`/`post`/`put`/`delete` cover the common four; `route(method, path, h)`
registers any of the other RFC 9110 methods this package accepts (`HEAD`,
`PATCH`, `OPTIONS`). A method the framework does not know is a panic at
registration - a typo like `"GTE"` is a startup failure, not a silent 404
nobody notices until production. A path that matched no route, but matched
some other method's pattern, comes back `405` with an `Allow` header naming
what would have worked.

## Naming a route

`.name(n)` records a route under a name so another handler can build its URL
without hand-concatenating the path:

```bit
import { App, Ctx, Res } from "bitlang.org/pkg/web"

fn showUser(c: Ctx): Res! {
  return c.text("user ${c.param("id")}")
}

fn afterCreate(c: Ctx): Res! {
  let target = c.route("user.show", []string{ "42" })?
  return c.redirect(target)
}

fn mount(app: App) {
  app.get("/users/:id", showUser).name("user.show")
}
```

A duplicate name is not an error where it is declared - it is recorded and
only surfaces when the app freezes its route table (at `App.freeze()` or
`App.listen()`), the same way a conflicting pattern does, so one error
message can name every offending route at once.

Next: [The request](request.md), for everything `Ctx` gives a handler.
