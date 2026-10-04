# API keys for scripts and integrations

Inkwell's build server publishes a draft whenever a pull request merges. It is
a script, not a person: it has no password to type, no browser to keep a
cookie in, and no refresh dance to perform. It needs one long-lived secret
that you can hand over once, give only the rights it needs, and take back the
day it leaks.

That secret is an API key, and most of the ways to get one wrong are quiet. A
key stored as plain text hands every integration to whoever reads one
database backup. A key with no recognisable shape cannot be found by a secret
scanner when someone pastes it into a public repository. A key that cannot be
revoked cannot be rotated. And a lookup that answers faster for a key id that
does not exist tells an attacker which ids are real.

`ApiKeys` creates and checks keys so you do not write that part. `ApiKeyStrategy`
puts the check behind `requireAuth`, the same way a password login sits there,
and `hasScope` answers what a key may do.

## The simplest thing that works

An `ApiKeys` needs a place to keep key records, an `ApiKeyStore`, and
`ApiKeyOptions`. `MemoryApiKeyStore` is a store that lives in the process, which
is right for development and for tests. `prefix` is required: two to twelve
characters from `a-z` and `0-9`, and it is the part that tells a person or a
scanner whose key a leaked string is.

```bit
import {
  ApiKeyOptions,
  ApiKeyRecord,
  ApiKeyStore,
  ApiKeyStrategy,
  ApiKeys,
  CreatedKey,
  InvalidApiKey,
  MemoryApiKeyStore,
  Strategy,
  currentIdentity,
  hasScope,
  requireAuth,
} from "auth"
import { App, Config, MemoryStore, forbidden, unauthorized } from "web"

fn inkwellKeys(): ApiKeys! {
  return ApiKeys(MemoryApiKeyStore(), ApiKeyOptions{ prefix = "ink" })?
}
```

The constructor fails, with a message that says what is wrong, for a missing
store, a prefix outside that shape and a negative `touchInterval`. You find out
when the app starts, not when the first script calls.

## Hand out a key

`create` takes whom the key is for, what it may do, and optionally when it
stops working, in seconds since the epoch. It returns a `CreatedKey`.

```bit
fn publisherKey(keys: ApiKeys): CreatedKey! {
  return keys.create("ci-publisher", []string{ "articles:write", "articles:read" })?
}
```

`CreatedKey.key` is the only copy of the secret there will ever be. Show it to
its owner once, in the response that created it, and keep nothing but
`CreatedKey.keyId`. A key looks like this:

```text
ink_7QXJ2A4M5TD3K_pL9wQxT2mZb8RkVd4YfHn6CsEa3GjUo1Wm0BiQ
```

Three parts joined by underscores, then a checksum:

- `ink` is your prefix.
- `7QXJ2A4M5TD3K` is the key id, a handle for finding the record. It is not a
  secret, so it can sit in logs, admin screens and audit trails, and it is what
  `revoke` takes.
- The next 32 characters are the secret: 190 bits from the operating system's
  random source, so it cannot be guessed.
- The last 6 characters are a checksum of everything before them.

The checksum is not security. Anyone can compute it. It exists so that a typo,
or a key cut off in a copy, is refused without asking the database anything,
and so a secret scanner can tell a real key from a random string with the
same prefix.

`create` fails for an empty subject, a scope that is empty or holds a space,
and an expiry that is negative or already past. Pass `expiresAt` for a key that
should stop on its own, for a contractor's access for example:

```bit
fn contractorKey(keys: ApiKeys, until: i64): CreatedKey! {
  return keys.create("contractor-ana", []string{ "articles:read" }, until)?
}
```

## What the store keeps

The store never sees the secret. It gets an `ApiKeyRecord`: the key id, the
SHA-256 of the secret in hex, the subject, the scopes and four times, all in
seconds since the epoch. `lastUsedAt` is zero for a key never used,
`revokedAt` is zero for a live key and `expiresAt` is zero for one that does not
expire.

The secret is already random, so a plain SHA-256 is enough: there is nothing to
guess, so there is nothing to stretch. A stolen backup holds hashes that cannot
be turned back into keys. It also means checking a key costs one hash and one
lookup, nothing like a password.

## Check a key

`verify` returns the record of a good key and an `InvalidApiKey` for every key
it will not honour.

```bit
fn whoseKey(keys: ApiKeys, key: string): string {
  let rec: ApiKeyRecord = keys.verify(key) catch e {
    let (_, refused) = e.(InvalidApiKey)
    if (refused) {
      return "nobody"
    }
    return "store failure: ${e.message()}"
  }
  return rec.subject
}
```

A wrong prefix, a malformed key, a bad checksum, an id that does not exist, a
wrong secret, a revoked key and an expired key are all the same
`InvalidApiKey`, with the message `auth: invalid API key`, and the message never
contains the key. Your client gets one answer, so it cannot learn which part it
got right. The first three are answered without touching the store. For the
rest, `verify` always hashes the secret and compares it in constant time, even
when the id is unknown (it compares against a placeholder), so the time a
refusal takes does not say whether the id exists.

A failure of the store itself, the database being down, is not an
`InvalidApiKey`: it comes back as it came, because it is yours to see and
nothing a client caused.

`verify` also records the use. `touchInterval`, five minutes unless you set it,
is how often a key's `lastUsedAt` is written, so a script calling every second
costs one write per five minutes and not one per call.

## Protect a route

`ApiKeyStrategy` reads the key from `Authorization: Bearer <key>` or, when
that header carries none, from `X-API-Key`. Name another header as its second
argument if you prefer one. A strategy sits in `requireAuth` like any other, and
the `Identity` it produces has the subject as `id` and the key id and scopes
as claims. `hasScope` reads them.

```bit
fn inkwellApp(keys: ApiKeys): App {
  let app = App(Config{ secret = "change-me", sessions = MemoryStore(10_000) })
  let publisher = ApiKeyStrategy(keys) catch e {
    panic("inkwell: ${e.message()}")
  }
  app.use(requireAuth([]Strategy{ publisher }))

  app.post("/articles", (c) => {
    let who = currentIdentity(c) catch _ {
      fail unauthorized()
    }
    if (!hasScope(who, "articles:write")) {
      fail forbidden()
    }
    return c.text("published by ${who.id}")
  })
  return app
}
```

`hasScope` checks what a key was issued for. It is not a role system or a
permission model: it answers "does this key carry this word", and what the words
mean is up to your routes. An identity from another strategy has no scopes, so
`hasScope` is false for it.

A request with no key at all gets a 401 with `WWW-Authenticate: Bearer`, and one
with a refused key gets `Bearer error="invalid_token"`, as RFC 6750 asks. The
strategy is stateless: it creates no session, because the key travels on every
request.

If a request sends a JWT in `Authorization: Bearer`, `ApiKeyStrategy` refuses it
without a lookup, because it is not shaped like a key. Put it in the same
`requireAuth` list as a `BearerStrategy` and each one takes what it recognises.

## Take a key back

`revoke` takes the key id, the part you kept. The key stops working at once, on
the next `verify`.

```bit
fn leaked(keys: ApiKeys, made: CreatedKey): ()! {
  keys.revoke(made.keyId)?
}
```

Revoking a key twice is fine and keeps the first time. Revoking an id the store
does not hold fails, so a mistyped id is not mistaken for a revocation.

## Use your own store

Production keys live in your database. `ApiKeyStore` is four methods, and any
type that has them is a store: no declaration needed.

```bit
class CountingStore {
  inner: MemoryApiKeyStore
  writes: int

  insert(rec: ApiKeyRecord): ()! {
    this.inner.insert(rec)?
  }

  find(keyId: string): Option<ApiKeyRecord>! {
    return this.inner.find(keyId)?
  }

  touch(keyId: string, at: i64): ()! {
    this.writes = this.writes + 1
    this.inner.touch(keyId, at)?
  }

  revoke(keyId: string, at: i64): ()! {
    this.inner.revoke(keyId, at)?
  }
}

fn countedKeys(store: CountingStore): ApiKeys! {
  let backend: ApiKeyStore = store
  return ApiKeys(backend, ApiKeyOptions{ prefix = "ink", touchInterval = 60 })?
}
```

The rules for a store:

- `insert` fails when the key id exists. Make the key id the primary key.
- `find` answers `Option.None` for an id it does not hold.
- `touch` records a use at `at`, and does nothing for an id it does not hold.
- `revoke` records the time, keeps the earliest one if the key is already
  revoked, and fails for an id it does not hold.

`MemoryApiKeyStore` holds ten thousand keys unless you pass another number, and
`insert` fails when it is full rather than forgetting a key someone still has.

## Test it without waiting

Give `ApiKeyOptions` a `clock` that returns seconds since the epoch and move it by
hand, to see a key expire or `lastUsedAt` update without sleeping.

```bit
class Now {
  t: i64,
}

fn clockedKeys(now: Now): ApiKeys! {
  let read: () => i64 = () => now.t
  return ApiKeys(MemoryApiKeyStore(), ApiKeyOptions{ prefix = "ink", clock = read })?
}
```

Create a key with `expiresAt` of `now.t + 60`, set `now.t` to 59 seconds later and
`verify` accepts it, set it to 60 and it does not.

## Sharp edges

- The secret is shown once. If an owner loses it, revoke the key and create
  another: the store cannot recover what it never held.
- Log the key id, never the key. `CreatedKey.key` is a credential; treat it like
  a password in your own logs and error messages.
- A key is a bearer credential: anyone holding it is the subject. Send it only
  over TLS, and give each integration its own key so you can revoke one without
  the rest.
- Scopes are fixed when the key is created. To change what a key may do, create
  a new one and revoke the old one.

## When not to use it

A person signing in belongs on a password or an OpenID Connect provider and a
session. A short-lived call from your own mobile app, one that must stop
within minutes of the user signing out, belongs on
[bearer tokens](bearer-tokens.md), which expire on their own. An API key is for
the caller that has no user to sign out: a script, a build server, a partner's
backend.

Where next: [Bearer tokens for an API](bearer-tokens.md) for the short-lived
alternative, and [Security model](security.md) for what the package checks
overall.
