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
import { dial, newOptions, newMessage, Address, Client, Message } from "std/smtp"

// Submit `m` through a relay on the cleartext submission port, upgrading to TLS
// before the credential is sent. `startTls` verifies the server's certificate
// against the system trust anchors; the second `ehlo` is required by RFC 3207,
// because the capability list offered in cleartext is not authenticated.
fn submit(host: string, user: string, pass: string, m: Message): ()! {
  let c = dial(host, 587)?
  defer c.close()
  c.ehlo("client.example.com")?
  c.startTls(newOptions())?
  c.ehlo("client.example.com")?
  c.authPlain(user, pass)?
  c.send(m)?
  c.quit()?
}
```

Port 465 is implicit TLS: `dialTls` instead, and no `startTls`.

## What this module refuses to do

Four rules are structural - enforced by the code that would otherwise break
them, not by documentation:

| Rule | Where |
|---|---|
| A CR, LF or NUL in a header value is **rejected**, never stripped | every value, on the way in |
| `AUTH` never runs on a connection that is not TLS | `authPlain`, `authLogin` |
| The server certificate is verified | `Options.insecureSkipVerify` is the only opt-out |
| No transmitted line reaches 998 octets | folding, encoding, and a final check |

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

The fourth is a property of the data rather than a flag. A part is sent `7bit`
only when its own bytes prove it can be: printable ASCII, and every line inside
the limit with room for the DATA dot-stuffing octet. Anything else - a non-ASCII
byte, a 1200-character line - becomes base64 wrapped at 76 columns. A header
value that cannot be folded at whitespace inside the limit becomes RFC 2047
encoded words, one per line.

## Addresses and messages

A message is built, then rendered once. Nothing is validated at the setters and
everything is validated at `render()`, so a message assembled from several
places has one failure point with the whole message in view.

```bit
import { newMessage, newAttachment, Address } from "std/smtp"

// A two-part message with an attachment: text, an HTML alternative, and a file.
// The body comes out `multipart/mixed` wrapping a `multipart/alternative`.
fn invoice(pdf: []byte): string! {
  let m = newMessage(Address{ name: "Billing", email: "billing@example.com" })
  m.addTo(Address{ name: "", email: "customer@example.net" })
  m.setSubject("Your invoice")
  m.setText("The invoice is attached.\n")
  m.setHtml("<p>The invoice is attached.</p>\n")
  m.attach(newAttachment("invoice.pdf", "application/pdf", pdf))
  return m.render()?
}
```

The body shape follows what the message carries, with no empty wrappers:

| Content | Body |
|---|---|
| text only | `text/plain` |
| text + HTML | `multipart/alternative` |
| text (+ HTML) + attachments | `multipart/mixed` |

### `Address`

A mailbox: `name` is the optional display name, `email` the addr-spec the
envelope carries. `email` is validated before use - exactly one `@`, a non-empty
local part, a well-formed domain, and inside RFC 5321's 64/254 octet ceilings -
and `name` is a header value, rejected for CR/LF/NUL like any other. A name that
is not printable ASCII, or that carries a quote or a backslash, is sent as an
RFC 2047 encoded word rather than a quoted string.

### `Attachment`

A file to attach: `filename`, `contentType` (empty means
`application/octet-stream`) and `data`, the raw bytes. Attachments are always
base64 - an attachment is opaque bytes, and choosing an encoding from a sample
of them is how a binary file arrives corrupted.

### `newAttachment(filename: string, contentType: string, data: []byte): Attachment`

An attachment of `data` named `filename`, typed `contentType`.

### `Message`

One outgoing mail. Build it with `newMessage` and the setters below; nothing
reaches the network until `Client.send`.

### `newMessage(sender: Address): Message`

A fresh message from `sender`, with no recipients, subject or body.

### `Message.addTo(a: Address)`

Add a `To:` recipient. Also an envelope recipient: this module has no concept of
a header recipient that is not delivered to.

### `Message.addCc(a: Address)`

Add a `Cc:` recipient, delivered to like a `To:`.

### `Message.setSubject(s: string)`

Set the `Subject:` header. Rejected at `render()` if it carries a CR, LF or NUL;
folded, or encoded as RFC 2047 words, if it is long or not printable ASCII.

### `Message.setText(s: string)`

Set the plain-text body. Always present in the rendered message: a mail with only
an HTML part is unreadable to a text-only client.

### `Message.setHtml(s: string)`

Set the HTML alternative. Sent alongside the text part inside a
`multipart/alternative`, never instead of it.

### `Message.attach(a: Attachment)`

Attach `a`. The message becomes `multipart/mixed` at render time.

### `Message.setBoundary(b: string)`

Override the MIME boundary. Exists so a test can assert an exact body; the
default is random (UUIDv4), which is what a boundary must be - one derived from
the content is one an attacker who controls a part can reproduce and embed.
Rejected at `render()` unless it is a legal RFC 2046 boundary.

### `Message.recipients(): []Address`

Every address this message is delivered to, `To:` then `Cc:`, in the order
added - the envelope `RCPT TO` list.

### `Message.render(): string!`

The complete RFC 5322 message: headers, a blank line, and the body, CRLF
throughout, dot-stuffing NOT applied (that belongs to the transmission, not to
the message). Fails on a header value carrying a CR, LF or NUL, on a malformed
envelope address, on an illegal explicit boundary, or if any line would exceed
the octet limit.

## Connecting

### `Options`

How a TLS leg is set up. The zero value verifies, so a bare `Options{}` is as
safe as `newOptions()`.

| Field | Meaning |
|---|---|
| `insecureSkipVerify` | skip chain **and** hostname verification |
| `serverName` | SNI and the name the certificate must match; empty means the dialed host |
| `roots` | trust anchors; empty means the OS store, bundled roots as fallback |

Setting `insecureSkipVerify` true means the connection proves nothing about who
the peer is, and a credential sent over one is a credential given to whoever
answered. It is for tests and pinned lab servers.

### `newOptions(): Options`

Secure-by-default TLS options: verification on, system trust anchors, SNI taken
from the dialed host.

### `dial(host: string, port: int): Client!`

Connect to a cleartext submission port (587, or 25 for a relay) and read the
greeting. The session is not secure yet: `startTls` makes it so, and until it
does, `authPlain` and `authLogin` refuse to run.

### `dialTls(host: string, port: int, o: Options): Client!`

Connect to an implicit-TLS submission port (465): the handshake happens before
the greeting, so there is no cleartext phase and no `startTls`.

### `Client`

One SMTP session.

### `Client.ehlo(name: string): ()!`

Send `EHLO name` and record the capabilities it returns. `name` is the client's
own domain and goes on the command line unquoted, so it must be printable ASCII
with no spaces. Must be re-issued after `startTls`.

### `Client.startTls(o: Options): ()!`

Upgrade a cleartext connection to TLS (RFC 3207). Fails when the server did not
advertise `STARTTLS`, and fails when the server has sent bytes that would sit in
the read buffer across the handshake - the plaintext command-injection shape
(CVE-2011-0411), which is refused rather than quietly discarded. Call `ehlo`
again afterwards.

### `Client.supports(ext: string): bool`

Whether the server advertised `ext` in its last EHLO reply, matched
case-insensitively against the first word of each capability line, so
`supports("AUTH")` answers for `AUTH PLAIN LOGIN`.

### `Client.isSecure(): bool`

Whether this connection is TLS - an implicit-TLS dial, or a completed
`startTls`.

### `Client.authPlain(user: string, pass: string): ()!`

Authenticate with SASL PLAIN (RFC 4616). Refused, before the command is built,
on a connection that is not TLS.

### `Client.authLogin(user: string, pass: string): ()!`

Authenticate with SASL LOGIN - username and password as two base64 challenge
responses. Same refusal on a non-TLS connection, and it fires before the
`AUTH LOGIN` command, so not even the username is transmitted.

### `Client.send(m: Message): ()!`

Render, validate and send `m`: `MAIL FROM`, one `RCPT TO` per recipient, `DATA`,
the dot-stuffed payload, and the terminating dot. The message is rendered and
checked first, so a CR in a subject or a malformed recipient fails with
`MAIL FROM` never sent.

### `Client.quit(): ()!`

End the session politely: `QUIT`, then close the socket. The socket is closed
even when the reply is not a 221 - the alternative is leaking a descriptor over
a server's bad manners.

### `Client.close()`

Close the connection without a `QUIT`. Idempotent.

### `Stream`

The transport under a session: `send`, `recv` and `shut`. It exists so the rest
of the module never asks whether it is talking cleartext or TLS - `startTls`
swaps one implementation for another inside a live `Client`, and the flag that
guards `AUTH` is written by that same swap, so there is no state for it to
disagree with. A caller has no reason to implement it.
