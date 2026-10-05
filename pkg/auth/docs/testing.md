# Testing your sign-in routes

<!-- doctest: per-block -->

[Sign in with Google](oidc.md) wired two routes:

```text
app.get("/auth/google", (c) => beginAuthorization(oidc, c))
app.get("/auth/google/callback", (c) => {
  let identity: Identity = handleCallback(oidc, c)?
  return c.redirect("/me")
})
```

`handleCallback` POSTs to Google's real token endpoint and reads Google's
real JWKS. That is exactly what you want in production and exactly what you
cannot have in a test: CI has no business reaching `accounts.google.com`,
and a real provider gives you no way to force an expired token or a wrong
nonce on demand.

The route above does not change for a test. `OidcStrategy` carries a
`tokenFetch` field, set through `OidcOptions` - `nil` means the real network
call, the same way every constructor in this package defaults it - and
`handleCallback` reads it off the strategy value instead of taking it as a
parameter. Build `oidc` from `Provider.Endpoints` with a fake `tokenFetch`
and a JWKS cache that already knows its keys, and the identical route code runs end to end against a provider you
control, with zero network access.

## A fake provider, the same route

The pieces below - a config literal, an already-parsed JWKS, a fake token
endpoint - are all a fake OIDC provider is. Nothing here is a special test
function: `beginAuthorization` and `handleCallback` are the two calls
`oidc.md`'s route registration already makes.

<!-- doctest: test-file -->
```bit
import { App, Config, MemoryStore } from "web"
import {
  JwksCache, JwksSource, OidcConfig, OidcOptions, OidcStrategy, Provider, TokenFetch,
  beginAuthorization, handleCallback,
} from "auth"
import { Request } from "std/http"
import { emptyTrustStore, TlsConfig } from "std/tls"
import { encodeBase64Url, hmac, HashAlg } from "std/crypto"
import { Json, JsonEntry, jsonEncode } from "std/json"
import { parseJwks } from "std/jwt"
import { now, Second } from "std/time"
import { split } from "std/strings"

const fakeIssuer = "https://fake-provider.test"
const fakeClientId = "test-client-id"
const fakeKid = "test-key"

fn fakeSecret(): []byte { return []byte("test-hmac-secret-do-not-use-in-prod") }

class TokenBox { idToken: string }

fn fakeTokenFetch(box: TokenBox): TokenFetch {
  let f: TokenFetch = (url, headers, body) => {
    return "{\"id_token\":\"" + box.idToken + "\"}"
  }
  return f
}

// Everything a real `discover()`/`JwksCache(...)` would have fetched over
// HTTPS, written by hand instead: `OidcConfig`'s fields are already public
// data, and `JwksSource.Parsed` wraps an already-parsed `Jwks` - built
// with `std/jwt`'s own `parseJwks` - with no HTTP call at all, not even to
// a local server. `tokenFetch` is the one field production code always
// leaves `nil`.
fn buildFakeStrategy(box: TokenBox): OidcStrategy! {
  let tls = TlsConfig(emptyTrustStore())
  let config = OidcConfig{
    issuer = fakeIssuer,
    authorizationEndpoint = fakeIssuer + "/authorize",
    tokenEndpoint = fakeIssuer + "/token",
    jwksUri = fakeIssuer + "/jwks",
  }
  let jwksDoc = "{\"keys\":[{\"kty\":\"oct\",\"kid\":\"" +
    fakeKid +
    "\",\"k\":\"" +
    encodeBase64Url(fakeSecret()) +
    "\"}]}"
  let jwks = parseJwks(jwksDoc)?
  let cache = JwksCache(config.jwksUri, tls, JwksSource.Parsed(jwks))?
  return OidcStrategy(
    Provider.Endpoints(config, cache),
    fakeClientId,
    "test-client-secret",
    "https://app.example.com/auth/google/callback",
    OidcOptions{ tokenFetch = fakeTokenFetch(box) },
  )?
}

// A signed ID token naming `nonce` - `std/jwt`'s own `sign` never writes a
// `kid` header, and `verifyIdToken` reads `kid` first, so a fake token is
// hand-assembled the same way this package's own tests build one.
fn fakeIdToken(nonce: string): string {
  let header = jsonEncode(
    Json.JsonObject(
      [
        JsonEntry{ key = "alg", value = Json.JsonString("HS256") },
        JsonEntry{ key = "typ", value = Json.JsonString("JWT") },
        JsonEntry{ key = "kid", value = Json.JsonString(fakeKid) },
      ],
    ),
  )
  let nowSeconds = now().ns / Second
  let payload = jsonEncode(
    Json.JsonObject(
      [
        JsonEntry{ key = "iss", value = Json.JsonString(fakeIssuer) },
        JsonEntry{ key = "aud", value = Json.JsonString(fakeClientId) },
        JsonEntry{ key = "sub", value = Json.JsonString("fake-user-1") },
        JsonEntry{ key = "exp", value = Json.JsonInt(i64(nowSeconds + 3600)) },
        JsonEntry{ key = "iat", value = Json.JsonInt(i64(nowSeconds - 10)) },
        JsonEntry{ key = "nonce", value = Json.JsonString(nonce) },
      ],
    ),
  )
  let signingInput = encodeBase64Url([]byte(header)) + "." + encodeBase64Url([]byte(payload))
  let sig = hmac(HashAlg.Sha256, fakeSecret(), []byte(signingInput))
  return signingInput + "." + encodeBase64Url(sig)
}

// Your real route handlers, unchanged from production - `oidc.md`'s own
// `app.get("/auth/google", ...)`/`app.get("/auth/google/callback", ...)`
// lines, verbatim. Only `s`, built above, is a fake.
fn testApp(s: OidcStrategy): App {
  let app = App(Config{ secret = "test-secret", sessions = MemoryStore(1000) })
  app.get("/auth/google", (c) => beginAuthorization(s, c))
  app.get("/auth/google/callback", (c) => {
    let identity = handleCallback(s, c)?
    return c.text(identity.id)
  })
  app.freeze() catch e {
    panic("freeze: ${e.message()}")
  }
  return app
}

fn testReq(path: string, cookie: string): Request {
  if (len(cookie) == 0) {
    return Request{ method = "GET", path = path, headers = "", body = "" }
  }
  return Request{ method = "GET", path = path, headers = "Cookie: " + cookie, body = "" }
}

// `state` and `nonce` never need to be read back out of the session: both
// are already in the redirect's query string, the same place your browser
// would carry them to the real provider and back.
fn paramFrom(query: string, name: string): string {
  return split(split(query, "${name}=")[1], "&")[0]
}

test "the unmodified callback route returns the verified fake identity, no network" {
  let box = TokenBox{ idToken = "" }
  let strategy = buildFakeStrategy(box) catch e {
    panic("buildFakeStrategy: ${e.message()}")
  }
  let app = testApp(strategy)

  let begin = app.handle(testReq("/auth/google", ""))
  assert(begin.status == 302, "want a redirect, got ${begin.status}")
  let cookie = begin.getHeader("Set-Cookie")
  let location = begin.getHeader("Location")
  let state = paramFrom(location, "state")
  let nonce = paramFrom(location, "nonce")
  box.idToken = fakeIdToken(nonce)

  let callback = "/auth/google/callback?code=fake-code&state=" + state
  let res = app.handle(testReq(callback, cookie))

  assert(res.status == 200, "want 200, got ${res.status}: ${res.body}")
  assert(res.body == "fake-user-1", "want the fake identity's id, got '${res.body}'")
}
```

## A fake Apple

`Provider.Endpoints` cannot carry the `AppleKey` that `Provider.Apple` needs, so
Apple is faked one layer lower: `OidcOptions.discoveryFetch` is a function from
a URL to the body served there, used for the discovery document and the JWKS, and
the real constructor runs against it. The page on [Sign in with
Apple](apple.md#testing-your-apple-routes) shows the strategy; here is a whole
test, driving `beginAuthorization` and Apple's cookie-less form-POST
`handleCallback`:

<!-- doctest: test-file -->
```bit
import { App, Config, MemoryStore } from "web"
import {
  AppleKey, HttpFetch, MemoryOneTimeStore, OidcOptions, OidcStrategy, OneTimeStore,
  Provider, TokenFetch, beginAuthorization, handleCallback,
} from "auth"
import { Request } from "std/http"
import { encodeBase64Url, hmac, HashAlg } from "std/crypto"
import { Json, JsonEntry, jsonEncode } from "std/json"
import { now, Second } from "std/time"
import { split } from "std/strings"

const appleHost = "https://appleid.apple.com"
const clientId = "com.example.inkwell.web"
const kid = "test-key"

// A throwaway P-256 key made for this page; it signs nothing Apple ever sees.
const p8 = "-----BEGIN PRIVATE KEY-----\n" +
  "MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQghoAqb0cpl8arBQT+\n" +
  "ebu4YgIUHiTTdFxPu2tgoaseJ0+hRANCAAQlERh2AAc44f8m3cJ6AotPl0/3cjr8\n" +
  "BwqhlqfZUPvqpyqOhc0WOKkLsGfGYGJUjXB90JzKlsXcKqNNS3a8c+8u\n" +
  "-----END PRIVATE KEY-----\n"

fn hmacKey(): []byte { return []byte("test-hmac-secret-do-not-use-in-prod") }

// What Apple would serve: the discovery document, then the JWKS it points to.
fn fakeApple(): HttpFetch {
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
      return "{\"keys\":[{\"kty\":\"oct\",\"kid\":\"" +
        kid +
        "\",\"k\":\"" +
        encodeBase64Url(hmacKey()) +
        "\"}]}"
    }
    fail newError("unexpected GET ${url}")
  }
  return f
}

class TokenBox { idToken: string }

fn fakeTokenEndpoint(box: TokenBox): TokenFetch {
  let f: TokenFetch = (url, headers, body) => {
    return "{\"id_token\":\"" + box.idToken + "\"}"
  }
  return f
}

fn appleStrategy(box: TokenBox): OidcStrategy! {
  let key = AppleKey("ABCDE12345", "KEYID67890", p8)?
  let states: OneTimeStore = MemoryOneTimeStore()
  return OidcStrategy(
    Provider.Apple(key),
    clientId,
    "",
    "https://app.example.com/auth/apple/callback",
    OidcOptions{
      stateStore = Option.Some(states),
      discoveryFetch = fakeApple(),
      tokenFetch = fakeTokenEndpoint(box),
    },
  )?
}

// A signed ID token naming `nonce`, the way Apple's would, with the fake JWKS key.
fn idToken(nonce: string): string {
  let header = jsonEncode(
    Json.JsonObject(
      [
        JsonEntry{ key = "alg", value = Json.JsonString("HS256") },
        JsonEntry{ key = "kid", value = Json.JsonString(kid) },
      ],
    ),
  )
  let t = now().ns / Second
  let payload = jsonEncode(
    Json.JsonObject(
      [
        JsonEntry{ key = "iss", value = Json.JsonString(appleHost) },
        JsonEntry{ key = "aud", value = Json.JsonString(clientId) },
        JsonEntry{ key = "sub", value = Json.JsonString("001234.abcdef.5678") },
        JsonEntry{ key = "exp", value = Json.JsonInt(i64(t + 3600)) },
        JsonEntry{ key = "iat", value = Json.JsonInt(i64(t - 10)) },
        JsonEntry{ key = "nonce", value = Json.JsonString(nonce) },
      ],
    ),
  )
  let input = encodeBase64Url([]byte(header)) + "." + encodeBase64Url([]byte(payload))
  return input + "." + encodeBase64Url(hmac(HashAlg.Sha256, hmacKey(), []byte(input)))
}

fn param(query: string, name: string): string {
  return split(split(query, "${name}=")[1], "&")[0]
}

test "the unmodified Apple routes sign a user in against a fake Apple, no network" {
  let box = TokenBox{ idToken = "" }
  let s = appleStrategy(box) catch e {
    panic("appleStrategy: ${e.message()}")
  }
  // The same two routes apple.md registers.
  let app = App(Config{ secret = "test-secret", sessions = MemoryStore(1000) })
  app.get("/auth/apple", (c) => beginAuthorization(s, c))
  app.post("/auth/apple/callback", (c) => {
    let who = handleCallback(s, c)?
    return c.text(who.id)
  })
  app.freeze() catch e {
    panic("freeze: ${e.message()}")
  }

  let begin = app.handle(Request{ method = "GET", path = "/auth/apple", headers = "", body = "" })
  assert(begin.status == 302, "want a redirect, got ${begin.status}")
  let location = begin.getHeader("Location")
  box.idToken = idToken(param(location, "nonce"))

  // Apple's answer is a cookie-less form POST carrying the state it was given.
  let form = Request{
    method = "POST",
    path = "/auth/apple/callback",
    headers = "Content-Type: application/x-www-form-urlencoded",
    body = "code=apple-code&state=" + param(location, "state"),
  }
  let res = app.handle(form)
  assert(res.status == 200, "want 200, got ${res.status}: ${res.body}")
  assert(res.body == "001234.abcdef.5678", "want the token's sub, got '${res.body}'")
}
```

## Sharp edges

The seam replaces the transport only. `verifyIdToken` still checks the
signature against the JWKS key named by `kid`, the issuer against the
discovered `config.issuer`, the audience against your client id, the nonce
against the session's, and expiry against the clock - a fake token built
with the wrong issuer or an expired `exp` fails exactly as a real one would.
Setting `tokenFetch` or building a `JwksCache` from a hand-parsed `Jwks`
skips no check; it only decides where the bytes came from.

A `JwksCache` built from `JwksSource.Parsed` still enforces the rate-limited
refetch-on-miss that one built from `JwksSource.Remote` does (a `kid` your fake JWKS never listed refetches through
whatever `fetch` you pass it, `nil` included) - a fake key set is not
exempt from the cooldown that protects a real JWKS endpoint.

To fake Microsoft's `common` or `organizations` sign-in, write the config
the same way with `multiTenant = true` and the template
`https://login.microsoftonline.com/{tenantid}/v2.0` as `issuer`, and sign the
fake token with a `tid` claim and the matching `iss`; `allowedTenants` on the
config is the allow-list `OidcOptions.allowedTenants` fills in production. The
issuer, GUID and allow-list checks run on a fake token exactly as on a real
one.

`Provider.Endpoints` is not the only way to skip the network. For the providers
that discover their endpoints (`Google`, `Microsoft`, `Generic`, `Apple`),
`OidcOptions.discoveryFetch` is a function from a URL to the body served there,
used for the discovery document and the JWKS, so the real constructor runs
against a fake provider; [A fake Apple](#a-fake-apple) is the worked example.

Setting `tokenFetch` or `discoveryFetch` on a strategy your production code
builds is the one way to misuse these seams: a strategy is configuration your
app builds once at startup, so a non-`nil` `tokenFetch` or `discoveryFetch`
reaching a real deployment means some code path constructed the strategy wrong,
not that `handleCallback` itself needs different production and test versions.

Next: [Security model](security.md), for the full list of checks this
package runs on your behalf.
