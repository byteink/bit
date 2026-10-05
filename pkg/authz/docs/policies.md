# Policies

Inkwell's rule is short to say and easy to get wrong in code: "an author may
read and update their own articles, but nobody updates an archived one".
Written as `if` statements inside handlers, it is copied into every route and
drifts. A policy writes it once, as data the rest of `authz` can check, list
and explain.

<!-- doctest: per-block -->

## The simplest thing that works

A policy is a name and a function. The function receives `p`, where the rules
are written, and the user they are written for:

```bit
import { Authz, Policy, Rule, Rules, eq } from "authz"
import { Tabled } from "orm"
import { Value } from "std/sql"

enum Action { Manage, Read, Create, Update, Delete, Publish }

@table class Article {
  @id
  id: i64
  authorId: string
  status: string
}

class User {
  export id: string,
  export roles: []string,
}

fn main() {
  let editOwn = Policy<User, Action>("EditOwnArticles", (p, user) => {
    p.can<Article>([Action.Read, Action.Update], eq("authorId", Value.Text(user.id)))
  })
  let rules: []Rule<Action> = editOwn.rulesFor(User{ id = "mira", roles = []string(0) })
  println("${len(rules)} rule, from ${rules[0].policy}")
}
```

This prints `1 rule, from EditOwnArticles`. `p.can<Article>` takes the
resource as a type argument, a list of actions, and a condition (the same
`Cond` the conditions chapter builds). A single action is a one-element list:
`p.can<Article>([Action.Read])`. Left out, the condition is `Cond.True`, every
row. A `Rules<Action>` is only a recorder: nothing is checked while the
function runs.

`rulesFor(user)` runs the function for one user and returns what it wrote, in
order. The list for one user never leaks into another's: each call starts from
an empty `Rules`.

## Allow and deny

`p.can` allows and `p.cannot` refuses. A refusal is meant to win over any
allow, so "own articles, unless archived" is two rules:

```bit
import { Effect, Policy, eq } from "authz"
import { Tabled } from "orm"
import { Value } from "std/sql"

enum Action { Manage, Read, Create, Update, Delete, Publish }

@table class Article {
  @id
  id: i64
  authorId: string
  status: string
}

class User {
  export id: string,
  export roles: []string,
}

fn word(e: Effect): string {
  return match (e) {
    Allow => "allow"
    Deny => "deny"
  }
}

fn main() {
  let editOwn = Policy<User, Action>("EditOwnArticles", (p, user) => {
    p.can<Article>([Action.Read, Action.Update], eq("authorId", Value.Text(user.id)))
    p.cannot<Article>([Action.Update], eq("status", Value.Text("archived")))
  })
  let mira = User{ id = "mira", roles = []string(0) }
  for r of editOwn.rulesFor(mira) {
    println("${word(r.effect)} ${len(r.actions)} action(s)")
  }
}
```

This prints `allow 2 action(s)` then `deny 1 action(s)`. Listing several
actions in one `can` makes one rule holding all of them, not one rule each.
The policy reads the same for an admin and an author; what differs is the
user the function is run for.

## Every resource at once

Admins manage everything, and naming each class would break the day a new one
is registered. `canAll` and `cannotAll` take only actions and cover every
resource, which `all` is the marker for:

```bit
import { Policy, ResourceRef, all } from "authz"

enum Action { Manage, Read, Create, Update, Delete, Publish }

class User {
  export id: string,
  export roles: []string,
}

fn main() {
  let admin = Policy<User, Action>("Admin", (p, user) => {
    p.canAll([Action.Manage])
    p.cannotAll([Action.Delete])
  })
  let rules = admin.rulesFor(User{ id = "ada", roles = ["admin"] })
  let first: ResourceRef = rules[0].resource
  println("${len(rules)} rules, first on all: ${first == all}")
}
```

This prints `2 rules, first on all: true`. A condition on `all` may not name a
field, since the resources it covers do not share one.

## Checking a policy at startup

The function cannot fail, so a typo inside it is found later, when the policy
is registered. `validatePolicy` runs the policy for a sample user and checks
every rule against the registered resources. The error names the policy and
the rule's position, counting from 0:

```bit
import { Authz, Policy, eq } from "authz"
import { Tabled } from "orm"
import { Value } from "std/sql"

enum Action { Manage, Read, Create, Update, Delete, Publish }

@table class Article {
  @id
  id: i64
  authorId: string
}

@table class Folder {
  @id
  id: i64
  name: string
}

class User {
  export id: string,
  export roles: []string,
}

fn main(): ()! {
  let authz = Authz<Action>()?
  authz.resource<Article>()?
  let sample = User{ id = "mira", roles = []string(0) }
  let tidy = Policy<User, Action>("Tidy", (p, user) => {
    p.can<Article>([Action.Read])
    p.can<Folder>([Action.Read])
  })
  authz.validatePolicy<User>(tidy, sample) catch e {
    println(e.message())
  }
  let typo = Policy<User, Action>("Typo", (p, user) => {
    p.can<Article>([Action.Read], eq("owner", Value.Text(user.id)))
  })
  authz.validatePolicy<User>(typo, sample) catch e {
    println(e.message())
  }
}
```

This prints two lines: `invalid policy: policy Tidy rule 1: unknown
resource Folder (registered: Article)` and `invalid policy: policy Typo rule
0: no field owner (fields: id, authorId)`. A rule with an empty action list
fails the same way (`no actions`). Call `validatePolicy` for every policy
before the server starts, so a mistake stops the app instead of denying (or
granting) quietly at request time.

A policy that branches on the user is checked for the branch the sample takes;
pass a sample that reaches every `can` you want checked.

## Sharp edges

- Today the type arguments are written out: `Policy<User, Action>(...)`.
  They are inferred only when the closure's parameters are annotated
  (`(p: Rules<Action>, user: User) => ...`); with plain `(p, user)` the
  compiler asks for them (E0068). Inferring them from an expected type is
  tracked as #7299.
- The resource is a type argument, `p.can<Article>(...)`. `Article` must be a
  `@table` class; a plain class is refused at compile time.
- `can` and `cannot` record rules; nothing evaluates them yet. Deny-wins and
  default-deny are applied by the evaluation chapter's `authz.can`.

## Next

Policies become useful once roles bundle them and `authz.can(user, action,
thing)` answers for a user; both build on the `Rule` list this chapter
produces.
