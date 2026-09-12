# bitlang.org/pkg/mysql

A MySQL **and MariaDB** driver for `std/sql`. It exports one symbol.

```bit
import { pool, Datasource, Pool } from "std/sql"
import { adapter } from "mysql"

fn connect(url: string): Pool! {
  return pool(adapter(), Datasource{ uri: url })?
}
```

Install with `bit add bitlang.org/pkg/mysql@v0.1.0`, which writes the
dependency into `bit.lock` under the key `mysql` - the vanity path's last
segment, which is also the name every import above uses.

One package serves both servers. The wire protocol is one protocol; the
differences are a version prefix, a second half of the capability field and one
extra authentication plugin, each handled where it occurs. Two packages would
be two copies of everything else.

`adapter(): Adapter` is the entire exported surface - nothing else, on purpose.
URI parsing lives behind the `Adapter` interface rather than beside it, because
the one-line driver swap is the whole point of `std/sql`: a program that
imported a second symbol from here could not change one line and be on a
different database.

## Documentation

Read the [docs](docs/README.md) in order:

1. [Connecting](docs/connecting.md) - a first query through `std/sql`'s `pool`,
   the URI and its fields
2. [MySQL and MariaDB](docs/servers.md) - one driver, both servers, and which
   stock Docker images verify
3. [TLS](docs/tls.md) - `ssl-mode`, the no-mode ladder, what `VERIFY_CA` checks
4. [Authentication](docs/authentication.md) - the four plugins and which two warn
5. [Queries](docs/queries.md) - placeholder rewriting, prepared statements, the
   single-packet limit
6. [Errors](docs/errors.md) - matching a server error by code and SQLSTATE
7. [Limitations](docs/limitations.md) - what this driver does not do yet
