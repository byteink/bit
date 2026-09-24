# Security model

What this package checks for every request, stated plainly, and the one
thing it cannot check for you.

## PKCE, S256 only

`beginAuthorization` always sends a PKCE `code_challenge` computed with
S256 (RFC 7636) - never the `plain` method, which exists in the standard only
for a client that cannot compute SHA-256. `handleCallback` proves possession
of the matching `code_verifier` as part of the token exchange, so a stolen
authorization code is useless to whoever intercepted it without also holding
the verifier your server generated and kept server-side.

## The state check runs before any network call, in constant time

`handleCallback` compares the `state` query parameter against the value
`beginAuthorization` stored, byte for byte, in constant time - a timing
side-channel on that comparison would let an attacker learn a valid `state`
one byte at a time. This is the very first thing the callback does: a wrong
or missing `state` fails before your server ever makes an HTTP request to
the provider's token endpoint, so a forged callback costs your app nothing
but the comparison.

`state`, `nonce` and the PKCE `code_verifier` are each single-use: the
callback consumes them atomically from the session, so two requests racing
the same callback URL - a replay, or a browser that fired it twice - resolve
to exactly one success. The second sees the identical failure a `state` that
was never issued would produce; neither case is distinguishable from the
other in the response.

## The session id is regenerated on every successful login

Both `newPasswordStrategy`'s strategy and `handleCallback` call
`Session.regenerate()` (`pkg/web`) the moment they have a verified identity,
before storing it. This closes session fixation: without it, a session id an
attacker set on a victim before login stays valid after login, so the
attacker's own known id now carries an authenticated session. Regenerating
on every privilege change, not only at login, is what the OWASP Session
Management Cheat Sheet recommends, and every login path in this package
follows it - there is no path that stores an `Identity` without it.

## Microsoft Entra ID: single tenant only

`microsoftStrategy` refuses the three multi-tenant aliases Microsoft
documents - `common`, `organizations`, `consumers` - before making any
request. See [Other OIDC providers](providers.md) for why: `discover()`'s
issuer check, which every strategy in this package relies on, cannot be
satisfied by a document served under one of those aliases.

## Scopes default to `openid`, and stay that way

`newOidcStrategy` requests `openid` alone unless you widen it.
`withScopes(s, scopes)` replaces a strategy's scope list outright, and
refuses any list missing `openid` - every strategy this package builds is
doing OpenID Connect, never bare OAuth2, so a scope list that drops the one
scope that makes it OIDC is rejected rather than silently accepted:

```bit
import { OidcStrategy, withScopes } from "auth"

fn rejectsMissingOpenid(s: OidcStrategy): bool {
  withScopes(s, ["email"]) catch _ {
    return true
  }
  return false
}
```

## What this package cannot check: your TLS roots

`discover`, `newJwksCache` and the token exchange all take an explicit
`TlsConfig` (`std/tls`) rather than a package default, because nothing in
`std/tls` or this package exports a way to build a secure-by-default trust
store from outside those modules. Supplying `insecureSkipVerify: true`, or a
`TlsConfig` built from roots you do not actually trust, defeats every check
above - the token exchange and JWKS fetch are only as trustworthy as the
certificate chain you configured them to verify.
