# Data

`Data` is what every function in this package that reads or writes takes
instead of `Pool` directly: the interface `Pool` and a live transaction both
satisfy, so one function runs standalone or inside a caller's transaction
with no second version and no second entry point.

```bit
import { Data } from "orm"
import { Value } from "std/sql"

fn transfer(db: Data, fromId: i64, toId: i64, amt: i64): ()! {
  db.exec("update accounts set balance = balance - ${amt} where id = ${fromId}", []Value(0))?
  db.exec("update accounts set balance = balance + ${amt} where id = ${toId}", []Value(0))?
}
```

Call it either way:

```bit
import { Data } from "orm"
import { Pool, Value } from "std/sql"

fn transfer(db: Data, fromId: i64, toId: i64, amt: i64): ()! {
  db.exec("update accounts set balance = balance - ${amt} where id = ${fromId}", []Value(0))?
  db.exec("update accounts set balance = balance + ${amt} where id = ${toId}", []Value(0))?
}

fn runIt(p: Pool): ()! {
  transfer(p, 1, 2, 500)?                        // its own transaction, per statement
  p.tx((db) => { transfer(db, 1, 2, 500)? })?     // inside the caller's transaction
  return
}
```

## The closure parameter shadows the outer handle

Name a `pool.tx(...)` block's parameter `db`, not `pool` or `t`: shadowing
the outer `Pool` makes it unreachable inside the block, so nothing written
in there can accidentally run outside the transaction and skip the
rollback. `pool.tx((db) => { pool.save(a)? })` - reusing the outer name -
writes outside the transaction it looks like it is inside; `pool.tx((db) =>
{ db.save(a)? })` cannot make that mistake, because `pool` is not in scope.

## The transaction methods

`Pool` has `.tx(f)`, `.txAt(level, f)`, `.txValue<T>(f)` and
`.txValueAt<T>(level, f)` - methods, not free functions to import
separately. Each commits on a normal return from `f`, rolls back on a
failure or a panic inside it, and hands the connection back either way.
`std/sql`'s own `tx`/`txAt`/`txValue`/`txValueAt` free functions
(`stdlib/sql/tx.bit`) are unchanged underneath; the methods are one line
each, delegating to them.
