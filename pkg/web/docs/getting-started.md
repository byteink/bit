# Getting started

`App` is where every request in a program starts: build one with a `Config`,
register routes on it, and either serve it on a socket or call it in process.
This chapter is the shortest path from `bit add` to a response.

## Install

```json
{
  "dependencies": {
    "web": "bitlang.org/pkg/web@v0.1.0"
  }
}
```

## Build an App and answer a request

`Config.secret` is the one field with no default (it signs CSRF tokens); an
`App` built without it panics naming the field. Read it from the
environment - the framework never reads an environment variable itself.

```bit
import { App, Config } from "web"
import { env } from "std/os"

fn main(): ()! {
  let app = App(Config{ secret: env("APP_SECRET") })
  app.get("/", (c) => c.text("hello, bit"))
  app.listen()?
}
```

`app.listen()` freezes the route table, then serves `Config.host:Config.port`
forever (`127.0.0.1:8080` by default - never `0.0.0.0`, so reaching the
network is a deliberate choice made at the call site). It returns only on a
bind/accept error, or immediately if freezing rejects the route table (a
duplicate pattern, a duplicate route name).

## Testing without a socket

`app.handle(req: Request): Response` runs the same dispatch `listen()`
serves - the same router, the same middleware chain, the same `Ctx` - and
returns a `Response` in process, with nothing bound. It is the seam a test
calls instead of standing up a server:

```bit
import { App, Config, Ctx, Res } from "web"

fn home(c: Ctx): Res! {
  return c.text("hello, bit")
}

fn build(): App {
  let app = App(Config{ secret: "test-secret" })
  app.get("/", home)
  return app
}
```

## Organizing routes with groups

`app.group(prefix)` returns a `Group` sharing the app's own router: register
on it to prefix a whole feature's routes at once, and see
[Middleware](middleware.md) for what a group's own `use()` does and does not
see.

```bit
import { App, Ctx, Res } from "web"

fn listUsers(c: Ctx): Res! {
  return c.text("users")
}

fn mountApi(app: App) {
  let api = app.group("/api")
  api.get("/users", listUsers)
}
```

Next: [Routing](routing.md), for params, wildcards and named routes.
