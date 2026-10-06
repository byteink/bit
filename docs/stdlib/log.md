# std/log

Structured, leveled logging. Inkwell's publish job logs `published draft 41 in
312ms` today, and the day you want to count failures, filter by author, or feed
the lines to a log pipeline, you are parsing English. A structured logger
writes the message and the facts as separate fields, so a person reads
`msg="draft published" id=41 took=312ms` and a machine reads
`{"msg":"draft published","id":41,"took":312000000}`, from the same call.

A `Logger` level method returns a `Record`; typed methods add the facts to it
and `log(msg)` writes it through a `Handler`, which decides where the bytes
go. The message comes last because it is what finishes the record: `log` is
the one call that writes, so the line reads as what it does.

<!-- doctest: per-block -->

```bit
import { Logger, TextHandler } from "std/log"
import { stdout } from "std/io"

fn main() {
  let log = Logger(TextHandler(stdout(), timestamps = false))
  log.info().int("id", 41).str("author", "ada").duration("took", 312000000).log("draft published")
}
```

This prints:

```text
level=INFO msg="draft published" id=41 author=ada took=312ms
```

## Levels

There are four named levels, `LevelDebug`, `LevelInfo`, `LevelWarn` and
`LevelError`, and a handler built with a `level` drops everything below it.
The default is `LevelInfo`, so `debug` lines cost nothing in production.

```bit
import { Logger, TextHandler, LevelWarn, LevelInfo, levelName } from "std/log"
import { stdout } from "std/io"

fn main() {
  let log = Logger(TextHandler(stdout(), LevelWarn, false))
  log.info().log("not shown")
  log.warn().log("disk at 91 percent")
  log.at(LevelInfo + 2).log("also not shown: below LevelWarn")
  if (log.enabled(LevelWarn)) {
    log.error().log("shown")
  }
  log.debug().log("not shown either")
  println(levelName(LevelInfo + 2)) // INFO+2
}
```

A level is a plain `int`, so `LevelInfo + 2` is a "notice" level of your own
and `levelName` renders it as `INFO+2`. `Logger.at(level)` is the one core;
`debug()`, `info()`, `warn()` and `error()` are it with the level filled in.

## Attributes

An attribute is a key and a typed value, added with `str`, `int`, `float`,
`bool`, `duration` (nanoseconds, as everywhere in Bit), `time`, `err` and
`group`. Typed values matter because the JSON handler writes `1500` as a
number and `"1500"` as a string, and your pipeline can tell them apart.

```bit
import { Logger, JsonHandler, attrs } from "std/log"
import { stdout } from "std/io"
import { now } from "std/time"

fn main() {
  let log = Logger(JsonHandler(stdout(), timestamps = false))
  let r = log.error().int("draft", 41).float("score", 0.5).bool("retry", true)
  r = r.duration("took", 1500000000).time("scheduled", now()).err(newError("tags table locked"))
  r.group("author", attrs().str("name", "ada").int("posts", 12)).log("publish failed")
}
```

`err(e)` writes the error's message under the key `error`; pass a second
argument to rename it. `group` nests the attributes of a record built with
`attrs()`: `author.name=ada` in text, `{"author":{"name":"ada"}}` in JSON. A
group with no attributes is left out. `attrs()` has no logger, so calling
`log` on it panics; it exists for `group` and `with`.

An empty key panics at the call, enabled or not, because a field with no name
is a bug in the caller and the log is the wrong place to discover it.

## What a line costs

A record holds its first five attributes in its own fields, so an enabled
line with up to five costs two objects, the record and the line, whatever
those attributes are; each one past five, and a group, is one `Attr` more.
When the level is off, the level method returns a shared record that keeps
nothing, so the whole chain allocates nothing and needs no `enabled` guard:
measured with `BIT_GC_STATS=1`, a disabled call carrying three attributes
costs 0 objects. What the arguments cost
to compute is still paid: `enabled` guards a value that is expensive to
build. A record is written only by `log(msg)`, so a chain without it writes
nothing.

## Children: `with` and `withGroup`

Every line of one request should carry the request id. `with` returns a child
logger that adds attributes, built with `attrs()`, to everything it writes,
and `withGroup` nests what comes after it. The parent is not changed.

```bit
import { Logger, TextHandler, attrs } from "std/log"
import { stdout } from "std/io"

fn main() {
  let root = Logger(TextHandler(stdout(), timestamps = false))
  let req = root.with(attrs().str("req", "a41"))
  let db = req.withGroup("db").with(attrs().str("table", "drafts"))
  db.info().int("rows", 3).log("query")
  req.info().log("done")
}
```

```text
level=INFO msg=query req=a41 db.table=drafts db.rows=3
level=INFO msg=done req=a41
```

## Output

`TextHandler` writes `key=value` pairs. A value that is empty, or holds a
space, `=`, `"`, `\` or a control character, is quoted and escaped, so a user
who submits the title `x\nlevel=ERROR msg=forged` gets one line, with the
newline written as `\n`. They cannot start a line of their own. Keys are
treated the same way.

`JsonHandler` writes one JSON object per line, escaped by `std/json`'s own
string escaper. Both handlers add a `time` field (RFC 3339, UTC) first unless
you pass `timestamps = false`, and both write a record with one `write` call
under a lock, so lines from two tasks never interleave.

The destination is any `Sink`: a class with `write(s: string): ()!`. `std/io`'s
`stdout()`, `stderr()` and `writer(fd)` all qualify, and so does a class of
your own, such as a buffer a test reads back.

A failed write is dropped. A log line must not take the program down, and the
log is the only place a failure could be reported.

## The process default

`getDefault()` is a `TextHandler` on stderr at `LevelInfo` until you replace
it. Set your own once, at startup, before spawning tasks.

```bit
import { Logger, JsonHandler, LevelDebug, getDefault, setDefault } from "std/log"
import { stderr } from "std/io"

fn main() {
  setDefault(Logger(JsonHandler(stderr(), LevelDebug)))
  getDefault().debug().str("service", "inkwell").log("starting")
}
```

Calling `setDefault` a second time panics: two parts of a program fighting
over the default is a bug to find, not to paper over.

## Your own handler

`Handler` has four methods: `enabled(level)`, `handle(record)`,
`with(attrs)` and `withGroup(name)`. A `Record` answers `unixNanos()`,
`level()`, `message()` and `attrs()`; `attrs()` builds an `Attr` (`key`,
`kind`, `num`, `flt`, `str`, `group`) for each attribute on every call, which
the shipped handlers never do. Implement them to route records to a metrics
counter, a network sink, or a test double.

```bit
import { Logger, Handler, Record, Attr, LevelInfo } from "std/log"

class Counter {
  n: int
  export enabled(level: int): bool {
    return level >= LevelInfo
  }
  export handle(r: Record): ()! {
    if (r.level() >= LevelInfo && r.message() != "" && r.unixNanos() > 0) {
      this.n = this.n + len(r.attrs())
    }
  }
  export with(attrs: []Attr): Handler {
    return this
  }
  export withGroup(name: string): Handler {
    return this
  }
}

fn main() {
  let c = Counter{ n = 0 }
  Logger(c).info().int("a", 1).int("b", 2).log("counted")
  println("${c.n}") // 2
}
```

## Sharp edges

- `Logger(nil)`, `TextHandler(nil)` and `JsonHandler(nil)` panic: a logger
  with nowhere to write is a bug.
- A text `Duration` keeps its fraction (`1.5s`, `340ms`); JSON writes the
  integer nanoseconds.
- Level is fixed when the handler is built. To change it, build another
  handler.

## Reference

### `Logger`

The call-site API: a `Handler` plus the level methods. Build one with
`Logger(handler)`.

### `Logger(h: Handler)`

A logger writing through `h`.

### `Logger.at(level: int): Record`

A record at `level` to add attributes to and write with `log(msg)`; a shared
record that keeps nothing when `level` is disabled.

### `Logger.debug(): Record`

`at(LevelDebug)`.

### `Logger.info(): Record`

`at(LevelInfo)`.

### `Logger.warn(): Record`

`at(LevelWarn)`.

### `Logger.error(): Record`

`at(LevelError)`.

### `Logger.enabled(level: int): bool`

Whether a record at `level` would be written. Use it to guard a value that is
expensive to compute.

### `Logger.with(fields: Record): Logger`

A child logger that adds the attributes of `fields`, built with `attrs()`, to
every record.

### `Logger.withGroup(name: string): Logger`

A child logger whose later attributes nest under `name`.

### `getDefault(): Logger`

The process default logger.

### `setDefault(l: Logger)`

Replaces the process default; panics on a second call.

### `LevelDebug: int`

The debug level, `-4`.

### `LevelInfo: int`

The info level, `0`.

### `LevelWarn: int`

The warn level, `4`.

### `LevelError: int`

The error level, `8`.

### `levelName(level: int): string`

`"DEBUG"`, `"INFO"`, `"WARN"`, `"ERROR"`, or the nearest lower name plus an
offset such as `"INFO+2"`.

### `Attr`

A key and a typed value, as `Record.attrs()` and `Handler.with` hand them to a
handler of your own. Read-only fields: `key`, `kind`, `num`, `flt`, `str`,
`group`.

### `Kind`

Which field of an `Attr` holds its value: `String`, `Int`, `Float`, `Bool`,
`Duration`, `Time`, `Error` or `Group`.

### `Record`

The builder a level method returns, and what a handler receives. Its first
five attributes live in its own fields.

### `attrs(): Record`

A record with no logger, for `group` and `Logger.with`. `log` on it panics.

### `Record.str(key: string, value: string): Record`

A string attribute.

### `Record.int(key: string, value: int): Record`

An integer attribute.

### `Record.float(key: string, value: f64): Record`

A float attribute. JSON writes a non-finite value as `null`.

### `Record.bool(key: string, value: bool): Record`

A boolean attribute.

### `Record.duration(key: string, nanos: int): Record`

A duration in nanoseconds.

### `Record.time(key: string, at: Timestamp): Record`

A point in time, written as RFC 3339.

### `Record.err(e: error, key: string = "error"): Record`

An error's message.

### `Record.group(key: string, members: Record): Record`

The attributes of `members` nested under `key`.

### `Record.log(msg: string)`

Writes the record with `msg`, or nothing when its level was disabled.

### `Record.unixNanos(): int`

Nanoseconds since the Unix epoch at which the record was made.

### `Record.level(): int`

The record's level.

### `Record.message(): string`

The message `log` was given.

### `Record.attrs(): []Attr`

Every attribute in order, as a fresh `Attr` each.

### `Handler`

The interface a destination implements: `enabled`, `handle`, `with`,
`withGroup`.

### `Sink`

The interface a handler writes finished lines to: `write(s: string): ()!`.

### `TextHandler`

A handler writing `key=value` lines.

### `TextHandler(out: Sink, level: int = LevelInfo, timestamps: bool = true)`

A text handler writing to `out`.

### `JsonHandler`

A handler writing one JSON object per line.

### `JsonHandler(out: Sink, level: int = LevelInfo, timestamps: bool = true)`

A JSON handler writing to `out`.

### `TextHandler.enabled(level: int): bool`

Whether `level` is at or above this handler's level.

### `TextHandler.handle(r: Record): ()!`

Writes `r` as one text line, or fails when the sink's `write` fails.

### `TextHandler.with(attrs: []Attr): Handler`

A child handler that adds `attrs` to every record. `Logger.with` calls this.

### `TextHandler.withGroup(name: string): Handler`

A child handler that nests later attributes under `name`. `Logger.withGroup`
calls this.

### `JsonHandler.enabled(level: int): bool`

Whether `level` is at or above this handler's level.

### `JsonHandler.handle(r: Record): ()!`

Writes `r` as one JSON line, or fails when the sink's `write` fails.

### `JsonHandler.with(attrs: []Attr): Handler`

A child handler that adds `attrs` to every record. `Logger.with` calls this.

### `JsonHandler.withGroup(name: string): Handler`

A child handler that nests later attributes under `name`. `Logger.withGroup`
calls this.
