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
  let editOwn: Policy<User, Action> = Policy("EditOwnArticles", (p, user) => {
    p.can<Article>([Action.Read, Action.Update], eq("authorId", Value.Text(user.id)))
    p.cannot<Article>([Action.Update], eq("status", Value.Text("archived")))
  })
  let mira = User{ id = "mira", roles = []string(0) }
  for r of editOwn.rulesFor(mira) {
    println("${word(r.effect)} ${len(r.actions)} action(s)")
  }
}
```

The annotation on `editOwn` is what tells `Policy` its user and action types,
so `(p, user)` needs no types of its own. Without an annotation, write them
on the call: `Policy<User, Action>("EditOwnArticles", ...)`.

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

## Roles bundle policies

Inkwell has three kinds of people: readers, authors and admins. Nobody should
list policies per user; a role is a name for a list of them, and a user's
`roles` say which lists apply. Register the resources first, then each role:

```bit
import { Authz, Policy, eq } from "authz"
import { Tabled } from "orm"
import { Value } from "std/sql"
import { join } from "std/strings"

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

fn readPublished(): Policy<User, Action> {
  return Policy("ReadPublished", (p, user) => {
    p.can<Article>([Action.Read], eq("status", Value.Text("published")))
  })
}

fn editOwn(): Policy<User, Action> {
  return Policy("EditOwnArticles", (p, user) => {
    p.can<Article>([Action.Read, Action.Update], eq("authorId", Value.Text(user.id)))
  })
}

fn manageAll(): Policy<User, Action> {
  return Policy("ManageAll", (p, user) => {
    p.canAll([Action.Manage])
  })
}

fn main(): ()! {
  let authz = Authz<Action>()?
  authz.resource<Article>()?
  authz.role<User>("reader", [readPublished()])?
  authz.role<User>("author", [readPublished(), editOwn()])?
  let ada = User{ id = "ada", roles = ["admin"] }
  authz.role<User>("admin", [manageAll()], probe = Option<User>.Some(ada))?
  println(join(authz.roleNames(), ", "))
}
```

This prints `admin, author, reader`. `role` returns the handle, so the calls
chain, each with its own `?`. A role name is 1 to 64 characters of letters,
digits, `_`, `.` and `-`, because stored attachments refer to it; a name used
twice fails with `invalid policy: role author defined twice`. `guest` is an
ordinary name here. Every policy is checked when its role is registered, as
`validatePolicy` checks it, so a typo stops the app at startup. The sample
user the policy is run for is a user with every field empty; `probe`, as on
`admin` above, passes a real one to check the branch it takes.

A policy's name is its identity: `ReadPublished` in two roles is one policy.

## What a user's roles give them

`rolesOf(user)` reads `user.roles` and returns the union of those roles'
policies, each policy once, in the order the roles list them:

```bit
import { Authz, Policy, eq } from "authz"
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

fn main(): ()! {
  let readPublished = Policy<User, Action>("ReadPublished", (p, user) => {
    p.can<Article>([Action.Read], eq("status", Value.Text("published")))
  })
  let editOwn = Policy<User, Action>("EditOwnArticles", (p, user) => {
    p.can<Article>([Action.Read, Action.Update], eq("authorId", Value.Text(user.id)))
  })
  let authz = Authz<Action>()?
  authz.resource<Article>()?
  authz.role<User>("reader", [readPublished])?
  authz.role<User>("author", [readPublished, editOwn])?
  let mira = User{ id = "mira", roles = ["reader", "author", "intern"] }
  let got = authz.rolesOf(mira)
  println("${len(got.rules)} rules, ${len(got.skipped)} skipped: ${got.skipped[0]}")
}
```

This prints `2 rules, 1 skipped: role intern is not defined`. `ReadPublished`
comes in once although two roles list it. A role nothing defines gives no
rules, so a user can only lose access to a mistake, and the reason is in
`skipped` for the server log. A user of another class than the policy was
written for gets no rules from that policy and a line in `skipped` too.

To catch a role nothing defines before any request, list the roles your
identity provider can issue at startup:

```bit
import { Authz } from "authz"

enum Action { Manage, Read, Create, Update, Delete, Publish }

fn main() {
  let authz = Authz<Action>() catch e {
    panic(e.message())
  }
  authz.checkRoles(["reader"]) catch e {
    println(e.message())
  }
}
```

This prints `invalid policy: unknown role reader (defined: )`: here nothing
was registered. With the three roles above it passes.

## Policies as data

An admin who cannot deploy code writes the same policy as a document. A
`PolicyDoc` is a name and statements; each statement has an `effect`
(`"allow"` or `"deny"`), `actions` by variant name, a `resource` by class name
(or `"*"` for all) and an optional `when`, the JSON of [Conditions](conditions.md)
or CEL text. `validateDoc` checks it against what is registered and returns the
same `Rule`s `p.can` would have recorded:

```bit
import { Authz, PolicyDoc, Statement } from "authz"
import { Tabled } from "orm"
import { jsonParse } from "std/json"

enum Action { Manage, Read, Create, Update, Delete, Publish }

@table class Article {
  @id
  id: i64
  team: string
  status: string
}

fn main() {
  let authz = Authz<Action>() catch e {
    panic(e.message())
  }
  authz.resource<Article>() catch e {
    panic(e.message())
  }
  let when = jsonParse("{ \"team\": \"$user.team\", \"status\": \"review\" }") catch e {
    panic(e.message())
  }
  let doc = PolicyDoc{
    name = "PublishOwnTeam",
    statements = [
      Statement{ effect = "allow", actions = ["Publish"], resource = "Article", when = when },
    ],
  }
  let compiled = authz.validateDoc(doc) catch e {
    panic(e.message())
  }
  println("${compiled.name}: ${len(compiled.rules)} rule")
  let typo = PolicyDoc{
    name = "PublishOwnTeam",
    statements = [
      Statement{ effect = "allow", actions = ["Publsh"], resource = "Article", when = when },
    ],
  }
  let _ = authz.validateDoc(typo) catch e {
    println(e.message())
    return
  }
}
```

This prints `PublishOwnTeam: 1 rule`, then `invalid policy:
/statements/0/actions/0: unknown action 'Publsh'; valid actions: Manage, Read,
Create, Update, Delete, Publish`. Every refusal starts with the
[JSON Pointer](https://www.rfc-editor.org/rfc/rfc6901) of the fault in the
document, so an admin's form can mark the field. The limits are fixed: a name is
1 to 64 characters of letters, digits, `_`, `.` and `-`; a policy holds 1 to 64
statements; a document holds at most 64 KiB (the whole document is `#` in a
pointer). `"*"` is a resource, never an action: to grant every action the
statement names `Manage`.

An `Attachment` says who gets a stored policy: `policy`, `to` (a `Target` with
exactly one of `role`, `group` or `user`) and `tenant` (empty is global).
`authz.validateAttachment(a)` checks the names the same way; that the policy
exists is the store's check.

## Sharp edges

- `Policy`'s type arguments come from the type the policy is written
  against: an annotated `let`, a function's declared result, an argument of
  a function or method that is not generic, or an element of a list in any of
  those. With none of these the arguments are written out,
  `Policy<User, Action>(...)`, or the closure's parameters are annotated
  (`(p: Rules<Action>, user: User) => ...`); with plain `(p, user)` and no
  type to read them from, the compiler asks for them (E0068).
- The resource is a type argument, `p.can<Article>(...)`. `Article` must be a
  `@table` class; a plain class is refused at compile time.
- `can` and `cannot` only record rules. Deny-wins and default-deny are
  applied when you ask, by `authz.can` (the [Deciding](decisions.md) chapter).
- Roles come from `user.roles` alone. Policies attached to one user directly
  arrive with stored policies; `validateDoc` and `validateAttachment` check
  their documents today.

## Next

Policies and roles answer questions in [Deciding](decisions.md):
`authz.can(user, action, thing)` builds on the `Rule` list `rolesOf` returns.
