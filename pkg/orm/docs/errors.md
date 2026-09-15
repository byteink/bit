# Constraint errors

[Write](write.md)'s `savePerson` can fail for a reason no `TableDesc` or
`Value` describes: the database itself rejected the row. Register a
second `Person` with an email already in `people` and the driver answers
with its own text, something like `duplicate key value violates unique
constraint "people_email_key"` on Postgres or `Duplicate entry
'ada@x.com' for key 'people.email'` on MySQL. Two different sentences for
the same fact, and a signup handler that wants to answer "that email is
taken" would have to string-match one of them, then break the day the
server's locale or version changes the wording.

`classify` turns that driver error into one of six typed causes instead,
decided from the SQLSTATE code the driver already carries, so your
`catch` branches on a type, never on English.

## Catching a duplicate email

```bit
import { Data, TableDesc, UniqueViolation, classify, save } from "orm"
import { AttrDesc, FieldDesc, Value } from "std/sql"

@table class Person {
  @id
  id: i64
  name: string
  email: string
}

fn personDesc(): TableDesc {
  return TableDesc{
    table: "people",
    fields: Person{ id: 0, name: "", email: "" }.tableDescriptor(),
    classAttrs: []AttrDesc(0),
  }
}

fn personValues(p: Person): map<string, Value> {
  return map<string, Value>{
    "id": Value.Int(p.id),
    "name": Value.Text(p.name),
    "email": Value.Text(p.email),
  }
}

fn savePersonOrFail(db: Data, p: Person): Person! {
  let desc = personDesc()
  save(db, desc, personValues(p), p.isPersisted()) catch e {
    let cause = classify(e, desc.table)
    let (uv, ok) = cause.(UniqueViolation)
    if (ok) {
      fail newError("that ${uv.columns[0]} is already registered")
    }
    fail cause
  }
  p.markPersisted(true)
  return p
}
```

`classify(e, desc.table)` asks the failure for its SQLSTATE. A unique
violation on `people` comes back as `UniqueViolation{ table: "people",
constraint: "...", columns: [...] }` - the table and constraint names,
never the row's email address, which is exactly what let this handler
write a clean message instead of forwarding the driver's.

## The six causes

`classify` maps five SQLSTATE codes to five named violations, and one more
code that is not a violation at all:

| SQLSTATE | Type | Carries |
| -------- | ---- | ------- |
| `23505` | `UniqueViolation` | `table`, `constraint`, `columns` |
| `23503` | `ForeignKeyViolation` | `table`, `constraint`, `column`, `referencedTable` |
| `23502` | `NotNullViolation` | `table`, `column` |
| `23514` | `CheckViolation` | `table`, `constraint` |
| `40P01` | `DeadlockDetected` | nothing - the server broke a deadlock by killing one side |
| `40001` | `SerializationFailure` | nothing - a serializable transaction could not be ordered |

A handler that wants to log every one by name, not only react to
`UniqueViolation`, checks each in turn:

```bit
import { CheckViolation, ForeignKeyViolation, NotNullViolation } from "orm"
import { DeadlockDetected, SerializationFailure } from "orm"

fn describeFailure(e: error, table: string): string {
  let cause = classify(e, table)
  let (fk, fkOk) = cause.(ForeignKeyViolation)
  if (fkOk) {
    return "foreign key '${fk.constraint}' on ${fk.table}.${fk.column} -> ${fk.referencedTable}"
  }
  let (nn, nnOk) = cause.(NotNullViolation)
  if (nnOk) {
    return "'${nn.column}' on ${nn.table} may not be null"
  }
  let (ck, ckOk) = cause.(CheckViolation)
  if (ckOk) {
    return "check '${ck.constraint}' on ${ck.table} failed"
  }
  let (_, dlOk) = cause.(DeadlockDetected)
  if (dlOk) {
    return "deadlock - safe to retry"
  }
  let (_, sfOk) = cause.(SerializationFailure)
  if (sfOk) {
    return "serialization failure - safe to retry"
  }
  return cause.message()
}
```

`DeadlockDetected` and `SerializationFailure` are worth a branch of their
own for a different reason: they are not a bug in your data, they are the
database telling you to run the same transaction again. Each carries
`retryable(): bool` - `true` for these two, `false` for the other four -
so a retry helper can ask any of the six the same question without
naming every type first:

```bit
fn isRetryable(e: error, table: string): bool {
  let cause = classify(e, table)
  let (dl, dlOk) = cause.(DeadlockDetected)
  if (dlOk) {
    return dl.retryable()
  }
  let (sf, sfOk) = cause.(SerializationFailure)
  if (sfOk) {
    return sf.retryable()
  }
  return false
}
```

This package builds no retry loop on top of `retryable()` - how many
attempts, what backoff, belongs to your application, not to the ORM.

## The sharp edge: only SQLSTATE decides, and only two drivers today

`classify` never reads the driver's message text, only the SQLSTATE code,
which both `pkg/postgres` and `pkg/mysql` already report. An error that
does not carry one (a connection failure, an error you built yourself)
comes back from `classify` **unchanged**, not swallowed:

```bit
fn wontClassify(): bool {
  let raw = newError("connection refused")
  let cause = classify(raw, "people")
  return cause.message() == "connection refused"
}
```

`wontClassify()` returns `true`: `classify` looked for a SQLSTATE, found
none, and handed the same error straight back.

`constraint`/`column`/`referencedTable` are filled in only when the
driver's error ALSO exposes them beyond the SQLSTATE - neither shipped
driver does yet, so today every `UniqueViolation.columns` you see in a
real program is empty unless a future driver update fills it in. The
`table` field is always right regardless, because it is the table you
already told `classify` about, not something parsed off the wire.

## When not to use it

If you already know which constraint can fail (an `email` column you
declared `unique` yourself), a plain application-level check before the
`INSERT` is often simpler and cheaper than round-tripping to the
database to find out. Reach for `classify` when the failure can come from
more than one place, or when a race between two requests means checking
first cannot be race-free anyway - a unique constraint is the database's
last line of defense against exactly that race.

## Where to go next

[Write](write.md) covers `save`, `delete` and `upsert`, the calls this
page's `catch` blocks sit around. [Query](query.md) covers reading rows
back with `find`.
