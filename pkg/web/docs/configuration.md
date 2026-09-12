# Configuration

Every setting an `App` reads comes from one `Config` value the program builds
and hands over at construction. The framework opens no file and reads no
environment variable itself - an app that wants `APP_SECRET` reads it and
puts the result here.

```bit
import { App, Config, MemoryStore } from "web"
import { env } from "std/os"

fn build(): App {
  return App(Config{
    secret: env("APP_SECRET"),
    maxBody: 2_000_000,
    rejectUnknownFields: true,
    sessions: MemoryStore(10_000),
    host: "0.0.0.0",
    port: 8080,
  })
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
| `logs` | `nil`, means stderr | A `LogSink`. Where the framework writes what it refuses to send - the real message behind every `5xx`, with the request method and path. |

`sessions` and `logs` are interfaces, so `nil` is the language's own "absent"
rather than a sentinel this package invented - a class-typed field could be
neither omitted nor given a default, since a default must be a compile-time
constant and no class value is one.

This was the last chapter; see [pkg/web/README.md](../README.md) for install,
or start over at [Getting started](getting-started.md).
