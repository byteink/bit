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
    True => println("sara owns it")
    False => println("not hers")
    Unknown => println("cannot tell")
  }
}
```

This prints `sara owns it`. The answer is a `Truth`, not a `bool`: `True`,
`False` or `Unknown`, and a later section says when that happens. Field names
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
import { Truth, evalCond, gte, lt, ne, oneOf } from "authz"
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

fn show(b: Truth): string {
  return match (b) {
    True => "yes"
    False => "no"
    Unknown => "unknown"
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
import { Truth, and, eq, evalCond, gt, not, or } from "authz"
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
  let yes = evalCond(canEdit, a)? == Truth.True
  let no = evalCond(canNotEdit, a)? == Truth.True
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
import { Truth, Cond, and, eq, evalCond, not, or } from "authz"
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

fn show(b: Truth): string {
  return match (b) {
    True => "True"
    False => "False"
    Unknown => "Unknown"
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

This prints `Unknown`, `False`, `True`, `Unknown`. `and` and `or` follow SQL's three-valued
logic: a false child settles an `and` and a true child settles an `or`,
whatever else is unknown; otherwise unknown wins; `not` leaves it alone.

| and | True | False | Unknown |
| --- | ---- | ----- | ------- |
| True | True | False | Unknown |
| False | False | False | False |
| Unknown | Unknown | False | Unknown |

| or | True | False | Unknown |
| -- | ---- | ----- | ------- |
| True | True | True | True |
| False | True | False | Unknown |
| Unknown | True | Unknown | Unknown |

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
import { Truth, evalCond, fromWhere } from "authz"
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
  let holds = evalCond(fromWhere<Article>(w)?, a)? == Truth.True
  println("${holds}")
}
```

This prints `true`. A `Where` with no clauses and no children matches every
row, so it becomes the always-true condition whatever its join.

## Stored conditions and the asking user

A condition kept in a database cannot hold a closure, so "editors may update
their own team's articles" has no `user.team` to read when it is saved. It
names the attribute instead: the operand is the text `"$user.team"`.
`operandOf` reads stored text into an `Operand`, which is either `Lit(value)`
or `Param(path)`, and `bind` replaces every `Param` with the value the asking
user has, once per request, before the condition is evaluated:

```bit
import { Cond, Operand, Subject, Truth, bind, evalCond, operandOf } from "authz"
import { Tabled } from "orm"
import { Op } from "std/where"

@table class Article {
  @id
  id: i64
  team: string
  status: string
}

class User {
  export id: string,
  export roles: []string,
  export team: string,
}

fn describe(o: Operand): string {
  return match (o) {
    Lit(_) => "a value"
    Param(path) => "the user's ${path}"
  }
}

fn main(): ()! {
  let stored = Cond.Cmp("team", Op.Eq, [operandOf("$user.team")])
  let article = Article{ id = 1, team = "sport", status = "draft" }
  println(describe(operandOf("$user.team")))

  let mira = User{ id = "mira", roles = ["editor"], team = "sport" }
  let (bound, missing) = bind(stored, Option<Subject>.Some(mira))
  println("mira: ${evalCond(bound, article)? == Truth.True}, unresolved ${len(missing)}")

  let (asGuest, why) = bind(stored, Option<Subject>.None)
  println("guest: ${evalCond(asGuest, article)? == Truth.True}, unresolved ${why[0]}")
}
```

This prints `the user's team`, then `mira: true, unresolved 0`, then `guest:
false, unresolved team`. `bind` returns the condition and the paths it could
not fill in, so the decision log can say why a stored rule did not apply.

Binding fails closed. A path the user cannot supply (the guest, a name the
class does not have, a field that is private or an `Option`, a dotted path such
as `org.id`: attribute names are flat, see the subjects chapter) makes that one
comparison not hold, and the path is listed. Under a `not` it is the `not`
that must not hold, so `bind` writes the always-true condition there and
`not(team == $user.nope)` never grants. An attribute that does not exist can
never be the reason someone gets in.

A list attribute is the source of `oneOf`: `"$user.roles"` expands to one
operand per role, and a user with no roles matches nothing. Any other
comparison given a list cannot be bound.

Only a leading `$` is special in stored text. `"$user.<path>"` is a
placeholder, `"$$..."` is the literal text with one `$` dropped, and
everything else, `"$5"` included, is itself:

```bit
import { Operand, operandOf } from "authz"

fn show(text: string): string {
  return match (operandOf(text)) {
    Lit(_) => "${text} is text"
    Param(path) => "${text} is the user's ${path}"
  }
}

fn main() {
  println(show("$user.team"))
  println(show("$$user.team"))
  println(show("$5"))
}
```

This prints `$user.team is the user's team`, `$$user.team is text` and `$5 is
text`; the second one means the literal string `$user.team`.

A condition that still holds a `Param` when it is evaluated is an
`InvalidPolicy` naming the field and the path, never a quiet false: call `bind`
first. `validate` accepts a placeholder (its value is not known until the
request) and still checks the field it compares.

## Filtering a list

"May sara update THIS article" is one row. Inkwell's "my articles" page asks
for every row she may read, and loading the table to ask the first question a
thousand times is the slow answer. `compileSql` turns the same condition into
the text of a WHERE clause, so the database does the filtering and the two
questions cannot disagree. It takes the condition, the resource's
`ResourceInfo` (`resourceByName`), the server (`ServerDialect`, from `orm`)
and the number of the first placeholder, and returns a `SqlFragment`: the text
and the values its placeholders stand for:

```bit
import { Authz, SqlFragment, and, asAllow, asDeny, compileSql, eq, gt } from "authz"
import { MysqlVersion, ServerDialect, Tabled } from "orm"
import { Value } from "std/sql"

enum Action { Manage, Read, Create, Update, Delete, Publish }

@table class Article {
  @id
  id: i64
  authorId: string
  status: string
  views: i64
}

fn main(): ()! {
  let authz = Authz<Action>()?
  authz.resource<Article>()?
  let info = unwrap(authz.resourceByName("Article"))

  let popular = and([eq("authorId", Value.Text("sara")), gt("views", Value.Int(10))])
  let pg: SqlFragment = compileSql(popular, info, ServerDialect.Postgres, 1)?
  println(pg.sql)
  println("${len(pg.args)}")
  println(asAllow(pg, ServerDialect.Postgres).sql)

  let mysql = ServerDialect.Mysql(MysqlVersion{ major = 8, minor = 4 })
  let archived = compileSql(eq("status", Value.Text("archived")), info, mysql, 1)?
  println(asDeny(archived, mysql).sql)
}
```

This prints:

```text
("author_id" = $1 AND "views" > $2)
2
COALESCE((("author_id" = $1 AND "views" > $2)), FALSE)
NOT COALESCE((`status` = ?), 0)
```

Two rules keep this safe from SQL injection, and neither has an exception. A
value is never part of the text: every operand is a bound parameter, `$1`,
`$2` and so on on Postgres (counted from the number you pass, because the
query you add it to has numbered its own already) and `?` on MySQL, and
`oneOf` with three values is three placeholders. Text such as `'; DROP TABLE
articles;--` ends up in `args` and the SQL is the same text it was without
it. A name is never taken from the condition: it names a FIELD, the class's
declared columns give the column (`authorId` is `author_id`, or whatever
`@column` says) and it is quoted for the dialect with the quote doubled. A
field the class does not declare is an `InvalidPolicy`, so a hostile name
fails instead of being written.

An empty `oneOf` is `FALSE` (`0` on MySQL), `and` and `or` are parenthesised
groups and so is `not`, and a `$user.x` placeholder that `bind` has not
replaced is an `InvalidPolicy`.

The text is the condition as written, and a database NULL makes it unknown
rather than false, just as `evalCond` answers `Unknown`. What unknown means
depends on the rule: `asAllow` wraps an allow rule so an unknown row is not
granted, and `asDeny` wraps a deny rule so an unknown row is not denied. That
is how a list comes out the same rows as one check per row.

## Asking the rules for the whole list

`compileSql` needs a condition, and a person's rules are a pile of allows and
denies. `filterFor` folds them for you. It asks what `can` would ask, with no
row: which rules apply to this class and action for this person, with their
`$user.x` placeholders already filled in. The answer is a `Filter`, one of
three things:

- `All`: every row passes. An allow with no condition and no deny.
- `None`: no row does. No allow at all, or a deny with no condition.
- `Where(c)`: the rows for which `c` is true. It is "any allow, and no deny"
  written as one condition, and `compileSql` turns it into the WHERE clause.

```bit
import { Authz, Cond, Filter, Policy, Subject, Truth, compileSql, eq, evalCond } from "authz"
import { ServerDialect, Tabled } from "orm"
import { Value } from "std/sql"

enum Action { Manage, Read, Create, Update, Delete, Publish }

@table class Article {
  @id
  id: i64
  authorId: string
  status: string
  editorNote: Option<string>
}

class User {
  export id: string,
  export roles: []string,
}

fn reading(): Policy<User, Action> {
  return Policy("Reading", (p, user) => {
    p.can<Article>([Action.Read], eq("status", Value.Text("published")))
    p.can<Article>([Action.Read], eq("authorId", Value.Text(user.id)))
    p.cannot<Article>([Action.Read], eq("editorNote", Value.Text("hold")))
  })
}

fn everything(): Policy<User, Action> {
  return Policy("Everything", (p, user) => {
    p.canAll([Action.Manage])
  })
}

fn main(): ()! {
  let authz = Authz<Action>()?
  authz.resource<Article>()?
  authz.role<User>("reader", [reading()])?
  authz.role<User>("admin", [everything()])?
  let sara = Option<Subject>.Some(User{ id = "sara", roles = ["reader"] })
  let root = Option<Subject>.Some(User{ id = "root", roles = ["admin"] })

  let mine: Filter = authz.filterFor<Article>(sara, Action.Read)?
  match (mine) {
    All => println("all")
    None => println("none")
    Where(c) => {
      let info = unwrap(authz.resourceByName("Article"))
      let sql = compileSql(c, info, ServerDialect.Postgres, 1)?
      println(sql.sql)
      let draft = Article{ id = 1, authorId = "sara", status = "draft" }
      println("${authz.can(sara, Action.Read, draft)}")
      println("${evalCond(c, draft)? == Truth.True}")

      let hold = eq("editorNote", Value.Text("hold"))
      println("${evalCond(hold, draft)? == Truth.Unknown}")
      println("${evalCond(Cond.Known(hold), draft)? == Truth.False}")
    }
  }
  match (authz.filterFor<Article>(root, Action.Read)?) {
    All => println("all")
    _ => println("not all")
  }
  match (authz.filterFor<Article>(Option<Subject>.None, Action.Read)?) {
    None => println("none")
    _ => println("not none")
  }
}
```

```

This prints:

```text
((COALESCE(("status" = $1), FALSE) OR COALESCE(("author_id" = $2), FALSE)) AND (NOT COALESCE(("editor_note" = $3), FALSE)))
true
true
true
true
all
none
```

The WHERE clause is "some allow holds and no deny does". Sara reads what is
published and what she wrote, except what an editor put on hold. The admin
has an allow with no condition and no deny, so `All`; the guest has no role,
so no allow, so `None`. Neither needs a query.

The `COALESCE`s are the NULL rule from "Unknown is not false". The draft has
no editor note, so "the note says hold" is unknown for it, and an unknown deny
denies nothing: `can` lets sara read it, and so does the filter. SQL alone
would get this wrong, because `NOT unknown` is unknown and a WHERE drops
unknown rows. `filterFor` therefore wraps every rule in `Cond.Known`, which is
true only when its inner condition is exactly true and false when it is false
or unknown. `evalCond(Cond.Known(hold), draft)` is `False` where `hold` alone
is `Unknown`, and `compileSql` writes it as `COALESCE((...), FALSE)` (`0` on
MySQL). The promise is one sentence: for every row, the filter keeps it
exactly when `can` allows it, NULL columns included.

A rule written as code (below) has no SQL form, so `filterFor` fails with a
`NotFilterable` as soon as one applies to the class and action, even when
another rule would allow every row: which rule is met first must not decide
whether a list works. A rule `check` would refuse as invalid is an
`InvalidPolicy` here too. Repeat calls for the same person are cheap: the
rules come from the same per-person cache `can` uses.

## A rule written as code

Some rules are not data: "the publish window is open" is a function of the
clock. `canIf` writes one, and `custom` builds the same condition by hand:

```bit
import { Authz, Cond, NotFilterable, Policy, Subject, custom, eq, filterable } from "authz"
import { Tabled } from "orm"
import { Value } from "std/sql"

enum Action { Manage, Read, Create, Update, Delete, Publish }

@table class Article {
  @id
  id: i64
  authorId: string
  views: i64
}

class User {
  export id: string,
  export roles: []string,
}

fn publishing(): Policy<User, Action> {
  return Policy("Publishing", (p, user) => {
    p.canIf<Article>([Action.Publish], "PublishWindowOpen", (a) => a.views < 100)
  })
}

fn main(): ()! {
  let authz = Authz<Action>()?
  authz.resource<Article>()?
  authz.role<User>("editor", [publishing()])?
  let sara = User{ id = "sara", roles = ["editor"] }
  let early = Article{ id = 1, authorId = "sara", views = 5 }
  let late = Article{ id = 2, authorId = "sara", views = 500 }
  println("${authz.can(Option<Subject>.Some(sara), Action.Publish, early)}")
  println("${authz.can(Option<Subject>.Some(sara), Action.Publish, late)}")

  let nested = Cond.Not(custom<Article>("Quiet", (a) => a.views == 0))
  println(unwrapOr(filterable(nested), "none"))
  println(unwrapOr(filterable(eq("authorId", Value.Text("sara"))), "none"))

  authz.validateFilterable<Article>(Action.Publish) catch e {
    let (nf, ok) = e.(NotFilterable)
    println("${ok}: ${nf.policy} / ${nf.label}")
    println(e.message())
  }
}
```

This prints `true`, `false`, `Quiet`, `none`, then `true: Publishing /
PublishWindowOpen` and the message `policy 'Publishing' rule
'PublishWindowOpen' is a code function and cannot filter a list`. A single
check runs the function, so `can` answers. A list cannot: the database has no
function to run, so reading a list through the rule fails with
`NotFilterable`, a 500 and a mistake in the app's policies, never a quietly
wrong list. `filterable` finds the first code function in a condition however
deeply it sits under `and`, `or` and `not`. `authz.validateFilterable<T>(action)`
asserts it at startup (a test calls it for every list the app serves), and
checks the rules each role gives its sample user, as `role` does.

The `label` is required and names the rule in that error and the log; an empty
one is an `InvalidPolicy` when the policy is registered. The function takes
the typed row, written with its type (`(a: Article) => ...`). Prefer a
condition when one can say it: a rule as data is also a filter.

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
