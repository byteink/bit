# Patch

Every login updates one column: `lastSeenAt`. [Write](write.md)'s `save`
needs a whole `Person` in hand to do that - load the row, change one field,
write every column back. That is a wasted round trip for a single
timestamp, and it gets worse for a bulk job: "archive everyone inactive 90
days" has no single instance to hold at all. `update`/`deleteMany` write
columns directly, by a `where` clause, with nothing loaded first.

## The simplest patch

```bit
import { Data, update } from "orm"
import { AttrDesc, FieldDesc, Value } from "std/sql"

@table class Person {
  @id
  id: i64
  name: string
  email: string
  lastSeenAt: i64
}

fn personFields(): []FieldDesc {
  return Person{ id: 0, name: "", email: "", lastSeenAt: 0 }.tableDescriptor()
}

fn touchLastSeen(db: Data, id: i64, now: i64): int! {
  return update<Person>(db, "people", personFields()).where("id", Value.Int(id)).set(
    "lastSeenAt",
    Value.Int(now),
  ).run()?
}
```

`touchLastSeen` never reads a `Person` back - `update<Person>(...)` runs
`update people set last_seen_at = $2 where id = $1` directly, and `run()`
returns how many rows it matched: `1` for a real user, `0` for a stale id
that no longer exists, neither one an error. Compare that to `save`, where
`0` rows matched IS an error, because `save` holds an entity it believes is
real; `update` never held one to begin with.

## Growing the chain: more than one column, more than one row

```bit
fn deactivate(db: Data, id: i64): int! {
  return update<Person>(db, "people", personFields()).where("id", Value.Int(id)).set(
    "name",
    Value.Text("(deactivated)"),
  ).set("email", Value.Text("")).run()?
}

fn archiveInactive(db: Data, cutoff: i64): int! {
  return update<Person>(db, "people", personFields()).where("lastSeenAt", Value.Int(cutoff)).set(
    "name",
    Value.Text("(archived)"),
  ).run()?
}
```

Each `.set(...)` adds one column; `run()` writes only the columns you named,
never the rest of the row the way `save`'s UPDATE does. `where` is the one
predicate `update`/`deleteMany` both take: equality only, the exact
vocabulary [Query](query.md)'s own `where` uses, translated to a SQL column
the same way.

## The sharp edge: a bare `run()` is refused

```bit
fn wipeEveryone(db: Data): int! {
  return update<Person>(db, "people", personFields()).set("name", Value.Text("(wiped)")).run()?
}
```

```text
pkg/orm: update/delete on the class mapped to 'people' has no where() and no .all() - refusing to touch every row; call .all() before run() if a bulk write is intended
```

No `where` means every row in `people` - almost never what was meant, and
never something this package will do silently. Say so on purpose with
`.all()`:

```bit
fn resetEveryone(db: Data): int! {
  return update<Person>(db, "people", personFields()).all().set("lastSeenAt", Value.Int(0)).run()?
}
```

## Deleting more than one row

```bit
import { deleteMany } from "orm"

fn removeInactive(db: Data, cutoff: i64): int! {
  return deleteMany<Person>(db, "people", personFields()).where("lastSeenAt", Value.Int(cutoff)).run()?
}
```

`deleteMany`, not `delete` - [Write](write.md) already exports a `delete`
for the single, already-loaded entity, and a second function with the same
name in the same package would collide rather than overload. The same bare
`run()` refusal applies here too: `deleteMany<Person>(...).run()` with no
`where` and no `.all()` is refused before a statement reaches the driver,
for the same reason a bare `update` is.

## The sharper edge: a `@version` table with no version supplied

`update` never loads the row it is changing, so it has nothing to compare a
version against - unlike `save` (see [Optimistic locking](version.md) for
the automatic optimistic lock `save` carries on a `@version` table). On a
class that carries `@version`, `update` refuses to run unless the `where`
chain named
that field explicitly:

```bit
@table class Account {
  @id
  id: i64
  @version
  version: i64
  balanceCents: i64
}

fn setBalanceBlind(db: Data, id: i64, newCents: i64): int! {
  return update<Account>(
    db,
    "accounts",
    Account{ id: 0, version: 0, balanceCents: 0 }.tableDescriptor(),
  ).where("id", Value.Int(id)).set("balanceCents", Value.Int(newCents)).run()?
}
```

```text
pkg/orm: update on the class mapped to 'accounts' carries a @version field - supply it explicitly with where("<field>", ...) before run(), or use save() (#5059) for automatic optimistic locking
```

Naming the version in `where` is what "supplied explicitly" means here -
`update` does not read it off anywhere else, and it does not increment it
for you the way `save`'s own optimistic lock will. Reach for `save` instead
when the write needs to detect a lost update; reach for `update` when you
never needed the old row at all.

## The column check runs before your program does

Exactly [Query](query.md)'s own guarantee, extended to this file: a
string-literal column chained directly off `update<T>(...)` or
`deleteMany<T>(...)` is checked against `T`'s declared fields at compile
time.

```bit ignore
fn typo(db: Data, id: i64): int! {
  return update<Person>(db, "people", personFields()).where("id", Value.Int(id)).set("naem", Value.Text("x")).run()?
}
```

```text
error[E0163]: 'naem' is not a field of 'Person'
```

A column built from something other than a literal still compiles; the
runtime check `update`/`deleteMany` both run internally catches it one step
later, and panics naming the field and the table. Either way, no column
name reaches SQL text unless it named a real field first, and every value
in this file is a bound `$n` argument, never pasted into the SQL text.

## When not to use this

If you already have the instance - it came from a `find`, or you just
built it - use [Write](write.md)'s `save`. `update`/`deleteMany` exist for
the two cases where you don't: one column on a row you never loaded, or a
change that touches rows you never held individually at all.

## Where to go next

[Write](write.md) covers `save`, `delete` and `upsert` for when you hold
the instance. [Query](query.md) covers reading rows back and its own
compile-time column check, which this page extends.
