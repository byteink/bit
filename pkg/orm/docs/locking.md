# Lock rows so two workers can't grab the same one

A `jobs` table holds pending work, and two worker processes both poll it:
`find<Job>(db, "jobs", fields, jobMapper).where("state", Value.Text("pending")).limit(1).one()`.
Nothing about a plain `SELECT` holds the row it read for the caller that read
it - if both workers run that query in the same instant, both get job 42
back. Both start processing it. Whichever one writes its result back last
wins, silently; the other one did the same work for nothing, or worse, wrote
an outcome that assumed nothing else had touched the row since. `forUpdate`
is what turns "read a row" into "read a row and hold it until you decide
what happens to it."

## The simplest thing that works: FOR UPDATE blocks

```bit
import {
  Data,
  LockCause,
  LockDialect,
  LockError,
  LockOpts,
  LockedQuery,
  MysqlVersion,
  Query,
  find,
  forUpdate,
} from "orm"
import { AttrDesc, FieldDesc, Pool, Rows, Value, sqlReqInt, sqlReqText } from "std/sql"

@table class Job {
  id: i64,
  state: string,
}

fn jobMapper(rows: Rows): Job! {
  let cols = rows.columns()
  return Job{ id: sqlReqInt(rows, cols, "id")?, state: sqlReqText(rows, cols, "state")? }
}

fn pendingJobs(db: Data): Query<Job> {
  let fields = Job{ id: 0, state: "" }.tableDescriptor()
  return find<Job>(db, "jobs", fields, jobMapper).where("state", Value.Text("pending"))
}

fn claimOneJob(db: Data): Option<Job>! {
  let job = pendingJobs(db).limit(1).forUpdate(LockOpts{}, LockDialect.Neutral).one()?
  match (job) {
    Some(j) => {
      db.exec(
        "update jobs set state = $1 where id = $2",
        [Value.Text("processing"), Value.Int(j.id)],
      )?
      return Option.Some(j)
    }
    None => return Option.None
  }
}

fn runClaimOneJob(p: Pool): Option<Job>! {
  return p.txValue<Option<Job>>((db) => {
    return claimOneJob(db)?
  })?
}
```

`Query<T>.forUpdate(opts, dialect)` continues the chain you're already
building with `find`/`where`/`limit` - `pendingJobs(db).limit(1)` above -
and returns a `LockedQuery<T>` whose terminals (`all`/`one`/`oneOrFail`)
run the same SQL with a lock clause appended. `dialect` is required and
explicit - see "SKIP LOCKED and NOWAIT need MySQL 8.0" below for what it is
for. `LockOpts{}` is plain `FOR UPDATE`: it **blocks** until whichever
transaction currently holds the row commits or rolls back. Two workers both
calling `claimOneJob` at once do not both get job 42 - the second one's
`forUpdate(...).one()` simply waits its turn.

The free function `forUpdate<T>(q, opts, dialect)` (`pkg/orm/lock.bit`)
does the identical work - `.forUpdate(opts, dialect)` is one line
delegating straight into it, the same way `Pool.txValue<T>` delegates into
its own free-function twin. Reach for the free function when you already
hold a built `Query<T>` value - passed in as a parameter, or returned by
another function - rather than writing the chain inline: `claimUpTo` below
wraps `pendingJobs(db).limit(n)` with the free function for exactly that
reason.

Holding the lock is not the same as claiming the job. `claimOneJob` also
writes `state = 'processing'` before it commits, inside the same
transaction the lock is held in (`runClaimOneJob`'s `p.txValue`) - that
write is what stops the second worker from matching the row again once its
own `SELECT ... FOR UPDATE` finally runs. `forUpdate` alone, with nothing
written back before commit, only delays the second worker; it does not
prevent it from claiming the same row a moment later.

## Never block: SKIP LOCKED for a queue

A worker that wants to claim several jobs at once does not want to sit
behind whatever another worker is already holding - it wants everything
free, right now:

```bit
fn claimUpTo(db: Data, n: int): LockedQuery<Job> {
  return forUpdate<Job>(pendingJobs(db).limit(n), LockOpts{ skipLocked: true }, LockDialect.Neutral)
}

fn claimBatch(db: Data, n: int): []Job! {
  let jobs = claimUpTo(db, n).all()?
  for j of jobs {
    db.exec(
      "update jobs set state = $1 where id = $2",
      [Value.Text("processing"), Value.Int(j.id)],
    )?
  }
  return jobs
}

fn runClaimBatch(p: Pool, n: int): []Job! {
  return p.txValue<[]Job>((db) => {
    return claimBatch(db, n)?
  })?
}
```

`LockOpts{ skipLocked: true }` **never blocks**. It quietly leaves out any
row another transaction already has locked and returns the rest
immediately. Call `runClaimBatch(p, 10)` while other workers together hold
seven of the ten matching rows, and it returns three `Job` records - not
ten, and not an error. That is correct, not a bug: `SKIP LOCKED` answers
"give me whatever is free right now," and three free rows is a true answer
to that question. A worker's poll loop calls `runClaimBatch(p, 10)` on a
timer and processes however many jobs come back, including zero.

That same behavior is exactly wrong for code that needs to see every
matching row - a report counting pending jobs, say. `SKIP LOCKED` would
make it silently undercount, omitting whatever another transaction happens
to be holding at that instant with no indication anything was left out.
Reach for `LockOpts{}` (blocks) or no lock at all when you need every row;
reach for `skipLocked: true` only when "whatever is currently free" is the
right answer to your question, the way it is for a queue worker claiming
work.

## The sharp edges

### Refused outside a transaction

```bit
fn claimOneJobFromPool(p: Pool): Option<Job>! {
  return claimOneJob(p) catch e {
    let (le, ok) = e.(LockError)
    if (ok && le.cause == LockCause.NotInTransaction) {
      fail newError("claimOneJob must run inside p.tx(...) or p.txValue<T>(...), never called with the pool directly")
    }
    fail e
  }
}
```

`claimOneJob(p)` above - `p` a `Pool`, not a `Tx` - fails before any SQL
reaches the driver:

```text
pkg/orm: forUpdate requires a live transaction (Tx), not a Pool - SELECT ... FOR UPDATE issued on a Pool takes the lock and releases it at the end of that one statement, protecting nothing; wrap the call in db.tx((db) => { ... })
```

The reason is not a rule for its own sake. `SELECT ... FOR UPDATE` issued
straight against a `Pool` takes its lock and releases it again at the end
of that one statement - the query still returns the right row, so it looks
like it worked. Two workers doing exactly that at the same moment both
"win" the same job, and nothing about the value either of them gets back
says so. `forUpdate` checks this before building any SQL at all: the
`LockError` above carries `cause: LockCause.NotInTransaction`, and zero
statements are sent to the database, so there is nothing to undo.

### count() and exists() refuse

```bit
fn pendingCountLocked(db: Data): i64! {
  return forUpdate<Job>(pendingJobs(db), LockOpts{}, LockDialect.Neutral).count()?
}

fn pendingCount(db: Data): i64! {
  return pendingJobs(db).count()?
}
```

`pendingCountLocked` always fails:

```text
pkg/orm: forUpdate cannot be combined with 'count()' - a row lock is meaningless without a row to lock
```

`exists()` refuses the same way, naming itself instead of `count()`. A row
lock has nothing to hold when the result is a number or a boolean, not a
row - there is no row identity to keep another transaction away from.
Count or check existence on the plain, unlocked query instead, the way
`pendingCount` above does; reach for `forUpdate` only on the terminals that
actually return rows (`all`/`one`/`oneOrFail`).

`LockOpts{ skipLocked: true, nowait: true }` together are refused too
(`LockCause.ConflictingOptions`) - `skipLocked` returns fewer rows without
waiting, `nowait` fails immediately instead of waiting, and a caller has to
pick one answer to "what happens when the row is already locked," not both.

### SKIP LOCKED and NOWAIT need MySQL 8.0

Nothing reaching `Data` carries a server version today (#5384), so
`forUpdate`'s third argument, `dialect: LockDialect`, is how you supply it -
`LockDialect.Neutral` for Postgres or MySQL 8+ (every example above uses
this; `lockClause` alone is already correct for both), `LockDialect.
Mysql(version)` for anything targeting MySQL. `LockedQuery`'s own `guard()`
checks `version` before building any SQL, the same "zero statements issued
on a refusal" guarantee the transaction check above gives:

```bit
fn claimBatchOnMysql(db: Data, n: int, version: MysqlVersion): []Job! {
  let jobs = forUpdate<Job>(
    pendingJobs(db).limit(n),
    LockOpts{ skipLocked: true },
    LockDialect.Mysql(version),
  ).all()?
  for j of jobs {
    db.exec(
      "update jobs set state = $1 where id = $2",
      [Value.Text("processing"), Value.Int(j.id)],
    )?
  }
  return jobs
}
```

Called with `MysqlVersion{ major: 5, minor: 7 }`, this fails before any SQL
reaches the driver:

```text
pkg/orm: MySQL 5.7 does not support FOR UPDATE SKIP LOCKED (added in MySQL 8.0); omit skipLocked or upgrade the server
```

Pass `LockDialect.Neutral` against a MySQL server older than 8.0 instead of
`Mysql(version)`, and the failure comes back from the driver - a SQL syntax
error, not this typed `LockError`: `Neutral` means "render the
dialect-neutral clause unconditionally," never "this is Postgres." Postgres
should always pass `Neutral` - it has no version gate to check.

## When not to use this

Not for a query that has to see every matching row - a report, an
export, anything counting or listing without intending to change what it
reads. `skipLocked: true` is silently wrong there: it would leave out rows
another transaction is holding with no sign anything was skipped. Use a
plain, unlocked `Query<T>` for those, or `LockOpts{}` if you genuinely need
to block until the data is stable.

Not for `count()`/`exists()` - they refuse outright; see "The sharp edges"
above for what to call instead.

Not outside a transaction. `forUpdate` refuses rather than running a
statement that would look like it worked while protecting nothing - see
"Refused outside a transaction" above.

## Where to go next

[Query](query.md) covers the `find`/`where`/`limit` chain `forUpdate` wraps.
[Data](data.md) covers `Pool.tx`/`Pool.txValue<T>` and why the closure
parameter should shadow the outer handle. [MySQL](mysql.md) covers the
other places Postgres and MySQL diverge, including the version gate
`LockDialect.Mysql(version)` closes here.
