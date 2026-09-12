# Middleware

A `Middleware` is `(Ctx, Next) => Res!`: it receives the request and the rest
of the chain, and decides whether - and when - to call it. Onion model: call
`next(c)` before acting to run code on the way in, act on the `Res` it
returns to run code on the way out, or never call it and return your own
`Res` to short-circuit (that is how auth rejects).

## Writing one

```bit
import { Ctx, Res, Middleware, Next } from "bitlang.org/pkg/web"

fn requestId(): Middleware {
  return (c: Ctx, next: Next) => {
    let res = next(c)?
    return res.header("X-Request-Id", "generated-here")
  }
}
```

## Scope: app.use vs group.use

`app.use(m)` runs `m` for **every request the app answers**, including one
for a path no route matches: the app-root chain is composed around the
framework's own 404 and 405 as well as around each route's handler. A
middleware that calls `next(c)` on such a request gets that 404 back and can
act on it; one that answers without calling `next` replaces it. That is what
lets a file mount work with nothing registered on the router - see
`static()` in [Operational middleware](operations.md).

`group.use(m)` is narrower on purpose: it runs for the **routes** registered
on that group and on groups nested under it, and a request that matched no
route is on no group. Mount on the app when you want the middleware to see
misses.

```bit
import { App, Ctx, Res } from "bitlang.org/pkg/web"

fn logMiss(c: Ctx): Res! {
  return c.text("miss")
}

fn mount(app: App) {
  let api = app.group("/api")
  api.use((c, next) => next(c)?)
}
```

A `use()` on an ancestor group made *after* a child group (or a route on it)
was created still applies: a group's middleware list is read live at every
request, never snapshotted at the moment the child was created.

## Error handlers

`group.onError(h)` installs a renderer, replacing the default response for
any failure that reaches a route on that group or one nested under it - see
[Errors](errors.md) for what the handler is allowed to send. Both `use()` and
`onError()` are refused after the app has been frozen (`listen()` or
`freeze()`), and a second `onError()` on the same group is refused too - both
are startup failures, not something a request should discover.

Next: [Sessions, CSRF and security](security.md).
