# Testing your sign-in routes

<!-- doctest: per-block -->

[Sign in with Google](oidc.md) wired `/auth/google/callback` to
`handleCallback`, which POSTs to Google's real token endpoint and fetches
Google's real JWKS. That is exactly what you want in production and exactly
what you cannot have in a test: CI has no business reaching
`accounts.google.com`, and a real provider gives you no way to force an
expired token or a wrong nonce on demand.

`discover`, `newJwksCache` and `handleCallback` each have an injectable
sibling - `discoverFetch`, `newJwksCacheFetch` and `handleCallbackFetch` -
taking one extra parameter, a fetch function, that the production entry
points always pass as `nil` ("make the real call"). Pass your own instead,
and the same route handler runs end to end against a provider you control,
with zero network access.

## A fake provider in one test file

The three canned documents below - a discovery document, a JWKS, and a
signed ID token - are all a fake OIDC provider is: no server, no port, just
the strings `discoverFetch`/`newJwksCacheFetch`/`handleCallbackFetch` would
otherwise have fetched over HTTPS.

<!-- doctest: test-file -->
```bit
import { App, Config, MemoryStore } from "web"
import {
  HttpFetch, OidcStrategy, TokenFetch,
  beginAuthorization, discoverFetch, handleCallbackFetch, newJwksCacheFetch,
} from "auth"
import { Request } from "std/http"
import { emptyTrustStore, newTlsConfig } from "std/tls"
import { encodeBase64Url, hmac, newSha256 } from "std/crypto"
import { Json, JsonEntry, jsonEncode } from "std/json"
import { now, Second } from "std/time"
import { split } from "std/strings"

const fakeIssuer = "https://fake-provider.test"
const fakeClientId = "test-client-id"
const fakeKid = "test-key"

fn fakeSecret(): []byte { return []byte("test-hmac-secret-do-not-use-in-prod") }

// The fake provider's two GET endpoints: `discoverFetch` calls this once for
// the discovery document, `newJwksCacheFetch` once for the JWKS - neither
// ever reaches a real network.
fn buildFakeStrategy(): OidcStrategy! {
  let tls = newTlsConfig(emptyTrustStore())

  let discoveryDoc = "{\"issuer\":\"" +
    fakeIssuer +
    "\"," +
    "\"authorization_endpoint\":\"" +
    fakeIssuer +
    "/authorize\"," +
    "\"token_endpoint\":\"" +
    fakeIssuer +
    "/token\"," +
    "\"jwks_uri\":\"" +
    fakeIssuer +
    "/jwks\"}"
  let discoverOnce: HttpFetch = (url) => {
    return discoveryDoc
  }
  let config = discoverFetch(fakeIssuer, tls, discoverOnce)?

  let jwksDoc = "{\"keys\":[{\"kty\":\"oct\",\"kid\":\"" +
    fakeKid +
    "\"," +
    "\"k\":\"" +
    encodeBase64Url(fakeSecret()) +
    "\"}]}"
  let jwksOnce: HttpFetch = (url) => {
    return jwksDoc
  }
  let jwks = newJwksCacheFetch(config.jwksUri, tls, jwksOnce)?

  return OidcStrategy{
    config = config,
    clientId = fakeClientId,
    clientSecret = "test-client-secret",
    redirectUri = "https://app.example.com/auth/google/callback",
    jwks = jwks,
    scopes = ["openid"],
  }
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
  let sig = hmac(newSha256, fakeSecret(), []byte(signingInput))
  return signingInput + "." + encodeBase64Url(sig)
}

class TokenBox { idToken: string }

fn fakeTokenFetch(box: TokenBox): TokenFetch {
  let f: TokenFetch = (url, headers, body) => {
    return "{\"id_token\":\"" + box.idToken + "\"}"
  }
  return f
}

// Your real route handlers, unchanged from production - only the
// `OidcStrategy` and the token fetch passed in are fakes.
fn testApp(s: OidcStrategy, box: TokenBox): App {
  let app = App(Config{ secret = "test-secret", sessions = MemoryStore(1000) })
  app.get("/auth/google", (c) => beginAuthorization(s, c))
  app.get("/auth/google/callback", (c) => {
    let identity = handleCallbackFetch(s, c, fakeTokenFetch(box))?
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

test "the callback route returns the verified fake identity, no network" {
  let strategy = buildFakeStrategy() catch e {
    panic("buildFakeStrategy: ${e.message()}")
  }
  let box = TokenBox{ idToken = "" }
  let app = testApp(strategy, box)

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

## Sharp edges

The seam replaces the transport only. `verifyIdToken` still checks the
signature against the JWKS key named by `kid`, the issuer against the
discovered `config.issuer`, the audience against your client id, the nonce
against the session's, and expiry against the clock - a fake token built
with the wrong issuer or an expired `exp` fails exactly as a real one would.
Nothing about `discoverFetch`/`newJwksCacheFetch`/`handleCallbackFetch` skips
or weakens those checks; they only decide where the bytes come from.

Passing a fetch through in production code is the one way to misuse this
seam: `discoverFetch(issuer, tls, myFetch)` with a real `myFetch` still
means "trust `myFetch` instead of TLS to a real provider". Production code
should call `discover`/`newJwksCache`/`handleCallback` (or a provider preset
like `googleStrategy`), which always pass `nil` - never wire a fetch
parameter through your own app's configuration.

Next: [Security model](security.md), for the full list of checks this
package runs on your behalf.
