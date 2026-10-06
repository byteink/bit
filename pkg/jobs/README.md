# bitlang.org/pkg/jobs

Background jobs: a worker pool, retries with exponential backoff and full
jitter, a dead-letter list, and stores for PostgreSQL, MySQL 8, MariaDB 10.6 and Redis 7+ (`SqlStore`, `RedisStore`). No default queue
backend, the same call as pkg/web's session and rate-limit stores: an
in-memory queue silently loses every pending job on deploy.

<!-- doctest: deps postgres -->

```bit
import { pool, Datasource } from "std/sql"
import { adapter } from "postgres"
import { SqlStore, migrate, open, Options } from "jobs"
import { Json } from "std/json"

@job("send-welcome") @json class SendWelcome {
  userId: i64,
}

fn main(): ()! {
  let db = pool(adapter(), Datasource{ uri = "postgres://localhost/myapp" })?
  migrate(db)?
  let store = SqlStore(db)?
  let q = open(store, Options{ workers = 4 })?
  q.register<SendWelcome>((job: SendWelcome) => {
    sendWelcomeEmail(job.userId)?
  })?
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
`register<T: Job>` and `enqueue<T: Job>` both read `T`'s `@job` name and use
it to route the job to the right handler.

`bit add bitlang.org/pkg/jobs@v0.3.0` adds it to your project.

## Docs

- [Getting started](docs/getting-started.md): the problem, `open`,
  `register`, `enqueue`, starting workers, retries and the dead-letter
  list, one running example (a welcome-email job).
- [Scheduled jobs](docs/cron.md): `schedule` and `every`, cron
  expressions and zones, missed-tick policies, leader election so three
  instances enqueue each tick once.
- [Watching the queue](docs/logging.md): `Options.logger`, the std/log
  records for a job and for the scheduler, and what is never logged.
- [Redis](docs/redis.md): `RedisStore` and `RedisLocker` on Redis 7+, the
  keys and atomic scripts behind a claim, the hash-tag prefix for Redis
  Cluster, what Redis durability means for a queue.
- [PostgreSQL, MySQL and MariaDB](docs/sql.md): `SqlStore`, the dialect the pool's
  server picks, running the migration, writing your own `Store`,
  at-least-once delivery and idempotent handlers.
