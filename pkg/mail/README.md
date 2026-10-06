# pkg/mail

Email for Bit programs, from a sign-up form to a business sending millions. You
build one `Mailer` from one URL, hand it a `Message`, and it checks the message,
writes it in the format mail servers expect, signs it, retries what a server only
postponed, and sends it over SMTP or a provider's API. The same code runs against
a printed mail on your laptop and a real server in production.

## Install

`bit add bitlang.org/pkg/mail@v0.1.0` writes:

```json
{
  "dependencies": {
    "mail": "bitlang.org/pkg/mail@v0.1.0"
  }
}
```

## Usage

```bit
import { Message, Options, open } from "mail"
import { env } from "std/os"

fn main(): ()! {
  let mailer = open(env("MAIL_URL"), Options{ from = "Inkwell <hello@inkwell.dev>" })?
  mailer.send(
    Message{
      to = ["Sara Ali <sara@example.com>"],
      subject = "Welcome to Inkwell",
      text = "Hi Sara. Write your first note at https://inkwell.dev/new",
    },
  )?
  mailer.close()
  return
}
```

With `MAIL_URL=log://` this prints the mail to standard output and sends
nothing. Point the same variable at a server and the program does not change.

| `MAIL_URL` | What it does |
|---|---|
| `log://` | prints each mail; for your laptop |
| `file://./outbox` | writes each mail as an `.eml` file you can open in a mail client |
| `smtps://user:pass@host` | SMTP over TLS; `smtp://` uses STARTTLS, which is never optional |
| `resend://key@default` | Resend's API |
| `postmark://token@default` | Postmark's API |
| `sendgrid://key@default` | SendGrid's API |
| `mailgun://key:domain@default` | Mailgun's API |

A mistake in the message or the setup is a `MailError` that names the field, and
a setup mistake stops the program at `open`, not at the first customer.

## Where to read next

Start with [Send a welcome email](docs/getting-started.md): one mail, from
`log://` on your machine to a provider URL, DKIM and a boot-time check in
production. The rest, in the order a program meets them:

- What you send: [Messages](docs/messages.md), [Addresses](docs/addresses.md),
  [Attachments](docs/attachments.md), [Calendar invites](docs/invites.md),
  [Unsubscribe](docs/unsubscribe.md).
- How it leaves: [The Mailer](docs/mailer.md) and its `Outbox` for tests,
  [Sending for real](docs/open.md), and one chapter per provider
  ([Resend](docs/resend.md), [Postmark](docs/postmark.md),
  [SendGrid](docs/sendgrid.md), [Mailgun](docs/mailgun.md)).
- Going live: [Signing your mail](docs/dkim.md),
  [Checking the setup at boot](docs/verify.md),
  [Staging mail](docs/redirect.md), [Reusing connections](docs/pool.md).
- Staying up: [Retries and pace](docs/retry.md),
  [A second route](docs/failover.md), [Watching the mail](docs/observe.md),
  [Webhooks](docs/webhooks.md) for bounces and complaints.

The [documentation index](docs/README.md) lists every chapter.

For how first-party packages in this repository are laid out, gated,
versioned and released, see [`pkg/README.md`](../README.md).
