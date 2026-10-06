# Redis

<!-- doctest: per-block -->
<!-- doctest: deps redis -->

[Getting started](getting-started.md) runs a welcome-email job against a
store, and [PostgreSQL and MySQL](sql.md) shows the one that keeps jobs in
your application database. If you already run Redis, `RedisStore` keeps the
queue there instead, and `RedisLocker` lets several instances share one
cron schedule. Both need Redis 7 or newer (or a Valkey of that line).

## The simplest thing that works

`RedisStore` takes a connected pkg/redis `Client`. There is no migration:
the first `enqueue` creates the keys.

```bit
import { open as redisOpen } from "redis"
import { RedisStore, open, Options } from "jobs"

fn main(): ()! {
  let c = redisOpen("redis://localhost:6379")?
  let store = RedisStore(c)?
  let q = open(store, Options{ workers = 4 })?
  q.run()?
  return
}
```

`RedisStore(c)` asks the server for its version once and refuses anything
older than Redis 7, naming what it found, so a server the store cannot serve
fails here and not on the first claim under load:

```text
jobs: the Redis store needs Redis 7 or newer (its scripts read TIME and then write); the server reported redis_version '6.2.14'
```

## What it keeps in Redis

A job is a hash, and two sorted sets say where it is: `ready` holds jobs
waiting for their time, scored by when each becomes available, and `flight`
holds jobs a worker has claimed, scored by when that claim runs out.
Finished jobs are deleted; dead-lettered ones move to a third set, `dead`,
with the reason on the job's hash. With the default prefix the keys are:

```text
{jobs}:seq          the counter job ids come from
{jobs}:job:<id>     name, payload, attempts, max; reason and deadAt when dead
{jobs}:ready        sorted set of ids by availableAt
{jobs}:flight       sorted set of ids by claim expiry
{jobs}:dead         sorted set of ids by when they were dead-lettered
```

Every step that touches more than one of these is one Lua script, run
atomically on the server. A claim is one round trip: the script takes a
job whose claim ran out (a worker that crashed mid-job) or else the oldest
ready one, moves it to `flight` for the visibility timeout and raises its
attempt count. Two workers can never take the same job, on one instance or
fifty.

The script reads the time from the server (`TIME`), so a worker whose own
clock is wrong can neither claim a job early nor take over another worker's
job before its visibility timeout is up. The `availableAt` you hand to
`enqueue` or `retry` is your clock, so the store turns it into a delay before
it stores it: "in 30 seconds by my clock" is 30 seconds on the server's, and a
clock that drifted, yours or Redis's, shifts nothing.

## The prefix, and Redis Cluster

Every key starts with a prefix, `{jobs}` by default (`defaultPrefix`). The
braces matter: Redis Cluster hashes only the text inside them, so one tag
puts all of a queue's keys in one slot and one script can touch them all. A
prefix with no tag would fail on a cluster with a cross-slot error, so
`RedisStore` refuses it up front:

```bit
import { open as redisOpen } from "redis"
import { RedisStore, defaultPrefix } from "jobs"

fn main(): ()! {
  let c = redisOpen("redis://localhost:6379")?
  println("default prefix: ${defaultPrefix}")
  let emails = RedisStore(c, prefix = "{emails}")?
  let reports = RedisStore(c, prefix = "{reports}")?
  println(emails.prefix)
  println(emails.readyKey)
  println(emails.flightKey)
  println(reports.deadKey)
  return
}
```

`prefix`, `readyKey`, `flightKey` and `deadKey` are public so you can look at
a queue from `redis-cli`: `ZRANGE {emails}:dead 0 -1` lists what was
dead-lettered. Two prefixes are two independent queues on one server, and on a cluster
they may live on different nodes. The cost of the tag is that one queue is
one slot: a very hot queue is bound by one node, which is also what keeps
`claim` a single round trip.

## Cron across instances

`RedisLocker` is the `SqlLocker` of [Scheduled jobs](cron.md) on Redis: pass
it as `Options.locker` and three instances enqueue each tick once. Give it
the same prefix as the store so both live in one slot:

```bit
import { open as redisOpen } from "redis"
import { RedisStore, RedisLocker, open, Options } from "jobs"
import { Minute } from "std/time"

@job("send-digest") @json class SendDigest {
  list: string,
}

fn main(): ()! {
  let c = redisOpen("redis://localhost:6379")?
  let store = RedisStore(c)?
  let locker = RedisLocker(c, keep = 256)?
  let q = open(store, Options{ workers = 2, locker = locker })?
  q.every(Minute, SendDigest{ list = "daily" })?
  q.run()?
  return
}
```

A lease is a key holding `<expiry>|<holder>`. One script reads it and
writes it, so acquiring, renewing your own lease and taking over an expired
one are each a single step, and only the holder's token (the instance id)
or an expired lease lets a write through. The expiry is the caller's clock,
not a Redis TTL, for the reason `Locker.tryAcquire` states: a lease that
vanished on real time could let a second instance fire a tick the first
already enqueued. So lease keys carry no TTL; after each win the locker
deletes all but the newest `keep` arrivals of that schedule (and the newest
tick), so a schedule holds at most `keep + 1` keys. `keep` is also how many
missed ticks `Missed.RunAll` may catch up, as with `SqlLocker`. `lastTick`
reads the newest tick back after a restart, and `serverNowNs` is Redis's
`TIME`, which the scheduler compares with its own clock before it fires
anything.

## What Redis does not give you

A Redis queue is as durable as the Redis behind it. With the default
snapshots a crash loses the jobs enqueued since the last one, and with
`appendonly yes` and `appendfsync everysec` it loses up to a second. Turn
the append-only file on for a queue you cannot lose, or keep the jobs in
[PostgreSQL or MySQL](sql.md), where a commit is durable.

Scores in a sorted set are doubles, which hold a nanosecond timestamp to
256 ns. Two jobs enqueued less than that apart for the same instant tie
and run in id order as text, and a job can become claimable up to 256 ns
before its time. Ids, attempt counts and lease ticks are exact: they live
in a counter, a hash and a string, never in a score.

Delivery is at-least-once here as everywhere, so write the handler to be
idempotent: see [At-least-once delivery](sql.md#at-least-once-delivery-and-why-your-handler-must-be-idempotent).

## Next

Back to [Getting started](getting-started.md) for the worker pool, retries
and the dead-letter list this store backs.
