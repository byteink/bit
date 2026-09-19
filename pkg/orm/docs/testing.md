# Test against the database without leaving rows behind

Testing code that writes to a real database usually comes down to two bad
options. Point every test at its own throwaway database, and now every test
run needs a moving part to provision. Or run tests against one shared
database and clean up by hand afterward - and the one `DELETE` you forget to
add is a test that passes alone and fails only once another test happens to
run before it. `withRollback` is a third option: run the test's body inside a
real transaction, and never let that transaction commit. Whatever it wrote
is visible to the body itself, and gone the moment the call returns.

## The simplest thing that works

```bit
import { Data, Seq, create, make, withRollback } from "orm"
import { Pool, Value } from "std/sql"

class User {
  email: string,
  name: string,
}

fn userSeed(n: i64): User {
  return User{ email = "user${n}@example.test", name = "User ${n}" }
}

fn insertOneUser(pool: Pool, seq: Seq): ()! {
  withRollback(pool, (db) => {
    let u = make<User>(seq, userSeed)
    db.exec(
      "insert into users (email, name) values ($1, $2)",
      [Value.Text(u.email), Value.Text(u.name)],
    )?
  })?
}
```

`insertOneUser(pool, Seq{})` inserts one row, exactly as `pool.tx((db) => {
... })` would, then rolls back instead of committing. Once the call returns,
nothing it wrote is in `users` - there is nothing left to delete before the
next test runs.

`make<User>(seq, userSeed)` never touches the database on its own; it just
returns a `User` built from `seq`'s next value. `make`/`create` do not fill
`userSeed`'s fields for you the way `orm.make<User>(email = "a@b.c")` might
suggest - a function generic over an unconstrained `T` cannot build a `T{
field = value }` composite literal, because the compiler has to know `T`'s
field names to check one, and an unconstrained type parameter carries none
(the same E0057 gap [Write](write.md)'s own header documents). `userSeed` is
that one place your entity's shape is spelled out, written once per entity,
the same way `savePerson`'s `personValues` is for `save`.

## Growing it: proving the first test left nothing behind for the second

```bit
fn countUsers(db: Data, email: string): int! {
  let rows = db.query("select email from users where email = $1", [Value.Text(email)])?
  let n = 0
  while (rows.next()?) {
    n = n + 1
  }
  rows.close()
  return n
}

fn firstTest(pool: Pool, seq: Seq): int! {
  let seen = 0
  withRollback(pool, (db) => {
    let u = make<User>(seq, userSeed)
    db.exec(
      "insert into users (email, name) values ($1, $2)",
      [Value.Text(u.email), Value.Text(u.name)],
    )?
    seen = countUsers(db, u.email)?
  })?
  return seen
}

fn secondTest(pool: Pool): int! {
  let seen = 0
  withRollback(pool, (db) => {
    seen = countUsers(db, "user1@example.test")?
  })?
  return seen
}
```

Call `firstTest(pool, Seq{})` against a `pool` connected to a database with
an empty `users` table: it returns `1` - the row it just inserted is visible
to a query inside the *same* transaction, before `withRollback` ends it.
Call `secondTest(pool)` right after, against that same `pool`: it returns
`0`. Nothing from `firstTest` survived - not because the two ran against
different databases, but because `withRollback` never let the first
transaction commit in the first place.

## `make` builds a value; `create` builds and saves one

Reach for `create` instead of `make` when the test needs the row to actually
exist for something later in the same body to find - a query, a relation, a
foreign key another insert points at:

```bit
fn createUser(db: Data, seq: Seq): User! {
  return create<User>(seq, userSeed, (u) => {
    db.exec(
      "insert into users (email, name) values ($1, $2)",
      [Value.Text(u.email), Value.Text(u.name)],
    )?
    return u
  })?
}
```

`create<User>(seq, userSeed, persist)` is `make<User>(seq, userSeed)`, then
`persist` on the result - here, the same `db.exec` call `insertOneUser`
already made, wrapped in a closure. `make` alone never inserts; `create` is
the one of the two that does.

## Why `withRollback` always rolls back, even when the body succeeds

[`pool.tx`](data.md) commits the moment its block returns normally, and has
no rollback-only mode - correct for `pool.tx`, which exists to make a write
durable. `withRollback` needs the opposite guarantee, so it never lets the
block return normally at all. When the body succeeds, `withRollback` ends
the `pool.tx` block by failing it with an error private to this file, used
for exactly one purpose - forcing `pool.tx` onto its rollback path - and
swallowed before it ever reaches you. When the body itself fails,
`withRollback` still rolls back, and your exact error reaches you unchanged,
so checking a specific error type (`e.(SomeError)`) works the same inside
`withRollback` as outside it. There is no "commit anyway" switch to flip: if
you find yourself wanting one, `pool.tx` is the function you actually want.

## The mistake `withRollback` cannot catch for you

`withRollback`'s closure parameter is `db`, never `pool` - the same rule
[Data](data.md#the-closure-parameter-shadows-the-outer-handle) states for
`pool.tx`, and for the same reason. Nothing stops you from reaching for the
outer `pool` inside the block instead of the `db` you were handed:

```bit
// Wrong: pool.exec opens its own connection outside the transaction
// withRollback is about to roll back, so this write is never undone.
fn leaksARow(pool: Pool, seq: Seq): ()! {
  withRollback(pool, (db) => {
    let u = make<User>(seq, userSeed)
    pool.exec(
      "insert into users (email, name) values ($1, $2)",
      [Value.Text(u.email), Value.Text(u.name)],
    )?
  })?
}

// Right: db.exec runs inside the transaction withRollback is about to
// roll back, so nothing it wrote survives the call.
fn leaksNothing(pool: Pool, seq: Seq): ()! {
  withRollback(pool, (db) => {
    let u = make<User>(seq, userSeed)
    db.exec(
      "insert into users (email, name) values ($1, $2)",
      [Value.Text(u.email), Value.Text(u.name)],
    )?
  })?
}
```

`leaksARow` commits at once through `pool` and `withRollback` never sees the
write, so it is never rolled back - run it in a suite and it leaves a row in
`users` permanently. The type checker cannot catch this for you: `pool` and
`db` are both just a `Data`-shaped handle with `query`/`exec`, so a call
through either one typechecks identically. Name the closure parameter `db`,
and never write `pool` inside the block.

## `Seq` is per-test, and never random

A fresh `Seq{}`, one per test, is what makes `make`/`create`'s output
deterministic and reproducible: `firstTest`'s `Seq{}` above always produces
`user1@example.test` first, regardless of what any other test did before it
in the same run. An ambient, package-level counter was never on the table -
it would make one test's factory output depend on what happened to run
before it in the same process. A random factory is worse: it produces a
suite that fails once a month, on data nothing wrote down, and cannot be
re-run to reproduce the failure. `Seq{}` per test is what makes "run this
test again" mean something.

## When not to use this

`withRollback` is for tests, not for request handling or a background job -
every write inside it is thrown away on purpose, which is exactly wrong for
code that needs its writes to survive. Use [`pool.tx`](data.md) for that.
`make`/`create` are for building an entity's fields inside a test; they do
not replace [`save`](write.md) as the real insert/update decision your
application code makes outside a test.

## Where to go next

[Data](data.md) covers `Data`, `Pool.tx` and why the closure parameter rule
this page repeats exists in the first place. [Write](write.md) covers
`save`, the real insert-or-update `create`'s `persist` closure usually calls.
