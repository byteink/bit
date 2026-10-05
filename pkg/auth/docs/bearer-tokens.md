# Bearer tokens for an API

Inkwell's mobile app and its single-page editor call the JSON API with no
cookie. They sign in once, get a token, and send it on every request in an
`Authorization: Bearer` header. A token is the one place an API gets
authentication badly wrong, and the mistakes are quiet ones. The server trusts
the algorithm named inside the token, so an attacker picks `none`. It accepts a
token that was meant for another service, or an ID token where an access token
belongs. A signing key is rotated by replacing it, and every signed-in user is
logged out at once. A key is a short password.

`AccessTokens` issues and checks JWT access tokens (RFC 9068, with the checks
RFC 8725 asks for) so you do not write that part. `BearerStrategy` puts the
check behind `requireAuth`, the same way a password login sits there.

## The simplest thing that works

An `AccessTokens` needs a `KeySet`, the keys it signs and verifies with, and
`TokenOptions`, what a token says about itself. `issuer` and `audience` are
required: they name your server and the API the token is for, and a token
carrying anything else is refused. `algorithm` pins the signing algorithm. It
must be the algorithm of every key you give, and the token's own header is
never allowed to pick another.

```bit
import { AccessTokens, KeySet, TokenOptions } from "auth"
import { Jwk, SigningKey, VerifyKey } from "std/jwt"

fn inkwellTokens(secret: []byte): AccessTokens! {
  let keys = KeySet{
    signing = SigningKey.Hs256Key(secret),
    signingKid = "2026-10",
    verify = []Jwk{ Jwk{ kid = "2026-10", key = VerifyKey.Hs256Key(secret) } },
  }
  let opts = TokenOptions{
    issuer = "https://inkwell.example",
    audience = "https://api.inkwell.example",
    algorithm = "HS256",
  }
  return AccessTokens(keys, opts)?
}
```

`signingKid` names the key in every token's header, so a verifier knows which
one to use. It must be one of the keys in `verify`, or the tokens you issue
would not verify.

Build this once at startup and share it. The constructor fails, with a message
saying what is wrong, for a short HMAC key (HS256 needs at least 32 bytes), an
empty `issuer` or `audience`, a `ttl` of zero or less, a negative `skew`, a
`signingKid` that `verify` does not list, and any key whose algorithm is not the
pinned `algorithm`. You find out when the app starts, not at the first login.

## Issue a token

`issue` takes the subject (whom the token is for), optional extra claims, and
an optional space-separated `scope`. The token lives for `ttl` seconds, fifteen
minutes unless you set it, and carries a random `jti` that is new each time.

```bit
import { Json, JsonEntry } from "std/json"

fn signIn(tokens: AccessTokens, authorId: string): string! {
  let extra = Json.JsonObject(
    []JsonEntry{
      JsonEntry{ key = "role", value = Json.JsonString("editor") },
      JsonEntry{ key = "client_id", value = Json.JsonString("inkwell-web") },
    },
  )
  return tokens.issue(authorId, extra, "drafts:read drafts:write")?
}
```

Your login route checks the password (see [Getting started](getting-started.md))
and then returns this string. Extra claims may not reuse a name `issue` writes
itself (`iss`, `sub`, `aud`, `exp`, `iat`, `nbf`, `jti`, `scope`), so a bug in
the code that builds them cannot stretch a token's life or change its owner.

## Protect the API

`BearerStrategy` reads the header, verifies the token and returns an
`Identity` whose `id` is the subject and whose `claims` are the token's whole
payload. Put it in `requireAuth` like any other strategy.

```bit
import { App, Config, MemoryStore } from "web"
import { BearerStrategy, Identity, Strategy, currentIdentity, requireAuth } from "auth"

fn inkwellApi(tokens: AccessTokens): App {
  let app = App(Config{ secret = "change-me", sessions = MemoryStore(10_000) })
  let api = app.group("/api")
  api.use(requireAuth([]Strategy{ BearerStrategy(tokens) }))
  api.get("/me", (c) => {
    return c.text(currentIdentity(c)?.id)
  })
  return app
}
```

A request with no good token gets a 401 and a `WWW-Authenticate` header, as
RFC 6750 asks. With no bearer credential at all the header is `Bearer`. With a
token that failed for any reason it is `Bearer error="invalid_token"`. The body
is empty, and the client is never told which check failed. A caller who learns
that the signature was right but the audience was wrong has learned how to
build a better forgery.

`BearerStrategy` creates no session and regenerates none. The token travels
with every request, so there is no login step for a stolen session id to
survive. `requireAuth` still stores the `Identity` it was handed for the rest
of that request.

You can put a `BearerStrategy` and a `PasswordStrategy` in one list for a route
that serves both the browser and the API. If nothing authenticates, the 401
carries the bearer challenge.

## Know why a token failed

You want the reason in your logs, even though the client must not see it.
Call `verify` yourself, where you have a logger, and keep the message.

```bit
fn checkToken(tokens: AccessTokens, token: string): Identity! {
  return tokens.verify(token) catch e {
    println("bearer refused: ${e.message()}")
    fail e
  }
}
```

`verify` refuses, each with its own message, a header `alg` that is not the
pinned one (`none` included), a `typ` that is not `at+jwt`, an unknown `kid`, a
bad signature, a wrong `iss` or `aud`, a token expired or not yet valid by more
than `skew`, and a token missing `exp`, `iat`, `sub` or `jti`. The `typ` check
is why an OpenID Connect ID token signed by the same key is not accepted as an
access token. The messages never repeat what the attacker sent, so a log line
cannot be forged by a crafted header.

## Raise the 401 yourself

A route outside `requireAuth`, a WebSocket upgrade for example, can still ask
the strategy and answer in the same shape. The error a failed
`BearerStrategy.authenticate` returns is a `BearerChallenge`, and its
`challenge` field is the header value.

```bit
import { Ctx, Res } from "web"
import { BearerChallenge } from "auth"

fn live(c: Ctx, tokens: AccessTokens): Res! {
  let bearer = BearerStrategy(tokens)
  let who = bearer.authenticate(c) catch e {
    let (bc, ok) = e.(BearerChallenge)
    if (ok) {
      return c.status(401).header("WWW-Authenticate", bc.challenge)
    }
    fail e
  }
  return c.text(who.id)
}
```

## Rotate a key without logging everyone out

A signing key should change from time to time, and at once if it leaks. A
token already in the wild was signed with the old key, and it should keep
working until it expires. List the old key in `verify` beside the new one, sign
with the new one, and take the old one out after `ttl` has passed.

```bit
fn rotated(oldSecret: []byte, newSecret: []byte): AccessTokens! {
  let keys = KeySet{
    signing = SigningKey.Hs256Key(newSecret),
    signingKid = "2026-11",
    verify = []Jwk{
      Jwk{ kid = "2026-11", key = VerifyKey.Hs256Key(newSecret) },
      Jwk{ kid = "2026-10", key = VerifyKey.Hs256Key(oldSecret) },
    },
  }
  let opts = TokenOptions{
    issuer = "https://inkwell.example",
    audience = "https://api.inkwell.example",
    algorithm = "HS256",
  }
  return AccessTokens(keys, opts)?
}
```

A token whose `kid` is not in `verify` is refused. Leaking a key is therefore
fixed by removing it from the list, which refuses everything it signed.

## Clocks, skew and expiry

Two servers' clocks are never exactly equal, so `exp`, `nbf` and `iat` are
checked with `skew` seconds of slack, a minute by default. A token is accepted
up to `skew` seconds after it expired and refused one second later. Set `skew`
lower, to zero if all your servers share a clock, and `ttl` as short as your
clients can refresh.

To test the edges without sleeping, give `TokenOptions` a `clock` that returns
seconds since the epoch and move it by hand.

```bit
class Now {
  t: i64,
}

fn testTokens(now: Now, secret: []byte): AccessTokens! {
  let keys = KeySet{
    signing = SigningKey.Hs256Key(secret),
    signingKid = "test",
    verify = []Jwk{ Jwk{ kid = "test", key = VerifyKey.Hs256Key(secret) } },
  }
  let read: () => i64 = () => now.t
  let opts = TokenOptions{
    issuer = "https://inkwell.example",
    audience = "https://api.inkwell.example",
    algorithm = "HS256",
    ttl = 60,
    skew = 5,
    clock = read,
  }
  return AccessTokens(keys, opts)?
}
```

Issue a token, set `now.t` to 65 seconds later and `verify` accepts it, to 66
and it does not.

## An asymmetric key

HS256 shares one secret between the server that signs and every server that
verifies. If a second service must verify tokens but must not be able to forge
them, sign with RS256, ES256 or EdDSA and give that service only the public
half: put `SigningKey.Rs256Key(...)` in `signing`, `VerifyKey.Rs256Key(...)` in
`verify`, and `algorithm = "RS256"`. A token signed with HS256 using your
public key as the secret is refused, because the pinned algorithm is RS256 and
the header does not get a vote.

## When not to use it

A token cannot be taken back before it expires: nothing here keeps a list of
revoked ones. Keep `ttl` short and issue a longer-lived opaque refresh token
beside it, [one that notices theft](refresh-tokens.md). If you need to cut a session off the moment a user signs out, use a
cookie session.

Where next: [Security model](security.md) for what the package checks for you
overall, and [Getting started](getting-started.md) for the password login that
hands out the first token.
