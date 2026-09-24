# pkg/auth docs

The chapters below, in reading order.

| Chapter | Covers |
| ------- | ------ |
| [Getting started](getting-started.md) | A password login: hash and look up a user, protect a route, read who is calling. |
| [Sign in with Google](oidc.md) | Add an OpenID Connect provider beside the password login, PKCE included. |
| [Other OIDC providers](providers.md) | Microsoft Entra ID's single-tenant requirement, and any other conformant provider. |
| [Verifying a token directly](manual-verification.md) | A mobile or single-page client that already holds an ID token, with no redirect. |
| [Security model](security.md) | What this package checks for you, and the one thing it cannot: your token exchange TLS roots. |

For install and the exported surface, see [`pkg/auth/README.md`](../README.md).
