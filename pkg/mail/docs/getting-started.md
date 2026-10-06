# Send a welcome email

A writer signs up for Inkwell. A minute later they should have a mail with a
link that proves the address is theirs, and the sign-up is not finished until
they press it. Without a library that is a conversation with a mail server
(login, TLS, envelopes), a message in a format with its own rules (headers,
encoded subjects, an HTML part and a text part, attachments), and a different
set of credentials on your laptop than on the server. This chapter sends that
one mail, starting with five lines on your machine and ending with the same
code in production. Every other chapter is linked where the welcome mail needs
it.

<!-- doctest: per-block -->
<!-- doctest: deps web -->

## The first send

The program reads one string, `MAIL_URL`, and builds a `Mailer` from it. On
your laptop the string is `log://`, which sends nothing and prints each mail,
so there is no account to create:

```bit
import { Message, Options, open } from "mail"
import { env } from "std/os"

fn main(): ()! {
  let mailer = open(env("MAIL_URL"), Options{ from = "Inkwell <hello@inkwell.dev>" })?
  mailer.send(
    Message{
      to = ["Sara Ali <sara@example.com>"],
      subject = "Welcome to Inkwell",
      text = "Hi Sara. Confirm your address: https://inkwell.dev/verify/9f2c",
      id = "welcome-7",
    },
  )?
  mailer.close()
  return
}
```

Run it with `MAIL_URL=log:// bit run main.bit` and the mail appears on standard
output:

```text
------------------------------------------------------------
From: hello@inkwell.dev
To: Sara Ali <sara@example.com>
Subject: Welcome to Inkwell
Message-ID: <welcome-7@inkwell.dev>

Hi Sara. Confirm your address: https://inkwell.dev/verify/9f2c
------------------------------------------------------------
```

`open` returns a `Mailer`. It connects to nothing; the first `send` does.
`Options.from` is the sender for every message that names none, so the call
site says who the mail is for and what it says, never who it is from. `id` names
the mail's own Message-ID, `<welcome-7@inkwell.dev>`, so you can find it again
and so a later mail can reply to it (see [Replies and threads](#replies-and-threads)).
`MAIL_URL` unset is a mistake, and `open` says so before anything is sent:
`mail: configuration: open needs a URL like smtps://user:pass@smtp.example.com; got an empty string`.

## Check the address the writer typed

The sign-up form gives you a string. `parseAddress` turns it into an `Address`
with the display name and the address apart, or fails with a message you can
show next to the field:

```bit
import { MailError, Mailer, Message, Options, Receipt, open, parseAddress } from "mail"
import { env } from "std/os"

fn welcome(mailer: Mailer, form: string): Receipt!MailError {
  let who = parseAddress(form)?
  return mailer.send(
    Message{
      to = [who.toString()],
      subject = "Welcome to Inkwell, ${who.name}",
      text = "Hi ${who.name}. Confirm your address: https://inkwell.dev/verify/9f2c",
      id = "welcome-7",
    },
  )?
}

fn main(): ()! {
  let mailer = open(env("MAIL_URL"), Options{ from = "Inkwell <hello@inkwell.dev>" })?
  let r = welcome(mailer, "Sara Ali <sara@example.com>")?
  println("id ${r.id}")
  println("accepted ${r.accepted[0]}, rejected ${len(r.rejected)}")
  println("queued ${r.queued}, provider id '${r.providerId}', transport '${r.transport}'")
  welcome(mailer, "sara at example.com") catch e {
    println(e.message())
    mailer.close()
    return
  }
  mailer.close()
  return
}
```

With `log://` the mail is printed first (the subject reads `Welcome to Inkwell,
Sara Ali` and the text opens `Hi Sara Ali.`), then:

```text
id <welcome-7@inkwell.dev>
accepted sara@example.com, rejected 0
queued false, provider id 'log', transport ''
mail: invalid address "sara at example.com": no @ sign
```

`send` returns a `Receipt` once the server has the mail: `id` is the Message-ID
as written, `accepted` the recipients that took it, `rejected` those that did
not, each with the server's reply, `queued` is true when the server kept it for
later, `providerId` is the server's own handle for it (`log` here), and
`transport` names the server that delivered when there is more than one (see
[A second route](failover.md)). The rules for what an address may be are in
[Addresses](addresses.md).

## A welcome that looks like Inkwell

A text mail works, and a welcome mail deserves a button. Build the HTML the way
you build a page, with a JSX component from pkg/web, and hand the rendered
string to `Message.html`:

```bit
import { Message, Options, open } from "mail"
import { Node, attr, elem, frag, render, text } from "web"
import { env } from "std/os"

fn Welcome(name: string, link: string): Node {
  return <div>
    <h1>Welcome to Inkwell, {text(name)}</h1>
    <p>Confirm your address to write your first note.</p>
    <p><a href={link}>Verify my address</a></p>
  </div>
}

fn main(): ()! {
  let mailer = open(env("MAIL_URL"), Options{ from = "Inkwell <hello@inkwell.dev>" })?
  mailer.send(
    Message{
      to = ["Sara Ali <sara@example.com>"],
      subject = "Welcome to Inkwell",
      html = render(<Welcome name="Sara" link="https://inkwell.dev/verify/9f2c" />),
      id = "welcome-7",
    },
  )?
  mailer.close()
  return
}
```

The message sets only `html`, and the mail still has a text part. When `text`
is empty the package writes one from the HTML, so a client that shows plain
text, and a spam filter that distrusts a lone HTML mail, both get a readable
version. With `log://` you see that text:

```text
------------------------------------------------------------
From: hello@inkwell.dev
To: Sara Ali <sara@example.com>
Subject: Welcome to Inkwell
Message-ID: <welcome-7@inkwell.dev>

Welcome to Inkwell, Sara

Confirm your address to write your first note.

Verify my address (https://inkwell.dev/verify/9f2c)
------------------------------------------------------------
```

The link survived as `label (url)`, and the heading and paragraphs became lines. Set `text` yourself when you want your own
wording. The web package's `text(name)` escapes what it is given, so a writer
who signs up as `<script>` gets a harmless name in the HTML; see
[Responses](../../web/docs/response.md) for components.

## A PDF to keep and a logo in the mail

The welcome carries the writer's handbook as a PDF, and the Inkwell logo sits at
the top of the HTML rather than as a second file. `Attachment.file` reads a file
and fills in the name and the type; giving it a second argument, a `cid`, makes
the picture inline, and the HTML shows it with `cid:logo`:

```bit
import { Attachment, Message, Options, open } from "mail"
import { Node, attr, elem, frag, render, text } from "web"
import { env, envOr } from "std/os"
import { remove, writeFile } from "std/fs"

fn Welcome(name: string): Node {
  return <div>
    <img src="cid:logo" alt="Inkwell" />
    <h1>Welcome to Inkwell, {text(name)}</h1>
    <p>The writer's handbook is attached.</p>
  </div>
}

fn main(): ()! {
  let dir = envOr("TMPDIR", "/tmp")
  writeFile("${dir}/inkwell-handbook.pdf", "%PDF-1.7\n")?
  writeFile("${dir}/inkwell-logo.png", "\x89PNG\r\n")?
  let handbook = Attachment.file("${dir}/inkwell-handbook.pdf")?
  let logo = Attachment.file("${dir}/inkwell-logo.png", "logo")?
  remove("${dir}/inkwell-handbook.pdf")?
  remove("${dir}/inkwell-logo.png")?

  let mailer = open(env("MAIL_URL"), Options{ from = "Inkwell <hello@inkwell.dev>" })?
  mailer.send(
    Message{
      to = ["Sara Ali <sara@example.com>"],
      subject = "Welcome to Inkwell",
      html = render(<Welcome name="Sara" />),
      attachments = [handbook, logo],
      id = "welcome-7",
    },
  )?
  mailer.close()
  return
}
```

`log://` lists each attachment by name and size and never prints its bytes:

```text
Attachment: inkwell-handbook.pdf (9 bytes)
Attachment: inkwell-logo.png (6 bytes)
```

The first has no `cid`, so it is a download. The second has one, so the mail is
written with the logo inside the HTML part. The HTML and the `cid`s have to
agree, and a mismatch is refused (see [Sharp edges](#sharp-edges)). The type
table, the size limit and the inline rules are in [Attachments](attachments.md).

## Replies and threads

Two days later Inkwell mails Sara tips for her first note. In her inbox that mail
belongs under the welcome, as one conversation, so it names the welcome in
`inReplyTo` and lists the thread so far in `references`:

```bit
import { Message, Options, open } from "mail"
import { env } from "std/os"
import { hasPrefix, split } from "std/strings"

fn main(): ()! {
  let mailer = open(env("MAIL_URL"), Options{ from = "Inkwell <hello@inkwell.dev>" })?
  let tips = Message{
    to = ["Sara Ali <sara@example.com>"],
    subject = "Re: Welcome to Inkwell",
    text = "Three tips for your first note.",
    inReplyTo = "<welcome-7@inkwell.dev>",
    references = ["<welcome-7@inkwell.dev>"],
    id = "tips-7",
  }
  for line of split(mailer.render(tips)?, "\r\n") {
    if (hasPrefix(line, "In-Reply-To:") ||
      hasPrefix(line, "References:") ||
      hasPrefix(line, "Message-ID:")) {
      println(line)
    }
  }
  mailer.close()
  return
}
```

That prints the three header lines:

```text
Message-ID: <tips-7@inkwell.dev>
In-Reply-To: <welcome-7@inkwell.dev>
References: <welcome-7@inkwell.dev>
```

`id` is what makes this work: you chose `welcome-7`, so you can write it down
and quote it later. Left empty it is a fresh unique id, which is fine for a mail
nobody replies to. `references` takes the ids oldest first, and the package adds
`inReplyTo` at the end if it is missing. All the `Message` fields are in
[Messages](messages.md).

## The editorial call

New writers are invited to Inkwell's editorial call. The mail carries a calendar
event, so Gmail and Outlook show Yes, No and Maybe next to it. That is the
`invite` field, an `Invite`. `Method.Request` is the default and is spelled out
here to read well; moving the call keeps the `uid` and raises `sequence`, and
calling it off is `Method.Cancel` with the next `sequence`:

```bit
import { Invite, Message, Method, Options, open } from "mail"
import { Minute, parseRfc3339 } from "std/time"
import { env } from "std/os"
import { hasPrefix, split } from "std/strings"

fn calendarLine(raw: string) {
  for line of split(raw, "\r\n") {
    if (hasPrefix(line, "Content-Type: text/calendar")) {
      println(line)
    }
  }
}

fn main(): ()! {
  let start = parseRfc3339("2026-10-12T09:00:00Z")?
  let mailer = open(env("MAIL_URL"), Options{ from = "Kim Lee <kim@inkwell.dev>" })?
  let call = Invite{
    uid = "editorial-call-2026-10-12@inkwell.dev",
    start = start,
    end = start.add(30 * Minute),
    summary = "Editorial call",
    method = Method.Request,
  }
  calendarLine(
    mailer.render(
      Message{
        to = ["Sara Ali <sara@example.com>"],
        subject = "Editorial call on Monday",
        text = "Monday at 09:00 UTC. The invite is attached.",
        invite = Option<Invite>.Some(call),
      },
    )?,
  )
  let off = Invite{
    uid = call.uid,
    start = call.start,
    end = call.end,
    summary = call.summary,
    method = Method.Cancel,
    sequence = 1,
  }
  calendarLine(
    mailer.render(
      Message{
        to = ["Sara Ali <sara@example.com>"],
        subject = "Editorial call is off",
        text = "Not this week.",
        invite = Option<Invite>.Some(off),
      },
    )?,
  )
  mailer.close()
  return
}
```

The mail's calendar part names its method, and the cancel's names a different one:

```text
Content-Type: text/calendar; method=REQUEST; charset=UTF-8
Content-Type: text/calendar; method=CANCEL; charset=UTF-8
```

A calendar knows an event by its `uid` alone, so the cancel repeats it. The cancel
has `sequence = 1` because it must be higher than the request's 0; a cancel with
the same number is refused. Attendees, the organizer and the other fields are in
[Calendar invites](invites.md).

## Sharp edges

Four mistakes are the program's, and each one fails the send before anything
leaves the process, naming the field. These three are the ones you meet first in
a welcome mail:

```bit
import { Attachment, MailError, Mailer, Message, Options, Unsubscribe, open } from "mail"
import { env } from "std/os"

fn kind(e: MailError): string {
  match (e) {
    Invalid(_) => return "Invalid"
    Config(_) => return "Config"
    Auth(_) => return "Auth"
    Rejected(_) => return "Rejected"
    Signature(_) => return "Signature"
    Transient(_) => return "Transient"
    Unknown(_) => return "Unknown"
  }
}

fn show(mailer: Mailer, m: Message) {
  mailer.send(m) catch e {
    println("${kind(e)}: ${e.message()}")
    return
  }
}

fn main(): ()! {
  let mailer = open(env("MAIL_URL"))?
  let to = ["Sara Ali <sara@example.com>"]
  show(mailer, Message{ to = to, subject = "Welcome to Inkwell", text = "Hi." })
  show(
    mailer,
    Message{
      from = "Inkwell <hello@inkwell.dev>",
      to = to,
      subject = "Your weekly digest",
      text = "Hi.",
      unsubscribe = Unsubscribe{ url = "http://inkwell.dev/u/7f3a9c" },
    },
  )
  show(
    mailer,
    Message{
      from = "Inkwell <hello@inkwell.dev>",
      to = to,
      subject = "Welcome to Inkwell",
      html = "<p>Hi Sara.</p>",
      attachments = [Attachment{ name = "inkwell.png", data = [u8(1)], cid = "logo" }],
    },
  )
  mailer.close()
  return
}
```

The three messages, in order:

```text
Invalid: mail: Message.from is empty and Options.from is not set
Invalid: mail: unsubscribe.url: must be https for one-click (RFC 8058)
Invalid: mail: attachments[0]: cid "logo" is never referenced: write cid:logo in the html, or clear Attachment.cid
```

Each is a `MailError.Invalid`: the message is wrong, and sending it again fails
again. The others tell you something else:

| Variant | What it means for the welcome mail |
|---|---|
| `Invalid` | the message is wrong; fix the code, not the retry |
| `Config` | the setup is wrong; raised by `open` and `Mailer(...)`, so the program stops at boot |
| `Auth` | the server refused the login: the password was rotated |
| `Rejected` | the server refused the mail or the address for good; do not retry |
| `Transient` | the server said "not now"; `send` already retries it (see [Retries and pace](retry.md)) |
| `Unknown` | the answer never came back, so the mail may be delivered; check before sending again |
| `Signature` | not a send: a webhook failed its check (see [Webhooks](webhooks.md)) |

One more setting is worth knowing before production: `tls=off`. A server on your
own machine, such as a mail catcher, takes mail without TLS, and the URL says so.
It never takes a password with it:

```bit
import { open } from "mail"

fn main(): ()! {
  open("smtp://hello:app-password@localhost:1025?tls=off") catch e {
    println(e.message())
    return
  }
  return
}
```

That prints:

```text
mail: configuration: smtp://hello:***@localhost:1025 carries credentials with tls=off; a password is never sent over a connection that is not TLS
```

Everywhere else the upgrade to TLS is required before a password is sent, and
there is no "TLS if the server has it" setting, because a program that sends in
plaintext whenever someone strips STARTTLS from the conversation has no
encryption at all. The reasoning and the URL forms are in
[Sending for real](open.md).

## To production

Nothing above changes. The program still reads `MAIL_URL`, and only its value
does. On the server it is one of these:

| `MAIL_URL` | Server |
|---|---|
| `log://` | your laptop: prints each mail |
| `smtps://hello%40inkwell.dev:app-password@smtp.example.com` | a mailbox with an app password (Fastmail, Gmail) |
| `resend://re_inkwell_key@default` | [Resend](resend.md) over HTTPS |
| `postmark://pm_inkwell_token@default` | [Postmark](postmark.md) over HTTPS |
| `sendgrid://SG.inkwell_key@default` | [SendGrid](sendgrid.md) over HTTPS |
| `mailgun://key-inkwell:mg.inkwell.dev@default` | [Mailgun](mailgun.md) over HTTPS |

Two things belong to production only. Mailbox providers want proof the mail comes
from your domain, so you sign it with a DKIM key ([Signing your mail](dkim.md)).
And a rotated password or an unpublished DNS record should stop the deploy, not a
signed-up writer, so you ask the mailer to check itself once at boot with
`verify()`, which sends nothing ([Checking the setup at boot](verify.md)).
`mailgun://` or an SMTP URL carries your signature as written; Resend, Postmark
and SendGrid sign for you and refuse `Options.dkim`. The private key stays in a
file the deploy mounts, and `DKIM_KEY_FILE` names it:

```bit
import { Dkim, Message, Options, open } from "mail"
import { env } from "std/os"
import { readFile } from "std/fs"

fn main(): ()! {
  let mailer = open(
    env("MAIL_URL"),
    Options{
      from = "Inkwell <hello@inkwell.dev>",
      dkim = [
        Dkim{
          domain = "inkwell.dev",
          selector = "2026r",
          key = readFile(env("DKIM_KEY_FILE"))?,
        },
      ],
    },
  )?
  mailer.verify()?
  println("mail is ready")
  mailer.send(
    Message{
      to = ["Sara Ali <sara@example.com>"],
      subject = "Welcome to Inkwell",
      text = "Hi Sara. Confirm your address: https://inkwell.dev/verify/9f2c",
    },
  )?
  mailer.close()
  return
}
```

With the account and the DNS record in place this prints `mail is ready` and
sends the welcome. Run it before the record is published and it stops at
`verify()` instead, with every problem in one error and the record to publish,
and the first writer never sees it:

```text
mail: configuration: verify found 1 problem:
  2026r._domainkey.inkwell.dev: no TXT record is published; publish this TXT value: v=DKIM1; k=rsa; p=MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8A...
```

The `p=` value is the public half of your key, cut here for the page. A wrong
password, an unreachable provider and a key that differs from the published one
each get a line of their own.

## Where to go next

[Testing without a server](mailer.md#the-outbox-in-a-test) shows the `Outbox`,
which keeps every mail for a test to read back. Retries, the second route and the
metrics come after you are live: [Retries and pace](retry.md),
[A second route](failover.md), [Watching the mail](observe.md). The complete
list of chapters is in the [documentation index](README.md).
