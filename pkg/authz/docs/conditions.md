# Conditions

"Editors may update articles" is too broad. What Inkwell wants is "editors
may update THEIR OWN articles, while they are still drafts". The part after
"their own" is a condition, and `authz` writes one as a small tree of data
that can be checked against a single article today and turned into a database
filter for a list later, so the two never disagree.

<!-- doctest: per-block -->

## The simplest thing that works

A condition compares a field with a value. Build one with `eq`, and ask it
about a row with `evalCond`:

```bit
import { Cond, eq, evalCond } from "authz"
import { Tabled } from "orm"
import { Value } from "std/sql"

@table class Article {
  @id
  id: i64
  authorId: string
  status: string
  views: i64
  editorNote: Option<string>
}

fn main(): ()! {
  let article = Article{ id = 1, authorId = "sara", status = "draft", views = 40 }
  let mine: Cond = eq("authorId", Value.Text("sara"))
  match (evalCond(mine, article)?) {
    T => println("sara owns it")
    F => println("not hers")
    U => println("cannot tell")
  }
}
```

This prints `sara owns it`. The answer is a `Bool3`, not a `bool`: `T`, `F`
or `U` for unknown, and the last section says when that happens. Field names
are the class's own (`authorId`), never column names, and values are
`std/sql`'s `Value`: `Int`, `Float`, `Bool`, `Text`, `Blob` and `Null`.

## The seven comparisons

Each one is a function that returns a `Cond`:

| Function | Holds when the field |
| -------- | -------------------- |
| `eq(f, v)` | equals `v` |
| `ne(f, v)` | differs from `v` |
| `oneOf(f, vs)` | equals any value in `vs` |
| `lt(f, v)` | is less than `v` |
| `lte(f, v)` | is less than or equal to `v` |
| `gt(f, v)` | is greater than `v` |
| `gte(f, v)` | is greater than or equal to `v` |

`oneOf` is `in`: `in` is a reserved word, so it cannot name a function.

```bit
import { Bool3, evalCond, gte, lt, ne, oneOf } from "authz"
import { Tabled } from "orm"
import { Value } from "std/sql"

@table class Article {
  @id
  id: i64
  authorId: string
  status: string
  views: i64
  editorNote: Option<string>
}

fn show(b: Bool3): string {
  return match (b) {
    T => "yes"
    F => "no"
    U => "unknown"
  }
}

fn main(): ()! {
  let a = Article{ id = 1, authorId = "sara", status = "draft", views = 40 }
  let open = [Value.Text("draft"), Value.Text("review")]
  println(show(evalCond(oneOf("status", open), a)?))
  println(show(evalCond(ne("authorId", Value.Text("sara")), a)?))
  println(show(evalCond(gte("views", Value.Int(40)), a)?))
  println(show(evalCond(lt("views", Value.Float(39.5)), a)?))
}
```

This prints `yes`, `no`, `yes`, `no`. Integers compare exactly, an integer
against a float compares as floats, and text compares byte by byte.

## Combining conditions

`and`, `or` and `not` take conditions and give one back. An empty `and` is
always true and an empty `or` never is, so a list you build in a loop needs
no special case for zero entries:

```bit
import { Bool3, and, eq, evalCond, gt, not, or } from "authz"
import { Tabled } from "orm"
import { Value } from "std/sql"

@table class Article {
  @id
  id: i64
  authorId: string
  status: string
  views: i64
  editorNote: Option<string>
}

fn main(): ()! {
  let a = Article{ id = 1, authorId = "sara", status = "draft", views = 40 }
  let own = eq("authorId", Value.Text("sara"))
  let draft = eq("status", Value.Text("draft"))
  let popular = gt("views", Value.Int(1000))
  let canEdit = and([own, or([draft, popular])])
  let canNotEdit = not(canEdit)
  let yes = evalCond(canEdit, a)? == Bool3.T
  let no = evalCond(canNotEdit, a)? == Bool3.T
  println("${yes}")
  println("${no}")
}
```

This prints `true`, then `false`. The constructors simplify only what cannot
hide a mistake: an empty `and`, a one-child `and`, `not(not(c))`. They do not
fold `and([False, c])` into False, because that would throw `c` away, and with
it a misspelled field that startup checking would have caught.

## Catch typos at startup

A condition is only text and values until it meets a resource.
`authz.validate` checks it against a registered class once, when the policy is
registered, so a misspelled field or a value of the wrong type stops the app
at startup instead of quietly never matching:

```bit
import { Authz, eq, gt, resourceRef } from "authz"
import { Tabled } from "orm"
import { Value } from "std/sql"

enum Action { Manage, Read, Create, Update, Delete, Publish }

@table class Article {
  @id
  id: i64
  authorId: string
  views: i64
}

fn main(): ()! {
  let authz = Authz<Action>()?
  authz.resource<Article>()?
  let ref = resourceRef<Article>()
  authz.validate(ref, eq("authorId", Value.Text("sara")))?
  authz.validate(ref, gt("views", Value.Int(1000)))?
  authz.validate(ref, eq("authorID", Value.Text("sara"))) catch e {
    println(e.message())
  }
  authz.validate(ref, eq("views", Value.Text("many"))) catch e {
    println(e.message())
  }
}
```

The two good conditions pass. The other two print:

```text
invalid policy: no field authorID (fields: id, authorId, views)
invalid policy: field views is i64, the value is text
```

`validate` also refuses a comparison with `Value.Null` (it is never true), an
ordering (`lt`, `gt`) over a bool or bytes column, an `oneOf` with no values,
and a resource that is not registered. A condition on `all` may not name a
field, since the resources `all` covers do not share one.

## Unknown is not false

A field of type `Option` that is `None` is NULL. Nothing equals NULL, nothing
is less than it and nothing differs from it, so every comparison with it is
unknown, exactly as in SQL:

```bit
import { Bool3, Cond, and, eq, evalCond, not, or } from "authz"
import { Tabled } from "orm"
import { Value } from "std/sql"

@table class Article {
  @id
  id: i64
  authorId: string
  status: string
  views: i64
  editorNote: Option<string>
}

fn show(b: Bool3): string {
  return match (b) {
    T => "T"
    F => "F"
    U => "U"
  }
}

fn main(): ()! {
  let a = Article{ id = 1, authorId = "sara", status = "draft", views = 40 }
  let unknown: Cond = eq("editorNote", Value.Text("ok"))
  let yes = eq("status", Value.Text("draft"))
  let no = eq("status", Value.Text("final"))
  println(show(evalCond(unknown, a)?))
  println(show(evalCond(and([no, unknown]), a)?))
  println(show(evalCond(or([yes, unknown]), a)?))
  println(show(evalCond(not(unknown), a)?))
}
```

This prints `U`, `F`, `T`, `U`. `and` and `or` follow SQL's three-valued
logic: a false child settles an `and` and a true child settles an `or`,
whatever else is unknown; otherwise unknown wins; `not` leaves it alone.

| and | T | F | U |
| --- | - | - | - |
| T | T | F | U |
| F | F | F | F |
| U | U | F | U |

| or | T | F | U |
| -- | - | - | - |
| T | T | T | T |
| F | T | F | U |
| U | T | U | U |

A rule that comes out unknown does not apply: an allow rule that is unknown
grants nothing, and a deny rule that is unknown denies nothing. In SQL the
same rule is `NOT COALESCE(cond, false)`.

`oneOf` is a chain of `or`ed equalities, so `oneOf("views", [Null, 40])` is
true for 40 and unknown for anything else, as `x IN (NULL, 40)` is.

## Where this differs from CASL

CASL conditions are Mongo-style objects and a missing field simply does not
match. Here a class has declared columns, so the two failure kinds are
separated: a field the class does not have is an error (`InvalidPolicy`,
at startup through `validate`, and on the first check if it slipped past), and
a field that exists but is NULL is unknown. `$in` over a list is `oneOf`;
`$ne`, `$lt`, `$lte`, `$gt`, `$gte`, `$and`, `$or` and `$not` are `ne`, `lt`,
`lte`, `gt`, `gte`, `and`, `or` and `not`.

Evaluation checks every child of an `and` and `or` and every value of an
`oneOf` even after the answer is settled, so a typo fails on the first row
instead of only on rows that reach it. Comparing unlike kinds (`eq("status",
Value.Int(1))`) is an `InvalidPolicy`, not false. A float NaN is unordered:
every comparison with it is false except `ne`.

## From a typed literal

`std/where` has the data a condition literal such as `{ authorId: "sara" }`
lowers to. `fromWhere` turns that `Where<T>` into a `Cond`, one node for one:

```bit
import { Bool3, evalCond, fromWhere } from "authz"
import { Tabled } from "orm"
import { Clause, Op, Where } from "std/where"
import { Value } from "std/sql"

@table class Article {
  @id
  id: i64
  authorId: string
  status: string
}

fn main(): ()! {
  let own = Clause("authorId", Op.Eq, [Value.Text("sara")])?
  let w = Where<Article>(clauses = [own])
  let a = Article{ id = 1, authorId = "sara", status = "draft" }
  let holds = evalCond(fromWhere(w), a)? == Bool3.T
  println("${holds}")
}
```

This prints `true`. A `Where` with no clauses and no children matches every
row, so it becomes the always-true condition whatever its join.

## Sharp edges

- Only fields stored in a row can be named: scalars (`i64`, `int`, `f64`,
  `bool`, `string`, `[]byte`) and an `Option` of one. A relation field
  (`@belongsTo`, `@hasMany`) cannot, and neither can a field of another type.
- `Value.Null` is never a useful operand: `validate` refuses it, and
  evaluated directly it makes the comparison unknown.
- Text compares byte by byte here. A database with a case-insensitive
  collation orders text differently; keep authorization comparisons on
  columns that use a binary collation.
- Ordering a bool or a bytes field (`lt`, `lte`, `gt`, `gte`) is an
  `InvalidPolicy`.

## Next

A condition becomes useful once a policy attaches it to an action on a
resource: that is the policies chapter.
