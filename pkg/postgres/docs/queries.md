# Queries

Every statement goes out on the **extended query protocol** - Parse, Bind,
Describe, Execute, Sync, written as one batch, one round trip. The simple
query protocol has no field a parameter could travel in, so a driver using
it for `where id = $1` would have to build the statement text around the
caller's value; nothing here ever does.

`$1` is Postgres's own placeholder and the text is passed through
untouched, so a placeholder used twice is **one** parameter bound to both
positions:

```bit
import { Pool, Value } from "std/sql"

fn placeholderReuse(db: Pool): ()! {
  db.query("select $1::int4 as l, $1::int4 as r", []Value{ Value.Int(7) })?
}
```

Values come back in the protocol's **text format**, so every non-NULL
column is `Value.Text` whatever its type, and the result set carries each
column's type OID beside it. Turning those bytes into
`Value.Int`/`Value.Float`/... is `#3989` - see [Limitations](limitations.md).

`exec` reports the count from the server's own `CommandComplete` tag.
Parameters are sent with their types left for the server to infer, except a
`Value.Blob`, which is declared `bytea` and sent as raw binary.

## The statement cache is off by default

With `statementCache` unset, every execution parses an **unnamed**
statement, which the server discards at the next Parse:

```bit
import { pool, Datasource } from "std/sql"
import { adapter } from "bitlang.org/pkg/postgres"
import { env } from "std/os"

fn openDefault(): ()! {
  let db = pool(adapter(), Datasource{ uri: env("DATABASE_URL"), maxOpen: 20 })?
}
```

A named prepared statement lives on **one** backend. pgbouncer in
transaction mode hands the next query to a different one, which answers
`prepared statement "s1" does not exist` - an error naming neither the
pooler nor the cache. RDS Proxy instead pins the connection, so the pooling
silently stops happening. Opt in when you know neither is in front of you:

```bit
import { pool, Datasource } from "std/sql"
import { adapter } from "bitlang.org/pkg/postgres"
import { env } from "std/os"

fn openCached(): ()! {
  let db = pool(adapter(), Datasource{
    uri: env("DATABASE_URL"), maxOpen: 20, statementCache: 256,
  })?
}
```

The number is how many distinct statements **each** connection remembers.
The cache is per connection, never shared, evicts least-recently-used,
closes what it evicts, and dies with the connection. A statement is
remembered only after the server has actually parsed it: a Parse in a batch
that then failed was rolled back with its implicit transaction.
