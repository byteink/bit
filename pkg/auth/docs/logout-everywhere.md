# Sign an author out of every device

Ada signs in to Inkwell on her laptop, her phone and the library computer. A
week later she changes her password because she left the library computer
signed in. The new password means nothing if the library session still works:
whoever sits down there is still Ada. She needs one button, "sign out
everywhere", and Inkwell needs the same call when she changes the password
and when an admin disables an account.

`logoutEverywhere` is that call. It destroys every session a user holds, on
every device, in one step.

## The simplest thing that works

Every login this package performs (password, magic link, OAuth 2.0, OpenID
Connect, Apple, a bearer token through `requireAuth`) files its session under
the user's `Identity.id`, so the session store can find all of a user's
sessions without scanning. You do nothing to turn that on. The call takes the
same store you gave `Config`, and the user's id:

```bit
import { App, Config, MemoryStore, unauthorized } from "web"
import { currentIdentity, logoutEverywhere } from "auth"

fn routes(sessions: MemoryStore): App {
  let app = App(Config{ secret = "change-me", sessions = sessions })
  app.post("/me/sign-out-everywhere", (c) => {
    let me = currentIdentity(c) catch _ {
      fail unauthorized()
    }
    logoutEverywhere(sessions, me.id)?
    return c.redirect("/login")
  })
  return app
}
```

`logoutEverywhere` returns how many sessions it destroyed. Each one is
destroyed exactly as `Session.destroy()` destroys it: the id is refused from
then on, so a request that was already running with it cannot write it back.
The next request on any of those cookies is a stranger and gets a fresh
session. Because the store is shared, this also reaches sessions held by
other server processes behind the same store.

This call destroys the session that made the request too, so the route above
answers with a redirect and writes nothing to the session afterwards.

## Keep the session that is asking

Changing a password is different: Ada is at her laptop and should stay signed
in there. `Keep.Current(c)` names the session of the request `c` as the one to
spare; the default, `Keep.Nobody`, spares none.

```bit
import { App, Config, MemoryStore, unauthorized } from "web"
import { Keep, currentIdentity, logoutEverywhere } from "auth"

fn passwordRoutes(sessions: MemoryStore): App {
  let app = App(Config{ secret = "change-me", sessions = sessions })
  app.post("/me/password", (c) => {
    let me = currentIdentity(c) catch _ {
      fail unauthorized()
    }
    // ... store the new password hash for me.id ...
    let others = logoutEverywhere(sessions, me.id, Keep.Current(c))?
    return c.text("signed out of ${others} other devices")
  })
  return app
}
```

The same call serves an admin disabling an account: there is no request of
the user's, so it is `logoutEverywhere(sessions, authorId)` and `Keep.Nobody`.

## When you write a Strategy of your own

A session is only found by `logoutEverywhere` if the login filed it. Your own
`Strategy` does that with `bindSession`, after it regenerates the session id:
it stores the `Identity` on the session, files the session under the user's
id, and saves. It is the only place this package writes an `Identity` to a
session, so a strategy never touches the session key itself.

```bit
import { Ctx, unauthorized } from "web"
import { Identity, bindSession } from "auth"
import { Json } from "std/json"

// Signs in whoever the reverse proxy in front of Inkwell vouches for.
class ProxyLogin {
  export name(): string {
    return "proxy"
  }

  export authenticate(c: Ctx): Identity! {
    let user = c.header("X-Forwarded-User")
    if (user == "") {
      fail unauthorized()
    }
    c.session()?.regenerate()?
    let identity = Identity{ id = user, claims = Json.JsonNull }
    bindSession(c, identity)?
    return identity
  }
}
```

An `Identity` with an empty `id` makes `bindSession` fail with an error:
a session that cannot be filed under anyone could never be signed out, so
the login is refused rather than left unrevocable. A stateless strategy such
as `BearerStrategy` needs no `bindSession`: `requireAuth` calls it for the
session it makes.

## What it does underneath

`bindSession` calls `Session.index(subjectIndexKey, id)` and
`logoutEverywhere` calls `SessionStore.destroyIndexed` with the same key, so
this is all there is to it:

```bit
import { SessionStore } from "web"
import { subjectIndexKey } from "auth"

fn destroyByHand(sessions: SessionStore, id: string): int! {
  return sessions.destroyIndexed(subjectIndexKey, id, "", 86400)?
}
```

Use `logoutEverywhere` and not this: it also refuses an empty id and keeps the
tombstone as long as a session lives. The snippet matters if you write a
`SessionStore` of your own, which must keep the index, as the
[`pkg/web` security chapter](../../web/docs/security.md) describes. A
session that rotates its id (`Session.regenerate()`) takes the index with it,
so a session rotated after login is still found.

## Sharp edges

- `subject` is the `Identity.id` your lookup returned, not a username or an
  email address, unless that is what you return as the id.
- An empty `subject` fails with `auth: logoutEverywhere(): subject is empty`.
- With `Keep.Current(c)`, the call fails if the app configured no session
  store, the same error `c.session()` gives.
- A session created before your app upgraded to this version of `pkg/auth` has
  no index entry, so `logoutEverywhere` does not find it. It ends when it
  expires, a day after its last save.

## Where to go next

- [Security model](security.md): why every login regenerates the session id.
- [Getting started](getting-started.md): the password login that creates these
  sessions.
