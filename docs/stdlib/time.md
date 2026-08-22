# std/time

Durations are plain `int` nanoseconds. There is no `Duration` type, so a duration
is built by multiplying a count by a unit constant: `500 * Millisecond`.

Two clocks, for two different jobs. `now` tells you *when*; `monotonic` tells you
*how long*, and never jumps when the system clock is adjusted.

<!-- doctest: per-block -->

## Units

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

```bit
import { Millisecond, Second } from "std/time"

fn timeout(): int {
  return 250 * Millisecond
}

fn retryDelay(attempt: int): int {
  return attempt * Second
}
```

## Clocks

### `now(): int`

Nanoseconds since the Unix epoch. Follows the system clock, so it can jump
backwards. Use it to stamp an event, never to measure an interval.

### `monotonic(): int`

Nanoseconds from an unspecified fixed origin. Only differences are meaningful,
and they never go backwards. This is the one to time things with.

### `since(start: int): int`

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

## Sleeping

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

## Converting a duration

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

## Formatting a duration

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

## Calendar

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
  let c = Civil{ year: 2024, month: 2, day: 29, hour: 0, minute: 0, second: 0,
    nanosecond: 0, weekday: 0, yearDay: 0 }
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

## Calendar arithmetic

Every function below takes and returns nanoseconds since the Unix epoch, and
every operation is UTC.

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
