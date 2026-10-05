# Sign in with Apple

Inkwell ships an iPhone app, and the App Store asks an app that offers Google
sign-in to offer Apple's too. Apple speaks OpenID Connect, so
[`OidcStrategy`](oidc.md) already does most of the work, but four things are
different enough to bite: the client secret is a token you sign yourself, the
answer comes back as a cross-site POST, the user's name arrives once and never
again, and the email may be a throwaway address. `Provider.Apple` handles all
four.

## What you take from Apple's developer account

Four values, none of which this package can guess:

- the **Services ID**, which is the `clientId`;
- the **Team ID**, ten characters, shown top right in the account;
- the **Key ID**, ten characters, of a key with "Sign in with Apple" enabled;
- the **`.p8` file** of that key, which Apple lets you download once.

The `.p8` is a PEM-encoded P-256 private key. `AppleKey` parses it, checks that it
really is P-256, and keeps it. You register the callback under the Services ID as
a return URL; Apple insists it is `https`, has a domain name, and is not
`localhost`.

```bit
import { App, Config, MemoryStore, unauthorized } from "web"
import {
  AppleKey,
  Identity,
  MemoryOneTimeStore,
  OidcOptions,
  OidcStrategy,
  OneTimeStore,
  Provider,
  beginAuthorization,
  currentIdentity,
  handleCallback,
} from "auth"
import { TlsConfig } from "std/tls"
import { fromPem } from "std/crypto"

// `rootsPem` is your deployment's trusted CA bundle; `p8` is the text of the
// downloaded AuthKey file.
fn apple(rootsPem: string, p8: string): OidcStrategy! {
  let tls = TlsConfig(fromPem(rootsPem)?)
  let key = AppleKey("ABCDE12345", "KEYID67890", p8)?
  let states: OneTimeStore = MemoryOneTimeStore()
  return OidcStrategy(
    Provider.Apple(key),
    "com.example.inkwell.web",
    "",
    "https://app.example.com/auth/apple/callback",
    OidcOptions{ tls = Option.Some(tls), stateStore = Option.Some(states) },
  )?
}

fn build(rootsPem: string, p8: string): App! {
  let app = App(Config{ secret = "change-me", sessions = MemoryStore(10_000) })
  let oidc = apple(rootsPem, p8)?

  app.get("/auth/apple", (c) => beginAuthorization(oidc, c))
  app.post("/auth/apple/callback", (c) => {
    let who: Identity = handleCallback(oidc, c)?
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

The begin route is the one every provider has. The callback is registered with
`app.post`, because Apple sends the browser back with a form POST
(`response_mode=form_post`, which Apple requires as soon as you ask for the name
or the email). A `GET` to it is a 400.

The third argument to `OidcStrategy` is `""` on purpose. There is no client secret
to configure: `handleCallback` signs a fresh one for every code exchange, a JWT
with the `.p8` key (ES256, header `kid` = key id; claims `iss` = team id, `sub` =
client id, `aud` = `https://appleid.apple.com`, `iat`, and an `exp` five minutes
out; Apple allows six months). Nothing is stored, so there is no secret to rotate
or to leak. Passing a non-empty one is an error.

## Why there is a state store

Every other provider keeps `state` and the `nonce` on the user's session. Apple's
POST comes from another site, so a session cookie with `SameSite=Lax` is not sent
with it, and the session would be empty exactly when the callback needs it.
`stateStore` is where the login in flight waits instead: any
[`OneTimeStore`](account-tokens.md), such as `MemoryOneTimeStore` for one process
or a database or Redis table behind several. The `state` Apple echoes back is a
one-time token: 256 random bits, only its hash is stored, redeemable once and good for
a quarter of an hour. Its record carries the `nonce`. A replayed, expired or
invented `state` is the same 401 and never reaches Apple.

A consequence worth knowing: because no cookie ties the callback to the browser
that started it, `state` proves the request came from your begin route, not from
the same person. The ID token's `nonce` and your `redirectUri` registration are
the rest of the protection, which is the most a cross-site POST can carry.

If your app runs the CSRF middleware, exempt this one route: Apple cannot send
your token.

## The name arrives once

Apple does not put the user's name in the ID token. On the first authorization
only, the POST carries a `user` field, JSON such as
`{"name":{"firstName":"Ada","lastName":"Lovelace"}}`. `handleCallback` reads it
and puts `given_name` and `family_name` on `Identity.claims`. The next sign-in
does not have them, so persist them in the same request that creates the account:

```bit
import { Json, jsonAsString, jsonGet } from "std/json"
import { isSome, unwrap } from "std/core"

fn claimText(claims: Json, key: string): string {
  let v = jsonGet(claims, key)
  if (!isSome(v)) {
    return ""
  }
  let s = jsonAsString(unwrap(v))
  if (!isSome(s)) {
    return ""
  }
  return unwrap(s)
}

fn newAuthor(who: Identity): string {
  return claimText(who.claims, "given_name") + " " + claimText(who.claims, "family_name")
}
```

The `user` field comes from the browser, not from Apple's signature, so it is held
to less trust than the token: a value that is not JSON is ignored, and a name
longer than 128 bytes or with a control character in it is dropped, never
failing the login. Escape it when you render it, like any user input.

## The email may be a relay

A user can hide their address. Apple then puts a relay address such as
`abc123@privaterelay.appleid.com` in `email`, and `is_private_email` is true. Mail
sent there is forwarded only if your sending domain is registered with Apple. Both
`email_verified` and `is_private_email` arrive as a JSON boolean or the string
`"true"`; the claims you get always hold booleans, and anything that is not
`true` reads as `false`, so a verified email is never inferred from a surprise.

## Scopes

`OidcOptions.scopes` keeps the OIDC names other providers use. For Apple, `email`
asks for the email, `profile` asks for the name, and `openid` is implied. The
default list, `openid email profile`, therefore sends `scope=email name`. Anything
else, such as `phone`, fails at construction because Apple would silently ignore
it.

## Testing your Apple routes

`OidcStrategy(Provider.Apple(key), ...)` discovers Apple's endpoints and keys
over TLS when it is built, so a test would reach `appleid.apple.com` before it
ran a single route. `OidcOptions.discoveryFetch` is the seam for that half, the
way `tokenFetch` is for the code exchange: a function from a URL to the body
served there, called for Apple's discovery document and for the JWKS the
document names, and again when a key is rotated. Left `nil` it is the real TLS
fetch. When it is set, `tls` is not required. The constructor, and every check
it makes, runs unchanged, so the strategy under test is the one production
builds:

```bit
import { HttpFetch, TokenFetch } from "auth"

const appleHost = "https://appleid.apple.com"

// What Apple would serve: the discovery document, then the JWKS it points to.
fn fakeApple(jwks: string): HttpFetch {
  let f: HttpFetch = (url) => {
    if (url == appleHost + "/.well-known/openid-configuration") {
      return "{\"issuer\":\"" +
        appleHost +
        "\"," +
        "\"authorization_endpoint\":\"" +
        appleHost +
        "/auth/authorize\"," +
        "\"token_endpoint\":\"" +
        appleHost +
        "/auth/token\"," +
        "\"jwks_uri\":\"" +
        appleHost +
        "/auth/keys\"}"
    }
    if (url == appleHost + "/auth/keys") {
      return jwks
    }
    fail newError("unexpected GET ${url}")
  }
  return f
}

// The strategy `apple` builds, with Apple replaced by `fakeApple` and the
// token endpoint by `tokens`. Nothing else differs.
fn appleUnderTest(p8: string, jwks: string, tokens: TokenFetch): OidcStrategy! {
  let key = AppleKey("ABCDE12345", "KEYID67890", p8)?
  let states: OneTimeStore = MemoryOneTimeStore()
  return OidcStrategy(
    Provider.Apple(key),
    "com.example.inkwell.web",
    "",
    "https://app.example.com/auth/apple/callback",
    OidcOptions{
      stateStore = Option.Some(states),
      discoveryFetch = fakeApple(jwks),
      tokenFetch = tokens,
    },
  )?
}
```

Hand it a throwaway P-256 key, a JWKS you control and a `tokenFetch` that answers
with an ID token you signed, and the routes above, `beginAuthorization` and the
form-POST `handleCallback`, run unchanged against it. The complete test, ID token
included, is in [Testing your sign-in routes](testing.md#a-fake-apple). The ID
token is checked exactly as a real one is: signature against the key named by
`kid`, issuer, audience, nonce and expiry. Use `discoveryFetch` only in tests: a
strategy your app builds at startup leaves it `nil`.

## Mistakes that fail at construction

`AppleKey(...)` and `OidcStrategy(...)` return an error, so the app does not
start, for each of these:

- a team id or key id that is not ten characters of `A-Z` and `0-9`;
- a `.p8` that is not exactly one PKCS#8 `PRIVATE KEY` PEM block, or whose key is
  not P-256;
- `Provider.Apple` without `OidcOptions.stateStore`, or `stateStore` on any other
  provider;
- a non-empty client secret;
- a `redirectUri` that is not `https` or has a `#` fragment;
- a scope other than `openid`, `email` and `profile`;
- no `tls`, which the discovery of Apple's keys needs, unless
  `discoveryFetch` is set (see [Testing your Apple routes](#testing-your-apple-routes)).

Apple's pages document no PKCE for either endpoint, so none is sent: the client
authenticates with the signed secret, and the `nonce` binds the ID token to your
request.

Next: [Sign in with GitHub](oauth2.md) for providers with no ID token, or the
[Security model](security.md).
