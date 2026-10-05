# Bounces and complaints from webhooks

Inkwell sends its welcome mail and its weekly digest through Resend. Some of
those addresses do not exist, and a few readers press "report spam". If Inkwell
keeps mailing them, mailbox providers start to treat all of Inkwell's mail as
junk. Resend tells you what happened to each message by posting a webhook to a
URL you give it; `parseEvents` checks that the post is really from Resend and
turns it into `Event`s you can act on.

<!-- doctest: per-block -->

## Check the post and read it

Your web server gives you the request headers and the raw body. Pass both, with
the signing secret from the Resend dashboard, to `parseEvents`:

```bit
import { Event, EventKind, Provider, parseEvents } from "mail"

// Addresses Inkwell must stop writing to.
let suppressed: []string = []

fn onResendWebhook(header: (string) => string, body: string, secret: string): ()! {
  let events: []Event = parseEvents(Provider.Resend, header, body, secret)?
  for e of events {
    if (e.kind == EventKind.Complained || (e.kind == EventKind.Bounced && e.permanent)) {
      suppressed = append(suppressed, e.recipient)
    }
  }
  return
}
```

`header` is a function that returns the request header of the name you give it,
or `""` when there is none. The server's own header lookup fits, and it is
called with lower-case names. `body` is the request body exactly as it arrived.
Do not parse it and write it back out first: the signature covers the bytes
Resend sent, and a different spacing or key order makes it fail.

One webhook can name several recipients, and you get one `Event` for each. The
provider is a value, `Provider.Resend`, and not a different function, so
the day Inkwell adds a second provider only that argument changes. `Provider`
lists only the providers whose webhooks `parseEvents` can read; a new one is
added in the same release as its parser.

## What an Event says

| Field | Meaning |
|---|---|
| `kind` | An `EventKind`: `Delivered`, `Deferred`, `Bounced`, `Complained`, `Unsubscribed`, `Opened`, `Clicked`, `Rejected` or `Subscribe` |
| `recipient` | The address the event is about |
| `messageId` | The Message-ID of the mail as written, `<...>`; it is the `Receipt.messageId` of the send, so you can find the mail again. `""` when Resend did not report it |
| `providerId` | Resend's own id for the message (`data.email_id`) |
| `deliveryId` | Resend's id for this webhook delivery (`svix-id`); the same on every retry |
| `at` | When it happened, as Resend reports it |
| `permanent` | For `Bounced`: the refusal is for good. A bounce Resend does not classify counts as permanent. `false` for every other kind |
| `reason` | Resend's explanation, or `""`. It is the provider's text: escape it before you show it on a page |
| `provider` | Who posted it |

Resend's `email.delivered`, `email.delivery_delayed`, `email.bounced`,
`email.complained`, `email.opened` and `email.clicked` become `Delivered`,
`Deferred`, `Bounced`, `Complained`, `Opened` and `Clicked`. `email.failed`
and `email.suppressed` become `Rejected`: Resend did not send the mail. Any
other type, such as `contact.created`, gives `[]`. It is not an error, so
adding an event type in Resend's dashboard never makes your endpoint answer
with a failure.

## Retries and de-duplication

Resend posts again until it gets a 2xx answer, so the same event can arrive
twice. `deliveryId` is the same on every retry of one delivery. Store it and
skip what you have seen:

```bit
import { Provider, parseEvents } from "mail"

let seen: []string = []

fn wasSeen(id: string): bool {
  for s of seen {
    if (s == id) {
      return true
    }
  }
  return false
}

fn handle(header: (string) => string, body: string, secret: string): int {
  let events = parseEvents(Provider.Resend, header, body, secret) catch e {
    match (e) {
      Signature(_) => return 401
      Config(why) => {
        println("webhook setup: ${why}")
        return 500
      }
      _ => return 400
    }
  }
  for ev of events {
    if (wasSeen(ev.deliveryId)) {
      return 200
    }
    seen = append(seen, ev.deliveryId)
    println("${ev.recipient}: ${ev.reason}")
  }
  return 200
}
```

The answer to Resend is `200` once you have taken the event.

## When the post is not Resend's

Resend signs every post with the Svix scheme, the same one the Standard
Webhooks specification describes. `parseEvents` takes the secret exactly as the
dashboard shows it, `whsec_` and then base64, and checks, before it reads any
JSON:

- the `svix-id`, `svix-timestamp` and `svix-signature` headers are there (the
  Standard Webhooks names `webhook-id`, `webhook-timestamp` and
  `webhook-signature` are read as well);
- the timestamp is a Unix time in seconds within 5 minutes of now either way, so
  a post that was recorded earlier cannot be played back;
- the signature header, which holds one `v1,<base64>` entry for each active
  secret and so survives a rotation, has at least one entry that matches the
  HMAC-SHA256 of `<id>.<timestamp>.<body>`. Entries of another version are
  skipped. The tags are compared in constant time.

A request that fails any of them returns `MailError.Signature`. Its text names
the reason: `signature does not match`, `svix-signature header is missing`,
`timestamp is more than 5 minutes from now`, and `message()` reads `mail:
webhook rejected: signature does not match`. It never contains the secret or the
body. Answer such a request with 401; it is not a sending failure, so it has no
`Reply`. A body over 1 MiB is `MailError.Invalid` before it is
hashed, and so is a signed body that is not Resend's JSON.

```bit
import { Provider, parseEvents } from "mail"

fn rejects(): string {
  let none = (name: string) => ""
  parseEvents(Provider.Resend, none, "{}", "whsec_MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw") catch e {
    match (e) {
      Signature(why) => return "401 ${why}"
      _ => return e.message()
    }
  }
  return "accepted"
}
```

`rejects()` returns `401 svix-id header is missing`.

## A wrong secret is found by the first request

A secret that is empty, has no `whsec_` prefix or is not base64 after it is a
mistake in your setup, not in the request. `parseEvents` fails every call with
`MailError.Config`, so the first test post shows it and the text says what is
wrong without printing the value:

```bit
import { Provider, parseEvents } from "mail"

fn main(): ()! {
  let none = (name: string) => ""
  parseEvents(Provider.Resend, none, "{}", "re_live_key_not_a_webhook_secret") catch e {
    println(e.message())
    return
  }
  return
}
```

That prints `mail: configuration: the Resend webhook secret must be the whsec_
value from the dashboard`. The signing secret is not the API key: copy it from
the webhook's page in the dashboard.

Next: [The Mailer](mailer.md) for sending, and [Messages](messages.md) for the
`Message-ID` that `messageId` gives you back.
