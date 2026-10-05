# Reusing connections

Inkwell's Monday digest goes to ten thousand subscribers. Sent one connection
per mail, that is ten thousand TCP handshakes, ten thousand TLS handshakes and
ten thousand logins, and most of the run is spent on them. Some providers count
logins and answer 421 or 454 when a program makes too many. An SMTP session is
built to carry many mails one after another, so `open` keeps the logged-in
sessions and lends them out. `Options.pool` says how many it may hold.

<!-- doctest: per-block -->

## A digest on four sessions

```bit
import { Message, Options, open } from "mail"
import { envOr } from "std/os"

fn main(): ()! {
  let url = envOr("MAIL_URL", "smtps://hello%40inkwell.dev:app-password@smtp.example.com")
  let mailer = open(url, Options{ from = "Inkwell <hello@inkwell.dev>", pool = 4 })?
  let n = 0
  while (n < 10000) {
    mailer.send(
      Message{
        to = ["reader${n}@example.com"],
        subject = "Inkwell digest",
        text = "This week on https://inkwell.dev",
      },
    )?
    n = n + 1
  }
  mailer.close()
  return
}
```

Sent from one task, this logs in once and sends all ten thousand on that one
session. `pool` is the most sessions open at once, 4 by default, so tasks that
send together each get one, up to four, and a fifth waits for one to come back.
`1` keeps a single session and sends one mail at a time. Nothing is connected
until the first `send`, and a pool never holds more sockets than `pool`.

`mailer.close()` ends every idle session with `QUIT`. After it a `send` fails
`MailError.Invalid` reading `mailer is closed`.

## When all the sessions are busy

A send that finds every session in use waits for one, never longer than
`Options.timeout`. Then it fails with `MailError.Transient` and the text
`all 4 SMTP sessions busy`, and `Options.retry` repeats it like any other
temporary failure:

```bit
import { MailError, Message, Options, open } from "mail"
import { Second } from "std/time"

fn main(): ()! {
  let mailer = open(
    "smtp://127.0.0.1:1025?tls=off",
    Options{ from = "Inkwell <hello@inkwell.dev>", pool = 1, timeout = 5 * Second },
  )?
  mailer.send(Message{ to = ["sara@example.com"], subject = "Hi", text = "Hello." }) catch e {
    match (e) {
      Transient(r) => println("try again later: ${r.toString()}")
      _ => println("failed: ${e.message()}")
    }
  }
  mailer.close()
  return
}
```

## What keeps a session healthy

A server may close a connection that sits idle, and a long-lived session meets
every limit a server has. The pool deals with each so a send does not see it:

* A session unused for 30 seconds gets a `NOOP` before it is lent. If the
  server does not answer, the session is dropped and the send gets another, new
  one.
* A session whose send the server refused (a 550 for a recipient, a 452 for a
  full queue) is kept only if it answers `RSET` afterwards. A timeout, a
  dropped connection or a 421 drops it.
* A session ends after 5 minutes, and after the number of mails the server
  allows. A server that advertises `LIMITS MAILMAX=1000` (RFC 9422) gets a new
  session after 1000 mails; one that says nothing gets one after 100. A retired
  session is closed with `QUIT`.
* A mail with more recipients than the server's `RCPTMAX` goes in several
  transactions on one session, and one `Receipt` lists everyone: 5 recipients
  against `RCPTMAX=2` is three transactions and five entries in `accepted`. If
  a later transaction fails after an earlier one took the mail, the recipients
  it did not reach are in `rejected` with the server's reply, so the mail is
  not sent again to those that already have it.

A send that finds its pooled session dead is repeated once on a new session, but
only if the server cannot have the mail yet, that is, the connection broke
before the end of the message. A connection that breaks after the message was
sent, before the server's answer, is reported as `MailError.Transient` and is
not repeated here: the server may or may not have queued it, and the retry from
`Options.retry` is the choice to risk a duplicate rather than lose the mail.

## Setup mistakes

`pool` below 1 or above 100 fails in `Mailer(...)` and `open(...)` as
`MailError.Config`, before the first mail:

```bit
import { Mailer, Options, Outbox } from "mail"

fn main(): ()! {
  Mailer(Outbox(), Options{ pool = 0 }) catch e {
    println(e.message())
    return
  }
  return
}
```

That prints `mail: configuration: Options.pool must be 1 to 100 sessions, got 0`.
A transport that is not SMTP, such as `Outbox`, ignores `pool`.
