# Watching the queue

<!-- doctest: deps postgres -->

Inkwell's welcome email job has been failing for an hour: the provider rejects
one address in twenty, the retries absorb most of it, and the rest ended up in
the dead-letter list where nobody looked. A queue that runs unattended has to
say what it is doing, in a form a log pipeline can filter: which job, which
attempt, how long it took, why it failed. `Options.logger` takes a `Logger`
from `std/log` and the queue writes one record for each of those events. The
handler you built decides whether a record is text or JSON and where it goes,
the same as everywhere else in the program.

## Give the queue a logger

```bit
import { pool, Datasource } from "std/sql"
import { adapter } from "postgres"
import { SqlStore, PermanentFailure, migrate, open, Options } from "jobs"
import { Logger, JsonHandler, LevelInfo } from "std/log"
import { stdout } from "std/io"

@job("send-welcome") @json class SendWelcome {
  email: string,
}

fn main(): ()! {
  let db = pool(adapter(), Datasource{ uri = "postgres://localhost/inkwell" })?
  migrate(db)?
  let logger = Logger(JsonHandler(stdout(), LevelInfo, false))
  let q = open(SqlStore(db)?, Options{ workers = 4, logger = Option.Some(logger) })?
  q.register<SendWelcome>((job: SendWelcome) => {
    if (job.email == "") {
      fail PermanentFailure{ reason = "the welcome mail has no address" }
    }
  })?
  q.enqueue(SendWelcome{ email = "sara@example.com" })?
  q.run()?
  return
}
```

A job that runs cleanly writes two lines, with `took` in nanoseconds:

```text
{"level":"INFO","msg":"job started","job":"send-welcome","attempt":1}
{"level":"INFO","msg":"job done","job":"send-welcome","attempt":1,"took":3250000}
```

`job` is the `@job` name and `attempt` counts from 1, so a job on its third try
says `attempt=3`.

## The records

| Level | `msg` | Written when | Other attributes |
|---|---|---|---|
| `INFO` | `job started` | a worker took the job and runs its handler | |
| `INFO` | `job done` | the handler returned | `took` |
| `WARN` | `job retry` | the handler failed and the job has attempts left | `error` |
| `ERROR` | `job failed permanently` | the job is dead-lettered: attempts used up, a `PermanentFailure`, or no handler registered | `error` |
| `ERROR` | `job claim failed` | the store could not hand out a job; the worker waits a poll interval | `error` |
| `ERROR` | `job acknowledge failed` | the store could not record the outcome; the job comes back when its visibility timeout lapses | `job`, `error` |

The scheduler writes its own, one per event that [Scheduled jobs](cron.md)
describes: `cron tick dropped` (WARN: the `job`, the `schedule`, the `policy`,
how many ticks were `missed`, how many `enqueued`, and the window `from` and
`to`), `cron clock moved back`, `cron last tick ignored` and `cron clock skewed
from the database, not firing ticks` (WARN), `cron clock agrees with the
database again, firing ticks` (INFO), and `cron cannot read the database
clock, not firing ticks` and `cron schedule failed` (ERROR).

A job whose handler fails twice and then succeeds writes `job retry` twice and
`job done` once, each with the attempt it belongs to:

```text
level=WARN msg="job retry" job=send-welcome attempt=1 error="smtp: 451 try later"
level=WARN msg="job retry" job=send-welcome attempt=2 error="smtp: 451 try later"
level=INFO msg="job done" job=send-welcome attempt=3 took=41ms
```

## What an unset logger does

Leave `Options.logger` out and the two per-job `INFO` lines, `job started` and
`job done`, write nothing and read no clock for a line: a queue that runs a
thousand jobs a second would otherwise write two thousand lines a second nobody
asked for. Everything else is an operational event that a person has to see, so
it goes to std/log's process default, `getDefault()`, which writes text on
stderr at `INFO`: a failing job, a dropped cron tick, a clock that disagrees
with the database. A queue nobody configured still says when it is losing work.
Replace the process default once, at startup, with `setDefault`, and an unset
queue follows it.

Set a logger whose level is `LevelError` and the queue writes only the
`ERROR` records; a level a logger has off costs nothing, since std/log hands
back one shared record that keeps no attributes.

## What is never logged

No record holds a job's payload. A payload is whatever you enqueued: an
address, a token, a customer's name. A record names the job and the attempt and
nothing of what is in it. The one text a record copies from your code is the
`error`: the message of the error a handler failed with, or the text of a panic
it hit. Write that message for a log, `the provider refused the address` and
not `refused sara@example.com`, because it is also what the dead-letter list
keeps as the reason.

## Upgrading

Before `Options.logger`, the queue wrote its few notes with `eprint`, as
`jobs: ...` sentences. Those are records now, with the same facts as attributes
(`jobs: schedule 'x' missed 3 tick(s) from A to B; Missed.Skip enqueued 0` is
`msg="cron tick dropped"` with `schedule`, `missed`, `enqueued`, `from` and
`to`), and a failing or retried job, which wrote nothing before, writes one.
That is a change to what lands on stderr, so a minor release. A program that
parsed the old sentences reads the records instead.
