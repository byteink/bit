# Deliver mail reliably in production

Inkwell's welcome message works on a laptop. After deployment, some readers
find it in spam and others never receive it. A successful inline `send` means
a transport accepted the message, not that it reached an inbox. You need a
verified sending identity, bounded delivery, and a record of failures.

Start with the same welcome message in a local transport:

<!-- doctest: per-block -->
<!-- doctest: deps jobs postgres -->

```bit
import { Message, Options, open } from "mail"

fn main(): ()! {
  let mailer = open("log://", Options{ from = "Inkwell <hello@inkwell.dev>" })?
  defer mailer.close()
  let receipt = mailer.send(
    Message{
      to = ["sara@example.com"], subject = "Welcome to Inkwell",
      text = "Your first note starts at https://inkwell.dev/new",
      id = "welcome-sara-1",
    },
  )?
  println(receipt.id)
}
```

This writes mail locally. Keep this message as you replace the transport;
do not test production credentials by sending to arbitrary addresses.

## Give the domain a verifiable identity

SPF authorizes the servers that send for your envelope sender's domain.
DKIM signs the message with a key whose public half is in DNS. DMARC checks
whether a passing SPF or DKIM identity aligns with the visible From domain
and publishes your policy for failures. These checks complement each other.
[Gmail's sender requirements](https://support.google.com/mail/answer/81126?hl=en)
explain the authentication and alignment requirements, including stricter
rules for bulk senders. Authentication helps delivery; it does not guarantee it.

Publish one SPF TXT record for each sending domain. Use your providers'
documented mechanisms, combine all authorized senders in that one record,
and do not invent a second SPF record for a fallback provider. At
`_dmarc.inkwell.dev`, a starting monitoring policy can look like this:

```text
v=DMARC1; p=none; rua=mailto:dmarc@inkwell.dev; adkim=r; aspf=r
```

Create the reporting mailbox first. `p=none` requests reports, not rejection
of impersonated mail. Review legitimate senders and their alignment before
moving to `quarantine` or `reject`.

For SMTP that carries your own signatures, generate private keys in a
private directory. These commands create unencrypted keys for the mailer to
load; protect them with your secret store and file permissions:

```sh
umask 077
mkdir -m 700 inkwell-mail-keys
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out inkwell-mail-keys/rsa.pem
openssl genpkey -algorithm ED25519 -out inkwell-mail-keys/ed25519.pem
```

[OpenSSL's key-generation manual](https://docs.openssl.org/master/man1/openssl-genpkey/)
documents both algorithms. Deploy the files as secrets, not application
source. Use a different selector for each key and rotate by publishing the
new selector before changing the signer.

## Refuse a broken deployment at boot

Replace `log://` with your configured `smtps://` relay or a `smtp://` relay
that negotiates verified STARTTLS. Percent-encode credentials in a URL.
Read the URL and key paths from your deployment's secret configuration:

```bit
import { Dkim, Message, Options, open } from "mail"
import { readFile } from "std/fs"
import { env } from "std/os"
import { Dsn, Notify, Ret } from "std/smtp"
import { Second } from "std/time"

fn main(): ()! {
  let mailer = open(
    env("MAIL_URL"),
    Options{
      from = "Inkwell <hello@inkwell.dev>", replyTo = "support@inkwell.dev",
      bounce = "bounce@inkwell.dev", timeout = 30 * Second,
      dkim = [
        Dkim{
          domain = "inkwell.dev",
          selector = "welcome-rsa",
          key = readFile(env("MAIL_RSA_KEY_FILE"))?,
        },
        Dkim{
          domain = "inkwell.dev",
          selector = "welcome-ed",
          key = readFile(env("MAIL_ED_KEY_FILE"))?,
        },
      ],
    },
  )?
  defer mailer.close()
  mailer.verify()?
  mailer.send(
    Message{
      to = ["sara@example.com"], subject = "Welcome to Inkwell",
      text = "Your first note starts at https://inkwell.dev/new", id = "welcome-sara-1",
      dsn = Dsn{ notify = [Notify.Failure], ret = Ret.Headers, envid = "welcome-sara-1" },
    },
  )?
}
```

`Dsn`, `Notify` and `Ret` describe an SMTP delivery-status request. Your
relay must offer DSN; a permanent capability refusal is not retried.
The bounce address changes the envelope sender, not the visible From, and
must have exactly the same normalized DNS domain as From.

For the keys above, publish TXT records at
`welcome-rsa._domainkey.inkwell.dev` and
`welcome-ed._domainkey.inkwell.dev`. The RSA record uses
`v=DKIM1; k=rsa; p=...`; Ed25519 uses `v=DKIM1; k=ed25519; p=...`.
Replace `...` with the public key, never the private PEM. `verify()` reports
the exact public TXT value to publish when a record is missing or wrong:

```text
mail: configuration: verify found 2 problems:
  smtps://***@smtp.example.com: login refused: 535 5.7.8 Authentication failed
  welcome-rsa._domainkey.inkwell.dev: no TXT record is published; publish this TXT value: v=DKIM1; k=rsa; p=...
```

It checks every configured transport and DKIM key without sending mail.
Treat its `Config` error as a failed readiness check. It does not validate
SPF or DMARC, predict inbox placement, or prove Graph mailbox permissions.
An Ed25519 key alone is refused; this package requires an RSA key of at least
2048 bits beside it. [Signing your mail](dkim.md) explains alignment and
[Checking the setup at boot](verify.md) lists each searchable failure.

## Bound a burst and decide what may repeat

Reuse one mailer across requests. `pool` bounds SMTP sessions, not messages
waiting in your application. Ten thousand welcome messages reuse those
sessions instead of logging in ten thousand times. SMTP `LIMITS` can retire
a session at MAILMAX or split recipients at RCPTMAX; they do not enlarge
your provider's sending allowance.

```bit
import { Options, Retry, open } from "mail"
import { env } from "std/os"
import { Second } from "std/time"

fn main(): ()! {
  let mailer = open(
    env("MAIL_URL"),
    Options{
      from = "Inkwell <hello@inkwell.dev>", pool = 4, rate = 20,
      timeout = 30 * Second,
      retry = Retry{ attempts = 3, base = Second, max = 10 * Second },
    },
  )?
  defer mailer.close()
  mailer.verify()?
}
```

Choose `rate` below your account's allowance; the example's value is a local
cap, not a provider recommendation. It is shared by sends through this
mailer, not across replicas. A busy pool or exhausted rate budget waits no
longer than `timeout`, then returns `Transient`.

Only `Transient` repeats. `Retry.attempts` includes the first attempt;
backoff uses full jitter and honors `Reply.retryAfter` within `Retry.max`.
`Rejected`, `Auth`, `Invalid` and `Config` return without a retry.
`Unknown` means the request may already have been delivered. Check the
provider's activity log before repeating it; a stable `Message.id` is not
a universal de-duplication guarantee.

SMTP can report a lost final acknowledgement as `Transient`; a retry can
then deliver a duplicate. Its Message-ID does not make the server idempotent.

Add a second compatible route without weakening that distinction:

```bit
import { Options, open } from "mail"
import { env } from "std/os"

fn main(): ()! {
  let mailer = open(
    env("MAIL_URL"),
    Options{
      from = "Inkwell <hello@inkwell.dev>",
      fallback = [env("MAIL_FALLBACK_URL")], spread = true, requireTls = true,
    },
  )?
  defer mailer.close()
  mailer.verify()?
}
```

Use two SMTP routes that support REQUIRETLS for this example. STARTTLS
secures the connection to the relay; `requireTls` additionally requests TLS
for onward SMTP delivery. A relay that lacks REQUIRETLS fails `Rejected`
before MAIL. Do not replace this with `tls=off` in production.

Only `Transient` moves to a fallback. `Unknown` never does. A failing route
has a 15-second cooldown; `spread` rotates the starting route and requires
a fallback list. Every route must support your envelope requirements and,
when configured, your own DKIM signing. See [A second route](failover.md).

## Put durable work behind the request

Inline sending keeps the reader waiting for the provider. Give the signup
handler and the worker the same durable jobs store. This example combines
the queue with the metrics, tracing and structured logs you will use to
operate it:

```bit
import { Message, Options, Retry, open as openMailer } from "mail"
import { Options as QueueOptions, SqlStore, open as openQueue } from "jobs"
import { adapter } from "postgres"
import { stdout } from "std/io"
import { JsonHandler, LevelInfo, Logger } from "std/log"
import { Registry } from "std/metrics"
import { env } from "std/os"
import { Datasource, pool } from "std/sql"
import { Tracer } from "std/trace"

fn main(): ()! {
  let db = pool(adapter(), Datasource{ uri = env("DATABASE_URL") })?
  defer db.close()
  let queue = openQueue(SqlStore(db)?, QueueOptions{ workers = 2 })?
  let metrics = Registry(100)
  let tracer = Tracer(env("OTLP_TRACES_URL"), "inkwell", 1.0)
  defer tracer.shutdown()
  let logger = Logger(JsonHandler(stdout(), LevelInfo, false))
  let mailer = openMailer(
    env("MAIL_URL"),
    Options{
      from = "Inkwell <hello@inkwell.dev>", queue = Option.Some(queue),
      retry = Retry{ attempts = 3 }, rate = 20,
      metrics = Option.Some(metrics), tracer = Option.Some(tracer), logger = Option.Some(logger),
    },
  )?
  defer mailer.close()
  mailer.verify()?
  let receipt = mailer.send(
    Message{
      to = ["sara@example.com"], subject = "Welcome to Inkwell",
      text = "Your first note starts at https://inkwell.dev/new", id = "welcome-sara-1",
    },
  )?
  println("queued=${receipt.queued} id=${receipt.id}")
}
```

This producer writes the rendered mail to the store; it does not run a worker.
A separate worker opens the same store and builds the same mailer, then
calls `queue.run()`. Its shutdown handler calls `queue.stop()` to drain before
closing the mailer and database. Do not report delivery from `Receipt.queued`:
it reports a durable enqueue, with no accepted recipients yet.

Jobs retry `Transient`; permanent and ambiguous failures go to the dead-letter
list. With `Options.queue`, set only `Retry.attempts`: nondefault `base` or
`max` is a configuration error because jobs owns backoff. Delivery is
at least once. Keep a stable message id for the business event, but only a
provider that implements an idempotency key can use it to suppress duplicate
requests. SMTP Message-ID alone does not promise exactly-once delivery.
Secure and retain the queue store as you would the mail itself.

Export `metrics.exposition()` from your metrics endpoint. Watch
`mail_sent_total` by transport and result, `mail_recipients_rejected_total`,
`mail_retries_total` and `mail_send_seconds`. The retry counter counts inline
mail retries, not jobs' retries. Trace `mail.send` and its `mail.deliver`
attempts; keep the logger free of application secrets too. Use a separate
`Registry` for each mailer. [Watching the mail](observe.md) gives labels and
[Sending in the background](queue.md) gives the complete worker lifecycle.

## Choose a transport with the guarantees you need

Credentials below are URL-shape labels. Store real values as secrets and
percent-encode them. Provider acceptance is not an inbox-delivery receipt.

| Transport URL | Own `Options.dkim` | `Message.tags` |
|---|---|---|
| `smtps://USER:PASSWORD@HOST:465` | yes | no provider-specific API mapping |
| `smtp://USER:PASSWORD@HOST:587` | yes, over verified STARTTLS | no provider-specific API mapping |
| `resend://KEY@default` | refused; provider signs | name/value `tags` |
| `postmark://TOKEN@default?stream=welcome` | refused; provider signs | `tag` becomes `Tag`; remaining entries become `Metadata` |
| `sendgrid://KEY@default` or `@eu` | refused; provider signs | `category` becomes comma-separated `categories`; remaining entries become `custom_args` |
| `mailgun://KEY:DOMAIN@default` or `@eu` | yes; MIME bytes are sent | comma-separated `tag` becomes `o:tag`; remaining entries become `v:` fields |
| `graph://MAILBOX@default` | yes; MIME bytes are sent | no provider-specific API mapping |
| `log://`, `file:///PATH` | yes, for local inspection | no provider-specific API mapping |

Resend uses the stable message id as its idempotency key within the
provider's retention window. Postmark,
SendGrid, Mailgun and Graph can return `Unknown` after a lost answer;
they do not gain idempotency by sharing that id. Their individual guides
explain limits and provider error mappings. Graph's MIME transport cannot
send Bcc or an envelope that differs from visible recipients; it also
refuses redirect, bounce overrides, DSN and `requireTls`. Mailgun can carry
the TLS request, but not SMTP DSN or a per-message bounce override.

SES and automatic AWS credential discovery are not supported transports
here. Choose one of the implemented routes above.

## Use the right OAuth audience

For Microsoft SMTP, an administrator grants `SMTP.SendAsApp`, grants admin
consent, registers the service principal in Exchange and limits mailbox
access and SendAs permission. Follow the current
[Exchange SMTP OAuth instructions](https://learn.microsoft.com/en-us/exchange/client-developer/legacy-protocols/how-to-authenticate-an-imap-pop-smtp-application-by-using-oauth).
For Graph, grant the application `Mail.Send` and constrain mailbox access;
the [Graph sendMail contract](https://learn.microsoft.com/en-us/graph/api/user-sendmail?view=graph-rest-1.0)
explains permissions and why HTTP 202 does not prove delivery.

```bit
import { MicrosoftApp, Options, open } from "mail"
import { env } from "std/os"

fn main(): ()! {
  let source = MicrosoftApp(env("MAIL_TENANT"), env("MAIL_CLIENT_ID"), env("MAIL_CLIENT_SECRET"))
  let mailer = open(
    "graph://hello%40inkwell.dev@default",
    Options{ from = "Inkwell <hello@inkwell.dev>", token = source },
  )?
  defer mailer.close()
  mailer.verify()?
}
```

Use the same source with `smtp://hello%40inkwell.dev@smtp.office365.com:587`
for SMTP. `MicrosoftApp` keeps separate SMTP and Graph token audiences.
Graph `verify` checks token acquisition, not `Mail.Send` authorization.

For a user-authorized Google SMTP session, retain the refresh token in your
secret store. Request the `https://mail.google.com/` scope and the appropriate
offline access during consent. Google's [SMTP OAuth contract](https://developers.google.com/workspace/gmail/imap/xoauth2-protocol)
describes that broad mail scope and its verification requirements:

```bit
import { RefreshToken, Token, TokenSource } from "mail"
import { env } from "std/os"

fn main(): ()! {
  let source: TokenSource = RefreshToken(
    "https://oauth2.googleapis.com/token", env("MAIL_CLIENT_ID"), env("MAIL_REFRESH_TOKEN"),
    clientSecret = env("MAIL_CLIENT_SECRET"),
  )
  let token: Token = source.token()?
  assert(token.value != "", "Inkwell received an empty token")
  println("token expires at ${token.expires.toString()}")
}
```

Pass this source as `Options.token` to the Gmail SMTP mailer. Never log the
token value. A rotated refresh token is updated in memory; persist it to
your secret store for the next restart. Do not mutate source configuration
while sends are active.

For Workspace application sending, a service account has no mailbox of its
own. An administrator grants domain-wide delegation for the SMTP scope and
authorizes the user you impersonate, following
[Google's delegation instructions](https://developers.google.com/identity/protocols/oauth2/service-account#delegatingauthority):

```bit
import { GoogleServiceAccount, Options, open } from "mail"
import { readFile } from "std/fs"
import { env } from "std/os"

fn main(): ()! {
  let source = GoogleServiceAccount(
    readFile(env("MAIL_SERVICE_ACCOUNT_FILE"))?, "hello@inkwell.dev",
    scope = "https://mail.google.com/",
  )
  let mailer = open(
    "smtps://hello%40inkwell.dev@smtp.gmail.com:465",
    Options{ from = "Inkwell <hello@inkwell.dev>", token = source },
  )?
  defer mailer.close()
  mailer.verify()?
}
```

Use a delegated Workspace account, not this flow for a personal Gmail
account. Protect the JSON private key and choose an explicit delegated
subject. [Send with OAuth](oauth.md) explains expiry, the shared refresh
cache, bounded authentication retry and configuration failures.

## Keep staging safe and failures visible

A production domain with test recipients is still production mail. Use
`log://` or `file://` locally. For an SMTP staging server, redirect every
envelope to your QA mailbox before any delivery:

```bit
import { Options, open } from "mail"
import { env } from "std/os"

fn main(): ()! {
  let mailer = open(
    env("STAGING_MAIL_URL"),
    Options{ from = "Inkwell <hello@inkwell.dev>", redirect = "qa@inkwell.dev" },
  )?
  defer mailer.close()
  mailer.verify()?
}
```

Do not use that redirect with Graph. Deploy only after the startup check,
then watch queued, transient, permanent and unknown outcomes separately.
Do not use a background queue when the request must report delivery failure
immediately, and do not treat a provider's acceptance as proof of arrival.

Next: [Test the mail your app sends](testing.md),
[Webhooks](webhooks.md) for delivery events, and
[Unsubscribe](unsubscribe.md) before sending a digest.
