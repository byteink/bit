# Query

A page's article list runs a `SELECT` with a `WHERE` on user input, an
`ORDER BY` the request picked, and a `LIMIT`/`OFFSET` for pagination - five
moving parts, and every one of them is a place a hand-built SQL string can
go wrong. `db.table<T>()` builds that same query as a chain instead: the
column names are checked against your class at compile time, and every
value you pass reaches the database as a bound argument, never pasted into
the SQL text.

## The simplest query

```bit
import { Db, open } from "orm"

@table class Article {
  id: i64,
  title: string,
  authorId: i64,
}

fn byId(db: Db, id: i64): Article! {
  return db.table<Article>().find(id)?
}
```

`db.table<Article>()` returns a repository over the `article` table - no
table name, field list or row mapper to write; `@table` supplies all three.
Every method below hangs off that one repository.

## Growing the chain

```bit
import { Dir } from "orm"

fn byAuthor(db: Db, authorId: i64): []Article! {
  return db.table<Article>().where("authorId", authorId).orderBy("title").all()?
}

fn recent(db: Db, authorId: i64): []Article! {
  return db.table<Article>().where("authorId", authorId).orderBy("id", Dir.Desc).limit(20).all()?
}
```

`where`/`orderBy` take the Bit FIELD name (`authorId`), not the SQL column
(`author_id`) - the class itself knows how to turn one into the other (see
[Naming](naming.md)). `orderBy`'s second argument is optional and defaults
to `Dir.Asc`; pass `Dir.Desc` for the other direction. `where`, `orderBy`,
`limit` and `offset` all return the same builder, so they chain, and each
one is a plain value: an optional filter is an `if`, not string surgery.

```bit
fn filtered(db: Db, authorId: i64, term: Option<string>): []Article! {
  let q = db.table<Article>().where("authorId", authorId)
  match (term) {
    Some(t) => return q.where("title", t).all()?
    None => return q.all()?
  }
}
```

## Paging through a large table with `after`

`limit`/`offset` gets slower the deeper you page, because the database
still has to count past every skipped row. `after` pages by the last key
you saw instead - a `WHERE id > $1` under the hood, the same cost on page 1
and page 1,000:

```bit
fn nextPage(db: Db, lastId: i64): []Article! {
  return db.table<Article>().orderBy("id").after(lastId)?.limit(20).all()?
}
```

Call it with the id of the last row from the previous page (or skip it for
page one). `after` needs `orderBy` on the same column somewhere in the
chain, which is why it returns a failure (`?`) instead of a plain value -
it fails naming the mistake if the two disagree.

## The terminals

`all`/`first`/`find` are what actually run a query - everything before
them only builds SQL text and a bound argument list in memory.

```bit
fn newest(db: Db, authorId: i64): Option<Article>! {
  return db.table<Article>().where("authorId", authorId).orderBy("id", Dir.Desc).first()?
}
```

`all` returns every matching row. `first` returns `Option<Article>` - `None`
for zero rows, never an error. `find(id)` is the shortest path to exactly
one row by its primary key, and fails naming the table if no row (or more
than one, which should never happen on a primary key) matches.

## The column check runs before your program does

```text
db.table<Article>().where("titel", "x")
```

```text
error[E0163]: 'titel' is not a field of 'Article'
```

The compiler checks a string-literal column passed to `where`/`orderBy`
against `Article`'s own declared fields, at compile time - the typo is
caught before the program runs at all, not after it ships a broken filter.

## Where to go next

[Write](write.md) covers `insert`/`update`/`delete` and bulk writes on the
same repository. [Relations](relation.md) covers `with`, `@hasMany`,
`@belongsTo` and many-to-many `link`/`unlink`. [Soft delete](softdelete.md)
covers what `all`/`find` hide by default on a `@softDelete` class.
[Locking](locking.md) covers `tx.table<T>().lock()` for a row you're about
to change inside a transaction. [Naming](naming.md) covers how a field name
becomes the column text `where`/`orderBy` bind against.
