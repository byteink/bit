# Logging

Inkwell's nightly job reads every draft through `db.asSystem()`, and the day a
page loads slowly you want to know which statement was slow and how many rows
it returned, without a password or an email address ever landing in a log file.
The ORM writes through `std/log`: one `Logger`
type for the whole program, and the handler you built decides whether a record
is text or JSON and where it goes.

## Pick a logger

`Options.logger` is an `Option<Logger>`. Unset means std/log's process default,
which drops everything below `INFO`.

```bit
import { Db, Options, open } from "orm"
import { Logger, TextHandler, LevelDebug } from "std/log"
import { stderr } from "std/io"

fn openAudited(url: string): Db! {
  let logger = Logger(TextHandler(stderr(), LevelDebug))
  return open(url, Options{ logger = Option.Some(logger) })?
}
```

With that logger, `db.asSystem().table<Draft>()` writes
`level=DEBUG msg="system access" table=drafts`. With the default logger the
call writes nothing and allocates nothing: a level that is off hands back a
shared record that keeps no attributes.

## Log every statement

`QueryLog` wraps a `Pool` or a transaction handle. The wrapper is itself a
`Data`, so it goes anywhere the original did, and it counts the statements that
pass through it.

```bit
import { Data, QueryLog } from "orm"
import { Logger } from "std/log"
import { Value } from "std/sql"

fn logged(db: Data, logger: Logger): Data {
  return QueryLog(logger).wrap(db)
}

fn slowOnly(db: Data, logger: Logger): Data {
  return QueryLog(logger, 50).wrap(db)
}

fn countedReads(db: Data, logger: Logger): int {
  let q = QueryLog(logger)
  let counted = q.wrap(db)
  counted.query("select id from drafts", []Value(0)) catch _ {}
  return q.statementCount
}
```

Each finished statement is one `INFO` record:

```text
level=INFO msg=statement sql="select id from drafts where author = $1" rows=3 took=412us
```

A statement slower than the threshold writes a second, `WARN` record,
`msg="slow statement"`, with the same three attributes. The default threshold
is 200ms; `QueryLog(logger, 50)` makes it 50ms and a threshold of zero or less
turns the warning off. `rows` is the number of rows the caller actually read
from the cursor, or the rows affected by an `exec`.

`statementCount` is what the N+1 tests read: reading `post.author.name` for
any number of posts issues exactly two statements, and a test says so with
`q.statementCount == 2`.

## What is never logged

A record holds the statement text, the row count and the duration, and nothing
else. The text is the SQL with its placeholders (`$1`, `?`); the values travel
separately and never reach a record, and there is no switch that turns them on.
When a statement fails, one `ERROR` record carries the text and the driver's
message as two separate attributes:

```text
level=ERROR msg="statement failed" sql="insert into users (email) values ($1)" error="duplicate key value violates unique constraint \"users_email_key\""
```

The driver's message is redacted first, because a constraint violation
routinely echoes the offending value (`DETAIL:  Key (email)=(...) already
exists.`, MySQL's `Duplicate entry '...'`). The `DETAIL` section is dropped, a
single-quoted span becomes `'[redacted]'`, and a double-quoted span after a
colon becomes `"[redacted]"`. A double-quoted identifier survives, so the
constraint name stays. A driver that writes a bare value into free-form prose
cannot be told from the words around it and is logged as it is.

## Upgrading from `Logger(sink)`

`Options.logger` used to take pkg/orm's own `Logger(sink)`, writing finished
lines to a one-method `LogSink`. That type, `LogSink`, `LogOptions`,
`LogValues` and `defaultOptions()` are removed in favour of std/log's `Logger`:
pre-1.0 and a breaking change for the package, so a minor release.

- `Logger(sink)` and `Logger(sink, options)` become `QueryLog(logger)` and
  `QueryLog(logger, slowThresholdMs)`; `wrap` and `statementCount` are
  unchanged.
- `Options.logger = Logger(sink)` becomes
  `Options.logger = Option.Some(Logger(TextHandler(out)))`, where `out` has
  `write(s: string): ()!` instead of `log(line: string)`.
- `LogValues.Shown` is gone: no option logs a bound value.
- The `[sql] 4ms ... args=[redacted]` lines are `key=value` records now.
