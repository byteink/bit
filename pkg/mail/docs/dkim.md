# Signing your mail

Inkwell's publish mail goes to thousands of readers, and Gmail, Outlook and
Yahoo now ask who really sent each one. A message that carries no DKIM
signature (RFC 6376) from the domain in its From line lands in spam, or is
refused. Signing by hand means canonicalizing headers and a body, hashing and
signing them, and writing the result into a header that must be exact to the
byte. `Options.dkim` does it for every message, so no call site has to know.

<!-- doctest: per-block -->

## One key, every message

You give the `Mailer` the private key and say where the receiver finds the
public half: `<selector>._domainkey.<domain>` in DNS.

```bit
import { Dkim, Mailer, Message, Options, Outbox } from "mail"
import { contains } from "std/strings"
import { readFile } from "std/fs"

fn main(): ()! {
  let rsa = Dkim{
    domain = "inkwell.dev",
    selector = "2026a",
    key = readFile("/run/secrets/inkwell-dkim-rsa.pem")?,
  }
  let box = Outbox()
  let mailer = Mailer(box, Options{ from = "Inkwell <hello@inkwell.dev>", dkim = [rsa] })?
  mailer.send(
    Message{
      to = ["Sara Ali <sara@example.com>"],
      subject = "Kim published \"Why we left Jira\"",
      text = "Read it at https://inkwell.dev/p/why-we-left-jira",
    },
  )?
  let raw = box.sent()[0].raw
  println("${contains(raw, "s=2026a;")}")
  return
}
```

The key is loaded once, when `Mailer(...)` runs. Every `send` then puts a
`DKIM-Signature` header in front of the message, and `render` returns the same
signed bytes. The private key is PEM, either PKCS#8 (`BEGIN PRIVATE KEY`, what
`openssl genpkey` writes) or PKCS#1 (`BEGIN RSA PRIVATE KEY`), and it must not
be encrypted: a program that can read a passphrase at startup can read the key
the same way. Keep the key in a secret store, never in the source.

The signature is `rsa-sha256` with relaxed canonicalization for headers and
body. It covers `From`, `To`, `Cc`, `Reply-To`, `Subject`, `Date`, `Message-ID`,
`In-Reply-To`, `References`, `MIME-Version`, `Content-Type` and the list headers
(`List-Unsubscribe`, `List-Unsubscribe-Post`, `List-Id`, `Feedback-Id`), and
each one that is present is listed once more than it occurs, so a second From added
on the way breaks the signature instead of showing above the signed one. It
never uses `l=` and never SHA-1 (RFC 8301).

## Both algorithms: RSA first, Ed25519 beside it

Ed25519 keys (RFC 8463) are small and fast, but the large mailbox providers
verify RSA only. A mail signed with Ed25519 alone is, to them, unsigned. So an
Ed25519 key is always a second key, never the only one:

```bit
import { Dkim, Mailer, Options, Outbox } from "mail"

// A throwaway Ed25519 key for this page. Never sign real mail with it.
const edKey: string = "-----BEGIN PRIVATE KEY-----\n" +
  "MC4CAQAwBQYDK2VwBCIEIJPkYoSta14gAdyUGCIf2ZHEHPue9w1gWpVKvaCuw6Jl\n" +
  "-----END PRIVATE KEY-----\n"

fn main(): ()! {
  let ed = Dkim{ domain = "inkwell.dev", selector = "2026e", key = edKey }
  Mailer(Outbox(), Options{ from = "Inkwell <hello@inkwell.dev>", dkim = [ed] }) catch e {
    println(e.message())
    return
  }
  return
}
```

That prints the reason and stops the program where it starts:

```text
mail: configuration: Options.dkim: 2026e._domainkey.inkwell.dev: an Ed25519 DKIM key needs an RSA key beside it: Gmail, Outlook and Yahoo do not verify Ed25519 signatures
```

With an RSA key listed too, each message carries two signatures, the RSA one
first. A receiver that reads only the first signature it understands gets the
one it can verify. The RSA key must have its own selector, and the pair must
share a domain.

## What fails at `open` and at `send`

`Dkim` entries are checked when `Mailer(...)` or `open(...)` runs, because a
wrong key is a mistake in the program, and a program that discovers it on the
first publish mail has already lost that mail. Each is a `MailError.Config`
naming `Options.dkim` and the identity:

* a key that does not load: not PEM, encrypted, not RSA or Ed25519, an RSA key
  under 2048 bits (RFC 8301 allows 1024; Gmail and others stop trusting it), a
  domain or selector that is not a DNS name, a `headers` list without `From`, `List-Unsubscribe` or `List-Unsubscribe-Post`;
* two entries with the same domain and selector, since DNS holds one key under
  one name;
* an Ed25519 key with no RSA key for its domain, above;
* a `d=` that does not align with the domain of `Options.from`: DMARC passes a
  DKIM signature only when its `d=` is the From domain or a parent of it
  (relaxed alignment, RFC 7489). A key for `other.com` signing mail From
  `inkwell.dev` would verify and still fail DMARC;
* a transport that does not deliver the bytes it is given, below.

A message can name its own From, so alignment is checked per message too. Mail
From `news@mail.inkwell.dev` is signed by the key for `inkwell.dev`; mail From
`hi@other.com` is refused with `MailError.Invalid` before anything is
delivered. When `Options.from` is empty, every message is checked this way, and
only the keys that align with that message's From sign it, so one mailer can
sign for several domains.

```bit
import { Dkim, Mailer, Message, Options, Outbox } from "mail"
import { readFile } from "std/fs"

fn main(): ()! {
  let rsa = Dkim{
    domain = "inkwell.dev",
    selector = "2026a",
    key = readFile("/run/secrets/inkwell-dkim-rsa.pem")?,
  }
  let mailer = Mailer(Outbox(), Options{ from = "Inkwell <hello@inkwell.dev>", dkim = [rsa] })?
  mailer.send(
    Message{
      from = "Partner <hi@other.com>",
      to = ["Sara Ali <sara@example.com>"],
      subject = "Hello",
      text = "Hello.",
    },
  ) catch e {
    println(e.message())
    return
  }
  return
}
```

That prints `mail: from: the domain other.com aligns with no Options.dkim domain,
so DMARC would reject the mail`.

## Tuning a key

`Dkim.headers` replaces the list of signed headers (lower case or not; `From`
is required, since DMARC is about From, and so are `List-Unsubscribe` and
`List-Unsubscribe-Post`, which RFC 8058 requires a one-click signature to
cover; see [Unsubscribe](unsubscribe.md)). `Dkim.expire` is the seconds a
signature stays valid; above zero it adds `x=`, so an old copy of a message
cannot be replayed forever.

```bit
import { Dkim } from "mail"

fn digestKey(pem: string): Dkim {
  return Dkim{
    domain = "inkwell.dev",
    selector = "digest",
    key = pem,
    headers = [
      "From",
      "To",
      "Subject",
      "Date",
      "Message-ID",
      "List-Unsubscribe",
      "List-Unsubscribe-Post",
    ],
    expire = 7 * 24 * 3600,
  }
}

fn main() {
  println(digestKey("").selector)
}
```

Rotate a key by publishing the new selector in DNS first, listing the new key
under it, and removing the old entry after the mail signed with it is no longer
in flight.

## Providers that sign for you

Some transports hand a provider the fields of a message and let it build the
mail (a JSON API). The bytes the provider sends are not the bytes this package
signed, so a signature made here would be thrown away or, worse, broken by the
rewrite. `Mailer(...)` refuses the combination:

```text
mail: configuration: Options.dkim: this transport hands the message to a provider that builds it itself and signs with its own DKIM key; configure DKIM with the provider and remove Options.dkim
```

SMTP, `Outbox` and any transport that sends `Delivery.raw` as it is can sign;
`mailgun://` is one, because it posts the finished message
([Sending through Mailgun](mailgun.md)).
Your own transport says which it is with `signs()`: see
[Your own transport](mailer.md#your-own-transport).

## Where to go next

[The Mailer](mailer.md) has `Options`; [Sending for real](open.md) passes
`Options.dkim` to `open` unchanged.
