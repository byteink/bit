# Enum columns

A post's status is one of a fixed few states: draft, active, archived.
Storing it as a bare integer (`0`, `1`, `2`) is compact, but reordering the
enum in your Bit source silently remaps every existing row: no error, no
migration, and `select * from posts` shows `0`/`1`/`2` to anyone debugging.
A native database enum type looks like the fix, but adding a value to
Postgres' own `ALTER TYPE ... ADD VALUE` cannot run inside a transaction
before Postgres 12, and MySQL's `ENUM(...)` is a completely different
mechanism with nothing like it on Postgres. The type diverges hardest on
the operation you do most often. `enumColumnDef` (`pkg/orm/enumcol.bit`)
renders what this package uses instead: a plain `text` column, `not null`,
with a CHECK constraint listing every variant by name - the variant's own
**name** is what gets stored, never its position.

## Declare the enum

Bit has no reflection, so nothing can read `PostStatus`'s own variant
names or convert a value to one automatically. You write both, once, the
same way any `@table` class writes its own field-filling code:

```bit
enum PostStatus {
  Draft
  Active
  Archived

  export name(): string {
    match (this) {
      Draft => return "Draft"
      Active => return "Active"
      Archived => return "Archived"
    }
  }
}

fn parsePostStatus(text: string): Option<PostStatus> {
  if (text == "Draft") {
    return Option.Some(PostStatus.Draft)
  }
  if (text == "Active") {
    return Option.Some(PostStatus.Active)
  }
  if (text == "Archived") {
    return Option.Some(PostStatus.Archived)
  }
  return Option.None
}

fn postStatusVariants(): []string {
  return ["Draft", "Active", "Archived"]
}
```

## Render the column

```bit
import { enumColumnDef } from "orm"

fn statusColumnDdl(): string {
  return enumColumnDef("status", postStatusVariants())
}
```

`statusColumnDdl()` returns:

```text
status text not null check (status in ('Draft','Active','Archived'))
```

exactly, on both dialects - `text`, `not null` and `check (col in (...))`
are identical syntax on Postgres and MySQL for this shape, so there is
only one `enumColumnDef`, not one per dialect.

## Add it to a table

`Table` has no `t.enum(...)` builder - a CHECK constraint is exactly what
`t.raw(...)` is for (see [Schema](schema.md)'s own header on why `raw()`
is the escape hatch for a shape no builder expresses). A plain
`t.text("status")` gives the `not null text` column; a raw `ALTER TABLE
... ADD CONSTRAINT` right after gives it its CHECK, built from the same
`enumCheckName`/`enumVariantList` `enumColumnDef` itself uses, so the
constraint's name and its quoting stay consistent with everything else
this package renders:

```bit
import { SchemaOp, enumCheckName, enumVariantList, table } from "orm"

fn postsTable(): SchemaOp {
  let name = enumCheckName("posts", "status")
  let variants = postStatusVariants()
  return table("posts", (t) => {
    t.id("id")
    t.text("status")
    t.raw("alter table \"posts\" add constraint \"${name}\" check (status in (${enumVariantList(variants)}));")
  })
}
```

`Postgres{}.render(postsTable())` renders two statements: the `CREATE
TABLE` with `status` as an ordinary `not null text` column, then the `ALTER
TABLE ... ADD CONSTRAINT ... CHECK` naming every variant - both run inside
the same migration transaction on Postgres, so a table with `status`
holding anything outside the three declared variants never exists even
for an instant.

## Write a value in, read it back

```bit
import { enumColumnRead, enumColumnValue } from "orm"
import { Value } from "std/sql"

fn storeStatus(s: PostStatus): Value {
  return enumColumnValue<PostStatus>(s, (v) => v.name())
}

fn readStatus(v: Value): PostStatus! {
  return enumColumnRead<PostStatus>(v, "status", "PostStatus", parsePostStatus)?
}
```

`storeStatus(PostStatus.Active)` binds `Value.Text("Active")` - the
variant's name, never `1`. `readStatus` on that same value returns
`PostStatus.Active` back: `enumColumnValue`/`enumColumnRead` are a plain
pair, generic over any enum whose caller supplies a `name`/`parse`
function this same shape, not something written once per enum type.

**An unrecognised stored value is never the first variant.** A row
written by another service, or one that predates a removed variant, fails
loudly instead of quietly becoming `PostStatus.Draft`:

```bit
fn readUnknownStatus(): PostStatus! {
  return readStatus(Value.Text("Deleted"))?
}
```

`readUnknownStatus()` fails with:

```text
pkg/orm: column 'status' holds 'Deleted', not a variant of PostStatus
```

naming the column, the raw value and the enum - a wrong answer that looks
like real data is worse than a crash here, the same rule
[JSON columns](json.md) states for invalid stored bytes.

## Changing the variants later

Adding `Retired` means every existing row already satisfies the new list,
so the migration only has to widen the CHECK - drop the old constraint,
add it back with all four names, in one statement. There is no `AlterOp`
for "change a CHECK" (see [Schema](schema.md) for the ops that exist), so
you call the dialect function directly - `enumCheckAlter` on Postgres,
`mysqlEnumCheckAlter` on MySQL:

```bit
import { enumCheckAlter } from "orm"

fn addRetiredVariantSql(): string {
  let variants = ["Draft", "Active", "Archived", "Retired"]
  return enumCheckAlter("posts", "status", variants).sql
}
```

`addRetiredVariantSql()` returns:

```text
alter table "posts" drop constraint "posts_status_check", add constraint "posts_status_check" check (status in ('Draft','Active','Archived','Retired'));
```

`mysqlEnumCheckAlter` renders the identical change with MySQL's own
keyword: `drop check "posts_status_check"` becomes `` drop check
`posts_status_check` ``, never Postgres' `drop constraint`.

**Removing a variant renders through the same function - and fails loudly
on the rows still holding it.** Adding `add constraint ... check (...)`
validates every existing row against the new list; a row still holding a
value you just removed rejects the whole statement rather than silently
keeping an orphaned value around. That failure is [classify](errors.md)'s
own `CheckViolation` (SQLSTATE `23514`), the same typed error every other
constraint violation in this package raises.

**Reordering the enum emits nothing.** `enumVariantsChanged` compares two
variant lists as sets, never as sequences:

```bit
import { enumVariantsChanged } from "orm"

fn reorderIsANoOp(): bool {
  return !enumVariantsChanged(
    ["Draft", "Active", "Archived"],
    ["Archived", "Draft", "Active"],
  )
}
```

`reorderIsANoOp()` returns `true` - resorting `PostStatus`'s own
declaration for readability changes nothing about what a migration should
emit, because the variant's **name** is what a row carries, never its
declaration position.

**You don't have to call `enumCheckAlter` yourself.** Declare the field's
variant list on the entity with `@enumVariants("Draft", "Active",
"Archived", "Retired")` instead of a free-floating list, and
[Generate](generate.md) reads the live CHECK back and renders this exact
drop-and-recreate for you the next time you run it - the same SET
comparison shown above, wired into the live diff rather than something
you call by hand.

## Sharp edges

**Renaming what `name()` returns for a variant is not free.** Reordering
the enum's declaration is a no-op because the stored value is the name,
not the position - but if you change `PostStatus.Active`'s own `name()`
from `"Active"` to `"Published"`, every row still holding the string
`"Active"` now fails the new CHECK and `enumColumnRead` on it. That is a
real data migration (`UPDATE posts SET status = 'Published' WHERE status =
'Active'`, then the CHECK change), not something this package infers or
guesses at.

**There is no nullable enum column built in.** `enumColumnDef` always
renders `not null`; a nullable status field needs its own `.nullable()`
handling the way [JSON columns](json.md)' own "A SQL NULL and a JSON null
are different" section handles `Option<Json>` - convert `None` to
`Value.Null` before calling `enumColumnValue`, and check for `Value.Null`
before calling `enumColumnRead`.

## Where to go next

[Schema](schema.md) covers `t.raw()` and every other `ColumnType` a table
can carry. [Dialect](dialect.md) and [MySQL](mysql.md) cover the
`Dialect` interface `Postgres{}.render`/`Mysql{}.render` implement.
[Errors](errors.md) covers `classify` and every typed constraint-violation
cause, `CheckViolation` among them. [Write](write.md) covers `save`, where
a `map<string, Value>` built with `enumColumnValue` usually ends up.
[Generate](generate.md) covers `@enumVariants` and the live CHECK diff in
full.
