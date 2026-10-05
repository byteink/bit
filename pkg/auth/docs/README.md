# pkg/auth docs

The chapters below, in reading order.

| Chapter | Covers |
| ------- | ------ |
| [Getting started](getting-started.md) | A password login: hash and look up a user, protect a route, read who is calling. |
| [Sign in with Google](oidc.md) | Add an OpenID Connect provider beside the password login, PKCE included. |
| [Sign in with Apple](apple.md) | `Provider.Apple`: a client secret signed from your `.p8` key on every exchange, the form_post callback and the state store it needs, the name that arrives once, and the private relay email. |
| [Testing your sign-in routes](testing.md) | Drive your OIDC callback route against a fake, in-process provider with zero real network calls. |
| [Other OIDC providers](providers.md) | Microsoft Entra ID, one tenant or many, and any other conformant provider. |
| [Sign in with GitHub, or any OAuth 2.0 provider](oauth2.md) | A provider with no ID token: the authorization-code flow with PKCE, a profile fetch that yields the `Identity`, client authentication, `iss` checks, typed provider errors, and a fake provider for tests. |
| [Verifying a token directly](manual-verification.md) | A mobile or single-page client that already holds an ID token, with no redirect. |
| [Two-factor authentication with TOTP](totp.md) | A second login step with an authenticator app: enrollment, verifying a code, skew and replay protection, recovery codes for a lost phone, and the pending session that keeps a password alone out of the app until the code is right. |
| [Let an author sign in with a passkey](passkeys.md) | Register a passkey: the relying party and its origins, the options for the browser, verifying the response and storing the public key, attestation `none`, the checks and their error messages, a credential store of your own, and the policy options. |
| [Check a new password](password-policy.md) | An opt-in policy for new passwords after NIST SP 800-63B: length in code points, normalization recorded in the hash, context words, blocklists, runs, an optional breach check, and why there is no composition rule or expiry. |
| [Slow down password guessing](brute-force.md) | Throttle failed logins per account and per address: backoff, lockout, reset on success, an audit trail. |
| [One-time tokens for account emails](account-tokens.md) | The token behind password reset, email verification and magic links: hashed at rest, single use, expiring, one purpose each. |
| [Confirm an author's email address](email-verification.md) | Email verification on one-time tokens: send a link at signup, confirm it once, resend without revealing which addresses exist, and what happens when the address changes. |
| [Sign in with a link in an email](magic-link.md) | Passwordless login on one-time tokens: ask for a link, open it in the same browser, only the newest works, the same answer for every address, and a page that mail scanners cannot spend. |
| [Let an author reset a forgotten password](password-reset.md) | Password reset on one-time tokens: the same answer for every address, a single-use hour-long link, the new password checked by `PasswordPolicy` without spending the link, every session of the author ended, and a failed mail that reaches your log and not the form. |
| [Bearer tokens for an API](bearer-tokens.md) | Sign in once, call the JSON API with a JWT access token: a pinned algorithm, audience and issuer checks, key rotation without logging anyone out, clock skew, and the 401 a client should get. |
| [API keys for scripts and integrations](api-keys.md) | A long-lived key for a build server or a partner: a recognisable prefix and checksum, SHA-256 at rest, scopes, expiry, last-used, revoke, constant-time checks, and the strategy that reads it from `Authorization: Bearer` or `X-API-Key`. |
| [Refresh tokens that notice theft](refresh-tokens.md) | Stay signed in for weeks on an opaque refresh token: rotation on every use, reuse of an old token ending the whole login, an absolute lifetime cap, a grace window for retries, revoke, and a store of your own. |
| [Sign an author out of every device](logout-everywhere.md) | "Sign out everywhere" and "sign out my other devices" after a password change: `logoutEverywhere`, `Keep`, the index every login files its session under, and `bindSession` for a `Strategy` of your own. |
| [Security model](security.md) | What this package checks for you, and the one thing it cannot: your token exchange TLS roots. |

For install and the exported surface, see [`pkg/auth/README.md`](../README.md).
