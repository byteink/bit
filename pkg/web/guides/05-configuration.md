# Configuration

`build()` still hardcodes `"dev-secret"` as the session-signing key, and
Inkwell only ever binds `127.0.0.1:8080`. That is fine for one file on one
machine, but it breaks the moment you want a different secret in production
or a different port in a container. `pkg/web` never reads a file or an
environment variable itself; an app that wants a setting reads it and hands
the result to `Config`. Inkwell reads every setting exactly once, in one
place, and every other file takes the result as a plain value instead of
calling into the environment again.

## Step 1: one struct for every setting

```bit
import { env, envOr } from "std/os"
import { parseInt } from "std/strings"

export class AppConfig {
  export databaseUrl: string,
  export secret: string,
  export host: string,
  export port: int,
}
```

`databaseUrl` sits unused until part 6, but it lives in this struct now
because every setting Inkwell reads from the environment belongs in the same
place, read once, not scattered across the files that end up needing it.

## Step 2: fail loudly, and name the variable

A `string`'s zero value is `""`, so a forgotten `APP_SECRET` would otherwise
build an app whose sessions are signed under an empty key without saying so.
Fail at startup instead, naming exactly what is missing:

```bit
fn mustEnv(name: string): string! {
  let v = env(name)
  if (len(v) == 0) {
    fail newError("inkwell: ${name} is not set, export it before starting the app")
  }
  return v
}

export fn loadConfig(): AppConfig! {
  let databaseUrl = mustEnv("DATABASE_URL")?
  let secret = mustEnv("APP_SECRET")?
  let host = envOr("HOST", "127.0.0.1")
  let port = parseInt(envOr("PORT", "8080"))?
  return AppConfig{ databaseUrl = databaseUrl, secret = secret, host = host, port = port }
}
```

`DATABASE_URL` and `APP_SECRET` are required: there is no sane default for
either, so a missing one stops the app before it binds a port. `HOST` and
`PORT` fall back to `127.0.0.1:8080`, `pkg/web`'s own defaults, so a
developer who sets neither still gets a working app.

## Step 3: wire it into main

```bit
import { App, Config } from "web"

fn main(): ()! {
  let cfg = loadConfig()?
  let app = App(Config{ secret = cfg.secret, host = cfg.host, port = cfg.port })
  app.get("/", (c) => c.text("inkwell"))
  app.listen()?
}
```

Run it with nothing set:

```
$ bit run main.bit
inkwell: DATABASE_URL is not set, export it before starting the app
```

The process exits before it binds a socket - there is no partially started
app to accidentally serve traffic on the wrong secret. Now set every
variable and run it again:

```
$ export DATABASE_URL=postgres://inkwell:inkwell@127.0.0.1:5432/inkwell?sslmode=disable
$ export APP_SECRET=$(head -c 32 /dev/urandom | base64)
$ export PORT=9090
$ bit run main.bit &
$ curl -s http://127.0.0.1:9090/
inkwell
```

`PORT=9090` reached `app.listen()` with nothing else in the file changing -
the whole point of reading every setting once, in one place.

## What we built

Inkwell now reads `DATABASE_URL`, `APP_SECRET`, `HOST` and `PORT` from the
environment exactly once, fails at startup naming whichever required
variable is missing, and hands the result to every file that needs a
setting as a plain value.

Previous: [Errors and consistent responses](04-errors-and-consistent-responses.md)
Next: [Connecting to PostgreSQL](06-connecting-to-postgresql.md)
