# Messages

When an author on Inkwell publishes a post, every subscriber gets a mail. The
mail is one value, a `Message`: who it is from, who it is for, what it says.
You build it with the fields you need and leave the rest out; nothing is checked
until the message is turned into bytes to send, so one refusal names the whole
message at once.

<!-- doctest: per-block -->

## A message

```bit
import { Message } from "mail"

fn main(): ()! {
  let m = Message{
    from = "Inkwell <hello@inkwell.dev>",
    to = ["Sara Ali <sara@example.com>"],
    subject = "Kim published \"Why we left Jira\"",
    text = "Read it at https://inkwell.dev/p/why-we-left-jira",
  }
  println(m.from)
  println("${len(m.to)} recipient")
  println("html set: ${m.html != ""}")
  return
}
```

That prints the From, `1 recipient` and `html set: false`. A `Message` is plain
data. `from`, `to`, `cc`, `bcc` and `replyTo` take addresses the way people
write them, the same text `parseAddress` reads, and a list names the element at
fault (`to[1]`) when one is refused. An omitted text field is `""`, an omitted
list is empty.

## Every field

```bit
import { Message } from "mail"

fn main(): ()! {
  let m = Message{
    from = "Inkwell <hello@inkwell.dev>",
    to = ["Sara Ali <sara@example.com>"],
    cc = ["kim@example.com"],
    bcc = ["audit@inkwell.dev"],
    replyTo = ["Support <support@inkwell.dev>"],
    subject = "Re: Why we left Jira",
    text = "Thanks for the comment, Sara.",
    html = "<p>Thanks for the comment, Sara.</p>",
    headers = { "X-Post": "why-we-left-jira" },
    tags = { "campaign": "comments" },
    inReplyTo = "<comment-41@inkwell.dev>",
    references = ["<post-9@inkwell.dev>", "<comment-41@inkwell.dev>"],
    id = "reply-41",
  }
  println(m.subject)
  println(m.headers["X-Post"])
  println(m.tags["campaign"])
  println(m.id)
  return
}
```

* **`from`** is the sender. Empty means the mailer's default From; with neither,
  the message is refused.
* **`to`, `cc`** are the visible recipients, **`bcc`** the blind ones: delivered
  to, and never written into any header. At least one of the three is required,
  and an address that appears in two of them is delivered to once.
* **`replyTo`** is where a reply goes instead of to `from`.
* **`subject`** is required. Non-ASCII text is sent as an RFC 2047 encoded word.
* **`text`** and **`html`**: at least one is required. Send both and mail
  clients pick the one they can show.
* **`attachments`** are files sent with the mail, and pictures shown inside
  its HTML; see [Attachments](attachments.md).
* **`headers`** are extra header fields, written sorted by name. Names the
  package owns (`From`, `To`, `Date`, `Message-ID`, `Content-*` and the like)
  are refused, and so is a value holding a line break. Every message also gets
  `Auto-Submitted: auto-generated` (RFC 3834), so auto-responders do not answer
  it; set `Auto-Submitted` in `headers` to send your own value instead.
* **`tags`** are labels for your own bookkeeping. They are never written into
  the message.
* **`inReplyTo`** is the Message-ID of the mail this one answers, with or
  without the `<>`. It becomes the `In-Reply-To` header, and **`references`**,
  the ids of the thread so far, oldest first, get it appended to become the
  `References` header, each id once.
* **`id`** names this message's own Message-ID: `reply-41` becomes
  `<reply-41@inkwell.dev>`, at the From address's domain, so a later mail can
  put it in `inReplyTo`. Only letters, digits and the symbols RFC 5322 allows in
  an id are accepted. Empty means a fresh unique id.

## What is refused

Four mistakes are the program's, not the user's, and each has its own text:

```text
mail: Message.from is empty and Options.from is not set
mail: Message has no recipient: set to, cc or bcc
mail: Message has no body: set text or html
mail: Message.subject is empty
```

Everything else is a `MailError.Invalid` naming the field, such as
`to[1]: invalid address "no-at-sign": no @ sign`, `id: "a b" is not
dot-atom-text: ...` or `headers["X-Post"]: the value contains a CR, LF or NUL
(header injection)`. A raw line break from the input never appears in the text.

## Where to go next

The package front page is [README](../README.md). Addresses are in
[Addresses](addresses.md); the mailer that sends a `Message` is in
[The Mailer](mailer.md); files and inline images are in
[Attachments](attachments.md).
