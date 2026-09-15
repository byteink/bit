# Bulk insert

Importing a CSV of 10,000 people with [`save`](write.md) in a loop is
10,000 INSERT statements, 10,000 round trips to the database - most of
that time is not the database doing work, it is the network between your
process and it, paid ten thousand times over. `insertAll` sends every row
in as few statements as it can.

## The simplest bulk insert

```bit
import { Data, TableDesc, insertAll } from "orm"
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
  }
}

fn personValues(p: Person): map<string, Value> {
  return map<string, Value>{
    "id": Value.Int(p.id),
    "name": Value.Text(p.name),
    "email": Value.Text(p.email),
  }
}

fn importPeople(db: Data, imported: []Person): []Person! {
  let rows = []map<string, Value>(0)
  for p of imported {
    rows = append(rows, personValues(p))
  }
  let generated = insertAll(db, personDesc(), rows)?
  let i = 0
  while (i < len(imported)) {
    let (id, ok) = generated[i]["id"]
    if (ok) {
      imported[i].id = intValue(id)
    }
    imported[i].markPersisted(true)
    i = i + 1
  }
  return imported
}

fn intValue(v: Value): i64 {
  match (v) {
    Int(n) => return n
    _ => return 0
  }
}
```

`personDesc()` and `personValues(p)` are the same two functions
[Write](write.md)'s `savePerson` uses - `insertAll` reads a `Person`'s
shape through them too, for the identical reason: `isPersisted`/
`markPersisted`/`tableDescriptor` only resolve on a concrete class, not
inside a function generic over an unconstrained `T` (see
[Write](write.md)'s "Why this isn't generic"). `importPeople` calls
`insertAll` once for the whole batch, then walks its result in the same
order it built `rows` - `generated[i]` is what the database wrote back for
`imported[i]`, and applying it is the caller's own job, the same division
`savePerson` already establishes for a single row.

For 3 rows this is one statement:

```text
insert into people (id, name, email) values ($1, $2, $3), ($4, $5, $6), ($7, $8, $9) returning *
```

## Why this isn't just `save` in a loop

Three rows through `save` is three round trips. `insertAll` is one round
trip carrying three `VALUES` groups - the database parses and plans the
statement once, and your process pays the network latency once instead of
three times. At 10,000 rows the difference is not a rounding error, it is
minutes versus seconds.

## The chunk size is computed, not guessed

Postgres caps a single statement at 65535 bound parameters. A `Person` row
binds 3 of them (`id`, `name`, `email`), so `importPeople` above can carry
at most `65535 / 3 = 21845` rows in one statement before it would exceed
that limit - `insertAll` works this division out from your class's own
column count, and splits a larger batch into that many statements instead
of one that Postgres would reject:

```bit
fn importManyPeople(db: Data, imported: []Person): []Person! {
  return importPeople(db, imported)? // 50,000 rows: 3 statements, not 1 and not 50,000
}
```

50,000 rows at 21845 per chunk is 3 statements (21845 + 21845 + 6310) -
`insertAll` never issues one statement per row, and it never guesses a
chunk size tuned to one entity's width and wrong for another's.

## The sharp edge: only Postgres, today

`insertAll` builds `... RETURNING *`, Postgres's own syntax for handing
back the rows a statement just wrote - the same limit
[Write](write.md)'s `upsert` documents for MySQL (`ON DUPLICATE KEY
UPDATE` has no `RETURNING` equivalent there either). A MySQL variant is
real, separate work, not attempted here.

## When not to use it

A handful of rows, or a single row you already have loaded, wants
[`save`](write.md) - `insertAll`'s whole benefit is round trips saved
across many rows at once, and building a `[]map<string, Value>` for one or
two rows is more code for no measurable gain.

## Where to go next

[Write](write.md) covers a single row: `save`, `delete` and `upsert`.
[Keyset pagination](keyset.md) covers the other scale problem, reading a
large table back a page at a time without `OFFSET` getting slower as you
page deeper.
