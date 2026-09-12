# bitlang.org/pkg/postgres

A PostgreSQL driver for `std/sql`. It exports one symbol, `adapter()`: a
fresh `Adapter` per pool, with URI parsing, TLS, authentication and the wire
protocol behind it, so swapping this package for another database's driver
changes one line.

Install with `bit add bitlang.org/pkg/postgres@v0.1.0`.

```bit
import { pool, Datasource, Value } from "std/sql"
import { adapter } from "postgres"
import { env } from "std/os"

fn run(): ()! {
  let db = pool(adapter(), Datasource{ uri: env("DATABASE_URL") })?
  let rows = db.query("select * from users where id = $1", []Value{ Value.Int(7) })?
}
```

## Docs

- [Connecting](docs/connecting.md) - opening a pool, the connection URI and
  its individual-field form
- [TLS](docs/tls.md) - the negotiation ladder, pinning a mode, exactly what
  `verify-ca` checks
- [Authentication](docs/authentication.md) - SCRAM-SHA-256, and why SASLPrep
  and channel binding are absent
- [Queries](docs/queries.md) - the extended protocol, parameter binding,
  result values, the statement cache
- [Errors](docs/errors.md) - the SQLSTATE surface and retrying
- [Limitations](docs/limitations.md) - what this driver does not do yet
- [Testing](docs/testing.md) - running the package's own test suite

Start at [docs/README.md](docs/README.md) for the full reading order.
