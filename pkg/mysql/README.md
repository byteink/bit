# bitlang.org/pkg/mysql

A MySQL **and MariaDB** driver for `std/sql`. It exports one symbol.

```bit
import { pool, Datasource } from "std/sql"
import { adapter } from "bitlang.org/pkg/mysql"

let db = pool(adapter(), Datasource{ uri: env("DATABASE_URL") })?
let rows = db.query("select 1", []Value(0))?
```

Install with `bit add bitlang.org/pkg/mysql@v0.1.0`.

One package serves both servers. The wire protocol is one protocol; the
differences are a version prefix, a second half of the capability field and one
extra authentication plugin, each handled where it occurs. Two packages would be
two copies of everything else.

## The exported surface

`adapter(): Adapter` - nothing else. URI parsing lives behind the `Adapter`
interface rather than beside it, because the one-line driver swap is the whole
point of `std/sql`: a program that imported a second symbol from here could not
change one line and be on a different database.

It is a function and not `export let adapter: Adapter` because a module-level
`let` may only hold an untraced scalar (SPEC §11.11) - an interface value there
is a compile error, not a style preference. `adapter()` returns a fresh value per
call, and the once-per-pool warnings below are counted on it, so two pools in one
program each get their own warning rather than the second one connecting weakly
in silence.

## Connecting

Both schemes are accepted, and so is the individual-field form of `Datasource`:

```
mysql://app:pw@localhost:3306/dev
mariadb://app:pw@db.internal/erp?ssl-mode=VERIFY_IDENTITY
Datasource{ host: "localhost", user: "app", database: "dev" }
```

`port` 0 - the `Datasource` default - means 3306. `ssl-mode` is the only query
parameter read; any other fails naming itself rather than being dropped.

## TLS

The setting is spelled MySQL's way, `ssl-mode=`, and its values map onto
`std/sql`'s shared `SslMode`:

| `ssl-mode=` | rung |
|---|---|
| `VERIFY_IDENTITY` | chain and hostname verified |
| `VERIFY_CA` | chain verified, hostname not checked |
| `REQUIRED` | encrypted, certificate not verified |
| `DISABLED` | cleartext |

Case does not matter. `PREFERRED` is **not** accepted: it names the fallback
behaviour that omitting `ssl-mode` already gives. An unrecognised value is
rejected, never defaulted - a typo silently falling back to the ladder would turn
a production `ssl-mode=VERIFY_IDENTITYY` into an unauthenticated connection.

**With no `ssl-mode`,** the strongest rung that works is taken: `VERIFY_IDENTITY`,
then `VERIFY_CA`, then `REQUIRED`, then plaintext. A stock local server with no
TLS configured connects.

**With an explicit `ssl-mode`, in the URI or in the field, that mode is a pin.**
It fails rather than downgrading, which is what makes a production URI a
guarantee.

Every rung below `VERIFY_IDENTITY` prints one line to stderr, **once per pool**,
never once per connection.

MySQL has no TLS port and no ALPN. The server greets in the clear; a client that
wants TLS answers with the first 32 bytes of a handshake response with
`CLIENT_SSL` set, and the next byte on the same socket starts the TLS handshake.
A server that advertises `CLIENT_SSL` and then fails the handshake is **not**
downgraded to plaintext - the plaintext rung belongs to a server that never
offered TLS at all.

## Authentication

Four plugins, all of which connect:

| plugin | |
|---|---|
| `caching_sha2_password` (MySQL 8 default) | strong |
| `client_ed25519` (MariaDB) | strong |
| `mysql_native_password` | weak - SHA-1, and the server's stored value answers the challenge on its own |
| `mysql_old_password` | weak - the pre-4.1 hash, 64 bits of keyspace |

The two weak ones each warn **once per pool**, naming the plugin and the fix.
Refusing them was the first draft and was rejected: a stock local MariaDB
verifies nothing - its certificate is self-signed - and may well have a
native-password account, and a driver that will not talk to it is a driver
nobody can start with. The URI is the only place strictness is
configured.

**`caching_sha2_password`'s full-authentication path is implemented over TLS
only.** The fast path - the one that answers the server's cached hash - always
runs, so a cached password over a plain socket connects like any other client.
When the cache misses, the server asks for the password protected only by an RSA
public key it supplies on the same connection; fetching a key from the party you
are authenticating to and trusting it because it arrived is a key exchange with
no authentication at all, so a man in the middle simply supplies its own. Without
TLS this driver sends nothing further - no public-key request, no RSA operation -
and fails with a message naming TLS. `auth.test.bit` asserts the byte count after
the refusal is zero.

## MariaDB's two traps

**The version string.** MariaDB reports `5.5.5-10.11.2`, a compatibility hack
from when old clients rejected a leading `10.`. A naive parse reads MySQL 5.5.5
and takes every legacy path on a modern server. The prefix is stripped and the
family is decided explicitly; `serverInfo.family` is `MariaDB` or `MySQL` and
never a guess from a version number.

**The capability field.** MariaDB puts its own capability bits in the **upper 32
bits** of a 64-bit field, in four bytes MySQL leaves as zero filler after the
greeting's six-byte filler. They are read as such.

## Limitations, and where each one is going

- **The query layer is a separate ticket under epic #3986.** `query` runs
  `COM_QUERY` with no parameters - enough for a `select 1` liveness check. `exec`,
  `prepare` and `begin` fail naming the epic. Values come back in the protocol's
  text format, so every non-NULL column is `Value.Text` whatever its column type.
- **Neither stock image verifies.** `mysql:8.4` and `mariadb:11.4` each generate
  a self-signed certificate on first start, so the ladder lands on `REQUIRED`
  against both: encrypted, unverified. `VERIFY_CA` and `VERIFY_IDENTITY` need a
  certificate your trust store can chain, which is a server you configured.
- **Single packets only.** A 16 MiB payload (the protocol's multi-packet form) is
  named rather than truncated.
- **`VERIFY_CA` checks the chain against the trust store and deliberately does
  not check the name.** It does that by handing `x509VerifyChain` the leaf's own
  first SubjectAltName, so the name test is vacuous by construction rather than by
  omission.
- **TLS client certificates are not sent.** `std/tls` does not request or present
  them.
- **`LOAD DATA LOCAL` is never served.** The capability is not requested and the
  request packet fails.

## Tests

`./make test-package-mysql` runs everything that needs no server: the URI parser,
the greeting parse (the `5.5.5-` prefix, the upper-half capability bits) and the
authentication exchanges against an in-process fake server. The fake checks a
credential the way a server does - recovering the client's hash from the response
and comparing it with what the server stores - rather than calling this driver's
own function back, and the three response formats are additionally pinned to
vectors computed outside this codebase.

`live.test.bit` adds the cases that need a real server. Each is skipped, out loud,
when its URI is unset:

```sh
docker run --rm -d --name my -e MYSQL_ROOT_PASSWORD=pw -p 127.0.0.1:13306:3306 mysql:8.4
docker run --rm -d --name maria -e MARIADB_ROOT_PASSWORD=pw -p 127.0.0.1:13307:3306 mariadb:11.4

# Both stock images generate a self-signed certificate on first start, so both are
# the one-rung-down case: the connection is encrypted and the certificate does not
# verify.

# MY_TEST_STRICT_URI needs a server that never offers TLS, which neither stock
# image is. `--skip-ssl` starts one: it reports `have_ssl = DISABLED` and never
# advertises CLIENT_SSL, so a pinned ssl-mode has nothing to downgrade to.
docker run --rm -d --name notls -e MARIADB_ROOT_PASSWORD=pw -p 127.0.0.1:13308:3306 mariadb:11.4 --skip-ssl

docker exec my mysql -uroot -ppw -e \
  "create user n@'%' identified with mysql_native_password by 'pw'; grant all on *.* to n@'%'"
docker exec maria mariadb -uroot -ppw -e \
  "install soname 'auth_ed25519'; create user e@'%' identified via ed25519 using password('pw'); grant all on *.* to e@'%'"

MY_TEST_MYSQL_URI=mysql://root:pw@127.0.0.1:13306/mysql \
MY_TEST_MARIADB_URI=mariadb://root:pw@127.0.0.1:13307/mysql \
MY_TEST_NATIVE_URI=mysql://n:pw@127.0.0.1:13306/mysql \
MY_TEST_ED25519_URI=mariadb://e:pw@127.0.0.1:13307/mysql \
MY_TEST_STRICT_URI=mariadb://root:pw@127.0.0.1:13308/mysql?ssl-mode=VERIFY_IDENTITY \
MY_TEST_FIELDS_HOST=127.0.0.1 MY_TEST_FIELDS_USER=root \
MY_TEST_FIELDS_PASSWORD=pw MY_TEST_FIELDS_DATABASE=mysql \
  bit test pkg/mysql
```

`MY_TEST_FIELDS_*` needs the server on 3306 itself, since the point of that case
is that `port` left 0 reaches the default port.

`MY_TEST_SHA2_NOTLS_URI` needs a `caching_sha2_password` account whose password
is not in the server's cache, reached with `ssl-mode=DISABLED`: restart the
container, then connect once with that URI.
