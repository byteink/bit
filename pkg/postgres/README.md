# bitlang.org/pkg/postgres

A PostgreSQL driver for `std/sql`. It exports one symbol.

```bit
import { pool, Datasource } from "std/sql"
import { adapter } from "bitlang.org/pkg/postgres"

let db = pool(adapter(), Datasource{ uri: env("DATABASE_URL") })?
let rows = db.query("select 1", []Value(0))?
```

Install with `bit add bitlang.org/pkg/postgres@v0.1.0`.

## The exported surface

`adapter(): Adapter` — nothing else. URI parsing lives behind the `Adapter`
interface rather than beside it, because the one-line driver swap is the whole
point of `std/sql`: a program that imported a second symbol from here could not
change one line and be on a different database.

One adapter value per pool. `adapter()` returns a fresh one per call, and the
once-per-pool warnings below are counted on it.

## Connecting

Both spellings of the scheme are accepted, and so is the individual-field form
of `Datasource`:

```
postgres://app:pw@localhost:5432/dev
postgresql://app:pw@db.internal/erp?sslmode=verify-full
Datasource{ host: "localhost", user: "app", database: "dev" }
```

`port` 0 — the `Datasource` default — means 5432. `sslmode` is the only query
parameter read; any other fails naming itself rather than being dropped. An
unrecognised `sslmode` value is rejected, never defaulted.

## TLS

Postgres has no TLS port and no ALPN. The driver opens a cleartext socket,
sends the eight-byte `SSLRequest` packet, and reads the server's one-byte
answer — `S` (handshake now, on this socket) or `N` (this server has no TLS).
`std/tls.client` runs the handshake from there.

**With no `sslmode`,** the strongest rung that works is taken: `verify-full`,
then `verify-ca`, then `require`, then plaintext. A stock local server with no
TLS configured connects.

**With an explicit `sslmode`, in the URI or in the field, that mode is a pin.**
It fails rather than downgrading, which is what makes a production URI a
guarantee.

Accepted values: `disable`, `require`, `verify-ca`, `verify-full`. libpq's
`prefer` and `allow` are not accepted — they name the fallback behaviour that
omitting `sslmode` already gives.

Every rung below `verify-full` prints one line to stderr, **once per pool**,
never once per connection.

A server that answers `S` and then fails the handshake is **not** downgraded to
plaintext. The plaintext rung belongs to a server that answered `N`; a server
that offers TLS and then breaks is misconfigured or being interfered with, and
sending the password to it in the clear is the strip attack the ladder exists
to avoid.

## Authentication

`scram-sha-256` (RFC 5802/7677) whenever the server offers it, and `md5`,
cleartext `password` and `trust` all connect — a stock server uses one of the
last three, and a driver that refuses them is a driver nobody can start with.
Each of the three warns once per pool, naming the method and the fix.

The SCRAM exchange verifies the **server's** signature before accepting
`AuthenticationOk`, and every comparison in it goes through `crypto/subtle`.

## Limitations, and where each one is going

- **Queries are `#3988`.** `query` runs the simple-query protocol with no
  parameters — enough for a `select 1` liveness check. `exec`, `prepare` and
  `begin` fail naming `#3988`. Values come back in the protocol's text format,
  so every non-NULL column is `Value.Text` whatever its column type.
- **`verify-ca` checks the chain against the trust store and deliberately does
  not check the name.** It does that by handing `x509VerifyChain` the leaf's own
  first SubjectAltName, so the name test is vacuous by construction rather than
  by omission.
- **SASLPrep (RFC 4013) is not applied to the password.** It is the identity
  function for an ASCII password. A password whose normalized form differs from
  its raw form would derive a different key here than libpq derives.
- **`SCRAM-SHA-256-PLUS` (channel binding) is not offered.**
- **TLS client certificates are not sent.** `std/tls` does not request or
  present them.

## Tests

`./make test-package-postgres` runs everything that needs no server: the URI
parser, and the startup exchange against an in-process fake backend that is a
real SCRAM server side (it derives `StoredKey`/`ServerKey` and verifies the
client's proof), so a forged server signature, a replayed nonce, a weak
iteration count and a missing server proof each fail.

`live.test.bit` adds the cases that need a real server. Each is skipped, out
loud, when its URI is unset:

```sh
docker run --rm -d --name pg-trust -e POSTGRES_HOST_AUTH_METHOD=trust \
  -p 127.0.0.1:5432:5432 postgres:16-alpine
docker run --rm -d --name pg-scram -e POSTGRES_PASSWORD=pw \
  -e POSTGRES_INITDB_ARGS="--auth-host=scram-sha-256" -p 127.0.0.1:55000:5432 postgres:16-alpine
# --auth-host=md5 matters: it makes initdb store the superuser's password as
# md5. With the default password_encryption=scram-sha-256, Postgres 14+ answers
# an md5 line in pg_hba.conf with SASL anyway, and the md5 path is never taken.
docker run --rm -d --name pg-md5 -e POSTGRES_PASSWORD=pw \
  -e POSTGRES_HOST_AUTH_METHOD=md5 -e POSTGRES_INITDB_ARGS="--auth-host=md5" \
  -p 127.0.0.1:55001:5432 postgres:16-alpine
docker run --rm -d --name pg-password -e POSTGRES_PASSWORD=pw \
  -e POSTGRES_HOST_AUTH_METHOD=password -p 127.0.0.1:55003:5432 postgres:16-alpine

PG_TEST_TRUST_URI=postgres://postgres@127.0.0.1:5432/postgres \
PG_TEST_SCRAM_URI=postgres://postgres:pw@127.0.0.1:55000/postgres \
PG_TEST_MD5_URI=postgres://postgres:pw@127.0.0.1:55001/postgres \
PG_TEST_PASSWORD_URI=postgres://postgres:pw@127.0.0.1:55003/postgres \
  bit test pkg/postgres
```

For `PG_TEST_TLS_URI`, turn `ssl` on in a container with a self-signed
certificate: generate `server.crt`/`server.key` into the data directory
(`openssl req -new -x509 -nodes -subj /CN=localhost`), `chmod 600` the key,
`chown postgres`, then `ALTER SYSTEM SET ssl='on'` and `SELECT
pg_reload_conf()`.
