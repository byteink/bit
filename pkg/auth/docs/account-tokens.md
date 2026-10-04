# One-time tokens for account emails

Inkwell wants to mail an author a link: "confirm this address", "reset your
password", "sign in without a password". Each link carries a secret, and each
is a place apps get it wrong. The token is saved in plaintext, so a leaked
database backup is a set of working links. It never expires, or it can be used
twice, or a link meant for confirming an address also resets a password
because nothing says what it was for.

`OneTimeTokens` is the primitive all three flows share. A token it issues is
256 random bits, is stored only as a SHA-256 hash, works for one purpose,
expires, and redeems exactly once. This page builds Inkwell's "confirm your
address" link on it; password reset and magic links are the same three calls
with another purpose string.

## The simplest thing that works

`issue` makes a token for a purpose and a subject (whom it is for) and a
lifetime in seconds. `redeem` takes the token and the purpose it must have been
issued for, and returns what was stored. `MemoryOneTimeStore` keeps the hashes
in this process, which is all a first version and every test needs.

```bit
import { OneTimeTokens, MemoryOneTimeStore, OneTimeRecord } from "auth"

fn confirmAddress(): OneTimeRecord! {
  let tokens = OneTimeTokens(MemoryOneTimeStore())?
  let token = tokens.issue("verify-email", "author-17", 86400, "ada@example.com")?
  return tokens.redeem(token, "verify-email")?
}
```

`token` is 43 URL-safe characters, so it goes in a link as it is:
`https://inkwell.example/confirm?t=${token}`. The returned `OneTimeRecord` has
the `purpose` and `subject` it was issued with and the `data` string, here the
address being confirmed, so the confirm page does not have to trust anything
else in the request. `expiresAt` is the instant the token died, in seconds
since the epoch.

Run `redeem` a second time on the same token and it fails. So does a token
that is a day old, a token for another purpose, a token someone made up, and
a string that is not a token at all.

## Every failure looks the same

Those five failures are one error, `InvalidToken`, with one message. A client
probing the confirm page learns nothing about whether a token ever existed,
had expired, or was meant for something else. Your route answers all of them
with the same page.

```bit
import { InvalidToken, OneTimeTokens } from "auth"

fn confirmed(tokens: OneTimeTokens, token: string): bool! {
  let rec = tokens.redeem(token, "verify-email") catch e {
    let (_, invalid) = e.(InvalidToken)
    if (invalid) {
      return false
    }
    fail e
  }
  return rec.subject != ""
}
```

A failure that is not `InvalidToken` is the store's, a database that is down,
say. It is returned as it came, since the operator needs to see it and a
client cannot cause it. Do not show it to the client.

A token redeemed for the wrong purpose is consumed. Someone who takes a
confirm link and tries it at the password reset page has burned it, and the
author asks for another. A guess that leaves the token alive would be free.

## A new request replaces the old one

An author who clicks "send it again" has two live links, and the first is
still in a mailbox the author may no longer control. `revokeSubject` drops
every live token of one purpose for one subject. Call it, then `issue`:

```bit
import { OneTimeTokens } from "auth"

fn resend(tokens: OneTimeTokens, authorId: string, address: string): string! {
  tokens.revokeSubject("verify-email", authorId)?
  return tokens.issue("verify-email", authorId, 86400, address)?
}
```

Revoking one purpose leaves the others alone: a pending password reset
survives a resent confirmation.

## Sending the token

The primitive makes tokens and does not send mail. The app supplies the
delivery as a `Deliver`, a function from the address, the token and the expiry
to nothing, that may fail. The password reset, email verification and
magic-link flows all take one, so the code that mails a link is written once.
This one writes to a list, which is what a development build or a test wants;
`pkg/mail` will replace it when it ships.

```bit
import { Deliver, OneTimeTokens } from "auth"
import { now, Second } from "std/time"

fn sendConfirmation(
  tokens: OneTimeTokens,
  deliver: Deliver,
  authorId: string,
  address: string,
): ()! {
  let ttl: i64 = 86400
  let token = tokens.issue("verify-email", authorId, ttl, address)?
  deliver(address, token, now().ns / Second + ttl)?
}

class Outbox {
  lines: []string,
}

fn inbox(outbox: Outbox): Deliver {
  let d: Deliver = (to, token, expiresAt) => {
    outbox.lines = append(outbox.lines, "to ${to}: https://inkwell.example/confirm?t=${token}")
  }
  return d
}
```

If `deliver` fails the token is already stored and nobody has it. It lapses
at its expiry; report the failure to the author and let them ask again, which
revokes it.

## Your own store

`MemoryOneTimeStore` forgets everything when the process restarts, which kills
every mailed link, and it is one process. A deployment with more than one server
needs a shared store. `OneTimeStore` is three methods, and any type that has
them is one:

- `put(hash, rec, ttl)` saves a record under the hash of the token, for `ttl`
  seconds.
- `take(hash)` returns the record and deletes it in one atomic step, or
  `Option.None` when there is none. This is what makes a token single use. With
  SQL it is one `DELETE ... RETURNING`; with Redis, `GETDEL`. A `SELECT` followed
  by a `DELETE` lets two requests both win.
- `revokeSubject(purpose, subject)` deletes every record with that purpose and
  subject.

The store only ever sees hashes. This one wraps another store and counts how
many tokens the app has issued, which is the shape of any decorator, an audit
log or a metrics hook:

```bit
import { MemoryOneTimeStore, OneTimeRecord, OneTimeTokens } from "auth"

class CountingStore {
  inner: MemoryOneTimeStore
  puts: []int

  export put(hash: string, rec: OneTimeRecord, ttl: i64): ()! {
    this.puts[0] = this.puts[0] + 1
    this.inner.put(hash, rec, ttl)?
  }

  export take(hash: string): Option<OneTimeRecord>! {
    return this.inner.take(hash)?
  }

  export revokeSubject(purpose: string, subject: string): ()! {
    this.inner.revokeSubject(purpose, subject)?
  }
}

fn counted(): OneTimeTokens! {
  let store = CountingStore{ inner = MemoryOneTimeStore(), puts = []int{ 0 } }
  return OneTimeTokens(store)?
}
```

`MemoryOneTimeStore(capacity)` holds 10,000 records unless told otherwise.
When it is full it drops the expired ones first and, if none are, the one
that would expire soonest, so a script that asks for tokens for a million
subjects cannot grow memory without bound. A capacity below 1 panics when the
store is built.

## Testing expiry without waiting

`OneTimeOptions` takes a `clock`, a function returning seconds since the
epoch. Pass your own and a test can move time by hand:

```bit
import { MemoryOneTimeStore, OneTimeOptions, OneTimeTokens } from "auth"

class Clock {
  t: i64,
}

fn expiresAfterADay(): bool! {
  let clock = Clock{ t = 1000 }
  let read: () => i64 = () => clock.t
  let tokens = OneTimeTokens(MemoryOneTimeStore(), OneTimeOptions{ clock = read })?
  let token = tokens.issue("verify-email", "author-17", 86400)?
  clock.t = 1000 + 86400
  tokens.redeem(token, "verify-email") catch _ {
    return true
  }
  return false
}
```

The other option, `maxTtl`, is the longest lifetime `issue` accepts: 30 days
by default. A link that lives longer is a standing credential, and a lifetime
given in milliseconds by mistake is caught the first time it runs.

## Sharp edges

- `issue` fails for an empty purpose, an empty subject, and a lifetime of zero,
  below zero or above `maxTtl`. `redeem` fails for an empty purpose. These are
  mistakes in your code, not in a request, and they are not `InvalidToken`.
- The token is shown once, in the return value of `issue`. Only its hash is
  stored, so there is no way to look a token up again. Send it and forget it.
- `data` is stored as given. Keep secrets out of it; an address is fine.
- Keep tokens out of logs and out of `Referer`: put the confirm page's own
  response behind `Referrer-Policy: no-referrer`, and redeem on a `POST`
  rather than on the `GET` a mail scanner may follow.

## Where to go next

- [Slow down password guessing](brute-force.md) throttles the login a reset
  link leads back to.
- [Security model](security.md) lists everything else this package enforces.
