# Other OIDC providers

Not everyone signs in with Google. This chapter covers Microsoft Entra ID,
where the tenant you configure matters more than it looks like it should, and
any other OIDC-conformant provider your team already runs.

## Microsoft Entra ID: one tenant, or many

Inkwell is for one company, so `Provider.Microsoft(tenant)` takes that
company's tenant - a tenant id (a GUID) or a verified domain. Every token the
strategy accepts then carries exactly that tenant's issuer, byte-for-byte,
which is what stops a user from some other company's Entra tenant signing in
to yours.

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

### Sign-in from any tenant

Suppose Inkwell becomes a product other companies sign in to with their own
work accounts. One tenant per strategy no longer fits, so Microsoft offers
three aliases in place of a tenant:

| Tenant value | Who can sign in |
| --- | --- |
| `organizations` | work and school accounts, from any tenant |
| `consumers` | personal Microsoft accounts only |
| `common` | both |

The catch is the issuer. A token's `iss` names the user's own tenant, but the
discovery document for `common` and `organizations` publishes the literal
template `https://login.microsoftonline.com/{tenantid}/v2.0`, and the document
for `consumers` publishes the personal-account tenant's issuer rather than the
`consumers` URL it was fetched from. A fixed-string issuer comparison can
never accept any of them. Microsoft's own rule for this case ([Validate the ID
token](https://learn.microsoft.com/en-us/entra/identity-platform/v2-protocols-oidc))
is to read the token's `tid` claim, substitute it into the template, and
compare that with `iss`. `OidcStrategy` does exactly that for you:

```bit
fn microsoftAnyTenant(rootsPem: string): OidcStrategy! {
  let tls = TlsConfig(fromPem(rootsPem)?)
  return OidcStrategy(
    Provider.Microsoft("organizations"),
    "your-client-id",
    "your-client-secret",
    "https://app.example.com/auth/microsoft/callback",
    OidcOptions{ tls = Option.Some(tls) },
  )?
}
```

Verification checks, after the signature, in this order:

- `tid` is present and is a GUID, so nothing in a token can add a path, a
  query or a second placeholder to the issuer built from it;
- `iss` equals `https://login.microsoftonline.com/{tid}/v2.0` with that `tid`
  substituted, exactly - not a prefix, not a different case;
- `aud`, `exp`, `nonce` and the rest are checked as for every other provider.

`consumers` needs no template: its fixed issuer is Microsoft's personal-account
tenant (`9188040d-6c67-4c5b-b112-36a304b66dad`), so the strategy is pinned to
it and a work-account token is refused.

### Which tenants may sign in

"Any tenant" is rarely what a product wants: a paid plan covers the companies
that bought it. `OidcOptions.allowedTenants` lists the tenant ids
(GUIDs) allowed to sign in; a token whose `tid` is not on the list is
rejected even though its issuer is genuine. Left empty it allows any tenant,
which is the right default only when you check the user yourself afterwards.

```bit
fn microsoftCustomers(rootsPem: string, customerTenants: []string): OidcStrategy! {
  let tls = TlsConfig(fromPem(rootsPem)?)
  return OidcStrategy(
    Provider.Microsoft("organizations"),
    "your-client-id",
    "your-client-secret",
    "https://app.example.com/auth/microsoft/callback",
    OidcOptions{ tls = Option.Some(tls), allowedTenants = customerTenants },
  )?
}
```

The sharp edges, each a construction failure rather than a surprise later:

- `allowedTenants` on any provider other than `Provider.Microsoft("common")`
  or `Provider.Microsoft("organizations")` is refused - on a single tenant or
  `consumers` it would restrict nothing and read as if it did;
- an entry that is not a GUID (a domain name such as `contoso.onmicrosoft.com`
  is the usual one) is refused, naming the entry; the `tid` claim is always a
  GUID, so a domain could never match.

A strategy you build yourself with `Provider.Endpoints` sets the same two
things on its `OidcConfig`: `multiTenant = true` with the template as `issuer`,
and `allowedTenants`. [Testing your sign-in routes](testing.md) describes the
shape.

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
`OidcOptions.scopes` left out requests `openid email profile`; set it to
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
