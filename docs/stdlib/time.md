# std/time

Durations are plain `int` nanoseconds. There is no `Duration` type, so a duration
is built by multiplying a count by a unit constant: `500 * Millisecond`.

Two clocks, for two different jobs. `now` tells you *when*; `monotonic` tells you
*how long*, and never jumps when the system clock is adjusted. Each returns its
own nominal record — `Instant` from `now`, `Mono` from `monotonic` — so a
reading from one clock can never be passed to the other clock's API by
accident; `.ns` gives the raw nanoseconds when a caller genuinely needs an int.

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

## Timer channels

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

## Local time zone

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

```bit
import { utcOffset, now } from "std/time"

fn localOffsetSeconds(): int {
  return utcOffset(now().ns)
}
```
