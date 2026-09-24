# Verifying a token directly

A native mobile app or a single-page app sometimes completes the OIDC flow
itself, using the provider's own SDK, and sends your API a bare ID token
instead of a session cookie. There is no redirect to handle - you only need
to verify the token it already has. `beginAuthorization` and `handleCallback`
are the wrong tool here; the pieces they are built on are exported so you can
call them yourself.

## The three pieces

- `discover(issuer, tls)` fetches the provider's discovery document into an
  `OidcConfig` - the same first step `newOidcStrategy` takes.
- `newJwksCache(jwksUri, tls)` builds a `JwksCache` that keeps the provider's
  signing keys fresh, refetching on an unrecognized key id.
- `verifyIdToken(token, config, jwks, nonce, opts)` checks the signature
  against the right key, the issuer, the audience, expiry, and the nonce, and
  returns the verified claims.

```bit
import { OidcConfig, JwksCache, discover, newJwksCache, verifyIdToken } from "auth"
import { newTlsConfig, newTrustStore } from "std/tls"
import { defaultClaimsOptions } from "std/jwt"
import { Json, jsonEncode } from "std/json"
import { now, Second } from "std/time"

class TokenVerifier {
  config: OidcConfig,
  jwks: JwksCache,
  clientId: string,
}

fn newTokenVerifier(issuer: string, clientId: string, rootsPem: string): TokenVerifier! {
  let tls = newTlsConfig(newTrustStore(rootsPem)?)
  let config = discover(issuer, tls)?
  let jwks = newJwksCache(config.jwksUri, tls)?
  return TokenVerifier{ config = config, jwks = jwks, clientId = clientId }
}

// `expectedNonce` is whatever value your mobile flow generated and handed to
// the provider's SDK before it minted the token - this package has no
// session to read one from here, unlike `handleCallback`.
fn verifyMobileToken(v: TokenVerifier, idToken: string, expectedNonce: string): Json! {
  let opts = defaultClaimsOptions(now().ns / Second)
  opts.expectedAud = Option.Some(v.clientId)
  return verifyIdToken(idToken, v.config, v.jwks, expectedNonce, opts)?
}
```

`newJwksCache` fetches the key set once, up front, so a verifier built at
startup is ready for the first request with no extra round trip; a later
request for an unrecognized key id triggers at most one refetch per minute,
so a burst of tokens signed with a just-rotated key costs one HTTP call, not
one per request.

## Wiring it into a route

```bit
import { Ctx, Res, unauthorized } from "web"

fn meHandler(v: TokenVerifier, c: Ctx): Res! {
  let claims = verifyMobileToken(v, c.header("Authorization"), c.header("X-Nonce")) catch _ {
    fail unauthorized()
  }
  return c.text(jsonEncode(claims))
}
```

Build one `TokenVerifier` per provider at startup and reuse it across
requests - `JwksCache` is safe under concurrent calls for exactly this
reason.

Next: [Security model](security.md), for what every path through this
package checks and why.
