# bitlang.org/pkg/jobs docs

Background jobs: a worker pool, retries with backoff, a dead-letter list,
and a `Store` trait with no default backend. Read the chapters in this
order; each one builds on the last.

| Chapter | Covers |
| ------- | ------ |
| [Getting started](getting-started.md) | the problem a queue solves, `open`/`register`/`enqueue`, starting workers, retries and the dead-letter list, one running example (a welcome-email job) |
| [PostgreSQL](postgres.md) | `PostgresStore`, running the migration, `Store` for writing your own backend, at-least-once delivery and why handlers must be idempotent |

For the front page, install command and status, see the
[package README](../README.md).
