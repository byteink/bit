<!-- doctest: deps postgres -->

# Connecting to PostgreSQL

`AppConfig.databaseUrl` has been sitting unused since part 5. Inkwell's
articles still live in a Bit slice that resets every time the process
restarts. This part opens a real connection to PostgreSQL and proves it
works, before part 7 puts a table behind it.

## Step 1: run PostgreSQL

A throwaway container is enough for development - no install, nothing left
behind once you remove it:

```
$ docker run --name inkwell-db -e POSTGRES_USER=inkwell -e POSTGRES_PASSWORD=inkwell \
    -e POSTGRES_DB=inkwell -p 5432:5432 -d postgres:18.6
$ docker exec inkwell-db pg_isready -U inkwell -d inkwell
/var/run/postgresql:5432 - accepting connections
```

`DATABASE_URL` from part 5 already matches this container:

```
postgres://inkwell:inkwell@127.0.0.1:5432/inkwell?sslmode=disable
```

## Step 2: add the driver

`std/sql` defines `Pool` and `Datasource`; the PostgreSQL wire protocol
itself lives in `bitlang.org/pkg/postgres`, which exports one function:
`adapter()`. Inkwell's own `bit.json` points at it with a local path rather
than `bit add bitlang.org/pkg/postgres@v...` - the package has not been
tagged yet (tracked as #6085), so a same-repo companion app depends on the
source directly:

```json
{
  "dependencies": {
    "web": "../..",
    "postgres": "../../../postgres"
  }
}
```

Once #6085 lands, this becomes a normal `bit add bitlang.org/pkg/postgres@v...`.

## Step 3: open the pool

Inkwell's own `openPool` (db.bit) takes the whole `AppConfig` part 5 built,
since every function that needs a setting takes that struct rather than
reading the environment again. This example takes just the URL, to keep it
focused on the connection itself:

```bit
import { Datasource, Pool, Value, pool } from "std/sql"
import { adapter } from "postgres"

export fn openPool(databaseUrl: string): Pool! {
  return pool(adapter(), Datasource{ uri = databaseUrl })?
}
```

`pool()` does not connect eagerly - it hands back a `Pool` that dials on
first use. Prove the connection actually works with one query, the same
shape `main.bit`'s own readiness probe uses (part 17):

```bit
fn probeDb(pool: Pool): bool {
  let rows = pool.query("select 1", []Value(0)) catch _ {
    return false
  }
  rows.close()
  return true
}
```

## Step 4: connect and probe

```bit
import { env } from "std/os"

fn main(): ()! {
  let databaseUrl = env("DATABASE_URL")
  let pool = openPool(databaseUrl)?
  if (!probeDb(pool)) {
    fail newError("inkwell: could not reach the database")
  }
  eprint("inkwell: connected to postgresql\n")
}
```

Run it against the container from step 1:

```
$ bit run main.bit
inkwell: connected to postgresql
```

Stop the container and run it again to see the other path:

```
$ docker stop inkwell-db
$ bit run main.bit
inkwell: could not reach the database
```

`probeDb` never leaks the driver's own error - a wrong password or an
unreachable host both fail the same `catch _`. Part 17 wires this same
probe into the app's real `/ready` route.

Remove the container once you are done:

```
$ docker rm -f inkwell-db
```

## What we built

Inkwell now opens a real connection to PostgreSQL at startup, using the
`DATABASE_URL` part 5 already reads, and fails loudly with its own message
rather than serving requests against a database it cannot reach.

Previous: [Configuration](05-configuration.md)
Next: [Tables and migrations with pkg/orm](07-tables-and-migrations-with-pkg-orm.md)
