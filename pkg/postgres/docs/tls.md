# TLS

Postgres has no TLS port and no ALPN. The driver opens a cleartext socket,
sends the eight-byte `SSLRequest` packet, and reads the server's one-byte
answer - `S` (handshake now, on this socket) or `N` (this server has no
TLS). `std/tls.client` runs the handshake from there.

**With no `sslmode`,** the strongest rung that works is taken: `verify-full`,
then `verify-ca`, then `require`, then plaintext. A stock local server with
no TLS configured connects.

**With an explicit `sslmode`, in the URI or in the field, that mode is a
pin.** It fails rather than downgrading, which is what makes a production
URI a guarantee.

Accepted values: `disable`, `require`, `verify-ca`, `verify-full`. libpq's
`prefer` and `allow` are not accepted - they name the fallback behaviour
that omitting `sslmode` already gives.

Every rung below `verify-full` prints one line to stderr, **once per pool**,
never once per connection.

A server that answers `S` and then fails the handshake is **not**
downgraded to plaintext. The plaintext rung belongs to a server that
answered `N`; a server that offers TLS and then breaks is misconfigured or
being interfered with, and sending the password to it in the clear is the
strip attack the ladder exists to avoid.

## What `verify-ca` checks, and what it does not

`verify-ca` requires the chain to reach a trust anchor but deliberately does
not check the hostname. `x509VerifyChain` takes a hostname as a required
argument, so the driver hands it the leaf certificate's own first
`SubjectAltName` - the name it checks is the server's own claim about
itself, which makes the name test vacuous by construction, not an omission.
`verify-full` is the rung that actually compares the certificate's name
against the host you dialed.
