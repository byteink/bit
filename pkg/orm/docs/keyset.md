# Keyset pagination

An admin page listing people, ordered by id, 50 at a time, usually reads
with [`offset`](query.md): page 2 is `OFFSET 50`, page 500 is `OFFSET
24950`. That works, and it gets slower every page deeper you go - the
database still has to walk and discard those 24950 rows before it can
hand you row 24951, on every request. Page 1 is instant; page 500 times
out. `after` reads the same table at any depth for the same cost.

## The simplest keyset page

```bit
import { Data, Dir, Query, find } from "orm"
import { AttrDesc, FieldDesc, Rows, Value, sqlReqInt, sqlReqText } from "std/sql"

@table class Person {
  @id
  id: i64
  name: string
  email: string
}

fn personMapper(rows: Rows): Person! {
  let cols = rows.columns()
  return Person{
    id: sqlReqInt(rows, cols, "id")?,
    name: sqlReqText(rows, cols, "name")?,
    email: sqlReqText(rows, cols, "email")?,
  }
}

fn people(db: Data): Query<Person> {
  let fields = Person{ id: 0, name: "", email: "" }.tableDescriptor()
  return find<Person>(db, "people", fields, personMapper)
}

fn firstPage(db: Data): []Person! {
  return people(db).orderBy("id", Dir.Asc).limit(50).all()?
}

fn nextPage(db: Data, lastId: i64): []Person! {
  let q = people(db).orderBy("id", Dir.Asc).after(Value.Int(lastId))?
  return q.limit(50).all()?
}
```

`people(db)` is the same helper [Query](query.md) already builds `find`
chains from. `nextPage` carries the *last row of the page you already
have* - not a page number - and `after` turns that into `WHERE id > $1`
instead of an `OFFSET`:

```text
select * from people where id > $1 order by id asc limit 50
```

That `WHERE` uses the index on `id` the same way any other equality or
range lookup does. It costs the same whether `lastId` is row 50 or row
50,000 - there is nothing before it to walk and discard, because the
query never asked for "the 50,000th row", it asked for "rows after this
one."

## Walking a whole table

```bit
fn walkAll(db: Data, onPage: ([]Person) => ()!): ()! {
  let lastId = i64(0)
  while (true) {
    let q = people(db).orderBy("id", Dir.Asc)
    if (lastId != 0) {
      q = q.after(Value.Int(lastId))?
    }
    let page = q.limit(500).all()?
    if (len(page) == 0) {
      return
    }
    onPage(page)?
    lastId = page[len(page) - 1].id
  }
}
```

A backfill or export job that reads an entire table this way costs the
same per page from the first row to the last - no page eventually times
out the way a deep `OFFSET` would.

## `after` needs a deterministic, unique order

`after` reads the FIRST `orderBy` column you set - "after row X" is only
meaningful once you have said what order the rows are in - and it must be
`@id` or `@unique`. Calling `people(db).after(Value.Int(1))` with no
`orderBy` set yet, or ordering by a column two rows can share (`name`,
say - "everything after this value" is then ambiguous: a row with the
same name as the cursor could be silently skipped or handed back twice),
both refuse rather than paginate wrong:

```text
pkg/orm: after() on the class mapped to 'people' has no orderBy() set - keyset pagination needs a deterministic order to compare the cursor against
pkg/orm: after() on the class mapped to 'people' orders by 'name', which is neither @id nor @unique - the page boundary would be ambiguous, silently skipping or repeating rows
```

`after` returns `Query<T>!`, unlike every other chain method here (`where`,
`orderBy`, `limit`, ...) - those can never fail, but "no order set yet" and
"ordering by a non-unique column" are mistakes a caller can catch, so
`after` is `fail`-based, propagated with `?` before the next call in the
chain.

## When not to use it

`after` cannot jump to an arbitrary page number - there is no cursor for
"page 500" without having already read page 499's last row, so a
page-number UI (`1 2 3 ... 500`, click page 47 directly) still needs
[`offset`](query.md), cost and all. Reach for `after` for "next page" /
"load more" / infinite scroll, and for any job that reads a whole table
front to back; reach for `offset` when a user picks a page number out of
order.

## What this proves, and what it does not

The tests for `after` run against a fake driver and prove the SQL shape:
a `WHERE <col> > $n` clause, never an `OFFSET`, with the comparison
flipped to `<` for a descending order. That is what makes the query
*capable* of costing the same at any depth - a fake driver cannot measure
an actual query plan or a wall-clock difference between page 1 and page
10,000 against a real, indexed table. Confirming a specific database
actually chooses an index scan for this `WHERE` is that database's own
`EXPLAIN` output, not a claim this package's tests make.

## Where to go next

[Query](query.md) covers the rest of the find chain - `where`, `orderBy`,
`limit`, and `offset` itself. [Bulk insert](bulk.md) covers the other
scale problem, writing many rows in one statement instead of one at a
time.
