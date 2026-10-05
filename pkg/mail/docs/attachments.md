# Attachments and inline images

Kim publishes "Why we left Jira" on Inkwell, and Sara asked for a copy she can
read on the train. The mail should carry the article as a PDF she can save, and
the Inkwell logo should sit at the top of the mail itself, not as a second file
she has to open. Those are the two things an `Attachment` does: a file that
travels beside the mail, and a picture the HTML body shows in place.

<!-- doctest: per-block -->

## A file that travels with the mail

```bit
import { Attachment, Message, Mailer, Options, Outbox } from "mail"

fn main(): ()! {
  let pdf = Attachment{
    name = "why-we-left-jira.pdf",
    data = [u8(37), u8(80), u8(68), u8(70)],
    contentType = "application/pdf",
  }
  let box = Outbox()
  let mailer = Mailer(box, Options{ from = "Inkwell <hello@inkwell.dev>" })?
  mailer.send(
    Message{
      to = ["Sara Ali <sara@example.com>"],
      subject = "Why we left Jira, as a PDF",
      text = "The article is attached.",
      attachments = [pdf],
    },
  )?
  println("${len(box.sent()[0].message.attachments)}")
  mailer.close()
  return
}
```

That prints `1`. An `Attachment` is a `name`, which is what Sara sees in her
mail client, and the file's `data`, as bytes. `Message.attachments` is a list,
empty unless you set it, and the mail is written as a `multipart/mixed` with the
text first and each file after it. The bytes are encoded once, when the message
is rendered, and not copied before that, so an attachment already in memory
costs only what its encoding costs.

`contentType` says what kind of file it is. Leave it out and the package picks
one from the extension of `name`; see [the type table](#the-type-table).

## A file from disk

`Attachment.file(path)` reads a file and fills in the rest: the name is the last
part of the path, the bytes are the file's, and the type comes from the
extension.

```bit
import { Attachment } from "mail"
import { remove, writeFile } from "std/fs"
import { envOr } from "std/os"

fn main(): ()! {
  let path = "${envOr("TMPDIR", "/tmp")}/inkwell-${timeUnixNs()}-Why-we-left-Jira.PDF"
  writeFile(path, "%PDF-1.7\n")?
  let pdf = Attachment.file(path)?
  remove(path)?
  println(pdf.contentType)
  println("${len(pdf.data)}")
  return
}
```

That prints `application/pdf` and `9`. The `.PDF` in capitals still counts, since
extensions are read in lower case.

A file that cannot be read is a `MailError.Invalid` that names the path:
`attachment /var/inkwell/missing.pdf: cannot open file: /var/inkwell/missing.pdf`.
A file over 25 MiB is refused when it is read, before its bytes are loaded.

## An image inside the mail

The logo is not a download. Give the attachment a `cid`, a name of your choice,
and write that name in the HTML as `cid:<name>`:

```bit
import { Attachment, Mailer, Message, Options, Outbox } from "mail"
import { contains } from "std/strings"

fn main(): ()! {
  let logo = Attachment{
    name = "inkwell.png",
    data = [u8(137), u8(80), u8(78), u8(71)],
    cid = "logo",
  }
  let box = Outbox()
  let mailer = Mailer(box, Options{ from = "Inkwell <hello@inkwell.dev>" })?
  mailer.send(
    Message{
      to = ["Sara Ali <sara@example.com>"],
      subject = "Kim published \"Why we left Jira\"",
      html = "<img src=\"cid:logo\" alt=\"Inkwell\"><p>Read it at <a href=\"https://inkwell.dev/p/why-we-left-jira\">inkwell.dev</a>.</p>",
      attachments = [logo],
    },
  )?
  let raw = box.sent()[0].raw
  println("${contains(raw, "multipart/related")}")
  println("${contains(raw, "Content-ID: <logo>")}")
  mailer.close()
  return
}
```

That prints `true` twice. The HTML and the logo are written in a
`multipart/related` (RFC 2387), and the image carries `Content-ID: <logo>`, which
is what `cid:logo` in the HTML points at (RFC 2392). The message has no `text`,
so the package writes the plain-text part from the HTML, as it always does.
Inline and download attachments mix freely in one list.

`Attachment.file("logo.png", "logo")` does the same from a file: the second
argument is the `cid`.

## What is refused

The HTML and the `cid`s have to agree, and a mismatch is a mistake you want to
hear about before the mail goes out, because a mail client shows it as a broken
image or a stray attachment and says nothing. Each rule has its own message,
naming the attachment as `attachments[1]`:

```bit
import { Attachment, Mailer, Message, Options, Outbox } from "mail"

fn refusal(html: string, files: []Attachment): string {
  let mailer = Mailer(Outbox(), Options{ from = "Inkwell <hello@inkwell.dev>" }) catch e {
    return e.message()
  }
  mailer.render(
    Message{
      to = ["sara@example.com"],
      subject = "Kim published",
      html = html,
      text = "Kim published.",
      attachments = files,
    },
  ) catch e {
    return e.message()
  }
  return "ok"
}

fn main(): ()! {
  let logo = Attachment{ name = "inkwell.png", data = [u8(1)], cid = "logo" }
  println(refusal("", [logo]))
  println(refusal("<img src=\"cid:logo\"><img src=\"cid:hero\">", [logo]))
  println(refusal("<p>Hello</p>", [logo]))
  println(refusal("<img src=\"cid:logo\">", [logo, logo]))
  println(refusal("", [Attachment{ name = "", data = [u8(1)] }]))
  println(refusal("", [Attachment{ name = "a.pdf", data = [] }]))
  return
}
```

That prints one refusal per line:

```text
mail: attachments[0]: cid "logo" is inline and the message has no html to show it in
mail: html: refers to cid:"hero" and no attachment has that cid; set Attachment.cid
mail: attachments[0]: cid "logo" is never referenced: write cid:logo in the html, or clear Attachment.cid
mail: attachments[1]: duplicate cid "logo", already on attachments[0]
mail: attachments[0]: name is empty
mail: attachments[0]: data is empty ("a.pdf" has no bytes)
```

In order: an inline attachment needs an HTML body to show it in; an HTML
`cid:` needs an attachment with that `cid`; an inline attachment the HTML never
mentions is dead weight, and some clients list it as a broken attachment; two
attachments cannot share a `cid`; a name and some bytes are both required. A
`cid:` is found anywhere HTML writes a URL (an `src`, a CSS `url(...)`), in any
case, with `%XX` escapes decoded. A line break in `name`, `contentType` or `cid`
is refused too, so a value that came from a user cannot add a header.

## How much a mail may carry

All attachments together may be 25 MiB, which is what Gmail, Outlook and Resend
accept in practice. More is refused when the message is rendered:

```text
mail: attachments total 26 MiB; most providers refuse more than 25 MiB
```

The size counts the file bytes, before base64 makes them about a third larger.
A mail refused here would have been refused later by the provider, with a worse
message. For anything bigger, send a link.

## The type table

When `contentType` is empty the type comes from the extension of `name`, in any
case, from a table built into the package, so the answer is the same on every
machine. The types are the ones IANA registers:

| Extension | Type |
|---|---|
| `pdf` | `application/pdf` |
| `png`, `jpg`, `jpeg`, `gif`, `webp` | `image/png`, `image/jpeg`, `image/jpeg`, `image/gif`, `image/webp` |
| `svg` | `image/svg+xml` |
| `ics` | `text/calendar` |
| `csv`, `txt`, `html` | `text/csv`, `text/plain`, `text/html` |
| `json`, `xml` | `application/json`, `application/xml` |
| `zip`, `gz` | `application/zip`, `application/gzip` |
| `doc`, `docx` | `application/msword`, `application/vnd.openxmlformats-officedocument.wordprocessingml.document` |
| `xls`, `xlsx` | `application/vnd.ms-excel`, `application/vnd.openxmlformats-officedocument.spreadsheetml.sheet` |
| `ppt`, `pptx` | `application/vnd.ms-powerpoint`, `application/vnd.openxmlformats-officedocument.presentationml.presentation` |
| `odt`, `ods` | `application/vnd.oasis.opendocument.text`, `application/vnd.oasis.opendocument.spreadsheet` |
| `mp3`, `mp4`, `wav` | `audio/mpeg`, `video/mp4`, `audio/vnd.wave` |
| `eml` | `message/rfc822` |

Anything else, or a name with no extension, is `application/octet-stream`, which
mail clients treat as "a file, save it". The text types carry no `charset`; set
`contentType = "text/csv; charset=utf-8"` yourself when the file is UTF-8.

## Where to go next

[Messages](messages.md) lists every `Message` field and the other refusals.
[The Mailer](mailer.md) sends the message and shows the `Outbox` these examples
read it back from.
