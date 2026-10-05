# Sending through Postmark

Inkwell's password resets and receipts go out through Postmark's transactional
stream, and its weekly digest through a broadcast stream of the same server.
Postmark takes mail over HTTPS, not SMTP, and you still want the same
`Mailer`: the same `Message`, the same `Options`, the same `MailError` to match
on. `open` builds one from a `postmark://` URL, the way it builds one from
`smtps://` or `resend://`.

<!-- doctest: per-block -->

## One URL, one mailer

The server token goes where an SMTP password would, in the URL:

```bit
import { Message, Options, open } from "mail"
import { envOr } from "std/os"

fn main(): ()! {
  let url = envOr("MAIL_URL", "postmark://server-token-123@default")
  let mailer = open(url, Options{ from = "Inkwell <hello@inkwell.dev>" })?
  let receipt = mailer.send(
    Message{
      to = ["Sara Ali <sara@example.com>"],
      subject = "Reset your Inkwell password",
      text = "Open https://inkwell.dev/reset/9f3a to choose a new one.",
    },
  )?
  println(receipt.providerId)
  mailer.close()
  return
}
```

`default` stands for `api.postmarkapp.com`. Each `send` is one `POST /email` with
the token in the `X-Postmark-Server-Token` header, and `Receipt.providerId` is
the `MessageID` Postmark gives the mail, the one its bounce and delivery
webhooks name. Nothing is connected at `open`; the first `send` is the first
request. The `From` address needs a confirmed sender signature or a verified
domain in Postmark, or it answers 422.

To try the program without delivering anything, use Postmark's own test token:
`postmark://POSTMARK_API_TEST@default` makes Postmark check each request and
send nothing.

## A message stream

A Postmark server has streams: `outbound` for transactional mail, and any
broadcast streams you add for bulk mail. A URL picks one with `stream`:

```bit
import { Message, Options, open } from "mail"

fn main(): ()! {
  let mailer = open(
    "postmark://server-token-123@default?stream=weekly-digest",
    Options{ from = "Inkwell <digest@inkwell.dev>" },
  )?
  mailer.send(
    Message{ to = ["sara@example.com"], subject = "Your digest", text = "This week on Inkwell" },
  )?
  mailer.close()
  return
}
```

With no `stream` the mail goes on `outbound`. A stream ID is 1 to 30 lowercase
letters, digits and `-`; anything else, a stream given twice or an empty
`stream=` fails at `open`, so a typo stops the program at startup and not on the
first digest. A stream that does not exist on the server is Postmark's answer
and comes back as `Rejected` with `postmark:1235`.

## The same Message, field for field

Everything a `Message` holds that Postmark can carry is sent:

| `Message` | Postmark |
|---|---|
| `from` (or `Options.from`) | `From` |
| `to`, `cc`, `bcc` | `To`, `Cc`, `Bcc`, each one string of addresses joined by `, ` |
| `replyTo` (or `Options.replyTo`) | `ReplyTo` |
| `subject`, `text`, `html` | `Subject`, `TextBody`, `HtmlBody` |
| `attachments` | `Attachments`: `Name`, base64 `Content`, `ContentType`, and `ContentID` as `cid:<id>` for one with a `cid` |
| `headers`, `inReplyTo`, `references` | `Headers`, a list of `Name` and `Value`, with `In-Reply-To`, `References` and `Auto-Submitted` as the SMTP transport writes them |
| `tags["tag"]` | `Tag` |
| every other `tags` entry | `Metadata` |

A message with only `html` still gets its plain text part, made the same way as
for SMTP. A `bcc` address is a field of the request and in no header Postmark
writes, as ever.

Postmark has one `Tag` per message and a free-form `Metadata` object, where
`Message.tags` has any number of names. The tag named `tag` is the `Tag`; the
rest are `Metadata`, which Postmark returns as strings on its webhooks and lets
you search by. A user id and a plan go in as `tags = { "tag": "password-reset",
"user": "7", "plan": "pro" }`.

Postmark builds the mail itself, so a few things differ from SMTP and are refused
before any request goes out, as `MailError.Invalid`:

* More than 50 recipients across `to`, `cc` and `bcc`. Send the rest in a
  second message.
* A `Tag` over 1000 characters.
* More than 10 `Metadata` entries, a name over 20 characters or empty, a value
  over 80 characters, or two names that differ only in case (Postmark's limits).
* `Message.invite`. Postmark has no calendar alternative; send invites over SMTP.

`Options.dkim` is refused when you call `open` with a `postmark://` URL: Postmark
signs with the key of the domain you verified in its dashboard, and a signature
made here would not be the one that counts.

## What Postmark answers

| Postmark says | You get |
|---|---|
| 200 with `ErrorCode` 0 | a `Receipt` with the `providerId` |
| 401 | `Auth` |
| 429 and 5xx | `Transient`, with `Reply.retryAfter` from `Retry-After` |
| 422 and any other 4xx | `Rejected`, with Postmark's own `Message` |
| no answer, the request never left (refused, connect failed) | `Transient`, naming the step |
| no answer, after the request was written (reset, timed out) | `Unknown`: it may have been taken, so it is not retried |
| a certificate that does not verify | `Rejected`: the same certificate comes back on every try |

Every `ErrorCode` Postmark sends is kept in `Reply.enhanced` as
`postmark:<code>`, so a program can act on the ones it cares about. The common
ones:

| Code | Postmark's meaning | Do |
|---|---|---|
| 300 | invalid email: no recipient, a bad address, no body | fix the message |
| 406 | the recipient is inactive: it bounced or complained before | stop sending to it |
| 411 | an attachment type Postmark does not allow | drop the attachment |
| 412 | a new account may only send to its own domain | wait for approval |
| 1235 | no such message stream on this server | fix `stream` |

```bit
import { MailError, Message, Options, open } from "mail"

fn main(): ()! {
  let mailer = open("postmark://server-token-123@default", Options{ from = "hello@inkwell.dev" })?
  mailer.send(Message{ to = ["sara@example.com"], subject = "Hi", text = "Welcome" }) catch e {
    match (e) {
      Auth(r) => println("check the server token: ${r.toString()}")
      Rejected(r) => {
        if (r.enhanced == "postmark:406") {
          println("suppressed, do not mail again: ${r.text}")
        } else {
          println("Postmark refused it: ${r.toString()}")
        }
      }
      _ => println(e.message())
    }
  }
  mailer.close()
  return
}
```

The token is never in an error or a `Receipt`: a text that Postmark echoes it
into shows `***`.

## A send that may happen twice

Postmark has no idempotency key, so a repeat of a request it already took is a
second mail. `Options.retry` therefore repeats a send only when Postmark cannot
have taken it: a refused connection or a failed connect (the request never
left), a 429, a 5xx (Postmark says a 500 loses the message, and a 503 is
maintenance).

A request that was written and then cut off, by a reset or a timeout while
waiting for the answer, may have been taken. Repeating it on its own would send
the mail twice (RFC 9110 section 9.2.2), so it fails with `MailError.Unknown`
and is not retried. The text names the failure. A program decides what is
worse, a lost mail or a double one:

```bit
import { MailError, Message, Options, open } from "mail"

fn main(): ()! {
  let mailer = open("postmark://server-token-123@default", Options{ from = "hello@inkwell.dev" })?
  mailer.send(Message{ to = ["sara@example.com"], subject = "Your receipt", text = "Thanks" }) catch e {
    match (e) {
      Unknown(r) => println("may have been delivered, check Postmark's activity first: ${r.text}")
      _ => println(e.message())
    }
  }
  mailer.close()
  return
}
```

A receipt or a one-time code is usually sent again anyway once the user asks, so
`Unknown` there means "show the retry button". For a mail that must arrive
exactly once, look the recipient up in Postmark's activity before sending again.

See [Retries and pace](retry.md) for what is repeated and how long it waits.

## A proxy, or a stand-in for tests

Any host other than `default` is used as the API address over HTTPS:
`postmark://server-token-123@mail-proxy.internal:8443`. Its certificate is
checked like Postmark's own. `?insecureSkipVerify=true` turns that off, and
`open` only allows it with such a host, so the real `api.postmarkapp.com` is
never left unverified. Use it with a fake server in a test; for staging, prefer
[`Options.redirect`](redirect.md), which keeps the real host and changes the
recipient.

## Every mistake fails at `open`

Each of these is a `MailError.Config` that names the problem and never repeats
the token: no token, an empty token, a token that is not printable ASCII, a
password after the token, no host, `default` with a port, a bad port, a path,
any query parameter but `stream` and `insecureSkipVerify`, a bad or repeated
`stream`, and `insecureSkipVerify=true` with `default`.

## Where to go next

[Retries and pace](retry.md) has the options used above, and [Sending through
Resend](resend.md) is the same idea for a provider that has an idempotency key.
