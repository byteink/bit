<!-- doctest: deps web jobs postgres -->

# Background jobs

Inkwell's API does two things that take real time: it sends a welcome
email when someone registers, and it rebuilds an article's search index
when it is published. Doing either one straight inside the request
handler makes the caller wait for a mail provider or a reindex to finish,
and if the process crashes between saving the row and finishing that
work, the work is simply gone:

```bit
fn createUser(email: string): i64! {
  // insert into the users table, return the new row's id
  return 1
}

fn sendWelcomeEmailNow(userId: i64): ()! {
  // call your mail provider
  return
}

fn registerInline(email: string): i64! {
  let userId = createUser(email)?
  sendWelcomeEmailNow(userId)?
  return userId
}
```

The moment the mail provider is slow, registering a user is slow for a
reason that has nothing to do with creating their account, and a crash
between the two calls above silently drops the email. What you want is to
write down "send this email" and let something else run it, retrying if
the provider hiccups and giving up loudly if it never comes back. That is
`pkg/jobs`: a worker pool with retries and a dead-letter list (the jobs
that kept failing, kept for you to look at), in front of a database table
instead of a request handler. See
[Background jobs](/packages/jobs) for the full reference; this chapter
wires it into Inkwell.

## The simplest thing that works

A job is a class with a stable name and a JSON body. `open` builds a
queue over a store, `register` tells it what to do with a job type, and
`enqueue` adds one:

```bit
import { pool, Datasource } from "std/sql"
import { adapter } from "postgres"
import { SqlStore, migrate, open, Options, Queue } from "jobs"

@job("send-welcome") @json class SendWelcome {
  userId: i64,
}

fn sendWelcomeEmail(userId: i64): ()! {
  // call your mail provider
  return
}

fn openJobQueue(databaseUrl: string): Queue! {
  let db = pool(adapter(), Datasource{ uri = databaseUrl })?
  migrate(db)?
  let store = SqlStore(db)?
  let q = open(store, Options{ workers = 4 })?
  q.register<SendWelcome>((job: SendWelcome) => {
    sendWelcomeEmail(job.userId)?
  })?
  return q
}
```

`@job("send-welcome")` gives `SendWelcome` a stable name that survives
renaming the class - the queue dispatches by that name, never by a typed
string you write yourself. `@json` is required because the payload has to
cross the store as text. `migrate` creates the tables `SqlStore`
needs; running it more than once is safe. A standalone worker process is
the simplest way to run this - `openJobQueue`, then `q.run()` starts the
pool and blocks until something stops it:

```text
fn main(): ()! {
  let q = openJobQueue(env("DATABASE_URL"))?
  q.run()?
}
```

## Building on it: a second job, and workers beside the server

Rebuilding an article's search index after it is published is the same
shape as the welcome email - a second job type, registered on the same
queue. `register` is called once per job type (a second call for the same
name fails, naming the job), and `start` runs the
pool in the background instead of blocking, which is what you want when
jobs share a process with something else:

```bit
@job("reindex-article") @json class ReindexArticle {
  articleId: i64,
}

fn reindexArticle(articleId: i64): ()! {
  // rebuild the search index entry for this article
  return
}

fn startJobs(q: Queue): ()! {
  q.register<ReindexArticle>((job: ReindexArticle) => {
    reindexArticle(job.articleId)?
  })?
  q.start()
  return
}
```

`openJobQueue` already registered `SendWelcome`; `startJobs` adds
`ReindexArticle` and starts the pool. `stop()` is the other half - it
stops handing out new jobs and blocks until whichever job each worker is
already running finishes, the same graceful drain `server.shutdown` uses
for in-flight requests.

## The real use case: wiring it into the web app

The web server built in [Part 4](../../pkg/web/guides/17-operations.md)
enqueues a job instead of doing the slow work itself, and runs the
worker pool alongside its own request handling:

```bit
import { App, Config, Ctx, Res } from "web"
import { Signal, waitForSignal } from "std/signal"
import { parseInt } from "std/strings"

export @json class RegisterInput {
  email: string,
}

fn registerUser(c: Ctx, q: Queue): Res! {
  let input = c.body<RegisterInput>()?
  let userId = createUser(input.email)?
  q.enqueue(SendWelcome{ userId = userId })?
  return c.text("created").status(201)
}

fn publishArticle(c: Ctx, q: Queue): Res! {
  let articleId = parseInt(c.param("id")) catch _ {
    return c.text("invalid id").status(400)
  }
  q.enqueue(ReindexArticle{ articleId = articleId })?
  return c.text("published")
}

fn mountRoutes(app: App, q: Queue) {
  app.post("/users", (c) => registerUser(c, q))
  app.post("/articles/:id/publish", (c) => publishArticle(c, q))
}

fn serveWithJobs(databaseUrl: string): ()! {
  let app = App(Config{ secret = "change-me" })
  let q = openJobQueue(databaseUrl)?
  startJobs(q)?
  mountRoutes(app, q)
  let srv = app.serve()?
  waitForSignal([Signal.Term, Signal.Int])
  q.stop()
  srv.shutdown(10_000)?
}
```

`registerUser` and `publishArticle` return as soon as the job is written
down, not once the email is sent or the index is rebuilt - the request
that created the work is never the one waiting on it. On shutdown,
`q.stop()` drains whatever jobs the workers already claimed before
`srv.shutdown` drains whatever requests were already in flight, so
neither a half-sent email nor a half-handled request is the cost of a
deploy.

## Sharp edges

**Retries and the dead-letter list.** `enqueue`'s extra arguments are how
many times to try before giving up, passed positionally:

```bit
fn enqueueWelcome(q: Queue, userId: i64): ()! {
  q.enqueue(SendWelcome{ userId = userId }, 0, 5)?
  return
}
```

`enqueue(job, delay, maxAttempts)` - `delay` is nanoseconds before the job
is first claimable, `maxAttempts` is 5 here. When a handler fails, the job
waits a random time before each retry, roughly 0-1s after the first
failure and doubling each time up to 5 minutes, so a mail provider
outage does not turn into every worker hammering it back to life the
instant it recovers. After the 5th failed attempt the job moves to the
dead-letter list instead of being retried again, for you to inspect and
requeue by hand.

**An unregistered job name.** If a worker claims a job whose name nothing
has `register`ed - a class renamed after jobs were already queued under
its old `@job` name, or a deploy that removed a handler - it goes straight
to the dead-letter list, rather than being retried forever or dropped
silently.

**A panic is a failure, not a crash.** A handler that panics does not take
the worker down; it is caught and treated exactly like a failed job, on
the same retry-then-dead-letter path above.

**At-least-once delivery.** A worker can be killed right after
`sendWelcomeEmail` succeeds but before the store hears about it, so
another worker claims and runs the same job again. `SendWelcome` and
`ReindexArticle` are both safe to run twice - sending the same welcome
email is a nuisance, not a correctness bug, and reindexing an article is
already idempotent - but a handler that debits an account or charges a
card needs its own check for "did I already do this". See
[Background jobs](/packages/jobs) for how to write one.

## When not to use a queue

If the caller needs the answer before you can tell them it worked -
validating a credit card before confirming an order - it does not belong
in a queue. Reach for one when the caller's own request can succeed
without waiting for the work to finish, which is true of a welcome email
and a search index and false of the payment itself.

## What you built

Inkwell now writes down slow work instead of doing it inline, and a
worker pool that runs beside the server picks it up, retries what fails,
and drains cleanly on shutdown along with everything else in flight.

Specification: [pkg/jobs](/packages/jobs).

Previous: [Operations](../../pkg/web/guides/17-operations.md). Next:
[Making it fast](32-making-it-fast.md).
