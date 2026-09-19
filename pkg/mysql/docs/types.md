# Money, timestamps and MariaDB's own types

A payments table looks something like this:

```sql
create table payments (
  id uuid primary key default uuid(),
  amount decimal(12,2) not null,
  refunded_amount decimal(12,2),
  refunded_at timestamp,
  captured_at timestamp not null,
  payout_id uuid,
  source_ip inet4
);
```

Read straight off `rows.value(i)`, every one of those columns comes back as a
`std/sql.Value` - a five-variant union that only knows `Null`, `Int`, `Float`,
`Text` or `Blob`, never "this is money" or "this is an instant". Treat a
DECIMAL column's text as a float and a comparison that should be exact starts
drifting. Treat a `TIMESTAMP` as a bare string and you lose the fact that it
is already UTC and can be compared and stored as one. `mysqlDecimal` and
`mysqlInstant` (from `mysql`) turn the generic `Value` for one of these
columns into the specific Bit type, the same step `std/sql`'s own
`sqlReqInt`/`sqlReqBool` already do for the widths every SQL driver shares.

## Money: `mysqlDecimal`

```bit
import { Pool, Value } from "std/sql"
import { mysqlDecimal } from "mysql"

fn amountOf(db: Pool, id: string): decimal! {
  let rows = db.query("select amount from payments where id = $1", [Value.Text(id)])?
  defer rows.close()
  rows.next()?
  return mysqlDecimal("amount", rows.value(0))?
}
```

MySQL's binary protocol never gives DECIMAL or NUMERIC a dedicated binary
layout - the server sends the same length-encoded text `cast(amount as
char)` would produce, trailing zeros and all. `mysqlDecimal` is
`parseDecimal` (`std/decimal`) on that text, with the column's name folded
into any failure so the error says which column, not just "bad decimal". A
`decimal(65,30)` value with more digits than Bit's 96-bit `decimal` can hold
is one such failure - it is never silently rounded, and this package never
pre-rounds a value on the way out either; a write past the column's own range
is left for the server to reject.

## When: `mysqlInstant`, and why DATETIME is refused

MySQL has two "date and time" types, and if you already know Postgres they
are a trap: Postgres's `timestamptz` is the zone-aware one, but in MySQL it
is the other way around. `TIMESTAMP` is zone-aware; `DATETIME` is a bare
wall-clock reading that nothing on the wire converts.

```bit
import { mysqlInstant } from "mysql"
import { Timestamp } from "std/time"

fn capturedAt(db: Pool, id: string): Timestamp! {
  let rows = db.query("select captured_at from payments where id = $1", [Value.Text(id)])?
  defer rows.close()
  rows.next()?
  return mysqlInstant("captured_at", rows.value(0))?
}
```

Point that same query at a `datetime` column instead and it fails, naming the
column and pointing at the type that would have worked:

```
mysql: column 'captured_at' is DATETIME, which has no time zone and is refused; use TIMESTAMP instead
```

Decoding DATETIME as an instant would have to invent a zone - there is
nothing on the wire to convert with - so the driver refuses rather than
guessing UTC, the server's zone, or the connecting process's zone. If a table
genuinely has a `datetime` column, read it with `std/sql`'s `asText` and
treat it as the wall-clock string it is, never as an instant.

`TIMESTAMP`'s conversion depends on the connection's `time_zone` session
variable. This package's `connect()` pins every connection it opens to
`time_zone='+00:00'` before your code runs a single query, so `mysqlInstant`
reads UTC regardless of what the server administrator has set as the
default - you never call `set time_zone` yourself, and a server-side default
changing under you cannot silently change what your program reads.

## Dates and times: `mysqlDate`, `mysqlTime`

```bit
import { mysqlDate, mysqlTime } from "mysql"
import { Date } from "std/time"

fn shippedOn(db: Pool, id: string): Date! {
  let rows = db.query("select ship_date from payments where id = $1", [Value.Text(id)])?
  defer rows.close()
  rows.next()?
  return mysqlDate("ship_date", rows.value(0))?
}
```

`mysqlDate` reads a `DATE` column as `std/time.Date`. MySQL will also store
`0000-00-00` - a real value outside strict mode - which `mysqlDate` refuses
rather than guesses at: `Date` has no year-0 to represent it as, and `None`
already means SQL `NULL`, so returning it there would conflate a stored
zero date with an absent one.

`mysqlTime` reads a `TIME` column, and its return type is deliberately
`int`, not `std/time.Time`: MySQL's `TIME` is a **duration**, spanning
`-838:59:59` to `838:59:59` - negative, and past 24 hours - neither of
which a time-of-day type can hold. The `int` is nanoseconds, the same
duration idiom `std/time.Second`/`Hour` already use:

```bit
import { Second } from "std/time"

fn prepTimeOf(db: Pool, id: string): int! {
  let rows = db.query("select prep_time from recipes where id = $1", [Value.Text(id)])?
  defer rows.close()
  rows.next()?
  let ns = mysqlTime("prep_time", rows.value(0))?
  return ns / Second // whole seconds, if that's what the caller wants
}
```

Both wire encodings are length-prefixed and variable-width - a `DATE` is
0, 4, 7 or 11 bytes depending on how much precision is present, and `TIME`
carries its own sign byte and day count - but that decoding already happens
in this package's wire layer; `mysqlDate`/`mysqlTime` parse the
server-rendered text it produces, the same text either protocol (`query`
vs a bound statement) hands back.

## Nullable columns

Every accessor above has an `Opt` twin that reads a SQL `NULL` as `None`
rather than failing - the same shape `std/sql`'s `sqlOptInt`/`sqlOptText`
already use for the widths they cover.

```bit
import { mysqlOptDecimal, mysqlOptInstant } from "mysql"

fn refundOf(db: Pool, id: string): (Option<decimal>, Option<Timestamp>)! {
  let rows = db.query(
    "select refunded_amount, refunded_at from payments where id = $1",
    [Value.Text(id)],
  )?
  defer rows.close()
  rows.next()?
  return (
    mysqlOptDecimal("refunded_amount", rows.value(0))?,
    mysqlOptInstant("refunded_at", rows.value(1))?,
  )
}
```

A refund that has not happened yet reads as `None`, not as a zero amount or
an error - the column really is `NULL`, and a zero would be a lie about a
refund that was issued for nothing.

## JSON: `mysqlJson`

MySQL 5.7+ and MariaDB disagree about what a `JSON` column even is, and it
is not cosmetic. MySQL has a native `JSON` type with its own binary wire
representation; MariaDB has none - `JSON` there is `LONGTEXT` under a
`CHECK` constraint, so it always arrives as ordinary text. Decoding
MariaDB's text as though it were MySQL's binary format produces garbage
that looks like a parse bug rather than a wrong assumption.

```bit
import { mysqlJson } from "mysql"
import { Json } from "std/json"

fn metadataOf(db: Pool, id: string): Json! {
  let rows = db.query("select metadata from payments where id = $1", [Value.Text(id)])?
  defer rows.close()
  rows.next()?
  return mysqlJson("metadata", rows.value(0))?
}
```

`mysqlJson` detects which shape it was handed by the bytes themselves,
not by which server the connection is talking to: a parameterless query
stays on the text protocol even against a real MySQL `JSON` column (see
[Queries](queries.md)), so "the server is MySQL" is not the same claim as
"these bytes are MySQL's binary format" - reading the leading byte is.
Text - MariaDB always, MySQL whenever the query used the text protocol -
goes through `std/json.jsonParse`; MySQL's binary tag format is decoded
by this package's own reader, in one pass over the wire bytes.

## MariaDB's own types: UUID and INET4/INET6

MariaDB (10.7+) adds native `UUID`, `INET4` and `INET6` column types that
MySQL does not have. None of the three needs a wire-level change in this
driver: MariaDB sends all three as an ordinary length-encoded string, so
`INET4` and `INET6` already decode to `Value.Text` through the same
unmapped-type fallthrough every unrecognized type gets, and `mysqlUuid` is
`std/uuid.parse` on a MariaDB `UUID` column's text, wrapped the same way as
`mysqlDecimal` and `mysqlInstant`.

```bit
import { asText } from "std/sql"
import { mysqlUuid, mysqlOptUuid } from "mysql"
import { UUID } from "std/uuid"

class Payment {
  id: UUID,
  payoutId: Option<UUID>,
  sourceIp: string,
}

fn paymentById(db: Pool, id: string): Payment! {
  let rows = db.query(
    "select id, payout_id, source_ip from payments where id = $1",
    [Value.Text(id)],
  )?
  defer rows.close()
  rows.next()?
  return Payment{
    id = mysqlUuid("id", rows.value(0))?,
    payoutId = mysqlOptUuid("payout_id", rows.value(1))?,
    sourceIp = asText(rows.value(2))?,
  }
}
```

A payment not yet linked to a payout has `payout_id` `NULL` in the table, so
`payoutId` above reads `None` rather than failing to parse an empty string as
a UUID.

## The rest of the type table needs no codec here

`TINYINT(1)`, MySQL's conventional bool column, already decodes to
`Value.Int` - read it with `std/sql`'s `sqlReqBool` when the field is a
`bool`, or `sqlReqInt` when it is an `i64`; the field you are reading into
decides. See [Queries](queries.md) for how a column's real type only comes
back at all once a query goes through the binary protocol - a
parameterless query stays on `COM_QUERY` and every column of it comes back
as `Value.Text`, `1` and all, regardless of its declared type.

## Where to go next

- [Queries](queries.md) - `query` vs `exec` vs `prepare`, and why only a
  bound statement gets a real type back
- [Errors](errors.md) - matching a server error by code, and what a
  `FatalError` does to the connection pool
- [Limitations](limitations.md) - what this driver does not decode yet
