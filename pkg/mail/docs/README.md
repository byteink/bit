# pkg/mail documentation

Read in this order. Each row is one chapter; this table is the order
bitlang.org's sidebar reads it in.

| Chapter | Covers |
|---|---|
| [Addresses](addresses.md) | `parseAddress` and `parseAddressList` on Inkwell's sign-up form, `Address` and its display name, what is refused and why, `MailError` |
| [Messages](messages.md) | the `Message` class on Inkwell's publish mail: every field, threading, `Message-ID`, `Auto-Submitted`, what is refused |
| [The Mailer](mailer.md) | `Mailer`, `Options`, `send` and `render` on Inkwell's welcome mail: startup checks, the `Outbox` test transport, writing a `Transport`, `Receipt`, `MailError` |
| [Attachments](attachments.md) | `Attachment` and `Attachment.file` on Inkwell's publish mail: a PDF to save, a logo shown inside the HTML by `cid`, the checks that tie the two together, the 25 MiB limit, the MIME type table |

See the [package front page](../README.md) for install and a minimal example.
