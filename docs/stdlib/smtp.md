# std/smtp

An ESMTP submission client: the layer a service needs to put a password reset,
a verification link, an invoice or an alert into a relay. Built on
[`std/net`](net.md) and [`std/tls`](tls.md).

Sending only. There is no IMAP, no POP3 and no server here.

<!-- doctest: per-block -->

## The session

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

## When a server goes quiet

A relay that accepts a connection and then says nothing must not hold a sender
forever, so every step is bounded by `Options.timeout`: the connect (and, for
`dialTls`, the TLS handshake with it), the greeting, each command with its
reply, and a DATA payload with the reply to it. Each exchange starts a fresh
clock; the total of a session is not capped, and a slow server that answers each
step inside the limit is not interrupted.

```bit
import { dial, Options, Client, Message, SmtpError } from "std/smtp"
import { Second } from "std/time"

// Give a slow relay a minute per step rather than the default 30 seconds.
fn dialPatient(host: string): Client!SmtpError {
  return dial(host, 587, Options(timeout = 60 * Second))?
}

// A step that ran out of time fails with a message naming it, and the
// connection is already closed.
fn sendOnce(c: Client, m: Message): bool {
  c.send(m) catch e {
    return e.command == "MAIL FROM" && e.transient()
  }
  return true
}
```

A step that runs out of time fails with an `SmtpError` whose `command` names it
and whose message reads `smtp: EHLO timed out after 200ms`. It has no reply code
and `transient()` is true, since a later attempt may meet a peer that answers.
The connection is closed at that moment and never reused: a late answer to the
abandoned command would otherwise be read as the answer to the next one, so any
further call on that `Client` fails with `smtp: the connection was closed after a
timeout; dial again`, and the next attempt dials afresh. A `timeout` that is zero
or negative is a caller's bug and fails before anything connects, with `smtp:
Options.timeout must be positive, got 0`.

The default is 30 seconds. RFC 5321 section 4.5.3.2 tells a client to wait 5
minutes for the greeting, `MAIL` and `RCPT`, 2 minutes for the reply to `DATA`,
3 minutes per DATA block and 10 minutes for the reply after the final dot,
figures meant for an unattended relay draining a queue to a distant host. A
sender behind a request, a pool or a retry loop cannot park a worker that long
on a silent peer, so the default is shorter than every one of them. A caller that
relays slowly, or sends a large message over a slow link (the payload and its
reply share one clock), raises `timeout`; passing the RFC's `10 * Minute`
restores the longest of its figures for every step.

## What this module refuses to do

Four rules are structural - enforced by the code that would otherwise break
them, not by documentation:

| Rule | Where |
|---|---|
| A CR, LF or NUL in a header value is **rejected**, never stripped | every value, on the way in |
| `AUTH` never runs on a connection that is not TLS | `auth` |
| The server certificate is verified | `Options.insecureSkipVerify` is the only opt-out |
| No message line reaches 998 octets, no command line 12288 | folding, encoding, and a final check |

Header injection is the reason for the first. A newline in a supplied subject,
recipient or display name lets the caller close the header it was given and open
one of its own - a `Bcc` to an address the sender never approved is the classic
payload. The value is refused rather than rewritten, and the whole message is
rendered and validated before `MAIL FROM` is sent, so a rejected value costs
zero transmitted bytes.

The second has no opt-out at all. A downgrade that silently puts a password on a
cleartext wire is worse than not sending the mail, so `AUTH` fails on a
connection that is neither implicit TLS nor post-`STARTTLS` - and it fails
before the command is built, so not even a username is transmitted.

The fourth is a property of the data rather than a flag. A text part is sent
one of three ways, chosen from its own bytes:

- `7bit` when it can be: printable ASCII (tab and line breaks aside), every line
  inside the limit with room for the DATA dot-stuffing octet.
- Otherwise quoted-printable (RFC 2045 section 6.7) when that is no larger than
  base64: `=XX` for a byte outside printable ASCII and for `=` itself, a trailing
  space or tab escaped, lines cut at 76 columns with a soft break that never
  lands inside a UTF-8 character. A mostly-English mail with one curly quote
  stays readable in its raw form, and a 1200-character line is cut into legal
  lines.
- Otherwise base64 wrapped at 76 columns: text that is mostly non-ASCII, such as
  an Arabic or Chinese paragraph, costs three characters per byte in
  quoted-printable and about 1.3 in base64.

The same text always takes the same path, and a bare LF or CR in it becomes CRLF
on all three. A header value that cannot be folded at whitespace inside the
limit becomes RFC 2047 encoded words, one per line.

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
[What this module refuses to do](#what-this-module-refuses-to-do).

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
throughout, dot-stuffing NOT applied (that belongs to the transmission, not to
the message). The headers are, in order, `Date`, `From`, `To`, `Cc`, `Reply-To`, `Subject`,
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
`to: []string` is every `RCPT TO` addr-spec, at least one.

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

## Connecting

### `Options(insecureSkipVerify: bool = false, serverName: string = "", roots: TrustStore = ..., timeout: int = 30 * Second)`

How a TLS leg is set up. `Options()` is secure by default: verification on,
system trust anchors, SNI taken from the dialed host. Each argument loosens or
pins one thing, so the call site says exactly what it changed:

```bit
import { dial, dialTls, Options, Client } from "std/smtp"

// The relay's certificate names the provider, not the host we dial through.
fn viaPinnedName(host: string): Client! {
  return dialTls(host, 465, Options(serverName = "smtp.mail.example.com"))?
}

// A local test server with a throwaway certificate: the one place to opt out.
fn viaLabServer(port: int): Client! {
  return dialTls("127.0.0.1", port, Options(insecureSkipVerify = true))?
}
```

| Field | Meaning |
|---|---|
| `insecureSkipVerify` | skip chain **and** hostname verification |
| `serverName` | SNI and the name the certificate must match; empty means the dialed host |
| `roots` | trust anchors; empty means the OS store, bundled roots as fallback |
| `timeout` | nanoseconds each step may take; must be positive; default 30 seconds |

Setting `insecureSkipVerify` true means the connection proves nothing about who
the peer is, and a credential sent over one is a credential given to whoever
answered. It is for tests and pinned lab servers.

### `dial(host: string, port: int, o: Options = Options()): Client!SmtpError`

Connect to a cleartext submission port (587, or 25 for a relay) and read the
greeting. The session is not secure yet: `startTls` makes it so, and until it
does, `auth` refuses to run. The connect, the greeting and
every later step are bounded by `o.timeout`; nothing else in `o` is read, since
no TLS happens here. See "When a server goes quiet".

### `dialTls(host: string, port: int, o: Options): Client!SmtpError`

Connect to an implicit-TLS submission port (465): the handshake happens before
the greeting, so there is no cleartext phase and no `startTls`. The connect and
the handshake share one `o.timeout`; the greeting and each later step get a
fresh one.

### `Client`

One SMTP session.

### `Client.ehlo(name: string): ()!SmtpError`

Send `EHLO name` and record the capabilities it returns. `name` is the client's
own domain and goes on the command line unquoted, so it must be printable ASCII
with no spaces. Must be re-issued after `startTls`.

### `Client.startTls(o: Options): ()!SmtpError`

Upgrade a cleartext connection to TLS (RFC 3207). Fails when the server did not
advertise `STARTTLS`, and fails when the server has sent bytes that would sit in
the read buffer across the handshake - the plaintext command-injection shape
(CVE-2011-0411), which is refused rather than quietly discarded. Call `ehlo`
again afterwards. The handshake is bounded by `o.timeout`: `startTls` takes its
own budget from the `Options` it is given, and refuses one that is not positive.

### `Client.supports(ext: string): bool`

Whether the server advertised `ext` in its last EHLO reply, matched
case-insensitively against the first word of each capability line, so
`supports("AUTH")` answers for `AUTH PLAIN LOGIN`.

### `Client.isSecure(): bool`

Whether this connection is TLS - an implicit-TLS dial, or a completed
`startTls`.

### `Client.auth(a: Auth): ()!SmtpError`

Authenticate with the mechanism `a` selects. Before a credential byte exists
this checks, in order: the connection is TLS (refused outright otherwise, with
no opt-out, so not even a username is transmitted), neither credential carries a
CR, LF or NUL (a token or an OAuth username also no 0x01), `ehlo` has run, and the server's `AUTH` capability lists the
mechanism (RFC 4954 section 3, matched case-insensitively, `AUTH=` spelling
included). A mechanism the server does not list fails with `smtp: the server
does not offer AUTH <MECH>` and sends nothing. An error never repeats a
credential.

```bit
import { Auth, Client, SmtpError } from "std/smtp"

// A relay that offers only `AUTH LOGIN`.
fn loginOnly(c: Client): ()!SmtpError {
  c.auth(Auth.Login("mustafa", "hunter2"))?
}
```

### `Auth`

The credentials `auth` takes. The variant is the mechanism; new mechanisms are
new variants, never new methods.

| Variant | Mechanism |
|---|---|
| `Auth.Plain(user, pass)` | SASL PLAIN (RFC 4616): one initial response, `\0user\0pass` in base64 |
| `Auth.Login(user, pass)` | SASL LOGIN: the username and the password as two base64 challenge responses |
| `Auth.Xoauth2(user, token)` | XOAUTH2: an OAuth2 access token, `user=<user>\x01auth=Bearer <token>\x01\x01` in base64 |
| `Auth.OauthBearer(user, token)` | OAUTHBEARER (RFC 7628): the same token with a GS2 header and the dialed host and port |

#### OAuth2 tokens

Google Workspace and Exchange Online no longer take a password over SMTP; they
take an OAuth2 access token, which the caller obtains and refreshes. `auth`
sends it, once, and does nothing else with it.

| Provider | Variant |
|---|---|
| Gmail and Google Workspace (`smtp.gmail.com`) | `Auth.Xoauth2` or `Auth.OauthBearer`; the server's `AUTH` line lists both |
| Microsoft 365 and Exchange Online (`smtp.office365.com`) | `Auth.Xoauth2` only |

```bit
import { Auth, Client, SmtpError } from "std/smtp"

// `token` is a current access token with the scope the provider requires.
fn gmail(c: Client, user: string, token: string): ()!SmtpError {
  c.auth(Auth.Xoauth2(user, token))?
}

fn gmailBearer(c: Client, user: string, token: string): ()!SmtpError {
  c.auth(Auth.OauthBearer(user, token))?
}
```

A token or username carrying CR, LF, NUL or 0x01 is refused before anything is
sent. When the server rejects the token it first sends a `334` reply holding a
base64 JSON error (an expired token, a missing scope). `auth` answers it as RFC
7628 section 3.2.3 asks, an empty line for XOAUTH2 and a single 0x01 for
OAUTHBEARER, and fails with the server's final reply as an `SmtpError` whose
`text` starts with the JSON's `status` and `scope`, for example `OAuth
status=401 scope=https://mail.google.com/: Username and Password not accepted`.
`command` is `AUTH XOAUTH2` or `AUTH OAUTHBEARER`. The token is in no error
text. An `AUTH` command line may be up to 12288 octets (RFC 4954 section 4), so
an Exchange Online token of over 1500 characters goes out in one line.

### `Client.send(m: Sendable): Delivery!SmtpError`

Render and send `m`, a `Message` or a [`Raw`](#raw-env-envelope-data-string):
`MAIL FROM`, one `RCPT TO` per envelope recipient, `DATA`, the dot-stuffed
payload, and the terminating dot. The message and the envelope are checked
first, so a CR in a subject, a malformed address or an over-long line fails with
`MAIL FROM` never sent.

Every recipient is offered. One the server refuses is recorded in the
[`Delivery`](#delivery), and the rest still get the message (RFC 5321 section
3.3: `DATA` proceeds when at least one `RCPT TO` was accepted). When the server
refuses all of them, no `DATA` is sent: the call sends `RSET` and fails with the
last refusal, whose `text` ends with `(refused: ` and every refused address.

A refused `MAIL FROM` or `DATA` also sends `RSET` before failing, so the same
`Client` can send the next message. Nothing is reset after a failure with no
reply (the connection broke or timed out), after a `421` (the server is closing
the channel), or after the reply to the payload, which ends the transaction
whatever it says: a `451` there leaves the session ready for the next `send`.

### `Delivery`

What `send` did with the recipients of one message. It is returned only when at
least one was accepted.

| Field | Meaning |
|---|---|
| `accepted` | the recipients the server took, in envelope order |
| `rejected` | the recipients it refused, in envelope order, as `Rejection`s |
| `queueId` | the server's reply to the end of `DATA` with its code taken off, such as `2.0.0 Ok: queued as 4Bx1` |

### `Rejection`

One recipient the server refused: `address`, and `error`, the `SmtpError` with
the reply's `code`, `enhanced` status and `text`, and `command` `RCPT TO`.
`error.transient()` tells a mailbox that is busy (4xx) from one that does not
exist (5xx).

### `Client.quit(): ()!SmtpError`

End the session politely: `QUIT`, then close the socket. The socket is closed
even when the reply is not a 221 - the alternative is leaking a descriptor over
a server's bad manners.

### `Client.close()`

Close the connection without a `QUIT`. Idempotent.

### `Stream`

The transport under a session: `send`, `recv`, `deadline` (arm the limit every
later `send` and `recv` obeys), `timedOut` (whether the last `recv` came back
empty because that limit passed) and `shut`. It exists so the rest
of the module never asks whether it is talking cleartext or TLS - `startTls`
swaps one implementation for another inside a live `Client`, and the flag that
guards `AUTH` is written by that same swap, so there is no state for it to
disagree with. A caller has no reason to implement it.

### `SmtpError`

Why a step failed, and the one type every fallible call here fails with.

| Field | Meaning |
|---|---|
| `code` | the reply code the server answered with; 0 when no reply was involved (network, TLS, a malformed reply, a local refusal) |
| `enhanced` | the RFC 3463 status the server sent (`5.1.1`, RFC 2034), or `""` when it sent none |
| `text` | the server's text joined by a space with the enhanced status taken off, or the local reason when `code` is 0 |
| `cause` | the `std/net` or `std/tls` error under a transport failure, nil otherwise; a failed TLS handshake is a `std/tls` `HandshakeError` |
| `command` | the step that failed (for a timeout, the step that ran out of time): `connect`, `greeting`, `EHLO`, `STARTTLS`, `AUTH PLAIN`, `AUTH LOGIN`, `AUTH XOAUTH2`, `AUTH OAUTHBEARER`, `AUTH LOGIN username`, `AUTH LOGIN password`, `MAIL FROM`, `RCPT TO`, `DATA`, `end of DATA`, `QUIT`, or `validate` for a local refusal |

### `SmtpError.transient(): bool`

True when sending again later can succeed: a 4xx reply, or a failure with no
reply that is not a local `validate` refusal and not a TLS handshake refused on
verification or negotiation. See "When a send fails".

### `SmtpError.message(): string`

The failure as one line, in the module's wording: `smtp: <command> got <code>:
<enhanced> <text>` for a reply, `smtp: <reason>` without one.
