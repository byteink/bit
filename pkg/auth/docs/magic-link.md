# Sign in with a link in an email

Inkwell's authors write a few times a week. Nobody remembers a password they
use that rarely, so they click "forgot password" every visit, or reuse one
from somewhere else. A magic link drops the password: the author types their
address, Inkwell mails a link, and opening the link signs them in.

`MagicLinkStrategy` is that login, built on the one-time tokens of
[the account tokens chapter](account-tokens.md) the same way
[email verification](email-verification.md) is. It is a `Strategy`, so it
mounts with `requireAuth` beside the password login. It does not send mail and
it does not own your users table: you hand it a `lookup` and a `deliver`.

## The simplest thing that works

`lookup` finds the user an address belongs to, or `None`. `deliver` sends the
link; here it writes to a list, which is what a development build or a test
wants. Two routes use the strategy: one asks for a link, one redeems it.

```bit
import { App, Config, MemoryStore } from "web"
import { Json } from "std/json"
import {
  Deliver,
  MagicLinkOptions,
  MagicLinkStrategy,
  MagicLinkUser,
  MemoryOneTimeStore,
  OneTimeTokens,
  Strategy,
  currentIdentity,
  requireAuth,
  verifyLink,
} from "auth"

class Authors {
  idsByEmail: map<string, string>,
}

class Outbox {
  lines: []string,
}

fn magicLinks(authors: Authors, outbox: Outbox): MagicLinkStrategy! {
  let lookup: (string) => Option<MagicLinkUser> = (address) => {
    let (id, found) = authors.idsByEmail[address]
    if (!found) {
      return Option<MagicLinkUser>.None
    }
    return Option<MagicLinkUser>.Some(MagicLinkUser{ id = id, claims = Json.JsonNull })
  }
  let deliver: Deliver = (to, token, expiresAt) => {
    let link = verifyLink("https://inkwell.example/magic/open", token)?
    outbox.lines = append(outbox.lines, "to ${to}: ${link}")
  }
  let tokens = OneTimeTokens(MemoryOneTimeStore())?
  let opts = MagicLinkOptions{ lookup = lookup, deliver = deliver }
  return MagicLinkStrategy(tokens, opts)?
}

fn routes(magic: MagicLinkStrategy): App {
  let app = App(Config{ secret = "change-me", sessions = MemoryStore(10_000) })
  app.post("/magic", (c) => {
    magic.request(c, c.query("email"))?
    return c.status(202)
  })
  let redeem = app.group("/magic/redeem")
  redeem.use(requireAuth([]Strategy{ magic }))
  redeem.post("/", (c) => c.text("welcome"))
  app.get("/me", (c) => c.text(currentIdentity(c)?.id))
  return app
}
```

`request` looks the address up and, if there is an author, makes a ten-minute
one-use token and calls `deliver` with the address, the token and the instant
it dies. The link the mail carries is `verifyLink`'s: a base URL you wrote
down, never the request's `Host` header, with the token as its `token` query
parameter. Redeeming goes through `requireAuth` like the password login does:
it calls `authenticate`, which reads `{"token": "..."}` from the body, spends
the token, and returns the author's `Identity`; `requireAuth` stores it, and
`/me` reads it back.

The session id changes on the way: `authenticate` calls
`Session.regenerate()` before it returns, so a session id an attacker planted
in the author's browser before the login is dead after it. See
[Security model](security.md).

## The page behind the link

Mail scanners and link previewers open every link in a message with a `GET`,
before the author sees it. If opening the link signed in, the scanner would
spend the token and the author would find a dead link. So the link does not
call `authenticate`. It opens a page with a button, and the button's `POST`
does.

```bit
import { App } from "web"

fn openPage(app: App) {
  app.get("/magic/open", (c) => {
    let page = "<!doctype html><title>Sign in to Inkwell</title>" +
      "<meta name=\"referrer\" content=\"no-referrer\">" +
      "<button id=\"go\">Sign in to Inkwell</button>" +
      "<script>document.getElementById('go').onclick = function () {" +
      "var t = new URLSearchParams(location.search).get('token');" +
      "fetch('/magic/redeem', { method: 'POST', credentials: 'same-origin'," +
      " headers: { 'Content-Type': 'application/json' }," +
      " body: JSON.stringify({ token: t }) })" +
      ".then(function (r) { location = r.ok ? '/me' : '/magic/expired'; });" +
      "};</script>"
    return c.bytes(page, "text/html; charset=utf-8")
  })
}
```

The body is JSON, as for the password login; a plain form post is not read. The
page asks for no referrer so the token in its address is not sent on to
another site, and a strict `Content-Security-Policy` needs the script served
from a file of yours instead of inline.

## Only the newest link works

Ada asks for a link, the mail is slow, she asks again. Now two links are in
her mailbox. `request` issues with `Live.One`, so the second kills the first in
the same atomic store step that saves it; two requests at the same instant
still leave exactly one live link. Only the last mail works.

If `deliver` fails, the link it was about to send is revoked, because nobody
has it. What happens next is the next section's subject.

## Without telling anyone which addresses exist

A form that answers "no such author" for an unknown address is a list of your
authors for anyone with a script. `request` answers the same for an address
that has an account and one that has none, and does the same work: the same
result, the same write to the session, and the same one atomic store step. For
an unknown address that step is on a decoy record no link can reach, and
`deliver` is not called.

That is also why a failed delivery is not returned. If `request` failed when
`deliver` did, only known addresses could ever fail, and the failure would
say which ones exist. `request` revokes the link and tells the hook you set in
`onDeliveryError`, which is where the failure belongs: your log.

```bit
import { MagicLinkErrorHook, MagicLinkOptions } from "auth"

class Log {
  lines: []string,
}

fn withLogging(opts: MagicLinkOptions, log: Log): MagicLinkOptions {
  let heard: MagicLinkErrorHook = (e) => {
    log.lines = append(log.lines, "magic link not delivered: ${e.message()}")
  }
  opts.onDeliveryError = heard
  return opts
}
```

The error is `deliver`'s own; it may name the address, and it never holds the
token. A hook that panics is caught, so it cannot change the answer.

What `deliver` costs is yours to even out. A mail sent inline takes a second
and an unknown address takes none, which a stopwatch can tell apart. Have
`deliver` put the mail on a queue and return, so a known address does the same
work as an unknown one. The same page of advice is in the OWASP Forgot Password
Cheat Sheet.

A malformed address, one with a space, a comma or a newline in it, is a 400:
that depends only on what the visitor typed, not on who you have.

## Opening the link in the same browser

A link is bound to the browser that asked for it. `request` stores a random
value in that browser's session and in the token, and `authenticate` refuses a
link whose value is not in the session it arrives with. Two attacks stop here.
In login CSRF the attacker asks for a link for their own account and gets a
victim's browser to open it, so the victim is signed in as the attacker. And a
link forwarded, or leaked from a mailbox, is refused in any browser but the one
that asked.

The cost is real: an author who asks on the laptop and opens the mail on the
phone, or in a mail app's own browser, is refused, and the link is spent. They
ask again from the browser they will use. If your authors read mail on a device
other than the one they sign in on, turn the binding off.

```bit
import { Deliver, MagicLinkOptions, MagicLinkUser } from "auth"

fn crossDevice(lookup: (string) => Option<MagicLinkUser>, deliver: Deliver): MagicLinkOptions {
  return MagicLinkOptions{ lookup = lookup, deliver = deliver, bindToBrowser = false }
}
```

Without the binding, anyone holding the link can sign in as Ada until it is
used or expires, which is what ten minutes and one use are for.

## Slowing a script down

A form that mails is a form a script can use to fill a stranger's inbox, and a
login that takes a token is one a script can guess at. Pass the
`LoginThrottle` of [Slow down password guessing](brute-force.md) as
`throttle`. It is asked before `request` works, and counts every request
against the address and the caller, whether or not the address has an account,
so a refusal looks the same for both. In `authenticate` it counts every refused
link against the caller's address and forgets the count when a link works. A
refusal is the throttle's `Throttled`, a 429 with `Retry-After`.

Give it a throttle of its own. The address counter of a shared one is also fed
by every password attempt, and a thousand authors behind one office address
would lock each other out.

```bit
import { Deliver, LoginThrottle, MagicLinkOptions, MagicLinkUser, ThrottleOptions } from "auth"
import { MemoryCounter } from "web"

fn throttled(lookup: (string) => Option<MagicLinkUser>, deliver: Deliver): MagicLinkOptions! {
  let policy = ThrottleOptions{ accountFailures = 3, window = 3600 }
  let throttle = LoginThrottle(MemoryCounter(10_000), policy)?
  return MagicLinkOptions{
    lookup = lookup,
    deliver = deliver,
    throttle = Option<LoginThrottle>.Some(throttle),
  }
}
```

With three allowed a hour, the first request is answered, a second one at once
waits a second, and the fourth locks the address for the window.

## How long a link lives

`ttl` is in seconds and defaults to 600, ten minutes: short, as NIST SP 800-63B asks of an
out-of-band secret. It cannot be longer than the `maxTtl`
of the `OneTimeTokens` underneath.

```bit
import { Deliver, MagicLinkOptions, MagicLinkUser } from "auth"

fn fiveMinutes(lookup: (string) => Option<MagicLinkUser>, deliver: Deliver): MagicLinkOptions {
  return MagicLinkOptions{ lookup = lookup, deliver = deliver, ttl = 300 }
}
```

## Sharp edges

- A missing `lookup` or `deliver`, and a `ttl` below 1 or above `maxTtl`, fail
  when `MagicLinkStrategy` is built, with a message naming the option. The app
  does not start with a login that cannot work.
- Every bad link is the same `401`: unknown, expired, used, malformed, a token
  from another flow (a password reset or an address confirmation), a link
  opened in another browser, and an author deleted since. The token is spent in
  each case, so a refused link is never tried twice.
- `authenticate` looks the address up again, so a user who is gone, or whose
  id changed, is refused even with a good link in hand.
- The address is used as given. If your users table lowercases addresses,
  lowercase them before `request`.
- The token is in the link and nowhere else. This package never puts it in an
  error or a log line; do not put it in yours.
- `MemoryOneTimeStore` forgets every link when the process restarts, and with
  more than one server the sessions and the tokens both need a shared store;
  see [Your own store](account-tokens.md#your-own-store).
- A store failure is returned as it came, a 500, for known and unknown
  addresses alike.

## Where to go next

- [One-time tokens for account emails](account-tokens.md) is the primitive under
  this flow.
- [Confirm an author's email address](email-verification.md) is the same flow
  for proving an address, and shares `verifyLink`.
- [Slow down password guessing](brute-force.md) is the throttle.
- [Security model](security.md) explains the session id change.
