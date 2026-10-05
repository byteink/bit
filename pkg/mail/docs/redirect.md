# Staging mail: one address gets everything

Inkwell's staging server runs on a copy of production data. The nightly digest
job reads real subscribers and sends them real mail, from a server nobody is
supposed to be watching. One missed environment variable and a thousand
readers get a half-finished "Test digest, please ignore". Laravel's
`Mail::alwaysTo` and Symfony's envelope listener exist because every team that
shares data between environments eventually learns this the hard way.

`Options.redirect` is that safety net, in the one place every message passes
through. Set it on staging and every mail goes to one address, whatever the
message says.

<!-- doctest: per-block -->

## One option

```bit
import { Mailer, Message, Options, Outbox } from "mail"

fn main(): ()! {
  let box = Outbox()
  let mailer = Mailer(
    box,
    Options{ from = "Inkwell <hello@inkwell.dev>", redirect = "QA <qa@inkwell.dev>" },
  )?
  let r = mailer.send(
    Message{
      to = ["Sara Ali <sara@example.com>", "lee@example.com"],
      cc = ["Kim <kim@example.com>"],
      bcc = ["audit@example.com"],
      subject = "Kim published \"Why we left Jira\"",
      text = "Read it at https://inkwell.dev/p/why-we-left-jira",
    },
  )?
  println(r.accepted[0])
  println("${len(r.accepted)}")
  mailer.close()
  return
}
```

That prints `qa@inkwell.dev` and `1`. The envelope, the `RCPT TO` list the
server sees, is exactly the redirect address. Sara, Lee, Kim and the audit
mailbox are never delivered to, and `Receipt.accepted` says so. A redirect may
carry a display name; the envelope takes its bare address.

## What the tester sees

The message still looks like the real one, so the tester sees what a customer
would have seen:

* the `To:` and `Cc:` lines are as written;
* `X-Original-To` lists the addresses of those two lines, here
  `sara@example.com, lee@example.com, kim@example.com`;
* the Subject starts with `[redirected] `, so a staging mail is never mistaken
  for a real one in a mailbox.

A `Bcc` address is in none of it. A blind recipient is written into no header
in production, and staging does not change that: `X-Original-To` lists To and
Cc only, and the bytes of a redirected message hold no Bcc address anywhere.

The caller's `Message` is not changed; the redirect works on a copy.

## Signed and delivered with it

The redirect is applied before DKIM signing, so the signature covers the
`[redirected]` Subject and the `X-Original-To` line that are delivered, and a
staging mail that carries `Options.dkim` verifies like any other. `render`
returns the redirected bytes too, so a test that compares them sees what a send
would deliver.

A transport that builds the mail itself from `Delivery.message` (an HTTP
provider API) gets the redirected message: `to` is the redirect address alone,
`cc` and `bcc` are empty, and the original addresses are only in the
`X-Original-To` header:

```bit
import { Delivery, Mailer, MailError, Message, Options, Receipt } from "mail"
import { join } from "std/strings"

// What a provider's JSON body would carry.
class Api {
  deliver(d: Delivery): Receipt!MailError {
    println("to ${join(d.message.to, ", ")}, cc ${len(d.message.cc)}, bcc ${len(d.message.bcc)}")
    println(d.message.headers["X-Original-To"])
    return Receipt{ id = d.messageId, accepted = d.envelope.to }
  }

  signs(): bool {
    return false
  }

  check(): ()!MailError {}

  close() {}
}

fn main(): ()! {
  let mailer = Mailer(
    Api{},
    Options{ from = "Inkwell <hello@inkwell.dev>", redirect = "qa@inkwell.dev" },
  )?
  mailer.send(
    Message{
      to = ["sara@example.com"],
      bcc = ["audit@example.com"],
      subject = "Welcome to Inkwell",
      text = "Hello Sara.",
    },
  )?
  return
}
```

That prints `to qa@inkwell.dev, cc 0, bcc 0` and `sara@example.com`.

## Queues

The redirect is applied when the mail is sent, not when it is composed. A job
that was enqueued before the setting existed, or by a copy of the program that
had it unset, still goes to the redirect address when a staging worker sends
it. No stored message can reach an original recipient through a redirected
`Mailer`.

## Sharp edges

* An address that does not parse fails in `Mailer(...)` and `open(...)` as
  `MailError.Config` naming `Options.redirect`, before the first mail:

```bit
import { Mailer, Options, Outbox } from "mail"

fn main(): ()! {
  Mailer(Outbox(), Options{ redirect = "qa at inkwell" }) catch e {
    println(e.message())
    return
  }
  return
}
```

That prints a line that starts `mail: configuration: Options.redirect: invalid
address` and ends with the reason the address was refused.

* A message is checked as it would be without a redirect: an empty Subject is
  refused before the prefix can hide it, and a bad `to[1]` fails as it does in
  production.
* The header `X-Original-To` is the redirect's own. A message that sets it in
  `Message.headers` is refused as a header set twice, rather than overwritten.
* A message with only a Bcc has nothing visible to list, so it carries no
  `X-Original-To`; it is still delivered to the redirect alone.

## When not to use it

Do not use it in production, and do not use it as the way a test reads what
was sent: `Outbox` records mail without delivering it and needs no redirect.
`redirect` is for an environment that runs a real transport against data that
names real people.

Next: [The Mailer](mailer.md) for `Options`, [Signing your mail](dkim.md) for
the signature that covers the redirected bytes.
