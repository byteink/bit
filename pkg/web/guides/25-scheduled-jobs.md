# Run a nightly article digest

Inkwell should summarize yesterday's new articles without keeping an HTTP
request open until the next morning. The finished app schedules a digest at
02:00 UTC and lets its background queue run it.

## Run the finished app

Set the database, token and session settings from [Run the finished app](README.md#run-the-finished-app),
including `REDIS_URL`, then apply the migrations and start Inkwell:

```sh
cd pkg/web/guides/inkwell
bit migrate
bit run .
```

The app registers `NightlyDigest`, schedules it with
`q.schedule("0 2 * * *", NightlyDigest{}, tz = "UTC")`, then starts the queue.
Its handler counts articles created in the preceding 24 hours, excludes
soft-deleted articles, and writes a `nightly article digest` log record with
an `articles` count. An empty day records zero.

The complete handler and queue setup are in [jobs.bit](inkwell/jobs.bit).
They share the app's existing database pool. `RedisStore` keeps queued jobs
under `{inkwell:jobs}`, and `RedisLocker` lets several app instances share
the schedule without each enqueueing the same tick.

## Keep work through a restart

The queue uses the default missed-tick policy, `Missed.RunOnce`. After a
stall, it collapses missed occurrences into one digest rather than sending
one for every elapsed night. Each run summarizes the 24 hours before that
run; it is not an accounting ledger that reconstructs every missed day.

Redis durability determines whether queued jobs survive a Redis restart.
Use persistent storage and the append-only settings appropriate to your
recovery requirements. Queue delivery is at least once; this handler only
counts and logs, so a retry cannot send duplicate mail or change an article.

Use a separate reporting workflow when you need an exact, permanent record
for each calendar day. See [Scheduled jobs](../../jobs/docs/cron.md) for
missed ticks and time zones, then [Cache article lists in Redis](26-caching-with-redis.md).
