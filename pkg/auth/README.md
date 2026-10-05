# pkg/auth

Authentication for [`pkg/web`](../web). An app proves who is calling in one
of two ways: a password checked against a lookup you supply, or an OpenID
Connect provider like Google or Microsoft Entra ID. Both produce the same
`Identity`, stored on the request's session, so the rest of your app never
needs to know which one ran.

## Install

`bit add bitlang.org/pkg/auth@^0.6.0` (and `bitlang.org/pkg/web@^0.9.0`, which
it runs on) writes:

```json
{
  "dependencies": {
    "auth": "bitlang.org/pkg/auth@^0.6.0",
    "web": "bitlang.org/pkg/web@^0.9.0"
  }
}
```

## Usage

```bit
import { App, Config, MemoryStore, unauthorized } from "web"
import {
  Identity,
  Lookup,
  LookupResult,
  Strategy,
  currentIdentity,
  PasswordStrategy,
  requireAuth,
} from "auth"
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

fn build(): App {
  let app = App(Config{ secret = "change-me", sessions = MemoryStore(10_000) })
  let lookup: Lookup = users

  let login = app.group("/login")
  login.use(requireAuth([]Strategy{ PasswordStrategy(lookup) }))
  login.post("/", (c) => c.text("welcome"))

  app.get("/me", (c) => {
    let identity: Identity = currentIdentity(c) catch _ {
      fail unauthorized()
    }
    return c.text(identity.id)
  })
  return app
}
```

`requireAuth` runs a request through one or more `Strategy` values until one
authenticates it, regenerates the session id, and stores the result. A
protected route that is not itself doing the authenticating just reads
`currentIdentity(c)` and turns a miss into `unauthorized()`.

## The exported surface

- `Strategy`, `Identity` - the seam every authentication method implements,
  and what a successful one produces.
- `requireAuth`, `currentIdentity` - the middleware that runs a `Strategy`
  list, and the accessor a protected route reads the result with.
- `logoutEverywhere`, `Keep`, `bindSession`, `subjectIndexKey` - destroy every
  session of one user (`Keep.Current(c)` spares the caller's), over the index
  every login files its session under; `bindSession` is what a `Strategy` of
  your own calls after `Session.regenerate()`; see
  [Sign an author out of every device](docs/logout-everywhere.md).
- `hashPassword`, `Lookup`, `LookupResult`, `PasswordStrategy` - a
  password `Strategy` over your own user lookup, Argon2id underneath.
- `PasswordOptions`, `AuthEvent`, `AuthEventHook` - the optional second
  argument of `PasswordStrategy`: a `LoginThrottle` to consult and an audit
  hook told every login.
- `PasswordPolicy`, `PolicyOptions`, `PolicyContext`, `Violation`, `PolicyViolations`,
  `BreachCheck`, `BreachMode` - the opt-in check of a new password after NIST SP
  800-63B: one `check` returning every rule broken, `hash` for the set side
  (it records NFKC in the stored hash, which `PasswordStrategy` follows); see
  [Check a new password](docs/password-policy.md).
- `PwnedPasswords`, `PwnedOptions`, `RangeFetch` - the Have I Been Pwned range
  check as a `BreachCheck`: only 5 hex digits of the password's SHA-1 leave, and
  `endpoint` points it at a copy of the data you host; see
  [Check against Have I Been Pwned](docs/password-policy.md#check-against-have-i-been-pwned).
- `LoginThrottle`, `ThrottleOptions`, `Throttled`, `ThrottleEvent`,
  `ThrottleHook`, `ThrottleKind` - the brute-force defence: per-account and
  per-address failure counters over `pkg/web`'s `RateStore`, backoff, lockout,
  reset on success; see [Slow down password guessing](docs/brute-force.md).
- `OidcStrategy`, `Provider`, `OidcOptions`, `beginAuthorization`,
  `handleCallback` - the OpenID Connect authorization-code flow with PKCE;
  `Provider` names the identity provider (`Google`, `Microsoft(tenant)`,
  `Generic(issuer)`, `Endpoints(config, jwks)`) and `OidcOptions` carries the
  scopes, the `TlsConfig` and the token-exchange seam.
- `AppleKey`, `Provider.Apple`, `OidcOptions.stateStore` - Sign in with Apple: `AppleKey(teamId,
  keyId, p8Pem)` parses the .p8 and fails at startup for anything but a P-256 key,
  `handleCallback` signs an ES256 client secret per exchange, and the form_post
  callback keeps `state` and `nonce` in a `OneTimeStore` because Apple's POST carries no
  session cookie; the first-login name surfaces as `given_name`/`family_name` and
  `email_verified`/`is_private_email` are booleans; see
  [Sign in with Apple](docs/apple.md).
- `OAuth2Strategy`, `OAuth2Endpoints`, `OAuth2Options`, `ClientAuth`,
  `ProfileFetch`, `OAuth2Error`, `OAuth2ErrorKind` - the OAuth 2.0
  authorization-code flow with PKCE for providers that issue no ID token (GitHub,
  Discord, Slack): `beginAuthorization` and `authenticate` are the two routes, a
  `ProfileFetch` you supply turns the access token into an `Identity`, and a
  provider's refusal arrives as a typed `OAuth2Error`; see
  [Sign in with GitHub](docs/oauth2.md).
- `github`, `GithubOptions`, `GithubFetch`, `OAuth2Endpoints.defaultScopes` - Sign in with GitHub on
  `OAuth2Strategy`: `github(opts)` returns GitHub's endpoints and a profile step whose
  `Identity.id` is the numeric user id (never the login) and whose `email` is the primary
  address only when GitHub has verified it; `enterpriseHost` targets GitHub Enterprise
  Server, `requireVerifiedEmail` decides whether a missing one fails the sign-in, and
  `apiFetch` is the test seam, and the endpoints carry the `read:user user:email` scopes themselves; see [Sign in with GitHub](docs/oauth2.md#github-in-one-function).
- `endSession`, `handleLogoutCallback`, `LogoutOptions`,
  `OidcOptions.postLogoutRedirectUris`, `OidcConfig.endSessionEndpoint` - OpenID
  Connect RP-Initiated Logout 1.0: `endSession` destroys the local session, then
  sends the browser to the provider's `end_session_endpoint` with `id_token_hint`,
  `client_id`, `post_logout_redirect_uri` and `state`; the redirect target must be
  registered, and a provider with no endpoint gets a local-only logout; see
  [Signing out](docs/oidc.md#signing-out).
- `OidcConfig`, `discover`, `JwksCache`, `JwksSource`, `verifyIdToken` - the
  discovery document and key set `OidcStrategy` is built from, and the ID
  token verifier, for a client that already holds a token and skips the
  redirect flow.
- `HttpFetch`, `TokenFetch`, `JwksSource.Parsed`, `Provider.Endpoints`, `OidcOptions.tokenFetch`
  - the seam for testing your own callback route: `tokenFetch` in the options of a strategy
  you build is `handleCallback`'s fake token-exchange endpoint, and
  `JwksSource.Parsed` wraps an already-parsed `Jwks` with no network call
  - so `beginAuthorization`/`handleCallback` run unmodified against a fake
  provider; see [Testing your sign-in routes](docs/testing.md).
- `Secret`, `generateSecret`, `parseSecret`, `provisioningUri`,
  `ProvisioningOptions`, `hotp`, `totp`, `verify`, `Algorithm`, `sha1` - TOTP
  (RFC 6238) two-factor codes: enrollment, the `otpauth://` QR-code URI, and
  verifying a submitted code with a skew window and caller-owned replay
  protection.
- `OneTimeTokens`, `OneTimeStore`, `OneTimeRecord`, `OneTimeOptions`,
  `Live`, `MemoryOneTimeStore`, `InvalidToken`, `Deliver` - the one-time token behind
  password reset, email verification and magic links: 256 random bits stored
  only as a SHA-256 hash, bound to a purpose, expiring, redeemed once, with a
  pluggable store and the `Deliver` function the app supplies to send them; see
  [One-time tokens for account emails](docs/account-tokens.md).
- `EmailVerification`, `VerifyOptions`, `verifyLink` - email verification on the
  one-time token: `send` mails a link and atomically revokes the earlier ones, `confirm`
  spends it once and calls your `markVerified`, refusing it when the address
  changed or for any reason in the one `InvalidToken`; `verifyLink` builds the
  link from a base URL the app configures; see
  [Confirm an author's email address](docs/email-verification.md).
- `MagicLinkStrategy`, `MagicLinkOptions`, `MagicLinkUser`, `MagicLinkErrorHook` -
  passwordless login by a mailed link, a `Strategy` on the one-time token:
  `request` mails a link that replaces the earlier ones and answers the same
  for every address, `authenticate` spends it once, refuses another browser's
  copy, and regenerates the session id; optionally throttled with a
  `LoginThrottle`; see [Sign in with a link in an email](docs/magic-link.md).
- `PasswordReset`, `ResetOptions`, `ResetErrorHook` - password reset on the
  one-time token: `request` mails a one-hour link that replaces the earlier
  ones and answers the same for every identifier, `confirm` spends it once,
  applies the `PasswordPolicy` without spending the link on a refusal, stores
  the new hash with your `setPassword` and ends every session of the user with
  `logoutEverywhere`; see
  [Let an author reset a forgotten password](docs/password-reset.md).
- `RefreshTokens`, `RefreshStore`, `RefreshRecord`, `RefreshOptions`,
  `RefreshRotation`, `MemoryRefreshStore`, `InvalidRefreshToken` - opaque refresh
  tokens (RFC 9700): 256 random bits stored only as a SHA-256 hash, rotated on
  every use, with reuse of a rotated token revoking the whole login, an
  absolute lifetime cap, an optional grace window, `revoke` and `revokeSubject`,
  and a pluggable store whose `rotate` is atomic; see
  [Refresh tokens that notice theft](docs/refresh-tokens.md).
- `AccessTokens`, `KeySet`, `TokenOptions`, `BearerStrategy`, `BearerChallenge` -
  JWT bearer access tokens for an API (RFC 9068): `issue` signs one with a
  pinned algorithm, `kid` and a random `jti`, `verify` refuses `none`, a wrong
  `typ`, issuer or audience and an expired token, keys rotate by listing the
  retired one, and `BearerStrategy` answers a failure with the 401 and
  `WWW-Authenticate` header RFC 6750 asks for, never saying why; see
  [Bearer tokens for an API](docs/bearer-tokens.md).
- `ApiKeys`, `ApiKeyOptions`, `ApiKeyStore`, `ApiKeyRecord`, `MemoryApiKeyStore`,
  `CreatedKey`, `InvalidApiKey`, `ApiKeyStrategy`, `hasScope` - API keys for scripts
  and integrations: a prefix and CRC-32 checksum so typos and leaks are caught,
  the SHA-256 of the secret at rest, scopes, expiry, throttled last-used,
  revoke, a constant-time check that answers every failure the same way, and a
  `Strategy` reading `Authorization: Bearer` or `X-API-Key`; see
  [API keys for scripts and integrations](docs/api-keys.md).
- `generateRecoveryCodes`, `RecoveryOptions`, `RecoverySet`,
  `redeemRecoveryCode`, `RedeemOptions`, `RecoveryRedeem` - single-use
  recovery codes for a lost authenticator: generated from the CSPRNG, stored
  as Argon2id hashes, redeemed at the cost of one hash, optionally throttled
  with a `LoginThrottle`, and replaced wholesale by regenerating.

Every one of these is used in a full example in [`docs/`](docs/README.md),
along with the security properties this package enforces (PKCE, constant-time
state comparison, session regeneration, and Microsoft's per-token tenant
check).

For how first-party packages in this repository are laid out, gated,
versioned and released, see [`pkg/README.md`](../README.md).
