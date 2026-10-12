<!-- doctest: per-block -->

# Send mail to international addresses

An Inkwell author can have a mailbox such as `josé@example.com`. Encoding
their display name is not enough: the mailbox itself must reach the relay
unchanged. `Message` preserves that address and `Client.send` checks the
relay's current capabilities before sending a transaction.

## Send the author's notification

This program submits one notification over verified TLS. Replace the relay
and mailbox addresses with yours, then run it against a relay that accepts
your sender. Add authentication to the session when your relay requires it.

```bit
import { Address, Message, dialTls } from "std/smtp"

fn main(): ()! {
  let message = Message(Address{ name = "Inkwell", email = "notes@example.com" })
  message.addTo(Address{ name = "José", email = "josé@example.com" })
  message.setSubject("Your draft is ready")
  message.setText("Open Inkwell to review your draft.")

  let client = dialTls("smtp.example.com", 465)?
  defer client.close()
  client.ehlo("inkwell.example.com")?
  client.send(message)?
  client.quit()?
}
```

The display name is encoded for mail readers; the `josé@example.com`
addr-spec stays in the `To` header and `RCPT TO` command. The same rule
applies to the sender, Cc, Bcc and Reply-To. Bcc remains absent from headers.
A Unicode sender domain also stays in the generated Message-ID.

`send` adds `SMTPUTF8 BODY=8BITMIME` to `MAIL FROM` when an envelope address
or rendered header contains a non-ASCII byte. Both capabilities must be
advertised, even if the body contains only ASCII. Existing SIZE, delivery
notification and onward TLS options continue to describe the same message.

## Submit already signed bytes

Use `Raw` when you already have a complete message, including its signature.
It sends the original bytes after checking their line endings and limits;
it does not encode or normalize the headers or body.

```bit
import { Client, Envelope, Raw } from "std/smtp"

fn submitSigned(client: Client, signed: string): ()! {
  let envelope = Envelope{
    from = "notes@example.com",
    to = ["josé@example.com"],
  }
  client.send(Raw(envelope, signed))?
}
```

Only the header block must be valid UTF-8. A Raw body with arbitrary
eight-bit bytes requires `8BITMIME` and adds `BODY=8BITMIME`; it does not
require `SMTPUTF8` unless the envelope or headers also need it. A normal
Message encodes its non-ASCII body, so ASCII mailboxes and headers need
neither extension just because their text contains an accented character.

## Handle a local refusal

When SMTPUTF8 is missing, the error is
`smtp: the message needs SMTPUTF8, which the server does not offer`.
When 8BITMIME is missing, it is
`smtp: the message has 8-bit data and the server does not offer 8BITMIME`.
Both have `command` equal to `"validate"` and are permanent. No MAIL, RCPT
or DATA command is sent, and the connection remains reusable for another
message that the relay can carry. Choose a relay supporting the required
extensions instead of silently changing the recipient.

Addresses must be valid UTF-8 with exactly one `@`. Control bytes and command
delimiters remain forbidden. The local part is limited to 64 octets and the
whole address to 254 octets; these count bytes, not characters. Raw headers
with malformed UTF-8 fail locally too, while arbitrary eight-bit body bytes
remain valid.

The module never converts a Unicode domain into an ASCII domain. If your
application performs DNS lookup on that domain, perform the required IDNA
conversion for DNS separately. Use ASCII addresses with a seven-bit body
when you need a relay that offers neither extension.

Continue with [SMTP sessions](../smtp.md) for authentication, delivery
notifications and connection reuse.
