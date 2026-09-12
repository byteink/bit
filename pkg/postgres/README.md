# bitlang.org/pkg/postgres

A PostgreSQL driver for `std/sql`. It exports one symbol.

```bit
import { pool, Datasource } from "std/sql"
import { adapter } from "bitlang.org/pkg/postgres"

let db = pool(adapter(), Datasource{ uri: env("DATABASE_URL") })?
let rows = db.query("select * from users where id = $1", []Value{ Value.Int(7) })?
```

Install with `bit add bitlang.org/pkg/postgres@v0.1.0`.

## The exported surface

`adapter(): Adapter` - nothing else. URI parsing lives behind the `Adapter`
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

`port` 0 - the `Datasource` default - means 5432. `sslmode` is the only query
parameter read; any other fails naming itself rather than being dropped. An
unrecognised `sslmode` value is rejected, never defaulted.

## TLS

Postgres has no TLS port and no ALPN. The driver opens a cleartext socket,
sends the eight-byte `SSLRequest` packet, and reads the server's one-byte
answer - `S` (handshake now, on this socket) or `N` (this server has no TLS).
`std/tls.client` runs the handshake from there.

**With no `sslmode`,** the strongest rung that works is taken: `verify-full`,
then `verify-ca`, then `require`, then plaintext. A stock local server with no
TLS configured connects.

**With an explicit `sslmode`, in the URI or in the field, that mode is a pin.**
It fails rather than downgrading, which is what makes a production URI a
guarantee.

Accepted values: `disable`, `require`, `verify-ca`, `verify-full`. libpq's
`prefer` and `allow` are not accepted - they name the fallback behaviour that
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
cleartext `password` and `trust` all connect - a stock server uses one of the
last three, and a driver that refuses them is a driver nobody can start with.
Each of the three warns once per pool, naming the method and the fix.

The SCRAM exchange verifies the **server's** signature before accepting
`AuthenticationOk`, and every comparison in it goes through `crypto/subtle`.

## Queries

Every statement goes out on the **extended query protocol** - Parse, Bind,
Describe, Execute, Sync, written as one batch, one round trip. The simple query
protocol has no field a parameter could travel in, so a driver using it for
`where id = $1` would have to build the statement text around the caller's
value; nothing here ever does.

`$1` is Postgres's own placeholder and the text is passed through untouched, so
a placeholder used twice is **one** parameter bound to both positions:

```bit
db.query("select $1::int4 as l, $1::int4 as r", []Value{ Value.Int(7) })?
```

Values come back in the protocol's **text format**, so every non-NULL column is
`Value.Text` whatever its type, and the result set carries each column's type
OID beside it. Turning those bytes into `Value.Int`/`Value.Float`/... is
`#3989`.

`exec` reports the count from the server's own `CommandComplete` tag.
Parameters are sent with their types left for the server to infer, except a
`Value.Blob`, which is declared `bytea` and sent as raw binary.

## The statement cache is off by default

With `statementCache` unset, every execution parses an **unnamed** statement,
which the server discards at the next Parse:

```bit
let db = pool(adapter(), Datasource{ uri: env("DATABASE_URL")?, maxOpen: 20 })?
```

A named prepared statement lives on **one** backend. pgbouncer in transaction
mode hands the next query to a different one, which answers `prepared statement
"s1" does not exist` - an error naming neither the pooler nor the cache. RDS
Proxy instead pins the connection, so the pooling silently stops happening.
Opt in when you know neither is in front of you:

```bit
let db = pool(adapter(), Datasource{
  uri: env("DATABASE_URL")?, maxOpen: 20, statementCache: 256,
})?
```

The number is how many distinct statements **each** connection remembers. The
cache is per connection, never shared, evicts least-recently-used, closes what
it evicts, and dies with the connection. A statement is remembered only after
the server has actually parsed it: a Parse in a batch that then failed was
rolled back with its implicit transaction.

## Errors carry the SQLSTATE

A failure the server reported is a typed error, not a sentence. Ask it for the
shape you need:

```bit
interface SqlError { message(): string, sqlState(): string }

db.exec(sql, params) catch e {
  let (pg, ok) = e.(SqlError)
  if (ok && (pg.sqlState() == "40001" || pg.sqlState() == "40P01")) { retry() }
}
```

`23505` is a unique violation and is not retryable; `40001` (serialization
failure) and `40P01` (deadlock detected) are. Telling them apart by message
text is how retry loops get written wrong.

Every exchange is drained to `ReadyForQuery`, so a statement that failed -
including one that failed halfway through a result set - leaves the connection
usable, and the next borrower from the pool never inherits a half-read stream.

## Limitations, and where each one is going

- **Typed decoding is `#3989`.** Columns arrive as text bytes with their type
  OIDs; `asInt` on an `int4` column fails today, `asText` works.
- **Transactions are the rest of `#3986`.** `begin` fails naming the epic;
  `std/sql` runs transactions through a closure (`stdlib/sql/tx.bit`).
- **`Conn.prepare` does not name a statement on the server.** It holds the
  text and runs the ordinary path, so a `Stmt` is unnamed unless
  `statementCache` turned the cache on. A name is meaningful only on the one
  backend that parsed it, which is the same reason the cache is opt-in.
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
parser, the startup exchange against an in-process fake backend that is a real
SCRAM server side (it derives `StoredKey`/`ServerKey` and verifies the client's
proof), so a forged server signature, a replayed nonce, a weak iteration count
and a missing server proof each fail - and the query layer against a backend
that decodes each frontend frame and answers it, which is where "no named Parse
across a hundred executions" is asserted against the bytes that were sent.

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

`PG_TEST_TRUST_URI` alone covers the query layer: the parameter round trip and
its OIDs, the SQLSTATEs, the mid-result-set failure, and the cache, which is
counted from the server's own `pg_prepared_statements`. Any port works - the
one field-form test that needs 5432 skips out loud elsewhere:

```sh
docker run --rm -d --name pg-3988 -e POSTGRES_HOST_AUTH_METHOD=trust \
  -p 127.0.0.1:55010:5432 postgres:16-alpine
PG_TEST_TRUST_URI=postgres://postgres@127.0.0.1:55010/postgres ./make test-package-postgres
docker rm -f pg-3988
```

For `PG_TEST_TLS_URI`, turn `ssl` on in a container with a self-signed
certificate: generate `server.crt`/`server.key` into the data directory
(`openssl req -new -x509 -nodes -subj /CN=localhost`), `chmod 600` the key,
`chown postgres`, then `ALTER SYSTEM SET ssl='on'` and `SELECT
pg_reload_conf()`.
