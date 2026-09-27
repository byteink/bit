# std/signal

A process only ever stops two ways: the OS kills it outright, and nothing
runs after that, ever - or something inside the program calls `exit`.
Neither lets an external `docker stop`, a `kubectl delete pod`, or a
developer's Ctrl-C run a single line of your own code first. `SIGTERM` and
`SIGINT` just end the process, mid-request, mid-write, however things stood
at that instant.

`std/signal` gives a program a third option: block a green thread until one
of those signals arrives, and decide for yourself what "stopped" means -
stop accepting new work, let what is already running finish, then exit.

<!-- doctest: per-block -->

## Waiting for the signal

### `waitForSignal(sigs: []Signal): Signal`

```bit
import { waitForSignal, Signal } from "std/signal"

fn main() {
  print("running - send SIGTERM or SIGINT to stop\n")
  let sig = waitForSignal([Signal.Term, Signal.Int])
  if (sig == Signal.Term) {
    print("stopped by SIGTERM\n")
  } else {
    print("stopped by SIGINT\n")
  }
}
```

`waitForSignal` blocks the calling green thread until the process receives
one of `sigs`, and returns which one arrived. It does not consume the
signal - your program has already decided to stop; there is nothing left
for the OS's own default disposition to do differently.

## Building on it: shut down after starting other work

The call belongs on its own green thread's last line, after everything else
has already started - a socket listener, a background worker, whatever the
program's real job is:

```bit
import { waitForSignal, Signal } from "std/signal"
import { sleep } from "std/time"

fn worker() {
  while (true) {
    // ... do one unit of background work ...
    sleep(100000000) // 100ms, in nanoseconds
  }
}

fn main() {
  spawn worker()

  let _ = waitForSignal([Signal.Term, Signal.Int])
  print("shutting down\n")
  // ... close listeners, drain in-flight work, flush writers ...
}
```

A signal outside `sigs` never returns from the call - it is silently
re-waited, since nothing this program asked for happened. Passing both
`Signal.Term` and `Signal.Int` is the common case: a deployment sends
`SIGTERM`, a developer's terminal sends `SIGINT`, and a program that wants
to shut down cleanly usually wants to for either reason.

## The real use case: a web server's graceful shutdown

[`pkg/web`](../../pkg/web/docs/operations.md)'s `App.serve()` returns a
`Server` you can stop on your own terms with `server.shutdown(timeoutMs)` -
but nothing calls `shutdown` for you. `waitForSignal` is the missing wire:

```bit
import { App, Config } from "web"
import { waitForSignal, Signal } from "std/signal"

fn main(): ()! {
  let app = App(Config{ secret = "change-me" })
  app.get("/", (c) => c.text("ok"))
  let server = app.serve()?

  let _ = waitForSignal([Signal.Term, Signal.Int])
  server.shutdown(10000)?
}
```

Docker and Kubernetes both send `SIGTERM` first and wait before sending
`SIGKILL` - `server.shutdown`'s own timeout should stay under however long
your deployment waits, or the platform kills the process mid-drain anyway.

## Sharp edges

**One call per process, not per listener.** `waitForSignal` is not scoped
to whatever green thread calls it first - the underlying signal disposition
is process-wide. Calling it from two different green threads at once is
legal (each independently waits for its own `sigs`), but there is no way to
have one part of a program opt out while another opts in: the first call
anywhere arms delivery for the whole process.

**Windows has a narrower signal set.** `SetConsoleCtrlHandler` reports
Ctrl-C as `Signal.Int` and a Ctrl-Break, console-close or logoff/shutdown
event as `Signal.Term` - there is no POSIX-style `SIGKILL` equivalent to
miss, since none of Windows's own forceful termination paths run any
handler either.

## Where next

- [`pkg/web`'s operations guide](../../pkg/web/docs/operations.md) for
  wiring this into a running server's `shutdown`.
- [`std/os`](os.md) for the process's arguments, its environment, and
  `exit`.

Specification: `runtime/ABI.md` §19.
