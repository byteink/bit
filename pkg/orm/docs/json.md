# JSON columns

A webhook receiver stores what the sender posted so it can be replayed or
inspected later. Every provider sends a different shape - one has
`{"event": "paid", "amount": 500}`, another nests three levels deep - and
there is no single table wide enough for all of them. A `text` column
keeps the bytes, but the database cannot see inside them: nothing stops a
row from holding `not even json`, and reading one field back means
parsing the whole column by hand, every time. `t.json(...)` declares a
real `jsonb` (Postgres) / `json` (MySQL) column for exactly this, and
`jsonColumnValue`, `jsonColumnRead` and `jsonColumnDecode<T>`
(`pkg/orm/jsoncol.bit`) are the write and read halves that go with it.

## Declare the column

```bit
import {
  JsonColumnError,
  Mysql,
  Postgres,
  SchemaOp,
  alter,
  jsonColumnDecode,
  jsonColumnRead,
  jsonColumnValue,
  table,
} from "orm"
import { Json, JsonEntry, jsonEncode } from "std/json"
import { Value } from "std/sql"

fn eventsTable(): SchemaOp {
  return table("events", (t) => {
    t.id("id")
    t.json("payload")
  })
}
```

`Postgres{}.render(eventsTable())` renders:

```text
create table "events" (
  "id" bigint generated always as identity primary key,
  "payload" jsonb not null
);
```

`Mysql{}.render(eventsTable())` renders the same table with lowercase
`json` instead:

```text
create table `events` (
  `id` bigint auto_increment primary key,
  `payload` json not null
);
```

`t.json(name)` is the one builder for a JSON column on either dialect -
`jsonb` on Postgres, `json` on MySQL - and it does not care whether the
Bit-side value is a raw `Json` tree or a class carrying `@json`; both go
through the same column.

## Adding one to a table that already exists

`AlterTable.addJson` is `Table.json`'s own sibling for `alter`:

```bit
fn addMetaColumn(): SchemaOp {
  return alter("events", (t) => {
    t.addJson("meta").nullable()
  })
}
```

```text
alter table "events" add column "meta" jsonb;
```

`.nullable()` here matters: `meta` is going to carry who redelivered an
event and how many times, something old rows were written before this
column existed and will never have. See "A SQL NULL and a JSON null are
different" below for what that means on the Bit side.

## Write a value in, read it back

```bit
fn nonCanonicalPayload(): Json {
  return Json.JsonObject(
    [
      JsonEntry{ key = "b", value = Json.JsonInt(2) },
      JsonEntry{ key = "a", value = Json.JsonString("x") },
      JsonEntry{ key = "a", value = Json.JsonBool(true) },
    ],
  )
}

fn writeAndReadPayload(): Json! {
  let bound = jsonColumnValue(nonCanonicalPayload())
  return jsonColumnRead(bound, "payload")?
}
```

`nonCanonicalPayload()` is deliberately messy on purpose: `"b"` before
`"a"`, and `"a"` written twice. `jsonColumnValue` does not sort or dedupe
it - it just encodes the tree, so the text bound to the column is exactly
`{"b":2,"a":"x","a":true}`. `jsonColumnRead` parses that same text back
with `jsonParse`, so `writeAndReadPayload()` returns the identical tree:
`jsonEncode` on the result is still `{"b":2,"a":"x","a":true}`.

**That equality is a property of this package, not of a live database.**
`jsonColumnValue`/`jsonColumnRead` round-trip through Bit's own encoder
and parser - there is no Postgres or MySQL between the two calls above. A
real `jsonb`/`json` column reparses the text the moment it is written:
the duplicate `"a"` key collapses to one value, insignificant whitespace
disappears, and nothing guarantees the key order you wrote survives.
Write `nonCanonicalPayload()` to a live `jsonb` column and read it back
later, and you get a document with one `"a"` key, not two, and no
promise it comes back in the order you sent it. If you need to compare a
stored payload against what you originally sent - a checksum, a
signature, an equality assertion in a test - compare the parsed `Json`
values, never the raw bytes.

## A `@json` class field

```bit
@json class EventMeta {
  source: string,
  retryCount: i64,
}

fn writeAndReadMeta(): EventMeta! {
  let meta = EventMeta{ source = "webhook", retryCount = 2 }
  let bound = jsonColumnValue(meta.toJson())
  return jsonColumnDecode<EventMeta>(bound, "meta")?
}
```

`writeAndReadMeta()` returns an `EventMeta` with `source == "webhook"` and
`retryCount == 2`: `meta.toJson()` (synthesized by `@json`) builds the
tree, `jsonColumnValue` encodes it the same way it encodes any other
`Json`, and `jsonColumnDecode<T>` parses the stored text and decodes it
into `T` - `EventMeta` here, but the function itself is generic, so it
never needed writing per class.

**Why `jsonColumnDecode<T>` goes through `jsonParse` and `jsonDecode<T>`
and not `jsonDecodeText<T>`.** `jsonDecodeText<T>` is specialised by
rewriting the call site to the concrete class named in its turbofish, and
refuses a bare type parameter outright - calling it from inside
`jsonColumnDecode<T>` (itself generic over `T`) fails to compile with
`E0145`:

```text
'jsonDecodeText' cannot decode into 'T': it is a type parameter, and the
text entry point is specialised by rewriting the call rather than
through the instantiation ledger
```

`jsonDecode<T>`, taking an already-parsed `Json` instead of raw text, has
no such restriction, which is why `jsonColumnDecode<T>` parses first and
decodes second instead of calling a text entry point directly. Worth
remembering before "simplifying" it back to one call.

## A SQL NULL and a JSON `null` are different

A stored JSON `null` is a **value** - `jsonColumnValue` never produces a
SQL NULL, even for `Json.JsonNull`:

```bit
fn storedJsonNull(): Value {
  return jsonColumnValue(Json.JsonNull)
}
```

`storedJsonNull()` binds `Value.Text("null")` - three bytes, a row that
holds the JSON literal `null`. A column with **no** value at all is a
different thing, and this package never conflates the two: reading a
column that is actually a SQL NULL fails, naming the column, rather than
quietly becoming `Json.JsonNull` or some zero value that looks like real
data once it is sitting in a variable:

```bit
fn readMetaOrFail(v: Value): Json! {
  return jsonColumnRead(v, "meta")?
}
```

Calling `readMetaOrFail(Value.Null)` fails with:

```text
pkg/orm: column 'meta' is not usable as JSON: sql: value is not Text
```

the same for `jsonColumnDecode<T>`. Nullability is `meta`'s own concern
(the `.nullable()` above, and `Option<T>` for the Bit-side field - see
[Schema](schema.md)'s "Money columns" section for the identical mechanism
on `decimal`), never something either read path silently absorbs. A
caller with a nullable JSON field checks for `Value.Null` itself, before
reaching this package, and wraps the result back into `Option<Json>`
after:

```bit
fn metaValue(meta: Option<Json>): Value {
  match (meta) {
    Some(j) => return jsonColumnValue(j)
    None => return Value.Null
  }
}

fn readMeta(v: Value, column: string): Option<Json>! {
  match (v) {
    Null => return Option<Json>.None
    _ => {
      let j = jsonColumnRead(v, column)?
      return Option<Json>.Some(j)
    }
  }
}
```

`metaValue(Option<Json>.None)` writes a real SQL NULL. `readMeta` checks
for that NULL first and only calls `jsonColumnRead` on a value that
really is JSON text - `readMeta(Value.Null, "meta")` returns `None`, not
an error, because the `Null` branch above catches it before
`jsonColumnRead` ever sees it.

## Invalid bytes are an error too

A row whose stored bytes are not valid JSON at all - truncated, hand
edited, written by something outside this package - fails the same way,
naming the column and carrying the underlying parse error:

```bit
fn readCorruptedPayload(v: Value): Json! {
  return jsonColumnRead(v, "payload")?
}
```

`readCorruptedPayload(Value.Text("{not json"))` fails with `column
'payload' is not usable as JSON`, never with an empty value that would
hide a corrupted row. Both failures - a SQL NULL and invalid bytes - are
a `JsonColumnError`, catchable as one type regardless of which one hit.

## When not to use this

Querying *inside* a stored document - `payload->>'event' = 'paid'` - is
not this file's job; no builder here adds a JSON path operator.
[`whereRaw`](raw.md) is the escape hatch for exactly that, the same as
for any other expression the rest of this package's builders do not
express.

## Where to go next

[Schema](schema.md) covers `.nullable()` and every other `ColumnType`
`t.json` sits beside. [Dialect](dialect.md) and [MySQL](mysql.md) cover
the `Dialect` interface `Postgres{}.render`/`Mysql{}.render` implement.
[Raw SQL and dynamic columns](raw.md) covers `whereRaw` for querying
inside a document. [Write](write.md) covers `save`, which is where a
`map<string, Value>` built with `jsonColumnValue` usually ends up.
