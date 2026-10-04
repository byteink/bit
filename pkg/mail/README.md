# pkg/mail

Email for Bit programs, from a sign-up form to a business sending millions.
This first release is the address layer every later part builds on: read the
`Sara Ali <sara@example.com>` a person typed into a form, a config file or a
`From` header, and get back a checked `Address` with the display name decoded
and nothing in it that could add a header line of its own.

## Install

`bit add bitlang.org/pkg/mail@v0.1.0` writes:

```json
{
  "dependencies": {
    "mail": "bitlang.org/pkg/mail@v0.1.0"
  }
}
```

## Usage

```bit
import { parseAddress } from "mail"

fn main(): ()! {
  let who = parseAddress("\"Ali, Sara\" <sara@example.com>")?
  println(who.name)
  println(who.email)
  println(who.toString())
  return
}
```

That prints `Ali, Sara`, `sara@example.com` and `"Ali, Sara" <sara@example.com>`.
Anything that is not a single, safe mailbox fails with a `MailError` that says
which input and why, so a form can show it as it is.

Everything else - what is accepted and what is refused and why, address lists,
and the errors - is in [`docs/`](docs/README.md).

For how first-party packages in this repository are laid out, gated,
versioned and released, see [`pkg/README.md`](../README.md).
