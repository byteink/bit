# Naming

A `@table` class's fields are written the way Bit fields are always written
- camelCase, no underscores. SQL wants snake_case columns and pluralised
table names; JSON keys (`@json`, `@key`) are a third, unrelated naming and
are never touched here. `pkg/orm/naming.bit` maps between the two, in both
directions.

## Table names

`className` is pluralised by four rules, checked in order, with no
irregular-noun list:

1. ends `s`, `x`, `z`, `ch` or `sh` -> `+es` - `Box` -> `Boxes`, `Class` -> `Classes`
2. ends in a consonant then `y` -> drop the `y`, `+ies` - `Company` -> `Companies`
3. otherwise -> `+s` - `User` -> `Users`, `Order` -> `Orders`

Then the pluralised name is snake_cased: `OrderLine` -> `OrderLines` ->
`order_lines`.

This gets `Person` -> `persons`, which is the wrong English word for it. That
is accepted on purpose: an irregular-noun list is English-only and turns
into a permanent stream of "why is this noun handled and not that one"
reports. Write the real name on the class instead, with `@table("...")`'s
own argument:

```bit
import { tableName } from "orm"
import { FieldDesc, AttrDesc } from "std/sql"

@table("people") class Person {
  id: i64,
}

fn showTableNames() {
  println(tableName("Person", Person{ id: 0 }.tableAttrs())) // "people"
  println(tableName("Order", []AttrDesc(0)))                 // "orders" - the four rules, no override
}
```

`tableName`'s second argument is the class's own synthesized
`tableAttrs(): []AttrDesc` - `@column`'s counterpart for the class itself,
carrying `@table`'s argument the identical way a field's `@column("...")`
override reaches `FieldDesc.attrs`.

## Column names

A field name is snake_cased directly: `createdAt` -> `created_at`. A run of
capitals stays one word - `userID` -> `user_id`, `HTTPStatus` ->
`http_status`, never `user_i_d` or `h_t_t_p_status`. An already-snake_case
field name is unchanged, and no produced name ever starts with an
underscore.

`@column("...")` on a field overrides the derived name exactly, unchanged
and unpluralised:

```bit
@table class Contact {
  @column("e_mail")
  email: string // column name is "e_mail", not "email"
}
```

## Reading a result back

Mapping a result column back to a field is driven by the class's own
descriptor (`fieldForColumn`), not by un-converting the column name: collapsing
`userID` to `user_id` loses whether it was `userID` or `userId`, so only the
actual field list - the thing the descriptor already has - can answer it
correctly.
