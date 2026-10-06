# Configuration

Every setting an `App` reads comes from one `Config` value the program builds
and hands over at construction. The framework opens no file and reads no
environment variable itself - an app that wants `APP_SECRET` reads it and
puts the result here.

```bit
import { App, Config, MemoryStore } from "web"
import { env } from "std/os"

fn build(): App {
  return App(
    Config{
      secret = env("APP_SECRET"),
      maxBody = 2_000_000,
      rejectUnknownFields = true,
      sessions = MemoryStore(10_000),
      host = "0.0.0.0",
      port = 8080,
    },
  )
}
```

| field | default | notes |
|---|---|---|
| `secret` | none, required | Signs CSRF tokens ([Sessions, CSRF and security](security.md)). `App(...)` panics naming this field when it is empty - a `string`'s zero value is `""`, so this is enforced at construction, not by the type. Never used for session ids: the session cookie carries a random id, not signed data. |
| `maxBody` | `1_000_000` | Largest request body this package will parse, in bytes. `std/http` enforces its own, separate budget (32 MiB by default) before a body reaches a `Ctx` at all - see [The request](request.md). |
| `rejectUnknownFields` | `true` | The app-level default for `c.body<T>()`; a route overrides it per call with `bodyWith`. |
| `sessions` | `nil`, no default | A `SessionStore`. `c.session()` fails, naming this field, when it is unset - see [Sessions, CSRF and security](security.md). |
| `host` | `"127.0.0.1"` | The interface `listen()` binds. Never `0.0.0.0` by default: reaching the network is a choice made at the call site, not a framework default. |
| `port` | `8080` | The port `listen()` binds. |
| `logger` | `Option.None`, means `getDefault()` | An `Option<Logger>` from `std/log`. Where the framework writes what it refuses to send - the real message behind every `5xx`, with the request method and path - and the request records of `logger()`. See [Logging](#logging). |

`sessions` is an interface, so `nil` is the language's own "absent" rather than
a sentinel this package invented. `logger` is an `Option`, whose zero value is
`Option.None` - a class-typed field could be neither omitted nor given a
default, since a default must be a compile-time constant and no class value is
one.

## Logging

The framework writes through one `std/log` `Logger`, the same one your own
code can use, so the app chooses the handler, the level and the destination
once. With no `logger` set, it uses `getDefault()`: text lines on stderr at
`LevelInfo`. A swallowed `500` with no record anywhere is the failure mode this
field exists to prevent, so absent never means silent.

Pass the process default explicitly, or build one that writes JSON for a log
aggregator:

```bit
import { App, Config, logger } from "web"
import { Logger, JsonHandler, LevelInfo, attrs, getDefault } from "std/log"
import { stdout } from "std/io"

fn withDefault(secret: string): App {
  return App(Config{ secret = secret, logger = Option.Some(getDefault()) })
}

fn withJson(secret: string): App {
  let lg = Logger(JsonHandler(stdout(), LevelInfo)).with(attrs().str("service", "inkwell"))
  let app = App(Config{ secret = secret, logger = Option.Some(lg) })
  app.use(logger())
  return app
}
```

With that logger, a request to `GET /health` writes

```text
{"time":"2026-10-06T09:14:02Z","level":"INFO","service":"inkwell","msg":"request","method":"GET","path":"/health","status":200,"took":412000}
```

(`took` is a duration: nanoseconds in JSON, `412us` in text), and a handler
that fails with a plain error writes one `ERROR` record carrying the method,
the path and the real message, while the client receives only
`Internal Server Error`. A level above `LevelInfo` silences the request records
and keeps the errors. When the level is off, `logger()` builds nothing and
allocates nothing per request; when it is on, a request costs three objects
more than a quiet one: the clock reading, the record and the line.

### Upgrading from `logs`

`Config.logs` and the one-method `LogSink` interface are removed in favour of
`Config.logger`: pre-1.0, and a breaking change for the package, so a minor
release. Replace `logs = sink` with
`logger = Option.Some(Logger(TextHandler(sink)))`, where `sink` has
`write(s: string): ()!` (a `std/log` `Sink`) instead of `log(line: string)`.
Records are `key=value` attributes now, not one hand-formatted string.

This was the last chapter; see [pkg/web/README.md](../README.md) for install,
or start over at [Getting started](getting-started.md).
