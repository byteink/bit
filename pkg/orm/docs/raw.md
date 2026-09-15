# Raw SQL and dynamic columns

[Query](query.md)'s chain covers `where`/`whereIn`/`whereNull`/
`whereLike`/`orderBy`, but nothing expresses a `case` expression, `NULLS
LAST`, a window function, a lateral join, a CTE, or a Postgres `tsvector`
match - SQL your database can run that this package's builder has no
shape for. And a sortable table header handing you a column name at
request time has no safe place in the chain at all: every method on
[Query](query.md) takes a Bit field name, checked against the class you
mapped, never a string an HTTP request picked. `whereRaw`, `orderByRaw`
and `orderByField` are the three escape hatches - the only place in this
package SQL text or a dynamic identifier is allowed to reach a query.

## whereRaw: a fragment plus its own bound arguments

```bit
import { Data, Dir, Query, find } from "orm"
import { AttrDesc, FieldDesc, Rows, Value, sqlReqInt, sqlReqText } from "std/sql"

@table class Person {
  id: i64,
  name: string,
  email: string,
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

fn byEmailCaseInsensitive(db: Data, email: string): []Person! {
  return people(db).whereRaw("lower(email) = lower($1)", Value.Text(email)).all()?
}
```

`byEmailCaseInsensitive`'s `email` argument never touches the SQL text -
it reaches `all()` as `Value.Text(email)`, the second argument to
`whereRaw`, and comes out the far side as a bound `$1`, exactly the way
`where`'s own value argument does. What `whereRaw` adds over `where` is
the fragment itself: `lower(email) = lower($1)` is SQL you wrote, not a
column-and-operator this package assembled, so it can say anything your
database understands - a `case when`, a subquery, a call to a function
`where` has no method for.

Write `$1`, `$2`, ... as if this `whereRaw` call were the only bound
clause in the query - `whereRaw` renumbers them to their true position
once it knows how many arguments earlier `where`/`whereIn`/`whereRaw`
calls in the same chain already bound, so composing two calls still works:

```bit
fn recentByEmail(db: Data, minId: i64, email: string): []Person! {
  let q = people(db).where("id", Value.Int(minId))
  return q.whereRaw("lower(email) = lower($1)", Value.Text(email)).all()?
}
```

emits `where id = $1 and lower(email) = lower($2)` - the fragment's own
`$1` became `$2` because `where("id", ...)` already bound the first
argument, not because you had to count for it.

`whereRaw`'s two arguments must agree: a fragment naming `$1` with no
value supplied, or a value supplied with no placeholder in the fragment,
panics rather than silently running a mismatched query - the fragment is
code you wrote, so a mismatch is a bug in that code, caught the moment it
runs rather than producing a query with the wrong argument count.

## orderByRaw: a sort expression with no bound values

```bit
fn exampleAddressesFirst(db: Data): []Person! {
  let q = people(db).orderByRaw("case when email like '%@example.com' then 0 else 1 end")
  return q.orderBy("name", Dir.Asc).all()?
}
```

`orderByRaw` is `whereRaw`'s counterpart for the ORDER BY clause - the
escape hatch for a `case` expression, `NULLS LAST`, an ordinal, or a
window function's output, none of which `orderBy`/`orderByField` can
express. `exampleAddressesFirst` sorts `@example.com` addresses first,
then every row alphabetically by name - `orderByRaw` and `orderBy`
compose in the order you call them, the same way two `where` calls do.

Unlike `whereRaw`, `orderByRaw` takes **no argument list at all**. ORDER
BY has no bound-value form - nothing in a query ever supplies a parameter
for a sort expression - so a fragment containing a placeholder (`$1`,
`$2`, ...) is refused with a panic rather than silently accepted: the
placeholder could never be filled, so writing one is always a mistake in
the fragment itself, not something a caller can trigger with input.

## orderByField: a column name from outside your program

```bit
fn sortedBy(db: Data, column: string): []Person! {
  return people(db).orderByField(column, Dir.Asc)?.all()?
}
```

A sortable table header's request often looks exactly like `column`
above - text the caller does not control the shape of. `orderByField`
resolves it against `Person`'s own descriptor (the same field list
[Naming](naming.md) reads `where`'s columns from) and fails, rather than
panicking, when it is not one of `Person`'s declared fields:

Calling `sortedBy(db, "id; drop table users")` fails rather than running:

```
pkg/orm: 'id; drop table users' is not a field of the class mapped to 'people'
```

That refusal is the whole mechanism - there is no escaping, no quoting,
no attempt to make an unrecognised column name safer to embed. SQL has no
placeholder form for an identifier, so the only sound answer to "this
text might be a column name" is "it is, or it is refused" - anything
that tries to sanitise the text instead has been bypassed before.

## Why raw stays in the name, and orderByField does not

`whereRaw` and `orderByRaw` are the two methods in this package that run
SQL text you wrote - `raw` stays in both names on purpose, so a security
review can find every call to either with one grep, the same reason
`pkg/web`'s `raw(s)` carries the word for unescaped HTML. `orderByField`
is not a third raw escape hatch: it is the safe alternative to writing
one, and naming it as though it were unsafe would bury the two names
actually worth grepping for.

## Where to go next

[Query](query.md) covers the rest of the find chain these three extend.
[Schema](schema.md)'s own `raw()` is the equivalent escape hatch for DDL -
a different threat model, since a migration is text a developer authors
once rather than text a request can shape.
