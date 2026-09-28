# std/time

Dates, times, time zones, durations, clocks and timers.

<!-- doctest: per-block -->

## Quick start

You need to show a user when something happened, in their own words: "1
September 2026" for a due date, or an instant that will not shift a day when
the server it runs on moves country.

```bit
import { now, utc, zone } from "std/time"

fn whatTimeIsIt(): string! {
  let dubai = zone("Asia/Dubai")?
  return now().inZone(dubai).format("EEEE, d MMMM yyyy 'at' HH:mm")?
  // "Tuesday, 1 September 2026 at 09:00"
}
```

`now()` gives the current instant. `.inZone(z)` reads it in a named place.
`.format(pattern)` renders it. That is the whole module in one call; the rest
of this page is the six situations where "just use a date-time" stops being
enough.

## Six types, because a "moment" is six different things

A single date-time type cannot be correct. An invoice value date, a shop's
opening hour, and the instant a row was written are not the same kind of
value, and storing them in one type is how a date shifts by a day when a
server moves country.

| Type | Holds | Knows a zone | Example |
|---|---|---|---|
| `Date` | year, month, day | no | an invoice value date |
| `Time` | hour, minute, second, nanosecond | no | a shop opening at `09:00` |
| `NaiveDateTime` | a `Date` and a `Time` | no | "9am on the 1st", somewhere |
| `DateTime` | a `NaiveDateTime`, a `Zone`, an offset | yes | 9am on the 1st in Dubai |
| `Timestamp` | nanoseconds since the Unix epoch | n/a | what a database column holds |
| `Zone` | an IANA zone identity | - | `Asia/Dubai` |

`Mono`, the monotonic clock reading, is a seventh type and is unrelated to
the calendar: it measures elapsed time and nothing else (see
[Clocks](#clocks)).

| The value is | Use |
|---|---|
| a calendar day with no time of day | `Date` |
| a time of day with no date | `Time` |
| a wall clock reading whose zone is not yet known | `NaiveDateTime` |
| an appointment a person will keep in a named place | `DateTime` |
| when something happened, for storage or comparison | `Timestamp` |
| how long something took | `int` nanoseconds, from `since` |

When in doubt between `DateTime` and `Timestamp`: if moving the value to
another country must **change the number a user sees**, it is a `DateTime`.
If it must **not change the moment**, it is a `Timestamp`.

Every value of every type is immutable. Every operation returns a new value
and never modifies its receiver, so a value is safe to share across green
threads with no synchronisation, and passing it to a function can never
silently change the caller's copy.

Construction and parsing are fallible and return `T!`, because a caller
outside the module's control - a form field, a file, a network peer - can
always send something out of range. Everything else (arithmetic, snapping,
comparison, differences, formatting) is total: once a value exists, no
operation on it can fail.

| Type | Range | Why |
|---|---|---|
| `Date`, `NaiveDateTime` | years **1 through 9999** | proleptic Gregorian, no BC |
| `Time` | `00:00:00.000000000` to `23:59:59.999999999` | no leap second |
| `Timestamp` | `1677-09-21T00:12:43Z` to `2262-04-11T23:47:16Z` | signed 64-bit nanoseconds |

**The `Timestamp` range is narrower than the `Date` range, and that is
deliberate.** A date of birth in 1890 is a perfectly good `Date` and cannot
be a `Timestamp`. Store dates of birth, historical value dates and
far-future maturity dates as `Date`, not as an instant - `Date.toTimestamp`
fails rather than wrapping.

Leap seconds do not exist in this module. A `:60` second is rejected on
parse and cannot be constructed. Every day is exactly 86,400 seconds of UTC.

## Zones

A `Zone` is an IANA time zone, identified by its canonical name -
`Asia/Dubai`, `Europe/London`, `UTC`. A `Zone` is not an offset: `Asia/Dubai`
is permanently `+04:00`, but `Europe/London` is `+00:00` for part of the
year and `+01:00` for the rest, and a zone's rules change when a government
changes them. The offset is a property of a zone **at an instant**, never of
the zone alone.

```bit
import { zone, utc, localZone, Zone } from "std/time"

fn openZones(): Zone! {
  let dubai = zone("Asia/Dubai")?
  let london = zone("Europe/London")?
  return dubai
}
```

`localZone()` reads the host's own zone from `/etc/localtime`, or `utc()`
when the host provides none. Prefer an explicit `zone("Asia/Dubai")` in
server code: the host's zone is a property of the machine, not of the
business, and a machine moves.

Zone data is read from the host's own database - `/usr/share/zoneinfo` on
Linux and macOS - not from a copy bundled into the binary, because
governments change daylight saving rules around ten times a year. This has
one consequence worth planning for: **a `scratch` or `distroless` container
has no zone database, and neither does Windows.** There, `zone` fails for
every name except `UTC` until the program installs one with `extend`:

```bit
import * as tz from "std/tz"
import { extend } from "std/time"

fn installZoneData(): bool {
  return extend(tz.data)
}
```

`extend(ext: string): bool` installs an extension and returns whether it was
accepted; today the only extension is a zone database, which `zone` falls
back to only for a name the host has no file for, so a current host database
is never overridden by a bundled copy that has gone stale. It returns
`false`, changing nothing, for a blob it cannot use, and for a second call
once an extension is already installed.

### Daylight saving: the two awkward days

Twice a year a zone that observes daylight saving moves its clocks, and on
those two days the mapping between a wall clock and an instant is not
one-to-one.

**The spring gap.** On 2026-03-29 in `Europe/London`, the clock goes
straight from `01:00` to `02:00`. The wall times in between never happen.
`inZone` **pushes forward by the size of the gap** rather than failing:
`01:30` becomes `02:30`.

**The autumn overlap.** On 2026-10-25 in `Europe/London`, the clock goes
back from `02:00` to `01:00`, so the wall times in between happen twice.
`inZone` **takes the first occurrence** - the one with the earlier offset.

```bit
import { zone, date, DateTime } from "std/time"

fn springGap(): DateTime! {
  let london = zone("Europe/London")?
  // 01:30 does not exist on this day; the result is 02:30 +01:00.
  return date(2026, 3, 29)?.atTime(1, 30, 0)?.inZone(london)
}
```

Calendar arithmetic on a `DateTime` keeps the **wall clock** and lets the
elapsed physical time absorb the transition, which is what a person means by
"same time tomorrow": a daily 9am report still runs at 9am, even the day the
clocks changed, and the elapsed real time between the two 9ams was 23 or 25
hours. `Timestamp` arithmetic does the opposite: it adds real elapsed time
and lets the wall clock absorb it. Use `differenceInDays` for the first kind
of question and `Timestamp` subtraction for the second; to add real elapsed
time to a `DateTime`, go through the instant:

```bit
import { Hour, DateTime } from "std/time"

fn plusRealHours(t: DateTime, n: int): DateTime! {
  return t.toTimestamp()?.add(n * Hour).inZone(t.zone())
}
```

## Constructing

```bit
import { date, time, timeNs, today, zone, Date } from "std/time"

fn build(): Date! {
  let d = date(2026, 9, 1)?
  let t = time(9, 0, 0)?
  let precise = timeNs(9, 0, 0, 500000000)?
  let dubai = zone("Asia/Dubai")?
  return today(dubai)
}
```

| Function | Fails when |
|---|---|
| `date(year, month, day): Date!` | month outside 1..12, day outside the month's range, or year outside 1..9999 |
| `time(hour, minute, second): Time!` | any field out of range; nanoseconds are zero. A `second` of 60 is rejected |
| `timeNs(hour, minute, second, nanosecond): Time!` | as `time`, plus nanosecond outside 0..999999999 |
| `today(z: Zone): Date` | never - the current instant is always representable |
| `now(): Timestamp` | never - see [Clocks](#clocks) |

## Converting between types

Five conversions, in one place, because getting them confused is the single
most common source of date bugs.

| From | To | Method | Adds |
|---|---|---|---|
| `Date` | `NaiveDateTime` | `.atTime(h, m, s)` | a time of day |
| `Date` | `DateTime` | `.atStartOfDay(z)` | a time and a zone |
| `NaiveDateTime` | `DateTime` | `.inZone(z)` | a zone |
| `DateTime` | `Timestamp` | `.toTimestamp()` | drops the zone |
| `Timestamp` | `DateTime` | `.inZone(z)` | a zone |

And the other way, dropping information: `.date()` and `.time()` on
`DateTime` or `NaiveDateTime`, and `.naive()` on `DateTime`.

`atStartOfDay` and `Timestamp.inZone` are total: midnight always exists, and
every instant has exactly one offset in any zone. `atTime` fails exactly
when `time(h, m, s)` fails. `toTimestamp` fails outside `Timestamp`'s range
(see [Ranges](#six-types-because-a-moment-is-six-different-things) above).
`inZone` on a `NaiveDateTime` is total on purpose: the two awkward days above
are resolved without failing, so there is nothing left to fail on.

`inZone` and `withZone` sound alike and do opposite things - worth reading
twice:

```bit
import { zone, date, DateTime } from "std/time"

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

`inZone` is on `NaiveDateTime` and `Timestamp`. `withZone` is on `DateTime`
only, because only a `DateTime` already has an instant to preserve; it is
total, since every instant has exactly one offset in any zone.

## Reading, changing and comparing

The same eleven fields, the same arithmetic and the same comparisons work
the same way on `Date`, `Time`, `NaiveDateTime` and `DateTime`, so they are
one table each rather than one heading per type. On `NaiveDateTime` and
`DateTime` each method reads or changes the matching `Date` or `Time` half;
on `DateTime` it is the **wall clock**, with the zone offset re-resolved the
same way `inZone` resolves it (see [the two awkward
days](#daylight-saving-the-two-awkward-days)).

### Fields

| Method | Returns | On |
|---|---|---|
| `year()` | 1..9999 | `Date` `NaiveDateTime` `DateTime` |
| `month()` | 1..12 | `Date` `NaiveDateTime` `DateTime` |
| `day()` | 1..31 | `Date` `NaiveDateTime` `DateTime` |
| `hour()` | 0..23 | `Time` `NaiveDateTime` `DateTime` |
| `minute()` | 0..59 | `Time` `NaiveDateTime` `DateTime` |
| `second()` | 0..59, never 60 | `Time` `NaiveDateTime` `DateTime` |
| `nanosecond()` | 0..999999999 | `Time` `NaiveDateTime` `DateTime` |
| `dayOfWeek()` | 1 Monday .. 7 Sunday (ISO 8601) | `Date` `NaiveDateTime` `DateTime` |
| `dayOfYear()` | 1..366 | `Date` `NaiveDateTime` `DateTime` |
| `quarter()` | 1..4 | `Date` `NaiveDateTime` `DateTime` |
| `daysInMonth()` | 28..31 | `Date` `NaiveDateTime` `DateTime` |
| `weekOfYear()` | 1..53, ISO 8601 week-date, scoped to that ISO year | `Date` `NaiveDateTime` `DateTime` |
| `zone()` `offset()` `isDst()` | the `Zone`; seconds east of UTC; whether daylight saving is in effect | `DateTime` only |

`weekOfYear()` can differ from `year()` near a year boundary: week 1 is the
week containing the year's first Thursday, so a date in late December can
fall in week 1 of the next ISO year.

### Arithmetic and setting a field

Every method returns a new value; `n` may be negative.

| Method | On | Behaviour |
|---|---|---|
| `addYears(n)` `addMonths(n)` | `Date` `NaiveDateTime` `DateTime` | clamps to the last day of the target month, see below |
| `addWeeks(n)` `addDays(n)` | `Date` `NaiveDateTime` `DateTime` | exact, never clamped |
| `addHours(n)` .. `addNanoseconds(n)` | `Time` | wraps within the day, never carries into a date |
| `addHours(n)` .. `addNanoseconds(n)` | `NaiveDateTime` `DateTime` | carries into the date across midnight |
| `add(ns)` | `Timestamp` | adds real elapsed time, not wall clock |
| `withYear(y)` `withMonth(m)` `withDay(d)` | `Date` `NaiveDateTime` `DateTime` | clamps the day to fit |
| `withHour(h)` .. `withNanosecond(n)` | `Time` `NaiveDateTime` `DateTime` | replaces exactly that field, not clamped |
| `withTime(h, m, s)` | `NaiveDateTime` `DateTime` | replaces the time of day |
| `withZone(z)` | `DateTime` | keeps the instant, see [Converting](#converting-between-types) |

`addMonths` and `addYears` keep the day of month where they can and
**clamp** to the last day of the target month where they cannot:

| Input | Operation | Result |
|---|---|---|
| 2026-01-31 | `addMonths(1)` | 2026-02-28 |
| 2024-01-31 | `addMonths(1)` | 2024-02-29 |
| 2024-02-29 | `addYears(1)` | 2025-02-28 |

Clamping is not the only defensible rule - some libraries *normalise*, so
2026-01-31 plus one month becomes 2026-03-03. This module clamps, because a
monthly billing cycle that starts on the 31st must stay in the month it
names. Clamping is **not reversible**: `d.addMonths(1).addMonths(-1)` is not
always `d`. For a recurring schedule that must stay anchored, compute each
occurrence from the original date, never by stepping forward from the last
one:

```bit
import { Date } from "std/time"

fn billingDates(start: Date): Date {
  // Anchored: every occurrence is computed from `start`, never from the
  // previous occurrence, so a February clamp does not poison March.
  return start.addMonths(2)
}
```

### Boundaries

Each returns the first or last representable instant of the named period.

| Method | 2026-09-17 (a Thursday) gives |
|---|---|
| `startOfDay()` / `endOfDay()` | `00:00:00` / `23:59:59.999999999` |
| `startOfWeek()` / `endOfWeek()` | 2026-09-14 (Monday) / 2026-09-20 |
| `startOfMonth()` / `endOfMonth()` | 2026-09-01 / 2026-09-30 |
| `startOfQuarter()` / `endOfQuarter()` | 2026-07-01 / 2026-09-30 |
| `startOfYear()` / `endOfYear()` | 2026-01-01 / 2026-12-31 |

Shipped on `Date`, `NaiveDateTime` and `DateTime`; on a `Date` it is the
identity when there is no time of day to floor. The week starts on
**Monday** (ISO 8601); `startOfWeekOn(day)` / `endOfWeekOn(day)` take an
explicit first day (1 Monday .. 7 Sunday) for the many organisations that
start the week on Sunday. None of them fails, and no month length is
hardcoded. On a `DateTime`, `startOfDay`/`endOfDay` re-resolve the zone
offset for the new wall time, because in a handful of zones midnight itself
falls inside a spring-forward gap.

`endOfDay` is the last representable nanosecond, not the next midnight, so a
range check should prefer a half-open interval:

```bit
import { Timestamp } from "std/time"

fn inDay(t: Timestamp, dayStart: Timestamp, nextDayStart: Timestamp): bool {
  return !t.isBefore(dayStart) && t.isBefore(nextDayStart)
}
```

### Comparing

| Method | Meaning | On |
|---|---|---|
| `compare(other)` | `-1`, `0` or `1`, for sorting | `Date` `Time` `NaiveDateTime` `DateTime` `Timestamp` |
| `isBefore(other)` `isAfter(other)` `isSame(other)` | strict / strict / equal | same five |
| `isBetween(lo, hi)` | `lo <= this && this <= hi`, inclusive | same five |
| `isLeapYear()` | this date's year is a Gregorian leap year | `Date` `NaiveDateTime` `DateTime` |
| `isSameDay(other)` `isSameMonth(other)` `isSameYear(other)` | same calendar day / month / year | `Date` `NaiveDateTime` `DateTime` |
| `isWeekend(w)` `isWeekday(w)` | see [Business days](#business-days) | `Date` `NaiveDateTime` `DateTime` |
| `isPast()` `isFuture()` | compared against `now()` at call time | `DateTime` `Timestamp` |

None of these fail; a `lo` later than `hi` names an empty range, so
`isBetween` is false for every receiver rather than failing.

Comparison is only defined between two values of the **same type**. Two
`DateTime` values compare their **instants**, not their wall clocks, so
09:00 in Dubai is before 09:00 in London. Compare `.naive()` on both sides
to compare wall clocks instead, or convert both to `Timestamp` to compare
across types.

### Differences

Each returns a whole number, **truncated toward zero**, of complete units
from the receiver to the argument - what an age calculation wants: someone
born 2000-06-15 is 25 on 2026-06-14 and 26 on 2026-06-15.

| Method | On |
|---|---|
| `differenceInYears` `differenceInMonths` `differenceInWeeks` `differenceInDays` | `Date` `NaiveDateTime` `DateTime` |
| `differenceInHours` `differenceInMinutes` `differenceInSeconds` | `NaiveDateTime` `DateTime` `Timestamp` |
| `differenceInNanoseconds` | `Timestamp` |

A month is complete when `addMonths` has reached it, so 2026-01-31 to
2026-02-28 is **one** complete month, inheriting the same clamp as
arithmetic above; `differenceInYears` is that month count divided by 12.

On a `DateTime`, **date units read the wall clock and time units read the
instant** - the same split arithmetic makes. Across an autumn transition,
`differenceInDays` is 1 (one calendar day) while `differenceInHours` is 25
(real elapsed time). Both are correct answers to different questions;
subtract two `Timestamp` values when only real elapsed time matters.

```bit
import { Date } from "std/time"

fn ageInYears(birth: Date, on: Date): int {
  return birth.differenceInYears(on)
}
```

## Business days

A business day is any day that is not a weekend day and not in a supplied
holiday set.

```bit
import { calendar, weekendSatSun, Date } from "std/time"

fn paymentDue(invoiced: Date, holidays: []Date): Date {
  let c = calendar(weekendSatSun(), holidays)
  return invoiced.addBusinessDays(c, 30)
}
```

| Function | Returns |
|---|---|
| `weekendSatSun(): Weekend` | Saturday, Sunday off - the default; Europe, the Americas, the UAE since 2022 |
| `weekendFriSat(): Weekend` | Friday, Saturday off - Saudi Arabia, Egypt, and much of the region |
| `weekendOn(days: []int): Weekend!` | the given day numbers off, `1` Monday .. `7` Sunday; fails outside 1..7 or on a set covering all seven days |
| `calendar(w: Weekend, holidays: []Date): Calendar` | a `Weekend` plus a set of holiday dates |

There is no correct global default, so every business-day method takes a
`Weekend` explicitly. This module ships no holiday data for any country:
public holidays are set by governments, change annually, and several in
this region depend on a moon sighting announced days in advance - a bundled
list would be silently wrong.

| Method (on `Date`, `NaiveDateTime` and `DateTime`) | Meaning |
|---|---|
| `isBusinessDay(c)` | not a weekend day and not a holiday |
| `nextBusinessDay(c)` / `previousBusinessDay(c)` | the next/previous one, strictly after/before |
| `addBusinessDays(c, n)` | skips weekends and holidays; `n` may be negative; `n == 0` returns this date unchanged |
| `differenceInBusinessDays(c, other)` | complete business days between, excluding the earlier date and including the later |

On `NaiveDateTime` and `DateTime` these read the wall-clock date and return
a `Date`: a business day is a property of the calendar day, unaffected by
the time of day or a daylight saving transition. `nextBusinessDay` and
`previousBusinessDay` never return the receiver, even when it is itself a
business day. Each of the three date-walking methods is **bounded**: a
search that would need to pass 3,660 consecutive non-business days (ten
years) panics, naming the calendar's weekend and holiday count, rather than
running forever - a ten-year holiday run is a caller error, not a runtime
condition.

## Formatting and parsing

```bit
import { DateTime, parseWith, NaiveDateTime } from "std/time"

fn render(t: DateTime): string! {
  return t.format("EEEE, d MMMM yyyy 'at' HH:mm")?
  // "Tuesday, 1 September 2026 at 09:00"
}

fn fromUkForm(field: string): NaiveDateTime! {
  return parseWith("dd/MM/yyyy", field)?
}
```

`format(pattern): string!` is shipped on `Date`, `Time`, `NaiveDateTime` and
`DateTime`, using **Unicode LDML** date field symbols - the pattern language
Java, .NET, ICU and date-fns already use. It fails on a symbol the receiver
does not carry (`H` on a `Date`, `d` on a `Time`, a zone symbol on anything
but a `DateTime`), on an unknown pattern letter, and on an unterminated
quoted literal.

| Symbol | Meaning | `2026-09-01T09:05:00+04:00` |
|---|---|---|
| `y` `yy` `yyyy` | year / last two digits / at least four digits | `2026` `26` `2026` |
| `M` `MM` `MMM` `MMMM` | month, number / name | `9` `09` `Sep` `September` |
| `d` `dd` | day of month | `1` `01` |
| `E` `EEE` `EEEE` | day of week name | `Tue` `Tue` `Tuesday` |
| `H` `HH` | hour, 0..23 | `9` `09` |
| `h` `hh` | hour, 1..12 (pair with `a`) | `9` `09` |
| `m` `mm` `s` `ss` | minute / second | `5` `05` `0` `00` |
| `S`..`SSSSSSSSS` | fractional second, that many digits | `0` .. `000000000` |
| `a` | am/pm | `AM` |
| `Q` | quarter | `3` |
| `Z` `X` `V` | offset no colon / offset ISO 8601 / zone identifier | `+0400` `+04:00` `Asia/Dubai` |

Text between single quotes is literal (`'at'` renders `at`); any other
non-letter character is copied unchanged. **`Y` (week-based year) and `D`
(day of year) are deliberately not implemented** and are rejected: both are
one shift key away from `y` and `d`, and both are silently wrong rather than
visibly wrong around a New Year - `YYYY-MM-dd` gives the wrong year for a
few days a year. Use `weekOfYear()` and `dayOfYear()` when those values are
genuinely wanted.

`toString()` is each type's RFC 3339 canonical form, and the matching
`parse*` function reads it back exactly:

| Type | `toString()` | Parses with |
|---|---|---|
| `Date` | `2026-09-01` | `parseDate(s): Date!` |
| `Time` | `09:00:00`, `.` and nine digits if nonzero | `parseTime(s): Time!` |
| `NaiveDateTime` | `2026-09-01T09:00:00` | `parseNaiveDateTime(s): NaiveDateTime!` |
| `DateTime` | `2026-09-01T09:00:00+04:00` | `parseDateTime(s): DateTime!` |
| `Timestamp` | `2026-09-01T05:00:00Z` | see [Clocks](#clocks) |
| any | whatever `pattern` describes | `parseWith(pattern, s): NaiveDateTime!` |

Parsing is **strict**: the input must match exactly and reach the end of
the string. Leading or trailing whitespace, a lowercase `t` or `z`, a
missing colon in an offset, and a `:60` leap second are all failures rather
than best-effort guesses - silent acceptance of nearly-right input is how a
wrong date reaches a ledger. `parseDateTime` recovers only the **offset**,
not the zone identity, since `+04:00` does not say which zone it came from;
the result's `zone()` is a fixed-offset zone, so call `.withZone(z)` when
the real zone is known from elsewhere.

## Hijri dates

A display conversion, not a second calendar system: values are stored and
computed in the Gregorian calendar, and `hijri()` produces a rendering in
the **Umm al-Qura** variant used for official and civil purposes in Saudi
Arabia and across the Gulf.

```bit
import { Date } from "std/time"

fn invoiceHeader(d: Date): string! {
  return d.format("d MMMM yyyy")? + " / " + d.hijri()?.format("d MMMM yyyy")? + " AH"
}
```

| Symbol | Meaning |
|---|---|
| `Date.hijri(): HijriDate!` | this day in Umm al-Qura; fails outside 1882-11-12 to 2077-11-16 |
| `hijriDate(year, month, day): HijriDate!` | builds one directly, for parsing a Hijri date off a document |
| `HijriDate.year()` `.month()` `.day()` | the Hijri fields: year 1300..1500, month 1..12, day 1..29 or 30 |
| `HijriDate.gregorian(): Date` | back to the `Date` this renders; never fails |
| `HijriDate.toString(): string` | `1448-03-19` |
| `HijriDate.format(pattern): string!` | the same LDML tokens as `Date.format`, with Hijri month names |

There is no Hijri **arithmetic** - add months to the `Date` and convert for
display. The table is tabulated, not computed, covering roughly 1300 to
1500 AH; both functions fail rather than extrapolate past it. Month and day
names are Latin script; Arabic script and Arabic-Indic digits are out of
scope for this module.

## Storing time in a database

| Business meaning | Bit type | PostgreSQL column |
|---|---|---|
| a calendar day: value date, due date, date of birth | `Date` | `date` |
| a time of day: opening hours, a cut-off | `Time` | `time` |
| when a row changed: audit, created, updated | `Timestamp` | `timestamptz` |
| an appointment in a named place | `Timestamp` **and** a `text` zone name | `timestamptz` + `text` |

Two rules that prevent most date bugs in a system with users in more than
one country.

**Never store a calendar day as an instant.** A `Date` written as midnight
UTC and read back in `Asia/Dubai` is still the right day; read back in
`America/Chicago` it is the day before. Use a `date` column.

**A `DateTime` does not round-trip through one column.** PostgreSQL's
`timestamptz` stores an instant and discards the zone, despite its name. A
future appointment that must stay at "9am Dubai" even if the UAE changes its
offset needs the zone name stored beside it, so the wall clock can be
recomputed rather than recovered from a frozen offset. For anything already
in the past, the instant alone is enough.

## Durations

Durations are plain `int` nanoseconds. There is no `Duration` type, so a
duration is built by multiplying a count by a unit constant.

```bit
import { Millisecond, Second, secs, millis, toSeconds, formatDuration } from "std/time"

fn describe(d: int): string {
  return "${formatDuration(d)} (${secs(d)}s, ${toSeconds(d)} exactly)"
}

fn example(): string {
  return describe(1 * Second + 500 * Millisecond)
}
```

| Name | Nanoseconds |
|---|---|
| `Nanosecond` | `1` |
| `Microsecond` | `1000` |
| `Millisecond` | `1000000` |
| `Second` | `1000000000` |
| `Minute` | `60000000000` |
| `Hour` | `3600000000000` |

There is no `Day` constant, deliberately: a day is not always 86,400
seconds of wall clock, and a constant would invite the arithmetic that
breaks twice a year. Use `addDays` on a date type instead.

| Function | Returns |
|---|---|
| `millis(d)` / `secs(d)` | whole milliseconds / seconds in `d`, truncated |
| `toMillis(d)` / `toSeconds(d)` | `d` in milliseconds / seconds, keeping the fraction, as `f64` |
| `formatDuration(d): string` | `340ns`/`340us`/`340ms` below a second; `45s`/`2m5s`/`1h23m4s` at or above, each part truncated |

## Clocks

Two clocks, for two different jobs: `now()` tells you *when*, `monotonic()`
tells you *how long*, and never jumps when the system clock is adjusted.
Each returns its own record type, so a reading from one can never be passed
to the other's API by accident.

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

| Symbol | Meaning |
|---|---|
| `now(): Timestamp` | nanoseconds since the Unix epoch; follows the system clock, so it can jump backwards. Stamp an event, never measure an interval with it |
| `monotonic(): Mono` | nanoseconds from an unspecified fixed origin; only differences are meaningful, and they never go backwards |
| `since(start: Mono): int` | nanoseconds elapsed since `start` |
| `.ns` | on either type, the raw nanoseconds, `readonly` |

A timeout, a retry backoff, a cache expiry and a rate limiter must all use
`monotonic`. Using `now` for any of them means an NTP correction or an
operator adjusting the clock can make a deadline fire immediately or never.

## Sleeping

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

`sleep(d: int)` parks the calling green thread for at least `d`
nanoseconds; `d <= 0` yields and returns at once. A sleeping green thread
does not hold an OS thread, so a thousand threads sleeping 50 ms finish in
about 50 ms in total, not 50 seconds.

`sleepUntil(deadlineNs: int)` parks until `deadlineNs` on the
`monotonic().ns` clock - an absolute instant rather than a duration. Useful
when several callers must park on the exact same deadline: compute it once
and hand it to every caller, rather than each recomputing
`deadline - monotonic().ns` after acquiring a lock, which drifts.

## Timer channels

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
```

| Symbol | Meaning |
|---|---|
| `after(d: int): chan<bool>` | receives `true` once, `d` nanoseconds from now - the idiomatic `select` timeout arm |
| `Timer` / `newTimer(d): Timer` | one-shot timer; `.c` receives `true` once when it fires |
| `Timer.stop(): bool` | cancels; `true` if it was still pending. Does not drain `.c` |
| `Timer.reset(d): bool` | re-arms; `false`, with no effect, if it already fired |
| `Ticker` / `newTicker(d): Ticker` | repeating timer; `.c` receives `true` every `d` nanoseconds until stopped |
| `Ticker.stop(): bool` | cancels; after this, `.c` receives no further ticks |
| `tick(d: int): chan<bool>` | receives `true` every `d` nanoseconds, forever - there is no way to stop it, so its slot leaks for the program's life; prefer `newTicker` when it must ever stop |

In a loop, prefer `newTimer` and `Timer.reset` over a fresh `after` each
iteration, which otherwise accumulates one live slot per iteration between
fires.

A `Ticker` is not a scheduler: it fires on an interval from the moment it
was armed, drifts under load, and knows nothing about calendars or zones.
"Every day at 09:00 Dubai time" is not a ticker - compute the next
occurrence with the calendar API and `sleepUntil` it, recomputing after each
run so a daylight saving transition is absorbed.

## Sharp edges

| Situation | Behaviour |
|---|---|
| `date(2026, 2, 30)` | fails |
| `date(2024, 2, 29)` | succeeds, 2024 is a leap year |
| `time(12, 0, 60)` | fails, no leap second |
| 2026-01-31 `addMonths(1).addMonths(-1)` | 2026-01-28, not reversible |
| `Time` `23:30` `addMinutes(60)` | `00:30`, wraps, no date carry |
| `differenceInDays` across a DST transition | 1, calendar days, not 23 or 25 hours |
| `isBetween` with `lo` after `hi` | `false`, an empty range |
| comparing two `DateTime` in different zones | compares instants, not wall clocks |
| `parseDateTime` on `2026-09-01t09:00:00z` | fails, lowercase `t`/`z` |
| `parseDateTime` on `...+0400` | fails, offset needs a colon |
| `Date.toTimestamp()` on year 1600 | fails, outside the instant range |
| `zone("Asia/Dubai")` with no host zone data | fails - see [Zones](#zones) |
| `hijri()` outside 1300-1500 AH | fails, tables do not cover it |

## Where to go next

- Installing zone data in a container with no `/usr/share/zoneinfo`: `std/tz`.
- Handling dates and time zones end to end in a real program: [The Bit
  Book, chapter 9](/book/09-words-and-dates).
- Propagating a construction or parsing failure with `?` and `catch`:
  [Errors](/language/errors).

---

Specification: `spec/SPEC.md`.
