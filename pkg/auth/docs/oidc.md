# Sign in with Google

Some of your users would rather not have another password. This chapter adds
"Sign in with Google" beside the password login from
[Getting started](getting-started.md), as a second `Strategy` sharing the
same `/me` route - neither login method needs to know the other exists.

## Two routes: begin, then come back

The OIDC authorization-code flow is two requests, not one call:
`beginAuthorization` redirects the browser to Google with a PKCE challenge,
and `handleCallback` runs when Google redirects back, exchanging the code for
an ID token and verifying it. Both take the `OidcStrategy` built for a
`Provider` and the request's `Ctx` - wire them straight onto two routes.

```bit
import { App, Config, MemoryStore, unauthorized } from "web"
import {
  Identity, Lookup, LookupResult, LogoutOptions, OidcOptions, OidcStrategy, Provider, Strategy,
  beginAuthorization, currentIdentity, endSession, handleCallback, handleLogoutCallback,
  PasswordStrategy, requireAuth,
} from "auth"
import { TlsConfig } from "std/tls"
import { fromPem } from "std/crypto"
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
// guesses one; see `fromPem` in std/crypto.
fn google(rootsPem: string): OidcStrategy! {
  let tls = TlsConfig(fromPem(rootsPem)?)
  return OidcStrategy(
    Provider.Google,
    "your-client-id.apps.googleusercontent.com",
    "your-client-secret",
    "https://app.example.com/auth/google/callback",
    OidcOptions{
      tls = Option.Some(tls),
      scopes = ["openid", "email"],
      postLogoutRedirectUris = ["https://app.example.com/signed-out"],
    },
  )?
}

fn build(rootsPem: string): App! {
  let app = App(Config{ secret = "change-me", sessions = MemoryStore(10_000) })
  let lookup: Lookup = users
  let oidc = google(rootsPem)?

  let login = app.group("/login")
  login.use(requireAuth([]Strategy{ PasswordStrategy(lookup) }))
  login.post("/", (c) => c.text("welcome"))

  app.get("/auth/google", (c) => beginAuthorization(oidc, c))
  app.get("/auth/google/callback", (c) => {
    let identity: Identity = handleCallback(oidc, c)?
    return c.redirect("/me")
  })

  app.get("/logout", (c) => {
    return endSession(
      oidc,
      c,
      LogoutOptions{ postLogoutRedirectUri = "https://app.example.com/signed-out" },
    )?
  })
  app.get("/signed-out", (c) => handleLogoutCallback(c, c.text("You are signed out"))?)

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

`OidcOptions.scopes` left out requests `openid email profile` from every
provider. Set it to replace the list outright - useful when you want less,
or a scope the default does not request, as the route registration above
does with `["openid", "email"]`. The constructor refuses any list missing
`openid`, since every strategy this package builds is doing OpenID Connect,
never bare OAuth2:

```bit
fn scopesMustIncludeOpenid(tls: TlsConfig): bool {
  OidcStrategy(
    Provider.Google,
    "your-client-id",
    "your-client-secret",
    "https://app.example.com/auth/google/callback",
    OidcOptions{ tls = Option.Some(tls), scopes = ["profile"] },
  ) catch _ {
    // fails: "openid" is required
    return true
  }
  return false
}
```

## Signing out

`Session.destroy()` alone signs the user out of your app, not out of Google.
Google's own session survives, so the next "Sign in with Google" click logs
the user straight back in with no prompt. OpenID Connect RP-Initiated Logout
1.0 closes that gap: the app sends the browser to the provider's
`end_session_endpoint`, and the provider ends its session too.

`endSession` does it in one call, as the `/logout` route above shows. It
destroys your local session first, so a failure after that point never leaves
the user signed in, then redirects with the four parameters the specification
defines: `id_token_hint` (the ID token `handleCallback` kept in the session),
`client_id`, `post_logout_redirect_uri` and `state`. Pass nothing, `endSession(oidc,
c)`, to leave the landing page to the provider; then neither
`post_logout_redirect_uri` nor `state` is sent.

`post_logout_redirect_uri` must be one of the values you registered, byte for
byte, in `OidcOptions.postLogoutRedirectUris` (and with the provider). Anything
else, another host, `http://` instead of `https://`, a trick like
`https://app.example.com@evil.example/`, makes `endSession` fail with an
`Error` before it destroys anything, so no request of yours can turn the
provider into an open redirect. Registrations are checked when the strategy is
built: each must be `https` (`http` is accepted only for `localhost`,
`127.0.0.1` and `[::1]`) and carry no userinfo and no fragment.

When the provider sends the browser back, `handleLogoutCallback` checks the
returned `state` against the one this browser was issued, in constant time and
once, and hands back the response you give it, here the "You are signed out"
text, or fails with 401. The `state` rides in a short-lived `HttpOnly`,
`Secure`, `SameSite=Lax` cookie, because the session it would otherwise live in
was just destroyed. `LogoutOptions` also takes `logoutHint` and `uiLocales`
(`logout_hint` and `ui_locales`) for providers that use them.

### When the provider has no `end_session_endpoint`

Not every provider publishes one, and Google does not (its discovery document
has no `end_session_endpoint`, checked 2026-10-05), while Microsoft Entra ID
does. Where it is missing, `OidcConfig.endSessionEndpoint` is `None` and
`endSession` can only log out locally: it destroys your session and sends the
browser straight to `postLogoutRedirectUri` (or `/`). **The provider session
stays alive**, and the next sign-in may succeed without a password prompt. Check
at startup if that matters to you:

```bit
fn endsProviderSession(oidc: OidcStrategy): bool {
  match (oidc.config.endSessionEndpoint) {
    Some(_) => return true
    None => return false
  }
}
```

An app that needs the provider session gone for such a provider has to link
users to that provider's own sign-out page.

Next: [Other OIDC providers](providers.md), for Microsoft Entra ID and any
other conformant provider.
