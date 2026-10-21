# Run a nightly article digest

Inkwell should summarize yesterday's new articles without keeping an HTTP
request open until the next morning. Schedule a small job at 02:00 UTC,
and let the background queue run it beside the API.

<!-- doctest: deps jobs redis orm -->

## Run the finished app

Set the database, token and session settings from
[Run the finished app](README.md#run-the-finished-app), including `REDIS_URL`.
Apply the migrations before starting Inkwell:

```sh
cd pkg/web/guides/inkwell
bit migrate
bit run .
```

At 02:00 UTC, the app writes a `nightly article digest` log record with an
`articles` count. An empty day records zero. You do not need to leave a
browser or an HTTP connection open.

## Count the articles in one interval

Start with the work the job must do. The following imports and declarations
come from the app's [jobs.bit](inkwell/jobs.bit) and its shared imports.
The Bit blocks on this page form one module.

```bit
import { Db } from "orm"
import { Client as RedisClient } from "redis"
import { now } from "std/time"
import { Queue, Options as JobOptions, RedisStore, RedisLocker, open as openJobs } from "jobs"
import { getDefault as digestLogger } from "std/log"
import { Hour as DigestHour } from "std/time"

@job("nightly-digest") @json class NightlyDigest {}

@table("articles") class DigestCount {
  total: i64,
}

fn digestArticleCount(db: Db, at: i64): i64! {
  let since = at - i64(24 * DigestHour)
  let rows = db.query<DigestCount>(
    "select count(*) as total from articles where deleted_at is null and created_at >= ? and created_at < ?",
    since, at,
  )?
  assert(len(rows) == 1, "digest count must return one row")
  return rows[0].total
}

fn runNightlyDigest(db: Db): ()! {
  let total = digestArticleCount(db, now().ns)?
  digestLogger().info().int("articles", int(total)).log("nightly article digest")
}
```

`NightlyDigest` is the queue's payload. It contains no request or database
connection; the handler receives the app's existing `Db` instead. The query
binds its time limits and excludes soft-deleted articles. Its lower limit
is inclusive and its upper limit is exclusive.

The handler counts the 24 hours before it runs. If it starts late, that
window moves with it. It does not reconstruct a report for a named calendar
day. Keep that distinction when you turn a log record into an email or a
billing operation.

## Register the handler before starting the queue

The same file opens the queue, connects the job type to its handler, and
adds the schedule:

```bit
fn openDigestQueue(db: Db, redis: RedisClient): Queue! {
  let store = RedisStore(redis, prefix = "{inkwell:jobs}")?
  let locker = RedisLocker(redis, prefix = "{inkwell:jobs}")?
  let q = openJobs(store, JobOptions{ workers = 1, locker = locker })?
  q.register<NightlyDigest>((job) => {
    runNightlyDigest(db)?
  })?
  q.schedule("0 2 * * *", NightlyDigest{}, tz = "UTC")?
  return q
}
```

`register` supplies the function that does the work. `schedule` supplies
when to enqueue that work. The expression `0 2 * * *` means 02:00 every day;
`tz = "UTC"` makes that time independent of the server's local time zone.
Registration and scheduling can fail, so `?` returns those errors to startup.

`RedisStore` keeps jobs under `{inkwell:jobs}`. `RedisLocker` lets app
instances share the schedule without each enqueueing the same tick. Use
the same dedicated Redis service and prefix on those instances.

The app's [main.bit](inkwell/main.bit) starts the returned queue before
listening for requests. These lines are an excerpt from that existing
function; `db`, `redis` and `app` are its already-open resources:

```text
  let jobs = openDigestQueue(db, redis)?
  jobs.start()
  defer jobs.stop()
  app.listen()?
```

## Keep work through a restart

The queue uses the default missed-tick policy, `Missed.RunOnce`. After a
stall, it collapses missed occurrences into one digest. It does not enqueue
one report for every elapsed night.

Redis durability determines whether queued jobs survive a Redis restart.
Use persistent storage and the append-only settings that meet your recovery
requirements. Queue delivery is at least once. This handler only counts and
logs, so a retry cannot send duplicate mail or change an article. An email
handler would need its own protection against duplicate sends.

Use a reporting workflow with stored day boundaries when you need an exact,
permanent record for each calendar day. See [Scheduled jobs](../../jobs/docs/cron.md)
for missed ticks and time zones. Next, [Cache article lists in Redis](26-caching-with-redis.md).
