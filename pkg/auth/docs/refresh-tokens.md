# Refresh tokens that notice theft

Inkwell's JSON API hands a client a short-lived access token and a long-lived
refresh token, so the client can stay signed in for weeks without holding a
password. That refresh token is the most valuable thing in the app: whoever
has a copy can mint access tokens until it expires. A phone is stolen, a
backup leaks, a script logs a header, and nothing on the server can tell the
thief from the author.

The defence in the OAuth 2.0 Security Best Current Practice (RFC 9700) is
rotation with reuse detection. Every use of a refresh token swaps it for a
new one and kills the old. The first time a dead token comes back, somebody
is holding a copy. The server cannot tell if it is the thief or the author, so
it ends the whole login and both of them have to sign in again.
`RefreshTokens` does that, and this page builds Inkwell's `/auth/token/refresh`
route on it.

## The simplest thing that works

`issue` starts a login and returns its first token. `rotate` exchanges a token
for the next one. `MemoryRefreshStore` keeps the hashes in this process, which
is all a first version and every test needs.

```bit
import { RefreshTokens, MemoryRefreshStore, RefreshRotation } from "auth"

fn signInAndStayIn(): RefreshRotation! {
  let tokens = RefreshTokens(MemoryRefreshStore())?
  let first = tokens.issue("author-17", "device=phone")?
  return tokens.rotate(first)?
}
```

Both tokens are 43 URL-safe characters (256 random bits), so they go in a JSON
body or a cookie as they are. The `RefreshRotation` you get back has the new
`token`, the `subject` it was issued for, the `data` string given to `issue`
(here a device label, carried unchanged through every rotation) and
`expiresAt`, in seconds since the epoch, for a cookie's `Max-Age`.

The token you passed to `rotate` is now dead. Run `rotate` on it a second time
and it fails, which is the next section.

## Reuse ends the login

Say the thief copied the first token and the author rotated it afterwards, so
the author holds the second one. The thief now presents the first:

```bit
import { RefreshTokens, MemoryRefreshStore } from "auth"

fn stolenTokenIsReplayed(): bool! {
  let tokens = RefreshTokens(MemoryRefreshStore())?
  let first = tokens.issue("author-17")?
  let second = tokens.rotate(first)?
  tokens.rotate(first) catch _ {
    // The author's token died with it.
    tokens.rotate(second.token) catch _ {
      return true
    }
  }
  return false
}
```

The replay fails, and so does the author's next refresh, because every token
that descends from one login belongs to one family and a reused token revokes
the family. The author lands on the sign-in page, which is what you want: a
password or a second factor now stands between the thief and the account, and
the token the thief held is worthless.

The other order is the same. If the thief rotates first and the author comes
back with the old token, the author's request is the reuse and the thief's
new token dies.

## Every failure looks the same

A token that is malformed, unknown, expired, revoked, past the absolute cap
below, or already rotated fails with one error, `InvalidRefreshToken`, with one
message. A client probing the refresh route learns nothing about whether a
token ever existed. Your route answers all of them with the same 401.

```bit
import { InvalidRefreshToken, RefreshTokens } from "auth"

fn refreshed(tokens: RefreshTokens, token: string): string! {
  let next = tokens.rotate(token) catch e {
    let (_, invalid) = e.(InvalidRefreshToken)
    if (invalid) {
      return ""
    }
    fail e
  }
  return next.token
}
```

A failure that is not `InvalidRefreshToken` is the store's, a database that is
down, say. It is returned as it came, since the operator needs to see it and a
client cannot cause it, and nothing is issued: a store that cannot record the
rotation never hands out the new token.

## Lifetimes

`RefreshOptions` sets three durations, all in seconds:

- `ttl`, 30 days: how long one token lives. Each rotation starts it again, so
  a client that comes back every week never expires.
- `absoluteTtl`, 90 days: how long a login lives from the moment of
  `issue`, however often it rotates. A token a thief keeps alive by rotating
  it still dies here, and the last token's `expiresAt` is clamped to it.
- `graceSeconds`, 0: see the next section.

`ttl` and `absoluteTtl` are the numbers a security review asks about, so put
them in your configuration. A `ttl` below 1, an `absoluteTtl` below `ttl` or a
negative `graceSeconds` fails when you build `RefreshTokens`, so the mistake
shows when the app starts rather than at the first refresh.

`RefreshOptions` also takes a `clock`, a function returning seconds since the
epoch, so a test can move time by hand:

```bit
import { MemoryRefreshStore, RefreshOptions, RefreshTokens } from "auth"

class Clock {
  t: i64,
}

fn capEndsAFamilyThatKeepsRotating(): bool! {
  let clock = Clock{ t = 1000 }
  let read: () => i64 = () => clock.t
  let opts = RefreshOptions{ clock = read, ttl = 100, absoluteTtl = 250 }
  let tokens = RefreshTokens(MemoryRefreshStore(), opts)?
  let token = tokens.issue("author-17")?
  clock.t = 1090
  token = tokens.rotate(token)?.token
  clock.t = 1180
  let last = tokens.rotate(token)?
  clock.t = 1250
  tokens.rotate(last.token) catch _ {
    return true
  }
  return false
}
```

## Two requests at once, and a lost response

Two things look like theft and are not. A phone on a bad connection sends a
refresh, the server rotates, and the response never arrives, so the phone
retries with the token it still holds. Or a web page with two tabs refreshes
from both at the same instant.

With the default `graceSeconds = 0` both are reuse and cost the login. A
positive value excuses a second presentation that arrives fewer than that many
seconds after the rotation: it still fails, because the new token cannot be
handed out twice (only its hash is stored), but the login survives and the
token the first request received keeps working. The client then signs in
again, or, for the two tabs, one of them already holds a good token.

```bit
import { MemoryRefreshStore, RefreshOptions, RefreshTokens } from "auth"

fn tolerateABriefRace(): RefreshTokens! {
  return RefreshTokens(MemoryRefreshStore(), RefreshOptions{ graceSeconds = 10 })?
}
```

Keep it small. Every second of grace is a second in which a thief replaying a
stolen token is also excused, though not rewarded.

## Signing out

`revoke` ends the login a token belongs to, whichever token of it you hold, so
the token the client has now stops working. A token that is malformed or that
the store does not know is already dead, so `revoke` does not fail for it: a
sign-out with a stale cookie succeeds.

`revokeSubject` ends every login of one author, for "sign out everywhere", a
password change or a banned account.

```bit
import { RefreshTokens } from "auth"

fn signOut(tokens: RefreshTokens, token: string): ()! {
  tokens.revoke(token)?
}

fn signOutEverywhere(tokens: RefreshTokens, authorId: string): ()! {
  tokens.revokeSubject(authorId)?
}
```

An access token you already issued lives until its own expiry, which is why
those are short. Revoking a refresh token stops the next renewal, not the
current access token.

## Your own store

`MemoryRefreshStore` forgets everything when the process restarts, which signs
everyone out, and it is one process. A deployment with more than one server
needs a shared store. `RefreshStore` is five methods, and any type that has
them is one. A `RefreshRecord` is what it keeps, one per token, under the
SHA-256 hash of the token:

| Field | Meaning |
| ----- | ------- |
| `hash` | SHA-256 of the token in hex, never the token. |
| `family` | The login the token descends from. |
| `subject` | Whom it is for. |
| `expiresAt` | When this token dies. |
| `familyExpiresAt` | When the whole login dies; the same on every record of a family. |
| `rotatedAt` | When this token was exchanged for the next, `0` if it has not been. |
| `revoked` | Set when the family or the subject was revoked. |
| `data` | What `issue` was given. |

- `insert(rec)` saves a new login's first record.
- `findByHash(hash)` returns the record or `Option.None`. A revoked or rotated
  record must still be found, because that is how reuse is recognised.
- `rotate(oldHash, next, at)` is the one that matters. It must be one atomic
  step: if the old record exists, is not revoked and has `rotatedAt == 0`, set
  its `rotatedAt` to `at`, store `next` and answer `true`; otherwise change
  nothing and answer `false`. With SQL it is an `UPDATE ... WHERE rotated_at = 0
  AND NOT revoked` and an `INSERT` in one transaction, taking the row count of
  the `UPDATE` as the answer; with Redis, a script. A `SELECT` followed by an
  `UPDATE` lets two requests both win, and then one token has been exchanged
  twice and reuse detection has a hole.
- `revokeFamily(family)` and `revokeSubject(subject)` set `revoked` on every
  matching record.

Inkwell's own store, `OrmRefreshStore` in `pkg/web/guides/inkwell/auth.bit`,
is the SQL version of this: one `refresh_tokens` row per record, and a `rotate`
that runs the conditional `UPDATE` and the `INSERT` of the next token inside one
`db.tx`, answering `true` only when the `UPDATE` touched a row. Its test starts
sixteen rotations of one token at once and checks that exactly one wins.

The store only ever sees hashes. This one wraps another store and counts the
rotations, the shape of any decorator, an audit log or a metrics hook:

```bit
import { MemoryRefreshStore, RefreshRecord, RefreshTokens } from "auth"

class CountingStore {
  inner: MemoryRefreshStore
  rotations: []int

  export insert(rec: RefreshRecord): ()! {
    this.inner.insert(rec)?
  }

  export findByHash(hash: string): Option<RefreshRecord>! {
    return this.inner.findByHash(hash)?
  }

  export rotate(oldHash: string, next: RefreshRecord, at: i64): bool! {
    let won = this.inner.rotate(oldHash, next, at)?
    if (won) {
      this.rotations[0] = this.rotations[0] + 1
    }
    return won
  }

  export revokeFamily(family: string): ()! {
    this.inner.revokeFamily(family)?
  }

  export revokeSubject(subject: string): ()! {
    this.inner.revokeSubject(subject)?
  }
}

fn counted(): RefreshTokens! {
  let store = CountingStore{ inner = MemoryRefreshStore(), rotations = []int{ 0 } }
  return RefreshTokens(store)?
}
```

`MemoryRefreshStore(capacity)` holds 100,000 records unless told otherwise. When
it is full it drops the one that would expire soonest, so a script that logs in
a million times cannot grow memory without bound. A rotated token is kept until
then, since reuse detection needs it. A capacity below 1 panics when the store
is built.

## Sharp edges

- `issue` fails for an empty subject and `revokeSubject` for an empty subject.
  These are mistakes in your code, not in a request, and they are not
  `InvalidRefreshToken`.
- The token is shown once, in the return value of `issue` and `rotate`. Only its
  hash is stored, so there is no way to look one up again.
- `data` is stored as given and carried to every new token. Keep secrets out
  of it.
- Keep a refresh token out of logs and URLs. In a browser, put it in an
  `HttpOnly`, `Secure`, `SameSite` cookie, scoped to the refresh route, rather
  than in storage a script can read.
- A client that retries a refresh after a timeout needs `graceSeconds`, or it
  signs itself out.

## When not to use it

If the client is a browser that talks to your own server only, a cookie
session is simpler and can be cut off at once. Refresh tokens pay off when the
client is an app or a script that holds a credential for weeks and calls an
API with short-lived access tokens.

## Where to go next

- [Bearer tokens for an API](bearer-tokens.md) issues the short-lived access
  token this one renews.
- [API keys for scripts and integrations](api-keys.md) is the credential for a
  caller that has no sign-in step at all.
- [Security model](security.md) for what the package checks for you overall.
