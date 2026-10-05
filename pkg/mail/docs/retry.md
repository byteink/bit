# Retries and pace

Inkwell mails every subscriber when an author publishes. Mail servers answer
"not now" more often than anyone expects: a greylisting server says 451 to a
sender it has not met, a provider says 429 when the burst is too big, a network
drops a connection in the middle. Written by hand, the retry is a loop at every
call site, and a loop that sleeps a fixed second brings ten thousand failed
sends back in the same second. `Options.retry` repeats them for you, spread
out; `Options.rate` keeps the whole program under the provider's limit in the
first place.

<!-- doctest: per-block -->

## What is repeated

A `send` that fails with `MailError.Transient` is tried again. That is the
server's temporary answer: a 4xx reply, or a connection that could not be made
or broke. The other five kinds return at once, because the same mail gets the
same answer: `Invalid` and `Config` are mistakes in the program, `Auth` is a
refused login, and `Rejected` is a 5xx, a refusal for good. A 550 is never sent
twice. `Unknown` is the odd one: the request was written to a provider with no
idempotency key and then cut off, so the mail may already be delivered and a
repeat could send it twice. It is for you to decide, not the retry loop; see
[Sending through Postmark](postmark.md) or [SendGrid](sendgrid.md).

The defaults retry twice (three tries in all), so `Options{}` already does the
right thing. This mailer retries harder, and waits less:

```bit
import { Delivery, Mailer, MailError, Message, Options, Receipt, Reply, Retry } from "mail"
import { Millisecond } from "std/time"

// A server that greylists the first two tries, as many do.
class Greylist {
  tries: int

  deliver(d: Delivery): Receipt!MailError {
    this.tries = this.tries + 1
    if (this.tries < 3) {
      fail MailError.Transient(
        Reply{ code = 451, enhanced = "4.7.1", text = "greylisted, try later" },
      )
    }
    return Receipt{ id = d.messageId, accepted = d.envelope.to }
  }

  signs(): bool {
    return true
  }

  close() {}
}

fn main(): ()! {
  let server = Greylist{ tries = 0 }
  let mailer = Mailer(
    server,
    Options{
      from = "Inkwell <hello@inkwell.dev>",
      retry = Retry{ attempts = 5, base = 10 * Millisecond, max = 200 * Millisecond },
    },
  )?
  let r = mailer.send(
    Message{
      to = ["Sara Ali <sara@example.com>"],
      subject = "Kim published \"Why we left Jira\"",
      text = "Read it at https://inkwell.dev/p/why-we-left-jira",
    },
  )?
  println("${r.accepted[0]} after ${server.tries} tries")
  return
}
```

That prints `sara@example.com after 3 tries`. A caller sees one `send`, one
`Receipt`, and no loop.

The tries carry the same bytes. The message is rendered and signed once, so
every try has the same `Message-ID` and the same `DKIM-Signature`; a server that
took the mail on the second try after timing out on the first sees one mail, not
two.

## How long it waits

The wait before the next try is "full jitter", from the AWS Architecture Blog
post "Exponential Backoff And Jitter": a random time between zero and a ceiling
that doubles each try, `min(max, base * 2^n)`. With `base = 1 * Second` the
ceilings are 1 s, 2 s, 4 s and so on up to `max`. The randomness is the point: a
thousand sends that failed together do not retry together.

* **`attempts`** is the number of tries in all, the first included, from 1 to
  10. `Retry{ attempts = 1 }` never retries. The default is 3.
* **`base`** is the first ceiling, in nanoseconds. It must be above zero. The
  default is 1 second.
* **`max`** is the highest any wait gets, and it must be at least `base`. The
  default is 30 seconds.

When the last try fails, `send` returns that failure, the server's own words.

## When the server says how long

Some servers tell the sender when to come back. An HTTP provider's
`Retry-After` header is one; a transport for such a provider copies it into
`Reply.retryAfter`, in nanoseconds. When that is longer than the random wait,
the mailer waits for it instead, never more than `max`. Zero means the server
asked for nothing:

```bit
import { Delivery, Mailer, MailError, Message, Options, Receipt, Reply, Retry } from "mail"
import { Millisecond } from "std/time"

// A provider that sends 429 with a Retry-After of 50 ms, once.
class Busy {
  asked: bool

  deliver(d: Delivery): Receipt!MailError {
    if (!this.asked) {
      this.asked = true
      fail MailError.Transient(
        Reply{ code = 429, text = "slow down", retryAfter = 50 * Millisecond },
      )
    }
    return Receipt{ id = d.messageId, accepted = d.envelope.to }
  }

  signs(): bool {
    return true
  }

  close() {}
}

fn main(): ()! {
  let mailer = Mailer(
    Busy{ asked = false },
    Options{
      from = "Inkwell <hello@inkwell.dev>",
      retry = Retry{ base = 1 * Millisecond, max = 100 * Millisecond },
    },
  )?
  let r = mailer.send(
    Message{ to = ["sara@example.com"], subject = "Welcome to Inkwell", text = "Hello." },
  )?
  println(r.accepted[0])
  return
}
```

The random wait here is under 1 ms, so the mailer waits the 50 ms the provider
asked for before the second try.

## Staying under the limit

Retrying is how a send recovers; `rate` is how a burst avoids the 429 at all.
`Options.rate` is the most messages a second the whole `Mailer` delivers, no
matter how many tasks send through it:

```bit
import { Mailer, Message, Options, Outbox } from "mail"
import { Second } from "std/time"

fn main(): ()! {
  let box = Outbox()
  let mailer = Mailer(
    box,
    Options{ from = "Inkwell <hello@inkwell.dev>", rate = 50, timeout = 2 * Second },
  )?
  let n = 0
  while (n < 10) {
    mailer.send(
      Message{ to = ["sara@example.com"], subject = "Issue ${n}", text = "Read it at inkwell.dev" },
    )?
    n = n + 1
  }
  println("${len(box.sent())} sent")
  return
}
```

That prints `10 sent`, after about 180 ms: 50 a second is one every 20 ms, and the first is immediate.
A send waits for its turn before every try, retries included, so a storm of
retries cannot break the limit either.

The limit is a token bucket. It refills `rate` tokens a second and holds at most
`rate`, so after a quiet spell a program may send a burst of up to `rate` at once
and then falls back to the steady pace. A new `Mailer` starts with one token:
the first send is immediate and a restarted program does not open with a burst
against the provider.

A send never waits longer than `Options.timeout` for its turn. When the line is
that long it fails with `MailError.Transient` reading `rate limit wait exceeded`
and the mail is not delivered, so a caller that sends faster than the limit for a
long time hears about it instead of piling up behind it. That failure is not
retried: the line is what is full. `0`, the default, is no limit.

## Setup mistakes

These fail in `Mailer(...)` and `open(...)` as `MailError.Config`, naming the
field, before the first mail:

* `Retry.attempts` below 1 or above 10;
* `Retry.base` zero or less;
* `Retry.max` below `Retry.base`;
* `rate` below zero or above 1000000.

```bit
import { Mailer, Options, Outbox, Retry } from "mail"

fn main(): ()! {
  Mailer(Outbox(), Options{ retry = Retry{ attempts = 0 } }) catch e {
    println(e.message())
    return
  }
  return
}
```

That prints `mail: configuration: Options.retry.attempts must be 1 to 10, got 0`.
