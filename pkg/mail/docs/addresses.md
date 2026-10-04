# Addresses

Inkwell's sign-up form has one field, "Your email", and people fill it in with
what they have: `sara@example.com`, `Sara Ali <sara@example.com>`, a name
copied out of a mail client with a comma in it, or a line pasted from a
spreadsheet with a newline at the end. Whatever the field holds ends up in a
database row, in an envelope and in a header, so it has to be checked once,
up front, by something that knows the rules. That is `parseAddress`.

<!-- doctest: per-block -->

## One address, checked

```bit
import { parseAddress } from "mail"

fn main(): ()! {
  let a = parseAddress("  sara@example.com ")?
  println(a.email)
  return
}
```

Surrounding whitespace is dropped. What comes back is an `Address` with two
fields: `email`, the address mail is delivered to, and `name`, the display
name, empty when there was none.

Compare addresses with `email`. The local part comes back in its shortest
valid spelling, so `"sara"@example.com` and `sara@example.com` are the same
`email`. The domain is kept exactly as typed: `Sara@Example.COM` stays
`Sara@Example.COM`, because domains are case-insensitive but the part before
the `@` may not be, and this package does not guess for you.

## A name people can read

```bit
import { parseAddress } from "mail"

fn main(): ()! {
  let a = parseAddress("=?UTF-8?Q?Jos=C3=A9_Garc=C3=ADa?= <jose@example.com>")?
  println(a.name)
  println(a.toString())
  return
}
```

This prints `José García` and `José García <jose@example.com>`. Mail clients
write non-ASCII names as RFC 2047 encoded words (`=?UTF-8?Q?...?=`, or the
`B` base64 form); `name` is always the decoded UTF-8 text. UTF-8 and ASCII,
ISO-8859-1 and Windows-1252 words are decoded. A word in any other charset
is refused by name rather than shown as garbage.

Names with commas, quotes or other punctuation come out of `toString()`
quoted, the way they must be written into a header, and `parseAddress` reads
that text back to the same `Address`:

```bit
import { Address, parseAddress } from "mail"

fn main(): ()! {
  let a = Address{ name = "Ali, Sara", email = "sara@example.com" }
  let text = a.toString()
  println(text)
  let back = parseAddress(text)?
  println("${back.name == a.name}")
  return
}
```

`"Ali, Sara" <sara@example.com>`, then `true`.

## Several at once

Inkwell lets an author invite co-authors by pasting a list.
`parseAddressList` splits it on the commas that separate mailboxes, not on
the one inside `"Ali, Sara"`:

```bit
import { parseAddressList } from "mail"

fn main(): ()! {
  let invited = parseAddressList("sara@example.com, \"Ali, Sara\" <sara.ali@example.com>, kim@example.com")?
  for a of invited {
    println(a.email)
  }
  return
}
```

Order is kept. An empty element (`a@example.com,,b@example.com`) is refused,
and so is anything `parseAddress` refuses, naming the one mailbox at fault.
`parseAddress` on a list fails with "more than one address", so a field that
takes one address cannot be handed two.

## When the input is wrong

Every refusal is `MailError.Invalid` with the input and the reason in its
message, ready to show next to the field:

```bit
import { MailError, parseAddress } from "mail"

fn check(field: string): string {
  parseAddress(field) catch e {
    match (e) {
      Invalid(why) => return why
    }
  }
  return ""
}

fn main(): ()! {
  println(check("sara.example.com"))
  println(check("sara@exam..ple.com"))
  println(check("sara@example.com\r\nBcc: boss@example.com"))
  return
}
```

```text
invalid address "sara.example.com": no @ sign
invalid address "sara@exam..ple.com": the domain has an empty label (a dot at the start or end, or two in a row)
invalid address "sara@example.com\r\nBcc: boss@example.com": the input contains a CR (header injection)
```

The message shows a control character as `\r` or `\n`, never as the real
byte, and cuts a very long input, so putting it in a log line cannot be used
to forge another line.

## What is refused, and why

* **CR, LF, NUL and every other control byte, anywhere.** A line break in an
  address is how a form field becomes an extra `Bcc:` header. This applies to
  display names too after their encoded words are decoded, so
  `=?UTF-8?B?DQo=?=` (an encoded line break) is caught as well. Invalid
  UTF-8 and the Unicode line separators (U+0085, U+2028, U+2029) are refused
  for the same reason.
* **Comments, `Sara (work) <...>`.** They are obsolete, and two parsers
  disagreeing about where a comment ends is a known way to make a checker
  and a mail server read different addresses.
* **Group syntax, `team: a@x.com, b@x.com;`, and source routes.** A sender
  never needs them.
* **A domain literal, `sara@[1.2.3.4]`.** Submission never needs it.
* **More than one address**, from `parseAddress`.
* **Size.** A local part over 64 octets, an address over 254, a domain label
  over 63 or empty.
* **Whitespace around an address with no name brackets**, as in
  `Sara sara@example.com`. The error says to put the address in `<...>`.

International addresses are accepted: UTF-8 in the display name, the local
part and the domain, as `Zoë <zoë@bücher.example>`. The domain stays as
written. Turning it into its ASCII form for the wire happens when a message
is sent, not here.

## Where to go next

The package front page is [README](../README.md). The sending API, built on
these addresses, arrives in the next chapters of this documentation.
