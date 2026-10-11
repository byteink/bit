# Tenants

Inkwell now serves two publishers, Acme Press and Borealis. They share one
deployment and one set of policies, but each publisher decides for itself what
its own editors may do, and nothing one of them writes may show up in the
other's checks. A tenant view is how `Authz` keeps them apart: one handle for
the app, and per request a view of it for the publisher the request came from.

<!-- doctest: per-block -->

## The simplest thing that works

`forTenant` returns a view of the handle for one tenant. Policies are saved
once; an attachment says which tenant it is for, and `""` is every tenant:

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

fn allow(name: string, action: string): PolicyDoc! {
  let st = Statement{
    effect = "allow",
    actions = [action],
    resource = "Article",
    when = jsonParse("null")?,
  }
  return PolicyDoc{ name = name, statements = [st] }
}

fn attach(authz: Authz<Action>, policy: string, tenant: string): ()! {
  authz.attach(
    Attachment{
      policy = policy,
      to = Target{ role = Option<string>.Some("editor") },
      tenant = tenant,
    },
  )?
}

fn answers(authz: Authz<Action>, who: Option<Subject>, piece: Article): string {
  return "${authz.can<Article>(who, Action.Read, piece)} ${authz.can<Article>(
    who,
    Action.Publish,
    piece,
  )}"
}

fn main(): ()! {
  let authz = Authz<Action>()?
  authz.resource<Article>()?
  authz.savePolicy(allow("ReadAny", "Read")?)?
  authz.savePolicy(allow("PublishAny", "Publish")?)?
  attach(authz, "ReadAny", "")?
  attach(authz, "PublishAny", "acme")?
  let eve = Option<Subject>.Some(User{ id = "eve", roles = ["editor"] })
  let piece = Article{ id = 1, status = "review" }
  println("acme:    ${answers(authz.forTenant("acme")?, eve, piece)}")
  println("borealis: ${answers(authz.forTenant("borealis")?, eve, piece)}")
  println("no tenant: ${answers(authz, eve, piece)}")
}
```

This prints `acme:    true true`, `borealis: true false` and
`no tenant: true false`. Eve is an editor everywhere. `ReadAny` is attached
with `tenant = ""`, so it applies in every view and on the plain handle;
`PublishAny` is attached for `"acme"`, so it applies in Acme's view and nowhere
else. The plain handle, which is the tenant `""`, sees only the global
attachments, and a tenant with no attachments of its own sees those alone.

## One view per request

`forTenant` makes one small object over the same registry, rule cache and
stores, so it is cheap enough to build in the handler, from whatever the
request knows about its tenant:

```text
let mine = authz.forTenant(currentTenant(c))?
mine.check(user, Action.Update, article)?
```

A view reflects the handle as it is now: a policy saved or attached later shows
up in a view made earlier. Its checks are cached like the handle's, with the
tenant part of the key, so one person asking in two tenants gets each tenant's
answer. A tenant is empty (the global one) or 1 to 64 characters of
`A-Z a-z 0-9 _ . -`, and anything else is an `InvalidPolicy` at the
`forTenant` call, so a name taken from a header or a subdomain can never reach
a SQL statement or a Redis key unchecked:

```bit
import { Authz } from "authz"

enum Action { Manage, Read, Create, Update, Delete, Publish }

fn main(): ()! {
  let authz = Authz<Action>()?
  for t of ["acme", "", "a b", "a;b"] {
    authz.forTenant(t) catch e {
      println("'${t}': ${e.message()}")
      continue
    }
    println("'${t}': ok")
  }
}
```

This prints `'acme': ok`, `'': ok`, then a refusal for `'a b'` and for `'a;b'`
that says which character is wrong. A view of a view is a view of the new
tenant, not of both.

## Who wins when they disagree

The rules a tenant sees are the global ones and its own, and they are decided
together as [Deciding](decisions.md) says: an explicit deny from any of them
beats any allow, and no match is a refusal. A global deny therefore cannot be
allowed back inside a tenant, and a tenant's own deny applies to that tenant
even where a global rule allows. This is AWS IAM's evaluation logic, in which
every applicable policy is considered and an explicit deny in any of them wins
([policy evaluation logic](https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_policies_evaluation-logic.html)).
Code policies and roles are global: they apply in every tenant.

## What a view may write

A tenant's admin endpoint holds a view, and what it writes is that tenant's:

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

fn editor(tenant: string): Attachment {
  return Attachment{
    policy = "PublishAny",
    to = Target{ role = Option<string>.Some("editor") },
    tenant = tenant,
  }
}

fn main(): ()! {
  let authz = Authz<Action>()?
  authz.resource<Article>()?
  let st = Statement{
    effect = "allow",
    actions = ["Publish"],
    resource = "Article",
    when = jsonParse("null")?,
  }
  let doc = PolicyDoc{ name = "PublishAny", statements = [st] }
  authz.savePolicy(doc)?
  let acme = authz.forTenant("acme")?
  let borealis = authz.forTenant("borealis")?
  let eve = Option<Subject>.Some(User{ id = "eve", roles = ["editor"] })
  let piece = Article{ id = 1, status = "review" }
  acme.attach(editor(""))?
  println(
    "acme ${acme.can<Article>(eve, Action.Publish, piece)}, borealis ${borealis.can<Article>(
      eve,
      Action.Publish,
      piece,
    )}",
  )
  acme.attach(editor("borealis")) catch e {
    println(e.message())
  }
  acme.savePolicy(doc) catch e {
    println(e.message())
  }
  acme.detach(editor("acme"))?
  println("after detach: ${acme.can<Article>(eve, Action.Publish, piece)}")
}
```

This prints `acme true, borealis false`: the attachment written on Acme's view
with `tenant = ""` is Acme's. Then it prints the two refusals, and
`after detach: false`.

`attach` and `detach` on a view write that tenant's attachments: one that says
`tenant = ""` is stamped with the view's tenant (it does not become global), and
one that names another tenant is an `InvalidPolicy`, so a tenant's admin cannot
attach for the global namespace or for someone else. Attaching globally is
done on the plain handle, which writes any tenant it is asked to.
`savePolicy` is refused on a view: a policy has one name for every tenant, and
saving over it would change what the others are allowed. Save policies on the
handle, and let each tenant choose which of them apply to it.

## Relationship tuples

A tuple lives in one tenant. `relate`, `unrelate`, `related` and `hasRelation` on a
view read and write that tenant's tuples, and the walk behind `hasRelation` and
behind a `related("editor")` condition never leaves them, so a group in one tenant
cannot give anyone access in another. The plain handle's tuples are the
global namespace, which is a namespace of its own: no tenant inherits them. This
is the separation OpenFGA's stores give: tuples in one store are never read by a
check in another ([OpenFGA](https://openfga.dev/docs)).

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
  let acme = authz.forTenant("acme")?
  let borealis = authz.forTenant("borealis")?
  acme.relate("user:sara", "editor", "folder:launch")?
  println("acme: ${acme.related("user:sara", "editor", "folder:launch")?}")
  println("borealis: ${borealis.related("user:sara", "editor", "folder:launch")?}")
  println("no tenant: ${authz.related("user:sara", "editor", "folder:launch")?}")
}
```

This prints `acme: true`, `borealis: false` and `no tenant: false`. A
`RelationStore` takes the tenant as the first argument of `write`, `delete`,
`has`, `direct` and `list`, so a SQL store binds it like any other parameter
(see [Relationships](relationships.md)).

## Sharp edges

- A save, or an attachment with `tenant = ""`, rebuilds every tenant's cached
  rules on their next check. An attachment for one tenant rebuilds that
  tenant's only; the others stay warm ([Stored policies](stored.md) has how a
  second server learns of it).
- The first `forTenant` of a tenant reads its attachments from the store once;
  after that a view makes no store call.
- `rolesOf` on a view lists the rules of that tenant.
- A `MemoryStore` and a `MemoryRelationStore` are per process, tenants or not.

## Next

[Stored policies](stored.md) has `savePolicy` and `attach`;
[Relationships](relationships.md) has the tuples a view keeps apart.
