# Testing the API

Inkwell now registers, logs in, creates articles and tags. None of that is
worth much if a route can regress silently the next time someone touches
`articles.bit`. This part tests the app two ways: fast checks that never
touch a socket, and real integration tests that hit a live PostgreSQL,
exactly the ones Inkwell's own test suite runs.

## The seam: `app.handle(req)`

[Getting started](../docs/getting-started.md) already showed the shape:
`app.handle(req: Request): Response` runs the same router, the same
middleware chain and the same `Ctx` a real socket would, and returns a
`Response` in process. That one function is the whole seam a test needs -
no server to start, no port to pick, no client library to dial with.

```bit
import { App, Config, Ctx, Res } from "web"
import { Request } from "std/http"

fn home(c: Ctx): Res! {
  return c.text("hello, inkwell")
}

fn buildApp(): App {
  let app = App(Config{ secret = "test-secret" })
  app.get("/", home)
  return app
}
```

A test calls it the same way a real request would arrive. `test-package-docs`
cannot typecheck a real `test "..." { }` declaration itself - it always
compiles a page's blocks into one scratch `main.bit`, never a
`<name>.test.bit`, so a `test` block is out of its reach today. The block below is marked
`ignore` for that reason; every name and call in it is the same ones proven
above,
and the shape is exactly `math.test.bit`'s from [Test your
code](../../../docs/guides/test-your-code.md):

```bit ignore
import { eq } from "std/testing"

test "GET / answers hello" {
  let app = buildApp()
  let res = app.handle(Request{ method = "GET", path = "/", headers = "", body = "" })
  eq<i64>(res.status, 200, "status")
  eq<string>(res.body, "hello, inkwell", "body")
}
```

Run it:

```
$ bit test app.test.bit
ok   GET / answers hello

discovered 1 test, ran 1: 1 passed, 0 failed
```

[Test your code](../../../docs/guides/test-your-code.md) covers the
assertions themselves (`eq`, `ok`, the `check` twins for a table of cases).
This part is about what an API-shaped test needs on top of them: building a
request, reading back a status and a body, and - for anything that touches
the database - a real one to touch.

## A request with a body and a cookie

Registering and logging in are the two calls almost every other route
needs a session for first. Building the request by hand, the way Inkwell's
own `app.test.bit` does, keeps a test readable as "do this, then check
that" instead of a wall of client setup:

```bit
fn jsonReq(method: string, path: string, cookie: string, body: string): Request {
  let headers = "Content-Type: application/json"
  if (len(cookie) > 0) {
    headers = headers + "\r\nCookie: " + cookie
  }
  return Request{ method = method, path = path, headers = headers, body = body }
}
```

A route that requires a session reads the `Set-Cookie` header a login
response answered with, and sends it back on the next call:

```bit
import { Response } from "std/http"

fn register(app: App, username: string): Response! {
  let body = "{\"username\":\"${username}\",\"password\":\"correct horse\"}"
  let res = app.handle(jsonReq("POST", "/auth/register", "", body))
  if (res.status != 201) {
    fail newError("register: want 201, got ${res.status}")
  }
  return res
}
```

## Integration tests against a real database

`app.handle()` proves the routing and the response shape, but Inkwell's
real risk lives in the SQL: a migration that does not match the ORM's
table description, a query that returns the wrong row, a transaction that
half-commits. None of that shows up against a fake. Inkwell's integration
tests open a real `Pool` against `DATABASE_URL` and run every route through
it:

<!-- doctest: deps postgres -->
```bit
import { adapter } from "postgres"
import { Datasource, Pool, pool } from "std/sql"
import { env } from "std/os"

fn testPool(): Pool! {
  let url = env("DATABASE_URL")
  if (len(url) == 0) {
    fail newError("DATABASE_URL is not set")
  }
  return pool(adapter(), Datasource{ uri = url })?
}
```

A test that needs the database opens its own pool and builds its own `App`
- `App` freezes its route table once, so two tests sharing one `App` value
would collide. Marked `ignore` for the same reason as the block above:

```bit ignore
test "health answers ok" {
  let p = testPool() catch e {
    panic("testPool: ${e.message()}")
  }
  let app = App(Config{ secret = "test-secret" })
  app.get("/health", (c) => c.text("ok"))
  app.freeze() catch e {
    panic("freeze: ${e.message()}")
  }
  let res = app.handle(Request{ method = "GET", path = "/health", headers = "", body = "" })
  eq<i64>(res.status, 200, "health status")
  p.close()
}
```

Every test name is unique-data, not fixture-shared: a username built from a
random suffix (`std/uuid`'s `uuidV4`), never a hardcoded one, so two tests
running in the same database in any order never collide on a unique
constraint. Inkwell's `uniqueName("alice")` does exactly this, and every
one of its fifteen-plus tests calls it before registering a user.

## How Inkwell's own tests are built

Inkwell's tests live beside the code they test, one `*.test.bit` file per
resource - `articles.bit` next to nothing today, its coverage folded into
`app.test.bit` at the top level, since a blog post's real risk is how
articles, tags and comments interact, not any one file in isolation. The
whole suite runs against one real, throwaway PostgreSQL: a `Gate{}` named
`test-web-guides-app` starts a pinned `postgres:18.6` image in a Docker
container before the run and always removes it after, pass or fail, so a
test can never leave a stray container behind and never depends on one
already running on the machine. Wired that way, the suite skips cleanly on
a machine with no Docker instead of failing - the same rule any live-service
gate in this repo follows.

Every test that touches the database calls `runMigrations(pool)` itself,
first - a fresh `Pool` from `testPool()` knows nothing about the schema
until something applies it, and doing that once per test (not once for the
whole run) means one test's half-finished transaction can never leave the
next one looking at tables in a state no test asked for.

The real thing runs, at [`inkwell/app.test.bit`](inkwell/app.test.bit): nine
tests, one per behavior (health and readiness, register plus login plus
`/me`, a duplicate username, an article's tags attached atomically, an
owner-only update and delete, comments, admin-only tag creation, pagination,
logout). Every one of the two blocks above is that file's own code, trimmed
to the one route each explains.

```
$ bit test app.test.bit
ok   health and readiness answer without authentication
ok   register, login, and read back the caller's own profile with /me
ok   a duplicate username registers 409, and a wrong password logs in 401
ok   creating an article attaches its tags atomically, and the detail route shows both
ok   only the article's own author (or an admin) may update or delete it
ok   comments: any logged-in reader may post, only the comment's own author may delete
ok   tag creation is admin-only, and the tag list is public
ok   the article list paginates: a 1-item page reports the real total and a next cursor
ok   logging out invalidates the session for a subsequent request

discovered 9 tests, ran 9: 9 passed, 0 failed
```

## What we built

Inkwell now has a way to prove a route works without breaking anything a
future change might touch: fast in-process checks for the response shape,
and real database-backed tests for the SQL underneath it. The same
`app.handle()` seam serves both - a test never needs a socket, only a real
`Pool` when the question is one only a real database can answer.

Previous: Transactions (part 15). Next: [Operations](17-operations.md).
