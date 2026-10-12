# Connect and authenticate to an SMTP relay

Choose the relay port and verify its certificate before Inkwell sends a credential.
Use STARTTLS on port 587 or connect with TLS directly on port 465.

<!-- doctest: per-block -->

## When a server goes quiet

A relay that accepts a connection and then says nothing must not hold a sender
forever, so every step is bounded by `Options.timeout`: the connect (and, for
`dialTls`, the TLS handshake with it), the greeting, each command with its
reply, and a DATA payload with the reply to it. Each exchange starts a fresh
clock; the total of a session is not capped, and a slow server that answers each
step inside the limit is not interrupted.

```bit
import { dial, Options, Client, Message, SmtpError } from "std/smtp"
import { Second } from "std/time"

// Give a slow relay a minute per step rather than the default 30 seconds.
fn dialPatient(host: string): Client!SmtpError {
  return dial(host, 587, Options(timeout = 60 * Second))?
}

// A step that ran out of time fails with a message naming it, and the
// connection is already closed.
fn sendOnce(c: Client, m: Message): bool {
  c.send(m) catch e {
    return e.command == "MAIL FROM" && e.transient()
  }
  return true
}
```

A step that runs out of time fails with an `SmtpError` whose `command` names it
and whose message reads `smtp: EHLO timed out after 200ms`. It has no reply code
and `transient()` is true, since a later attempt may meet a peer that answers.
The connection is closed at that moment and never reused: a late answer to the
abandoned command would otherwise be read as the answer to the next one, so any
further call on that `Client` fails with `smtp: the connection was closed after a
timeout; dial again`, and the next attempt dials afresh. A `timeout` that is zero
or negative is a caller's bug and fails before anything connects, with `smtp:
Options.timeout must be positive, got 0`.

The default is 30 seconds. RFC 5321 section 4.5.3.2 tells a client to wait 5
minutes for the greeting, `MAIL` and `RCPT`, 2 minutes for the reply to `DATA`,
3 minutes per DATA block and 10 minutes for the reply after the final dot,
figures meant for an unattended relay draining a queue to a distant host. A
sender behind a request, a pool or a retry loop cannot park a worker that long
on a silent peer, so the default is shorter than every one of them. A caller that
relays slowly, or sends a large message over a slow link (the payload and its
reply share one clock), raises `timeout`; passing the RFC's `10 * Minute`
restores the longest of its figures for every step.

## What this module refuses to do

Four rules are structural - enforced by the code that would otherwise break
them, not by documentation:

| Rule | Where |
|---|---|
| A CR, LF or NUL in a header value is **rejected**, never stripped | every value, on the way in |
| `AUTH` never runs on a connection that is not TLS | `auth` |
| The server certificate is verified | `Options.insecureSkipVerify` is the only opt-out |
| No message line reaches 998 octets, no command line 12288 | folding, encoding, and a final check |

Header injection is the reason for the first. A newline in a supplied subject,
recipient or display name lets the caller close the header it was given and open
one of its own - a `Bcc` to an address the sender never approved is the classic
payload. The value is refused rather than rewritten, and the whole message is
rendered and validated before `MAIL FROM` is sent, so a rejected value costs
zero transmitted bytes.

The second has no opt-out at all. A downgrade that silently puts a password on a
cleartext wire is worse than not sending the mail, so `AUTH` fails on a
connection that is neither implicit TLS nor post-`STARTTLS` - and it fails
before the command is built, so not even a username is transmitted.

The fourth is a property of the data rather than a flag. A text part is sent
one of three ways, chosen from its own bytes:

- `7bit` when it can be: printable ASCII (tab and line breaks aside), every line
  inside the limit with room for the DATA dot-stuffing octet.
- Otherwise quoted-printable (RFC 2045 section 6.7) when that is no larger than
  base64: `=XX` for a byte outside printable ASCII and for `=` itself, a trailing
  space or tab escaped, lines cut at 76 columns with a soft break that never
  lands inside a UTF-8 character. A mostly-English mail with one curly quote
  stays readable in its raw form, and a 1200-character line is cut into legal
  lines.
- Otherwise base64 wrapped at 76 columns: text that is mostly non-ASCII, such as
  an Arabic or Chinese paragraph, costs three characters per byte in
  quoted-printable and about 1.3 in base64.

The same text always takes the same path, and a bare LF or CR in it becomes CRLF
on all three. A header value that cannot be folded at whitespace inside the
limit becomes RFC 2047 encoded words, one per line.

### `Options(insecureSkipVerify: bool = false, serverName: string = "", roots: TrustStore = ..., timeout: int = 30 * Second)`

How a TLS leg is set up. `Options()` is secure by default: verification on,
system trust anchors, SNI taken from the dialed host. Each argument loosens or
pins one thing, so the call site says exactly what it changed:

```bit
import { dial, dialTls, Options, Client } from "std/smtp"

// The relay's certificate names the provider, not the host we dial through.
fn viaPinnedName(host: string): Client! {
  return dialTls(host, 465, Options(serverName = "smtp.mail.example.com"))?
}

// A local test server with a throwaway certificate: the one place to opt out.
fn viaLabServer(port: int): Client! {
  return dialTls("127.0.0.1", port, Options(insecureSkipVerify = true))?
}
```

| Field | Meaning |
|---|---|
| `insecureSkipVerify` | skip chain **and** hostname verification |
| `serverName` | SNI and the name the certificate must match; empty means the dialed host |
| `roots` | trust anchors; empty means the OS store, bundled roots as fallback |
| `timeout` | nanoseconds each step may take; must be positive; default 30 seconds |

Setting `insecureSkipVerify` true means the connection proves nothing about who
the peer is, and a credential sent over one is a credential given to whoever
answered. It is for tests and pinned lab servers.

### `dial(host: string, port: int, o: Options = Options()): Client!SmtpError`

Connect to a cleartext submission port (587, or 25 for a relay) and read the
greeting. The session is not secure yet: `startTls` makes it so, and until it
does, `auth` refuses to run. The connect, the greeting and
every later step are bounded by `o.timeout`; nothing else in `o` is read, since
no TLS happens here. See "When a server goes quiet".

### `dialTls(host: string, port: int, o: Options): Client!SmtpError`

Connect to an implicit-TLS submission port (465): the handshake happens before
the greeting, so there is no cleartext phase and no `startTls`. The connect and
the handshake share one `o.timeout`; the greeting and each later step get a
fresh one.

### `Client`

One SMTP session.

### `Client.ehlo(name: string): ()!SmtpError`

Send `EHLO name` and record the capabilities it returns. `name` is the client's
own domain and goes on the command line unquoted, so it must be printable ASCII
with no spaces. Must be re-issued after `startTls`.

### `Client.startTls(o: Options): ()!SmtpError`

Upgrade a cleartext connection to TLS (RFC 3207). Fails when the server did not
advertise `STARTTLS`, and fails when the server has sent bytes that would sit in
the read buffer across the handshake - the plaintext command-injection shape
(CVE-2011-0411), which is refused rather than quietly discarded. Call `ehlo`
again afterwards. The handshake is bounded by `o.timeout`: `startTls` takes its
own budget from the `Options` it is given, and refuses one that is not positive.

### `Client.supports(ext: string): bool`

Whether the server advertised `ext` in its last EHLO reply, matched
case-insensitively against the first word of each capability line, so
`supports("AUTH")` answers for `AUTH PLAIN LOGIN`.

### `Client.limits(): Limits`

The caps the server advertised in its last EHLO reply's `LIMITS` line (RFC 9422):
`rcptMax`, the `RCPT TO` commands it accepts in one transaction, and `mailMax`,
the `MAIL FROM` commands it accepts in one session. A cap that was not
advertised, or whose value is not one to six digits with no leading zero
(1..999999), is 0. It never fails: the advertisement is advice, and a malformed
one must not stop a send. Names are matched case-insensitively, a name this
module does not know is skipped, and a `LIMITS` parameter that breaks the basic
`name=value` syntax (an empty word, a `;` in a value) is ignored as a whole.

Like `supports`, it reads the last EHLO only: it is all zero before `ehlo`, and
again after `startTls` until `ehlo` is re-issued.

```bit
import { Client, Limits } from "std/smtp"

// The recipient lists to send one message as, so no transaction carries more
// `RCPT TO` commands than the server accepts. A server that advertised no cap
// gets the whole list.
fn batches(c: Client, to: []string): [][]string {
  let l: Limits = c.limits()
  let out = [][]string(0)
  if (l.rcptMax == 0) {
    return append(out, to)
  }
  let i = 0
  while (i < len(to)) {
    let end = i + l.rcptMax
    if (end > len(to)) {
      end = len(to)
    }
    out = append(out, to[i:end])
    i = end
  }
  return out
}

// Whether a session that has carried `sent` transactions should be retired
// before the next one, so the server never has to cut it.
fn retire(c: Client, sent: int): bool {
  let l = c.limits()
  return l.mailMax > 0 && sent >= l.mailMax
}
```

### `Limits`

The caps `Client.limits()` returns: `rcptMax` and `mailMax`, both `int`, each 0
when the server did not advertise it.

### `Client.isSecure(): bool`

Whether this connection is TLS - an implicit-TLS dial, or a completed
`startTls`.

### `Client.authMechanisms(): []string`

The SASL mechanisms the server advertised in its last EHLO reply's `AUTH` line
(and its legacy `AUTH=` spelling), upper-case and in the server's order, for
example `["PLAIN", "LOGIN"]`. Empty when it advertised none, before `ehlo`, and
again after `startTls` until `ehlo` is re-issued. It is how a caller picks the
`Auth` variant to pass to `auth`, or names what a server offers when none of
them fits.

```bit
import { Auth, Client, SmtpError } from "std/smtp"

// Log in with PLAIN when the relay offers it, else LOGIN; say so when it
// offers neither.
fn login(c: Client, user: string, pass: string): ()!SmtpError {
  for m of c.authMechanisms() {
    if (m == "PLAIN") {
      return c.auth(Auth.Plain(user, pass))?
    }
    if (m == "LOGIN") {
      return c.auth(Auth.Login(user, pass))?
    }
  }
  println("the relay offers neither PLAIN nor LOGIN")
}
```

### `Client.auth(a: Auth): ()!SmtpError`

Authenticate with the mechanism `a` selects. Before a credential byte exists
this checks, in order: the connection is TLS (refused outright otherwise, with
no opt-out, so not even a username is transmitted), neither credential carries a
CR, LF or NUL (a token or an OAuth username also no 0x01), `ehlo` has run, and the server's `AUTH` capability lists the
mechanism (RFC 4954 section 3, matched case-insensitively, `AUTH=` spelling
included). A mechanism the server does not list fails with `smtp: the server
does not offer AUTH <MECH>` and sends nothing. An error never repeats a
credential.

```bit
import { Auth, Client, SmtpError } from "std/smtp"

// A relay that offers only `AUTH LOGIN`.
fn loginOnly(c: Client): ()!SmtpError {
  c.auth(Auth.Login("mustafa", "hunter2"))?
}
```

### `Auth`

The credentials `auth` takes. The variant is the mechanism; new mechanisms are
new variants, never new methods.

| Variant | Mechanism |
|---|---|
| `Auth.Plain(user, pass)` | SASL PLAIN (RFC 4616): one initial response, `\0user\0pass` in base64 |
| `Auth.Login(user, pass)` | SASL LOGIN: the username and the password as two base64 challenge responses |
| `Auth.Xoauth2(user, token)` | XOAUTH2: an OAuth2 access token, `user=<user>\x01auth=Bearer <token>\x01\x01` in base64 |
| `Auth.OauthBearer(user, token)` | OAUTHBEARER (RFC 7628): the same token with a GS2 header and the dialed host and port |

#### OAuth2 tokens

Google Workspace and Exchange Online no longer take a password over SMTP; they
take an OAuth2 access token, which the caller obtains and refreshes. `auth`
sends it, once, and does nothing else with it.

| Provider | Variant |
|---|---|
| Gmail and Google Workspace (`smtp.gmail.com`) | `Auth.Xoauth2` or `Auth.OauthBearer`; the server's `AUTH` line lists both |
| Microsoft 365 and Exchange Online (`smtp.office365.com`) | `Auth.Xoauth2` only |

```bit
import { Auth, Client, SmtpError } from "std/smtp"

// `token` is a current access token with the scope the provider requires.
fn gmail(c: Client, user: string, token: string): ()!SmtpError {
  c.auth(Auth.Xoauth2(user, token))?
}

fn gmailBearer(c: Client, user: string, token: string): ()!SmtpError {
  c.auth(Auth.OauthBearer(user, token))?
}
```

A token or username carrying CR, LF, NUL or 0x01 is refused before anything is
sent. When the server rejects the token it first sends a `334` reply holding a
base64 JSON error (an expired token, a missing scope). `auth` answers it as RFC
7628 section 3.2.3 asks, an empty line for XOAUTH2 and a single 0x01 for
OAUTHBEARER, and fails with the server's final reply as an `SmtpError` whose
`text` starts with the JSON's `status` and `scope`, for example `OAuth
status=401 scope=https://mail.google.com/: Username and Password not accepted`.
`command` is `AUTH XOAUTH2` or `AUTH OAUTHBEARER`. The token is in no error
text. An `AUTH` command line may be up to 12288 octets (RFC 4954 section 4), so
an Exchange Online token of over 1500 characters goes out in one line.

### `Client.send(m: Sendable): Delivery!SmtpError`

Render and send `m`, a `Message` or a [`Raw`](../smtp.md#rawenv-envelope-data-string):
`MAIL FROM`, one `RCPT TO` per envelope recipient, `DATA`, the dot-stuffed
payload, and the terminating dot. The message and the envelope are checked
first, so a CR in a subject, a malformed address or an over-long line fails with
`MAIL FROM` never sent.

Every recipient is offered. One the server refuses is recorded in the
[`Delivery`](#delivery), and the rest still get the message (RFC 5321 section
3.3: `DATA` proceeds when at least one `RCPT TO` was accepted). When the server
refuses all of them, no `DATA` is sent: the call sends `RSET` and fails with the
last refusal, whose `text` ends with `(refused: ` and every refused address.

A refused `MAIL FROM` or `DATA` also sends `RSET` before failing, so the same
`Client` can send the next message. Nothing is reset after a failure with no
reply (the connection broke or timed out), after a `421` (the server is closing
the channel), or after the reply to the payload, which ends the transaction
whatever it says: a `451` there leaves the session ready for the next `send`.

Whether the `RSET` was answered is not lost: [`reusable`](#clientreusable-bool)
reports it.

### `Delivery`

What `send` did with the recipients of one message. It is returned only when at
least one was accepted.

| Field | Meaning |
|---|---|
| `accepted` | the recipients the server took, in envelope order |
| `rejected` | the recipients it refused, in envelope order, as `Rejection`s |
| `queueId` | the server's reply to the end of `DATA` with its code taken off, such as `2.0.0 Ok: queued as 4Bx1` |

### `Rejection`

One recipient the server refused: `address`, and `error`, the `SmtpError` with
the reply's `code`, `enhanced` status and `text`, and `command` `RCPT TO`.
`error.transient()` tells a mailbox that is busy (4xx) from one that does not
exist (5xx).

### `Client.reset(): ()!SmtpError`

Send `RSET` (RFC 5321 section 4.1.1.5) and expect a 250: the server forgets the
transaction in progress, so the next `send` starts clean. After a successful
`send` nothing needs resetting, and a refused `MAIL FROM` or `DATA` already
resets by itself; this is for a caller that abandoned a transaction on its own
account. `ehlo` must have run, as for `send`.

### `Client.reusable(): bool`

Whether the session can carry another `send`. It is `true` on a fresh session
and after any refusal the server cleaned up: a refused `MAIL FROM`, `RCPT TO`
or `DATA` followed by an `RSET` it answered 250, a `451` at the end of `DATA`,
and a message `send` refused locally before writing anything. It is `false`
after a failure with no reply (the connection broke), after a `421`, after a
timeout, and after a refused transaction whose `RSET` failed or was not
answered 250, since the server may still hold the abandoned transaction. A
`false` is final: close the client and dial again.

`send` fails with the refusal that mattered, never with the `RSET`'s, so
`reusable` is how a failed `RSET` is seen. A pool needs nothing else to decide
whether to keep a session after a failed message, and does not send an `RSET`
of its own.

```bit
import { Client, Message } from "std/smtp"

// Send `m`; keep `c` for the next message only when the server is still in
// step with us. The caller closes `c` when this reports false.
fn sendKeeping(c: Client, m: Message): bool {
  let _ = c.send(m) catch _ {
    return c.reusable()
  }
  return true
}
```

### `Client.noop(): ()!SmtpError`

Send `NOOP` (RFC 5321 section 4.1.1.9) and expect a 250. The server does nothing
but answer, which makes it the health check for a session that sat idle in a
pool: if it returns, the connection is alive and ready for the next message.
Unlike `reset` it is legal before `ehlo`.

Both commands run under `Options.timeout` and fail with an `SmtpError` whose
`command` is `RSET` or `NOOP`: the server's reply when it is not a 250, a
transient error with no reply code when the connection is gone. A timeout and a
`421` (the server is closing the channel, RFC 5321 section 4.2.2) both close the
`Client`, and any later call on it fails with `smtp: the connection was closed
after a timeout; dial again` or `smtp: the connection was closed after a 421
reply; dial again`. Any other refusal leaves the session usable.

```bit
import { Client, Message, Delivery, SmtpError } from "std/smtp"

// Send two messages over one session, checking the session answers in between
// the way a pool does before it hands a connection out again. A session that
// fails the check is the pool's to drop and dial afresh.
fn sendTwice(c: Client, a: Message, b: Message): (Delivery, Delivery)!SmtpError {
  let first = c.send(a)?
  c.noop()?
  let second = c.send(b)?
  return (first, second)
}

// Abandon a transaction that was started and not finished, so the next send is
// accepted.
fn startOver(c: Client): ()!SmtpError {
  c.reset()?
}
```

### `Client.quit(): ()!SmtpError`

End the session politely: `QUIT`, then close the socket. The socket is closed
even when the reply is not a 221 - the alternative is leaking a descriptor over
a server's bad manners.

### `Client.close()`

Close the connection without a `QUIT`. Idempotent.

### `Stream`

The transport under a session: `send`, `recv`, `deadline` (arm the limit every
later `send` and `recv` obeys), `timedOut` (whether the last `recv` came back
empty because that limit passed) and `shut`. It exists so the rest
of the module never asks whether it is talking cleartext or TLS - `startTls`
swaps one implementation for another inside a live `Client`, and the flag that
guards `AUTH` is written by that same swap, so there is no state for it to
disagree with. A caller has no reason to implement it.

### `SmtpError`

Why a step failed, and the one type every fallible call here fails with.

| Field | Meaning |
|---|---|
| `code` | the reply code the server answered with; 0 when no reply was involved (network, TLS, a malformed reply, a local refusal) |
| `enhanced` | the RFC 3463 status the server sent (`5.1.1`, RFC 2034), or `""` when it sent none |
| `text` | the server's text joined by a space with the enhanced status taken off, or the local reason when `code` is 0 |
| `cause` | the `std/net` or `std/tls` error under a transport failure, nil otherwise; a failed TLS handshake is a `std/tls` `HandshakeError` |
| `command` | the step that failed (for a timeout, the step that ran out of time): `connect`, `greeting`, `EHLO`, `STARTTLS`, `AUTH PLAIN`, `AUTH LOGIN`, `AUTH XOAUTH2`, `AUTH OAUTHBEARER`, `AUTH LOGIN username`, `AUTH LOGIN password`, `MAIL FROM`, `RCPT TO`, `DATA`, `end of DATA`, `QUIT`, or `validate` for a local refusal |

### `SmtpError.transient(): bool`

True when sending again later can succeed: a 4xx reply, or a failure with no
reply that is not a local `validate` refusal and not a TLS handshake refused on
verification or negotiation. See "When a send fails".

### `SmtpError.message(): string`

The failure as one line, in the module's wording: `smtp: <command> got <code>:
<enhanced> <text>` for a reply, `smtp: <reason>` without one.

Next: [prepare the message and its envelope](../smtp.md#the-envelope-and-pre-rendered-mail).
