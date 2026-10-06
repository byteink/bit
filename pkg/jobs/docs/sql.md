# PostgreSQL, MySQL and MariaDB

<!-- doctest: per-block -->
<!-- doctest: deps postgres mysql -->

[Getting started](getting-started.md) enqueues and runs jobs against a
`store` without saying what one is. There is no default: an in-memory
queue silently loses every pending job on deploy and behaves differently
on one instance than on three, so you always pick one. `SqlStore` is
the one this package ships, and it runs on PostgreSQL, on MySQL 8.0.1 or
newer and on MariaDB 10.6 or newer.

## The simplest thing that works

`SqlStore` takes a `std/sql.Pool` - the same one you would use for
anything else in your app - and needs two tables, created by
`migrate` before the first `open`. The pool decides the database: build it
with `postgres`'s adapter and you are on PostgreSQL, with `mysql`'s and you
are on MySQL or MariaDB (the one adapter speaks to both). Nothing else in your
code changes:

```bit
import { pool, Datasource } from "std/sql"
import { adapter } from "postgres"
import { SqlStore, migrate, open, Options } from "jobs"

fn main(): ()! {
  let db = pool(adapter(), Datasource{ uri = "postgres://localhost/myapp" })?
  migrate(db)?
  let store = SqlStore(db)?
  let q = open(store, Options{ workers = 4 })?
  q.run()?
  return
}
```

The same program on MySQL or MariaDB changes the adapter and the URL:

```bit
import { pool, Datasource } from "std/sql"
import { adapter } from "mysql"
import { SqlStore, migrate, open, Options } from "jobs"

fn main(): ()! {
  let db = pool(adapter(), Datasource{ uri = "mysql://app:secret@localhost/myapp" })?
  migrate(db)?
  let store = SqlStore(db)?
  let q = open(store, Options{ workers = 4 })?
  q.run()?
  return
}
```

`SqlStore(db)` asks the server what it is with one `SELECT version()` and keeps
the answer, so the store always speaks the dialect of the server it is
connected to. That is also where a server this package cannot serve is
refused, with the reason, instead of failing on the first claim under load:

```text
jobs: MySQL 5.7.44 is too old for SqlStore: claiming jobs needs SELECT ... FOR UPDATE SKIP LOCKED, which MySQL has had since 8.0.1
jobs: MariaDB 10.5.27-MariaDB is too old for SqlStore: claiming jobs needs SELECT ... FOR UPDATE SKIP LOCKED, which MariaDB has had since 10.6
```

`migrate` runs `migrationStatements(dialect)` - a plain `[]string`, one entry
per statement, in order - for the dialect the server reported. The `Dialect`
enum names the two, `Dialect.Postgres` and `Dialect.MySql`; MariaDB takes the
`MySql` one:

```bit
import { migrationStatements, Dialect } from "jobs"

fn printMigration(dialect: Dialect) {
  for stmt of migrationStatements(dialect) {
    println(stmt)
    println(";")
  }
}
```

If your app has its own migration tool, run those same statements through
it instead of calling `migrate` - `migrationStatements` is exposed
exactly so you are not stuck writing the table definitions by hand.
The statements also create `bit_schedule_leases`, the table `SqlLocker`
(see [Cron](cron.md)) keeps its per-tick leases in. Its `seq` column numbers
the leases in the order they were won, and that order, not the tick value and
not the expiry, decides which old rows are dropped: both of those come from
the clock of the instance that wrote the row, and one instance with a clock
years ahead must not be able to push a correct instance's lease out of the
table.

## How a claim works on each engine

Every engine uses `SELECT ... FOR UPDATE SKIP LOCKED`, so several workers -
even across several instances of your app - can poll the same table at once and
never claim the same row twice, and a worker that crashes mid-job loses its
claim automatically once its visibility timeout elapses, letting another
worker pick the job back up.

What differs is the number of round trips. PostgreSQL claims in one statement,
an `UPDATE` over the `SKIP LOCKED` subquery that returns the claimed row with
`RETURNING`. MySQL has no `RETURNING`, and neither does MariaDB's `UPDATE` before
13.0, so both claim in one transaction: the
`SELECT ... FOR UPDATE SKIP LOCKED`, then an `UPDATE` of that row by id. The
transaction runs at READ COMMITTED, so the scan locks the row it takes and no
gap, and a worker enqueueing a job never waits for a claim.

The two engines also disagree about case. MySQL's default collation compares
text without regard to case, which would make the schedule leases `Report@1`
and `report@1` the same row, so the MySQL lease table declares its keys
`utf8mb4_bin`. If you run the statements yourself, keep that.

## Writing your own store

`Store` is a structural interface (`store.bit`) - anything with these five
methods works with `open`, no declaration needed:

```bit
import { Store, ClaimedJob } from "jobs"

class loggingStore {
  inner: Store

  export enqueue(name: string, payload: string, availableAt: int, maxAttempts: int): ()! {
    println("enqueue: ${name}")
    this.inner.enqueue(name, payload, availableAt, maxAttempts)?
  }

  export claim(visibilityTimeout: int): Option<ClaimedJob>! {
    return this.inner.claim(visibilityTimeout)?
  }

  export complete(id: int): ()! {
    this.inner.complete(id)?
  }

  export retry(id: int, availableAt: int): ()! {
    this.inner.retry(id, availableAt)?
  }

  export deadLetter(id: int, reason: string): ()! {
    println("dead-lettered: ${reason}")
    this.inner.deadLetter(id, reason)?
  }
}
```

`ClaimedJob` is what `claim` hands back: `id`, `name`, `payload` and
`attempts`/`maxAttempts` so a store's caller (the worker loop) can decide
retry versus dead-letter without asking the store again.

## At-least-once delivery, and why your handler must be idempotent

A queue built this way can run a job more than once. Say the worker's
process is killed right after `sendWelcomeEmail` succeeds but before the
worker tells the store the job is done: nothing recorded that success, so
once the visibility timeout elapses another worker claims the same job and
runs it again. This is "at-least-once" delivery - the queue guarantees a
job is not lost, never that it runs exactly once - and every queue with a
crash-recovery story (this one, SQS, Sidekiq) makes the same trade,
because the alternative, guaranteeing exactly-once across a network and a
process crash, is not solvable in general.

The fix is not in the queue; it is in the handler. `SendWelcome` should
either check "did I already welcome this user" before sending, or - the
usual answer - ask the mail provider for the same idempotency key every
time (`userId` is already a natural one) so a duplicate send is caught on
their side instead of yours. A handler that debits an account or emails a
customer without an idempotency check will eventually do it twice; a
handler that only ever produces the same end state no matter how many
times it runs is safe to retry, which is the whole point of retrying.

## Next

Back to [Getting started](getting-started.md) for the worker pool,
retries and the dead-letter list this store backs.
