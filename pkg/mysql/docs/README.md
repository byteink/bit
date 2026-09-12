# pkg/mysql documentation

Read in this order. Each row is one chapter; this table is the order
bitlang.org's sidebar reads it in.

| Chapter | Covers |
|---|---|
| [Connecting](connecting.md) | the one exported symbol, a first query through `std/sql`'s `pool`, the connection URI and its individual fields |
| [MySQL and MariaDB](servers.md) | one driver for both servers, the version-string and capability-field traps, which stock Docker images verify |
| [TLS](tls.md) | `ssl-mode`, the no-mode ladder, exactly what `VERIFY_CA` checks and does not, the once-per-pool warnings |
| [Authentication](authentication.md) | the four plugins, which two warn, why `caching_sha2_password`'s full path needs TLS |
| [Queries](queries.md) | `query`, `exec`, `prepare`, `$N` placeholder rewriting, the statement cache, the single-packet limit |
| [Errors](errors.md) | matching a server error by code and SQLSTATE, `FatalError` and what the connection pool does with one |
| [Limitations](limitations.md) | what this driver does not do yet, named against the ticket that closes each gap |

See the [package front page](../README.md) for install and a minimal example.
