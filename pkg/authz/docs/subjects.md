# Subjects

Inkwell's editors may publish articles, but only for their own team: the
desk editor for sport cannot publish a politics piece. Before any policy can
say that, it has to know who is asking and which team they belong to. `authz`
calls the asker the subject, and asks very little of it.

<!-- doctest: per-block -->

## The simplest thing that works

A subject is any class with an `id` and a list of `roles`. There is no base
class to extend and nothing to register; `Subject` is an interface the
compiler checks structurally:

```bit
import { Subject } from "authz"

class User {
  export id: string,
  export roles: []string,
}

fn describe(s: Subject): string {
  return "${s.id} has ${len(s.roles)} role(s)"
}

fn main() {
  println(describe(User{ id = "mira", roles = ["editor"] }))
}
```

The fields are `export`ed because `User` lives in your app and `Subject` in
`authz`; a field that is not exported satisfies the interface only inside its
own module. A class with `id: int`, or without `roles`, is refused at compile
time naming the field.

## Attributes a stored policy can name

A policy saved in the database cannot hold a closure, so it names the
subject's attributes instead. "An editor may update articles of their own
team" is stored with `"team": "$user.team"`, and `attributeOf` turns the
placeholder into a value:

```bit
import { attributeOf } from "authz"
import { jsonAsString } from "std/json"

@json class User {
  export id: string,
  export roles: []string,
  export team: string,
}

fn main() {
  let mira = User{ id = "mira", roles = ["editor"], team = "sport" }
  match (attributeOf(mira, "team")) {
    Some(v) => println("team: ${unwrapOr(jsonAsString(v), "?")}")
    None => println("no team")
  }
}
```

`id` and `roles` always resolve. Every other path is read from the class's
`toJson()`, which only exists when you write `@json` on it. Without `@json`
the language gives `authz` no way to see a field it has no name for, so any
other path is `None`. A dotted path such as `address.city` walks nested
`@json` classes; arrays are never indexed.

`None` is not an error. A condition that cannot read its attribute does not
match, so a typo in a stored placeholder denies instead of granting. Policies
written in code skip all this: the closure reads `user.team` directly.

## Joining pkg/auth

`pkg/auth` hands you an `Identity` with an `id` and a bag of `claims`. `authz`
does not import it, so your app converts once, in one function:

```bit
import { attributeOf } from "authz"
import { Json, JsonEntry, jsonAsString, jsonGet } from "std/json"

class Identity {
  id: string,
  claims: Json,
}

@json class User {
  export id: string,
  export roles: []string,
  export team: string,
}

fn claim(i: Identity, key: string): string {
  return match (jsonGet(i.claims, key)) {
    Some(v) => unwrapOr(jsonAsString(v), "")
    None => ""
  }
}

fn userOf(i: Identity): User {
  return User{ id = i.id, roles = ["editor"], team = claim(i, "team") }
}

fn main() {
  let claims = Json.JsonObject([JsonEntry{ key = "team", value = Json.JsonString("sport") }])
  let u = userOf(Identity{ id = "mira", claims = claims })
  match (attributeOf(u, "team")) {
    Some(v) => println("${u.id} is on ${unwrapOr(jsonAsString(v), "?")}")
    None => println("${u.id} has no team")
  }
}
```

`Identity` above stands in for the real one so the example runs alone; use
`pkg/auth`'s.

## No subject is the guest

A visitor who has not signed in is not a `User` with an empty id. Everywhere
an API takes a subject it takes `Option<Subject>`, and `None` is the guest.
There is no guest class to build or to forget to check; a policy for guests is
a policy that applies when the subject is absent.

## Sharp edges

- Forgetting `@json` makes every stored `$user.<field>` placeholder
  unresolvable, so the statement never matches. Add it to your user class.
- The attribute is the JSON key, which is the field name unless you rename it
  with `@key("...")`. Stored placeholders use the key.
- `attributeOf` never reads a field the class keeps out of `toJson`; only
  what you serialize can be named by a policy.
