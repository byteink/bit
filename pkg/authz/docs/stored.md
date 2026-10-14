# Stored policies

Every rule so far lives in the code, so changing one means a deploy. Inkwell's
editor-in-chief wants to let authors on the news team publish their own
articles that are in review, and to take it away again next month, without
asking anyone to ship anything. That rule is a stored policy: a document an
admin saves, that the package validates and keeps, and that `can` reads next to
the policies written in code.

<!-- doctest: per-block -->

## The simplest thing that works

An admin posts a JSON document. `savePolicy` checks it and stores it, `attach`
says who it is for, and from then on `can` knows about it:

```bit
import { Authz, Attachment, PolicyDoc, Subject, Target } from "authz"
import { Tabled } from "orm"
import { jsonDecodeText } from "std/json"

enum Action { Manage, Read, Create, Update, Delete, Publish }

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

const publishOwnTeam: string = "{ \"name\": \"PublishOwnTeam\", \"statements\": [ { \"effect\": \"allow\", \"actions\": [\"Publish\"], \"resource\": \"Article\", \"when\": { \"team\": \"$user.team\", \"status\": \"review\" } } ] }"

fn main(): ()! {
  let authz = Authz<Action>()?
  authz.resource<Article>()?
  let mira = Option<Subject>.Some(User{ id = "mira", roles = ["author"], team = "news" })
  let piece = Article{ id = 1, team = "news", status = "review" }
  println("before: ${authz.can<Article>(mira, Action.Publish, piece)}")
  authz.savePolicy(jsonDecodeText<PolicyDoc>(publishOwnTeam)?)?
  authz.attach(
    Attachment{
      policy = "PublishOwnTeam",
      to = Target{ role = Option<string>.Some("author") },
      tenant = "",
    },
  )?
  println("after: ${authz.can<Article>(mira, Action.Publish, piece)}")
}
```

This prints `before: false` and `after: true`. The document is the one an
endpoint would receive, `jsonDecodeText<PolicyDoc>` is how it becomes a
`PolicyDoc`, and `"$user.team"` is the same placeholder a code policy writes as
`user.team`. Nothing about `author` is defined in code: a role needs no
definition to receive a stored policy.

The next answers, for the same Mira, are `false` for an article of another team
and `false` for one that is still a draft: the document says both.

## Save a condition built in code

Inkwell can let an editor build the same condition with CEL before saving it.
`condToJson` turns that resource-valid `Cond` into the JSON value a statement's
`when` field stores; `condFromJson` reads it back against the same resource.

```bit
import { Authz, condFromCel, condFromJson, condToJson } from "authz"
import { Tabled } from "orm"
import { jsonEncode } from "std/json"

enum Action { Manage, Read, Create, Update, Delete, Publish }

@table class Article {
  @id
  id: i64
  team: string
  status: string
}

fn main(): ()! {
  let authz = Authz<Action>()?
  authz.resource<Article>()?
  let article = unwrap(authz.resourceByName("Article"))
  let condition = condFromCel(article, "resource.team == user.team && resource.status == 'review'")?
  let stored = condToJson(condition)?
  println(jsonEncode(stored))
  let _ = condFromJson(article, stored)?
}
```

This prints `{"status":"review","team":"$user.team"}`. Distinct field names
are merged and sorted, so the same condition produces stable JSON bytes.
Repeated fields stay in `$and`; `$or` and `$not` keep their child order.
A literal string starting with `$` gets one extra `$`, while a user placeholder
keeps its `$user.` prefix. Null predicates keep their `null` form. Relationship
targets come from the resource metadata when the document is read back.

The input must already fit its resource, as a condition parsed from CEL does.
`condToJson` has no resource argument and cannot validate column names or the
relationship target. It refuses `Known`, code-bearing `Custom`, byte literals,
literal `Value.Null`, non-finite floats and malformed operands with
`InvalidPolicy`. The tree is limited to 16 levels and 256 nodes; the emitted
JSON also stays within the decoder's 256-node budget.

## What save refuses

`savePolicy` and `attach` are meant to sit behind an admin endpoint, so their
input is untrusted: a document is read against the registered resources and the
enum, bounded in size, and every refusal is an `InvalidPolicy` whose message
starts with the JSON Pointer of the fault. The [Policies](policies.md) chapter's
`validateDoc` is what runs; nothing is stored when it fails.

```bit
import { Authz, Attachment, PolicyDoc, Statement, Target } from "authz"
import { Tabled } from "orm"
import { jsonParse } from "std/json"

enum Action { Manage, Read, Create, Update, Delete, Publish }

@table class Article {
  @id
  id: i64
  status: string
}

fn main(): ()! {
  let authz = Authz<Action>()?
  authz.resource<Article>()?
  let typo = PolicyDoc{
    name = "PublishReviewed",
    statements = [
      Statement{
        effect = "allow",
        actions = ["Publsh"],
        resource = "Article",
        when = jsonParse("null")?,
      },
    ],
  }
  authz.savePolicy(typo) catch e {
    println(e.message())
  }
  let ghost = Attachment{
    policy = "PublishReviewed",
    to = Target{ role = Option<string>.Some("author") },
    tenant = "",
  }
  authz.attach(ghost) catch e {
    println(e.message())
  }
  println("stored: ${isSome(authz.policy("PublishReviewed")?)}")
}
```

The first message points at `/statements/0/actions/0` and lists the valid
actions; the second says no stored policy is called `PublishReviewed`, because
an attachment names a policy that was saved, and the typo was never saved. The
last line prints `stored: false`.

## Roles, groups and one user

`to` has exactly one of three keys. A role is a name in `Subject.roles`. A group
is a role spelled `group:<name>` there, so an identity provider that already
lists groups as roles needs nothing more and `Subject` gains no member;
`to.group = "editors"` is for a subject whose roles hold `group:editors`. A user
is the subject whose `id` it is:

```bit
import { Authz, Attachment, PolicyDoc, Statement, Subject, Target } from "authz"
import { Tabled } from "orm"
import { jsonParse } from "std/json"

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

fn grant(authz: Authz<Action>, to: Target): ()! {
  authz.attach(Attachment{ policy = "PublishAny", to = to, tenant = "" })?
}

fn main(): ()! {
  let authz = Authz<Action>()?
  authz.resource<Article>()?
  let any = Statement{
    effect = "allow",
    actions = ["Publish"],
    resource = "Article",
    when = jsonParse("null")?,
  }
  authz.savePolicy(PolicyDoc{ name = "PublishAny", statements = [any] })?
  grant(authz, Target{ group = Option<string>.Some("editors") })?
  grant(authz, Target{ user = Option<string>.Some("sara") })?
  let piece = Article{ id = 1, status = "review" }
  let eve = Option<Subject>.Some(User{ id = "eve", roles = ["group:editors"] })
  let sara = Option<Subject>.Some(User{ id = "sara", roles = [] })
  let zed = Option<Subject>.Some(User{ id = "zed", roles = ["editors"] })
  println(
    "${authz.can<Article>(eve, Action.Publish, piece)} ${authz.can<Article>(
      sara,
      Action.Publish,
      piece,
    )} ${authz.can<Article>(zed, Action.Publish, piece)}",
  )
}
```

This prints `true true false`. Zed holds a role called `editors`, which is not
the group, so the group's attachment does not reach him. The guest, the absent
subject, gets the policies attached to the role `guest`.

## Taking it away

`detach` undoes `attach` and a cached subject sees it on its next check.
Attaching what is attached, detaching what is not, and saving a document equal
to the stored one are all no-ops: they change nothing and do not disturb any
cached rule.

```bit
import { Authz, Attachment, PolicyDoc, Statement, Subject, Target } from "authz"
import { Tabled } from "orm"
import { jsonParse } from "std/json"

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
  let authz = Authz<Action>()?
  authz.resource<Article>()?
  let any = Statement{
    effect = "allow",
    actions = ["Publish"],
    resource = "Article",
    when = jsonParse("null")?,
  }
  authz.savePolicy(PolicyDoc{ name = "PublishAny", statements = [any] })?
  let att = Attachment{
    policy = "PublishAny",
    to = Target{ role = Option<string>.Some("author") },
    tenant = "",
  }
  authz.attach(att)?
  let mira = Option<Subject>.Some(User{ id = "mira", roles = ["author"] })
  let piece = Article{ id = 1, status = "review" }
  println("attached: ${authz.can<Article>(mira, Action.Publish, piece)}")
  authz.detach(att)?
  println("detached: ${authz.can<Article>(mira, Action.Publish, piece)}")
  let doc = authz.policy("PublishAny")?
  println("still saved: ${isSome(doc)}")
}
```

This prints `attached: true`, `detached: false` and `still saved: true`:
`policy(name)` reads a document back as it was saved, and detaching leaves it
for the next attachment.

## Beside the policies in code

A subject's rules are the policies of its roles written in code, then the
stored policies attached to those roles, to its groups, and to the subject
itself. The decision over all of them is the one [Deciding](decisions.md) has:
an explicit deny from any source beats any allow, an allow needs a matching
rule, and no match is a refusal. This is the order AWS IAM documents for its
policies ([policy evaluation logic](https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_policies_evaluation-logic.html):
explicit deny, then allow, then implicit deny) and CASL's. So an admin can
add a stored deny that stops a code allow, and cannot lift a code deny with a
stored allow. The order the sources are read in only decides which policy the
log names as the one that decided.

A policy has one name. `savePolicy` refuses a name a policy written in code
already has, and a code policy defined later under a stored policy's name wins:
the stored one is left out and `rolesOf` says so in `skipped`.

## Where they are kept

A document is compiled to rules once, when it is saved, and the compiled form is
what `can` reads: a check never parses a document. Saving a policy or changing a
global attachment drops every subject's cached rules, and each is rebuilt on its
next check; an attachment written for one tenant drops that tenant's only
([Tenants](tenants.md)). Rebuilding a subject whose class no role in code names costs a full
resolution on every check, so a stored-only app registers the class once with
`subject`:

```bit
import { Authz, MemoryStore, PolicyStore } from "authz"

enum Action { Manage, Read, Create, Update, Delete, Publish }

class User {
  export id: string,
  export roles: []string,
}

fn size(store: PolicyStore): int {
  let docs = store.policies() catch e {
    return -1
  }
  return len(docs)
}

fn main(): ()! {
  let authz = Authz<Action>()?
  authz.subject<User>()
  let tiny = MemoryStore(maxPolicies = 1)
  println("policies: ${size(tiny)}")
}
```

`Authz<Action>()` keeps its policies in a `MemoryStore`: they last as long as
the process, and a store holds `maxPolicies` documents and `maxAttachments`
attachments (10,000 and 100,000 unless asked) before a write that would add one
fails, so an endpoint cannot grow it without limit. `PolicyStore` is the
interface a store satisfies: `putPolicy`, `policy`, `policies`, `attach`,
`detach`, `attachments(tenant)`, `version` and `scopeVersion(tenant)`, with
writes that are idempotent and versions that grow on every real write. It
trusts what it is given;
`Authz` validates first. This program prints `policies: 0`.

## Keeping servers in step

Two servers share one store, and an admin saves a policy on server A. Server B
compiled its policies at startup and answers from them: until something tells
it, B keeps allowing what A just revoked. A check can't ask the store each
time, since that is a network call per `can`. So a handle reads the store's
versions in the background and reloads only what moved:

```bit
import { Authz, MemoryStore, PolicyStore, StoreOptions } from "authz"

enum Action { Manage, Read, Create, Update, Delete, Publish }

fn main(): ()! {
  let shared = MemoryStore()
  let options = StoreOptions(
    policyStore = Option<PolicyStore>.Some(shared),
    refreshEveryMs = 1000,
  )
  let authz = Authz<Action>(options = options)?
  authz.refresh() catch e {
    println("down: ${e.message()}")
  }
  authz.close()
  println("closed")
}
```

`refreshEveryMs` (5000 unless asked) is the longest another server's write can
go unseen. `refresh()` is the same step on demand: call it once after you have
registered your resources and roles, because a store that already holds
policies cannot be compiled before then and the handle answers every request
with a refusal until it has been. `close()` stops the poll; the handle keeps
what it has loaded. A handle on its own in-memory store (`Authz()`) has no
other writer and starts no poll.

A write through the handle does not wait for the poll: it reloads before it
returns, so the server that wrote is consistent at once. A save or a global
attachment rebuilds every subject's rules everywhere; an attachment for one
tenant rebuilds that tenant's only, and another tenant's cached rules stay
warm.

### When the store is down

If the store cannot answer the poll, the handle fails closed: `can` is
`false`, and `check` and `filterFor` fail with `StoreUnavailable` (a 503 in
`web`), for everyone, until a later refresh succeeds. Allowing on the strength
of a cache whose age is unknown would be the wrong default; OWASP's word for the
right one is "fail securely". The cause is logged once at ERROR when the
handle goes down and once at INFO when it comes back, not once per request. A
store call that hangs rather than fails is caught too: two intervals without a
successful refresh take the handle down the same way.

Inside one interval a warm handle keeps serving what it has, which is the
staleness window above. The first `forTenant("acme")` reads that tenant's
attachments once (and is a `StoreUnavailable` if it cannot); after that the
tenant is followed by the poll and a view costs no store call. At most
`maxTenants` (10,000) are followed, so a tenant name invented by a client cannot
grow the set: the next one is an `InvalidPolicy` naming the option.

### When one server cannot read a new policy

During a rolling deploy, a newer Inkwell server can save a policy for a resource
that an older server has not registered. The older server refuses every check
for the subjects attached to that policy. Other subjects keep their own grants.
This applies to both allow and deny policies: dropping an unreadable deny could
let another grant permit the operation.

```bit
import {
  Authz,
  Attachment,
  MemoryStore,
  PolicyDoc,
  PolicyStore,
  Statement,
  StoreOptions,
  Subject,
  Target,
} from "authz"
import { Tabled } from "orm"
import { jsonParse } from "std/json"

enum Action { Manage, Read, Create, Update, Delete, Publish }

@table class Article {
  @id
  id: i64
}

@table class Draft {
  @id
  id: i64
}

class User {
  export id: string,
  export roles: []string,
}

fn main(): ()! {
  let shared = MemoryStore()
  let options = StoreOptions(policyStore = Option<PolicyStore>.Some(shared), refreshEveryMs = 0)
  let older = Authz<Action>(options = options)?
  older.resource<Article>()?
  let newer = Authz<Action>(options = options)?
  newer.resource<Article>()?.resource<Draft>()?
  newer.savePolicy(
    PolicyDoc{
      name = "PublishArticles",
      statements = [
        Statement{
          effect = "allow",
          actions = ["Publish"],
          resource = "Article",
          when = jsonParse("null")?,
        },
      ],
    },
  )?
  newer.attach(
    Attachment{
      policy = "PublishArticles",
      to = Target{ role = Option<string>.Some("author") },
      tenant = "",
    },
  )?
  newer.savePolicy(
    PolicyDoc{
      name = "ProtectDrafts",
      statements = [
        Statement{
          effect = "deny",
          actions = ["Publish"],
          resource = "Draft",
          when = jsonParse("null")?,
        },
      ],
    },
  )?
  newer.attach(
    Attachment{
      policy = "ProtectDrafts",
      to = Target{ role = Option<string>.Some("author") },
      tenant = "",
    },
  )?
  older.refresh()?
  let mira = Option<Subject>.Some(User{ id = "mira", roles = ["author"] })
  let article = Article{ id = 1 }
  println("older: ${older.can<Article>(mira, Action.Publish, article)}")
  println("newer: ${newer.can<Article>(mira, Action.Publish, article)}")
  older.resource<Draft>()?
  println("registered: ${older.can<Article>(mira, Action.Publish, article)}")
}
```

This prints `older: false`, `newer: true` and `registered: true`. Registering the
missing resource or relation retries failed policies without a store write.
For an affected subject, `can` returns `false`; `check` and `filterFor` report an
`InvalidPolicy` naming the failed policy. Global attachments also apply inside
each tenant; tenant attachments affect that tenant alone. The guest follows the
attachments of the `guest` role. A failed stored policy still refuses its subjects
when a policy in code has the same name.

Each failed-policy transition produces one ERROR record. Repeated refreshes and
requests do not repeat it. `refresh` succeeds when the store can be read, even
when some policies cannot compile here; those failures remain attached to their
subjects until a later refresh or registration resolves them.

## Sharp edges

- An attachment with a `tenant` applies inside `authz.forTenant(tenant)` only;
  the plain handle sees the global ones (`tenant = ""`). [Tenants](tenants.md)
  has the views.
- The stored rules are rules like any other: `filterFor` folds them into the
  list filter, and a stored `when` is bound to the subject with `$user.x`.
- Names are 1 to 64 characters of `A-Z a-z 0-9 _ . -`, a document is at most 64
  KiB and 64 statements. `validateDoc` has the list.
- A `MemoryStore` is per process. Two servers each hold their own unless you
  hand both one with `StoreOptions(policyStore = ...)`, which is what a test of
  two servers does.

## Next

[Policies](policies.md) has the code-side `Policy` and `role`;
[Deciding](decisions.md) has `can`, `check` and `Denied`.
