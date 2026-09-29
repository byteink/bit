# Raw SQL and transactions

[`Repo<T>`](query.md)'s chain covers `where`/`orderBy`/`limit`/`offset`/
`with`, but nothing expresses a `case` expression, a window function, a
lateral join, a CTE, or a bulk report query that never maps to one `@table`
class. `Db.exec`/`Db.query<T>` are the escape hatch - a caller writes real
SQL text, still with every value bound, never pasted into the statement.
`Db.tx` is the second half: an all-or-nothing block for a write that must
land as one unit, or not at all.

## exec and query: SQL you write, values you bind

```bit
import { Data } from "orm"

@table class Post {
  @id id: i64,
  title: string,
  views: i64,
}

fn bumpViews(db: Data, id: i64): ()! {
  db.exec("update post set views = views + 1 where id = ?", id)?
}

fn popular(db: Data, prefix: string): []Post! {
  return db.query<Post>("select * from post where title like ?", "${prefix}%")?
}
```

`bumpViews`'s `id` argument never touches the SQL text: `?` is the one
placeholder spelling a caller writes, whatever the underlying driver's own
wire form is, and the value behind it reaches the database as a bound
argument - the same guarantee every `Repo<T>` chain method gives. `query<T>`
maps every returned row into `T` through the same `T.__fromRow` a `Repo<T>`
read already uses, so a hand-written report query still comes back as a
list of real entities, not a driver-shaped row set.

## tx: an all-or-nothing block

```bit
fn transferViews(db: Data, fromId: i64, toId: i64, n: i64): ()! {
  db.tx((tx) => {
    tx.exec("update post set views = views - ? where id = ?", n, fromId)?
    tx.exec("update post set views = views + ? where id = ?", n, toId)?
    return
  })?
}
```

`db.tx`'s closure receives its own handle - never the outer `db` - and
commits when the closure returns, rolling back on any failure or panic
inside it. `tx.table<T>()`/`tx.exec`/`tx.query<T>` are the identical shapes
`db.table<T>()`/`db.exec`/`db.query<T>` already are, so a `Repo<T>` chain
and a hand-written statement compose in the same transaction without a
second API to learn - see [Locking](locking.md) for the one thing only the
transaction handle can do, `tx.table<T>().lock(mode)`.
