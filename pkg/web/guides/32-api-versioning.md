# Give the API a versioned address

An Inkwell client saves the URL it calls. Changing that route's response
shape without changing its address can break a client you cannot upgrade
today. Put the current API under `/v1` so a future contract can have its own
address while you decide how long to keep the first one.

## Mount a group once

The finished app puts every existing resource and operation route behind
one group. Route modules accept `Routes`, the existing interface both an
`App` and a route `Group` satisfy. They keep registering relative paths.
This complete example applies the same arrangement to health and readiness:

<!-- doctest: deps orm -->

```bit
import { App, Config, Ctx, Res, Routes } from "web"
import { Db, open } from "orm"
import { env } from "std/os"

fn health(c: Ctx): Res! { return c.text("ok") }

fn ready(c: Ctx, db: Db): Res! {
  db.exec("select 1") catch _ {
    return c.text("database unavailable").status(503)
  }
  return c.text("ready")
}

fn mountOperations(app: Routes, db: Db) {
  app.get("/health", health)
  app.get("/ready", (c) => ready(c, db))
}

fn main(): ()! {
  let db = open(env("DATABASE_URL"))?
  defer db.pool.close()
  let app = App(Config{ secret = env("APP_SECRET") })
  mountOperations(app.group("/v1"), db)
  app.listen()?
}
```

In [main.bit](inkwell/main.bit), the same group is passed to
`mountOperations`, `mountUsers`, `mountAuth`, `mountArticles`, `mountTags`
and `mountComments`. Each keeps its existing dependencies; the route
registration interface is the only part that changes.

The existing middleware stays on `App`, wrapping the versioned routes.
Nested groups compose: `mountAuth` adds `/api`, so its bearer-token profile
route is `/v1/api/me`, while its session profile route is `/v1/me`.

## Change the client addresses too

Against the finished app:

```sh
curl -i http://127.0.0.1:8080/v1/health
curl -i http://127.0.0.1:8080/v1/ready
curl -i http://127.0.0.1:8080/v1/articles
```

All earlier app routes moved, including health and readiness. Update load
balancer probes and request paths in tests, not just article clients.
Unprefixed `/health`, `/articles` and `/auth/login` are no longer aliases.
Created-resource `Location` headers also include `/v1`.

For optional Google sign-in, register and configure
`http://127.0.0.1:8080/v1/auth/google/callback` as the return address.
The [Google chapter](36-sign-in-with-google.md) follows that setting through
the authorization flow.

The small standalone programs in earlier chapters retain the paths they
register locally. When running the completed `inkwell/` app instead, use
these versioned addresses. Do not add `/v1` inside a resource module as well
as on its parent group, or you will register the prefix twice.

## Decide what a version promises

A prefix reserves an address; it does not translate old request bodies,
copy data into another database or create a second implementation. Inkwell
currently serves only `v1`. Add another version when you have a contract
that needs it, with an explicit migration plan for its clients.

The documentation endpoint remains at `/openapi.json` outside the API
group. The next chapter generates its contents from the routes actually
mounted, including their `/v1` prefixes.

Previous: [Reuse an article until its representation changes](31-conditional-client-caching.md).
Next: [Generate the API document from its routes](33-generated-openapi.md).
