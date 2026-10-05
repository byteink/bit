# Relationships

Inkwell lets authors group articles into folders, and the launch folder is
edited by Sara and by everyone on the engineering team. "Sara may edit this
article" is not something you can write as a condition on the article: the
fact lives between a person and a folder. `authz` keeps such facts as
relationship tuples, plain data you write at runtime and read back.

<!-- doctest: per-block -->

## The simplest thing that works

A tuple says "this subject is a `relation` of that object". Register the class
the object belongs to, then `relate`:

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
  authz.relate("user:sara", "editor", "folder:launch")?
  println("${authz.related("user:sara", "editor", "folder:launch")?}")
  authz.unrelate("user:sara", "editor", "folder:launch")?
  println("${authz.related("user:sara", "editor", "folder:launch")?}")
}
```

This prints `true`, then `false`. The three strings are always in the order
subject, relation, object. `related` answers for exactly the tuple you wrote.

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
  authz.relate("team:eng#member", "editor", "folder:launch")?
  println("${authz.related("team:eng#member", "editor", "folder:launch")?}")
  println("${authz.related("user:sara", "editor", "folder:launch")?}")
}
```

`team:eng#member` is a userset: everyone who is a `member` of team `eng`.
Groups and folder inheritance are made of these. `related` is direct only, so
this prints `true`, then `false`: Sara is not named by the tuple, and
`related` does not expand the team.

## What is refused

Tuples usually arrive from an admin endpoint, so every part is checked before
anything is stored, and a bad one is an `InvalidPolicy`:

- the relation is `[a-z][a-z0-9_]{0,31}`;
- an id is 1 to 128 printable ASCII bytes with no space, `:` or `#`;
- the object's type, and the subject's unless it is `user`, is a registered
  resource;
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
  authz.relate("user:sara", "editor", "article:7") catch e {
    println(e.message())
  }
}
```

This prints `invalid policy: object type is not a registered resource
(registered: folder)`. The message names the part that is wrong and never
repeats the rejected text, which is untrusted and unbounded. A typo such as
`flder:launch` fails here instead of silently never matching.

## Where tuples live

`Authz` keeps tuples in a `MemoryRelationStore`, which dies with the process.
A `RelationStore` is anything with `write`, `delete`, `direct`, `list` and
`version`, so a database can stand in. Writes are idempotent, and `version`
moves only when something really changed, which is what lets a cache of
answers know it went stale:

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
  println("version ${store.version()?}")
  println(join(store.direct("folder:launch", "editor")?, ", "))
  for t of store.list("user:sara")? {
    println("${t.subject} is ${t.relation} of ${t.object}")
  }
}
```

This prints `version 2`, then `user:sara, user:ada`, then Sara's one tuple:
the repeated write changed nothing. `direct` lists the
subjects holding a relation on an object, oldest first, and `list` lists the
tuples one subject holds. A store trusts its input; `Authz` is what validates,
so write through `relate`, not through the store, when the strings are not
yours. `MemoryRelationStore(capacity = n)` bounds it: a write past `n` tuples
fails instead of growing without limit (default 100,000).

## Sharp edges

- `related` is a direct lookup. Following `team:eng#member` to its members is
  the relationship check that comes next.
- `relate`, `unrelate` and `related` all validate, so asking about an unknown
  type is an `InvalidPolicy` too, not `false`.
- Types are case-sensitive: `folder:launch`, never `Folder:launch`.

## Next

Policies can then ask whether a subject is an `editor` of a row's folder.
