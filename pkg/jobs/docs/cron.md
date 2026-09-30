# Scheduled jobs

<!-- doctest: deps postgres -->

Inkwell needs two chores. Every night at 02:00 New York time it emails
readers a digest of the day's new articles, and every 15 minutes it prunes
abandoned drafts. The usual answer is a crontab entry on one host that runs
a script. That works until the host is replaced, until the script needs the
same retries and dead-letter list your other jobs already have, or until
you run three copies of the app and the digest goes out three times.

A schedule in this package is not a second system. It is a producer for the
queue you already have: when a tick comes due, it enqueues an ordinary job,
and your workers run it with the retries and dead-lettering from
[Getting started](getting-started.md).

## The simplest thing that works

`schedule` takes a cron expression and a job. `every` takes a period.
Both go on the same `Queue` as `register`, before `run`:

```bit
import { pool, Pool, Datasource } from "std/sql"
import { adapter } from "postgres"
import { newPostgresStore, migrate, open, Options, Missed, Queue } from "jobs"
import { Json } from "std/json"
import { Minute } from "std/time"

@job("nightly-digest") @json class NightlyDigest {
  list: string,
}

@job("prune-drafts") @json class PruneDrafts {
  olderThanDays: i64,
}

fn main(): ()! {
  let db = pool(adapter(), Datasource{ uri = "postgres://localhost/inkwell" })?
  migrate(db)?
  let q = open(newPostgresStore(db), Options{ workers = 4 })?
  q.register<NightlyDigest>((job: NightlyDigest) => {
    sendDigest(job.list)?
  })
  q.register<PruneDrafts>((job: PruneDrafts) => {
    pruneDrafts(job.olderThanDays)?
  })
  q.schedule(
    "0 2 * * *",
    NightlyDigest{ list = "readers" },
    missed = Missed.RunOnce,
    tz = "America/New_York",
  )?
  q.every(15 * Minute, PruneDrafts{ olderThanDays = 30 })?
  q.run()?
  return
}

fn sendDigest(list: string): ()! {
  // build and send the digest
  return
}

fn pruneDrafts(olderThanDays: i64): ()! {
  // delete drafts nobody has touched
  return
}
```

`q.run()` now also starts a scheduler next to the workers. It sleeps until
the earliest tick that is due, enqueues that job, and goes back to sleep;
it never polls in a loop. `missed` and `tz` are optional, and default to
`Missed.RunOnce` and `"UTC"`.

## Cron expressions and time zones

An expression has five fields: minute, hour, day of month, month, day of
week. Each field takes `*`, a value, a range (`9-17`), a step (`*/15`,
`0-30/10`) or a comma list of those. Months and weekdays also take names
(`JAN`, `MON-FRI`). As in every cron, once either day field is restricted
the two are "or"ed: `0 9 15 * MON` fires on the 15th and on Mondays.

`tz` is a zone name, read in the same `std/time` zone data as
`zone(name)`, and it is checked when `schedule` is called: an unknown zone
or a bad expression makes `schedule` fail at startup, not at 02:00. A
daylight saving change follows the rule Vixie cron documents in `man 8
cron`: a job that runs at a specific time runs once, and a job that runs
every hour or more often keeps following the clock. Which one a job is
depends on its minute and hour fields. If either is `*` (or a `*` step such
as `*/15`, or the whole range), the job follows real time: on a fall-back
night it fires in both passes through the repeated hour, and on a
spring-forward night the skipped times do not exist, so it does not fire in
them. If both are named (`30 1`, `0,30 2`), the job fires once per matching
wall time: a time that happens twice fires at its first occurrence, and a
time that does not exist fires once, at the first instant after the gap.

For example, in New York, where 01:00 to 02:00 happens twice on 2026-11-01
and 02:00 to 03:00 does not exist on 2026-03-08:

```text
30 1 * * *   on 2026-11-01: 01:30 EDT only, not 01:30 EST again
0 * * * *    on 2026-11-01: 01:00 EDT, 01:00 EST, 02:00 EST
30 2 * * *   on 2026-03-08: 03:00 EDT, once
```

The next tick is always later than the moment you ask from, even when you
ask from the second 01:30 of a fall-back night.

To see what an expression means before you ship it, `parseCron` gives you
the same schedule the queue uses:

```bit
import { parseCron } from "jobs"
import { utc, Timestamp } from "std/time"

fn nextDigestAfter(afterNs: int): int! {
  let cs = parseCron("0 2 * * *")?
  let after = Timestamp{ ns = afterNs }.inZone(utc())
  let next = cs.nextAfter(after)?
  let ts = next.toTimestamp()?
  return ts.ns
}
```

`every` needs no calendar. Its ticks are multiples of the period counted
from the Unix epoch, not from when the process started, so every instance
of the app agrees on them without talking to each other.

## Building on it: what happens after downtime

The scheduler's loop can fall behind: the process is paused, the machine
sleeps, the database was unreachable for ten minutes. When it catches up,
ticks are due that the scheduler did not reach on time, and `missed` says
what to do about them. A tick is missed when the scheduler reaches it more
than a minute after its due time, or after the next tick is already due,
whichever comes first. Every other tick is on time and is always enqueued,
whatever `missed` says. So the newest due tick is missed only when it is over
a minute late, and an older one is missed as soon as the tick after it is
due: `every(1 * Second)` after a three second stall has two missed ticks and
one on time. Each tick the policy drops is logged to stderr, once, with the
schedule, the window of missed ticks and how many were enqueued.

- `Missed.Skip` drops every missed tick. Use it when only the freshest
  answer matters, like a cache warm-up.
- `Missed.RunOnce` enqueues one job for all of them. The default, and right
  for the nightly digest: the readers want one email, not six.
- `Missed.RunAll(cap)` enqueues one job per missed tick, at most `cap`, the
  most recent ones. Use it when each tick stands for a period that must be
  accounted for, such as a job that closes a day of the ledger: skipping a
  tick leaves a day unclosed, and collapsing two ticks closes two days as
  one. The cap is a promise that a long outage produces a bounded burst of
  jobs, not thousands.

The nightly digest runs at 02:00, and the app is down across that run:

```text
02:00  the digest is due; nothing is running
02:30  the app starts: the 02:00 tick is 30 minutes late, so it is missed
       Skip enqueues nothing and waits for 02:00 tomorrow
       RunOnce and RunAll(cap) enqueue the digest once
```

A short outage is not downtime. The database fails at 02:00:00 and comes back
at 02:00:40, or a deploy restarts the app at 02:00:30:

```text
02:00:00  the digest is due; the store is down, the pass fails and retries
02:00:40  the store is back: the tick is 40 seconds late, so it is on time
          Skip, RunOnce and RunAll(cap) all enqueue the digest once
```

Had the store stayed down until 02:01:01, the tick would be missed and `Skip`
would drop it, and log it. `missedEnqueueCount` is the arithmetic the
scheduler uses for the policy, exposed so you can check it against your own
numbers:

```bit
import { missedEnqueueCount } from "jobs"

fn ledgerBurst(): int {
  // six days missed, at most four catch-up jobs
  return missedEnqueueCount(6, Missed.RunAll(4))
}
```

The downtime can also be the whole app. With a `Locker` (next section) the
scheduler asks it, when it starts, for the newest tick each schedule ever
enqueued, and begins at the first tick after that. Every tick that came due
while nothing was running is then handled by `missed` exactly like a stall.
The nightly digest, with `Missed.RunAll(2)`:

```text
Thu 02:00  digest enqueued
Thu 22:00  the app goes down
Mon 09:00  the app starts: the last enqueued tick is Thu 02:00
           ticks Fri, Sat, Sun and Mon 02:00 are due
           RunAll(2) enqueues Sun and Mon; RunOnce would enqueue Mon only,
           Skip nothing
Tue 02:00  the next tick, on time
```

A schedule that never fired starts at its first tick after the app starts, and
without a `Locker` there is nothing to read, so a restart starts each
schedule at its first tick after it starts.

## The real use case: three copies of the app

With three instances, all three reach 02:00 together. Give each a `Locker`
and only one of them enqueues the tick. `PostgresLocker` keeps a lease row
per tick in the same database as the queue (`migrate` creates its table):

```bit
import { newPostgresLocker } from "jobs"

fn openOnEveryInstance(db: Pool, instance: string): Queue! {
  let q = open(
    newPostgresStore(db),
    Options{ workers = 4, locker = newPostgresLocker(db), instanceId = instance },
  )?
  q.schedule("0 2 * * *", NightlyDigest{ list = "readers" }, tz = "America/New_York")?
  return q
}
```

`instanceId` names the instance in the lease table and defaults to a random
one. The lease is per tick, not per schedule, so if the instance that won
tick 02:00 dies a second later, the others do not fire it again: the tick's
lease is already taken. A lease expires after an hour, which only lets
another instance take that tick over. The rows are also how a restarted app
learns its last tick, so they are never deleted by age: each schedule keeps
its newest 1024 lease rows and the older ones are dropped as new ticks are
won. That count is the locker's lease window, and `schedule` and `every`
refuse a `Missed.RunAll` cap above it, because a catch-up that long would drop
lease rows another instance still races for. With `keep = 200`, this fails when
the schedule is registered:

```bit
fn smallLeaseWindow(db: Pool): Locker {
  return newPostgresLocker(db, keep = 200)
}

fn ledgerTooWide(q: Queue) {
  q.every(Minute, NightlyDigest{ list = "readers" }, missed = Missed.RunAll(500)) catch e {
    eprint("${e.message()}\n")
  }
}
```

```text
jobs: Missed.RunAll(500) exceeds the locker's lease window of 200; raise newPostgresLocker(keep = ...)
```

Without a `locker`, every instance enqueues every tick. That is right for a
single instance and wrong for two. To use another lock service, write a
`Locker`: three methods.
`tryAcquire(key, holder, nowNs, expiresAt)` returns true when `holder` owns
`key` after the call and false when someone else's lease has not expired;
compare `expiresAt` against the `nowNs` you are given, not your own clock.
`lastTick(key)` returns the newest tick number won for the schedule `key`
(a lease key is `key` then `@` then the tick), or 0 when there is none. `window()` returns
how many of the newest ticks of one schedule the locker still remembers, the
cap `schedule` and `every` hold `Missed.RunAll` to. A locker that forgets its
ticks, like the one below, only loses the catch-up after downtime, and it has
no lease rows to prune, so its window is as large as you will allow.

```bit
import { Locker, Store } from "jobs"

class singleHost {
  export tryAcquire(key: string, holder: string, nowNs: int, expiresAt: int): bool! {
    return true
  }

  export lastTick(key: string): int! {
    return 0
  }

  export window(): int {
    return 1000000
  }
}

fn openOnOneHost(store: Store): Queue! {
  let leader: Locker = singleHost{}
  return open(store, Options{ workers = 2, locker = leader })?
}
```

## Testing a schedule without waiting for it

`Options.clock` replaces the wall clock. A `Clock` has two methods,
`nowNs` and `pause`, and a test that moves its own time crosses a day of
ticks in milliseconds and never depends on how loaded the machine is:

```bit
import { Clock } from "jobs"
import { sleep, Millisecond } from "std/time"

class handClock {
  ns: int

  export nowNs(): int {
    return this.ns
  }

  export pause(d: int) {
    sleep(Millisecond)
  }
}

fn openForTest(store: Store, clock: Clock): Queue! {
  return open(store, Options{ workers = 1, clock = clock })?
}
```

## Mistakes it refuses at startup

`open`, `schedule` and `every` fail at once, with the wrong value in the
message, for what would otherwise misbehave hours later:

```text
jobs: Options.pollInterval must be positive, got 0
jobs: Options.visibilityTimeout must be positive, got -1
jobs: the locker keeps 0 lease row(s) per schedule; it must keep at least 1 (newPostgresLocker(keep = ...))
jobs: Missed.RunAll cap must be at least 1, got 0
jobs: Missed.RunAll(500) exceeds the locker's lease window of 200; raise newPostgresLocker(keep = ...)
jobs: schedule 'nightly-digest|0 2 * * *|UTC' registered after start(); register schedules before start() or run()
```

A zero `pollInterval` would spin the workers and the scheduler; a locker that
keeps no lease rows (`newPostgresLocker(db, keep = 0)`) would forget every tick
it wins, so `open` refuses it instead of quietly keeping one; a `RunAll` cap
below 1 would drop ticks that are on time; a schedule registered after
`start()` or `run()` would never be seen by the scheduler already running.
Register every schedule right after `open`, before either call.

## Sharp edges

- Scheduling the same job with the same expression and zone twice fails:
  the two would share a lease and fire twice.
- A scheduled job is an ordinary job, delivered at least once. A handler
  that runs the same tick twice must produce the same result, as described
  in [PostgreSQL](postgres.md).
- `every` takes nanoseconds, like `enqueue`'s `delay`; `15 * Minute` is the
  readable form. A period of zero or less fails.
- `L`, `W` and `#` (last day of month, nearest weekday, nth weekday) are
  not supported. `schedule` rejects them.

## When not to use this

A schedule is at-least-once and only as punctual as its workers. If work
must start within a second of the clock, or must not run twice under any
failure, a queue-backed schedule is the wrong tool. If the work has to run
once per deploy rather than once per tick, use a migration.

## Next

[PostgreSQL](postgres.md) covers the store and the lease table behind
`PostgresLocker`, and why handlers must be idempotent.
