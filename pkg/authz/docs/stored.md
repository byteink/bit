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
  authz.attach(Attachment{ policy = "PublishOwnTeam", to = Target{ role = Option<string>.Some("author") }, tenant = "" })?
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
      Statement{ effect = "allow", actions = ["Publsh"], resource = "Article", when = jsonParse("null")? },
    ],
  }
  authz.savePolicy(typo) catch e {
    println(e.message())
  }
  let ghost = Attachment{ policy = "PublishReviewed", to = Target{ role = Option<string>.Some("author") }, tenant = "" }
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
  let any = Statement{ effect = "allow", actions = ["Publish"], resource = "Article", when = jsonParse("null")? }
  authz.savePolicy(PolicyDoc{ name = "PublishAny", statements = [any] })?
  grant(authz, Target{ group = Option<string>.Some("editors") })?
  grant(authz, Target{ user = Option<string>.Some("sara") })?
  let piece = Article{ id = 1, status = "review" }
  let eve = Option<Subject>.Some(User{ id = "eve", roles = ["group:editors"] })
  let sara = Option<Subject>.Some(User{ id = "sara", roles = [] })
  let zed = Option<Subject>.Some(User{ id = "zed", roles = ["editors"] })
  println("${authz.can<Article>(eve, Action.Publish, piece)} ${authz.can<Article>(sara, Action.Publish, piece)} ${authz.can<Article>(zed, Action.Publish, piece)}")
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
  let any = Statement{ effect = "allow", actions = ["Publish"], resource = "Article", when = jsonParse("null")? }
  authz.savePolicy(PolicyDoc{ name = "PublishAny", statements = [any] })?
  let att = Attachment{ policy = "PublishAny", to = Target{ role = Option<string>.Some("author") }, tenant = "" }
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
what `can` reads: a check never parses a document. Saving, attaching or
detaching drops every subject's cached rules, and each is rebuilt on its next
check. Rebuilding a subject whose class no role in code names costs a full
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
`detach`, `attachments(tenant)` and `version`, with writes that are idempotent
and a `version` that grows on every real one. It trusts what it is given;
`Authz` validates first. This program prints `policies: 0`.

## Sharp edges

- An attachment with a `tenant` is stored, and applies to nobody until a
  tenant view exists; only the global ones (`tenant = ""`) apply today.
- The stored rules are rules like any other: `filterFor` folds them into the
  list filter, and a stored `when` is bound to the subject with `$user.x`.
- Names are 1 to 64 characters of `A-Z a-z 0-9 _ . -`, a document is at most 64
  KiB and 64 statements. `validateDoc` has the list.
- A `MemoryStore` is per process. Two servers each hold their own.

## Next

[Policies](policies.md) has the code-side `Policy` and `role`;
[Deciding](decisions.md) has `can`, `check` and `Denied`.
