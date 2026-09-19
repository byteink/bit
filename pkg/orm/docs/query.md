# Query

A page's list view runs a `SELECT` with a `WHERE` on user input, an
`ORDER BY` the request picked, and a `LIMIT`/`OFFSET` for pagination -
five moving parts, and every one of them is a place a hand-built SQL
string can go wrong. `find` builds that same query as a chain instead: the
column names are checked against the class you are mapping into, and every
value you pass reaches the database as a bound argument, never pasted into
the SQL text.

## Build and run a query

```bit
import { Data, Dir, Query, find } from "orm"
import { AttrDesc, FieldDesc, Rows, Value, sqlReqInt, sqlReqText } from "std/sql"

@table class Person {
  id: i64,
  name: string,
  email: string,
  joinedAt: i64,
}

fn personMapper(rows: Rows): Person! {
  let cols = rows.columns()
  return Person{
    id = sqlReqInt(rows, cols, "id")?,
    name = sqlReqText(rows, cols, "name")?,
    email = sqlReqText(rows, cols, "email")?,
    joinedAt = sqlReqInt(rows, cols, "joined_at")?,
  }
}

fn people(db: Data): Query<Person> {
  let fields = Person{ id = 0, name = "", email = "", joinedAt = 0 }.tableDescriptor()
  return find<Person>(db, "people", fields, personMapper)
}

fn byEmail(db: Data, email: string): []Person! {
  return people(db).where("email", Value.Text(email)).all()?
}
```

`people(db)` is the one place `Person`'s shape is spelled out: its
`tableDescriptor()` (the class's own synthesized field list, [Naming](naming.md))
and `personMapper` (an ordinary `(Rows) => Person!` closure - see "Why
`find` takes four arguments", below). Every other function in this file
calls `people(db)` and chains onto it.

`where("email", Value.Text(email))` takes the Bit FIELD name, `email`, not
a SQL column - `find`'s own class knows how to turn one into the other.
`byEmail`'s only email-shaped input, the `Value.Text(email)` argument,
never touches the SQL text: `all()` runs `select * from people where
email = $1`, with `email` bound as the query's own first parameter.

## Growing the chain

`where`/`whereIn`/`whereNull`/`whereLike`/`orderBy` all take a Bit field
name first. `limit`/`offset` take a plain count. Every one but the
terminals returns the same builder, so they chain:

```bit
fn recentJoiners(db: Data, minId: i64): []Person! {
  let q = people(db).where("id", Value.Int(minId))
  q = q.orderBy("joinedAt", Dir.Desc)
  q = q.limit(20)
  q = q.offset(0)
  return q.all()?
}

fn byEmails(db: Data, emails: []string): []Person! {
  let vals = []Value(0)
  for e of emails {
    vals = append(vals, Value.Text(e))
  }
  return people(db).whereIn("email", vals).all()?
}

fn withoutName(db: Data): []Person! {
  return people(db).whereNull("name").all()?
}
```

`whereIn` binds one placeholder per value (`in ($1, $2, $3)`, never a
single string built from `join`), and an empty list matches nothing rather
than emitting `in ()`, which several dialects refuse to parse at all.

A `Query<T>` is a normal value, so an optional filter is an `if`, not
string surgery:

```bit
fn optionalFilter(db: Data, term: string): []Person! {
  let q = people(db).where("id", Value.Int(1))
  if (len(term) > 0) {
    q = q.whereLike("name", Value.Text("%${term}%"))
  }
  return q.limit(50).all()?
}
```

`q` still names the same builder after the `if`; whichever branch ran, the
predicate it added is in the SQL the final `.all()` sends.

## The five terminals

`all`/`one`/`oneOrFail`/`count`/`exists` are the only calls that actually
run a query - everything before them only builds SQL text and a bound
argument list in memory.

```bit
fn firstOrNone(db: Data, email: string): Option<Person>! {
  return people(db).where("email", Value.Text(email)).one()?
}

fn exactlyOne(db: Data, email: string): Person! {
  return people(db).where("email", Value.Text(email)).oneOrFail()?
}

fn howMany(db: Data): i64! {
  return people(db).where("name", Value.Text("")).count()?
}

fn anyAt(db: Data, email: string): bool! {
  return people(db).where("email", Value.Text(email)).exists()?
}
```

`one`/`oneOrFail` always carry a `LIMIT` - at least 2, even when you never
called `.limit(...)` yourself - so a query that unexpectedly matches two
rows is caught and reported, never silently answered with whichever row
came back first. `one` returns `Option<Person>` (`None` for zero rows,
never an error); `oneOrFail` errors on zero rows too, for the call sites
where an absent row is a bug, not a normal outcome. `count` runs `select
count(*)`; `exists` runs `select 1 ... limit 1`, the cheapest query that
can answer yes or no.

## The column check runs before your program does

```bit
fn typo(db: Data): []Person! {
  return people(db).where("emial", Value.Text("x")).all()?
}
```

```
error[E0163]: 'emial' is not a field of 'Person'
```

`compiler/checkormquery.bit` checks a string-literal column directly
chained off `find<T>(...)` against `T`'s own declared fields, at compile
time - the mistake people actually make, caught before the program runs at
all. A column built from something other than a literal (read from a
config file, chosen by a caller) still compiles; `Query`'s own runtime
`columnFor` checks it the same way, one step later, and panics naming the
field and the class if it is wrong. Either way, no column name - checked
here or not - reaches SQL text unless it named a real field first.

## Why `find` takes four arguments

`db.find<Person>()` - no `table`, `fields` or mapper - is the shape you
would expect, and it is not what this package can do today. `find<T>`'s
generic sibling in `std/sql` (`stdlib/sql/row.bit`) gets its own per-class
mapper from a COMPILER REWRITE that only fires when `<T>` is written
literally at the exact call it rewrites; `Query<T>.all()`/`.one()`/
`.oneOrFail()` are ordinary methods, so by the time they run, `T` is
`Query`'s own type parameter, not a class name any such rewrite can see.
Reusing that machinery for this package's own `find<T>` needs a second
compiler pass shaped the same way, which is real, buildable work not
attempted yet - `pkg/orm/query.bit`'s own header names the exact functions
it would reuse. Until then, `people(db)` above is the pattern: write the
`table`/`fields`/`mapper` once per entity, and every other function in
your program calls that one function instead of `find` directly.

## Where to go next

[Naming](naming.md) covers `tableDescriptor()` and how a field name becomes
the column text `where`/`orderBy` bind against. [Data](data.md) covers the
`Data` interface every function on this page takes, and why it is not
`Pool` directly. [Raw SQL and dynamic columns](raw.md) covers `whereRaw`,
`orderByRaw` and `orderByField` - a SQL fragment this file's builder has
no shape for, and a column name from outside your own source.
