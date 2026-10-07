# Relationships

Inkwell lets authors group articles into folders, and the launch folder is
edited by Sara and by everyone on the engineering team. "Sara may edit this
article" is not something you can write as a condition on the article: the
fact lives between a person and a folder. `authz` keeps such facts as
relationship tuples, plain data you write at runtime and read back.

<!-- doctest: per-block -->

## The simplest thing that works

A tuple says "this subject is a `relation` of that object". Register the class
the object belongs to, declare the relations it has, then `relate`:

```bit
import { Authz } from "authz"
import { Tabled } from "orm"

enum Action { Manage, Read, Create, Update, Delete, Publish }

@table class Folder {
  @id
  id: i64
  name: string
}

fn main(): ()! {
  let authz = Authz<Action>()?
  authz.resource<Folder>()?
  authz.relation<Folder>("editor")?
  authz.relate("user:sara", "editor", "folder:launch")?
  println("${authz.related("user:sara", "editor", "folder:launch")?}")
  authz.unrelate("user:sara", "editor", "folder:launch")?
  println("${authz.related("user:sara", "editor", "folder:launch")?}")
}
```

This prints `true`, then `false`. The three strings are always in the order
subject, relation, object. `related` answers for exactly the tuple you wrote.

## Relations are declared per type

`relation<Folder>("editor")` says folders have an `editor` relation. Without
it, a typo such as `edtior` would be accepted, stored, and then never match
anything: the kind of bug that shows up as "Sara cannot edit her folder"
weeks later. With it, the typo fails where you wrote it:

```bit
import { Authz } from "authz"
import { Tabled } from "orm"

enum Action { Manage, Read, Create, Update, Delete, Publish }

@table class Folder {
  @id
  id: i64
  name: string
}

fn main(): ()! {
  let authz = Authz<Action>()?
  authz.resource<Folder>()?
  authz.relation<Folder>("editor")?
  authz.relation<Folder>("viewer")?
  authz.relate("user:sara", "edtior", "folder:launch") catch e {
    println(e.message())
  }
}
```

This prints `invalid policy: relation is not declared on folder (declared:
editor, viewer)`. `relate`, `unrelate`, `related` and `hasRelation` all refuse
an undeclared relation, and so does a userset whose relation its type does not
declare. Declare each relation once; a second `relation<Folder>("editor")` is
an `InvalidPolicy`, and so is declaring one on a class you did not register
first.

## Typed references

`user:sara` and `folder:launch` are typed references, `type:id`. The type of
an object is a registered resource's class name with its first letter
lowered: `Folder` is `folder`, `OrderLine` is `orderLine`. A subject is
`user:<id>` or any registered type, so a whole team can be a subject. There is
exactly one spelling per type, so `Folder:launch` is refused instead of
becoming a second, unrelated object.

Inkwell's engineers become editors of the launch folder with one tuple:

```bit
import { Authz } from "authz"
import { Tabled } from "orm"

enum Action { Manage, Read, Create, Update, Delete, Publish }

@table class Folder {
  @id
  id: i64
  name: string
}

@table class Team {
  @id
  id: i64
  name: string
}

fn main(): ()! {
  let authz = Authz<Action>()?
  authz.resource<Folder>()?.resource<Team>()?
  authz.relation<Folder>("editor")?
  authz.relation<Team>("member")?
  authz.relate("team:eng#member", "editor", "folder:launch")?
  println("${authz.related("team:eng#member", "editor", "folder:launch")?}")
  println("${authz.related("user:sara", "editor", "folder:launch")?}")
}
```

`team:eng#member` is a userset: everyone who is a `member` of team `eng`.
Groups and folder inheritance are made of these. `related` is direct only, so
this prints `true`, then `false`: Sara is not named by the tuple, and
`related` does not expand the team. Expanding it is what `hasRelation` does,
below.

## What is refused

Tuples usually arrive from an admin endpoint, so every part is checked before
anything is stored, and a bad one is an `InvalidPolicy`:

- the relation is `[a-z][a-z0-9_]{0,31}` and declared on the object's type;
- an id is 1 to 128 printable ASCII bytes with no space, `:` or `#`;
- the object's type, and the subject's unless it is `user`, is a registered
  resource;
- a userset's relation is declared on its type, and `user` has none;
- a reference without a `:` is refused.

```bit
import { Authz } from "authz"
import { Tabled } from "orm"

enum Action { Manage, Read, Create, Update, Delete, Publish }

@table class Folder {
  @id
  id: i64
  name: string
}

fn main(): ()! {
  let authz = Authz<Action>()?
  authz.resource<Folder>()?
  authz.relation<Folder>("editor")?
  authz.relate("user:sara", "editor", "article:7") catch e {
    println(e.message())
  }
}
```

This prints `invalid policy: object type is not a registered resource
(registered: folder)`. The message names the part that is wrong and never
repeats the rejected text, which is untrusted and unbounded. A typo such as
`flder:launch` fails here instead of silently never matching.

## Asking whether Sara can edit

"Is Sara an editor of the launch folder?" is not one lookup. She may be
named by a tuple, or be a member of a team that is, or hold the folder
through a parent folder. `hasRelation` follows all of it:

```bit
import { Authz } from "authz"
import { Tabled } from "orm"

enum Action { Manage, Read, Create, Update, Delete, Publish }

@table class Folder {
  @id
  id: i64
  name: string
}

@table class Team {
  @id
  id: i64
  name: string
}

fn main(): ()! {
  let authz = Authz<Action>()?
  authz.resource<Folder>()?.resource<Team>()?
  authz.relation<Team>("member")?
  authz.relation<Folder>("parent")?
  authz.relation<Folder>("editor", inherit = "parent")?
  authz.relate("user:sara", "member", "team:eng")?
  authz.relate("team:eng#member", "editor", "folder:q3")?
  authz.relate("folder:q3", "parent", "folder:launch")?
  println("${authz.hasRelation("user:sara", "editor", "folder:launch")?}")
  println("${authz.hasRelation("user:bob", "editor", "folder:launch")?}")
}
```

This prints `true`, then `false`. Sara is a member of `eng`; `eng`'s members
edit `q3`; and `q3` is the parent of `launch`, which is why she edits it.

`inherit = "parent"` is the whole rewrite language: whoever is `editor` of an
object's `parent` is `editor` of the object. It applies to the relation that
declares it, so `viewer`, declared without `inherit`, is not inherited. Declare
`parent` before the relation that inherits through it.

## When the check cannot finish

A check walks a graph someone else wrote, so it has bounds, and each is an
option on `Authz`:

| Option | Default | Stops |
| ------ | ------- | ----- |
| `maxDepth` | 8 | hops from the object to the subject |
| `maxVisited` | 10,000 | distinct `object#relation` nodes |
| `maxFanout` | 10,000 | subjects read from one node, 1,000 at a time |

A cycle is not a bound: every node is read once, so folders that are each
other's parent end the walk with `false`. Reaching a bound without finding the
subject is not `false` either, because the walk did not look everywhere. It
fails with a `RelationLimit` that names the bound, and a caller that cannot
answer treats that as not related:

```bit
import { Authz } from "authz"
import { Tabled } from "orm"

enum Action { Manage, Read, Create, Update, Delete, Publish }

@table class Folder {
  @id
  id: i64
  name: string
}

fn canEdit(authz: Authz<Action>, who: string, folder: string): bool {
  let yes = authz.hasRelation(who, "editor", folder) catch e {
    println("refused: ${e.message()}")
    return false
  }
  return yes
}

fn main(): ()! {
  let authz = Authz<Action>(maxDepth = 2)?
  authz.resource<Folder>()?
  authz.relation<Folder>("parent")?
  authz.relation<Folder>("editor", inherit = "parent")?
  authz.relate("folder:q3", "parent", "folder:launch")?
  authz.relate("folder:2026", "parent", "folder:q3")?
  authz.relate("folder:root", "parent", "folder:2026")?
  authz.relate("user:sara", "editor", "folder:root")?
  authz.relate("user:ada", "editor", "folder:2026")?
  println("${canEdit(authz, "user:ada", "folder:launch")}")
  println("${canEdit(authz, "user:sara", "folder:launch")}")
}
```

This prints `true`: Ada is two hops from `launch`. Then it prints `refused:
relationship check stopped at maxDepth 2; treated as not related` and
`false`: Sara is three hops away. Raise `maxDepth` when your folders really
nest that deep. The error is a 500, which `pkg/web` logs and never sends; the
message tells you which bound to raise. A subject found before or beside a
bound still answers `true`, and a store that cannot be reached fails the check
with the store's own error: the answer is never guessed.

## Where tuples live

`Authz` keeps tuples in a `MemoryRelationStore`, which dies with the process.
A `RelationStore` is anything with `write`, `delete`, `has`, `direct`, `list`
and `version`, so a database can stand in. Writes are idempotent, and
`version` moves only when something really changed, which is what lets a cache
of answers know it went stale:

```bit
import { MemoryRelationStore, RelationStore, Tuple } from "authz"
import { join } from "std/strings"

fn grant(store: RelationStore, who: string, folder: string): ()! {
  store.write(Tuple{ subject = who, relation = "editor", object = folder })?
}

fn main(): ()! {
  let store = MemoryRelationStore()
  grant(store, "user:sara", "folder:launch")?
  grant(store, "user:sara", "folder:launch")?
  grant(store, "user:ada", "folder:launch")?
  grant(store, "user:bob", "folder:launch")?
  println("version ${store.version()?}")
  println(join(store.direct("folder:launch", "editor", 0, 2)?, ", "))
  println(join(store.direct("folder:launch", "editor", 2, 2)?, ", "))
  let sara = Tuple{ subject = "user:sara", relation = "editor", object = "folder:launch" }
  println("${store.has(sara)?}")
  for t of store.list("user:sara")? {
    println("${t.subject} is ${t.relation} of ${t.object}")
  }
}
```

This prints `version 3`, then the first page `user:sara, user:ada`, then the
second page `user:bob`, then `true`, then Sara's one tuple: the repeated write
changed nothing. `direct` lists the subjects holding a relation on an object,
oldest first, `limit` of them from `offset`; the check reads it in pages of at
most 1,000, so a store never has to hand over a whole group at once. `has`
asks for one exact tuple, and `list` lists the tuples one subject holds. A
store trusts its input; `Authz` is what validates, so write through `relate`,
not through the store, when the strings are not yours.
`MemoryRelationStore(capacity = n)` bounds it: a write past `n` tuples fails
instead of growing without limit (default 100,000).

## Policies that ask about the folder

A tuple answers a question about two names. Editing an article is a question
about a row, so a policy needs the row to point at the folder. `related`
is the condition for that: `Update` is allowed when the asking user is an
`editor` of the object the row names. For the folder itself the row names
itself, and the condition is `{ id: related("editor") }`; a condition literal
lowers to std/where's `Clause`, whose value slot `related("editor")` fills,
and `fromWhere` turns the clause into a condition:

```bit
import { Authz, Policy, Subject, fromWhere, related } from "authz"
import { Tabled } from "orm"
import { Clause, Op, Where } from "std/where"

enum Action { Manage, Read, Create, Update, Delete, Publish }

@table class Folder {
  @id
  id: i64
  name: string
}

class Member {
  export id: string,
  export roles: []string,
}

fn main(): ()! {
  let authz = Authz<Action>()?
  authz.resource<Folder>()?
  authz.relation<Folder>("editor")?
  let mine = Clause("id", Op.Eq, [related("editor")])?
  let cond = fromWhere<Folder>(Where<Folder>(clauses = [mine]))?
  let editFolder = Policy<Member, Action>("EditFolder", (p, user) => {
    p.can<Folder>([Action.Update], cond)
  })
  authz.role<Member>("member", [editFolder])?
  authz.relate("user:sara", "editor", "folder:1")?
  let launch = Folder{ id = 1, name = "launch" }
  let sara = Option<Subject>.Some(Member{ id = "sara", roles = ["member"] })
  let tom = Option<Subject>.Some(Member{ id = "tom", roles = ["member"] })
  println("${authz.can<Folder>(sara, Action.Update, launch)}")
  println("${authz.can<Folder>(tom, Action.Update, launch)}")
}
```

This prints `true`, then `false`. The folder's `id` made the object
`folder:1`, the user is `user:sara`, and the answer is `hasRelation`'s, so
usersets and `inherit` count: whoever edits a parent folder edits this one.
Roles play no part in it; they are what chose the policy.

An article does not name itself, it names a folder. Its foreign key column
`folderId` is what points there, and `{ folder: related("editor") }` on a
`@belongsTo("folderId")` relation field means exactly that: build the object
from the column, `folder:<folderId>`. `fromWhere` resolves the field to
`Cond.Related(column, target, relation)` once, when the policy is built, and
`Cond.Related` is the same condition written out:

```bit
import { Authz, Cond, Policy, Subject } from "authz"
import { Tabled } from "orm"

enum Action { Manage, Read, Create, Update, Delete, Publish }

@table class Folder {
  @id
  id: i64
  name: string
}

@table class Article {
  @id
  id: i64
  title: string
  folderId: Option<i64>
}

class Member {
  export id: string,
  export roles: []string,
}

fn main(): ()! {
  let authz = Authz<Action>()?
  authz.resource<Folder>()?.resource<Article>()?
  authz.relation<Folder>("parent")?
  authz.relation<Folder>("editor", inherit = "parent")?
  let editShared = Policy<Member, Action>("EditShared", (p, user) => {
    p.can<Article>([Action.Update], Cond.Related("folderId", "Folder", "editor"))
  })
  authz.role<Member>("member", [editShared])?
  authz.relate("user:sara", "editor", "folder:1")?
  authz.relate("folder:1", "parent", "folder:2")?
  let sara = Option<Subject>.Some(Member{ id = "sara", roles = ["member"] })
  let inFolder1 = Article{ id = 7, title = "Launch notes", folderId = Option<i64>.Some(1) }
  let inFolder2 = Article{ id = 8, title = "Q3 plan", folderId = Option<i64>.Some(2) }
  let inFolder9 = Article{ id = 9, title = "Elsewhere", folderId = Option<i64>.Some(9) }
  let loose = Article{ id = 10, title = "Loose", folderId = Option<i64>.None }
  println("${authz.can<Article>(sara, Action.Update, inFolder1)}")
  println("${authz.can<Article>(sara, Action.Update, inFolder2)}")
  println("${authz.can<Article>(sara, Action.Update, inFolder9)}")
  println("${authz.can<Article>(sara, Action.Update, loose)}")
  println("${authz.can<Article>(Option<Subject>.None, Action.Update, inFolder1)}")
}
```

This prints `true`, `true`, `false`, `false`, `false`. Sara edits an article
of her folder and, through `parent`, of the folder above it. Folder 9 has no
tuple. The loose article has a NULL `folderId`, so the condition is unknown,
which, as everywhere, does not match. A guest is `None` and never relates.

`validatePolicy` and `role` refuse the mistakes at startup: a target that was
never registered, a relation it does not declare, a column that is not text or
an integer, and a `related` on a field that is neither a `@belongsTo`
relation (or its column) nor the `@id`, or on a `@belongsTo` or `@id` of several
columns. The last two are found when `fromWhere` resolves the field, so they
fail there, with an `InvalidPolicy` that names the field.

When the check cannot answer, a rule fails closed. A bound reached by an
allow rule (`RelationLimit`) means that rule does not match, and a warning
record says which policy and bound; a bound reached by a `cannot` rule refuses,
because a refusal that did not match could let an allow through. A relationship
store that cannot be reached refuses the request: `can` answers `false`, and
`check` fails with `StoreUnavailable`.

## Sharp edges

- `related` is a direct lookup; `hasRelation` follows usersets and
  `inherit`. Use `hasRelation` to answer "can she?".
- `relate`, `unrelate`, `related` and `hasRelation` all validate, so asking
  about an unknown type or an undeclared relation is an `InvalidPolicy` too,
  not `false`.
- Types are case-sensitive: `folder:launch`, never `Folder:launch`.
- A `related` condition answers `can` and `check`. Listing rows through it
  (`compileSql`, `filterFor` into a query) is refused until it compiles to SQL.
- `related("editor")` the condition and `authz.related(subject, relation,
  object)` the direct lookup are different things with one name.
- Each step of a chain such as `authz.relation<Folder>("a")?.relation<Folder>("b")?`
  carries its own `?`.

## Next

[Deciding](decisions.md) has `can` and `check`, which these policies answer.
