# Timestamps

Almost every table ends up with a `createdAt` and an `updatedAt` column,
and almost every app re-implements them slightly differently: one forgets
to update `updatedAt` on a bulk job, another lets an `UPDATE` accidentally
overwrite `createdAt` because `save` writes every column. `@timestamps`
does the whole thing once: `createdAt` is set on `INSERT` and never
touched again; `updatedAt` is set on `INSERT` and every `UPDATE`, single
or bulk.

## Marking the table

Add `@timestamps` alongside `@table`, and declare the two columns it fills:

```bit
import { Data, TableDesc, applyTimestamps, save } from "orm"
import { AttrDesc, FieldDesc, Value } from "std/sql"
import { now } from "std/time"

@table @timestamps class Person {
  @id
  id: i64
  name: string
  email: string
  createdAt: i64
  updatedAt: i64
}

fn personDesc(): TableDesc {
  return TableDesc{
    table = "people",
    fields = Person{ id = 0, name = "", email = "", createdAt = 0, updatedAt = 0 }.tableDescriptor(),
  }
}

fn personValues(p: Person): map<string, Value> {
  return map<string, Value>{
    "id": Value.Int(p.id),
    "name": Value.Text(p.name),
    "email": Value.Text(p.email),
  }
}

fn savePerson(db: Data, p: Person): Person! {
  let desc = applyTimestamps(personDesc(), personValues(p), p.isPersisted(), p.tableAttrs(), now())?
  let result = save(db, desc, personValues(p), p.isPersisted())?
  p.markPersisted(true)
  return p
}
```

`savePerson` never sets `createdAt`/`updatedAt` itself - `applyTimestamps`
reads `p.isPersisted()`, the same flag `save` already uses to pick
`INSERT` or `UPDATE`, and reuses it rather than asking twice: `createdAt`
is filled only when this is an `INSERT`; `updatedAt` is filled either way,
from the SAME clock reading, so a freshly inserted row's two columns come
out byte-identical.

## Why `now()` is a parameter, not a call inside the package

`applyTimestamps` takes the clock reading (`now()`, `stdlib/time`) as its
last argument instead of calling `now()` internally. That is what makes
`savePerson` testable: a test passes a fixed `Timestamp` and asserts the
EXACT value written, something a call to the real wall clock could never
let you check. The package still reads it only once per write -
`savePerson` calls `now()` a single time and passes the same reading to
every column that needs it.

## Why an UPDATE never touches createdAt

[Write](write.md) documents that `save`'s `UPDATE` writes every column in
`TableDesc.fields` - there is no per-column exclusion of its own. Rewriting
`createdAt` on every update would destroy the row's real age, so
`applyTimestamps` returns a DIFFERENT `TableDesc` on the `UPDATE` branch,
one with `createdAt` dropped from `fields` entirely: `save` never sees the
column, so it can never write it. `personDesc()` still declares
`createdAt` - the field is real, it is just excluded from that one
statement.

## The patch-builder path

[Patch](patch.md)'s `update<T>` writes only the columns you `.set()`
explicitly, so nothing here happens automatically - name it your `Patch`
build:

```bit
import { update } from "orm"
import { withUpdatedAt } from "orm"

fn renamePerson(db: Data, id: i64, name: string): int! {
  let fields = Person{ id = 0, name = "", email = "", createdAt = 0, updatedAt = 0 }.tableDescriptor()
  let p = update<Person>(db, "people", fields).where("id", Value.Int(id)).set(
    "name",
    Value.Text(name),
  )
  return withUpdatedAt(
    p,
    Person{ id = 0, name = "", email = "", createdAt = 0, updatedAt = 0 }.tableAttrs(),
    now(),
  ).run()?
}
```

`withUpdatedAt` chains one more `.set("updatedAt", ...)` onto the build -
the exact same call `renamePerson` could have written by hand - when
`classAttrs` (the class's own `tableAttrs()`) carries the `@timestamps`
mark, and returns the `Patch` unchanged otherwise. `deleteMany`/
`DeletePatch` never call it - a `DELETE` has no `SET` list to add to.

## The sharp edge: a `@timestamps` class missing either column

`@timestamps` requires both `createdAt` and `updatedAt` to exist as real
fields. A class that carries the mark without one is rejected at the
first write, naming the missing field:

```bit ignore
@table @timestamps class Draft {
  @id
  id: i64
  title: string
  createdAt: i64
}
```

```text
pkg/orm: the class mapped to 'drafts' carries '@timestamps' but declares no 'updatedAt' field
```

This is a catchable `TimestampsError` (`cause: TimestampsCause.MissingField`),
not a panic - `applyTimestamps`/`withUpdatedAt` both return it through the
ordinary `!` result, the same shape `write.bit`'s `WriteError` and
`patch.bit`'s `PatchError` already are, so a caller can `catch` it and
report which field is missing rather than crash:

```bit
import { TimestampsCause, TimestampsError, hasTimestampsAttr } from "orm"

fn savePersonOrReport(db: Data, p: Person): Person! {
  return savePerson(db, p) catch e {
    let (te, ok) = e.(TimestampsError)
    if (ok && te.cause == TimestampsCause.MissingField) {
      fail newError("schema bug: ${te.message()}")
    }
    fail e
  }
}

fn describesTimestamps(attrs: []AttrDesc): string {
  if (hasTimestampsAttr(attrs)) {
    return "createdAt/updatedAt are managed automatically"
  }
  return "createdAt/updatedAt are plain columns"
}
```

A table that never carries `@timestamps` at all is unaffected -
`applyTimestamps` checks for the mark first (`hasTimestampsAttr`, the same
check `describesTimestamps` runs above) and returns the `TableDesc`
unchanged when it is absent, so a plain `@table` class writes exactly what
it always did.

## When not to use this

If a table's `createdAt`/`updatedAt` follow a different rule than "set once,
touch on every write" - soft-deleted rows that should stop updating, or a
column driven by a database trigger instead of the application - write the
`Value.Int(...)` entries into `personValues` directly the way [Write](write.md)
does for every other column, and skip `@timestamps` for that class.

## Where to go next

[Write](write.md) covers `save`'s own `INSERT`/`UPDATE` decision that
`applyTimestamps` reuses. [Patch](patch.md) covers `update`/`deleteMany`
for writes with no instance loaded, extended here by `withUpdatedAt`.
