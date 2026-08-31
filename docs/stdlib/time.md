# std/time

Dates, times, time zones, durations, clocks and timers.

<!-- doctest: per-block -->

## Status of this document

This page is **both** the reference for what ships today and the specification for
the calendar rewrite that replaces the UTC-only calendar API.

| Part | State |
|---|---|
| Durations, clocks, sleeping, timer channels | **Shipped.** Unchanged by the rewrite. |
| Dates, times, zones, formatting, parsing | **Specified, not yet implemented.** |
| The `Civil` calendar API | **Shipped, superseded.** See [Superseded API](#superseded-api). |

Every example in a specified section is fenced ```` ```bit ignore ```` because the
API it shows does not exist yet and would fail the doc-snippet gate. Examples in
shipped sections compile.

---

## Design

### Six types, because a "moment" is six different things

A single date-time type cannot be correct. An invoice value date, a shop's opening
hour, and the instant a row was written are not the same kind of value, and storing
them in one type is how a date shifts by a day when a server moves country.

| Type | Holds | Knows a zone | Example |
|---|---|---|---|
| `Date` | year, month, day | no | an invoice value date |
| `Time` | hour, minute, second, nanosecond | no | a shop opening at `09:00` |
| `NaiveDateTime` | a `Date` and a `Time` | no | "9am on the 1st", somewhere |
| `DateTime` | a `NaiveDateTime`, a `Zone`, an offset | **yes** | 9am on the 1st in Dubai |
| `Timestamp` | nanoseconds since the Unix epoch | n/a | what a database column holds |
| `Zone` | an IANA zone identity | — | `Asia/Dubai` |

`Mono`, the monotonic clock reading, is a seventh type and is unrelated to the
calendar. It measures elapsed time and nothing else.

### Choosing a type

| The value is | Use |
|---|---|
| a calendar day with no time of day | `Date` |
| a time of day with no date | `Time` |
| a wall clock reading whose zone is not yet known | `NaiveDateTime` |
| an appointment a person will keep in a named place | `DateTime` |
| when something happened, for storage or comparison | `Timestamp` |
| how long something took | `int` nanoseconds, from `since` |

When in doubt between `DateTime` and `Timestamp`: if moving the value to another
country must **change the number a user sees**, it is a `DateTime`. If it must
**not change the moment**, it is a `Timestamp`.

### Immutability

Every value of every type is immutable. Every operation returns a new value and
never modifies its receiver. This makes every type safe to share across green
threads with no synchronisation, and it removes the class of bug where passing a
date to a function silently changes the caller's copy.

### Failure

Construction and parsing are fallible and return `T!`. Everything else is total.

| Operation | Fallible |
|---|---|
| `date`, `time`, `dateTime` | yes — out-of-range fields |
| `parseDate`, `parseTime`, `parseNaiveDateTime`, `parseDateTime`, `parseWith` | yes — malformed input |
| `zone` | yes — unknown identifier, or no zone data on the host |
| `Date.toTimestamp`, `DateTime.toTimestamp` | yes — outside the representable instant range |
| arithmetic, snapping, comparison, differences, formatting | **no** |
| `NaiveDateTime.inZone`, `DateTime.withZone` | **no** |

`inZone` is total on purpose. Every wall-clock reading maps to exactly one instant
under the disambiguation rules below, so there is nothing left to fail on.

### Ranges

| Type | Range | Why |
|---|---|---|
| `Date`, `NaiveDateTime` | years **1 through 9999** | proleptic Gregorian, no BC |
| `Time` | `00:00:00.000000000` to `23:59:59.999999999` | no leap second |
| `Timestamp` | `1677-09-21T00:12:43.145224192Z` to `2262-04-11T23:47:16.854775807Z` | signed 64-bit nanoseconds |

**The `Timestamp` range is narrower than the `Date` range, and that is deliberate.**
A date of birth in 1890 is a perfectly good `Date` and cannot be a `Timestamp`.
Store dates of birth, historical value dates and far-future maturity dates as
`Date`, not as an instant. `Date.toTimestamp` fails rather than wrapping.

Leap seconds do not exist in this module. A `:60` second is rejected on parse and
cannot be constructed. Every day is exactly 86,400 seconds of UTC.

---

## Zones

### `Zone`

An IANA time zone, identified by its canonical name — `Asia/Dubai`,
`Europe/London`, `UTC`. Immutable and safe to share. Two `Zone` values naming the
same zone are equal.

A `Zone` is not an offset. `Asia/Dubai` is permanently `+04:00`, but
`Europe/London` is `+00:00` for part of the year and `+01:00` for the rest, and a
zone's rules change when a government changes them. The offset is a property of a
zone **at an instant**, never of the zone alone.

### `zone(name: string): Zone!`

Loads the zone named `name`. Fails when the name is not a zone the host knows.

Zone data is read from the host's own database — `/usr/share/zoneinfo` on Linux
and macOS — not from a copy bundled into the binary. Governments change daylight
saving rules around ten times a year, so a bundled copy would tie correctness to
the compiler release schedule.

That has one consequence worth planning for: **a `scratch` or `distroless`
container has no zone database, and neither does Windows.** In those environments
`zone` fails for every name except `UTC`. Import `bitlang.org/pkg/tzdata` to embed
a copy; importing it is the entire configuration.

### `utc(): Zone`

The UTC zone. Always available, never fails, never has a transition.

### `localZone(): Zone`

The host's own zone, read from `/etc/localtime`. Returns `utc()` when the host
provides no zone information.

Prefer an explicit `zone("Asia/Dubai")` in server code. The host's zone is a
property of the machine, not of the business, and a machine moves.

```bit ignore
import { zone, utc, localZone } from "std/time"

fn zones(): Zone! {
  let dubai = zone("Asia/Dubai")?
  let london = zone("Europe/London")?
  return dubai
}
```

### Daylight saving: the two awkward days

Twice a year a zone that observes daylight saving moves its clocks, and on those
two days the mapping between a wall clock and an instant is not one-to-one.

**The spring gap.** On 2026-03-29 in `Europe/London`, the clock goes straight from
`01:00` to `02:00`. The wall times `01:00:00` through `01:59:59.999999999` never
happen.

> `inZone` **pushes forward by the size of the gap.** `01:30` becomes `02:30`.
> It does not fail.

**The autumn overlap.** On 2026-10-25 in `Europe/London`, the clock goes back from
`02:00` to `01:00`. The wall times `01:00:00` through `01:59:59.999999999` happen
twice, once at `+01:00` and again at `+00:00`.

> `inZone` **takes the first occurrence** — the one with the earlier offset.

Both rules are total and deterministic. A scheduled job that runs at `01:30` runs
exactly once a day, every day, in every zone, and never raises an error on one day
a year in one country.

```bit ignore
import { zone, date } from "std/time"

fn springGap(): DateTime! {
  let london = zone("Europe/London")?
  // 01:30 does not exist on this day; the result is 02:30 +01:00.
  return date(2026, 3, 29)?.atTime(1, 30, 0)?.inZone(london)
}
```

### Arithmetic across a transition

Calendar arithmetic on a `DateTime` keeps the **wall clock** and lets the elapsed
physical time absorb the transition. This is what a person means by "same time
tomorrow".

```bit ignore
import { zone, date } from "std/time"

fn twentyFiveHours(): int! {
  let london = zone("Europe/London")?
  let before = date(2026, 10, 24)?.atTime(9, 0, 0)?.inZone(london)
  let after = before.addDays(1)

  // after.hour() is 9 — the wall clock is unchanged.
  // The elapsed real time is 25 hours, because the clocks went back.
  return after.toTimestamp()?.ns - before.toTimestamp()?.ns
}
```

Both facts are true at once, and both matter. A daily 9am report must still run at
9am. A billing period must still be measured in real elapsed time. Use
`differenceInDays` for the first and `Timestamp` subtraction for the second.

To add real elapsed time instead, go through the instant:

```bit ignore
import { Hour } from "std/time"

fn plusRealHours(t: DateTime, n: int): DateTime! {
  return t.toTimestamp()?.add(n * Hour).inZone(t.zone())
}
```

---

## Constructing

### `date(year: int, month: int, day: int): Date!`

Fails when `month` is outside 1..12, when `day` is outside 1..(days in that month,
leap years included), or when `year` is outside 1..9999.

### `time(hour: int, minute: int, second: int): Time!`

Nanoseconds are zero. Fails when `hour` is outside 0..23, `minute` outside 0..59,
or `second` outside 0..59. A `second` of 60 is rejected.

### `timeNs(hour: int, minute: int, second: int, nanosecond: int): Time!`

As `time`, with an explicit nanosecond field in 0..999999999.

### `today(z: Zone): Date`

The calendar date it is right now in `z`. Total — the current instant is always
inside the representable range.

### `now(): Timestamp`

The current instant. See [Clocks](#clocks).

```bit ignore
import { date, time, timeNs, today, zone } from "std/time"

fn build(): Date! {
  let d = date(2026, 9, 1)?
  let t = time(9, 0, 0)?
  let precise = timeNs(9, 0, 0, 500000000)?
  let dubai = zone("Asia/Dubai")?
  return today(dubai)
}
```

---

## Converting between types

Five conversions, in one place, because getting them confused is the single most
common source of date bugs.

| From | To | Method | Adds |
|---|---|---|---|
| `Date` | `NaiveDateTime` | `.atTime(h, m, s)` | a time of day |
| `Date` | `DateTime` | `.atStartOfDay(z)` | a time and a zone |
| `NaiveDateTime` | `DateTime` | `.inZone(z)` | a zone |
| `DateTime` | `Timestamp` | `.toTimestamp()` | drops the zone |
| `Timestamp` | `DateTime` | `.inZone(z)` | a zone |

And two that go the other way, dropping information:

| From | To | Method |
|---|---|---|
| `DateTime` / `NaiveDateTime` | `Date` | `.date()` |
| `DateTime` / `NaiveDateTime` | `Time` | `.time()` |
| `DateTime` | `NaiveDateTime` | `.naive()` |

### `inZone` and `withZone` are different operations

This pair is worth reading twice.

```bit ignore
import { zone, date } from "std/time"

fn twoDirections(): DateTime! {
  let dubai = zone("Asia/Dubai")?
  let london = zone("Europe/London")?

  // inZone: "read this wall clock AS Dubai time".
  // The wall clock stays 09:00. The instant is decided by it.
  let meeting = date(2026, 9, 1)?.atTime(9, 0, 0)?.inZone(dubai)

  // withZone: "same instant, SHOW it to me in London".
  // The instant stays. The wall clock becomes 06:00.
  return meeting.withZone(london)
}
```

`inZone` is on `NaiveDateTime` and on `Timestamp`. `withZone` is on `DateTime`
only, because only a `DateTime` already has an instant to preserve.

---

## Reading fields

Available on every type that carries the field.

| Method | Returns | On |
|---|---|---|
| `year()` | 1..9999 | `Date` `NaiveDateTime` `DateTime` |
| `month()` | 1..12 | `Date` `NaiveDateTime` `DateTime` |
| `day()` | 1..31 | `Date` `NaiveDateTime` `DateTime` |
| `hour()` | 0..23 | `Time` `NaiveDateTime` `DateTime` |
| `minute()` | 0..59 | `Time` `NaiveDateTime` `DateTime` |
| `second()` | 0..59 | `Time` `NaiveDateTime` `DateTime` |
| `nanosecond()` | 0..999999999 | `Time` `NaiveDateTime` `DateTime` |
| `dayOfWeek()` | 1 Monday .. 7 Sunday | `Date` `NaiveDateTime` `DateTime` |
| `dayOfYear()` | 1..366 | `Date` `NaiveDateTime` `DateTime` |
| `quarter()` | 1..4 | `Date` `NaiveDateTime` `DateTime` |
| `daysInMonth()` | 28..31 | `Date` `NaiveDateTime` `DateTime` |
| `weekOfYear()` | 1..53, ISO 8601 | `Date` `NaiveDateTime` `DateTime` |

`dayOfWeek` is **1 for Monday through 7 for Sunday**, the ISO 8601 numbering. This
differs from the superseded `Civil.weekday`, which was 0 for Sunday.

On `DateTime` only:

| Method | Returns |
|---|---|
| `zone()` | the `Zone` |
| `offset()` | seconds east of UTC at this instant, `14400` for Dubai |
| `isDst()` | whether daylight saving is in effect at this instant |

On `Timestamp` only:

| Method | Returns |
|---|---|
| `ns` | nanoseconds since the Unix epoch, as an `int` |

---

## Arithmetic

Every method returns a new value. `n` may be negative.

| Method | On |
|---|---|
| `addYears(n)` `addMonths(n)` `addWeeks(n)` `addDays(n)` | `Date` `NaiveDateTime` `DateTime` |
| `addHours(n)` `addMinutes(n)` `addSeconds(n)` `addNanoseconds(n)` | `Time` `NaiveDateTime` `DateTime` |
| `add(ns)` | `Timestamp` |

`Time` arithmetic wraps within the day: `23:30` plus 60 minutes is `00:30`. It
never carries into a date, because a `Time` has no date to carry into. Use
`NaiveDateTime` when the carry matters.

### Month arithmetic clamps

`addMonths` and `addYears` keep the day of month where they can and **clamp to the
last day of the target month** where they cannot.

| Input | Operation | Result |
|---|---|---|
| 2026-01-31 | `addMonths(1)` | 2026-02-28 |
| 2024-01-31 | `addMonths(1)` | 2024-02-29 |
| 2026-03-31 | `addMonths(-1)` | 2026-02-28 |
| 2024-02-29 | `addYears(1)` | 2025-02-28 |

Clamping is not the only defensible rule, and the alternative is worth knowing
about because it produces different invoices. Some libraries **normalise**, so
2026-01-31 plus one month becomes 2026-03-03. This module clamps, because a
monthly billing cycle that starts on the 31st must stay in the month it names.

Clamping is **not reversible**: `d.addMonths(1).addMonths(-1)` is not always `d`.
2026-01-31 goes to 2026-02-28 and comes back as 2026-01-28. When a recurring
schedule must stay anchored, keep the original date and compute each occurrence
from it, rather than stepping forward one month at a time from the last one.

### Setting a field

| Method | Notes |
|---|---|
| `withYear(y)` `withMonth(m)` `withDay(d)` | clamps the day the same way |
| `withHour(h)` `withMinute(m)` `withSecond(s)` `withNanosecond(n)` | |
| `withTime(h, m, s)` | on `NaiveDateTime` and `DateTime` |
| `withZone(z)` | on `DateTime`, keeps the instant |

`withMonth` clamps: 2026-01-31 `withMonth(2)` is 2026-02-28.

```bit ignore
import { date } from "std/time"

fn billingDates(start: Date): Date {
  // Anchored: every occurrence is computed from `start`, never from the
  // previous occurrence, so a February clamp does not poison March.
  return start.addMonths(2)
}
```

---

## Boundaries

Each returns the first or last representable instant of the named period.

| Method | 2026-09-17 gives |
|---|---|
| `startOfDay()` / `endOfDay()` | 2026-09-17 00:00:00 / 23:59:59.999999999 |
| `startOfWeek()` / `endOfWeek()` | 2026-09-14 (Monday) / 2026-09-20 |
| `startOfMonth()` / `endOfMonth()` | 2026-09-01 / 2026-09-30 |
| `startOfQuarter()` / `endOfQuarter()` | 2026-07-01 / 2026-09-30 |
| `startOfYear()` / `endOfYear()` | 2026-01-01 / 2026-12-31 |

The week starts on **Monday**, matching ISO 8601. `startOfWeek(day)` takes an
explicit first day when a different convention is needed — many organisations in
the Gulf and the United States start the week on Sunday.

On a `Date` these return a `Date`. On a `NaiveDateTime` or `DateTime` they set the
time of day as well.

`endOfDay` on a `DateTime` is the last representable nanosecond, not the next
midnight. A range check on a whole day should prefer a half-open interval:

```bit ignore
fn inDay(t: Timestamp, dayStart: Timestamp, nextDayStart: Timestamp): bool {
  return !t.isBefore(dayStart) && t.isBefore(nextDayStart)
}
```

---

## Comparison

| Method | Meaning |
|---|---|
| `isBefore(other)` | strictly earlier |
| `isAfter(other)` | strictly later |
| `isSame(other)` | equal |
| `isBetween(lo, hi)` | `lo <= this && this <= hi`, inclusive |
| `compare(other)` | `-1`, `0` or `1`, for sorting |

Comparison is only defined between two values of the **same type**. Comparing a
`DateTime` in Dubai with a `DateTime` in London compares the two **instants**, not
the two wall clocks, so 09:00 Dubai is before 09:00 London.

To compare wall clocks instead, compare `.naive()` on both sides. To compare
across types at all, convert both to `Timestamp` first.

Convenience predicates on `Date`:

| Method | Meaning |
|---|---|
| `isLeapYear()` | this date's year is a Gregorian leap year |
| `isSameDay(other)` | same calendar day |
| `isSameMonth(other)` `isSameYear(other)` | |
| `isWeekend()` `isWeekday()` | see [Business days](#business-days) |

On `Timestamp` and `DateTime`:

| Method | Meaning |
|---|---|
| `isPast()` `isFuture()` | compared against `now()` |

---

## Differences

Each returns a whole number, **truncated toward zero**, of complete units from the
receiver to the argument.

| Method | On |
|---|---|
| `differenceInYears` `differenceInMonths` `differenceInWeeks` `differenceInDays` | `Date` `NaiveDateTime` `DateTime` |
| `differenceInHours` `differenceInMinutes` `differenceInSeconds` | `NaiveDateTime` `DateTime` `Timestamp` |
| `differenceInNanoseconds` | `Timestamp` |

Truncation means partial units are dropped, which is what an age calculation
wants: someone born 2000-06-15 is 25 on 2026-06-14 and 26 on 2026-06-15.

`differenceInDays` on a `DateTime` counts **calendar days**, so it returns 1 across
a daylight saving transition even though 25 hours of real time elapsed. Subtract
two `Timestamp` values when real elapsed time is what matters. These two answers
differing is correct, not a bug.

```bit ignore
fn ageInYears(birth: Date, on: Date): int {
  return birth.differenceInYears(on)
}
```

---

## Business days

A business day is any day that is not a weekend day and not in the supplied
holiday set.

### `Weekend`

Which days of the week are not worked. Constructed from day numbers, `1` Monday
through `7` Sunday.

| Constructor | Days off | Where |
|---|---|---|
| `weekendSatSun()` | Saturday, Sunday | the default; Europe, the Americas, the UAE since 2022 |
| `weekendFriSat()` | Friday, Saturday | Saudi Arabia, Egypt, and much of the region |
| `weekendOn(days: []int)` | as given | anything else, including a six-day week |

There is no correct global default. Every business-day method takes a `Weekend`
explicitly rather than reading one from the host, because the right answer is a
property of the organisation, not of the machine the code runs on.

### `Calendar`

A `Weekend` plus a set of holiday `Date` values.

| Function | Returns |
|---|---|
| `calendar(w: Weekend, holidays: []Date): Calendar` | a business calendar |

Holidays are supplied by the caller. This module ships no holiday data for any
country: public holidays are set by governments, change annually, and several in
this region depend on a moon sighting announced days in advance. A bundled list
would be silently wrong.

### Methods

| Method | Meaning |
|---|---|
| `isBusinessDay(c)` | not a weekend day and not a holiday |
| `nextBusinessDay(c)` | the next one strictly after this date |
| `previousBusinessDay(c)` | the previous one strictly before |
| `addBusinessDays(c, n)` | skips weekends and holidays; negative `n` goes back |
| `differenceInBusinessDays(c, other)` | complete business days between |

```bit ignore
import { date, calendar, weekendSatSun } from "std/time"

fn paymentDue(invoiced: Date, holidays: []Date): Date {
  let c = calendar(weekendSatSun(), holidays)
  return invoiced.addBusinessDays(c, 30)
}
```

---

## Formatting

### `format(pattern: string): string`

Renders using **Unicode LDML** date field symbols, the pattern language defined by
Unicode Technical Standard #35 and used by Java, .NET, ICU and date-fns.

Repeating a symbol widens the field.

| Symbol | Meaning | `2026-09-01T09:05:00+04:00` |
|---|---|---|
| `y` | year | `2026` |
| `yy` | year, last two digits | `26` |
| `yyyy` | year, at least four digits | `2026` |
| `M` `MM` | month, number | `9` / `09` |
| `MMM` `MMMM` | month, name | `Sep` / `September` |
| `d` `dd` | day of month | `1` / `01` |
| `E` `EEE` `EEEE` | day of week, name | `Tue` / `Tue` / `Tuesday` |
| `H` `HH` | hour, 0..23 | `9` / `09` |
| `h` `hh` | hour, 1..12 | `9` / `09` |
| `m` `mm` | minute | `5` / `05` |
| `s` `ss` | second | `0` / `00` |
| `S`..`SSSSSSSSS` | fractional second, that many digits | `0` .. `000000000` |
| `a` | am/pm | `AM` |
| `Q` | quarter | `3` |
| `Z` | offset, no colon | `+0400` |
| `X` | offset, ISO 8601, `Z` when zero | `+04:00` |
| `V` | zone identifier | `Asia/Dubai` |

Text between single quotes is literal: `'at'` renders `at`. Two single quotes
render one. Any character that is not a pattern letter is copied unchanged.

**`Y` and `D` are deliberately not implemented, and are rejected as errors.**

In LDML, `Y` is the *week-based* year, which is only correct alongside a week
number, and `D` is the day of the *year*. Both are one shift key away from `y` and
`d`, and both are silently wrong rather than visibly wrong: `YYYY-MM-dd` gives the
wrong year for a few days around every New Year. This is a well-known and expensive
mistake. Rejecting them at the point of use costs a compile-time-visible failure
and saves a class of bug that appears once a year in production.

Use `weekOfYear()` and `dayOfYear()` when those values are genuinely wanted.

### `toString()`

Each type's canonical form. Whatever `toString` writes, the matching `parse`
function reads back to the same value.

| Type | `toString()` |
|---|---|
| `Date` | `2026-09-01` |
| `Time` | `09:00:00`, plus `.` and nine digits when nanoseconds are nonzero |
| `NaiveDateTime` | `2026-09-01T09:00:00` |
| `DateTime` | `2026-09-01T09:00:00+04:00` |
| `Timestamp` | `2026-09-01T05:00:00Z` |

These are RFC 3339 forms. The RFC number does not appear in any function name;
`toString` and `parseDateTime` are that format.

```bit ignore
fn render(t: DateTime): string {
  return t.format("EEEE, d MMMM yyyy 'at' HH:mm")
  // "Tuesday, 1 September 2026 at 09:00"
}
```

Month and day names are English. Localised names are not in scope for this module
and belong with the rest of internationalisation.

---

## Parsing

| Function | Accepts | Returns |
|---|---|---|
| `parseDate(s)` | `2026-09-01` | `Date!` |
| `parseTime(s)` | `09:00:00`, optional fraction | `Time!` |
| `parseNaiveDateTime(s)` | `2026-09-01T09:00:00` | `NaiveDateTime!` |
| `parseDateTime(s)` | `2026-09-01T09:00:00+04:00` or `...Z` | `DateTime!` |
| `parseWith(pattern, s)` | whatever `pattern` describes | `NaiveDateTime!` |

Parsing is **strict**. The input must match exactly and reach the end of the
string. Leading or trailing whitespace, a lowercase `t` or `z`, a missing colon in
an offset, and a `:60` leap second are all failures rather than best-effort
guesses. Silent acceptance of nearly-right input is how a wrong date reaches a
ledger.

A fractional second is accepted at 1 to 9 digits and zero-padded on the right, so
`.5` is 500000000 nanoseconds. Ten or more digits is a failure, never a truncation.

`parseDateTime` recovers only the **offset**, not the zone identity, because
`+04:00` does not say which zone it came from. The result's `zone()` is a
fixed-offset zone. Call `.withZone(z)` when the real zone is known from elsewhere.
This is why storing a zone name alongside a timestamp matters for anything that
must later be re-rendered in local time.

```bit ignore
import { parseDate, parseDateTime, parseWith } from "std/time"

fn fromCsv(field: string): Date! {
  return parseDate(field)?
}

fn fromUkCsv(field: string): NaiveDateTime! {
  return parseWith("dd/MM/yyyy", field)?
}
```

---

## Hijri dates

A display conversion, not a second calendar system. Values are stored and computed
in the Gregorian calendar; `hijri()` produces a rendering.

### `Date.hijri(): HijriDate`

| Method | Returns |
|---|---|
| `year()` `month()` `day()` | the Hijri fields |
| `format(pattern)` | LDML pattern with Hijri month names |
| `toString()` | `1448-03-19` |
| `gregorian()` | back to a `Date` |

### `hijriDate(year: int, month: int, day: int): HijriDate!`

Builds one directly, for parsing a Hijri date off a document.

The variant is **Umm al-Qura**, the calendar used for official and civil purposes
in Saudi Arabia and across the Gulf. Other Hijri variants exist — a purely
arithmetic one, and observation-based ones — and they can differ from Umm al-Qura
by a day. A document that must match a government record needs Umm al-Qura, so
that is the only variant provided.

Umm al-Qura is tabulated, not computed, and its published tables cover roughly
1300 to 1500 AH. `hijri()` fails outside that span rather than extrapolating.

There is no Hijri **arithmetic**. Add months to the `Date` and convert for display.

```bit ignore
import { date } from "std/time"

fn invoiceHeader(d: Date): string {
  return d.format("d MMMM yyyy") + " / " + d.hijri().format("d MMMM yyyy") + " AH"
}
```

---

## Storing time in a database

| Business meaning | Bit type | PostgreSQL column |
|---|---|---|
| a calendar day: value date, due date, date of birth | `Date` | `date` |
| a time of day: opening hours, a cut-off | `Time` | `time` |
| when a row changed: audit, created, updated | `Timestamp` | `timestamptz` |
| an appointment in a named place | `Timestamp` **and** a `text` zone name | `timestamptz` + `text` |

Two rules that prevent most date bugs in a system with users in more than one
country.

**Never store a calendar day as an instant.** A `Date` written as midnight UTC and
read back in `Asia/Dubai` is still the right day; read back in `America/Chicago` it
is the day before. Use a `date` column.

**A `DateTime` does not round-trip through one column.** PostgreSQL's `timestamptz`
stores an instant and discards the zone, despite its name. A future appointment
that must stay at "9am Dubai" even if the UAE changes its offset needs the zone
name stored beside it, so the wall clock can be recomputed rather than recovered
from a frozen offset.

For anything already in the past, the instant alone is enough.

---

## Durations

**Shipped.** Durations are plain `int` nanoseconds. There is no `Duration` type,
so a duration is built by multiplying a count by a unit constant:
`500 * Millisecond`.

Each constant is that unit's length in nanoseconds.

### `Nanosecond: int`

`1`.

### `Microsecond: int`

`1000` nanoseconds.

### `Millisecond: int`

A thousand microseconds.

### `Second: int`

A thousand milliseconds.

### `Minute: int`

Sixty seconds.

### `Hour: int`

Sixty minutes.

There is no `Day` constant, deliberately. A day is not always 86,400 seconds of
wall clock, and a constant would invite exactly the arithmetic that breaks twice a
year. Use `addDays` on a date type.

```bit
import { Millisecond, Second } from "std/time"

fn timeout(): int {
  return 250 * Millisecond
}

fn retryDelay(attempt: int): int {
  return attempt * Second
}
```

### `millis(d: int): int`

Whole milliseconds in `d`, truncated.

### `secs(d: int): int`

Whole seconds in `d`, truncated.

### `toMillis(d: int): f64`

`d` in milliseconds, keeping the fraction.

### `toSeconds(d: int): f64`

`d` in seconds, keeping the fraction.

```bit
import { secs, millis, toSeconds, Second, Millisecond } from "std/time"

fn describe(d: int) {
  println("${secs(d)} s, ${millis(d)} ms, ${toSeconds(d)} exactly")
}

fn example() {
  describe(1 * Second + 500 * Millisecond)
}
```

### `formatDuration(d: int): string`

Renders `d` nanoseconds the way a person reads it: `340ns`, `340us`, `340ms`
below one second; `45s`, `2m5s`, `1h23m4s` at or above one second, each part
truncated to a whole second. A negative `d` gets a leading `-`; `0` is `"0s"`.

```bit
import { formatDuration, Second, Millisecond } from "std/time"

fn report(label: string, d: int) {
  println("${label}: ${formatDuration(d)}")
}

fn example() {
  report("timeout", 1 * Second + 500 * Millisecond)
}
```

---

## Clocks

**Shipped**, except that `Instant` is renamed `Timestamp` by the rewrite and gains
the calendar methods above. `now()` keeps its signature and its meaning.

Two clocks, for two different jobs. `now` tells you *when*; `monotonic` tells you
*how long*, and never jumps when the system clock is adjusted. Each returns its own
nominal record, so a reading from one clock can never be passed to the other
clock's API by accident; `.ns` gives the raw nanoseconds when a caller genuinely
needs an int.

### `Instant`

A wall-clock reading, nanoseconds since the Unix epoch, returned by `now`.
`.ns` gives the raw nanoseconds. Never pass one to `since` — an `Instant` can
jump backwards (NTP, an operator setting the clock), so it cannot measure an
interval; use a `Mono` from `monotonic` instead.

### `Mono`

A monotonic reading, returned by `monotonic`. Only differences between two
`Mono` readings are meaningful; pass one to `since` to get the elapsed
nanoseconds. `.ns` gives the raw nanoseconds.

### `now(): Instant`

Nanoseconds since the Unix epoch. Follows the system clock, so it can jump
backwards. Use it to stamp an event, never to measure an interval.

### `monotonic(): Mono`

Nanoseconds from an unspecified fixed origin. Only differences are meaningful,
and they never go backwards. This is the one to time things with.

### `since(start: Mono): int`

Nanoseconds elapsed since `start`, which must have come from `monotonic()`.

```bit
import { monotonic, since, toMillis } from "std/time"

fn timed(label: string) {
  let start = monotonic()
  let sum = 0
  let i = 0
  while (i < 1000) {
    sum = sum + i
    i = i + 1
  }
  println("${label} took ${toMillis(since(start))} ms, sum ${sum}")
}
```

A timeout, a retry backoff, a cache expiry and a rate limiter must all use
`monotonic`. Using `now` for any of them means an NTP correction or an operator
adjusting the clock can make a deadline fire immediately or never.

---

## Sleeping

**Shipped.**

### `sleep(d: int)`

Parks the calling green thread for at least `d` nanoseconds. The deadline is
absolute, so the runtime clamps it to `i64max` nanoseconds; a duration of
`i64max` parks the thread for about 292 years and never returns early. A
duration of `0` or less yields the calling green thread and returns at once.

A sleeping green thread does not hold an OS thread: the scheduler runs others on
it and wakes this one when the deadline passes. A thousand threads sleeping 50 ms
finish in about 50 ms in total, not 50 seconds.

```bit
import { sleep, Millisecond } from "std/time"

fn worker(id: int, done: chan<int>) {
  sleep(10 * Millisecond)
  done <- id
}

fn fanOut() {
  let done = chan<int>(8)
  let i = 0
  while (i < 8) {
    spawn worker(i, done)
    i = i + 1
  }
  i = 0
  while (i < 8) {
    let got = <- done
    i = i + 1
  }
  println("all 8 slept concurrently")
}
```

### `sleepUntil(deadlineNs: int)`

Parks the calling green thread until `deadlineNs` on the clock `monotonic().ns`
reads — an absolute instant, not a duration. Useful when several callers must
park on the exact same deadline: compute it once and hand it to every
`sleepUntil` caller, rather than each recomputing `deadline - monotonic().ns`
after acquiring a lock, which drifts. A `deadlineNs` already in the past
returns quickly rather than parking indefinitely.

```bit
import { monotonic, sleepUntil, Millisecond } from "std/time"

fn waitUntilDeadline(deadline: int) {
  sleepUntil(deadline)
  println("deadline passed at ${monotonic().ns}")
}

fn example() {
  let deadline = monotonic().ns + 50 * Millisecond
  waitUntilDeadline(deadline)
}
```

---

## Timer channels

**Shipped.**

Built on the scheduler's own timer-channel primitives: arming a timer claims
one of a fixed pool of slots and queues it against the scheduler's timer
wheel. Nothing here spawns a green thread; expiry is a plain send on the
channel. A duration `d` is nanoseconds, the same unit `sleep` takes.

### `after(d: int): chan<bool>`

A channel that receives `true` once, `d` nanoseconds from now — the
idiomatic `select` timeout arm. If the timeout arm is never taken, the pool
slot leaks only until its own deadline: it fires and self-frees regardless,
so the leak is bounded by `d`, never permanent. In a loop, prefer `newTimer`
and `Timer.reset` over a fresh `after` each iteration, which would otherwise
accumulate one live slot per iteration between fires.

### `Timer`

A one-shot timer. `c` receives `true` once, when the timer fires.

### `newTimer(d: int): Timer`

Starts a one-shot `Timer` that fires `d` nanoseconds from now.

### `Timer.stop(): bool`

Cancels the timer. Returns `true` when it was still pending, `false` when it
had already fired. Does not drain `c` — a fired timer's buffered `true`
value stays there, matching Go's own `Timer.Stop`: `if !t.stop() { <-t.c }`
drains it before reuse.

### `Timer.reset(d: int): bool`

Re-arms the timer for `d` nanoseconds from now. Returns `false`, with no
effect, when the timer already fired: its pool slot was freed at fire time,
so there is no entry left to move and no second value will ever arrive on
`c`. Build a new `Timer` with `newTimer` instead of trying to resurrect a
fired one.

### `Ticker`

A repeating timer. `c` receives `true` every `d` nanoseconds until stopped.
An un-stopped `Ticker` leaks its pool slot forever — the same caveat Go's own
`time.Ticker` documents.

### `newTicker(d: int): Ticker`

Starts a `Ticker` that ticks every `d` nanoseconds.

### `Ticker.stop(): bool`

Cancels the ticker. Returns `true` when it was still pending, `false`
otherwise. After this returns, `c` receives no further ticks.

### `tick(d: int): chan<bool>`

A channel that receives `true` every `d` nanoseconds, forever. There is no
way to stop it — the underlying `Ticker` is discarded, so its pool slot
leaks for the life of the program. Use `newTicker` directly when the ticker
must ever be stopped.

```bit
import { after, newTimer, newTicker, tick, Millisecond } from "std/time"

fn waitForWork(work: chan<int>): int {
  select {
    case v = <- work:
      return v
    case <- after(100 * Millisecond):
      return -1
  }
}

fn pollFiveTimes(): int {
  let t = newTicker(50 * Millisecond)
  let n = 0
  while (n < 5) {
    let v = <- t.c
    n = n + 1
  }
  t.stop()
  return n
}

fn countdown(): int {
  let deadline = newTimer(200 * Millisecond)
  let ticks = tick(50 * Millisecond)
  let n = 0
  while (true) {
    select {
      case <- ticks:
        n = n + 1
      case <- deadline.c:
        return n
    }
  }
  return n
}
```

A `Ticker` is not a scheduler. It fires on an interval from the moment it was
armed, drifts under load, and knows nothing about calendars or zones. "Every day
at 09:00 Dubai time" is not a ticker: compute the next occurrence with the
calendar API and `sleepUntil` it, recomputing after each run so a daylight saving
transition is absorbed.

---

## Behaviour reference

The edge cases, in one table, so a reviewer can check an implementation against a
single list.

| Situation | Behaviour |
|---|---|
| `date(2026, 2, 30)` | fails |
| `date(2024, 2, 29)` | succeeds, 2024 is a leap year |
| `time(12, 0, 60)` | fails, no leap second |
| 2026-01-31 `addMonths(1)` | 2026-02-28, clamped |
| 2026-01-31 `addMonths(1).addMonths(-1)` | 2026-01-28, not reversible |
| `withMonth(2)` on 2026-01-31 | 2026-02-28, clamped |
| `addDays` across a spring transition | wall clock preserved, 23 real hours |
| `addDays` across an autumn transition | wall clock preserved, 25 real hours |
| `inZone` on a wall time in the spring gap | pushed forward by the gap |
| `inZone` on a wall time in the autumn overlap | the first occurrence |
| `Time` `23:30` `addMinutes(60)` | `00:30`, wraps, no date carry |
| `differenceInDays` across a transition | 1, calendar days |
| `Timestamp` subtraction across a transition | 23 or 25 hours, real time |
| comparing two `DateTime` in different zones | compares instants |
| `parseDateTime` on `2026-09-01t09:00:00z` | fails, lowercase |
| `parseDateTime` on `2026-09-01T09:00:00+0400` | fails, offset needs a colon |
| `parseTime` on `09:00:00.5` | succeeds, 500000000 ns |
| `parseTime` on a ten-digit fraction | fails, never truncates |
| `format` with `Y` or `D` | fails, see Formatting |
| `Date.toTimestamp` on year 1890 | fails, outside the instant range |
| `zone("Asia/Dubai")` with no host zone data | fails |
| `hijri()` outside 1300–1500 AH | fails, tables do not cover it |

---

## Superseded API

Documented because it ships today and because code has to be migrated off it. It
is UTC-only: it has no notion of a zone, `formatRfc3339` can only ever print `Z`,
and `addDays` is fixed 86400-second arithmetic. It is replaced by the types above.

### Migration

| Superseded | Replacement |
|---|---|
| `Instant` | `Timestamp` |
| `Civil` | `NaiveDateTime`, or `Date` when there is no time of day |
| `civilFromUnix(ns)` | `Timestamp.inZone(utc()).naive()` |
| `unixFromCivil(c)` | `NaiveDateTime.inZone(utc()).toTimestamp()` |
| `formatUnix(ns, "%Y-%m-%d")` | `.format("yyyy-MM-dd")`, note the token change |
| `formatRfc3339(ns)` | `.toString()` |
| `parseRfc3339(s)` | `parseDateTime(s)` |
| `startOfDay(ns)` | `.startOfDay()` |
| `addDays(ns, n)` | `.addDays(n)`, now zone-aware |
| `addMonths(ns, n)` | `.addMonths(n)`, clamping unchanged |
| `utcOffset(ns)` | `DateTime.offset()`, or `localZone()` |
| `Civil.weekday`, 0 = Sunday | `dayOfWeek()`, **1 = Monday** |

Two behaviour changes to check for during migration. `dayOfWeek` renumbers, so any
comparison against a weekday literal has to move. And format strings change from
strftime `%Y-%m-%d` to LDML `yyyy-MM-dd`; the two are not interchangeable and a
strftime pattern passed to `format` renders as literal text rather than failing.

### `Civil`

A broken-down UTC date and time: `year`, `month` (1..12), `day` (1..days in
that month), `hour` (0..23), `minute` (0..59), `second` (0..59), `nanosecond`
(0..999999999), `weekday` (0 for Sunday up to 6 for Saturday), and `yearDay`
(1 for January 1).

### `civilFromUnix(ns: int): Civil`

`ns` nanoseconds since the Unix epoch, broken down into a UTC `Civil`. Exact
for any instant, including before 1970 — the day/time split floors instead of
truncating, so a negative `ns` still lands on the correct calendar day.

```bit
import { civilFromUnix } from "std/time"

fn describe(ns: int) {
  let c = civilFromUnix(ns)
  println("${c.year}-${c.month}-${c.day} ${c.hour}:${c.minute}:${c.second}")
}
```

### `unixFromCivil(c: Civil): int!`

The inverse of `civilFromUnix`: nanoseconds since the Unix epoch for a UTC
`Civil`. Fails when `month`, `day`, `hour`, `minute`, `second`, or
`nanosecond` is out of range — `day` is checked against the actual length of
`month` in `year`, leap years included. Ignores `weekday` and `yearDay`.

```bit
import { Civil, unixFromCivil } from "std/time"

fn leapDaySeconds(): int! {
  let c = Civil{
    year: 2024, month: 2, day: 29, hour: 0, minute: 0, second: 0,
    nanosecond: 0, weekday: 0, yearDay: 0,
  }
  return unixFromCivil(c)?
}
```

### `formatUnix(ns: int, layout: string): string`

Renders the UTC instant `ns` (nanoseconds since the Unix epoch) with a
strftime subset. Every character in `layout` is copied through unchanged
except: `%Y` the year (at least four digits, zero padded); `%m` the month
(two digits); `%d` the day (two digits); `%H` the hour (two digits); `%M` the
minute (two digits); `%S` the second (two digits); `%%` a literal `%`. Any
other `%x` pair, and a trailing lone `%`, are copied through unchanged.

```bit
import { formatUnix } from "std/time"

fn describe(ns: int) {
  println(formatUnix(ns, "%Y-%m-%d %H:%M:%S"))
}
```

### `formatRfc3339(ns: int): string`

Renders the UTC instant `ns` as RFC 3339: `2026-08-02T14:03:11Z` when the
nanosecond field is `0`. When it is not `0`, a `.` and exactly nine
zero-padded digits are inserted before the `Z` — 500 nanoseconds prints
`2026-08-02T14:03:11.000000500Z`, never `.5`.

```bit
import { formatRfc3339 } from "std/time"

fn logLine(ns: int, msg: string) {
  println("${formatRfc3339(ns)} ${msg}")
}
```

### `startOfDay(ns: int): int`

The UTC midnight that starts the day containing `ns`. Floors rather than
truncates, so a negative `ns` still lands on the calendar day it belongs to.

```bit
import { startOfDay, formatRfc3339 } from "std/time"

fn describe(ns: int) {
  println(formatRfc3339(startOfDay(ns)))
}
```

### `addDays(ns: int, n: int): int`

`ns` shifted by `n` days of exactly 86400000000000 nanoseconds each. `n` may
be negative.

```bit
import { addDays } from "std/time"

fn tomorrow(ns: int): int {
  return addDays(ns, 1)
}
```

### `addMonths(ns: int, n: int): int`

`ns` shifted by `n` calendar months, keeping the time-of-day fields
unchanged. `n` may be negative. The day is clamped to the last valid day of
the target month rather than overflowing into the next one:
2026-01-31 plus one month is 2026-02-28, not 2026-03-03 (contrast Go's
`time.AddDate`, which normalizes and would give 2026-03-03).

```bit
import { addMonths } from "std/time"

fn nextMonthClamped(ns: int): int {
  return addMonths(ns, 1)
}
```

### `parseRfc3339(s: string): int!`

The inverse of `formatRfc3339`: parses `YYYY-MM-DDTHH:MM:SS`, an optional `.`
plus 1 to 9 fractional-second digits, then a zone (`Z`, or a signed `HH:MM`
offset), into nanoseconds since the Unix epoch. Stricter than RFC 3339 in
three ways: only uppercase `T` and `Z` are accepted; the zone offset always
carries its `:` (`+HHMM` is rejected); and a leap-second `:60` is rejected,
since `unixFromCivil` — which this function delegates every calendar range
check to — rejects any second above 59. A fractional part shorter than nine
digits is zero-padded on the right (`.5` is `500000000`); ten or more digits
is a parse failure rather than a silent truncation.

```bit
import { parseRfc3339, formatRfc3339 } from "std/time"

fn roundTrip(text: string): bool! {
  let ns = parseRfc3339(text)?
  return formatRfc3339(ns) == text
}
```

### `utcOffset(ns: int): int`

The host's offset from UTC, in seconds east of UTC, in effect at the instant
`ns` (nanoseconds since the Unix epoch). Dubai returns `14400`, UTC returns
`0`. Reads `/etc/localtime` — the version 1 (32-bit) block of the TZif format,
RFC 8536 — directly: the path is the same on macOS and Linux, so there is no
platform branch, and no copy of the tzdata database ships with this function.
Returns `0`, rather than failing, when the file is missing, is a dangling
symlink, is shorter than the header, or does not start with the TZif magic.

Version 1's transition times are signed 32-bit seconds, which overflow in
2038; an instant past then resolves against the last version 1 transition
rather than the correct one. RFC 8536 §3.2's version 2 block, with 64-bit
transition times, is the upgrade path.

**This function has no callers anywhere in this repository.** The zone work
replaces it, and the version 2 reader it needs is part of that work.

```bit
import { utcOffset, now } from "std/time"

fn localOffsetSeconds(): int {
  return utcOffset(now().ns)
}
```
