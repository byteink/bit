# Errors

`HttpError` is the opt-in that decides two things at once: this status is the
right answer, and this message is fit for a client to read. Writing one is a
decision that shows up in a diff - not a config flag, not a registry entry.

## Failing with a status

```bit
import { Ctx, Res, notFound, badRequest, unprocessable } from "bitlang.org/pkg/web"

fn showUser(c: Ctx): Res! {
  fail notFound("no user with that id")
}
```

The named constructors - `notFound`, `badRequest`, `unauthorized`,
`forbidden`, `conflict`, `unprocessable` - are aliases for the general
`httpError(status, msg)`, which panics for a status outside `100..599` at the
call that built it, naming the line responsible rather than surfacing the
mistake later on the response path.

## What happens to a failure that is not an HttpError

A failure that does not satisfy `HttpError` - a plain `newError(...)`, a
database driver's own error type - is mapped to a `500` with a generic body
and the real message logged through `Config.logs` (stderr when none is set).
That is the security property the whole design turns on: an error becomes
client-visible only by opting in with a type that says `status()` and
`message()`, never by accident.

## Rendering an error yourself

`Group.onError(h)` (see [Middleware](middleware.md)) replaces the default
mapping for a scope. The handler never sees a failure that did not satisfy
`HttpError` - it always receives a value built from the mapping, so it
decides the body while the framework still owns the status:

```bit
import { App, Ctx, Res, HttpError } from "bitlang.org/pkg/web"

fn renderError(c: Ctx, e: HttpError): Res {
  return c.text(e.message()).status(e.status())
}

fn mount(app: App) {
  app.onError(renderError)
}
```

`onError` is refused after the app is frozen, and a second one on the same
group is refused too - both fail at registration rather than on a request.

Next: [Configuration](configuration.md).
