# Sign in with Google

Some of your users would rather not have another password. This chapter adds
"Sign in with Google" beside the password login from
[Getting started](getting-started.md), as a second `Strategy` sharing the
same `/me` route - neither login method needs to know the other exists.

## Two routes: begin, then come back

The OIDC authorization-code flow is two requests, not one call:
`beginAuthorization` redirects the browser to Google with a PKCE challenge,
and `handleCallback` runs when Google redirects back, exchanging the code for
an ID token and verifying it. Both take the `OidcStrategy` a provider preset
builds and the request's `Ctx` - wire them straight onto two routes.

```bit
import { App, Config, MemoryStore, unauthorized } from "web"
import {
  Identity, Lookup, LookupResult, OidcStrategy, Strategy,
  beginAuthorization, currentIdentity, googleStrategy, handleCallback,
  newPasswordStrategy, requireAuth, withScopes,
} from "auth"
import { newTlsConfig, newTrustStore } from "std/tls"
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

// `rootsPem` is your deployment's trusted CA bundle - this package never
// guesses one; see std/tls's `newTrustStore`.
fn google(rootsPem: string): OidcStrategy! {
  let tls = newTlsConfig(newTrustStore(rootsPem)?)
  let s = googleStrategy(
    "your-client-id.apps.googleusercontent.com",
    "your-client-secret",
    "https://app.example.com/auth/google/callback",
    tls,
  )?
  return withScopes(s, ["openid", "email"])?
}

fn build(rootsPem: string): App! {
  let app = App(Config{ secret = "change-me", sessions = MemoryStore(10_000) })
  let lookup: Lookup = users
  let oidc = google(rootsPem)?

  let login = app.group("/login")
  login.use(requireAuth([]Strategy{ newPasswordStrategy(lookup) }))
  login.post("/", (c) => c.text("welcome"))

  app.get("/auth/google", (c) => beginAuthorization(oidc, c))
  app.get("/auth/google/callback", (c) => {
    let identity: Identity = handleCallback(oidc, c)?
    return c.redirect("/me")
  })

  app.get("/me", (c) => {
    let identity: Identity = currentIdentity(c) catch _ {
      fail unauthorized()
    }
    return c.text(identity.id)
  })
  return app
}
```

`handleCallback` does everything `requireAuth` would have done for a
password login - regenerate the session id, store the `Identity` - so `/me`
reads it back the same way regardless of which route the user actually came
through. Neither `beginAuthorization` nor `handleCallback` goes through
`requireAuth([]Strategy{...})`: `OidcStrategy` is configuration, not a
`Strategy` itself, because the flow is two separate requests, not one
`authenticate(c)` call.

## Choosing scopes

`googleStrategy` already requests `openid email profile`. `withScopes`
replaces a strategy's scope list outright - useful when you want less, or a
scope Google's preset does not request by default. It refuses any list
missing `openid`, since every strategy this package builds is doing OpenID
Connect, never bare OAuth2:

```bit
fn scopesMustIncludeOpenid(s: OidcStrategy): OidcStrategy {
  return withScopes(s, ["profile"]) catch _ {
    // fails: "openid" is required
    return s
  }
}
```

Next: [Other OIDC providers](providers.md), for Microsoft Entra ID and any
other conformant provider.
