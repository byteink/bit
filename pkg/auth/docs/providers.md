# Other OIDC providers

Not everyone signs in with Google. This chapter covers Microsoft Entra ID,
where the tenant you configure matters more than it looks like it should, and
any other OIDC-conformant provider your team already runs.

## Microsoft Entra ID: one tenant, not "any Microsoft account"

`Provider.Microsoft(tenant)` takes a real tenant - a tenant id (a GUID)
or a verified domain - never `common`, `organizations` or `consumers`, the
three multi-tenant aliases Microsoft also documents. Those aliases serve a
discovery document whose own `issuer` does not match the URL you configured
(`common`/`organizations` echo back the literal, unsubstituted template
string; `consumers` serves a different fixed tenant's issuer entirely), so
`discover()`'s byte-for-byte issuer check - the same one every strategy in
this package relies on - can never accept them. `OidcStrategy(...)` refuses
all three itself, before ever making a request, rather than building a
strategy that would fail the first time someone tried to use it.

```bit
import { OidcOptions, OidcStrategy, Provider } from "auth"
import { TlsConfig } from "std/tls"
import { fromPem } from "std/crypto"

fn microsoft(tenantId: string, rootsPem: string): OidcStrategy! {
  let tls = TlsConfig(fromPem(rootsPem)?)
  return OidcStrategy(
    Provider.Microsoft(tenantId),
    "your-client-id",
    "your-client-secret",
    "https://app.example.com/auth/microsoft/callback",
    OidcOptions{ tls = Option.Some(tls) },
  )?
}
```

If your app genuinely needs to accept sign-ins from any Microsoft account
across tenants, that needs validating the token's tenant against an
allow-list at verification time rather than one fixed issuer, which this
package does not do - configure one real tenant per `OidcStrategy`.

## Any other conformant provider

`Provider.Generic(issuer)` is Google and Microsoft's own providers with no
issuer transformation: point it at any provider that publishes a standard
`/.well-known/openid-configuration` document, and it requests the same
`openid email profile` scopes the named providers do.

```bit
fn okta(oktaDomain: string, rootsPem: string): OidcStrategy! {
  let tls = TlsConfig(fromPem(rootsPem)?)
  return OidcStrategy(
    Provider.Generic("https://${oktaDomain}"),
    "your-client-id",
    "your-client-secret",
    "https://app.example.com/auth/okta/callback",
    OidcOptions{ tls = Option.Some(tls) },
  )?
}
```

## Providers you have already discovered

`Provider.Google`, `Provider.Microsoft` and `Provider.Generic` all run
discovery over `OidcOptions.tls`, which is therefore required for them -
leaving it out fails at construction, naming the option. `Provider.Endpoints`
takes an `OidcConfig` and a `JwksCache` you already hold, makes no network
call, and ignores `tls`; it is what [Testing your sign-in
routes](testing.md) builds a fake provider from. Whichever you pick,
`OidcOptions.scopes` left empty requests `openid email profile`; set it to
choose your scopes from a blank slate:

```bit
fn minimalScopeProvider(issuer: string, rootsPem: string): OidcStrategy! {
  let tls = TlsConfig(fromPem(rootsPem)?)
  return OidcStrategy(
    Provider.Generic(issuer),
    "your-client-id",
    "your-client-secret",
    "https://app.example.com/auth/callback",
    OidcOptions{ tls = Option.Some(tls), scopes = ["openid"] },
  )?
}
```

Next: [Verifying a token directly](manual-verification.md), for a client
that already holds an ID token and skips the redirect entirely.
