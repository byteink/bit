# Optimistic locking

Alice and Bob both load account 1: balance 100, version 5. Alice deposits
10 and saves - the row becomes balance 110, version 6. Bob, still holding
his stale copy, withdraws 20 from the balance *he* read and saves too. A
plain `UPDATE accounts SET balance = ...WHERE id = 1` cannot tell Bob's
write is based on a row that no longer exists: it matches, it succeeds, and
Alice's deposit is gone with nothing logged. On a money table that is how
an audit trail goes missing. `@version` closes it: the `UPDATE` only
succeeds if the row is still the one you read.

## Marking a class

```bit
import { Data, StaleWriteError, TableDesc, save } from "orm"
import { AttrDesc, FieldDesc, Value } from "std/sql"

@table class Account {
  @id
  id: i64
  @version
  version: i64
  balanceCents: i64
}

fn accountDesc(): TableDesc {
  return TableDesc{
    table: "accounts",
    fields: Account{ id: 0, version: 0, balanceCents: 0 }.tableDescriptor(),
    classAttrs: []AttrDesc(0),
  }
}

fn accountValues(a: Account): map<string, Value> {
  return map<string, Value>{
    "id": Value.Int(a.id),
    "version": Value.Int(a.version),
    "balanceCents": Value.Int(a.balanceCents),
  }
}

fn saveAccount(db: Data, a: Account): Account! {
  let result = save(db, accountDesc(), accountValues(a), a.isPersisted())?
  let (newVersion, ok) = result.generated["version"]
  if (ok) {
    match (newVersion) {
      Int(n) => a.version = n
      _ => {}
    }
  }
  a.markPersisted(true)
  return a
}
```

`@version` needs nothing from you beyond the mark and an `i64` column -
[Write](write.md)'s `save` reads it off `accountDesc()` the same way it
already reads `@id`. On an `Account` that carries it, `save` emits

```text
update accounts set id = $1, version = $2, balance_cents = $3 where id = $4 and version = $5
```

with `$2` bound to `version + 1` and `$5` bound to the version this call
started with - both computed from `a.version`, never re-read from the
database. A successful save writes the new version back onto `a` through
`result.generated`, the identical channel a database-generated id already
uses (see [Write](write.md)) - that is what makes a second `saveAccount(db,
a)` compare against the right value.

## The sharp edge: a stale write is a distinct, catchable error

```bit
fn depositSafely(db: Data, a: Account, cents: i64): Account! {
  a.balanceCents = a.balanceCents + cents
  return saveAccount(db, a) catch e {
    let (_, stale) = e.(StaleWriteError)
    if (stale) {
      fail newError("account ${a.id} changed since it was read - reload and try again")
    }
    fail e
  }
}
```

Bob's second `save` above matches zero rows - his `WHERE version = 5` finds
Alice's row at `version = 6` instead - and `save` fails with
`StaleWriteError`, never silence:

```text
pkg/orm: stale write on the class mapped to 'accounts' with key 1 - tried to write version 6 over 5, but another write already changed it; reload and retry
```

This is a different type from [Write](write.md)'s `WriteError`, the error a
plain, unversioned table's `save` raises when an `UPDATE` matches nothing.
The two mean different things and want different responses: `WriteError`
means the row is gone - show a 404. `StaleWriteError` means the row is
still there but changed - reload it and let the caller retry, the way
`depositSafely` above does. A `catch` that only checked `WriteError` would
never see Bob's case at all.

## The sharper edge: exactly one `@version` field

```bit ignore
@table class Broken {
  @id
  id: i64
  @version
  version: i64
  @version
  revision: i64
}
```

Two fields both marked `@version` is a class shaped wrong, not a choice -
`save` rejects it before touching the driver:

```text
pkg/orm: the class mapped to 'broken' carries more than one '@version' field - exactly one is allowed
```

## When not to use this

[`update<T>(...)`](patch.md) never loads the row it changes, so it has no
old version to compare against - on a `@version` table it refuses to run
unless you name the version column in `where(...)` yourself. That is a
narrower, manual guard, not this feature; reach for `save` whenever a lost
update matters, and `update<T>` only for the single-column or bulk writes
[Patch](patch.md) describes. [`upsert`](write.md#upsert---insert-or-update-in-one-statement-with-two-real-limits)
cannot version-check at all - Postgres and MySQL both decide insert-or-update
inside the one statement, before any comparison could run.

## Where to go next

[Write](write.md) covers `save`, `delete` and `upsert` for the rest of the
persisted-flag-driven write path. [Patch](patch.md) covers `update`/
`deleteMany` and their own, more limited `@version` refusal.
