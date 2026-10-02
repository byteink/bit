# Sessions and logging in

<!-- doctest: deps auth postgres orm -->

Inkwell can register a user, but every request is still anonymous: HTTP
carries no memory of its own, so nothing tells `POST /articles` who is
calling. This part adds `POST /auth/login`, and after it a client that logs
in once gets recognized on every request that follows, until it logs out.

## Why a session cookie, not a token with the data in it

There are two common ways to keep a client "logged in": put everything in a
signed token the client carries (a JWT), or hand the client a random id and
keep the real data on the server, keyed by that id (a session). Inkwell uses
the second.

A session's cookie carries a random id and **nothing else**. Every byte of
"who is this and what can they do" lives in a server-side store, keyed by
that id. The id does not need to be signed, because a forged id simply
misses in the store; it is not trusted the way a signed token is. The
payoff is revocation: logging a user out, or out of every device, is one
store write, because the truth lives on the server. A signed token holding
the data has none of that: whatever it says at the moment it was issued is
what every server trusts until it expires, whether or not you meant that to
still be true five minutes later.

## Configuring where sessions live

`Config.sessions` has no default, on purpose: a framework that quietly hands
you a working in-memory session store is a framework that quietly stops
working the day you run a second copy of your app. Inkwell writes it down at
the call site, in `main.bit`:

```bit
import { App, Config, MemoryStore } from "web"

fn buildApp(secret: string): App {
  return App(Config{ secret = secret, sessions = MemoryStore(10_000) })
}
```

`MemoryStore(10_000)` is fine for one process and for this part. A second
Inkwell process would not share it; swapping in a `SessionStore` backed by
Redis or Postgres later is a one-line change, because every route that reads
or writes a session goes through the same `c.session()` call.

## Looking a user up by username

`pkg/auth`'s password check needs one thing from your app: given a
username, the stored Argon2id hash and whatever you want to remember about
the user afterward. That is a `Lookup`:

```bit
import { Lookup, LookupResult, Strategy, PasswordStrategy } from "auth"
import { Db } from "orm"
import { Json, JsonEntry } from "std/json"

// `users`, not the snake_case default `user` - see [Registering users and
// hashing passwords](10-registering-users-and-hashing-passwords.md).
@table("users") @timestamps class User {
  id: i64,
  username: string,
  email: string,
  passwordHash: string,
  role: string,
  createdAt: i64,
  updatedAt: i64,
}

fn findUserByUsername(db: Db, username: string): User! {
  let found = db.table<User>().where("username", username).first()?
  if (!isSome(found)) {
    fail newError("no user named '${username}'")
  }
  return unwrap(found)
}

fn userClaims(u: User): Json {
  return Json.JsonObject([JsonEntry{ key = "role", value = Json.JsonString(u.role) }])
}

fn userLookup(db: Db): Lookup {
  return (username) => {
    let u = findUserByUsername(db, username)?
    return LookupResult{ hash = u.passwordHash, id = "${u.id}", claims = userClaims(u) }
  }
}
```

`PasswordStrategy(userLookup(db))` wraps that into a `Strategy`: given a
request, it reads a `{"username": ..., "password": ...}` JSON body, calls
your lookup, and verifies the password against the stored Argon2id hash with
the same algorithm [chapter 23](10-registering-users-and-hashing-passwords.md)
hashed it with. A wrong password and an unknown username answer with the
identical `401 Unauthorized`, in the identical amount of time: if the two
cases looked or felt different from the outside, an attacker could use that
difference to find out which usernames exist.

## Session fixation, and why login mints a brand new id

Before a session is trusted with anything, it must not be one an attacker
could have planted. **Session fixation** is the attack this defends
against: an attacker gets a victim to load a page carrying a session id the
attacker already knows (their own valid cookie, planted in the victim's
browser), waits for the victim to log in under that same id, and now the
attacker's known id is an authenticated session too.

The fix is to never let a pre-login id survive login. `Session.regenerate()`
moves the session's data onto a freshly minted id and immediately destroys
the old one, so the id a request arrived with is worthless the instant
authentication succeeds, even to a request that had already read it:

```bit
import { Ctx } from "web"

fn afterVerified(c: Ctx): ()! {
  c.session()?.regenerate()?
}
```

## The login route

```bit
import { Res, unauthorized } from "web"
import { isSome, unwrap } from "std/core"
import { jsonDecString, jsonGet } from "std/json"

const sessionUserIdKey = "inkwell:userId"
const sessionRoleKey = "inkwell:role"

fn login(c: Ctx, strategy: Strategy): Res! {
  let identity = strategy.authenticate(c)?
  let session = c.session()?
  session.regenerate()?
  session.set(sessionUserIdKey, identity.id)
  let role = jsonGet(identity.claims, "role")
  if (isSome(role)) {
    session.set(sessionRoleKey, jsonDecString(unwrap(role), "identity.claims.role")?)
  }
  return c.noContent()
}
```

One thing about this route matters more than it looks:

`session.regenerate()` runs **before** anything is written into the
session, for the reason above: the write has to land on the new id, not on
the one that might have been planted.

Nothing here calls `session.save()`. `pkg/web` autosaves a modified session
once the handler returns: if any `set()`/`delete()`/`regenerate()` marked
the session dirty, the framework writes it to the store for you, whether
the handler succeeded or failed. `Session.set()` still only changes the
copy of the session held in memory for the rest of *this* request; the
store write itself happens automatically at the end, not inside `login`.

`c.noContent()` answers `204 No Content`. There is nothing to return besides
the cookie: the caller already knows who they are, because they sent the
credentials.

## Logging out, and reading the caller back

```bit
import { parseInt } from "std/strings"

fn logout(c: Ctx): Res! {
  c.session()?.destroy()?
  return c.noContent()
}

fn currentUserId(c: Ctx): i64! {
  let raw = c.session()?.get(sessionUserIdKey)
  if (len(raw) == 0) {
    fail unauthorized()
  }
  return parseInt(raw)?
}

fn findUserById(db: Db, id: i64): User! {
  return db.table<User>().find(id)?
}

@json class MeView {
  id: i64,
  username: string,
  role: string,
}

fn showMe(c: Ctx, db: Db): Res! {
  let id = currentUserId(c)?
  let u = findUserById(db, id)?
  return c.json(MeView{ id = u.id, username = u.username, role = u.role })
}

export fn mountAuth(app: App, db: Db) {
  let strategy = PasswordStrategy(userLookup(db))
  app.post("/auth/login", (c) => login(c, strategy))
  app.post("/auth/logout", (c) => logout(c))
  app.get("/me", (c) => showMe(c, db))
}
```

`destroy()` tombstones the session in the store and clears the cookie's
data; a request that presents the old cookie afterward misses in the store
and is treated as a brand new, anonymous visitor.

## Why Inkwell mounts no CSRF middleware

`pkg/web` ships an opt-in `csrf()` middleware for exactly one case: an app
that serves an HTML `<form>`, where a browser will submit a cross-site POST
carrying the victim's cookies without being asked. Inkwell never does that.
It is a JSON API, read only by clients that set `Content-Type:
application/json` on purpose, over an explicit list of allowed origins
(`cors()`, with `credentials: true` for exactly those origins and no
wildcard). The session cookie itself already carries `SameSite=Lax`, which
every current browser refuses to attach to a cross-site POST at all. Between
those two, there is no cross-site form for `csrf()` to defend, so Inkwell
does not mount it. An app that later serves an HTML form from this same
session store would mount `csrf()` on that form's routes, and only those.

## Try it

Register a user first ([chapter 23](10-registering-users-and-hashing-passwords.md)),
then log in, keeping the cookie jar:

```
$ curl -si -c cookies.txt -X POST http://127.0.0.1:8089/auth/login \
    -H 'Content-Type: application/json' \
    -d '{"username":"ada","password":"correct horse battery"}'
```

```
HTTP/1.1 204 No Content
Content-Length: 0
Set-Cookie: sid=5bf0dd109ce1aa521cd02d6599dffbbb; HttpOnly; SameSite=Lax; Secure; Path=/
```

The saved cookie proves who is calling on the next request:

```
$ curl -si -b cookies.txt http://127.0.0.1:8089/me
```

```
HTTP/1.1 200 OK
Content-Type: application/json

{"data":{"id":1,"username":"ada","role":"author"}}
```

A wrong password never creates a session:

```
$ curl -si -X POST http://127.0.0.1:8089/auth/login \
    -H 'Content-Type: application/json' \
    -d '{"username":"ada","password":"wrong password"}'
```

```
HTTP/1.1 401 Unauthorized
Content-Type: application/json

{"error":{"code":"unauthorized","message":"Unauthorized"}}
```

And logging out invalidates the cookie for every request after it:

```
$ curl -si -b cookies.txt -X POST http://127.0.0.1:8089/auth/logout
$ curl -si -b cookies.txt http://127.0.0.1:8089/me
```

```
HTTP/1.1 204 No Content

HTTP/1.1 401 Unauthorized
Content-Type: application/json

{"error":{"code":"unauthorized","message":"Unauthorized"}}
```

(Every response above also carries Inkwell's own security and rate-limit
headers, [chapter 26](13-middleware.md)'s subject; they are trimmed here to
keep the point visible.)

## What we built

`POST /auth/login` that verifies a password, closes session fixation with
`regenerate()`, and persists the result via `pkg/web`'s autosave, with no
explicit `save()` call. `POST /auth/logout` that destroys the session
outright, and `GET /me` that
reads the logged-in caller back. Every route in Inkwell can now ask "who is
calling", but not yet "are they allowed to do this": that is [chapter
25](12-authorization.md).

Previous: [Registering users and hashing passwords](10-registering-users-and-hashing-passwords.md).
Next: [Authorization](12-authorization.md).
