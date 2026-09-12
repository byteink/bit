# Authentication

Four plugins, all of which connect - this driver refuses none of them:

| plugin | |
|---|---|
| `caching_sha2_password` (MySQL 8 default) | strong |
| `client_ed25519` (MariaDB) | strong |
| `mysql_native_password` | weak - SHA-1, and the server's stored value answers the challenge on its own |
| `mysql_old_password` | weak - the pre-4.1 hash, 64 bits of keyspace |

The two weak ones each warn once per pool, to stderr, naming the plugin and
the fix. Refusing them outright was the first draft and was rejected: a stock
local MariaDB verifies nothing - its certificate is self-signed - and may well
have a native-password account already, and a driver that will not talk to it
is a driver nobody can start with. The URI's `ssl-mode` is the only place
strictness is configured; there is no equivalent knob for authentication
plugins.

## `caching_sha2_password` needs TLS for a cache miss

The fast path - answering the server's cached hash - always runs, so a cached
password over a plain socket connects like any other client. When the cache
misses, the server asks for the password protected only by an RSA public key
it supplies on the same connection. Fetching a key from the party you are
authenticating to, and trusting it because it arrived, is a key exchange with
no authentication at all: a man in the middle simply supplies its own key.

Without TLS, this driver sends nothing further for that path - no public-key
request, no RSA operation - and fails with a message naming TLS. There is no
partial credential leak on this failure path: zero additional bytes go out
after the refusal.

## What a program does with the warning

Nothing needs to. The warning is diagnostic, not a return value - `pool` and
every query call still succeed. A program that wants to enforce a floor pins
`ssl-mode` (for TLS) or moves the account to `caching_sha2_password` or
`client_ed25519` (for authentication); this driver has no code path to refuse
a connection on plugin strength alone.
