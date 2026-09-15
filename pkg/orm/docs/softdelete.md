# Soft delete

Banning an account should not erase it. Support still needs to look up the
banned user's old orders, finance still needs the row for a chargeback, and
"we deleted the evidence" is not where you want to be if the ban itself gets
disputed. A real `DELETE` cannot be undone and cannot be read back - what you
actually want is a row that is *gone* to every normal query but still there
when you go looking for it on purpose. `@softDelete` marks a class for
exactly that: `delete` stops removing the row and starts marking it, and
every ordinary read stops seeing a marked row at all.

## Marking a class

```bit
import { Data, SoftQuery, TableDesc, delete, findScoped, restore, forceDelete } from "orm"
import { AttrDesc, FieldDesc, Rows, Value, sqlReqInt, sqlReqText } from "std/sql"

@table @softDelete class Account {
  @id
  id: i64
  email: string
  deletedAt: Option<i64>
}

fn accountEntity(): Account {
  return Account{ id: 0, email: "", deletedAt: Option.None }
}

fn accountFields(): []FieldDesc {
  return accountEntity().tableDescriptor()
}

fn accountAttrs(): []AttrDesc {
  return accountEntity().tableAttrs()
}

fn accountDesc(): TableDesc {
  return TableDesc{ table: "accounts", fields: accountFields(), classAttrs: accountAttrs() }
}

fn accountValues(a: Account): map<string, Value> {
  return map<string, Value>{ "id": Value.Int(a.id) }
}

fn banAccount(db: Data, a: Account): ()! {
  delete(db, accountDesc(), accountValues(a))?
}
```

`@softDelete` requires a declared `deletedAt` field - that is the column
every entry point on this page reads and writes, the same way `@id` marks
the primary key `pkg/orm/write.bit`'s own `delete` uses. `banAccount`'s
`delete(...)` no longer runs `DELETE FROM accounts`: it runs `UPDATE
accounts SET deleted_at = now() WHERE id = $1`, and the row is still there,
just marked.

## Every ordinary query stops seeing it

`accountDesc()`'s `classAttrs` is what tells this package the class is
soft-delete at all - it is the same `tableAttrs()` [Naming](naming.md)
already reads for `@table("...")`. `findScoped` reads it too, and adds the
filter to every terminal automatically:

```bit
fn accountMapper(rows: Rows): Account! {
  let cols = rows.columns()
  return Account{
    id: sqlReqInt(rows, cols, "id")?,
    email: sqlReqText(rows, cols, "email")?,
    deletedAt: Option.None,
  }
}

fn accounts(db: Data): SoftQuery<Account>! {
  return findScoped<Account>(db, "accounts", accountFields(), accountAttrs(), accountMapper)?
}

fn byEmail(db: Data, email: string): []Account! {
  return accounts(db)?.where("email", Value.Text(email)).all()?
}
```

`byEmail` runs `select * from accounts where email = $1 and deleted_at is
null` - the exclusion is ANDed onto whatever `where`/`whereIn`/`whereLike`
you already chained, never pasted after the fact onto assembled SQL text,
so it composes correctly no matter how many predicates came before it.
`one`/`oneOrFail`/`count`/`exists` all carry the identical filter; there is
no fifth terminal that forgets it.

## Seeing a trashed row on purpose

```bit
fn anyAccountEver(db: Data, email: string): bool! {
  return accounts(db)?.where("email", Value.Text(email)).withTrashed().exists()?
}

fn bannedAccounts(db: Data): []Account! {
  return accounts(db)?.onlyTrashed().all()?
}
```

`withTrashed()` drops the filter entirely - `anyAccountEver` sees a banned
row too, the check a signup form needs before it can say "that address is
already registered, banned or not." `onlyTrashed()` inverts it to `deleted_at
is not null` instead: `bannedAccounts` is a moderation queue's own query,
the trashed rows and nothing else.

## Undoing a ban, and the escape hatch that actually removes a row

```bit
fn unbanAccount(db: Data, a: Account): ()! {
  restore(db, accountDesc(), accountValues(a))?
}

fn eraseAccount(db: Data, a: Account): ()! {
  forceDelete(db, accountDesc(), accountValues(a))?
}
```

`restore` runs `UPDATE accounts SET deleted_at = NULL WHERE id = $1` - the
same row `banAccount` marked, now visible to `accounts(db)` again with no
other code path aware anything happened. `forceDelete` is the one function
on this page that still runs a real `DELETE`, on a soft-delete table or
not - reach for it only when a row must actually be gone, GDPR erasure
being the case that actually requires it.

## The sharp edge: marking a class without the field it needs

```bit ignore
@table @softDelete class Broken {
  @id
  id: i64
}
```

```text
pkg/orm: '@softDelete' on the class mapped to 'brokens' requires a declared 'deletedAt' field
```

This is a caught `error`, not a panic - a class shaped wrong is a program
bug your own code can report, same as any other `catch`:

```bit ignore
fn brokenDesc(): TableDesc {
  return TableDesc{ table: "brokens", fields: [], classAttrs: [AttrDesc{ name: "softDelete", args: []string(0) }] }
}

fn probe(db: Data): ()! {
  delete(db, brokenDesc(), map<string, Value>{}) catch e {
    let (se, ok) = e.(SoftDeleteError)
    if (ok) {
      fail newError("class misconfigured: ${se.cause}")
    }
    fail e
  }
}
```

## Bulk writes respect the mark too

[Patch](patch.md)'s `update`/`deleteMany` have their own soft-delete-aware
entry points, `updateScoped`/`deleteManyScoped`, so a bulk job never
touches a row the single-instance path already protects:

```bit
import { SoftDeletePatch, deleteManyScoped, updateScoped } from "orm"

fn closeStaleAccounts(db: Data, cutoffId: i64): int! {
  let patch = updateScoped<Account>(db, "accounts", accountFields(), accountAttrs())?
  return patch.where("id", Value.Int(cutoffId)).set("email", Value.Text("")).run()?
}

fn staleAccounts(db: Data): SoftDeletePatch<Account>! {
  return deleteManyScoped<Account>(db, "accounts", accountFields(), accountAttrs())?
}

fn purgeBanned(db: Data, id: i64): int! {
  return staleAccounts(db)?.where("id", Value.Int(id)).run()?
}
```

`patch` already excludes an already-trashed row from its own default
`where`, the same way `accounts(db)` does. `purgeBanned`'s `run()` never
runs a real `DELETE` on this table - it emits the identical `UPDATE ... SET
deleted_at = now()` `banAccount` does, so a bulk removal can never
hard-delete what the single-row path only marks. On a class with no
`@softDelete` at all, both functions behave exactly like the plain
`update`/`deleteMany` they wrap - unchanged.

## A relation's own child query respects the mark too

The classic version of this bug: a banned account's orders reappear under
`account.orders` because the relation loader forgot the filter. [Relations](relation.md)'s
`hasMany`/`hasOne`/`belongsTo` take an ordinary `childQuery: (Data) =>
Query<TChild>` closure, the same per-entity wrapper shape every function on
this page already uses - so a `@softDelete` child table is just a choice of
which function goes in that closure: `findScopedQuery`, not `find`.

```bit
import { Dir, Query, RelationLoader, find, findScopedQuery, hasMany, withRelations } from "orm"

@table class Team {
  @id
  id: i64
  @hasMany("teamId")
  accounts: []Account
}

fn teamAccountsLoader(): RelationLoader<Team> {
  return hasMany<Team, Account>(
    (t) => t.id,
    (db) => findScopedQuery<Account>(db, "accounts", accountFields(), accountAttrs(), accountMapper),
    "teamId",
    (a) => a.id,
    (t, accts) => {
      t.accounts = accts
    },
  )
}

fn teamMapper(rows: Rows): Team! {
  return Team{ id: sqlReqInt(rows, rows.columns(), "id")? }
}

fn teams(db: Data): Query<Team> {
  return withRelations(
    find<Team>(
      db,
      "teams",
      [FieldDesc{ name: "id", typeName: "i64", attrs: []AttrDesc(0) }],
      teamMapper,
    ),
    map<string, RelationLoader<Team>>{ "accounts": teamAccountsLoader() },
  )
}

fn teamWithLiveAccounts(db: Data, id: i64): Team! {
  return teams(db).where("id", Value.Int(id)).with("accounts").oneOrFail()?
}
```

`teamWithLiveAccounts` runs two statements - the team, then `select *
from accounts where team_id in ($1) and deleted_at is null` - never a
banned account slipping back in under a team it still belongs to on
paper. `findScopedQuery` returns a plain `Query<T>`, not the
`withTrashed`/`onlyTrashed`-carrying wrapper `findScoped` does: a relation
load always respects the child's default scope, the same way every other
read on this page does when a caller doesn't ask for trashed rows on
purpose.

`SoftQuery<T>` (what `findScoped` returns) carries `with()`/`after()`
too, delegating straight to the wrapped `Query<T>` - a `@softDelete`
PARENT paginating with [keyset pagination](keyset.md) or eager-loading a
relation works exactly like `accounts(db)` above, no different spelling:

```bit
fn nextAccountsPage(db: Data, lastId: i64): []Account! {
  return accounts(db)?.orderBy("id", Dir.Asc).after(Value.Int(lastId))?.limit(50).all()?
}
```

`after()`'s own keyset predicate and the automatic `deleted_at is null`
are both ordinary entries in the same `where` list - order never matters,
both are `AND`ed.

## When not to use this

**A unique column blocks re-registration.** `accounts.email unique` plus a
soft-deleted row still holding that email means a new signup with the same
address fails at the database, not at your application - that is the
database doing exactly what `unique` asked it to do, not a bug this page
introduces. Fix it with a partial unique index (`UNIQUE (email) WHERE
deleted_at IS NULL`) if re-registration after a ban should be possible.

**The table only grows.** Nothing on this page ever removes a row short of
`forceDelete` - a high-churn table (sessions, audit events) marked
`@softDelete` keeps every row forever unless something else purges them,
which is usually the wrong trade for a table that size.

**Some data legally has to go.** A "right to erasure" request needs the row
gone, not flagged - `forceDelete` is that path, and it is worth grepping for
on purpose rather than reached for by habit, because every other function on
this page is built to protect the row it just marked.

## Where to go next

[Query](query.md) covers the plain `find` chain this page's `findScoped`
extends, and [keyset pagination](keyset.md)'s own `after()`. [Relations](relation.md)
covers `hasMany`/`hasOne`/`belongsTo` and `with()` before `findScopedQuery`
here. [Patch](patch.md) covers `update`/`deleteMany` before the
soft-delete-aware wrappers here. [Write](write.md) covers `save`/`delete`/
`upsert` and `TableDesc`, the shape `classAttrs` was added to for this page.
