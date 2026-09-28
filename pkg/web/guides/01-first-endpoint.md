# Part 1: First endpoint

<!-- doctest: per-block -->

You want a program that answers HTTP requests. Nothing else yet - no
database, no routes past one. This part gets you there in a few minutes, and
every later part in [Build an API with Bit](README.md) builds on what you
write here: Inkwell, a blogging API you will grow part by part.

## Install pkg/web

Make a directory for the project and turn it into a Bit project:

```text
$ mkdir inkwell && cd inkwell
$ bit init inkwell
bit init: wrote bit.json
```

Add `pkg/web`, the framework this whole course is built on:

```text
$ bit add bitlang.org/pkg/web@v0.7.0
bit add: web -> bitlang.org/pkg/web@0.7.0 (d13a8daf9505f438586c7ee82eb5e2220a294c40)
```

`bit add` writes the dependency into `bit.json` and pins the exact commit it
resolved into `bit.lock`, the same way `go.sum` or a lockfile in any other
language pins what you actually got.

## Write the endpoint

An `App` is where every request starts. You build one with a `Config`, then
register a route on it before serving. `Config.secret` has no default
because it signs cookies later in the course - for now, a literal string is
enough to get running; part 5 loads it from the environment properly.

Create `main.bit`:

```bit
import { App, Config, Ctx, Res } from "web"

fn health(c: Ctx): Res! {
  return c.text("ok")
}

fn main(): ()! {
  let app = App(Config{ secret = "dev-secret-change-me" })
  app.get("/health", health)
  app.listen()?
}
```

`app.get(path, handler)` registers a route: any `GET /health` request now
runs `health`, which takes the request's `Ctx` and returns a `Res!` - a
response, or a failure the framework turns into one. `c.text("ok")` builds a
`200` with a `text/plain` body. `app.listen()` freezes the route table and
serves forever, on `127.0.0.1:8080` by default.

## Run it

```text
$ bit run main.bit
```

This compiles and starts the server in one step; it keeps running until you
stop it. In another terminal, request it:

```text
$ curl -i http://127.0.0.1:8080/health
HTTP/1.1 200 OK
Content-Length: 2
Content-Type: text/plain; charset=utf-8
Connection: keep-alive

ok
```

## What we built

A running server with one route, `GET /health`, that answers `200 ok`. You
installed `pkg/web`, wrote an `App`, and served your first request.

Next: [Part 2, routing and route groups](02-routing-and-route-groups.md),
where Inkwell gets its first real resource: articles, with a path parameter
and routes grouped under one prefix.
