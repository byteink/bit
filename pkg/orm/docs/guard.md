# Guarding rows with an authorization layer

An Inkwell author should see their own drafts and nobody else's. Writing
`where("authorId", me)` on every query works until the one query that
forgets it. The ORM can hold a *guard* instead: one object, given once at
`open`, that the ORM consults for every table the guard protects.

The ORM does not decide who may do what. It declares what it needs from a
guard, and any class with those methods is one - the authorization package
plugs in here, and this package never imports it (the authorization package
stores its rules through this one, so an import in this direction would be
a cycle).

## The smallest guard

```bit
import { Actor, Guard, GuardFilter, GuardOp, Options, ServerDialect, open } from "orm"
import { Value } from "std/sql"

class OwnDrafts {
  export protects(table: string): bool {
    return table == "draft"
  }

  // The ORM appends this fragment to its own WHERE clause; `firstParam` is
  // the number its next placeholder must carry on Postgres.
  export filter(
    actor: Actor,
    op: GuardOp,
    table: string,
    dialect: ServerDialect,
    firstParam: int,
  ): GuardFilter! {
    return GuardFilter.Sql("author_id = $${firstParam}", [Value.Text(actor.id)])
  }

  export allows(
    actor: Actor,
    op: GuardOp,
    table: string,
    columns: []string,
    values: []Value,
  ): bool! {
    let i = 0
    while (i < len(columns)) {
      if (columns[i] == "authorId") {
        match (values[i]) {
          Int(id) => return "${id}" == actor.id
          Null => return false
          Float(_) => return false
          Bool(_) => return false
          Text(_) => return false
          Blob(_) => return false
        }
      }
      i = i + 1
    }
    return false
  }

  export columnsInRules(actor: Actor, op: GuardOp, table: string): []string! {
    return ["authorId"]
  }

  export denied(actor: Actor, op: GuardOp, table: string): error {
    return newError("not allowed to change ${table}")
  }

  export notFound(table: string): error {
    return newError("${table}: not found")
  }

  export check(): ()! {
    return
  }
}

fn main(): ()! {
  let guard: Guard = OwnDrafts{}
  let db = open("postgres://localhost/inkwell", Options{ authz = guard })?
  let drafts = db.as(Author{ id = "7" }).table<Draft>()
  let draft = drafts.insert(Draft{ id = 0, authorId = 7, body = "First outline" })?
  print(draft.body)
}

class Author { export id: string }

@table class DraftTag { id: i64 }

@table @softDelete class Draft {
  id: i64
  authorId: i64
  body: string
  deletedAt: Option<i64> = Option<i64>.None
  @manyToMany("draft_tags")
  tags: []DraftTag
}
```

`Options{ authz = guard }` is the only way to pass a guard. The
`Options` field defaults to no guard, so `open(url)` and
`Options{ synchronize = true }` behave exactly as before.

## What each method is for

- `protects(table)` says whether the guard cares about a table. A table it
  does not protect is never filtered.
- `filter(actor, op, table, dialect, firstParam)` returns a `GuardFilter`:
  `All` (no restriction), `None` (the actor may see no rows) or
  `Sql(fragment, args)`, a WHERE condition already numbered from
  `firstParam` with its arguments in order. `op` is a `GuardOp`: `Read`,
  `Create`, `Update` or `Delete`.
- `columnsInRules(actor, op, table)` lists all model field names read by the
  actor's applicable allow and deny rules, before simplification. Return each
  name once. Rule introspection errors must fail closed.
- `allows(actor, op, table, columns, values)` judges the column values of
  one create or update.
- `denied(actor, op, table)` and `notFound(table)` build the errors the
  ORM returns, so the guard chooses how a refusal reads - and may answer
  "not found" for a row the actor is not allowed to know exists.
- `check()` runs once, inside `open`, before any connection is made. If the
  guard cannot serve this ORM - a rule with an operation it does not
  understand, a store it cannot read - `open` returns that error, so the
  mistake surfaces at startup and not on the first request.

An `Actor` is any value with an `id: string` field. The guard receives it
as that narrow type and recovers the full subject with a type assertion.

## What the Db does with it

`open` keeps the guard on the `Db`, and every repository from
`db.table<T>()` and every handle from `db.tx(...)` carries it, including
through chain methods such as `where`. Opening without a guard changes
nothing.

## Three handles, and the one that fails

With a guard on the `Db`, every table it protects needs to say who is asking.
`Draft` (above) is protected by `OwnDrafts`, so a plain `db.table<Draft>()` is a
mistake in the program and the ORM says so loudly:

```bit
import { Actor, Db, Guard, Options, ScopedDb, ScopedRepo, SystemDb, Unscoped, open } from "orm"
import { Logger } from "std/log"

fn openGuarded(url: string, guard: Guard, logger: Logger): Db! {
  return open(url, Options{ authz = guard, logger = logger })?
}

fn forRequest(db: Db, who: Actor): ScopedDb {
  return db.as(who, "inkwell")
}

fn forGuest(db: Db): ScopedDb {
  return db.asGuest()
}

fn myDrafts(scoped: ScopedDb): ScopedRepo<Draft> {
  return scoped.table<Draft>()
}

fn forNightlyJob(db: Db): SystemDb {
  return db.asSystem()
}

fn forgotToScope(db: Db): ()! {
  db.table<Draft>().all() catch e {
    let (u, ok) = e.(Unscoped)
    if (ok) {
      print("refused: ${u.message()} (status ${u.status()})")
    }
  }
}
```

- `db.as(subject)` is for one request. `subject` is any class with an `id`;
  the optional second argument names a tenant. It returns a `ScopedDb`, and
  `table<T>()` on that returns a `ScopedRepo<T>`, the repository that holds
  the actor and the guard. `as` is a reserved word; after a `.` it is an
  ordinary method name.
- `db.asGuest()` is the same with no subject. A guest is still checked: it is
  an actor with no id, not an unchecked one.
- `db.asSystem()` is for jobs and migrations. It returns a `SystemDb` whose
  `table<T>()` is the plain, unguarded repository, so existing job code keeps
  its API. Each `table<T>()` writes one debug record, `msg="system access"
  table=<table>`, to `Options.logger` (std/log's default logger when unset), so
  system access can be audited once the logger's level admits debug; see
  [Logging](logging.md).
- A plain `db.table<T>()` (and `tx.table<T>()`) on a protected table returns a
  repository whose every terminal call (`find`, `all`, `insert`, `update`,
  `delete` and the rest) fails with `Unscoped`. Its message names the table
  and never a value the caller passed. Its status is 500, so a web handler
  that returns it reports a server fault and never leaks it to the client as
  a client error. Tables the guard does not protect, and a `Db` opened with
  no guard, are unchanged.

## Reading through a ScopedRepo

A `ScopedRepo<T>` has the same read chain as `Repo<T>`: `where`, `orderBy`,
`limit`, `offset`, `after`, `withDeleted`, and the terminal calls `all`,
`first`, `count` and `find`, with the same names and the same arguments. There
is no second API to learn. What changes is that each terminal call first asks
the guard `filter(actor, GuardOp.Read, table, dialect, firstParam)` and adds
the answer to the statement:

```bit
import { Dir, ScopedRepo } from "orm"

// SELECT * FROM draft WHERE body = $1 AND (author_id = $2)
// ORDER BY id DESC LIMIT 10 OFFSET 20
fn page(mine: ScopedRepo<Draft>): []Draft! {
  return mine.where("body", "outline").orderBy("id", Dir.Desc).limit(10).offset(20).all()?
}

fn nextPage(mine: ScopedRepo<Draft>, lastId: i64): []Draft! {
  return mine.orderBy("id").after(lastId).limit(10).all()?
}

fn oldestDraft(mine: ScopedRepo<Draft>): Option<Draft>! {
  return mine.orderBy("id").first()?
}

fn howMany(mine: ScopedRepo<Draft>): int! {
  return mine.count()?
}

fn trashAndAll(mine: ScopedRepo<Draft>): []Draft! {
  return mine.withDeleted().all()?
}

fn openDraft(mine: ScopedRepo<Draft>, id: i64): Draft! {
  return mine.find(id)?
}
```

- `firstParam` is the number after the last placeholder the chain already
  used (`len(args) + 1`), so a fragment numbered from it slots in after
  `where` and `after`. The fragment goes in parentheses and is ANDed with the
  chain's own conditions and with the soft-delete condition, so an `or` inside
  a rule cannot widen them.
- Write the fragment with `$n` placeholders on MySQL as well. The MySQL
  adapter turns every `$n` of the statement into `?`, and it counts
  parameters from the `$n` it finds; a bare `?` makes the statement fail
  with a parameter-count error, never run unfiltered.
- `GuardFilter.All` adds nothing. `GuardFilter.None` answers without running
  any SQL: `all` returns `[]`, `first` returns `None`, `count` returns `0`.
- A guard error (a rule it cannot turn into SQL, a store it cannot read) is
  returned as it is. A read is never run unfiltered because the filter
  failed.
- A table the guard does not `protects` is not filtered, and a guest is asked
  with an actor whose `id` is empty.

`find(id)` is `where(key, id)` plus the filter plus `limit 2`. When no row
comes back, it fails with the guard's `notFound(table)`. A row the actor may
not read and a row that does not exist give the same answer, so the error
never tells a caller that a draft exists. Make `notFound` a 404 and never a
403; `denied` is for writes.

## Creating through a ScopedRepo

`insert` and `insertAll` have the same signatures as on `Repo<T>`. Before any
SQL, the ORM asks the guard
`allows(actor, GuardOp.Create, table, columns, values)` about the new row:

```bit
import { ScopedRepo } from "orm"

fn startDraft(mine: ScopedRepo<Draft>, who: i64, body: string): Draft! {
  return mine.insert(Draft{ id = 0, authorId = who, body = body })?
}

fn startMany(mine: ScopedRepo<Draft>, who: i64, bodies: []string): []Draft! {
  let rows = []Draft(0)
  for body of bodies {
    rows = append(rows, Draft{ id = 0, authorId = who, body = body })
  }
  return mine.insertAll(rows)?
}
```

- `columns` are the field names of the row's columns (relation fields
  are not columns), in the order of `values`. For `Draft` that is `id`,
  `authorId`, `body`.
- The guard sees the row as the caller built it. A database-generated id is
  still `0` at this point and `@timestamps` columns are not yet filled, so a
  create rule over `id` or a timestamp cannot work; write it over the fields
  the caller sets, such as `authorId`.
- When `allows` returns `false`, the call fails with
  `guard.denied(actor, GuardOp.Create, table)` and nothing is written. Make
  `denied` a 403: the caller named a row they may not make.
- When `allows` fails (a store it cannot read), that error is returned
  unchanged. A write is never run because the check could not be made.
- `insertAll` asks about every row before the first statement, so one
  refused row rejects the whole batch. No transaction is opened, so none is
  left behind.
- The row comes back as `Repo<T>.insert` returns it, read back with no read
  filter. Someone who may create a draft but not read it still gets their
  row back from the call that made it.
- A table the guard does not `protects` is not asked, and a `ScopedRepo`
  with no guard inserts like a plain `Repo<T>`.

## Editing and removing your drafts

Inkwell must let you edit a draft without letting you hand it to another
author. `update` checks the proposed values first, then limits the write to
rows your guard allows you to update. `delete` applies the delete rule in
the same way.

Continue with the `Draft` and guard above:

```bit
import { ScopedRepo } from "orm"

fn revise(mine: ScopedRepo<Draft>, id: i64, body: string): Draft! {
  let draft = mine.find(id)?
  draft.body = body
  mine.update(draft)?
  return draft
}

fn saveOutline(mine: ScopedRepo<Draft>, authorId: i64, body: string): Draft! {
  let draft = mine.save(Draft{ id = 0, authorId = authorId, body = body })?
  draft.body = "Reviewed: " + draft.body
  return mine.save(draft)?
}

fn discard(mine: ScopedRepo<Draft>, id: i64): ()! {
  mine.delete(id)?
}

fn undoDiscard(mine: ScopedRepo<Draft>, id: i64): ()! {
  mine.restore(id)?
}

fn erasePermanently(mine: ScopedRepo<Draft>, id: i64): ()! {
  mine.forceDelete(id)?
}
```

`save` chooses the create checks when the key is zero and the update checks
when the key is set. An inserted row comes back with its generated values;
an updated row comes back as the value you supplied.

Because this `Draft` uses `@softDelete`, `delete` hides it from ordinary
reads. `restore` checks the update rule and clears `deletedAt`;
`forceDelete` checks the delete rule and permanently removes it. These two
operations can address a deleted row without requiring `withDeleted()`.
Use `withDeleted()` when you want to list the drafts in the trash.

The same `allows` method that checked creates receives `GuardOp.Update`
and the complete proposed values for `update` and the update branch of
`save`. In this guard, changing `authorId` to another author's id is refused
before any SQL runs. `restore` only clears the deletion marker; it asks for
the update filter without a caller-supplied row to pass to `allows`.

When the guarded statement changes no rows, the ORM checks whether you can
read the row. If you cannot, it returns your guard's `notFound` error. If
you can, it returns your guard's `denied` error for that write operation.
Give those errors statuses 404 and 403 respectively. A readable row whose
version no longer matches is also denied. The write and this visibility
check share one transaction; there is no separate permission check followed
by an unrestricted write.

`GuardFilter.None` skips the write and makes the same visibility check.
An error from either guard check is returned unchanged. No failed check
falls back to an unrestricted statement. A guard that does not protect a
table, or a repository with no guard, keeps the plain repository's behavior.

Use `db.asSystem()` for a trusted maintenance job that must bypass these
rules. Request handlers should keep using the actor's scoped handle.

## Revising a group of drafts

To replace a shared outline without touching another author's drafts, narrow
that batch and assign the new value:

```bit
fn reviseOutlines(mine: ScopedRepo<Draft>): int! {
  return mine.where("body", "outline").set("body", "Revised outline").updateAll()?
}
```

`set` returns a new scoped chain. `updateAll` appends the actor's `Update`
filter to your condition and returns the number of rows actually changed.
A bare call without `where()` fails before consulting the guard. `None`
returns zero without SQL, and a policy error fails without running a write.
The original chain keeps its predicates and assigned values.

A bulk operation cannot check the new values row by row. It therefore
refuses any assigned field named by the actor's `Update` **or** `Delete`
rules. For the guard above, changing `body` is allowed but changing
`authorId` is refused, even when the proposed value looks unchanged. Rule
introspection errors also fail closed. The automatic `updatedAt` assignment
on a timestamped model follows the same restriction. Use a guarded single-row
`update` when the change needs a value check.

## Removing a group of drafts

To discard every outline you may delete, narrow the batch explicitly:

```bit
fn discardOutlines(mine: ScopedRepo<Draft>): int! {
  return mine.where("body", "outline").deleteAll()?
}
```

`deleteAll` asks for `GuardOp.Delete`, ANDs its parenthesized filter with
that caller condition, and returns the affected-row count. On `Draft`, it
sets `deletedAt` instead of removing rows. Ordinary reads exclude those
rows; `withDeleted()` includes them.

A caller must supply `where()` even when the guard would add a condition.
A bare call fails before the guard runs, including with `All` or `None`.
For a narrowed chain, `None` returns zero without SQL; a guard error returns
unchanged without SQL. `All`, an unprotected table, or no guard retains the
plain bulk-delete behavior. The call leaves the source chain unchanged.

## Changing a draft's tags

Adding or removing a relation requires permission to update its owner. Keep using the
author's scoped repository, even when the caller already has the draft:

```bit
fn addTag(mine: ScopedRepo<Draft>, draft: Draft, tagId: i64): ()! {
  mine.link(draft, "tags", [tagId])?
}

fn removeTag(mine: ScopedRepo<Draft>, draft: Draft, tagId: i64): ()! {
  mine.unlink(draft, "tags", [tagId])?
}

fn addTagInTransaction(tx: ScopedTx, draft: Draft, tagId: i64): ()! {
  tx.table<Draft>().link(draft, "tags", [tagId])?
}

fn removeTagInTransaction(tx: ScopedTx, draft: Draft, tagId: i64): ()! {
  tx.table<Draft>().unlink(draft, "tags", [tagId])?
}
```

`link` and `unlink` read the owner's key from `draft`, then lock the stored owner
through its `Update` filter before writing the selected relation pairs.
The lock and relation write share one transaction. `link` inserts only missing
pairs, so repeating the same call is safe; `unlink` deletes the requested pairs. Fields on the supplied draft
cannot grant permission. The chain's conditions and soft-delete condition
still narrow the owner lookup. An unreadable owner returns `notFound`;
a readable owner refused by the update rule returns `denied`. A guard error
leaves the relation unchanged. Empty target ids change no pairs.

The same call on `ScopedTxRepo` uses the caller's transaction. No guard or
an unprotected owner table keeps the plain repository's behavior.

## Editing together in one scoped transaction

An edit may need to lock a draft before changing it. Start the transaction
on the request's scoped handle so every repository inside it keeps the same
author, tenant and guard:

```bit
import { Db, LockMode, ScopedLockedRepo, ScopedTx, ScopedTxRepo } from "orm"

fn editInTransaction(tx: ScopedTx, id: i64, body: string): ()! {
  let drafts: ScopedTxRepo<Draft> = tx.table<Draft>()
  let locked: ScopedLockedRepo<Draft> = drafts.lock(LockMode.Update)
  let draft = locked.find(id)?
  draft.body = body
  drafts.update(draft)?
}

fn editDraft(db: Db, author: Author, id: i64, body: string): ()! {
  db.as(author, "inkwell").tx((tx) => {
    editInTransaction(tx, id, body)?
  })?
}
```

`ScopedDb.tx` commits when its closure returns normally and rolls back on
a failure or panic. Let a denial propagate with `?` to roll back earlier
allowed writes in the same closure. Catching a denial inside the closure
and returning normally still commits its earlier work, as with `Db.tx`.

`ScopedTx.table<T>()` returns a `ScopedTxRepo<T>`. It forwards the scoped
read and write methods and keeps its transaction type through `where`,
`orderBy`, `limit`, `offset`, `after` and `withDeleted`. Only this
transaction repository offers `lock`; a pool-backed `ScopedRepo` does not.
`lock` returns a `ScopedLockedRepo<T>` whose `find` applies the read filter,
the chain's conditions and the soft-delete condition before locking. An
unreadable row returns the guard's `notFound` error. The existing dialect
rules for `LockMode.SkipLocked` and `LockMode.NoWait` still apply.

Neither `ScopedDb` nor `ScopedTx` offers `exec` or `query`: raw SQL cannot
be checked against row rules. Trusted raw SQL still uses `Db` or
`TxHandle`; keep those handles outside request helpers that need the guard.

Where to go next: [Querying](query.md) for the chain a guard narrows, and
[Raw SQL and transactions](raw.md) for the handles that carry it.
