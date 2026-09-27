# Operations: health, readiness and graceful shutdown

Inkwell works. It is not yet something you would deploy. A load balancer
needs a way to ask "is this instance up" before it sends traffic, and a
platform needs a way to ask "can this instance take real work" before it
stops health-checking and starts routing to it. When that platform decides
to stop the instance - a rolling deploy, a scale-down, a developer's Ctrl-C
- it sends a signal, and an app that has nothing to say back to that signal
just gets killed mid-request. This part covers all three: health, readiness
and shutting down without dropping what is already in flight.

<!-- doctest: per-block -->

## Health versus readiness

These answer different questions, and conflating them is the most common
mistake in a service's ops surface:

- **Health** ("liveness"): is the process itself alive and able to answer
  HTTP at all? A platform that gets no answer, or a 5xx, restarts the
  process. Nothing this route checks should ever be slow or depend on
  anything else being up - a health check that calls the database turns a
  database blip into a restart storm of every instance at once.
- **Readiness**: can this instance take real traffic right now? Early in
  boot, or if a downstream dependency it needs is down, the answer is no -
  and a platform that respects readiness stops routing to it without
  killing the process, which gives it a chance to recover on its own.

Inkwell registers both, unauthenticated, ahead of every other route:

```bit
import { App, Config, Ctx, Res } from "web"
import { Pool, Value } from "std/sql"

fn probeDb(p: Pool): bool {
  let rows = p.query("select 1", []Value(0)) catch _ {
    return false
  }
  rows.close()
  return true
}

fn health(c: Ctx): Res! {
  return c.text("ok")
}

fn ready(c: Ctx, p: Pool): Res! {
  if (!probeDb(p)) {
    return c.text("database unavailable").status(503)
  }
  return c.text("ready")
}

fn mountOperations(app: App, p: Pool) {
  app.get("/health", health)
  app.get("/ready", (c) => ready(c, p))
}
```

`/health` never touches `p`; it only proves the process can answer HTTP.
`/ready` runs the cheapest query that proves the connection Inkwell
actually uses still works - `select 1`, not a real table, because the
question is "can I reach Postgres", not "does my schema look right".

```
$ curl -i http://127.0.0.1:8080/health
HTTP/1.1 200 OK
Content-Type: text/plain; charset=utf-8

ok
$ curl -i http://127.0.0.1:8080/ready
HTTP/1.1 200 OK
Content-Type: text/plain; charset=utf-8

ready
```

## Serving without blocking forever

Every earlier part called `app.listen()`, which blocks until a bind or
accept error and never hands back the socket it bound - there is no way to
stop it from anywhere else in the program. `app.serve()` binds the same
way but returns immediately with the running `Server`, so the rest of the
program can hold onto it and stop it later:

```bit
import { App, Config } from "web"

fn main(): ()! {
  let app = App(Config{ secret = "change-me" })
  app.get("/", (c) => c.text("ok"))
  let srv = app.serve()?
  // ... the app is serving requests here, on its own green thread ...
}
```

`server.shutdown(timeoutMs)` stops accepting new connections immediately
and gives every request already in a handler's hands up to `timeoutMs`
milliseconds to finish, force-closing whatever is still running once that
passes.

## Catching the signal that means "stop"

`server.shutdown()` is only useful if something calls it. The thing that
decides it is time is almost never inside your own handler logic - it is
the platform sending `SIGTERM` (Docker, Kubernetes, any process supervisor
asking a process to stop before it kills it harder) or a developer hitting
Ctrl-C, which sends `SIGINT`. `std/signal`'s `waitForSignal` blocks the
calling green thread until one of those arrives:

```bit
import { App, Config } from "web"
import { Signal, waitForSignal } from "std/signal"

fn main(): ()! {
  let app = App(Config{ secret = "change-me" })
  app.get("/", (c) => c.text("ok"))
  let srv = app.serve()?

  waitForSignal([Signal.Term, Signal.Int])
  srv.shutdown(10_000)?
}
```

Read top to bottom, this is the whole shape: start serving on a green
thread, block the main one on whichever stop signal arrives, then drain.
Nothing about `app.serve()` or `waitForSignal` cares which one triggered
it - a `docker stop` and a Ctrl-C hit the exact same shutdown path.

Sending the signal by hand shows the sequence:

```
$ ./inkwell &
$ curl http://127.0.0.1:8080/health
ok
$ kill -TERM %1
inkwell: shutting down
$ jobs
(no output - the process has exited)
```

A request already being handled when the signal arrives still gets its
answer; a new connection after that point is refused, not queued.

## What we built

Inkwell now answers the two questions a deployment platform actually asks -
"is this alive" and "can it take traffic" - without ever letting a health
check depend on the database going down turning into a restart storm. And
it stops the way a real deployment stops it: `SIGTERM` or `SIGINT` drains
whatever is in flight instead of cutting it off.

Previous: [Testing the API](16-testing-the-api.md). Next: [Shipping a
single binary](18-shipping-a-single-binary.md).
