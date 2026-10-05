# Let an author reset a forgotten password

Ada has not opened Inkwell in three months and cannot remember her password.
She types her address into "forgot password", Inkwell mails her a link, and
the link lets her choose a new one. Every part of that is a place to go wrong:
a form that says "no such author" lists your authors for anyone with a script,
a link that works twice is a standing key to her account, and a new password
that leaves the old sessions alive changes nothing for whoever was already
signed in as her.

`PasswordReset` is that flow, built on the one-time tokens of
[the account tokens chapter](account-tokens.md) the same way
[email verification](email-verification.md) and
[magic links](magic-link.md) are. It does not send mail and it does not own
your users table: you hand it a `lookup`, a `deliver` and a `setPassword`.

## The simplest thing that works

`lookup` finds the id of the author an address belongs to, or `None`.
`deliver` sends the link; here it writes to a list, which is what a
development build or a test wants. `setPassword` stores the new hash. `sessions`
is the store you gave `Config`, so a reset can end the author's sessions.

```bit
import { App, Config, MemoryStore, SessionStore, badRequest } from "web"
import {
  Deliver,
  InvalidToken,
  MemoryOneTimeStore,
  OneTimeTokens,
  PasswordReset,
  ResetOptions,
} from "auth"

class Authors {
  idsByEmail: map<string, string>,
  hashes: map<string, string>,
}

class Outbox {
  lines: []string,
}

@json class AskBody {
  email: string,
}

@json class ConfirmBody {
  token: string,
  password: string,
}

fn resetFlow(authors: Authors, outbox: Outbox, sessions: SessionStore): PasswordReset! {
  let lookup: (string) => Option<string> = (address) => {
    let (id, found) = authors.idsByEmail[address]
    if (!found) {
      return Option<string>.None
    }
    return Option<string>.Some(id)
  }
  let deliver: Deliver = (to, token, expiresAt) => {
    outbox.lines = append(outbox.lines, "to ${to}: https://inkwell.example/reset#${token}")
  }
  let setPassword: (string, string) => ()! = (id, hash) => {
    authors.hashes[id] = hash
  }
  let tokens = OneTimeTokens(MemoryOneTimeStore())?
  let opts = ResetOptions{
    lookup = lookup,
    deliver = deliver,
    setPassword = setPassword,
    sessions = sessions,
  }
  return PasswordReset(tokens, opts)?
}

fn routes(reset: PasswordReset, sessions: MemoryStore): App {
  let app = App(Config{ secret = "change-me", sessions = sessions })
  app.post("/reset", (c) => {
    let body = c.body<AskBody>()?
    reset.request(body.email)?
    return c.status(202)
  })
  app.post("/reset/confirm", (c) => {
    let body = c.body<ConfirmBody>()?
    reset.confirm(body.token, body.password) catch e {
      let (_, invalid) = e.(InvalidToken)
      if (invalid) {
        fail badRequest("this link has expired or was already used")
      }
      fail e
    }
    return c.status(204)
  })
  return app
}
```

`request` looks the address up and, if there is an author, makes a one-hour,
one-use token and calls `deliver` with the address, the token and the instant
it dies. `confirm` takes the token and the new password, spends the token,
stores the password's Argon2id hash with `setPassword`, and signs the author
out everywhere. A second `confirm` with the same token is an `InvalidToken`.

## The link and the page behind it

The token is the secret, so it should go to as few places as it can. A link
with the token in the URL fragment (`/reset#...`) is never sent to your server
by the browser, so it is in no access log and no proxy log. The page reads it
from `location.hash` and posts it in the body of `/reset/confirm`, never in a
query string. The page asks for no referrer, with `Referrer-Policy:
no-referrer` or `<meta name="referrer" content="no-referrer">`, so the address
is not sent on to another site when the page loads one. This package never
puts a token in an error message or a log line; do not put it in yours.

Mail scanners open every link in a message with a `GET` before the author sees
it. A page that only shows a form spends nothing, which is why the token is
redeemed by the form's `POST` and not by opening the link.

## Without telling anyone which addresses exist

`request` answers the same for an address that has an account and one that has
none, and does the same work: the same result and the same one atomic store
step. For an unknown address that step is on a decoy record no token can
reach, and `deliver` is not called. The route above answers `202` for both, and
the page says "if there is an account for that address, we sent a link", as the
OWASP Forgot Password Cheat Sheet asks.

That is also why a failed delivery is not returned. If `request` failed when
`deliver` did, only known addresses could ever fail, and the failure would say
which ones exist. `request` revokes the token nobody received and tells the
hook you set in `onError`, which is where the failure belongs: your log.

```bit
import { Deliver, MemoryOneTimeStore, OneTimeTokens, PasswordReset, ResetErrorHook, ResetOptions } from "auth"
import { SessionStore } from "web"

class Log {
  lines: []string,
}

fn withLogging(
  lookup: (string) => Option<string>,
  deliver: Deliver,
  setPassword: (string, string) => ()!,
  sessions: SessionStore,
  log: Log,
): PasswordReset! {
  let heard: ResetErrorHook = (e) => {
    log.lines = append(log.lines, "reset link not delivered: ${e.message()}")
  }
  let opts = ResetOptions{
    lookup = lookup,
    deliver = deliver,
    setPassword = setPassword,
    sessions = sessions,
    onError = heard,
  }
  return PasswordReset(OneTimeTokens(MemoryOneTimeStore())?, opts)?
}
```

The error is `deliver`'s own; it may name the address, and it never holds the
token. A hook that panics is caught, so it cannot change the answer.

What `deliver` costs is yours to even out. A mail sent inline takes a second
and an unknown address takes none, which a stopwatch can tell apart. Have
`deliver` put the mail on a queue and return. And put a rate limit in front of
`/reset`: a form that mails is a form a script can use to fill a stranger's
inbox.

## Only the newest link works

Ada asks, the mail is slow, she asks again. `request` issues with `Live.One`,
so the second token kills the first in the same atomic store step that saves
it; two requests at the same instant still leave exactly one live token. After
a reset, every other outstanding reset token of the author is revoked too.

## A password the policy refuses

NIST SP 800-63B asks that a new password is checked against the rules for
passwords. Pass the `PasswordPolicy` of
[Check a new password](password-policy.md) as `policy`; the app's own blocklist
and breach check, if it set them, apply here, and the package ships no list of
its own. A password the policy refuses fails with `PolicyViolations`, which
lists what to fix, and the token is not spent: Ada reads the list, types
another password and uses the same link. Only a holder of a live token ever
reaches the policy, so its breach check is not a free proxy for strangers.

```bit
import { PasswordPolicy, PasswordReset, PolicyViolations, ResetOptions } from "auth"

fn setNewPassword(reset: PasswordReset, token: string, password: string): string {
  reset.confirm(token, password) catch e {
    let (found, refused) = e.(PolicyViolations)
    if (!refused) {
      return e.message()
    }
    let tooShort = false
    for v of found.violations {
      match (v) {
        TooShort(_) => tooShort = true
        _ => {}
      }
    }
    if (tooShort) {
      return "choose a longer password"
    }
    return e.message()
  }
  return "saved"
}

fn withPolicy(opts: ResetOptions): ResetOptions! {
  opts.policy = Option<PasswordPolicy>.Some(PasswordPolicy()?)
  return opts
}
```

Without a policy the only rule is that the password is not empty. A policy
that normalizes records it in the hash, so signing in later verifies the way
the password was set.

## Ending the author's sessions

A reset is a credential change, and OWASP ASVS v5 asks that the other sessions
end with it. `confirm` calls `logoutEverywhere` ([Sign an author out of every
device](logout-everywhere.md)) for the author, so the laptop, the phone and
the library computer are all signed out, and the person who asked is too: the
page sends them to the sign-in form with the password they just chose. Other
authors' sessions are untouched.

## How long a link lives

`ttl` is in seconds and defaults to 3600, an hour, short as the OWASP cheat
sheet and NIST SP 800-63B ask of a recovery secret. It cannot be longer than
the `maxTtl` of the `OneTimeTokens` underneath.

## Sharp edges

- A missing `lookup`, `deliver`, `setPassword` or `sessions`, and a `ttl`
  below 1 or above `maxTtl`, fail when `PasswordReset` is built, with a
  message naming the option. The app does not start with a reset that cannot
  work.
- Every bad token is the same `InvalidToken`: unknown, expired, used,
  malformed, or from another flow (an address confirmation or a magic link). The
  token is spent in each case, so a refused link is never tried twice.
- The token is spent before `setPassword` runs. If `setPassword` fails, its
  error is returned as it came and Ada asks for a new link. A refused policy
  is the one exception.
- If ending the sessions fails after the password was stored, the error is
  returned as it came: treat it as an incident, the password has changed and
  an old session may still be alive.
- The address is used as given. If your users table lowercases addresses,
  lowercase them before `request`.
- `MemoryOneTimeStore` forgets every token when the process restarts, and with
  more than one server the sessions and the tokens both need a shared store;
  see [Your own store](account-tokens.md#your-own-store).
- A store failure in `request` is returned as it came, a 500, for known and
  unknown addresses alike.

## Where to go next

- [One-time tokens for account emails](account-tokens.md) is the primitive
  under this flow.
- [Check a new password](password-policy.md) is the policy `confirm` applies.
- [Sign an author out of every device](logout-everywhere.md) is the call that
  ends the sessions.
- [Slow down password guessing](brute-force.md) is the throttle for the form
  that asks for the mail.
