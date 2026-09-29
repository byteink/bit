# Naming

A `@table` class's fields are written the way Bit fields are always written
- camelCase, no underscores. SQL wants snake_case columns, and Postgres
folds an unquoted identifier to lower case anyway, so a table name has to be
lower case and predictable too. `pkg/orm/naming.bit` maps between the two,
in both directions - table names, column names, and reading a result row
back.

## Table names: snake_case of the class, never pluralized

```bit
import { Db, open } from "orm"

@table class Author {
  id: i64,
  name: string,
}

fn authorsTable(db: Db): []Author! {
  return db.table<Author>().all()? // reads from "author", not "authors"
}
```

`Author` maps to `author` - the class name, lower-cased, nothing added.
`OrderLine` maps to `order_line` the same way: split on the capital letters,
join with `_`, lower-case the whole thing. There is no pluralization step
and no irregular-noun list - the computed name is always singular, because
a guessed plural is exactly the kind of thing that is right for `Author`
and wrong for `Box`, and the override below exists for every case that
needs a different word.

Override it with `@table("...")`'s own argument when you want a different
name:

```bit
@table("people") class Person {
  id: i64,
}
```

`db.table<Person>()` now reads from `people`, not `person`. The override is
the whole table name, unchanged and unpluralized - `@table("people")` means
exactly `people`, never a hint this package pluralizes further.

kv's `store.collection<T>()` (`pkg/kv`) follows the identical rule for the
same reason: `@collection("...")` overrides, and a bare `@json` class name
is snake_cased with no pluralization, so the two packages agree on what a
class is called without a caller needing to remember which one pluralizes.

## Column names

A field name is snake_cased directly: `createdAt` -> `created_at`. A run of
capitals stays one word - `userID` -> `user_id`, `HTTPStatus` ->
`http_status`, never `user_i_d` or `h_t_t_p_status`. An already-snake_case
field name is unchanged, and no produced name ever starts with an
underscore.

`@column("...")` on a field overrides the derived name exactly, unchanged:

```bit
@table class Contact {
  id: i64
  @column("e_mail")
  email: string // column name is "e_mail", not "email"
}
```

## Reading a result back

Mapping a result column back to a field is driven by the class's own field
list, not by un-converting the column name: collapsing `userID` to `user_id`
loses whether it was `userID` or `userId`, so only the field list Bit
already has from the class declaration can answer it correctly. This is
also why `where`/`orderBy` ([Query](query.md)) take the Bit FIELD name
(`authorId`), never the SQL column (`author_id`) - the mapping only ever
needs to run in one direction at any one call site.

## Where to go next

[Schema](schema.md) declares the tables and columns whose names come from
these rules. [Query](query.md) matches a Bit field name against the same
rules when it builds a `where` or `orderBy` clause.
