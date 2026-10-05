# Deciding: can and check

Inkwell's handler for "update this article" had grown three `if`s: is the user
an admin, is it their own article, is it archived. The same three lived in the
delete handler, slightly different. The roles and policies of the last two
chapters exist so that one call answers it for every handler:
`authz.can(user, action, article)`.

<!-- doctest: per-block -->

## The simplest thing that works

Register the resources and roles once at startup, then ask:

```bit
import { Authz, Policy, Subject, eq } from "authz"
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
  let editOwn = Policy<User, Action>("EditOwnArticles", (p, user) => {
    p.can<Article>([Action.Read, Action.Update], eq("authorId", Value.Text(user.id)))
    p.cannot<Article>([Action.Update], eq("status", Value.Text("archived")))
  })
  let authz = Authz<Action>()?
  authz.resource<Article>()?
  authz.role<User>("author", [editOwn])?
  let mira = Option<Subject>.Some(User{ id = "mira", roles = ["author"] })
  let draft = Article{ id = 1, authorId = "mira", status = "draft" }
  let old = Article{ id = 2, authorId = "mira", status = "archived" }
  let mayEditDraft = authz.can<Article>(mira, Action.Update, draft)
  let mayEditOld = authz.can<Article>(mira, Action.Update, old)
  println("${mayEditDraft} ${mayEditOld}")
}
```

This prints `true false`. `can` takes the user as an `Option<Subject>`, the
action, and the row, and answers a `bool`: it never fails and never panics, so
it reads naturally in an `if`. The second answer is false because the
archived-article rule refuses and a refusal wins over any allow.

## The rules, in order

For one question `can` does what CASL does:

1. Collect the rules of the user's roles that name this resource (or `all`) and
   this action (or `Manage`, when the enum has one).
2. Bind `$user.x` placeholders to the user, then evaluate each condition on the
   row. Unknown (a NULL field) does not match.
3. Any matching `cannot` refuses. Otherwise any matching `can` allows.
   Otherwise the answer is no: nothing allows what no policy mentions.

## check, for handlers

A handler wants to stop, not to branch. `check` is `can` as a `()!`; the
failure is a `Denied` carrying a fixed "forbidden" text, so a client learns
nothing about which policy refused:

```bit
import { Authz, Policy, Subject } from "authz"
import { Tabled } from "orm"

enum Action { Manage, Read, Create, Update, Delete, Publish }

@table class Article {
  @id
  id: i64
  authorId: string
}

class User {
  export id: string,
  export roles: []string,
}

fn main(): ()! {
  let reader = Policy<User, Action>("ReadAll", (p, user) => {
    p.can<Article>([Action.Read])
  })
  let authz = Authz<Action>()?
  authz.resource<Article>()?
  authz.role<User>("reader", [reader])?
  let sam = Option<Subject>.Some(User{ id = "sam", roles = ["reader"] })
  let a = Article{ id = 1, authorId = "mira" }
  authz.check<Article>(sam, Action.Read, a)?
  authz.check<Article>(sam, Action.Update, a) catch e {
    println(e.message())
  }
}
```

This prints `forbidden`. Inside a handler that returns `()!` write
`authz.check<Article>(user, Action.Update, article)?` and pkg/web turns the
`Denied` into a 403.

## The guest

An anonymous request has no user: pass `Option<Subject>.None`. It gets the
role called `guest`, evaluated like anyone else, and with no such role every
answer is no. The `guest` policies are run once, at `role`, for the `probe`
user, since a guest has no attributes; a placeholder in a guest policy never
binds, so its comparison does not hold.

```bit
import { Authz, Policy, Subject, eq } from "authz"
import { Tabled } from "orm"
import { Value } from "std/sql"

enum Action { Manage, Read, Create, Update, Delete, Publish }

@table class Article {
  @id
  id: i64
  status: string
}

class User {
  export id: string,
  export roles: []string,
}

fn main(): ()! {
  let published = Policy<User, Action>("ReadPublished", (p, user) => {
    p.can<Article>([Action.Read], eq("status", Value.Text("published")))
  })
  let authz = Authz<Action>()?
  authz.resource<Article>()?
  authz.role<User>("guest", [published])?
  let live = Article{ id = 1, status = "published" }
  let draft = Article{ id = 2, status = "draft" }
  let nobody = Option<Subject>.None
  let readsLive = authz.can<Article>(nobody, Action.Read, live)
  let readsDraft = authz.can<Article>(nobody, Action.Read, draft)
  println("${readsLive} ${readsDraft}")
}
```

This prints `true false`.

## Logging the reason

The deciding policy never reaches the client, but you will want it. Give the
handle a sink, the one-method `LogSink` pkg/orm's `Logger` writes to, and every
decision logs a line with the action, resource, subject, outcome and policy:

```bit
import { Authz, Policy, Subject } from "authz"
import { Tabled } from "orm"

enum Action { Manage, Read, Create, Update, Delete, Publish }

@table class Article {
  @id
  id: i64
}

class User {
  export id: string,
  export roles: []string,
}

class Lines {
  export log(line: string) {
    println(line)
  }
}

fn main(): ()! {
  let lockedDown = Policy<User, Action>("NoDeletes", (p, user) => {
    p.cannot<Article>([Action.Delete])
  })
  let authz = Authz<Action>()?
  authz.resource<Article>()?
  authz.role<User>("staff", [lockedDown])?
  authz.logTo(Lines{})
  let sam = Option<Subject>.Some(User{ id = "sam", roles = ["staff"] })
  authz.can<Article>(sam, Action.Delete, Article{ id = 1 })
}
```

This prints `[authz] debug deny Delete on Article subject=sam policy=NoDeletes
reason=denied by rule`. With no sink nothing is logged and no line is built.

## A broken rule is not a quiet no

`validatePolicy` and `role` check a policy for one probe user, and a policy
may branch on the user. So `can` and `check` check every rule of the user's
roles too, once per policy and position, and remember the verdict. A rule with
no actions, a resource nothing registered or a condition that does not fit the
class makes `check` fail with an `InvalidPolicy` naming the policy and the
rule (`policy Branchy rule 1: no actions`) and `can` answer false. The
mistake is logged at ERROR the first time. It is a refusal, never a grant.

## Sharp edges

- `can` is false for a broken rule, so test your policies with `check` or
  watch the sink.
- A rule on `all` allows every resource, including ones you register later.
- The log line names the policy; it is for the server log only. `Denied`
  keeps the policy for `deciding()` and not for `message()`.
- The first check for a user runs the policy closures (`rolesOf`) and keeps
  the rules, indexed by resource and action. Every later check for a user of
  the same value reuses them, so a rule without a condition allocates
  nothing and one with a condition reads the row once. "Same value" means
  every field: a user whose `team` changed, in a fresh object or in place,
  gets the new team's rules. Registering a role or a resource rebuilds every
  user's rules on their next check. Up to 512 users' rules are kept; a user
  whose slot another took is rebuilt on the next check.
- A user class needs value semantics to be kept (strings, numbers, bools,
  enums, slices, maps, `Option`s and classes of those). A class with a
  function, an interface or a generic class field has its rules built on
  every call instead, which is correct and slower.

## Next

Rules become database filters in the list chapter, and relationships join the
decision once relationship rules land.
