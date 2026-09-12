# Connecting

`bitlang.org/pkg/mysql` exports exactly one symbol, `adapter()`, which hands
`std/sql`'s `pool` an `Adapter` for MySQL and MariaDB. It is a function and not
`export let adapter: Adapter` because a module-level `let` may only hold an
untraced scalar (SPEC §11.11) - an interface value there is a compile error,
not a style preference. Each call returns a fresh value, which is also the
correct shape for the once-per-pool warnings covered in [TLS](tls.md) and
[Authentication](authentication.md): a process-wide singleton would turn "once
per pool" into "once per process", so a second pool in the same program would
connect on `ssl-mode=DISABLED` and say nothing.

## A first query

```bit
import { pool, Datasource, Pool, Value } from "std/sql"
import { adapter } from "bitlang.org/pkg/mysql"

fn firstRow(url: string): Value! {
  let db = pool(adapter(), Datasource{ uri: url })?
  defer db.close()
  let rows = db.query("select 1", []Value(0))?
  defer rows.close()
  rows.next()?
  return rows.value(0)
}
```

`pool` is `std/sql`'s bounded connection pool - see the `std/sql` chapter of
the standard library reference for `Datasource`'s full field list,
`tx`/`txValue` for transactions, and the `Rows` cursor. This package supplies
only the `Adapter` that turns a `Datasource` into a live MySQL or MariaDB
connection.

## The connection URI

Both schemes are accepted, and so is the individual-field form of
`Datasource`:

```
mysql://app:pw@localhost:3306/dev
mariadb://app:pw@db.internal/erp?ssl-mode=VERIFY_IDENTITY
Datasource{ host: "localhost", user: "app", database: "dev" }
```

`uri` and the individual fields are mutually exclusive - `Datasource.validate`
rejects setting both, or neither. `port` left at 0, the `Datasource` default,
means 3306. `ssl-mode` is the only query parameter this driver reads; any other
name fails naming itself rather than being silently dropped. Its values are
covered in full in [TLS](tls.md).
