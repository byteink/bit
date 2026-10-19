# Send Inkwell mail with access tokens

An SMTP service may require an access token instead of a password. Give
Inkwell one token source at startup. The source exchanges your application's
credentials over verified HTTPS and shares its cached token across senders.

For an Exchange Online application with SMTP permissions already granted:

```bit
import { Message, MicrosoftApp, Options, open } from "mail"
import { env } from "std/os"

fn main(): ()! {
  let source = MicrosoftApp(env("MAIL_TENANT"), env("MAIL_CLIENT_ID"), env("MAIL_CLIENT_SECRET"))
  let mailer = open(
    "smtp://hello%40inkwell.dev@smtp.office365.com:587",
    Options{ from = "Inkwell <hello@inkwell.dev>", token = source },
  )?
  defer mailer.close()
  mailer.send(
    Message{
      to = ["sara@example.com"],
      subject = "Welcome to Inkwell",
      text = "Your account is ready.",
    },
  )?
}
```

`MicrosoftApp` uses the client credentials grant and the SMTP resource scope
`https://outlook.office365.com/.default`. Its tenant must be a GUID or domain.
Register the application and grant the mailbox permissions described in
[Microsoft's SMTP OAuth guide](https://learn.microsoft.com/en-us/exchange/client-developer/legacy-protocols/how-to-authenticate-an-imap-pop-smtp-application-by-using-oauth).
Direct `source.token()` calls and SMTP mailers use this SMTP scope.

## Send through Microsoft Graph

If your Exchange tenant permits Graph instead of SMTP, keep the same Inkwell
message and token source. Grant the application `Mail.Send`, then change the
transport. Call `sendGraphWelcome()` from `main` to select Graph:

```bit
import { Message, MicrosoftApp, Options, open } from "mail"
import { env } from "std/os"

fn sendGraphWelcome(): ()! {
  let source = MicrosoftApp(env("MAIL_TENANT"), env("MAIL_CLIENT_ID"), env("MAIL_CLIENT_SECRET"))
  let mailer = open(
    "graph://hello%40inkwell.dev@default",
    Options{ from = "Inkwell <hello@inkwell.dev>", token = source },
  )?
  defer mailer.close()
  mailer.send(
    Message{
      to = ["sara@example.com"], subject = "Welcome to Inkwell",
      text = "Your account is ready.",
    },
  )?
}
```

The mailbox before `@default` is percent-decoded. `default` selects
`graph.microsoft.com`. A custom host and port use HTTPS; certificate checks
can be disabled only for a custom test host. The transport posts your final
MIME bytes as base64 with `Content-Type: text/plain`, so `Options.dkim` can
sign the message. Read [Microsoft's sendMail contract](https://learn.microsoft.com/en-us/graph/api/user-sendmail?view=graph-rest-1.0)
for the application permission and mailbox access policy.

Graph requests `https://graph.microsoft.com/.default`. One `MicrosoftApp`
can serve both Graph and SMTP; each audience has a separate cache. A custom
`TokenSource` or `RefreshToken` must already produce a Graph token. A Graph
401 forces one refresh and one further request. A second 401, or a 403,
fails with `MailError.Auth`. A 429, 503, or 504 fails with
`MailError.Transient`; `Reply.retryAfter` retains a valid `Retry-After` value.
A 400 fails with `MailError.Rejected` and the provider's message. A 202
returns `Receipt.providerId` from `request-id`; it records acceptance,
not final delivery. A connection lost after sending the request is
`MailError.Unknown`, because repeating it could send the same mail twice.

Graph gets recipients from the MIME headers. A message with Bcc fails with
`graph:// cannot send Bcc recipients in MIME mode; send them a separate message`.
It also refuses an envelope that differs from those visible recipients,
including a queued blind recipient. `Options.redirect` fails at `open`
because preserving signed headers would deliver to their original recipients.
Use SMTP or Mailgun when you need blind recipients, staging redirects, or a
separate envelope. Graph also refuses delivery notifications, bounce overrides,
and `requireTls` because its API cannot carry those SMTP requirements.

`Mailer.verify()` checks token acquisition for Graph. It cannot prove
`Mail.Send` or the mailbox access policy without a real send.

## Use a delegated refresh token

When a user has already authorized Inkwell, keep that user's refresh token in
your secret store. Replace the source above with:

```bit
import { RefreshToken, Token, TokenSource } from "mail"
import { env } from "std/os"

fn inkwellSource(): TokenSource {
  return RefreshToken(
    "https://oauth2.googleapis.com/token",
    env("MAIL_CLIENT_ID"),
    env("MAIL_REFRESH_TOKEN"),
    clientSecret = env("MAIL_CLIENT_SECRET"),
  )
}

fn inspectExpiry(source: TokenSource): ()! {
  let token: Token = source.token()?
  assert(token.value != "", "Inkwell received an empty access token")
  println("Inkwell's access token expires at ${token.expires.toString()}")
}
```

`RefreshToken` takes `tokenUrl`, `clientId`, `refreshToken`, an optional
`clientSecret`, and an optional `scope`. An omitted secret supports public
clients; an omitted scope keeps the authorization originally granted. Set
`scope` only to scopes that the provider permits for that refresh token.
Google's SMTP authorization uses the `https://mail.google.com/` scope; see
[Google's SMTP OAuth guide](https://developers.google.com/workspace/gmail/imap/xoauth2-protocol).

A provider's rotated refresh token replaces `source.refreshToken` in memory.
Persist it in your secret store when your application needs it across restarts.
Treat source configuration as immutable while sends are in progress.

## Refreshing and failures

Each built-in source caches a `Token` per audience: its `value` is the bearer credential,
and `expires` is a `std/time.Timestamp`. Never print `value`. The source reuses
the token until sixty seconds before expiry, with one refresh in flight across
concurrent senders. Reuse the same source object to share this cache.

`TokenSource` is the interface for your own provider: implement
`token(): Token!MailError`. Custom sources own their caching and refresh
behavior. A direct `token()` call on a built-in source has a thirty-second
request timeout; SMTP uses `Options.timeout`. Token responses are limited to
64 KiB and redirects are refused.

SMTP authenticates after TLS, preferring OAUTHBEARER when advertised and
otherwise XOAUTH2. A 535 causes one token refresh and one more AUTH attempt.
Concurrent failures for the same acquisition share that refresh, even if the
provider returns the same token text. This happens before any message
transaction; it never resends delivered mail. Authenticated pooled sessions
continue carrying mail without repeating AUTH on every message.

A URL user with neither a password nor `Options.token` fails at `open`. With a
token source, use a username and no password. Plaintext SMTP never takes token
credentials. A token endpoint must use HTTPS. A 400 or 401 becomes
`MailError.Auth` with the provider's error code and description, scrubbed of
credentials. Network failures are `Transient`; no raw response body is included
in an error.

Use password authentication for a local relay that requires it, or a provider's
HTTP transport when that is the interface your account supports. Read
[Reusing connections](pool.md) and [Checking the setup at boot](verify.md) next.
