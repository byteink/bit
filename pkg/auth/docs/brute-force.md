# Slow down password guessing

Inkwell's `/login` route answers as fast as your server can verify a password.
That is the problem: a script can try thousands of passwords against one
account, or one leaked password against thousands of accounts, and the only
limit is your bandwidth. OWASP's ASVS (the authentication chapter, on
anti-automation) and NIST SP 800-63B (the section on throttling failed
attempts) both ask for a limit on failed attempts per account. `LoginThrottle`
is that limit.

It counts failed logins per account and per client address, makes a client wait
longer after each failure, locks an account or an address that keeps failing,
and forgets an account's failures when its owner gets in. It keeps its counters
in the same `RateStore` that `pkg/web`'s `rateLimit` uses, so there is no second
store to run.

## The simplest thing that works

Build one throttle when the app starts, and call it three times around the
password check: `check` before, `recordFailure` on a wrong password,
`recordSuccess` on a right one.

```bit
import { Ctx, MemoryCounter, Res } from "web"
import { Lookup, LoginThrottle, Throttled } from "auth"
import { argon2Verify } from "std/crypto"

@json class Login {
  username: string,
  password: string,
}

// Stand-in for however you already verify a password.
fn passwordOk(users: Lookup, username: string, password: string): bool {
  let found = users(username) catch _ {
    return false
  }
  return argon2Verify([]byte(password), found.hash)
}

// The 429 a refused client gets. `Throttled` carries the wait, so the route
// can send it as `Retry-After`.
fn tooMany(c: Ctx, e: error): Res! {
  let (t, ok) = e.(Throttled)
  if (!ok) {
    fail e
  }
  return c.status(429).header("Retry-After", "${t.retryAfter}")
}

fn login(c: Ctx, throttle: LoginThrottle, users: Lookup): Res! {
  let creds = c.body<Login>()?
  throttle.check(creds.username, c.peer()) catch e {
    return tooMany(c, e)?
  }
  if (!passwordOk(users, creds.username, creds.password)) {
    throttle.recordFailure(creds.username, c.peer())?
    return c.status(401)
  }
  throttle.recordSuccess(creds.username)?
  return c.text("welcome")
}

fn newThrottle(): LoginThrottle! {
  return LoginThrottle(MemoryCounter(10_000))?
}
```

`check` fails with a `Throttled` when the client has to wait. It is an
`HttpError`, so a route that lets it escape answers `429 Too Many Requests`; the
route above catches it only to add the `Retry-After` header.

Call `check` before you verify the password. A locked account then costs the
attacker an attempt and costs you no password hash.

## What the defaults do

`LoginThrottle(store)` uses `ThrottleOptions{}`:

| Option | Default | Meaning |
| ------ | ------- | ------- |
| `accountFailures` | 5 | Failures one account may have inside `window` before it is locked. |
| `ipFailures` | 20 | Failures one address may have inside `window` before it is locked. |
| `window` | 900 | Seconds a failure counts. |
| `baseDelay` | 1 | Seconds to wait after the first failure. |
| `maxDelay` | 900 | The wait stops doubling here. |
| `lockout` | 900 | Seconds a locked account or address is refused. |
| `onEvent` | none | An audit hook, see below. |

After the first failure the account must wait `baseDelay` seconds, after the
second twice that, then four times, and so on: `min(maxDelay, baseDelay * 2^(n-1))`.
The fifth failure reaches `accountFailures` and locks the account for `lockout`
seconds. Five is well under NIST's ceiling of 100 consecutive failures.

Change what you need, and leave the rest:

```bit
import { MemoryCounter } from "web"
import { LoginThrottle, ThrottleOptions } from "auth"

fn strict(): LoginThrottle! {
  return LoginThrottle(
    MemoryCounter(10_000),
    ThrottleOptions{ accountFailures = 3, window = 600, lockout = 1800 },
  )?
}
```

All times are in seconds. A policy that cannot work fails when you build the
throttle, naming the field, so a typo stops the app at startup and not on the
first attack: an `accountFailures` or `ipFailures` below 1, a `window`,
`baseDelay` or `lockout` below 1, a `maxDelay` below `baseDelay`, or no store.

## What a refused client learns

`Retry-After` is the full wait for the failure that caused it. It is exact right
after the failure and an upper bound afterwards, because the counter store reports
how many failures there are, not how long a key has left. A client that waits
that long is let in.

The refusal is the same for every cause and every account. The throttle counts
whatever string it is given and never asks your `Lookup` whether the account
exists, so an attacker cannot tell a real username from an invented one by who
gets throttled.

## Success forgets the account, not the address

`recordSuccess` resets the account's failures and nothing else. It does not reset
the address. If it did, an attacker with one valid login could interleave it
with a guessing run and never reach the address limit. The address has no
backoff either, only the lockout, because an address is often a whole office
behind one NAT.

Account names are lower-cased, so `Ada` and `ada` are one account.

## Keep an audit trail

Set `onEvent` to hear every failure, lockout, refusal and reset. The hook runs on
the request path, so keep it quick.

```bit
import { MemoryCounter } from "web"
import { LoginThrottle, ThrottleEvent, ThrottleHook, ThrottleKind, ThrottleOptions } from "auth"

fn audited(sink: (string) => ()): LoginThrottle! {
  let hook: ThrottleHook = (e: ThrottleEvent) => {
    sink("login ${e.kind.show()} account=${e.account} ip=${e.ip} failures=${e.failures} wait=${e.retryAfter}")
  }
  return LoginThrottle(MemoryCounter(10_000), ThrottleOptions{ onEvent = hook })?
}

fn isLockout(e: ThrottleEvent): bool {
  return e.kind == ThrottleKind.LockedOut
}
```

The kinds are `Failed` (a failure was recorded), `LockedOut` (that failure
started a lockout), `Locked` and `Delayed` (the two reasons `check` refused),
and `Cleared` (a success reset the account).

`account` is the SHA-256 hash of the lower-cased name, not the name. People type
passwords into username fields, and a log is the last place for one. The same
hash is what the throttle puts in its store keys, so a username never reaches
the store in the clear either. The hash is not keyed, so someone who can read
the store can still test a guess against it.

## Sharp edges

- **Pick the store for how you deploy.** `MemoryCounter` lives in one process.
  Behind a load balancer each server counts alone and the limit becomes five per
  server. Use a `RateStore` backed by a shared store such as Redis. `MemoryCounter` also
  drops its oldest counters when it is full, which hands a client a fresh
  quota, so size it for the accounts you expect.
- **`check` and `recordFailure` are two steps.** Requests that arrive together
  can all pass `check` before the first failure is recorded, so a burst gets a
  few extra tries. The counters themselves never lose a failure.
- **Pass the real client address.** `c.peer()` is the socket's far end. Behind a
  proxy it is the proxy, and every user would share one counter, so use
  `byForwardedIp`'s trusted-hop rule from `pkg/web` to read the real one.
  An empty address fails, since it would put everyone in one bucket.
- **A store outage is an error, not a pass.** `check` returns the store's own
  error, which is not a `Throttled`, so an unhandled one is a 500 and the login
  is refused. If you would rather keep logins working through an outage, catch
  it, log it, and carry on.

## Where to go next

[Getting started](getting-started.md) builds the login route this protects, and
[Security model](security.md) lists what the rest of the package checks for you.
