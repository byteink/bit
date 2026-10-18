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
  beginAuthorization, currentIdentity, endSession, handleBackchannelLogout, handleCallback, handleLogoutCallback,
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
  let sessions = MemoryStore(10_000)
  let app = App(Config{ secret = "change-me", sessions = sessions })
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
  app.post("/auth/google/backchannel", (c) => handleBackchannelLogout(oidc, c, sessions)?)

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

## When the provider signs the user out

An enterprise provider can end a user's login while the browser is closed.
Without a back-channel route, your application's session would remain active
until its own expiry. The example's `/auth/google/backchannel` route shows
`handleBackchannelLogout(oidc, c, sessions)`: give it the same strategy and
session store that the sign-in routes use. Register that absolute route URL
with a provider that supports OpenID Connect Back-Channel Logout. A provider
that does not support the protocol will not call this route.

The provider sends a POST form containing `logout_token`. The handler checks
the signature with the strategy's JWKS, its issuer and client audience, a
required `jti`, `iat` and `exp`, and the back-channel logout event object. A
`nonce` claim is forbidden. An absent `typ` header is accepted for providers
that omit this recommended header; a present header must be `logout+jwt`.
These checks follow [Back-Channel Logout 1.0 sections 2.4-2.8](https://openid.net/specs/openid-connect-backchannel-1_0.html).

This package also sets local bounds: the compact token is at most 16,384
bytes, and each issuer, subject, sid and jti string is at most 1,024 bytes.
The issued-at time must be within the previous 300 seconds. Expiry must be
later than both now and issued-at, and no more than 300 seconds ahead of
now. Logout checks use no clock skew allowance. These are application
policies, not limits set by the protocol; synchronize the provider and server
clocks. ID-token clock skew behavior stays the same.

A `sid` token ends sessions for that sid and verified issuer. A token with
only `sub` ends all sessions for that subject and issuer. Sessions from a
different issuer survive, even when its sid or subject is identical. The
ordinary subject index used by `logoutEverywhere` stays available. Callback
sessions retain the verified provider subject separately from `Identity.id`,
so mapping that exported id to a local account keeps provider logout working.
The ordinary subject index follows the local id. Callback
sessions waiting for MFA are indexed too, and promotion carries their
indexes to the rotated session. A later non-OIDC login removes the old
provider indexes; arbitrary `Identity.claims` cannot create provider
provenance. Existing sessions created before this feature have no provider
provenance and acquire it on the next OIDC login.

A successful request returns 200, including when no matching session remains.
Every failed request returns 400 with `{"error":"invalid_request"}`. Both
responses carry `Cache-Control: no-store`.

Each long-lived strategy holds at most 10,000 replay records, keyed by issuer
and jti. An in-flight request claims its record before destroying sessions;
a concurrent duplicate is refused, even if the original token expires while
the store call runs. Successful requests retain their records until expiry.
A full cache refuses another request and never evicts a live record. A store
failure releases the claim, so the provider can retry the same token. A store
that partly completed a failed operation must allow an idempotent retry;
already-removed sessions count as success.

Replay history belongs to one strategy instance in one process. Reuse the
strategy created at application startup. Separate instances and processes
have separate histories, and a restart loses the history. A crash after
revocation but before recording success also loses that record; a retry can
repeat the idempotent revocation. Applications that require durable replay
protection across processes must enforce issuer-and-jti deduplication in
their shared infrastructure. Session revocation itself uses the configured
session store and reaches every session indexed there.
