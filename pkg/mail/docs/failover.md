# A second route for the mail

Inkwell sends its welcome mail through one provider. On the day that provider
has an outage, nobody can sign up and confirm their address, and the retry loop
from [Retries and pace](retry.md) only asks the same dead server again.
`Options.fallback` names a second server. When the first one says "not now", the
mail goes to the second, and the `Receipt` tells you which one took it.

<!-- doctest: per-block -->

## The fallback

```bit
import { Message, Options, open } from "mail"
import { envOr } from "std/os"

fn main(): ()! {
  let mailer = open(
    envOr("MAIL_URL", "smtps://hello%40inkwell.dev:app-password@smtp.example.com"),
    Options{
      from = "Inkwell <hello@inkwell.dev>",
      fallback = [envOr("MAIL_URL_2", "resend://re_inkwell_key@default")],
    },
  )?
  let r = mailer.send(
    Message{
      to = ["Sara Ali <sara@example.com>"],
      subject = "Welcome to Inkwell",
      text = "Hello Sara. Write your first note at https://inkwell.dev/new",
    },
  )?
  println("${r.accepted[0]} through ${r.transport}")
  mailer.close()
  return
}
```

With the first server up, this prints `sara@example.com through
smtps://***@smtp.example.com`. With it down, the same program prints
`sara@example.com through resend://***@default`. `Receipt.transport` is the URL
of the transport that delivered, with the user name, password or API key
replaced by `***` and the query dropped, so it is safe to log. It is empty when
`open` was given one URL.

Each entry of `fallback` is read by the rules of `open`'s own URL, all of them
at `open`, so a typo in the second URL stops the program at startup and not on
the night the first server fails. A refusal names the entry:
`Options.fallback[0]: unknown URL scheme 'imap'`. Entries may be any scheme
`open` takes, an SMTP relay behind an API provider and the other way round.

## What moves to the next one

Only `MailError.Transient` does: the server's "not now", a 4xx, or a connection
that could not be made. Nothing was taken, so the mail can go elsewhere.
Everything else comes back as it is:

| The first transport ends | The mail |
|---|---|
| `Transient` | goes to the next transport |
| `Rejected`, `Invalid`, `Config` | is returned: a second provider would refuse it for the same reason |
| `Auth` | is returned: the login for that server is wrong, and it is for you to fix |
| `Unknown` | is returned: the request was sent and the answer never came, so the mail may already be delivered, and trying another transport could send it twice |

Laravel's `failover` mailer and Symfony's `failover://` and `roundrobin://`
transports go to the next transport on any transport exception, an `Unknown`
included, and so can deliver one mail twice. Here that choice stays with you:
check the provider's activity log, or send again knowing it can arrive twice.

The order is the list's: the first URL given to `open`, then `fallback` in the
order written. If the last transport tried fails, you get its error. A mailer
that has `Options.retry` repeats the whole list, so with the default three tries
a mail is offered to every server three times before a send fails.

## The cool-down

A transport that failed with `Transient` is skipped for 15 seconds, so a
provider that is down is not asked first by every mail, one timeout each. After
the 15 seconds it is tried first again. If every transport is cooling down at
once, they are all tried, in order, as if none were.

## Sharing the load

```bit
import { Options, open } from "mail"

fn main(): ()! {
  let mailer = open(
    "smtps://hello%40inkwell.dev:app-password@smtp.example.com",
    Options{
      from = "Inkwell <hello@inkwell.dev>",
      fallback = ["resend://re_inkwell_key@default", "postmark://pm_inkwell_token@default"],
      spread = true,
    },
  )?
  mailer.close()
  return
}
```

With `spread = true` each mail starts at the next transport in turn: the first
mail at the SMTP relay, the second at Resend, the third at Postmark, the fourth
at the relay again. A failure still moves on in list order from where the mail
started, and the cool-down applies. The turn is one atomic counter, so any
number of tasks sending at once share the rotation evenly, and nothing is
allocated for it per send. `spread` without `fallback` fails at `open`.

## DKIM

`Options.dkim` signs the bytes the transport sends, so every listed transport
must send them unchanged. A transport that builds the message itself, like
`resend://`, cannot, and `open` fails naming the one that cannot:
`Options.dkim: resend://***@default hands the message to a provider that builds
it itself`. Use `mailgun://` or SMTP for every entry, or sign with the provider
and drop `Options.dkim`; see [Signing your mail](dkim.md).

## Setup mistakes

These fail in `open` as `MailError.Config`:

* an empty entry in `fallback`, such as an environment variable that is not set:
  `Options.fallback[0] is empty`;
* a URL in `fallback` that `open` would refuse, named by its index;
* `spread` with an empty `fallback`;
* `Options.dkim` with a transport that cannot carry the signature.

`Mailer(transport, options)` takes the one transport you give it and refuses
`fallback` and `spread`: only `open` builds the list.

```bit
import { Options, open } from "mail"

fn main(): ()! {
  open("log://", Options{ fallback = [""] }) catch e {
    println(e.message())
    return
  }
  return
}
```

That prints `mail: configuration: Options.fallback[0] is empty`.
