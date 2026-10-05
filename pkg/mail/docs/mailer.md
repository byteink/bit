# The Mailer

Inkwell sends a welcome mail when someone signs up, and a mail to every
subscriber when an author publishes. Each call site should not know which
server carries the mail, which address it comes from, or how a mail is turned
into bytes. A `Mailer` is the one object that knows: you build it once when the
program starts, hand it a `Message`, and it checks the message, fills in the
defaults, and passes it to a transport that moves it.

<!-- doctest: per-block -->

## Build one, send one

```bit
import { Mailer, Message, Options, Outbox } from "mail"

fn main(): ()! {
  let box = Outbox()
  let mailer = Mailer(box, Options{ from = "Inkwell <hello@inkwell.dev>" })?
  let receipt = mailer.send(
    Message{
      to = ["Sara Ali <sara@example.com>"],
      subject = "Welcome to Inkwell",
      text = "Hello Sara. Write your first note at https://inkwell.dev/new",
    },
  )?
  println("${len(receipt.id) > 0}")
  println(receipt.accepted[0])
  return
}
```

That prints `true` and `sara@example.com`. The message names no sender, so the
mailer's `Options.from` is used. `Outbox` is the transport for tests and for
trying things out: it delivers nothing and keeps every mail. A program that
sends for real passes a network transport in its place and changes nothing
else.

`Mailer(...)` can fail, so it is written with `?` (or `catch`). It fails at
startup, which is the point; see [Setup mistakes](#setup-mistakes).

## What `Options` sets

```bit
import { Mailer, Options, Outbox } from "mail"
import { Second } from "std/time"

fn main(): ()! {
  let mailer = Mailer(
    Outbox(),
    Options{
      from = "Inkwell <hello@inkwell.dev>",
      replyTo = "Support <support@inkwell.dev>",
      timeout = 10 * Second,
    },
  )?
  mailer.close()
  return
}
```

* **`from`** is the sender for a message that sets none. Empty (the default)
  means every message must name its own.
* **`replyTo`** is the Reply-To for a message that sets none. A message's own
  `replyTo` replaces it, never adds to it.
* **`timeout`** is how long one delivery may take, in nanoseconds, so
  `10 * Second` with `Second` from `std/time`. The default is 30 seconds. A
  transport that talks to a network enforces it; `Outbox` never waits.
* **`dkim`** is the list of keys every message is signed with. Empty (the
  default) means unsigned. See [Signing your mail](dkim.md).
* **`retry`** says how a delivery the server only postponed is repeated, and
  **`rate`** how many messages a second the mailer delivers at most. See
  [Retries and pace](retry.md).
* **`redirect`** is for staging: every mail goes to that one address and to
  nobody else. See [Staging mail](redirect.md).

`Options{}` is a valid setup. More fields arrive with the parts of the package
that need them, always with a default, so code written today keeps working.

## Setup mistakes

A wrong setup is a mistake in the program, so it stops the program where it
starts and says which field:

```bit
import { Mailer, MailError, Options, Outbox } from "mail"

fn setup(o: Options): string {
  Mailer(Outbox(), o) catch e {
    match (e) {
      Config(why) => return "config: ${why}"
      _ => return "other: ${e.message()}"
    }
  }
  return "ok"
}

fn main(): ()! {
  println(setup(Options{ from = "inkwell" }))
  println(setup(Options{ timeout = 0 }))
  return
}
```

That prints the two refusals, each a `MailError.Config` naming its field:

```text
config: Options.from: invalid address "inkwell": no @ sign
config: Options.timeout must be positive, got 0
```

`e.message()` on the same error reads `mail: configuration: Options.timeout must
be positive, got 0`.

`from` and `replyTo` must parse as addresses (the same rules as
[Addresses](addresses.md)) when they are set, and `timeout` must be above zero.

## Sending and rendering

`send` renders the message and delivers it. `render` does the first half only,
returning the exact bytes `send` would hand to the transport, so a mail can be
looked at, logged or signed without being sent.

```bit
import { Mailer, Message, Options, Outbox } from "mail"
import { contains } from "std/strings"

fn main(): ()! {
  let box = Outbox()
  let mailer = Mailer(box, Options{ from = "Inkwell <hello@inkwell.dev>" })?
  let m = Message{
    to = ["Sara Ali <sara@example.com>"],
    bcc = ["audit@inkwell.dev"],
    subject = "Kim published \"Why we left Jira\"",
    text = "Read it at https://inkwell.dev/p/why-we-left-jira",
    id = "post-9-sara",
  }
  let raw = mailer.render(m)?
  println("${contains(raw, "From: \"Inkwell\" <hello@inkwell.dev>")}")
  mailer.send(m)?
  let sent = box.sent()
  println("${len(sent)}")
  println(sent[0].message.subject)
  println("${len(sent[0].receipt.accepted)}")
  println("${contains(sent[0].raw, "audit@inkwell.dev")}")
  return
}
```

That prints `true`, `1`, the subject, `2` and `false`. Setting `id` makes the
Message-ID `<post-9-sara@inkwell.dev>` the same on every render; without it
each render gets a fresh one, and a fresh `Date`, so two renders of one message
differ in those lines only.

A message the package cannot send fails with `MailError.Invalid` before the
transport is called: nothing was delivered and nothing is recorded. The reasons
are in [Messages](messages.md).

## The Outbox in a test

`Outbox.sent()` returns a `Sent` for each mail taken, oldest first: the
`message` as you wrote it, the `raw` bytes a real transport would have sent, and
the `receipt`. It is a copy; mail sent later does not change a list you already
hold. Any number of tasks can send through one `Outbox` at once.

```bit
import { Mailer, Message, Options, Outbox } from "mail"

fn publish(mailer: Mailer, subscribers: []string) {
  for to of subscribers {
    mailer.send(
      Message{
        to = [to],
        subject = "Kim published \"Why we left Jira\"",
        text = "Read it at https://inkwell.dev/p/why-we-left-jira",
      },
    ) catch e {
      println("failed for ${to}: ${e.message()}")
      continue
    }
  }
}

fn main(): ()! {
  let box = Outbox()
  let mailer = Mailer(box, Options{ from = "Inkwell <hello@inkwell.dev>" })?
  publish(mailer, ["sara@example.com", "lee@example.com", "not an address"])
  for s of box.sent() {
    println(s.receipt.accepted[0])
  }
  mailer.close()
  return
}
```

The first two subscribers get their mail; the third is refused, its failure is
printed, and the other two are unaffected. `close` releases the transport; call
it once, when no send is running.

## Your own transport

A transport is any class with `deliver`, `signs` and `close`; there is nothing to
implement or register. `deliver` gets a `Delivery` (the `message`, the
`envelope` with every address including `bcc`, the `messageId` and the final
`raw` bytes) and returns a `Receipt` or a `MailError`. It may be called from
many tasks at once. `signs` says whether the `raw` bytes are the bytes that
reach the recipient: true for a transport that sends them as they are (a
server, a file), false for one that gives a provider the fields and lets it
build the mail. A mailer with `Options.dkim` refuses a transport that answers
false, because a signature made here would not survive. See
[Signing your mail](dkim.md).

```bit
import { Delivery, Mailer, MailError, Message, Options, Receipt, Rejection, Reply } from "mail"

// Takes every address except one a policy forbids.
class Screened {
  blocked: string

  deliver(d: Delivery): Receipt!MailError {
    let ok: []string = []
    let no: []Rejection = []
    for a of d.envelope.to {
      if (a == this.blocked) {
        no = append(
          no,
          Rejection{
            address = a,
            reply = Reply{ code = 550, enhanced = "5.7.1", text = "blocked by policy" },
          },
        )
      } else {
        ok = append(ok, a)
      }
    }
    if (len(ok) == 0) {
      fail MailError.Rejected(Reply{ code = 554, text = "no valid recipients" })
    }
    return Receipt{
      id = d.messageId,
      providerId = "scr-1",
      accepted = ok,
      rejected = no,
      queued = true,
    }
  }

  signs(): bool {
    return true
  }

  close() {}
}

fn main(): ()! {
  let mailer = Mailer(
    Screened{ blocked = "lee@example.com" },
    Options{ from = "Inkwell <hello@inkwell.dev>" },
  )?
  let r = mailer.send(
    Message{
      to = ["sara@example.com", "lee@example.com"],
      subject = "Welcome to Inkwell",
      text = "Hello.",
    },
  )?
  println(r.accepted[0])
  println(r.rejected[0].reply.toString())
  println(r.providerId)
  println("${r.queued}")
  return
}
```

That prints `sara@example.com`, `550 5.7.1 blocked by policy`, `scr-1` and `true`.
A `Receipt` says which recipients took the mail (`accepted`), which did not and
why (`rejected`), the provider's own id (`providerId`, `""` when there is none)
and whether the mail was only queued for later (`queued`). `id` is the
Message-ID as written in the header.

## The errors

A send fails with a `MailError`. Match on it to decide what to do:

```bit
import { MailError, Reply } from "mail"

fn advice(e: MailError): string {
  match (e) {
    Invalid(why) => return "fix the message: ${why}"
    Config(why) => return "fix the setup: ${why}"
    Auth(r) => return "check the credentials: ${r.toString()}"
    Rejected(r) => return "do not retry: ${r.toString()}"
    Signature(why) => return "answer 401: ${why}"
    Transient(r) => return "retry later: ${r.toString()}"
    Unknown(r) => return "may have been delivered, check first: ${r.toString()}"
  }
}

fn main(): ()! {
  println(advice(MailError.Invalid("Message.subject is empty")))
  println(advice(MailError.Transient(Reply{ code = 451, enhanced = "4.7.1", text = "greylisted" })))
  return
}
```

* **`Invalid`**: the message is wrong. Sending it again fails again.
* **`Config`**: the setup is wrong; raised by `Mailer(...)`.
* **`Auth`**: the server refused the login. Nothing was sent.
* **`Rejected`**: the server refused the message or its recipients for good.
* **`Signature`**: a webhook posted to your program failed its signature
  check; see [Webhooks](webhooks.md). It is not about a send.
* **`Transient`**: the server cannot take it now. This is the only variant a
  retry is for, and `send` already retries it; see [Retries and pace](retry.md).
* **`Unknown`**: the request reached the provider and the answer never came
  back, so the mail may have been taken. A provider without an idempotency key
  (Postmark) reports a reset or a timeout after the write this way instead of
  `Transient`, and `send` does not repeat it: a retry could deliver it twice.

`Invalid`, `Config` and `Signature` carry text naming the field or the reason;
`Auth`, `Rejected`, `Transient` and `Unknown` carry the server's `Reply`: its `code`, its
`enhanced` status code (`""` when it sent none) and its `text`.

## Where to go next

The package front page is [README](../README.md). The message a mailer sends is
in [Messages](messages.md), and the addresses in it in
[Addresses](addresses.md).
