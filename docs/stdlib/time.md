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

### How far into the future a zone is right

A zone file lists every clock change up to some year (2037 in a full file,
2007 in a compact one) and then ends with a **rule** - a POSIX TZ string such
as `EST5EDT,M3.2.0,M11.1.0`, "the second Sunday of March, the first of
November" - for every instant after the last listed change. `std/time` reads
that rule, so a zone keeps observing daylight saving for as long as the rule
stands: a mortgage schedule or a 2040 meeting in `America/New_York` lands on
the right side of the March change, not an hour off.

The rule has to agree with the file. Evaluated at the last listed change it
must give that change's offset, daylight-saving flag and abbreviation; a file
whose rule disagrees would jump at the end of its table, so `zone` fails when
it loads it, naming the rule, the instant and the first field that differs.

```bit
import { zone, date, DateTime } from "std/time"

fn summerMeeting(): DateTime! {
  let newYork = zone("America/New_York")?
  // July 2040 is past the last listed change: the rule says -04:00.
  return date(2040, 7, 1)?.atTime(9, 0, 0)?.inZone(newYork)
}
```

A gap or an overlap after the last listed change resolves exactly as it does
before it (see below). A rule that is not a valid POSIX TZ string makes
`zone` fail, naming the footer; it is never ignored.

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
| `Timestamp` | `2026-09-01T05:00:00Z` | `parseRfc3339(s): Timestamp!`, see [RFC 3339 and epoch timestamps](#rfc-3339-and-epoch-timestamps) |
| any | whatever `pattern` describes | `parseWith(pattern, s): NaiveDateTime!` |

Parsing is **strict**: the input must match exactly and reach the end of
the string. Leading or trailing whitespace, a lowercase `t` or `z`, a
missing colon in an offset, and a `:60` leap second are all failures rather
than best-effort guesses - silent acceptance of nearly-right input is how a
wrong date reaches a ledger. `parseDateTime` recovers only the **offset**,
not the zone identity, since `+04:00` does not say which zone it came from;
the result's `zone()` is a fixed-offset zone, so call `.withZone(z)` when
the real zone is known from elsewhere.

## HTTP dates

A `Date`, `Last-Modified` or `Expires` header carries a timestamp in the
format RFC 9110 section 5.6.7 calls HTTP-date, and a server that signs
requests (an S3 client, for one) compares it with its own clock. It is not
RFC 3339: `Sun, 06 Nov 1994 08:49:37 GMT`, always GMT, English day and month
names, to the second.

```bit
import {
  HttpDateCause, HttpDateError, Timestamp, formatHttpDate, parseHttpDate,
} from "std/time"

fn stamp(t: Timestamp): string {
  return formatHttpDate(t)
  // "Sun, 06 Nov 1994 08:49:37 GMT"
}

fn clockSkew(header: string, local: Timestamp): string {
  let server = parseHttpDate(header) catch e {
    let he = e.(HttpDateError)
    match (he.cause) {
      Zone => return "the server stamped a zone other than GMT"
      Syntax => return "not an HTTP-date: ${he.input}"
      Range => return "an impossible date"
      Weekday => return "the day name and the date disagree"
    }
  }
  return "server is ${(server.ns - local.ns) / 1000000000}s ahead"
}
```

`formatHttpDate(t)` writes the one form a sender may write, IMF-fixdate. A
fraction of a second is dropped toward the past.

`parseHttpDate(s)` reads all three forms a recipient must accept, and the
same instant comes back from each:

| Form | Example |
|---|---|
| IMF-fixdate | `Sun, 06 Nov 1994 08:49:37 GMT` |
| RFC 850 (obsolete) | `Sunday, 06-Nov-94 08:49:37 GMT` |
| asctime (obsolete) | `Sun Nov  6 08:49:37 1994` |

It is strict, like the other parsers: the grammar is case sensitive and takes
no extra whitespace. Everything else fails with an `HttpDateError`, whose
`cause` says why: `Syntax` for none of the three shapes, `Range` for a field
no calendar has (day 32, hour 24, second 60, 30 February) or an instant
outside a `Timestamp`'s roughly 1677 to 2262 span, `Zone` for anything but
`GMT` (`UTC`, `+0000`), and `Weekday` when the day name disagrees with the
date. The error's `input` is the refused text.

An RFC 850 year has two digits. RFC 9110 reads one that lands more than 50
years in the future as the most recent past year with the same last two
digits, so the answer depends on today's date. `parseHttpDate(s, reference)`
takes that date as a second argument, defaulting to `now()`; pass a stored
response's own timestamp to read it as it was read then.

## RFC 3339 and epoch timestamps

A feed that Inkwell imports articles from stamps each one `published`
with whatever its server writes: `2024-01-02T03:04:05.5+05:30` from one,
`2024-01-02t03:04:05z` from another, `1704164645.5` as a JSON number from a
third. `parseDateTime` reads only the exact shape `toString()` writes, so none
of them parse with it. `parseRfc3339` reads everything RFC 3339 section 5.6
allows, and `parseEpochSeconds` reads a number of seconds since the epoch.
Both return the instant as a `Timestamp`.

```bit
import {
  Timestamp, TimestampParseCause, TimestampParseError,
  parseEpochSeconds, parseRfc3339,
} from "std/time"

fn publishedAt(field: string): Timestamp! {
  return parseRfc3339(field)?
  // "1996-12-19T16:39:57-08:00" is the instant 851042397 seconds
}

fn updatedAt(field: string): Timestamp! {
  return parseEpochSeconds(field)?
  // "1700000000.123" is 1700000000123000000 nanoseconds
}

fn explain(field: string): string {
  let t = parseRfc3339(field) catch e {
    let pe = e.(TimestampParseError)
    match (pe.cause) {
      Syntax => return "not an RFC 3339 date-time: ${pe.input}"
      Range => return "no such instant: ${pe.input}"
    }
  }
  return "ok, ${t.ns} ns since the epoch"
}
```

What `parseRfc3339` takes, exactly as the RFC's grammar has it:

| Part | Accepted |
|---|---|
| Separator | `T` or `t` (a space is not RFC 3339 and fails) |
| Zone | `Z`, `z`, `+hh:mm`, `-hh:mm` (the colon is required) |
| Fraction | `.` and one or more digits, any number of them |
| `-00:00` | read as UTC; RFC 3339 4.3 means "offset unknown" and an instant has no use for the difference |
| Bounds | month 1 to 12, day 1 to the month's length (leap years included), hour 0 to 23, minute 0 to 59, second 0 to 60, offset hour 0 to 23, offset minute 0 to 59 |

A fraction is stored as nanoseconds, so digits past the ninth are
**truncated**, never rounded: `.9999999999` is `.999999999`, the same
direction `formatHttpDate` drops a fraction.

A `Timestamp` has no second 60. `parseRfc3339` accepts `:60` only where a leap
second can exist, 23:59:60 UTC on the last day of a month once the offset is
applied, and reads it as the second after it: `1990-12-31T23:59:60Z` is the
same instant as `1991-01-01T00:00:00Z`, and so is `1990-12-31T15:59:60-08:00`.
Any other `:60` fails with `Range`.

`parseEpochSeconds` reads `-?digits`, an optional `.digits`, and an optional
exponent (`1.7E9`, how some JSON writers print a large number). A negative
value is read as a negative number of seconds, so `-1.5` is one and a half
seconds before the epoch. Digits past the ninth fractional one are truncated
toward the past: `-0.0000000001` is one nanosecond before the epoch. A
leading `+`, `.5`, `5.`, `NaN` and surrounding space fail with `Syntax`.

Both functions fail with a `TimestampParseError`: `Syntax` when the text is
not the grammar, `Range` for a field no calendar has (month 13, `2023-02-29`,
offset `+25:00`, an invalid leap second) and for an instant outside a
`Timestamp`'s roughly 1677 to 2262 span, such as `9999-12-31T23:59:59Z` or an
epoch value of `1e12`. Nothing wraps: the bound is checked before the seconds
are turned into nanoseconds, down to the last nanosecond
(`9223372036.854775807` fits, `9223372036.854775808` fails). The error's
`input` is the refused text.

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
import { after, Ticker, tick, Millisecond } from "std/time"

fn waitForWork(work: chan<int>): int {
  select {
    case v = <- work:
      return v
    case <- after(100 * Millisecond):
      return -1
  }
}

fn pollFiveTimes(): int {
  let t = Ticker(50 * Millisecond)
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
| `Timer(d: int)` | one-shot timer; `.c` receives `true` once when it fires |
| `Timer.stop(): bool` | cancels; `true` if it was still pending. Does not drain `.c` |
| `Timer.reset(d): bool` | re-arms; `false`, with no effect, if it already fired |
| `Ticker(d: int)` | repeating timer; `.c` receives `true` every `d` nanoseconds until stopped |
| `Ticker.stop(): bool` | cancels; `true` if it was still pending. After a `true`, no tick is sent, though one already in `.c` stays there until received |
| `tick(d: int): chan<bool>` | receives `true` every `d` nanoseconds, forever - there is no way to stop it, so its slot leaks for the program's life; prefer `Ticker(d)` when it must ever stop |

In a loop, prefer `Timer(d)` and `Timer.reset` over a fresh `after` each
iteration, which otherwise accumulates one live slot per iteration between
fires.

`Ticker.stop` follows Go's `Ticker.Stop`. When it returns `true`, no tick is
sent after it returns: a send that is under way when `stop` is called is waited
out, never left to land afterwards. A tick that was already delivered before
`stop` returned is still in `.c`; drain it with `select { case <- t.c: default: }`
if the channel is reused. `stop` returns `false` for a ticker that was
already stopped. A `Timer` differs on purpose: it is released at the instant it
fires, so `Timer.stop` is `false` once the timer is due, and its value arrives
even when the `stop` call began first.

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
| `parseHttpDate` on `Sun, 06 Nov 1994 08:49:37 UTC` | fails, `Zone`: only `GMT` |
| `parseHttpDate` on a date after year 2262 | fails, `Range`: a `Timestamp` cannot hold it |
| `parseRfc3339` on `2024-01-02 03:04:05Z` | fails, `Syntax`: a space is not `T` or `t` |
| `parseRfc3339` on `...05.9999999999Z` | `.999999999`, extra digits truncate |
| `parseRfc3339` on `12:00:60Z` | fails, `Range`: `:60` only at a UTC month end |
| `parseEpochSeconds` on `1e12` | fails, `Range`: a `Timestamp` cannot hold it |

## Date reference

### `Date`

A calendar day with no time of day and no zone: an invoice value date, a due date, a date of birth. Immutable, like every type in this module.

### `Date.addBusinessDays(c: Calendar, n: i64): Date`

Skips `n` business days under calendar `c`, forward or backward; `n` may be negative and `0` returns this date unchanged. See [Business days](#business-days).

### `Date.addDays(n: i64): Date`

Returns a copy of this `Date` with `n` days added; `n` may be negative. See [Arithmetic](#arithmetic-and-setting-a-field).

### `Date.addMonths(n: i64): Date`

Returns a copy of this `Date` with `n` months added; `n` may be negative. See [Arithmetic](#arithmetic-and-setting-a-field).

### `Date.addWeeks(n: i64): Date`

Returns a copy of this `Date` with `n` weeks added; `n` may be negative. See [Arithmetic](#arithmetic-and-setting-a-field).

### `Date.addYears(n: i64): Date`

Returns a copy of this `Date` with `n` years added; `n` may be negative. See [Arithmetic](#arithmetic-and-setting-a-field).

### `Date.atStartOfDay(z: Zone): DateTime`

This date at midnight in zone `z`, as a `DateTime`. See [Converting between types](#converting-between-types).

### `Date.atTime(h: i64, m: i64, s: i64): NaiveDateTime!`

This date combined with a time of day, as a `NaiveDateTime`; fails exactly when `time(h, m, s)` fails.

### `Date.compare(other: Date): i64`

Returns `-1`, `0` or `1` for sorting against another value of the same type. See [Comparing](#comparing).

### `Date.day(): i64`

Returns the day of the month, `1` to `31`. See [Fields](#fields).

### `Date.dayOfWeek(): i64`

Returns the day of the week, `1` Monday through `7` Sunday (ISO 8601). See [Fields](#fields).

### `Date.dayOfYear(): i64`

Returns the day of the year, `1` to `366`. See [Fields](#fields).

### `Date.daysInMonth(): i64`

Returns the number of days in this month, `28` to `31`. See [Fields](#fields).

### `Date.differenceInBusinessDays(c: Calendar, other: Date): i64`

The complete business days from this date to `other` under calendar `c`, excluding this date and including `other`. See [Business days](#business-days).

### `Date.differenceInDays(other: Date): i64`

The whole days from this value to `other`, truncated toward zero. See [Differences](#differences).

### `Date.differenceInMonths(other: Date): i64`

The whole months from this value to `other`, truncated toward zero. See [Differences](#differences).

### `Date.differenceInWeeks(other: Date): i64`

The whole weeks from this value to `other`, truncated toward zero. See [Differences](#differences).

### `Date.differenceInYears(other: Date): i64`

The whole years from this value to `other`, truncated toward zero. See [Differences](#differences).

### `Date.endOfDay(): Date`

The last representable instant of the named period. See [Boundaries](#boundaries).

### `Date.endOfMonth(): Date`

The last representable instant of the named period. See [Boundaries](#boundaries).

### `Date.endOfQuarter(): Date`

The last representable instant of the named period. See [Boundaries](#boundaries).

### `Date.endOfWeek(): Date`

The last representable instant of the named period. See [Boundaries](#boundaries).

### `Date.endOfWeekOn(day: i64): Date`

The last representable instant of the named period. See [Boundaries](#boundaries).

### `Date.endOfYear(): Date`

The last representable instant of the named period. See [Boundaries](#boundaries).

### `Date.format(pattern: string): string!`

Renders this value using the LDML pattern `pattern`. See [Formatting and parsing](#formatting-and-parsing).

### `Date.hijri(): HijriDate!`

This day rendered as a `HijriDate` in the Umm al-Qura calendar; fails outside the tabulated span. See [Hijri dates](#hijri-dates).

### `Date.isAfter(other: Date): bool`

Whether this value is strictly after `other`. See [Comparing](#comparing).

### `Date.isBefore(other: Date): bool`

Whether this value is strictly before `other`. See [Comparing](#comparing).

### `Date.isBetween(lo: Date, hi: Date): bool`

Whether this value falls within `lo` and `hi`, inclusive. See [Comparing](#comparing).

### `Date.isBusinessDay(c: Calendar): bool`

Whether this date is a business day under calendar `c`: not a weekend day and not a holiday. See [Business days](#business-days).

### `Date.isLeapYear(): bool`

Whether this value's year is a Gregorian leap year.

### `Date.isSame(other: Date): bool`

Whether this value is equal to `other`. See [Comparing](#comparing).

### `Date.isSameDay(other: Date): bool`

Whether this value and `other` fall on the same calendar day.

### `Date.isSameMonth(other: Date): bool`

Whether this value and `other` fall on the same month.

### `Date.isSameYear(other: Date): bool`

Whether this value and `other` fall on the same year.

### `Date.isWeekday(w: Weekend): bool`

Whether this date is a working day under `w`. See [Business days](#business-days).

### `Date.isWeekend(w: Weekend): bool`

Whether this date is a weekend day under `w`. See [Business days](#business-days).

### `Date.month(): i64`

Returns the month, `1` to `12`. See [Fields](#fields).

### `Date.nextBusinessDay(c: Calendar): Date`

The next business day under calendar `c`, strictly after this date; never returns this date, even when it is itself a business day. See [Business days](#business-days).

### `Date.previousBusinessDay(c: Calendar): Date`

The previous business day under calendar `c`, strictly before this date; never returns this date, even when it is itself a business day. See [Business days](#business-days).

### `Date.quarter(): i64`

Returns the quarter, `1` to `4`. See [Fields](#fields).

### `Date.startOfDay(): Date`

The first representable instant of the named period. See [Boundaries](#boundaries).

### `Date.startOfMonth(): Date`

The first representable instant of the named period. See [Boundaries](#boundaries).

### `Date.startOfQuarter(): Date`

The first representable instant of the named period. See [Boundaries](#boundaries).

### `Date.startOfWeek(): Date`

The first representable instant of the named period. See [Boundaries](#boundaries).

### `Date.startOfWeekOn(day: i64): Date`

The first representable instant of the named period. See [Boundaries](#boundaries).

### `Date.startOfYear(): Date`

The first representable instant of the named period. See [Boundaries](#boundaries).

### `Date.toString(): string`

This value's canonical text form, the same text its matching `parse*` function reads back.

### `Date.weekOfYear(): i64`

Returns the ISO 8601 week number, `1` to `53`. See [Fields](#fields).

### `Date.withDay(d: i64): Date`

Returns a copy of this `Date` with its day replaced. See [Arithmetic](#arithmetic-and-setting-a-field).

### `Date.withMonth(mo: i64): Date`

Returns a copy of this `Date` with its month replaced. See [Arithmetic](#arithmetic-and-setting-a-field).

### `Date.withYear(y: i64): Date`

Returns a copy of this `Date` with its year replaced. See [Arithmetic](#arithmetic-and-setting-a-field).

### `Date.year(): i64`

Returns the year, `1` to `9999`. See [Fields](#fields).


## DateTime reference

### `DateTime`

A wall-clock reading, a zone, and the resolved offset: an appointment a person will keep in a named place. Immutable.

### `DateTime.addBusinessDays(c: Calendar, n: i64): Date`

Skips `n` business days under calendar `c`, forward or backward; `n` may be negative and `0` returns this date unchanged. See [Business days](#business-days).

### `DateTime.addDays(n: i64): DateTime`

Returns a copy of this `DateTime` with `n` days added; `n` may be negative. See [Arithmetic](#arithmetic-and-setting-a-field).

### `DateTime.addHours(n: i64): DateTime`

Returns a copy of this `DateTime` with `n` hours added; `n` may be negative. See [Arithmetic](#arithmetic-and-setting-a-field).

### `DateTime.addMinutes(n: i64): DateTime`

Returns a copy of this `DateTime` with `n` minutes added; `n` may be negative. See [Arithmetic](#arithmetic-and-setting-a-field).

### `DateTime.addMonths(n: i64): DateTime`

Returns a copy of this `DateTime` with `n` months added; `n` may be negative. See [Arithmetic](#arithmetic-and-setting-a-field).

### `DateTime.addNanoseconds(n: i64): DateTime`

Returns a copy of this `DateTime` with `n` nanoseconds added; `n` may be negative. See [Arithmetic](#arithmetic-and-setting-a-field).

### `DateTime.addSeconds(n: i64): DateTime`

Returns a copy of this `DateTime` with `n` seconds added; `n` may be negative. See [Arithmetic](#arithmetic-and-setting-a-field).

### `DateTime.addWeeks(n: i64): DateTime`

Returns a copy of this `DateTime` with `n` weeks added; `n` may be negative. See [Arithmetic](#arithmetic-and-setting-a-field).

### `DateTime.addYears(n: i64): DateTime`

Returns a copy of this `DateTime` with `n` years added; `n` may be negative. See [Arithmetic](#arithmetic-and-setting-a-field).

### `DateTime.compare(other: DateTime): i64`

Returns `-1`, `0` or `1` for sorting against another value of the same type. See [Comparing](#comparing).

### `DateTime.date(): Date`

The calendar date half of this value, dropping the time of day.

### `DateTime.day(): i64`

Returns the day of the month, `1` to `31`. See [Fields](#fields).

### `DateTime.dayOfWeek(): i64`

Returns the day of the week, `1` Monday through `7` Sunday (ISO 8601). See [Fields](#fields).

### `DateTime.dayOfYear(): i64`

Returns the day of the year, `1` to `366`. See [Fields](#fields).

### `DateTime.daysInMonth(): i64`

Returns the number of days in this month, `28` to `31`. See [Fields](#fields).

### `DateTime.differenceInBusinessDays(c: Calendar, other: Date): i64`

The complete business days from this date to `other` under calendar `c`, excluding this date and including `other`. See [Business days](#business-days).

### `DateTime.differenceInDays(other: DateTime): i64`

The whole days from this value to `other`, truncated toward zero. See [Differences](#differences).

### `DateTime.differenceInHours(other: DateTime): i64`

The whole hours from this value to `other`, truncated toward zero. See [Differences](#differences).

### `DateTime.differenceInMinutes(other: DateTime): i64`

The whole minutes from this value to `other`, truncated toward zero. See [Differences](#differences).

### `DateTime.differenceInMonths(other: DateTime): i64`

The whole months from this value to `other`, truncated toward zero. See [Differences](#differences).

### `DateTime.differenceInSeconds(other: DateTime): i64`

The whole seconds from this value to `other`, truncated toward zero. See [Differences](#differences).

### `DateTime.differenceInWeeks(other: DateTime): i64`

The whole weeks from this value to `other`, truncated toward zero. See [Differences](#differences).

### `DateTime.differenceInYears(other: DateTime): i64`

The whole years from this value to `other`, truncated toward zero. See [Differences](#differences).

### `DateTime.endOfDay(): DateTime`

The last representable instant of the named period. See [Boundaries](#boundaries).

### `DateTime.endOfMonth(): DateTime`

The last representable instant of the named period. See [Boundaries](#boundaries).

### `DateTime.endOfQuarter(): DateTime`

The last representable instant of the named period. See [Boundaries](#boundaries).

### `DateTime.endOfWeek(): DateTime`

The last representable instant of the named period. See [Boundaries](#boundaries).

### `DateTime.endOfWeekOn(day: i64): DateTime`

The last representable instant of the named period. See [Boundaries](#boundaries).

### `DateTime.endOfYear(): DateTime`

The last representable instant of the named period. See [Boundaries](#boundaries).

### `DateTime.format(pattern: string): string!`

Renders this value using the LDML pattern `pattern`. See [Formatting and parsing](#formatting-and-parsing).

### `DateTime.hour(): i64`

Returns the hour, `0` to `23`. See [Fields](#fields).

### `DateTime.isAfter(other: DateTime): bool`

Whether this value is strictly after `other`. See [Comparing](#comparing).

### `DateTime.isBefore(other: DateTime): bool`

Whether this value is strictly before `other`. See [Comparing](#comparing).

### `DateTime.isBetween(lo: DateTime, hi: DateTime): bool`

Whether this value falls within `lo` and `hi`, inclusive. See [Comparing](#comparing).

### `DateTime.isBusinessDay(c: Calendar): bool`

Whether this date is a business day under calendar `c`: not a weekend day and not a holiday. See [Business days](#business-days).

### `DateTime.isDst(): bool`

Returns whether daylight saving is in effect at this instant. See [Fields](#fields).

### `DateTime.isFuture(): bool`

Whether this value is after `now()`, checked at the moment this is called.

### `DateTime.isLeapYear(): bool`

Whether this value's year is a Gregorian leap year.

### `DateTime.isPast(): bool`

Whether this value is before `now()`, checked at the moment this is called.

### `DateTime.isSame(other: DateTime): bool`

Whether this value is equal to `other`. See [Comparing](#comparing).

### `DateTime.isSameDay(other: DateTime): bool`

Whether this value and `other` fall on the same calendar day.

### `DateTime.isSameMonth(other: DateTime): bool`

Whether this value and `other` fall on the same month.

### `DateTime.isSameYear(other: DateTime): bool`

Whether this value and `other` fall on the same year.

### `DateTime.isWeekday(w: Weekend): bool`

Whether this date is a working day under `w`. See [Business days](#business-days).

### `DateTime.isWeekend(w: Weekend): bool`

Whether this date is a weekend day under `w`. See [Business days](#business-days).

### `DateTime.minute(): i64`

Returns the minute, `0` to `59`. See [Fields](#fields).

### `DateTime.month(): i64`

Returns the month, `1` to `12`. See [Fields](#fields).

### `DateTime.naive(): NaiveDateTime`

This value with its zone dropped, as a `NaiveDateTime`.

### `DateTime.nanosecond(): i64`

Returns the nanosecond, `0` to `999999999`. See [Fields](#fields).

### `DateTime.nextBusinessDay(c: Calendar): Date`

The next business day under calendar `c`, strictly after this date; never returns this date, even when it is itself a business day. See [Business days](#business-days).

### `DateTime.offset(): i64`

Returns this value's offset from UTC, in seconds east. See [Fields](#fields).

### `DateTime.previousBusinessDay(c: Calendar): Date`

The previous business day under calendar `c`, strictly before this date; never returns this date, even when it is itself a business day. See [Business days](#business-days).

### `DateTime.quarter(): i64`

Returns the quarter, `1` to `4`. See [Fields](#fields).

### `DateTime.second(): i64`

Returns the second, `0` to `59`, never `60`. See [Fields](#fields).

### `DateTime.startOfDay(): DateTime`

The first representable instant of the named period. See [Boundaries](#boundaries).

### `DateTime.startOfMonth(): DateTime`

The first representable instant of the named period. See [Boundaries](#boundaries).

### `DateTime.startOfQuarter(): DateTime`

The first representable instant of the named period. See [Boundaries](#boundaries).

### `DateTime.startOfWeek(): DateTime`

The first representable instant of the named period. See [Boundaries](#boundaries).

### `DateTime.startOfWeekOn(day: i64): DateTime`

The first representable instant of the named period. See [Boundaries](#boundaries).

### `DateTime.startOfYear(): DateTime`

The first representable instant of the named period. See [Boundaries](#boundaries).

### `DateTime.time(): Time`

The time-of-day half of this value, dropping the date.

### `DateTime.toString(): string`

This value's canonical text form, the same text its matching `parse*` function reads back.

### `DateTime.toTimestamp(): Timestamp!`

This value converted to an instant, dropping the zone; fails when the result falls outside `Timestamp`'s range.

### `DateTime.weekOfYear(): i64`

Returns the ISO 8601 week number, `1` to `53`. See [Fields](#fields).

### `DateTime.withDay(d: i64): DateTime`

Returns a copy of this `DateTime` with its day replaced. See [Arithmetic](#arithmetic-and-setting-a-field).

### `DateTime.withHour(h: i64): DateTime`

Returns a copy of this `DateTime` with its hour replaced. See [Arithmetic](#arithmetic-and-setting-a-field).

### `DateTime.withMinute(mi: i64): DateTime`

Returns a copy of this `DateTime` with its minute replaced. See [Arithmetic](#arithmetic-and-setting-a-field).

### `DateTime.withMonth(mo: i64): DateTime`

Returns a copy of this `DateTime` with its month replaced. See [Arithmetic](#arithmetic-and-setting-a-field).

### `DateTime.withNanosecond(ns: i64): DateTime`

Returns a copy of this `DateTime` with its nanosecond replaced. See [Arithmetic](#arithmetic-and-setting-a-field).

### `DateTime.withSecond(s: i64): DateTime`

Returns a copy of this `DateTime` with its second replaced. See [Arithmetic](#arithmetic-and-setting-a-field).

### `DateTime.withTime(h: i64, m: i64, s: i64): DateTime`

Returns a copy of this value with a new time of day, keeping the date. See [Arithmetic](#arithmetic-and-setting-a-field).

### `DateTime.withYear(y: i64): DateTime`

Returns a copy of this `DateTime` with its year replaced. See [Arithmetic](#arithmetic-and-setting-a-field).

### `DateTime.withZone(z: Zone): DateTime`

Returns the same instant shown in a different zone: the wall clock changes, the instant does not. See [Converting between types](#converting-between-types).

### `DateTime.year(): i64`

Returns the year, `1` to `9999`. See [Fields](#fields).

### `DateTime.zone(): Zone`

Returns this value's zone. See [Fields](#fields).


## NaiveDateTime reference

### `NaiveDateTime`

A calendar date and a time of day, with no zone: "9am on the 1st", somewhere unspecified. Immutable.

### `NaiveDateTime.addBusinessDays(c: Calendar, n: i64): Date`

Skips `n` business days under calendar `c`, forward or backward; `n` may be negative and `0` returns this date unchanged. See [Business days](#business-days).

### `NaiveDateTime.addDays(n: i64): NaiveDateTime`

Returns a copy of this `NaiveDateTime` with `n` days added; `n` may be negative. See [Arithmetic](#arithmetic-and-setting-a-field).

### `NaiveDateTime.addHours(n: i64): NaiveDateTime`

Returns a copy of this `NaiveDateTime` with `n` hours added; `n` may be negative. See [Arithmetic](#arithmetic-and-setting-a-field).

### `NaiveDateTime.addMinutes(n: i64): NaiveDateTime`

Returns a copy of this `NaiveDateTime` with `n` minutes added; `n` may be negative. See [Arithmetic](#arithmetic-and-setting-a-field).

### `NaiveDateTime.addMonths(n: i64): NaiveDateTime`

Returns a copy of this `NaiveDateTime` with `n` months added; `n` may be negative. See [Arithmetic](#arithmetic-and-setting-a-field).

### `NaiveDateTime.addNanoseconds(n: i64): NaiveDateTime`

Returns a copy of this `NaiveDateTime` with `n` nanoseconds added; `n` may be negative. See [Arithmetic](#arithmetic-and-setting-a-field).

### `NaiveDateTime.addSeconds(n: i64): NaiveDateTime`

Returns a copy of this `NaiveDateTime` with `n` seconds added; `n` may be negative. See [Arithmetic](#arithmetic-and-setting-a-field).

### `NaiveDateTime.addWeeks(n: i64): NaiveDateTime`

Returns a copy of this `NaiveDateTime` with `n` weeks added; `n` may be negative. See [Arithmetic](#arithmetic-and-setting-a-field).

### `NaiveDateTime.addYears(n: i64): NaiveDateTime`

Returns a copy of this `NaiveDateTime` with `n` years added; `n` may be negative. See [Arithmetic](#arithmetic-and-setting-a-field).

### `NaiveDateTime.compare(other: NaiveDateTime): i64`

Returns `-1`, `0` or `1` for sorting against another value of the same type. See [Comparing](#comparing).

### `NaiveDateTime.date(): Date`

The calendar date half of this value, dropping the time of day.

### `NaiveDateTime.day(): i64`

Returns the day of the month, `1` to `31`. See [Fields](#fields).

### `NaiveDateTime.dayOfWeek(): i64`

Returns the day of the week, `1` Monday through `7` Sunday (ISO 8601). See [Fields](#fields).

### `NaiveDateTime.dayOfYear(): i64`

Returns the day of the year, `1` to `366`. See [Fields](#fields).

### `NaiveDateTime.daysInMonth(): i64`

Returns the number of days in this month, `28` to `31`. See [Fields](#fields).

### `NaiveDateTime.differenceInBusinessDays(c: Calendar, other: Date): i64`

The complete business days from this date to `other` under calendar `c`, excluding this date and including `other`. See [Business days](#business-days).

### `NaiveDateTime.differenceInDays(other: NaiveDateTime): i64`

The whole days from this value to `other`, truncated toward zero. See [Differences](#differences).

### `NaiveDateTime.differenceInHours(other: NaiveDateTime): i64`

The whole hours from this value to `other`, truncated toward zero. See [Differences](#differences).

### `NaiveDateTime.differenceInMinutes(other: NaiveDateTime): i64`

The whole minutes from this value to `other`, truncated toward zero. See [Differences](#differences).

### `NaiveDateTime.differenceInMonths(other: NaiveDateTime): i64`

The whole months from this value to `other`, truncated toward zero. See [Differences](#differences).

### `NaiveDateTime.differenceInSeconds(other: NaiveDateTime): i64`

The whole seconds from this value to `other`, truncated toward zero. See [Differences](#differences).

### `NaiveDateTime.differenceInWeeks(other: NaiveDateTime): i64`

The whole weeks from this value to `other`, truncated toward zero. See [Differences](#differences).

### `NaiveDateTime.differenceInYears(other: NaiveDateTime): i64`

The whole years from this value to `other`, truncated toward zero. See [Differences](#differences).

### `NaiveDateTime.endOfDay(): NaiveDateTime`

The last representable instant of the named period. See [Boundaries](#boundaries).

### `NaiveDateTime.endOfMonth(): NaiveDateTime`

The last representable instant of the named period. See [Boundaries](#boundaries).

### `NaiveDateTime.endOfQuarter(): NaiveDateTime`

The last representable instant of the named period. See [Boundaries](#boundaries).

### `NaiveDateTime.endOfWeek(): NaiveDateTime`

The last representable instant of the named period. See [Boundaries](#boundaries).

### `NaiveDateTime.endOfWeekOn(day: i64): NaiveDateTime`

The last representable instant of the named period. See [Boundaries](#boundaries).

### `NaiveDateTime.endOfYear(): NaiveDateTime`

The last representable instant of the named period. See [Boundaries](#boundaries).

### `NaiveDateTime.format(pattern: string): string!`

Renders this value using the LDML pattern `pattern`. See [Formatting and parsing](#formatting-and-parsing).

### `NaiveDateTime.hour(): i64`

Returns the hour, `0` to `23`. See [Fields](#fields).

### `NaiveDateTime.inZone(z: Zone): DateTime`

Reads this wall clock, or this instant, as a `DateTime` in zone `z`. See [Converting between types](#converting-between-types).

### `NaiveDateTime.isAfter(other: NaiveDateTime): bool`

Whether this value is strictly after `other`. See [Comparing](#comparing).

### `NaiveDateTime.isBefore(other: NaiveDateTime): bool`

Whether this value is strictly before `other`. See [Comparing](#comparing).

### `NaiveDateTime.isBetween(lo: NaiveDateTime, hi: NaiveDateTime): bool`

Whether this value falls within `lo` and `hi`, inclusive. See [Comparing](#comparing).

### `NaiveDateTime.isBusinessDay(c: Calendar): bool`

Whether this date is a business day under calendar `c`: not a weekend day and not a holiday. See [Business days](#business-days).

### `NaiveDateTime.isLeapYear(): bool`

Whether this value's year is a Gregorian leap year.

### `NaiveDateTime.isSame(other: NaiveDateTime): bool`

Whether this value is equal to `other`. See [Comparing](#comparing).

### `NaiveDateTime.isSameDay(other: NaiveDateTime): bool`

Whether this value and `other` fall on the same calendar day.

### `NaiveDateTime.isSameMonth(other: NaiveDateTime): bool`

Whether this value and `other` fall on the same month.

### `NaiveDateTime.isSameYear(other: NaiveDateTime): bool`

Whether this value and `other` fall on the same year.

### `NaiveDateTime.isWeekday(w: Weekend): bool`

Whether this date is a working day under `w`. See [Business days](#business-days).

### `NaiveDateTime.isWeekend(w: Weekend): bool`

Whether this date is a weekend day under `w`. See [Business days](#business-days).

### `NaiveDateTime.minute(): i64`

Returns the minute, `0` to `59`. See [Fields](#fields).

### `NaiveDateTime.month(): i64`

Returns the month, `1` to `12`. See [Fields](#fields).

### `NaiveDateTime.nanosecond(): i64`

Returns the nanosecond, `0` to `999999999`. See [Fields](#fields).

### `NaiveDateTime.nextBusinessDay(c: Calendar): Date`

The next business day under calendar `c`, strictly after this date; never returns this date, even when it is itself a business day. See [Business days](#business-days).

### `NaiveDateTime.previousBusinessDay(c: Calendar): Date`

The previous business day under calendar `c`, strictly before this date; never returns this date, even when it is itself a business day. See [Business days](#business-days).

### `NaiveDateTime.quarter(): i64`

Returns the quarter, `1` to `4`. See [Fields](#fields).

### `NaiveDateTime.second(): i64`

Returns the second, `0` to `59`, never `60`. See [Fields](#fields).

### `NaiveDateTime.startOfDay(): NaiveDateTime`

The first representable instant of the named period. See [Boundaries](#boundaries).

### `NaiveDateTime.startOfMonth(): NaiveDateTime`

The first representable instant of the named period. See [Boundaries](#boundaries).

### `NaiveDateTime.startOfQuarter(): NaiveDateTime`

The first representable instant of the named period. See [Boundaries](#boundaries).

### `NaiveDateTime.startOfWeek(): NaiveDateTime`

The first representable instant of the named period. See [Boundaries](#boundaries).

### `NaiveDateTime.startOfWeekOn(day: i64): NaiveDateTime`

The first representable instant of the named period. See [Boundaries](#boundaries).

### `NaiveDateTime.startOfYear(): NaiveDateTime`

The first representable instant of the named period. See [Boundaries](#boundaries).

### `NaiveDateTime.time(): Time`

The time-of-day half of this value, dropping the date.

### `NaiveDateTime.toString(): string`

This value's canonical text form, the same text its matching `parse*` function reads back.

### `NaiveDateTime.weekOfYear(): i64`

Returns the ISO 8601 week number, `1` to `53`. See [Fields](#fields).

### `NaiveDateTime.withDay(d: i64): NaiveDateTime`

Returns a copy of this `NaiveDateTime` with its day replaced. See [Arithmetic](#arithmetic-and-setting-a-field).

### `NaiveDateTime.withHour(h: i64): NaiveDateTime`

Returns a copy of this `NaiveDateTime` with its hour replaced. See [Arithmetic](#arithmetic-and-setting-a-field).

### `NaiveDateTime.withMinute(mi: i64): NaiveDateTime`

Returns a copy of this `NaiveDateTime` with its minute replaced. See [Arithmetic](#arithmetic-and-setting-a-field).

### `NaiveDateTime.withMonth(mo: i64): NaiveDateTime`

Returns a copy of this `NaiveDateTime` with its month replaced. See [Arithmetic](#arithmetic-and-setting-a-field).

### `NaiveDateTime.withNanosecond(ns: i64): NaiveDateTime`

Returns a copy of this `NaiveDateTime` with its nanosecond replaced. See [Arithmetic](#arithmetic-and-setting-a-field).

### `NaiveDateTime.withSecond(s: i64): NaiveDateTime`

Returns a copy of this `NaiveDateTime` with its second replaced. See [Arithmetic](#arithmetic-and-setting-a-field).

### `NaiveDateTime.withTime(h: i64, m: i64, s: i64): NaiveDateTime`

Returns a copy of this value with a new time of day, keeping the date. See [Arithmetic](#arithmetic-and-setting-a-field).

### `NaiveDateTime.withYear(y: i64): NaiveDateTime`

Returns a copy of this `NaiveDateTime` with its year replaced. See [Arithmetic](#arithmetic-and-setting-a-field).

### `NaiveDateTime.year(): i64`

Returns the year, `1` to `9999`. See [Fields](#fields).


## Time reference

### `Time`

A time of day with no date and no zone: a shop opening at `09:00`. Immutable.

### `Time.addHours(n: i64): Time`

Returns a copy of this `Time` with `n` hours added; `n` may be negative. See [Arithmetic](#arithmetic-and-setting-a-field).

### `Time.addMinutes(n: i64): Time`

Returns a copy of this `Time` with `n` minutes added; `n` may be negative. See [Arithmetic](#arithmetic-and-setting-a-field).

### `Time.addNanoseconds(n: i64): Time`

Returns a copy of this `Time` with `n` nanoseconds added; `n` may be negative. See [Arithmetic](#arithmetic-and-setting-a-field).

### `Time.addSeconds(n: i64): Time`

Returns a copy of this `Time` with `n` seconds added; `n` may be negative. See [Arithmetic](#arithmetic-and-setting-a-field).

### `Time.compare(other: Time): i64`

Returns `-1`, `0` or `1` for sorting against another value of the same type. See [Comparing](#comparing).

### `Time.format(pattern: string): string!`

Renders this value using the LDML pattern `pattern`. See [Formatting and parsing](#formatting-and-parsing).

### `Time.hour(): i64`

Returns the hour, `0` to `23`. See [Fields](#fields).

### `Time.isAfter(other: Time): bool`

Whether this value is strictly after `other`. See [Comparing](#comparing).

### `Time.isBefore(other: Time): bool`

Whether this value is strictly before `other`. See [Comparing](#comparing).

### `Time.isBetween(lo: Time, hi: Time): bool`

Whether this value falls within `lo` and `hi`, inclusive. See [Comparing](#comparing).

### `Time.isSame(other: Time): bool`

Whether this value is equal to `other`. See [Comparing](#comparing).

### `Time.minute(): i64`

Returns the minute, `0` to `59`. See [Fields](#fields).

### `Time.nanosecond(): i64`

Returns the nanosecond, `0` to `999999999`. See [Fields](#fields).

### `Time.second(): i64`

Returns the second, `0` to `59`, never `60`. See [Fields](#fields).

### `Time.toString(): string`

This value's canonical text form, the same text its matching `parse*` function reads back.

### `Time.withHour(h: i64): Time`

Returns a copy of this `Time` with its hour replaced. See [Arithmetic](#arithmetic-and-setting-a-field).

### `Time.withMinute(mi: i64): Time`

Returns a copy of this `Time` with its minute replaced. See [Arithmetic](#arithmetic-and-setting-a-field).

### `Time.withNanosecond(ns: i64): Time`

Returns a copy of this `Time` with its nanosecond replaced. See [Arithmetic](#arithmetic-and-setting-a-field).

### `Time.withSecond(s: i64): Time`

Returns a copy of this `Time` with its second replaced. See [Arithmetic](#arithmetic-and-setting-a-field).


## Timestamp reference

### `Timestamp`

Nanoseconds since the Unix epoch, with no zone: what a database column holds. Returned by `now()`. Immutable.

### `Timestamp.add(ns: i64): Timestamp`

Returns a copy of this `Timestamp` with `ns`  added; `ns` may be negative. See [Arithmetic](#arithmetic-and-setting-a-field).

### `Timestamp.compare(other: Timestamp): i64`

Returns `-1`, `0` or `1` for sorting against another value of the same type. See [Comparing](#comparing).

### `Timestamp.differenceInHours(other: Timestamp): i64`

The whole hours from this value to `other`, truncated toward zero. See [Differences](#differences).

### `Timestamp.differenceInMinutes(other: Timestamp): i64`

The whole minutes from this value to `other`, truncated toward zero. See [Differences](#differences).

### `Timestamp.differenceInNanoseconds(other: Timestamp): i64`

The whole nanoseconds from this value to `other`, truncated toward zero. See [Differences](#differences).

### `Timestamp.differenceInSeconds(other: Timestamp): i64`

The whole seconds from this value to `other`, truncated toward zero. See [Differences](#differences).

### `Timestamp.inZone(z: Zone): DateTime`

Reads this wall clock, or this instant, as a `DateTime` in zone `z`. See [Converting between types](#converting-between-types).

### `Timestamp.isAfter(other: Timestamp): bool`

Whether this value is strictly after `other`. See [Comparing](#comparing).

### `Timestamp.isBefore(other: Timestamp): bool`

Whether this value is strictly before `other`. See [Comparing](#comparing).

### `Timestamp.isBetween(lo: Timestamp, hi: Timestamp): bool`

Whether this value falls within `lo` and `hi`, inclusive. See [Comparing](#comparing).

### `Timestamp.isFuture(): bool`

Whether this value is after `now()`, checked at the moment this is called.

### `Timestamp.isPast(): bool`

Whether this value is before `now()`, checked at the moment this is called.

### `Timestamp.isSame(other: Timestamp): bool`

Whether this value is equal to `other`. See [Comparing](#comparing).

### `Timestamp.toString(): string`

This value's canonical text form, the same text its matching `parse*` function reads back.


## HijriDate reference

### `HijriDate`

A Hijri calendar date in the Umm al-Qura variant, produced by rendering a Gregorian `Date`. See [Hijri dates](#hijri-dates).

### `HijriDate.day(): i64`

Returns the day of the month, `1` to `31`. See [Fields](#fields).

### `HijriDate.format(pattern: string): string!`

Renders this value using the LDML pattern `pattern`. See [Formatting and parsing](#formatting-and-parsing).

### `HijriDate.gregorian(): Date`

The Gregorian `Date` this Hijri date renders; never fails.

### `HijriDate.month(): i64`

Returns the month, `1` to `12`. See [Fields](#fields).

### `HijriDate.toString(): string`

This value's canonical text form, the same text its matching `parse*` function reads back.

### `HijriDate.year(): i64`

Returns the year, `1` to `9999`. See [Fields](#fields).


## Ticker reference

### `Ticker`

A repeating timer; `.c` receives `true` every interval until stopped. See [Timer channels](#timer-channels).

### `Ticker.stop(): bool`

Cancels this ticker; returns whether it was still pending. After a `true`, no further tick is sent; a tick already sitting in `.c` stays until received. See [Timer channels](#timer-channels).


## Timer reference

### `Timer`

A one-shot timer; `.c` receives `true` once when it fires. See [Timer channels](#timer-channels).

### `Timer.reset(d: i64): bool`

Re-arms this timer to fire `d` nanoseconds from now; returns `false`, with no effect, if it had already fired.

### `Timer.stop(): bool`

Cancels this timer; returns whether it was still pending.


## Zones, calendars and clocks reference

### `Zone`

An IANA time zone, identified by its canonical name, such as `Asia/Dubai`. Immutable and safe to share across green threads. See [Zones](#zones).

### `zone(name: string): Zone!`

Loads the zone named `name` from the host's zone database. Fails when the name is not a real zone, or when neither the host nor an installed extension has it, or when the file found is malformed, including a rule after its last change that is not a valid POSIX TZ string or that disagrees with the last change. See [Zones](#zones).

### `localZone(): Zone`

The host's own zone, read from its local time settings. Falls back to `utc()` on any failure, so this never fails.

### `utc(): Zone`

The UTC zone: no transitions, offset always `0`. Never touches the filesystem and never fails.

### `extend(data: string): bool`

Installs a zone database extension for hosts with no zone data of their own, such as a minimal container image. Returns whether it was accepted; a current host database always wins over the extension, and a second call always returns `false`. See [Zones](#zones).

### `Calendar`

A `Weekend` plus a set of holiday dates: everything `isBusinessDay` needs. Built by `calendar`. See [Business days](#business-days).

### `Weekend`

Which days of the week are not worked, as day numbers `1` Monday through `7` Sunday. See [Business days](#business-days).

### `calendar(w: Weekend, holidays: []Date): Calendar`

Builds a business calendar from a `Weekend` and a set of holiday dates. This module ships no holiday list for any country. See [Business days](#business-days).

### `weekendSatSun(): Weekend`

Saturday and Sunday off. The common default: Europe, the Americas, and the UAE since 2022.

### `weekendFriSat(): Weekend`

Friday and Saturday off: Saudi Arabia, Egypt, and much of the region.

### `weekendOn(days: []i64): Weekend!`

A weekend on exactly the given day numbers, each `1` Monday through `7` Sunday, for any pattern the two named constructors above do not cover. Fails on a number outside `1..7`, or on a set covering all seven days.

### `date(year: i64, month: i64, day: i64): Date!`

Builds a calendar date. Fails when `month` is outside `1..12`, `day` is outside that month's range, or `year` is outside `1..9999`. See [Constructing](#constructing).

### `time(hour: i64, minute: i64, second: i64): Time!`

Builds a time of day with zero nanoseconds. Fails when any field is out of range; a `second` of `60` fails, since this module has no leap seconds. See [Constructing](#constructing).

### `timeNs(hour: i64, minute: i64, second: i64, nanosecond: i64): Time!`

As `time`, with an explicit nanosecond field. Fails on the same three fields, plus when `nanosecond` is outside `0..999999999`.

### `today(z: Zone): Date`

The calendar date it is right now in zone `z`. Never fails: every instant has exactly one calendar date in every zone. See [Constructing](#constructing).

### `now(): Timestamp`

The current instant, as nanoseconds since the Unix epoch. Follows the system clock, so it can jump backwards on an NTP correction; use it to stamp an event, never to measure an interval. See [Clocks](#clocks).

### `Mono`

A monotonic clock reading, returned by `monotonic()`. Only differences between two readings from this clock are meaningful, and they never go backwards. See [Clocks](#clocks).

### `monotonic(): Mono`

The current reading of the monotonic clock, meaningful only when compared with another reading from this same clock. See [Clocks](#clocks).

### `since(start: Mono): i64`

Nanoseconds elapsed since the `monotonic()` reading `start`.

### `sleep(d: i64): ()`

Parks the calling green thread for at least `d` nanoseconds without blocking an OS thread. `d <= 0` yields once and returns at once. See [Sleeping](#sleeping).

### `sleepUntil(deadlineNs: i64): ()`

Parks the calling green thread until `deadlineNs` on the `monotonic()` clock, an absolute instant rather than a duration. Useful when several callers must wake at the exact same moment. See [Sleeping](#sleeping).

### `Timer(d: i64)`

Starts a one-shot `Timer` that fires `d` nanoseconds from now.

### `Ticker(d: i64)`

Starts a `Ticker` that ticks every `d` nanoseconds.

### `after(d: i64): chan<bool>`

A channel that receives `true` once, `d` nanoseconds from now: the idiomatic `select` timeout arm. Its slot self-frees once it fires, even if the timeout arm is never taken. See [Timer channels](#timer-channels).

### `tick(d: i64): chan<bool>`

A channel that receives `true` every `d` nanoseconds, forever. There is no way to stop it, so prefer `Ticker(d)` when the ticker must ever be stopped.

## Formatting, parsing and Hijri dates reference

### `parseDate(s: string): Date!`

Reads back a `Date.toString()` result, `YYYY-MM-DD`. Fails on any other shape, or on a date no calendar has.

### `parseTime(s: string): Time!`

Reads back a `Time.toString()` result, `HH:MM:SS` with an optional fractional part. Fails on a `:60` leap second or a fraction of ten or more digits.

### `parseNaiveDateTime(s: string): NaiveDateTime!`

Reads back a `NaiveDateTime.toString()` result, `YYYY-MM-DDTHH:MM:SS` with an optional fraction. The `T` must be uppercase.

### `parseDateTime(s: string): DateTime!`

Reads back a `DateTime.toString()` result: a wall clock plus `Z` or a `+HH:MM`/`-HH:MM` offset. The result's zone is a fixed offset, not a named zone, since an offset does not say which zone produced it; call `.withZone(z)` once the real zone is known.

### `parseWith(pattern: string, s: string): NaiveDateTime!`

Reads `s` against the LDML pattern `pattern`, the same pattern language `format` writes. A field the pattern does not name keeps its default. See [Formatting and parsing](#formatting-and-parsing).

### `formatHttpDate(t: Timestamp): string`

Writes `t` as an IMF-fixdate, `Sun, 06 Nov 1994 08:49:37 GMT`, the only form RFC 9110 lets a sender write. A fraction of a second is dropped toward the past. See [HTTP dates](#http-dates).

### `parseHttpDate(s: string, reference: Timestamp = now()): Timestamp!`

Reads an IMF-fixdate, an RFC 850 date or an asctime date to the instant it names. Fails with an `HttpDateError` on any other text, a field out of range, a zone other than `GMT`, or a day name that does not match the date. `reference` places an RFC 850 two-digit year by the 50-year rule and is read for no other form.

### `HttpDateCause`

Which of the four things went wrong: `Syntax`, `Range`, `Zone` or `Weekday`.

### `HttpDateError`

The error every `parseHttpDate` failure produces: `cause`, and `input`, the text that was refused. Reach the fields with `e.(HttpDateError)`.

### `HttpDateError.message`

A fixed one-sentence summary of the cause, without the input; the same text the caught `error` reports.

### `parseRfc3339(s: string): Timestamp!`

Reads an RFC 3339 section 5.6 `date-time` to the instant it names: `T` or `t`, `Z`, `z` or a `+hh:mm` / `-hh:mm` offset (`-00:00` is UTC), a fraction of any length (digits past the ninth are truncated), and `:60` only at a UTC month end (read as the next second). Fails with a `TimestampParseError`: `Syntax` for any other text, `Range` for a field out of bounds or an instant a `Timestamp` cannot hold.

### `parseEpochSeconds(s: string): Timestamp!`

Reads a decimal number of seconds since the epoch, `-?digits(.digits)?([eE][+-]?digits)?`, to the instant it names. Negative values and any digit count are read without overflow; digits past the ninth fractional one are truncated toward the past. Fails with a `TimestampParseError`: `Syntax` for any other text, `Range` for an instant a `Timestamp` cannot hold.

### `TimestampParseCause`

Which of the two things went wrong: `Syntax` or `Range`.

### `TimestampParseError`

The error `parseRfc3339` and `parseEpochSeconds` produce: `cause`, and `input`, the text that was refused. Reach the fields with `e.(TimestampParseError)`.

### `TimestampParseError.message`

A fixed one-sentence summary of the cause, without the input; the same text the caught `error` reports.

### `hijriDate(year: i64, month: i64, day: i64): HijriDate!`

Builds a Hijri date directly, for reading one off a document. Fails when any field is outside its tabulated range. See [Hijri dates](#hijri-dates).

## Durations reference

### `Nanosecond: i64`

One nanosecond, the base unit every duration is built from.

### `Microsecond: i64`

`1000` nanoseconds.

### `Millisecond: i64`

`1000000` nanoseconds.

### `Second: i64`

`1000000000` nanoseconds.

### `Minute: i64`

`60000000000` nanoseconds.

### `Hour: i64`

`3600000000000` nanoseconds.

### `millis(d: i64): i64`

Whole milliseconds in `d`, truncated.

### `secs(d: i64): i64`

Whole seconds in `d`, truncated.

### `toMillis(d: i64): f64`

`d` as fractional milliseconds.

### `toSeconds(d: i64): f64`

`d` as fractional seconds.

### `formatDuration(d: i64): string`

Renders a duration the way a person reads it: `340ns`, `340ms`, `45s`, `1h23m4s`. Below one second it prints a single truncated unit; at or above one second it prints hours, minutes and seconds, each truncated to a whole second.

## Where to go next

- Installing zone data in a container with no `/usr/share/zoneinfo`: `std/tz`.
- Handling dates and time zones end to end in a real program: [The Bit
  Book, chapter 9](/book/09-words-and-dates).
- Propagating a construction or parsing failure with `?` and `catch`:
  [Errors](/language/errors).

---

Specification: `spec/SPEC.md`.
