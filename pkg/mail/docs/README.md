# pkg/mail documentation

Read in this order. Each row is one chapter; this table is the order
bitlang.org's sidebar reads it in.

| Chapter | Covers |
|---|---|
| [Addresses](addresses.md) | `parseAddress` and `parseAddressList` on Inkwell's sign-up form, `Address` and its display name, what is refused and why, `MailError` |
| [Messages](messages.md) | the `Message` class on Inkwell's publish mail: every field, threading, `Message-ID`, `Auto-Submitted`, what is refused |
| [The Mailer](mailer.md) | `Mailer`, `Options`, `send` and `render` on Inkwell's welcome mail: startup checks, the `Outbox` test transport, writing a `Transport`, `Receipt`, `MailError` |
| [Attachments](attachments.md) | `Attachment` and `Attachment.file` on Inkwell's publish mail: a PDF to save, a logo shown inside the HTML by `cid`, the checks that tie the two together, the 25 MiB limit, the MIME type table |
| [Calendar invites](invites.md) | `Invite` and `Method` on Inkwell's Monday standup: an iMIP REQUEST that shows Yes / No / Maybe in Gmail and Outlook, moving and cancelling it with `uid` and `sequence`, the organizer and attendee defaults, RFC 5545 folding and escaping, what is refused |
| [Sending for real](open.md) | `open` on Inkwell's production setup: `smtps://` and `smtp://` URLs, STARTTLS that is required and never optional, `tls=off` for a local catcher, `caFile` and `serverName` for a private CA, how server answers map to `MailError` |
| [Sending through Resend](resend.md) | `open("resend://...")` on Inkwell's welcome mail: the API key in the URL, every `Message` field and what Resend cannot carry, `Idempotency-Key` from `Message.id`, how Resend's answers map to `MailError`, `Retry-After`, a proxy or test host with `insecureSkipVerify`, why `Options.dkim` is refused |
| [Sending through Postmark](postmark.md) | `open("postmark://...")` on Inkwell's password resets and weekly digest: the server token in the URL, message streams with `stream`, `Message.tags` as Postmark's `Tag` and `Metadata`, `ErrorCode` kept in `Reply.enhanced`, why a lost answer can send twice and how to allow one try, why `Options.dkim` is refused |
| [Reusing connections](pool.md) | `Options.pool` on Inkwell's Monday digest: one login for ten thousand mails, the NOOP and RSET that keep a session healthy, `LIMITS` MAILMAX and RCPTMAX, a send that finds every session busy, a connection lost mid-send without a double send |
| [Signing your mail](dkim.md) | `Options.dkim` and `Dkim` on Inkwell's publish mail: RSA and Ed25519 keys, what is checked at startup, DMARC alignment per message, providers that sign for you |
| [Retries and pace](retry.md) | `Options.retry`, `Retry`, `Options.rate` and `Reply.retryAfter` on Inkwell's publish mail: which failures repeat, full-jitter backoff, a server's Retry-After, a token bucket under the provider's limit |
| [Staging mail](redirect.md) | `Options.redirect` on Inkwell's staging server: one address takes every mail, the envelope is that address alone, `X-Original-To`, the `[redirected]` Subject, Bcc in no header, DKIM over the redirected bytes, a provider API's recipient fields, a bad address failing at `Mailer(...)` |
| [Webhooks](webhooks.md) | `parseEvents`, `Event`, `EventKind` and `Provider` on Inkwell's suppression list: Resend's Svix signature, the 5 minute window, de-duplicating on `deliveryId`, what each Resend event becomes |

See the [package front page](../README.md) for install and a minimal example.
