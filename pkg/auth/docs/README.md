# pkg/auth docs

The chapters below, in reading order.

| Chapter | Covers |
| ------- | ------ |
| [Getting started](getting-started.md) | A password login: hash and look up a user, protect a route, read who is calling. |
| [Sign in with Google](oidc.md) | Add an OpenID Connect provider beside the password login, PKCE included. |
| [Testing your sign-in routes](testing.md) | Drive your OIDC callback route against a fake, in-process provider with zero real network calls. |
| [Other OIDC providers](providers.md) | Microsoft Entra ID, one tenant or many, and any other conformant provider. |
| [Verifying a token directly](manual-verification.md) | A mobile or single-page client that already holds an ID token, with no redirect. |
| [Two-factor authentication with TOTP](totp.md) | A second login step with an authenticator app: enrollment, verifying a code, skew and replay protection. |
| [Slow down password guessing](brute-force.md) | Throttle failed logins per account and per address: backoff, lockout, reset on success, an audit trail. |
| [Security model](security.md) | What this package checks for you, and the one thing it cannot: your token exchange TLS roots. |

For install and the exported surface, see [`pkg/auth/README.md`](../README.md).
