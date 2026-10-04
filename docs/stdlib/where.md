# std/where

Inkwell's authors may edit their own articles, and only while the article is
not archived. That rule is a condition on an `Article`: `authorId` equals the
signed-in user, `status` is not `"archived"`. Something has to hold that
condition so one part of your program can write it and another can run it,
against a loaded article in memory or as the `WHERE` of a database query.

`std/where` is that holder. It is plain data: a small tree of field
comparisons, joined with and or or, optionally negated. It never evaluates
anything and knows nothing about databases or policies. A package that wants
the condition (an access check, a query builder) reads the tree and does the
work its own way.

<!-- doctest: per-block -->

## One comparison

A `Clause` is a single test: a field name, an `Op`, and the value or values to
compare against. Values are `std/sql`'s `Value`, so the same clause can be
checked in memory or bound as a query parameter.

```bit
import { Clause, Op } from "std/where"
import { Value } from "std/sql"

fn ownArticle(userId: string): Clause! {
  return Clause("authorId", Op.Eq, [Value.Text(userId)])?
}
```

`Clause(...)` is fallible because it checks the shape: every `Op` takes
exactly one value except `In`, which takes one or more. A clause that exists is
well formed, so code that reads one never has to ask.

## A condition on an Article

A `Where<Article>` holds clauses and combines them. With no `join` given they
are all required (`And`). The type argument is never stored: it exists so a
condition written for `Article` cannot be passed where one for `Comment` is
expected.

```bit
import { Clause, Op, Where } from "std/where"
import { Value } from "std/sql"

class Article {
  authorId: string,
  status: string,
}

fn editableBy(userId: string): Where<Article>! {
  let mine = Clause("authorId", Op.Eq, [Value.Text(userId)])?
  let open = Clause("status", Op.Ne, [Value.Text("archived")])?
  return Where<Article>(clauses = [mine, open])
}
```

`Where<Article>()` with nothing in it is the empty filter and matches every
article.

## Writing the condition as an object literal

Building clauses by hand says everything, and says it at length. Where a
`Where<Article>` is expected you can write the condition the way you would say
it, as an object literal whose keys are the article's fields:

```bit
import { Where } from "std/where"

class Article {
  authorId: string,
  status: string,
  editor: Option<string>,
}

fn mine(userId: string) {
  let editable: Where<Article> = { authorId: userId, status: "published" }
  let anything: Where<Article> = {}
  let unassigned: Where<Article> = { editor: nil }
}
```

Each entry compares its field for equality, and the entries are all required.
`{}` is the empty filter. A key that is not a field of `Article` is an error at
compile time, with the nearest field as a suggestion, and so is a value of the
wrong type:

```text
error[E0301]: Article has no field "authorID"
   |                             ^^^^^^^^ did you mean "authorId"?

error[E0302]: field "authorId" of Article is 'string', found 'i64'
```

An `Option` field accepts a value of its payload type, or `nil` to test for
absence. `nil` on any other field is the same E0302. The literal is only a
condition because a `Where<Article>` is expected where it is written; with
another expected type it is an ordinary map and `authorId` would be a variable.

The operator forms (`{ age: { gte: 18 } }`), the `and`, `or` and `not` keys and
`related(...)` values are reported as E0303 until they are supported. A program
that contains a condition literal type-checks but is not yet built: lowering it
to the clauses above is the next step.

## Or, nested and negated

`Join.Or` makes a node match when any of its clauses or children match. Nesting
builds the rest: put the alternatives in `children`, and set `not` to negate a
node. This is the same tree a condition with `and`, `or` and `not` keys becomes,
so there is no separate type for each.

```bit
import { Clause, Op, Join, Where } from "std/where"
import { Value } from "std/sql"

class Article {
  authorId: string,
  status: string,
}

fn visibleTo(userId: string): Where<Article>! {
  let published = Clause("status", Op.In, [Value.Text("published"), Value.Text("featured")])?
  let mine = Clause("authorId", Op.Eq, [Value.Text(userId)])?
  let archived = Where<Article>(clauses = [Clause("status", Op.Eq, [Value.Text("archived")])?])
  let readable = Where<Article>(clauses = [published, mine], join = Join.Or)
  return Where<Article>(children = [readable, Where<Article>(not = true, children = [archived])])
}
```

Reading this: an article is visible when it is published or featured, or it is
yours, and it is not archived.

## Sharp edges

- `Clause(...)` fails with a message naming the field when the value count is
  wrong, for example `` where: Clause(): `status` In needs at least one value ``,
  or when the field name is empty.
- A `Clause` is built through `Clause(...)` only. The class has a constructor,
  so a literal such as `Clause{ field = "age" }` is refused outside this module.
- An empty node matches everything, and `not = true` on an empty node then
  matches nothing. Combining the clauses and the children uses the same `join`.
- There is no `and`, `or` or `not` function. `Where<Article>(join = Join.Or,
  children = [a, b])` and `Where<Article>(not = true, children = [a])` say it
  with the one constructor.

## Reference

### `Op`

How a clause compares its field: `Eq`, `Ne`, `In`, `Lt`, `Lte`, `Gt`, `Gte`.
`In` matches when the field equals any of the clause's values.

```bit
import { Op } from "std/where"

fn isMembership(op: Op): bool {
  return op == Op.In
}
```

### `Join`

How a `Where` combines its clauses and children: `And` (all must match) or
`Or` (any may match).

```bit
import { Join } from "std/where"

fn needsAll(j: Join): bool {
  return j == Join.And
}
```

### `Clause`

One comparison: `field: string`, `op: Op` and `values: []Value`. Build it with
`Clause(field, op, values)`.

### `Clause(field: string, op: Op, values: []Value): Clause!`

The checked constructor. Fails when `field` is empty, when `op` is `In` and
`values` is empty, or when `op` is anything else and `values` does not hold
exactly one value.

```bit
import { Clause, Op } from "std/where"
import { Value } from "std/sql"

fn rejectsTwo(): bool {
  let refused = false
  Clause("age", Op.Eq, [Value.Int(1), Value.Int(2)]) catch e {
    refused = true
  }
  return refused
}
```

### `Where<T>`

A condition on a `T`: `clauses: []Clause`, `join: Join`, `not: bool` and
`children: []Where<T>`. The node matches when its clauses and children,
combined by `join`, hold, then `not` flips the answer.

### `Where<T>(clauses: []Clause = [], join: Join = Join.And, not: bool = false, children: []Where<T> = []): Where<T>`

The constructor. Every argument is optional, so `Where<T>()` is the empty
filter.

```bit
import { Where } from "std/where"

class Draft {
  title: string,
}

fn matchAll(): Where<Draft> {
  return Where<Draft>()
}
```

Next: [sql](sql.md), whose `Value` this module's clauses carry.
