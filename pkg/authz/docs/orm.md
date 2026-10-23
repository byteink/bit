# Scoped database access

Inkwell's list and write paths need the same rules as its row checks.
Wrap an `Authz` handle in `OrmGuard` and pass it through the ORM's existing
`Options.authz`. The adapter keeps `Authz.check(user, action, row)` intact;
its separate `check()` validates the ORM's four CRUD action names.

```bit
import { Authz, OrmGuard, Policy, eq } from "authz"
import { Guard, GuardOp, Options, ServerDialect, open } from "orm"
import { Value } from "std/sql"
import { env } from "std/os"

enum Action { Manage, Read, Create, Update, Delete }
class User { export id: string, export roles: []string }
@table("articles") class Article {
  @id
  id: i64
  authorId: string
}

fn main(): ()! {
  let rules = Authz<Action>()?
  rules.resource<Article>()?
  rules.role<User>(
    "author",
    [
      Policy<User, Action>("Own", (p, user) => {
        p.can<Article>([Action.Manage], eq("authorId", Value.Text(user.id)))
      }),
    ],
  )?
  let guard: Guard = OrmGuard<Action>(rules)?
  let user = User{ id = "sara", roles = ["author"] }
  guard.check()?
  assert(guard.protects("articles"), "registered tables are protected")
  let fragment = guard.filter(user, GuardOp.Read, "articles", ServerDialect.Postgres, 2)?
  match (fragment) {
    Sql(sql, _) => println(sql)
    _ => panic("expected the author filter")
  }
  let row = Article{ id = 1, authorId = "sara" }
  assert(
    guard.allows(user, GuardOp.Create, "articles", ["id", "authorId"], row.__values())?,
    "author",
  )
  println(guard.denied(user, GuardOp.Update, "articles").message())
  println(guard.notFound("articles").message())
  let db = open(env("DATABASE_URL"), Options{ authz = Option.Some(guard) })?
  defer db.pool.close()
  for article of db.as(user).table<Article>().all()? {
    println("${article.id}")
  }
}
```

An unregistered table is unprotected: registration is the opt-in. A guest
uses `db.asGuest()` and receives only guest rules. Signed-in actors must be
actual `Subject` values with nonempty ids; the adapter never builds roles
from an id alone. Use an authenticated identity at this boundary.

Create the adapter from `rules.forTenant(tenant)?` for a tenant-specific
handle. The current `Guard` port does not carry a per-request tenant, so
`db.as(user, tenant)` alone cannot select an authorization tenant.

Matching code functions and relationship conditions are refused before
folding, even when another matching rule permits everything. Typed policy
literals and relationship SQL remain outside this adapter's scope (#7042).
The port's denial callback has no row: its `Denied` has an empty deciding
policy and the fixed message `forbidden`; missing rows use `not found`.

The ORM requires `$n` placeholders for both databases. The adapter calls
`compileSql(cond, info, dialect, firstParam, true)` to request numbering
without changing MySQL's identifier quoting. Existing four-argument calls
still emit `?` on MySQL. A numbered call requires `firstParam >= 1`.
