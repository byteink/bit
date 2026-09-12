# Connecting

`adapter(): Adapter` is the only symbol this package exports - nothing else.
URI parsing, TLS, authentication and the wire protocol all live behind the
`Adapter` interface rather than beside it, because the one-line driver swap
is the whole point of `std/sql`: a program that imported a second symbol from
here could not change one line and be on a different database. Call
`adapter()` once per `pool`; it returns a fresh value per call, and the
once-per-pool warnings covered in [TLS](tls.md) and
[Authentication](authentication.md) are counted on it.

A first query, through `std/sql`'s pool:

```bit
import { pool, Datasource, Value } from "std/sql"
import { adapter } from "postgres"
import { env } from "std/os"

fn run(): ()! {
  let db = pool(adapter(), Datasource{ uri: env("DATABASE_URL") })?
  let rows = db.query("select * from users where id = $1", []Value{ Value.Int(7) })?
}
```

## The connection URI, and the individual-field form

Both spellings of the scheme are accepted, and so is the individual-field
form of `Datasource`:

```
postgres://app:pw@localhost:5432/dev
postgresql://app:pw@db.internal/erp?sslmode=verify-full
Datasource{ host: "localhost", user: "app", database: "dev" }
```

`uri` and the individual fields are mutually exclusive - `std/sql`'s
`Datasource.validate` rejects a value that sets both, or neither, before
anything opens a socket.

`port` 0 - the `Datasource` default - means 5432. `sslmode` is the only
query parameter read; any other fails naming itself rather than being
dropped. An unrecognised `sslmode` value is rejected, never defaulted; see
[TLS](tls.md) for what each accepted value does.
