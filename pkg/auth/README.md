# pkg/auth

Authentication for [`pkg/web`](../web): a `Strategy` interface for how a
request proves who it is, and a `requireAuth` middleware that runs a
request through one or more of them, storing the result on the request's
session.

## Install

```json
{
  "dependencies": {
    "auth": "bitlang.org/pkg/auth@v0.1.0",
    "web": "bitlang.org/pkg/web@v0.1.0"
  }
}
```

## Usage

```bit
import { App, Config, Ctx, MemoryStore } from "web"
import { Identity, Strategy, currentIdentity, requireAuth } from "auth"
import { Json } from "std/json"

class ApiKeyStrategy {
  export name(): string {
    return "api-key"
  }
  export authenticate(c: Ctx): Identity! {
    if (c.header("x-api-key") != "secret") {
      fail newError("api-key: invalid key")
    }
    return Identity{ id = "service", claims = Json.JsonNull }
  }
}

fn main(): ()! {
  let app = App(Config{ secret = "change-me", sessions = MemoryStore(10_000) })
  app.use(requireAuth([]Strategy{ ApiKeyStrategy{} }))
  app.get("/me", (c) => {
    let identity = currentIdentity(c)?
    return c.text(identity.id)
  })
  app.listen()?
}
```

`Identity.claims` is a `Json` value (`std/json`), not a string map: an OIDC
ID token's claims hold arrays and nested objects a string map would
truncate, and a password lookup's callback already builds a JSON object.

This package exports the `Strategy` seam, the middleware that runs it, and
`newPasswordStrategy` (`password.bit`) — an Argon2id `Strategy` over an
application-supplied `Lookup` callback. `OidcStrategy` is later work under
the same epic.

For how first-party packages in this repository are laid out, gated,
versioned and released, see [`pkg/README.md`](../README.md).
