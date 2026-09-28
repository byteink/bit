# PostgreSQL

<!-- doctest: per-block -->
<!-- doctest: deps postgres -->

[Getting started](getting-started.md) enqueues and runs jobs against a
`store` without saying what one is. There is no default: an in-memory
queue silently loses every pending job on deploy and behaves differently
on one instance than on three, so you always pick one. `PostgresStore` is
the one this package ships.

## The simplest thing that works

`PostgresStore` takes a `std/sql.Pool` - the same one you would use for
anything else in your app - and needs one table, created by
`migrate` before the first `open`:

```bit
import { pool, Datasource } from "std/sql"
import { adapter } from "postgres"
import { newPostgresStore, migrate, open, Options } from "jobs"

fn main(): ()! {
  let db = pool(adapter(), Datasource{ uri = "postgres://localhost/myapp" })?
  migrate(db)?
  let store = newPostgresStore(db)
  let q = open(store, Options{ workers = 4 })?
  q.run()?
  return
}
```

`migrate` runs `migrationStatements()` - a plain `[]string`, one entry per
statement, in order:

```bit
import { migrationStatements } from "jobs"

fn printMigration() {
  for stmt of migrationStatements() {
    println(stmt)
    println(";")
  }
}
```

If your app has its own migration tool, run those same statements through
it instead of calling `migrate` - `migrationStatements()` is exposed
exactly so you are not stuck writing the table definition by hand.
`PostgresStore.claim` uses `SELECT ... FOR UPDATE SKIP LOCKED`, so several
workers - even across several instances of your app - can poll the same
table at once and never claim the same row twice, and a worker that
crashes mid-job loses its claim automatically once its visibility timeout
elapses, letting another worker pick the job back up.

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
`attempts`/`maxAttempts` so a store's caller (`jobs.bit`'s worker loop)
can decide retry versus dead-letter without asking the store again. A
Redis store follows the same shape once pkg/redis 0.2 ships (#6013).

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
