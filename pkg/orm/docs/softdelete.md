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
import { Db, open } from "orm"

@table @softDelete class Account {
  id: i64,
  email: string,
  deletedAt: Option<i64>,
}

fn banAccount(db: Db, id: i64): ()! {
  db.table<Account>().delete(id)?
}
```

`@softDelete` requires a declared `deletedAt` field - that is the column
every method on this page reads and writes. `banAccount`'s `delete(id)` no
longer runs `DELETE FROM account`: it runs `UPDATE account SET deleted_at =
now() WHERE id = $1`, and the row is still there, just marked.

## Every ordinary read stops seeing it

```bit
fn byEmail(db: Db, email: string): []Account! {
  return db.table<Account>().where("email", email).all()?
}

fn lookUp(db: Db, id: i64): Account! {
  return db.table<Account>().find(id)?
}
```

`byEmail` runs `select * from account where email = $1 and deleted_at is
null` - the exclusion is ANDed onto whatever `where`/`orderBy` you already
chained, never pasted after the fact onto assembled SQL text, so it composes
correctly no matter how many predicates came before it. `find`, `all`,
`first` and `count` all carry the identical filter - `lookUp(db, id)` fails
naming the row once `banAccount` has marked it, the same way it would if the
row were really gone.

## Seeing a trashed row on purpose

```bit
fn anyAccountEver(db: Db, email: string): int! {
  return db.table<Account>().where("email", email).withDeleted().count()?
}
```

`withDeleted()` drops the filter entirely for the rest of the chain -
`anyAccountEver` sees a banned row too, the check a signup form needs before
it can say "that address is already registered, banned or not."

## Undoing a ban, and the escape hatch that actually removes a row

```bit
fn unbanAccount(db: Db, id: i64): ()! {
  db.table<Account>().restore(id)?
}

fn eraseAccount(db: Db, id: i64): ()! {
  db.table<Account>().forceDelete(id)?
}
```

`restore` runs `UPDATE account SET deleted_at = NULL WHERE id = $1` - the
same row `banAccount` marked, now visible to `byEmail`/`lookUp` again with
no other code path aware anything happened. `forceDelete` is the one method
on this page that still runs a real `DELETE`, marked or not - reach for it
only when a row must actually be gone, GDPR erasure being the case that
actually requires it.

## Bulk writes respect the mark too

```bit
fn closeStaleAccounts(db: Db, cutoffId: i64): int! {
  return db.table<Account>().where("id", cutoffId).deleteAll()?
}
```

`deleteAll` on a `@softDelete` class never runs a real `DELETE` - it emits
the identical `UPDATE ... SET deleted_at = now()` `banAccount` does, scoped
by whatever `where(...)` narrowed to, so a bulk removal can never
hard-delete what the single-row path only marks. On a class with no
`@softDelete` at all, `deleteAll` behaves exactly like an ordinary bulk
delete - unchanged.

## The sharp edge: marking a class without the field it needs

```bit ignore
@table @softDelete class Broken {
  id: i64,
}

fn probe(db: Db): ()! {
  db.table<Broken>().delete(1)?
}
```

```text
pkg/orm: '@softDelete' on the class mapped to 'broken' requires a declared 'deletedAt' field
```

This surfaces as an ordinary error at the first call that needs the column -
`delete`, `all`, `find`, anything routed through the chain's own soft-delete
check - never a panic and never a silent no-op: a class shaped wrong is a
program bug your own code can report, same as any other failed `?`.

## The sharp edge: a relation's own child query does not know about the mark

```bit
@table class Team {
  id: i64
  @hasMany("teamId")
  accounts: []Account
}

fn printRoster(db: Db, id: i64): ()! {
  match (db.table<Team>().where("id", id).first()?) {
    Some(team) => println("${len(team.accounts)} accounts")
    None => println("not found")
  }
}
```

Reading `team.accounts` makes the compiler load it with the query
([Relations](relation.md) explains the rule), and that load reads every
`Account` row whose `team_id` matches, by a plain `SELECT` that does not go
through `Repo<Account>` at all - a banned account still turns up under
`team.accounts`. A relation load and this page's own exclusion are two
separate mechanisms today; if a team roster must never show a banned
member, filter `deletedAt` out of `team.accounts` yourself after loading,
rather than assume the load already did it.

## When not to use this

**A unique column blocks re-registration.** `account.email unique` plus a
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
on purpose rather than reached for by habit, because every other method on
this page is built to protect the row it just marked.

## Where to go next

[Query](query.md) covers the plain `find`/`where`/`all` chain this page's
exclusion sits on top of. [Relations](relation.md) covers how a relation loads and the
sharp edge above in full. [Write](write.md) covers `insert`/`update`, which
`@softDelete` never changes.
