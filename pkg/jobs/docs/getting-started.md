# Getting started with background jobs

<!-- doctest: deps postgres -->

A user signs up and your handler needs to send them a welcome email. Doing
it inline is the obvious thing:

```bit
import { Json } from "std/json"
fn createUserSync(email: string): ()! {
  // insert into your database
  return
}

fn sendWelcomeEmailSync(email: string): ()! {
  // call your mail provider
  return
}

fn signUp(email: string): ()! {
  createUserSync(email)?
  sendWelcomeEmailSync(email)?
  return
}
```

The moment the mail provider is slow or down, `signUp` is slow or down too,
and the user's request fails for a reason that has nothing to do with
creating their account. What you want is to record "send this email" and
let something else worry about actually sending it, retrying if the
provider hiccups, and giving up loudly if it never comes back.

That is a job queue: a place to put small units of work, and a pool of
workers that pick them up, run them, and retry the ones that fail.

## The simplest thing that works

A job is a class with a stable name and a JSON-shaped payload. `open`
builds a queue over a `Store`; `register` tells it what to do with a job
type; `enqueue` adds one. `jobs` ships no default store (this package's own
README), so every runnable example on this page opens a `SqlStore` -
see [PostgreSQL, MySQL and MariaDB](sql.md) for what `migrate` and `SqlStore` do.

```bit
import { pool, Datasource } from "std/sql"
import { adapter } from "postgres"
import { SqlStore, PermanentFailure, migrate, open, Options, Store } from "jobs"

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

`q.run()` starts the worker pool and blocks - the shape a standalone
worker process wants. `@job("send-welcome")` gives `SendWelcome` a stable
name that survives renaming the class: the queue dispatches by that name,
never by a typed string you write yourself, and `@json` is required
because the payload has to cross the store as text.

## Building on it: workers alongside other work

A worker process is one shape. Often you want jobs running inside the same
process as your web server instead - `start`/`stop` do that. `store` here
is the same `SqlStore` `main` above already opened:

```bit
fn runAlongsideWebServer(store: Store): ()! {
  let q = open(store, Options{ workers = 4 })?
  q.register<SendWelcome>((job: SendWelcome) => {
    sendWelcomeEmail(job.userId)?
  })?
  q.start()
  // ... serve requests, run migrations, whatever this process does ...
  q.stop()
  return
}
```

`start()` returns immediately and runs `Options.workers` green threads in
the background. `stop()` tells them to stop taking new jobs and then
blocks until whichever job each one is running finishes - a graceful
drain, never an abandoned half-sent email.

## The real use case: retries and the dead-letter list

The mail provider fails sometimes. `enqueue`'s third argument is how many
times to try before giving up:

```bit
fn runWithRetries(store: Store): ()! {
  let q = open(store, Options{ workers = 4 })?
  q.register<SendWelcome>((job: SendWelcome) => {
    sendWelcomeEmail(job.userId)?
  })?
  q.enqueue(SendWelcome{ userId = 1 }, 0, 5)?
  q.run()?
  return
}
```

`enqueue(job, delay, maxAttempts)` - `delay` is nanoseconds before the job
is first claimable, `maxAttempts` is 5 here. When the handler fails
(`fail`s, or panics), the job is retried with exponential backoff and full
jitter: roughly 0-1s after the first failure, 0-2s after the second,
doubling up to a 5-minute ceiling, so a provider outage does not turn into
every worker hammering it back to life in lockstep the instant it recovers.
After the 5th failed attempt, the job moves to the dead-letter list instead
of being retried again - visible in your store's `bit_jobs` table
(`dead_lettered = true`, `dead_reason` set to the failure's message), for
you to inspect and requeue by hand.

The arguments can also be named: `enqueue(SendWelcome{ userId = 1 },
maxAttempts = 5)` leaves `delay` at its default of 0.

## Giving up at once: PermanentFailure

Some failures are the same on every try: the provider refused the address
for good. Retrying only delays the dead-letter list and hammers the
provider. A handler that knows a retry cannot help fails with a
`PermanentFailure`, and the job goes to the dead-letter list on that attempt,
whatever `maxAttempts` was:

```bit
fn runGivingUp(store: Store): ()! {
  let q = open(store, Options{ workers = 4 })?
  q.register<SendWelcome>((job: SendWelcome) => {
    if (job.userId < 0) {
      fail PermanentFailure{ reason = "user ${job.userId} does not exist" }
    }
    sendWelcomeEmail(job.userId)?
  })?
  q.enqueue(SendWelcome{ userId = -1 }, 0, 5)?
  q.run()?
  return
}
```

`reason` is what the dead-letter list records. Every other failure is still
retried with backoff.

## Sharp edge: an unregistered job name is dead-lettered, loudly

If a worker claims a job whose name nothing has `register`ed - a class
renamed after jobs were already queued under its old `@job` name, or a
deploy that removed a handler - it goes straight to the dead-letter list
with the reason `no handler registered for '<name>'`, rather than being
retried forever or dropped silently.

## Sharp edge: a second handler for one job name fails

`register` keeps one handler per `@job` name. Registering the same job on a
queue twice would leave one handler dead, so the second call fails at startup
and names the job:

```text
jobs: register: a handler for job 'send-welcome' is already registered on this Queue
```

## Sharp edge: bad options fail in `open`

`open` checks the options before it returns a queue: `workers`,
`pollInterval` and `visibilityTimeout` must all be positive. A zero
`pollInterval` would make every idle worker spin on the store, so it fails
at startup and names the value:

```text
jobs: Options.pollInterval must be positive, got 0
```

Leave a field out to get its default (4 workers, 500 ms, 30 s).

## Sharp edge: a panic is a failure, not a crash

A handler that panics does not take the worker down. The panic is caught
and treated exactly like a `fail` - the same retry-then-dead-letter path
above - so a bug in one handler cannot stop every other job in the queue
from being processed.

## When not to use this

If the work has to happen before you can tell the caller it succeeded -
validating a credit card before confirming an order - it does not belong
in a queue: the caller needs the answer now, not "we will let you know."
Reach for a job when the caller's own request can succeed without waiting
for the work to finish.

## Next

[PostgreSQL, MySQL and MariaDB](sql.md): a real `Store`, the migration, writing your own
store, and why a handler that runs the same job twice must produce the
same result.
