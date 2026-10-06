# Watching the mail

Inkwell sends a welcome mail to every new reader, and for a week nobody noticed
that one in five of them failed: the provider answered "not now" to a burst, the
retry loop from [Retries and pace](retry.md) absorbed most of it, and the rest
went into a log nobody read. A dashboard that shows sends by result, how long a
delivery takes and how often the mailer had to retry would have shown it on the
first day. `Options.metrics` and `Options.tracer` feed one. Both are off until
you set them, and off costs nothing: the mailer reads no clock, builds no label
and starts no span.

<!-- doctest: per-block -->

## Counting sends

Give the mailer a `Registry` from `std/metrics`. It registers four metrics on
it, once, in `Mailer(...)`:

| Metric | Type | Labels | Counts |
|---|---|---|---|
| `mail_sent_total` | counter | `transport`, `result` | every delivery attempt |
| `mail_recipients_rejected_total` | counter | `transport` | recipients a server refused while taking the others |
| `mail_retries_total` | counter | `transport` | deliveries repeated after a `Transient` failure |
| `mail_send_seconds` | histogram | `transport` | the time of one delivery attempt, in seconds, in the default buckets |

```bit
import { Mailer, Message, Options, Outbox } from "mail"
import { Registry } from "std/metrics"
import { split, contains } from "std/strings"

fn main(): ()! {
  let registry = Registry(100)
  let mailer = Mailer(
    Outbox(),
    Options{ from = "Inkwell <hello@inkwell.dev>", metrics = Option.Some(registry) },
  )?
  mailer.send(
    Message{
      to = ["Sara Ali <sara@example.com>"],
      subject = "Welcome to Inkwell",
      text = "Hello Sara. Write your first note at https://inkwell.dev/new",
    },
  )?
  for line of split(registry.exposition(), "\n") {
    if (contains(line, "mail_sent_total{")) {
      println(line)
    }
  }
  mailer.close()
  return
}
```

That prints `mail_sent_total{transport="outbox",result="ok"} 1`. Serve
`registry.exposition()` on the program's metrics route and Prometheus reads the
rest. The names follow the Prometheus conventions: a counter ends in `_total`,
a time is in seconds.

An attempt, not a send, is what is counted. A send that greylisting delays once
and the second try delivers is one `transient` and one `ok`, and one retry. That
way `mail_sent_total` adds up to the number of times a server was asked.

A `Registry` takes each name once, so two mailers in one program need a
`Registry` each; the second `Mailer(...)` fails with a `MailError.Config` that
names `Options.metrics`, at startup and not on a send.

## The labels

`transport` is the scheme of the transport that took the attempt: `smtps`,
`smtp`, `resend`, `postmark`, `sendgrid`, `mailgun`, `log`, `file` or `outbox`;
`failover` for what happens around a [second route](failover.md) and not in one
of its transports; `custom` for a transport you wrote yourself. It is never a
host, a user name, a key or an address, so the number of series stays small and
nothing private reaches a dashboard.

`result` is one word per kind of `MailError`, and two for success:

| `result` | The attempt |
|---|---|
| `ok` | was taken |
| `queued` | was taken to be sent later (`Receipt.queued`) |
| `transient` | failed with `MailError.Transient` |
| `rejected` | failed with `MailError.Rejected` |
| `auth` | failed with `MailError.Auth` |
| `unknown` | failed with `MailError.Unknown`: the mail may have been delivered |
| `invalid` | failed with `MailError.Invalid`, before any transport saw the message |
| `config` | failed with `MailError.Config` |

A message refused before a transport saw it, and a send the `Options.rate`
limit gave up on, are counted under the mailer's own scheme, `failover` when it
has a `fallback`. With `Options.fallback` every transport counts its own
attempts: when the primary is down, `mail_sent_total{transport="smtps",result="transient"}`
and `mail_sent_total{transport="resend",result="ok"}` rise together.

## One span per send

Give the mailer a `Tracer` from `std/trace` and every `send` records a
`mail.send` span with one `mail.deliver` child for each attempt, under whatever
span the calling task has open: the request that triggered the mail, say.

```bit
import { Mailer, Message, Options, Outbox } from "mail"
import { Tracer } from "std/trace"

fn main(): ()! {
  let tracer = Tracer("http://localhost:4318/v1/traces", "inkwell", 1.0)
  let mailer = Mailer(
    Outbox(),
    Options{ from = "Inkwell <hello@inkwell.dev>", tracer = Option.Some(tracer) },
  )?
  let r = mailer.send(
    Message{
      to = ["Sara Ali <sara@example.com>"],
      subject = "Welcome to Inkwell",
      text = "Hello Sara.",
      id = "welcome-1",
    },
  )?
  println(r.id)
  mailer.close()
  tracer.shutdown()
  return
}
```

A send that the server delayed once is one `mail.send` span and two
`mail.deliver` spans. The attributes:

* **`mail.transport`**: the scheme, as above.
* **`mail.message_id`**: the Message-ID without its angle brackets and its
  domain, `welcome-1` for `<welcome-1@inkwell.dev>`.
* **`mail.recipients`**: how many envelope recipients, never who.
* **`mail.result`**: the `result` word of the attempt, or of the send's last.
* **`smtp.code`**: the reply code, when the server gave one.

A failed attempt or send sets the span's status to error. No span or label holds
an address, so a trace backend never receives one.

Next: [Checking the setup at boot](verify.md).
