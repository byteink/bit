# TLS

MySQL does not negotiate TLS the way HTTPS does: there is no TLS port and no
ALPN. The server greets in the clear; a client that wants TLS answers with the
first 32 bytes of a handshake response with `CLIENT_SSL` set, and the next
byte on the same socket starts the TLS handshake. A server that advertises
`CLIENT_SSL` and then fails the handshake is **not** downgraded to
plaintext - the plaintext rung belongs only to a server that never offered TLS
at all.

## `ssl-mode`

The setting is spelled MySQL's way and maps onto `std/sql`'s shared `SslMode`:

| `ssl-mode=` | rung |
|---|---|
| `VERIFY_IDENTITY` | chain and hostname verified |
| `VERIFY_CA` | chain verified, hostname not checked |
| `REQUIRED` | encrypted, certificate not verified |
| `DISABLED` | cleartext |

Case does not matter. `PREFERRED` is **not** accepted: it names the fallback
behavior that omitting `ssl-mode` already gives. An unrecognized value is
rejected, never silently defaulted - a typo falling back to the ladder would
turn a production `ssl-mode=VERIFY_IDENTITYY` into an unauthenticated
connection.

## With no `ssl-mode`, the strongest rung that works is taken

`VERIFY_IDENTITY`, then `VERIFY_CA`, then `REQUIRED`, then plaintext. A stock
local server with no TLS configured connects; a server that advertises TLS but
fails every rung's handshake fails rather than dropping to plaintext, for the
reason above.

## With an explicit `ssl-mode`, that mode is a pin

Set in the URI or in the `Datasource` field, it fails rather than downgrading.
That is what makes a production URI a guarantee rather than a preference.

## What `VERIFY_CA` checks, exactly

The certificate chain must reach a trust anchor in the system store; the name
on the certificate is **not** checked against the host that was dialled. This
driver gets that half-check by handing `x509VerifyChain` the leaf
certificate's own first SubjectAltName as the name to verify - so the hostname
test is vacuous by construction, on every call, rather than by an omission
that could regress. `VERIFY_IDENTITY` is the same chain check plus the real
hostname.

## Warnings

Every rung below `VERIFY_IDENTITY` prints one line to stderr, **once per
pool**, never once per connection - naming the rung and what it does not
check. Two pools in one program each warn once independently; `adapter()`
returns a fresh value per call for exactly this reason.
