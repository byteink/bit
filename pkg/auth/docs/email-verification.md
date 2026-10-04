# Confirm an author's email address

An Inkwell author signs up with `ada@example.com`. Nothing says the address is
hers. Without a check, someone can register an address they do not own and sit
on it: when Ada signs up later, the account already exists, or the real owner
of the mailbox receives mail for a stranger's account. And every typo in the
form is a bounce that damages the sender's reputation.

The check is a link in a mail. Whoever opens it controls the mailbox.
`EmailVerification` is that flow, built on the one-time tokens of
[the previous chapter](account-tokens.md): it mails a link when an author signs
up, and marks the address verified when the link is opened. It does not send
mail itself and it does not own your users table; you hand it three functions.

## The simplest thing that works

The three functions are `deliver`, which sends the link, `markVerified`, which
records the address as verified, and `currentEmail`, which reads the address on
file. Here `deliver` writes to a list, which is what a development build or a
test wants, and the users are two maps.

```bit
import {
  Deliver,
  EmailVerification,
  MemoryOneTimeStore,
  OneTimeTokens,
  VerifyOptions,
  verifyLink,
} from "auth"

class Users {
  emails: map<string, string>,
  verified: map<string, bool>,
}

class Outbox {
  lines: []string,
}

fn verification(users: Users, outbox: Outbox): EmailVerification! {
  let deliver: Deliver = (to, token, expiresAt) => {
    let link = verifyLink("https://inkwell.example/confirm", token)?
    outbox.lines = append(outbox.lines, "to ${to}: ${link}")
  }
  let markVerified: (string, string) => ()! = (userId, email) => {
    users.verified[userId] = true
  }
  let currentEmail: (string) => string! = (userId) => {
    let (email, found) = users.emails[userId]
    if (!found) {
      return ""
    }
    return email
  }
  let tokens = OneTimeTokens(MemoryOneTimeStore())?
  let opts = VerifyOptions{
    deliver = deliver,
    markVerified = markVerified,
    currentEmail = currentEmail,
  }
  return EmailVerification(tokens, opts)?
}

fn signUp(v: EmailVerification, users: Users, authorId: string, email: string): ()! {
  users.emails[authorId] = email
  v.send(authorId, email)?
}

fn linkOpened(v: EmailVerification, token: string): ()! {
  v.confirm(token)?
}
```

`send` makes a one-purpose, one-day token that carries the address, and calls
`deliver` with the address, the token and the instant the token dies. `confirm`
takes the token back, and, if everything checks out, calls `markVerified` with
the user and the address that was proven. The token is spent before that call,
so a second click, a replayed link and a mail scanner that opens every link
cannot call it twice.

## Building the link

The link is `https://inkwell.example/confirm?token=...`, and the base of it is
yours to configure, not the request's. If the server builds a link from the
`Host` header, an attacker who sends `Host: evil.example` with Ada's address
gets Ada a mail whose button opens their site, with her token in the URL.

`verifyLink(baseUrl, token)` builds the link from a base the app wrote down,
and refuses a base that could be bent: not `https://`, no host, a query, a
fragment, a `user@` in front of the host, a space or a control character. Plain
`http://` is accepted for `localhost`, `127.0.0.1` and `[::1]`, so a development
build works. The token is checked to be what `OneTimeTokens.issue` makes, 43
URL-safe characters, so nothing else is ever appended.

```bit
import { verifyLink } from "auth"

fn confirmLink(token: string): string! {
  return verifyLink("https://inkwell.example/confirm", token)?
}

fn devLink(token: string): string! {
  return verifyLink("http://localhost:8080/confirm", token)?
}
```

## The address can change

Ada signs up with a typo, `ada@exmaple.com`, then fixes it to
`ada@example.com`. The link already sent to the typo's mailbox, if anyone owns
it, proves nothing about the new address. So the token carries the address it
was sent to, and `confirm` compares it with `currentEmail(userId)`. If they
differ the link is refused, and `markVerified` is not called.

This is also why `currentEmail` returns `""` for a user that no longer exists:
a link for a deleted account is refused like any other. A `currentEmail` that
*fails* is a store failure, and `confirm` returns it as it came.

## Sending it again

Ada did not get the mail. She clicks "send it again", and now there are two
links, the first of them in a mailbox she may no longer control. `send` revokes
every earlier link of that user before it issues the new one, so only the last
mail works. Another author's links are untouched.

If `deliver` fails, the link it was about to send is revoked too, because nobody
has it, and `send` returns the failure for you to log. Do not show it to the
visitor.

Two `send` calls at the same instant for one user can both survive, and Ada
holds two live links to the same address. Neither is stronger than the other,
and the next `send` revokes both.

## Without telling anyone which addresses exist

A "send it again" form that says "no such account" for an unknown address is a
list of your users for anyone with a script. The form answers the same thing
whether the address is registered or not, and does the same visible work. The
route below looks the author up, calls `send` only when there is one, and
returns `202` either way.

Slow the form down as well. An endpoint that sends mail is one a script can use
to fill a stranger's inbox, and the `rateLimit` middleware of `pkg/web` already
does the counting: no new code, just compose it in front of the route.

```bit
import { App, Config, MemoryCounter, MemoryStore, Limit, byIp, rateLimit } from "web"
import { EmailVerification, InvalidToken } from "auth"

class Directory {
  idsByEmail: map<string, string>,
}

fn routes(v: EmailVerification, dir: Directory): App! {
  let app = App(Config{ secret = "change-me", sessions = MemoryStore(10_000) })
  let resend = app.group("/resend")
  let limit = Limit{
    requests = 3,
    window = 3600,
    by = byIp,
    store = MemoryCounter(10_000),
    name = "resend",
  }
  resend.use(rateLimit(limit))
  resend.post("/", (c) => {
    let address = c.query("email")
    let (authorId, found) = dir.idsByEmail[address]
    if (found) {
      v.send(authorId, address)?
    }
    return c.status(202)
  })
  app.post("/confirm", (c) => {
    v.confirm(c.query("token")) catch e {
      let (_, invalid) = e.(InvalidToken)
      if (invalid) {
        return c.status(400)
      }
      fail e
    }
    return c.status(200)
  })
  return app
}
```

The limit is per address of the caller, three a hour. A limit per mailbox as
well, so one address cannot be flooded from many callers, is the same `Limit`
with a `by` function that reads the `email` parameter.

A refusal in `confirm` is always `InvalidToken` and always the same `400`. An
unknown token, an expired one, one already used, one for another flow, one for
an address the author has since changed and a string that is not a token look
identical to the client. Anything else `confirm` fails with is yours, a store that is down, and
the route lets it escape as a `500` instead of describing it to the client.

## Where the options are tuned

`VerifyOptions.ttl` is how long a link lives, in seconds: one day unless you
say otherwise. It cannot be longer than the `maxTtl` of the `OneTimeTokens`
underneath, 30 days.

```bit
import {
  Deliver,
  EmailVerification,
  MemoryOneTimeStore,
  OneTimeTokens,
  VerifyOptions,
} from "auth"

fn shortLived(deliver: Deliver): EmailVerification! {
  let tokens = OneTimeTokens(MemoryOneTimeStore())?
  let markVerified: (string, string) => ()! = (userId, email) => {}
  let currentEmail: (string) => string! = (userId) => ""
  let opts = VerifyOptions{
    deliver = deliver,
    markVerified = markVerified,
    currentEmail = currentEmail,
    ttl = 3600,
  }
  return EmailVerification(tokens, opts)?
}
```

## Sharp edges

- A missing `deliver`, `markVerified` or `currentEmail`, and a `ttl` below 1 or
  above `maxTtl`, fail when `EmailVerification` is built, with a message naming
  the option. The app does not start with a flow that cannot work.
- `send` fails for an empty user id, and for an address that is not one address:
  empty, longer than 254 bytes, without exactly one `@`, or holding a space, a
  control character or one of `<>,;"\`. A newline in an address is how a mail
  header is injected, so it is caught here and not left to the mail library.
- The token is in the link and nowhere else. This file never puts it in an
  error or a log line; do not put it in yours, and keep the confirm page behind
  `Referrer-Policy: no-referrer`. Redeem on a `POST` rather than on the `GET`
  that a mail scanner may follow, as the previous chapter says.
- If `markVerified` fails, the link is already spent. `confirm` returns the
  failure; Ada asks for another link.
- The address is compared exactly. If your users table lowercases addresses,
  lowercase them before `send` as well.
- `MemoryOneTimeStore` forgets every link when the process restarts. A
  deployment with more than one server gives `OneTimeTokens` a shared store;
  see [Your own store](account-tokens.md#your-own-store).

## Where to go next

- [One-time tokens for account emails](account-tokens.md) is the primitive under
  this flow, and the other flows on it: password reset and magic links.
- [Slow down password guessing](brute-force.md) throttles the login this
  address is verified for.
