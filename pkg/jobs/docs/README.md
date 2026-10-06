# bitlang.org/pkg/jobs docs

Background jobs: a worker pool, retries with backoff, a dead-letter list,
and a `Store` trait with no default backend. Read the chapters in this
order; each one builds on the last.

| Chapter | Covers |
| ------- | ------ |
| [Getting started](getting-started.md) | the problem a queue solves, `open`/`register`/`enqueue`, starting workers, retries and the dead-letter list, one running example (a welcome-email job) |
| [Scheduled jobs](cron.md) | `schedule` and `every`, cron expressions and zones, the three `Missed` policies, `SqlLocker` so three instances enqueue each tick once, injecting a `Clock` in tests |
| [PostgreSQL, MySQL and MariaDB](sql.md) | `SqlStore` on any of them, `Dialect`, running the migration, `Store` for writing your own backend, at-least-once delivery and why handlers must be idempotent |
| [Watching the queue](logging.md) | `Options.logger`, the records a queue writes for a job and for the scheduler, what an unset logger does, what is never logged |
| [Redis](redis.md) | `RedisStore` and `RedisLocker` on Redis 7+, the keys and the atomic scripts behind a claim, the hash-tag prefix for Redis Cluster, durability |

For the front page, install command and status, see the
[package README](../README.md).
