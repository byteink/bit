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
