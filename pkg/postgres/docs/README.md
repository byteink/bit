# bitlang.org/pkg/postgres docs

A PostgreSQL driver for `std/sql`. Read the chapters in this order; each one
builds on the last.

| Chapter | Covers |
| ------- | ------ |
| [Connecting](connecting.md) | the one exported symbol, a first query through the pool, the connection URI and its individual-field form |
| [TLS](tls.md) | the SSLRequest ladder, pinning a mode with an explicit `sslmode`, exactly what `verify-ca` checks and does not check |
| [Authentication](authentication.md) | SCRAM-SHA-256, `md5`/cleartext `password`/`trust`, and why SASLPrep and channel binding are absent |
| [Queries](queries.md) | the extended query protocol, parameter binding, the text-format result values, the per-connection statement cache |
| [Errors](errors.md) | the SQLSTATE surface and telling a retryable failure from one that is not |
| [Limitations](limitations.md) | what this driver does not do yet, and where each gap is tracked |
| [Testing](testing.md) | running the package's own test suite, including the cases that need a real server |

For the front page, install command and a one-sample overview, see the
[package README](../README.md).
