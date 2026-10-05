# Sending through SendGrid

Inkwell's receipts and its weekly digest go out through SendGrid, which takes
mail over HTTPS and bills by volume. You still want the same `Mailer`: the same
`Message`, the same `Options`, the same `MailError` to match on. `open` builds
one from a `sendgrid://` URL, the way it builds one from `smtps://`,
`resend://` or `postmark://`.

<!-- doctest: per-block -->

## One URL, one mailer

The API key goes where an SMTP password would, in the URL:

```bit
import { Message, Options, open } from "mail"
import { envOr } from "std/os"

fn main(): ()! {
  let url = envOr("MAIL_URL", "sendgrid://SG.key-123@default")
  let mailer = open(url, Options{ from = "Inkwell <hello@inkwell.dev>" })?
  let receipt = mailer.send(
    Message{
      to = ["Sara Ali <sara@example.com>"],
      subject = "Your Inkwell receipt",
      text = "Thanks for your order.",
    },
  )?
  println(receipt.providerId)
  mailer.close()
  return
}
```

`default` stands for `api.sendgrid.com`. Each `send` is one `POST /v3/mail/send`
with the key as a Bearer token. SendGrid answers `202 Accepted` and names the mail
in the `X-Message-Id` header; `Receipt.providerId` is that id. A 202 means
SendGrid queued the mail, not that it was delivered. Nothing is connected at
`open`; the first `send` is the first request. The `From` address must be a
verified sender or domain in SendGrid, or it answers 403.

## The EU host

An account that sends from an EU regional subuser uses SendGrid's EU host.
`@eu` names it, so the URL says which region it is:

```bit
import { Message, Options, open } from "mail"

fn main(): ()! {
  let mailer = open("sendgrid://SG.key-123@eu", Options{ from = "hello@inkwell.dev" })?
  mailer.send(Message{ to = ["sara@example.com"], subject = "Hi", text = "Welcome" })?
  mailer.close()
  return
}
```

`@eu` is `api.eu.sendgrid.com` and takes no port. Like `default`, it is always
verified: `insecureSkipVerify=true` is refused with it.

## The same Message, field for field

Everything a `Message` holds that SendGrid can carry is sent. A `Message` is one
`personalization`: one mail with the recipients it lists, never one mail per
address.

| `Message` | SendGrid |
|---|---|
| `from` (or `Options.from`) | `from`: `email` and `name` |
| `to`, `cc`, `bcc` | `personalizations[0].to`, `cc`, `bcc`, each a list of `email` and `name` |
| `replyTo` (or `Options.replyTo`) | `reply_to_list` |
| `subject` | `subject` |
| `text`, `html` | `content`: `text/plain` first, then `text/html` |
| `attachments` | `attachments`: base64 `content`, `type`, `filename`, and `disposition` `inline` with `content_id` for one with a `cid`, `attachment` for the rest |
| `headers`, `inReplyTo`, `references` | `headers`, with `In-Reply-To`, `References` and `Auto-Submitted` as the SMTP transport writes them |
| `tags["category"]` | `categories`, split on commas |
| every other `tags` entry | `personalizations[0].custom_args` |

A message with only `html` still gets its plain text part, made the same way as
for SMTP. A `bcc` address is a field of the request and in no header SendGrid
writes, as ever.

`Message.tags` has any number of names; SendGrid has `categories`, which are names
only, and `custom_args`, which carry a value and come back on every event
webhook. The tag named `category` holds the categories, separated by commas; the
rest are `custom_args`. A receipt for user 7 on the pro plan is
`tags = { "category": "receipt, billing", "user": "7", "plan": "pro" }`.

SendGrid builds the mail itself, so a few things differ from SMTP and are refused
before any request goes out, as `MailError.Invalid`:

* No `to` recipient. SendGrid needs one; `cc` and `bcc` alone are not enough.
* More than 1000 recipients across `to`, `cc` and `bcc`. Send the rest in a
  second message.
* More than 10 categories, an empty one, one over 255 characters, or one given
  twice.
* `custom_args` over 10000 bytes of names and values together.
* A header SendGrid does not let a request set: `Received`, `DKIM-Signature`,
  `X-SG-ID`, `X-SG-EID`.
* `Message.invite`. SendGrid has no calendar alternative; send invites over SMTP.

`Options.dkim` is refused when you call `open` with a `sendgrid://` URL: SendGrid
signs with the key of the domain you authenticated in its dashboard, and a
signature made here would not be the one that counts.

## What SendGrid answers

| SendGrid says | You get |
|---|---|
| 202 | a `Receipt` with the `providerId` |
| 401, 403 | `Auth` |
| 403 about the `from` field | `Rejected`: the sender is not verified, which is not a bad key |
| 429 | `Transient`, with `Reply.retryAfter` from `X-RateLimit-Reset` |
| 5xx | `Transient` |
| 400, 413 and any other 4xx | `Rejected`, with SendGrid's `errors[].message` texts joined by `; ` |
| no answer, the request never left (refused, connect failed) | `Transient`, naming the step |
| no answer, after the request was written (reset, timed out) | `Unknown`: it may have been taken, so it is not retried |
| a certificate that does not verify | `Rejected`: the same certificate comes back on every try |

SendGrid sends no `Retry-After`. It sends `X-RateLimit-Reset`, the epoch second
its limit refreshes at, and `Reply.retryAfter` is the time from now to then, so
`Options.retry` waits until the limit is back. A reset in the past, or more
than a day away, is no hint.

```bit
import { MailError, Message, Options, open } from "mail"
import { Second } from "std/time"

fn main(): ()! {
  let mailer = open("sendgrid://SG.key-123@default", Options{ from = "hello@inkwell.dev" })?
  mailer.send(Message{ to = ["sara@example.com"], subject = "Hi", text = "Welcome" }) catch e {
    match (e) {
      Auth(r) => println("check the API key and its permissions: ${r.toString()}")
      Transient(r) => println("busy, try again in ${r.retryAfter / Second} s: ${r.text}")
      Rejected(r) => println("SendGrid refused it: ${r.toString()}")
      _ => println(e.message())
    }
  }
  mailer.close()
  return
}
```

The key is never in an error or a `Receipt`: a text that SendGrid echoes it
into shows `***`.

## A send that may happen twice

SendGrid has no idempotency key, so a repeat of a request it already took is a
second mail. `Options.retry` therefore repeats a send only when SendGrid cannot
have taken it: a refused connection or a failed connect (the request never
left), a 429, a 5xx.

A request that was written and then cut off, by a reset or a timeout while
waiting for the answer, may have been taken. Repeating it on its own would send
the mail twice (RFC 9110 section 9.2.2), so it fails with `MailError.Unknown`
and is not retried. The text names the failure:

```bit
import { MailError, Message, Options, open } from "mail"

fn main(): ()! {
  let mailer = open("sendgrid://SG.key-123@default", Options{ from = "hello@inkwell.dev" })?
  mailer.send(Message{ to = ["sara@example.com"], subject = "Your receipt", text = "Thanks" }) catch e {
    match (e) {
      Unknown(r) => println("may have been delivered, check SendGrid's activity first: ${r.text}")
      _ => println(e.message())
    }
  }
  mailer.close()
  return
}
```

A receipt or a one-time code is usually sent again anyway once the user asks, so
`Unknown` there means "show the retry button". For a mail that must arrive
exactly once, look the recipient up in SendGrid's Email Activity before sending
again.

See [Retries and pace](retry.md) for what is repeated and how long it waits.

## A proxy, or a stand-in for tests

Any host other than `default` and `eu` is used as the API address over HTTPS:
`sendgrid://SG.key-123@mail-proxy.internal:8443`. Its certificate is checked like
SendGrid's own. `?insecureSkipVerify=true` turns that off, and `open` only
allows it with such a host, so SendGrid's real hosts are never left unverified.
Use it with a fake server in a test; for staging, prefer
[`Options.redirect`](redirect.md), which keeps the real host and changes the
recipient.

## Every mistake fails at `open`

Each of these is a `MailError.Config` that names the problem and never repeats
the key: no key, an empty key, a key that is not printable ASCII, a password
after the key, no host, `default` or `eu` with a port, a bad port, a path, any
query parameter but `insecureSkipVerify`, and `insecureSkipVerify=true` with
`default` or `eu`.

## Where to go next

[Retries and pace](retry.md) has the options used above, [Sending through
Postmark](postmark.md) is the same idea for a provider with message streams, and
[Sending through Resend](resend.md) for one that has an idempotency key.
