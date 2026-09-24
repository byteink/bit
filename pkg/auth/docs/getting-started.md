# Getting started

Your app has users with a username and password, stored somewhere you
control - a table, a file, wherever. You want a `/login` route that checks
those credentials, and other routes that only answer once someone has.
`pkg/auth` does the checking and the session bookkeeping; you only supply the
lookup.

## Storing a password

`hashPassword` turns a plaintext password into the Argon2id string you store.
Never store the plaintext, and never write your own hashing - this is the one
function in the package that touches it.

```bit
import { hashPassword } from "auth"

fn createAccount(password: string): string {
  return hashPassword(password)
}
```

## Looking users up and protecting a route

A `Lookup` is a function from username to a `LookupResult` - the stored hash,
plus whatever you want to identify the user by afterward. `pkg/auth` holds no
user table of its own; this is the only place it asks your app for data.

`newPasswordStrategy(lookup)` wraps that into a `Strategy`, the interface
every authentication method in this package implements: a `name()` and an
`authenticate(c)` that either returns an `Identity` or fails.

```bit
import { App, Config, MemoryStore, unauthorized } from "web"
import { Identity, Lookup, LookupResult, Strategy, currentIdentity, newPasswordStrategy, requireAuth } from "auth"
import { Json } from "std/json"

fn users(username: string): LookupResult! {
  if (username != "ada") {
    fail newError("users: no such user '${username}'")
  }
  return LookupResult{
    hash = "$argon2id$v=19$m=19456,t=2,p=1$c29tZXNhbHQAAAAAAAAAAA$dGVzdGhhc2h0ZXN0aGFzaHRlc3RoYXNoMTIz",
    id = "u1",
    claims = Json.JsonNull,
  }
}

fn build(): App {
  let app = App(Config{ secret = "change-me", sessions = MemoryStore(10_000) })
  let lookup: Lookup = users

  let login = app.group("/login")
  login.use(requireAuth([]Strategy{ newPasswordStrategy(lookup) }))
  login.post("/", (c) => c.text("welcome"))

  app.get("/me", (c) => {
    let identity: Identity = currentIdentity(c) catch _ {
      fail unauthorized()
    }
    return c.text(identity.id)
  })
  return app
}
```

`requireAuth` is mounted on the `/login` group only, not on the whole app: it
reads the POST body's credentials, runs every `Strategy` in the list until
one succeeds, regenerates the session id, and stores the resulting
`Identity` - see [Security model](security.md) for why the regeneration
matters. `/me` is a plain route that reads what got stored: `currentIdentity`
fails when there is nothing there, and the handler turns that into a 401
with `unauthorized()` rather than leaking the internal error text.

A wrong password and an unknown username fail with the exact same error and
do the same amount of work, so neither timing nor the response body tells an
attacker which one they hit.

Next: [Sign in with Google](oidc.md), for a second `Strategy` beside this
one.
