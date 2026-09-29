# Lock a row so two writers can't both change it

Two moderators open the same reported article at the same time, both edit
`status`, and both save. A plain `find`/`update` has no idea either of them
is happening: whichever `update` runs last wins, silently, and the first
moderator's change is gone with no error to explain why. `tx.table<T>().
lock()` is what turns "read a row" into "read a row and hold it until this
transaction decides what happens to it" - the second `find` inside a
locking transaction simply waits until the first one commits or rolls back.

## The simplest thing that works

```bit
import { Db, open } from "orm"

@table class Article {
  id: i64,
  title: string,
  status: string,
}

fn approve(db: Db, id: i64): ()! {
  db.tx((tx) => {
    let articles = tx.table<Article>()
    let a = articles.lock().find(id)? // held until this closure returns
    a.status = "approved"
    articles.update(a)?
  })?
}
```

`lock()` only exists on `tx.table<T>()` - the repository a `db.tx((tx) =>
{ ... })?` closure hands you, never on `db.table<T>()` itself. Try it on
the plain one and it doesn't compile:

```text
error: 'Repo<Article>' has no method 'lock'
```

That's on purpose: `SELECT ... FOR UPDATE` run outside a transaction takes
its lock and releases it at the end of that one statement, protecting
nothing - the mistake is caught before your program runs, not after a
customer reports two conflicting edits both "succeeded."

## Claiming a row without waiting for it

`lock()` takes a `LockMode`. The default, `LockMode.Update`, is what
`approve` above used - it blocks until the row is free. Sometimes blocking
is the wrong answer: a deploy restarts every instance of a scheduled job at
once, and each one calls the same function at the same moment. Only one
should actually run it; the rest should back off immediately, not queue up
behind a lock that's about to be held for a while. `LockMode.SkipLocked`
does that - `find` simply fails, right away, if the row is already locked:

```bit
import { LockMode } from "orm"

@table class DigestRun {
  id: i64,
  runDate: string,
  status: string,
}

fn tryClaimDigest(db: Db, id: i64): bool! {
  let claimed = false
  db.tx((tx) => {
    let runs = tx.table<DigestRun>()
    let row = runs.lock(LockMode.SkipLocked).find(id) catch _ {
      return
    }
    row.status = "running"
    runs.update(row)?
    claimed = true
  })?
  return claimed
}
```

`LockedRepo<T>` (what `lock()` returns) only has `find(id)` - a locked read
is always "the one row I'm about to change," never an unbounded scan, so
there is no `all()` to reach for by mistake; you still need the row's id
from somewhere (a known constant here, a foreign key, an earlier unlocked
read elsewhere).

`LockMode.NoWait` behaves the same way as `SkipLocked` from the caller's
side - `find` fails instead of blocking - but tells you *why* through the
error rather than silently treating "locked" the same as "missing."

## The real use case: exactly-once on a deploy that restarts everything

```bit
fn runDigestOnce(db: Db, id: i64): ()! {
  if (tryClaimDigest(db, id)?) {
    // this instance won the claim - send the digest here
  }
  // every other instance's tryClaimDigest returned false, immediately
}
```

Every worker calls `runDigestOnce` with the same `id` within the same
window after a deploy. The first one to reach `lock()` gets `true` and
sends the digest; every other one gets `false` back in milliseconds
instead of blocking for however long the winner's transaction takes -
`SkipLocked` is what makes "false" come back fast rather than eventually.

## Sharp edge: a lock outlives the row it was taken for

If the transaction rolls back (the closure returns an error, or panics),
the lock releases and nothing was written - the next reader sees the row
exactly as it was, never a half-applied change. There is no explicit
"unlock": committing or failing the transaction is the only way a
`lock()`'d row's hold ends.

## When not to reach for this

A row two people might both edit, but rarely at the exact same moment,
often reads better with the optimistic `@version` check in
[Write](write.md) instead: no transaction held open while a user is
thinking, just a write that fails if someone else got there first. Reach
for `lock()` when the wait itself is correct - a queue worker, a balance
transfer, a batch job - not as the default for every update.

## Where to go next

[Query](query.md) covers the `where`/`orderBy`/`limit` chain `lock()`
builds on. [Write](write.md) covers `@version`, the optimistic alternative
to locking a row at all.
