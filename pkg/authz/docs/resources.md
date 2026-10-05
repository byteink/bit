# Resources

Inkwell has articles and folders, and a policy has to say which of them it
is about: "editors may update articles", "admins may manage everything". If a
policy names a resource with a string, `"Artcle"` matches nothing and nobody
notices. `authz` registers your `@table` classes as resources once at
startup, so a policy can only name something that exists.

<!-- doctest: per-block -->

## The simplest thing that works

Register each class the policies talk about, right after building the
handle:

```bit
import { Authz } from "authz"
import { Tabled } from "orm"

enum Action { Manage, Read, Create, Update, Delete, Publish }

@table class Article {
  @id
  id: i64
  title: string
  authorId: string
}

@table class Folder {
  @id
  id: i64
  name: string
}

fn main(): ()! {
  let authz = Authz<Action>()?
  authz.resource<Article>()?.resource<Folder>()?
  println("${len(authz.resourceNames())}")
}
```

`resource<T>()` returns the handle, so registrations chain. Each step has its
own `?`: registering can fail, and one `?` at the end of the chain does not
compile today (#7185).

## Names come from the class

A stored policy says `"resource": "Article"`. That is the class name as you
declared it, never the table name. Give a class its own table with
`@table("custom")` and the resource is still called by the class:

```bit
import { Authz, ResourceInfo } from "authz"
import { Tabled } from "orm"

enum Action { Manage, Read, Create, Update, Delete, Publish }

@table("posts") class Article {
  @id
  id: i64
  title: string
}

fn main(): ()! {
  let authz = Authz<Action>()?
  authz.resource<Article>()?
  let found: Option<ResourceInfo> = authz.resourceByName("Article")
  match (found) {
    Some(info) => println("${info.name} lives in table ${info.table}")
    None => println("not registered")
  }
}
```

This prints `Article lives in table posts`. `resourceByName` is how stored
policies, conditions and the SQL compiler find a resource; the `ResourceInfo`
it returns carries the `name`, the `table` a list filter queries and the
`columns` a condition may mention. Renaming the table later changes no stored
policy.

## Asking about a field

A condition such as `"authorId": "$user.id"` is only valid if the resource
has that field, and a numeric comparison only if the field is numeric.
`fieldType` answers with the type the compiler gave the column, or `None`:

```bit
import { Authz } from "authz"
import { Tabled } from "orm"

enum Action { Manage, Read, Create, Update, Delete, Publish }

@table class Article {
  @id
  id: i64
  title: string
}

fn main(): ()! {
  let authz = Authz<Action>()?
  authz.resource<Article>()?
  match (authz.fieldType("Article", "title")) {
    Some(t) => println("title is ${t}")
    None => println("no such field")
  }
  println("${isSome(authz.fieldType("Article", "slug"))}")
}
```

This prints `title is string`, then `false`: a policy that mentions `slug` is
refused when it is saved, not silently never matched.

## Naming a resource in a policy

`resourceRef<T>()` is the reference to one class, and `all` is the marker for
every resource. Both are values of `ResourceRef`, so a policy line such as
`p.can(Manage, all)` and `p.can(Read, Article)` have the same type:

```bit
import { ResourceRef, all, resourceRef } from "authz"
import { Tabled } from "orm"

@table class Article {
  @id
  id: i64
  title: string
}

fn label(r: ResourceRef): string {
  return match (r) {
    All => "every resource"
    Named(n) => "only ${n}"
  }
}

fn main() {
  println(label(all))
  println(label(resourceRef<Article>()))
}
```

## Sharp edges

- Only `@table` classes qualify. `authz.resource<Plain>()` on a class without
  `@table` is a compile error ("does not satisfy the bound 'Tabled'"):
  a check reads a row through its columns and a list filter needs the table,
  so a plain class could be neither.
- Registering the same class twice fails with `InvalidPolicy`
  (`resource Article registered twice`), so a copy-pasted line stops the app
  at startup.
- `resourceNames()` lists the registered names in alphabetical order, the form
  error messages use.

## Next

Policies say what a subject may do with a registered resource; roles bundle
them.
