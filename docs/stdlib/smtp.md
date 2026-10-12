# std/smtp

An ESMTP submission client: the layer a service needs to put a password reset,
a verification link, an invoice or an alert into a relay. Built on
[`std/net`](net.md) and [`std/tls`](tls.md).

Sending only. There is no IMAP, no POP3 and no server here.

<!-- doctest: per-block -->

## The session

### International addresses

UTF-8 mailbox addresses stay unchanged in the envelope and address headers.
`send` requires the relay's current `SMTPUTF8` and `8BITMIME` offers before
opening the transaction. Raw eight-bit bodies require `8BITMIME` alone.
See [Send mail to international addresses](smtp/international-addresses.md)
for complete examples, local refusals and signed-message behavior.

A session is `dial` (or `dialTls`), `ehlo`, optionally `startTls` and an `auth`
mechanism, then one `send` per message, then `quit`.

```bit
import { dial, Options, Address, Auth, Client, Message } from "std/smtp"

// Submit `m` through a relay on the cleartext submission port, upgrading to TLS
// before the credential is sent. `startTls` verifies the server's certificate
// against the system trust anchors; the second `ehlo` is required by RFC 3207,
// because the capability list offered in cleartext is not authenticated.
fn submit(host: string, user: string, pass: string, m: Message): ()! {
  let c = dial(host, 587)?
  defer c.close()
  c.ehlo("client.example.com")?
  c.startTls(Options())?
  c.ehlo("client.example.com")?
  c.auth(Auth.Plain(user, pass))?
  c.send(m)?
  c.quit()?
}
```

Port 465 is implicit TLS: `dialTls` instead, and no `startTls`.

## When a send fails

Every fallible call in the module fails with an `SmtpError`. A relay that
retries has to tell "try again later" from "this will never work", and the error
answers that without parsing its text.

```bit
import { Client, Message, SmtpError } from "std/smtp"

// How `send` ended: delivered, worth another attempt, or given up on.
enum Outcome { Sent, Retry, Rejected }

// The decision, from the error alone.
fn verdict(e: SmtpError): Outcome {
  if (e.transient()) {
    return Outcome.Retry
  }
  return Outcome.Rejected
}

fn attempt(c: Client, m: Message): Outcome {
  c.send(m) catch e {
    println("${e.command} failed: ${e.code} ${e.enhanced} ${e.text}")
    return verdict(e)
  }
  return Outcome.Sent
}
```

`e` is an `SmtpError` there, fields in reach, because `send` is declared
`Delivery!SmtpError`. A mailbox that is busy (`450 4.2.1 Mailbox busy`)
is `Retry`; an unknown user (`550 5.1.1 No such user`) is `Rejected`, and
sending it again draws the same answer.

`transient()` is true for a 4xx reply, and for a failure with no reply at all -
a refused connection, a reset, a timeout, a handshake the network cut off -
because those are the network's. It is false for a 5xx reply, an unexpected 2xx
or 3xx, a TLS handshake that failed on the server's certificate or on
negotiation, and for the calls the module refuses locally: a CR in a header value, a malformed
address, `AUTH` on a connection that is not TLS, a command out of order. A
local refusal has `command` equal to `"validate"`, and retrying it is only
ever the same mistake again.

A certificate the client will not accept - an untrusted or self-signed chain, a
name the certificate does not cover, an expired one - and a handshake the two
sides cannot agree on are permanent: the server presents the same certificate
and the same offer next time, so a retry only delays the operator's signal. The
reason is in `cause`, the `std/tls` error under the failure, and it is a
`HandshakeError` whose `kind` says which:

```bit
import { Options, dialTls } from "std/smtp"
import { HandshakeError, HandshakeFailure } from "std/tls"

// Why a connection to `host` could not be made, for the operator.
fn why(host: string): string {
  dialTls(host, 465, Options()) catch e {
    let (h, ok) = e.cause.(HandshakeError)
    if (!ok) {
      return "network: ${e.message()}"
    }
    if (h.kind == HandshakeFailure.Verification) {
      return "certificate: ${e.message()}"
    }
    return "tls: ${e.message()}"
  }
  return "connected"
}
```

`cause` is nil for a reply and for a local refusal, so the `ok` check is also the
test for "this failure came from a transport error at all".

`message()` gives the one-line form, `smtp: RCPT TO got 450: 4.2.1 Mailbox
busy`, and `SmtpError` satisfies `error`, so a caller that only logs can keep
`catch e` and `e.message()` and ignore the rest.

## When some recipients are refused

A message with three recipients and one mistyped address should reach the other
two. `send` returns a `Delivery` that says which were taken and which were not:

```bit
import { Client, Delivery, Message, SmtpError } from "std/smtp"

// Send `m`, and list the recipients to try again or to tell the author about.
fn sendAndReport(c: Client, m: Message): ()!SmtpError {
  let d = c.send(m)?
  println("queued as ${d.queueId}: ${len(d.accepted)} delivered")
  let i = 0
  while (i < len(d.rejected)) {
    let r = d.rejected[i]
    println("${r.address}: ${r.error.code} ${r.error.enhanced} ${r.error.text}")
    i = i + 1
  }
}
```

A recipient in `rejected` did not get the message, and sending the message
again to everyone would deliver it twice to the others: send it again to the
`rejected` addresses whose `error.transient()` is true, and only those. When
every recipient is refused there is no `Delivery`; `send` fails with an
`SmtpError` as in "When a send fails".

## Addresses and messages

A message is built, then rendered once. Nothing is validated at the setters and
everything is validated at `render()`, so a message assembled from several
places has one failure point with the whole message in view.

```bit
import { Message, Attachment, Address } from "std/smtp"

// A two-part message with an attachment: text, an HTML alternative, and a file.
// The body comes out `multipart/mixed` wrapping a `multipart/alternative`.
fn invoice(pdf: []byte): string! {
  let m = Message(Address{ name = "Billing", email = "billing@example.com" })
  m.addTo(Address{ name = "", email = "customer@example.net" })
  m.setSubject("Your invoice")
  m.setText("The invoice is attached.\n")
  m.setHtml("<p>The invoice is attached.</p>\n")
  m.attach(Attachment("invoice.pdf", "application/pdf", pdf))
  return m.render()?
}
```

The body shape follows what the message carries, with no empty wrappers:

| Content | Body |
|---|---|
| text only | `text/plain` |
| text + HTML | `multipart/alternative` |
| text (+ HTML) + `addAlternative` parts | `multipart/alternative` |
| text (+ HTML, alternatives) + attachments | `multipart/mixed` |
| text + HTML + `addInline` parts | `multipart/alternative` holding `text/plain` and a `multipart/related` of the HTML and the inline parts |
| the same + attachments | `multipart/mixed` wrapping that `multipart/alternative`, then the attachments |

### `Address`

A mailbox: `name` is the optional display name, `email` the addr-spec the
envelope carries. `email` is validated before use - exactly one `@`, a non-empty
local part, a well-formed domain, and inside RFC 5321's 64/254 octet ceilings -
and `name` is a header value, rejected for CR/LF/NUL like any other. A name that
is not printable ASCII, or that carries a quote or a backslash, is sent as an
RFC 2047 encoded word rather than a quoted string.

### `Attachment(filename: string, contentType: string, data: []byte)`

A file to attach: `filename`, `contentType` (empty means
`application/octet-stream`) and `data`, the raw bytes. Attachments are always
base64 - an attachment is opaque bytes, and choosing an encoding from a sample
of them is how a binary file arrives corrupted.

The file name reaches the receiver in the `filename` parameter of
`Content-Disposition` and the `name` parameter of the part's `Content-Type`
(Outlook reads that one), and it is written so that it can only ever be a file
name:

- A plain printable ASCII name is a quoted string, with `"` and `\` escaped
  by a backslash. `a"; x="y.pdf` arrives as one parameter, not as the
  parameter `x`.
- Anything else - a non-ASCII name, or one too long for a line - is an
  RFC 2231 extended value, `filename*=utf-8''r%C3%A9sum%C3%A9.pdf`, split into
  `filename*0*=`, `filename*1*=` continuations so no line passes 77 octets.
  Mail clients that predate RFC 2231 read the quoted ASCII fallback written
  just before it (`filename="r?sum?.pdf"`: one `?` per non-ASCII rune, cut
  short with its extension kept).
- A name is never an RFC 2047 encoded word: a header parameter may not hold
  one, and clients show it as garbage.
- A CR, LF or NUL in the name is still rejected by `Message.render`, never
  encoded.

### `Message(sender: Address)`

One outgoing mail, built from its sender with no recipients, subject or body.
Add those with the setters below; nothing reaches the network until
`Client.send`.

### `Message.addTo(a: Address)`

Add a `To:` recipient. Also an envelope recipient: this module has no concept of
a header recipient that is not delivered to.

### `Message.addCc(a: Address)`

Add a `Cc:` recipient, delivered to like a `To:`.

### `Message.addBcc(a: Address)`

Add a blind recipient: delivered to like a `To:`, and never written into any
header, not even a `Bcc:` one. RFC 5322 section 3.6.3 allows a `Bcc:` header,
but a relay or a mail client that keeps it shows every recipient the whole list,
so this module sends the copy and leaves the header out. The address is
validated at `render()` like any other, because it still ends up in a
`RCPT TO:` command.

```bit
import { Message, Address } from "std/smtp"

// The auditor gets every invoice; the customer never learns that.
fn invoice(): string! {
  let m = Message(Address{ name = "Billing", email = "billing@inkwell.dev" })
  m.addTo(Address{ name = "", email = "customer@example.net" })
  m.addBcc(Address{ name = "Audit", email = "audit@inkwell.dev" })
  return m.render()?
}
```

The rendered message above has a `To:` line and no mention of
`audit@inkwell.dev`; `Client.send` still issues a `RCPT TO` for it.

### `Message.addReplyTo(a: Address)`

Add a `Reply-To:` address, the place a reply goes instead of the sender. It is
rendered as one header after `Cc:`, validated like `To:` and `Cc:`, and is not
an envelope recipient: nothing is delivered to it.

```bit
import { Message, Address } from "std/smtp"

// Mail comes from a no-reply address; answers go to the support desk.
fn notice(): string! {
  let m = Message(Address{ name = "Inkwell", email = "no-reply@inkwell.dev" })
  m.addTo(Address{ name = "", email = "customer@example.net" })
  m.addReplyTo(Address{ name = "Support", email = "support@inkwell.dev" })
  return m.render()?
}
```

### `Message.setSubject(s: string)`

Set the `Subject:` header. Rejected at `render()` if it carries a CR, LF or NUL;
folded, or encoded as RFC 2047 words, if it is long or not printable ASCII.

### `Message.setText(s: string)`

Set the plain-text body. Always present in the rendered message: a mail with only
an HTML part is unreadable to a text-only client. The body, and the HTML part,
is sent `7bit`, quoted-printable or base64 as described in
[What this module refuses to do](smtp/connecting.md#what-this-module-refuses-to-do).

```bit
import { Address, Message } from "std/smtp"
import { indexOf } from "std/strings"

// The `Content-Transfer-Encoding` a body renders with: `7bit` for ASCII,
// `quoted-printable` for a few accented letters, `base64` for a script that is
// mostly multi-byte.
fn encodingOf(body: string): string! {
  let m = Message(Address{ name = "", email = "orders@inkwell.dev" })
  m.addTo(Address{ name = "", email = "ada@example.com" })
  m.setSubject("Your order")
  m.setText(body)
  let raw = m.render()?
  let key = "Content-Transfer-Encoding: "
  let at = indexOf(raw, key) + len(key)
  let end = at + indexOf(raw[at:], "\r\n")
  return raw[at:end]
}
```

### `Message.setHtml(s: string)`

Set the HTML alternative. Sent alongside the text part inside a
`multipart/alternative`, never instead of it.

### `Message.addAlternative(contentType: string, body: string)`

Add a further part to the `multipart/alternative`, after the text and HTML
parts and in call order. RFC 2046 section 5.1.4 makes the last part the
preferred one, so a client that understands it shows it. The usual use is a
calendar invite (RFC 6047), which Gmail and Outlook render with accept and
decline buttons only when it is a `text/calendar` part with a `method`
parameter next to the HTML:

```bit
import { Message, Address } from "std/smtp"

fn invite(ics: string): string! {
  let m = Message(Address{ name = "Ada", email = "ada@example.com" })
  m.addTo(Address{ name = "", email = "team@example.net" })
  m.setSubject("Design review")
  m.setText("Design review, Friday at 10:00.\n")
  m.setHtml("<p>Design review, Friday at 10:00.</p>\n")
  m.addAlternative("text/calendar; method=REQUEST; charset=utf-8", ics)
  return m.render()?
}
```

The body is encoded like a text part: `7bit` when its bytes prove it safe, else
quoted-printable or base64, whichever is smaller. A message with text and one
alternative but no HTML is still a `multipart/alternative`.

`render()` fails with `smtp: '<contentType>' is not allowed as an alternative
part` unless `contentType` is `type/subtype` of RFC 2045 token characters,
optionally followed by `; name=value` parameters (the value a token or a
quoted string), with no CR, LF or NUL. `multipart/*`, `text/plain` and
`text/html` are refused whatever their parameters, because they have their own
setters.

### `Message.addInline(a: Attachment, contentId: string)`

Add `a` as an inline part the HTML body refers to by `Content-ID`: a logo in a
receipt, shown in the message instead of listed as a file. The HTML says
`<img src="cid:logo@inkwell">` (RFC 2392) and the part carries
`Content-ID: <logo@inkwell>`; the HTML and its inline parts travel in a
`multipart/related` (RFC 2387) whose first part is the HTML, nested in the
`multipart/alternative` beside the text part. Extra `addAlternative` parts
still come last, and attachments still wrap everything in `multipart/mixed`.

```bit
import { Message, Attachment, Address } from "std/smtp"

fn receipt(logo: []byte): string! {
  let m = Message(Address{ name = "Inkwell", email = "shop@example.com" })
  m.addTo(Address{ name = "", email = "customer@example.net" })
  m.setSubject("Your receipt")
  m.setText("Thank you for your order.\n")
  m.setHtml("<img src=\"cid:logo@inkwell\"><p>Thank you for your order.</p>\n")
  m.addInline(Attachment("logo.png", "image/png", logo), "logo@inkwell")
  return m.render()?
}
```

`contentId` is the bare id, without angle brackets. The part is base64 with
`Content-Disposition: inline` and the same filename encoding as an attachment.
`render()` fails with `smtp: '<contentId>' is not a valid Content-ID` unless
`contentId` is a dot-atom, or two dot-atoms joined by one `@`, of at most 250
ASCII octets with no CR, LF, NUL or space; with `smtp: duplicate Content-ID
'<contentId>'` when two inline parts share one (compared byte for byte); and
with `smtp: an inline part needs an HTML body` when the message has no HTML,
since nothing could refer to the part.

### `Message.attach(a: Attachment)`

Attach `a`. The message becomes `multipart/mixed` at render time.

### `Message.setBoundary(b: string)`

Override the MIME boundary. Exists so a test can assert an exact body; the
default is random (UUIDv4), which is what a boundary must be - one derived from
the content is one an attacker who controls a part can reproduce and embed.
Rejected at `render()` unless it is a legal RFC 2046 boundary.

### `Message.setMessageId(id: string)`

Set the `Message-ID` to `id`, the bare id without angle brackets. Without it,
`render()` writes a fresh one: a UUIDv7 at the sender's own domain, never the
local hostname, so no two messages share an id and the id names no machine.
Set one when the id has to be known before the send, to thread a reply or to
find the message again in a log:

```bit
import { Message, Address } from "std/smtp"

// The id is chosen by the caller, so a later `In-Reply-To` can name it.
fn receipt(order: string): string! {
  let m = Message(Address{ name = "Billing", email = "billing@inkwell.dev" })
  m.addTo(Address{ name = "", email = "customer@example.net" })
  m.setMessageId("receipt-${order}@inkwell.dev")
  return m.render()?
}
```

Rejected at `render()`, as `smtp: '<id>' is not a valid Message-ID`, unless it
is RFC 5322 `id-left "@" id-right`: dot-atom-text on both sides, printable
ASCII with no space, CR, LF or NUL, at most 250 octets.

### `Message.setHeader(name: string, value: string)`

Set a custom header: `In-Reply-To` and `References` to thread a reply,
`List-Unsubscribe` and `List-Unsubscribe-Post` for bulk mail, `Auto-Submitted`
for an automated one, or a provider's own `X-` field. The fields are written
after `Message-ID` and before `MIME-Version`, in the order first set. Setting a
name again, in any letter case, replaces its value and keeps its place:

```bit
import { Message, Address } from "std/smtp"

// A reply that threads under the receipt sent earlier.
fn followUp(order: string): string! {
  let m = Message(Address{ name = "Billing", email = "billing@inkwell.dev" })
  m.addTo(Address{ name = "", email = "customer@example.net" })
  m.setSubject("Re: your receipt")
  m.setHeader("In-Reply-To", "<receipt-${order}@inkwell.dev>")
  m.setHeader("References", "<receipt-${order}@inkwell.dev>")
  m.setHeader("Auto-Submitted", "auto-generated")
  return m.render()?
}
```

The value is folded, or encoded as RFC 2047 words, like a subject, and is
rejected at `render()` if it carries a CR, LF or NUL. The name is checked at
`render()` too: it must be 1 to 76 octets of printable ASCII other than a space
or `:`, else `smtp: '<name>' is not a valid header name`. A name a typed setter
owns is refused, in any letter case, as `smtp: header <name> is set by its own
method, not setHeader`: `From`, `To`, `Cc`, `Bcc`, `Reply-To`, `Subject`,
`Date`, `Message-ID`, `MIME-Version` and every `Content-*` name. Two ways to set
one field would let a receiver read either, so there is only one.

### `Message.recipients(): []Address`

Every address this message is delivered to, `To:`, then `Cc:`, then `Bcc:`, in
the order added - the envelope `RCPT TO` list. `Reply-To:` is not in it.

### `Message.envelope(): Envelope`

The envelope this message is sent under: `from` is the sender's address, `to` is
`recipients()` as addr-specs. `Client.send` calls it for you.

### `Message.render(): string!SmtpError`

The complete RFC 5322 message: headers, a blank line, and the body, CRLF
throughout, including the final line ending used in SMTP `SIZE`. Existing final
line endings are preserved. Dot-stuffing is not applied (that belongs to the
transmission, not to the message). The headers are, in order, `Date`, `From`,
`To`, `Cc`, `Reply-To`, `Subject`,
`Message-ID`, the `setHeader` fields, `MIME-Version` and the `Content-*` fields. `Date` is the time of
the render in RFC 5322 form with a numeric zone, `Date: Sun, 06 Nov 1994
08:49:37 +0000`, and `Message-ID` is `<uuidv7@sender-domain>` unless
`setMessageId` set one. Both are written here rather than left to a relay: a
relay that adds a missing one changes bytes the sender may already have signed,
and a receiving provider counts a message without them against it. Fails on a
header value carrying a CR, LF or NUL, on a malformed envelope address, on an
illegal explicit boundary or Message-ID, or if any line would exceed the octet
limit.

## The envelope and pre-rendered mail

`MAIL FROM` and `RCPT TO` are not the message's headers, and sometimes they must
differ. A bounce address that encodes the notification it belongs to (VERP) is
not the `From`; a staging server that redirects every mail to one inbox
delivers to an address no header names; and a message signed with DKIM must be
sent as the exact bytes that were signed, so whoever signed it cannot hand
`send` a `Message` to render again.

`send` takes a `Sendable` for all three: something that renders to a complete
message and says which envelope to use. A `Message` is one and derives its
envelope; a `Raw` is the other and carries both from you.

```bit
import { Client, Raw, Envelope, SmtpError } from "std/smtp"

// Send an already rendered (and signed) Inkwell notification. Replies to the
// notification bounce to an address that says which one it was, so the bounce
// handler can find it; the headers inside `signed` still say
// `From: noreply@inkwell.dev`.
fn sendNotification(c: Client, id: int, to: string, signed: string): ()!SmtpError {
  let e = Envelope{ from = "bounce+${id}@inkwell.dev", to = [to] }
  c.send(Raw(e, signed))?
}
```

An empty `from` sends `MAIL FROM:<>`, the null reverse-path a bounce itself
uses so that it is never bounced back.

The bytes go out as they are, apart from DATA dot-stuffing, which the server
removes. Bytes that are not a well-formed message are refused, never repaired,
because a repair would change a body a signature already covers:

| The data has | Refused as |
|---|---|
| a bare LF or a bare CR | line N does not end in CRLF |
| a NUL | line N contains a NUL byte |
| a line of 998 octets or more | line N is too long |
| no blank line between header and body | no blank line |
| a last line without CRLF | line N does not end in CRLF |

Every address in the envelope goes through the same check as the addresses of a
`Message`, so one carrying a CR, LF or space is refused, and an envelope with no
recipient is refused. All of it happens before `MAIL FROM`, so a refusal sends
nothing after `EHLO`. A `Bcc` recipient is just another entry in `to`: it never
appears in the bytes.

### `Envelope`

`from: string` is the `MAIL FROM` addr-spec, `""` for the null reverse-path;
`to: []string` is every `RCPT TO` addr-spec, at least one; `dsn: Dsn` is the
delivery status notifications to ask for, `Dsn{}` by default; `requireTls: bool`
requires verified TLS for this message and its onward delivery, false by default.

### `Sendable`

What `Client.send` takes: `render(): string!SmtpError`, the complete message,
and `envelope(): Envelope`. `Message` and `Raw` both satisfy it; implementing it
is for a caller with its own message type.

### `Raw(env: Envelope, data: string)`

Pre-rendered `data` and the `env` to deliver it under. `render()` validates
`data` as in the table above and returns it unchanged.

### `Raw.render(): string!SmtpError`

Validate the data as in the table above and return it unchanged.

### `Raw.envelope(): Envelope`

The `env` the `Raw` was made with, as given.

## Require TLS for onward delivery

Inkwell can require that a notification stays on TLS connections after the relay
accepts it. Set `Envelope.requireTls` on a `Raw` message. The relay must advertise
`REQUIRETLS` over a TLS connection whose certificate was verified.

```bit
import { Client, Message, Raw, SmtpError } from "std/smtp"

// Preserve the rendered notification while requiring TLS on onward hops.
fn requireEncryptedDelivery(c: Client, m: Message): ()!SmtpError {
  let env = m.envelope()
  env.requireTls = true
  c.send(Raw(env, m.render()?))?
}
```

Connect with the normal verification options and issue `ehlo` after `startTls`,
or after `dialTls`. The parameter is the bare word `REQUIRETLS` on `MAIL FROM`;
existing delivery notification parameters remain present. The default false adds
nothing and keeps ordinary sends unchanged.

The request never degrades. These permanent `validate` errors occur before any
`MAIL FROM` byte reaches the relay:

| Error | Action |
|---|---|
| `smtp: REQUIRETLS was requested and the connection is not TLS` | Establish TLS and issue `ehlo` again. |
| `smtp: REQUIRETLS was requested and the server certificate was not verified` | Connect with certificate verification enabled. `insecureSkipVerify` cannot qualify. |
| `smtp: REQUIRETLS was requested and the server does not offer REQUIRETLS` | Choose a relay that advertises the capability after TLS. |

This protects transport between relays. Each relay still sees the message;
use content encryption if relays must not read it. The client connects to the
relay you name and does not discover delivery hosts through MX records.
[The REQUIRETLS standard](https://www.rfc-editor.org/rfc/rfc8689.html#section-2)
defines the relay's onward obligations.

## Delivery status notifications

A mail that cannot be delivered comes back as a bounce, and a sender that wants
more than the server's default asks for it in the envelope (RFC 3461). Inkwell
wants a report for every notification it sends, and wants to match the report to
the notification it belongs to without parsing the body:

```bit
import { Client, Message, Dsn, Notify, Ret, SmtpError } from "std/smtp"

// Ask for a failure or delay report that carries the headers of the original
// message, tagged with the notification id.
fn sendTracked(c: Client, id: int, m: Message): ()!SmtpError {
  m.dsn = Dsn{
    notify = [Notify.Failure, Notify.Delay],
    ret = Ret.Headers,
    envid = "note-${id}",
  }
  c.send(m)?
}
```

With a server that advertised `DSN`, that sends

```text
MAIL FROM:<billing@inkwell.dev> RET=HDRS ENVID=note-7
RCPT TO:<ana@example.net> NOTIFY=FAILURE,DELAY ORCPT=rfc822;ana@example.net
```

`Message.dsn` and `Envelope.dsn` default to `Dsn{}`, which adds no parameter
anywhere. The parameters are sent only when the server's EHLO reply advertised
`DSN`. When the `Dsn` asks for anything and it did not, `send` fails before
`MAIL FROM` with `smtp: delivery notifications were requested and the server
does not offer DSN`, a permanent `SmtpError` with no code: a request for
reports is never quietly dropped. Check `Client.supports("DSN")` first to fall
back instead. A `Raw` carries its `Dsn` in its `Envelope`.

A request also puts `ORCPT` on every `RCPT TO`, using `rfc822` for ASCII
recipients or `utf-8` for international recipients, which names
the recipient as you gave it, so a report can say who it is about even after a
server rewrote the address. Envelope identifiers and ASCII recipient values
use xtext: a byte from 33 to 126 stands for itself except `+` and `=`, and
any other byte is `+` and two upper-case hex digits, so `msg 42` becomes
`msg+2042`. International recipient values keep Unicode bytes and escape
ASCII special characters with unitext. See
[International addresses](smtp/international-addresses.md).

A `Dsn` that contradicts itself is refused before anything is sent, with an
error naming the field: `Never` listed with another value, a value listed
twice, an `envid` with a byte outside printable ASCII, or one longer than 100
characters once encoded.

### `Dsn`

`notify: []Notify`, `ret: Ret` and `envid: string`, each left at its default
(an empty list, `Ret.Default`, `""`) when it is left out of the literal.

### `Notify`

One report to ask for in `Dsn.notify`: `Success`, `Failure`, `Delay` or
`Never`. An empty list sends no `NOTIFY`, and the server reports failures and
delays. `Never` asks for no report at all and is valid only alone. Several
values are combined in the one `NOTIFY` parameter, always in the order
SUCCESS, FAILURE, DELAY, whatever order the list has.

### `Ret`

`RET` of `MAIL FROM`: how much of the message a failure report returns.
`Default` sends none, `Headers` is `RET=HDRS`, `Full` is `RET=FULL`.

### `Message.dsn`

The `Dsn` the message asks for, `Dsn{}` for a new `Message`. `envelope()`
carries it into the `Envelope`.

## Connecting

[Connect and authenticate to a relay](smtp/connecting.md) covers TLS options,
capabilities, authentication, transaction results, and closing a session.

### `Options`

See [the connection guide](smtp/connecting.md#optionsinsecureskipverify-bool--false-servername-string---roots-truststore---timeout-int--30--second).

### `dial`

See [the connection guide](smtp/connecting.md#dialhost-string-port-int-o-options--options-clientsmtperror).

### `dialTls`

See [the connection guide](smtp/connecting.md#dialtlshost-string-port-int-o-options-clientsmtperror).

### `Client`

See [the connection guide](smtp/connecting.md#client).

### `Client.ehlo`

See [the connection guide](smtp/connecting.md#clientehloname-string-smtperror).

### `Client.startTls`

See [the connection guide](smtp/connecting.md#clientstarttlso-options-smtperror).

### `Client.supports`

See [the connection guide](smtp/connecting.md#clientsupportsext-string-bool).

### `Client.maxSize(): int`

After the latest `ehlo`, the server's maximum message size in octets, or `0`
when it offers no readable fixed limit. A bare `SIZE` or `SIZE 0` sets no
limit. STARTTLS discards this value until the required new `ehlo`.

```bit
import { Client, Message, Raw, SmtpError } from "std/smtp"

// Render once so the preflight and the delivery use the same message bytes.
fn submitWithinLimit(c: Client, m: Message): ()!SmtpError {
  let data = m.render()?
  let max = c.maxSize()
  if (max > 0 && len(data) > max) {
    println("The attachment exceeds the relay's ${max}-octet limit.")
    return
  }
  c.send(Raw(m.envelope(), data))?
}
```

`send` enforces the same limit before `MAIL FROM`, failing permanently with
`smtp: message is <n> octets, the server accepts at most <max>`. When `SIZE`
is advertised it adds `SIZE=<n>` to `MAIL FROM`. The count includes headers,
body and CRLF pairs, excluding DATA's extra quoting dots and terminating dot
([RFC 1870 §5](https://www.rfc-editor.org/rfc/rfc1870.html#section-5)).
Malformed or overflowing advertisements supply no usable maximum.

### `Client.limits`

See [the connection guide](smtp/connecting.md#clientlimits-limits).

### `Limits`

See [the connection guide](smtp/connecting.md#limits).

### `Client.isSecure`

See [the connection guide](smtp/connecting.md#clientissecure-bool).

### `Client.authMechanisms`

See [the connection guide](smtp/connecting.md#clientauthmechanisms-string).

### `Client.auth`

See [the connection guide](smtp/connecting.md#clientautha-auth-smtperror).

### `Auth`

See [the connection guide](smtp/connecting.md#auth).

### `Client.send`

See [the connection guide](smtp/connecting.md#clientsendm-sendable-deliverysmtperror).

When the relay advertises `PIPELINING`, send groups `MAIL FROM`, every `RCPT TO`
and `DATA` into one write, reading ordered replies concurrently under one
exchange deadline. All capability and size checks happen first. Rejections
remain per recipient; no accepted recipients means no message payload, with
an empty dot completing an unexpected `354` before reset. Other relays use
the sequential command/reply exchange.

### `Delivery`

See [the connection guide](smtp/connecting.md#delivery).

### `Rejection`

See [the connection guide](smtp/connecting.md#rejection).

### `Client.reset`

See [the connection guide](smtp/connecting.md#clientreset-smtperror).

### `Client.reusable`

See [the connection guide](smtp/connecting.md#clientreusable-bool).

### `Client.noop`

See [the connection guide](smtp/connecting.md#clientnoop-smtperror).

### `Client.quit`

See [the connection guide](smtp/connecting.md#clientquit-smtperror).

### `Client.close`

See [the connection guide](smtp/connecting.md#clientclose).

### `Stream`

See [the connection guide](smtp/connecting.md#stream).

### `SmtpError`

See [the connection guide](smtp/connecting.md#smtperror).

### `SmtpError.transient`

See [the connection guide](smtp/connecting.md#smtperrortransient-bool).

### `SmtpError.message`

See [the connection guide](smtp/connecting.md#smtperrormessage-string).

### `checkEnvelope`

See [envelope validation](smtp/connecting.md#validate-an-envelope-before-queueing-it).
