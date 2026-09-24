# Other OIDC providers

Not everyone signs in with Google. This chapter covers Microsoft Entra ID,
where the tenant you configure matters more than it looks like it should, and
any other OIDC-conformant provider your team already runs.

## Microsoft Entra ID: one tenant, not "any Microsoft account"

`microsoftStrategy(tenant, ...)` takes a real tenant - a tenant id (a GUID)
or a verified domain - never `common`, `organizations` or `consumers`, the
three multi-tenant aliases Microsoft also documents. Those aliases serve a
discovery document whose own `issuer` does not match the URL you configured
(`common`/`organizations` echo back the literal, unsubstituted template
string; `consumers` serves a different fixed tenant's issuer entirely), so
`discover()`'s byte-for-byte issuer check - the same one every strategy in
this package relies on - can never accept them. `microsoftStrategy` refuses
all three itself, before ever making a request, rather than building a
strategy that would fail the first time someone tried to use it.

```bit
import { OidcStrategy, microsoftStrategy } from "auth"
import { newTlsConfig, newTrustStore } from "std/tls"

fn microsoft(tenantId: string, rootsPem: string): OidcStrategy! {
  let tls = newTlsConfig(newTrustStore(rootsPem)?)
  return microsoftStrategy(
    tenantId,
    "your-client-id",
    "your-client-secret",
    "https://app.example.com/auth/microsoft/callback",
    tls,
  )?
}
```

If your app genuinely needs to accept sign-ins from any Microsoft account
across tenants, that needs validating the token's tenant against an
allow-list at verification time rather than one fixed issuer, which this
package does not do yet - configure one real tenant per `microsoftStrategy`
call today.

## Any other conformant provider

`genericOidcStrategy(issuer, ...)` is Google and Microsoft's own presets with
no issuer transformation: point it at any provider that publishes a standard
`/.well-known/openid-configuration` document, and it requests the same
`openid email profile` scopes the named presets do.

```bit
import { genericOidcStrategy } from "auth"

fn okta(oktaDomain: string, rootsPem: string): OidcStrategy! {
  let tls = newTlsConfig(newTrustStore(rootsPem)?)
  return genericOidcStrategy(
    "https://${oktaDomain}",
    "your-client-id",
    "your-client-secret",
    "https://app.example.com/auth/okta/callback",
    tls,
  )?
}
```

## Building a strategy with no preset scopes

Every preset above widens the scope list with `withScopes` before handing
the strategy back. `newOidcStrategy` is what they are built on: the same
discovery and JWKS setup, but its default scope list is `openid` alone. Call
it directly when you want to choose your scopes from a blank slate instead of
overriding a preset's:

```bit
import { newOidcStrategy } from "auth"

fn minimalScopeProvider(issuer: string, rootsPem: string): OidcStrategy! {
  let tls = newTlsConfig(newTrustStore(rootsPem)?)
  return newOidcStrategy(
    issuer,
    "your-client-id",
    "your-client-secret",
    "https://app.example.com/auth/callback",
    tls,
  )?
}
```

Next: [Verifying a token directly](manual-verification.md), for a client
that already holds an ID token and skips the redirect entirely.
