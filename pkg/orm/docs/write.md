# Write

"If I have a `Person` instance, whether I just built it or it came back
from a query, saving it should just work" - that's the whole shape of this
page. No `create` for a new row and a different `update` for an existing
one. One `save`, and it picks the right SQL statement on its own.

## The simplest save

`save` needs to know one thing about your class that [Query](query.md)
never did: which column is the primary key, so an `UPDATE` can find the
row again. Mark it with `@id`.

```bit
import { Data, TableDesc, save } from "orm"
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

fn savePerson(db: Data, p: Person): Person! {
  let result = save(db, personDesc(), personValues(p), p.isPersisted())?
  if (result.inserted) {
    let (id, ok) = result.generated["id"]
    if (ok) {
      p.id = intValue(id)
    }
  }
  p.markPersisted(true)
  return p
}

fn intValue(v: Value): i64 {
  match (v) {
    Int(n) => return n
    _ => return 0
  }
}

fn createPerson(db: Data, name: string, email: string): Person! {
  let p = Person{ id: 0, name: name, email: email }
  return savePerson(db, p)?
}
```

`Person{ id: 0, name: name, email: email }` is a composite literal, so
`p.isPersisted()` reads `false` and `save` emits an `INSERT` naming every
column, `id` included, as a `$n` placeholder - never the value pasted into
the SQL text. Postgres hands the row it actually wrote back through
`RETURNING`, and `result.generated["id"]` is how `createPerson` learns the
real, database-assigned id: a brand-new `Person` starts with `id: 0`, and
`0` is not what ends up in the `people` table.

`personDesc()` and `personValues(p)` are the one place `Person`'s shape is
spelled out - `save`/`delete`/`upsert` never read a field off `Person`
themselves, because `isPersisted`/`markPersisted`/`tableDescriptor` only
resolve on a concrete class, not on a type parameter (see "Why this isn't
generic", below). Every other function on this page calls `personDesc()`
and `personValues()` instead of rebuilding them.

## Saving a loaded row updates it

```bit
fn renamePerson(db: Data, p: Person, newName: string): Person! {
  p.name = newName
  return savePerson(db, p)?
}
```

A `Person` `find`/`findOneOrFail` (see [Query](query.md)) handed back reads
`p.isPersisted() == true` already - the row mapper set that flag at
hydration. `savePerson` doesn't ask which case it is: `save` reads
`p.isPersisted()` itself and emits `UPDATE people set id = $1, name = $2,
email = $3 where id = $4`, never inspecting `p.id`'s value to decide. That
matters because an application-assigned key, or a UUID generated before
the first save, is already non-zero on a row that has never touched the
database - `id == 0` would be the wrong test.

## The sharp edge: an UPDATE matching no row is an error

If another request already deleted `p`'s row, `renamePerson`'s `UPDATE`
matches zero rows - and `save` does not treat that as success:

```text
pkg/orm: update matched 0 rows in the class mapped to 'people' with key 42
```

A silent no-op here is the actual bug this catches: your process is still
holding a `Person` that no longer exists in the database, and without this
error the row would simply, invisibly, not update. Catch it the way any
other `error` is caught:

```bit
fn renameSafely(db: Data, p: Person, newName: string): Person! {
  p.name = newName
  return savePerson(db, p) catch e {
    fail newError("could not rename: ${e.message()}")
  }
}
```

## Deleting, and re-saving a deleted entity

```bit
import { delete } from "orm"

fn removePerson(db: Data, p: Person): ()! {
  delete(db, personDesc(), personValues(p))?
  p.markPersisted(false)
}
```

`delete` runs `DELETE FROM people WHERE id = $1` by the same primary key
`save`'s `UPDATE` uses. `p.markPersisted(false)` afterward is what makes
`savePerson(db, p)` on the same, now-deleted `p` emit an `INSERT` instead
of an `UPDATE` that would match nothing - the exact case the section above
catches, avoided here on purpose.

## upsert - insert or update in one statement, with two real limits

```bit
import { ServerDialect, upsert } from "orm"

fn upsertPersonByEmail(db: Data, p: Person): ()! {
  upsert(db, personDesc(), personValues(p), ServerDialect.Postgres, on = "email")?
}
```

This is `INSERT INTO people (...) VALUES (...) ON CONFLICT (email) DO
UPDATE SET ...` on Postgres, `ON DUPLICATE KEY UPDATE` on MySQL
(`ServerDialect.Mysql(version)`) - the statement CSV imports and sync jobs
actually want: one round trip, no "does this email already exist" query
first. `on` names a unique or primary-key column; the Bit field name,
translated the same way `where`'s column names are, never a raw SQL
identifier. Omit it and `upsert` uses the primary key.

A MySQL call here has to supply a `MysqlVersion` on `ServerDialect.Mysql`
that `upsert` never reads - `ON CONFLICT` vs `ON DUPLICATE KEY UPDATE` is a
syntax choice, not a version-gated one. `ServerDialect` (#5384) is the one
type every dialect-sensitive function in this package takes now, replacing
an earlier, narrower `UpsertDialect` that existed only for `upsert`; the
version-carrying shape came from [Locking](locking.md)'s `forUpdate`, which
does need a real MySQL version to gate `SKIP LOCKED`/`NOWAIT`. `Dialect`
(the schema-rendering interface, [Dialect](dialect.md)) is a different type
for a different question - "how do I render a migration's DDL," not "which
server am I talking to."

**`upsert` is never what `save` does by default, for two reasons that
matter in production:**

- **It cannot version-check.** There is no "which statement ran" for an
  optimistic-locking compare to gate on, because Postgres and MySQL both
  decide insert-or-update *inside* the one statement.
- **It can resurrect a row `delete` removed.** Insert-or-update means
  exactly that - a deleted row's email arriving again brings the row back,
  silently. `save` never does this; `upsert` always can.

Reach for it when you mean "this row should exist with these values,
whether or not it already did" - not as a faster `save`.

## Why this isn't generic

`save`/`delete`/`upsert` take a `TableDesc` (table name plus field list)
and a `map<string, Value>` of the entity's current column values, rather
than a `Person` directly the way you might expect from a language with
generics. `isPersisted()`/`markPersisted()`/`tableDescriptor()` only
resolve on a concrete `@table` class - inside a function generic over an
unconstrained `T`, the compiler cannot yet tell whether `T` carries them,
so the call is rejected as an unknown member. Until that changes,
`personDesc()`/`personValues()`/`savePerson()` above are the pattern:
write them once per entity, the same way [Query](query.md)'s `people(db)`
wraps `find<T>`.

`values` is keyed by Bit field name on purpose, not a positional list -
`save`/`delete`/`upsert` look up each column by name and panic naming the
field and the table if one is missing, so a field added to `Person` without
a matching entry in `personValues` fails loudly the first time it runs,
rather than quietly inserting the wrong value into the wrong column.

## Where to go next

[Query](query.md) covers reading rows back with `find`. [Naming](naming.md)
covers how `Person`'s field names become `people`'s column names.
[Schema](schema.md) covers declaring the `people` table itself.
