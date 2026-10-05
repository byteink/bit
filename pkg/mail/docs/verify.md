# Checking the setup at boot

Inkwell's welcome mail worked on the developer's laptop and has been silent
since Friday's deploy. Nothing failed: the app password was rotated and the
production secret was not, and the same deploy moved the DKIM key to a new
selector that nobody published in DNS. Mail from a wrong password is not sent;
mail signed with a key DNS does not know goes to spam. The first report is a
customer asking where the confirmation link is.

`Mailer.verify` is the one call that finds this before the customer does. It
sends no mail. Put it in the program's boot, or behind a health endpoint:

<!-- doctest: per-block -->

```bit
import { Dkim, Message, Options, open } from "mail"
import { envOr } from "std/os"
import { readFile } from "std/fs"

fn main(): ()! {
  let mailer = open(
    envOr("MAIL_URL", "smtps://hello%40inkwell.dev:app-password@smtp.example.com"),
    Options{
      from = "Inkwell <hello@inkwell.dev>",
      dkim = [
        Dkim{
          domain = "inkwell.dev",
          selector = "2026r",
          key = readFile("/run/secrets/inkwell-dkim-rsa.pem")?,
        },
      ],
    },
  )?
  mailer.verify()?
  println("mail is ready")
  mailer.close()
  return
}
```

With everything in place this prints `mail is ready`. After Friday's deploy it
fails at startup instead, with every problem in one error, one line each:

```text
mail: configuration: verify found 2 problems:
  smtps://***@smtp.example.com: login refused: 535 5.7.8 Authentication failed
  2026r._domainkey.inkwell.dev: no TXT record is published; publish this TXT value: v=DKIM1; k=rsa; p=MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8A...
```

`verify` does not stop at the first problem, so the operator fixes the password
and publishes the record in one deploy and not in two. The failure is a
`MailError.Config`, the same variant a wrong `Options` raises, so a program that
already treats `Config` as "do not start" needs nothing else. A secret never
appears in a line: the transport is named by its URL with the user name,
password or API key replaced by `***`, and a server's own text is scrubbed of
the secret before it is shown.

## What each transport does

`verify` asks every transport to prove itself, with a `check` method that sends
no message.

| Transport | `check` |
|---|---|
| `smtps://`, `smtp://` | connects, negotiates TLS, says EHLO, logs in, QUIT, on a session of its own |
| `resend://` | `GET /domains` with the API key; a key that may only send mail, which Resend answers 401 `restricted_api_key`, counts as working |
| `postmark://` | `GET /server` with the server token |
| `sendgrid://` | `GET /v3/scopes` with the API key |
| `mailgun://` | `GET /v4/domains/<domain>` with the API key, for the sending domain in the URL |
| `log://`, `file://`, `Outbox` | nothing to connect to, always ready |
| a `Failover` from `Options.fallback` | every listed transport, each reported by its own URL |

The answers map to the errors a send would give: a refused login or key is
`login refused`, a provider that is down or unreachable is `temporary failure`,
and anything else is `rejected`. Mailgun's read needs a key that may read the
domain, so a key that can only send mail, which Mailgun calls a domain sending
key, is refused here although it sends fine; use the account's API key in the
URL, or leave `verify` off that deployment. Mailgun answers 404 for a domain
that is not in the region the URL names, so a domain kept in the EU region and a
`mailgun://...@default` URL are caught here too.

## The DKIM records

For each `Dkim` in `Options.dkim`, `verify` reads the TXT record at
`<selector>._domainkey.<domain>` and compares it with the key that signs. It
reads the record as RFC 6376 section 3.6.1 does: a list of `name=value` tags
separated by `;`, with the strings of one TXT record joined and white space
inside `p=` ignored, so a long RSA key that DNS tools cut into several 255 byte
strings, or folded over lines, still matches. The key it expects is the public
half of the private key in `Dkim.key`: the SubjectPublicKeyInfo for RSA, the 32
raw bytes for Ed25519, both as base64 in `p=`.

Each of these fails with its own line:

| What DNS holds | The line says |
|---|---|
| nothing at that name | `no TXT record is published` |
| more than one record | `2 TXT records are published and a verifier may read any of them; publish exactly one` |
| `p=` empty | `the key is revoked: p= is empty` |
| no `p=` | `the record has no p= tag` |
| another `k=`, or none for an Ed25519 key | `k=rsa but the configured key is ed25519` |
| `v=` other than `DKIM1` | `v=DKIM2 where DKIM1 is required` |
| a `p=` that is not this key | `p= is a different key than the one Options.dkim signs with` |
| a lookup that fails | `the DNS lookup failed: ...` |

Every line about a key that is wrong ends with `publish this TXT value:` and
the exact record, `v=DKIM1; k=rsa; p=...`, to paste into the DNS panel. A
lookup that fails (a timeout) is not a statement about the key, so that line
carries no value.

## Checking at runtime

A health endpoint calls `verify` on an interval, not per request: each call
connects to the server and asks DNS. Every failure comes back as one `Config`
whose text is the report, so the endpoint answers 503 with it:

```bit
import { Mailer } from "mail"

fn mailHealth(mailer: Mailer): (int, string) {
  mailer.verify() catch e {
    return (503, e.message())
  }
  return (200, "mail is ready")
}
```

## Your own transport

A class passed to `Mailer(...)` needs a `check(): ()!MailError` beside
`deliver`, `signs` and `close`. Return an error from the step that proves it
works, such as a login or a cheap authenticated read, and nothing when there is
nothing to prove, as `Outbox` does. See [The Mailer](mailer.md).

## Where to go next

[Signing your mail](dkim.md) is where the keys and selectors come from, and
[A second route](failover.md) is the list `verify` goes through. The URLs and
what each server answers are in [Sending for real](open.md).
