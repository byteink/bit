# Send a welcome email after registration

A new author should receive a welcome message without waiting for your mail
relay before their registration request can finish. First build the message
with the SMTP client, then let Inkwell's existing background worker send it.

## Try the message against a development relay

Use a development SMTP relay you already run on `127.0.0.1:1025`. Save this
complete program as `welcome.bit`, then run `bit run welcome.bit`:

```bit
import { Address, Message, Options, dial } from "std/smtp"
import { Second } from "std/time"

fn main(): ()! {
  let message = Message(Address{ name = "Inkwell", email = "welcome@example.test" })
  message.addTo(Address{ name = "", email = "author@example.test" })
  message.setSubject("Welcome to Inkwell")
  message.setText("Welcome to Inkwell, new-author!\n")

  let client = dial("127.0.0.1", 1025, Options(timeout = 5 * Second))?
  defer client.close()
  client.ehlo("inkwell")?
  client.send(message)?
  client.quit()?
}
```

The relay should show one plain-text message with subject `Welcome to Inkwell`.
`Address` separates the display name from the email address. `Message` holds the
sender, recipient, subject and text; `send` submits it over the connection.
`?` returns connection, protocol and delivery errors to the caller. The deferred
`close` also releases the connection when an earlier operation fails.

This small program uses the same SMTP operations as the finished app's
[`sendWelcome`](inkwell/mail.bit). It deliberately connects only to an explicit
loopback relay. Do not use a cleartext connection for a remote relay. See
[SMTP](../../../docs/stdlib/smtp.md) for the complete client API.

## Configure the finished app

Run the existing [Inkwell application](inkwell/README.md), rather than adding
SMTP work to the HTTP handler. Set its database, Redis, session and token
settings as described in [Run the finished app](README.md#run-the-finished-app).
With those services and your development relay already running:

```sh
cd pkg/web/guides/inkwell
export SMTP_HOST=127.0.0.1
export SMTP_PORT=1025
export SMTP_FROM=welcome@example.test
export VERIFY_EMAIL_URL=http://localhost:8080/confirm
bit migrate
bit run main.bit
```

[`loadConfig`](inkwell/config.bit) reads these settings once at startup.
`SMTP_HOST` and `SMTP_FROM` both default to empty, disabling welcome mail.
Set both to enable it. A partial configuration fails startup with
`inkwell: SMTP_HOST, SMTP_PORT and SMTP_FROM must configure a mail relay`.
`SMTP_PORT` defaults to `465` and must be between `1` and `65535`.

The current app includes a verification link in new welcome messages, so mail
also requires a trusted `VERIFY_EMAIL_URL`. Supply your own confirmation page
at that URL. It must use HTTPS, except for an HTTP localhost or loopback page,
and must contain no query, fragment or credentials. A page opened by a mail
scanner must not change account state. The finished app's
[email verification instructions](inkwell/README.md#send-a-welcome-email-after-registration)
explain the separate confirmation request. Token handling is outside this
chapter.

### Use verified TLS for a remote relay

For deployment, set `SMTP_HOST` to your relay's actual host, `SMTP_PORT` to its
implicit-TLS port, and `SMTP_FROM` to an address it permits. Inkwell's
`mailConnection` makes the transport choice explicitly:

```text
  let opts = MailOptions(timeout = 5 * Second)
  if (cfg.smtpHost == "127.0.0.1" || cfg.smtpHost == "::1") {
    return dialMail(cfg.smtpHost, cfg.smtpPort, opts)?
  }
  return dialMailTls(cfg.smtpHost, cfg.smtpPort, opts)?
```

This is an excerpt from [mail.bit](inkwell/mail.bit), after its configuration
validation. Only the exact strings `127.0.0.1` and `::1` select cleartext.
`localhost` is not an alias for that exception: it follows the TLS path.
Remote connections verify the relay's TLS certificate. Each connection or protocol step gets
a fresh five-second timeout, rather than one deadline for the whole send.
Errors still propagate instead of being treated as a successful send. The application does not configure SMTP credentials or
STARTTLS submission. Use a relay compatible with this connection policy rather
than disabling certificate verification.

## Enqueue after the account is saved

The app's [`register`](inkwell/auth.bit) handler validates the submitted address
when mail is enabled. It saves the account and verification data in one
PostgreSQL transaction. Only after that transaction commits does it enqueue
this job in Redis:

```text
  jobs.enqueue(
    SendWelcomeEmail{
      email = saved.email,
      username = saved.username,
      verificationLink = Option.Some(link),
    },
  )?
```

The recipient and username come from the saved account. The queue payload
contains the data needed to deliver its welcome message; it does not carry an
HTTP request or an open database connection.

[`openMailQueue`](inkwell/jobs.bit) uses the existing jobs package's `RedisStore`
and `RedisLocker` under `{inkwell:jobs}` and registers `SendWelcomeEmail` with
`deliverWelcome`. That handler calls `sendWelcome`. The latter builds the
message, opens its SMTP connection with `mailConnection`, sends it and closes
the connection. A delivery failure reaches the jobs queue as
`inkwell: welcome email delivery failed`; the wrapper avoids exposing a usable
link through a relay's error message.

The application's [entry point](inkwell/main.bit) starts the queue before
listening for HTTP requests:

```text
  let jobs = openDigestQueue(db, redis, cfg)?
  jobs.start()
  defer jobs.stop()
  app.listen()?
```

`openDigestQueue` includes the mail handler and the app's nightly digest.
Running `main.bit` matters: constructing the HTTP app alone does not start its
background worker. The [jobs package](../../jobs/README.md) explains queue
configuration and delivery policies.

## Register an author and inspect the relay

In another terminal, submit a new account to the finished app's real route:

```sh
curl --fail-with-body http://127.0.0.1:8080/v1/auth/register \
  -H 'Content-Type: application/json' \
  -d '{"username":"new-author","email":"author@example.test","password":"development-password"}'
```

A successful registration returns `201` with a `Location` header for the saved
user. It means the account was saved and its welcome job was enqueued, not
that the recipient has received mail. With the worker running, inspect the
development relay for the subject, recipient and welcome text. If the relay
is unavailable, inspect the worker's delivery error and the queue's retry or
dead-letter state rather than expecting the HTTP request to wait for SMTP.

PostgreSQL and Redis cannot share this transaction. If enqueueing fails, the
request returns an error even though the account and verification data may
already exist. Retrying the same registration can return a conflict. This
example provides neither a transactional outbox nor exactly-once mail.
Queue delivery can repeat a send. Redis durability determines whether pending
jobs survive a Redis restart; restrict access to its jobs and backups because
the welcome payload contains a usable verification link.

Use this path for Inkwell's welcome message when the existing queue and relay
policy fit your deployment. A service requiring SMTP authentication, STARTTLS
or stronger delivery guarantees needs a separately designed delivery path.

Previous: [Keep cover bytes in object storage](21-object-storage.md).
Continue with the existing [nightly article digest](25-scheduled-jobs.md), or
return to [Build an API with Bit](README.md).
