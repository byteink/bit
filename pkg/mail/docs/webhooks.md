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
provider is a value, `Provider.Resend`, `Provider.Postmark` or `Provider.Mailgun`, and not a different function, so
the day Inkwell adds a second provider only that argument changes. `Provider`
lists only the providers whose webhooks `parseEvents` can read; a new one is
added in the same release as its parser.

## What an Event says

| Field | Meaning |
|---|---|
| `kind` | An `EventKind`: `Delivered`, `Deferred`, `Bounced`, `Complained`, `Unsubscribed`, `Opened`, `Clicked`, `Rejected` or `Subscribe` |
| `recipient` | The address the event is about |
| `messageId` | The Message-ID of the mail as written, `<...>`; `""` when the provider did not report it |
| `providerId` | The provider's message id: Resend `data.email_id`, Postmark `MessageID` |
| `deliveryId` | The webhook delivery id: Resend `svix-id`, Postmark `X-PM-Webhook-Trace-Id`; stable across retries, `""` if absent |
| `at` | When it happened, as the provider reports it; delivery time if missing or invalid |
| `permanent` | For `Bounced`: whether future sends should be suppressed. An unclassified bounce counts as permanent. `false` for every other kind |
| `reason` | The provider's explanation, or `""`: escape it before showing it on a page |
| `provider` | Who posted it |

A log line for the support team reads each kind, the time and who posted it:

```bit
import { Event, EventKind, Provider } from "mail"
import { parseRfc3339 } from "std/time"

fn describe(e: Event): string {
  match (e.kind) {
    Delivered => return "${e.recipient} took the mail"
    Deferred => return "${e.recipient} is busy, Resend will try again"
    Bounced => return "${e.recipient} bounced, permanent ${e.permanent}: ${e.reason}"
    Complained => return "${e.recipient} reported spam: stop writing"
    Unsubscribed => return "${e.recipient} unsubscribed"
    Opened => return "${e.recipient} opened it"
    Clicked => return "${e.recipient} followed a link"
    Rejected => return "Resend did not send to ${e.recipient}: ${e.reason}"
    Subscribe => return "${e.recipient} subscribed"
  }
}

fn main(): ()! {
  let e = Event{
    kind = EventKind.Bounced,
    recipient = "sara@example.com",
    messageId = "<welcome-7@inkwell.dev>",
    providerId = "49a3999c-0ce1-4ea6-ab68-afcd6dc2e794",
    deliveryId = "msg_2Lh9KRb0pzN3LePPs7bPXpNnTcv",
    at = parseRfc3339("2026-10-06T09:15:00Z")?,
    permanent = true,
    reason = "mailbox does not exist",
    provider = Provider.Resend,
  }
  println(describe(e))
  println("${e.at.toString()} ${e.provider == Provider.Resend}")
  return
}
```

That prints `sara@example.com bounced, permanent true: mailbox does not exist`
and then `2026-10-06T09:15:00Z true`.

Resend's `email.delivered`, `email.delivery_delayed`, `email.bounced`,
`email.complained`, `email.opened` and `email.clicked` become `Delivered`,
`Deferred`, `Bounced`, `Complained`, `Opened` and `Clicked`. `email.failed`
and `email.suppressed` become `Rejected`: Resend did not send the mail. Any
other type, such as `contact.created`, gives `[]`. It is not an error, so
adding an event type in Resend's dashboard never makes your endpoint answer
with a failure.

## When Inkwell uses Postmark

Inkwell can keep the same suppression list when it sends through Postmark.
Configure an HTTPS webhook URL with Basic authentication in Postmark, such as
`https://<user>:<password>@inkwell.dev/hooks/postmark`. Keep the configured
`user:password` in your application's secret store and pass it as `secret`.
Postmark does not sign the body; `parseEvents` checks the decoded Basic
credentials in constant time before reading any JSON. Your server can also
allow only [Postmark's webhook IP ranges](https://postmarkapp.com/support/article/800-ips-for-firewalls).

The handler uses Postmark's explicit suppression changes as well as permanent
bounces and complaints. It reports credential failures as 401 without logging
the supplied credentials:

```bit
import { EventKind, Provider, parseEvents } from "mail"

fn onPostmarkWebhook(
  header: (string) => string,
  body: string,
  credentials: string,
  setSuppressed: (string, bool) => (),
): int {
  let events = parseEvents(Provider.Postmark, header, body, credentials) catch e {
    match (e) {
      Auth(_) => return 401
      _ => return 400
    }
  }
  for ev of events {
    if (ev.kind == EventKind.Subscribe) {
      setSuppressed(ev.recipient, false)
    }
    if (ev.kind == EventKind.Unsubscribed ||
      ev.kind == EventKind.Complained ||
      (ev.kind == EventKind.Bounced && ev.permanent)) {
      setSuppressed(ev.recipient, true)
    }
  }
  return 200
}
```

An empty `secret` is `MailError.Invalid`: configure credentials before exposing
the endpoint. Missing, malformed or incorrect Authorization is `MailError.Auth`.
Resend continues to report signature failures as `MailError.Signature`.
Both providers reject bodies over 1 MiB; malformed authenticated JSON is Invalid.

Postmark's `Delivery`, `Bounce`, `SpamComplaint`, `Open` and `Click` records become
`Delivered`, `Bounced`, `Complained`, `Opened` and `Clicked`. `SubscriptionChange`
becomes `Unsubscribed` when `SuppressSending` is true and `Subscribe` when false.
It must be a JSON boolean. Unknown record types give `[]`; known records require
a recipient from `Recipient`, with `Email` as fallback.

`providerId` reads `MessageID`, which may be null on manual suppressions and
reactivations. `messageId` reads an original RFC Message-ID your application
carried in `Metadata.message_id`, then a `Message-ID` entry in the payload's
`Headers` list (`Name` and `Value`). Missing or null optional ids become `""`.
Postmark's `MessageID` is its provider id, never a substitute for the mail header.
The event time reads `DeliveredAt`, `BouncedAt`, `ChangedAt` or `ReceivedAt`;
the reason reads `Description`, then `Details`, then `SuppressionReason`.

For bounces, the package interprets
[Postmark's documented types](https://postmarkapp.com/developer/api/bounce-api#bounce-types)
as suppression policy. It treats `HardBounce`, `Unsubscribe`, `AddressChange`,
`SpamNotification`, `Unknown`, `BadEmailAddress`, `SpamComplaint`,
`ManuallyDeactivated` and `Unconfirmed` as permanent. `Transient`, `Subscribe`,
`AutoResponder`, `DnsError`, `OpenRelayTest`, `SoftBounce`, `VirusNotification`,
`ChallengeVerification`, `Blocked`, `SMTPApiError`, `InboundError`, `DMARCPolicy`
and `TemplateRenderingFailed` are temporary: some concern this message or the
sender's setup rather than a dead address. Missing or new classifications are
conservatively permanent. These flags are the package's interpretation, not a
binary field Postmark promises. `Inactive` does not override the type; use
SubscriptionChange to follow Postmark's actual suppression state.

`deliveryId` reads `X-PM-Webhook-Trace-Id`; keep it when you record the event so
retries do not apply it twice. When absent, construct a compound key from the
record's identity, recipient and event time. Never treat all empty ids as one
delivery. The existing Resend de-duplication example below assumes a nonempty
delivery id.

## When Inkwell uses Mailgun

Keep the same suppression list when Inkwell sends through Mailgun. Copy the
account's HTTP webhook signing key from Settings > API Security. This is the
raw signing key, not the API key. Mailgun sends signature fields inside JSON:

```json
{"signature":{"timestamp":"1700000000","token":"delivery-7","signature":"hex HMAC-SHA256"},"event-data":{"event":"delivered","recipient":"sara@inkwell.dev","id":"event-7","timestamp":1700000000.125,"message":{"headers":{"message-id":"<welcome-7@inkwell.dev>"}}}}
```

The signature is hexadecimal HMAC-SHA256 over the exact timestamp text followed
by the token, with no separator. It does not sign the event payload bytes.
Use HTTPS and pass the raw body and signing key to the same API:

```bit
import { EventKind, Provider, parseEvents } from "mail"

fn onMailgunWebhook(body: string, signingKey: string, suppress: (string) => ()): int {
  let events = parseEvents(Provider.Mailgun, (name) => "", body, signingKey) catch e {
    match (e) {
      Signature(_) => return 401
      Config(_) => return 500
      _ => return 400
    }
  }
  for ev of events {
    if (ev.kind == EventKind.Complained ||
      ev.kind == EventKind.Unsubscribed ||
      (ev.kind == EventKind.Bounced && ev.permanent)) {
      suppress(ev.recipient)
    }
  }
  return 200
}
```

The signed timestamp must be within five minutes either way, including both
boundaries. Wrong signatures, stale timestamps and repeated tokens return
`MailError.Signature`. An empty signing key returns `MailError.Config`.
Malformed signature fields or event data return `MailError.Invalid`. The same
1 MiB body limit applies. Bounded JSON is read to extract the signature;
event fields are mapped after verification.

Delivered, complained, unsubscribed, opened and clicked become the matching
`EventKind`. A failed event with permanent severity becomes `Bounced` with
`permanent = true`; temporary severity becomes `Deferred`. An unknown failure
severity is Invalid. Accepted and unknown events give `[]`.

`providerId` reads the event's `id`, `messageId` reads
`message.headers.message-id`, and `deliveryId` is the signed token.
`at` reads numeric `event-data.timestamp`, including fractional seconds;
missing, nonnumeric or out-of-range time falls back to request time.
`reason` is the first nonempty `delivery-status.description`,
`delivery-status.message`, then `event-data.reason`.

Each process remembers at most 10,000 verified token digests. A token expires
only after its signed time plus five minutes, so a future-dated token remains
protected throughout its acceptance window. Capacity evicts the oldest
insertion. A restart or eviction loses that local replay record. Store
`Event.deliveryId` in shared application storage for durable deduplication
across instances; local rejection alone cannot provide it. Invalid signatures
never consume a cache slot.

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
