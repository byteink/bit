# Unsubscribe: one click, signed

Every Monday Inkwell sends the weekly digest to forty thousand subscribers.
Gmail holds senders of more than 5,000 mails a day to one rule: marketing and
subscribed mail must support one-click unsubscribe (RFC 8058), and Yahoo asks
for the same and for unsubscribes to be honoured within two days. Both also want
a visible unsubscribe link in the body, so keep the one in your template. Mail
that lacks the header is deferred or sent to spam: the mailbox provider shows
its own "Unsubscribe" button next to the sender name, and it needs a header to
find out where that button points.

`Message.unsubscribe` writes that header, and the second one RFC 8058 requires
beside it, and makes sure the DKIM signature covers both.

<!-- doctest: per-block -->

## One URL

```bit
import { Mailer, Message, Options, Outbox, Unsubscribe } from "mail"
import { contains } from "std/strings"

fn main(): ()! {
  let mailer = Mailer(Outbox(), Options{ from = "Inkwell <hello@inkwell.dev>" })?
  let raw = mailer.render(
    Message{
      to = ["Sara Ali <sara@example.com>"],
      subject = "Your weekly Inkwell digest",
      text = "Three new posts this week.",
      unsubscribe = Unsubscribe{ url = "https://inkwell.dev/u/7f3a9c" },
    },
  )?
  let one = contains(raw, "List-Unsubscribe: <https://inkwell.dev/u/7f3a9c>")
  let post = contains(raw, "List-Unsubscribe-Post: List-Unsubscribe=One-Click")
  println("${one} ${post}")
  mailer.close()
  return
}
```

That prints `true true`. `url` is the address the mailbox provider sends an
HTTPS POST to when the reader presses its button. Your server answers that POST
and removes the subscriber; nothing else is sent to it, no cookies and no login,
so the URL has to say on its own who is leaving and from which list. Put an
unguessable token in it (`7f3a9c` here stands for one): a URL anyone can build
lets anyone unsubscribe anyone. The answer must be a plain 200, never a
redirect (RFC 8058 section 3.1).

## A mailto beside it

Some mail clients and older receivers unsubscribe by sending a mail instead.
RFC 8058 allows both in the one `List-Unsubscribe` field, and the usual practice
is the https URL first and a `mailto:` after it. Set both on `Unsubscribe`:

```bit
import { Mailer, Message, Options, Outbox, Unsubscribe } from "mail"

fn main(): ()! {
  let box = Outbox()
  let mailer = Mailer(box, Options{ from = "Inkwell <hello@inkwell.dev>" })?
  mailer.send(
    Message{
      to = ["Sara Ali <sara@example.com>"],
      subject = "Your weekly Inkwell digest",
      text = "Three new posts this week.",
      unsubscribe = Unsubscribe{
        url = "https://inkwell.dev/u/7f3a9c",
        mailto = "unsubscribe@inkwell.dev?subject=7f3a9c",
      },
    },
  )?
  println(box.sent()[0].message.unsubscribe.mailto)
  mailer.close()
  return
}
```

The field reads `List-Unsubscribe: <https://inkwell.dev/u/7f3a9c>,
<mailto:unsubscribe@inkwell.dev?subject=7f3a9c>`. `mailto` is an address or a
`mailto:` URI; an address gets the scheme. A `mailto` alone is written as
`List-Unsubscribe: <mailto:...>` and no `List-Unsubscribe-Post`, because there
is nothing to POST to. That is a valid RFC 2369 header and Yahoo accepts it, but
Gmail's setup asks for the https pair, so for bulk mail set `url`.

## Always signed

RFC 8058 requires a DKIM signature that covers both fields: otherwise anyone on
the path could swap the URL for their own. The default signed-header list of
`Options.dkim` includes `List-Unsubscribe` and `List-Unsubscribe-Post`, so a
mailer with a key needs nothing more. A custom `Dkim.headers` list that leaves
either out is refused when the mailer opens:

```text
mail: configuration: dkim digest._domainkey.inkwell.dev: headers must include List-Unsubscribe and List-Unsubscribe-Post: RFC 8058 requires both to be signed
```

See [Signing your mail](dkim.md).

## Through a provider

[Resend](resend.md), [Postmark](postmark.md) and [SendGrid](sendgrid.md) build
the message themselves, so both fields go in their custom-headers field of the
request, exactly as the SMTP renderer would write them. [Mailgun](mailgun.md)
takes the raw message and carries them as they are.

## What is refused

The check runs when the message is rendered and names the field, as every
other refusal in [Messages](messages.md) does:

* `unsubscribe.url: must be https for one-click (RFC 8058)` for an `http://`
  URL, and `is not an https URL` for anything else, including `https://` with no
  host;
* `unsubscribe.url` or `unsubscribe.mailto` with `it must be printable ASCII
  with no space, '<' or '>'` for a space, a control byte, a non-ASCII byte or an
  angle bracket (percent-encode them), so a value can never end the field early
  or start a new header;
* the same fields for a URI over 2000 bytes, and `unsubscribe.mailto` for an
  address `parseAddress` refuses.

`Message.headers` may set neither field: `headers["List-Unsubscribe"]` fails
with `set Message.unsubscribe instead`. There is one way to set it, and it is
the one that signs.

## Where to go next

[Signing your mail](dkim.md) has the key setup the signature needs.
[Messages](messages.md) lists every `Message` field, and
[The Mailer](mailer.md) the `Outbox` these examples read.
