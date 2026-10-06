# std/log

Structured, leveled logging. Inkwell's publish job logs `published draft 41 in
312ms` today, and the day you want to count failures, filter by author, or feed
the lines to a log pipeline, you are parsing English. A structured logger
writes the message and the facts as separate fields, so a person reads
`msg="draft published" id=41 took=312ms` and a machine reads
`{"msg":"draft published","id":41,"took":312000000}`, from the same call.

The design follows Go's `log/slog`: a `Logger` turns each call into a
`Record` and hands it to a `Handler`, which decides where the bytes go.

<!-- doctest: per-block -->

```bit
import { Logger, TextHandler, Str, Int, Duration } from "std/log"
import { stdout } from "std/io"

fn main() {
  let log = Logger(TextHandler(stdout(), timestamps = false))
  log.info("draft published", Int("id", 41), Str("author", "ada"), Duration("took", 312000000))
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
  log.info("not shown")
  log.warn("disk at 91 percent")
  log.log(LevelInfo + 2, "also not shown: below LevelWarn")
  println(levelName(LevelInfo + 2)) // INFO+2
}
```

A level is a plain `int`, so `LevelInfo + 2` is a "notice" level of your own
and `levelName` renders it as `INFO+2`. `Logger.log(level, msg, attrs...)` is
the one core; `debug`, `info`, `warn` and `error` are it with the level filled
in.

## Attributes

An attribute is a key and a typed value. The constructors are `Str`, `Int`,
`Float`, `Bool`, `Duration` (nanoseconds, as everywhere in Bit), `Time`,
`Err` and `Group`. Typed values matter because the JSON handler writes `1500`
as a number and `"1500"` as a string, and your pipeline can tell them apart.

```bit
import { Logger, JsonHandler, Str, Int, Float, Bool, Duration, Time, Err, Group } from "std/log"
import { stdout } from "std/io"
import { now } from "std/time"

fn main() {
  let log = Logger(JsonHandler(stdout(), timestamps = false))
  log.error(
    "publish failed",
    Int("draft", 41),
    Float("score", 0.5),
    Bool("retry", true),
    Duration("took", 1500000000),
    Time("scheduled", now()),
    Err(newError("tags table locked")),
    Group("author", Str("name", "ada"), Int("posts", 12)),
  )
}
```

`Err(e)` writes the error's message under the key `error`; pass a second
argument to rename it. `Group` nests: `author.name=ada` in text,
`{"author":{"name":"ada"}}` in JSON. A group with no attributes is left out.

An empty key panics at the call, because a field with no name is a bug in the
caller and the log is the wrong place to discover it. The fields of an `Attr`
(`key`, `kind`, `num`, `flt`, `str`, `group`) are readable, so a handler of
your own can switch on `kind`.

## Children: `with` and `withGroup`

Every line of one request should carry the request id. `with` returns a child
logger that adds attributes to everything it writes, and `withGroup` nests
what comes after it. The parent is not changed.

```bit
import { Logger, TextHandler, Str, Int } from "std/log"
import { stdout } from "std/io"

fn main() {
  let root = Logger(TextHandler(stdout(), timestamps = false))
  let req = root.with(Str("req", "a41"))
  let db = req.withGroup("db").with(Str("table", "drafts"))
  db.info("query", Int("rows", 3))
  req.info("done")
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
import { Logger, JsonHandler, LevelDebug, Str, getDefault, setDefault } from "std/log"
import { stderr } from "std/io"

fn main() {
  setDefault(Logger(JsonHandler(stderr(), LevelDebug)))
  getDefault().debug("starting", Str("service", "inkwell"))
}
```

Calling `setDefault` a second time panics: two parts of a program fighting
over the default is a bug to find, not to paper over.

## On a hot path: `at(level)`

`logger.debug("msg")` with debug turned off asks the handler one question,
compares the level, and returns: no `Record`, no allocation. Measured with
`BIT_GC_STATS=1` over 10000 calls it allocates the same bytes as 0 calls.

Attributes passed to `info` and its siblings are built before the call, so
`log.debug("x", Int("i", i))` allocates the `Int` and the argument list even
when debug is off, and an enabled call costs one object per attribute. On a
path that logs per request or per item, start the record with `at(level)`
instead, add attributes with its typed methods, and finish with `log(msg)`:

```bit
import { Logger, TextHandler, LevelInfo } from "std/log"
import { stderr } from "std/io"

class Timeout {
  export message(): string {
    return "upstream timed out"
  }
}

fn main() {
  let log = Logger(TextHandler(stderr()))
  let i = 0
  while (i < 3) {
    let r = log.at(LevelInfo).str("route", "/users/:id").int("status", 200)
    r.duration("took", 412000).bool("cached", i > 0).float("ratio", 0.5).log("request")
    i = i + 1
  }
  log.at(LevelInfo).err(Timeout{}).log("retrying")
}
```

The record holds its first five attributes in its own fields, so a record of
up to five costs two objects, the record and the line, whatever those
attributes are; each one past five is an `Attr`. When the level is off, `at`
returns a shared record that keeps nothing, so the whole chain allocates
nothing and needs no `enabled` guard. A record is written only by `log(msg)`:
a chain without it writes nothing. Groups are not inline; nest them with
`withGroup` or pass a `Group` to `info`.

## Your own handler

`Handler` has four methods: `enabled(level)`, `handle(record)`,
`with(attrs)` and `withGroup(name)`. A `Record` answers `time()` (nanoseconds
since the Unix epoch), `level()`, `msg()` and `attrs()`; `attrs()` builds an
`Attr` for each attribute on every call, which the shipped handlers never
do. Implement them to route records to a metrics counter, a network sink, or
a test double.

```bit
import { Logger, Handler, Record, Attr, LevelInfo } from "std/log"

class Counter {
  n: int
  export enabled(level: int): bool {
    return level >= LevelInfo
  }
  export handle(r: Record): ()! {
    if (r.level() >= LevelInfo && r.msg() != "" && r.time() > 0) {
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
  Logger(c).at(LevelInfo).int("a", 1).int("b", 2).log("counted")
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

### `Logger.log(level: int, msg: string, ...attrs: Attr)`

Writes one record at `level` if the handler enables it.

### `Logger.debug(msg: string, ...attrs: Attr)`

`log` at `LevelDebug`.

### `Logger.info(msg: string, ...attrs: Attr)`

`log` at `LevelInfo`.

### `Logger.warn(msg: string, ...attrs: Attr)`

`log` at `LevelWarn`.

### `Logger.error(msg: string, ...attrs: Attr)`

`log` at `LevelError`.

### `Logger.at(level: int): Record`

A record at `level` to fill with the typed methods below and write with
`log(msg)`; a shared record that keeps nothing when `level` is disabled.

### `Logger.enabled(level: int): bool`

Whether a record at `level` would be written. Use it to guard calls whose
attributes are expensive to build.

### `Logger.with(...attrs: Attr): Logger`

A child logger that adds `attrs` to every record.

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

A key and a typed value. Read-only fields: `key`, `kind`, `num`, `flt`, `str`,
`group`.

### `Kind`

Which field of an `Attr` holds its value: `String`, `Int`, `Float`, `Bool`,
`Duration`, `Time`, `Error` or `Group`.

### `Str(key: string, value: string): Attr`

A string attribute.

### `Int(key: string, value: int): Attr`

An integer attribute.

### `Float(key: string, value: f64): Attr`

A float attribute. JSON writes a non-finite value as `null`.

### `Bool(key: string, value: bool): Attr`

A boolean attribute.

### `Duration(key: string, nanos: int): Attr`

A duration in nanoseconds.

### `Time(key: string, at: Timestamp): Attr`

A point in time, written as RFC 3339.

### `Err(e: error, key: string = "error"): Attr`

An error's message.

### `Group(key: string, ...attrs: Attr): Attr`

Attributes nested under `key`.

### `Record`

What one call produced, and the builder `Logger.at` returns. Its first five
attributes live in its own fields.

### `Record.str(key: string, value: string): Record`

### `Record.int(key: string, value: int): Record`

### `Record.float(key: string, value: f64): Record`

### `Record.bool(key: string, value: bool): Record`

### `Record.duration(key: string, nanos: int): Record`

### `Record.err(e: error, key: string = "error"): Record`

Add one attribute, as `Str`, `Int`, `Float`, `Bool`, `Duration` and `Err`
build one, and return the record. An empty key panics, enabled or not.

### `Record.log(msg: string)`

Writes the record with `msg`, or nothing when its level was disabled.

### `Record.time(): int`

Nanoseconds since the Unix epoch at which the record was made.

### `Record.level(): int`

### `Record.msg(): string`

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
