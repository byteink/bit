# Test the mail your app sends

Inkwell sends a verification link when a writer registers. A test that sends
real mail waits for a server, depends on an account and fills someone's inbox.
Pass the handler a `Mailer` backed by `Outbox` instead. You exercise the same
message checks and rendering without delivering anything.

<!-- doctest: per-block -->

## Check the registration mail

Save this as `registration.test.bit` in your application. The registration
handler receives its mailer, so the test chooses the transport at setup.

<!-- doctest: test-file -->
```bit
import { Mailer, MailError, Message, Options, Outbox } from "mail"
import { contains } from "std/strings"

fn register(mailer: Mailer, email: string, token: string): ()!MailError {
  mailer.send(
    Message{
      to = [email],
      subject = "Welcome to Inkwell",
      text = "Hi Sara. Confirm your address: https://inkwell.dev/verify/${token}",
      headers = { "X-Inkwell-Flow": "registration" },
    },
  )?
}

test "registration sends the writer a verification link" {
  let outbox = Outbox()
  let mailer = Mailer(outbox, Options{ from = "Inkwell <hello@inkwell.dev>" }) catch e {
    panic(e.message())
  }
  defer mailer.close()
  register(mailer, "sara@example.com", "9f2c") catch e {
    panic(e.message())
  }
  let sent = outbox.sent()
  assert(len(sent) == 1)
  let welcome = sent[0]
  assert(welcome.message.subject == "Welcome to Inkwell")
  assert(contains(welcome.message.text, "https://inkwell.dev/verify/9f2c"))
  assert(welcome.receipt.accepted[0] == "sara@example.com")
  assert(contains(welcome.raw, "Subject: Welcome to Inkwell\r\n"))
  assert(contains(welcome.raw, "X-Inkwell-Flow: registration\r\n"))
}
```

Run `bit test .` from the application directory. `sent()` returns the recorded
messages in delivery order. Each entry holds the message, the rendered bytes
and the receipt. Take the list after the handler finishes; it is a copy, so
later sends do not appear in a list you already hold.

A refused message records nothing. Keep a fresh `Outbox` per test so another
test's mail cannot satisfy your assertions. If your application queues mail,
finish the worker's delivery before reading the outbox; a queued receipt alone
does not mean the transport has received it.

## Read mail during development

The running application chooses its mailer from `MAIL_URL`. This complete
program sends the same verification link:

```bit
import { Message, Options, open } from "mail"
import { envOr } from "std/os"

fn main(): ()! {
  let mailer = open(envOr("MAIL_URL", "log://"), Options{ from = "Inkwell <hello@inkwell.dev>" })?
  defer mailer.close()
  mailer.send(
    Message{
      to = ["sara@example.com"],
      subject = "Welcome to Inkwell",
      text = "Hi Sara. Confirm your address: https://inkwell.dev/verify/9f2c",
    },
  )?
  return
}
```

Save it as `main.bit`. Choose one development destination:

```sh
MAIL_URL=log:// bit run main.bit
mkdir -p ./outbox
MAIL_URL=file://./outbox bit run main.bit
```

`log://` prints the headers and text to standard output. `file://./outbox`
writes each rendered message as a separate `.eml` file you can open in a mail
client. Create the directory first; `open` refuses a missing or unwritable
directory. Neither destination sends mail over the network. The messages can
contain verification tokens, so keep the terminal output and files private.

## Snapshot the rendered text

You can also call `Mailer.render` without sending. This snapshot checks the
plain-text body as it appears in the rendered message:

<!-- doctest: test-file -->
```bit
import { Mailer, Message, Options, Outbox } from "mail"
import { split } from "std/strings"

test "the verification text stays readable" {
  let outbox = Outbox()
  let mailer = Mailer(outbox, Options{ from = "Inkwell <hello@inkwell.dev>" }) catch e {
    panic(e.message())
  }
  defer mailer.close()
  let raw = mailer.render(
    Message{
      to = ["sara@example.com"],
      subject = "Welcome to Inkwell",
      text = "Hi Sara. Confirm your address: https://inkwell.dev/verify/9f2c",
      id = "welcome-sara",
    },
  ) catch e {
    panic(e.message())
  }
  let parts = split(raw, "\r\n\r\n")
  assert(len(parts) == 2)
  assert(parts[1] == "Hi Sara. Confirm your address: https://inkwell.dev/verify/9f2c\r\n")
  assert(len(outbox.sent()) == 0)
}
```

`render` still validates the message. A whole-message snapshot must account for
the `Date` header, which follows the clock. Set `Message.id` to keep Message-ID
stable; an unset id gets a fresh value on each render. Signed messages also
have signatures that change with those headers. For HTML, attachments or
invites, inspect the separate MIME parts instead of this simple body split.

## Inspect SMTP delivery in Mailpit

Use a local catcher when you want to exercise SMTP and look at the result in
a browser. Run [Mailpit](https://mailpit.axllent.org/docs/install/docker/) in
Docker with its SMTP and web ports bound to your laptop:

```sh
docker run --rm --name inkwell-mailpit \
  -p 127.0.0.1:1025:1025 -p 127.0.0.1:8025:8025 \
  axllent/mailpit:v1.31.4
```

In another terminal, run the development program against it:

```sh
MAIL_URL='smtp://localhost:1025?tls=off' bit run main.bit
```

Open [the local inbox](http://localhost:8025). Read the text, HTML, raw headers
and attachments. Mailpit captures mail instead of forwarding it; keep relay
and forwarding options unset. Stop the Docker command when you finish; this
temporary container does not preserve your inbox.

The default Mailpit server offers no STARTTLS. `smtp://` requires STARTTLS
unless you explicitly set `tls=off`, so the plain SMTP catcher needs that
query parameter. A URL containing credentials with `tls=off` is refused at
setup: a password is never sent over a connection without TLS. Use this form
only for your local catcher, without a username or password.

For Inkwell's digest, inspect the unsubscribe information and the raw
`List-Unsubscribe` and `List-Unsubscribe-Post` headers. Mailpit displays parsed
unsubscribe links and syntax errors, including the one-click POST header; this
does not test that your unsubscribe endpoint handles the request. See
[Unsubscribe](unsubscribe.md) for the message fields to set.

Mailpit's [HTML check](https://mailpit.axllent.org/docs/usage/html-check/)
estimates HTML and CSS support in email clients. Use its warnings to find
compatibility problems, then check the clients your readers use. It does not
validate HTML or prove an unsubscribe endpoint works.

## Keep staging mail away from customers

A staging copy of Inkwell can contain real subscriber addresses. Set
`Options.redirect` on its mailer so every delivery goes to your test mailbox:

```bit
import { Message, Options, open } from "mail"
import { envOr } from "std/os"

fn main(): ()! {
  let stagingOptions = Options{
    from = "Inkwell <hello@inkwell.dev>",
    redirect = "QA <qa@inkwell.dev>",
  }
  let mailer = open(envOr("MAIL_URL", "log://"), stagingOptions)?
  defer mailer.close()
  let receipt = mailer.send(
    Message{
      to = ["sara@example.com"],
      subject = "Welcome to Inkwell",
      text = "Hi Sara. Confirm your address: https://inkwell.dev/verify/9f2c",
    },
  )?
  assert(receipt.accepted[0] == "qa@inkwell.dev")
  return
}
```

The envelope contains only the redirect address, including when the message
names Cc or Bcc recipients. The subject starts with `[redirected]`, and
`X-Original-To` records the original To and Cc addresses. Bcc appears in no
header. Keep this option in staging setup; leave it unset in production.
Read [Staging mail](redirect.md) for queues and provider transports.

Next: [Sending for real](open.md) to choose the production URL and TLS setup,
then [Checking the setup at boot](verify.md) to check it before the first send.
