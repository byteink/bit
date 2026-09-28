# bitlang.org/pkg/jobs

Background jobs: a worker pool, retries with exponential backoff and full
jitter, a dead-letter list, and a `PostgresStore`. No default queue
backend, the same call as pkg/web's session and rate-limit stores: an
in-memory queue silently loses every pending job on deploy.

<!-- doctest: deps postgres -->

```bit
import { pool, Datasource } from "std/sql"
import { adapter } from "postgres"
import { newPostgresStore, migrate, open, Options } from "jobs"
import { Json, JsonEntry } from "std/json"

@job("send-welcome") @json class SendWelcome {
  userId: i64,
}

fn main(): ()! {
  let db = pool(adapter(), Datasource{ uri = "postgres://localhost/myapp" })?
  migrate(db)?
  let store = newPostgresStore(db)
  let q = open(store, Options{ workers = 4 })?
  q.register<SendWelcome>((job: SendWelcome) => {
    sendWelcomeEmail(job.userId)?
  })
  q.enqueue(SendWelcome{ userId = 1 })?
  q.run()?
  return
}

fn sendWelcomeEmail(userId: i64): ()! {
  // call your mail provider
  return
}
```

Dispatch goes through the class, never a typed string:
`register<T: Job>`/`enqueue<T: Job>` read `T`'s stable `@job` name off a
generic bound, built entirely at runtime with no reflection and no
compiler-generated cross-module table (epic #4023's 2026-09-27 owner
decision).

## Docs

- [Getting started](docs/getting-started.md): the problem, `open`,
  `register`, `enqueue`, starting workers, retries and the dead-letter
  list, one running example (a welcome-email job).
- [PostgreSQL](docs/postgres.md): `PostgresStore`, running the migration,
  writing your own `Store`, at-least-once delivery and idempotent
  handlers.

## Left for follow-up tickets (epic #4023)

- Cron scheduling (#6083).
- A Redis `Store`, once pkg/redis 0.2 ships (#6013).
