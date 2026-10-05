# Sending through Resend

Inkwell's welcome mail goes out through Resend, which takes mail over HTTPS and
not over SMTP. You still want the same `Mailer`: the same `Message`, the same
`Options`, the same `MailError` to match on. `open` builds one from a
`resend://` URL, the way it builds one from `smtps://`.

<!-- doctest: per-block -->

## One URL, one mailer

The API key goes where an SMTP password would, in the URL:

```bit
import { Message, Options, open } from "mail"
import { envOr } from "std/os"

fn main(): ()! {
  let url = envOr("MAIL_URL", "resend://re_123456789@default")
  let mailer = open(url, Options{ from = "Inkwell <hello@inkwell.dev>" })?
  let receipt = mailer.send(
    Message{
      to = ["Sara Ali <sara@example.com>"],
      subject = "Welcome to Inkwell",
      text = "Hello Sara. Write your first note at https://inkwell.dev/new",
      id = "welcome-7",
    },
  )?
  println(receipt.providerId)
  mailer.close()
  return
}
```

`default` stands for `api.resend.com`. Each `send` is one `POST /emails` with
the key as a Bearer token, and `Receipt.providerId` is the id Resend gives the
mail, the same one its webhooks name (see [Webhooks](webhooks.md)). Nothing is
connected at `open`; the first `send` is the first request.

## The same Message, field for field

Everything a `Message` holds that Resend can carry is sent:

| `Message` | Resend |
|---|---|
| `from` (or `Options.from`) | `from` |
| `to`, `cc`, `bcc` | `to`, `cc`, `bcc` |
| `replyTo` (or `Options.replyTo`) | `reply_to` |
| `subject`, `text`, `html` | `subject`, `text`, `html` |
| `attachments` | `attachments`: `filename`, base64 `content`, `content_type`, and `content_id` for one with a `cid` |
| `headers`, `inReplyTo`, `references` | `headers`, with `In-Reply-To`, `References` and `Auto-Submitted` as the SMTP transport writes them |
| `tags` | `tags`, a `name` and a `value` each |

A message with only `html` still gets its plain text part, made the same way as
for SMTP. A `bcc` address is a field of the request and in no header Resend
writes, as ever.

Resend builds the mail itself, so a few things differ from SMTP and are refused
before any request goes out, as `MailError.Invalid`:

* More than 50 recipients across `to`, `cc` and `bcc`. Send the rest in a
  second message.
* A tag whose name or value has anything but letters, digits, `_` and `-`
  (Resend's rule). A user id like `7` is fine, an address is not.
* `Message.invite`. Resend has no calendar alternative; send invites over SMTP.

`Options.dkim` is refused when you call `open` with a `resend://` URL: Resend
signs with the key of the domain you verified in its dashboard, and a signature
made here would not be the one that counts.

## A send that happens once

A mail must not go out twice because a request timed out and was repeated. Every
request carries an `Idempotency-Key`: `Message.id` when you set it
(`welcome-7` above), else the unique part of the Message-ID. The `Mailer`
repeats a retry with the same key, and Resend keeps a key for 24 hours, so a
send whose answer was lost is a duplicate only if the first one really failed.
The key must be at most 256 bytes.

## What Resend answers

| Resend says | You get |
|---|---|
| 200 | a `Receipt` with the `providerId` |
| 429 and 5xx | `Transient`, with `Reply.retryAfter` from `Retry-After` |
| 401, or 403 about the key | `Auth` |
| 403 `validation_error` (an unverified domain) | `Rejected` |
| 409 while the same key is in flight | `Transient` |
| 409 for a key used with another body | `Invalid` |
| any other 4xx | `Rejected`, with Resend's own `message` |
| no answer at all (refused, reset, timed out) | `Transient`, naming the step |
| a certificate that does not verify | `Rejected`: the same certificate comes back on every try |

`Options.retry` repeats the `Transient` ones and honours `Retry-After` when it
is longer than its own wait (see [Retries and pace](retry.md)). Resend's default
limit is 10 requests a second, so `Options.rate = 10` keeps the program under it
instead of leaning on 429. The key is never in an error or a `Receipt`: a text
that Resend echoes it into shows `***`.

```bit
import { Message, Options, Retry, open } from "mail"
import { Second } from "std/time"

fn main(): ()! {
  let mailer = open(
    "resend://re_123456789@default",
    Options{
      from = "Inkwell <hello@inkwell.dev>",
      rate = 10,
      retry = Retry{ attempts = 5 },
      timeout = 20 * Second,
    },
  )?
  mailer.send(
    Message{ to = ["sara@example.com"], subject = "Your digest", text = "This week on Inkwell" },
  ) catch e {
    match (e) {
      Auth(r) => println("check the Resend key: ${r.toString()}")
      Rejected(r) => println("Resend refused it: ${r.text}")
      Transient(r) => println("still failing after the retries: ${r.toString()}")
      _ => println(e.message())
    }
  }
  mailer.close()
  return
}
```

## A proxy, or a stand-in for tests

Any host other than `default` is used as the API address over HTTPS:
`resend://re_123456789@mail-proxy.internal:8443`. Its certificate is checked
like Resend's own. `?insecureSkipVerify=true` turns that off, and `open` only
allows it with such a host, so the real `api.resend.com` is never left
unverified. Use it with a fake server in a test; for staging, prefer
[`Options.redirect`](redirect.md), which keeps the real host and changes the
recipient.

## Every mistake fails at `open`

Each of these is a `MailError.Config` that names the problem and never repeats
the key: no key, an empty key, a key that is not printable ASCII, a password
after the key (`re_x:pw@`), no host, `default` with a port, a bad port, a path,
any query parameter but `insecureSkipVerify`, and `insecureSkipVerify=true` with
`default`.

## Where to go next

[Webhooks](webhooks.md) reads what Resend posts back about each mail, and
[Retries and pace](retry.md) has the options used above.
