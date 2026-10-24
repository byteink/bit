# Send welcome mail through a background queue

A registration request should not wait for a mail relay to answer. Inkwell
already separates these steps: the request saves an author and queues a
welcome message; a worker sends it later. Follow that one job from the
request to its final queue outcome.

Use the [welcome-mail chapter](22-sending-email.md) for relay setup and
[verification and password recovery](23-email-verification-and-password-reset.md)
for the links in those messages. This chapter follows the worker, rather
than adding another mail sender or another application.

<!-- doctest: deps jobs -->

## Run one registration through the queue

Use the PostgreSQL, Redis, session and token settings from
[Run the finished app](README.md#run-the-finished-app), and the development
relay you already run for the welcome-mail chapter. Start the finished app:

```sh
cd pkg/web/guides/inkwell
export SMTP_HOST=127.0.0.1
export SMTP_PORT=1025
export SMTP_FROM=welcome@example.test
export VERIFY_EMAIL_URL=http://localhost:8080/confirm
bit migrate
bit run .
```

The confirmation address is a trusted page you supply; this app does not
serve that page. In another terminal, register a fresh author:

```sh
curl --fail-with-body -i http://127.0.0.1:8080/v1/auth/register \
  -H 'Content-Type: application/json' \
  -d '{"username":"queue-author","email":"author@example.test","password":"development-password"}'
```

With mail configured, `201` means the account was saved and the job was
queued. It does not mean the recipient received the message. Inspect the
development relay for `Welcome to Inkwell`, the recipient and welcome text.
There is no separate worker command to start for this example: the finished
app starts its queue alongside the API.

Leaving `SMTP_HOST` and `SMTP_FROM` empty disables mail. Registration can still
succeed without enqueueing a welcome job in that configuration. A partial
mail configuration fails startup instead of silently discarding mail.

## Give the stored work a type

The payload in [jobs.bit](inkwell/jobs.bit) is a complete declaration:

```bit
@job("send-welcome-email") @json class SendWelcomeEmail {
  email: string,
  username: string,
  verificationLink: Option<string> = Option.None,
}
```

`@job` supplies its queue name; `@json` lets the queue encode and decode the
payload. The payload carries values, not an HTTP context, a Redis connection
or an open mail client. The worker can reconstruct the work after the
request has ended.

The optional link keeps older welcome jobs readable. A job without a link
still sends the original welcome text; the worker does not silently issue a
new verification token. A retried job keeps its existing link, which may
expire before delayed delivery.

This payload contains an address, a username and, when present, a usable
verification link. Treat the Redis queue and its backups as sensitive data.
Do not print the payload while diagnosing a retry.

## Connect the type to its real handler

The app opens its producer queue with this function. This is an exact
source excerpt, not a second standalone program:

```text
fn openMailQueue(cfg: AppConfig, redis: RedisClient): Queue! {
  validateMailConfig(cfg)?
  let store = RedisStore(redis, prefix = "{inkwell:jobs}")?
  let locker = RedisLocker(redis, prefix = "{inkwell:jobs}")?
  let q = openJobs(store, JobOptions{ workers = 1, locker = locker })?
  q.register<SendWelcomeEmail>((job) => deliverWelcome(cfg, job))?
  return q
}
```

`RedisStore` persists the jobs. `RedisLocker` coordinates scheduled ticks
between app instances; it does not make mail delivery exactly once.
Both use the same `{inkwell:jobs}` prefix. `register<SendWelcomeEmail>`
connects the stored job name to the typed delivery handler before workers
start. Registering the same name twice on one queue is an error.

[Redis queue storage](../../jobs/docs/redis.md) explains the ready,
in-flight and dead-letter sets. Pending work survives an application restart
only while Redis keeps it; Redis restart recovery also depends on your
persistence and backup policy.

## Enqueue only after the account transaction

The end of [register](inkwell/auth.bit) runs after its PostgreSQL transaction
has committed:

```text
  // Redis cannot join the PostgreSQL transaction: enqueue errors remain visible.
  if (mailConfigured(cfg)) {
    jobs.enqueue(
      SendWelcomeEmail{
        email = saved.email,
        username = saved.username,
        verificationLink = Option.Some(link),
      },
    )?
  }
```

The queue encodes the payload and persists it in Redis. Enqueueing does not
call the delivery handler in the HTTP request. The request and worker can
use different `Queue` values because their stores share the same Redis
service and prefix.

PostgreSQL and Redis do not commit together here. If enqueueing fails, the
error reaches the API even though the account and verification data may
already exist. Check the saved account before retrying registration; the
same username or address can now return a conflict. This path has no
transactional outbox that repairs that gap automatically.

## Start the worker before listening

The real worker queue is opened by `openDigestQueue` in the same app file:

```text
fn openDigestQueue(db: Db, redis: RedisClient, cfg: AppConfig): Queue! {
  let q = openMailQueue(cfg, redis)?
  q.register<SendPasswordResetEmail>((job) => deliverPasswordReset(db, cfg, job))?
  q.register<NightlyDigest>((job) => {
    runNightlyDigest(db)?
  })?
  q.schedule("0 2 * * *", NightlyDigest{}, tz = "UTC")?
  return q
}
```

It starts with the welcome handler and adds the password-reset and nightly
handlers. A worker must know every job type that it may claim from this
shared queue. An unknown name is dead-lettered, rather than treated as a
successful no-op.

`runNightlyDigest` counts recent articles and writes `nightly article digest`
to the log. It does not send a digest email. The next chapter covers its
schedule; the welcome job in this chapter is enqueued by registration.

The finished [entry point](inkwell/main.bit) owns the database, Redis client
and worker lifecycle:

```text
fn main(): ()! {
  let cfg = loadConfig()?
  let db = open(cfg.databaseUrl)?
  defer db.pool.close()
  let redis = openRedis(cfg.redisUrl)?
  defer redis.close()
  let app = buildAppFromDb(cfg, db, openIdempotencyStore(db)?, redis)?
  let jobs = openDigestQueue(db, redis, cfg)?
  jobs.start()
  defer jobs.stop()
  app.listen()?
}
```

The app uses a queue for requests and a queue for running workers over the
same store. `start()` returns after starting the workers, so `app.listen()`
can serve HTTP while they work. There is no mail request held open until a
worker finishes.

## See failures without exposing the job

The welcome handler in [jobs.bit](inkwell/jobs.bit) calls the existing
sender from [mail.bit](inkwell/mail.bit):

```text
fn deliverWelcome(cfg: AppConfig, job: SendWelcomeEmail): ()! {
  // A relay can echo the bearer link in its refusal; jobs logs handler failures.
  sendWelcome(cfg, job.email, job.username, job.verificationLink) catch _ {
    fail newError("inkwell: welcome email delivery failed")
  }
}
```

A relay can include the usable link in an error response. The handler
replaces that error with `inkwell: welcome email delivery failed` before
passing it back to the queue. It still fails; redaction does not turn a
failed send into success.

With this app's default queue options, per-job `job started` and `job done`
records are not enabled. Delivery failures still produce operational
`job retry` or `job failed permanently` records through the default logger.
Use the relay and queue outcome to check delivery, rather than waiting for
a success log the app has not enabled. See [Queue logging](../../jobs/docs/logging.md)
for the logger option and its data boundary.

## Expect retries and possible duplicate mail

Registration uses the queue's default `maxAttempts = 5`. An ordinary handler
failure is retried with jittered backoff while attempts remain; otherwise
the job is dead-lettered. A successful handler is acknowledged by removing
the stored job. [Queue delivery](../../jobs/docs/getting-started.md) describes
these outcomes.

Those rules do not make the mail side effect atomic with its queue
acknowledgement. The relay may accept a message before the worker crashes,
loses its connection or fails to acknowledge it. A stale claim can be taken
again after its visibility timeout. A handler that outlives that timeout
can overlap another attempt. None of those paths guarantees a single send,
and the attempt setting is not an exactly-once delivery guarantee.

Keep side effects safe to repeat when you add work to this queue. Do not
use this welcome-mail flow as a guarantee for a non-repeatable payment or
another operation that needs its own durable coordination.

## Drain the queue deliberately

`Queue.stop()` clears the running flag and waits for the worker and
scheduler loops. Workers check that flag between jobs; it does not cancel
a handler that is already running. A handler that never returns can keep
that wait open. Jobs still waiting in Redis are not deleted by `stop()`.
Keep Redis and the database available until the workers finish.

The deferred call in this entry point describes cleanup when control
unwinds `main`. The current entry point uses blocking `app.listen()` and
does not install a signal-driven HTTP shutdown hook. Do not assume an abrupt
process termination will run the deferred queue drain. See
[Operations](17-operations.md) for the server lifecycle boundary before
designing a deployment shutdown sequence.

Use this queue when its retry and duplicate-delivery behavior fits the
work. Continue with [Run a nightly article digest](25-scheduled-jobs.md) for
scheduled work, or return to the [course index](README.md).
