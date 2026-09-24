# pkg/auth

Authentication for [`pkg/web`](../web). An app proves who is calling in one
of two ways: a password checked against a lookup you supply, or an OpenID
Connect provider like Google or Microsoft Entra ID. Both produce the same
`Identity`, stored on the request's session, so the rest of your app never
needs to know which one ran.

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
import { App, Config, MemoryStore, unauthorized } from "web"
import {
  Identity,
  Lookup,
  LookupResult,
  Strategy,
  currentIdentity,
  newPasswordStrategy,
  requireAuth,
} from "auth"
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

`requireAuth` runs a request through one or more `Strategy` values until one
authenticates it, regenerates the session id, and stores the result. A
protected route that is not itself doing the authenticating just reads
`currentIdentity(c)` and turns a miss into `unauthorized()`.

## The exported surface

- `Strategy`, `Identity` - the seam every authentication method implements,
  and what a successful one produces.
- `requireAuth`, `currentIdentity` - the middleware that runs a `Strategy`
  list, and the accessor a protected route reads the result with.
- `hashPassword`, `Lookup`, `LookupResult`, `newPasswordStrategy` - a
  password `Strategy` over your own user lookup, Argon2id underneath.
- `OidcStrategy`, `newOidcStrategy`, `withScopes`, `beginAuthorization`,
  `handleCallback` - the OpenID Connect authorization-code flow with PKCE.
- `googleStrategy`, `microsoftStrategy`, `genericOidcStrategy` - provider
  presets over `newOidcStrategy`.
- `OidcConfig`, `discover`, `JwksCache`, `newJwksCache`, `verifyIdToken` - the
  discovery document and key set `OidcStrategy` is built from, and the ID
  token verifier, for a client that already holds a token and skips the
  redirect flow.

Every one of these is used in a full example in [`docs/`](docs/README.md),
along with the security properties this package enforces (PKCE, constant-time
state comparison, session regeneration, and the Microsoft single-tenant
restriction).

For how first-party packages in this repository are laid out, gated,
versioned and released, see [`pkg/README.md`](../README.md).
