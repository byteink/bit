# Sending in the background

Inkwell sends a welcome mail from the sign-up handler. Done inline, the new
reader waits for the mail provider before the page loads, a provider outage
turns into a failed sign-up, and a deploy in the middle of a send loses the
mail without a trace. What the handler wants to do is write down "send this
mail", answer the reader, and let something else worry about delivery, retrying
it when the provider hiccups and keeping the ones that can never work where a
person will see them. That is a job queue, and [pkg/jobs](../../jobs/README.md)
is one. `Options.queue` plugs a `Mailer` into it.

<!-- doctest: per-block -->
<!-- doctest: deps postgres -->

## Send now, deliver later

Give the `Mailer` a `Queue` from `pkg/jobs`. The sign-up handler does not
change: it still calls `send`.

```bit
import { Message, Options, open as openMailer } from "mail"
import { pool, Datasource } from "std/sql"
import { adapter } from "postgres"
import { PostgresStore, open as openQueue, Options as QueueOptions } from "jobs"

fn main(): ()! {
  let db = pool(adapter(), Datasource{ uri = "postgres://localhost/inkwell" })?
  let queue = openQueue(PostgresStore(db), QueueOptions{ workers = 4 })?
  let mailer = openMailer(
    "smtps://hello%40inkwell.dev:secret@smtp.inkwell.dev",
    Options{ from = "Inkwell <hello@inkwell.dev>", queue = Option.Some(queue) },
  )?
  let receipt = mailer.send(
    Message{
      to = ["Sara Ali <sara@example.com>"],
      subject = "Welcome to Inkwell",
      text = "Hello Sara. Write your first note at https://inkwell.dev/new",
    },
  )?
  println("${receipt.queued} ${len(receipt.id) > 0}")
  return
}
```

That prints `true true`. `send` checked the message, rendered it, signed it
with `Options.dkim` if there is any, and wrote the finished mail to the queue's
store. It did not touch the SMTP server: the `Receipt` has `queued` set, `id`
is the `Message-ID` the mail will go out with, and `accepted` is empty, because
nobody has accepted it yet.

Nothing is delivered until a worker runs the queue. The worker is a program
that builds the same `Mailer` over the same store and calls `run`:

```bit
import { Options, open as openMailer } from "mail"
import { pool, Datasource } from "std/sql"
import { adapter } from "postgres"
import { PostgresStore, open as openQueue, Options as QueueOptions } from "jobs"

fn main(): ()! {
  let db = pool(adapter(), Datasource{ uri = "postgres://localhost/inkwell" })?
  let queue = openQueue(PostgresStore(db), QueueOptions{ workers = 4 })?
  let mailer = openMailer(
    "smtps://hello%40inkwell.dev:secret@smtp.inkwell.dev",
    Options{ from = "Inkwell <hello@inkwell.dev>", queue = Option.Some(queue) },
  )?
  queue.run()?
  mailer.close()
  return
}
```

`Mailer(...)` teaches the queue to deliver a queued mail through that mailer's
own transport, so a worker needs no handler of its own. The web process may run
the workers too (`queue.start()`), or only enqueue and leave delivery to a
separate worker process; both build the `Mailer` the same way.

## What fails where

A mistake in the message is still the caller's. `send` renders before it
enqueues, so a mail with no recipient, a bad address or a From that aligns with
no DKIM key fails with `MailError.Invalid` in the handler that wrote it, and
nothing is queued. A queue that cannot take the mail (the database is down)
fails `Transient`, and `send` can be tried again: nothing was queued.

The delivery is the worker's, and each way it can fail has its own outcome:

| The transport reports | What pkg/jobs does |
|---|---|
| `Transient`: a 4xx, a connection that could not be made | retries with its backoff, up to `Options.retry.attempts` deliveries in all |
| `Rejected`, `Auth` | dead-letters the job at once, with the server's reply as the reason |
| `Invalid`, `Config` | dead-letters the job at once |
| `Unknown`: the mail may already be delivered | dead-letters the job at once, never retried |

`Unknown` is the one to read the reason of. A transport with no idempotency key
sent the request and lost the answer; sending it again can deliver it twice, so
the queue does not, and the dead-letter list holds the reason (`mail: outcome
unknown, may have been delivered: ...`) for a person to check the provider's
log. The jobs docs show [how a handler fails for good](../../jobs/docs/getting-started.md);
the mailer does exactly that with `PermanentFailure`.

Every attempt carries the same bytes. The mail was rendered and signed once,
before it was queued, so the `Message-ID` and the `DKIM-Signature` are the
same on the first try and the fifth, and a provider that takes the mail on a
retry after timing out on the first try sees one mail. An API transport sends
the same `Idempotency-Key` on every try, for the key comes from `Message.id`
or the `Message-ID`, and both are stored with the mail.

## Retries are pkg/jobs'

With a queue, the mailer does not repeat a delivery itself. `Options.retry`
means one thing: `attempts` is how many deliveries the job is tried for, the
first included, and pkg/jobs waits between them (full jitter, up to five
minutes). `base` and `max` would be ignored, so a `Mailer` that sets them with
a queue fails at startup:

```bit
import { Retry, Options, Mailer, Outbox } from "mail"
import { PostgresStore, open as openQueue, Options as QueueOptions } from "jobs"
import { pool, Datasource } from "std/sql"
import { adapter } from "postgres"

fn main(): ()! {
  let db = pool(adapter(), Datasource{ uri = "postgres://localhost/inkwell" })?
  let queue = openQueue(PostgresStore(db), QueueOptions{ workers = 1 })?
  Mailer(
    Outbox(),
    Options{ queue = Option.Some(queue), retry = Retry{ attempts = 5, max = 5000000000 } },
  ) catch e {
    println(e.message())
    return
  }
  return
}
```

That prints `mail: configuration: Options.retry.base and Options.retry.max do
not apply with Options.queue: pkg/jobs backs off between attempts; set
Options.retry.attempts alone`. `Options.rate` still applies: a worker waits for
its token before every delivery, so a queue cannot push the provider past its
limit either.

## Watching it

With `Options.metrics` or `Options.tracer` a queued send counts once as
`result="queued"` in `mail_sent_total` when it is enqueued, and its
`mail.send` span ends there. The worker's deliveries are counted as they
happen, each attempt under its own result (`ok`, `transient`, `rejected`...),
with a `mail.deliver` span for each. `mail_retries_total` counts the retries
the mailer makes itself, so it stays at zero with a queue; the attempts that
pkg/jobs repeats show as extra `transient` counts. See
[Watching the mail](observe.md).

## Sharp edges

* **The mail sits in the store.** The queue's table holds the whole rendered
  mail, attachments and all, until it is delivered. A `Message` with a 20 MiB
  attachment is a 27 MiB row. Keep the store as private as the mail.
* **A transport that builds the mail itself** (Resend, Postmark and SendGrid
  take fields, not bytes) also needs the `Message`, so the row carries it a
  second time, attachments as base64 text. SMTP and Mailgun's `messages.mime`
  send the bytes as they are and store them once.
* **One `Mailer` per queue.** The queue holds one handler for mail, so a second
  `Mailer` on the same `Queue` replaces the first one's transport. Two
  transports are one `Mailer` with `Options.fallback`.
* **The queue is yours to close.** `Mailer.close` releases the transport and
  leaves the queue running.
* **`Mailer.verify` still checks the transport**, queue or not; call it in the
  worker's boot.

## When not to queue

When the mail is the answer. A password reset page that says "check your
inbox" is a promise that the mail left; if the reader should hear "we could not
send it" right now, send inline and take the failure in the handler. Everything
else, a welcome, a receipt, a digest, a notification, belongs on the queue.

Next: [Retries and pace](retry.md) for what inline sends do, and
[the jobs docs](../../jobs/docs/getting-started.md) for the worker side.
