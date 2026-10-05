# Sending for real

Inkwell's tests send through an `Outbox`. In production the same `Mailer` has to
reach a real server: Postmark, Amazon SES, a company relay. You should not need
a different type for that, and the server's address and password should live in
one string in the environment, not scattered through the code. `open` builds a
`Mailer` from that string.

<!-- doctest: per-block -->

## One URL, one mailer

```bit
import { Message, Options, open } from "mail"
import { envOr } from "std/os"

fn main(): ()! {
  let url = envOr("MAIL_URL", "smtps://hello%40inkwell.dev:app-password@smtp.example.com")
  let mailer = open(url, Options{ from = "Inkwell <hello@inkwell.dev>" })?
  mailer.send(
    Message{
      to = ["Sara Ali <sara@example.com>"],
      subject = "Welcome to Inkwell",
      text = "Hello Sara. Write your first note at https://inkwell.dev/new",
    },
  )?
  mailer.close()
  return
}
```

`open(url, opts)` returns the same `Mailer` as `Mailer(Outbox(), opts)`, so
everything in [The Mailer](mailer.md) applies: the defaults in `Options`, the
checks before a send, `MailError`. Only the transport differs. `open` connects
to nothing; the first `send` does. Sessions are kept and reused, up to
`Options.pool` of them, and `close` ends them with `QUIT`; see
[Reusing connections](pool.md).

A user name that is an address has an `@` in it, which a URL spells `%40`. User
name and password are percent-decoded, so a password with `@`, `/` or `:` in it
is written `%40`, `%2F`, `%3A`.

## The URL forms, and why TLS cannot be turned off

| URL | What happens |
|---|---|
| `smtps://user:pass@host` | TLS from the first byte, port 465 (RFC 8314) |
| `smtp://user:pass@host` | port 587; STARTTLS (RFC 3207), required |
| `smtp://host:1025?tls=off` | no TLS, no login: for a server on your own machine |
| `resend://key@default` | Resend's HTTPS API instead of SMTP: see [Sending through Resend](resend.md) |
| `postmark://token@default` | Postmark's HTTPS API instead of SMTP: see [Sending through Postmark](postmark.md) |
| `sendgrid://key@default` | SendGrid's HTTPS API instead of SMTP, `@eu` for its EU host: see [Sending through SendGrid](sendgrid.md) |
| `mailgun://key:domain@default` | Mailgun's HTTPS API instead of SMTP, `@eu` for its EU region: see [Sending through Mailgun](mailgun.md) |

TLS is not a setting you can lose. With `smtp://` the connection is upgraded
with STARTTLS before any password is sent, and a server that does not offer
STARTTLS fails the send instead of getting the password in the clear:

```text
mail: configuration: smtp://user:***@mail.example.com:587 does not offer STARTTLS; for a local test server use smtp://mail.example.com:587?tls=off
```

There is no "use TLS if the server has it" mode, under any name: a program that
quietly sends in plaintext when someone strips STARTTLS from the conversation
has no encryption at all. `tls=off` is the one way to a cleartext session and
`open` refuses it together with a user name, so a password cannot be sent over
it:

```bit
import { MailError, open } from "mail"

fn main(): ()! {
  open("smtp://hello:app-password@localhost:1025?tls=off") catch e {
    match (e) {
      Config(why) => println(why)
      _ => println("other: ${e.message()}")
    }
  }
  return
}
```

That prints `smtp://hello:***@localhost:1025 carries credentials with tls=off; a
password is never sent over a connection that is not TLS`. Use it with a local
catcher such as Mailpit, which takes mail without a login.

## A relay with its own certificate authority

An internal relay is often signed by the company's own CA. Name the file with
its certificate; only the roots in that file are trusted, and it is read when
you call `open`:

```bit
import { open } from "mail"

fn main(): ()! {
  let mailer = open(
    "smtps://relay:app-password@mail.corp.example?caFile=/etc/ssl/corp-ca.pem&serverName=mail.corp.example",
  )?
  mailer.close()
  return
}
```

* **`serverName=x`** is the name the certificate must be issued for, when it
  differs from the host you connect to (an address, say).
* **`caFile=/path/ca.pem`** trusts the certificates in that file instead of the
  system's. A missing file, or one with no certificate in it, fails `open`.
* **`insecureSkipVerify=true`** turns certificate checking off. It is the only
  way to; a connection made this way proves nothing about who answered, so keep
  it to a lab. It is not needed for a private CA: use `caFile`.
* **`tls=off`** is above.

## Every mistake fails at `open`

A URL is configuration, so a wrong one stops the program where it starts. Each
of these is a `MailError.Config` that names what is wrong: an empty URL, an
unknown scheme (`imap://`), no host, a port outside 1 to 65535, a path, any
query parameter not listed above, the same parameter twice, a bad percent
escape, a missing `caFile`.

The password is never in an error, a `Receipt` or the text of the transport. A
message names the URL as `smtp://user:***@mail.example.com:587`, and a server
that repeats the password in its reply has it hidden too.

## What a send reports

The server's answers become the `MailError` variants from
[The Mailer](mailer.md):

| The server says | You get |
|---|---|
| 535, 534 or 530 | `Auth` |
| a 4xx, or no answer at all (refused, reset, timed out) | `Transient` |
| a message or all recipients refused for good (5xx) | `Rejected` |
| the server offers no `AUTH PLAIN` or `AUTH LOGIN` | `Config`, naming what it does offer |

When some recipients are refused and others taken, the send succeeds and the
`Receipt` says which is which: `accepted` and `rejected` (each with the server's
reply). `providerId` is the server's answer to the end of the message, for
example `2.0.0 Ok: queued as 4Bx1`, the only handle a relay gives to look the
mail up later.

The login is `AUTH PLAIN` when the server offers it, else `AUTH LOGIN`. The name
the client announces in `EHLO` is the domain of `Options.from` when you set it,
else `localhost`.

## Where to go next

The [Mailer](mailer.md) chapter has `Options` and the errors; [Messages](messages.md)
has what a message may hold.
