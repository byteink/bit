# Sending through Mailgun

Inkwell's publish mail goes out through Mailgun from `mg.inkwell.dev`, and it is
signed with Inkwell's own DKIM key. Mailgun takes mail over HTTPS, and you still
want the same `Mailer`: the same `Message`, the same `Options`, the same
`MailError` to match on. `open` builds one from a `mailgun://` URL, the way it
builds one from `smtps://`, `resend://`, `postmark://` or `sendgrid://`.

<!-- doctest: per-block -->

## One URL, one mailer

Mailgun's API key goes where an SMTP password would, and the sending domain
follows it after a colon:

```bit
import { Message, Options, open } from "mail"
import { envOr } from "std/os"

fn main(): ()! {
  let url = envOr("MAIL_URL", "mailgun://key-123abc:mg.inkwell.dev@default")
  let mailer = open(url, Options{ from = "Inkwell <hello@inkwell.dev>" })?
  let receipt = mailer.send(
    Message{
      to = ["Sara Ali <sara@example.com>"],
      subject = "Kim published \"Why we left Jira\"",
      text = "Read it at https://inkwell.dev/p/why-we-left-jira",
    },
  )?
  println(receipt.providerId)
  mailer.close()
  return
}
```

`default` stands for `api.mailgun.net`. Each `send` is one
`POST /v3/mg.inkwell.dev/messages.mime`, authenticated with HTTP basic auth as
user `api` and the key as the password. Mailgun answers `200` with an `id`;
`Receipt.providerId` is that id without the angle brackets Mailgun writes round
it. A 200 means Mailgun queued the mail, not that it was delivered. Nothing is
connected at `open`; the first `send` is the first request.

The domain is the one the Mailgun account sends from, a DNS name with a dot in
it. It is checked at `open`, because it becomes part of the request path.

## The EU region

A domain created in Mailgun's EU region is served from another host. `@eu` names
it, so the URL says which region it is:

```bit
import { Message, Options, open } from "mail"

fn main(): ()! {
  let mailer = open(
    "mailgun://key-123abc:mg.inkwell.dev@eu",
    Options{ from = "hello@inkwell.dev" },
  )?
  mailer.send(Message{ to = ["sara@example.com"], subject = "Hi", text = "Welcome" })?
  mailer.close()
  return
}
```

`@eu` is `api.eu.mailgun.net` and takes no port. Like `default`, it is always
verified: `insecureSkipVerify=true` is refused with it. A domain in one region is
not found in the other, so a wrong choice is a `Rejected` 404 from Mailgun, not a
bad key.

## The message is sent as it was rendered

Mailgun has two ways in: the fields of a mail, which it builds into a message
itself, and a finished message, `messages.mime`. This transport uses the second.
The request is `multipart/form-data` with:

| Field | Holds |
|---|---|
| `to`, once per recipient | every envelope recipient: `to`, `cc` and `bcc` |
| `o:tag`, once per tag | the tags in `Message.tags["tag"]` |
| `v:<name>` | every other entry of `Message.tags` |
| `message`, a file | the message exactly as `Mailer.render` makes it |

Because the message is the finished one, nothing is rebuilt at Mailgun. Every
`Message` field SMTP carries, an attachment, an inline image and an invite
included, arrives as it would over SMTP, and `Options.dkim` is accepted: the
signature is made over the bytes Mailgun is given. A `bcc` address is a `to`
field of the request and is in no header of the message, as ever.

Mailgun still applies the DKIM setting of the sending domain, which is a setting
in its dashboard and not something this package changes.

`Message.tags` has any number of names; Mailgun has `o:tag`, which are names
only, and `v:` variables, which carry a value and come back in its events and
webhooks. The tag named `tag` holds the tags, separated by commas, and the rest
are variables. A receipt for user 7 on the pro plan is
`tags = { "tag": "receipt, billing", "user": "7", "plan": "pro" }`.

A few things Mailgun would refuse are refused first, before any request, as
`MailError.Invalid`:

* More than 1000 recipients across `to`, `cc` and `bcc`. Send the rest in a
  second message.
* More than 3 tags, an empty one, one over 128 characters, one that is not
  printable ASCII, or one given twice in any case.
* A variable name that is not 1 to 64 of letters, digits, `_`, `.` and `-`.
* Tags that together, names and values, are over the 16384 bytes Mailgun reads
  from the `o:` and `v:` fields.

## Signing your own mail

The mailer in the first example sends unsigned mail and leaves signing to
Mailgun. To sign with Inkwell's key, give `Options.dkim` as for any other
transport:

```bit
import { Dkim, Message, Options, open } from "mail"
import { readFile } from "std/fs"

fn main(): ()! {
  let rsa = Dkim{
    domain = "inkwell.dev",
    selector = "2026a",
    key = readFile("/run/secrets/inkwell-dkim-rsa.pem")?,
  }
  let mailer = open(
    "mailgun://key-123abc:mg.inkwell.dev@default",
    Options{ from = "Inkwell <hello@inkwell.dev>", dkim = [rsa] },
  )?
  mailer.send(Message{ to = ["sara@example.com"], subject = "Hi", text = "Welcome" })?
  mailer.close()
  return
}
```

`d=` must align with the domain of the From address, as everywhere; see
[Signing your mail](dkim.md). This is the difference from `resend://`,
`postmark://` and `sendgrid://`, which build the message themselves and refuse
`Options.dkim`.

## What Mailgun answers

| Mailgun says | You get |
|---|---|
| 200 | a `Receipt` with the `providerId` |
| 401 | `Auth` |
| 429 | `Transient`, with `Reply.retryAfter` from `Retry-After` when it sends one |
| 5xx | `Transient` |
| 400, 404 and any other 4xx | `Rejected`, with Mailgun's `message` |
| no answer, the request never left (refused, connect failed) | `Transient`, naming the step |
| no answer, after the request was written (reset, timed out) | `Unknown`: it may have been taken, so it is not retried |
| a certificate that does not verify | `Rejected`: the same certificate comes back on every try |

```bit
import { MailError, Message, Options, open } from "mail"
import { Second } from "std/time"

fn main(): ()! {
  let mailer = open(
    "mailgun://key-123abc:mg.inkwell.dev@default",
    Options{ from = "hello@inkwell.dev" },
  )?
  mailer.send(Message{ to = ["sara@example.com"], subject = "Hi", text = "Welcome" }) catch e {
    match (e) {
      Auth(r) => println("check the API key: ${r.toString()}")
      Transient(r) => println("busy, try again in ${r.retryAfter / Second} s: ${r.text}")
      Rejected(r) => println("Mailgun refused it: ${r.toString()}")
      _ => println(e.message())
    }
  }
  mailer.close()
  return
}
```

The key is never in an error or a `Receipt`: a text that Mailgun echoes it into
shows `***`.

## A send that may happen twice

Mailgun has no idempotency key, so a repeat of a request it already took is a
second mail. `Options.retry` therefore repeats a send only when Mailgun cannot
have taken it: a refused connection or a failed connect (the request never
left), a 429, a 5xx.

A request that was written and then cut off, by a reset or a timeout while
waiting for the answer, may have been taken. Repeating it on its own would send
the mail twice (RFC 9110 section 9.2.2), so it fails with `MailError.Unknown` and
is not retried. A receipt or a one-time code is usually sent again anyway once
the user asks, so `Unknown` there means "show the retry button". For a mail that
must arrive exactly once, look the recipient up in Mailgun's logs before sending
again. See [Retries and pace](retry.md) for what is repeated and how long it
waits.

## A proxy, or a stand-in for tests

Any host other than `default` and `eu` is used as the API address over HTTPS:
`mailgun://key-123abc:mg.inkwell.dev@mail-proxy.internal:8443`. Its certificate is
checked like Mailgun's own. `?insecureSkipVerify=true` turns that off, and `open`
only allows it with such a host, so Mailgun's real hosts are never left
unverified. Use it with a fake server in a test; for staging, prefer
[`Options.redirect`](redirect.md), which keeps the real host and changes the
recipient.

## Every mistake fails at `open`

Each of these is a `MailError.Config` that names the problem and never repeats
the key: no key, an empty key, a key that is not printable ASCII, no domain, a
domain that is not a DNS name with a dot, no host, `default` or `eu` with a port,
a bad port, a path, any query parameter but `insecureSkipVerify`, and
`insecureSkipVerify=true` with `default` or `eu`.

## Where to go next

[Signing your mail](dkim.md) has the keys used above, [Retries and pace](retry.md)
the options, and [Sending through SendGrid](sendgrid.md) is the same idea for a
provider that builds the message itself.
