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
    return true
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
  let drafts = db.table<Draft>()
}

@table class Draft {
  id: i64,
  authorId: i64,
  body: string,
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
import { Actor, Db, Guard, Logger, Options, ScopedDb, ScopedRepo, SystemDb, Unscoped, open } from "orm"

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
  its API. When `Options.logger` is set, each `table<T>()` writes one debug
  line, `orm: system access to <table>`, so system access can be audited.
- A plain `db.table<T>()` (and `tx.table<T>()`) on a protected table returns a
  repository whose every terminal call (`find`, `all`, `insert`, `update`,
  `delete` and the rest) fails with `Unscoped`. Its message names the table
  and never a value the caller passed. Its status is 500, so a web handler
  that returns it reports a server fault and never leaks it to the client as
  a client error. Tables the guard does not protect, and a `Db` opened with
  no guard, are unchanged.

Where to go next: [Querying](query.md) for the chain a guard narrows, and
[Raw SQL and transactions](raw.md) for the handles that carry it.
